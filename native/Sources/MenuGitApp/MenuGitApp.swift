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
        if let window = NSApp.windows.first(where: { $0.canBecomeKey && !($0 is NSPanel) }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        if AppModel.shared.screen != .conflicts { AppModel.shared.screen = .welcome }
        AppModel.shared.openMainWindow?()
    }
}

struct MenuGitCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开仓库…") {
                openWindow(id: "main")
                model.chooseFolder()
            }
            .keyboardShortcut("o")
            Button("新建仓库") {
                openWindow(id: "main")
                model.screen = .create
            }
            Button("克隆仓库") {
                openWindow(id: "main")
                model.screen = .clone
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                openWindow(id: "main")
                model.refreshExtensionStatus()
                model.screen = .settings
            }
            .keyboardShortcut(",")
        }
    }
}

@main
struct MenuGitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("MenuGit", id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 490, height: 620)
        .defaultPosition(.center)
        .commands { MenuGitCommands(model: model) }
    }
}
