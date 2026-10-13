import { defineStore } from "pinia";
import { ElMessage } from "element-plus";

/** diff 行类型：hunk 头 / 上下文 / 新增 / 删除（沿用原型类名） */
export type DiffLineType = "hunk" | "ctxl" | "add" | "del";

export interface DiffLine {
  type: DiffLineType;
  text: string;
}

/** 文件状态：M 修改 / A 新增 / D 删除 / U 未跟踪 / C 冲突 */
export type FileStatus = "M" | "A" | "D" | "U" | "C";

export const STATUS_LABEL: Record<FileStatus, string> = {
  M: "修改",
  A: "新增",
  D: "删除",
  U: "未跟踪",
  C: "冲突"
};

export interface ChangeFile {
  name: string;
  status: FileStatus;
  /** 勾选态：是否纳入本次提交 */
  checked: boolean;
  /** 二进制文件：不展示内容对比 */
  binary?: boolean;
  diff: DiffLine[];
}

/** 勾选默认规则：修改/删除默认勾选，新增/未跟踪默认不勾选，冲突不可勾选 */
export function defaultChecked(f: ChangeFile): boolean {
  if (f.status === "C") return false;
  return f.status === "M" || f.status === "D";
}

/** 行内增删统计（演示数据，规则与原型一致）：删除文件不显示 */
export function fileStat(f: ChangeFile): string {
  if (f.status === "D" || f.binary) return "";
  const n = ((f.name.length * 7) % 40) + 6;
  const del = f.status === "A" || f.status === "U" ? "" : ` −${(n % 9) + 1}`;
  return `+${n}${del}`;
}

/* ───────── mock 数据（取自原型演示数据） ───────── */

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
    /** 仓库 mock 信息 */
    repo: {
      name: "my-project",
      branch: "main",
      upstream: "origin/main",
      ahead: 1,
      behind: 0
    },
    /** 作者信息（mock：来自系统 Git 配置） */
    author: "yxw <yxw@example.com>",
    /** 文件名过滤关键字 */
    filter: "",
    /** 提交信息（必填） */
    message: "",
    /** 当前在右侧预览 diff 的文件名 */
    selected: null as string | null,
    /** 提交中（模拟 loading） */
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
      if (ahead > 0) return `领先 ${upstream} ${ahead} 个提交`;
      if (behind > 0) return `落后 ${upstream} ${behind} 个提交`;
      return `与 ${upstream} 同步`;
    }
  },

  actions: {
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
    /** 模拟提交：loading → 成功提示 → 移除已提交文件 → 领先数 +1 */
    async doCommit() {
      if (!this.canCommit) return;
      this.committing = true;
      const names = this.files.filter((f) => f.checked).map((f) => f.name);
      // 模拟 git commit 耗时，不发起任何真实调用
      await new Promise((r) => setTimeout(r, 800));
      const hash = Math.random().toString(16).slice(2, 9);
      this.repo.ahead++;
      // 已提交文件从变更列表移除，剩余文件勾选恢复默认
      this.files = this.files.filter((f) => !f.checked);
      this.files.forEach((f) => (f.checked = defaultChecked(f)));
      this.message = "";
      this.selected = null;
      this.committing = false;
      ElMessage.success(`已提交 ${hash} · ${names.length} 个文件`);
    }
  }
});
