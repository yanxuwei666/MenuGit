//! logop.rs —— 提交日志命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::repo_root;

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

    let mut args: Vec<&str> = vec!["log", "--format", format, "--skip", &skip_s, "-n", &limit_s];
    if all.unwrap_or(false) {
        args.push("--all");
    }
    if let Some(fpath) = file.as_deref() {
        args.push("--");
        args.push(fpath);
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
