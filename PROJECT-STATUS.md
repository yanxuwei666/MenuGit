# MenuGit 项目状态与进度说明

> 本文件是 AI 协作交接文档：记录项目概况、已确认决策、当前进度与下一步计划，供后续 AI 会话（或新协作者）快速接续工作。**每次完成一个阶段性节点，应更新本文件。**
>
> 最后更新：2026-10-13 ｜ 当前阶段：M2（Rust git 执行层）代码已写完、**尚未编译验证**

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
| M2 Rust git 执行层 | 🔶 代码已写完，**未编译验证** | 见 §5 明细 |
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

### 5.3 ⚠️ 未验证 / 未完成事项（接手 AI 优先处理）

1. **cargo check 从未运行过**（`src-tauri/target/` 不存在）。后台实现代理在写完代码后被手动停止，编译错误未知。→ 先按 §3 命令模板跑 `cargo check`，逐个修复编译错误。
2. **api.ts 与 Rust command 的入参/出参类型一致性未核对**（代理分两步写，可能存在字段名/可选性不一致）。→ cargo check 通过后逐命令比对。
3. **前端视图仍是 mock**：CommitView/commit.ts 尚未接线到真实 invoke（原计划 M2 第二阶段做）。→ 接线时保留"无 Tauri 环境时回退 mock"的能力（session.ts 已有 `tauriReady` 判断）。
4. 提交闭环（提交成功 → 自动切推送面板）尚未实现，推送面板本身还是占位视图。
5. `npm run tauri dev` 桌面窗口尚未验证过（依赖前两项完成）。

## 6. 下一步执行顺序

1、跑 `cargo check` 并修复全部编译错误（注意代理环境变量）。
2、核对 `src/api.ts` 与 Rust 命令签名/结构体字段一致性，修正不一致处。
3、前端接线：commit store 从 mock 切到 `api.ts`（get_repo_info/get_status/get_diff/stage_files/commit），提交成功后切换到 push 占位视图（事件流按 PRD 闭环：提交 → 自动推送面板 → 取消时按工作区是否干净决定关闭或返回）。
4、`npm run tauri dev` 在真实仓库上手工验证：状态列表、diff、勾选默认规则（修改/删除默认勾选、未跟踪不勾选、冲突不可勾选）、提交后文件消失、领先计数变化。
5、进入 M3：Windows COM DLL 最小验证（Rust cdylib + windows-rs 实现 IContextMenu/IShellExtInit，注册到 HKCU\Software\Classes，先让"MenuGit (main)"出现在右键菜单并能拉起主程序，再做完整 7+1 菜单）。

## 7. 工作约定（给后续 AI 的红线）

- 不引入 git2/libgit2；git 一律走 CLI，命令规范严格遵守 TechSpec §3.2 表格。
- 写操作必须过 lock.rs（R3）；破坏性操作前端二次确认（R4）。
- 凭证/代理/pull 策略等 git 配置一概不传参，完全复用系统 Git（R2）。
- 菜单扩展（M3+）内零网络请求、零子进程、异常全吞掉降级，绝不能拖垮文件管理器进程。
- 代码注释用中文；不运行 `npm run tauri dev` 留后台进程（验证窗口时告知用户即可）。
- 验证手段：Rust 侧 `cargo check`，前端侧 `npm run build`；环境问题先查代理。
- 完成节点后更新本文件 §4/§5/§6，重大决策写入 docs/TechSpec-MenuGit.md 并同步此文件 §2。
