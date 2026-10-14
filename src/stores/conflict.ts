/**
 * conflict.ts —— FM-08 解决冲突状态（Pinia）。
 *
 * 职责：
 * - 冲突面板：getStatus 中 status==="conflict" 的文件 ∪ 本地记录的已解决集合，
 *   统计"已解决 n / 总数 m"；全部处理完后"完成合并提交"才可用；
 * - 编辑器状态：当前文件的冲突段与每块三选一（local / theirs / both），
 *   全部块决定后自动 resolveConflictFile 标记为已解决；
 * - 完成合并提交（completeMerge）与中止合并（abortMerge）。
 * 浏览器环境（无 Tauri）使用底部 mock 数据演示编辑器交互。
 */
import { defineStore } from "pinia";
import { ElMessage, ElMessageBox } from "element-plus";
import {
  getRepoInfo,
  getStatus,
  getConflictFile,
  resolveConflictFile,
  completeMerge,
  abortMerge,
  toGitError,
  type StatusFile,
  type ConflictFileResult,
  type ConflictChoice
} from "../api";
import { useSessionStore } from "./session";
import { useCommitStore } from "./commit";

/** 短暂延时（mock 流程与自动标记的过渡感） */
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** 生成 n 个"未决定"的 choices 数组 */
const nullChoices = (n: number): (ConflictChoice | null)[] =>
  Array<ConflictChoice | null>(n).fill(null);

export const useConflictStore = defineStore("conflict", {
  state: () => ({
    /** 仓库根路径；null = 浏览器 mock 模式 */
    repoPath: null as string | null,
    /** 仓库名（标题栏展示） */
    repoName: "仓库",
    /** 当前分支名（编辑器左右栏标题用） */
    branch: "main",
    /** 上游分支（右栏标题与合并提交信息用） */
    upstream: null as string | null,
    /** 冲突面板加载中 */
    loading: false,
    /** 加载失败信息 */
    loadError: null as string | null,
    /** 本会话已知的冲突文件列表（getStatus 快照 ∪ 本地已解决记录） */
    files: [] as string[],
    /** 本地记录的已解决集合 */
    resolved: [] as string[],
    /** 当前在编辑器中打开的文件 */
    activeFile: null as string | null,
    /** 当前文件的冲突段解析结果 */
    result: null as ConflictFileResult | null,
    /** 每个冲突块的当前选择（顺序与冲突块出现顺序一致） */
    choices: [] as (ConflictChoice | null)[],
    /** 最近一次选择的块序号（自动标记失败时回退该块以便重试） */
    lastPickIdx: 0,
    /** 首次加载的冲突块缓存（文件写回后重新编辑时恢复原块结构） */
    cache: {} as Record<string, ConflictFileResult>,
    /** 已解决文件当时的决策（重新打开已解决文件时恢复高亮，仅供查看） */
    savedChoices: {} as Record<string, (ConflictChoice | null)[]>,
    /** 编辑器加载中 */
    editorLoading: false,
    /** 自动标记进行中 */
    resolving: false,
    /** 完成合并提交进行中 */
    completing: false,
    /** 合并提交信息（进入视图时预填，可编辑） */
    message: ""
  }),

  getters: {
    /** 已解决文件数 */
    resolvedCount: (s) => s.files.filter((f) => s.resolved.includes(f)).length,
    /** 全部冲突文件处理完毕（"完成合并提交"可用条件） */
    allResolved(): boolean {
      return this.files.length > 0 && this.resolvedCount === this.files.length;
    },
    /** 编辑器左栏标题 */
    localLabel: (s) => `你的（当前分支 ${s.branch}）`,
    /** 编辑器右栏标题 */
    theirsLabel: (s) => `传入的（${s.upstream ?? `origin/${s.branch}`}）`,
    /** 按当前每块选择重组的合并结果（逐行；未决定的块暂不进入结果） */
    mergedLines(): string[] {
      const out: string[] = [];
      if (!this.result) return out;
      let ci = -1;
      for (const sec of this.result.sections) {
        if (sec.type === "context") {
          out.push(...sec.lines);
          continue;
        }
        ci += 1;
        const d = this.choices[ci];
        if (d === "local") out.push(...sec.local);
        else if (d === "theirs") out.push(...sec.theirs);
        else if (d === "both") out.push(...sec.local, ...sec.theirs);
      }
      return out;
    }
  },

  actions: {
    /** 换仓库时清空本地会话记录（已解决集合按仓库隔离） */
    resetSession() {
      this.resolved = [];
      this.cache = {};
      this.savedChoices = {};
      this.activeFile = null;
      this.result = null;
      this.choices = [];
    },

    /** 载入冲突文件列表（进入视图时调用） */
    async load() {
      const session = useSessionStore();
      const path = session.request.path;
      const isMock = !session.tauriReady || !path;
      this.loading = true;
      this.loadError = null;
      try {
        if (isMock) {
          if (this.repoPath !== null) this.resetSession();
          this.repoPath = null;
          this.repoName = "my-project";
          this.branch = "main";
          this.upstream = "origin/main";
          const names = mockStatus()
            .filter((f) => f.status === "conflict")
            .map((f) => f.path);
          this.files = Array.from(new Set([...names, ...this.resolved]));
          this.message = "Merge branch 'main'";
        } else {
          const p = path!;
          if (this.repoPath !== p) this.resetSession();
          this.repoPath = p;
          const [info, status] = await Promise.all([getRepoInfo(p), getStatus(p)]);
          this.repoName =
            info.path?.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "仓库";
          this.branch = info.branch ?? "HEAD";
          this.upstream = info.upstream;
          const names = status
            .filter((f) => f.status === "conflict")
            .map((f) => f.path);
          this.files = Array.from(new Set([...names, ...this.resolved]));
          const up = info.upstream ? info.upstream.replace(/^origin\//, "") : "HEAD";
          this.message = `Merge branch '${up}'`;
        }
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "加载冲突状态失败";
      } finally {
        this.loading = false;
      }
    },

    /**
     * 打开文件编辑器：加载冲突段并初始化每块选择。
     * 文件已写回（getConflictFile 无冲突标记）时回退到缓存块结构；
     * reEdit=true 表示重新编辑（清空全部选择，允许重新选）。
     */
    async openEditor(file: string, reEdit = false) {
      this.activeFile = file;
      this.editorLoading = true;
      try {
        const r = this.repoPath
          ? await getConflictFile(this.repoPath, file)
          : mockConflictFile(file);
        const cached = this.cache[file];
        const hasConflict = r.sections.some((s) => s.type === "conflict");
        if (reEdit && cached) {
          this.result = cached;
          this.choices = nullChoices(cached.conflictCount);
        } else if (!reEdit && this.resolved.includes(file) && cached) {
          // 已解决文件重新打开：恢复缓存块与当时的决策高亮，仅供查看
          this.result = cached;
          const saved = this.savedChoices[file];
          this.choices =
            saved && saved.length === cached.conflictCount
              ? [...saved]
              : nullChoices(cached.conflictCount);
        } else if (hasConflict) {
          this.result = r;
          this.cache[file] = r;
          this.choices = nullChoices(r.conflictCount);
        } else if (cached) {
          // 文件已写回（无冲突标记）：回退到缓存块结构，兜底恢复查看态
          this.result = cached;
          const saved = this.savedChoices[file];
          this.choices =
            saved && saved.length === cached.conflictCount
              ? [...saved]
              : nullChoices(cached.conflictCount);
        } else {
          this.result = r;
          this.choices = [];
        }
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "读取冲突内容失败",
          showClose: true,
          duration: 5000
        });
        this.result = null;
        this.choices = [];
      } finally {
        this.editorLoading = false;
      }
    },

    /** 重新编辑：从已解决集合移除并恢复原始冲突块（全部块重新选择） */
    reEdit(file: string) {
      this.resolved = this.resolved.filter((f) => f !== file);
      delete this.savedChoices[file];
      this.openEditor(file, true);
    },

    /** 选择某个冲突块的保留方案；全部块决定后自动标记为已解决 */
    async makeChoice(idx: number, choice: ConflictChoice) {
      const file = this.activeFile;
      if (!file || this.resolving || this.resolved.includes(file)) return;
      if (idx < 0 || idx >= this.choices.length || this.choices[idx]) return;
      this.choices[idx] = choice;
      this.lastPickIdx = idx;
      if (this.choices.length > 0 && this.choices.every((c) => c !== null)) {
        await this.resolveCurrent();
      }
    },

    /** 全部块已决定：按选择重组写回并 git add，标记为已解决 */
    async resolveCurrent() {
      const file = this.activeFile;
      if (!file || this.resolving) return;
      this.resolving = true;
      try {
        if (this.repoPath) {
          await resolveConflictFile(
            this.repoPath,
            file,
            this.choices as ConflictChoice[]
          );
        } else {
          await sleep(250);
        }
        this.savedChoices[file] = [...this.choices];
        if (!this.resolved.includes(file)) this.resolved.push(file);
        ElMessage.success(`已解决 ${file}`);
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "标记解决失败",
          showClose: true,
          duration: 5000
        });
        // 回退最近一次选择，允许用户重试
        this.choices[this.lastPickIdx] = null;
      } finally {
        this.resolving = false;
      }
    },

    /** 返回提交视图并刷新提交 store */
    backToCommit() {
      const session = useSessionStore();
      session.request = { ...session.request, view: "commit" };
      if (this.repoPath) useCommitStore().load(this.repoPath);
    },

    /** 完成合并提交（git commit -F -） */
    async doComplete() {
      if (!this.allResolved || this.completing) return;
      this.completing = true;
      try {
        if (this.repoPath) {
          await completeMerge(this.repoPath, this.message.trim());
        } else {
          await sleep(600);
        }
        ElMessage.success("合并完成");
        this.backToCommit();
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "完成合并失败",
          showClose: true,
          duration: 5000
        });
      } finally {
        this.completing = false;
      }
    },

    /** 中止合并：红色警示二次确认后恢复到拉取前状态 */
    async doAbort() {
      try {
        await ElMessageBox.confirm(
          "将放弃所有解决结果，恢复到拉取前状态，不可恢复。",
          "中止合并",
          {
            type: "error",
            confirmButtonText: "确认中止",
            cancelButtonText: "返回",
            confirmButtonClass: "cf-abort-confirm"
          }
        );
      } catch {
        return; // 用户取消
      }
      try {
        if (this.repoPath) {
          await abortMerge(this.repoPath);
        } else {
          await sleep(400);
        }
        ElMessage.success("已中止合并，恢复到拉取前状态");
        this.backToCommit();
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "中止合并失败",
          showClose: true,
          duration: 5000
        });
      }
    }
  }
});

/* ───────── mock 数据（浏览器调试用：演示三选一编辑器交互） ───────── */

const MOCK_RESULTS: ConflictFileResult[] = [
  {
    file: "src/config.py",
    conflictCount: 2,
    sections: [
      { type: "context", lines: ["# 应用配置", "TIMEOUT = 30", ""] },
      {
        type: "conflict",
        local: ["RETRIES = 3"],
        theirs: ["RETRIES = 5"],
        base: ["RETRIES = 2"]
      },
      {
        type: "context",
        lines: ['LOG_LEVEL = "info"', "", "def build_report(count):"]
      },
      {
        type: "conflict",
        local: ['    return f"本地报告：共 {count} 条记录"', "    notify_admin(count)"],
        theirs: [
          '    return f"远端报告：共 {count} 条记录"',
          "    notify_admin(count)",
          "    archive(count)"
        ],
        base: null
      },
      { type: "context", lines: ["", 'FEATURE_FLAGS = {"dark_mode": True}'] }
    ]
  },
  {
    file: "README.md",
    conflictCount: 2,
    sections: [
      { type: "context", lines: ["# my-project", ""] },
      {
        type: "conflict",
        local: ["本地开发版说明：需要 Python 3.10+。"],
        theirs: ["团队版说明：需要 Python 3.12+，详见 docs/install.md。"],
        base: null
      },
      { type: "context", lines: ["", "## 快速开始", ""] },
      {
        type: "conflict",
        local: ["pip install -r requirements-dev.txt", "python main.py"],
        theirs: ["pip install -r requirements.txt", "python -m app"],
        base: null
      },
      { type: "context", lines: ["", "## 许可证", "MIT"] }
    ]
  },
  {
    file: "src/utils.py",
    conflictCount: 3,
    sections: [
      { type: "context", lines: ['"""通用工具函数（合并冲突演示）"""', "import json", ""] },
      {
        type: "conflict",
        local: ["def to_json(obj):", "    return json.dumps(obj)"],
        theirs: [
          "def to_json(obj, indent=2):",
          "    return json.dumps(obj, ensure_ascii=False, indent=indent)"
        ],
        base: null
      },
      { type: "context", lines: ["", "", "def chunk(items, size):"] },
      {
        type: "conflict",
        local: ["    step = size or 10"],
        theirs: ["    step = max(1, size or 10)"],
        base: ["    step = size"]
      },
      {
        type: "context",
        lines: ["    for i in range(0, len(items), step):", "        yield items[i:i + step]", ""]
      },
      {
        type: "conflict",
        local: ['VERSION = "1.2.0"'],
        theirs: ['VERSION = "1.3.0"'],
        base: null
      },
      { type: "context", lines: [""] }
    ]
  }
];

/** mock 工作区状态（conflict 视图只取 status==="conflict" 的文件） */
function mockStatus(): StatusFile[] {
  const mk = (p: string, st: StatusFile["status"]): StatusFile => ({
    path: p,
    status: st,
    origPath: null,
    added: null,
    deleted: null,
    binary: false,
    staged: st !== "untracked",
    untracked: st === "untracked"
  });
  return [
    mk("src/config.py", "conflict"),
    mk("README.md", "conflict"),
    mk("src/utils.py", "conflict"),
    mk("src/app.py", "modified"),
    mk("notes.txt", "untracked")
  ];
}

/** mock 冲突文件解析结果（深拷贝避免 mock 数据被引用篡改） */
function mockConflictFile(file: string): ConflictFileResult {
  const hit = MOCK_RESULTS.find((r) => r.file === file);
  if (hit) return structuredClone(hit);
  return {
    file,
    conflictCount: 0,
    sections: [{ type: "context", lines: [`（mock）未找到 ${file} 的冲突内容`] }]
  };
}
