import AppKit
import Darwin
import os

final class MenuGitAction: NSObject {
    let command: String
    let path: String
    let file: String?

    init(command: String, path: String, file: String? = nil) {
        self.command = command
        self.path = path
        self.file = file
    }

    /// 沙盒扩展向主应用传 argv 会被 LaunchServices 丢弃，改用自定义 URL 携带请求。
    var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "menugit"
        components.host = command
        var items = [URLQueryItem(name: "path", value: path)]
        if let file, Self.fileCommands.contains(command) {
            items.append(URLQueryItem(name: "file", value: file))
        }
        components.queryItems = items
        return components.url
    }

    private static let fileCommands = ["commit", "log", "discard"]
}

/// 菜单生成与 Finder 控制器分离，后台测试直接复用生产逻辑。
final class MenuGitFinderMenu: NSObject {
    private var nextActionTag = 0
    private var actions: [Int: MenuGitAction] = [:]
    // 后台集成测试替换启动器，保留系统动作分派与参数解析，但不打开主应用窗口。
    static var applicationLauncher: (MenuGitAction, URL) -> Void = launchApplication
    static var observedDirectories: Set<URL> {
        var roots = Set(["/Volumes", "/private/tmp"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        // getpwuid 返回真实账户目录；NSHomeDirectory 在 App Sandbox 中是扩展容器。
        if let account = getpwuid(getuid()), let home = account.pointee.pw_dir {
            let homePath = String(cString: home)
            roots.insert(URL(fileURLWithPath: homePath, isDirectory: true))
            let dataPath = "/System/Volumes/Data" + homePath
            if FileManager.default.fileExists(atPath: dataPath) {
                roots.insert(URL(fileURLWithPath: dataPath, isDirectory: true))
            }
        }
        return roots
    }

    func makeMenu(for selected: URL) -> NSMenu {
        // 原始动作保留在扩展内；Finder 只传输系统支持的 tag，不传自定义 NSObject。
        if actions.count > 256 { actions.removeAll() }
        // Finder 可能传入 file:///.file/id=… 引用 URL，先统一成基于路径的 URL。
        let target = Self.canonicalFileURL(selected)
        // 仓库发现不能依赖 isDirectory：在 Finder 沙盒中资源属性查询可能失败，
        // 而仓库文件夹本身、仓库内的文件/子目录都必须进入仓库菜单。
        let repository = findRepository(from: target)
        let clickedIsDirectory = isDirectory(target)
        let contextDirectory = repository
            ?? (clickedIsDirectory ? target : target.deletingLastPathComponent())
        let menu = NSMenu()
        let submenu = NSMenu()
        // 保留显式设置的禁用状态，避免 AppKit 自动重新启用“解决冲突”。
        menu.autoenablesItems = false
        submenu.autoenablesItems = false
        let parentTitle: String

        if let repository {
            let branch = branchName(at: repository) ?? "Git"
            parentTitle = "MenuGit (\(branch))"
            let relativeFile = clickedIsDirectory ? nil : relativePath(target, to: repository)
            add("提交…", command: "commit", repository: repository, file: relativeFile, to: submenu)
            add("拉取", command: "pull", repository: repository, to: submenu)
            add("推送", command: "push", repository: repository, to: submenu)
            add("分支…", command: "branch", repository: repository, to: submenu)
            add("日志…", command: "log", repository: repository, file: relativeFile, to: submenu)
            add("放弃修改…", command: "discard", repository: repository, file: relativeFile, to: submenu)
            add("解决冲突…", command: "conflict", repository: repository, enabled: mergeInProgress(at: repository), to: submenu)
            submenu.addItem(.separator())
        } else {
            parentTitle = "MenuGit"
            add("在此初始化 Git 仓库", command: "init", repository: contextDirectory, to: submenu)
            add("克隆仓库到此处…", command: "clone", repository: contextDirectory, to: submenu)
            submenu.addItem(.separator())
        }
        add("设置…", command: "settings", repository: contextDirectory, to: submenu)
        let parent = NSMenuItem(title: parentTitle, action: #selector(submenuAction(_:)), keyEquivalent: "")
        nextActionTag += 1
        parent.tag = nextActionTag
        parent.target = self
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    private func add(_ title: String, command: String, repository: URL, file: String? = nil,
                     enabled: Bool = true, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(openMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        nextActionTag += 1
        item.tag = nextActionTag
        actions[item.tag] = MenuGitAction(command: command, path: repository.path, file: file)
        menu.addItem(item)
    }

    func action(for item: NSMenuItem) -> MenuGitAction? {
        actions[item.tag]
    }

    @objc func submenuAction(_ sender: NSMenuItem) {}

    static func containingApplication(for extensionURL: URL) -> URL {
        extensionURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @objc func openMenuAction(_ sender: NSMenuItem) {
        guard let action = action(for: sender) else { return }
        let appBundle = Self.containingApplication(for: Bundle.main.bundleURL)
        Self.applicationLauncher(action, appBundle)
    }

    private static func launchApplication(_ action: MenuGitAction, _ appBundle: URL) {
        guard let url = action.deepLinkURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        // 明确指定自身应用，不依赖 URL Scheme 的默认处理器，避免打开另一份拷贝。
        NSWorkspace.shared.open([url], withApplicationAt: appBundle, configuration: configuration) { _, error in
            if let error {
                Logger(subsystem: "dev.menugit.desktop.findersync", category: "launch")
                    .error("Unable to open MenuGit request URL: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        // filePathURL 无法解析的引用 URL 会退化为空路径或 "/"，重建为路径 URL 后
        // deletingLastPathComponent 才会正常收敛（引用 URL 会不断生成 "/.."）。
        let path = (url as NSURL).filePathURL?.path ?? url.path
        return URL(fileURLWithPath: path.isEmpty ? "/" : path)
    }

    private func findRepository(from directory: URL) -> URL? {
        var current = Self.canonicalFileURL(directory).standardizedFileURL.path
        guard !current.isEmpty else { return nil }
        // 父路径必须严格缩短，并设置上限：异常 URL 绝不能让 Finder 菜单请求无响应。
        for _ in 0..<128 {
            let candidate = URL(fileURLWithPath: current, isDirectory: true)
            if let gitDirectory = gitDirectory(at: candidate),
               FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("HEAD").path) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { return nil }
            current = parent
        }
        return nil
    }

    /// 读取目录标记；资源属性查询失败时退回文件系统检查，避免把仓库文件夹当文件。
    private func isDirectory(_ url: URL) -> Bool {
        let target = Self.canonicalFileURL(url)
        if let value = try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return value
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        return false
    }

    private func branchName(at repository: URL) -> String? {
        guard let gitDirectory = gitDirectory(at: repository),
              let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return String(head.prefix(7))
    }

    private func relativePath(_ file: URL, to repository: URL) -> String? {
        let root = repository.standardizedFileURL.path
        let target = Self.canonicalFileURL(file).standardizedFileURL.path
        guard target.hasPrefix(root + "/") else { return nil }
        return String(target.dropFirst(root.count + 1))
    }

    private func mergeInProgress(at repository: URL) -> Bool {
        // 合并未完成时允许进入处理页，包括冲突已解决、等待提交的状态。
        guard let gitDirectory = gitDirectory(at: repository) else { return false }
        return FileManager.default.fileExists(atPath: gitDirectory.appendingPathComponent("MERGE_HEAD").path)
    }

    private func gitDirectory(at repository: URL) -> URL? {
        let marker = repository.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return marker }
        guard let markerText = try? String(contentsOf: marker, encoding: .utf8), markerText.hasPrefix("gitdir:") else {
            return nil
        }
        let value = markerText.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value).standardizedFileURL
            : repository.appendingPathComponent(value).standardizedFileURL
    }
}
