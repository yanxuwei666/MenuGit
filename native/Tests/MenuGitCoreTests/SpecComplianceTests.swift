import XCTest
@testable import MenuGitCore

final class SpecComplianceTests: XCTestCase {
    private var directory: URL!
    private var git: GitRunner!
    private var repository: GitRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuGit-spec-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        git = GitRunner()
        try git.require(["init", "-q"], at: directory)
        try git.require(["config", "user.name", "MenuGit Test"], at: directory)
        try git.require(["config", "user.email", "test@example.invalid"], at: directory)
        repository = GitRepository(root: directory, git: git)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func write(_ path: String, _ contents: String) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commitAll(_ message: String = "initial") throws {
        try git.require(["add", "--all"], at: directory)
        try git.require(["commit", "-qm", message], at: directory)
    }

    func testRemoteBranchListingSkipsRemoteHeadSymbolicRef() throws {
        try write("a.txt", "base\n"); try commitAll()
        let bare = directory.deletingLastPathComponent().appendingPathComponent("MenuGit-bare-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bare) }
        try git.require(["init", "-q", "--bare", bare.path], at: directory)
        try git.require(["remote", "add", "origin", bare.path], at: directory)
        try git.require(["push", "-q", "origin", "HEAD"], at: directory)
        _ = try? git.require(["remote", "set-head", "origin", "--auto"], at: directory)
        let current = try git.require(["rev-parse", "--abbrev-ref", "HEAD"], at: directory).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let branches = try repository.branches()
        XCTAssertFalse(branches.remote.contains("origin"))
        XCTAssertTrue(branches.remote.contains("origin/\(current)"))
    }

    func testRenameIsOneLogicalChange() throws {
        try write("a.txt", "base\n"); try commitAll()
        try git.require(["mv", "a.txt", "b.txt"], at: directory)
        let state = try repository.status()
        XCTAssertEqual(state.files.count, 1)
        let file = try XCTUnwrap(state.files.first)
        XCTAssertEqual(file.path, "b.txt")
        XCTAssertEqual(file.originalPath, "a.txt")
        XCTAssertTrue(file.isRename)
        XCTAssertEqual(file.label, "已重命名")
        XCTAssertEqual(Set(file.commitPaths), Set(["a.txt", "b.txt"]))
        _ = try repository.commit(paths: ["b.txt"], message: "rename")
        XCTAssertEqual(try git.require(["ls-tree", "-r", "--name-only", "HEAD"], at: directory).output, "b.txt\n")
    }

    func testRenameWithWorkingTreeEditCommitsNewContent() throws {
        try write("a.txt", "base\n"); try commitAll()
        try git.require(["mv", "a.txt", "b.txt"], at: directory)
        try write("b.txt", "changed\n")
        _ = try repository.commit(paths: ["b.txt"], message: "rename and edit")
        XCTAssertEqual(try git.require(["show", "HEAD:b.txt"], at: directory).output, "changed\n")
        XCTAssertEqual(try git.require(["ls-tree", "-r", "--name-only", "HEAD"], at: directory).output, "b.txt\n")
    }

    func testCommitWithoutIdentityIsRejectedBeforeChangingIndex() throws {
        try git.require(["config", "--unset", "user.name"], at: directory)
        try git.require(["config", "--unset", "user.email"], at: directory)
        let home = directory.deletingLastPathComponent().appendingPathComponent("MenuGit-empty-home-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let isolated = GitRunner(extraEnvironment: ["HOME": home.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path])
        let isolatedRepository = GitRepository(root: directory, git: isolated)
        try write("new.txt", "content\n")
        XCTAssertThrowsError(try isolatedRepository.commitIdentity()) { error in
            XCTAssertTrue(error.localizedDescription.contains("身份"), error.localizedDescription)
        }
        XCTAssertThrowsError(try isolatedRepository.commit(paths: ["new.txt"], message: "no identity"))
        XCTAssertTrue(try isolatedRepository.status().files.first(where: { $0.path == "new.txt" })?.isUntracked == true)
    }

    func testHistoryPagination() throws {
        try write("a.txt", "1\n"); try commitAll("one")
        try write("a.txt", "2\n"); try commitAll("two")
        try write("a.txt", "3\n"); try commitAll("three")
        let first = try repository.history(limit: 2)
        XCTAssertEqual(first.commits.count, 2)
        XCTAssertTrue(first.hasMore)
        XCTAssertEqual(first.commits.map(\.subject), ["three", "two"])
        let second = try repository.history(skip: 2, limit: 2)
        XCTAssertEqual(second.commits.map(\.subject), ["one"])
        XCTAssertFalse(second.hasMore)
    }

    func testConflictBlockStartLinesAndSummary() throws {
        try write("conflict.txt", "header\nbase\nfooter\n"); try commitAll()
        let main = try repository.status().branch
        try git.require(["switch", "-c", "other"], at: directory)
        try write("conflict.txt", "header\nremote\nfooter\n"); try commitAll("remote")
        try git.require(["switch", "--", main], at: directory)
        try write("conflict.txt", "header\nlocal\nfooter\n"); try commitAll("local")
        XCTAssertNotEqual(try git.run(["merge", "other"], at: directory).status, 0)
        let document = try repository.conflictDocument(path: "conflict.txt")
        XCTAssertEqual(document.localStartLines, [2])
        XCTAssertEqual(document.incomingStartLines, [2])
        let summaries = try repository.conflictSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].path, "conflict.txt")
        XCTAssertEqual(summaries[0].unresolvedBlocks, 1)
        if case .text = summaries[0].kind {} else { XCTFail("expected text conflict") }
    }

    func testPullRejectsUnknownRemoteBranch() throws {
        try write("a.txt", "base\n"); try commitAll()
        let bare = directory.deletingLastPathComponent().appendingPathComponent("MenuGit-remote-" + UUID().uuidString + ".git")
        defer { try? FileManager.default.removeItem(at: bare) }
        try git.require(["init", "--bare", bare.path], at: directory)
        try git.require(["remote", "add", "origin", bare.path], at: directory)
        XCTAssertThrowsError(try repository.pull(remote: "origin", branch: "main")) { error in
            XCTAssertTrue(error.localizedDescription.contains("未找到分支"), error.localizedDescription)
        }
    }

    func testDiffPreviewSectionsAndKinds() throws {
        try write("a.txt", "base\n"); try commitAll()
        try write("a.txt", "staged\n")
        try git.require(["add", "--", "a.txt"], at: directory)
        try write("a.txt", "working\n")
        guard case let .text(sections) = try repository.diffPreview(path: "a.txt") else { return XCTFail("expected text preview") }
        XCTAssertEqual(sections.map(\.title), ["已暂存", "未暂存"])
        let kinds = sections.flatMap(\.lines).map(\.kind)
        XCTAssertTrue(kinds.contains(.added))
        XCTAssertTrue(kinds.contains(.removed))
        XCTAssertTrue(kinds.contains(.header))
    }

    func testDiffPreviewUntrackedAndBinary() throws {
        try write("new.txt", "one\ntwo\n")
        guard case let .text(sections) = try repository.diffPreview(path: "new.txt") else { return XCTFail("expected text preview") }
        XCTAssertEqual(sections.first?.lines.map(\.text), ["one", "two", ""])
        XCTAssertTrue(sections.flatMap(\.lines).allSatisfy { $0.kind == .added })
        try Data([0, 1, 2, 3]).write(to: directory.appendingPathComponent("image.bin"))
        guard case .binary = try repository.diffPreview(path: "image.bin") else { return XCTFail("expected binary preview") }
    }

    func testCreatingExistingBranchDoesNotSwitchOrReset() throws {
        try write("a.txt", "base\n"); try commitAll()
        let initial = try repository.status().branch
        try repository.createBranch("feature")
        XCTAssertEqual(try repository.status().branch, "feature")
        XCTAssertThrowsError(try repository.createBranch(initial)) { error in
            XCTAssertTrue(error.localizedDescription.contains("已存在"), error.localizedDescription)
        }
    }

    func testStreamingCloneReportsProgressAndCreatesWorktree() throws {
        try write("a.txt", "base\n"); try commitAll()
        let parent = directory.deletingLastPathComponent()
        let bare = parent.appendingPathComponent("MenuGit-clone-source-" + UUID().uuidString + ".git")
        let destination = parent.appendingPathComponent("MenuGit-clone-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: destination)
        }
        try git.require(["clone", "--bare", directory.path, bare.path], at: parent)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let output = OutputBox()
        let task = try git.startStreaming(["clone", "--progress", "--", bare.path, "copy"], at: destination) { line in
            output.append(line)
        }
        XCTAssertEqual(task.wait(), 0)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("copy/a.txt"), encoding: .utf8), "base\n")
        XCTAssertFalse(output.lines.isEmpty)
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
}
