/**
 * sync.ts —— 推送（FM-04）与拉取（FM-03）共用状态。
 *
 * 两个面板同构：进入时 load() 拉取仓库概要与远端分支列表；
 * 执行后刷新概要；取消走 PRD 闭环（工作区干净 → 关窗，否则回提交窗口）。
 * 浏览器（无 Tauri 环境）保持静态示例数据，仅供布局调试。
 */
import { defineStore } from "pinia";
import { notifySuccess, notifyError, notifyWarning } from "../ui/feedback";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  getRepoInfo,
  getStatus,
  listBranches,
  push as apiPush,
  pull as apiPull,
  toGitError,
  type RepoInfo,
  type PullResult
} from "../api";
import { useSessionStore } from "./session";

/** 分支名校验（沿用原型规则：不允许空格、中文与特殊字符） */
export function validBranchName(v: string): boolean {
  return v.length > 0 && !/[\s\u4e00-\u9fa5]/.test(v) && !/[^a-zA-Z0-9_\-\/.]/.test(v);
}

/** PullResult → 摘要文案（commits>0 显示数量，否则视为已是最新） */
export function pullSummaryTextOf(r: PullResult): string {
  if (r.commits != null && r.commits > 0) {
    return `拉入 ${r.commits} 个提交${r.filesChanged != null ? `，更新 ${r.filesChanged} 个文件` : ""}`;
  }
  return "已是最新";
}

export const useSyncStore = defineStore("sync", {
  state: () => ({
    /** 真实仓库根路径；null = 浏览器 mock 模式 */
    repoPath: null as string | null,
    /** 仓库数据加载中 */
    loading: false,
    /** 加载失败信息 */
    loadError: null as string | null,
    /** 仓库概要（mock 模式为静态示例） */
    repo: {
      name: "my-project",
      branch: "main",
      upstream: "origin/main" as string | null,
      ahead: 1,
      behind: 0
    },
    /** 远端分支名（去掉 origin/ 前缀，供下拉选择/新建） */
    remoteBranches: ["main", "dev", "feature-search"] as string[],

    /* ── 推送（FM-04） ── */
    /** 推送目标远端分支（默认上游分支；可输入新名称） */
    pushTarget: "main",
    /** 推送进行中 */
    pushing: false,
    /** 推送进行中的状态文字 */
    pushStatus: "",
    /** 推送成功（显示"已同步"，底部按钮变"完成"） */
    pushDone: false,
    /** 推送被拒（远端有新提交，引导先拉取） */
    pushRejected: false,

    /* ── 拉取（FM-03） ── */
    /** 拉取来源远端分支（默认上游分支；可跨分支选择） */
    pullSource: "main",
    /** 拉取进行中 */
    pulling: false,
    /** 拉取进行中的状态文字 */
    pullStatus: "",
    /** 拉取完成（显示摘要） */
    pullDone: false,
    /** 拉取产生冲突 */
    pullConflict: false,
    /** 拉取结果摘要 */
    pullSummary: null as { commits: number | null; filesChanged: number | null } | null
  }),

  getters: {
    /** 是否已设置上游分支 */
    hasUpstream: (s) => !!s.repo.upstream,
    /** 推送目标是否为远端不存在的新分支 */
    isNewTarget: (s) =>
      s.pushTarget.trim() !== "" && !s.remoteBranches.includes(s.pushTarget.trim()),
    /** 推送是否需要 -u：目标为新分支或当前无上游 */
    pushSetUpstream(): boolean {
      return this.isNewTarget || !this.hasUpstream;
    },
    /** 拉取是否需要 -u：当前无上游时，把所选来源设为上游 */
    pullSetUpstream(): boolean {
      return !this.hasUpstream;
    },
    /** 推送按钮可用：目标分支名非空且未在执行中 */
    canPush(): boolean {
      return !this.pushing && !this.pushDone && this.pushTarget.trim().length > 0;
    },
    /** 拉取按钮可用：来源分支名非空且未在执行中 */
    canPull(): boolean {
      return !this.pulling && this.pullSource.trim().length > 0;
    },
    /** 拉取结果摘要文案 */
    pullSummaryText(): string {
      return this.pullSummary
        ? pullSummaryTextOf({ ...this.pullSummary, raw: "" })
        : "已是最新";
    },
    /** 本地区同步描述（口径同提交窗口） */
    localSyncText(): string {
      const { ahead, behind, upstream } = this.repo;
      if (!upstream) return "尚未设置上游分支";
      if (ahead > 0) return `领先 ${upstream} ${ahead} 个提交`;
      if (behind > 0) return `落后 ${upstream} ${behind} 个提交`;
      return `与 ${upstream} 同步`;
    }
  },

  actions: {
    /** 应用仓库概要并复位默认目标/来源（上游短名；无上游为空） */
    applyInfo(info: RepoInfo) {
      this.repo = {
        name:
          info.path
            ?.replace(/[\\/]+$/, "")
            .split(/[\\/]/)
            .pop() || "仓库",
        branch: info.branch ?? "(未检出)",
        upstream: info.upstream,
        ahead: info.ahead,
        behind: info.behind
      };
      const up = info.upstream?.replace(/^origin\//, "") ?? "";
      this.pushTarget = up;
      this.pullSource = up;
    },

    /** 载入仓库概要与远端分支列表（Tauri 环境，由视图挂载时调用） */
    async load(path: string) {
      this.repoPath = path;
      this.loading = true;
      this.loadError = null;
      try {
        const [info, branches] = await Promise.all([getRepoInfo(path), listBranches(path)]);
        this.applyInfo(info);
        this.remoteBranches = branches.remote
          .map((b) => b.name.replace(/^origin\//, ""))
          .filter((n) => n.length > 0);
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "加载仓库状态失败";
      } finally {
        this.loading = false;
      }
    },

    /** 执行推送（FM-04）：目标为新分支或无上游时附带 -u；被拒时引导先拉取 */
    async doPush() {
      if (!this.canPush) return;
      const path = this.repoPath;
      if (!path) {
        await this.mockPush();
        return;
      }
      const target = this.pushTarget.trim();
      if (!validBranchName(target)) {
        notifyWarning("分支名不能含空格、中文或特殊字符");
        return;
      }
      this.pushing = true;
      this.pushRejected = false;
      this.pushStatus = `正在推送到 origin/${target}…`;
      try {
        await apiPush(path, target, this.pushSetUpstream);
        await this.load(path);
        this.pushDone = true;
        this.pushStatus = "";
        notifySuccess(`已推送到 origin/${target}`);
      } catch (e) {
        const err = toGitError(e);
        if (/rejected/i.test(`${err.message}\n${err.stderr}`)) {
          // 远端有新提交被拒：红色提示条 + 立即拉取（PRD 闭环）
          this.pushRejected = true;
          this.pushStatus = "";
        } else {
          notifyError(err.message || "推送失败");
        }
      } finally {
        this.pushing = false;
      }
    },

    /** 推送被拒后的"立即拉取"：默认 git pull；成功显示摘要，冲突进入冲突处理 */
    async pullNow() {
      const path = this.repoPath;
      if (!path || this.pulling) return;
      this.pulling = true;
      this.pullStatus = "正在拉取远端更新…";
      try {
        const r = await apiPull(path);
        await this.load(path);
        if (/CONFLICT/i.test(r.raw)) {
          this.enterConflict();
          return;
        }
        this.pushRejected = false;
        this.pullStatus = "";
        notifySuccess(pullSummaryTextOf(r));
      } catch (e) {
        const err = toGitError(e);
        if (/CONFLICT/i.test(`${err.message}\n${err.stderr}`)) {
          this.enterConflict();
        } else {
          notifyError(err.message || "拉取失败");
        }
      } finally {
        this.pulling = false;
      }
    },

    /** 执行拉取（FM-03）：无上游时附带 -u；允许跨分支拉取 */
    async doPull() {
      if (!this.canPull) return;
      const path = this.repoPath;
      if (!path) {
        await this.mockPull();
        return;
      }
      const source = this.pullSource.trim();
      if (!validBranchName(source)) {
        notifyWarning("分支名不能含空格、中文或特殊字符");
        return;
      }
      this.pulling = true;
      this.pullConflict = false;
      this.pullDone = false;
      this.pullSummary = null;
      this.pullStatus = `正在从 origin/${source} 拉取…`;
      try {
        const r = await apiPull(path, source, this.pullSetUpstream);
        await this.load(path);
        if (/CONFLICT/i.test(r.raw)) {
          this.enterConflict();
          return;
        }
        this.pullDone = true;
        this.pullStatus = "";
        this.pullSummary = { commits: r.commits, filesChanged: r.filesChanged };
        notifySuccess(pullSummaryTextOf(r));
      } catch (e) {
        const err = toGitError(e);
        if (/CONFLICT/i.test(`${err.message}\n${err.stderr}`)) {
          this.enterConflict();
        } else {
          notifyError(err.message || "拉取失败");
        }
      } finally {
        this.pulling = false;
      }
    },

    /** 冲突闭环：提示并切换到冲突处理视图 */
    enterConflict() {
      this.pullStatus = "";
      notifyWarning("拉取产生冲突，进入冲突处理");
      const session = useSessionStore();
      session.request = { ...session.request, view: "conflict" };
    },

    /** 取消 / 完成（PRD 闭环）：工作区干净 → 关窗；否则回提交窗口（commit store 状态保留） */
    async cancel() {
      const path = this.repoPath;
      if (!path) {
        // 浏览器 mock：演示返回提交视图
        useSessionStore().request = { ...useSessionStore().request, view: "commit" };
        return;
      }
      if (!("__TAURI_INTERNALS__" in window)) return;
      try {
        const files = await getStatus(path);
        if (files.length === 0) {
          await getCurrentWindow().close();
        } else {
          useSessionStore().request = { ...useSessionStore().request, view: "commit" };
        }
      } catch (e) {
        const err = toGitError(e);
        notifyError(err.message || "检查工作区状态失败");
      }
    },

    /** 浏览器 mock 推送（静态示例演示） */
    async mockPush() {
      this.pushing = true;
      this.pushStatus = `正在推送到 origin/${this.pushTarget}…`;
      await new Promise((r) => setTimeout(r, 600));
      this.pushing = false;
      this.pushStatus = "";
      this.repo.ahead = 0;
      this.repo.upstream = `origin/${this.pushTarget}`;
      this.pushDone = true;
      notifySuccess(`已推送到 origin/${this.pushTarget}`);
    },

    /** 浏览器 mock 拉取（静态示例演示） */
    async mockPull() {
      this.pulling = true;
      this.pullStatus = `正在从 origin/${this.pullSource} 拉取…`;
      await new Promise((r) => setTimeout(r, 600));
      this.pulling = false;
      this.pullStatus = "";
      this.pullDone = true;
      this.repo.behind = 0;
      this.pullSummary = { commits: 1, filesChanged: 2 };
      notifySuccess(this.pullSummaryText);
    }
  }
});
