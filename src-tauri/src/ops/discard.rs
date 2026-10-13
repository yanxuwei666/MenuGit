//! discard.rs —— 放弃修改命令。

use crate::git::{self, GitError};
use crate::ops::with_write_lock;
use crate::repo;

/// 放弃指定文件的本地修改（R4：二次确认由前端负责，这里直接执行）：
/// - 已跟踪：`git restore -- <paths>`
/// - 未跟踪：`git clean -f -- <paths>`
#[tauri::command]
pub fn discard_changes(path: String, files: Vec<String>) -> Result<(), GitError> {
    if files.is_empty() {
        return Ok(());
    }
    with_write_lock(&path, false, |root| {
        let status = repo::collect_status(root)?;
        let is_untracked = |f: &String| status.entries.iter().any(|e| e.untracked && e.path == *f);

        let tracked: Vec<&String> = files.iter().filter(|f| !is_untracked(f)).collect();
        let untracked: Vec<&String> = files.iter().filter(|f| is_untracked(f)).collect();

        if !tracked.is_empty() {
            let mut args: Vec<&str> = vec!["restore", "--"];
            for f in &tracked {
                args.push(f.as_str());
            }
            git::run(&args, &git::RunOptions::local(root))?;
        }
        if !untracked.is_empty() {
            let mut args: Vec<&str> = vec!["clean", "-f", "--"];
            for f in &untracked {
                args.push(f.as_str());
            }
            git::run(&args, &git::RunOptions::local(root))?;
        }
        Ok(())
    })
}
