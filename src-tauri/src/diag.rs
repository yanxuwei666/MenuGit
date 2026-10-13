//! diag.rs —— 诊断日志（R6）。
//!
//! 记录每条 git 命令、退出码与耗时；默认关闭，由设置页开关控制。
//! 日志写入 Tauri app data 目录下的 `diag.log`，每行格式：
//! `unix毫秒时间戳 \t 退出码 \t 耗时毫秒 \t 工作目录 \t 命令参数`

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

static ENABLED: AtomicBool = AtomicBool::new(false);
static LOG_FILE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 设置日志文件路径（应用启动时由 setup 调用）
pub fn set_log_file(path: Option<PathBuf>) {
    let cell = LOG_FILE.get_or_init(Default::default);
    *cell.lock().unwrap() = path;
}

/// 设置诊断开关
pub fn set_enabled(on: bool) {
    ENABLED.store(on, Ordering::Relaxed);
}

/// 当前是否开启诊断
pub fn enabled() -> bool {
    ENABLED.load(Ordering::Relaxed)
}

/// 记录一条 git 命令执行；code 为 None 表示未拿到退出码（启动失败/被终止/超时）
pub fn log_git(args: &[&str], cwd: &Path, code: Option<i32>, elapsed: Duration) {
    if !enabled() {
        return;
    }
    let path = {
        let cell = LOG_FILE.get_or_init(Default::default);
        cell.lock().unwrap().clone()
    };
    let Some(path) = path else { return };
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let line = format!(
        "{}\t{:?}\t{}\t{}\t{}\n",
        ts,
        code,
        elapsed.as_millis(),
        cwd.display(),
        args.join(" ")
    );
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = f.write_all(line.as_bytes());
    }
}
