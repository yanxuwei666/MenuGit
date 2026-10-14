import { defineStore } from "pinia";
import { invoke } from "@tauri-apps/api/core";
import { ElMessage } from "element-plus";
import {
  cancelClone,
  cloneRepo,
  initRepo,
  listenCloneProgress,
  toGitError,
  type CloneProgress
} from "../api";
import { useSessionStore } from "./session";

/** 从仓库 URL 推断目标文件夹名：末段去掉 .git（与 Rust 端 repo_name_from_url 一致） */
export function dirNameFromUrl(url: string): string {
  const trimmed = url.trim().replace(/\/+$/, "");
  const last = trimmed.split(/[\\/]/).pop() ?? "";
  return last.replace(/\.git$/, "");
}

/** URL 合法性：https:// 或 git@ 或 ssh:// 形式 */
export function isValidCloneUrl(url: string): boolean {
  return /^(https:\/\/|git@|ssh:\/\/)/.test(url.trim());
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

export const useRepoOpsStore = defineStore("repoops", {
  state: () => ({
    /** 初始化执行中（FM-09） */
    initializing: false,

    /* ── 克隆表单（FM-10） ── */
    url: "",
    /** 目标文件夹名：默认 URL 末段去掉 .git */
    dir: "",
    /** 克隆阶段：form 表单 / running 进行中 / done 已结束（含失败） */
    phase: "form" as "form" | "running" | "done",
    /** 启动克隆返回的订阅 / 取消标识 */
    repoKey: "",
    /** 克隆目标目录（绝对路径，来自后端） */
    targetDir: "",
    /** 最新进度（已按 repoKey 过滤） */
    progress: null as CloneProgress | null,
    /** 累计原始输出（失败时在折叠面板展示） */
    output: "",
    /** 进度订阅取消函数 */
    unlisten: null as (() => void) | null
  }),

  getters: {
    /** URL 非空但不合法时的即时提示 */
    urlError(): string {
      const u = this.url.trim();
      return u && !isValidCloneUrl(u)
        ? "仓库 URL 需以 https://、git@ 或 ssh:// 开头"
        : "";
    },
    canClone(): boolean {
      return this.phase === "form" && !!this.url.trim() && !this.urlError;
    },
    /** 进度条百分比（percent 非空时展示） */
    percent(): number | null {
      return this.progress?.percent ?? null;
    },
    /** 失败信息（done 且 error 时有值） */
    failMessage(): string {
      return this.progress?.message ?? "";
    },
    /** 是否处于失败态（含启动失败） */
    failed(): boolean {
      return this.phase === "done" && (this.progress?.error ?? false);
    },
    /** 认证失败：原始输出含 Authentication / publickey */
    authFailed(): boolean {
      return /Authentication|publickey/i.test(
        `${this.output} ${this.failMessage}`
      );
    }
  },

  actions: {
    /* ══════════ FM-09 初始化 ══════════ */

    /** 在目标目录初始化仓库（视图正文即确认框）；成功后切到提交视图 */
    async doInit(path: string) {
      if (this.initializing) return;
      this.initializing = true;
      try {
        await initRepo(path);
        ElMessage.success("仓库已创建");
        const s = useSessionStore();
        s.request = { ...s.request, view: "commit" }; // commit store 会自动加载数据
      } catch (e) {
        // 已是仓库等错误：用 err.message 呈现（如"此处已在仓库 xxx 中"），不执行
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "初始化失败",
          showClose: true,
          duration: 5000
        });
      } finally {
        this.initializing = false;
      }
    },

    /** 浏览器演示初始化 */
    async mockInit() {
      this.initializing = true;
      await sleep(700);
      this.initializing = false;
      ElMessage.success("仓库已创建");
      const s = useSessionStore();
      s.request = { ...s.request, view: "commit" };
    },

    /** 初始化入口：按环境分发 */
    async startInit() {
      const s = useSessionStore();
      if (!s.tauriReady) {
        await this.mockInit();
        return;
      }
      if (!s.request.path) {
        ElMessage.warning("未指定目录路径");
        return;
      }
      await this.doInit(s.request.path);
    },

    /* ══════════ FM-10 克隆 ══════════ */

    /** URL 输入：同步推断目标文件夹名（沿用原型逻辑） */
    onUrlInput(u: string) {
      this.url = u;
      this.dir = dirNameFromUrl(u);
    },

    /** 重置克隆流程（失败重试 / 离开页面时调用） */
    resetClone() {
      this.unlisten?.();
      this.unlisten = null;
      this.phase = "form";
      this.progress = null;
      this.output = "";
      this.repoKey = "";
      this.targetDir = "";
    },

    /** 开始克隆：cloneRepo → 订阅 clone-progress（按 repoKey 过滤） */
    async startClone(path: string) {
      if (!this.canClone || this.phase === "running") return;
      try {
        const r = await cloneRepo(path, this.url.trim(), this.dir.trim() || undefined);
        this.repoKey = r.repoKey;
        this.targetDir = r.targetDir;
        this.progress = null;
        this.output = "";
        this.phase = "running";

        this.unlisten?.();
        this.unlisten = await listenCloneProgress((p) => {
          if (p.repoKey !== this.repoKey) return;
          this.progress = p;
          if (p.text) this.output = this.output ? `${this.output}\n${p.text}` : p.text;
          if (p.done) {
            this.unlisten?.();
            this.unlisten = null;
            this.phase = "done";
            if (!p.error) ElMessage.success("克隆完成");
          }
        });
      } catch (e) {
        // 启动失败（如目标目录已存在非空等）：直接以错误态呈现
        const err = toGitError(e);
        this.progress = {
          repoKey: "",
          percent: null,
          text: err.stderr,
          done: true,
          error: true,
          message: err.message || "克隆失败"
        };
        this.output = err.stderr;
        this.phase = "done";
      }
    },

    /** 浏览器演示克隆（模拟进度） */
    async mockClone() {
      this.targetDir = "（演示）";
      this.phase = "running";
      this.output = "";
      for (let p = 10; p <= 100; p += 15) {
        this.progress = {
          repoKey: "mock",
          percent: p,
          text: `接收对象中: ${p}%`,
          done: false,
          error: false,
          message: null
        };
        await sleep(160);
      }
      this.progress = {
        repoKey: "mock",
        percent: 100,
        text: "克隆完成",
        done: true,
        error: false,
        message: null
      };
      this.phase = "done";
      ElMessage.success("克隆完成");
    },

    /** 克隆入口：按环境分发（重试也走这里，先重置流程） */
    async startCloneFlow() {
      const s = useSessionStore();
      if (!s.tauriReady) {
        await this.mockClone();
        return;
      }
      if (!s.request.path) {
        ElMessage.warning("未指定父目录路径");
        return;
      }
      await this.startClone(s.request.path);
    },

    /** 失败重试：重置表单后重新执行 */
    async retryClone() {
      this.resetClone();
      await this.startCloneFlow();
    },

    /** 取消克隆（终止整个 git 进程树；结果经 done 事件回传） */
    async cancelCloneRun() {
      if (!this.repoKey) return;
      try {
        await cancelClone(this.repoKey);
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "取消失败",
          showClose: true,
          duration: 5000
        });
      }
    },

    /** 打开克隆目标文件夹 */
    // TODO: 汇总时迁移到 api.ts（open_dir 命令封装）
    async openTargetDir() {
      if (!this.targetDir) return;
      try {
        await invoke("open_dir", { path: this.targetDir });
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "打开文件夹失败",
          showClose: true,
          duration: 5000
        });
      }
    },

    /** 离开克隆视图：清理订阅 */
    dispose() {
      this.unlisten?.();
      this.unlisten = null;
    },

    /** 返回提交视图（取消 / 关闭） */
    backToCommit() {
      this.dispose();
      const s = useSessionStore();
      s.request = { ...s.request, view: "commit" };
    }
  }
});
