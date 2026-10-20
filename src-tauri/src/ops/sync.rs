//! sync.rs —— 推送 / 拉取命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::{validate_branch_name, with_write_lock};
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

/// 规范化远端目标分支名：允许用户输入 origin/xxx，实际 ref 只取 xxx。
fn normalize_remote_branch(branch: &str) -> Result<String, GitError> {
    let name = branch.trim();
    let name = name.strip_prefix("origin/").unwrap_or(name);
    let name = name.strip_prefix("refs/heads/").unwrap_or(name);
    validate_branch_name(name)?;
    Ok(name.to_string())
}

/// 推送：`git push [-u] origin HEAD:<branch>`。
/// branch 缺省取当前分支；没有上游或新建远端分支时自动加 `-u` 记住上游。
/// 失败原因由 git.rs 统一分类：rejected → 提示先拉取；auth/network → stderr 透传。
#[tauri::command]
pub fn push(
    path: String,
    branch: Option<String>,
    set_upstream: Option<bool>,
) -> Result<(), GitError> {
    with_write_lock(&path, false, |root| {
        let status = repo::collect_status(root)?;
        if status.detached {
            return Err(GitError::other("当前处于 detached HEAD，请先切换到分支"));
        }
        if !status.has_commits {
            return Err(GitError::other("还没有任何提交，无法推送"));
        }
        let branch = match branch {
            Some(b) if !b.trim().is_empty() => normalize_remote_branch(&b)?,
            _ => status
                .head
                .clone()
                .ok_or_else(|| GitError::other("无法确定当前分支，请刷新后重试"))?,
        };
        // 无上游时必须建立跟踪，否则后续状态无法显示领先/落后。
        let set_upstream = set_upstream.unwrap_or(false) || status.upstream.is_none();
        let mut args: Vec<&str> = vec!["push"];
        if set_upstream {
            args.push("-u");
        }
        args.push("origin");
        // 目标名称可以不同于本地分支；HEAD 明确表示推送当前检出提交。
        let refspec = format!("HEAD:{branch}");
        args.push(&refspec);
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
        let branch = branch
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(normalize_remote_branch)
            .transpose()?;
        // 记录拉取前 HEAD，用于统计拉入提交数（unborn 仓库忽略）
        let old_head = git::run(&["rev-parse", "HEAD"], &git::RunOptions::local(root))
            .ok()
            .map(|o| o.stdout.trim().to_string())
            .filter(|s| !s.is_empty());

        let out = match &branch {
            Some(b) => git::run(&["pull", "origin", b], &git::RunOptions::net(root))?,
            _ => git::run(&["pull"], &git::RunOptions::net(root))?,
        };

        // 记住上游：显式勾选，或当前分支本来没有上游（PRD FM-03）。
        if let Some(b) = branch.as_deref() {
            let status = repo::collect_status(root)?;
            if set_upstream.unwrap_or(false) || status.upstream.is_none() {
                if let Some(current) = status.head {
                    let flag = format!("--set-upstream-to=origin/{b}");
                    git::run(&["branch", &flag, &current], &git::RunOptions::local(root))?;
                }
            }
        }

        // merge 摘要在 stdout（"N files changed, ..."），fetch 进度在 stderr
        let raw = format!("{}\n{}", out.stdout, out.stderr);
        let files_changed = parse_files_changed(&raw);
        let commits = old_head.and_then(|old| {
            let range = format!("{old}..HEAD");
            git::run(
                &["rev-list", "--count", &range],
                &git::RunOptions::local(root),
            )
            .ok()
            .and_then(|o| o.stdout.trim().parse().ok())
        });
        Ok(PullResult {
            commits,
            files_changed,
            raw,
        })
    })
}

/// 从 "N files changed, ..." 摘要行提取更新的文件数
fn parse_files_changed(text: &str) -> Option<u64> {
    for line in text.lines() {
        let Some(idx) = line.find(" changed") else {
            continue;
        };
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

#[cfg(test)]
mod tests {
    use super::{pull, push};
    use crate::ops::{branch, logop, status};
    use std::path::{Path, PathBuf};
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir()
                .join(format!("menugit-sync-test-{}-{nonce}", std::process::id()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn run_git(cwd: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .args(args)
            .current_dir(cwd)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).trim().to_string()
    }

    fn configure_identity(repo: &Path) {
        run_git(repo, &["config", "user.name", "MenuGit Test"]);
        run_git(
            repo,
            &["config", "user.email", "menugit-test@example.invalid"],
        );
        run_git(repo, &["config", "commit.gpgsign", "false"]);
        let hooks = repo.join(".empty-hooks");
        std::fs::create_dir_all(&hooks).unwrap();
        run_git(
            repo,
            &[
                "config",
                "core.hooksPath",
                hooks.to_str().expect("temporary path is UTF-8"),
            ],
        );
    }

    #[test]
    fn local_push_pull_branch_and_log_commands_complete_offline_roundtrip() {
        let root = TestDir::new();
        let remote = root.0.join("origin.git");
        let local = root.0.join("local");
        let peer = root.0.join("peer");
        std::fs::create_dir_all(&local).unwrap();
        run_git(
            &root.0,
            &["init", "--bare", "--quiet", remote.to_str().unwrap()],
        );
        run_git(
            &root.0,
            &[
                "--git-dir",
                remote.to_str().unwrap(),
                "symbolic-ref",
                "HEAD",
                "refs/heads/main",
            ],
        );

        run_git(&local, &["init", "--quiet"]);
        configure_identity(&local);
        run_git(&local, &["switch", "--quiet", "-c", "main"]);
        std::fs::write(local.join("base.txt"), "base\n").unwrap();
        run_git(&local, &["add", "--", "base.txt"]);
        run_git(&local, &["commit", "--quiet", "-m", "initial"]);
        run_git(
            &local,
            &["remote", "add", "origin", remote.to_str().unwrap()],
        );

        push(
            local.to_string_lossy().into_owned(),
            Some("main".to_string()),
            Some(true),
        )
        .unwrap();
        assert_eq!(
            status::get_repo_info(local.to_string_lossy().into_owned())
                .unwrap()
                .upstream
                .as_deref(),
            Some("origin/main")
        );

        run_git(
            &root.0,
            &[
                "clone",
                "--quiet",
                remote.to_str().unwrap(),
                peer.to_str().unwrap(),
            ],
        );
        configure_identity(&peer);
        std::fs::write(peer.join("incoming.txt"), "remote update\n").unwrap();
        run_git(&peer, &["add", "--", "incoming.txt"]);
        run_git(&peer, &["commit", "--quiet", "-m", "remote update"]);
        run_git(&peer, &["push", "--quiet", "origin", "HEAD:main"]);

        let pulled = pull(
            local.to_string_lossy().into_owned(),
            Some("main".to_string()),
            Some(true),
        )
        .unwrap();
        assert_eq!(pulled.commits, Some(1));
        assert_eq!(pulled.files_changed, Some(1));
        assert_eq!(
            std::fs::read_to_string(local.join("incoming.txt")).unwrap(),
            "remote update\n"
        );

        branch::switch_branch(
            local.to_string_lossy().into_owned(),
            "feature/test".to_string(),
            Some(true),
        )
        .unwrap();
        assert_eq!(
            branch::list_branches(local.to_string_lossy().into_owned())
                .unwrap()
                .current
                .as_deref(),
            Some("feature/test")
        );

        let entries =
            logop::get_log(local.to_string_lossy().into_owned(), None, None, None, None).unwrap();
        assert_eq!(entries[0].subject, "remote update");
        let detail = logop::get_log_detail(
            local.to_string_lossy().into_owned(),
            entries[0].hash.clone(),
        )
        .unwrap();
        assert!(detail.files.iter().any(|file| file.path == "incoming.txt"));
        let diff = logop::get_commit_file_diff(
            local.to_string_lossy().into_owned(),
            entries[0].hash.clone(),
            "incoming.txt".to_string(),
        )
        .unwrap();
        assert!(diff.contains("+remote update"));
    }
}
