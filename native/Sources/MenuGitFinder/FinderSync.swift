import AppKit
import FinderSync
import Darwin

final class FinderSync: FIFinderSync {
    private var controller: FIFinderSyncController { .default() }
    private var requests: [Int: Request] = [:]
    private var nextTag = 0
    private var removalTimer: Timer?
    private struct Request { let action: String; let target: URL; let items: [URL] }

    private var isInstalled: Bool {
        let path = Bundle.main.bundleURL.path
        return !path.contains("/.Trash/") && FileManager.default.fileExists(atPath: path)
    }

    override init() {
        super.init()
        startRemovalWatch()
        var roots: Set<URL> = [URL(fileURLWithPath: "/Volumes", isDirectory: true), URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
        if let account = getpwuid(getuid()), let home = account.pointee.pw_dir {
            let path = String(cString: home)
            roots.insert(URL(fileURLWithPath: path, isDirectory: true))
            roots.insert(URL(fileURLWithPath: "/System/Volumes/Data" + path, isDirectory: true))
        }
        controller.directoryURLs = roots
    }

    private func startRemovalWatch() {
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(removalTick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        removalTimer = timer
    }

    @objc private func removalTick() {
        guard !isInstalled else { return }
        removalTimer?.invalidate()
        removalTimer = nil
        exit(0)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard isInstalled else { return nil }
        let selected = (controller.selectedItemURLs() ?? []).map { ($0 as NSURL).filePathURL ?? $0 }
        let targeted = controller.targetedURL().map { ($0 as NSURL).filePathURL ?? $0 }
        let target: URL?
        switch menuKind {
        case .contextualMenuForItems: target = selected.first ?? targeted
        case .contextualMenuForContainer, .contextualMenuForSidebar: target = targeted
        default: return nil
        }
        guard let target else { return nil }
        let items = menuKind == .contextualMenuForItems ? selected : []
        let repo = findRepository(from: target)
        let branch = repo.flatMap { branchName(at: $0) }
        let parent = NSMenuItem(title: repo == nil ? "MenuGit" : "MenuGit（\(branch ?? "未知分支")）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let heading = NSMenuItem(title: repo == nil ? "当前文件夹" : "仓库 · \(branch ?? "未知分支")", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        submenu.addItem(heading)
        submenu.addItem(.separator())
        let options: [(String, String)] = repo == nil ? [("创建", "init"), ("克隆", "clone")] : [("提交", "commit"), ("推送", "push"), ("拉取", "pull"), ("分支", "branches"), ("日志", "history")]
        if requests.count > 512 { requests.removeAll() }
        for (title, action) in options {
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            nextTag += 1; item.tag = nextTag; item.target = self
            requests[item.tag] = Request(action: action, target: target, items: items)
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置", action: #selector(performAction(_:)), keyEquivalent: "")
        nextTag += 1; settings.tag = nextTag; settings.target = self
        requests[settings.tag] = Request(action: "settings", target: target, items: [])
        submenu.addItem(settings)
        parent.submenu = submenu
        let menu = NSMenu(); menu.addItem(parent); return menu
    }

    @objc private func performAction(_ item: NSMenuItem) {
        guard let request = requests[item.tag] else { return }
        var components = URLComponents()
        components.scheme = "menugit-native"; components.host = request.action
        components.queryItems = [URLQueryItem(name: "path", value: request.target.path)] + request.items.map { URLQueryItem(name: "item", value: $0.path) }
        guard let url = components.url else { return }
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: .init()) { _, error in
            if let error { NSLog("MenuGit: unable to open request: %@", error.localizedDescription) }
        }
    }

    private func findRepository(from url: URL) -> URL? {
        var current = url.standardizedFileURL
        for _ in 0..<128 {
            let marker = current.appendingPathComponent(".git")
            if FileManager.default.fileExists(atPath: marker.path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
        return nil
    }

    private func branchName(at root: URL) -> String? {
        var gitDirectory = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue, let pointer = try? String(contentsOf: gitDirectory, encoding: .utf8), pointer.hasPrefix("gitdir:") {
                let path = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                gitDirectory = URL(fileURLWithPath: path, relativeTo: root).standardizedFileURL
            }
        }
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
        let value = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("ref: refs/heads/") { return String(value.dropFirst("ref: refs/heads/".count)) }
        return value.isEmpty ? nil : String(value.prefix(7))
    }
}
