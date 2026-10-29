import AppKit
import FinderSync

enum FinderExtension {
    static var isEnabled: Bool { FIFinderSyncController.isExtensionEnabled }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
