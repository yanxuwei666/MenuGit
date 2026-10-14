# menugit-shell —— Windows 资源管理器右键菜单 COM Shell 扩展（最小技术验证）

对应 `docs/TechSpec-MenuGit.md` §3.4/§5.1（方案 A，TortoiseGit 同款机制）的 M3 里程碑第一步：
一个 Rust `cdylib`，实现 `IContextMenu` + `IShellExtInit` 进程内 COM 组件，注册后在
**目录右键 / 目录空白处右键**菜单中显示静态 "MenuGit" 项，点击后经 CLI 协议拉起 Tauri 主程序。

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

运行时行为：`InvokeCommand` 执行 `menugit commit --path <选中目录>`（CLI 协议见 TechSpec §6）。

## 已验证 / 未验证

**已验证**
- `cargo check` / `cargo build` 通过（windows 0.61.3，零警告；仅一条无害的 LNK4104 链接器提示）。
- dumpbin 确认 DLL 导出 5 个符号：`DllGetClassObject`、`DllCanUnloadNow`、`DllRegisterServer`、`DllUnregisterServer`、`DllInstall`。
- 注册表写入/删除逻辑为纯 HKCU 操作（RegCreateKeyExW/RegSetValueExW/RegDeleteTreeW），未实际执行。

**未验证（需实机注册后确认）**
- Explorer 实际加载 DLL、右键菜单显示、状态栏帮助文本（GCS_HELPTEXTW）。
- 点击菜单项拉起主程序（依赖 `HKCU\Software\MenuGit\ExePath` 先写入）。
- `DllCanUnloadNow` 恒返回 S_OK 的简化实现：Explorer 理论上可能在对象存活时卸载 DLL（MVP 接受；
  正确做法需维护模块锁计数）。
- 多选混合（文件+目录）、超长路径、非 UTF-16 可表示路径等边界。
- Win11 新版菜单不显示本项（预期行为：位于"显示更多选项"经典菜单内，与 TortoiseGit 一致）。

## 已知简化项

- 菜单为静态 "MenuGit" 文本 + 一条禁用的路径提示项；分支名动态显示留待后续里程碑。
- `GetCommandString` 仅支持 `GCS_HELPTEXTW`（其 COM 签名 pszName 为 LPSTR，宽文本按 PWSTR 写入，与官方约定一致）。
- 非目录选择时 `IShellExtInit::Initialize` 返回 E_FAIL 拒绝。
- 文件（`*`）与驱动器（`Drive`）挂载点未注册，仅 `Directory` 与 `Directory\Background`。
