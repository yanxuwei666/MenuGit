import { defineStore } from "pinia";
import { h } from "vue";
import { ElMessageBox } from "element-plus";
import { notifySuccess, notifyError } from "../ui/feedback";
import { discardChanges, getStatus, toGitError, type StatusFile } from "../api";
import { useSessionStore } from "./session";

/** 可放弃的变更状态（conflict 不列入，PRD FM-07） */
export type DiscardStatus = "modified" | "deleted" | "untracked";

/** 状态标记：与提交视图 M/D/U 徽章对应（样式类名复用 st-M/st-D/st-U） */
export const DISCARD_TAG: Record<DiscardStatus, string> = {
  modified: "M",
  deleted: "D",
  untracked: "U"
};

export const DISCARD_LABEL: Record<DiscardStatus, string> = {
  modified: "修改",
  deleted: "删除",
  untracked: "未跟踪"
};

export interface DiscardFile {
  path: string;
  status: DiscardStatus;
  /** 勾选态：默认全部未勾选（必须用户主动选择） */
  checked: boolean;
}

export const useDiscardStore = defineStore("discard", {
  state: () => ({
    /** 仓库根路径；null = 浏览器 mock 模式 */
    repoPath: null as string | null,
    loading: false,
    loadError: null as string | null,
    files: [] as DiscardFile[],
    /** 放弃执行中 */
    discarding: false
  }),

  getters: {
    checkedCount: (s) => s.files.filter((f) => f.checked).length,
    /** 勾选中是否含未跟踪文件（确认框单独提示） */
    hasUntrackedChecked: (s) =>
      s.files.some((f) => f.checked && f.status === "untracked"),
    allChecked(): boolean {
      return this.files.length > 0 && this.files.every((f) => f.checked);
    },
    someChecked(): boolean {
      const n = this.files.filter((f) => f.checked).length;
      return n > 0 && n < this.files.length;
    }
  },

  actions: {
    /** 载入可放弃变更（modified / deleted / untracked），默认全部未勾选 */
    async load(path: string) {
      this.repoPath = path;
      this.loading = true;
      this.loadError = null;
      try {
        const files = await getStatus(path);
        const allowed: DiscardStatus[] = ["modified", "deleted", "untracked"];
        this.files = files
          .filter((f) => allowed.includes(f.status as DiscardStatus))
          .map((f: StatusFile) => ({
            path: f.path,
            status: f.status as DiscardStatus,
            checked: false
          }));
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "加载仓库状态失败";
      } finally {
        this.loading = false;
      }
    },

    /** 浏览器演示数据（取自原型演示集） */
    loadMock() {
      this.repoPath = null;
      this.loading = false;
      this.loadError = null;
      this.files = [
        { path: "src/app.py", status: "modified", checked: false },
        { path: "docs/old.md", status: "deleted", checked: false },
        { path: "notes.txt", status: "untracked", checked: false }
      ];
    },

    /** 全选 / 取消全选 */
    setAll(checked: boolean) {
      this.files.forEach((f) => (f.checked = checked));
    },

    /** 放弃所选：R4 二次确认 → discardChanges → 刷新列表 + 成功提示 */
    async doDiscard() {
      if (this.checkedCount === 0 || this.discarding) return;
      const n = this.checkedCount;
      const lines = [`将放弃 ${n} 个文件的修改，将永久丢弃这些修改，不可恢复。`];
      if (this.hasUntrackedChecked) lines.push("未跟踪文件将被彻底删除。");
      try {
        await ElMessageBox.confirm(
          h("div", null, lines.map((t) => h("div", { style: "margin:2px 0" }, t))),
          "确认放弃修改",
          { type: "warning", confirmButtonText: "确认放弃", cancelButtonText: "取消" }
        );
      } catch {
        return; // 用户取消确认框
      }

      this.discarding = true;
      try {
        const names = this.files.filter((f) => f.checked).map((f) => f.path);
        if (this.repoPath) {
          await discardChanges(this.repoPath, names);
          await this.load(this.repoPath); // 成功后刷新列表
        } else {
          await new Promise((r) => setTimeout(r, 600));
          this.files = this.files.filter((f) => !f.checked);
        }
        notifySuccess(`已放弃 ${n} 个文件的修改`);
      } catch (e) {
        const err = toGitError(e);
        notifyError(err.message || "放弃修改失败");
      } finally {
        this.discarding = false;
      }
    },

    /** 完成：返回提交视图 */
    finish() {
      const s = useSessionStore();
      s.request = { ...s.request, view: "commit" };
    }
  }
});
