import { defineStore } from "pinia";
import { ElMessage } from "element-plus";
import {
  commit as commitFiles,
  getAuthorIdentity,
  getDiff,
  getRepoInfo,
  getStatus,
  getSettings,
  toGitError,
  type GitErrorPayload,
  type StatusFile
} from "../api";

/** diff 行类型：hunk 头 / 上下文 / 新增 / 删除（沿用原型类名） */
export type DiffLineType = "hunk" | "ctxl" | "add" | "del";

export interface DiffLine {
  type: DiffLineType;
  text: string;
}

/** 文件状态：M 修改 / A 新增 / D 删除 / U 未跟踪 / C 冲突 / R 重命名 */
export type FileStatus = "M" | "A" | "D" | "U" | "C" | "R";

export const STATUS_LABEL: Record<FileStatus, string> = {
  M: "修改",
  A: "新增",
  D: "删除",
  U: "未跟踪",
  C: "冲突",
  R: "重命名"
};

export interface ChangeFile {
  /** 当前仓库内的相对路径；用于 API 调用 */
  name: string;
  /** 重命名前的旧路径 */
  origPath?: string | null;
  status: FileStatus;
  /** 勾选态：是否纳入本次提交 */
  checked: boolean;
  /** 后端未提供统计值时保留为 undefined，以便 mock 展示示例数据 */
  added?: number | null;
  deleted?: number | null;
  /** 已暂存变更 */
  staged?: boolean;
  untracked?: boolean;
  /** 二进制文件：不展示内容对比 */
  binary?: boolean;
  diff: DiffLine[];
}

/** 勾选默认规则：修改/删除/重命名默认勾选，新增/未跟踪不勾选，冲突不可勾选 */
export function defaultChecked(file: Pick<ChangeFile, "status">): boolean {
  return file.status === "M" || file.status === "D" || file.status === "R";
}

/** 行内增删统计；未连接 Git 时用原型示例数值 */
export function fileStat(file: ChangeFile): string {
  if (file.status === "D" || file.binary) return "";
  if (Object.prototype.hasOwnProperty.call(file, "added") || Object.prototype.hasOwnProperty.call(file, "deleted")) {
    const parts: string[] = [];
    if (typeof file.added === "number" && file.added > 0) parts.push(`+${file.added}`);
    if (typeof file.deleted === "number" && file.deleted > 0) parts.push(`−${file.deleted}`);
    return parts.join(" ");
  }
  const count = ((file.name.length * 7) % 40) + 6;
  const removed = file.status === "A" || file.status === "U" ? "" : ` −${(count % 9) + 1}`;
  return `+${count}${removed}`;
}

function mapStatus(status: StatusFile["status"]): FileStatus {
  switch (status) {
    case "added":
      return "A";
    case "deleted":
      return "D";
    case "untracked":
      return "U";
    case "conflict":
      return "C";
    case "renamed":
      return "R";
    default:
      return "M";
  }
}

export function parseDiff(text: string): DiffLine[] {
  return text
    .replace(/\r\n/g, "\n")
    .split("\n")
    .filter((line, index, lines) => line.length > 0 || index < lines.length - 1)
    .map((line): DiffLine => {
      if (line.startsWith("@@")) return { type: "hunk", text: line };
      if (line.startsWith("+") && !line.startsWith("+++")) return { type: "add", text: line };
      if (line.startsWith("-") && !line.startsWith("---")) return { type: "del", text: line };
      return { type: "ctxl", text: line };
    });
}

/* ──── mock 数据（取自原型演示数据，仅浏览器预览使用） ──── */

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

const CONFLICT_DIFF: DiffLine[] = [
  { type: "hunk", text: "⚠ 该文件存在未解决的合并冲突" },
  { type: "ctxl", text: "" },
  { type: "ctxl", text: "请通过右键 →「解决冲突」处理，此处暂不展示内容。" }
];

function mockFile(name: string, status: FileStatus, options?: { binary?: boolean }): ChangeFile {
  return {
    name,
    status,
    checked: defaultChecked({ status }),
    binary: options?.binary,
    diff: options?.binary ? [] : (MOCK_DIFFS[name] ?? CONFLICT_DIFF)
  };
}

function directoryName(path: string): string {
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? path;
}

export const useCommitStore = defineStore("commit", {
  state: () => ({
    /** 浏览器预览走 mock；Tauri 环境连接真实仓库 */
    isMock: true,
    workspacePath: null as string | null,
    loading: false,
    loadError: null as string | null,
    loadRequestId: 0,
    diffRequestId: 0,
    /** 仓库概要 */
    repo: {
      name: "my-project",
      branch: "main",
      upstream: "origin/main" as string | null,
      ahead: 1,
      behind: 0,
      mergeInProgress: false
    },
    /** 作者信息（浏览器预览 mock；Tauri 中读取系统 Git 配置） */
    author: "yxw <yxw@example.com>",
    newFilesChecked: false,
    /** 文件名过滤关键字 */
    filter: "",
    /** 提交信息（必填） */
    message: "",
    /** 当前在右侧预览 diff 的文件名 */
    selected: null as string | null,
    /** 提交中 */
    committing: false,
    commitError: null as GitErrorPayload | null,
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
    filteredFiles: (state) => {
      const keyword = state.filter.trim();
      return keyword ? state.files.filter((file) => file.name.includes(keyword)) : state.files;
    },
    hasConflict: (state) => state.files.some((file) => file.status === "C"),
    conflictCount: (state) => state.files.filter((file) => file.status === "C").length,
    checkedCount: (state) => state.files.filter((file) => file.checked).length,
    selectableInFilter: (state) => {
      const keyword = state.filter.trim();
      const visible = keyword ? state.files.filter((file) => file.name.includes(keyword)) : state.files;
      return visible.filter((file) => file.status !== "C");
    },
    allChecked(): boolean {
      const selectable = this.selectableInFilter;
      return selectable.length > 0 && selectable.every((file) => file.checked);
    },
    someChecked(): boolean {
      const checked = this.selectableInFilter.filter((file) => file.checked).length;
      return checked > 0 && checked < this.selectableInFilter.length;
    },
    selectedFile: (state) => state.files.find((file) => file.name === state.selected) ?? null,
    canCommit(): boolean {
      return !this.committing
        && !this.loading
        && !this.hasConflict
        && !this.repo.mergeInProgress
        && this.checkedCount > 0
        && this.message.trim().length > 0;
    },
    syncText(): string {
      const { ahead, behind, upstream } = this.repo;
      if (!upstream) return "尚未设置上游";
      if (ahead > 0) return `领先 ${upstream} ${ahead} 个提交`;
      if (behind > 0) return `落后 ${upstream} ${behind} 个提交`;
      return `与 ${upstream} 同步`;
    }
  },

  actions: {
    async initialize(path: string | undefined, tauriReady: boolean, preferredFile?: string) {
      const workspaceChanged = this.workspacePath !== (path ?? null);
      this.loadRequestId += 1;
      this.diffRequestId += 1;
      this.isMock = !tauriReady;
      this.workspacePath = path ?? null;
      this.loading = false;
      this.loadError = null;
      if (workspaceChanged) {
        this.message = "";
        this.filter = "";
        this.commitError = null;
        this.selected = null;
      }
      if (!tauriReady) return;
      this.files = [];
      this.selected = null;
      if (!path) {
        this.loadError = "没有收到目标目录。请从文件管理器右键菜单打开 MenuGit。";
        return;
      }
      await this.refresh(preferredFile, { resetChecks: true });
    },

    async refresh(preferredFile?: string, options: { resetChecks?: boolean } = {}) {
      if (this.isMock || !this.workspacePath) return;
      const requestId = ++this.loadRequestId;
      const selectedBefore = this.selected;
      this.loading = true;
      this.loadError = null;
      try {
        const info = await getRepoInfo(this.workspacePath);
        if (requestId !== this.loadRequestId) return;
        if (!info.isRepo) {
          this.files = [];
          this.selected = null;
          this.repo = {
            name: directoryName(this.workspacePath),
            branch: "—",
            upstream: null,
            ahead: 0,
            behind: 0,
            mergeInProgress: false
          };
          this.loadError = "目标目录不属于 Git 仓库。";
          return;
        }

        const [statuses, identity, settings] = await Promise.all([
          getStatus(this.workspacePath),
          getAuthorIdentity(this.workspacePath),
          getSettings()
        ]);
        if (requestId !== this.loadRequestId) return;

        this.repo = {
          name: directoryName(info.path ?? this.workspacePath),
          branch: info.branch ?? "(无分支)",
          upstream: info.upstream,
          ahead: info.ahead,
          behind: info.behind,
          mergeInProgress: info.mergeInProgress
        };
        const identityParts = [identity.name?.trim(), identity.email?.trim() ? `<${identity.email.trim()}>` : null]
          .filter((part): part is string => Boolean(part));
        this.author = identityParts.length ? identityParts.join(" ") : "未配置系统 Git 用户身份";
        this.newFilesChecked = settings.newFilesChecked;

        const previous = new Map(this.files.map((file) => [file.name, file]));
        this.files = statuses.map((item): ChangeFile => {
          const status = mapStatus(item.status);
          const old = previous.get(item.path);
          return {
            name: item.path,
            origPath: item.origPath,
            status,
            checked: status === "C"
              ? false
              : old && !options.resetChecks
                ? old.checked
                : defaultChecked({ status })
                  || (this.newFilesChecked && (status === "A" || status === "U")),
            added: item.added,
            deleted: item.deleted,
            staged: item.staged,
            untracked: item.untracked,
            binary: item.binary,
            diff: []
          };
        });

        const nextSelected = preferredFile && this.files.some((file) => file.name === preferredFile)
          ? preferredFile
          : selectedBefore && this.files.some((file) => file.name === selectedBefore)
            ? selectedBefore
            : null;
        this.selected = nextSelected;
        if (preferredFile) {
          const file = this.files.find((candidate) => candidate.name === preferredFile);
          if (file && file.status !== "C") file.checked = true;
        }
        if (nextSelected) await this.loadDiff(nextSelected);
      } catch (error) {
        if (requestId === this.loadRequestId) {
          this.files = [];
          this.selected = null;
          this.loadError = toGitError(error).message;
        }
      } finally {
        if (requestId === this.loadRequestId) this.loading = false;
      }
    },

    async selectFile(name: string) {
      this.selected = name;
      await this.loadDiff(name);
    },

    async loadDiff(name: string) {
      if (this.isMock || !this.workspacePath) return;
      const file = this.files.find((candidate) => candidate.name === name);
      if (!file || file.binary || file.status === "C") return;
      const requestId = ++this.diffRequestId;
      try {
        const diffs = await Promise.all([
          file.staged ? getDiff(this.workspacePath, name, true) : Promise.resolve(null),
          getDiff(this.workspacePath, name, false)
        ]);
        if (requestId !== this.diffRequestId || this.selected !== name) return;
        file.binary = diffs.some((diff) => diff?.isBinary);
        file.diff = parseDiff(diffs.map((diff) => diff?.text ?? "").filter(Boolean).join("\n"));
      } catch (error) {
        if (requestId === this.diffRequestId) {
          file.diff = [];
          ElMessage.error(toGitError(error).message);
        }
      }
    },

    toggleCheck(name: string) {
      const file = this.files.find((candidate) => candidate.name === name);
      if (file && file.status !== "C") file.checked = !file.checked;
    },

    setAll(checked: boolean) {
      this.selectableInFilter.forEach((file) => (file.checked = checked));
    },

    resetForm() {
      this.filter = "";
      this.message = "";
      this.selected = null;
      this.files.forEach((file) => {
        file.checked = file.status !== "C" && (defaultChecked(file)
          || (this.newFilesChecked && (file.status === "A" || file.status === "U")));
      });
    },

    async doCommit(): Promise<string | null> {
      if (!this.canCommit) return null;
      if (this.isMock) {
        this.committing = true;
        const names = this.files.filter((file) => file.checked).map((file) => file.name);
        await new Promise((resolve) => setTimeout(resolve, 800));
        const hash = Math.random().toString(16).slice(2, 9);
        this.repo.ahead += 1;
        this.files = this.files.filter((file) => !file.checked);
        this.files.forEach((file) => {
          file.checked = defaultChecked(file);
        });
        this.message = "";
        this.selected = null;
        this.committing = false;
        ElMessage.success(`已提交 ${hash} · ${names.length} 个文件`);
        return hash;
      }

      if (!this.workspacePath) return null;
      const names = this.files.filter((file) => file.checked).map((file) => file.name);
      this.committing = true;
      this.commitError = null;
      try {
        const result = await commitFiles(this.workspacePath, this.message.trim(), names);
        this.message = "";
        this.filter = "";
        this.selected = null;
        await this.refresh(undefined, { resetChecks: true });
        ElMessage.success(`已提交 ${result.hash.slice(0, 7)} · ${names.length} 个文件`);
        return result.hash;
      } catch (error) {
        const gitError = toGitError(error);
        this.commitError = gitError;
        ElMessage.error(gitError.message);
        return null;
      } finally {
        this.committing = false;
      }
    }
  }
});
