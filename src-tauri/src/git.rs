//! git.rs —— 统一的 git 子进程执行器。
//!
//! 所有 git 能力都通过调用系统 git CLI 实现（R2）：配置、凭证、代理完全复用系统 Git，
//! 不引入 libgit2。本模块负责：
//! - 固定追加 `--no-pager -c core.quotepath=false`，环境变量 `LC_ALL=C`
//! - 超时控制与取消（终止整个进程树）
//! - 捕获 stdout/stderr 并统一错误结构（serde 可序列化，前端按 `{ kind, message, stderr }` 呈现）

use std::collections::HashMap;
use std::io::Read;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::io::Write;

/// Windows 下隐藏子进程控制台窗口
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// 错误类别（与前端约定的 kind 字段一一对应）
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum GitErrorKind {
    GitMissing,
    NotARepo,
    Network,
    AuthRejected,
    Locked,
    Cancelled,
    Other,
}

impl std::fmt::Display for GitErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            GitErrorKind::GitMissing => "GitMissing",
            GitErrorKind::NotARepo => "NotARepo",
            GitErrorKind::Network => "Network",
            GitErrorKind::AuthRejected => "AuthRejected",
            GitErrorKind::Locked => "Locked",
            GitErrorKind::Cancelled => "Cancelled",
            GitErrorKind::Other => "Other",
        })
    }
}

/// 统一错误结构：前端按 `{ kind, message, stderr }` 呈现可读原因 + 可展开原始输出（R5）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GitError {
    pub kind: GitErrorKind,
    pub message: String,
    pub stderr: String,
}

impl GitError {
    pub fn new(kind: GitErrorKind, message: impl Into<String>) -> Self {
        Self { kind, message: message.into(), stderr: String::new() }
    }

    /// 附带原始 stderr 输出
    pub fn with_stderr(mut self, stderr: impl Into<String>) -> Self {
        self.stderr = stderr.into();
        self
    }

    pub fn other(message: impl Into<String>) -> Self {
        Self::new(GitErrorKind::Other, message)
    }

    pub fn not_a_repo() -> Self {
        Self::new(GitErrorKind::NotARepo, "该目录不是 Git 仓库")
    }

    pub fn locked(message: impl Into<String>) -> Self {
        Self::new(GitErrorKind::Locked, message)
    }
}

impl std::fmt::Display for GitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.kind, self.message)
    }
}

impl std::error::Error for GitError {}

/// 一次 git 命令的输出
#[derive(Debug, Clone)]
pub struct GitOutput {
    pub stdout: String,
    pub stderr: String,
    pub code: i32,
}

/// stderr 增量文本回调（用于 clone 进度解析与事件推送）
pub type StderrCallback = Arc<dyn Fn(&str) + Send + Sync>;

/// git 命令运行参数
#[derive(Default)]
pub struct RunOptions {
    /// 工作目录（仓库根或目标目录）
    pub cwd: PathBuf,
    /// 超时时间；None 表示不限时（如克隆）
    pub timeout: Option<Duration>,
    /// 取消标记：被置位后立刻终止整个 git 进程树
    pub cancel: Option<Arc<AtomicBool>>,
    /// 经 stdin 传入的数据（如提交信息 `git commit -F -`）
    pub stdin_data: Option<Vec<u8>>,
    /// 除 0 外额外视为成功的退出码（如 `--no-index` diff 有差异时退出码为 1）
    pub accept_exit_codes: Vec<i32>,
    /// stderr 增量回调（按 \r / \n 分行）
    pub on_stderr_text: Option<StderrCallback>,
}

impl RunOptions {
    /// 本地操作（status/diff/log 等），默认 120 秒超时
    pub fn local(cwd: impl Into<PathBuf>) -> Self {
        RunOptions { cwd: cwd.into(), timeout: Some(Duration::from_secs(120)), ..Default::default() }
    }

    /// 网络操作（push/pull），默认 600 秒超时
    pub fn net(cwd: impl Into<PathBuf>) -> Self {
        RunOptions { cwd: cwd.into(), timeout: Some(Duration::from_secs(600)), ..Default::default() }
    }
}

/// 解析后的 git 可执行文件路径缓存
static GIT_BIN: OnceLock<Option<PathBuf>> = OnceLock::new();

/// 在 PATH 与常见安装位置查找 git 可执行文件。
/// 优先使用绝对路径，避免 Windows 上从当前目录意外加载同名程序。
fn find_git() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        if let Some(path_var) = std::env::var_os("PATH") {
            for dir in std::env::split_paths(&path_var) {
                let candidate = dir.join("git.exe");
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
        for candidate in [
            r"C:\Program Files\Git\cmd\git.exe",
            r"C:\Program Files (x86)\Git\cmd\git.exe",
        ] {
            let p = PathBuf::from(candidate);
            if p.is_file() {
                return Some(p);
            }
        }
        None
    }
    #[cfg(not(windows))]
    {
        for candidate in ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"] {
            let p = PathBuf::from(candidate);
            if p.is_file() {
                return Some(p);
            }
        }
        Some(PathBuf::from("git"))
    }
}

/// 获取 git 可执行文件路径；找不到时返回 GitMissing
pub fn resolve_git_binary() -> Result<&'static PathBuf, GitError> {
    match GIT_BIN.get_or_init(find_git) {
        Some(p) => Ok(p),
        None => Err(GitError::new(
            GitErrorKind::GitMissing,
            "未找到系统 git，请先安装 Git 并加入 PATH",
        )),
    }
}

/// 终止整个 git 进程树（Windows 用 taskkill /T，其他平台直接 kill）
fn kill_tree(child: &mut Child) {
    #[cfg(windows)]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .creation_flags(CREATE_NO_WINDOW)
            .output();
    }
    let _ = child.kill();
    let _ = child.wait();
}

/// 后台线程读取整个管道
fn drain_pipe<R: Read + Send + 'static>(mut reader: R) -> Vec<u8> {
    let mut buf = Vec::new();
    let _ = reader.read_to_end(&mut buf);
    buf
}

/// 逐字节读取 stderr：按 \r / \n 分行触发增量回调，同时保留原始字节。
/// clone 的进度输出以 \r 刷新同一行，必须两者都当作行结束符。
fn drain_stderr<R: Read>(reader: R, callback: Option<&StderrCallback>, raw: &mut Vec<u8>) {
    let mut byte = [0u8; 1];
    let mut line: Vec<u8> = Vec::new();
    let mut reader = reader;
    loop {
        match reader.read(&mut byte) {
            Ok(0) => break,
            Ok(_) => {
                raw.push(byte[0]);
                if byte[0] == b'\n' || byte[0] == b'\r' {
                    if !line.is_empty() {
                        if let Some(cb) = callback {
                            cb(&String::from_utf8_lossy(&line));
                        }
                        line.clear();
                    }
                } else {
                    line.push(byte[0]);
                }
            }
            Err(_) => break,
        }
    }
    if !line.is_empty() {
        if let Some(cb) = callback {
            cb(&String::from_utf8_lossy(&line));
        }
    }
}

/// 取消注册表：repoKey（仓库路径 / 克隆目标目录）→ 取消标记
static CANCELS: OnceLock<Mutex<HashMap<String, Arc<AtomicBool>>>> = OnceLock::new();

fn cancels() -> &'static Mutex<HashMap<String, Arc<AtomicBool>>> {
    CANCELS.get_or_init(Default::default)
}

/// 注册一个取消标记（长操作开始时调用）
pub fn register_cancel(key: &str) -> Arc<AtomicBool> {
    let flag = Arc::new(AtomicBool::new(false));
    cancels().lock().unwrap().insert(key.to_string(), flag.clone());
    flag
}

/// 请求取消（置位标记，执行循环会在 30ms 内终止进程树）
pub fn cancel(key: &str) -> bool {
    if let Some(flag) = cancels().lock().unwrap().get(key) {
        flag.store(true, Ordering::Relaxed);
        true
    } else {
        false
    }
}

/// 长操作结束后注销取消标记
pub fn unregister_cancel(key: &str) {
    cancels().lock().unwrap().remove(key);
}

/// 根据退出码与 stderr 分类失败原因（R5）
fn classify_failure(stderr: &str) -> GitError {
    let s = stderr.to_lowercase();
    let err = if s.contains("not a git repository") {
        GitError::new(GitErrorKind::NotARepo, "该目录不是 Git 仓库")
    } else if s.contains("index.lock") || s.contains("another git process") {
        GitError::new(GitErrorKind::Locked, "Git 正被其他进程占用，请稍后重试")
    } else if s.contains("authentication fail")
        || s.contains("could not read from remote repository")
        || s.contains("permission denied (publickey)")
        || s.contains("terminal prompts disabled")
    {
        GitError::new(GitErrorKind::AuthRejected, "认证失败：请检查凭证或 SSH 配置")
    } else if s.contains("could not resolve host")
        || s.contains("failed to connect")
        || s.contains("connection timed out")
        || s.contains("connection refused")
        || s.contains("unable to access")
    {
        GitError::new(GitErrorKind::Network, "网络错误：无法连接远端仓库")
    } else if (s.contains("rejected") && s.contains("fetch first")) || s.contains("non-fast-forward") {
        GitError::new(GitErrorKind::Other, "推送被拒绝：远端有新提交，请先拉取")
    } else if s.contains("would be overwritten by") || s.contains("please commit your changes") {
        GitError::new(GitErrorKind::Other, "存在会被覆盖的本地修改，请先提交或放弃修改")
    } else {
        GitError::new(GitErrorKind::Other, "git 命令执行失败")
    };
    err.with_stderr(stderr)
}

/// 执行一条 git 命令。
///
/// 固定追加 `--no-pager -c core.quotepath=false`，设置 `LC_ALL=C`（R7：输出本地化归一），
/// 同时设置 `GIT_TERMINAL_PROMPT=0` 避免无凭证助手时挂起。
pub fn run(args: &[&str], opts: &RunOptions) -> Result<GitOutput, GitError> {
    let started = Instant::now();
    let exe = resolve_git_binary()?;

    let mut cmd = Command::new(exe);
    cmd.arg("--no-pager")
        .arg("-c")
        .arg("core.quotepath=false")
        .args(args)
        .current_dir(&opts.cwd)
        .env("LC_ALL", "C")
        .env("GIT_TERMINAL_PROMPT", "0")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            crate::diag::log_git(args, &opts.cwd, None, started.elapsed());
            return Err(GitError::new(
                GitErrorKind::GitMissing,
                format!("无法启动 git：{e}"),
            ));
        }
    };

    // stdin 写入放独立线程，避免子进程写满管道时父进程阻塞导致死锁
    match opts.stdin_data.clone() {
        Some(data) => {
            if let Some(mut stdin) = child.stdin.take() {
                std::thread::spawn(move || {
                    #[cfg(windows)]
                    {
                        let _ = stdin.write_all(&data);
                    }
                    #[cfg(not(windows))]
                    {
                        use std::io::Write;
                        let _ = stdin.write_all(&data);
                    }
                });
            }
        }
        // 不写 stdin 时立即关闭，避免 git 等待输入
        None => drop(child.stdin.take()),
    }

    // stdout 直接整块读取；stderr 走逐行回调（进度输出）
    let stdout_handle = child.stdout.take().map(|r| std::thread::spawn(move || drain_pipe(r)));
    let err_cb = opts.on_stderr_text.clone();
    let stderr_handle = child.stderr.take().map(|r| {
        std::thread::spawn(move || {
            let mut raw = Vec::new();
            drain_stderr(r, err_cb.as_ref(), &mut raw);
            raw
        })
    });

    // 轮询等待：完成 / 取消 / 超时，三者任一触发即终止进程树
    let deadline = opts.timeout.map(|t| started + t);
    let mut finished: Option<std::process::ExitStatus> = None;
    let mut cancelled = false;
    let mut timed_out = false;
    loop {
        if let Some(flag) = &opts.cancel {
            if flag.load(Ordering::Relaxed) {
                cancelled = true;
            }
        }
        if cancelled {
            kill_tree(&mut child);
            break;
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                finished = Some(status);
                break;
            }
            Ok(None) => {}
            Err(e) => {
                kill_tree(&mut child);
                let err = GitError::other(format!("等待 git 进程失败：{e}"));
                crate::diag::log_git(args, &opts.cwd, None, started.elapsed());
                return Err(err);
            }
        }
        if let Some(dl) = deadline {
            if Instant::now() > dl {
                timed_out = true;
                kill_tree(&mut child);
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    let _ = child.wait();

    let stdout = stdout_handle
        .and_then(|h| h.join().ok())
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    let stderr = stderr_handle
        .and_then(|h| h.join().ok())
        .map(|b| String::from_utf8_lossy(&b).into_owned())
        .unwrap_or_default();
    let elapsed = started.elapsed();

    let result = if cancelled {
        Err(GitError::new(GitErrorKind::Cancelled, "操作已取消"))
    } else if timed_out {
        Err(GitError::other("git 命令执行超时，已终止").with_stderr(stderr))
    } else {
        let code = finished.and_then(|s| s.code()).unwrap_or(-1);
        if code == 0 || opts.accept_exit_codes.contains(&code) {
            Ok(GitOutput { stdout, stderr, code })
        } else {
            Err(classify_failure(&stderr))
        }
    };

    crate::diag::log_git(args, &opts.cwd, result.as_ref().ok().map(|o| o.code), elapsed);
    result
}
