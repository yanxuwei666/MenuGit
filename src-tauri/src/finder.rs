//! macOS Finder 扩展注册、状态检查与修复；全部操作在后台执行。

use serde::Serialize;
use std::path::{Path, PathBuf};

const EXTENSION_ID: &str = "dev.menugit.desktop.findersync";

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FinderIntegration {
    pub supported: bool,
    pub bundled: bool,
    pub registered: bool,
    pub enabled: bool,
    pub extension_path: Option<String>,
    pub message: String,
}

fn extension_for_executable(executable: &Path) -> Option<PathBuf> {
    let macos = executable.parent()?;
    let contents = macos.parent()?;
    let app = contents.parent()?;
    if macos.file_name()? != "MacOS"
        || contents.file_name()? != "Contents"
        || app.extension()? != "app"
    {
        return None;
    }
    Some(contents.join("PlugIns/MenuGitFinderSync.appex"))
}

fn registered_state(output: &str, extension: &Path) -> (bool, bool) {
    let expected = extension.to_string_lossy();
    let mut enabled = false;
    let mut matched_identifier = false;
    for line in output.lines() {
        let row = line.trim_start();
        if row.contains(&format!("{EXTENSION_ID}(")) {
            matched_identifier = true;
            enabled = row.starts_with('+');
        } else if let Some(path) = row.strip_prefix("Path = ") {
            if matched_identifier && path == expected {
                return (true, enabled);
            }
            matched_identifier = false;
        }
    }
    (false, false)
}

#[cfg(target_os = "macos")]
fn plugin_command(arguments: &[&std::ffi::OsStr]) -> Result<String, String> {
    let result = std::process::Command::new("/usr/bin/pluginkit")
        .args(arguments)
        .output()
        .map_err(|error| format!("无法调用 Finder 扩展管理服务：{error}"))?;
    if !result.status.success() {
        return Err(format!(
            "Finder 扩展管理失败：{}",
            String::from_utf8_lossy(&result.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&result.stdout).into_owned())
}

pub fn status() -> Result<FinderIntegration, String> {
    let mut state = FinderIntegration {
        supported: cfg!(target_os = "macos"),
        bundled: false,
        registered: false,
        enabled: false,
        extension_path: None,
        message: "访达集成仅适用于 macOS".into(),
    };
    #[cfg(target_os = "macos")]
    {
        state.message = "请从已安装的 MenuGit.app 检查访达集成".into();
        let executable = std::env::current_exe().map_err(|error| error.to_string())?;
        let Some(extension) = extension_for_executable(&executable).filter(|path| path.is_dir())
        else {
            return Ok(state);
        };
        state.bundled = true;
        state.extension_path = Some(extension.to_string_lossy().into_owned());
        let output = plugin_command(&[
            "-m".as_ref(),
            "-A".as_ref(),
            "-D".as_ref(),
            "-vv".as_ref(),
            "-i".as_ref(),
            EXTENSION_ID.as_ref(),
        ])?;
        (state.registered, state.enabled) = registered_state(&output, &extension);
        state.message = if !state.registered {
            "访达扩展尚未注册"
        } else if !state.enabled {
            "访达扩展尚未启用"
        } else {
            "访达扩展已注册并启用"
        }
        .into();
    }
    Ok(state)
}

/// 应用启动时只注册随包扩展，保留用户已有的启用/禁用选择。
#[cfg(target_os = "macos")]
pub fn register() -> Result<(), String> {
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let Some(extension) = extension_for_executable(&executable).filter(|path| path.is_dir()) else {
        return Ok(());
    };
    plugin_command(&["-a".as_ref(), extension.as_os_str()])?;
    Ok(())
}

pub fn repair() -> Result<FinderIntegration, String> {
    #[cfg(target_os = "macos")]
    {
        if !status()?.bundled {
            return Err("应用包没有 Finder 扩展，请重新安装完整的 MenuGit.app".into());
        }
        register()?;
        plugin_command(&[
            "-e".as_ref(),
            "use".as_ref(),
            "-i".as_ref(),
            EXTENSION_ID.as_ref(),
        ])?;
        let state = status()?;
        if !state.registered || !state.enabled {
            return Err(
                "系统未接受 Finder 扩展，请在系统设置的 Finder 扩展列表中检查 MenuGit".into(),
            );
        }
        Ok(state)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("访达集成仅适用于 macOS".into())
    }
}

#[tauri::command]
pub async fn get_finder_integration() -> Result<FinderIntegration, String> {
    tauri::async_runtime::spawn_blocking(status)
        .await
        .map_err(|error| error.to_string())?
}

#[tauri::command]
pub async fn repair_finder_integration() -> Result<FinderIntegration, String> {
    tauri::async_runtime::spawn_blocking(repair)
        .await
        .map_err(|error| error.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_path_requires_an_application_bundle() {
        assert_eq!(
            extension_for_executable(Path::new(
                "/Applications/MenuGit.app/Contents/MacOS/menugit"
            )),
            Some(PathBuf::from(
                "/Applications/MenuGit.app/Contents/PlugIns/MenuGitFinderSync.appex"
            ))
        );
        assert!(extension_for_executable(Path::new("/tmp/debug/menugit")).is_none());
    }

    #[test]
    fn finder_status_matches_the_current_copy_and_user_election() {
        let extension =
            Path::new("/Applications/MenuGit.app/Contents/PlugIns/MenuGitFinderSync.appex");
        let output = format!("+    {EXTENSION_ID}(0.1.0)\n Path = /tmp/Old.app/Contents/PlugIns/MenuGitFinderSync.appex\n-    {EXTENSION_ID}(0.1.0)\n Path = {}\n", extension.display());
        assert_eq!(registered_state(&output, extension), (true, false));
        assert_eq!(
            registered_state(&output.replace("-    ", "+    "), extension),
            (true, true)
        );
        assert_eq!(registered_state(" (no matches)", extension), (false, false));
    }
}
