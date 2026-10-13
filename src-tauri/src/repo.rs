//! repo.rs —— 仓库发现与仓库信息解析（R1）。
//!
//! - 向上查找 `.git` 定位仓库根（普通目录与 worktree/子模块的 `.git` 文件均支持）
//! - 直接解析 `.git/HEAD` 读取当前分支（detached 时显示短 hash）
//! - 解析 `git status --porcelain=v2 --branch -z` 与 `git diff --numstat -z` 的输出

use std::collections::HashMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::git::{self, GitError};

/// 从给定目录向上查找包含 `.git` 的仓库根目录（R1）。
/// `.git` 可以是目录（普通仓库）或文件（worktree / 子模块），用 exists 判断两者。
pub fn find_repo_root(start: &Path) -> Option<std::path::PathBuf> {
    let mut current: Option<&Path> = Some(start);
    while let Some(dir) = current {
        if dir.join(".git").exists() {
            return Some(dir.to_path_buf());
        }
        current = dir.parent();
    }
    None
}

/// 直接解析 `.git/HEAD` 读取当前分支：
/// 返回 (分支名或短 hash, 是否 detached)。菜单扩展同款逻辑，供后端兜底使用。
pub fn read_head(root: &Path) -> (Option<String>, bool) {
    let head_file = root.join(".git").join("HEAD");
    let text = match std::fs::read_to_string(&head_file) {
        Ok(t) => t,
        Err(_) => return (None, false),
    };
    let trimmed = text.trim();
    if let Some(branch) = trimmed.strip_prefix("ref: refs/heads/") {
        (Some(branch.to_string()), false)
    } else if let Some(other) = trimmed.strip_prefix("ref: ") {
        // 非 heads/ 前缀的 ref（罕见）：取最后一段作为显示名
        let name = other.rsplit('/').next().unwrap_or(other);
        (Some(name.to_string()), false)
    } else if !trimmed.is_empty() {
        // detached HEAD：显示 7 位短 hash
        let short: String = trimmed.chars().take(7).collect();
        (Some(short), true)
    } else {
        (None, false)
    }
}

/// 是否处于合并冲突状态（`.git/MERGE_HEAD` 存在）
pub fn has_merge_head(root: &Path) -> bool {
    root.join(".git").join("MERGE_HEAD").exists()
}

/// porcelain v2 单条目
#[derive(Debug, Clone)]
pub struct PorcelainEntry {
    /// XY 状态位（如 "M."、"RM"；untracked 为 "??"）
    pub xy: String,
    /// 相对仓库根的路径（git 风格 `/` 分隔）
    pub path: String,
    /// 重命名/复制的原路径
    pub orig_path: Option<String>,
    /// 未跟踪条目（`?`）
    pub untracked: bool,
    /// 未合并（冲突）条目（`u`，XY 为 UU/AA/DD/AU/UA/DU/UD）
    pub unmerged: bool,
}

/// `git status --porcelain=v2 --branch -z` 解析结果
#[derive(Debug, Default)]
pub struct PorcelainStatus {
    /// 当前分支名；detached 时为 7 位短 hash
    pub head: Option<String>,
    pub detached: bool,
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
    pub entries: Vec<PorcelainEntry>,
    /// 是否已有提交（unborn 分支为 false）
    pub has_commits: bool,
}

/// 解析 `git status --porcelain=v2 --branch -z` 输出（NUL 分隔，路径原样不转义）。
///
/// 字段布局（实测确认）：
/// - `1 XY sub mH mI mW hH hI path`（9 个空格分隔字段，路径可含空格）
/// - `2 XY sub mH mI mW hH hI X+score path`，旧路径紧跟在下一个 NUL token
/// - `u XY sub m1 m2 m3 mW h1 h2 h3 path`（11 个字段）
/// - `? path` / `! path`
pub fn parse_porcelain_v2(raw: &str) -> PorcelainStatus {
    let mut status = PorcelainStatus::default();
    let tokens: Vec<&str> = raw.split('\0').collect();
    let mut i = 0;
    while i < tokens.len() {
        let token = tokens[i];
        i += 1;
        if token.is_empty() {
            continue;
        }
        if let Some(rest) = token.strip_prefix("# branch.head ") {
            if rest == "(detached)" {
                status.detached = true;
            } else {
                status.head = Some(rest.to_string());
            }
        } else if let Some(rest) = token.strip_prefix("# branch.upstream ") {
            status.upstream = Some(rest.to_string());
        } else if let Some(rest) = token.strip_prefix("# branch.ab ") {
            // 形如 "+1 -0"
            let mut parts = rest.split_whitespace();
            if let Some(a) = parts.next() {
                status.ahead = a.trim_start_matches(['+', '-']).parse().unwrap_or(0);
            }
            if let Some(b) = parts.next() {
                status.behind = b.trim_start_matches(['+', '-']).parse().unwrap_or(0);
            }
        } else if let Some(rest) = token.strip_prefix("# branch.oid ") {
            status.has_commits = !rest.starts_with("0000000");
        } else if token.starts_with("2 ") {
            let fields: Vec<&str> = token.splitn(10, ' ').collect();
            if fields.len() < 10 {
                continue;
            }
            // 重命名旧路径占下一个 NUL token
            let orig = tokens.get(i).map(|s| s.to_string());
            i += 1;
            status.entries.push(PorcelainEntry {
                xy: fields[1].to_string(),
                path: fields[9].to_string(),
                orig_path: orig.filter(|s| !s.is_empty()),
                untracked: false,
                unmerged: false,
            });
        } else if token.starts_with("u ") {
            let fields: Vec<&str> = token.splitn(11, ' ').collect();
            if fields.len() < 11 {
                continue;
            }
            status.entries.push(PorcelainEntry {
                xy: fields[1].to_string(),
                path: fields[10].to_string(),
                orig_path: None,
                untracked: false,
                unmerged: true,
            });
        } else if token.starts_with("1 ") {
            let fields: Vec<&str> = token.splitn(9, ' ').collect();
            if fields.len() < 9 {
                continue;
            }
            status.entries.push(PorcelainEntry {
                xy: fields[1].to_string(),
                path: fields[8].to_string(),
                orig_path: None,
                untracked: false,
                unmerged: false,
            });
        } else if token.starts_with("? ") {
            let mut parts = token.splitn(2, ' ');
            parts.next();
            if let Some(path) = parts.next() {
                status.entries.push(PorcelainEntry {
                    xy: "??".to_string(),
                    path: path.to_string(),
                    orig_path: None,
                    untracked: true,
                    unmerged: false,
                });
            }
        }
        // "! "（忽略的文件）与其余头部行不参与解析
    }
    // detached 时 porcelain 不给分支名，用 branch.oid 的短 hash 展示
    if status.detached && status.head.is_none() {
        if let Some(oid) = status_branch_oid(raw) {
            status.head = Some(oid.chars().take(7).collect());
        }
    }
    status
}

/// 从原始 porcelain 输出中提取 branch.oid
fn status_branch_oid(raw: &str) -> Option<String> {
    raw.split('\0').find_map(|t| t.strip_prefix("# branch.oid ").map(String::from))
}

/// 解析 `git diff --numstat -z` 输出：路径 → (增行数, 删行数, 是否二进制)。
///
/// 实测格式：普通条目为 `a\td\tpath\0`；重命名条目为 `a\td\t\0旧路径\0新路径\0`
/// （前两个 tab 字段后紧跟 NUL，随后依次是旧路径、新路径）；二进制时增删位为 `-`。
pub fn parse_numstat_z(raw: &str) -> HashMap<String, (Option<u64>, Option<u64>, bool)> {
    let mut map: HashMap<String, (Option<u64>, Option<u64>, bool)> = HashMap::new();
    let tokens: Vec<&str> = raw.split('\0').collect();
    let mut i = 0;
    while i < tokens.len() {
        let token = tokens[i];
        i += 1;
        if token.is_empty() {
            continue;
        }
        let mut parts = token.splitn(3, '\t');
        let added = parts.next().unwrap_or("");
        let deleted = parts.next().unwrap_or("");
        let path_part = parts.next().unwrap_or("");
        let binary = added == "-" || deleted == "-";
        let insert = |map: &mut HashMap<String, (Option<u64>, Option<u64>, bool)>, path: &str| {
            if path.is_empty() {
                return;
            }
            let value = if binary {
                (None, None, true)
            } else {
                (added.parse().ok(), deleted.parse().ok(), false)
            };
            map.insert(path.to_string(), value);
        };
        if path_part.is_empty() {
            // 重命名条目：接下来两个 token 依次为旧路径、新路径（按新路径汇总行数）
            if i + 1 < tokens.len() {
                let new_path = tokens[i + 1];
                i += 2;
                insert(&mut map, new_path);
            }
        } else {
            insert(&mut map, path_part);
        }
    }
    map
}

/// 执行 `git status --porcelain=v2 --branch -z` 并解析
pub fn collect_status(root: &Path) -> Result<PorcelainStatus, GitError> {
    let out = git::run(&["status", "--porcelain=v2", "--branch", "-z"], &git::RunOptions::local(root))?;
    Ok(parse_porcelain_v2(&out.stdout))
}

/// 把 porcelain 条目映射为面向前端的文件状态标签（PRD 语义）
pub fn status_label(entry: &PorcelainEntry) -> &'static str {
    if entry.unmerged {
        return "conflict";
    }
    if entry.untracked {
        return "untracked";
    }
    let x = entry.xy.as_bytes().first().copied().unwrap_or(b'.');
    let y = entry.xy.as_bytes().nth(1).copied().unwrap_or(b'.');
    if x == b'R' || y == b'R' || x == b'C' || y == b'C' {
        "renamed"
    } else if x == b'A' || y == b'A' {
        "added"
    } else if x == b'D' || y == b'D' {
        "deleted"
    } else {
        "modified"
    }
}

/// 仓库概要信息（get_repo_info 返回值）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoInfo {
    /// 仓库根目录；非仓库时为 null
    pub path: Option<String>,
    pub is_repo: bool,
    /// 当前分支；detached 时为 7 位短 hash
    pub branch: Option<String>,
    pub detached: bool,
    pub upstream: Option<String>,
    pub ahead: u64,
    pub behind: u64,
    /// 是否存在合并冲突状态（MERGE_HEAD）
    pub merge_in_progress: bool,
    /// 冲突文件数
    pub conflict_file_count: u32,
}

/// 变更文件条目（get_status 返回值）
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusFile {
    pub path: String,
    /// added / modified / deleted / renamed / untracked / conflict
    pub status: String,
    /// 重命名前的旧路径
    pub orig_path: Option<String>,
    /// 新增行数（二进制文件为 null）
    pub added: Option<u64>,
    /// 删除行数（二进制文件为 null）
    pub deleted: Option<u64>,
    pub binary: bool,
    /// 是否有已暂存变更（X 位非 '.'）
    pub staged: bool,
    pub untracked: bool,
}
