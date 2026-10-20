# MenuGit 技术方案

> 装上就能用，右键就 Git —— 技术选型与实现方案。

| 版本 | 日期 | 配套文档 | 状态 |
| --- | --- | --- | --- |
| v1.0 | 2026-10-13 | [PRD-MenuGit.md](./PRD-MenuGit.md)（v0.3） | 选型已评审锁定 |

---

## 1. 选型结论

| 层 | 选型 | 决策理由 |
| --- | --- | --- |
| 应用壳 | **Tauri v2**（Rust 核心 + 系统 WebView） | 安装包约 10MB、内存占用低，契合"轻量"定位；Windows 依赖 WebView2、Ubuntu 24.04 自带 WebKitGTK 4.1，系统级保障 |
| 前端 | **Vue 3 + Vite + Element Plus + SCSS** | 复用既有技术栈与原型交互逻辑 |
| Git 能力 | **调用系统 git CLI** | 落实 PRD R2：配置/凭证/代理全部复用系统 Git，不引入 libgit2 重复实现凭证体系 |
| Windows 菜单 | **COM Shell Extension DLL**（Rust cdylib） | 唯一能动态显示"分支名"的通用方案；Win10/Win11 经典菜单全覆盖 |
| macOS 菜单 | **FinderSync 扩展**（Swift） | Apple 官方唯一正规右键扩展途径，菜单可动态构建 |
| Ubuntu 菜单 | **python3-nautilus 扩展** | Nautilus 46（GNOME 46）官方扩展机制，实现最轻 |
| 扩展 ↔ GUI 通信 | **CLI 参数拉起进程** | 无常驻后台服务；分支名由扩展直接读 `.git/HEAD`，毫秒级 |
| 单实例 | tauri-plugin-single-instance | 重复点击菜单时参数转发给现有实例，避免多窗口 |

平台基线（低于基线不做兼容承诺，安装时可提示）：

| 平台 | 基线 | 关键系统依赖 |
| --- | --- | --- |
| Windows | Windows 10+ | WebView2 Runtime（安装器自动补装） |
| macOS | macOS 12+ | 系统自带 WKWebView |
| Linux | **Ubuntu 24.04**（GNOME 46 / Nautilus 46） | libwebkit2gtk-4.1、python3-nautilus（deb 声明依赖，apt 自动安装） |

> 已评审放弃的备选：Electron（体积/内存与轻量定位矛盾）；Win11 IExplorerCommand + MSIX（不覆盖 Win10，仅作后续增强）；Ubuntu 20.04（官方源无 webkit2gtk-4.1/libsoup3，Tauri v2 无法运行，且标准支持已于 2025-04 结束，**不做兼容，后续如需适配则重新评估 Linux 技术栈**）。

## 2. 系统架构

### 2.1 组件与进程模型

```
文件管理器进程（Explorer / Finder / Nautilus）
└─ MenuGit 菜单扩展（进程内加载）
   ├─ 弹出菜单时：直接读 <repo>/.git/HEAD → 显示 "MenuGit (main)"
   └─ 点击菜单项：spawn 主程序 CLI 参数
        ↓  menugit commit --path <dir>
MenuGit 主程序（Tauri v2，单实例，参数转发）
├─ Vue 3 界面（WebView）：提交 / 拉取 / 推送 / 分支 / 日志 / 冲突 / 设置
└─ Rust 薄核心：仓库发现 → 并发锁 → spawn git → 解析输出 → 事件回传
      ↓  子进程
   系统 git（配置、凭证、代理全部复用系统）
```

要点：

- 菜单扩展内**不 spawn git**：分支名直接解析 `.git/HEAD`（`ref: refs/heads/<name>`，detached HEAD 时显示短 hash），保证菜单秒开且不拖慢文件管理器。
- 扩展内代码必须防御性编写：任何异常吞掉并降级为"无分支名显示"，绝不能让 Explorer/Finder/Nautilus 崩溃。
- 主程序是唯一执行 git 的进程，扩展只负责"显示 + 拉起"。

### 2.2 仓库结构

```
MenuGit/
├─ src/                      # Vue 3 前端（页面组件、Pinia 状态、差异/冲突视图）
├─ src-tauri/                # Rust 核心（Tauri 命令、git 执行层、仓库发现、锁）
├─ extensions/
│  ├─ windows/               # COM Shell Extension DLL（Rust cdylib）
│  ├─ macos/                 # FinderSync 扩展（Swift，打包为 .appex）
│  └─ linux/                 # python3-nautilus 扩展脚本（随 deb 分发）
├─ docs/                     # PRD、技术方案、原型
└─ .github/workflows/        # 三平台 CI 构建
```

## 3. Rust 核心设计（src-tauri）

### 3.1 模块划分

| 模块 | 职责 |
| --- | --- |
| `repo.rs` | R1 仓库发现（向上查找 `.git`）、读取当前分支/上游/领先落后计数 |
| `lock.rs` | R3 并发写锁：内存级 per-repo 忙标记，写操作互斥，冲突未解决时拦截其他写操作 |
| `git.rs` | 统一的 git 子进程执行器：参数拼装、超时控制、取消（kill 进程树）、stderr 捕获 |
| `ops/*` | 各功能命令实现：status / diff / commit / push / pull / branch / log / discard / conflict / init / clone |
| `settings.rs` | 薄设置持久化（语言、新增默认勾选、诊断日志开关），不含任何 git config 项 |
| `diag.rs` | 诊断日志（R6）：记录 git 命令、退出码、耗时，默认关闭 |
| `ipc.rs` | CLI 参数解析 + 单实例转发（tauri-plugin-single-instance） |

### 3.2 Git 命令规范

所有命令固定追加 `--no-pager -c core.quotepath=false`，输出按 UTF-8 解析。关键映射：

| 功能 | 命令 |
| --- | --- |
| 状态与分支信息 | `git status --porcelain=v2 --branch -z`（勾选/冲突/领先落后一并解析） |
| 差异预览 | 已跟踪：`git diff --no-color [--cached] -- <file>`；未跟踪：`git diff --no-color --no-index /dev/null <file>` |
| 暂存勾选 | 修改/删除/未跟踪统一 `git add -A -- <paths>`；提交 `git commit --only -F - -- <paths>`（信息走 stdin，避免转义问题，并确保未勾选但已暂存的文件不会混入本次提交） |
| 推送 | `git push origin <branch>`；新建远端分支 `git push -u origin <branch>` |
| 拉取 | `git pull`（遵循系统 pull 策略，不干预）；无上游时 `git pull origin <b>` 并记住上游 |
| 分支 | 列表 `git branch --format=...` / `git branch -r`；切换 `git switch`；新建 `git switch -c`；检出远端 `git switch -t origin/<b>` |
| 日志 | `git log --format=%H|%h|%s|%an|%at|%D -n 200 [--all] [-- <path>]`，滚动加载 `--skip` |
| 放弃修改 | 已跟踪 `git restore -- <paths>`；未跟踪 `git clean -f -- <paths>` |
| 冲突检测 | porcelain 状态位（UU/AA/DD/AU/UA/DU/UD）+ `.git/MERGE_HEAD` 存在性 |
| 解决冲突 | 写回结果文件后 `git add <file>`；完成合并 `git commit -F -`；中止 `git merge --abort` |
| 初始化 / 克隆 | `git init`；`git clone <url> <dir> --progress`（进度从 stderr sideband 解析） |

凭证、代理、diff 工具、pull 策略等一律不传参，完全交给系统 Git 配置（R2）。

### 3.3 冲突解决器

1. 拉取冲突后，读取工作区文件内 git 生成的冲突标记（`<<<<<<<` / `=======` / `>>>>>>>`），解析为结构化冲突块列表（本地段 / 远端段）。
2. 前端渲染左右并列对比 + 三选一（采用本地 / 采用远端 / 保留双方 = 顺序保留两段），实时预览合并结果；全程用户不接触标记文本。
3. 全部块选定后重组写回文件 → `git add` → 标记已解决；全部文件解决后启用"完成合并提交"，信息自动生成 `Merge branch ...`；"中止合并"二次确认后 `git merge --abort`（R4）。

### 3.4 长操作与反馈

- clone / pull / push 等网络操作异步执行：进度经 Tauri 事件推送到前端；提供取消（终止整个进程树）。
- 每个仓库同一时刻只允许一个写操作（R3），前端按钮态与后端锁双重拦截。

## 4. 前端设计（src）

- 页面与 PRD 功能一一对应，单窗口多视图（无路由跳转感，贴近原型）：`提交（主窗口）` `推送面板` `拉取面板` `分支` `日志` `放弃修改` `冲突解决` `初始化/克隆` `设置`。
- 状态管理用 Pinia：`repoStore`（状态/分支/锁）、`commitStore`（勾选、过滤、提交信息——保证子面板返回后无损恢复）。
- 交互闭环照搬已验证原型：提交成功 → 自动弹推送；推送取消 → 工作区干净则关闭、有剩余则回提交窗口；分支窗口操作完自动返回提交窗口。
- 三主题样式随系统（win / mac / ubuntu），Element Plus 变量覆盖实现；图标统一内联 SVG（项目既有结论）。
- Tauri invoke 封装为统一的 `api.ts`，错误对象统一含 `{ kind, message, stderr }`，按 R5 呈现可读原因 + 可展开原始输出。

## 5. 三平台右键菜单集成

### 5.1 Windows：COM Shell Extension DLL（extensions/windows）

- 形态：Rust `cdylib`，用 windows-rs 实现 `IContextMenu` / `IShellExtInit` 进程内 COM 组件（TortoiseGit 同款机制）。
- 注册：安装器写 **HKCU\Software\Classes**（免管理员权限，匹配 Tauri NSIS 默认 per-user 安装）：
  - `*\shellex\ContextMenuHandlers\MenuGit`（文件）
  - `Directory\shellex\ContextMenuHandlers\MenuGit`（目录）
  - `Directory\Background\shellex\ContextMenuHandlers\MenuGit`（目录空白处）
- `QueryContextMenu`：按 R1 判定仓库 → 动态构建 "MenuGit (main)" 一级子菜单，7+1 或 2+1 项；无冲突时"解决冲突"置灰。
- `InvokeCommand`：以 CLI 参数拉起主程序（`ShellExecute`），不阻塞 Explorer。
- Win11 表现：经典菜单（"显示更多选项"内），与 TortoiseGit 现状一致；新版菜单的 IExplorerCommand 支持列为后续增强，不在 P0。
- 稳定性红线：DLL 内不做网络/不做大目录扫描、异常全部吞掉、分支读取带缓存（按 `.git/HEAD` mtime）；注册表提供"禁用扩展"开关用于排障。

### 5.2 macOS：FinderSync 扩展（extensions/macos）

- Swift 实现 `FIFinderSync`，以 `NSExtensionMain` 为入口编译成 Mach-O **executable**，打包为 `MenuGitFinderSync.appex` 并嵌入主 App 的 `Contents/PlugIns/`；不可编译为动态 bundle。编译目标和 plist 均明确 macOS 12.0。
- 扩展启用 App Sandbox，并只读访问用户目录、挂载卷和测试临时目录。监控 `getpwuid` 返回的真实账户主目录及 APFS Data 别名、`/Volumes`、`/private/tmp`，不使用沙盒内指向扩展容器的 `NSHomeDirectory()`；控制器在 `super.init()` 后获取。
- `menu(for:)` 每次右键动态构建仓库菜单或入口菜单；分支名直接解析 `.git/HEAD`，支持 `.git` 文件指向的 worktree 元数据，不在 Finder 扩展内运行 Git 子进程。
- 菜单动作 selector 由扩展主对象接收，系统菜单通过 `tag` 对应扩展内缓存的路径，避免跨进程传输自定义 `representedObject`。点击后通过 `NSWorkspace.openApplication` 向主程序传递 `<command> --path <dir> [--file <p>]` 参数；单实例机制承接重复拉起。
- `npm run tauri:macos` 在 macOS 本机编译前端和 FinderSync，再生成 `.app`、签名校验和拖拽式 DMG。DMG 由 `hdiutil create` 无界面生成，不运行默认 DMG 脚本的 Finder AppleScript。
- 扩展与应用分别从内向外签名，保留扩展的沙盒 entitlements；本地无 Apple 签名身份时使用 ad-hoc 签名。正式分发需要 `APPLE_SIGNING_IDENTITY` Developer ID Application、Apple 公证凭据和公证流程。
- 主应用启动时后台注册随包扩展，保留用户的启用/禁用选择；设置页提供状态与“修复访达右键菜单”按钮，按用户操作调用 `pluginkit` 注册并启用。无窗口 CLI `--finder-extension-status` / `--repair-finder-extension` 用于后台排障。
- `npm run test:findersync` 在真实沙盒中测试菜单和仓库路径，并通过系统框架验证菜单序列化和原始动作分派（应用启动器替身保证后台测试）。打包脚本检查 Mach-O 入口、最低版本、沙盒签名和无窗口 CLI。安装后的 `node scripts/check-macos-bundle.mjs /Applications/MenuGit.app --installed` 要求系统已注册、已启用且 Finder 已实际启动扩展进程；`test:findersync:installed -- ... --observed-path <已打开的目录>` 进一步要求 Finder 实际观察到该目录，匹配路径指纹。

### 5.3 Ubuntu：python3-nautilus 扩展（extensions/linux）

- 实现 `Nautilus.MenuProvider`（python3-nautilus 4.x，适配 Nautilus 46 的 `get_file_items(self, files)` 新签名）。
- 菜单构建与分支显示逻辑同上；点击动作 `subprocess.Popen(["menugit", command, "--path", dir])`。
- 分发：deb 包由 Tauri bundler 生成，`Depends` 声明 `python3-nautilus`；扩展脚本由 postinst 安装到 `/usr/share/nautilus-python/extensions/`。KDE Dolphin / Nemo 适配为 P1。

## 6. CLI 协议（扩展 → 主程序）

统一格式：`menugit <command> --path <dir> [options]`

| command | 打开界面 | 附加参数 |
| --- | --- | --- |
| commit | 提交主窗口 | `--file <p>` 文件级右键预勾选 |
| pull / push | 拉取 / 推送面板 | — |
| branch / log | 分支 / 日志窗口 | `--file <p>` 日志按文件过滤 |
| discard | 放弃修改窗口 | `--file <p>` 预勾选 |
| conflict | 冲突解决窗口 | — |
| init | 初始化确认 | — |
| clone | 克隆窗口 | `--url <u>` 可选预填 |
| settings | 设置窗口 | — |

- 主程序启动时解析参数 → 转成前端初始视图；已运行时由单实例插件转发参数，前端切换视图。
- git 不可用：CLI 侧 `which git` / `where git` 检测失败即打开提示视图（R2：各平台安装指引，PRD Q3 结论 = 提示 + 指引命令，不做一键安装）。

## 7. 打包与分发

| 平台 | 打包物 | 安装动作 | 卸载动作 |
| --- | --- | --- | --- |
| Windows | NSIS 安装包（Tauri bundler）+ 自定义步骤注册 COM DLL（HKCU） | 安装 WebView2（如缺）、注册右键、创建开始菜单 | 反注册 DLL、清理注册表 |
| macOS | notarized App + DMG | 拖入 Applications，引导启用 Finder 扩展 | 删除 App 即可 |
| Ubuntu | deb（Tauri bundler） | apt 解析依赖，postinst 部署 Nautilus 扩展 | 卸载时清理扩展脚本 |

CI：GitHub Actions 三矩阵（windows / macos / ubuntu-24.04），tag 触发三平台产物构建。

## 8. 技术风险与对策

| # | 风险 | 等级 | 对策 |
| --- | --- | --- | --- |
| 1 | Rust 编写 COM DLL 是全新技术面（无既有经验） | 高 | M3 先做"最小 DLL 出现在右键菜单"技术验证，跑通后再展开；扩展逻辑极薄，主逻辑全在主程序 |
| 2 | 扩展崩溃拖垮文件管理器进程 | 高 | 扩展零网络/零子进程/全防御编码 + 禁用开关；Windows 上重点回归 Explorer 长时间运行 |
| 3 | 三平台 WebView 渲染差异 | 中 | 基线系统版本已锁定；UI 避免过新 CSS 特性；CI 三平台截图冒烟 |
| 4 | macOS 签名公证与 Gatekeeper | 中 | 尽早申请开发者账号并纳入 CI；未签名版本仅供本机开发 |
| 5 | Nautilus 扩展 API 变动 | 中 | 锁定 24.04 基线 + 启动时探测 python-nautilus 版本打诊断日志 |
| 6 | 大仓库 status 变慢 | 中 | porcelain v2 单命令取全量数据；列表渲染虚拟滚动；P1 再做状态缓存 |
| 7 | git 输出本地化差异 | 低 | git 命令统一 `LC_ALL=C` 执行，界面文案由 MenuGit 自己生成 |

## 9. 开发里程碑

1、**M1 GUI 骨架**：Tauri v2 工程建立，原型提交窗口迁移为 Vue 组件，手动命令行打开验证三端渲染。
2、**M2 Git 执行层**：status / diff / commit / push / pull / branch / log / discard 真仓库打通，R1/R3/R4 规则落地。
3、**M3 Windows 闭环**：COM DLL 技术验证 → 动态分支名菜单 → CLI 拉起 → 提交推送全流程；NSIS 安装器含 DLL 注册。
4、**M4 Ubuntu 闭环**：python3-nautilus 扩展 + deb 打包 + 24.04 虚拟机全流程验证。
5、**M5 macOS 闭环**：FinderSync 扩展 + 签名公证 + DMG。
6、**M6 收尾**：设置页、诊断日志、冲突解决器打磨、三平台回归（对照 PRD 验收标准）。

## 10. PRD 功能映射

| PRD | 实现 |
| --- | --- |
| FM-01 右键菜单 | 三平台扩展（第 5 章）+ CLI 协议（第 6 章） |
| FM-02 / 03 / 04 / 05 / 06 / 07 | Rust ops + 对应 Vue 视图 |
| FM-08 解决冲突 | 3.3 冲突解决器 + 冲突视图 |
| FM-09 / 10 | `git init` / `git clone` + 确认面板 |
| FM-11 设置 | settings.rs + 设置视图（不含任何 git config 项） |
| R1–R7 共享规则 | repo.rs（R1）、系统 git 直用（R2）、lock.rs（R3）、二次确认组件（R4）、错误呈现（R5）、diag.rs（R6）、i18n（R7） |
