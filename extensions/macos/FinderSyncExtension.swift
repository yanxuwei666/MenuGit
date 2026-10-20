import AppKit
import FinderSync
import CryptoKit
import os

@objc(MenuGitFinderSyncExtension)
final class FinderSyncExtension: FIFinderSync {
    // 默认控制器需要在 FIFinderSync 完成初始化后获取，不能在存储属性初始化时提前缓存。
    private var controller: FIFinderSyncController { FIFinderSyncController.default() }
    private let menuBuilder = MenuGitFinderMenu()

    override init() {
        super.init()
        // 沙盒内 NSHomeDirectory 指向扩展容器；观察真实目录，不遍历文件或启动 Git。
        controller.directoryURLs = MenuGitFinderMenu.observedDirectories
        Logger(subsystem: "dev.menugit.desktop.findersync", category: "lifecycle")
            .notice("Finder extension started; registered \(self.controller.directoryURLs.count, privacy: .public) monitored roots")
    }

    override func beginObservingDirectory(at url: URL) {
        Logger(subsystem: "dev.menugit.desktop.findersync", category: "routing")
            .notice("observing directory digest=\(Self.directoryDigest(url), privacy: .public)")
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let selected = Self.contextURL(
            for: menuKind,
            selected: controller.selectedItemURLs(),
            targeted: controller.targetedURL()
        )
        let logger = Logger(subsystem: "dev.menugit.desktop.findersync", category: "routing")
        guard let selected else {
            logger.notice("menu request kind=\(menuKind.rawValue, privacy: .public) has no target")
            return nil
        }
        let menu = menuBuilder.makeMenu(for: selected)
        for parent in menu.items {
            parent.target = self
            for item in parent.submenu?.items ?? [] where item.action != nil {
                item.target = self
            }
        }
        logger.notice("menu response kind=\(menuKind.rawValue, privacy: .public) targetDigest=\(Self.directoryDigest(selected), privacy: .public) itemCount=\(menu.items.count, privacy: .public)")
        return menu
    }

    @objc func openMenuAction(_ sender: NSMenuItem) {
        menuBuilder.openMenuAction(sender)
    }

    @objc func submenuAction(_ sender: NSMenuItem) {}

    static func directoryDigest(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func contextURL(for kind: FIMenuKind, selected: [URL]?, targeted: URL?) -> URL? {
        switch kind {
        case .contextualMenuForItems:
            // 优先被点击的项目本身；targeted 只是所在目录，否则仓库文件夹右键会落到父目录。
            return selected?.first ?? targeted
        case .contextualMenuForContainer, .contextualMenuForSidebar:
            // 空白处菜单必须使用当前目录，不能复用 Finder 中之前选中的文件。
            return targeted
        default:
            return nil
        }
    }
}
