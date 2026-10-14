import { defineStore } from "pinia";
import { notifySuccess, notifyError } from "../ui/feedback";
import { getSettings, setSettings, toGitError } from "../api";
import { useSessionStore } from "./session";

/** 应用设置（PRD FM-11 薄设置：仅诊断日志；语言当前版本固定中文） */
export const useSettingsStore = defineStore("settings", {
  state: () => ({
    /** 诊断日志开关 */
    diagEnabled: false,
    loading: false,
    loadError: null as string | null,
    saving: false
  }),

  actions: {
    /** 读取设置（浏览器 mock：保持默认值） */
    async load() {
      const s = useSessionStore();
      if (!s.tauriReady) {
        this.loading = false;
        return;
      }
      this.loading = true;
      this.loadError = null;
      try {
        const st = await getSettings();
        this.diagEnabled = st.diagEnabled;
      } catch (e) {
        const err = toGitError(e);
        this.loadError = err.message || "读取设置失败";
      } finally {
        this.loading = false;
      }
    },

    /** 切换诊断日志：变更即保存（失败回滚开关） */
    async setDiag(v: boolean) {
      const prev = this.diagEnabled;
      this.diagEnabled = v;
      const s = useSessionStore();
      if (!s.tauriReady) {
        notifySuccess("设置已保存");
        return;
      }
      this.saving = true;
      try {
        await setSettings({ diagEnabled: v });
        notifySuccess("设置已保存");
      } catch (e) {
        this.diagEnabled = prev;
        const err = toGitError(e);
        notifyError(err.message || "保存设置失败");
      } finally {
        this.saving = false;
      }
    },

    /** 返回提交视图 */
    backToCommit() {
      const s = useSessionStore();
      s.request = { ...s.request, view: "commit" };
    }
  }
});
