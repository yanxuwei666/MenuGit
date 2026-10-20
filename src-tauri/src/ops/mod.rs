//! ops —— 各功能 Tauri 命令实现（技术方案 §3.1）。
//!
//! 子模块按功能划分；本文件提供所有写操作共用的入口：
//! 入参校验（目录存在、非绝对路径）→ 合并冲突状态拦截（R3）→ 获取仓库写锁 → 执行。

pub mod auth;
pub mod branch;
pub mod conflict;
pub mod diff;
pub mod discard;
pub mod initclone;
pub mod logop;
pub mod stage;
pub mod status;
pub mod sync;

use std::path::{Path, PathBuf};

use crate::git::{self, GitError};
use crate::{lock, repo};

/// 校验目录存在，返回路径
pub fn validate_dir(path: &str) -> Result<PathBuf, GitError> {
    let dir = PathBuf::from(path);
    if !dir.is_dir() {
        return Err(GitError::other(format!("目录不存在：{path}")));
    }
    Ok(dir)
}

/// 校验目录并向上定位仓库根；非仓库返回 NotARepo
pub fn repo_root(path: &str) -> Result<PathBuf, GitError> {
    let dir = validate_dir(path)?;
    repo::find_repo_root(&dir).ok_or_else(GitError::not_a_repo)
}

/// 把仓库内相对路径转换成 Git literal pathspec，避免文件名被解释为通配语法。
pub fn literal_pathspec(path: &str) -> String {
    format!(":(literal){path}")
}

/// 校验分支名：交给系统 git 做权威校验，避免自写规则漏项。
pub fn validate_branch_name(name: &str) -> Result<(), GitError> {
    if name.is_empty() || name.trim() != name || name.starts_with('-') {
        return Err(GitError::other("分支名无效：不能为空、包含首尾空格或以 - 开头"));
    }
    match git::run(
        &["check-ref-format", "--branch", name],
        &git::RunOptions::local(std::env::temp_dir()),
    ) {
        Ok(_) => Ok(()),
        Err(_) => Err(GitError::other("分支名无效：不能包含空格或特殊字符")),
    }
}

/// 拒绝绝对路径和向上跳出仓库的相对路径。
pub fn validate_relative_path(path: &str) -> Result<(), GitError> {
    let candidate = Path::new(path);
    if candidate.is_absolute()
        || candidate.components().any(|component| {
            matches!(
                component,
                std::path::Component::ParentDir | std::path::Component::Prefix(_)
            )
        })
    {
        return Err(GitError::other("文件路径必须位于仓库内"));
    }
    Ok(())
}

/// 写操作统一入口（R3）：
/// 1. 校验 path 存在且为仓库根；
/// 2. 除冲突解决类操作外，处于合并冲突状态时拦截（返回 Locked）；
/// 3. 获取 per-repo 写锁后执行闭包。
pub fn with_write_lock<T>(
    path: &str,
    allow_during_merge: bool,
    f: impl FnOnce(&Path) -> Result<T, GitError>,
) -> Result<T, GitError> {
    let root = repo_root(path)?;
    if !allow_during_merge && repo::has_merge_head(&root) {
        return Err(GitError::locked(
            "存在未完成的合并冲突，请先解决冲突或中止合并",
        ));
    }
    let _guard = lock::acquire(&root)?;
    f(&root)
}
