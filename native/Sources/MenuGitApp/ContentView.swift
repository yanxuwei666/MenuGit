import AppKit
import MenuGitCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            header
            feedback
            if model.busy { ProgressView().controlSize(.small).padding(6) }
            content.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.busy)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch model.screen {
        case .welcome: WelcomeView(model: model)
        case .commit: CommitView(model: model)
        case .push: SyncView(model: model, push: true)
        case .pull: SyncView(model: model, push: false)
        case .branches: BranchesView(model: model)
        case .history: HistoryView(model: model)
        case .create: CreateView(model: model)
        case .clone: CloneView(model: model)
        case .settings: SettingsView(model: model)
        case .conflicts: ConflictsView(model: model)
        }
    }

    @ViewBuilder private var feedback: some View {
        if !model.notice.isEmpty {
            Banner(text: model.notice, color: .green)
        }
        if !model.error.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Banner(text: model.error, color: .red, actionTitle: "复制 Git 输出", action: copyErrorAction)
                if !model.detail.isEmpty { errorDetail }
            }
        }
    }

    private var copyErrorAction: () -> Void {
        { model.copyErrorDetail() }
    }

    private var errorDetail: some View {
        DisclosureGroup("显示 Git 详情") {
            Text(model.detail)
                .textSelection(.enabled)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.horizontal)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.blue)
            Text(title).font(.headline)
            if let status = model.status, model.repository != nil {
                Text(status.branch).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.blue.opacity(0.12), in: Capsule())
            }
            if model.repository != nil { navigation }
            Spacer()
            if let path = model.repository?.root.path {
                Text(path).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).font(.caption)
            }
            headerActions
        }.padding(14).background(.bar)
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            if model.status?.conflictedOperation != nil, model.screen != .conflicts {
                Button(model.status?.files.contains(where: \.hasConflict) == true ? "解决冲突" : "完成\(model.status?.conflictedOperation == "rebase" ? "变基" : "合并")") { model.go(.conflicts) }.disabled(model.busy)
            }
            Button("打开仓库") { model.chooseFolder() }.disabled(model.busy)
            Button {
                model.refreshExtensionStatus()
                model.screen = .settings
            } label: {
                Image(systemName: "gearshape")
            }.help("设置")
        }
    }

    private var navigation: some View {
        Picker("", selection: navigationBinding) {
            Text("提交").tag(AppModel.Screen.commit)
            Text("推送").tag(AppModel.Screen.push)
            Text("拉取").tag(AppModel.Screen.pull)
            Text("分支").tag(AppModel.Screen.branches)
            Text("日志").tag(AppModel.Screen.history)
        }
        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
    }

    private var navigationBinding: Binding<AppModel.Screen> {
        Binding(get: { model.screen }, set: { model.go($0) })
    }

    private var title: String {
        switch model.screen {
        case .welcome: return "MenuGit"
        case .commit: return "提交"
        case .push: return "推送"
        case .pull: return "拉取"
        case .branches: return "分支"
        case .history: return "日志"
        case .create: return "创建仓库"
        case .clone: return "克隆"
        case .settings: return "设置"
        case .conflicts:
            guard let operation = model.status?.conflictedOperation else { return "解决冲突" }
            if model.status?.files.contains(where: \.hasConflict) == true { return "解决冲突" }
            return operation == "rebase" ? "完成变基" : "完成合并"
        }
    }
}

struct Banner: View {
    let text: String
    let color: Color
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action { Button(actionTitle, action: action).buttonStyle(.link) }
        }
        .padding(10).background(color.opacity(0.12)).foregroundStyle(color).padding(.horizontal, 14).padding(.top, 8)
    }
}

struct WelcomeView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 42)).foregroundStyle(.blue)
            Text("从 Finder 右键使用 MenuGit").font(.title2.bold())
            Text("也可以在下方选择最近仓库或打开本地仓库。").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("打开仓库") { model.chooseFolder() }.buttonStyle(.borderedProminent)
                Button("设置") { model.refreshExtensionStatus(); model.screen = .settings }
            }
            if !model.recentRepositories.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("最近仓库").font(.headline)
                        Spacer()
                        Button("清除") { model.clearRecent() }.buttonStyle(.link)
                    }.padding(.bottom, 6)
                    ForEach(model.recentRepositories, id: \.self) { url in
                        Button { model.open(url) } label: {
                            HStack {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                    Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                            }.contentShape(Rectangle()).padding(.vertical, 5)
                        }.buttonStyle(.plain)
                        Divider()
                    }
                }.frame(maxWidth: 460).padding(.top, 8)
            }
            Spacer()
            Text("Finder 扩展：\(model.extensionEnabled ? "已启用" : "尚未启用")")
                .font(.caption).foregroundStyle(model.extensionEnabled ? .green : .orange)
        }.padding(24)
    }
}

struct CommitView: View {
    @ObservedObject var model: AppModel
    private var selectable: [ChangedFile] { (model.status?.files ?? []).filter { !$0.hasConflict } }
    private var allSelected: Bool { !selectable.isEmpty && selectable.allSatisfy { model.selected.contains($0.path) } }
    private var partialSelected: Bool { (model.status?.files ?? []).contains { model.selected.contains($0.path) && $0.isPartiallyStaged } }
    private var longFirstLine: Bool { (model.message.split(separator: "\n", omittingEmptySubsequences: false).first?.count ?? 0) > 50 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择本次提交的文件；选中文件以工作区当前内容提交，未选文件的已暂存内容会保留。")
                .font(.caption).foregroundStyle(.secondary)
            Text("范围：\(model.commitScope)").font(.caption).foregroundStyle(.secondary)
            if model.identityMissing {
                Banner(text: "尚未配置 Git 提交身份。请先在终端配置 user.name 和 user.email。", color: .orange, actionTitle: "重新检查", action: model.checkIdentity)
            }
            if partialSelected {
                Banner(text: "所选文件同时包含已暂存和未暂存修改，将提交工作区当前完整内容。", color: .orange)
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("全选", isOn: Binding(get: { allSelected }, set: { model.selectAll($0) })).toggleStyle(.checkbox)
                        Spacer()
                        Text("已选 \(model.selected.count) / \(model.status?.files.count ?? 0) 项").foregroundStyle(.secondary).font(.caption)
                    }
                    List(model.status?.files ?? []) { file in
                        HStack {
                            Toggle("", isOn: Binding(get: { model.selected.contains(file.path) }, set: { _ in model.toggle(file.path) })).labelsHidden().disabled(file.hasConflict)
                            Button { model.selectFile(file.path) } label: {
                                HStack {
                                    Text(file.label).font(.caption).foregroundStyle(color(for: file))
                                    Text(file.path).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if file.isPartiallyStaged { Text("部分暂存").font(.caption).foregroundStyle(.orange) }
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                    if let status = model.status, status.files.isEmpty {
                        Text("工作区干净，没有可提交的变更。").foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }.frame(minWidth: 280)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(model.selectedFile ?? "差异").font(.headline).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("用默认应用打开") { model.openSelectedFile() }.disabled(model.selectedFile == nil)
                    }
                    DiffPreviewView(preview: model.preview) { model.openSelectedFile() }
                }.frame(minWidth: 300)
            }
            Text("提交信息").font(.headline)
            TextEditor(text: $model.message).font(.body).frame(height: 80).border(Color.secondary.opacity(0.25))
            if longFirstLine { Text("首行较长，建议精简到 50 字符以内（不强制）。").font(.caption).foregroundStyle(.orange) }
            HStack {
                Text("提交只保存到本地，之后需要确认推送。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("提交") { model.commit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selected.isEmpty || model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.identityMissing)
            }
        }.padding(16)
    }

    private func color(for file: ChangedFile) -> Color {
        if file.hasConflict { return .red }
        if file.isUntracked { return .secondary }
        if file.isRename { return .purple }
        return .blue
    }
}

struct DiffPreviewView: View {
    let preview: DiffPreview
    let onOpen: () -> Void

    @ViewBuilder var body: some View {
        switch preview {
        case .text(let sections):
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title).font(.caption.bold()).foregroundStyle(.secondary).padding(.vertical, 3)
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.text.isEmpty ? " " : line.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(foreground(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(background(line.kind))
                        }
                        Divider()
                    }
                }.padding(8).textSelection(.enabled)
            }
        case .binary:
            VStack(alignment: .leading, spacing: 10) {
                Text("二进制文件，不在应用内渲染差异。").foregroundStyle(.secondary)
                Button("在默认应用中打开", action: onOpen)
                Spacer()
            }.padding(8)
        case .tooLarge:
            VStack(alignment: .leading, spacing: 10) {
                Text("差异过大，未在应用内完整渲染。").foregroundStyle(.secondary)
                Button("在默认应用中打开", action: onOpen)
                Spacer()
            }.padding(8)
        case .unavailable(let message):
            Text(message).foregroundStyle(.secondary).padding(8)
        }
    }

    private func foreground(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .added: return .green; case .removed: return .red; case .header: return .secondary; case .context: return .primary }
    }
    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind { case .added: return .green.opacity(0.12); case .removed: return .red.opacity(0.12); default: return .clear }
    }
}

struct CodePane: View {
    let lines: [String]
    let startLine: Int
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(startLine + offset)").foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                        Text(line.isEmpty ? " " : line)
                    }.font(.system(.caption, design: .monospaced))
                }
            }.padding(6).textSelection(.enabled)
        }
    }
}

struct SyncView: View {
    @ObservedObject var model: AppModel
    let push: Bool
    private var availableBranches: [String] {
        model.remoteBranches.filter { $0.hasPrefix(model.remote + "/") }
            .map { String($0.dropFirst(model.remote.count + 1)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if push, !model.lastCommit.isEmpty { Banner(text: "本地提交 \(model.lastCommit) 已创建；点击推送才会发送。", color: .green) }
            if model.remotes.isEmpty {
                Text("尚未配置远端仓库").font(.headline)
                Text("添加远端只会更改当前仓库。请使用系统 Git 凭证助手或 SSH 配置。").foregroundStyle(.secondary)
                if push {
                    TextField("远端名称", text: $model.newRemoteName)
                    TextField("HTTPS 或 SSH 地址", text: $model.remoteAddress)
                    Button("添加远端") { model.addRemote() }.disabled(model.remoteAddress.isEmpty)
                } else {
                    Text("需要先推送或手动配置远端后才能拉取。").font(.caption).foregroundStyle(.orange)
                }
            } else {
                if model.hasUpstream {
                    Text("目标：\(model.displayTargetRemote)/\(model.displayTargetBranch)").font(.headline)
                    Text("当前分支已配置上游，操作直接使用该上游。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Form {
                        Picker("远端", selection: $model.remote) { ForEach(model.remotes, id: \.self) { Text($0).tag($0) } }
                            .onChange(of: model.remote) { _ in model.syncRemoteBranchOptions() }
                        if push {
                            TextField("远端分支（不存在时创建）", text: $model.remoteBranch)
                            Toggle("记住为当前分支的上游", isOn: $model.setUpstream)
                        } else if availableBranches.isEmpty {
                            Text("该远端没有可用分支，请先推送或刷新。").foregroundStyle(.orange)
                        } else {
                            Picker("远端分支", selection: $model.remoteBranch) {
                                ForEach(availableBranches, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    }.formStyle(.grouped)
                }
                Text(push ? "不会执行强制推送；推送失败时本地提交保留。" : "拉取遵循当前 Git 配置；遇到冲突时暂停。")
                    .foregroundStyle(.secondary).font(.caption)
                if push {
                    Text("待推送提交（\(model.outgoingCommits.count)）").font(.headline)
                    if model.outgoingCommits.isEmpty {
                        Text("没有待推送提交。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.outgoingCommits.prefix(20)) { commit in
                                HStack(alignment: .top) {
                                    Text(commit.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(commit.subject).lineLimit(1)
                                    Spacer()
                                    Text(commit.author).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                if !model.resultLog.isEmpty {
                    ScrollView { Text(model.resultLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 100)
                }
                HStack {
                    Spacer()
                    Button(push ? "推送" : "拉取") { push ? model.push() : model.pull() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.displayTargetRemote.isEmpty || model.displayTargetBranch.isEmpty)
                }
            }
            Spacer()
        }.padding(24)
    }
}

struct BranchesView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let status = model.status, !status.files.isEmpty {
                Text("工作区有 \(status.files.count) 个未提交更改。MenuGit 不会自动暂存或丢弃；Git 判断会覆盖修改时会阻止切换。")
                    .font(.caption).foregroundStyle(.orange)
            }
            List {
                Section("本地分支") {
                    ForEach(model.localBranches, id: \.self) { branch in
                        HStack {
                            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            Text(branch)
                            Spacer()
                            if branch == model.status?.branch { Text("当前").foregroundStyle(.green) }
                            else { Button("切换") { model.switchBranch(branch) } }
                        }
                    }
                }
                Section("远程分支") {
                    ForEach(model.remoteBranches, id: \.self) { branch in
                        HStack {
                            Text(branch)
                            Spacer()
                            if let local = localName(for: branch), model.localBranches.contains(local) {
                                Text("已有本地分支 \(local)").foregroundStyle(.secondary)
                            } else {
                                Button("检出为跟踪分支") { model.switchBranch(branch, isRemote: true) }
                            }
                        }
                    }
                }
            }
            HStack {
                TextField("例如 feature/new-ui", text: $model.branchName)
                Button("创建并切换") { model.createBranch() }.buttonStyle(.borderedProminent).disabled(model.branchName.isEmpty)
            }.padding(.top, 8)
        }.padding(16)
    }

    private func localName(for remoteBranch: String) -> String? {
        guard let remote = model.remotes.first(where: { remoteBranch.hasPrefix($0 + "/") }) else { return nil }
        return String(remoteBranch.dropFirst(remote.count + 1))
    }
}

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    private var filtered: [CommitRecord] {
        model.commits.filter { search.isEmpty || ($0.subject + $0.author).localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(spacing: 8) {
            TextField("搜索提交信息或作者", text: $search)
            HSplitView {
                VStack(spacing: 0) {
                    List(filtered) { commit in
                        Button { model.showCommit(commit) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(commit.subject).fontWeight(.medium)
                                Text("\(commit.id) · \(commit.author) · \(commit.date)").font(.caption).foregroundStyle(.secondary)
                            }
                        }.buttonStyle(.plain)
                    }
                    if model.historyHasMore, search.isEmpty {
                        Button("加载更早的提交") { model.loadMoreHistory() }.padding(6)
                    }
                }.frame(minWidth: 280)
                ScrollView([.horizontal, .vertical]) {
                    Text(model.commitDetail.isEmpty ? "选择提交查看详情。" : model.commitDetail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 300)
            }
        }.padding(16)
    }
}

struct CreateView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("在此创建 Git 仓库").font(.title2.bold())
            Text(model.targetDirectory.path).textSelection(.enabled)
            Button("选择其他目录") { model.chooseCloneDirectory() }
            Text("将初始化所选目录。若该目录已属于仓库，操作会被阻止。").foregroundStyle(.secondary)
            Button("初始化") { model.initialize() }.buttonStyle(.borderedProminent)
            Spacer()
        }.padding(24)
    }
}

struct CloneView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("克隆仓库").font(.title2.bold())
            TextField("HTTPS 或 SSH 仓库地址", text: $model.cloneURL).onChange(of: model.cloneURL) { _ in model.suggestedCloneName() }
            TextField("新建文件夹名称", text: $model.cloneName)
            HStack {
                Text("目标目录：\(model.targetDirectory.path)").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("选择…") { model.chooseCloneDirectory() }.disabled(model.cloning)
            }
            if model.cloning {
                if let percent = model.clonePercent { ProgressView(value: percent) }
                else { ProgressView() }
                Text(model.cloneProgress).font(.system(.caption, design: .monospaced)).lineLimit(2).foregroundStyle(.secondary)
                Button("取消克隆") { model.cancelClone() }
            } else {
                Button("克隆") { model.startClone() }.buttonStyle(.borderedProminent)
            }
            Spacer()
        }.padding(24)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MenuGit 设置").font(.title2.bold())
            HStack {
                Text("Finder 扩展")
                Spacer()
                Text(model.extensionEnabled ? "已启用" : "未启用").foregroundStyle(model.extensionEnabled ? .green : .orange)
                Button("打开系统设置") { model.openExtensionSettings() }
                Button("刷新状态") { model.refreshExtensionStatus() }
            }
            if !model.extensionEnabled {
                Text("在“系统设置 → 通用 → 登录项与扩展 → Finder 扩展”中启用 MenuGit。").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("MenuGit 使用系统 Git、凭证助手、SSH agent 和 Git hooks，不保存账号凭证，不修改全局 Git 配置。").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Text("本机诊断信息")
                Spacer()
                Button("复制") { model.copyDiagnostics() }
            }
            Text(model.diagnostics()).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Divider()
            HStack {
                Text("最近仓库")
                Spacer()
                Text("\(model.recentRepositories.count) 个").foregroundStyle(.secondary)
                Button("清除") { model.clearRecent() }
            }
            Divider()
            HStack {
                Text("关于 MenuGit")
                Spacer()
                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")").foregroundStyle(.secondary)
            }
            HStack {
                Text("检查更新")
                Spacer()
                Text("更新地址待设置").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.padding(24)
    }
}

struct ConflictsView: View {
    @ObservedObject var model: AppModel
    @State private var search = ""
    private var files: [ChangedFile] { (model.status?.files ?? []).filter(\.hasConflict) }
    private var draft: AppModel.ConflictDraft? { model.conflictPath.flatMap { model.conflictDrafts[$0] } }
    private var operationName: String { model.status?.conflictedOperation == "rebase" ? "变基" : "合并" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if files.isEmpty, model.status?.conflictedOperation != nil {
                completion
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(operationName)冲突 · 剩余 \(files.count) 个文件").font(.headline)
                    if let draft {
                        Text("未解决 \(draft.choices.filter { $0 == nil }.count) 处").font(.caption).foregroundStyle(.red)
                    }
                    Spacer()
                    Button("撤销选择") { model.undoConflict() }.disabled(draft?.undo.isEmpty ?? true)
                }
                HSplitView {
                    sidebar.frame(minWidth: 220, idealWidth: 262, maxWidth: 320)
                    detail.frame(minWidth: 380)
                }
                HStack(spacing: 10) {
                    Button("中止\(operationName)") { model.abortConflict() }
                    Text("编辑中的文件需先保存或取消；二进制文件只能选择整份版本。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("继续\(operationName)") { model.continueConflict() }.buttonStyle(.borderedProminent)
                        .disabled(!files.isEmpty)
                        .opacity(files.isEmpty ? 1 : 0.45)
                }
            }
        }.padding(16)
    }

    private var completion: some View {
        let staged = model.status?.files.filter { $0.indexStatus != " " && $0.indexStatus != "?" }.count ?? 0
        let untracked = model.status?.files.filter(\.isUntracked).count ?? 0
        return VStack(spacing: 12) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 42)).foregroundStyle(.green)
            Text("所有冲突文件已解决").font(.title3.bold())
            Text("\(operationName)仍在进行中。继续后由 Git 生成\(operationName)提交，提交信息使用当前 Git 内容；中止会尝试恢复到操作前状态。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 520)
            Text("合并结果包含 \(staged) 个已暂存的文件变更").font(.caption).foregroundStyle(.secondary)
            if untracked > 0 {
                Text("\(untracked) 个未跟踪文件不在本次合并提交中，完成后可单独提交。").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("中止\(operationName)") { model.abortConflict() }
                Button("继续\(operationName)") { model.continueConflict() }.buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("搜索冲突文件", text: $search)
            List(files.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }) { file in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { model.conflictSelected.contains(file.path) }, set: { on in if on { model.conflictSelected.insert(file.path) } else { model.conflictSelected.remove(file.path) } })).labelsHidden()
                    Button { Task { await model.loadConflict(file.path) } } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text(statusText(file.path)).font(.caption).foregroundStyle(statusColor(file.path))
                        }
                    }.buttonStyle(.plain)
                }
            }
            Text("已选择 \(model.conflictSelected.count) 个文件").font(.caption).foregroundStyle(.secondary)
            Text("仅处理未解决的冲突块").font(.caption.bold())
            HStack {
                Button("批量使用本地") { model.batchConflicts(.local, wholeFiles: false) }
                Button("批量使用传入") { model.batchConflicts(.incoming, wholeFiles: false) }
            }.disabled(model.conflictSelected.isEmpty)
            Text("替换整份文件").font(.caption.bold())
            HStack {
                Button("整份保留本地") { model.batchConflicts(.local, wholeFiles: true) }
                Button("整份使用传入") { model.batchConflicts(.incoming, wholeFiles: true) }
            }.disabled(model.conflictSelected.isEmpty)
        }
    }

    @ViewBuilder private var detail: some View {
        if let draft, let path = model.conflictPath {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(path).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button("整份本地") { model.confirmWholeFile(.local) }.help("用本地版本替换整份文件，包括冲突以外的更改")
                    Button("整份传入") { model.confirmWholeFile(.incoming) }.help("用传入版本替换整份文件，包括冲突以外的更改")
                }
                switch draft.document.kind {
                case .text where !draft.document.blocks.isEmpty: textConflict(draft, path: path)
                case .binary: binaryConflict(draft, path: path)
                default:
                    Text(draft.document.reason).foregroundStyle(.secondary)
                    Button("在默认应用中打开") { model.openFile(path) }
                    Spacer()
                }
            }
        } else {
            VStack {
                Spacer()
                Text(files.isEmpty ? "所有冲突文件已解决，可以继续操作。" : "选择文件查看冲突。").foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func textConflict(_ draft: AppModel.ConflictDraft, path: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if draft.editing {
                TextEditor(text: Binding(get: { model.conflictDrafts[path]?.manualText ?? "" }, set: { model.updateManualConflict($0) }))
                    .font(.system(size: 11.5, design: .monospaced))
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
                HStack {
                    Text("删除全部冲突标记后保存；内容会原样写入该文件。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("取消编辑") { model.cancelConflictEdit() }
                    Button("保存并标记解决") { model.saveConflict() }.buttonStyle(.borderedProminent)
                }
            } else {
                navigation(draft)
                conflictDocument(draft)
                footer(draft)
            }
        }
    }

    private func navigation(_ draft: AppModel.ConflictDraft) -> some View {
        let count = draft.document.blocks.count
        let index = min(model.conflictIndex, max(count - 1, 0))
        let unresolved = draft.choices.filter { $0 == nil }.count
        return HStack(spacing: 8) {
            Text("第 \(index + 1) / \(count) 处").font(.caption)
            Text(unresolved > 0 ? "未解决 \(unresolved) 处" : "全部已选择").font(.caption.bold()).foregroundStyle(unresolved > 0 ? .red : .green)
            Spacer()
            Button("上一处") { model.conflictIndex = max(0, index - 1) }.disabled(index == 0)
            Button("下一处") { model.conflictIndex = min(count - 1, index + 1) }.disabled(index + 1 >= count)
            Button("下一处未解决") { model.nextUnresolved() }.disabled(unresolved == 0)
            Toggle("选择后跳转", isOn: $model.conflictAutoNext).toggleStyle(.checkbox).font(.caption)
        }
    }

    private func conflictDocument(_ draft: AppModel.ConflictDraft) -> some View {
        let rebase = model.status?.conflictedOperation == "rebase"
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(displayRows(draft)) { row in
                        switch row.kind {
                        case let .line(number, text):
                            lineRow(number, text)
                        case let .block(index, start):
                            ConflictBlockView(
                                block: draft.document.blocks[index],
                                start: start,
                                choice: draft.choices[index],
                                localTitle: "本地" + (rebase ? " · 正在重放的提交" : ""),
                                incomingTitle: "传入" + (rebase ? " · 变基基线" : ""),
                                editing: draft.editing,
                                onChoose: { model.chooseConflict($0, at: index) }
                            ).id("block-\(index)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.trailing, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .onAppear { scroll(to: proxy) }
            .onChange(of: model.conflictIndex) { _ in scroll(to: proxy) }
        }
        .frame(minHeight: 220, maxHeight: .infinity)
    }

    private func scroll(to proxy: ScrollViewProxy) {
        guard let draft, draft.document.blocks.indices.contains(model.conflictIndex) else { return }
        let target = "block-\(model.conflictIndex)"
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.16)) { proxy.scrollTo(target, anchor: .top) }
        }
    }

    private func lineRow(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 0) {
            Text("\(number)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing).padding(.trailing, 8)
            Text(text.isEmpty ? " " : text).font(.system(size: 11.5, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private func footer(_ draft: AppModel.ConflictDraft) -> some View {
        let unresolved = draft.choices.filter { $0 == nil }.count
        return HStack {
            Text("已处理 \(draft.choices.count - unresolved) / \(draft.choices.count) 处").font(.caption).foregroundStyle(.secondary)
            Text("每处冲突选择一侧或保留两边；仍含冲突标记时不会写入。").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("编辑结果") { model.editConflict() }.disabled(unresolved > 0 || draft.editing)
            Button("保存并标记解决") { model.saveConflict() }.buttonStyle(.borderedProminent)
                .disabled(unresolved > 0)
                .opacity(unresolved > 0 ? 0.45 : 1)
        }
    }

    private func binaryConflict(_ draft: AppModel.ConflictDraft, path: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.document.reason).foregroundStyle(.secondary)
            HStack {
                Button("保留本地文件") { model.saveConflict(choice: .local) }
                Button("使用传入文件") { model.saveConflict(choice: .incoming) }
            }
            Button("在默认应用中打开") { model.openFile(path) }
            Spacer()
        }
    }

    private func statusText(_ path: String) -> String {
        if let draft = model.conflictDrafts[path] {
            if draft.editing { return "编辑中 · 待保存" }
            switch draft.document.kind {
            case .text: return "未解决 \(draft.choices.filter { $0 == nil }.count) 处"
            case .binary: return "二进制 · 待解决"
            case .unsupported: return "需外部工具处理"
            }
        }
        switch model.conflictKind(for: path) {
        case .text: return "未解决 \(model.unresolvedCount(for: path) ?? 0) 处"
        case .binary: return "二进制 · 待解决"
        case .unsupported: return "需外部工具处理"
        case nil: return "待解决"
        }
    }
    private func statusColor(_ path: String) -> Color {
        if model.conflictDrafts[path]?.editing == true { return .orange }
        if model.conflictKind(for: path) == .unsupported { return .secondary }
        return .red
    }

    private struct DisplayRow: Identifiable {
        enum Kind { case line(Int, String); case block(index: Int, start: Int) }
        let id: String
        let kind: Kind
    }

    private func displayRows(_ draft: AppModel.ConflictDraft) -> [DisplayRow] {
        let doc = draft.document
        var rows: [DisplayRow] = []
        var number = 0
        func appendContext(_ lines: [String], tag: String) {
            for (offset, line) in lines.enumerated() {
                number += 1
                rows.append(DisplayRow(id: "\(tag)-\(offset)", kind: .line(number, line)))
            }
        }
        if let first = doc.sections.first { appendContext(first, tag: "s0") }
        for index in doc.blocks.indices {
            rows.append(DisplayRow(id: "row-block-\(index)", kind: .block(index: index, start: number + 1)))
            let localCount = doc.blocks[index].local.components(separatedBy: "\n").count
            let incomingCount = doc.blocks[index].incoming.components(separatedBy: "\n").count
            switch draft.choices[index] {
            case .local: number += localCount
            case .incoming: number += incomingCount
            default: number += localCount + incomingCount
            }
            if index + 1 < doc.sections.count { appendContext(doc.sections[index + 1], tag: "s\(index + 1)") }
        }
        return rows
    }
}

private struct ConflictBlockView: View {
    let block: ConflictBlock
    let start: Int
    let choice: ConflictChoice?
    let localTitle: String
    let incomingTitle: String
    let editing: Bool
    let onChoose: (ConflictChoice) -> Void

    private var localLines: [String] { block.local.components(separatedBy: "\n") }
    private var incomingLines: [String] { block.incoming.components(separatedBy: "\n") }
    private var showsLocal: Bool { choice == nil || choice == .local || choice == .both }
    private var showsIncoming: Bool { choice == nil || choice == .incoming || choice == .both }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsLocal {
                band(title: localTitle, lines: localLines, start: start, tone: .local, active: choice == .local, showActions: true)
            }
            if showsIncoming {
                band(title: incomingTitle, lines: incomingLines, start: start + (showsLocal ? localLines.count : 0), tone: .incoming, active: choice == .incoming, showActions: !showsLocal)
            }
        }
        .padding(.vertical, 4)
    }

    private func band(title: String, lines: [String], start: Int, tone: BandTone, active: Bool, showActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(tone.color)
                if active {
                    Label("已采用", systemImage: "checkmark").labelStyle(.titleAndIcon)
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(tone.color)
                }
                Spacer()
                if showActions {
                    chooseButton("采用本地", chosen: choice == .local) { onChoose(.local) }
                    chooseButton("采用传入", chosen: choice == .incoming) { onChoose(.incoming) }
                    chooseButton("保留两边", chosen: choice == .both) { onChoose(.both) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                HStack(spacing: 0) {
                    Text("\(start + offset)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing).padding(.trailing, 8)
                    Text(line.isEmpty ? " " : line).font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
        }
        .background(tone.tint.opacity(0.08))
        .overlay(alignment: .leading) { Rectangle().fill(tone.color).frame(width: 3).frame(maxHeight: .infinity) }
    }

    private func chooseButton(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if chosen { Image(systemName: "checkmark") }
                Text(title)
            }
            .font(.system(size: 10, weight: chosen ? .bold : .regular))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(chosen ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(editing)
        .fixedSize()
    }

    private enum BandTone {
        case local, incoming
        var color: Color {
            switch self {
            case .local: return Color(red: 0.05, green: 0.55, blue: 0.34)
            case .incoming: return Color(red: 0.75, green: 0.26, blue: 0.22)
            }
        }
        var tint: Color {
            switch self {
            case .local: return .green
            case .incoming: return .red
            }
        }
    }
}
