import { defineStore } from "pinia";
import { ElMessage } from "element-plus";
import {
  getDiff,
  getIdentity,
  getRepoInfo,
  getStatus,
  stageFiles,
  commit as apiCommit,
  toGitError,
  type StatusFile
} from "../api";
import { useSessionStore } from "./session";

/** diff 行类型：hunk 头 / 上下文 / 新增 / 删除（沿用原型类名） */
export type DiffLineType = "hunk" | "ctxl" | "add" | "del";

export interface DiffLine {
  type: DiffLineType;
  text: string;
}

/** 文件状态：M 修改 / A 新增 / D 删除 / U 未跟踪 / R 重命名 / C 冲突 */
export type FileStatus = "M" | "A" | "D" | "U" | "R" | "C";

export const STATUS_LABEL: Record<FileStatus, string> = {
  M: "修改",
  A: "新增",
  D: "删除",
  U: "未跟踪",
  R: "重命名",
  C: "冲突"
};

/** api StatusFile.status → 前端 FileStatus */
const STATUS_MAP: Record<string, FileStatus> = {
  modified: "M",
  added: "A",
  deleted: "D",
  untracked: "U",
  renamed: "R",
  conflict: "C"
};

export interface ChangeFile {
  name: string;
  status: FileStatus;
  /** 重命名的旧路径（旧名 → 新名） */
  origPath?: string | null;
  /** 增删行数（numstat；二进制/未跟踪为 null） */
  added?: number | null;
  deleted?: number | null;
  /** 勾选态：是否纳入本次提交 */
  checked: boolean;
  /** 二进制文件：不展示内容对比 */
  binary?: boolean;
  diff: DiffLine[];
}

/** 勾选默认规则：修改/删除/重命名默认勾选，新增/未跟踪默认不勾选，冲突不可勾选 */
export function defaultChecked(f: ChangeFile): boolean {
  if (f.status === "C") return false;
  return f.status === "M" || f.status === "D" || f.status === "R";
}

/** 行内增删统计：真实模式用 numstat 实数，mock 走启发式 */
export function fileStat(f: ChangeFile): string {
  if (f.status === "D" || f.binary || f.status === "U") return "";
  if (f.added != null) {
    return `+${f.added}${f.deleted ? ` −${f.deleted}` : ""}`;
  }
  const n = ((f.name.length * 7) % 40) + 6;
  const del = f.status === "A" ? "" : ` −${(n % 9) + 1}`;
  return `+${n}${del}`;
}

/** 解析 git diff 文本为行模型（跳过 diff --git / index / --- / +++ 等头部行） */
export function parseDiff(text: string): DiffLine[] {
  const out: DiffLine[] = [];
  for (const line of text.split("\n")) {
    if (
      line.startsWith("diff ") ||
      line.startsWith("index ") ||
      line.startsWith("--- ") ||
      line.startsWith("+++ ") ||
      line.startsWith("new file ") ||
      line.startsWith("deleted file ") ||
      line.startsWith("rename ") ||
      line.startsWith("similarity ") ||
      line.startsWith("old mode ") ||
      line.startsWith("new mode ")
    ) {
      continue;
    }
    if (line.startsWith("@@")) out.push({ type: "hunk", text: line });
    else if (line.startsWith("+")) out.push({ type: "add", text: line.slice(1) });
    else if (line.startsWith("-")) out.push({ type: "del", text: line.slice(1) });
    else if (line.startsWith(" ")) out.push({ type: "ctxl", text: line.slice(1) });
    else if (line !== "") out.push({ type: "ctxl", text: line });
  }
  return out;
}

/** api StatusFile → 前端 ChangeFile（按默认勾选规则初始化勾选态） */
function mapStatusFile(s: StatusFile): ChangeFile {
  const f: ChangeFile = {
    name: s.path,
    status: STATUS_MAP[s.status] ?? "M",
    origPath: s.origPath,
    added: s.added,
    deleted: s.deleted,
    checked: false,
    binary: s.binary,
    diff: []
  };
  f.checked = defaultChecked(f);
  return f;
}

/* ───────── mock 数据（浏览器调试用；取自原型演示数据） ───────── */

const MOCK_DIFFS: Record<string, DiffLine[]> = {
  "src/app.py": [
    { type: "hunk", text: "@@ -12,7 +12,9 @@ def main()" },
    { type: "ctxl", text: "def load_config():" },
    { type: "ctxl", text: '    path = os.environ.get("APP_CONFIG")' },
    { type: "del", text: "    if not path:" },
    { type: "del", text: '        path = "config.ini"' },
    { type: "add", text: "    if not path:" },
    { type: "add", text: '        raise ConfigError("missing APP_CONFIG")' },
    { type: "add", text: '    logger.debug("using config: %s", path)' },
    { type: "ctxl", text: "    return parse(path)" }
  ],
  "src/utils.py": [
    { type: "hunk", text: "@@ -0,0 +1,8 @@" },
    { type: "add", text: '"""通用工具函数"""' },
    { type: "add", text: "import json" },
    { type: "add", text: "" },
    { type: "add", text: "def to_json(obj, indent=2):" },
    { type: "add", text: "    return json.dumps(obj, ensure_ascii=False, indent=indent)" }
  ],
  "docs/old.md": [
    { type: "hunk", text: "@@ -1,6 +0,0 @@" },
    { type: "del", text: "# 旧版说明（已废弃）" },
    { type: "del", text: "本文档描述 v1.x 的安装方式，" },
    { type: "del", text: "内容已迁移至 docs/install.md。" }
  ],
  "notes.txt": [
    { type: "hunk", text: "@@ -0,0 +1,3 @@" },
    { type: "add", text: "随手记：" },
    { type: "add", text: "- 下周看一下缓存策略" }
  ]
};

/** 冲突文件在解决前不展示内容（文案沿用原型） */
const CONFLICT_DIFF: DiffLine[] = [
  { type: "hunk", text: "⚠ 该文件存在未解决的合并冲突" },
  { type: "ctxl", text: "" },
  { type: "ctxl", text: "请通过右键 →「解决冲突」处理，此处暂不展示内容。" }
];

function mockFile(name: string, status: FileStatus, opts?: { binary?: boolean }): ChangeFile {
  return {
    name,
    status,
    checked: defaultChecked({ name, status, checked: false, diff: [] }),
    binary: opts?.binary,
    diff: opts?.binary ? [] : (MOCK_DIFFS[name] ?? CONFLICT_DIFF)
  };
}

export const useCommitStore = defineStore("commit", {
  state: () => ({
    /** 真实仓库根路径；null = 浏览器 mock 模式 */
    repoPath: null as string | null,
    /** 仓库数据加载中 */
    loading: false,
    /** 加载失败信息 */
    loadError: null as string | null,
    /** 仓库信息（真实模式由 get_repo_info 填充） */
    repo: {
      name: "my-project",
      branch: "main",
      upstream: "origin/main" as string | null,
      ahead: 1,
      behind: 0
    },
    /** 作者信息（来自系统 Git 配置；未设置时给出引导文案） */
    author: "yxw <yxw@example.com>",
    /** 文件名过滤关键字 */
    filter: "",
    /** 提交信息（必填） */
    message: "",
    /** 当前在右侧预览 diff 的文件名 */
    selected: null as string | null,
    /** 提交中 */
    committing: false,
    /** 变更文件列表 */
    files: [
      mockFile("src/app.py", "M"),
      mockFile("src/utils.py", "A"),
      mockFile("src/config.py", "C"),
      mockFile("docs/old.md", "D"),
      mockFile("notes.txt", "U"),
      mockFile("assets/logo.png", "M", { binary: true })
    ] as ChangeFile[]
  }),

  getters: {
    /** 按文件名实时过滤后的列表 */
    filteredFiles: (s) => {
      const k = s.filter.trim();
      return k ? s.files.filter((f) => f.name.includes(k)) : s.files;
    },
    hasConflict: (s) => s.files.some((f) => f.status === "C"),
    conflictCount: (s) => s.files.filter((f) => f.status === "C").length,
    checkedCount: (s) => s.files.filter((f) => f.checked).length,
    /** 当前列表中可勾选（非冲突）的文件，全选框作用对象 */
    selectableInFilter: (s) => {
      const k = s.filter.trim();
      const base = k ? s.files.filter((f) => f.name.includes(k)) : s.files;
      return base.filter((f) => f.status !== "C");
    },
    allChecked(): boolean {
      const sel = this.selectableInFilter;
      return sel.length > 0 && sel.every((f) => f.checked);
    },
    someChecked(): boolean {
      const n = this.selectableInFilter.filter((f) => f.checked).length;
      return n > 0 && n < this.selectableInFilter.length;
    },
    selectedFile: (s) => s.files.find((f) => f.name === s.selected) ?? null,
    /** 提交按钮可用：已勾选文件且信息非空 */
    canCommit(): boolean {
      return !this.committing && this.checkedCount > 0 && this.message.trim().length > 0;
    },
    /** 与上游的同步描述 */
    syncText(): string {
      const { ahead, behind, upstream } = this.repo;
      if (!upstream) return "未设置上游分支";
      if (ahead > 0) return `领先 ${upstream} ${ahead} 个提交`;
      if (behind > 0) return `落后 ${upstream} ${behind} 个提交`;
      return `与 ${upstream} 同步`;
    }
  },

  actions: {
    /** 载入真实仓库数据（Tauri 环境，由 App.vue 按 CLI 目标路径调用） */
    async load(path: string) {
      this.repoPath = path;
      this.loading = true;
      this.loadError = null;
      try {
        const [info, files, identity] = await Promise.all([
          getRepoInfo(path),
          getStatus(path),
          getIdentity(path)
        ]);
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
        this.author = identity.name
          ? `${identity.name}${identity.email ? ` <${identity.email}>` : ""}`
          : "未设置（请在系统 Git 配置中设置 user.name / user.email）";
        this.files = files.map(mapStatusFile);
        this.filter = "";
        this.message = "";
        this.selected = null;
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "加载仓库状态失败";
      } finally {
        this.loading = false;
      }
    },

    /** 点击文件：选中并按需加载 diff（冲突文件显示占位；mock 模式用预置数据） */
    async selectFile(name: string) {
      this.selected = name;
      const f = this.files.find((x) => x.name === name);
      if (!f || this.repoPath == null || f.diff.length > 0) return;
      if (f.status === "C") {
        f.diff = CONFLICT_DIFF;
        return;
      }
      try {
        const r = await getDiff(this.repoPath, name);
        f.binary = r.isBinary;
        f.diff = r.isBinary ? [] : parseDiff(r.text);
      } catch (e) {
        const err = toGitError(e);
        f.diff = [{ type: "ctxl", text: `读取差异失败：${err.message}` }];
      }
    },

    /** 切换单个文件勾选（冲突文件不可勾选） */
    toggleCheck(name: string) {
      const f = this.files.find((x) => x.name === name);
      if (f && f.status !== "C") f.checked = !f.checked;
    },
    /** 全选 / 取消全选（仅作用于当前过滤出的非冲突文件） */
    setAll(checked: boolean) {
      this.selectableInFilter.forEach((f) => (f.checked = checked));
    },
    /** 取消：清空过滤、选择与信息，勾选恢复默认 */
    resetForm() {
      this.filter = "";
      this.message = "";
      this.selected = null;
      this.files.forEach((f) => (f.checked = defaultChecked(f)));
    },
    /** 提交入口：按模式分发 */
    async doCommit() {
      if (!this.canCommit) return;
      if (this.repoPath == null) {
        await this.mockCommit();
      } else {
        await this.realCommit();
      }
    },

    /** 真实提交：暂存勾选文件 → git commit → 刷新 → 闭环进入推送面板（PRD FM-02） */
    async realCommit() {
      const path = this.repoPath!;
      this.committing = true;
      try {
        const names = this.files.filter((f) => f.checked).map((f) => f.name);
        await stageFiles(path, names);
        const r = await apiCommit(path, this.message.trim());
        await this.load(path);
        ElMessage.success(`已提交 ${r.hash.slice(0, 7)} · ${names.length} 个文件`);
        useSessionStore().request = { ...useSessionStore().request, view: "push" };
      } catch (e) {
        const err = toGitError(e);
        ElMessage.error({
          message: err.message || "提交失败",
          showClose: true,
          duration: 5000
        });
      } finally {
        this.committing = false;
      }
    },

    /** 浏览器 mock 提交（无 Tauri 环境时保持原演示流程） */
    async mockCommit() {
      this.committing = true;
      const names = this.files.filter((f) => f.checked).map((f) => f.name);
      await new Promise((r) => setTimeout(r, 800));
      const hash = Math.random().toString(16).slice(2, 9);
      this.repo.ahead++;
      this.files = this.files.filter((f) => !f.checked);
      this.files.forEach((f) => (f.checked = defaultChecked(f)));
      this.message = "";
      this.selected = null;
      this.committing = false;
      ElMessage.success(`已提交 ${hash} · ${names.length} 个文件`);
    }
  }
});
