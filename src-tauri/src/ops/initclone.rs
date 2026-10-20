//! initclone.rs —— 仓库初始化与克隆命令（FM-09 / FM-10）。
//!
//! clone 异步执行：进度经 Tauri 事件 `clone-progress` 推送（payload 含 repoKey、
//! percent、文本、done/error），支持取消（终止整个 git 进程树）。

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tauri::Emitter;

use crate::git::{self, GitError};
use crate::lock;
use crate::ops::validate_dir;
use crate::repo;

use super::status::get_repo_info;

/// 初始化仓库：`git init`，返回新仓库概要信息
#[tauri::command]
pub fn init_repo(path: String) -> Result<repo::RepoInfo, GitError> {
    let dir = validate_dir(&path)?;
    // 已在仓库内（含仓库根本身）时不重复初始化，避免创建嵌套 .git（PRD FM-09）。
    if let Some(existing) = repo::find_repo_root(&dir) {
        return Err(GitError::other(format!(
            "此处已在仓库 {} 中，无需重复初始化",
            existing.display()
        )));
    }
    // 目标尚不是仓库：锁粒度取该目录
    let lock_target = dir.clone();
    let _guard = lock::acquire(&lock_target)?;
    git::run(&["init"], &git::RunOptions::local(&dir))?;
    drop(_guard);
    get_repo_info(path)
}

/// 克隆启动结果：repoKey 用于订阅进度与取消
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneStartResult {
    pub repo_key: String,
    /// 克隆目标目录（绝对路径）
    pub target_dir: String,
}

/// 克隆进度事件 payload（事件名 `clone-progress`）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CloneProgress {
    pub repo_key: String,
    /// 0-100；本地克隆等无百分比输出时为 null
    pub percent: Option<u8>,
    /// 进度文本（git stderr 原始行）
    pub text: String,
    pub done: bool,
    pub error: bool,
    /// 失败原因（done=true 且 error=true 时有值）
    pub message: Option<String>,
}

/// 克隆仓库：`git clone --progress <url> <dir>`，异步执行。
/// 进度经 `clone-progress` 事件推送；完成（含失败）也会推送一次 done 事件。
#[tauri::command]
pub fn clone_repo(
    app: tauri::AppHandle,
    path: String,
    url: String,
    dir: Option<String>,
) -> Result<CloneStartResult, GitError> {
    let parent = validate_dir(&path)?;
    let url = url.trim().to_string();
    if url.is_empty() {
        return Err(GitError::other("仓库地址不能为空"));
    }
    let name = match dir.as_deref().map(str::trim) {
        Some(d) if !d.is_empty() => d.to_string(),
        _ => repo_name_from_url(&url),
    };
    validate_folder_name(&name).map_err(GitError::other)?;
    let target = parent.join(&name);
    if target.exists() {
        return Err(GitError::other(format!(
            "目标目录已存在：{}",
            target.display()
        )));
    }

    // repoKey = 目标目录绝对路径，全局唯一
    let repo_key = target.to_string_lossy().into_owned();
    let target_str = repo_key.clone();
    let target_for_clone = target_str.clone();
    let cancel = git::register_cancel(&repo_key);

    let key_for_thread = repo_key.clone();
    std::thread::spawn(move || {
        let cb_key = key_for_thread.clone();
        let app_for_cb = app.clone();
        let opts = git::RunOptions {
            timeout: None, // 克隆不限时，靠取消标记终止
            cancel: Some(cancel),
            on_stderr_text: Some(Arc::new(move |line: &str| {
                let percent = parse_clone_progress(line);
                let _ = app_for_cb.emit(
                    "clone-progress",
                    CloneProgress {
                        repo_key: cb_key.clone(),
                        percent,
                        text: line.to_string(),
                        done: false,
                        error: false,
                        message: None,
                    },
                );
            })),
            // 私有仓库可复用应用内保存的钥匙串凭据。
            ..git::RunOptions::net(parent)
        };

        let result = git::run(
            &["clone", "--progress", "--", &url, &target_for_clone],
            &opts,
        );
        git::unregister_cancel(&key_for_thread);

        let payload = match result {
            Ok(_) => CloneProgress {
                repo_key: key_for_thread.clone(),
                percent: Some(100),
                text: "克隆完成".to_string(),
                done: true,
                error: false,
                message: None,
            },
            Err(e) => CloneProgress {
                repo_key: key_for_thread.clone(),
                percent: None,
                text: e.stderr.clone(),
                done: true,
                error: true,
                message: Some(format!("{}（{}）", e.message, e.kind)),
            },
        };
        let _ = app.emit("clone-progress", payload);
    });

    Ok(CloneStartResult {
        repo_key,
        target_dir: target_str,
    })
}

/// 取消克隆：置位取消标记，执行循环会终止整个 git 进程树
#[tauri::command]
pub fn cancel_clone(repo_key: String) -> Result<(), GitError> {
    git::cancel(&repo_key);
    Ok(())
}

/// 在 Finder 中显示给定路径（克隆完成后的快捷入口）。
#[tauri::command]
pub fn open_in_finder(path: String) -> Result<(), GitError> {
    let target = validate_dir(&path)?;
    #[cfg(target_os = "macos")]
    {
        let status = std::process::Command::new("/usr/bin/open")
            .arg("-R")
            .arg(&target)
            .status()
            .map_err(|error| GitError::other(format!("无法打开 Finder：{error}")))?;
        if !status.success() {
            return Err(GitError::other("Finder 未能显示克隆目录"));
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = target;
        Err(GitError::other("此操作目前仅支持 macOS Finder"))
    }
}

/// 目标文件夹名必须是当前目录下的单个目录名，禁止路径跳转与绝对路径。
fn validate_folder_name(name: &str) -> Result<(), String> {
    let candidate = std::path::Path::new(name);
    let single_normal = candidate.components().count() == 1
        && matches!(
            candidate.components().next(),
            Some(std::path::Component::Normal(_))
        );
    if name.trim().is_empty() || name.contains('\0') || candidate.is_absolute() || !single_normal {
        return Err("目标文件夹名无效：请只填写一个目录名，不要包含路径分隔符".to_string());
    }
    Ok(())
}

/// 从 clone 地址推断目录名：取最后一段并去掉 `.git` 后缀
fn repo_name_from_url(url: &str) -> String {
    let trimmed = url.trim_end_matches('/');
    let last = trimmed.rsplit(['/', '\\']).next().unwrap_or("");
    last.strip_suffix(".git").unwrap_or(last).to_string()
}

/// 从进度行提取百分比：取行内最后一个 "N% (x/y)" 模式
fn parse_clone_progress(line: &str) -> Option<u8> {
    let bytes = line.as_bytes();
    let mut best: Option<u8> = None;
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if i + 1 < bytes.len() && bytes[i] == b'%' && bytes[i + 1] == b' ' {
                if let Ok(v) = line[start..i].parse::<u8>() {
                    if v <= 100 {
                        best = Some(v);
                    }
                }
            }
        } else {
            i += 1;
        }
    }
    best
}
