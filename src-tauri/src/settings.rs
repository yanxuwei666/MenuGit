//! settings.rs —— 薄设置持久化（技术方案 §3.1）。
//!
//! 设置存于 Tauri app data 目录的 `settings.json`，不含任何 git config 项。
//! 当前仅诊断日志开关；语言等字段后续在 M6 扩展。

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Manager};

use crate::diag;

/// 应用设置
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// 诊断日志开关（R6，默认关闭）
    pub diag_enabled: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self { diag_enabled: false }
    }
}

fn settings_path(app: &AppHandle) -> Option<PathBuf> {
    app.path().app_data_dir().ok().map(|dir| dir.join("settings.json"))
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
    save(&app, &settings)?;
    diag::set_enabled(settings.diag_enabled);
    Ok(())
}
