//! lock.rs —— 每仓库粒度的并发写锁（R3）。
//!
//! 内存级互斥：同一仓库同一时刻只允许一个写操作；合并冲突未解决时由调用方
//! （`ops::with_write_lock`）拦截其他写操作，被拦截统一返回 Locked 错误。

use std::collections::HashSet;
use std::path::Path;
use std::sync::{Mutex, OnceLock};

use crate::git::GitError;

static LOCKS: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

fn locks() -> &'static Mutex<HashSet<String>> {
    LOCKS.get_or_init(Default::default)
}

/// 写锁守卫：Drop 时自动释放
pub struct WriteGuard {
    key: String,
}

impl Drop for WriteGuard {
    fn drop(&mut self) {
        if let Some(set) = LOCKS.get() {
            set.lock().unwrap().remove(&self.key);
        }
    }
}

/// 锁键：规范化后的仓库根绝对路径（Windows 忽略大小写）
fn lock_key(root: &Path) -> String {
    #[cfg(windows)]
    {
        std::fs::canonicalize(root)
            .map(|p| p.to_string_lossy().to_lowercase())
            .unwrap_or_else(|_| root.to_string_lossy().to_lowercase())
    }
    #[cfg(not(windows))]
    {
        std::fs::canonicalize(root)
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| root.to_string_lossy().into_owned())
    }
}

/// 尝试获取指定仓库的写锁；已有写操作在执行时返回 Locked 错误（R3）
pub fn acquire(repo_root: &Path) -> Result<WriteGuard, GitError> {
    let key = lock_key(repo_root);
    let mut set = locks().lock().unwrap();
    if set.contains(&key) {
        return Err(GitError::locked("该仓库正有其他写操作进行中，请稍后再试"));
    }
    set.insert(key.clone());
    Ok(WriteGuard { key })
}
