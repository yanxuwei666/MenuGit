import AppKit
import MenuGitCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppModel.shared.handle(url) }
        NSApp.activate(ignoringOtherApps: true)
        showWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.hasUnsavedConflictDrafts else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "存在尚未保存的冲突处理"
        alert.informativeText = "请返回保存并标记解决；如果放弃，尚未保存的选择和编辑将丢失。"
        alert.addButton(withTitle: "返回处理")
        alert.addButton(withTitle: "放弃并退出")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }

    private func showWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

@main
struct MenuGitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    var body: some Scene {
        Window("MenuGit", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 560)
        }
        .defaultSize(width: 1080, height: 760)
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
