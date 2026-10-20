import AppKit
import Darwin
import FinderSync

@_silgen_name("sandbox_check")
private func sandboxCheck(_ pid: pid_t, _ operation: UnsafePointer<CChar>?, _ flags: Int32) -> Int32

@main
struct FinderMenuTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Missing fixture path") }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let builder = MenuGitFinderMenu()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        func test(_ name: String, _ run: () -> Void) {
            run()
            passed += 1
            print("PASS \(name)")
        }
        func submenu(_ path: String) -> NSMenu {
            builder.makeMenu(for: fixture.appendingPathComponent(path)).items[0].submenu!
        }
        func action(_ menu: NSMenu, _ command: String) -> MenuGitAction {
            menu.items.compactMap { builder.action(for: $0) }.first { $0.command == command }!
        }
        test("Sandbox is active; principal class is discoverable") {
            check(sandboxCheck(getpid(), nil, 0) == 1, "Test process is not sandboxed")
            check(NSClassFromString("MenuGitFinderSyncExtension") != nil, "Missing extension principal class")
        }
        test("Observed roots cover actual user files, not sandbox home") {
            let paths = Set(MenuGitFinderMenu.observedDirectories.map(\.path))
            check(paths.contains("/Volumes") && paths.contains("/private/tmp"), "Missing volume or temporary roots")
            let home = String(cString: getpwuid(getuid())!.pointee.pw_dir)
            check(paths.contains(home), "Missing real account home")
            check(!paths.contains(NSHomeDirectory()), "Monitoring sandbox container")
        }
        test("Non-repository has init, clone and settings") {
            let menu = submenu("plain")
            check(menu.items.compactMap { builder.action(for: $0)?.command } == ["init", "clone", "settings"], "Wrong plain menu")
        }
        test("Repository branch and complete menu are readable inside sandbox") {
            let menu = builder.makeMenu(for: fixture.appendingPathComponent("repo/sub"))
            check(menu.items[0].title == "MenuGit (feature/menu-fix)", "Sandbox cannot read .git/HEAD")
            check(menu.items[0].submenu!.items.compactMap { builder.action(for: $0)?.command }
                  == ["commit", "pull", "push", "branch", "log", "discard", "conflict", "settings"], "Missing repository operations")
        }
        test("Repository folder itself uses the repository menu") {
            let menu = builder.makeMenu(for: fixture.appendingPathComponent("repo"))
            check(menu.items[0].title == "MenuGit (feature/menu-fix)", "Repository root was treated as a file or plain folder")
            let commands = menu.items[0].submenu!.items.compactMap { builder.action(for: $0)?.command }
            check(commands == ["commit", "pull", "push", "branch", "log", "discard", "conflict", "settings"], "Wrong repository root menu")
            check(action(menu.items[0].submenu!, "commit").file == nil, "Repository root should not pass a file argument")
        }
        test("Item context falls back to selection when target is missing") {
            let repository = fixture.appendingPathComponent("repo")
            check(FinderSyncExtension.contextURL(for: .contextualMenuForItems, selected: [repository], targeted: nil) == repository, "Missing item fallback")
        }
        test("Selected repository folder wins over its containing directory") {
            let repository = fixture.appendingPathComponent("repo")
            let containing = repository.deletingLastPathComponent()
            check(FinderSyncExtension.contextURL(for: .contextualMenuForItems, selected: [repository], targeted: containing) == repository, "Repository folder click lost its target")
        }
        test("File reference URLs resolve to repository or degrade promptly") {
            guard let reference = (fixture.appendingPathComponent("repo") as NSURL).fileReferenceURL() else {
                fatalError("Cannot create file reference URL")
            }
            check(builder.makeMenu(for: reference).items[0].title == "MenuGit (feature/menu-fix)", "Resolvable reference URL lost repository")
            let unresolved = URL(string: "file:///.file/id=6571367.2")!
            let started = Date()
            let menu = builder.makeMenu(for: unresolved)
            check(Date().timeIntervalSince(started) < 2, "Reference URL traversal did not terminate promptly")
            check(menu.items[0].title == "MenuGit", "Unresolved reference URL should degrade to a normal menu")
        }
        test("Deep link preserves spaces and Unicode only for file commands") {
            let menu = submenu("repo/sub/测试 file.txt")
            @MainActor func query(_ command: String) -> [String: String] {
                let url = action(menu, command).deepLinkURL!
                let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                check(components.scheme == "menugit" && components.host == command, "Wrong request URL command")
                return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            }
            for command in ["commit", "log", "discard"] {
                let items = query(command)
                check(items["path"] == fixture.appendingPathComponent("repo").path, "Wrong request URL repository")
                check(items["file"] == "sub/测试 file.txt", "Wrong request URL file")
            }
            check(query("push")["file"] == nil, "Push should not pass a file")
            check(action(submenu("repo"), "commit").deepLinkURL?.absoluteString.hasPrefix("menugit://commit?path=") == true, "Repository root request URL is malformed")
        }
        test("Background menu uses target directory instead of old selection") {
            let selected = fixture.appendingPathComponent("repo/sub/测试 file.txt")
            let target = fixture.appendingPathComponent("plain")
            check(FinderSyncExtension.contextURL(for: .contextualMenuForContainer, selected: [selected], targeted: target) == target, "Wrong background context")
            check(FinderSyncExtension.contextURL(for: .contextualMenuForItems, selected: [selected], targeted: target) == selected, "Clicked item should take precedence over its directory")
            check(FinderSyncExtension.contextURL(for: .contextualMenuForSidebar, selected: [selected], targeted: target) == target, "Sidebar missing")
            check(FinderSyncExtension.contextURL(for: .contextualMenuForContainer, selected: [selected], targeted: nil) == nil, "Unexpected background fallback")
        }
        test("Conflict action remains disabled after AppKit validates menu") {
            let menu = submenu("repo")
            menu.update()
            check(!menu.items.first { builder.action(for: $0)?.command == "conflict" }!.isEnabled, "Conflict incorrectly enabled")
        }
        test("Merge in progress enables conflict action") {
            check(submenu("merging").items.first { builder.action(for: $0)?.command == "conflict" }!.isEnabled, "Merge action disabled")
        }
        test("Worktree relative gitdir resolves branch") {
            check(builder.makeMenu(for: fixture.appendingPathComponent("worktree")).items[0].title == "MenuGit (worktree-test)", "Worktree metadata not found")
        }
        test("Detached HEAD uses short commit hash") {
            check(builder.makeMenu(for: fixture.appendingPathComponent("detached")).items[0].title == "MenuGit (1234567)", "Wrong detached title")
        }
        test("Malformed git marker degrades to normal directory") {
            check(builder.makeMenu(for: fixture.appendingPathComponent("malformed")).items[0].title == "MenuGit", "Malformed .git recognized as repo")
        }
        test("Native FinderSync returns serialized container menu including action tags") {
            let target = fixture.appendingPathComponent("repo", isDirectory: true)
            let payload = MenuGitRequestSerializedMenu(FinderSyncExtension.self, target, [], FIMenuKind.contextualMenuForContainer.rawValue, false) as? [[String: Any]]
            check(payload?.count == 1, "System rejected our menu")
            check(payload?[0]["title"] as? String == "MenuGit (feature/menu-fix)", "Wrong system menu title")
            check((payload?[0]["tag"] as? Int ?? 0) > 0, "Parent menu has no valid tag")
            check(class_getInstanceMethod(FinderSyncExtension.self, NSSelectorFromString("submenuAction:")) != nil, "Parent menu selector is not handled by the principal")
            let submenu = payload?[0]["submenu"] as? [[String: Any]] ?? []
            let actions = submenu.filter { $0["commandID"] != nil }
            check(actions.count == 8, "System omitted menu actions")
            check(actions.allSatisfy { $0["commandID"] as? String == "openMenuAction:" && ($0["tag"] as? Int ?? 0) > 0 }, "Missing system action tags")
            check(actions.first { ($0["title"] as? String) == "解决冲突…" }?["enabled"] as? Bool == false, "System enabled conflict action")
        }
        test("Native FinderSync returns repository menu for folder clicked inside parent") {
            let repository = fixture.appendingPathComponent("repo", isDirectory: true)
            let payload = MenuGitRequestSerializedMenu(FinderSyncExtension.self, fixture, [repository], FIMenuKind.contextualMenuForItems.rawValue, false) as? [[String: Any]]
            check(payload?.first?["title"] as? String == "MenuGit (feature/menu-fix)", "Clicked repository folder resolved to its containing directory")
        }
        test("Native FinderSync dispatches decoded file action to principal without opening GUI") {
            let original = MenuGitFinderMenu.applicationLauncher
            defer { MenuGitFinderMenu.applicationLauncher = original }
            var request: URL?
            MenuGitFinderMenu.applicationLauncher = { action, _ in request = action.deepLinkURL }
            let target = fixture.appendingPathComponent("repo/sub/测试 file.txt")
            let payload = MenuGitRequestSerializedMenu(FinderSyncExtension.self, target, [target], FIMenuKind.contextualMenuForItems.rawValue, true) as? [[String: Any]]
            check(payload?.count == 1, "No serialized file menu")
            let components = request.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            let items = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            check(components?.scheme == "menugit" && components?.host == "commit", "Native action dispatch lost the request command")
            check(items["path"] == fixture.appendingPathComponent("repo").path, "Native action dispatch lost the cached repository")
            check(items["file"] == "sub/测试 file.txt", "Native action dispatch lost the file path")
        }
        test("Containing app path is resolved without launching GUI or changing focus") {
            let plugin = URL(fileURLWithPath: "/Applications/MenuGit.app/Contents/PlugIns/MenuGitFinderSync.appex")
            check(MenuGitFinderMenu.containingApplication(for: plugin).path == "/Applications/MenuGit.app", "Wrong containing app")
            check(NSApp?.windows.isEmpty ?? true, "Test created a window")
            check(NSWorkspace.shared.frontmostApplication?.processIdentifier == frontmost, "Test changed foreground app")
        }
        print("Finder menu tests: \(passed) passed; sandbox active; no application launch, windows, or focus changes")
    }
}
