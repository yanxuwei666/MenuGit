//! ops —— 各功能 Tauri 命令实现（技术方案 §3.1）。
//!
//! 子模块按功能划分；本文件提供所有写操作共用的入口：
//! 入参校验（目录存在、非绝对路径）→ 合并冲突状态拦截（R3）→ 获取仓库写锁 → 执行。

pub mod branch;
pub mod conflict;
pub mod discard;
pub mod diff;
pub mod initclone;
pub mod logop;
pub mod stage;
pub mod status;
pub mod sync;

use std::path::{Path, PathBuf};

use crate::git::GitError;
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
