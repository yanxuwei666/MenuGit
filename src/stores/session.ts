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
    tauriReady: false,
    ready: false,
    pushFromCommit: false,
    requestId: 0,
    afterCommit: false
  }),
  getters: {
    view: (state) => state.request.view
  },
  actions: {
    async init() {
      // 浏览器直接打开（无 Tauri 环境）时保持默认提交视图，方便纯前端调试
      if (!("__TAURI_INTERNALS__" in window)) {
        this.tauriReady = false;
        this.ready = true;
        return;
      }
      this.tauriReady = true;
      try {
        // 先订阅，使用事件携带的参数，避免启动/重复右键时漏掉请求或读取旧参数。
        await listen<string[]>("cli-args", (event) => {
          // 普通二次启动（Dock / 访达打开应用）没有请求参数，不能清空当前仓库。
          if (event.payload.length === 0) return;
          this.request = parseCliArgs(event.payload);
          this.requestId += 1;
          this.pushFromCommit = false;
          this.afterCommit = false;
        });
        const before = this.requestId;
        const args = await invoke<string[]>("get_cli_args");
        if (args.length > 0 && before === this.requestId) this.request = parseCliArgs(args);
        this.pushFromCommit = false;
      } catch {
        // 读取失败时保留默认视图，避免把已收到的请求覆盖成空仓库。
      } finally {
        this.ready = true;
      }
    },
    setView(view: ViewName) {
      this.request = { ...this.request, view };
      if (view !== "push") this.pushFromCommit = false;
    },
    openPushFromCommit() {
      this.pushFromCommit = true;
      this.afterCommit = false;
      this.request = { ...this.request, view: "push" };
    },
    openPushAfterCommit() {
      this.openPushFromCommit();
      this.afterCommit = true;
    },
    openWorkspace(path: string, view: ViewName = "commit") {
      this.request = { view, path };
      this.requestId += 1;
      this.pushFromCommit = false;
      this.afterCommit = false;
    },
    chooseWorkspace() {
      this.request = { view: "commit" };
      this.requestId += 1;
    },
    async closeWindow() {
      if (!this.tauriReady) {
        this.request = { ...this.request, view: "commit" };
        return;
      }
      try {
        const { getCurrentWindow } = await import("@tauri-apps/api/window");
        await getCurrentWindow().close();
      } catch {
        this.request = { ...this.request, view: "commit" };
      }
    }
  }
});
