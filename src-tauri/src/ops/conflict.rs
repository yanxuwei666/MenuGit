//! conflict.rs —— 冲突解决器（技术方案 §3.3）。
//!
//! 拉取冲突后，读取工作区文件内的冲突标记（`<<<<<<<` / `=======` / `>>>>>>>`，
//! 兼容 diff3 的 `|||||||`）解析为结构化块列表；前端渲染三选一（采用本地 /
//! 采用远端 / 保留双方）后，按选择重组写回文件并 `git add`。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::{literal_pathspec, repo_root, validate_relative_path, with_write_lock};
use crate::repo;
use std::path::Path;

use super::stage::CommitResult;

/// 冲突文件中的一段：上下文行或冲突块（带类型标签，前端按 type 渲染）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ConflictSection {
    /// 无冲突上下文行
    Context { lines: Vec<String> },
    /// 冲突块：本地段 / 远端段；diff3 模式下附共同祖先段
    Conflict {
        local: Vec<String>,
        theirs: Vec<String>,
        base: Option<Vec<String>>,
    },
}

/// 冲突文件解析结果
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConflictFileResult {
    pub file: String,
    pub sections: Vec<ConflictSection>,
    /// 冲突块总数
    pub conflict_count: u32,
}

/// 解决结果
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveResult {
    /// 该文件标记已解决后，仓库剩余未解决冲突文件数
    pub remaining_conflicts: u32,
}

/// 读取工作区冲突文件并解析为结构化块列表（前端据此渲染三选一）
#[tauri::command]
pub fn get_conflict_file(path: String, file: String) -> Result<ConflictFileResult, GitError> {
    let root = repo_root(&path)?;
    let full = validate_relative(&root, &file)?;
    let bytes =
        std::fs::read(&full).map_err(|e| GitError::other(format!("读取冲突文件失败：{e}")))?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    let (sections, count) = parse_conflict_text(&text);
    Ok(ConflictFileResult {
        file,
        sections,
        conflict_count: count,
    })
}

/// 按每块选择（local / theirs / both）重组写回文件并 `git add <file>`，
/// 返回仓库剩余未解决冲突文件数
#[tauri::command]
pub fn resolve_conflict_file(
    path: String,
    file: String,
    choices: Vec<String>,
) -> Result<ResolveResult, GitError> {
    with_write_lock(&path, true, |root| {
        let full = validate_relative(root, &file)?;
        let bytes =
            std::fs::read(&full).map_err(|e| GitError::other(format!("读取冲突文件失败：{e}")))?;
        let text = String::from_utf8_lossy(&bytes).into_owned();
        let (sections, count) = parse_conflict_text(&text);
        if choices.len() != count as usize {
            return Err(GitError::other(format!(
                "选择数量（{}）与冲突块数量（{}）不一致，请刷新后重试",
                choices.len(),
                count
            )));
        }
        let choice_refs: Vec<&str> = choices.iter().map(String::as_str).collect();
        let mut rebuilt = rebuild_conflict_text(&sections, &choice_refs)
            .ok_or_else(|| GitError::other("无效的冲突选择，仅支持 local / theirs / both"))?;
        // 原文件末尾没有换行时，重组也不额外补一个，避免每次解决都多出空行。
        if !text.ends_with('\n') && rebuilt.ends_with('\n') {
            rebuilt.pop();
        }
        std::fs::write(&full, rebuilt.as_bytes())
            .map_err(|e| GitError::other(format!("写回冲突文件失败：{e}")))?;
        let file_spec = literal_pathspec(&file);
        git::run(&["add", "--", &file_spec], &git::RunOptions::local(root))?;

        let status = repo::collect_status(root)?;
        Ok(ResolveResult {
            remaining_conflicts: status.entries.iter().filter(|e| e.unmerged).count() as u32,
        })
    })
}

/// 完成合并提交：全部冲突解决后 `git commit -F -` 结束合并状态
#[tauri::command]
pub fn complete_merge(path: String, message: String) -> Result<CommitResult, GitError> {
    with_write_lock(&path, true, |root| {
        if !repo::has_merge_head(root) {
            return Err(GitError::other("当前没有进行中的合并"));
        }
        let mut opts = git::RunOptions::local(root);
        opts.stdin_data = Some(message.into_bytes());
        git::run(&["commit", "-F", "-"], &opts)?;
        let head = git::run(&["rev-parse", "HEAD"], &git::RunOptions::local(root))?;
        Ok(CommitResult {
            hash: head.stdout.trim().to_string(),
        })
    })
}

/// 中止合并：`git merge --abort`（前端需二次确认，R4）
#[tauri::command]
pub fn abort_merge(path: String) -> Result<(), GitError> {
    with_write_lock(&path, true, |root| {
        if !repo::has_merge_head(root) {
            return Err(GitError::other("当前没有进行中的合并"));
        }
        git::run(&["merge", "--abort"], &git::RunOptions::local(root))?;
        Ok(())
    })
}

/// 校验 file 为仓库内相对路径，返回绝对路径
fn validate_relative(root: &Path, file: &str) -> Result<std::path::PathBuf, GitError> {
    validate_relative_path(file)?;
    Ok(root.join(file))
}

/// 按行解析冲突标记。保留各行原始内容（含 \r），以便重组时维持原文件的 EOL 风格。
/// 返回 (段落列表, 冲突块数)。
pub fn parse_conflict_text(text: &str) -> (Vec<ConflictSection>, u32) {
    if text.is_empty() {
        return (Vec::new(), 0);
    }
    // 末尾换行只是行终止符，不应解析成额外的空行；重组时统一逐行补回。
    let body = text.strip_suffix('\n').unwrap_or(text);
    let raw_lines: Vec<&str> = body.split('\n').collect();

    let mut sections: Vec<ConflictSection> = Vec::new();
    let mut context: Vec<String> = Vec::new();
    let mut count: u32 = 0;
    let mut i = 0;
    while i < raw_lines.len() {
        let line = strip_carriage_return(raw_lines[i]);
        if line.starts_with("<<<<<<<") {
            // 冲突块开始：先落盘已积累的上下文
            if !context.is_empty() {
                sections.push(ConflictSection::Context {
                    lines: std::mem::take(&mut context),
                });
            }
            i += 1;
            let mut local: Vec<String> = Vec::new();
            let mut base: Option<Vec<String>> = None;
            let mut theirs: Vec<String> = Vec::new();
            let mut phase = 0u8; // 0 = 本地段, 1 = 祖先段(diff3), 2 = 远端段
            while i < raw_lines.len() {
                let marker = strip_carriage_return(raw_lines[i]);
                if marker.starts_with("=======") && phase < 2 {
                    phase = 2;
                } else if marker.starts_with("|||||||") && phase == 0 {
                    phase = 1;
                } else if marker.starts_with(">>>>>>>") {
                    i += 1;
                    break;
                } else {
                    let raw = raw_lines[i].to_string();
                    match phase {
                        0 => local.push(raw),
                        1 => base.get_or_insert_with(Vec::new).push(raw),
                        _ => theirs.push(raw),
                    }
                }
                i += 1;
            }
            sections.push(ConflictSection::Conflict {
                local,
                theirs,
                base,
            });
            count += 1;
        } else {
            context.push(raw_lines[i].to_string());
            i += 1;
        }
    }
    if !context.is_empty() {
        sections.push(ConflictSection::Context { lines: context });
    }
    (sections, count)
}

fn strip_carriage_return(line: &str) -> &str {
    line.strip_suffix('\r').unwrap_or(line)
}

/// 按选择重组文件内容。choices 与冲突块按出现顺序一一对应；
/// both 时顺序保留两段（本地在前）。选择非法返回 None。
/// 段落间以 \n 连接；行内原有的 \r 原样保留，维持原 EOL 风格与结尾换行状态。
pub fn rebuild_conflict_text(sections: &[ConflictSection], choices: &[&str]) -> Option<String> {
    let mut out = String::new();
    let mut choice_index = 0;
    for section in sections {
        match section {
            ConflictSection::Context { lines } => {
                for line in lines {
                    out.push_str(line);
                    out.push('\n');
                }
            }
            ConflictSection::Conflict { local, theirs, .. } => {
                let choice = *choices.get(choice_index)?;
                choice_index += 1;
                let picked: Vec<&String> = match choice {
                    "local" => local.iter().collect(),
                    "theirs" => theirs.iter().collect(),
                    "both" => local.iter().chain(theirs.iter()).collect(),
                    _ => return None,
                };
                for line in picked {
                    out.push_str(line);
                    out.push('\n');
                }
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::{
        abort_merge, complete_merge, get_conflict_file, parse_conflict_text, rebuild_conflict_text,
        resolve_conflict_file, ConflictSection,
    };
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
                std::env::temp_dir().join(format!("menugit-conflict-{}-{nonce}", std::process::id()));
            std::fs::create_dir_all(&path).unwrap();
            run_git(&path, &["init", "--quiet"]);
            run_git(&path, &["checkout", "--quiet", "-b", "main"]);
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

        fn string(&self) -> String {
            self.0.to_string_lossy().into_owned()
        }

        fn merge_with_conflict(&self, branch: &str) {
            let output = Command::new("git")
                .args(["merge", branch])
                .current_dir(&self.0)
                .output()
                .unwrap();
            assert!(!output.status.success(), "merge should conflict");
            assert!(self.0.join(".git/MERGE_HEAD").exists());
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
    fn parse_and_rebuild_keeps_single_trailing_newline() {
        let text = "before\n<<<<<<< HEAD\nlocal\n=======\ntheirs\n>>>>>>> origin/main\nafter\n";
        let (sections, count) = parse_conflict_text(text);
        assert_eq!(count, 1);
        let rebuilt = rebuild_conflict_text(&sections, &["local"]).unwrap();
        assert_eq!(rebuilt, "before\nlocal\nafter\n");
    }

    #[test]
    fn both_keeps_local_then_theirs() {
        let text = "<<<<<<< HEAD\nA\n=======\nB\n>>>>>>> origin/main\n";
        let (sections, count) = parse_conflict_text(text);
        assert_eq!(count, 1);
        assert!(matches!(&sections[0], ConflictSection::Conflict { .. }));
        let rebuilt = rebuild_conflict_text(&sections, &["both"]).unwrap();
        assert_eq!(rebuilt, "A\nB\n");
    }

    #[test]
    fn crlf_content_round_trips() {
        let text = "a\r\n<<<<<<< HEAD\r\nx\r\n=======\r\ny\r\n>>>>>>> o\r\nb\r\n";
        let (sections, count) = parse_conflict_text(text);
        assert_eq!(count, 1);
        let rebuilt = rebuild_conflict_text(&sections, &["theirs"]).unwrap();
        assert_eq!(rebuilt, "a\r\ny\r\nb\r\n");
    }

    #[test]
    fn resolved_conflicts_commit_and_abort_round_trip() {
        let repo = TestRepo::new();
        let file = repo.path().join("conflict.txt");
        std::fs::write(&file, "base\n").unwrap();
        run_git(repo.path(), &["add", "--", "conflict.txt"]);
        run_git(repo.path(), &["commit", "--quiet", "-m", "baseline"]);

        run_git(repo.path(), &["switch", "--quiet", "-c", "feature"]);
        std::fs::write(&file, "feature line\n").unwrap();
        run_git(repo.path(), &["commit", "--quiet", "-am", "feature edit"]);
        run_git(repo.path(), &["switch", "--quiet", "main"]);
        std::fs::write(&file, "main line\n").unwrap();
        run_git(repo.path(), &["commit", "--quiet", "-am", "main edit"]);
        repo.merge_with_conflict("feature");

        let parsed = get_conflict_file(repo.string(), "conflict.txt".into()).unwrap();
        assert_eq!(parsed.conflict_count, 1);
        let resolved = resolve_conflict_file(
            repo.string(),
            "conflict.txt".into(),
            vec!["both".into()],
        )
        .unwrap();
        assert_eq!(resolved.remaining_conflicts, 0);
        let merged = std::fs::read_to_string(&file).unwrap();
        assert!(merged.contains("main line") && merged.contains("feature line"));

        complete_merge(repo.string(), "Merge feature".into()).unwrap();
        assert!(!repo.path().join(".git/MERGE_HEAD").exists());
        assert_eq!(
            run_git(repo.path(), &["log", "-1", "--format=%s"]),
            "Merge feature"
        );

        // 再次制造冲突后中止，工作区应回到合并前的内容。
        run_git(repo.path(), &["switch", "--quiet", "-c", "feature2"]);
        std::fs::write(&file, "feature two\n").unwrap();
        run_git(repo.path(), &["commit", "--quiet", "-am", "feature two"]);
        run_git(repo.path(), &["switch", "--quiet", "main"]);
        std::fs::write(&file, "main two\n").unwrap();
        run_git(repo.path(), &["commit", "--quiet", "-am", "main two"]);
        repo.merge_with_conflict("feature2");
        assert!(get_conflict_file(repo.string(), "conflict.txt".into())
            .unwrap()
            .conflict_count
            > 0);

        abort_merge(repo.string()).unwrap();
        assert!(!repo.path().join(".git/MERGE_HEAD").exists());
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "main two\n");
    }
}
