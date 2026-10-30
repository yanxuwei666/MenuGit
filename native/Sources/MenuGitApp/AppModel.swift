import AppKit
import Foundation
import MenuGitCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Screen: String { case welcome, commit, push, pull, branches, history, create, clone, settings, conflicts }
    @Published var screen: Screen = .welcome
    @Published var repository: GitRepository?
    @Published var status: RepositoryStatus?
    @Published var selected = Set<String>()
    @Published var selectedFile: String?
    @Published var preview: DiffPreview = .unavailable("选择文件查看差异。")
    @Published var message = ""
    @Published var busy = false
    @Published var error = ""
    @Published var detail = ""
    @Published var notice = ""
    @Published var identity: String?
    @Published var identityMissing = false
    @Published var commitScope = ""
    @Published var localBranches: [String] = []
    @Published var remoteBranches: [String] = []
    @Published var remotes: [String] = []
    @Published var remote = ""
    @Published var remoteBranch = ""
    @Published var setUpstream = false
    @Published var remoteAddress = ""
    @Published var newRemoteName = "origin"
    @Published var branchName = ""
    @Published var commits: [CommitRecord] = []
    @Published var historyHasMore = false
    @Published var selectedCommit: CommitRecord?
    @Published var commitDetail = ""
    @Published var outgoingCommits: [CommitRecord] = []
    @Published var targetDirectory = FileManager.default.homeDirectoryForCurrentUser
    @Published var cloneURL = ""
    @Published var cloneName = ""
    @Published var cloning = false
    @Published var cloneProgress = ""
    @Published var clonePercent: Double?
    @Published var lastCommit = ""
    @Published var resultLog = ""
    @Published var contextItems: [URL] = []
    @Published var conflictSummaries: [ConflictFileSummary] = []
    @Published var recentRepositories: [URL] = []
    @Published var extensionEnabled = false
    @Published var gitVersion = ""
    var openMainWindow: (() -> Void)?

    struct ConflictDraft {
        let document: ConflictDocument
        var choices: [ConflictChoice?]
        var editing = false
        var manualText = ""
        var changed = false
        var undo: [[ConflictChoice?]] = []
    }
    @Published var conflictDrafts: [String: ConflictDraft] = [:]
    @Published var conflictPath: String?
    @Published var conflictIndex = 0
    @Published var conflictSelected = Set<String>()
    @Published var conflictAutoNext = true
    var hasUnsavedConflictDrafts: Bool { conflictDrafts.values.contains { $0.changed } }

    private let recentKey = "MenuGit.recentRepositories"
    private let historyPageSize = 200
    private var historySkip = 0
    private var cloneTask: StreamingGitTask?

    init() {
        reloadRecent()
        gitVersion = GitRunner().version()
        extensionEnabled = FinderExtension.isEnabled
    }

    var hasUpstream: Bool { status?.upstream != nil }
    var upstreamRemote: String? {
        guard let upstream = status?.upstream else { return nil }
        return remotes.sorted { $0.count > $1.count }.first { upstream.hasPrefix($0 + "/") }
    }
    var upstreamBranch: String? {
        guard let upstream = status?.upstream, let remote = upstreamRemote else { return nil }
        return String(upstream.dropFirst(remote.count + 1))
    }
    var displayTargetRemote: String { upstreamRemote ?? remote }
    var displayTargetBranch: String { upstreamBranch ?? remoteBranch }

    func handle(_ url: URL) {
        guard url.scheme == "menugit-native", let action = url.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/") else { return }
        let target = URL(fileURLWithPath: path)
        let items = (components.queryItems ?? []).filter { $0.name == "item" }.compactMap(\.value).filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0) }
        NSApp.activate(ignoringOtherApps: true)
        if action == "settings" { screen = .settings; refreshExtensionStatus(); return }
        if action == "init" || action == "clone" {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &dir) else { show(GitFailure("所选路径不存在。")); return }
            targetDirectory = dir.boolValue ? target : target.deletingLastPathComponent()
            screen = action == "init" ? .create : .clone
            return
        }
        let targetScreen: Screen
        switch action {
        case "commit": targetScreen = .commit
        case "push": targetScreen = .push
        case "pull": targetScreen = .pull
        case "branches": targetScreen = .branches
        case "history": targetScreen = .history
        default: return
        }
        open(target, items: items, screen: targetScreen)
    }

    func open(_ url: URL, items: [URL] = [], screen destination: Screen = .commit) {
        guard !busy else { notice = "当前操作尚未完成，请稍后再试。"; return }
        busy = true; clearFeedback()
        Task {
            do {
                let data = try await Task.detached { () throws -> (GitRepository, RepositoryStatus, [String], [String], [String], String?) in
                    let repo = try GitRepository.discover(from: url)
                    let status = try repo.status(); let branches = try repo.branches(); let remotes = try repo.remoteNames()
                    let identity = try? repo.commitIdentity()
                    return (repo, status, branches.local, branches.remote, remotes, identity)
                }.value
                if repository?.root.path != data.0.root.path {
                    conflictDrafts.removeAll(); conflictSelected.removeAll(); conflictPath = nil
                }
                repository = data.0; status = data.1; localBranches = data.2; remoteBranches = data.3; remotes = data.4
                identity = data.5; identityMissing = data.5 == nil
                contextItems = items
                remember(data.0.root)
                let root = data.0.root.path
                let explicitFiles = items.filter { url in var isDir: ObjCBool = false; return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue }.compactMap { relative($0, root: root) }
                var isDir: ObjCBool = false
                let isDirectory = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                let scopedDir = isDirectory ? relative(url, root: root) : nil
                if !explicitFiles.isEmpty {
                    selected = Set(data.1.files.map(\.path).filter { explicitFiles.contains($0) })
                    commitScope = "已预选右键所选文件"
                } else if let scope = scopedDir, !scope.isEmpty {
                    selected = Set(data.1.files.filter { $0.path.hasPrefix(scope + "/") && !$0.isNew && !$0.hasConflict }.map(\.path))
                    commitScope = "右键目录：\(scope)"
                } else {
                    selected = Set(data.1.files.filter { !$0.isNew && !$0.hasConflict }.map(\.path))
                    commitScope = "整个仓库；已跟踪文件默认勾选"
                }
                selectedFile = data.1.files.first(where: { selected.contains($0.path) })?.path ?? data.1.files.first?.path
                remote = upstreamRemote ?? data.4.first ?? ""
                remoteBranch = upstreamBranch ?? data.1.branch
                setUpstream = data.1.upstream == nil
                lastCommit = ""
                if data.1.conflictedOperation != nil {
                    screen = .conflicts
                    await loadConflicts()
                    if let path = data.1.files.first(where: \.hasConflict)?.path { await loadConflict(path) }
                } else {
                    screen = destination
                    if destination == .pull, data.1.upstream == nil { syncRemoteBranchOptions() }
                    if destination == .history { await loadHistory(reset: true) }
                    if destination == .push { await loadOutgoing() }
                }
                if let selectedFile { await loadPreview(selectedFile) } else { preview = .unavailable("点击左侧文件查看差异。") }
            } catch { show(error) }
            busy = false
        }
    }

    func go(_ destination: Screen) {
        guard repository != nil else { return }
        if destination != .conflicts, let operation = status?.conflictedOperation {
            let unresolved = status?.files.contains(where: \.hasConflict) == true
            screen = .conflicts
            notice = unresolved ? "存在未解决的冲突，请先处理或中止当前操作。" : "\(operation == "rebase" ? "变基" : "合并")尚未完成，请先继续或中止。"
            Task {
                await loadConflicts()
                if unresolved, let path = firstConflictPath() { await loadConflict(path) }
            }
            return
        }
        screen = destination
        clearFeedback()
        lastCommit = ""
        switch destination {
        case .history: Task { await loadHistory(reset: true) }
        case .push: Task { await loadOutgoing() }
        case .pull: syncRemoteBranchOptions()
        case .conflicts:
            Task { await loadConflicts(); if let path = firstConflictPath() { await loadConflict(path) } }
        case .commit:
            if selectedFile == nil, let files = status?.files, !files.isEmpty {
                selectedFile = files.first(where: { selected.contains($0.path) })?.path ?? files.first?.path
            }
            if let selectedFile { Task { await loadPreview(selectedFile) } }
        default: break
        }
    }

    func refresh() async {
        guard let repository else { return }
        do {
            let data = try await Task.detached { () throws -> (RepositoryStatus, [String], [String], [String]) in
                let state = try repository.status(); let branches = try repository.branches(); return (state, branches.local, branches.remote, try repository.remoteNames())
            }.value
            status = data.0; localBranches = data.1; remoteBranches = data.2; remotes = data.3
            selected = selected.intersection(Set(data.0.files.map(\.path)))
            if data.0.files.isEmpty {
                selectedFile = nil
                preview = .unavailable("工作区没有待提交的变更。")
            } else {
                if selectedFile == nil || !data.0.files.contains(where: { $0.path == selectedFile }) {
                    selectedFile = data.0.files.first(where: { selected.contains($0.path) })?.path ?? data.0.files.first?.path
                }
                if let selectedFile { await loadPreview(selectedFile) }
            }
            if data.0.conflictedOperation != nil { await loadConflicts() }
        } catch { show(error) }
    }

    func loadPreview(_ path: String) async {
        guard let repository else { return }
        do { preview = try await Task.detached { try repository.diffPreview(path: path) }.value }
        catch { preview = .unavailable(error.localizedDescription) }
    }

    func selectFile(_ path: String) { selectedFile = path; Task { await loadPreview(path) } }
    func toggle(_ path: String) {
        if selected.contains(path) {
            selected.remove(path)
        } else {
            selected.insert(path)
            selectFile(path)
        }
    }
    func selectAll(_ on: Bool) {
        guard let status else { return }
        if on { selected = Set(status.files.filter { !$0.hasConflict }.map(\.path)) } else { selected.removeAll() }
    }
    func openSelectedFile() {
        guard let path = selectedFile else { return }
        openFile(path)
    }
    func openFile(_ path: String) {
        guard let repository else { return }
        NSWorkspace.shared.open(repository.root.appendingPathComponent(path))
    }
    func syncRemoteBranchOptions() {
        guard screen == .pull else { return }
        let existing = remoteBranches.filter { $0.hasPrefix(remote + "/") }.map { String($0.dropFirst(remote.count + 1)) }
        remoteBranch = existing.first ?? ""
    }
    func checkIdentity() {
        guard let repository else { return }
        Task {
            do { identity = try await Task.detached { try repository.commitIdentity() }.value; identityMissing = false; clearFeedback() }
            catch { identity = nil; identityMissing = true; show(error) }
        }
    }

    func commit() {
        guard let repository, !busy else { return }
        busy = true; clearFeedback(); let paths = Array(selected).sorted(); let text = message
        Task {
            do {
                lastCommit = try await Task.detached { try repository.commit(paths: paths, message: text) }.value
                message = ""; await refresh(); screen = .push; notice = "提交成功，已保存到本地。请确认推送目标。"
                await loadOutgoing()
            } catch { show(error) }
            busy = false
        }
    }

    func addRemote() {
        guard let repository, !busy else { return }; busy = true; clearFeedback(); let name = newRemoteName, url = remoteAddress
        Task {
            do { try await Task.detached { try repository.addRemote(name: name, url: url) }.value; await refresh(); remote = name; remoteBranch = status?.branch ?? remoteBranch; remoteAddress = ""; notice = "已添加当前仓库的远端。" }
            catch { show(error) }; busy = false
        }
    }

    func push() { sync(isPush: true) }
    func pull() { sync(isPush: false) }
    private func sync(isPush: Bool) {
        guard let repository, !busy else { return }
        let targetRemote = displayTargetRemote, targetBranch = displayTargetBranch
        guard !targetRemote.isEmpty, !targetBranch.isEmpty else { show(GitFailure(isPush ? "请选择远端和分支。" : "请选择要拉取的远端分支。")); return }
        busy = true; clearFeedback(); let track = setUpstream
        Task {
            do {
                resultLog = try await Task.detached { try isPush ? repository.push(remote: targetRemote, branch: targetBranch, setUpstream: track) : repository.pull(remote: targetRemote, branch: targetBranch) }.value
                if isPush { lastCommit = "" }
                await refresh(); await loadOutgoing(); notice = isPush ? "推送成功。" : "拉取成功。"
            } catch {
                await refresh()
                if status?.conflictedOperation != nil {
                    screen = .conflicts; notice = "拉取产生冲突，请先处理。"
                    await loadConflicts()
                    if let path = firstConflictPath() { await loadConflict(path) }
                } else { show(error) }
            }
            busy = false
        }
    }

    func switchBranch(_ name: String, isRemote: Bool = false) {
        guard let repository, !busy else { return }; busy = true; clearFeedback()
        Task {
            do { try await Task.detached { try repository.switchBranch(name, remote: isRemote) }.value; await refresh(); notice = "已切换分支。"; await loadHistory(reset: true); if let selectedFile { await loadPreview(selectedFile) } }
            catch { show(error) }; busy = false
        }
    }
    func createBranch() {
        guard let repository, !busy else { return }; busy = true; clearFeedback(); let name = branchName
        Task {
            do { try await Task.detached { try repository.createBranch(name) }.value; branchName = ""; await refresh(); notice = "已创建并切换分支。"; await loadHistory(reset: true) }
            catch { show(error) }; busy = false
        }
    }

    func loadHistory(reset: Bool) async {
        guard let repository else { return }
        let root = repository.root.path
        let paths = contextItems.compactMap { relative($0, root: root) }.filter { path in var dir: ObjCBool = false; return FileManager.default.fileExists(atPath: repository.root.appendingPathComponent(path).path, isDirectory: &dir) && !dir.boolValue }
        let skip = reset ? 0 : historySkip
        let limit = historyPageSize
        do {
            let page = try await Task.detached { try repository.history(paths: paths, skip: skip, limit: limit) }.value
            commits = reset ? page.commits : commits + page.commits
            historySkip = commits.count
            historyHasMore = page.hasMore
            if let first = commits.first { showCommit(first) }
        } catch { show(error) }
    }
    func loadMoreHistory() {
        guard historyHasMore, !busy else { return }
        Task { await loadHistory(reset: false) }
    }
    func showCommit(_ record: CommitRecord) {
        guard let repository else { return }
        selectedCommit = record
        Task { do { commitDetail = try await Task.detached { try repository.showCommit(record.id) }.value } catch { show(error) } }
    }

    func loadOutgoing() async {
        guard let repository else { return }
        let targetRemote = displayTargetRemote, targetBranch = displayTargetBranch
        guard !targetRemote.isEmpty, !targetBranch.isEmpty else { outgoingCommits = []; return }
        do { outgoingCommits = try await Task.detached { try repository.outgoing(to: targetRemote, branch: targetBranch) }.value }
        catch { outgoingCommits = [] }
    }

    func initialize() {
        guard !busy else { return }; busy = true; clearFeedback(); let dir = targetDirectory
        Task {
            do {
                try await Task.detached { () throws in
                    if (try? GitRepository.discover(from: dir)) != nil { throw GitFailure("此位置已位于 Git 仓库内。") }
                    try GitRunner().require(["init"], at: dir)
                }.value
                busy = false; notice = "仓库已创建。"; open(dir)
            } catch { show(error); busy = false }
        }
    }

    func startClone() {
        guard !busy else { return }
        let source = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = cloneName.trimmingCharacters(in: .whitespacesAndNewlines)
        let dir = targetDirectory
        guard (source.hasPrefix("https://") || source.hasPrefix("ssh://") || source.hasPrefix("git@")), !name.isEmpty, name != ".", name != "..", !name.contains("/") else { show(GitFailure("请输入有效仓库地址和文件夹名称。")); return }
        if URLComponents(string: source)?.password != nil { show(GitFailure("地址中不能包含密码，请使用系统凭证助手。")); return }
        let destination = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { show(GitFailure("目标文件夹已存在，请改用其他名称或位置。")); return }
        busy = true; cloning = true; cloneProgress = "正在连接远端…"; clonePercent = nil; clearFeedback()
        let runner = GitRunner()
        Task {
            do {
                let task = try await Task.detached { () throws -> StreamingGitTask in
                    try runner.startStreaming(["clone", "--progress", "--", source, name], at: dir) { line in
                        Task { @MainActor in self.applyCloneProgress(line) }
                    }
                }.value
                cloneTask = task
                let status = await Task.detached { task.wait() }.value
                let cancelled = task.isCancelled
                cloneTask = nil; cloning = false; busy = false
                if status != 0 {
                    // The destination did not exist before this run, so only the partial clone is removed.
                    let created = FileManager.default.fileExists(atPath: destination.path)
                    var cleaned = false
                    if created { cleaned = (try? FileManager.default.trashItem(at: destination, resultingItemURL: nil)) != nil }
                    if cancelled {
                        if cleaned { notice = "已取消克隆，本次创建的部分目录已移到废纸篓。" }
                        else if created { show(GitFailure("克隆已取消。部分目录可能仍在 \(destination.path)，请检查后再处理。")) }
                        else { notice = "已取消克隆。" }
                    } else {
                        show(GitFailure("克隆失败。", detail: cloneProgress))
                    }
                    return
                }
                notice = "克隆完成。"
                NSWorkspace.shared.open(destination)
                open(destination)
            } catch { cloning = false; busy = false; show(error) }
        }
    }

    func cancelClone() { cloneTask?.cancel() }

    private func applyCloneProgress(_ line: String) {
        cloneProgress = line
        if let range = line.range(of: #"\d{1,3}%"#, options: .regularExpression), let value = Double(line[range].dropLast()) {
            clonePercent = min(max(value / 100, 0), 1)
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }
    func chooseCloneDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.directoryURL = targetDirectory; panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { targetDirectory = url }
    }
    func suggestedCloneName() {
        guard cloneName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let trimmed = cloneURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = trimmed.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        let name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        if !name.isEmpty { cloneName = name }
    }

    func refreshExtensionStatus() { extensionEnabled = FinderExtension.isEnabled }
    func openExtensionSettings() { FinderExtension.openSettings() }
    func clearRecent() { UserDefaults.standard.removeObject(forKey: recentKey); recentRepositories = [] }
    func diagnostics() -> String {
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return [
            "MenuGit \(app)",
            "Git：\(gitVersion)",
            "Git 路径：\(GitRunner().executable.path)",
            "Finder 扩展：\(extensionEnabled ? "已启用" : "未启用")",
            "仓库：\(repository?.root.path ?? "无")",
            "最近仓库：\(recentRepositories.count) 个"
        ].joined(separator: "\n")
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics(), forType: .string)
        notice = "诊断信息已复制。"
    }
    func copyErrorDetail() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(detail.isEmpty ? error : detail, forType: .string)
        notice = "Git 输出已复制。"
    }

    private func reloadRecent() {
        let paths = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
        recentRepositories = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
    private func remember(_ url: URL) {
        var paths = (UserDefaults.standard.stringArray(forKey: recentKey) ?? []).filter { $0 != url.path }
        paths.insert(url.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: recentKey)
        reloadRecent()
    }

    // MARK: Conflicts

    func loadConflicts() async {
        guard let repository else { return }
        do { conflictSummaries = try await Task.detached { try repository.conflictSummaries() }.value }
        catch { show(error) }
    }
    func firstConflictPath() -> String? { status?.files.first(where: \.hasConflict)?.path }
    func unresolvedCount(for path: String) -> Int? {
        if let draft = conflictDrafts[path] { return draft.editing ? 0 : draft.choices.filter { $0 == nil }.count }
        return conflictSummaries.first(where: { $0.path == path })?.unresolvedBlocks
    }
    func conflictKind(for path: String) -> ConflictKind? {
        if let draft = conflictDrafts[path] { return draft.document.kind }
        return conflictSummaries.first(where: { $0.path == path })?.kind
    }

    func loadConflict(_ path: String) async {
        conflictPath = path; conflictIndex = 0
        guard conflictDrafts[path] == nil, let repository else { return }
        do {
            let doc = try await Task.detached { try repository.conflictDocument(path: path) }.value
            conflictDrafts[path] = ConflictDraft(document: doc, choices: Array(repeating: nil, count: doc.blocks.count))
        } catch { show(error) }
    }
    func chooseConflict(_ choice: ConflictChoice) { chooseConflict(choice, at: conflictIndex) }
    func chooseConflict(_ choice: ConflictChoice, at index: Int) {
        guard let path = conflictPath, var draft = conflictDrafts[path], draft.document.kind == .text,
              !draft.editing, draft.choices.indices.contains(index) else { return }
        draft.undo.append(draft.choices); draft.choices[index] = choice; draft.changed = true
        conflictDrafts[path] = draft
        conflictIndex = index
        if conflictAutoNext, let next = nextUnresolved(in: draft, after: index) { conflictIndex = next }
    }
    func nextUnresolved() {
        guard let path = conflictPath, let draft = conflictDrafts[path], let next = nextUnresolved(in: draft, after: conflictIndex) else { return }
        conflictIndex = next
    }
    private func nextUnresolved(in draft: ConflictDraft, after index: Int) -> Int? {
        draft.choices.indices.first(where: { $0 > index && draft.choices[$0] == nil }) ?? draft.choices.indices.first(where: { draft.choices[$0] == nil })
    }
    func undoConflict() {
        guard let path = conflictPath, var draft = conflictDrafts[path], let previous = draft.undo.popLast(), !draft.editing else { return }
        draft.choices = previous; draft.changed = previous.contains { $0 != nil }; conflictDrafts[path] = draft
    }
    func editConflict() {
        guard let path = conflictPath, var draft = conflictDrafts[path], draft.document.kind == .text else { return }
        guard !draft.choices.contains(where: { $0 == nil }) else { show(GitFailure("请先为每一处冲突选择内容，再手动编辑结果。")); return }
        guard let text = try? draft.document.result(choices: draft.choices) else { return }
        draft.manualText = text; draft.editing = true; draft.changed = true; conflictDrafts[path] = draft
    }
    func updateManualConflict(_ value: String) {
        guard let path = conflictPath, var draft = conflictDrafts[path] else { return }
        draft.manualText = value; draft.changed = true; conflictDrafts[path] = draft
    }
    func cancelConflictEdit() {
        guard let path = conflictPath, var draft = conflictDrafts[path], draft.editing else { return }
        let original = (try? draft.document.result(choices: draft.choices)) ?? ""
        if draft.manualText != original {
            let alert = NSAlert()
            alert.messageText = "放弃手动编辑的结果？"
            alert.informativeText = "返回冲突块选择后，尚未保存的编辑内容会丢失。"
            alert.addButton(withTitle: "继续编辑")
            alert.addButton(withTitle: "放弃结果")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        draft.editing = false; draft.manualText = ""; draft.changed = draft.choices.contains { $0 != nil }; conflictDrafts[path] = draft
    }
    func confirmWholeFile(_ choice: ConflictChoice) {
        guard let path = conflictPath else { return }
        let side = choice == .local ? "本地" : "传入"
        let alert = NSAlert()
        alert.messageText = "整份使用\(side)版本？"
        alert.informativeText = "将用\(side)版本替换 \(path) 的整份内容，包括冲突以外的更改；另一侧的修改会被丢弃。替换后会立即标记为已解决。"
        alert.addButton(withTitle: "替换并标记解决")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        saveConflict(choice: choice)
    }
    func saveConflict(choice: ConflictChoice? = nil) {
        guard let repository, let path = conflictPath, let draft = conflictDrafts[path], !busy else { return }
        let result: Data
        do {
            if let choice { result = choice == .local ? draft.document.localVersion : draft.document.incomingVersion }
            else if draft.editing { result = Data(draft.manualText.utf8) }
            else { result = Data(try draft.document.result(choices: draft.choices).utf8) }
        } catch { show(error); return }
        busy = true; clearFeedback()
        Task {
            do {
                try await Task.detached { try repository.saveConflict(draft.document, result: result) }.value
                conflictDrafts.removeValue(forKey: path); conflictSelected.remove(path); await refresh()
                notice = "已保存并标记 \(path) 为已解决。"
                if let next = firstConflictPath() { await loadConflict(next) } else { conflictPath = nil }
            } catch { show(error) }
            busy = false
        }
    }
    func batchConflicts(_ choice: ConflictChoice, wholeFiles: Bool) {
        guard let repository, !busy, !conflictSelected.isEmpty else { return }
        let selectedPaths = conflictSelected.sorted()
        let warning = NSAlert(); warning.messageText = wholeFiles ? "确认替换整份文件？" : "确认批量解决冲突块？"
        warning.informativeText = wholeFiles ? "将替换所选文件的另一版本，包括冲突以外的更改。\n" + selectedPaths.joined(separator: "\n") : "将对所选文本文件的冲突块使用\(choice == .local ? "本地" : "传入")内容。已有选择会保留；二进制及不支持的冲突会跳过。"
        warning.addButton(withTitle: "确认"); warning.addButton(withTitle: "取消")
        guard warning.runModal() == .alertFirstButtonReturn else { return }
        busy = true; clearFeedback()
        let existing = conflictDrafts
        Task {
            var done: [String] = []; var skipped: [String] = []
            do {
                for path in selectedPaths {
                    if existing[path]?.editing == true { skipped.append(path); continue }
                    let doc: ConflictDocument
                    if let draft = existing[path] { doc = draft.document } else { doc = try await Task.detached { try repository.conflictDocument(path: path) }.value }
                    guard doc.kind != .unsupported else { skipped.append(path); continue }
                    let result: Data
                    if wholeFiles { result = choice == .local ? doc.localVersion : doc.incomingVersion }
                    else {
                        guard doc.kind == .text else { skipped.append(path); continue }
                        let previous = existing[path]?.choices ?? Array(repeating: nil, count: doc.blocks.count)
                        let choices = previous.map { $0 ?? choice }
                        result = Data(try doc.result(choices: choices).utf8)
                    }
                    try await Task.detached { try repository.saveConflict(doc, result: result) }.value
                    done.append(path); conflictDrafts.removeValue(forKey: path); conflictSelected.remove(path)
                }
                await refresh(); notice = "已解决 \(done.count) 个文件" + (skipped.isEmpty ? "。" : "，跳过 \(skipped.count) 个不支持的文件。")
            } catch { await refresh(); show(GitFailure("批量处理中断，已完成 \(done.count) 个文件，其余文件保留。", detail: (error as? GitFailure)?.detail ?? error.localizedDescription)) }
            if let next = firstConflictPath() { await loadConflict(next) } else { conflictPath = nil }
            busy = false
        }
    }
    func continueConflict() {
        guard let repository, !busy else { return }; busy = true; clearFeedback()
        Task {
            do {
                try await Task.detached { try repository.continueConflict() }.value
                await refresh(); await loadOutgoing()
                if status?.conflictedOperation != nil { screen = .conflicts; notice = "操作仍在进行，请继续处理。" }
                else { conflictDrafts.removeAll(); lastCommit = ""; screen = .push; notice = "冲突已解决；确认后可以推送。" }
            }
            catch {
                await refresh()
                if let path = firstConflictPath() { screen = .conflicts; await loadConflicts(); await loadConflict(path); notice = "继续时出现新的冲突，请继续处理。" }
                else { show(error) }
            }
            busy = false
        }
    }
    func abortConflict() {
        guard let repository, !busy else { return }
        let alert = NSAlert(); alert.messageText = "确认中止当前操作？"; alert.informativeText = "冲突处理期间的修改可能丢失；操作开始前的未提交修改也不保证都能恢复。"; alert.addButton(withTitle: "中止"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true; clearFeedback()
        Task { do { try await Task.detached { try repository.abortConflict() }.value; conflictDrafts.removeAll(); await refresh(); screen = .commit; notice = "已中止当前操作。" } catch { show(error) }; busy = false }
    }

    func show(_ error: Error) { self.error = error.localizedDescription; detail = (error as? GitFailure)?.detail ?? "" }
    func clearFeedback() { error = ""; detail = ""; notice = "" }
    private func relative(_ url: URL, root: String) -> String? {
        let path = url.standardizedFileURL.path
        if path == root { return "" }
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }
}
