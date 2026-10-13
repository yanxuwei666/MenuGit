//! stage.rs —— 暂存与提交命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::with_write_lock;

/// 提交结果
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResult {
    /// 新提交的完整 hash
    pub hash: String,
}

/// 批量暂存：统一 `git add -A -- <paths>`（新增/修改/删除通用，PRD 勾选模型）
#[tauri::command]
pub fn stage_files(path: String, files: Vec<String>) -> Result<(), GitError> {
    if files.is_empty() {
        return Ok(());
    }
    with_write_lock(&path, false, |root| {
        let mut args: Vec<&str> = vec!["add", "-A", "--"];
        for f in &files {
            args.push(f);
        }
        git::run(&args, &git::RunOptions::local(root))?;
        Ok(())
    })
}

/// 提交：提交信息经 stdin 走 `git commit -F -`（避免命令行转义问题），返回新提交 hash
#[tauri::command]
pub fn commit(path: String, message: String) -> Result<CommitResult, GitError> {
    with_write_lock(&path, false, |root| {
        let mut opts = git::RunOptions::local(root);
        opts.stdin_data = Some(message.into_bytes());
        git::run(&["commit", "-F", "-"], &opts)?;
        let head = git::run(&["rev-parse", "HEAD"], &git::RunOptions::local(root))?;
        Ok(CommitResult { hash: head.stdout.trim().to_string() })
    })
}
