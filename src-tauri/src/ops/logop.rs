//! logop.rs —— 提交日志命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::diff::DiffResult;
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
    /// 完整提交说明正文（subject 之外的部分，可能为空、含换行）
    pub body: String,
}

/// 读取提交日志：`git log --format=...`（字段间用 \x1f 分隔、记录间用 \x1e 分隔，
/// 避免提交说明中含 `|` 或正文含换行导致解析错位）。默认 200 条，滚动加载用 skip。
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
    // %b 为完整提交正文（可含换行），故每条记录末尾追加 \x1e 作记录分隔符
    let format = "%H%x1f%h%x1f%s%x1f%an%x1f%at%x1f%D%x1f%b%x1e";

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
    for record in out.stdout.split('\x1e') {
        // tformat 在每条记录后补 \n，切分后除首条外均以 \n 开头，去掉即可
        let record = record.trim_start_matches('\n');
        // splitn(7)：正文（最后一段）允许包含 \x1f
        let fields: Vec<&str> = record.splitn(7, '\x1f').collect();
        if fields.len() < 7 {
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
            body: fields[6].to_string(),
        });
    }
    Ok(entries)
}

/// 提交中单个变更文件条目（get_commit_files 返回）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitFileEntry {
    /// 文件路径（重命名时为新路径）
    pub path: String,
    /// 变更状态字母：A 新增 / M 修改 / D 删除 / R 重命名 等
    pub change: String,
    /// 重命名/复制时的原路径（旧名 → 新名展示用；非 R/C 状态为 null）
    pub orig_path: Option<String>,
}

/// 列出某次提交的变更文件（状态 + 路径）：
/// `git diff-tree --no-commit-id --name-status -r -z <hash>`，
/// 额外加 --root 让首个提交（无父提交）也能列出文件。
#[tauri::command]
pub fn get_commit_files(path: String, hash: String) -> Result<Vec<CommitFileEntry>, GitError> {
    let root = repo_root(&path)?;
    let out = git::run(
        &[
            "diff-tree",
            "--no-commit-id",
            "--name-status",
            "-r",
            "-z",
            "--root",
            &hash,
        ],
        &git::RunOptions::local(&root),
    )?;

    // -z 输出：每条记录为 "<status>[\t<score>]\t<path>[\t<orig_path>]"，记录间以 \0 分隔
    let mut files = Vec::new();
    for record in out.stdout.split('\0') {
        if record.is_empty() {
            continue;
        }
        let mut parts = record.split('\t');
        // 状态字母取首字符（R100/C75 这类带相似度得分的截去得分）
        let change = parts.next().unwrap_or("M").chars().next().unwrap_or('M').to_string();
        let file_path = match parts.next() {
            Some(p) if !p.is_empty() => p.to_string(),
            _ => continue,
        };
        // 重命名/复制：第三个字段为原路径
        let orig_path = parts.next().map(String::from);
        files.push(CommitFileEntry {
            path: file_path,
            change,
            orig_path,
        });
    }
    Ok(files)
}

/// 查看某次提交中单个文件的差异（对比该提交与其父提交；首个提交对比空树）：
/// `git show <hash> --no-color --no-pager -- <file>`
#[tauri::command]
pub fn get_commit_diff(path: String, hash: String, file: String) -> Result<DiffResult, GitError> {
    let root = repo_root(&path)?;
    let out = git::run(
        &["show", &hash, "--no-color", "--no-pager", "--", &file],
        &git::RunOptions::local(&root),
    )?;
    Ok(DiffResult {
        is_binary: out.stdout.contains("Binary files "),
        text: out.stdout,
    })
}
