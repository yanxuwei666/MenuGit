/**
 * branch.ts —— 分支窗口（FM-05）状态。
 *
 * 列表 / 切换 / 检出远端 / 新建分支；错误统一归一化，
 * 原始 stderr 交由视图用 el-collapse 展示（R5）。
 */

import { defineStore } from "pinia";
import { ElMessage } from "element-plus";
import {
  checkoutRemote,
  getRepoInfo,
  listBranches,
  switchBranch,
  toGitError,
  type BranchInfo
} from "../api";
import { useSessionStore } from "./session";

/** 从仓库路径取末段作为展示名 */
export function repoDisplayName(path: string | null): string {
  if (!path) return "my-project";
  return path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "仓库";
}

/** 分支名合法性校验：空 / 空格 / 中文（含中文标点）/ git 保留字符（~^:?*[\） */
export function validateBranchName(v: string, existing: string[]): string {
  const name = v.trim();
  if (!name) return "分支名不能为空";
  if (/[\s\u4e00-\u9fa5]/.test(name) || /[^a-zA-Z0-9_\-\/.]/.test(name)) {
    return "分支名不能含空格、中文或特殊字符";
  }
  if (existing.includes(name)) return "分支已存在";
  return "";
}

/** 从 stderr 提取"会被覆盖"的文件名列表（缩进的路径行） */
function overwrittenFiles(stderr: string): string[] {
  return stderr
    .split("\n")
    .map((l) => l.trim())
    .filter(
      (l) =>
        l &&
        !/^(error|fatal|hint|please|aborting|update your working|and has no)/i.test(l) &&
        !l.includes("would be overwritten")
    );
}

/** 最近一次失败信息（视图用 el-collapse 展示原始输出） */
export interface BranchError {
  message: string;
  stderr: string;
  /** "会被覆盖"场景下从 stderr 提取的文件列表 */
  files: string[];
}

export const useBranchStore = defineStore("branch", {
  state: () => ({
    /** 真实仓库根路径；null = 浏览器 mock 模式 */
    repoPath: null as string | null,
    repoName: "my-project",
    loading: false,
    loadError: null as string | null,
    /** 切换 / 检出 / 新建进行中 */
    busy: false,
    /** 仓库概要（切换成功后经 getRepoInfo 刷新） */
    repo: {
      branch: "main",
      upstream: null as string | null,
      ahead: 0,
      behind: 0
    },
    /** 本地 / 远端分支列表（当前分支在视图中置顶） */
    local: [] as BranchInfo[],
    remote: [] as BranchInfo[],
    current: null as string | null,
    /** 分支名过滤关键字 */
    filter: "",
    /** 新建分支输入 */
    newName: "",
    /** 最近一次操作失败的错误 */
    lastError: null as BranchError | null
  }),

  getters: {
    /** 当前分支置顶后的本地分支（按名称过滤） */
    filteredLocal(): BranchInfo[] {
      const k = this.filter.trim().toLowerCase();
      const arr = (
        k ? this.local.filter((b) => b.name.toLowerCase().includes(k)) : this.local.slice()
      ).sort((a, b) => (b.isCurrent ? 1 : 0) - (a.isCurrent ? 1 : 0));
      return arr;
    },
    filteredRemote(state): BranchInfo[] {
      const k = this.filter.trim().toLowerCase();
      return k ? state.remote.filter((b) => b.name.toLowerCase().includes(k)) : state.remote;
    },
    /** 新建分支即时校验提示 */
    nameError(): string {
      return validateBranchName(
        this.newName,
        this.local.map((b) => b.name)
      );
    },
    /** 远端分支在本地是否已存在同名分支（避免重复检出） */
    remoteCheckedOut(state): (name: string) => boolean {
      return (name: string) => {
        const short = name.replace(/^origin\//, "");
        return state.local.some((b) => b.name === short);
      };
    }
  },

  actions: {
    /** 初始化：浏览器环境走 mock；Tauri 环境按仓库路径加载 */
    async init(path: string | null | undefined) {
      if (!("__TAURI_INTERNALS__" in window)) {
        this.mockLoad();
        return;
      }
      if (!path) {
        this.loadError = "未指定仓库路径";
        return;
      }
      await this.load(path);
    },

    /** 加载分支列表 + 仓库概要 */
    async load(path: string) {
      this.repoPath = path;
      this.repoName = repoDisplayName(path);
      this.loading = true;
      this.loadError = null;
      this.filter = "";
      this.newName = "";
      this.lastError = null;
      try {
        await this.refresh(path);
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "加载分支列表失败";
      } finally {
        this.loading = false;
      }
    },

    /** 刷新列表与仓库概要（切换 / 检出成功后调用） */
    async refresh(path: string) {
      const [list, info] = await Promise.all([listBranches(path), getRepoInfo(path)]);
      this.local = list.local;
      this.remote = list.remote;
      this.current = list.current;
      this.repo = {
        branch: info.branch ?? "(未检出)",
        upstream: info.upstream,
        ahead: info.ahead,
        behind: info.behind
      };
    },

    /** 切换本地分支（FM-05）；成功后自动返回提交视图 */
    async switchTo(name: string) {
      if (this.busy || name === this.current) return;
      const path = this.repoPath;
      if (path == null) {
        this.mockSwitch(name, "已切换到");
        return;
      }
      this.busy = true;
      this.lastError = null;
      try {
        await switchBranch(path, name);
        ElMessage.success(`已切换到 ${name}`);
        await this.refresh(path);
        this.backToCommit();
      } catch (e) {
        this.handleError(e, "切换失败");
      } finally {
        this.busy = false;
      }
    },

    /** 检出远端分支为本地（建立跟踪） */
    async checkoutRemoteBranch(name: string) {
      if (this.busy) return;
      const path = this.repoPath;
      if (path == null) {
        this.mockCheckout(name);
        return;
      }
      this.busy = true;
      this.lastError = null;
      try {
        await checkoutRemote(path, name);
        ElMessage.success(`已检出 ${name} 并建立跟踪`);
        await this.refresh(path);
        this.backToCommit();
      } catch (e) {
        this.handleError(e, "检出失败");
      } finally {
        this.busy = false;
      }
    },

    /** 新建分支（基于当前 HEAD）并立即切换 */
    async createAndSwitch() {
      const name = this.newName.trim();
      if (this.busy || !name) return;
      if (this.nameError) return;
      const path = this.repoPath;
      if (path == null) {
        this.mockSwitch(name, "已创建并切换到");
        return;
      }
      this.busy = true;
      this.lastError = null;
      try {
        await switchBranch(path, name, true);
        ElMessage.success(`已创建并切换到 ${name}`);
        this.newName = "";
        await this.refresh(path);
        this.backToCommit();
      } catch (e) {
        this.handleError(e, "创建分支失败");
      } finally {
        this.busy = false;
      }
    },

    /** 统一错误处理：归一化 + ElMessage + 保留原始 stderr 供 el-collapse 展开 */
    handleError(e: unknown, fallback: string) {
      const err = toGitError(e);
      const overwritten =
        err.message.includes("would be overwritten") ||
        err.message.includes("本地修改") ||
        err.stderr.includes("would be overwritten") ||
        err.stderr.includes("本地修改");
      if (overwritten) {
        this.lastError = {
          message: "未提交修改无法自动携带，请先提交或放弃修改",
          stderr: err.stderr,
          files: overwrittenFiles(err.stderr)
        };
        ElMessage.error({
          message: "未提交修改无法自动携带，请先提交或放弃修改",
          showClose: true,
          duration: 5000
        });
      } else {
        this.lastError = { message: err.message || fallback, stderr: err.stderr, files: [] };
        ElMessage.error({
          message: err.message || fallback,
          showClose: true,
          duration: 5000
        });
      }
    },

    /** 返回提交视图（提交窗口状态保留在 store 中，PRD 要求） */
    backToCommit() {
      const session = useSessionStore();
      session.request = { ...session.request, view: "commit" };
    },

    /** 底部"完成"按钮 */
    done() {
      this.backToCommit();
    },

    /* ───────── 浏览器 mock（无 Tauri 环境的演示数据） ───────── */

    mockLoad() {
      this.repoPath = null;
      this.repoName = "my-project";
      this.current = "main";
      this.repo = { branch: "main", upstream: "origin/main", ahead: 1, behind: 0 };
      this.local = [
        { name: "main", isCurrent: true, upstream: "origin/main" },
        { name: "dev", isCurrent: false, upstream: "origin/dev" },
        { name: "feature-search", isCurrent: false, upstream: null }
      ];
      this.remote = [
        { name: "origin/main", isCurrent: false, upstream: null },
        { name: "origin/dev", isCurrent: false, upstream: null },
        { name: "origin/release-1.2", isCurrent: false, upstream: null }
      ];
      this.loading = false;
    },

    mockSwitch(name: string, text: string) {
      this.busy = true;
      setTimeout(() => {
        if (!this.local.some((b) => b.name === name)) {
          this.local.push({ name, isCurrent: false, upstream: null });
        }
        this.local.forEach((b) => (b.isCurrent = b.name === name));
        this.current = name;
        this.repo.branch = name;
        this.newName = "";
        this.busy = false;
        ElMessage.success(`${text} ${name}`);
        this.backToCommit();
      }, 500);
    },

    mockCheckout(name: string) {
      this.busy = true;
      setTimeout(() => {
        const short = name.replace(/^origin\//, "");
        if (!this.local.some((b) => b.name === short)) {
          this.local.push({ name: short, isCurrent: false, upstream: name });
        }
        this.local.forEach((b) => (b.isCurrent = b.name === short));
        this.current = short;
        this.repo.branch = short;
        this.busy = false;
        ElMessage.success(`已检出 ${name} 并建立跟踪`);
        this.backToCommit();
      }, 500);
    }
  }
});
