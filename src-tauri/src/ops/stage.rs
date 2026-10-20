//! stage.rs —— 暂存与提交命令。

use serde::{Deserialize, Serialize};
use std::path::{Component, Path};

use crate::git::{self, GitError};
use crate::ops::with_write_lock;
use crate::repo;

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

/// 提交勾选文件：先暂存所选路径，再通过 `--only` 限定本次提交范围。
/// 未勾选但已由其他工具暂存的文件会继续留在暂存区，不会被意外提交。
#[tauri::command]
pub fn commit(path: String, message: String, files: Vec<String>) -> Result<CommitResult, GitError> {
    if files.is_empty() {
        return Err(GitError::other("请至少选择一个文件后再提交"));
    }

    with_write_lock(&path, false, |root| {
        let status = repo::collect_status(root)?;
        let mut pathspecs = Vec::with_capacity(files.len());
        for file in &files {
            let candidate = Path::new(file);
            if candidate.is_absolute()
                || candidate.components().any(|part| {
                    matches!(
                        part,
                        Component::ParentDir | Component::RootDir | Component::Prefix(_)
                    )
                })
            {
                return Err(GitError::other("提交文件必须是仓库内的相对路径"));
            }
            if !status.entries.iter().any(|entry| entry.path == *file) {
                return Err(GitError::other(format!("文件已不再有变更：{file}")));
            }
            pathspecs.push(format!(":(literal){file}"));
        }

        let mut add_args: Vec<&str> = vec!["add", "-A", "--"];
        add_args.extend(pathspecs.iter().map(String::as_str));
        git::run(&add_args, &git::RunOptions::local(root))?;

        let mut opts = git::RunOptions::local(root);
        opts.stdin_data = Some(message.into_bytes());
        let mut commit_args: Vec<&str> = vec!["commit", "--only", "-F", "-", "--"];
        commit_args.extend(pathspecs.iter().map(String::as_str));
        git::run(&commit_args, &opts)?;
        let head = git::run(&["rev-parse", "HEAD"], &git::RunOptions::local(root))?;
        Ok(CommitResult {
            hash: head.stdout.trim().to_string(),
        })
    })
}

#[cfg(test)]
mod tests {
    use super::commit;
    use crate::repo;
    use std::path::PathBuf;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestRepo(PathBuf);

    impl TestRepo {
        fn new() -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path =
                std::env::temp_dir().join(format!("menugit-test-{}-{nonce}", std::process::id()));
            std::fs::create_dir_all(&path).unwrap();
            run_git(&path, &["init", "--quiet"]);
            run_git(&path, &["config", "user.name", "MenuGit Test"]);
            run_git(
                &path,
                &["config", "user.email", "menugit-test@example.invalid"],
            );
            run_git(&path, &["config", "commit.gpgsign", "false"]);
            let hooks = path.join(".empty-hooks");
            std::fs::create_dir_all(&hooks).unwrap();
            let hooks_path = hooks.to_string_lossy().into_owned();
            run_git(&path, &["config", "core.hooksPath", &hooks_path]);
            Self(path)
        }

        fn path(&self) -> &std::path::Path {
            &self.0
        }
    }

    impl Drop for TestRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn run_git(repo: &std::path::Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .args(args)
            .current_dir(repo)
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

    #[test]
    fn commit_only_includes_selected_files_and_preserves_other_staged_files() {
        let repo = TestRepo::new();
        std::fs::write(repo.path().join("selected.txt"), "before\n").unwrap();
        std::fs::write(repo.path().join("deferred.txt"), "before\n").unwrap();
        run_git(repo.path(), &["add", "--", "selected.txt", "deferred.txt"]);
        run_git(repo.path(), &["commit", "--quiet", "-m", "baseline"]);

        std::fs::write(repo.path().join("selected.txt"), "after\n").unwrap();
        std::fs::write(repo.path().join("deferred.txt"), "deferred\n").unwrap();
        std::fs::write(repo.path().join("new file.txt"), "new\n").unwrap();
        std::fs::write(repo.path().join(":(glob)*.txt"), "literal path\n").unwrap();
        std::fs::write(repo.path().join("wildcard.txt"), "must stay untracked\n").unwrap();
        run_git(repo.path(), &["add", "--", "deferred.txt"]);

        let result = commit(
            repo.path().to_string_lossy().into_owned(),
            "selected changes".to_string(),
            vec![
                "selected.txt".to_string(),
                "new file.txt".to_string(),
                ":(glob)*.txt".to_string(),
            ],
        )
        .unwrap();
        assert!(result.hash.len() == 40 || result.hash.len() == 64);

        let committed = run_git(
            repo.path(),
            &["diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"],
        );
        let mut committed_files: Vec<_> = committed.lines().collect();
        committed_files.sort_unstable();
        assert_eq!(
            committed_files,
            [":(glob)*.txt", "new file.txt", "selected.txt"]
        );

        let remaining = repo::collect_status(repo.path()).unwrap();
        let deferred = remaining
            .entries
            .iter()
            .find(|entry| entry.path == "deferred.txt")
            .unwrap();
        assert_eq!(deferred.xy, "M.");
        assert!(remaining
            .entries
            .iter()
            .any(|entry| entry.path == "wildcard.txt"));
    }

    #[test]
    fn commit_rejects_empty_selection() {
        let result = commit(
            "/not/a/repository".to_string(),
            "message".to_string(),
            vec![],
        );
        assert!(result.is_err());
    }
}
