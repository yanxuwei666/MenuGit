# menugit-shell —— Windows 资源管理器右键菜单 COM Shell 扩展

对应 `docs/TechSpec-MenuGit.md` §3.4/§5.1（方案 A，TortoiseGit 同款机制）：
一个 Rust `cdylib`，实现 `IContextMenu` + `IShellExtInit` 进程内 COM 组件，注册后在
**目录右键 / 目录空白处右键**菜单中按场景插入动态 "MenuGit" 子菜单，点击后经 CLI 协议拉起 Tauri 主程序。

## 菜单形态（运行时动态判定）

从选中目录（多选取第一个目录项；选中文件取其所在目录）向上最多 16 层查找 `.git`（目录或 worktree 文件均算）：

- **仓库内**：`MenuGit (分支名)`（分支读 `<仓库根>\.git\HEAD`，detached 显示前 7 位哈希，读失败不带括号）▸
  提交… / 拉取 / 推送 / 分支… / 日志… / 放弃修改… / 解决冲突…（无 `MERGE_HEAD` 时置灰） ─ 分隔线 ─ 设置…
- **非仓库**：`MenuGit` ▸ 在此初始化 Git 仓库 / 克隆仓库到此处… ─ 分隔线 ─ 设置…

命令偏移（相对 `idCmdFirst`，子菜单项从 +1 起）：仓库内 1..7 对应
commit/pull/push/branch/log/discard/conflict、9=设置（8 为分隔线）；
非仓库 1=init、2=clone、4=设置（3 为分隔线）。`QueryContextMenu` 返回 `最大偏移+1`（等价 `MAKEULRESULT`）。


**本阶段仅完成编码与编译验证；未执行 regsvr32、未写注册表**（需宿主与用户确认后操作）。

## 构建

```powershell
cd src-tauri-shell
cargo build            # 产物：target\debug\menugit_shell.dll（64 位，与 64 位 Explorer 匹配）
```

依赖走国内镜像（`.cargo/config.toml`，同 src-tauri 配置；rsproxy sparse）。

## CLSID

`{D4A7C1E9-3F2B-4E86-9C51-A0B2C3D4E5F6}`（写死于 `src/lib.rs` 常量 `CLSID_MENUGIT_EXT` / `CLSID_STR`）。

## 注册 / 卸载（免管理员：只写 HKCU）

DllRegisterServer 仅写 `HKCU\Software\Classes`，因此 regsvr32 不需要管理员权限。
注意须用 **64 位** regsvr32（System32 下，64 位 PowerShell 默认即是）。

```powershell
# 方式一：DllRegisterServer / DllUnregisterServer
regsvr32 /s "D:\Code\personal\MenuGit\src-tauri-shell\target\debug\menugit_shell.dll"
regsvr32 /s /u "D:\Code\personal\MenuGit\src-tauri-shell\target\debug\menugit_shell.dll"

# 方式二：DllInstall（/n /i:user，每用户语义，不触发 DllRegisterServer）
regsvr32 /n /i:user "D:\Code\personal\MenuGit\src-tauri-shell\target\debug\menugit_shell.dll"
regsvr32 /u /n /i:user "D:\Code\personal\MenuGit\src-tauri-shell\target\debug\menugit_shell.dll"
```

注册后如未立即生效：重启 Explorer（`Stop-Process -Name explorer`）或注销重登（shellex 变更通常无需重启，
但 Explorer 对 DLL 有缓存时可能需要）。

## 注册表键清单（注册时写入 / 卸载时删除）

| 键 | 值 | 说明 |
| --- | --- | --- |
| `HKCU\Software\Classes\CLSID\{D4A7C1E9-…-A0B2C3D4E5F6}\InprocServer32` | `(默认)` = DLL 绝对路径 | COM 类注册 |
| 同上 | `ThreadingModel` = `Apartment` | Explorer 要求 STA |
| `HKCU\Software\Classes\Directory\shellex\ContextMenuHandlers\MenuGit` | `(默认)` = `{D4A7C1E9-…}` | 目录右键 |
| `HKCU\Software\Classes\Directory\Background\shellex\ContextMenuHandlers\MenuGit` | `(默认)` = `{D4A7C1E9-…}` | 目录空白处右键 |
| `HKCU\Software\MenuGit\ExePath`（**只读**） | 主程序 exe 绝对路径 | `InvokeCommand` 读取；安装器/主程序负责写入，读不到则静默跳过 |

运行时行为：`InvokeCommand` 执行 `menugit <视图> --path <目标目录>`；视图为
`commit/pull/push/branch/log/discard/conflict/settings`（仓库内）或 `init/clone/settings`（非仓库，settings 也带 `--path`，主程序可忽略）。CLI 协议见 TechSpec §6。

## 已验证 / 未验证

**已验证**
- `cargo check` / `cargo build` 通过（windows 0.61.3，零警告；仅一条无害的 LNK4104 链接器提示）。
- dumpbin 确认 DLL 导出 5 个符号：`DllGetClassObject`、`DllCanUnloadNow`、`DllRegisterServer`、`DllUnregisterServer`、`DllInstall`。
- 注册表写入/删除逻辑为纯 HKCU 操作（RegCreateKeyExW/RegSetValueExW/RegDeleteTreeW），未实际执行。

**未验证（需实机注册后确认）**
- Explorer 实际加载 DLL、右键菜单动态子菜单显示（分支名/置灰态）、状态栏帮助文本（GCS_HELPTEXTW）。
- 点击菜单项拉起主程序（依赖 `HKCU\Software\MenuGit\ExePath` 先写入）。
- 超长路径、非 UTF-16 可表示路径、网络驱动器等边界。
- Win11 新版菜单不显示本项（预期行为：位于"显示更多选项"经典菜单内，与 TortoiseGit 一致）。

## 已知简化项

- 仓库判定只看 `.git` 是否存在，不校验 HEAD 内容；worktree（`.git` 为文件）按仓库处理，但分支名读取仍走
  `<仓库根>\.git\HEAD`，worktree 下读不到 → 标题显示为不带分支的 "MenuGit"。
- `GetCommandString` 仅支持 `GCS_HELPTEXTW`，所有命令返回同一句帮助文本（其 COM 签名 pszName 为 LPSTR，
  宽文本按 PWSTR 写入，与官方约定一致）。
- 选中文件时不做文件级预选，仅取其所在目录作为 `--path`。
- `DllCanUnloadNow` 恒返回 S_OK 的简化实现（正确做法需维护模块锁计数）。
