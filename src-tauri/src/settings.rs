//! settings.rs —— 薄设置持久化（技术方案 §3.1）。
//!
//! 设置存于 Tauri app data 目录的 `settings.json`，不含任何 git config 项。
//! 仅保存 MenuGit 自身偏好，不包含任何 git config 项。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::DialogExt;

use crate::diag;

/// 应用设置
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// 界面语言：system / zh-CN / en
    pub language: String,
    /// 新增 / 未跟踪文件是否默认勾选提交
    pub new_files_checked: bool,
    /// 诊断日志开关（R6，默认关闭）
    pub diag_enabled: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            language: "system".to_string(),
            new_files_checked: false,
            diag_enabled: false,
        }
    }
}

fn settings_path(app: &AppHandle) -> Option<PathBuf> {
    app.path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("settings.json"))
}

/// 读取设置；文件缺失或损坏时返回默认值
pub fn load(app: &AppHandle) -> Settings {
    let Some(path) = settings_path(app) else {
        return Settings::default();
    };
    std::fs::read_to_string(path)
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

/// 保存设置到 settings.json
pub fn save(app: &AppHandle, settings: &Settings) -> Result<(), String> {
    let Some(path) = settings_path(app) else {
        return Err("无法定位应用数据目录".to_string());
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let text = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::write(path, text).map_err(|e| e.to_string())
}

/// 读取应用设置
#[tauri::command]
pub fn get_settings(app: AppHandle) -> Settings {
    load(&app)
}

/// 保存应用设置，并同步诊断日志开关
#[tauri::command]
pub fn set_settings(app: AppHandle, settings: Settings) -> Result<(), String> {
    let mut normalized = settings;
    if !matches!(normalized.language.as_str(), "system" | "zh-CN" | "en") {
        normalized.language = "system".to_string();
    }
    save(&app, &normalized)?;
    diag::set_enabled(normalized.diag_enabled);
    Ok(())
}

/// 读取诊断日志与 Git 版本，供设置页排障。
#[tauri::command]
pub fn get_diagnostics(app: AppHandle) -> Diagnostics {
    let log_path = app
        .path()
        .app_data_dir()
        .ok()
        .map(|dir| dir.join("diag.log"));
    let log = log_path
        .as_ref()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .unwrap_or_else(|| "暂无诊断日志".to_string());
    let git_version = crate::git::resolve_git_binary()
        .ok()
        .and_then(|git| {
            std::process::Command::new(git)
                .arg("--version")
                .output()
                .ok()
        })
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string());
    Diagnostics {
        git_version,
        log_path: log_path.map(|path| path.to_string_lossy().into_owned()),
        log,
    }
}

/// 在系统浏览器打开项目发布页，供用户查看新版本与项目说明。
#[tauri::command]
pub fn open_project_releases() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("/usr/bin/open")
            .arg("https://github.com/yanxuwei666/MenuGit/releases")
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("无法打开项目发布页：{error}"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("此操作目前仅支持 macOS".to_string())
    }
}

/// 用户点击时打开系统目录选择器；后台检查通过输入路径跳过原生对话框。
#[tauri::command]
pub async fn choose_repository(app: AppHandle) -> Result<Option<String>, String> {
    tauri::async_runtime::spawn_blocking(move || {
        app.dialog()
            .file()
            .set_title("选择 Git 仓库目录")
            .blocking_pick_folder()
            .map(|path| {
                path.into_path()
                    .map(|path| path.to_string_lossy().into_owned())
                    .map_err(|error| error.to_string())
            })
            .transpose()
    })
    .await
    .map_err(|error| error.to_string())?
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Diagnostics {
    pub git_version: Option<String>,
    pub log_path: Option<String>,
    pub log: String,
}
