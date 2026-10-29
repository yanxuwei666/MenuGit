import Foundation

public struct ChangedFile: Identifiable, Hashable, Sendable {
    public let path: String
    public let originalPath: String?
    public let indexStatus: Character
    public let worktreeStatus: Character
    public var id: String { path }
    public var isUntracked: Bool { indexStatus == "?" && worktreeStatus == "?" }
    public var hasConflict: Bool { indexStatus == "U" || worktreeStatus == "U" || ["AA", "DD"].contains(String([indexStatus, worktreeStatus])) }
    public var isNew: Bool { isUntracked || indexStatus == "A" || worktreeStatus == "A" }
    public var isRename: Bool { indexStatus == "R" || worktreeStatus == "R" }
    public var isPartiallyStaged: Bool { indexStatus != " " && indexStatus != "?" && worktreeStatus != " " && worktreeStatus != "?" }
    /// A rename is one logical change: committing it must also record the removal of the old path.
    public var commitPaths: [String] { originalPath.map { [path, $0] } ?? [path] }
    public var label: String {
        if hasConflict { return "冲突" }; if isRename { return "已重命名" }; if isUntracked { return "未跟踪" }
        if isNew { return "已新增" }; if indexStatus == "D" || worktreeStatus == "D" { return "已删除" }
        return "已修改"
    }
}

public struct RepositoryStatus: Sendable {
    public let root: URL
    public let branch: String
    public let upstream: String?
    public let files: [ChangedFile]
    public let conflictedOperation: String?
}

public struct CommitRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let subject: String
    public let author: String
    public let date: String
}

public struct CommitPage: Sendable {
    public let commits: [CommitRecord]
    public let hasMore: Bool
}

public struct GitRepository: Sendable {
    public let root: URL
    public let git: GitRunner
    public init(root: URL, git: GitRunner = GitRunner()) { self.root = root.standardizedFileURL; self.git = git }

    public static func discover(from target: URL, git: GitRunner = GitRunner()) throws -> GitRepository {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { throw GitFailure("所选文件或文件夹不存在。") }
        let dir = isDirectory.boolValue ? target : target.deletingLastPathComponent()
        let result = try git.run(["rev-parse", "--show-toplevel"], at: dir)
        guard result.status == 0, let path = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .newlines), !path.isEmpty else {
            throw GitFailure("所选位置不属于 Git 仓库。", detail: result.error)
        }
        return GitRepository(root: URL(fileURLWithPath: path, isDirectory: true), git: git)
    }

    public func status() throws -> RepositoryStatus {
        let raw = try git.require(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root).stdout
        let records = raw.split(separator: 0, omittingEmptySubsequences: true)
        var files: [ChangedFile] = []
        var index = 0
        while index < records.count {
            guard records[index].count >= 4, let line = String(data: Data(records[index]), encoding: .utf8) else { throw GitFailure("仓库包含无法识别的文件名，已停止以保护文件。") }
            let chars = Array(line)
            guard chars.count >= 4, chars[2] == " " else { throw GitFailure("无法解析 Git 状态，已停止操作。") }
            var originalPath: String?
            if chars[0] == "R" || chars[0] == "C" || chars[1] == "R" || chars[1] == "C" {
                // Porcelain -z emits the original path as the next NUL-terminated record.
                guard index + 1 < records.count, let source = String(data: Data(records[index + 1]), encoding: .utf8) else { throw GitFailure("无法解析重命名状态，已停止操作。") }
                originalPath = source
                index += 2
            } else {
                index += 1
            }
            files.append(ChangedFile(path: String(chars.dropFirst(3)), originalPath: originalPath, indexStatus: chars[0], worktreeStatus: chars[1]))
        }
        let branchResult = try git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        let branch = branchResult.status == 0 ? branchResult.output.trimmingCharacters(in: .newlines) : "分离 HEAD"
        let upResult = try git.run(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"], at: root)
        let upstream = upResult.status == 0 ? upResult.output.trimmingCharacters(in: .newlines) : nil
        let gitDirResult = try git.require(["rev-parse", "--absolute-git-dir"], at: root)
        let gitDir = URL(fileURLWithPath: gitDirResult.output.trimmingCharacters(in: .newlines), isDirectory: true)
        let fm = FileManager.default
        let operation: String? = fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path) || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path) ? "rebase" : (fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path) ? "merge" : nil)
        return RepositoryStatus(root: root, branch: branch, upstream: upstream, files: files, conflictedOperation: operation)
    }

    public func commitIdentity() throws -> String {
        let name = try git.run(["config", "--get", "user.name"], at: root)
        let email = try git.run(["config", "--get", "user.email"], at: root)
        let value = name.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = email.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.status == 0, email.status == 0, !value.isEmpty, !address.isEmpty else {
            throw GitFailure("尚未配置 Git 提交身份。请先在终端配置 user.name 和 user.email（例如 git config --global user.name \"你的名字\"），再重新打开提交窗口。", detail: name.error + email.error)
        }
        return "\(value) <\(address)>"
    }

    public func commit(paths: [String], message: String) throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitFailure("请输入提交信息。") }
        try validate(paths: paths)
        let state = try status()
        guard state.conflictedOperation == nil, !state.files.contains(where: \.hasConflict) else { throw GitFailure("请先完成或中止当前冲突处理。") }
        let byPath = Dictionary(state.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var pathspec: [String] = []
        for path in paths {
            guard let file = byPath[path] else { throw GitFailure("文件状态已变化，请刷新后重试。") }
            for candidate in file.commitPaths where !pathspec.contains(candidate) { pathspec.append(candidate) }
        }
        _ = try commitIdentity()
        let untracked = paths.compactMap { byPath[$0] }.filter(\.isUntracked).map(\.path)
        // Intent-to-add makes new paths known to Git without staging their contents.
        if !untracked.isEmpty { try git.require(["add", "--intent-to-add", "--"] + untracked, at: root) }
        let result = try git.run(["commit", "--only", "-m", message, "--"] + pathspec, at: root)
        if result.status != 0 {
            // Only remove intent-to-add entries if they are still unmodified intent entries.
            // If another client staged a path concurrently, leave its index entry untouched.
            if !untracked.isEmpty, let now = try? status() {
                let safe = now.files.filter { untracked.contains($0.path) && $0.indexStatus == " " && $0.worktreeStatus == "A" }.map(\.path)
                if !safe.isEmpty { _ = try? git.run(["reset", "-q", "--"] + safe, at: root) }
            }
            throw GitFailure("提交失败，本地修改仍保留。", detail: result.error + result.output)
        }
        return try git.require(["rev-parse", "--short", "HEAD"], at: root).output.trimmingCharacters(in: .newlines)
    }

    public func branches() throws -> (local: [String], remote: [String]) {
        let local = try git.require(["for-each-ref", "--format=%(refname:short)", "refs/heads"], at: root).output.split(separator: "\n").map(String.init)
        let remote = try git.require(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], at: root).output.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/HEAD") }
        return (local, remote)
    }

    public func history(paths: [String] = [], skip: Int = 0, limit: Int = 200) throws -> CommitPage {
        if !paths.isEmpty { try validate(paths: paths) }
        guard skip >= 0, limit > 0 else { throw GitFailure("分页参数无效。") }
        let result = try git.run(["log", "-n", String(limit + 1), "--skip", String(skip), "--format=%h%x00%s%x00%an%x00%ar%x00"] + (paths.isEmpty ? [] : ["--"] + paths), at: root)
        if result.status != 0 {
            let head = try git.run(["rev-parse", "--verify", "HEAD"], at: root)
            if head.status != 0 { return CommitPage(commits: [], hasMore: false) }
            throw GitFailure("无法读取提交历史。", detail: result.error)
        }
        let records = parseCommits(result.stdout)
        return CommitPage(commits: Array(records.prefix(limit)), hasMore: records.count > limit)
    }

    private func parseCommits(_ data: Data) -> [CommitRecord] {
        let parts = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .newlines) }
        var records: [CommitRecord] = []
        var i = 0
        while i + 3 < parts.count { records.append(CommitRecord(id: parts[i], subject: parts[i+1], author: parts[i+2], date: parts[i+3])); i += 4 }
        return records
    }

    public func validate(paths: [String]) throws {
        guard !paths.isEmpty else { throw GitFailure("请至少选择一个文件。") }
        for path in paths {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(".."), !path.contains("\0") else {
                throw GitFailure("文件路径无效，已停止操作。")
            }
        }
    }
}

public extension GitRepository {
    func remoteNames() throws -> [String] {
        try git.require(["remote"], at: root).output.split(separator: "\n").map(String.init)
    }

    func remoteURL(name: String) throws -> String {
        try git.require(["remote", "get-url", name], at: root).output.trimmingCharacters(in: .newlines)
    }

    func addRemote(name: String, url: String) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { throw GitFailure("远端名称无效。") }
        let supported = url.hasPrefix("https://") || url.hasPrefix("ssh://") || url.hasPrefix("git@")
        guard supported, !url.contains("\n"), !url.contains("\r") else { throw GitFailure("请输入有效的 HTTPS 或 SSH 仓库地址。") }
        if let components = URLComponents(string: url), components.password != nil { throw GitFailure("地址中不能包含密码，请使用系统凭证助手。") }
        try git.require(["remote", "add", "--", name, url], at: root)
    }

    func push(remote: String, branch: String, setUpstream: Bool) throws -> String {
        guard try remoteNames().contains(remote) else { throw GitFailure("远端不存在，请刷新后重试。") }
        let check = try git.run(["check-ref-format", "refs/heads/" + branch], at: root)
        guard check.status == 0 else { throw GitFailure("远端分支名称无效。") }
        let args = ["push"] + (setUpstream ? ["--set-upstream"] : []) + ["--", remote, "HEAD:refs/heads/" + branch]
        let result = try git.run(args, at: root)
        guard result.status == 0 else { throw GitFailure("推送未完成，本地提交仍保留。", detail: result.error + result.output) }
        return result.error + result.output
    }

    func pull(remote: String, branch: String) throws -> String {
        guard try remoteNames().contains(remote) else { throw GitFailure("远端不存在，请刷新后重试。") }
        let check = try git.run(["check-ref-format", "refs/heads/" + branch], at: root)
        guard check.status == 0 else { throw GitFailure("远端分支名称无效。") }
        let known = try git.run(["show-ref", "--verify", "--quiet", "refs/remotes/" + remote + "/" + branch], at: root)
        guard known.status == 0 else { throw GitFailure("远端 \(remote) 上未找到分支 \(branch)，请先拉取或选择已有分支。") }
        let result = try git.run(["pull", "--", remote, branch], at: root)
        guard result.status == 0 else { throw GitFailure("拉取未完成，请检查冲突或错误详情。", detail: result.error + result.output) }
        return result.error + result.output
    }

    func remoteBranchExists(remote: String, branch: String) throws -> Bool {
        try git.run(["show-ref", "--verify", "--quiet", "refs/remotes/" + remote + "/" + branch], at: root).status == 0
    }

    func switchBranch(_ name: String, remote: Bool = false) throws {
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitFailure("分支名称无效。") }
        if remote {
            let local = String(name.dropFirst((name.firstIndex(of: "/").map { name.distance(from: name.startIndex, to: $0) + 1 }) ?? 0))
            guard !local.isEmpty else { throw GitFailure("远程分支名称无效。") }
            try git.require(["switch", "--track", "-c", local, "--", name], at: root)
        } else {
            try git.require(["switch", "--", name], at: root)
        }
    }

    func createBranch(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), (try git.run(["check-ref-format", "--branch", name], at: root)).status == 0 else { throw GitFailure("分支名称无效。") }
        if try branches().local.contains(name) { throw GitFailure("本地已存在分支 \(name)，请直接切换，未创建新分支。") }
        try git.require(["switch", "-c", name], at: root)
    }

    func outgoing(to remote: String, branch: String) throws -> [CommitRecord] {
        guard try remoteNames().contains(remote) else { return [] }
        let ref = "refs/remotes/" + remote + "/" + branch
        let exists = try git.run(["show-ref", "--verify", "--quiet", ref], at: root)
        let range = exists.status == 0 ? ref + "..HEAD" : "HEAD"
        let result = try git.run(["log", "-n", "200", "--format=%h%x00%s%x00%an%x00%ar%x00", range], at: root)
        guard result.status == 0 else { return [] }
        return parseCommits(result.stdout)
    }

    func showCommit(_ hash: String) throws -> String {
        guard hash.range(of: #"^[0-9a-fA-F]{4,64}$"#, options: .regularExpression) != nil else { throw GitFailure("提交编号无效。") }
        let result = try git.require(["show", "--format=fuller", "--stat", "--patch", "--no-ext-diff", "--no-color", hash], at: root).output
        let limit = 1_000_000
        guard result.utf8.count > limit else { return result }
        return String(result.prefix(limit)) + "\n…（内容过大，已截断）"
    }
}
