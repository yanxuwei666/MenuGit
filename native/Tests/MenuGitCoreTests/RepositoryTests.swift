import XCTest
@testable import MenuGitCore

final class RepositoryTests: XCTestCase {
    private var directory: URL!
    private var git: GitRunner!
    private var repository: GitRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MenuGit-tests-" + UUID().uuidString, isDirectory: true)
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

    private func initial() throws {
        try write("a.txt", "base\n"); try write("b.txt", "base\n")
        try git.require(["add", "--all"], at: directory)
        try git.require(["commit", "-qm", "initial"], at: directory)
    }

    func testCommitSelectedWorkingTreeAndUntrackedPreservesOtherStaged() throws {
        try initial()
        try write("a.txt", "staged\n"); try write("b.txt", "keep staged\n")
        try git.require(["add", "--", "a.txt", "b.txt"], at: directory)
        try write("a.txt", "working\n"); try write("new file.txt", "new\n")
        _ = try repository.commit(paths: ["a.txt", "new file.txt"], message: "selected")
        XCTAssertEqual(try git.require(["show", "HEAD:a.txt"], at: directory).output, "working\n")
        XCTAssertEqual(try git.require(["show", "HEAD:new file.txt"], at: directory).output, "new\n")
        XCTAssertTrue(try git.require(["diff", "--cached", "--", "b.txt"], at: directory).output.contains("+keep staged"))
        XCTAssertEqual(try repository.status().files.map(\.path), ["b.txt"])
    }

    func testFailedHookLeavesWorkingFilesAndOtherIndexIntact() throws {
        try initial(); try write("b.txt", "keep staged\n")
        try git.require(["add", "--", "b.txt"], at: directory)
        try write("new.txt", "new\n")
        let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho hook-failed >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        XCTAssertThrowsError(try repository.commit(paths: ["new.txt"], message: "blocked"))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("new.txt"), encoding: .utf8), "new\n")
        XCTAssertTrue(try git.require(["diff", "--cached", "--", "b.txt"], at: directory).output.contains("+keep staged"))
        XCTAssertTrue(try repository.status().files.first(where: { $0.path == "new.txt" })?.isUntracked == true)
        XCTAssertEqual(try git.require(["log", "-1", "--format=%s"], at: directory).output.trimmingCharacters(in: .whitespacesAndNewlines), "initial")
    }

    func testStatusAndCommitHandleLiteralNames() throws {
        try initial(); try write("a b\nname.txt", "new\n"); try write("-dash.txt", "dash\n")
        XCTAssertEqual(Set(try repository.status().files.map(\.path)), Set(["a b\nname.txt", "-dash.txt"]))
        _ = try repository.commit(paths: ["a b\nname.txt", "-dash.txt"], message: "literal")
        XCTAssertEqual(try git.require(["show", "HEAD:a b\nname.txt"], at: directory).output, "new\n")
        XCTAssertEqual(try git.require(["show", "HEAD:-dash.txt"], at: directory).output, "dash\n")
    }

    func testDiscoverNestedPathAndEmptyHistory() throws {
        try write("folder/file.txt", "new")
        XCTAssertEqual(try GitRepository.discover(from: directory.appendingPathComponent("folder/file.txt"), git: git).root.path, directory.standardizedFileURL.path)
        XCTAssertTrue(try repository.history().commits.isEmpty)
        XCTAssertThrowsError(try repository.validate(paths: ["../outside"]))
    }
}

extension RepositoryTests {
    func testMergeConflictChoicePreservesContextAndContinues() throws {
        let base = "header\nbase\nfooter\n"
        try write("conflict.txt", base); try git.require(["add", "--all"], at: directory); try git.require(["commit", "-qm", "base"], at: directory)
        let main = try repository.status().branch
        try git.require(["switch", "-c", "other"], at: directory)
        try write("conflict.txt", "header\nremote\nfooter\n"); try git.require(["commit", "-qam", "remote"], at: directory)
        try git.require(["switch", "--", main], at: directory)
        try write("conflict.txt", "header\nlocal\nfooter\n"); try git.require(["commit", "-qam", "local"], at: directory)
        XCTAssertNotEqual(try git.run(["merge", "other"], at: directory).status, 0)
        let document = try repository.conflictDocument(path: "conflict.txt")
        XCTAssertEqual(document.kind, .text); XCTAssertEqual(document.blocks.count, 1)
        XCTAssertEqual(document.blocks[0].local, "local"); XCTAssertEqual(document.blocks[0].incoming, "remote")
        let result = try document.result(choices: [.both])
        XCTAssertEqual(result, "header\nlocal\nremote\nfooter\n")
        try repository.saveConflict(document, result: Data(result.utf8))
        XCTAssertFalse(try repository.status().files.contains(where: \.hasConflict))
        try repository.continueConflict()
        XCTAssertNil(try repository.status().conflictedOperation)
        XCTAssertEqual(try git.require(["show", "HEAD:conflict.txt"], at: directory).output, result)
    }

    func testConflictSaveRejectsExternalChanges() throws {
        try write("conflict.txt", "base\n"); try git.require(["add", "--all"], at: directory); try git.require(["commit", "-qm", "base"], at: directory)
        let main = try repository.status().branch; try git.require(["switch", "-c", "other"], at: directory)
        try write("conflict.txt", "remote\n"); try git.require(["commit", "-qam", "remote"], at: directory)
        try git.require(["switch", "--", main], at: directory); try write("conflict.txt", "local\n"); try git.require(["commit", "-qam", "local"], at: directory)
        _ = try git.run(["merge", "other"], at: directory)
        let doc = try repository.conflictDocument(path: "conflict.txt")
        try write("conflict.txt", "external edit\n")
        XCTAssertThrowsError(try repository.saveConflict(doc, result: Data("chosen\n".utf8)))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("conflict.txt"), encoding: .utf8), "external edit\n")
        XCTAssertTrue(try repository.status().files.contains(where: \.hasConflict))
    }
}

extension RepositoryTests {
    func testCreateRemoteAndPushToBareRepository() throws {
        try initial()
        let bare = directory.deletingLastPathComponent().appendingPathComponent("MenuGit-remote-" + UUID().uuidString + ".git")
        defer { try? FileManager.default.removeItem(at: bare) }
        try git.require(["init", "--bare", bare.path], at: directory)
        try git.require(["remote", "add", "origin", bare.path], at: directory)
        XCTAssertEqual(try repository.remoteNames(), ["origin"])
        _ = try repository.push(remote: "origin", branch: "main", setUpstream: true)
        XCTAssertEqual(try git.require(["--git-dir", bare.path, "rev-parse", "refs/heads/main"], at: directory).output, try git.require(["rev-parse", "HEAD"], at: directory).output)
        XCTAssertTrue(try repository.status().upstream?.hasSuffix("origin/main") == true)
    }

    func testRemoteAddressValidationAndBranchTracking() throws {
        try initial()
        try repository.addRemote(name: "origin", url: "https://example.invalid/team/repo.git")
        XCTAssertEqual(try repository.remoteNames(), ["origin"])
        XCTAssertThrowsError(try repository.addRemote(name: "evil", url: "https://user:password@example.invalid/repo"))
        XCTAssertThrowsError(try repository.createBranch("../bad"))
        try repository.createBranch("feature/test")
        XCTAssertEqual(try repository.status().branch, "feature/test")
    }
}
