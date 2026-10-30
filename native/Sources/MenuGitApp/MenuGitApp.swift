import AppKit
import MenuGitCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var suppressUntilReveal = true
    private var fallbackTimer: Timer?
    private var layoutTimer: Timer?
    private var awaitingLayout = false
    private var appearBaseline = 0
    private var screenAtHide = AppModel.Screen.welcome

    private var mainWindow: NSWindow? {
        NSApp.windows.first { $0.canBecomeKey && !($0 is NSPanel) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        model.hideWindow = { [weak self] in self?.hideWindow() }
        model.revealWindow = { [weak self] in self?.revealWindow() }
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidUpdate), name: NSApplication.didUpdateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dialogLayoutDidChange(_:)), name: .menuGitDialogLayoutChanged, object: nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        suppressWindows()
        scheduleFallback(0.6)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        for url in urls { AppModel.shared.handle(url) }
        NSApp.activate(ignoringOtherApps: true)
        scheduleFallback(3)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !suppressUntilReveal, !flag else { return true }
        let model = AppModel.shared
        if model.screen == .conflicts || model.screen == .welcome {
            showWindow()
        } else {
            model.screen = .welcome
            screenAtHide = .conflicts
            appearBaseline = model.dialogAppearID
            revealWindow()
        }
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

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard suppressUntilReveal,
              let window = notification.object as? NSWindow,
              window.canBecomeKey, !(window is NSPanel) else { return }
        window.alphaValue = 0
    }

    @objc private func appDidUpdate() {
        guard suppressUntilReveal else { return }
        for window in NSApp.windows where window.canBecomeKey && !(window is NSPanel) && window.isVisible && window.alphaValue != 0 {
            window.alphaValue = 0
        }
    }

    private func suppressWindows() {
        guard let window = mainWindow else { return }
        window.alphaValue = 0
    }

    private func hideWindow() {
        suppressUntilReveal = true
        AppModel.shared.suppressWindowDisplay = true
        awaitingLayout = false
        appearBaseline = AppModel.shared.dialogAppearID
        screenAtHide = AppModel.shared.screen
        layoutTimer?.invalidate()
        layoutTimer = nil
        guard let window = mainWindow else { return }
        window.alphaValue = 0
    }

    private func revealWindow() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        awaitingLayout = true
        if dialogSettled() {
            finishReveal()
            return
        }
        let timer = Timer(timeInterval: 1.5, target: self, selector: #selector(layoutTimedOut), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        layoutTimer = timer
    }

    @objc private func dialogLayoutDidChange(_ notification: Notification) {
        guard awaitingLayout, dialogSettled() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.awaitingLayout, self.dialogSettled() else { return }
            self.finishReveal()
        }
    }

    private func dialogSettled() -> Bool {
        guard let window = mainWindow, windowMatchesDialogSize(window) else { return false }
        if AppModel.shared.screen == screenAtHide { return true }
        return AppModel.shared.dialogAppearID > appearBaseline
    }

    @objc private func layoutTimedOut() {
        finishReveal()
    }

    private func windowMatchesDialogSize(_ window: NSWindow) -> Bool {
        let desired = AppModel.shared.expectedDialogSize
        guard desired.width > 0 else { return true }
        return abs(window.frame.width - desired.width) < 1 && abs(window.frame.height - desired.height) < 1
    }

    private func finishReveal() {
        awaitingLayout = false
        AppModel.shared.suppressWindowDisplay = false
        layoutTimer?.invalidate()
        layoutTimer = nil
        suppressUntilReveal = false
        showWindow()
    }

    private func scheduleFallback(_ delay: TimeInterval) {
        fallbackTimer?.invalidate()
        let timer = Timer(timeInterval: delay, target: self, selector: #selector(fallbackFired), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    @objc private func fallbackFired() {
        revealWindow()
    }

    private func showWindow(attempts: Int = 0) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            reveal(window)
            return
        }
        guard let open = AppModel.shared.openMainWindow, attempts < 20 else { return }
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if let window = self.mainWindow {
                self.reveal(window)
            } else {
                self.showWindow(attempts: attempts + 1)
            }
        }
    }

    private func reveal(_ window: NSWindow) {
        window.alphaValue = 1
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
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
