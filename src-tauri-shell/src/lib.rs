//! MenuGit Shell 扩展（Windows 资源管理器右键菜单 COM 组件）
//!
//! 以 cdylib 形式提供进程内 COM 组件（TortoiseGit 同款机制）：
//! - `IShellExtInit`：接收资源管理器传入的选中项（CF_HDROP），解析目标目录
//!   （多选取第一个目录项；选中文件时取其所在目录）；
//! - `IContextMenu`：按场景插入 "MenuGit" 子菜单——
//!   · 仓库内（从选中目录向上查找 .git）：`MenuGit (分支名) ▸ 提交/拉取/推送/分支/日志/放弃修改/解决冲突 | 设置`；
//!   · 非仓库：`MenuGit ▸ 在此初始化 Git 仓库/克隆仓库到此处 | 设置`；
//!   点击后按 CLI 协议拉起主程序；
//! - 导出 DllGetClassObject / DllCanUnloadNow / DllRegisterServer / DllUnregisterServer / DllInstall。
//!
//! 稳定性约定：DLL 内不做网络访问、不扫大目录；所有异常路径吞掉并返回，不惊扰 Explorer。

use std::cell::RefCell;
use std::ffi::c_void;
use std::path::{Path, PathBuf};

use windows::core::{
    implement, BOOL, Error, GUID, HRESULT, HSTRING, Interface, IUnknown, PCWSTR, PSTR, Ref,
};
use windows::Win32::Foundation::{
    CLASS_E_CLASSNOTAVAILABLE, CLASS_E_NOAGGREGATION, E_FAIL, E_INVALIDARG, E_NOTIMPL, E_POINTER, HMODULE, S_OK,
};
use windows::Win32::System::Com::{
    DVASPECT_CONTENT, FORMATETC, IClassFactory, IClassFactory_Impl, IDataObject, TYMED_HGLOBAL,
};
use windows::Win32::System::LibraryLoader::{
    GetModuleFileNameW, GetModuleHandleExW, GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
    GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
};
use windows::Win32::System::Ole::{CF_HDROP, ReleaseStgMedium};
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteTreeW, RegGetValueW, RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_WRITE,
    REG_OPTION_NON_VOLATILE, REG_SZ, RRF_RT_REG_SZ,
};
use windows::Win32::UI::Shell::{
    CMF_DEFAULTONLY, CMINVOKECOMMANDINFO, DragQueryFileW, GCS_HELPTEXTW, HDROP, IContextMenu, IContextMenu_Impl,
    IShellExtInit, IShellExtInit_Impl,
};
use windows::Win32::UI::Shell::Common::ITEMIDLIST;
use windows::Win32::UI::WindowsAndMessaging::{
    CreatePopupMenu, DestroyMenu, HMENU, InsertMenuW, MF_BYPOSITION, MF_ENABLED, MF_GRAYED, MF_POPUP, MF_SEPARATOR,
    MF_STRING,
};

// ---------------------------------------------------------------------------
// 常量
// ---------------------------------------------------------------------------

/// 本扩展 COM 类的固定 CLSID（MVP 阶段写死；如需更换须同步更新 CLSID_STR 与注册脚本）
pub const CLSID_MENUGIT_EXT: GUID = GUID::from_u128(0xd4a7c1e9_3f2b_4e86_9c51_a0b2c3d4e5f6);

/// CLSID 的注册表字符串形式（必须与 CLSID_MENUGIT_EXT 保持一致）
const CLSID_STR: &str = "{D4A7C1E9-3F2B-4E86-9C51-A0B2C3D4E5F6}";

// --- 仓库内子菜单的命令偏移（相对 idCmdFirst；顺序即显示顺序）---
const OFF_COMMIT: u32 = 1;
const OFF_PULL: u32 = 2;
const OFF_PUSH: u32 = 3;
const OFF_BRANCH: u32 = 4;
const OFF_LOG: u32 = 5;
const OFF_DISCARD: u32 = 6;
const OFF_CONFLICT: u32 = 7;
/// 分隔线占用的偏移（无命令、不响应 InvokeCommand）
const OFF_REPO_SEPARATOR: u32 = 8;
const OFF_SETTINGS_REPO: u32 = 9;

// --- 非仓库子菜单的命令偏移 ---
const OFF_INIT: u32 = 1;
const OFF_CLONE: u32 = 2;
/// 分隔线占用的偏移
const OFF_NONREPO_SEPARATOR: u32 = 3;
const OFF_SETTINGS_NONREPO: u32 = 4;

/// 从选中目录向上查找 .git 的最大层数（含目录本身）
const MAX_REPO_WALK: u32 = 16;

/// 帮助文本（资源管理器状态栏提示，GCS_HELPTEXTW）
const MENU_HELP: &str = "在文件管理器中完成常用 Git 操作";

/// 子菜单条目：(相对 idCmdFirst 的命令偏移, 文本[None=分隔线], 是否置灰)
type MenuEntry = (u32, Option<&'static str>, bool);

/// 注册表：CLSID 注册根（per-user，免管理员）
const REG_CLSID_KEY: &str = "Software\\Classes\\CLSID\\{D4A7C1E9-3F2B-4E86-9C51-A0B2C3D4E5F6}";
/// 目录右键 / 目录空白处右键的挂载点
/// 挂载点基键：注册时在其下追加 `shellex\ContextMenuHandlers\MenuGit`
const REG_HANDLER_KEYS: [&str; 2] = [
    "Software\\Classes\\Directory",
    "Software\\Classes\\Directory\\Background",
];
/// 主程序路径配置（安装器负责写入；读不到则 InvokeCommand 静默跳过）
const REG_APP_SUBKEY: &str = "Software\\MenuGit";
const REG_APP_VALUE: &str = "ExePath";

// ---------------------------------------------------------------------------
// 场景与菜单内容
// ---------------------------------------------------------------------------

/// 仓库内子菜单条目；"解决冲突"仅在合并进行中（MERGE_HEAD 存在）时启用。
fn repo_entries(conflict_ready: bool) -> Vec<MenuEntry> {
    vec![
        (OFF_COMMIT, Some("提交…"), false),
        (OFF_PULL, Some("拉取"), false),
        (OFF_PUSH, Some("推送"), false),
        (OFF_BRANCH, Some("分支…"), false),
        (OFF_LOG, Some("日志…"), false),
        (OFF_DISCARD, Some("放弃修改…"), false),
        (OFF_CONFLICT, Some("解决冲突…"), !conflict_ready),
        (OFF_REPO_SEPARATOR, None, false),
        (OFF_SETTINGS_REPO, Some("设置…"), false),
    ]
}

/// 非仓库子菜单条目。
fn nonrepo_entries() -> Vec<MenuEntry> {
    vec![
        (OFF_INIT, Some("在此初始化 Git 仓库"), false),
        (OFF_CLONE, Some("克隆仓库到此处…"), false),
        (OFF_NONREPO_SEPARATOR, None, false),
        (OFF_SETTINGS_NONREPO, Some("设置…"), false),
    ]
}

/// 从 `start`（含自身）向上最多 16 层查找含 `.git` 的目录，查到盘符根为止。
/// `.git` 为目录或文件（worktree）均视为仓库；返回仓库根目录。
fn find_repo_root(start: &str) -> Option<PathBuf> {
    let mut cur = PathBuf::from(start);
    for _ in 0..MAX_REPO_WALK {
        if cur.join(".git").exists() {
            return Some(cur);
        }
        // pop() 在盘符根（如 "D:\"）返回 false，循环随之结束（盘符根已检查过）
        if !cur.pop() {
            break;
        }
    }
    None
}

/// 读取 `<仓库根>\.git\HEAD`，返回菜单标题里的分支标签：
/// `ref: refs/heads/xxx` → `xxx`（斜杠分支名保留完整名）；detached（裸哈希）→ 前 7 位；读失败 → None。
fn read_git_head_label(root: &Path) -> Option<String> {
    let head = std::fs::read_to_string(root.join(".git").join("HEAD")).ok()?;
    let content = head.trim();
    if let Some(r) = content.strip_prefix("ref: ") {
        Some(r.strip_prefix("refs/heads/").unwrap_or(r).to_string())
    } else if !content.is_empty() {
        Some(content.chars().take(7).collect())
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// 扩展对象：IShellExtInit + IContextMenu
// ---------------------------------------------------------------------------

/// COM 扩展对象。`#[implement]` 宏自动生成 IUnknown（QI/AddRef/Release）与两个接口的 vtable。
#[implement(IContextMenu, IShellExtInit)]
struct MenuGitExt {
    /// 目标目录：多选取第一个目录项；选中文件时取其所在目录（IShellExtInit::Initialize 填充）
    dir: RefCell<Option<String>>,
    /// QueryContextMenu 判定的场景（true=仓库内），决定 InvokeCommand 的偏移→视图映射
    in_repo: RefCell<bool>,
}

impl IShellExtInit_Impl for MenuGitExt_Impl {
    /// Explorer 传入选中项的 IDataObject；从 CF_HDROP 提取路径，解析出目标目录。
    /// 目录与文件都没有时返回 E_FAIL（表示本扩展不接受该次调用）。
    fn Initialize(
        &self,
        _pidlfolder: *const ITEMIDLIST,
        pdtobj: Ref<'_, IDataObject>,
        _hkeyprogid: HKEY,
    ) -> windows_core::Result<()> {
        let Ok(data_obj) = pdtobj.ok() else {
            return Err(Error::from(E_FAIL));
        };
        unsafe {
            // 只要 CF_HDROP（文件路径列表）
            let fmt = FORMATETC {
                cfFormat: CF_HDROP.0,
                dwAspect: DVASPECT_CONTENT.0,
                lindex: -1,
                tymed: TYMED_HGLOBAL.0 as u32,
                ptd: std::ptr::null_mut(),
            };
            // 0.61 版 GetData 直接返回 STGMEDIUM（出参改为返回值）
            let mut medium = match data_obj.GetData(&fmt) {
                Ok(m) => m,
                Err(_) => return Err(Error::from(E_FAIL)),
            };

            let hdrop = HDROP(medium.u.hGlobal.0);
            // 传 u32::MAX 查询拖放项总数
            let count = DragQueryFileW(hdrop, u32::MAX, None);

            let mut buf = [0u16; 1024];
            let mut first_dir: Option<String> = None;
            let mut first_file: Option<String> = None;
            for i in 0..count {
                let len = DragQueryFileW(hdrop, i, Some(&mut buf));
                if len == 0 || len as usize >= buf.len() {
                    continue;
                }
                let path = String::from_utf16_lossy(&buf[..len as usize]);
                if std::fs::metadata(&path).map(|m| m.is_dir()).unwrap_or(false) {
                    // 多选时取第一个目录项
                    if first_dir.is_none() {
                        first_dir = Some(path);
                    }
                } else if first_file.is_none() {
                    first_file = Some(path);
                }
            }
            // hGlobal 归 STGMEDIUM 所有，统一释放
            ReleaseStgMedium(&mut medium);

            // 纯文件选择：取该文件所在目录（文件级预选暂不做，保持简单）
            let target = first_dir.or_else(|| {
                first_file.and_then(|f| Path::new(&f).parent().map(|p| p.to_string_lossy().into_owned()))
            });
            let Some(dir) = target.filter(|d| !d.is_empty()) else {
                return Err(Error::from(E_FAIL));
            };
            *self.dir.borrow_mut() = Some(dir);
            Ok(())
        }
    }
}

impl IContextMenu_Impl for MenuGitExt_Impl {
    /// 向 hmenu 的 indexmenu 位置挂入一个 "MenuGit" 弹出子菜单，按仓库/非仓库场景填充条目，
    /// 返回"命令数"作为 HRESULT（SEVERITY_SUCCESS | FACILITY_NULL | 个数）。
    fn QueryContextMenu(
        &self,
        hmenu: HMENU,
        indexmenu: u32,
        idcmdfirst: u32,
        _idcmdlast: u32,
        uflags: u32,
    ) -> HRESULT {
        // 默认动词（双击等快捷调用）时不插入菜单
        if uflags & CMF_DEFAULTONLY != 0 {
            return HRESULT(0);
        }
        let Some(dir) = self.dir.borrow().clone() else {
            return HRESULT(0);
        };
        let repo_root = find_repo_root(&dir);
        *self.in_repo.borrow_mut() = repo_root.is_some();

        let (title, entries) = match &repo_root {
            Some(root) => {
                let title = match read_git_head_label(root) {
                    Some(branch) => format!("MenuGit ({branch})"),
                    None => "MenuGit".to_string(),
                };
                // "解决冲突"动态置灰：仅 MERGE_HEAD 存在（合并进行中）时可用
                let conflict_ready = root.join(".git").join("MERGE_HEAD").exists();
                (title, repo_entries(conflict_ready))
            }
            None => ("MenuGit".to_string(), nonrepo_entries()),
        };

        unsafe {
            let (popup, max_off) = build_popup_submenu(idcmdfirst, &entries);
            if popup.0.is_null() {
                return HRESULT(0);
            }
            let title_h = HSTRING::from(title);
            // MF_POPUP 时 uIDNewItem 传子菜单 HMENU（usize）
            let attached = InsertMenuW(
                hmenu,
                indexmenu,
                MF_POPUP | MF_BYPOSITION | MF_STRING,
                popup.0 as usize,
                PCWSTR(title_h.as_ptr()),
            )
            .is_ok();
            if !attached {
                let _ = DestroyMenu(popup);
                return HRESULT(0);
            }
            // 等价 MAKEULRESULT(max_off + 1) / MAKE_HRESULT(SEVERITY_SUCCESS, 0, 命令数)：
            // SEVERITY_SUCCESS=0、FACILITY_NULL=0，HRESULT 数值即添加的命令数
            HRESULT((max_off + 1) as i32)
        }
    }

    /// 执行菜单命令：按命令偏移映射视图名，启动主程序 `menugit <视图> --path <目标目录>`。
    /// Explorer 传的 lpVerb 高 16 位为 0 时表示命令偏移（MAKEINTRESOURCEA）；字符串动词一律不支持。
    fn InvokeCommand(&self, pici: *const CMINVOKECOMMANDINFO) -> windows_core::Result<()> {
        let Some(pici) = (unsafe { pici.as_ref() }) else {
            return Err(Error::from(E_FAIL));
        };
        let verb = pici.lpVerb.0 as usize;
        if verb & 0xFFFF_0000 != 0 {
            // 字符串形式的动词：本扩展未注册，直接拒绝
            return Err(Error::from(E_NOTIMPL));
        }
        let offset = (verb & 0xFFFF) as u32;
        let in_repo = *self.in_repo.borrow();
        let view = match (in_repo, offset) {
            (true, OFF_COMMIT) => "commit",
            (true, OFF_PULL) => "pull",
            (true, OFF_PUSH) => "push",
            (true, OFF_BRANCH) => "branch",
            (true, OFF_LOG) => "log",
            (true, OFF_DISCARD) => "discard",
            (true, OFF_CONFLICT) => "conflict",
            (true, OFF_SETTINGS_REPO) => "settings",
            (false, OFF_INIT) => "init",
            (false, OFF_CLONE) => "clone",
            (false, OFF_SETTINGS_NONREPO) => "settings",
            // 分隔线（无命令）或未知偏移：静默成功
            _ => return Ok(()),
        };

        // 读主程序路径；读不到则跳过（不给 Explorer 报错弹窗）
        let Some(exe) = (unsafe { read_exe_path() }) else {
            return Ok(());
        };
        let Some(dir) = self.dir.borrow().clone().filter(|d| !d.is_empty()) else {
            return Ok(());
        };
        // GUI 程序，spawn 不等待、不阻塞 Explorer；错误一律吞掉
        let _ = std::process::Command::new(&exe).args([view, "--path", &dir]).spawn();
        Ok(())
    }

    /// 提供帮助文本（GCS_HELPTEXTW）；其余查询类型一律 E_NOTIMPL。
    /// 注意：COM 签名的 pszName 是 LPSTR，GCS_HELPTEXTW 时缓冲区实为宽字符，需按 PWSTR 写入。
    fn GetCommandString(
        &self,
        icmd: usize,
        utype: u32,
        _pwreserved: *const u32,
        pszname: PSTR,
        cchmax: u32,
    ) -> windows_core::Result<()> {
        if utype != GCS_HELPTEXTW {
            return Err(Error::from(E_NOTIMPL));
        }
        let max_off = if *self.in_repo.borrow() {
            OFF_SETTINGS_REPO as usize
        } else {
            OFF_SETTINGS_NONREPO as usize
        };
        if icmd > max_off {
            return Err(Error::from(E_INVALIDARG));
        }
        if pszname.0.is_null() {
            return Err(Error::from(E_FAIL));
        }
        let mut wide: Vec<u16> = MENU_HELP.encode_utf16().collect();
        wide.push(0); // 结束符
        if wide.len() as u32 > cchmax {
            return Err(Error::from(E_NOTIMPL)); // 缓冲区不足，放弃
        }
        unsafe {
            let dst = pszname.0 as *mut u16;
            std::ptr::copy_nonoverlapping(wide.as_ptr(), dst, wide.len());
        }
        Ok(())
    }
}

/// 创建弹出子菜单并按顺序填充条目；返回 (子菜单句柄, 使用的最大命令偏移)。
/// 调用方须把句柄挂到父菜单（挂接后归父菜单所有）；挂接失败时负责 DestroyMenu。
unsafe fn build_popup_submenu(idcmdfirst: u32, entries: &[MenuEntry]) -> (HMENU, u32) {
    let Ok(popup) = CreatePopupMenu() else {
        return (HMENU(std::ptr::null_mut()), 0);
    };
    let mut max_off = 0u32;
    for (pos, (off, text, grayed)) in entries.iter().enumerate() {
        // HSTRING 必须活到 InsertMenuW 调用结束（PCWSTR 借用其缓冲区）
        let text_h = (*text).map(HSTRING::from);
        let (flags, new_item, text_pc) = match (&text_h, *grayed) {
            (Some(h), true) => (
                MF_STRING | MF_BYPOSITION | MF_GRAYED,
                (idcmdfirst + *off) as usize,
                PCWSTR(h.as_ptr()),
            ),
            (Some(h), false) => (
                MF_STRING | MF_BYPOSITION | MF_ENABLED,
                (idcmdfirst + *off) as usize,
                PCWSTR(h.as_ptr()),
            ),
            (None, _) => (MF_SEPARATOR | MF_BYPOSITION, 0, PCWSTR::null()),
        };
        // 单条插入失败不中断：菜单缺一项好过整体消失
        let _ = InsertMenuW(popup, pos as u32, flags, new_item, text_pc);
        max_off = (*off).max(max_off);
    }
    (popup, max_off)
}

// ---------------------------------------------------------------------------
// COM 类工厂
// ---------------------------------------------------------------------------

/// 标准 IClassFactory：Explorer 经 CoCreateInstance → DllGetClassObject 拿到它来创建 MenuGitExt。
#[implement(IClassFactory)]
struct MenuGitClassFactory;

impl IClassFactory_Impl for MenuGitClassFactory_Impl {
    fn CreateInstance(
        &self,
        punkouter: Ref<'_, IUnknown>,
        riid: *const GUID,
        ppvobject: *mut *mut c_void,
    ) -> windows_core::Result<()> {
        unsafe {
            // 本组件不支持聚合
            if punkouter.ok().is_ok() {
                return Err(Error::from(CLASS_E_NOAGGREGATION));
            }
            let ext: IContextMenu = MenuGitExt {
                dir: RefCell::new(None),
                in_repo: RefCell::new(false),
            }
            .into();
            // 按 Explorer 请求的 IID 完成 QueryInterface
            ext.query(riid, ppvobject).ok()
        }
    }

    fn LockServer(&self, _flock: BOOL) -> windows_core::Result<()> {
        // MVP 简化：不维护模块锁计数
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// DLL 导出
// ---------------------------------------------------------------------------

/// COM 入口：按 CLSID 返回类工厂。
#[no_mangle]
pub extern "system" fn DllGetClassObject(
    rclsid: *const GUID,
    riid: *const GUID,
    ppv: *mut *mut c_void,
) -> HRESULT {
    unsafe {
        if rclsid.is_null() || riid.is_null() || ppv.is_null() {
            return E_POINTER;
        }
        if *rclsid != CLSID_MENUGIT_EXT {
            return CLASS_E_CLASSNOTAVAILABLE;
        }
        let factory: IClassFactory = MenuGitClassFactory.into();
        factory.query(riid, ppv)
    }
}

/// MVP 简化：恒返回 S_OK（正确做法应维护 LockServer/AddRef 的模块级计数）。
#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> HRESULT {
    S_OK
}

/// 注册（regsvr32 调用）：只写 HKCU，免管理员权限。
#[no_mangle]
pub extern "system" fn DllRegisterServer() -> HRESULT {
    unsafe {
        // InprocServer32 需要本 DLL 的绝对路径
        let Some(dll_path) = get_dll_path() else {
            return E_FAIL;
        };

        // 1) CLSID\InprocServer32：默认值 = DLL 路径；ThreadingModel = Apartment（Explorer 要求 STA）
        if let Err(e) = reg_write_string(REG_CLSID_KEY, "InprocServer32", None, &dll_path) {
            return e;
        }
        if let Err(e) = reg_write_string(REG_CLSID_KEY, "InprocServer32", Some("ThreadingModel"), "Apartment") {
            return e;
        }

        // 2) 目录右键 + 目录空白处右键的挂载点：默认值 = "{CLSID}"
        for key in REG_HANDLER_KEYS {
            if let Err(e) = reg_write_string(key, "shellex\\ContextMenuHandlers\\MenuGit", None, CLSID_STR) {
                return e;
            }
        }
        S_OK
    }
}

/// 注销（regsvr32 /u 调用）：删除注册时写入的所有键（子树整体删除）。
#[no_mangle]
pub extern "system" fn DllUnregisterServer() -> HRESULT {
    unsafe {
        let _ = RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(HSTRING::from(REG_CLSID_KEY).as_ptr()));
        for key in REG_HANDLER_KEYS {
            let full = format!(r"{key}\shellex\ContextMenuHandlers\MenuGit");
            let _ = RegDeleteTreeW(HKEY_CURRENT_USER, PCWSTR(HSTRING::from(full).as_ptr()));
        }
        S_OK
    }
}

/// regsvr32 /n /i:user 走的入口：与 DllRegisterServer / DllUnregisterServer 等价，
/// 便于安装器以"每用户"语义注册（不触发 DllRegisterServer）。
#[no_mangle]
pub extern "system" fn DllInstall(b_install: BOOL, pszcmdline: PCWSTR) -> HRESULT {
    let cmd = pcwstr_to_string(pszcmdline);
    // 只接受空参数或 "user"（per-user 安装）；其他参数一律拒绝
    if !cmd.is_empty() && !cmd.eq_ignore_ascii_case("user") {
        return E_INVALIDARG;
    }
    if b_install.as_bool() {
        DllRegisterServer()
    } else {
        DllUnregisterServer()
    }
}

// ---------------------------------------------------------------------------
// 辅助函数
// ---------------------------------------------------------------------------

/// 读取 HKCU\Software\MenuGit\ExePath（主程序 exe 的绝对路径）。
unsafe fn read_exe_path() -> Option<String> {
    let subkey = HSTRING::from(REG_APP_SUBKEY);
    let value = HSTRING::from(REG_APP_VALUE);
    let mut buf = [0u16; 520];
    let mut cb = (buf.len() * 2) as u32;
    let err = RegGetValueW(
        HKEY_CURRENT_USER,
        PCWSTR(subkey.as_ptr()),
        PCWSTR(value.as_ptr()),
        RRF_RT_REG_SZ,
        None,
        Some(buf.as_mut_ptr() as *mut c_void),
        Some(&mut cb),
    );
    if err.0 != 0 {
        return None;
    }
    // REG_SZ 保证以 NUL 结尾；截到结束符
    let len = buf.iter().position(|&c| c == 0).unwrap_or(0);
    let path = String::from_utf16_lossy(&buf[..len]);
    if path.is_empty() {
        None
    } else {
        Some(path)
    }
}

/// 在 HKCU 下创建键并写入一个字符串值（REG_SZ）。
/// `subkey` 相对 HKEY_CURRENT_USER；`value = None` 写默认值。
unsafe fn reg_write_string(subkey: &str, value_name: &str, value: Option<&str>, data: &str) -> Result<(), HRESULT> {
    let subkey_h = HSTRING::from(format!(r"{subkey}\{value_name}"));
    let mut hk = HKEY::default();
    let err = RegCreateKeyExW(
        HKEY_CURRENT_USER,
        PCWSTR(subkey_h.as_ptr()),
        Some(0),
        PCWSTR(std::ptr::null()),
        REG_OPTION_NON_VOLATILE,
        KEY_WRITE,
        None,
        &mut hk,
        None,
    );
    if err.0 != 0 {
        return Err(HRESULT::from_win32(err.0));
    }

    // REG_SZ 需以 NUL 结尾的 UTF-16，按字节切片写入
    let data_w: Vec<u16> = data.encode_utf16().chain(std::iter::once(0)).collect();
    let data_bytes: Vec<u8> = data_w.iter().flat_map(|c| c.to_le_bytes()).collect();
    let value_h = value.map(HSTRING::from);
    let value_pc = match &value_h {
        Some(h) => PCWSTR(h.as_ptr()),
        None => PCWSTR(std::ptr::null()),
    };
    let err = RegSetValueExW(hk, value_pc, Some(0), REG_SZ, Some(&data_bytes));
    let _ = RegCloseKey(hk);
    if err.0 != 0 {
        return Err(HRESULT::from_win32(err.0));
    }
    Ok(())
}

/// 取本 DLL 自身的绝对路径：用本模块内函数地址反查模块句柄（免 DllMain 全局状态）。
unsafe fn get_dll_path() -> Option<String> {
    let mut hmod = HMODULE::default();
    // 用 DllGetClassObject 的函数地址定位本 DLL
    let addr = DllGetClassObject as *const () as *const u16;
    let flags = GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT;
    if GetModuleHandleExW(flags, PCWSTR(addr), &mut hmod).is_ok() {
        let mut buf = [0u16; 1024];
        let len = GetModuleFileNameW(Some(hmod), &mut buf);
        if len > 0 && (len as usize) < buf.len() {
            return Some(String::from_utf16_lossy(&buf[..len as usize]));
        }
    }
    None
}

/// PCWSTR → String（读到 NUL 为止；空指针返回空串）。
fn pcwstr_to_string(p: PCWSTR) -> String {
    if p.0.is_null() {
        return String::new();
    }
    unsafe {
        let mut len = 0usize;
        while *p.0.add(len) != 0 {
            len += 1;
        }
        String::from_utf16_lossy(std::slice::from_raw_parts(p.0, len))
    }
}
