import { defineStore } from "pinia";
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";

export type ViewName =
  | "commit"
  | "pull"
  | "push"
  | "branch"
  | "log"
  | "discard"
  | "conflict"
  | "init"
  | "clone"
  | "settings";

export interface CliRequest {
  view: ViewName;
  path?: string;
  file?: string;
  url?: string;
}

const COMMAND_MAP: Record<string, ViewName> = {
  commit: "commit",
  pull: "pull",
  push: "push",
  branch: "branch",
  log: "log",
  discard: "discard",
  conflict: "conflict",
  init: "init",
  clone: "clone",
  settings: "settings"
};

/** 解析 CLI 参数：menugit <command> --path <dir> [--file <p>] [--url <u>] */
export function parseCliArgs(args: string[]): CliRequest {
  const get = (flag: string): string | undefined => {
    const i = args.indexOf(flag);
    return i >= 0 ? args[i + 1] : undefined;
  };
  const command = args[0] ?? "commit";
  return {
    view: COMMAND_MAP[command] ?? "commit",
    path: get("--path"),
    file: get("--file"),
    url: get("--url")
  };
}

export const useSessionStore = defineStore("session", {
  state: () => ({
    request: { view: "commit" } as CliRequest,
    tauriReady: false
  }),
  getters: {
    view: (state) => state.request.view
  },
  actions: {
    async init() {
      // 浏览器直接打开（无 Tauri 环境）时保持默认提交视图，方便纯前端调试
      if (!("__TAURI_INTERNALS__" in window)) {
        this.tauriReady = false;
        return;
      }
      this.tauriReady = true;
      const args = await invoke<string[]>("get_cli_args");
      this.request = parseCliArgs(args);
      await listen("cli-args", async () => {
        const next = await invoke<string[]>("get_cli_args");
        this.request = parseCliArgs(next);
      });
    }
  }
});
