//! diff.rs —— 单文件差异命令。

use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::repo_root;
use crate::repo;

/// 单文件 diff 结果
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffResult {
    /// 是否二进制文件（numstat 输出 "-" 或 diff 提示 Binary）
    pub is_binary: bool,
    /// diff 文本；二进制时为原始提示文本
    pub text: String,
}

/// 获取单文件 diff 文本：
/// - 已跟踪：`git diff --no-color [--cached] -- <file>`
/// - 未跟踪：`git diff --no-color --no-index /dev/null <file>`（有差异时退出码为 1，属正常）
#[tauri::command]
pub fn get_diff(path: String, file: String, staged: Option<bool>) -> Result<DiffResult, GitError> {
    let root = repo_root(&path)?;
    if Path::new(&file).is_absolute() {
        return Err(GitError::other("file 必须是仓库内相对路径"));
    }
    let staged = staged.unwrap_or(false);

    let status = repo::collect_status(&root)?;
    let is_untracked = status.entries.iter().any(|e| e.untracked && e.path == file);
    if is_untracked {
        let opts = git::RunOptions {
            accept_exit_codes: vec![1],
            ..git::RunOptions::local(&root)
        };
        let out = git::run(
            &["diff", "--no-color", "--no-index", "/dev/null", &file],
            &opts,
        )?;
        return Ok(DiffResult {
            is_binary: out.stdout.contains("Binary files "),
            text: out.stdout,
        });
    }

    let out = if staged {
        git::run(&["diff", "--no-color", "--cached", "--", &file], &git::RunOptions::local(&root))?
    } else {
        git::run(&["diff", "--no-color", "--", &file], &git::RunOptions::local(&root))?
    };
    Ok(DiffResult {
        is_binary: out.stdout.contains("Binary files "),
        text: out.stdout,
    })
}
