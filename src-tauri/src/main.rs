#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod diag;
mod git;
mod lock;
mod ops;
mod repo;
mod settings;

use std::sync::Mutex;
use tauri::{Emitter, Manager};

/// CLI 参数状态：首次启动来自进程参数，二次拉起由单实例插件转发。
#[derive(Default)]
struct CliArgs(Mutex<Vec<String>>);

#[tauri::command]
fn get_cli_args(state: tauri::State<CliArgs>) -> Vec<String> {
    state.0.lock().unwrap().clone()
}

fn main() {
    let initial: Vec<String> = std::env::args().skip(1).collect();

    tauri::Builder::default()
        .manage(CliArgs(Mutex::new(initial)))
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // 已有实例在运行：更新参数并通知前端切换视图
            if let Some(state) = app.try_state::<CliArgs>() {
                *state.0.lock().unwrap() = argv.iter().skip(1).cloned().collect();
            }
            let _ = app.emit("cli-args", ());
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
        }))
        .setup(|app| {
            // 启动即恢复诊断日志开关与日志路径（设置存于 app data 目录，R6）
            let s = settings::load(app.handle());
            diag::set_enabled(s.diag_enabled);
            if let Ok(dir) = app.path().app_data_dir() {
                diag::set_log_file(Some(dir.join("diag.log")));
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_cli_args,
            settings::get_settings,
            settings::set_settings,
            ops::status::get_repo_info,
            ops::status::get_status,
            ops::status::get_identity,
            ops::diff::get_diff,
            ops::stage::stage_files,
            ops::stage::commit,
            ops::sync::push,
            ops::sync::pull,
            ops::branch::list_branches,
            ops::branch::switch_branch,
            ops::branch::checkout_remote,
            ops::logop::get_log,
            ops::discard::discard_changes,
            ops::conflict::get_conflict_file,
            ops::conflict::resolve_conflict_file,
            ops::conflict::complete_merge,
            ops::conflict::abort_merge,
            ops::initclone::init_repo,
            ops::initclone::clone_repo,
            ops::initclone::cancel_clone,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
