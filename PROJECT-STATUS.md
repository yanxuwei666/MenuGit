# MenuGit 项目状态与进度说明

> 本文件是 AI 协作交接文档：记录项目概况、已确认决策、当前进度与下一步计划，供后续 AI 会话（或新协作者）快速接续工作。**每次完成一个阶段性节点，应更新本文件。**
>
> 最后更新：2026-10-14 ｜ 当前阶段：M2 完成（编码 + 前端接线 + 编译验证），下一步 M3（Windows COM DLL）

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
| macOS 右键 | FinderSync 扩展（Swift，App Group 通信，DMG + Developer ID 公证） |
| Linux 右键 | python3-nautilus 扩展（Nautilus 46 新签名 `get_file_items(self, files)`） |
| 扩展 ↔ GUI | CLI 参数拉起：`menugit <command> --path <dir> [--file <p>] [--url <u>]`；分支名由扩展直接解析 `.git/HEAD`（不 spawn git） |
| 单实例 | tauri-plugin-single-instance，二次拉起参数转发给现有实例 |
| 平台基线 | Windows 10+ / macOS 12+ / **Ubuntu 24.04**（20.04 缺 webkit2gtk-4.1，明确不做兼容，后续如需适配重新开发） |
| 菜单形态 | 仓库内 7+1 项（提交/拉取/推送/分支/日志/放弃修改/解决冲突 + 设置），非仓库 2+1 项，一级菜单标题括号内显示当前分支名 |

## 3. 开发环境现状（Windows 开发机）

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

计划：M1 GUI 骨架 → M2 Git 执行层 → M3 Windows 闭环 → M4 Ubuntu 闭环 → M5 macOS 闭环 → M6 收尾（详见 TechSpec §9）。

| 里程碑 | 状态 | 说明 |
| --- | --- | --- |
| M1 GUI 骨架 + 提交窗口迁移 | ✅ 完成 | 前端 `npm run build` 通过 |
| M2 Rust git 执行层 | ✅ 完成 | cargo check / cargo build / npm run build 全部通过；api.ts 已与 Rust 签名核对一致 |
| M3 Windows COM DLL | ⬜ 未开始 | 第一步先做"最小 DLL 出现在右键菜单"技术验证 |
| M4 Ubuntu 闭环 / M5 macOS 闭环 / M6 收尾 | ⬜ 未开始 | — |

## 5. 当前代码状态明细

### 5.1 工程结构

```
MenuGit/
├─ src/                        # Vue 前端
│  ├─ views/CommitView.vue     # 提交窗口（M1 从原型迁移，布局/亮暗主题还原原型）
│  ├─ components/DiffPreview.vue
│  ├─ stores/session.ts        # 视图切换 + CLI 参数解析（commit/pull/push/... → ViewName）
│  ├─ stores/commit.ts         # 提交窗口状态（当前仍是 mock 数据）
│  ├─ api.ts                   # 【M2 新增，250 行】Rust command 的类型化 invoke 封装
│  └─ styles/theme.scss        # 从原型提取的设计令牌（:root 亮色 + [data-theme="dark"]）
├─ src-tauri/src/              # 【M2 新增 Rust 层】
│  ├─ main.rs                  # 入口：单实例 + CliArgs + setup(恢复设置/诊断日志) + 21 个命令注册
│  ├─ git.rs                   # git 子进程统一执行器（--no-pager -c core.quotepath=false、LC_ALL=C、超时/取消、错误结构）
│  ├─ repo.rs                  # R1 仓库发现 + .git/HEAD 分支解析 + porcelain v2 状态/领先落后解析
│  ├─ lock.rs                  # R3 每仓库内存写锁
│  ├─ settings.rs              # 薄设置（app data 目录 json）：语言/新增默认勾选/诊断开关
│  ├─ diag.rs                  # 诊断日志（默认关闭，写 app data/diag.log）
│  └─ ops/                     # status / diff / stage / sync(push,pull) / branch / logop / discard / conflict / initclone
├─ docs/                       # PRD、TechSpec、prototype.html
└─ PROJECT-STATUS.md           # 本文件
```

### 5.2 已注册的 Tauri 命令（main.rs）

`get_cli_args`、`settings::get_settings/set_settings`、`ops::status::get_repo_info/get_status`、`ops::diff::get_diff`、`ops::stage::stage_files/commit`、`ops::sync::push/pull`、`ops::branch::list_branches/switch_branch/checkout_remote`、`ops::logop::get_log`、`ops::discard::discard_changes`、`ops::conflict::get_conflict_file/resolve_conflict_file/complete_merge/abort_merge`、`ops::initclone::init_repo/clone_repo/cancel_clone`（clone 进度走 `clone-progress` 事件）。

### 5.3 当前剩余事项（接手 AI 优先处理）

1. **提交闭环只差推送面板**：提交成功后已自动切换到 push 视图（App.vue 中为占位空状态）。下一步实现推送面板（FM-04：目标分支选择、新建远端分支提示、结果反馈），拉取面板（FM-03）同构实现。
2. **桌面窗口冒烟未做**：`npm run tauri dev` 会开窗口、需要人工确认，故未自动运行。已验证到 `cargo build` 产出 `src-tauri/target/debug/menugit.exe`（13MB）。冒烟建议：`npm run tauri dev` 后手动执行 `target\debug\menugit.exe commit --path <任意仓库>` 或在 devUrl 中查看。
3. **前端其余视图**（branch/log/discard/conflict/init/clone/settings）仍为占位，按 M2+ 计划用真实 api.ts 逐步接线；api.ts 已提供全部命令封装。
4. `src/api.ts` 与 Rust 签名一致性已逐命令核对（2026-10-14），后续新增命令需同步维护。

### 5.4 M2 实现细节备忘

- Rust 侧共 22 个 Tauri command（21 个原有 + `ops::status::get_identity` 读系统 Git 身份），注册于 main.rs。
- 前端接线采用**双模式**：`stores/commit.ts` 的 `repoPath` 为 null 时走 mock（浏览器调试），Tauri 环境由 `App.vue` 在 `session.init()` 后按 CLI `--path` 调 `commit.load(path)`；二次拉起经 `watch(session.request)` 跟随新目标重载。
- diff 解析在纯前端完成：`parseDiff()` 把 `get_diff` 返回的统一 diff 文本转为 hunk/ctxl/add/del 行模型；冲突文件点击显示占位提示（走独立冲突编辑器）。
- cargo 镜像：`src-tauri/.cargo/config.toml` 配置了 rsproxy.cn（代理不稳定时的兜底），删除该文件即恢复官方源。

## 6. 下一步执行顺序

1、实现推送面板（FM-04）与拉取面板（FM-03）：同构对话框（本地分支 + 远端/分支选择、新建远端分支确认、进行中状态、结果摘要/失败可读原因），完成后把 realCommit 的闭环从"切占位视图"改为真实推送流程。
2、分支窗口（FM-05）、日志窗口（FM-06）接线：api.ts 的 listBranches/switchBranch/getLog 已就绪。
3、放弃修改（FM-07，含 R4 二次确认）与冲突解决（FM-08 三选一合并编辑器，get_conflict_file/resolve_conflict_file 已就绪）。
4、init/clone/settings 接线，完成全部 P0 视图。
5、进入 M3：Windows COM DLL 最小验证（Rust cdylib + windows-rs 实现 IContextMenu/IShellExtInit，注册到 HKCU\Software\Classes，先让"MenuGit (main)"出现在右键菜单并能拉起主程序，再做完整 7+1 菜单）。

## 7. 工作约定（给后续 AI 的红线）

- 不引入 git2/libgit2；git 一律走 CLI，命令规范严格遵守 TechSpec §3.2 表格。
- 写操作必须过 lock.rs（R3）；破坏性操作前端二次确认（R4）。
- 凭证/代理/pull 策略等 git 配置一概不传参，完全复用系统 Git（R2）。
- 菜单扩展（M3+）内零网络请求、零子进程、异常全吞掉降级，绝不能拖垮文件管理器进程。
- 代码注释用中文；不运行 `npm run tauri dev` 留后台进程（验证窗口时告知用户即可）。
- 验证手段：Rust 侧 `cargo check`，前端侧 `npm run build`；环境问题先查代理。
- 完成节点后更新本文件 §4/§5/§6，重大决策写入 docs/TechSpec-MenuGit.md 并同步此文件 §2。
