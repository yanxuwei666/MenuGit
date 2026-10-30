import AppKit
import MenuGitCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            titlebar
            hairline
            HStack(spacing: 0) {
                sidebar.frame(width: 190)
                Rectangle().fill(Theme.border).frame(width: 1)
                VStack(spacing: 0) {
                    feedback
                    if model.busy { ProgressView().controlSize(.small).padding(6) }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity).disabled(model.busy)
                }
            }
        }
        .background(Theme.panel)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
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

    private var hairline: some View { Rectangle().fill(Theme.border).frame(height: 1) }

    private var titlebar: some View {
        HStack(spacing: 8) {
            Text("MenuGit").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            if let repository = model.repository {
                Text("— \(repository.root.lastPathComponent)")
                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.muted)
                if let branch = model.status?.branch, !branch.isEmpty {
                    Text("· \(branch)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if model.status?.conflictedOperation != nil, model.screen != .conflicts {
                Button(model.status?.files.contains(where: \.hasConflict) == true ? "解决冲突" : "完成\(model.status?.conflictedOperation == "rebase" ? "变基" : "合并")") {
                    model.go(.conflicts)
                }.buttonStyle(QuietButtonStyle()).disabled(model.busy)
            }
            Button("打开仓库…") { model.chooseFolder() }
                .buttonStyle(QuietButtonStyle()).disabled(model.busy)
            Button {
                model.refreshExtensionStatus()
                model.screen = .settings
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(QuietButtonStyle()).help("设置")
        }
        .padding(.horizontal, 14)
        .frame(height: 45)
        .background(Theme.titlebar)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            repoCard
            navLabel("仓库")
            navItem("更改", icon: "pencil", screen: .commit, count: model.status?.files.count ?? 0)
            navItem("分支", icon: "arrow.triangle.branch", screen: .branches)
            navItem("历史", icon: "clock", screen: .history)
            navLabel("同步")
            navItem("推送", icon: "arrow.up", screen: .push, count: model.outgoingCommits.count)
            navItem("拉取", icon: "arrow.down", screen: .pull)
            Spacer(minLength: 10)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Button { model.screen = .create } label: { navContent("新建仓库", icon: "plus") }
                .buttonStyle(SidebarButtonStyle())
            Button { model.screen = .clone } label: { navContent("克隆仓库", icon: "square.on.square") }
                .buttonStyle(SidebarButtonStyle())
            Button {
                model.refreshExtensionStatus()
                model.screen = .settings
            } label: { navContent("设置", icon: "gearshape") }
            .buttonStyle(SidebarButtonStyle(active: model.screen == .settings))
        }
        .padding(.horizontal, 9)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Theme.sidebar)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var repoCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").font(.system(size: 10))
                Text(model.repository?.root.lastPathComponent ?? "未打开仓库")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.text)
            Text(repoPathHint)
                .font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                .lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, 2)
        .padding(.bottom, 15)
    }

    private var repoPathHint: String {
        guard let root = model.repository?.root else { return "从 Finder 右键或下方打开" }
        let parent = root.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
    }

    private func navLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .tracking(0.5)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
    }

    private func navItem(_ label: String, icon: String, screen: AppModel.Screen, count: Int = 0) -> some View {
        let active = model.screen == screen
        return Button { model.go(screen) } label: { navContent(label, icon: icon, count: count, active: active) }
            .buttonStyle(SidebarButtonStyle(active: active))
            .disabled(model.repository == nil)
    }

    private func navContent(_ label: String, icon: String, count: Int = 0, active: Bool = false) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 10.5)).frame(width: 14)
            Text(label).font(.system(size: 11, weight: active ? .semibold : .regular))
            Spacer(minLength: 0)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.navCount, in: Capsule())
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PageHeading<Trailing: View>: View {
    let title: String
    let subtitle: String
    let trailing: Trailing

    init(_ title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 11)
    }
}

extension PageHeading where Trailing == EmptyView {
    init(_ title: String, subtitle: String) {
        self.init(title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.rowHover : Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .background(Theme.accent.opacity(configuration.isPressed ? 0.85 : 1), in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct SidebarButtonStyle: ButtonStyle {
    var active = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(active ? Theme.navActive : Theme.sidebarText)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(active ? Theme.navActiveBackground : (configuration.isPressed ? Theme.rowHover : .clear), in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct MenuGitField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(width: width)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
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
        VStack(spacing: 0) {
            PageHeading("开始使用", subtitle: "打开本地仓库，或从 Finder 右键使用 MenuGit")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.gearshape")
                            .font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
                        Text("从 Finder 右键使用 MenuGit").font(.system(size: 14, weight: .semibold))
                        Text("也可以在下方打开本地仓库，或创建、克隆一个仓库。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                        HStack(spacing: 8) {
                            Button("打开仓库…") { model.chooseFolder() }.buttonStyle(PrimaryButtonStyle())
                            Button("新建仓库") { model.screen = .create }.buttonStyle(OutlineButtonStyle())
                            Button("克隆仓库") { model.screen = .clone }.buttonStyle(OutlineButtonStyle())
                        }.padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

                    if !model.recentRepositories.isEmpty {
                        SectionCard(title: "最近仓库") {
                            VStack(spacing: 0) {
                                ForEach(Array(model.recentRepositories.enumerated()), id: \.element) { index, url in
                                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 34) }
                                    Button { model.open(url) } label: {
                                        HStack(spacing: 9) {
                                            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.muted)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(url.lastPathComponent).font(.system(size: 11, weight: .medium))
                                                Text(displayPath(url)).font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                                                    .lineLimit(1).truncationMode(.middle)
                                            }
                                            Spacer()
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 34)
                                HStack {
                                    Text("\(model.recentRepositories.count) 个仓库").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                                    Spacer()
                                    Button("清除") { model.clearRecent() }.buttonStyle(QuietButtonStyle())
                                }.padding(.horizontal, 12).padding(.vertical, 4)
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        Circle().fill(model.extensionEnabled ? Color.green : Color.orange).frame(width: 6, height: 6)
                        Text("Finder 扩展\(model.extensionEnabled ? "已启用" : "尚未启用")")
                        if !model.extensionEnabled {
                            Button("去启用") { model.refreshExtensionStatus(); model.screen = .settings }
                                .buttonStyle(QuietButtonStyle())
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
        }
    }

    private func displayPath(_ url: URL) -> String {
        let path = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

enum Theme {
    static let accent = dynamic(0x1677E8, 0x4A9BFF)
    static let text = dynamic(0x303540, 0xE4E7EC)
    static let muted = dynamic(0x8B929E, 0x8E959F)
    static let border = dynamic(0xE1E4E9, 0x3C424B)
    static let hairline = dynamic(0xECEEF1, 0x333840)
    static let chrome = dynamic(0xF3F5F8, 0x2C3138)
    static let panel = dynamic(0xFCFCFD, 0x262A31)
    static let titlebar = dynamic(0xF7F7F8, 0x2A2E35)
    static let sidebar = dynamic(0xF8F9FB, 0x24282E)
    static let sidebarText = dynamic(0x5D6572, 0xC3C9D2)
    static let navActive = dynamic(0x176BC4, 0x8CC2FF)
    static let navActiveBackground = dynamic(0xE8F2FF, 0x1F3A5C)
    static let navCount = dynamic(0xE4E7EC, 0x3A3F47)
    static let rowHover = dynamic(0xF6F8FB, 0x30353D)
    static let rowSelected = dynamic(0xEAF3FF, 0x1F3A5C)
    static let diff = dynamic(0xFAFBFD, 0x21252B)
    static let addedText = dynamic(0x23643D, 0x7FD1A0)
    static let addedBackground = dynamic(0xEAF6EE, 0x1B3324)
    static let removedText = dynamic(0xA53C35, 0xF09A93)
    static let removedBackground = dynamic(0xFFF0EF, 0x3A2421)
    static let hunkText = dynamic(0x5375A2, 0x8DB4E2)
    static let hunkBackground = dynamic(0xEEF4FC, 0x243040)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }
    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

struct FileStatusTag: View {
    let file: ChangedFile
    var body: some View {
        Text(symbol)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(tone)
            .frame(width: 17, height: 16)
            .background(tone.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
    }
    private var symbol: String {
        if file.hasConflict { return "!" }
        if file.isRename { return "R" }
        if file.isUntracked { return "?" }
        if file.isNew { return "A" }
        if file.indexStatus == "D" || file.worktreeStatus == "D" { return "D" }
        return "M"
    }
    private var tone: Color {
        switch symbol {
        case "?": return Theme.muted
        case "A": return .green
        case "D", "!": return .red
        case "R": return .purple
        default: return Theme.accent
        }
    }
}

struct CommitView: View {
    @ObservedObject var model: AppModel
    @State private var hovered: String?

    private var files: [ChangedFile] { model.status?.files ?? [] }
    private var selectable: [ChangedFile] { files.filter { !$0.hasConflict } }
    private var allSelected: Bool { !selectable.isEmpty && selectable.allSatisfy { model.selected.contains($0.path) } }
    private var partialSelected: Bool { files.contains { model.selected.contains($0.path) && $0.isPartiallyStaged } }
    private var firstLineTooLong: Bool { (model.message.split(separator: "\n", omittingEmptySubsequences: false).first?.count ?? 0) > 50 }
    private var canCommit: Bool { !model.selected.isEmpty && !model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.identityMissing }
    private var branch: String { model.status?.branch ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            heading
            hairline
            if model.identityMissing {
                Banner(text: "尚未配置 Git 提交身份。请先在终端配置 user.name 和 user.email。", color: .orange, actionTitle: "重新检查", action: model.checkIdentity)
            }
            if partialSelected {
                Banner(text: "所选文件同时包含已暂存和未暂存修改，将提交工作区当前完整内容。", color: .orange)
            }
            if files.isEmpty { emptyState } else { changes }
            hairline
            commitBar
        }
        .task { await model.loadOutgoing() }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private var heading: some View {
        PageHeading("更改", subtitle: "\(branch) · \(files.count) 个文件变更 · \(model.commitScope)") {
            HStack(spacing: 4) {
                Text(syncLabel).font(.system(size: 10)).foregroundStyle(syncTone)
                Button("↓ 拉取") { model.go(.pull) }.buttonStyle(QuietButtonStyle())
                Button("↑ 推送") { model.go(.push) }.buttonStyle(QuietButtonStyle())
            }
        }
    }

    private var syncLabel: String {
        guard let upstream = model.status?.upstream else { return "尚未设置上游" }
        let ahead = model.outgoingCommits.count
        return ahead > 0 ? "领先 \(upstream) \(ahead) 个提交" : "没有待推送的提交"
    }
    private var syncTone: Color { model.outgoingCommits.isEmpty ? Theme.muted : .green }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "checkmark.circle").font(.system(size: 28, weight: .light)).foregroundStyle(.green)
            Text("工作区干净").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.text)
            Text(emptyHint).font(.system(size: 11)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: String {
        guard let upstream = model.status?.upstream else { return "尚未设置上游，等待下一次修改" }
        if model.outgoingCommits.count > 0 {
            return "领先 \(upstream) \(model.outgoingCommits.count) 个提交，切换到「推送」即可发布"
        }
        return "与 \(upstream) 同步，等待下一次修改"
    }

    private var changes: some View {
        HSplitView {
            changeList.frame(minWidth: 260, idealWidth: 330)
            diffPane.frame(minWidth: 320)
        }
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { allSelected }, set: { model.selectAll($0) })) {
                    Text("选择要提交的文件").font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.checkbox).disabled(selectable.isEmpty)
                Spacer()
                Text("已选 \(model.selected.count) / \(files.count)").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            hairline
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(files) { file in
                        fileRow(file)
                    }
                }.padding(6)
            }
        }
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.selected.contains(file.path) }, set: { _ in model.toggle(file.path) }))
                .labelsHidden().toggleStyle(.checkbox).disabled(file.hasConflict)
            FileStatusTag(file: file)
            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(file.hasConflict ? Color.red : Theme.text)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if file.isPartiallyStaged {
                Text("部分暂存").font(.system(size: 9.5)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(rowBackground(for: file.path), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { model.selectFile(file.path) }
        .onHover { inside in
            if inside { hovered = file.path } else if hovered == file.path { hovered = nil }
        }
    }

    private func rowBackground(for path: String) -> Color {
        if model.selectedFile == path { return Theme.rowSelected }
        return hovered == path ? Theme.rowHover : .clear
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.selectedFile ?? "差异预览")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let file = files.first(where: { $0.path == model.selectedFile }) {
                    Text(file.label).font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                }
                Button { model.openSelectedFile() } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 10.5))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .help("用默认应用打开").disabled(model.selectedFile == nil)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.chrome)
            Rectangle().fill(Theme.border).frame(height: 1)
            diffBody
        }
        .background(Theme.diff)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .padding(10)
    }

    @ViewBuilder private var diffBody: some View {
        switch model.preview {
        case .text(let sections):
            GeometryReader { geo in
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            if sections.count > 1 {
                                Text(section.title)
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 9).padding(.vertical, 3)
                                    .frame(minWidth: geo.size.width, alignment: .leading)
                                    .background(Theme.chrome.opacity(0.7))
                            }
                            ForEach(Array(visibleLines(section.lines).enumerated()), id: \.offset) { _, line in
                                diffRow(line, minWidth: geo.size.width)
                            }
                        }
                    }
                    .textSelection(.enabled)
                }
            }
        case .binary:
            unavailable("二进制文件，不在应用内渲染差异。", showOpen: true)
        case .tooLarge:
            unavailable("差异过大，未在应用内完整渲染。", showOpen: true)
        case .unavailable(let message):
            unavailable(message, showOpen: false)
        }
    }

    private func diffRow(_ line: DiffLine, minWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tone(for: line.kind).text)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(minWidth: minWidth, alignment: .leading)
        .background(tone(for: line.kind).background)
    }

    private func visibleLines(_ lines: [DiffLine]) -> [DiffLine] {
        lines.filter { line in
            guard line.kind == .header else { return true }
            return line.text.hasPrefix("@@") || line.text.hasPrefix("Binary files")
        }
    }

    private func tone(for kind: DiffLine.Kind) -> (text: Color, background: Color) {
        switch kind {
        case .added: return (Theme.addedText, Theme.addedBackground)
        case .removed: return (Theme.removedText, Theme.removedBackground)
        case .header: return (Theme.hunkText, Theme.hunkBackground)
        case .context: return (Theme.text, Theme.diff)
        }
    }

    private func unavailable(_ message: String, showOpen: Bool) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(message).font(.system(size: 11)).foregroundStyle(Theme.muted)
            if showOpen { Button("在默认应用中打开") { model.openSelectedFile() } }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(3)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                if model.message.isEmpty {
                    Text("提交信息（必填）")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                        .padding(.top, 7).padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 62)
            HStack(spacing: 8) {
                Text(authorNote).font(.system(size: 9.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                Spacer()
                if firstLineTooLong {
                    Text("首行建议不超过 50 字符（不强制）").font(.system(size: 9.5)).foregroundStyle(.orange)
                }
                Button("提交") { model.commit() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canCommit)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var authorNote: String {
        if let identity = model.identity { return "提交到 \(branch) · \(identity)" }
        return "提交到 \(branch) · 作者来自系统 Git 配置"
    }
}

struct SyncView: View {
    @ObservedObject var model: AppModel
    let push: Bool

    private var branch: String { model.status?.branch ?? "" }
    private var ahead: Int { model.outgoingCommits.count }
    private var availableBranches: [String] {
        model.remoteBranches.filter { $0.hasPrefix(model.remote + "/") }
            .map { String($0.dropFirst(model.remote.count + 1)) }
    }
    private var canRun: Bool { !model.displayTargetRemote.isEmpty && !model.displayTargetBranch.isEmpty }
    private var subtitle: String {
        guard model.hasUpstream else { return "\(branch) · 尚未设置上游" }
        let target = "\(model.displayTargetRemote)/\(model.displayTargetBranch)"
        return push ? "\(branch) → \(target)" : "\(target) → \(branch)"
    }
    private var stateText: String {
        guard let upstream = model.status?.upstream else { return "尚未设置上游" }
        if push { return ahead > 0 ? "领先 \(upstream) \(ahead) 个提交" : "与 \(upstream) 同步" }
        return "从 \(upstream) 获取并合并到当前分支"
    }
    private var stateTone: Color { push && ahead > 0 ? Theme.addedText : Theme.muted }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading(push ? "推送" : "拉取", subtitle: subtitle) {
                if push, !model.lastCommit.isEmpty {
                    Text("已创建本地提交 \(shortHash(model.lastCommit))")
                        .font(.system(size: 10)).foregroundStyle(Theme.addedText)
                }
            }
            hairline
            if model.remotes.isEmpty {
                remoteSetup
            } else {
                syncBody
                hairline
                footer
            }
        }
    }

    private var hairline: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }

    private var syncBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionCard(title: "本地") {
                    VStack(spacing: 0) {
                        row("分支") { branchPill }
                        hairline
                        row("状态") {
                            Text(stateText).font(.system(size: 10.5)).foregroundStyle(stateTone)
                        }
                    }
                    .padding(.bottom, 4)
                }

                SectionCard(title: push ? "目标" : "来源") {
                    VStack(spacing: 0) {
                        if model.hasUpstream {
                            row("远端") { remotePill(model.displayTargetRemote) }
                            hairline
                            row("分支") {
                                Text(model.displayTargetBranch)
                                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text)
                            }
                            cardHint("当前分支已配置上游，操作直接使用该上游。")
                        } else {
                            row("远端") {
                                Menu {
                                    ForEach(model.remotes, id: \.self) { name in
                                        Button(name) {
                                            model.remote = name
                                            model.syncRemoteBranchOptions()
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Text(model.remote).font(.system(size: 10.5, weight: .medium))
                                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .semibold))
                                    }
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Theme.chrome, in: Capsule())
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            }
                            hairline
                            row("分支") {
                                if push {
                                    MenuGitField(placeholder: "远端分支（不存在时创建）", text: $model.remoteBranch, width: 230)
                                } else if availableBranches.isEmpty {
                                    Text("该远端没有可用分支，请先推送或刷新。")
                                        .font(.system(size: 10.5)).foregroundStyle(.orange)
                                } else {
                                    Picker("", selection: $model.remoteBranch) {
                                        ForEach(availableBranches, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden().pickerStyle(.menu).frame(width: 190, alignment: .leading)
                                }
                            }
                            if push {
                                hairline
                                row("上游") {
                                    Toggle("记住为当前分支的上游", isOn: $model.setUpstream)
                                        .toggleStyle(.checkbox).font(.system(size: 10.5))
                                }
                            }
                            cardHint(push
                                     ? "默认推送到上游分支；目标在远端不存在时，将创建该远端分支并设为上游。"
                                     : "拉取 = 获取并合并该远端分支到当前分支；产生冲突时会暂停并进入解决冲突流程。")
                        }
                    }
                }

                if push {
                    SectionCard(title: "待推送提交（\(ahead)）") {
                        if model.outgoingCommits.isEmpty {
                            Text("没有待推送提交。")
                                .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 12).padding(.bottom, 10)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(model.outgoingCommits.prefix(30).enumerated()), id: \.element) { index, commit in
                                        if index > 0 { hairline }
                                        HStack(spacing: 8) {
                                            Text(shortHash(commit.id))
                                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                                                .frame(width: 54, alignment: .leading)
                                            Text(commit.subject).font(.system(size: 10.5)).lineLimit(1)
                                            Spacer(minLength: 6)
                                            Text(commit.author).font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                                        }
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                    }
                                }
                            }
                            .frame(maxHeight: 150)
                            .padding(.bottom, 4)
                        }
                    }
                }

                if !model.resultLog.isEmpty {
                    SectionCard(title: "Git 输出") {
                        ScrollView {
                            Text(model.resultLog)
                                .font(.system(size: 9.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.bottom, 8)
                        }
                        .frame(maxHeight: 110)
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("凭证来自系统 Git 配置").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            Spacer()
            Button(push ? "推送" : "拉取") { push ? model.push() : model.pull() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canRun || model.busy)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var remoteSetup: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "externaldrive.badge.questionmark")
                .font(.system(size: 26, weight: .light)).foregroundStyle(Theme.muted)
            Text("尚未配置远端仓库").font(.system(size: 13, weight: .semibold))
            Text(push
                 ? "添加远端只会更改当前仓库；凭证来自系统 Git 凭证助手或 SSH 配置。"
                 : "需要先推送或手动配置远端后才能拉取。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            if push {
                HStack(spacing: 8) {
                    MenuGitField(placeholder: "远端名称", text: $model.newRemoteName, width: 110)
                    MenuGitField(placeholder: "HTTPS 或 SSH 地址", text: $model.remoteAddress)
                }
                .frame(maxWidth: 420)
                Button("添加远端") { model.addRemote() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.remoteAddress.isEmpty || model.busy)
            } else {
                HStack(spacing: 8) {
                    Button("去推送") { model.go(.push) }.buttonStyle(OutlineButtonStyle())
                    Button("设置") { model.screen = .settings }.buttonStyle(OutlineButtonStyle())
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                .frame(width: 46, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func cardHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 12).padding(.top, 2).padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var branchPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
            Text(branch).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(Theme.navActive)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(Theme.navActiveBackground, in: Capsule())
    }

    private func remotePill(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(Theme.chrome, in: Capsule())
    }

    private func shortHash(_ hash: String) -> String { String(hash.prefix(7)) }
}

struct BranchesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("分支", subtitle: "切换或创建本地分支") {
                HStack(spacing: 6) {
                    MenuGitField(placeholder: "例如 feature/new-ui", text: $model.branchName, width: 170)
                    Button("＋ 新建分支") { model.createBranch() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.branchName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let status = model.status, !status.files.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10))
                    Text("工作区有 \(status.files.count) 个未提交更改。MenuGit 不会自动暂存或丢弃；Git 判断会覆盖修改时会阻止切换。")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07))
                Rectangle().fill(Theme.hairline).frame(height: 1)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionCaption("本地分支")
                    ForEach(model.localBranches, id: \.self) { branch in
                        branchRow(branch)
                        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 8)
                    }
                    if model.localBranches.isEmpty {
                        emptyRow("没有本地分支。")
                    }
                    sectionCaption("远程分支").padding(.top, 14)
                    if model.remoteBranches.isEmpty {
                        emptyRow("没有可用的远程分支；配置远端并推送后可在这里检出。")
                    } else {
                        ForEach(model.remoteBranches, id: \.self) { branch in
                            remoteRow(branch)
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 8)
                        }
                    }
                }
                .padding(.horizontal, 13).padding(.vertical, 10)
            }
        }
    }

    private func branchRow(_ branch: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            Text(branch).font(.system(size: 11, design: .monospaced))
            Spacer()
            if branch == model.status?.branch {
                Text("当前分支")
                    .font(.system(size: 9.5))
                    .foregroundStyle(Theme.addedText)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.addedBackground, in: Capsule())
            } else {
                Button("切换") { model.switchBranch(branch) }.buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
    }

    private func remoteRow(_ branch: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10.5)).foregroundStyle(.purple.opacity(0.75))
            Text(branch).font(.system(size: 11, design: .monospaced))
            Spacer()
            if let local = localName(for: branch), model.localBranches.contains(local) {
                Text("已有本地分支 \(local)").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            } else {
                Button("检出为跟踪分支") { model.switchBranch(branch, isRemote: true) }
                    .buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium)).tracking(0.5).foregroundStyle(Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 8)
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
    private var branch: String { model.status?.branch ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("历史", subtitle: "\(branch) 分支 · 最近提交") {
                MenuGitField(placeholder: "搜索提交信息或作者", text: $search, width: 210)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HSplitView {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { commit in
                                historyRow(commit)
                                Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 8)
                            }
                            if filtered.isEmpty {
                                Text(search.isEmpty ? "没有提交记录。" : "没有匹配的提交。")
                                    .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                            }
                        }
                    }
                    if model.historyHasMore, search.isEmpty {
                        Rectangle().fill(Theme.hairline).frame(height: 1)
                        Button("加载更早的提交") { model.loadMoreHistory() }
                            .buttonStyle(OutlineButtonStyle())
                            .padding(8)
                    }
                }
                .frame(minWidth: 290)

                detailPane.frame(minWidth: 300)
            }
        }
    }

    private func historyRow(_ commit: CommitRecord) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(commit.id)
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject).font(.system(size: 11, weight: .medium)).lineLimit(2)
                Text(commit.author).font(.system(size: 9.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 4)
            Text(commit.date)
                .font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(model.selectedCommit?.id == commit.id ? Theme.rowSelected : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.showCommit(commit) }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(model.selectedCommit.map { "\($0.id) · \($0.subject)" } ?? "提交详情")
                    .font(.system(size: 10.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(Theme.chrome)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                Text(detailText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Theme.diff)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
        .padding(10)
    }

    private var detailText: String {
        guard model.selectedCommit != nil else { return "选择提交查看详情。" }
        guard !model.commitDetail.isEmpty else { return "正在读取提交详情…" }
        let limit = 60_000
        guard model.commitDetail.count > limit else { return model.commitDetail }
        return String(model.commitDetail.prefix(limit)) + "\n…（内容过大，仅显示前 60,000 个字符）"
    }
}

struct CreateView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("新建仓库", subtitle: "在此目录初始化 Git 仓库")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCard(title: "位置") {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            Text(model.targetDirectory.path)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button("选择其他目录…") { model.chooseCloneDirectory() }
                                .buttonStyle(OutlineButtonStyle())
                        }
                        .padding(12)
                    }
                    Text("将初始化所选目录。若该目录已属于仓库，操作会被阻止。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    HStack {
                        Spacer()
                        Button("初始化") { model.initialize() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(model.busy)
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
        }
    }
}

struct CloneView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("克隆仓库", subtitle: "从 HTTPS 或 SSH 地址克隆到本地")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCard(title: "来源") {
                        VStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Text("地址").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                    .frame(width: 46, alignment: .leading)
                                MenuGitField(placeholder: "HTTPS 或 SSH 仓库地址", text: $model.cloneURL)
                                    .onChange(of: model.cloneURL) { _ in model.suggestedCloneName() }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            HStack(spacing: 10) {
                                Text("文件夹").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                    .frame(width: 46, alignment: .leading)
                                MenuGitField(placeholder: "新建文件夹名称", text: $model.cloneName, width: 230)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            HStack(spacing: 10) {
                                Text("目录").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                    .frame(width: 46, alignment: .leading)
                                Text(model.targetDirectory.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button("选择…") { model.chooseCloneDirectory() }
                                    .buttonStyle(OutlineButtonStyle())
                                    .disabled(model.cloning)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                    if model.cloning {
                        SectionCard(title: "进度") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let percent = model.clonePercent { ProgressView(value: percent) }
                                else { ProgressView() }
                                Text(model.cloneProgress)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .lineLimit(2).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 12).padding(.bottom, 10)
                        }
                    }
                    HStack {
                        Spacer()
                        if model.cloning {
                            Button("取消克隆") { model.cancelClone() }.buttonStyle(OutlineButtonStyle())
                        } else {
                            Button("克隆") { model.startClone() }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(model.cloneURL.trimmingCharacters(in: .whitespaces).isEmpty
                                          || model.cloneName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeading("设置", subtitle: "Finder 扩展、诊断与最近仓库")
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SectionCard(title: "Finder 扩展") {
                        VStack(spacing: 0) {
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(model.extensionEnabled ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Finder 右键菜单").font(.system(size: 11, weight: .medium))
                                    Text(model.extensionEnabled ? "已启用，可在 Finder 中右键使用 MenuGit。" : "尚未启用。")
                                        .font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 8)
                                Button("打开系统设置") { model.openExtensionSettings() }.buttonStyle(OutlineButtonStyle())
                                Button("刷新状态") { model.refreshExtensionStatus() }.buttonStyle(OutlineButtonStyle())
                            }
                            .padding(12)
                            if !model.extensionEnabled {
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                                Text("在“系统设置 → 通用 → 登录项与扩展 → Finder 扩展”中启用 MenuGit。")
                                    .font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    SectionCard(title: "仓库与凭证") {
                        Text("MenuGit 使用系统 Git、凭证助手、SSH agent 和 Git hooks，不保存账号凭证，不修改全局 Git 配置。")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 12).padding(.bottom, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    SectionCard(title: "本机诊断信息") {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text(model.gitVersion.isEmpty ? "Git 版本未知" : model.gitVersion)
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button("复制") { model.copyDiagnostics() }.buttonStyle(OutlineButtonStyle())
                            }
                            .padding(.horizontal, 12).padding(.bottom, 8)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            ScrollView {
                                Text(model.diagnostics())
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12)
                            }
                            .frame(maxHeight: 140)
                        }
                    }

                    SectionCard(title: "最近仓库") {
                        HStack(spacing: 8) {
                            Text("\(model.recentRepositories.count) 个").font(.system(size: 10.5))
                            Spacer(minLength: 8)
                            Button("清除") { model.clearRecent() }.buttonStyle(OutlineButtonStyle())
                        }
                        .padding(.horizontal, 12).padding(.bottom, 10)
                    }

                    SectionCard(title: "关于 MenuGit") {
                        VStack(spacing: 0) {
                            HStack {
                                Text("版本").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                Spacer()
                                Text(version).font(.system(size: 10.5, design: .monospaced))
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                            HStack {
                                Text("检查更新").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                                Spacer()
                                Text("更新地址待设置").font(.system(size: 9.5)).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                }
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
                .padding(18)
            }
        }
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
                HStack(spacing: 12) {
                    sidebar.frame(width: 250)
                    detail.frame(maxWidth: .infinity, alignment: .topLeading)
                }
                HStack(spacing: 10) {
                    Button("中止\(operationName)") { model.abortConflict() }
                    Text("编辑中的文件需先保存或取消；二进制文件只能选择整份版本。")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 6)
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
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
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
