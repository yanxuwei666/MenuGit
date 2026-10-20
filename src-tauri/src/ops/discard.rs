//! discard.rs —— 放弃修改命令。

use std::collections::HashSet;

use crate::git::{self, GitError};
use crate::ops::{literal_pathspec, validate_relative_path, with_write_lock};
use crate::repo;

/// 放弃指定文件的本地修改（R4：二次确认由前端负责，这里直接执行）。
///
/// 语义是"还原到 HEAD"（PRD FM-07），因此暂存区和工作区都要还原：
/// - HEAD 中存在的已跟踪文件：`git restore --source=HEAD --staged --worktree`
/// - 暂存区新增（HEAD 中不存在）：移出索引并删除工作区文件（含重命名的新路径）
/// - 未跟踪文件/目录：`git clean -f -d`
#[tauri::command]
pub fn discard_changes(path: String, files: Vec<String>) -> Result<(), GitError> {
    if files.is_empty() {
        return Ok(());
    }
    for file in &files {
        validate_relative_path(file)?;
    }
    with_write_lock(&path, false, |root| {
        let status = repo::collect_status(root)?;

        if let Some(stale) = files
            .iter()
            .find(|file| !status.entries.iter().any(|entry| entry.path == **file))
        {
            return Err(GitError::other(format!(
                "文件状态已变化：{stale}。请刷新列表后重试。"
            )));
        }

        // 选中的是状态列表里的路径；重命名还需要把旧路径一起还原。
        let selected: Vec<&repo::PorcelainEntry> = files
            .iter()
            .filter_map(|file| status.entries.iter().find(|entry| entry.path == *file))
            .collect();
        let untracked: Vec<&repo::PorcelainEntry> =
            selected.iter().copied().filter(|e| e.untracked).collect();
        let tracked: Vec<&repo::PorcelainEntry> =
            selected.iter().copied().filter(|e| !e.untracked).collect();

        // HEAD 中存在的路径才能 restore；新增文件和重命名新路径要单独处理。
        let mut head_paths: HashSet<String> = HashSet::new();
        if status.has_commits && !tracked.is_empty() {
            let mut candidates: Vec<String> = Vec::new();
            for entry in &tracked {
                candidates.push(entry.path.clone());
                if let Some(orig) = &entry.orig_path {
                    candidates.push(orig.clone());
                }
            }
            let mut args: Vec<String> = vec![
                "ls-tree".into(),
                "-z".into(),
                "--name-only".into(),
                "HEAD".into(),
                "--".into(),
            ];
            args.extend(candidates.iter().map(|p| literal_pathspec(p)));
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            let output = git::run(&refs, &git::RunOptions::local(root))?;
            head_paths.extend(
                output
                    .stdout
                    .split('\0')
                    .filter(|p| !p.is_empty())
                    .map(String::from),
            );
        }

        let mut restore: Vec<String> = Vec::new();
        let mut remove_from_index: Vec<String> = Vec::new();
        for entry in &tracked {
            if let Some(orig) = &entry.orig_path {
                // 重命名：旧路径一定来自 HEAD，还原它即可撤销；新路径从索引和工作区移除。
                restore.push(orig.clone());
                remove_from_index.push(entry.path.clone());
            } else if head_paths.contains(&entry.path) {
                restore.push(entry.path.clone());
            } else {
                remove_from_index.push(entry.path.clone());
            }
        }

        if !restore.is_empty() {
            let mut args: Vec<String> = vec![
                "restore".into(),
                "--source=HEAD".into(),
                "--staged".into(),
                "--worktree".into(),
                "--".into(),
            ];
            args.extend(restore.iter().map(|p| literal_pathspec(p)));
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            git::run(&refs, &git::RunOptions::local(root))?;
        }
        if !remove_from_index.is_empty() {
            let mut args: Vec<String> = vec!["rm".into(), "--cached".into(), "-f".into(), "--".into()];
            args.extend(remove_from_index.iter().map(|p| literal_pathspec(p)));
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            git::run(&refs, &git::RunOptions::local(root))?;
        }

        // 未跟踪文件与刚从索引移除的新增文件都回到未跟踪状态，统一清理。
        let mut clean: Vec<String> = untracked.iter().map(|e| e.path.clone()).collect();
        clean.extend(remove_from_index);
        if !clean.is_empty() {
            let mut args: Vec<String> = vec!["clean".into(), "-f".into(), "-d".into(), "--".into()];
            args.extend(clean.iter().map(|p| literal_pathspec(p)));
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            git::run(&refs, &git::RunOptions::local(root))?;
        }
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::discard_changes;
    use crate::repo;
    use std::process::Command;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestRepo(std::path::PathBuf);

    impl TestRepo {
        fn new() -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "menugit-discard-test-{}-{nonce}",
                std::process::id()
            ));
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
    }

    impl Drop for TestRepo {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn run_git(repo: &std::path::Path, args: &[&str]) {
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
    }

    #[test]
    fn discard_treats_git_pathspec_syntax_as_a_literal_filename() {
        let repo = TestRepo::new();
        let tracked_magic = ":(glob)*.tracked";
        std::fs::write(repo.0.join(tracked_magic), "before\n").unwrap();
        std::fs::write(repo.0.join("other.tracked"), "before\n").unwrap();
        run_git(
            &repo.0,
            &[
                "add",
                "--",
                &format!(":(literal){tracked_magic}"),
                "other.tracked",
            ],
        );
        run_git(&repo.0, &["commit", "--quiet", "-m", "baseline"]);

        std::fs::write(repo.0.join(tracked_magic), "changed\n").unwrap();
        std::fs::write(repo.0.join("other.tracked"), "keep changed\n").unwrap();
        discard_changes(
            repo.0.to_string_lossy().into_owned(),
            vec![tracked_magic.to_string()],
        )
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(repo.0.join(tracked_magic)).unwrap(),
            "before\n"
        );
        assert_eq!(
            std::fs::read_to_string(repo.0.join("other.tracked")).unwrap(),
            "keep changed\n"
        );

        let untracked_magic = ":(glob)*.txt";
        std::fs::write(repo.0.join(untracked_magic), "delete only this\n").unwrap();
        std::fs::write(repo.0.join("other.txt"), "keep this\n").unwrap();
        let diff = crate::ops::diff::get_diff(
            repo.0.to_string_lossy().into_owned(),
            untracked_magic.to_string(),
            None,
        )
        .unwrap();
        assert!(diff.text.contains("+delete only this"));
        discard_changes(
            repo.0.to_string_lossy().into_owned(),
            vec![untracked_magic.to_string()],
        )
        .unwrap();
        assert!(!repo.0.join(untracked_magic).exists());
        assert!(repo.0.join("other.txt").exists());
    }

    #[test]
    fn discard_restores_staged_changes_to_head() {
        let repo = TestRepo::new();
        std::fs::write(repo.0.join("tracked.txt"), "v1\n").unwrap();
        run_git(&repo.0, &["add", "tracked.txt"]);
        run_git(&repo.0, &["commit", "--quiet", "-m", "baseline"]);

        // 先暂存，再在暂存内容之上继续改工作区：两处都必须还原到 HEAD。
        std::fs::write(repo.0.join("tracked.txt"), "staged\n").unwrap();
        run_git(&repo.0, &["add", "tracked.txt"]);
        std::fs::write(repo.0.join("tracked.txt"), "worktree\n").unwrap();

        discard_changes(
            repo.0.to_string_lossy().into_owned(),
            vec!["tracked.txt".to_string()],
        )
        .unwrap();

        assert_eq!(
            std::fs::read_to_string(repo.0.join("tracked.txt")).unwrap(),
            "v1\n"
        );
        let status = repo::collect_status(&repo.0).unwrap();
        assert!(status.entries.is_empty(), "工作区与暂存区都应干净");
    }

    #[test]
    fn discard_removes_staged_new_file() {
        let repo = TestRepo::new();
        std::fs::write(repo.0.join("base.txt"), "base\n").unwrap();
        run_git(&repo.0, &["add", "base.txt"]);
        run_git(&repo.0, &["commit", "--quiet", "-m", "baseline"]);

        std::fs::write(repo.0.join("added.txt"), "new\n").unwrap();
        run_git(&repo.0, &["add", "added.txt"]);

        discard_changes(
            repo.0.to_string_lossy().into_owned(),
            vec!["added.txt".to_string()],
        )
        .unwrap();

        assert!(!repo.0.join("added.txt").exists());
        let status = repo::collect_status(&repo.0).unwrap();
        assert!(status.entries.is_empty(), "新增文件应完全移除");
    }

    #[test]
    fn discard_reverts_rename_to_head_path() {
        let repo = TestRepo::new();
        std::fs::write(repo.0.join("old.txt"), "content\n").unwrap();
        run_git(&repo.0, &["add", "old.txt"]);
        run_git(&repo.0, &["commit", "--quiet", "-m", "baseline"]);
        run_git(&repo.0, &["mv", "old.txt", "new.txt"]);

        discard_changes(
            repo.0.to_string_lossy().into_owned(),
            vec!["new.txt".to_string()],
        )
        .unwrap();

        assert!(repo.0.join("old.txt").exists());
        assert!(!repo.0.join("new.txt").exists());
        let status = repo::collect_status(&repo.0).unwrap();
        assert!(status.entries.is_empty(), "重命名应还原为 HEAD 状态");
    }
}
