/**
 * log.ts —— 日志窗口（FM-06）状态。
 *
 * 提交列表（分页滚动加载）+ 提交详情（变更文件 / 单文件差异）；
 * 相对时间与 refs 徽章由前端计算；错误统一归一化，
 * 原始 stderr 交由视图用 el-collapse 展示（R5）。
 */

import { defineStore } from "pinia";
import { invoke } from "@tauri-apps/api/core";
import { notifyError } from "../ui/feedback";
import { getLog, toGitError } from "../api";
import { parseDiff, type DiffLine } from "./commit";
import { useSessionStore } from "./session";

/** 每页条数（滚动到底自动追加） */
const PAGE_SIZE = 200;

// TODO: 汇总时迁移到 api.ts（随 get_commit_files / get_commit_diff 新命令一起）
/** 提交中单个变更文件条目（与 Rust CommitFileEntry 对应，字段 camelCase） */
export interface CommitFileEntry {
  /** 文件路径（重命名时为新路径） */
  path: string;
  /** 变更状态字母：A 新增 / M 修改 / D 删除 / R 重命名 等 */
  change: string;
  /** 重命名/复制时的原路径（旧名 → 新名展示用） */
  origPath: string | null;
}

/** 单文件提交差异结果（与 api.ts DiffResult 同构） */
interface CommitDiffResult {
  isBinary: boolean;
  text: string;
}

/** 含完整正文的日志条目（get_log 已返回 body 字段；api.ts LogEntry 类型同步前在此扩展） */
export interface LogEntryWithBody {
  hash: string;
  shortHash: string;
  subject: string;
  author: string;
  /** epoch 秒 */
  time: number;
  refs: string[];
  /** subject 之外的完整提交正文（可能为空） */
  body: string;
}

// TODO: 汇总时迁移到 api.ts
/** 某次提交的变更文件列表（git diff-tree --name-status） */
async function getCommitFiles(path: string, hash: string): Promise<CommitFileEntry[]> {
  try {
    return await invoke<CommitFileEntry[]>("get_commit_files", { path, hash });
  } catch (e) {
    throw toGitError(e);
  }
}

// TODO: 汇总时迁移到 api.ts
/** 某次提交中单文件差异（git show <hash> -- <file>，对比其父提交） */
async function getCommitDiff(path: string, hash: string, file: string): Promise<CommitDiffResult> {
  try {
    return await invoke<CommitDiffResult>("get_commit_diff", { path, hash, file });
  } catch (e) {
    throw toGitError(e);
  }
}

/** epoch 秒 → 相对时间：刚刚 / n 分钟前 / n 小时前 / n 天前；超过 30 天显示日期 */
export function relTime(epochSec: number): string {
  const diff = Math.floor(Date.now() / 1000) - epochSec;
  if (diff < 60) return "刚刚";
  if (diff < 3600) return `${Math.floor(diff / 60)} 分钟前`;
  if (diff < 86400) return `${Math.floor(diff / 3600)} 小时前`;
  if (diff < 86400 * 30) return `${Math.floor(diff / 86400)} 天前`;
  const d = new Date(epochSec * 1000);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** refs 徽章样式类别 */
export type RefBadgeKind = "head" | "br" | "org" | "tag";

/** 单条 ref → 徽章类别：HEAD / 本地分支 / 远端 / 标签 */
export function refKind(ref: string): RefBadgeKind {
  if (ref.includes("HEAD")) return "head";
  if (ref.startsWith("tag:")) return "tag";
  if (ref.startsWith("origin/")) return "org";
  return "br";
}

/** 状态字母 → 徽章色类别（A/M/D/R 有专属色，其余用中性色） */
export function changeKind(change: string): "A" | "M" | "D" | "R" | "X" {
  return change === "A" || change === "M" || change === "D" || change === "R" ? (change as "A" | "M" | "D" | "R") : "X";
}

/** 最近一次失败信息（视图用 el-collapse 展示原始输出） */
export interface LogError {
  message: string;
  stderr: string;
}

/* ───────── mock 数据（浏览器调试用；取自原型演示数据） ───────── */

const NOW = Math.floor(Date.now() / 1000);

const MOCK_LOG: LogEntryWithBody[] = [
  {
    hash: "e4f2a91c8b3d5f6a7e8c9d0b1a2c3d4e5f60718",
    shortHash: "e4f2a91",
    subject: "修复配置读取缺少环境变量时的崩溃",
    author: "yxw",
    time: NOW - 60 * 42,
    refs: ["HEAD -> main", "origin/main"],
    body: "load_config 在 APP_CONFIG 缺失时直接抛出未捕获异常，\n改为给出明确报错信息并记录日志。"
  },
  {
    hash: "9a3b7c2d1e0f5a6b7c8d9e0f1a2b3c4d5e6f7081",
    shortHash: "9a3b7c2",
    subject: "新增 JSON 工具函数（ensure_ascii=False）",
    author: "yxw",
    time: NOW - 3600 * 5,
    refs: [],
    body: ""
  },
  {
    hash: "77c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3",
    shortHash: "77c1d0e",
    subject: "更新安装文档至 v1.2",
    author: "lihua",
    time: NOW - 86400 * 2,
    refs: ["tag: v1.2"],
    body: "内容从 docs/old.md 迁移到 docs/install.md。"
  },
  {
    hash: "12ab34cd56ef78ab90cd12ef34ab56cd78ef90ab",
    shortHash: "12ab34c",
    subject: "初始化项目结构",
    author: "yxw",
    time: NOW - 86400 * 40,
    refs: [],
    body: ""
  }
];

/** mock：另一分支上的提交（"显示所有分支"时出现） */
const MOCK_LOG_OTHER: LogEntryWithBody[] = [
  {
    hash: "aa11bb22cc33dd44ee55ff6600778899aabbccdd",
    shortHash: "aa11bb2",
    subject: "（dev）调整缓存策略实验参数",
    author: "liming",
    time: NOW - 3600 * 26,
    refs: ["origin/dev"],
    body: ""
  }
];

const MOCK_FILES: Record<string, CommitFileEntry[]> = {
  e4f2a91c8b3d5f6a7e8c9d0b1a2c3d4e5f60718: [
    { path: "src/app.py", change: "M", origPath: null },
    { path: "src/utils.py", change: "A", origPath: null }
  ],
  "9a3b7c2d1e0f5a6b7c8d9e0f1a2b3c4d5e6f7081": [{ path: "src/utils.py", change: "A", origPath: null }],
  "77c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3": [
    { path: "docs/install.md", change: "R", origPath: "docs/old.md" },
    { path: "README.md", change: "M", origPath: null }
  ],
  "12ab34cd56ef78ab90cd12ef34ab56cd78ef90ab": [{ path: "src/app.py", change: "A", origPath: null }],
  aa11bb22cc33dd44ee55ff6600778899aabbccdd: [{ path: "src/cache.py", change: "M", origPath: null }]
};

const MOCK_DIFFS: Record<string, DiffLine[]> = {
  "src/app.py": [
    { type: "hunk", text: "@@ -12,7 +12,9 @@ def main()" },
    { type: "ctxl", text: "def load_config():" },
    { type: "del", text: '    path = os.environ.get("APP_CONFIG")' },
    { type: "add", text: "    if not path:" },
    { type: "add", text: '        raise ConfigError("missing APP_CONFIG")' },
    { type: "ctxl", text: "    return parse(path)" }
  ],
  "src/utils.py": [
    { type: "hunk", text: "@@ -0,0 +1,6 @@" },
    { type: "add", text: '"""通用工具函数"""' },
    { type: "add", text: "import json" },
    { type: "add", text: "def to_json(obj, indent=2):" },
    { type: "add", text: "    return json.dumps(obj, ensure_ascii=False, indent=indent)" }
  ],
  "docs/install.md": [
    { type: "hunk", text: "@@ -1,5 +1,6 @@" },
    { type: "add", text: "# 安装指南（v1.2）" },
    { type: "ctxl", text: "## 环境要求" },
    { type: "del", text: "本文档描述 v1.x 的安装方式。" }
  ],
  "README.md": [
    { type: "hunk", text: "@@ -3,4 +3,5 @@" },
    { type: "ctxl", text: "# MenuGit" },
    { type: "add", text: "轻量 Git 右键菜单工具。" }
  ],
  "src/cache.py": [
    { type: "hunk", text: "@@ -8,6 +8,7 @@ class Cache:" },
    { type: "add", text: "    TTL = 120  # 实验参数" }
  ]
};

export const useLogStore = defineStore("log", {
  state: () => ({
    /** 真实仓库根路径；null = 浏览器 mock 模式 */
    repoPath: null as string | null,
    repoName: "my-project",
    loading: false,
    loadError: null as string | null,
    /** 提交列表（服务端分页，前端过滤） */
    entries: [] as LogEntryWithBody[],
    /** "显示所有分支"开关（getLog all 参数） */
    all: false,
    /** 过滤关键字（提交信息 / 作者，前端实时过滤） */
    filter: "",
    /** 当前展开详情的提交 hash */
    expanded: null as string | null,
    /** 展开提交的变更文件列表 */
    files: [] as CommitFileEntry[],
    filesLoading: false,
    /** 展开提交中选中查看 diff 的文件路径 */
    selectedFile: null as string | null,
    fileDiff: [] as DiffLine[],
    fileBinary: false,
    diffLoading: false,
    /** 追加页加载中 */
    loadingMore: false,
    /** 服务端是否还有更多（返回满一页则认为可能还有） */
    hasMore: false,
    /** 最近一次失败的错误 */
    lastError: null as LogError | null
  }),

  getters: {
    /** 按提交信息 / 作者实时过滤后的列表 */
    filtered(): LogEntryWithBody[] {
      const k = this.filter.trim().toLowerCase();
      if (!k) return this.entries;
      return this.entries.filter(
        (c) => c.subject.toLowerCase().includes(k) || c.author.toLowerCase().includes(k)
      );
    },
    /** 展开提交的完整信息（subject + 正文） */
    fullMessage(): string {
      const c = this.entries.find((x) => x.hash === this.expanded);
      if (!c) return "";
      return c.body.trim() ? `${c.subject}\n\n${c.body}` : c.subject;
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

    /** 加载第一页日志（all=true 时显示所有分支的提交） */
    async load(path: string, all = false) {
      this.repoPath = path;
      this.repoName =
        path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "仓库";
      this.loading = true;
      this.loadError = null;
      this.expanded = null;
      this.selectedFile = null;
      this.fileDiff = [];
      this.filter = "";
      this.all = all;
      this.lastError = null;
      try {
        const list = (await getLog(path, { all, skip: 0, limit: PAGE_SIZE })) as LogEntryWithBody[];
        this.entries = list;
        this.hasMore = list.length >= PAGE_SIZE;
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "读取提交日志失败";
      } finally {
        this.loading = false;
      }
    },

    /** 切换"显示所有分支"：重头加载 */
    async toggleAll() {
      if (this.repoPath == null) {
        // mock：拼接另一分支的提交
        this.all = !this.all;
        this.expanded = null;
        this.selectedFile = null;
        this.fileDiff = [];
        this.entries = this.all
          ? [...MOCK_LOG, ...MOCK_LOG_OTHER].sort((a, b) => b.time - a.time)
          : MOCK_LOG;
        return;
      }
      await this.load(this.repoPath, !this.all);
    },

    /** 滚动到底自动追加下一页（skip = 已加载条数；过滤为前端行为不影响 skip） */
    async loadMore() {
      if (this.loadingMore || !this.hasMore || this.repoPath == null) return;
      this.loadingMore = true;
      try {
        const list = (await getLog(this.repoPath, {
          all: this.all,
          skip: this.entries.length,
          limit: PAGE_SIZE
        })) as LogEntryWithBody[];
        this.entries.push(...list);
        this.hasMore = list.length >= PAGE_SIZE;
      } catch (e) {
        this.handleError(e, "读取更多提交失败");
      } finally {
        this.loadingMore = false;
      }
    },

    /** 点击提交行：展开 / 收起详情（展开时加载变更文件列表） */
    toggleExpand(hash: string) {
      if (this.expanded === hash) {
        this.expanded = null;
        this.files = [];
        this.selectedFile = null;
        this.fileDiff = [];
        return;
      }
      this.expanded = hash;
      this.selectedFile = null;
      this.fileDiff = [];
      this.files = [];
      this.loadFiles(hash);
    },

    /** 加载展开提交的变更文件列表 */
    async loadFiles(hash: string) {
      this.filesLoading = true;
      try {
        this.files =
          this.repoPath == null
            ? MOCK_FILES[hash] ?? []
            : await getCommitFiles(this.repoPath, hash);
      } catch (e) {
        this.handleError(e, "读取提交文件列表失败");
        this.files = [];
      } finally {
        this.filesLoading = false;
      }
    },

    /** 点击变更文件：加载该提交中该文件的 diff（对比其父提交），复用 parseDiff 解析 */
    async selectFile(f: CommitFileEntry) {
      if (!this.expanded) return;
      this.selectedFile = f.path;
      this.fileDiff = [];
      this.fileBinary = false;
      if (this.repoPath == null) {
        // mock：预置 diff
        const lines = MOCK_DIFFS[f.path];
        this.fileDiff = lines ?? [{ type: "ctxl", text: "（演示数据：该文件无差异内容）" }];
        return;
      }
      this.diffLoading = true;
      try {
        const r = await getCommitDiff(this.repoPath, this.expanded, f.path);
        this.fileBinary = r.isBinary;
        this.fileDiff = r.isBinary ? [] : parseDiff(r.text);
      } catch (e) {
        const err = toGitError(e);
        this.fileDiff = [{ type: "ctxl", text: `读取差异失败：${err.message}` }];
      } finally {
        this.diffLoading = false;
      }
    },

    /** 统一错误处理：归一化 + notifyError + 保留原始 stderr 供 el-collapse 展开 */
    handleError(e: unknown, fallback: string) {
      const err = toGitError(e);
      this.lastError = { message: err.message || fallback, stderr: err.stderr };
      notifyError(err.message || fallback);
    },

    /** 返回提交视图（提交窗口状态保留在 store 中） */
    backToCommit() {
      const session = useSessionStore();
      session.request = { ...session.request, view: "commit" };
    },

    /** 底部"完成"按钮 */
    done() {
      this.backToCommit();
    },

    /** 浏览器 mock 初始化 */
    mockLoad() {
      this.repoPath = null;
      this.repoName = "my-project";
      this.entries = MOCK_LOG;
      this.hasMore = false;
      this.loading = false;
    }
  }
});
