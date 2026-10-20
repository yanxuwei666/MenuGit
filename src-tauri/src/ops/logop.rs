//! logop.rs —— 提交日志命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::{literal_pathspec, repo_root, validate_relative_path};

/// 提交日志条目。time 为 epoch 秒，展示格式（相对时间等）由前端决定。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogEntry {
    pub hash: String,
    pub short_hash: String,
    pub subject: String,
    pub author: String,
    /// 提交时间（epoch 秒）
    pub time: i64,
    /// 装饰器（如 ["HEAD -> main", "origin/main", "tag: v1"]）
    pub refs: Vec<String>,
}

/// 日志详情：完整提交信息与该提交涉及的文件。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogDetail {
    pub message: String,
    pub files: Vec<LogFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogFile {
    pub status: String,
    pub path: String,
    pub old_path: Option<String>,
}

fn validate_hash(hash: &str) -> Result<(), GitError> {
    if hash.is_empty() || hash.len() > 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(GitError::other("提交编号无效"));
    }
    Ok(())
}

/// 读取提交日志：`git log --format=%H|%h|%s|%an|%at|%D`（分隔符实际用 \x1f，
/// 避免提交说明中含 `|` 导致解析错位）。默认 200 条，滚动加载用 skip。
/// 空仓库（尚无提交）返回空列表。
#[tauri::command]
pub fn get_log(
    path: String,
    all: Option<bool>,
    file: Option<String>,
    skip: Option<u32>,
    limit: Option<u32>,
) -> Result<Vec<LogEntry>, GitError> {
    let root = repo_root(&path)?;
    let limit = limit.unwrap_or(200).max(1);
    let skip = skip.unwrap_or(0);
    let limit_s = limit.to_string();
    let skip_s = skip.to_string();
    let format = "%H%x1f%h%x1f%s%x1f%an%x1f%at%x1f%D";
    let format_arg = format!("--format={format}");

    let file_spec = file
        .as_deref()
        .map(|file| {
            validate_relative_path(file)?;
            Ok::<String, GitError>(literal_pathspec(file))
        })
        .transpose()?;
    let mut args: Vec<&str> = vec!["log", &format_arg, "--skip", &skip_s, "-n", &limit_s];
    if all.unwrap_or(false) {
        args.push("--all");
    }
    if let Some(pathspec) = file_spec.as_deref() {
        args.push("--");
        args.push(pathspec);
    }

    let out = match git::run(&args, &git::RunOptions::local(&root)) {
        Ok(o) => o,
        Err(e) => {
            // unborn 分支：log 会报 "does not have any commits yet"
            if e.stderr.contains("does not have any commits yet") {
                return Ok(Vec::new());
            }
            return Err(e);
        }
    };

    let mut entries = Vec::new();
    for line in out.stdout.lines() {
        let fields: Vec<&str> = line.split('\x1f').collect();
        if fields.len() < 6 {
            continue;
        }
        entries.push(LogEntry {
            hash: fields[0].to_string(),
            short_hash: fields[1].to_string(),
            subject: fields[2].to_string(),
            author: fields[3].to_string(),
            time: fields[4].parse().unwrap_or(0),
            refs: fields[5]
                .split(", ")
                .filter(|s| !s.is_empty())
                .map(String::from)
                .collect(),
        });
    }
    Ok(entries)
}

/// 读取完整提交说明与变更文件列表。
#[tauri::command]
pub fn get_log_detail(path: String, hash: String) -> Result<LogDetail, GitError> {
    validate_hash(&hash)?;
    let root = repo_root(&path)?;
    let message = git::run(
        &["show", "-s", "--format=%B", &hash],
        &git::RunOptions::local(&root),
    )?
    .stdout
    .trim_end()
    .to_string();
    let names = git::run(
        &[
            "diff-tree",
            "--root",
            "--no-commit-id",
            "--name-status",
            "-r",
            "-M",
            &hash,
        ],
        &git::RunOptions::local(&root),
    )?;
    let files = names
        .stdout
        .lines()
        .filter_map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            let status = fields.first()?.to_string();
            if status.starts_with('R') && fields.len() >= 3 {
                Some(LogFile {
                    status,
                    old_path: Some(fields[1].to_string()),
                    path: fields[2].to_string(),
                })
            } else if fields.len() >= 2 {
                Some(LogFile {
                    status,
                    path: fields[1].to_string(),
                    old_path: None,
                })
            } else {
                None
            }
        })
        .collect();
    Ok(LogDetail { message, files })
}

/// 读取某次提交相对于父提交的单文件差异。
#[tauri::command]
pub fn get_commit_file_diff(path: String, hash: String, file: String) -> Result<String, GitError> {
    validate_hash(&hash)?;
    validate_relative_path(&file)?;
    let root = repo_root(&path)?;
    let file_spec = literal_pathspec(&file);
    let out = git::run(
        &[
            "show",
            "--no-ext-diff",
            "--format=",
            &hash,
            "--",
            &file_spec,
        ],
        &git::RunOptions::local(&root),
    )?;
    Ok(out.stdout)
}
