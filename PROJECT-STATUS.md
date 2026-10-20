# MenuGit 项目状态与进度说明

> 本文件是 AI 协作交接文档：记录项目概况、已确认决策、当前进度与下一步计划，供后续 AI 会话（或新协作者）快速接续工作。**每次完成一个阶段性节点，应更新本文件。**
>
> 最后更新：2026-10-20 ｜ 当前范围：macOS 已构建、安装并通过后台验收；真实 Finder 目录路由、单实例参数转发与全部 P0 视图均已验证；Windows/Linux 由用户在其他环节推进

---

## 1. 项目概述

MenuGit 是跨平台轻量级 Git 桌面工具：安装后集成进系统文件管理器右键菜单（Windows 资源管理器 / macOS Finder / Ubuntu 24.04 GNOME Files），无需记忆命令即可完成提交、拉取、推送、分支、日志、放弃修改、解决冲突等日常 Git 操作。设计底线是"轻量"：不做 rebase/cherry-pick/stash/tag 等非核心功能，Git 配置与凭证完全复用系统 Git（PRD R2），不内置任何 git config 设置项。

- 产品需求：见 [docs/PRD-MenuGit.md](docs/PRD-MenuGit.md)（v0.3，功能已评审锁定）
- 技术方案：见 [docs/TechSpec-MenuGit.md](docs/TechSpec-MenuGit.md)（v1.0，选型已锁定）
- 交互原型：见 [docs/prototype.html](docs/prototype.html)（单文件，已通过 38 项 jsdom 自动化断言，交互细节以此为准）

## 2. 已确认的技术决策（不要再重新讨论）

| 项 | 决策 |
| --- | --- |
| 应用壳 | Tauri v2（Rust 薄核心 + 系统 WebView） |
| 前端 | Vue 3 + Vite + TypeScript + Element Plus + Pinia + SCSS |
| Git 能力 | 子进程调用系统 git CLI，**禁止引入 git2/libgit2** |
| Windows 右键 | COM Shell Extension DLL（Rust cdylib，动态显示分支名，Win11 走"显示更多选项"经典菜单） |
| macOS 右键 | FinderSync 扩展（Swift `.appex`，`menugit://` 深链交接，DMG） |
| Linux 右键 | python3-nautilus 扩展（Nautilus 46 新签名 `get_file_items(self, files)`） |
| 扩展 ↔ GUI | macOS 用 `menugit://<command>?path=…&file=…` 深链（沙盒会丢弃 argv）；Windows/Linux 用 `menugit <command> --path <dir> [--file <p>] [--url <u>]`。分支名由扩展直接解析 `.git/HEAD`（不 spawn git） |
| 单实例 | tauri-plugin-single-instance，二次拉起参数转发给现有实例 |
| HTTPS 凭据 | 应用内一次性配置，经 `git credential approve` 存入 macOS 钥匙串；网络命令只追加系统自带 osxkeychain helper 读取，令牌不进入命令行与诊断日志 |
| 平台基线 | Windows 10+ / macOS 12+ / **Ubuntu 24.04**（20.04 缺 webkit2gtk-4.1，明确不做兼容，后续如需适配重新开发） |
| 菜单形态 | 仓库内 7+1 项（提交/拉取/推送/分支/日志/放弃修改/解决冲突 + 设置），非仓库 2+1 项，一级菜单标题括号内显示当前分支名 |

## 3. 开发环境现状

当前执行环境为 macOS arm64；使用 Swift 6.4、Xcode 命令行工具、Rust stable 1.99、Node/npm 24/11。Windows 机器信息保留作历史记录，本次不在 Windows/Linux 推进或测试。

### 原 Windows 开发机（历史）

| 组件 | 状态 |
| --- | --- |
| Node / npm | v24.16.0 / 11.13.0 ✅ |
| git | 2.54.0.windows.1 ✅ |
| Rust | rustc / cargo 1.99.0（stable-x86_64-pc-windows-msvc）✅，装于 `%USERPROFILE%\.cargo` |
| MSVC | VS 2022 BuildTools + VCTools 工作负载 ✅（`C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools`） |
| 网络 | **必须走本机代理 `127.0.0.1:9847`**：rust-lang.org 直连会超时，清华/中科大镜像被 WAF 拦截；cargo 拉 crates.io 同样需要代理 |

常用命令模板（PowerShell）：

```powershell
# Rust 侧检查（在 src-tauri 目录）
$env:HTTPS_PROXY="http://127.0.0.1:9847"; $env:HTTP_PROXY="http://127.0.0.1:9847"; & "$env:USERPROFILE\.cargo\bin\cargo.exe" check

# 前端构建（项目根）
npm run build

# 桌面窗口开发调试（项目根，会开窗口）
npm run tauri dev
```

## 4. 里程碑与当前进度

原跨平台计划见 TechSpec §9。本轮按用户要求只推进 macOS，Windows 和 Ubuntu 留在其他环节。

| 里程碑 | 状态 | 说明 |
| --- | --- | --- |
| M1 GUI 骨架 + 提交窗口迁移 | ✅ 完成 | 前端 `npm run build` 通过 |
| M2 Rust Git 执行层与提交闭环 | ✅ 完成 | macOS 后台 `cargo check`、`cargo test` 和 `npm run build` 通过 |
| M3 Windows COM DLL | ⏸ 后续环节 | 本轮明确不处理 Windows |
| M4 Ubuntu Nautilus | ⏸ 后续环节 | 本轮明确不处理 Linux |
| M5 macOS FinderSync + DMG | ✅ 本地安装与加载通过 | 修正 Mach-O executable 入口和沙盒；应用已更新到 `/Applications`，系统注册、启用、实际后台加载与 DMG 校验通过 |
| macOS P0 操作流程 | ✅ 完成并通过后台验收 | 提交、拉取、推送、分支、日志、放弃修改、冲突、初始化/克隆、设置均连接真实 Tauri 命令；24 项 Rust 测试与 19 项 Finder 菜单测试通过 |
| macOS Finder 手工验收 / Developer ID 公证 | ⏳ 外部条件 | 真实右键点击拉起窗口仍需前台人工确认；正式分发还需 Developer ID Application 与公证凭据 |

## 5. 当前代码状态明细

### 5.1 工程结构

```
MenuGit/
├─ src/                        # Vue 前端
│  ├─ views/CommitView.vue     # 提交窗口：真实状态、差异、提交与冲突/分支入口
│  ├─ views/OperationsView.vue # 拉取、分支、日志、放弃、冲突、init/clone、设置
│  ├─ views/PushView.vue       # 手动推送与提交后的自动推送闭环
│  ├─ components/DiffPreview.vue
│  ├─ stores/session.ts        # 视图切换 + CLI 参数解析（commit/pull/push/... → ViewName）
│  ├─ stores/commit.ts         # 提交窗口状态（Tauri 使用真实仓库；浏览器预览使用 mock）
│  ├─ api.ts                   # Rust commands 的类型化 invoke 封装
│  └─ styles/theme.scss        # 从原型提取的设计令牌（:root 亮色 + [data-theme="dark"]）
├─ src-tauri/src/              # 【M2 新增 Rust 层】
│  ├─ main.rs                  # 入口：单实例 + CliArgs + 无窗口 Finder 排障 + 命令注册
│  ├─ finder.rs                # Finder 集成状态、后台注册、按用户操作修复启用
│  ├─ git.rs                   # git 子进程统一执行器（--no-pager -c core.quotepath=false、LC_ALL=C、超时/取消、错误结构）
│  ├─ repo.rs                  # R1 仓库发现 + .git/HEAD 分支解析 + porcelain v2 状态/领先落后解析
│  ├─ lock.rs                  # R3 每仓库内存写锁
│  ├─ settings.rs              # 薄设置（app data 目录 json）：语言/新增默认勾选/诊断开关
│  ├─ diag.rs                  # 诊断日志（默认关闭，写 app data/diag.log）
│  └─ ops/                     # status / diff / stage / sync(push,pull) / branch / logop / discard / conflict / initclone
├─ docs/                       # PRD、TechSpec、prototype.html
├─ extensions/macos/           # FinderSync、共用菜单生成器、沙盒 entitlements 与后台 Swift 回归测试
├─ scripts/                    # macOS 前置构建、无界面 DMG、沙盒菜单测试与安装后验收
└─ PROJECT-STATUS.md           # 本文件
```

### 5.2 已注册的 Tauri 命令（main.rs）

`get_cli_args`、设置/诊断命令、`get_finder_integration` / `repair_finder_integration`、仓库状态和差异、提交、push/pull、分支、日志详情和文件 diff、放弃修改、冲突解决、init/clone/cancel、Finder 定位目录。

### 5.3 验证结果与剩余限制

1. Rust `cargo check --locked` 通过；`cargo test --locked` 14 项通过，包括 Finder 安装路径/注册状态、提交选择隔离、放弃修改的暂存区/工作区还原、Git pathspec 字面路径、诊断 URL 凭证隐藏、冲突解析与“解析 → 写回 → 完成合并 / 中止合并”完整往返，以及本地裸仓库的 push → peer commit → pull → 分支 → 日志详情往返。
2. 前端 `tsc --noEmit` 与 `npm run build` 通过。生产包保留约 1.06 MB 的 JS chunk 体积警告（Element Plus 全量引入），不影响运行。
3. 最新 `npm run tauri:macos` 生成 arm64 `.app`（约 7 MiB）和 DMG；FinderSync 为 Mach-O **executable**，以 `NSExtensionMain` 为入口，最低 macOS 12.0，沙盒 entitlements 保留。打包自动检查可执行格式、入口、plist、权限、双方签名与无窗口状态命令；DMG checksum 有效。
4. `npm run test:findersync` 的 19 项沙盒菜单测试通过，覆盖普通目录、Git 仓库、仓库文件夹本身、仓库内文件/子目录、中文/空格文件名、目录空白处、冲突置灰、worktree、detached HEAD、坏元数据与动作参数。新增“文件引用 URL 与不可解析 ID 不会卡死菜单”和“在父目录中右键仓库文件夹时使用被点击项”两项回归。系统 FinderSync 框架的实际菜单序列化和解码动作分派验证 8 个操作、仓库文件夹点击与原始文件路径；启动器替身确保没有创建窗口或改变前台焦点。
5. 已重新构建并更新 `/Applications/MenuGit.app`，执行修复命令后注册与启用检查通过，Finder 实际加载最新扩展。`test:findersync:installed -- /Applications/MenuGit.app` 与真实项目目录路由验收通过；为清除此前扩展挂起留下的菜单连接，本轮重启过一次 Finder。最新报告位于 `src-tauri/target/finder-routing-check.log`。
6. 单实例转发已实测：先以提交视图启动，再强制启动第二个进程并传入日志参数，系统只保留一个实例，窗口正确切换到日志视图。`--file` 文件级右键参数也已验证会预选文件并加载差异。
7. 当前 DMG 为 ad-hoc 签名，不能作为已公证正式发行包；系统只发现 Apple Development 身份，没有 Developer ID Application 身份。
8. 设置中语言选项已持久化，但界面文案仍以中文为主；英文界面本地化尚未完成。

### 5.4 Finder 安装故障修复记录

用户安装上一版后 Finder 中没有 MenuGit。原因是扩展错误使用 `-emit-library -bundle`，缺少 App Sandbox，且 Swift 编译没有指定 macOS 12，生成了只适用于当前 SDK 版本的二进制。上一轮仅检查文件存在与签名，未检查系统能否注册或加载，因而漏检。

本轮改用 `-emit-executable -application-extension -target <arch>-apple-macosx12.0 -e _NSExtensionMain`，补全 plist 与沙盒，避免沙盒 HOME 误作监控目录；签名改为扩展与主应用分别签署，防止外层重签丢失扩展权限。后台菜单测试直接复用生产生成器，并新增真实安装与加载验收，防止同类问题再次进入 DMG。

### 5.5 已加载但当前目录没有菜单的后续修复

用户截图显示项目目录空白处右键仍没有 MenuGit，说明“进程已加载”的验收不足以证明菜单可用。控制器改为在 `super.init()` 后获取，监控范围改为真实账户主目录和 APFS Data 别名；修复后 Finder 实际发出当前项目目录的观察回调，已用路径指纹验证。

菜单动作改由扩展主对象接收，路径缓存在扩展内并通过 `tag` 找回。新增后台系统框架测试，直接调用系统菜单回调/序列化/解码分派链，验证完整操作列表与文件参数。测试用内部框架接口只编译到测试程序，发行扩展仍只用公开 API。不能再把“已注册、已启用、进程在运行”单独作为右键菜单验收结论。

### 5.6 2026-10-20 macOS 完整验收与修复记录

本轮按“仓库文件夹本身也能右键”的明确要求，移除了仓库发现对 `isDirectory` 的前置依赖，并补充目录判断的文件系统回退；新增“仓库文件夹本身使用仓库菜单”和“目标缺失时回退到选中项”两项沙盒测试。

同时补齐和修复了以下行为：

- 放弃修改现在同时还原暂存区与工作区，正确处理暂存新文件、重命名和未跟踪目录；新增 4 项测试。
- 推送 / 拉取统一规范化 `origin/`、`refs/heads/` 前缀并校验分支名；新建远端分支强制建立上游；合并进行中拦截其他写操作。
- 冲突编辑器改为内存暂存选择，全部冲突块选完自动标记已解决，可重新编辑；点击“完成合并提交”才统一写回并提交；新增“解析 → 写回 → 完成合并 / 中止合并”完整往返测试。
- 修复设置页首次打开时的暂时性死区错误（立即 watcher 早于 `settings` 声明执行）、分支页创建按钮初始误显示加载态、放弃修改页状态标签被拉伸三个 UI 问题。
- 窗口关闭改为隐藏而非销毁，Dock 重新打开可恢复；验证 Finder 连续右键依赖的单实例参数转发，第二个进程退出后只保留一个实例并正确切换视图。

验收方式：使用安装后的 `/Applications/MenuGit.app`，以 `open -g` 在后台逐个启动提交、拉取、分支、日志、放弃、冲突、初始化、克隆、设置、推送视图并截取窗口；额外验证 `--file` 预选与差异高亮、单实例转发。未进行真实右键点击和按钮点击，这两项仍属前台人工验收。最新 DMG 为 `src-tauri/target/release/bundle/dmg/MenuGit_0.1.0_aarch64.dmg`。

### 5.7 2026-10-20 右键菜单消失与扩展 CPU 失控修复

用户反馈两个现象：在父目录中右键 MenuGit 项目文件夹没有 MenuGit 菜单；进入项目后第一次有菜单，再次进入后消失。系统日志与诊断报告显示，扩展进程在 12:37:30–12:39:11 的 101 秒内消耗 90 秒 CPU（89%），物理内存从 17 MB 涨到 14.8 GB，全部堆栈都停在 Finder 的 `requestMenuItemsForTarget → menu(for:) → findRepository`，之后 Finder 不再发起菜单请求。

根因有两个：

1. `contextURL` 对 `contextualMenuForItems` 优先取 `targetedURL`（所在目录），导致在父目录右键仓库文件夹时落到非仓库目录。
2. Finder 可能传入 `file:///.file/id=…` 形式的文件引用 URL。`URL.deletingLastPathComponent()` 对这种 URL 不收敛，会不断生成 `/..`、`/../..`，`findRepository` 的父目录遍历因此永不结束，单次菜单请求永久挂起并持续分配内存。

修复内容：

- 新增 `canonicalFileURL`，先用 `NSURL.filePathURL` 把引用 URL 转成路径 URL，再基于 `NSString` 字符串路径向上遍历；父路径必须严格缩短，并设置 128 次上限，异常 URL 最多降级为普通菜单，绝不再无限循环。
- `contextualMenuForItems` 改为优先使用 `selectedItemURLs().first`，空白处菜单仍使用 `targetedURL`。
- 新增文件引用 URL、不可解析文件 ID、父目录中右键仓库文件夹的系统菜单序列化回归测试，Finder 测试增至 19 项。
- 重新构建安装后执行 `--repair-finder-extension` 恢复注册，并重启 Finder 清除挂起连接；扩展进程恢复为空闲状态。

结论：不能只验证“扩展进程存在/目录观察回调到达”。菜单生成路径必须对有界时间与异常输入做防御，且真实右键故障要结合 `log show` 与 `/Library/Logs/DiagnosticReports/*.cpu_resource.diag` 检查扩展是否被单次请求拖死。

### 5.8 2026-10-20 点击“提交”却打开空仓库页的深链修复

现象：在 Finder 中对仓库或文件点击“提交…”后，主应用显示“打开 Git 仓库”空页面，尽管本机 Git 已配置且仓库存在远端。

根因：Finder 扩展运行在 App Sandbox 中，`NSWorkspace.OpenConfiguration.arguments` 传入的 argv 会被 LaunchServices 静默丢弃。单实例插件把二次启动转发给已运行实例时只能转出空参数，前端 `parseCliArgs([])` 得到没有 `path` 的默认提交请求，于是渲染仓库选择页。使用与扩展同权限的沙盒探针复现：普通进程传入相同 argv 正常，沙盒进程只收到可执行文件路径。

修复：

- 扩展改用自定义 URL `menugit://<命令>?path=…&file=…`，通过 `NSWorkspace.open([url], withApplicationAt:)` 明确打开自身应用包；仅提交、日志、放弃修改携带 `file`。
- 应用 `Info.plist` 增加 `CFBundleURLTypes`（scheme `menugit`），主进程在 `RunEvent::Opened` 中解析 URL 并复用原有 CLI 路由；查询值按字面量百分号解码，路径中的 `+` 不会被当作空格。
- 前端忽略空 `cli-args` 事件与空 `get_cli_args` 结果；普通 Dock/访达二次启动只把窗口带回前台，不再清空当前仓库。
- 新增 3 项 Rust URL 解析测试（中文/空格/`+`、非法 scheme/命令、空值与未知参数），Swift 测试改为校验深链构造；17 项 Rust、19 项 Finder 测试全部通过。

验收：使用与 Finder 扩展同权限的 App Sandbox 辅助程序发起真实深链调用。冷启动（应用未运行）直接进入提交页并选中 `.gitignore` 显示差异；已运行时切换到日志视图正常；随后无参数二次启动保持日志视图，未回到空仓库页。安装包已重建、签名、安装并修复扩展注册，`check-macos-bundle` 新增 `menugit` URL scheme 断言。

### 5.9 2026-10-20 HTTPS 推送凭据配置

现象：macOS 推送 HTTPS 远端时报 `fatal: could not read Username for 'https://github.com': terminal prompts disabled`。应用以 `GIT_TERMINAL_PROMPT=0` 运行，系统原本没有保存 GitHub 凭据，git 无法弹出终端提示，因此每次推送都会失败。

修复：

- 推送 / 拉取出现 `AuthRejected` 时显示“配置 HTTPS 凭据”按钮。弹窗读取 origin 的 HTTPS host，填写用户名与 GitHub Personal Access Token（GitHub 已不接受账户密码），保存后自动重试。
- 凭据经 stdin 调用 `git credential approve` 写入 macOS 钥匙串；写入前先清空 helper 链，避免全局 `store` 等助手同时收到明文令牌。写入后回读校验，失败会明确提示。
- push / pull / clone 的网络命令追加系统自带 osxkeychain helper 读取凭据，不修改用户全局 git 配置；令牌不进入命令行、URL、仓库文件或诊断日志。
- 新增 6 项 Rust 测试：HTTPS 远端解析（用户信息 / 端口 / 令牌前缀）、非 HTTPS 拒绝、凭据注入防护、store helper 往返、仓库 origin 读取、认证错误分类。

验收：24 项 Rust 测试通过；使用假主机完成 osxkeychain 写入、读取、删除探针；验证清空 helper 链后全局 `store` 不会收到凭据。包含该功能的构建已安装到 `/Applications/MenuGit.app`，Finder 扩展注册与加载复检通过，DMG 重新生成。真实 GitHub 推送需要用户用自己的 PAT 在前台完成一次，仓库与测试代码不持有任何账户凭据。



1、后台安装、加载、目录路由、菜单序列化、深链转发与全部视图渲染已验证；真实右键点击拉起窗口与界面按钮交互属于前台人工验收。
2、如需公开分发，配置 Developer ID Application、签名环境变量与 Apple 公证凭据后重建 DMG。
3、补齐英文界面文案和语言切换的即时生效。
4、Windows/Linux 继续由用户指定的其他环节推进，不属于本轮 macOS 范围。

## 7. 工作约定（给后续 AI 的红线）

- 不引入 git2/libgit2；git 一律走 CLI，命令规范严格遵守 TechSpec §3.2 表格。
- 写操作必须过 lock.rs（R3）；破坏性操作前端二次确认（R4）。
- 凭证/代理/pull 策略等 git 配置一概不传参，完全复用系统 Git（R2）。
- 菜单扩展（M3+）内零网络请求、零子进程、异常全吞掉降级，绝不能拖垮文件管理器进程。
- 代码注释用中文；不运行 `npm run tauri dev` 留后台进程（验证窗口时告知用户即可）。
- 验证手段：Rust 侧 `cargo check`，前端侧 `npm run build`；环境问题先查代理。
- 完成节点后更新本文件 §4/§5/§6，重大决策写入 docs/TechSpec-MenuGit.md 并同步此文件 §2。
