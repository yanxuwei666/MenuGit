//! status.rs —— 仓库信息与工作区状态命令。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;

use crate::git::{self, GitError};
use crate::ops::{repo_root, validate_dir};
use crate::repo::{self, RepoInfo, StatusFile};

/// 系统 Git 当前提交身份（只读 user.name / user.email，不修改 Git 配置）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthorIdentity {
    pub name: Option<String>,
    pub email: Option<String>,
}

#[tauri::command]
pub fn get_author_identity(path: String) -> Result<AuthorIdentity, GitError> {
    let root = repo_root(&path)?;
    let read_config = |key: &str| {
        git::run(&["config", "--get", key], &git::RunOptions::local(&root))
            .ok()
            .map(|out| out.stdout.trim().to_string())
            .filter(|value| !value.is_empty())
    };
    Ok(AuthorIdentity {
        name: read_config("user.name"),
        email: read_config("user.email"),
    })
}

/// 仓库概要：根目录 / 是否仓库 / 分支 / 上游 / 领先落后 / 合并冲突状态。
/// 目录不是仓库时返回 `isRepo: false` 而非报错，便于前端切换初始化/克隆视图。
#[tauri::command]
pub fn get_repo_info(path: String) -> Result<RepoInfo, GitError> {
    let dir = validate_dir(&path)?;
    let Some(root) = repo::find_repo_root(&dir) else {
        return Ok(RepoInfo {
            path: None,
            is_repo: false,
            branch: None,
            detached: false,
            upstream: None,
            ahead: 0,
            behind: 0,
            merge_in_progress: false,
            conflict_file_count: 0,
        });
    };
    let status = repo::collect_status(&root)?;
    let (head_fallback, detached_fallback) = repo::read_head(&root);
    Ok(RepoInfo {
        path: Some(root.to_string_lossy().into_owned()),
        is_repo: true,
        branch: status.head.or(head_fallback),
        detached: status.detached || detached_fallback,
        upstream: status.upstream,
        ahead: status.ahead,
        behind: status.behind,
        merge_in_progress: repo::has_merge_head(&root),
        conflict_file_count: status.entries.iter().filter(|e| e.unmerged).count() as u32,
    })
}

/// 工作区变更文件列表：路径 / 状态 / 旧名→新名 / 增删行数（diff --numstat 汇总）。
#[tauri::command]
pub fn get_status(path: String) -> Result<Vec<StatusFile>, GitError> {
    let root = repo_root(&path)?;
    let status = repo::collect_status(&root)?;
    // 未暂存（工作区 vs 暂存区）与已暂存（暂存区 vs HEAD）各取一次 numstat，按路径累加
    let unstaged = numstat_map(&root, false)?;
    let staged = numstat_map(&root, true)?;

    let mut files = Vec::with_capacity(status.entries.len());
    for entry in &status.entries {
        let (added, deleted, binary) =
            merge_counts(unstaged.get(&entry.path), staged.get(&entry.path));
        files.push(StatusFile {
            path: entry.path.clone(),
            status: repo::status_label(entry).to_string(),
            orig_path: entry.orig_path.clone(),
            added,
            deleted,
            binary,
            staged: !entry.untracked
                && !entry.unmerged
                && entry.xy.as_bytes().first() != Some(&b'.'),
            untracked: entry.untracked,
        });
    }
    Ok(files)
}

/// 执行 numstat 并解析为 路径 → (增, 删, 是否二进制)
fn numstat_map(
    root: &Path,
    cached: bool,
) -> Result<HashMap<String, (Option<u64>, Option<u64>, bool)>, GitError> {
    let out = if cached {
        git::run(
            &["diff", "--cached", "--numstat", "-z"],
            &git::RunOptions::local(root),
        )?
    } else {
        git::run(&["diff", "--numstat", "-z"], &git::RunOptions::local(root))?
    };
    Ok(repo::parse_numstat_z(&out.stdout))
}

/// 合并两份 numstat 计数：任一二进制则整体按二进制处理
fn merge_counts(
    a: Option<&(Option<u64>, Option<u64>, bool)>,
    b: Option<&(Option<u64>, Option<u64>, bool)>,
) -> (Option<u64>, Option<u64>, bool) {
    match (a, b) {
        (None, None) => (None, None, false),
        (Some(x), None) => *x,
        (None, Some(x)) => *x,
        (Some(x), Some(y)) => {
            if x.2 || y.2 {
                (None, None, true)
            } else {
                (sum(x.0, y.0), sum(x.1, y.1), false)
            }
        }
    }
}

fn sum(a: Option<u64>, b: Option<u64>) -> Option<u64> {
    match (a, b) {
        (None, None) => None,
        (x, y) => Some(x.unwrap_or(0) + y.unwrap_or(0)),
    }
}
