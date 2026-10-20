# macOS 构建与 Finder 扩展

## 后台构建

在 macOS 本机运行：

```sh
npm run tauri:macos
```

命令会编译 Vue 前端、Swift FinderSync 扩展和 Tauri 应用，输出：

- `.app`：`src-tauri/target/release/bundle/macos/MenuGit.app`
- DMG：`src-tauri/target/release/bundle/dmg/MenuGit_<version>_<arch>.dmg`

DMG 使用 `hdiutil create` 生成，不挂载镜像、不启动应用，也不运行会操作 Finder 的 AppleScript。

## Finder 扩展

把 `MenuGit.app` 拖入“应用程序”后，首次打开应用会后台注册随包 Finder 扩展。在应用设置页检查“访达集成”，点击“修复访达右键菜单”即可重新注册并启用；也可以在系统设置 → 通用 → 登录项与扩展 → Finder 扩展中启用 MenuGit。

扩展位于 `Contents/PlugIns/MenuGitFinderSync.appex`，主文件必须是带 `NSExtensionMain` 入口的 Mach-O executable。它在 App Sandbox 中监控真实账户主目录（通过 `getpwuid` 获取，包含 APFS Data 路径别名）、`/Volumes` 和 `/private/tmp`，只读取仓库元数据，不运行 Git 或修改文件。不能用 `NSHomeDirectory()` 指定监控根目录，因为它在沙盒内指向扩展容器；Finder 控制器必须在 `super.init()` 完成后获取。

右键菜单从目标路径向上查找 `.git`，读取当前分支，然后以 `menugit://<命令>?path=…&file=…` 自定义 URL 请求主应用。Finder 扩展运行在 App Sandbox 中，通过 `NSWorkspace.OpenConfiguration.arguments` 传入的 argv 会被 LaunchServices 静默丢弃，单实例插件只能转发空参数，主应用因此退回仓库选择页，所以参数改由 URL 携带。`Info.plist` 的 `CFBundleURLTypes` 声明 `menugit` scheme；扩展用 `withApplicationAt:` 明确打开自身所在的应用包，不依赖 scheme 的默认处理器，避免打开另一份拷贝。主应用在 `RunEvent::Opened` 中解析查询参数并复用原有 CLI 路由；查询值按字面量百分号解码，路径中的 `+` 不会被当作空格。仓库文件夹本身、仓库内文件和子目录都会进入仓库菜单；Finder 沙盒中资源属性查询失败时退回文件系统判断目录类型。空白处右键使用当前目录，不会复用先前选中的文件。

本机开发包默认使用 ad-hoc 签名，首次打开时 macOS 可能要求用户在隐私与安全设置中确认。正式分发需要 Developer ID Application 证书与 Apple 公证凭据；构建脚本支持通过 `APPLE_SIGNING_IDENTITY` 传入签名身份。

## HTTPS 凭据（macOS 钥匙串）

GitHub 的 HTTPS 远端在系统没有可用凭据时，git 在 `GIT_TERMINAL_PROMPT=0` 下只会报 `could not read Username ...: terminal prompts disabled`。应用在推送或拉取认证失败时显示“配置 HTTPS 凭据”入口，只需配置一次：

- 只支持 HTTPS 远端；SSH 远端会提示改用 SSH 密钥或切换远端地址。
- GitHub 已不接受账户密码，必须使用 Personal Access Token（classic，勾选 `repo` 权限）作为密码。
- 用户名和令牌通过 stdin 交给 `git credential approve` 写入 macOS 钥匙串；写入前清空 helper 链，避免全局 `store` 等助手同时收到明文令牌。保存后会回读校验并自动重试。
- 应用发起的 push / pull / clone 追加系统自带的 `credential.helper=osxkeychain` 读取凭据，不修改用户的全局 git 配置；令牌不进入命令行、URL、仓库文件或诊断日志。

钥匙串读写可用假主机做无痕验证：

```sh
printf 'protocol=https\nhost=menugit-probe.invalid\nusername=probe\npassword=probe\n\n' | git -c credential.helper=osxkeychain credential approve
printf 'protocol=https\nhost=menugit-probe.invalid\n\n' | git -c credential.helper=osxkeychain credential fill
printf 'protocol=https\nhost=menugit-probe.invalid\nusername=probe\npassword=probe\n\n' | git -c credential.helper=osxkeychain credential reject
```

## 后台验证范围

菜单回归测试不会启动应用窗口或改变前台焦点：

```sh
npm run test:findersync
```

19 项测试直接复用扩展生产代码，并在真实 App Sandbox 中验证仓库/普通目录、仓库文件夹本身、仓库内文件与子目录、中文与空格文件名、worktree、冲突菜单、目录空白处上下文和深链参数。新增用例覆盖文件引用 URL（`file:///.file/id=…`）、不可解析文件 ID 的快速降级，以及“在父目录中右键仓库文件夹时使用被点击项”。其中三项通过当前系统的 FinderSync 框架调用菜单回调、生成系统菜单字典并分派解码后的动作，验证 8 个操作的标题、selector、tag、文件夹与文件参数。仅测试时替换应用启动器，因此不会打开主应用窗口。

菜单目标先归一化为路径 URL，再以字符串路径向父目录查找仓库；父路径必须严格缩短并设有上限。Finder 可能传入文件引用 URL，其 `deletingLastPathComponent()` 会不断产生 `/..`，不能直接用于遍历，否则一次菜单请求就会让扩展持续占用 CPU 和内存。

菜单动作由扩展主对象接收，原始路径保留在扩展内部，通过系统可传输的 `tag` 查找，不把自定义 `NSObject` 放入跨进程菜单数据。测试用的系统内部框架接口只存在于测试文件，发行应用使用公开 FinderSync API。

打包阶段还自动验证可执行入口、最低系统版本、扩展权限与外层签名，避免“文件存在但系统不能加载”的无效安装包。

已安装应用支持无窗口的检测和修复：

```sh
/Applications/MenuGit.app/Contents/MacOS/menugit --finder-extension-status
/Applications/MenuGit.app/Contents/MacOS/menugit --repair-finder-extension
node scripts/check-macos-bundle.mjs /Applications/MenuGit.app --installed
npm run test:findersync:installed -- /Applications/MenuGit.app
```

修复命令只操作 MenuGit 扩展的注册和启用状态，不启动主应用窗口或重启 Finder。验收脚本要求系统选择的是当前安装路径，并检查 Finder 扩展进程确实在运行。实际点击菜单拉起可见窗口属于前台验收，不在后台测试中执行。

如果某个目录的右键菜单缺失，并且该目录已经在 Finder 中打开，可以进一步验证真实目录路由：

```sh
npm run test:findersync:installed -- /Applications/MenuGit.app --observed-path /Users/<用户名>/Code/personal/MenuGit
```

这个检查只重新加载 MenuGit 自己的扩展，等待 Finder 的 `beginObservingDirectory` 事件，并匹配目标路径的 SHA-256 指纹，不切换窗口或替用户打开目录。没有收到匹配事件会报错，不能把“扩展进程已启动”当成“右键菜单可用”。记录保存在 `src-tauri/target/finder-routing-check.log`。

Apple 的[扩展开发说明](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionCreation.html)说明 macOS 扩展的沙盒配置；[Finder Sync 文档](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)说明系统如何实例化扩展和传递菜单上下文。
