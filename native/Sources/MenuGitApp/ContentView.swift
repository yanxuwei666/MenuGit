import AppKit
import MenuGitCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.screen {
            case .welcome: LauncherDialog(model: model)
            case .commit: CommitDialog(model: model)
            case .push: SyncDialog(model: model, push: true)
            case .pull: SyncDialog(model: model, push: false)
            case .branches: BranchesDialog(model: model)
            case .history: HistoryDialog(model: model)
            case .create: InitDialog(model: model)
            case .clone: CloneDialog(model: model)
            case .settings: SettingsDialog(model: model)
            case .conflicts: ConflictDialog(model: model)
            }
        }
        .ignoresSafeArea()
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
    }
}

func closeDialogWindow() {
    NSApp.keyWindow?.orderOut(nil)
}

// MARK: - Theme

enum Theme {
    static let header = Color(rgb: 0x173966)
    static let ink = Color(rgb: 0x1F2939)
    static let ink2 = Color(rgb: 0x435269)
    static let secondary = Color(rgb: 0x53647A)
    static let muted = Color(rgb: 0x86909D)
    static let faint = Color(rgb: 0x9AA6B6)
    static let hairline = Color(rgb: 0xE7EDF4)
    static let border = Color(rgb: 0xD9E1EB)
    static let dialogBorder = Color(rgb: 0xAEbCCC)
    static let buttonBorder = Color(rgb: 0xB5C2D1)
    static let fieldBorder = Color(rgb: 0xAEBDCE)
    static let footer = Color(rgb: 0xF2F5F9)
    static let listHeader = Color(rgb: 0xF1F5FA)
    static let rowActive = Color(rgb: 0xEAF3FF)
    static let rowHover = Color(rgb: 0xF6F8FB)
    static let primary = Color(rgb: 0x0865E7)
    static let primaryPressed = Color(rgb: 0x0B57C7)
    static let addedText = Color(rgb: 0x23643D)
    static let addedBg = Color(rgb: 0xEAF6EE)
    static let removedText = Color(rgb: 0xA53C35)
    static let removedBg = Color(rgb: 0xFFF0EF)
    static let hunkText = Color(rgb: 0x5375A2)
    static let hunkBg = Color(rgb: 0xEEF4FC)
    static let diffBg = Color(rgb: 0xFAFBFD)
    static let local = Color(rgb: 0x1855AC)
    static let localBg = Color(rgb: 0xEAF2FF)
    static let incoming = Color(rgb: 0x7139B4)
    static let incomingBg = Color(rgb: 0xF2E9FF)
    static let warningBg = Color(rgb: 0xFFF4DF)
    static let warningText = Color(rgb: 0x78510E)
    static let dangerBg = Color(rgb: 0xFFF0EF)
    static let dangerText = Color(rgb: 0xA84337)
    static let infoBg = Color(rgb: 0xE8F0FF)
    static let infoText = Color(rgb: 0x1559B8)
    static let successBg = Color(rgb: 0xEAF8EF)
    static let successText = Color(rgb: 0x126438)
    static let successBorder = Color(rgb: 0xA8DDBC)
}

extension Color {
    init(rgb: UInt32) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Window + dialog frame

private struct WindowConfigurator: NSViewRepresentable {
    let width: CGFloat
    let height: CGFloat

    final class SizingView: NSView {
        var desiredSize: NSSize = .zero {
            didSet {
                guard desiredSize != oldValue else { return }
                lastSizeChange = Date()
                enforceFrame()
                let size = desiredSize
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.desiredSize == size else { return }
                    self.enforceFrame()
                }
            }
        }
        private var applying = false
        private var lastSizeChange = Date.distantPast

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResizeNotification, object: nil)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResize), name: NSWindow.didResizeNotification, object: window)
            configure(window)
            lastSizeChange = Date()
            enforceFrame()
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func windowDidResize() { enforceFrame() }

        private func configure(_ window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.styleMask.remove(.resizable)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = true
            window.appearance = NSAppearance(named: .aqua)
            window.isRestorable = false
        }

        private func enforceFrame() {
            guard let window, desiredSize.width > 0, !applying else { return }
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
            let target = NSRect(x: visible.midX - desiredSize.width / 2,
                                y: visible.midY - desiredSize.height / 2,
                                width: desiredSize.width,
                                height: desiredSize.height)
            let current = window.frame
            let sizeMismatch = abs(current.width - target.width) > 0.5 || abs(current.height - target.height) > 0.5
            let settling = Date().timeIntervalSince(lastSizeChange) < 1
            let originMismatch = settling && (abs(current.origin.x - target.origin.x) > 0.5 || abs(current.origin.y - target.origin.y) > 0.5)
            guard sizeMismatch || originMismatch else { return }
            applying = true
            defer { applying = false }
            window.setFrame(target, display: true)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = SizingView()
        view.desiredSize = NSSize(width: width, height: height)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SizingView)?.desiredSize = NSSize(width: width, height: height)
    }
}

struct DialogFrame<Content: View, Footer: View>: View {
    let title: String
    let width: CGFloat
    let height: CGFloat
    let content: Content
    let footer: Footer

    init(title: String, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.title = title
        self.width = width
        self.height = height
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(title: title)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if Footer.self != EmptyView.self {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack(spacing: 8) { footer }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.footer)
            }
        }
        .frame(width: width)
        .frame(minHeight: max(0, height - 32), maxHeight: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.dialogBorder, lineWidth: 1))
        .background(WindowConfigurator(width: width, height: height))
        .environment(\.colorScheme, .light)
    }
}

extension DialogFrame where Footer == EmptyView {
    init(title: String, width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
        self.init(title: title, width: width, height: height, content: content, footer: { EmptyView() })
    }
}

struct DialogHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                closeDialogWindow()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(.leading, 88)
        .padding(.trailing, 12)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background(Theme.header)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? Theme.primaryPressed : Theme.primary,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(configuration.isPressed ? Theme.listHeader : Color.white,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.buttonBorder, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct CompactButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Theme.listHeader : Color.white,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.buttonBorder, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? Theme.listHeader : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

// MARK: - Shared controls

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Theme.ink2)
    }
}

struct DialogTextField: View {
    let placeholder: String
    @Binding var text: String
    var mono = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.fieldBorder, lineWidth: 1))
    }
}

struct ReadOnlyField: View {
    let text: String
    var mono = false

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(rgb: 0xF7F9FC))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.fieldBorder, lineWidth: 1))
    }
}

struct PlainCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

struct BranchPill: View {
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
            Text(name.isEmpty ? "未知分支" : name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(Color(rgb: 0x0956BB))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Color(rgb: 0xDCEAFF), in: Capsule())
    }
}

struct FileStatusTag: View {
    let file: ChangedFile

    var body: some View {
        Text(symbol)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(tone.text)
            .frame(minWidth: 20)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tone.background, in: Capsule())
    }

    private var symbol: String {
        if file.hasConflict { return "!" }
        if file.isRename { return "R" }
        if file.isUntracked { return "U" }
        if file.isNew { return "A" }
        if file.indexStatus == "D" || file.worktreeStatus == "D" { return "D" }
        return "M"
    }

    private var tone: (text: Color, background: Color) {
        switch symbol {
        case "A": return (Color(rgb: 0x087044), Color(rgb: 0xD3F4E5))
        case "D", "!": return (Color(rgb: 0xAA271E), Color(rgb: 0xFFE1DD))
        case "U", "R": return (Color(rgb: 0x6230AD), Color(rgb: 0xEADFFF))
        default: return (Color(rgb: 0x0956BB), Color(rgb: 0xDCEAFF))
        }
    }
}

struct InlineNotice<Accessory: View>: View {
    enum Tone {
        case warning, danger, info

        var text: Color {
            switch self {
            case .warning: return Theme.warningText
            case .danger: return Theme.dangerText
            case .info: return Theme.infoText
            }
        }
        var background: Color {
            switch self {
            case .warning: return Theme.warningBg
            case .danger: return Theme.dangerBg
            case .info: return Theme.infoBg
            }
        }
        var icon: String {
            switch self {
            case .warning: return "exclamationmark.triangle.fill"
            case .danger: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }
    }

    let text: String
    let tone: Tone
    let accessory: Accessory

    init(_ text: String, tone: Tone = .warning, @ViewBuilder accessory: () -> Accessory) {
        self.text = text
        self.tone = tone
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: tone.icon)
                .font(.system(size: 11))
                .foregroundStyle(tone.text)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(tone.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            accessory
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tone.background)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

extension InlineNotice where Accessory == EmptyView {
    init(_ text: String, tone: Tone = .warning) {
        self.init(text, tone: tone, accessory: { EmptyView() })
    }
}

struct FeedbackStrip: View {
    @ObservedObject var model: AppModel
    var showsNotice = true
    @State private var showDetail = false

    var body: some View {
        if !model.error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dangerText)
                    Text(model.error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.dangerText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    if !model.detail.isEmpty {
                        Button(showDetail ? "收起输出" : "Git 输出") {
                            withAnimation(.easeInOut(duration: 0.15)) { showDetail.toggle() }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }
                if showDetail, !model.detail.isEmpty {
                    ScrollView {
                        Text(model.detail)
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 90)
                }
            }
            .padding(10)
            .background(Theme.dangerBg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else if showsNotice, !model.notice.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.successText)
                Text(model.notice)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.successText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(Theme.successBg)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

private func successBlock(title: String, detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
        ZStack {
            Circle().fill(Color(rgb: 0x159553)).frame(width: 32, height: 32)
            Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.successText)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color(rgb: 0x315D45))
                .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
    }
    .padding(14)
    .background(Theme.successBg)
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.successBorder, lineWidth: 1))
}

private func shortHash(_ hash: String) -> String { String(hash.prefix(7)) }

@MainActor private func repositoryName(_ model: AppModel) -> String {
    model.repository?.root.lastPathComponent ?? "MenuGit"
}

private func parentPath(_ url: URL) -> String {
    let path = url.deletingLastPathComponent().path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Dock launcher

struct LauncherDialog: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DialogFrame(title: "MenuGit", width: 490, height: 620) {
            ScrollView {
                VStack(spacing: 18) {
                    hero
                    actionButtons
                    recentCard
                    extensionRow
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        } footer: {
            Text("从 Finder 右键即可使用 MenuGit")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Button("设置") {
                model.refreshExtensionStatus()
                model.screen = .settings
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var hero: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [Color(rgb: 0x3188FF), Color(rgb: 0x0757CF)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 52, height: 52)
                    .shadow(color: Color(rgb: 0x174FA6).opacity(0.28), radius: 6, y: 2)
                Text("M").font(.system(size: 26, weight: .heavy)).foregroundStyle(.white)
            }
            Text("MenuGit").font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.ink)
            Text("从 Finder 右键完成日常 Git 操作")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var actionButtons: some View {
        VStack(spacing: 8) {
            Button {
                model.chooseFolder()
            } label: {
                Text("打开仓库…").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            HStack(spacing: 8) {
                Button {
                    model.screen = .create
                } label: {
                    Text("新建仓库").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
                Button {
                    model.screen = .clone
                } label: {
                    Text("克隆仓库").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var recentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("最近仓库")
                Spacer()
                if !model.recentRepositories.isEmpty {
                    Button("清除") { model.clearRecent() }.buttonStyle(QuietButtonStyle())
                }
            }
            PlainCard {
                if model.recentRepositories.isEmpty {
                    Text("还没有最近仓库。打开或克隆一个仓库后会显示在这里。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(Array(model.recentRepositories.enumerated()), id: \.element) { index, url in
                        if index > 0 {
                            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 46)
                        }
                        Button {
                            model.open(url)
                        } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Theme.localBg)
                                        .frame(width: 26, height: 26)
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.local)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Text(parentPath(url))
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.muted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.faint)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var extensionRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.extensionEnabled ? Color(rgb: 0x2FA36B) : Color(rgb: 0xE0A02C))
                .frame(width: 6, height: 6)
            Text(model.extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展尚未启用")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            if !model.extensionEnabled {
                Button("去启用") {
                    model.refreshExtensionStatus()
                    model.screen = .settings
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Commit

struct CommitDialog: View {
    @ObservedObject var model: AppModel
    @State private var hovered: String?

    private var files: [ChangedFile] { model.status?.files ?? [] }
    private var selectable: [ChangedFile] { files.filter { !$0.hasConflict } }
    private var allSelected: Bool { !selectable.isEmpty && selectable.allSatisfy { model.selected.contains($0.path) } }
    private var partiallySelected: Bool { files.contains { model.selected.contains($0.path) && $0.isPartiallyStaged } }
    private var hasConflict: Bool { files.contains(where: \.hasConflict) }
    private var firstLineTooLong: Bool {
        (model.message.split(separator: "\n", omittingEmptySubsequences: false).first?.count ?? 0) > 50
    }
    private var canCommit: Bool {
        !model.selected.isEmpty
            && !model.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.identityMissing
            && !hasConflict
    }
    private var branch: String { model.status?.branch ?? "" }
    private var syncText: String {
        guard let upstream = model.status?.upstream else { return "尚未设置上游" }
        let ahead = model.outgoingCommits.count
        return ahead > 0 ? "领先 \(upstream) \(ahead) 个提交" : "与 \(upstream) 同步"
    }
    private var syncTone: Color { model.outgoingCommits.isEmpty ? Theme.secondary : Theme.successText }
    private var scopeText: String {
        let scope = model.commitScope.trimmingCharacters(in: .whitespaces)
        if scope.isEmpty { return "仓库全部变更；默认勾选已跟踪文件，新增文件请手动勾选。" }
        return scope + "；可调整勾选。"
    }

    var body: some View {
        DialogFrame(title: "提交更改 — \(repositoryName(model))", width: 820, height: 640) {
            VStack(alignment: .leading, spacing: 12) {
                if !model.error.isEmpty || !model.notice.isEmpty {
                    FeedbackStrip(model: model, showsNotice: false)
                }
                metaRow
                Text(scopeText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                if model.identityMissing {
                    InlineNotice("尚未配置 Git 提交身份。请先在终端配置 user.name 和 user.email。") {
                        Button("重新检查") { model.checkIdentity() }.buttonStyle(CompactButtonStyle())
                    }
                }
                if partiallySelected {
                    InlineNotice("所选文件同时包含已暂存和未暂存修改，将提交工作区当前完整内容。")
                }
                if hasConflict {
                    InlineNotice("存在未解决冲突，当前不能提交。", tone: .danger) {
                        Button("解决冲突") { model.go(.conflicts) }.buttonStyle(CompactButtonStyle())
                    }
                }
                if files.isEmpty {
                    emptyState
                } else {
                    changes
                }
                messageArea
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } footer: {
            Text("作者：\(model.identity ?? "来自系统 Git 配置") · 来自系统 Git 配置")
                .font(.system(size: 11))
                .foregroundStyle(Color(rgb: 0x5D6B7E))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("取消") { closeDialogWindow() }.buttonStyle(SecondaryButtonStyle())
            Button("提交") { model.commit() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canCommit)
        }
        .task { await model.loadOutgoing() }
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            BranchPill(name: branch)
            Text(syncText)
                .font(.system(size: 11.5))
                .foregroundStyle(syncTone)
            Spacer(minLength: 6)
            Text("提交后确认是否推送")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(rgb: 0x2FA36B))
            Text("工作区干净").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(emptyHint)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyHint: String {
        guard let upstream = model.status?.upstream else { return "尚未设置上游，等待下一次修改。" }
        if model.outgoingCommits.count > 0 {
            return "领先 \(upstream) \(model.outgoingCommits.count) 个提交，可从 Finder 右键菜单推送。"
        }
        return "与 \(upstream) 同步，等待下一次修改。"
    }

    private var changes: some View {
        HStack(alignment: .top, spacing: 14) {
            fileList
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            diffPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Toggle("", isOn: Binding(get: { allSelected }, set: { model.selectAll($0) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(selectable.isEmpty)
                Text("全选")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Text("已选 \(model.selected.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.listHeader)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(files) { file in
                        fileRow(file)
                    }
                }
                .padding(5)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private func fileRow(_ file: ChangedFile) -> some View {
        HStack(spacing: 7) {
            Toggle("", isOn: checkbox(file.path))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(file.hasConflict)
            FileStatusTag(file: file)
            Text(file.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(file.hasConflict ? Theme.dangerText : Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(file.label)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(rowBackground(file.path), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.selectFile(file.path) }
        .onHover { inside in
            if inside { hovered = file.path } else if hovered == file.path { hovered = nil }
        }
    }

    private func checkbox(_ path: String) -> Binding<Bool> {
        Binding(get: { model.selected.contains(path) }, set: { on in
            if on != model.selected.contains(path) { model.toggle(path) }
        })
    }

    private func rowBackground(_ path: String) -> Color {
        if model.selectedFile == path { return Theme.rowActive }
        return hovered == path ? Theme.rowHover : Color.clear
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(model.selectedFile ?? "差异预览")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(model.selectedFile == nil ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let file = files.first(where: { $0.path == model.selectedFile }) {
                    Text(file.label).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
                Button {
                    model.openSelectedFile()
                } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.secondary)
                .help("用默认应用打开")
                .disabled(model.selectedFile == nil)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Theme.listHeader)
            Rectangle().fill(Theme.border).frame(height: 1)
            diffBody
        }
        .background(Theme.diffBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundStyle(Theme.hunkText)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .frame(minWidth: geo.size.width, alignment: .leading)
                                    .background(Theme.listHeader)
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
            diffPlaceholder("二进制文件，不在应用内渲染差异。", showOpen: true)
        case .tooLarge:
            diffPlaceholder("差异过大，未在应用内完整渲染。", showOpen: true)
        case .unavailable(let message):
            diffPlaceholder(message, showOpen: false)
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
        .padding(.horizontal, 10)
        .frame(minWidth: minWidth, minHeight: 18, alignment: .leading)
        .background(tone(for: line.kind).background)
    }

    private func visibleLines(_ lines: [DiffLine]) -> [DiffLine] {
        let metadata = ["diff ", "index ", "--- ", "+++ ", "new file mode", "deleted file mode",
                        "old mode", "new mode", "similarity index", "rename from", "rename to"]
        return lines.filter { line in
            guard line.kind == .header else { return true }
            return !metadata.contains(where: { line.text.hasPrefix($0) })
        }
    }

    private func tone(for kind: DiffLine.Kind) -> (text: Color, background: Color) {
        switch kind {
        case .added: return (Theme.addedText, Theme.addedBg)
        case .removed: return (Theme.removedText, Theme.removedBg)
        case .header: return (Theme.hunkText, Theme.hunkBg)
        case .context: return (Theme.ink, Theme.diffBg)
        }
    }

    private func diffPlaceholder(_ message: String, showOpen: Bool) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Text(message).font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            if showOpen {
                Button("在默认应用中打开") { model.openSelectedFile() }.buttonStyle(CompactButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messageArea: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionLabel("提交说明")
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.message)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.fieldBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                if model.message.isEmpty {
                    Text("提交信息（必填）")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 14)
                        .padding(.leading, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 76)
            if firstLineTooLong {
                Text("首行较长，建议精简到 50 字符以内（不强制）。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(rgb: 0x9A7A35))
            }
        }
    }
}

// MARK: - Push / pull

struct SyncDialog: View {
    @ObservedObject var model: AppModel
    let push: Bool

    private var branch: String { model.status?.branch ?? "" }
    private var ahead: Int { model.outgoingCommits.count }
    private var availableBranches: [String] {
        model.remoteBranches
            .filter { $0.hasPrefix(model.remote + "/") }
            .map { String($0.dropFirst(model.remote.count + 1)) }
    }
    private var canRun: Bool { !model.displayTargetRemote.isEmpty && !model.displayTargetBranch.isEmpty }
    private var stateText: String {
        guard let upstream = model.status?.upstream else { return "尚未设置上游" }
        if push { return ahead > 0 ? "领先 \(upstream) \(ahead) 个提交" : "与 \(upstream) 同步" }
        return "从 \(upstream) 获取并合并到当前分支"
    }
    private var stateTone: Color { push && ahead > 0 ? Theme.successText : Theme.secondary }

    var body: some View {
        DialogFrame(title: "\(push ? "推送" : "拉取") — \(repositoryName(model))", width: 490, height: push ? (ahead > 0 ? 620 : 460) : 380) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    successCard
                    if !model.error.isEmpty {
                        FeedbackStrip(model: model, showsNotice: false)
                    }
                    localCard
                    if model.remotes.isEmpty {
                        noRemoteCard
                    } else {
                        targetCard
                    }
                    if push { outgoingCard }
                    if !model.resultLog.isEmpty { outputCard }
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Text("凭证来自系统 Git 配置")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            Button("取消") { closeDialogWindow() }.buttonStyle(SecondaryButtonStyle())
            Button(push ? "推送" : "拉取") { push ? model.push() : model.pull() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canRun || model.busy)
        }
    }

    @ViewBuilder private var successCard: some View {
        if push, !model.lastCommit.isEmpty {
            successBlock(title: "提交成功",
                         detail: "已保存到本地 \(branch) 分支 · \(shortHash(model.lastCommit))\n确认目标后点击「推送」，才会发送到远端。")
        } else if model.notice.contains("推送成功") {
            successBlock(title: "推送成功", detail: model.notice)
        } else if model.notice.contains("拉取成功") {
            successBlock(title: "拉取成功", detail: model.notice)
        } else if model.notice.contains("冲突已解决") {
            successBlock(title: "冲突已解决", detail: model.notice)
        }
    }

    private var localCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("本地")
            PlainCard {
                fieldRow("分支") {
                    BranchPill(name: branch)
                    Spacer(minLength: 6)
                    Text(stateText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(stateTone)
                        .lineLimit(1)
                }
            }
        }
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(push ? "目标" : "来源")
            PlainCard {
                fieldRow("远端") {
                    if model.hasUpstream {
                        remotePill(model.displayTargetRemote)
                    } else if model.remotes.isEmpty {
                        Text("未配置").font(.system(size: 11.5)).foregroundStyle(Theme.warningText)
                    } else {
                        remoteMenu
                    }
                    Spacer(minLength: 0)
                }
                rowDivider
                fieldRow("分支") {
                    if model.hasUpstream {
                        Text(model.displayTargetBranch)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                    } else if push {
                        DialogTextField(placeholder: "远端分支（不存在时创建）", text: $model.remoteBranch)
                    } else if availableBranches.isEmpty {
                        Text("该远端没有可用分支，请先推送或刷新。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.warningText)
                    } else {
                        Picker("", selection: $model.remoteBranch) {
                            ForEach(availableBranches, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                }
                if push && !model.hasUpstream {
                    rowDivider
                    fieldRow("上游") {
                        Toggle("记住为当前分支的上游", isOn: $model.setUpstream)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2)
                        Spacer(minLength: 0)
                    }
                }
            }
            Text(targetHint)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
    }

    private var targetHint: String {
        if model.hasUpstream { return "当前分支已配置上游，操作直接使用该上游。" }
        if push { return "默认推送到上游分支；目标在远端不存在时，将创建该远端分支并设为上游。" }
        return "拉取 = 获取并合并该远端分支到当前分支；产生冲突时会暂停并进入解决冲突流程。"
    }

    private var remoteMenu: some View {
        Menu {
            ForEach(model.remotes, id: \.self) { name in
                Button(name) {
                    model.remote = name
                    model.syncRemoteBranchOptions()
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(model.remote).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Theme.listHeader, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var noRemoteCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            InlineNotice("尚未配置远程仓库。请先通过系统 Git 添加远程仓库，然后再\(push ? "推送" : "拉取")。")
            if push {
                HStack(spacing: 8) {
                    DialogTextField(placeholder: "远端名称", text: $model.newRemoteName)
                        .frame(width: 104)
                    DialogTextField(placeholder: "HTTPS 或 SSH 地址", text: $model.remoteAddress)
                    Button("添加远端") { model.addRemote() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(model.remoteAddress.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
            }
        }
    }

    private var outgoingCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("待推送提交（\(ahead)）")
            PlainCard {
                if model.outgoingCommits.isEmpty {
                    Text("没有待推送提交。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.outgoingCommits.prefix(20).enumerated()), id: \.element) { index, commit in
                                if index > 0 {
                                    Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 12)
                                }
                                HStack(spacing: 9) {
                                    Text(shortHash(commit.id))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.muted)
                                        .frame(width: 58, alignment: .leading)
                                    Text(commit.subject)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(commit.author)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.muted)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Git 输出")
            PlainCard {
                ScrollView {
                    Text(model.resultLog)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private func fieldRow<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 46, alignment: .leading)
            value()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }

    private func remotePill(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Theme.listHeader, in: Capsule())
    }
}

// MARK: - Branches

struct BranchesDialog: View {
    @ObservedObject var model: AppModel

    private var dirty: Int { model.status?.files.count ?? 0 }

    var body: some View {
        DialogFrame(title: "分支 — \(repositoryName(model))", width: 720, height: 540) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    if !model.error.isEmpty {
                        FeedbackStrip(model: model, showsNotice: false)
                    } else if !model.notice.isEmpty {
                        InlineNotice(model.notice, tone: .info)
                    }
                    if dirty > 0 {
                        InlineNotice("工作区有 \(dirty) 个未提交更改。MenuGit 不会自动暂存或丢弃；Git 判断会覆盖修改时会阻止切换。")
                    }
                    localGroup
                    remoteGroup
                    createBox
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            Spacer()
            Button("完成") { closeDialogWindow() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private var intro: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(rgb: 0xDEEBFF))
                    .frame(width: 40, height: 40)
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(rgb: 0x075BD5))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("分支管理").font(.system(size: 15, weight: .bold)).foregroundStyle(Color(rgb: 0x16283F))
                Text("查看、切换和创建仓库分支").font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Spacer()
        }
    }

    private var localGroup: some View {
        group(title: "本地分支 · \(model.localBranches.count)") {
            if model.localBranches.isEmpty {
                emptyRow("没有本地分支。")
            } else {
                ForEach(model.localBranches, id: \.self) { branch in
                    branchRow(branch)
                }
            }
        }
    }

    private var remoteGroup: some View {
        group(title: "远程分支 · \(model.remoteBranches.count)") {
            if model.remoteBranches.isEmpty {
                emptyRow("没有可用的远程分支；配置远端并推送后可在这里检出。")
            } else {
                ForEach(model.remoteBranches, id: \.self) { branch in
                    remoteRow(branch)
                }
            }
        }
    }

    private func group<Rows: View>(title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(rgb: 0x354B67))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.listHeader)
            Rectangle().fill(Theme.border).frame(height: 1)
            rows()
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private func branchRow(_ branch: String) -> some View {
        HStack(spacing: 10) {
            branchIcon(tint: Theme.localBg, color: Theme.local)
            Text(branch)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(rgb: 0x22324B))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if branch == model.status?.branch {
                Text("● 当前分支")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color(rgb: 0x087342))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(rgb: 0xD9F3E4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Button("切换") { model.switchBranch(branch) }.buttonStyle(CompactButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 52)
        }
    }

    private func remoteRow(_ branch: String) -> some View {
        HStack(spacing: 10) {
            branchIcon(tint: Color(rgb: 0xF0E6FF), color: Color(rgb: 0x7544BC))
            Text(branch)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(rgb: 0x22324B))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            if let local = localName(for: branch), model.localBranches.contains(local) {
                Text("已有本地分支 \(local)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            } else {
                Button("检出为跟踪分支") { model.switchBranch(branch, isRemote: true) }
                    .buttonStyle(CompactButtonStyle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, 52)
        }
    }

    private func branchIcon(tint: Color, color: Color) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint).frame(width: 30, height: 30)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var createBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("新建分支")
            HStack(spacing: 8) {
                DialogTextField(placeholder: "例如 feature/new-ui", text: $model.branchName)
                Button("创建并切换") { model.createBranch() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.branchName.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
            }
        }
    }

    private func localName(for remoteBranch: String) -> String? {
        guard let remote = model.remotes.first(where: { remoteBranch.hasPrefix($0 + "/") }) else { return nil }
        return String(remoteBranch.dropFirst(remote.count + 1))
    }
}

// MARK: - History

struct HistoryDialog: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    private var filtered: [CommitRecord] {
        model.commits.filter { search.isEmpty || ($0.subject + $0.author).localizedCaseInsensitiveContains(search) }
    }
    private var selected: CommitRecord? { model.selectedCommit ?? filtered.first }

    var body: some View {
        DialogFrame(title: "日志 — \(repositoryName(model))", width: 820, height: 660) {
            VStack(spacing: 12) {
                DialogTextField(placeholder: "搜索提交信息或作者", text: $search)
                HStack(alignment: .top, spacing: 12) {
                    commitList
                        .frame(width: 360)
                        .frame(maxHeight: .infinity)
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } footer: {
            Button("关闭") { closeDialogWindow() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            if model.historyHasMore, search.isEmpty {
                Button("加载更早的提交") { model.loadMoreHistory() }.buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var commitList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered) { commit in
                    historyRow(commit)
                }
                if filtered.isEmpty {
                    Text(search.isEmpty ? "没有提交记录。" : "没有匹配的提交。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private func historyRow(_ commit: CommitRecord) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(shortHash(commit.id))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(commit.subject)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text(commit.author)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(commit.date)
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(model.selectedCommit?.id == commit.id ? Theme.rowActive : Color.white)
        .contentShape(Rectangle())
        .onTapGesture { model.showCommit(commit) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let commit = selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(commit.subject)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text("\(commit.id) · \(commit.author) · \(commit.date)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Theme.border).frame(height: 1)
                Text("提交详情")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 12)
                    .padding(.top, 9)
                    .padding(.bottom, 4)
                ScrollView {
                    Text(detailText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            } else {
                VStack {
                    Spacer()
                    Text("选择一条提交查看详情。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.diffBg)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }

    private var detailText: String {
        guard selected != nil else { return "选择提交查看详情。" }
        guard !model.commitDetail.isEmpty else { return "正在读取提交详情…" }
        let limit = 60_000
        guard model.commitDetail.count > limit else { return model.commitDetail }
        return String(model.commitDetail.prefix(limit)) + "\n…（内容过大，仅显示前 60,000 个字符）"
    }
}

// MARK: - Init / clone

struct InitDialog: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DialogFrame(title: "初始化 Git 仓库", width: 490, height: 280) {
            VStack(alignment: .leading, spacing: 10) {
                if !model.error.isEmpty || !model.notice.isEmpty {
                    FeedbackStrip(model: model)
                }
                SectionLabel("仓库位置")
                HStack(spacing: 8) {
                    ReadOnlyField(text: model.targetDirectory.path, mono: true)
                    Button("选择…") { model.chooseCloneDirectory() }.buttonStyle(SecondaryButtonStyle())
                }
                Text("初始化会在选定目录创建本地 Git 仓库；若该目录已属于仓库，操作会被阻止。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } footer: {
            Spacer()
            Button("取消") { closeDialogWindow() }.buttonStyle(SecondaryButtonStyle())
            Button("初始化") { model.initialize() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.busy)
        }
    }
}

struct CloneDialog: View {
    @ObservedObject var model: AppModel

    var body: some View {
        DialogFrame(title: "克隆仓库", width: 490, height: 470) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.error.isEmpty || !model.notice.isEmpty {
                        FeedbackStrip(model: model)
                    }
                    SectionLabel("仓库 URL（HTTPS 或 SSH）")
                    DialogTextField(placeholder: "https://github.com/example/repo.git", text: $model.cloneURL, mono: true)
                        .onChange(of: model.cloneURL) { _ in model.suggestedCloneName() }
                    SectionLabel("克隆到")
                    HStack(spacing: 8) {
                        ReadOnlyField(text: model.targetDirectory.path, mono: true)
                        Button("选择…") { model.chooseCloneDirectory() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.cloning)
                    }
                    SectionLabel("新建文件夹名称")
                    DialogTextField(placeholder: "awesome-lib", text: $model.cloneName)
                    Text("将在目标目录下新建仓库文件夹。凭证使用系统 Git credential helper / SSH agent。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.cloning {
                        PlainCard {
                            VStack(alignment: .leading, spacing: 8) {
                                if let percent = model.clonePercent {
                                    ProgressView(value: percent).tint(Theme.primary)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                Text(model.cloneProgress)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(2)
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } footer: {
            if model.cloning {
                Text(model.cloneProgress)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("取消克隆") { model.cancelClone() }.buttonStyle(SecondaryButtonStyle())
            } else {
                Spacer()
                Button("取消") { closeDialogWindow() }.buttonStyle(SecondaryButtonStyle())
                Button("克隆") { model.startClone() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.cloneURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.cloneName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

// MARK: - Settings

struct SettingsDialog: View {
    @ObservedObject var model: AppModel

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    var body: some View {
        DialogFrame(title: "MenuGit 设置", width: 490, height: 620) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    extensionCard
                    PlainCard {
                        Text("复用系统 Git、凭证助手、SSH agent 与 hooks。MenuGit 不保存账号凭证，也不修改全局 Git 配置。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                    }
                    diagnosticsCard
                    recentCard
                    aboutCard
                }
                .padding(22)
            }
        } footer: {
            Spacer()
            Button("完成") { closeDialogWindow() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private var extensionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Finder 扩展")
            PlainCard {
                HStack(spacing: 9) {
                    Circle()
                        .fill(model.extensionEnabled ? Color(rgb: 0x2FA36B) : Color(rgb: 0xE0A02C))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Finder 右键菜单")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text(model.extensionEnabled ? "已启用，可在 Finder 中右键使用 MenuGit。" : "尚未启用。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 6)
                    Button("系统设置") { model.openExtensionSettings() }.buttonStyle(CompactButtonStyle())
                    Button("刷新") { model.refreshExtensionStatus() }.buttonStyle(CompactButtonStyle())
                }
                .padding(12)
                if !model.extensionEnabled {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Text("在“系统设置 → 通用 → 登录项与扩展 → Finder 扩展”中启用 MenuGit。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("本机诊断信息")
            PlainCard {
                HStack(spacing: 8) {
                    Text(model.gitVersion.isEmpty ? "Git 版本未知" : model.gitVersion)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button("复制") { model.copyDiagnostics() }.buttonStyle(CompactButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollView {
                    Text(model.diagnostics())
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.ink2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(height: 130)
            }
        }
    }

    private var recentCard: some View {
        PlainCard {
            HStack(spacing: 8) {
                Text("最近仓库")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(model.recentRepositories.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("清除") { model.clearRecent() }.buttonStyle(CompactButtonStyle())
            }
            .padding(12)
        }
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("关于 MenuGit")
            PlainCard {
                HStack {
                    Text("版本").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text(version).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink)
                }
                .padding(12)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HStack {
                    Text("检查更新").font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("更新地址待设置").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Conflicts

struct ConflictDialog: View {
    @ObservedObject var model: AppModel
    @State private var search = ""

    private var files: [ChangedFile] { (model.status?.files ?? []).filter(\.hasConflict) }
    private var visibleFiles: [ChangedFile] {
        files.filter { search.isEmpty || $0.path.localizedCaseInsensitiveContains(search) }
    }
    private var draft: AppModel.ConflictDraft? { model.conflictPath.flatMap { model.conflictDrafts[$0] } }
    private var operationName: String { model.status?.conflictedOperation == "rebase" ? "变基" : "合并" }

    var body: some View {
        DialogFrame(title: "解决\(operationName)冲突", width: 1220, height: 760) {
            VStack(spacing: 0) {
                if files.isEmpty, model.status?.conflictedOperation != nil {
                    completion
                } else {
                    topBar
                    Rectangle().fill(Theme.border).frame(height: 1)
                    HStack(spacing: 0) {
                        sidebar.frame(width: 288)
                        Rectangle().fill(Theme.border).frame(width: 1)
                        detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(rgb: 0xF4F6FA))
                }
            }
        } footer: {
            Button("关闭") { closeDialogWindow() }.buttonStyle(SecondaryButtonStyle())
            Spacer()
            Button("中止\(operationName)") { model.abortConflict() }.buttonStyle(SecondaryButtonStyle())
            Button("继续\(operationName)") { model.continueConflict() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!files.isEmpty || model.status?.conflictedOperation == nil)
                .opacity(files.isEmpty ? 1 : 0.45)
        }
        .onAppear {
            if model.conflictPath == nil, let path = files.first?.path {
                Task { await model.loadConflict(path) }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("拉取后发现\(operationName)冲突")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(rgb: 0x233650))
                Text("选择文件，再逐处选择要保留的内容。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Text("剩余 \(files.count) 个冲突文件")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.infoText)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.infoBg, in: Capsule())
            Button("撤销上一步") { model.undoConflict() }
                .buttonStyle(CompactButtonStyle())
                .disabled(draft?.undo.isEmpty ?? true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Color.white)
    }

    private var completion: some View {
        let staged = model.status?.files.filter { $0.indexStatus != " " && $0.indexStatus != "?" }.count ?? 0
        let untracked = model.status?.files.filter(\.isUntracked).count ?? 0
        return VStack(spacing: 10) {
            Spacer()
            ZStack {
                Circle().fill(Color(rgb: 0x159553)).frame(width: 46, height: 46)
                Image(systemName: "checkmark").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
            }
            Text("所有冲突文件已解决")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("\(operationName)仍在进行中。继续后由 Git 生成\(operationName)提交；中止会尝试恢复到操作前状态。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Text("合并结果包含 \(staged) 个已暂存的文件变更")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            if untracked > 0 {
                Text("\(untracked) 个未跟踪文件不在本次\(operationName)提交中，完成后可单独提交。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("冲突文件 · \(files.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(rgb: 0x233650))
                    Spacer()
                }
                TextField("搜索冲突文件", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Color(rgb: 0xB9C9DC), lineWidth: 1))
                Toggle("全选未解决文件", isOn: selectAllBinding)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(visibleFiles) { file in
                        conflictRow(file)
                    }
                    if visibleFiles.isEmpty {
                        Text("没有匹配的文件")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .padding(12)
                    }
                }
                .padding(6)
            }
            .background(Color.white)
            bulkBar
        }
        .frame(maxHeight: .infinity)
    }

    private var selectAllBinding: Binding<Bool> {
        Binding(get: {
            let paths = visibleFiles.map(\.path)
            return !paths.isEmpty && paths.allSatisfy { model.conflictSelected.contains($0) }
        }, set: { on in
            let paths = visibleFiles.map(\.path)
            if on { model.conflictSelected.formUnion(paths) }
            else { model.conflictSelected.subtract(paths) }
        })
    }

    private func conflictRow(_ file: ChangedFile) -> some View {
        let active = model.conflictPath == file.path
        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { model.conflictSelected.contains(file.path) }, set: { on in
                if on { model.conflictSelected.insert(file.path) } else { model.conflictSelected.remove(file.path) }
            }))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Button {
                Task { await model.loadConflict(file.path) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(rgb: 0x253B56))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(statusText(file.path))
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor(file.path))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(active ? Theme.rowActive : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color(rgb: 0x236BEA))
                    .frame(width: 3)
                    .padding(.vertical, 5)
            }
        }
    }

    private var bulkBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("已选 \(model.conflictSelected.count) 个未解决文件")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
            Text("仅处理未解决的冲突块")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color(rgb: 0x405874))
            HStack(spacing: 6) {
                bulkButton("批量使用本地", .local, whole: false)
                bulkButton("批量使用传入", .incoming, whole: false)
            }
            Text("替换整份文件")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(Color(rgb: 0x405874))
            HStack(spacing: 6) {
                bulkButton("整份保留本地", .local, whole: true)
                bulkButton("整份使用传入", .incoming, whole: true)
            }
            Text("编辑中的文件先保存或取消；二进制文件只能选择整份版本。")
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.white)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func bulkButton(_ title: String, _ choice: ConflictChoice, whole: Bool) -> some View {
        Button {
            model.batchConflicts(choice, wholeFiles: whole)
        } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(CompactButtonStyle())
        .disabled(model.conflictSelected.isEmpty)
    }

    @ViewBuilder private var detail: some View {
        if let draft, let path = model.conflictPath {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(path)
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(rgb: 0x162E50))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(draft.editing ? "编辑中" : "待解决")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(Color(rgb: 0xAA271E))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color(rgb: 0xFFE1DD), in: Capsule())
                    Spacer(minLength: 6)
                    Button("整份本地") { model.confirmWholeFile(.local) }
                        .buttonStyle(CompactButtonStyle())
                        .help("用本地版本替换整份文件，包括冲突以外的更改")
                    Button("整份传入") { model.confirmWholeFile(.incoming) }
                        .buttonStyle(CompactButtonStyle())
                        .help("用传入版本替换整份文件，包括冲突以外的更改")
                    Button("打开文件") { model.openFile(path) }
                        .buttonStyle(CompactButtonStyle())
                }
                switch draft.document.kind {
                case .text where !draft.document.blocks.isEmpty:
                    textConflict(draft, path: path)
                case .binary:
                    binaryConflict(draft, path: path)
                default:
                    VStack(alignment: .leading, spacing: 10) {
                        Text(draft.document.reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                        Button("在默认应用中打开") { model.openFile(path) }
                            .buttonStyle(SecondaryButtonStyle())
                        Spacer()
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack {
                Spacer()
                Text(files.isEmpty ? "所有冲突文件已解决，可以继续操作。" : "选择文件查看冲突。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func textConflict(_ draft: AppModel.ConflictDraft, path: String) -> some View {
        if draft.editing {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(get: { model.conflictDrafts[path]?.manualText ?? "" }, set: { model.updateManualConflict($0) }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.fieldBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(maxHeight: .infinity)
                HStack(spacing: 8) {
                    Text("删除全部冲突标记后保存；内容会原样写入该文件。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                    Spacer()
                    Button("取消编辑") { model.cancelConflictEdit() }.buttonStyle(SecondaryButtonStyle())
                    Button("保存并标记解决") { model.saveConflict() }.buttonStyle(PrimaryButtonStyle())
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 8) {
                navigation(draft)
                conflictDocument(draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                perFileFooter(draft)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func navigation(_ draft: AppModel.ConflictDraft) -> some View {
        let count = draft.document.blocks.count
        let index = min(model.conflictIndex, max(count - 1, 0))
        let unresolved = draft.choices.filter { $0 == nil }.count
        return HStack(spacing: 6) {
            Text("冲突 \(index + 1) / \(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(rgb: 0x344A67))
            Text(unresolved > 0 ? "未解决 \(unresolved) 处" : "全部已选择")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(unresolved > 0 ? Color(rgb: 0xA66014) : Color(rgb: 0x087A46))
            Spacer()
            Button("上一处") { model.conflictIndex = max(0, index - 1) }
                .buttonStyle(CompactButtonStyle())
                .disabled(index == 0 || draft.editing)
            Button("下一处") { model.conflictIndex = min(count - 1, index + 1) }
                .buttonStyle(CompactButtonStyle())
                .disabled(index + 1 >= count || draft.editing)
            Button("下一处未解决") { model.nextUnresolved() }
                .buttonStyle(CompactButtonStyle())
                .disabled(unresolved == 0 || draft.editing)
            Toggle("选择后自动跳转", isOn: $model.conflictAutoNext)
                .toggleStyle(.checkbox)
                .font(.system(size: 10.5))
                .foregroundStyle(Color(rgb: 0x51647D))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color(rgb: 0xEDF3FB))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(rgb: 0xD2DFEF), lineWidth: 1))
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
                            )
                            .id("block-\(index)")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.trailing, 10)
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .onAppear { scroll(to: proxy) }
            .onChange(of: model.conflictIndex) { _ in scroll(to: proxy) }
        }
        .frame(minHeight: 240)
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
            Text("\(number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(rgb: 0x71849A))
                .frame(width: 38, alignment: .trailing)
                .padding(.trailing, 8)
            Text(text.isEmpty ? " " : text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }

    private func perFileFooter(_ draft: AppModel.ConflictDraft) -> some View {
        let unresolved = draft.choices.filter { $0 == nil }.count
        return HStack(spacing: 8) {
            Text("已处理 \(draft.choices.count - unresolved) / \(draft.choices.count) 处")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
            Text("每处冲突选择一侧或保留两边；仍含冲突标记时不会写入。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Button("编辑结果") { model.editConflict() }
                .buttonStyle(CompactButtonStyle())
                .disabled(unresolved > 0 || draft.editing)
            Button("保存并标记解决") { model.saveConflict() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(unresolved > 0)
                .opacity(unresolved > 0 ? 0.45 : 1)
        }
    }

    private func binaryConflict(_ draft: AppModel.ConflictDraft, path: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            InlineNotice("二进制文件无法按文本比较或逐块合并，请选择整份本地或传入文件。")
            HStack(spacing: 12) {
                binarySide(title: "本地", tint: Theme.localBg, color: Theme.local, button: "保留本地文件") {
                    model.saveConflict(choice: .local)
                }
                binarySide(title: "传入", tint: Theme.incomingBg, color: Theme.incoming, button: "使用传入文件") {
                    model.saveConflict(choice: .incoming)
                }
            }
            Button("在默认应用中打开") { model.openFile(path) }.buttonStyle(CompactButtonStyle())
            Spacer()
        }
    }

    private func binarySide(title: String, tint: Color, color: Color, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundStyle(color)
            Text("二进制文件版本")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(tint, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button(action: action) {
                Text(button).frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.border, lineWidth: 1))
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
        if model.conflictDrafts[path]?.editing == true { return Color(rgb: 0xA66014) }
        if model.conflictKind(for: path) == .unsupported { return Theme.muted }
        return Color(rgb: 0xA66014)
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
        .padding(.vertical, 5)
    }

    private func band(title: String, lines: [String], start: Int, tone: BandTone, active: Bool, showActions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tone.color)
                if active {
                    Label("已采用", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(tone.color)
                }
                Spacer()
                if showActions {
                    chooseButton("采用本地", chosen: choice == .local) { onChoose(.local) }
                    chooseButton("采用传入", chosen: choice == .incoming) { onChoose(.incoming) }
                    chooseButton("保留两边", chosen: choice == .both) { onChoose(.both) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            ForEach(Array(lines.enumerated()), id: \.offset) { offset, line in
                HStack(spacing: 0) {
                    Text("\(start + offset)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(rgb: 0x71849A))
                        .frame(width: 38, alignment: .trailing)
                        .padding(.trailing, 8)
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(tone.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 1)
            }
        }
        .background(tone.tint)
        .overlay(alignment: .leading) {
            Rectangle().fill(tone.color).frame(width: 3)
        }
    }

    private func chooseButton(_ title: String, chosen: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if chosen { Image(systemName: "checkmark") }
                Text(title)
            }
            .font(.system(size: 10, weight: chosen ? .bold : .medium))
            .foregroundStyle(chosen ? Color.white : Theme.ink2)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(chosen ? Color(rgb: 0x155ECB) : Color.white, in: Capsule())
            .overlay(Capsule().stroke(chosen ? Color.clear : Color(rgb: 0xC5D3E4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(editing)
        .fixedSize()
    }

    private enum BandTone {
        case local, incoming

        var color: Color { self == .local ? Theme.local : Theme.incoming }
        var tint: Color { self == .local ? Theme.localBg : Theme.incomingBg }
        var code: Color { self == .local ? Color(rgb: 0x153968) : Color(rgb: 0x4D2477) }
    }
}
