#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod diag;
mod finder;
mod git;
mod lock;
mod ops;
mod repo;
mod settings;

use std::sync::Mutex;
use tauri::{Emitter, Manager};

/// CLI 参数状态：首次启动来自进程参数或请求 URL，二次拉起由单实例插件转发。
#[derive(Default)]
struct CliArgs(Mutex<Vec<String>>);

const CLI_COMMANDS: [&str; 10] = [
    "commit", "pull", "push", "branch", "log", "discard", "conflict", "init", "clone", "settings",
];

#[tauri::command]
fn get_cli_args(state: tauri::State<CliArgs>) -> Vec<String> {
    state.0.lock().unwrap().clone()
}

/// 沙盒中的 Finder 扩展无法通过 argv 传参（LaunchServices 会丢弃），
/// 因此菜单动作以 `menugit://<命令>?path=…&file=…` 的形式打开。
fn args_from_request_url(url: &tauri::Url) -> Option<Vec<String>> {
    if url.scheme() != "menugit" {
        return None;
    }
    let command = url.host_str()?;
    if !CLI_COMMANDS.contains(&command) {
        return None;
    }
    let mut args = vec![command.to_string()];
    for pair in url.query().unwrap_or_default().split('&') {
        let Some((key, value)) = pair.split_once('=') else {
            continue;
        };
        let flag = match key {
            "path" => "--path",
            "file" => "--file",
            "url" => "--url",
            _ => continue,
        };
        // 按字面量解码，不能把路径里的 `+` 当成空格。
        let value = percent_encoding::percent_decode_str(value).decode_utf8_lossy();
        if !value.is_empty() {
            args.push(flag.to_string());
            args.push(value.into_owned());
        }
    }
    Some(args)
}

fn focus_main_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.show();
        let _ = window.unminimize();
        let _ = window.set_focus();
    }
}

fn route_cli_request(app: &tauri::AppHandle, args: Vec<String>, focus: bool) {
    // 空的二次启动（Dock / 访达打开应用）不应清空当前仓库；只有真实请求才覆盖状态。
    if !args.is_empty() {
        if let Some(state) = app.try_state::<CliArgs>() {
            *state.0.lock().unwrap() = args.clone();
        }
        let _ = app.emit("cli-args", args);
    }
    if focus {
        focus_main_window(app);
    }
}

fn main() {
    let initial: Vec<String> = std::env::args().skip(1).collect();

    // 无窗口入口用于安装修复与后台验收，不初始化 Tauri/WebView。
    if let Some(action) = initial.first().filter(|arg| {
        matches!(
            arg.as_str(),
            "--finder-extension-status" | "--repair-finder-extension"
        )
    }) {
        let result = if action == "--repair-finder-extension" {
            finder::repair()
        } else {
            finder::status()
        };
        match result {
            Ok(state) => println!("{}", serde_json::to_string(&state).unwrap()),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        return;
    }

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(CliArgs(Mutex::new(initial)))
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            // 已有实例在运行：更新参数并通知前端切换视图
            route_cli_request(app, argv.iter().skip(1).cloned().collect(), true);
        }))
        // 菜单工具常驻后台：关闭按钮只隐藏窗口，下次右键仍能复用同一实例；
        // 不做 prevent_close 会导致窗口销毁后没有可复用的 WebView。
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        });
    let app = builder
        .setup(move |app| {
            #[cfg(target_os = "macos")]
            std::thread::spawn(|| {
                let _ = finder::register();
            });
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
            finder::get_finder_integration,
            finder::repair_finder_integration,
            settings::get_settings,
            settings::set_settings,
            settings::get_diagnostics,
            settings::open_project_releases,
            settings::choose_repository,
            ops::status::get_repo_info,
            ops::status::get_status,
            ops::status::get_author_identity,
            ops::diff::get_diff,
            ops::stage::stage_files,
            ops::stage::commit,
            ops::sync::push,
            ops::sync::pull,
            ops::branch::list_branches,
            ops::branch::switch_branch,
            ops::branch::checkout_remote,
            ops::logop::get_log,
            ops::logop::get_log_detail,
            ops::logop::get_commit_file_diff,
            ops::discard::discard_changes,
            ops::conflict::get_conflict_file,
            ops::conflict::resolve_conflict_file,
            ops::conflict::complete_merge,
            ops::conflict::abort_merge,
            ops::initclone::init_repo,
            ops::initclone::clone_repo,
            ops::initclone::cancel_clone,
            ops::initclone::open_in_finder,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    app.run(|app_handle, event| {
        #[cfg(target_os = "macos")]
        match event {
            // 访达菜单通过自定义 URL 打开；冷启动与已运行都会走到这里。
            tauri::RunEvent::Opened { urls } => {
                if let Some(args) = urls.iter().find_map(args_from_request_url) {
                    route_cli_request(app_handle, args, true);
                }
            }
            // 窗口隐藏后点击 Dock 图标应重新回到当前界面（macOS 标准行为）。
            tauri::RunEvent::Reopen { .. } => focus_main_window(app_handle),
            _ => {}
        }
        #[cfg(not(target_os = "macos"))]
        let _ = (app_handle, event);
    });
}

#[cfg(test)]
mod tests {
    use super::args_from_request_url;
    use tauri::Url;

    #[test]
    fn request_url_decodes_unicode_spaces_and_plus() {
        let url = Url::parse(
            "menugit://commit?path=/Users/me/C++%20%E9%A1%B9%E7%9B%AE&file=sub%2F%E6%B5%8B%E8%AF%95%20file.txt",
        )
        .unwrap();
        assert_eq!(
            args_from_request_url(&url),
            Some(vec![
                "commit".into(),
                "--path".into(),
                "/Users/me/C++ 项目".into(),
                "--file".into(),
                "sub/测试 file.txt".into(),
            ])
        );
    }

    #[test]
    fn request_url_rejects_unknown_scheme_and_command() {
        assert_eq!(args_from_request_url(&Url::parse("https://commit?path=/tmp").unwrap()), None);
        assert_eq!(args_from_request_url(&Url::parse("menugit://unknown?path=/tmp").unwrap()), None);
        assert_eq!(args_from_request_url(&Url::parse("menugit://commit").unwrap()).unwrap()[0], "commit");
    }

    #[test]
    fn request_url_skips_empty_values_and_unknown_parameters() {
        let url = Url::parse("menugit://log?path=&file=&url=x&evil=1").unwrap();
        assert_eq!(args_from_request_url(&url), Some(vec!["log".into(), "--url".into(), "x".into()]));
    }
}
