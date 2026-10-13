//! sync.rs —— 推送 / 拉取命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::with_write_lock;
use crate::repo;

/// 拉取结果摘要
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PullResult {
    /// 拉入的提交数（解析失败为 null）
    pub commits: Option<u64>,
    /// 更新的文件数（解析失败为 null）
    pub files_changed: Option<u64>,
    /// 原始输出（前端可展开查看）
    pub raw: String,
}

/// 推送：`git push [-u] origin <branch>`。
/// branch 缺省取当前分支；setUpstream=true 时加 `-u`（新建远端分支并记住上游）。
/// 失败原因由 git.rs 统一分类：rejected → 提示先拉取；auth/network → stderr 透传。
#[tauri::command]
pub fn push(path: String, branch: Option<String>, set_upstream: Option<bool>) -> Result<(), GitError> {
    with_write_lock(&path, false, |root| {
        let branch = match branch {
            Some(b) if !b.trim().is_empty() => b,
            _ => {
                let status = repo::collect_status(root)?;
                status
                    .head
                    .filter(|_| status.has_commits)
                    .ok_or_else(|| GitError::other("当前处于 detached HEAD，请先切换到分支"))?
            }
        };
        let mut args: Vec<&str> = vec!["push"];
        if set_upstream.unwrap_or(false) {
            args.push("-u");
        }
        args.push("origin");
        args.push(&branch);
        git::run(&args, &git::RunOptions::net(root))?;
        Ok(())
    })
}

/// 拉取：默认 `git pull`（遵循系统 pull 配置，不干预，R2）；
/// 指定 branch 时 `git pull origin <branch>`；setUpstream=true 时拉取后记住上游。
/// 返回摘要（拉入提交数 / 更新文件数），解析不出时回传原始输出。
#[tauri::command]
pub fn pull(
    path: String,
    branch: Option<String>,
    set_upstream: Option<bool>,
) -> Result<PullResult, GitError> {
    with_write_lock(&path, false, |root| {
        // 记录拉取前 HEAD，用于统计拉入提交数（unborn 仓库忽略）
        let old_head = git::run(&["rev-parse", "HEAD"], &git::RunOptions::local(root))
            .ok()
            .map(|o| o.stdout.trim().to_string())
            .filter(|s| !s.is_empty());

        let out = match &branch {
            Some(b) if !b.trim().is_empty() => {
                git::run(&["pull", "origin", b], &git::RunOptions::net(root))?
            }
            _ => git::run(&["pull"], &git::RunOptions::net(root))?,
        };

        // 记住上游：git branch --set-upstream-to=origin/<b> <b>
        if set_upstream.unwrap_or(false) {
            if let Some(b) = branch.as_deref() {
                let flag = format!("--set-upstream-to=origin/{b}");
                let _ = git::run(&["branch", &flag, b], &git::RunOptions::local(root));
            }
        }

        // merge 摘要在 stdout（"N files changed, ..."），fetch 进度在 stderr
        let raw = format!("{}\n{}", out.stdout, out.stderr);
        let files_changed = parse_files_changed(&raw);
        let commits = old_head.and_then(|old| {
            let range = format!("{old}..HEAD");
            git::run(&["rev-list", "--count", &range], &git::RunOptions::local(root))
                .ok()
                .and_then(|o| o.stdout.trim().parse().ok())
        });
        Ok(PullResult { commits, files_changed, raw })
    })
}

/// 从 "N files changed, ..." 摘要行提取更新的文件数
fn parse_files_changed(text: &str) -> Option<u64> {
    for line in text.lines() {
        let Some(idx) = line.find(" changed") else { continue };
        // 取 " changed" 之前紧邻的数字，如 " 3 files changed" → 3
        let digits: String = line[..idx]
            .trim()
            .chars()
            .rev()
            .skip_while(|c| !c.is_ascii_digit())
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .chars()
            .rev()
            .collect();
        if let Ok(n) = digits.parse() {
            return Some(n);
        }
    }
    None
}
