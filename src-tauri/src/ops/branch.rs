//! branch.rs —— 分支列表与切换命令。

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};
use crate::ops::{repo_root, with_write_lock};

/// 分支条目
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchInfo {
    /// 本地分支名或远端引用名（如 origin/main）
    pub name: String,
    /// 是否为当前检出分支（仅本地分支会为 true）
    pub is_current: bool,
    /// 上游分支（如 origin/main）
    pub upstream: Option<String>,
}

/// 分支列表
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BranchList {
    /// 当前分支名
    pub current: Option<String>,
    pub local: Vec<BranchInfo>,
    pub remote: Vec<BranchInfo>,
}

/// 列出本地 + 远端分支并标记当前分支。
/// 用 %09（TAB）分隔字段，TAB 不能出现在 ref 名中，解析安全。
#[tauri::command]
pub fn list_branches(path: String) -> Result<BranchList, GitError> {
    let root = repo_root(&path)?;
    let format = "%(refname:short)%09%(HEAD)%09%(upstream:short)";
    let local_out = git::run(&["branch", "--format", format], &git::RunOptions::local(&root))?;
    let remote_out = git::run(&["branch", "-r", "--format", format], &git::RunOptions::local(&root))?;

    let mut current = None;
    let mut local = Vec::new();
    for line in local_out.stdout.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.is_empty() || fields[0].is_empty() {
            continue;
        }
        let is_current = fields.get(1).copied() == Some("*");
        if is_current {
            current = Some(fields[0].to_string());
        }
        local.push(BranchInfo {
            name: fields[0].to_string(),
            is_current,
            upstream: fields
                .get(2)
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string()),
        });
    }

    let mut remote = Vec::new();
    for line in remote_out.stdout.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.is_empty() || fields[0].is_empty() {
            continue;
        }
        // 过滤 origin/HEAD 这类符号引用
        if fields[0].ends_with("/HEAD") {
            continue;
        }
        remote.push(BranchInfo {
            name: fields[0].to_string(),
            is_current: false,
            upstream: None,
        });
    }
    Ok(BranchList { current, local, remote })
}

/// 切换分支：`git switch <branch>`；create=true 时 `git switch -c <branch>`。
/// 会覆盖未提交修改时 git 报错，原样透传给前端。
#[tauri::command]
pub fn switch_branch(path: String, branch: String, create: Option<bool>) -> Result<(), GitError> {
    with_write_lock(&path, false, |root| {
        if create.unwrap_or(false) {
            git::run(&["switch", "-c", &branch], &git::RunOptions::local(root))?;
        } else {
            git::run(&["switch", &branch], &git::RunOptions::local(root))?;
        }
        Ok(())
    })
}

/// 检出远端分支：`git switch -t <remoteBranch>`（如 origin/feature）
#[tauri::command]
pub fn checkout_remote(path: String, remote_branch: String) -> Result<(), GitError> {
    with_write_lock(&path, false, |root| {
        git::run(&["switch", "-t", &remote_branch], &git::RunOptions::local(root))?;
        Ok(())
    })
}
