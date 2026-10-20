//! auth.rs —— HTTPS 凭据配置（macOS 钥匙串）。
//!
//! 凭据只由用户主动填写：经 stdin 交给 `git credential approve`，由系统钥匙串保存；
//! 推送 / 拉取 / 克隆通过 osxkeychain helper 读取，令牌不进入命令行、URL 或诊断日志。

use std::path::Path;

use serde::Serialize;

use crate::git::{self, GitError, RunOptions};
use crate::ops::validate_dir;

const GITHUB_TOKEN_URL: &str =
    "https://github.com/settings/tokens/new?scopes=repo&description=MenuGit";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HttpsRemoteInfo {
    /// 远端名（通常是 origin）
    pub remote: String,
    /// 主机[:端口]，与 git credential 的 host 字段一致
    pub host: String,
    /// 远端 URL 中已有的用户名（通常没有）
    pub username: Option<String>,
}

/// 解析 HTTPS 远端；SSH、file:// 或格式异常返回 None。
fn parse_https_remote(url: &str) -> Option<(String, Option<String>)> {
    let url = url.trim();
    if url.len() < 8 || !url.as_bytes()[..8].eq_ignore_ascii_case(b"https://") {
        return None;
    }
    let authority = url[8..].split('/').next().unwrap_or_default();
    if authority.is_empty() {
        return None;
    }
    let (userinfo, host) = match authority.rsplit_once('@') {
        Some((user, host)) => (Some(user), host),
        None => (None, authority),
    };
    if host.is_empty()
        || host
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || c == '@')
    {
        return None;
    }
    let username = userinfo
        .filter(|value| !value.is_empty())
        // user:password 形式只保留用户名，令牌/密码不进入 UI。
        .map(|value| value.split(':').next().unwrap_or(value))
        .map(|value| {
            percent_encoding::percent_decode_str(value)
                .decode_utf8_lossy()
                .into_owned()
        })
        .filter(|value| {
            !value.is_empty()
                && !value.starts_with("ghp_")
                && !value.starts_with("github_pat_")
        });
    Some((host.to_string(), username))
}

/// 读取仓库的远端地址，优先 origin，其次按 `git remote` 顺序。
fn remote_url(cwd: &Path) -> Option<(String, String)> {
    let mut names = vec!["origin".to_string()];
    if let Ok(output) = git::run(&["remote"], &RunOptions::local(cwd)) {
        for name in output.stdout.lines().map(str::trim).filter(|n| !n.is_empty()) {
            if !names.iter().any(|existing| existing == name) {
                names.push(name.to_string());
            }
        }
    }
    for name in names {
        if let Ok(output) = git::run(&["remote", "get-url", &name], &RunOptions::local(cwd)) {
            let url = output.stdout.lines().next().unwrap_or_default().trim();
            if !url.is_empty() {
                return Some((name, url.to_string()));
            }
        }
    }
    None
}

/// 读取仓库可配置凭据的 HTTPS 远端；没有 HTTPS 远端时返回 null。
#[tauri::command]
pub fn get_https_remote(path: String) -> Result<Option<HttpsRemoteInfo>, GitError> {
    let dir = validate_dir(&path)?;
    let Some((remote, url)) = remote_url(&dir) else {
        return Ok(None);
    };
    let Some((host, username)) = parse_https_remote(&url) else {
        return Ok(None);
    };
    Ok(Some(HttpsRemoteInfo {
        remote,
        host,
        username,
    }))
}

/// 生成 git credential 协议输入；字段不得包含换行，否则会注入额外字段。
fn credential_input(host: &str, username: &str, secret: &str) -> Result<String, GitError> {
    if host.is_empty() || username.is_empty() || secret.is_empty() {
        return Err(GitError::other("主机、用户名和密码/令牌均不能为空"));
    }
    if host.chars().any(char::is_whitespace) {
        return Err(GitError::other("远端主机地址无效"));
    }
    for value in [host, username, secret] {
        if value
            .chars()
            .any(|c| matches!(c, '\n' | '\r' | '\0'))
        {
            return Err(GitError::other("凭据不能包含换行或空字符"));
        }
    }
    Ok(format!(
        "protocol=https\nhost={host}\nusername={username}\npassword={secret}\n\n"
    ))
}

/// 写入凭据并经同一助手回读校验；`helper` 仅测试时替换为 store。
fn approve_and_verify(
    host: &str,
    username: &str,
    secret: &str,
    helper: &str,
) -> Result<(), GitError> {
    let input = credential_input(host, username, secret)?;
    let helper_config = format!("credential.helper={helper}");
    let approve = RunOptions {
        stdin_data: Some(input.into_bytes()),
        ..RunOptions::local(std::env::temp_dir())
    };
    // 先清空用户已有的 helper 链，确保令牌只写入目标助手；
    // 否则全局 store 等助手也会收到明文令牌。
    git::run(
        &[
            "-c",
            "credential.helper=",
            "-c",
            &helper_config,
            "credential",
            "approve",
        ],
        &approve,
    )?;

    // 只比较回读结果，不把令牌返回前端或写入日志。
    let fill = RunOptions {
        stdin_data: Some(format!("protocol=https\nhost={host}\n\n").into_bytes()),
        ..RunOptions::local(std::env::temp_dir())
    };
    let output = git::run(
        &[
            "-c",
            "credential.helper=",
            "-c",
            &helper_config,
            "credential",
            "fill",
        ],
        &fill,
    )
    .map_err(|error| {
        GitError::other("凭据写入钥匙串失败，请重试").with_stderr(error.stderr)
    })?;
    let mut saved_user = None;
    let mut saved_password = None;
    for line in output.stdout.lines() {
        if let Some(value) = line.strip_prefix("username=") {
            saved_user = Some(value);
        }
        if let Some(value) = line.strip_prefix("password=") {
            saved_password = Some(value);
        }
    }
    if saved_user != Some(username) || saved_password != Some(secret) {
        return Err(GitError::other("凭据写入钥匙串失败，请重试"));
    }
    Ok(())
}

/// 保存 HTTPS 凭据到 macOS 钥匙串。后续网络命令由 git.rs 自动使用 osxkeychain。
#[tauri::command]
pub fn save_https_credential(
    host: String,
    username: String,
    secret: String,
) -> Result<(), GitError> {
    #[cfg(target_os = "macos")]
    {
        approve_and_verify(host.trim(), username.trim(), &secret, "osxkeychain")
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (host, username, secret);
        Err(GitError::other("当前平台暂不支持保存 HTTPS 凭据"))
    }
}

/// 打开 GitHub 经典 Token 创建页（预填 repo 权限）。
#[tauri::command]
pub fn open_github_tokens() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("/usr/bin/open")
            .arg(GITHUB_TOKEN_URL)
            .spawn()
            .map(|_| ())
            .map_err(|error| format!("无法打开 GitHub Token 页面：{error}"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("此操作目前仅支持 macOS".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{approve_and_verify, credential_input, parse_https_remote};
    use std::path::PathBuf;
    use std::time::{SystemTime, UNIX_EPOCH};

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let nonce = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir()
                .join(format!("menugit-auth-test-{}-{nonce}", std::process::id()));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn parses_https_remote_with_userinfo_and_port() {
        let (host, username) =
            parse_https_remote("https://alice@github.com:443/team/repo.git").unwrap();
        assert_eq!(host, "github.com:443");
        assert_eq!(username.as_deref(), Some("alice"));
        let (_, username) =
            parse_https_remote("https://alice:secret@github.com/team/repo.git").unwrap();
        assert_eq!(username.as_deref(), Some("alice"));
        let (_, username) =
            parse_https_remote("https://ghp_abcdef@github.com/team/repo.git").unwrap();
        assert_eq!(username, None);
        let (host, username) = parse_https_remote("HTTPS://github.com/a/b.git").unwrap();
        assert_eq!(host, "github.com");
        assert_eq!(username, None);
    }

    #[test]
    fn rejects_non_https_and_malformed_remote() {
        assert!(parse_https_remote("git@github.com:team/repo.git").is_none());
        assert!(parse_https_remote("ssh://git@github.com/team/repo.git").is_none());
        assert!(parse_https_remote("https://").is_none());
        assert!(parse_https_remote("https:///path").is_none());
        assert!(parse_https_remote("https://host with space/repo").is_none());
    }

    #[test]
    fn credential_input_rejects_control_characters() {
        assert!(credential_input("github.com", "alice", "token").is_ok());
        assert!(credential_input("github.com", "alice\nhost=evil", "token").is_err());
        assert!(credential_input("github.com", "alice", "tok\r\nen").is_err());
        assert!(credential_input("", "alice", "token").is_err());
    }

    #[test]
    fn reads_origin_remote_from_repository() {
        let dir = TestDir::new();
        let run = |args: &[&str]| {
            let output = std::process::Command::new("git")
                .args(args)
                .current_dir(&dir.0)
                .output()
                .unwrap();
            assert!(output.status.success(), "git {:?} failed", args);
        };
        run(&["init", "-q"]);
        run(&[
            "remote",
            "add",
            "origin",
            "https://github.com/team/repo.git",
        ]);
        let info = super::get_https_remote(dir.0.to_string_lossy().into_owned())
            .unwrap()
            .unwrap();
        assert_eq!(info.remote, "origin");
        assert_eq!(info.host, "github.com");
        assert_eq!(info.username, None);

        run(&[
            "remote",
            "set-url",
            "origin",
            "git@github.com:team/repo.git",
        ]);
        assert!(super::get_https_remote(dir.0.to_string_lossy().into_owned())
            .unwrap()
            .is_none());
    }

    #[test]
    fn credentials_round_trip_through_helper() {
        let dir = TestDir::new();
        let file = dir.0.join("credentials");
        let helper = format!("store --file={}", file.to_str().unwrap());
        approve_and_verify("example.invalid", "alice", "s3cret", &helper).unwrap();
        let stored = std::fs::read_to_string(&file).unwrap();
        assert_eq!(stored.trim(), "https://alice:s3cret@example.invalid");
    }
}
