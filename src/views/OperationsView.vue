<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";
import { Loading } from "@element-plus/icons-vue";
import type { UnlistenFn } from "@tauri-apps/api/event";
import {
  abortMerge,
  cancelClone,
  checkoutRemote,
  cloneRepo,
  completeMerge,
  discardChanges,
  getAuthorIdentity,
  getCommitFileDiff,
  getConflictFile,
  getDiagnostics,
  getFinderIntegration,
  getLog,
  getLogDetail,
  getRepoInfo,
  getSettings,
  getStatus,
  initRepo,
  listenCloneProgress,
  listBranches,
  openInFinder,
  openProjectReleases,
  pull as pullRepo,
  resolveConflictFile,
  repairFinderIntegration,
  setSettings,
  switchBranch,
  toGitError,
  type AppSettings,
  type BranchInfo,
  type CloneProgress,
  type ConflictChoice,
  type ConflictFileResult,
  type Diagnostics,
  type FinderIntegration,
  type GitErrorPayload,
  type LogDetail,
  type LogEntry,
  type RepoInfo,
  type StatusFile
} from "../api";
import { parseDiff } from "../stores/commit";
import type { ViewName } from "../stores/session";

type OperationView = Exclude<ViewName, "commit" | "push">;
const props = defineProps<{
  view: OperationView;
  path?: string;
  file?: string;
  url?: string;
  tauriReady: boolean;
}>();
const emit = defineEmits<{ navigate: [view: ViewName] }>();

const loading = ref(false);
const running = ref(false);
const error = ref<GitErrorPayload | null>(null);
const notice = ref("");
const repoInfo = ref<RepoInfo | null>(null);
const statuses = ref<StatusFile[]>([]);
// 立即 watcher 会在 setup 期间调用 load()，settings 相关状态必须先于 watcher 声明，
// 否则赋值语句左侧求值会命中暂时性死区。
const settings = ref<AppSettings>({ language: "system", newFilesChecked: false, diagEnabled: false });
const diagnostics = ref<Diagnostics | null>(null);
const diagnosticsBusy = ref(false);
const finderIntegration = ref<FinderIntegration | null>(null);
const finderBusy = ref(false);
const workspaceLabel = computed(() => repoInfo.value?.path ?? props.path ?? "未指定目录");
const title = computed(() => ({
  pull: "拉取远端更新",
  branch: "分支",
  log: "提交日志",
  discard: "放弃修改",
  conflict: "解决冲突",
  init: "初始化仓库",
  clone: "克隆仓库",
  settings: "设置"
}[props.view]));

function fail(reason: unknown) {
  const gitError = toGitError(reason);
  if (gitError.kind !== "Cancelled") error.value = gitError;
}

async function loadRepo() {
  if (!props.tauriReady || !props.path) return;
  const info = await getRepoInfo(props.path);
  repoInfo.value = info;
  if (info.isRepo) statuses.value = await getStatus(props.path);
}

async function load() {
  error.value = null;
  notice.value = "";
  if (!props.tauriReady) return;
  loading.value = true;
  try {
    if (props.view === "settings") {
      settings.value = await getSettings();
      finderIntegration.value = await getFinderIntegration();
      return;
    }
    if (!props.path) {
      throw new Error("没有收到目标目录。请从 Finder 右键菜单打开 MenuGit。");
    }
    if (props.view === "init" || props.view === "clone") {
      repoInfo.value = await getRepoInfo(props.path);
      identityMissing.value = false;
      if (props.view === "clone" && props.url) cloneUrl.value = props.url;
      return;
    }
    await loadRepo();
    if (props.view === "branch") await loadBranches();
    if (props.view === "log") await loadLogs(true);
    if (props.view === "discard") selectedDiscard.value = new Set();
    if (props.view === "conflict") await loadConflicts();
    if (props.view === "pull") await loadBranches();
  } catch (reason) {
    fail(reason);
  } finally {
    loading.value = false;
  }
}

watch(() => [props.view, props.path, props.file, props.url, props.tauriReady] as const, () => void load(), { immediate: true });

function go(view: ViewName = "commit") {
  emit("navigate", view);
}

const branches = ref<{ current: string | null; local: BranchInfo[]; remote: BranchInfo[] }>({
  current: null,
  local: [],
  remote: []
});
const branchFilter = ref("");
const newBranch = ref("");
const branchBusy = ref("");
const localBranches = computed(() => filterBranches(branches.value.local, branchFilter.value));
const remoteBranches = computed(() => filterBranches(branches.value.remote, branchFilter.value));
const branchNameError = computed(() =>
  newBranch.value.trim() && !validBranchName(newBranch.value.trim())
    ? "分支名不能含空格、中文或特殊字符"
    : ""
);
function filterBranches(items: BranchInfo[], term: string) {
  const query = term.trim().toLowerCase();
  return query ? items.filter((branch) => branch.name.toLowerCase().includes(query)) : items;
}
async function loadBranches() {
  if (!props.path) return;
  branches.value = await listBranches(props.path);
}
function validBranchName(name: string) {
  return Boolean(name.trim()) && !name.startsWith("-") && !name.includes("..") && !name.includes("@{")
    && !name.includes("//") && !name.startsWith("/") && !name.endsWith("/") && !name.endsWith(".")
    && !name.endsWith(".lock") && /^[\w./-]+$/.test(name);
}
async function changeBranch(branch: BranchInfo, remote = false) {
  if (!props.path || branchBusy.value) return;
  branchBusy.value = branch.name;
  error.value = null;
  try {
    if (remote) await checkoutRemote(props.path, branch.name);
    else await switchBranch(props.path, branch.name);
    ElMessage.success(`已切换到 ${remote ? branch.name : branch.name}`);
    await loadBranches();
    await loadRepo();
    go("commit");
  } catch (reason) {
    fail(reason);
  } finally {
    branchBusy.value = "";
  }
}
async function createBranch() {
  if (!props.path || !validBranchName(newBranch.value) || branchBusy.value) return;
  branchBusy.value = newBranch.value;
  error.value = null;
  try {
    await switchBranch(props.path, newBranch.value.trim(), true);
    ElMessage.success(`已创建并切换到 ${newBranch.value.trim()}`);
    newBranch.value = "";
    await loadBranches();
    await loadRepo();
    go("commit");
  } catch (reason) {
    fail(reason);
  } finally {
    branchBusy.value = "";
  }
}

const selectedSource = ref("");
const rememberUpstream = ref(false);
const syncSummary = ref("");
const originBranches = computed(() => branches.value.remote
  .map((branch) => branch.name)
  .filter((name) => name.startsWith("origin/") && name !== "origin/HEAD")
  .map((name) => name.slice("origin/".length)));
const upstreamBranch = computed(() => repoInfo.value?.upstream?.startsWith("origin/")
  ? repoInfo.value.upstream.slice("origin/".length)
  : "");
const normalizedPullSource = computed(() => selectedSource.value.trim().replace(/^origin\//, ""));
const pullSourceError = computed(() =>
  normalizedPullSource.value && !validBranchName(normalizedPullSource.value)
    ? "分支名不能含空格、中文或特殊字符"
    : ""
);
watch(() => [repoInfo.value?.upstream, originBranches.value.join("|")] as const, () => {
  if (props.view !== "pull" && props.view !== "push") return;
  selectedSource.value = upstreamBranch.value || originBranches.value[0] || "";
  rememberUpstream.value = !repoInfo.value?.upstream;
}, { immediate: true });

async function runPull() {
  if (!props.path || running.value) return;
  if (pullSourceError.value) {
    ElMessage.warning(pullSourceError.value);
    return;
  }
  running.value = true;
  error.value = null;
  notice.value = "正在从 origin 拉取并合并更新…";
  try {
    const result = await pullRepo(props.path, normalizedPullSource.value || undefined, rememberUpstream.value);
    await loadRepo();
    if (repoInfo.value?.mergeInProgress || repoInfo.value?.conflictFileCount) {
      notice.value = "拉取产生了合并冲突，正在打开冲突处理。";
      resetConflictState();
      go("conflict");
      return;
    }
    syncSummary.value = result.commits === 0
      ? "已是最新，无需更新。"
      : `拉取完成：${result.commits == null ? "提交数未知" : `拉入 ${result.commits} 个提交`}${result.filesChanged == null ? "" : `，更新 ${result.filesChanged} 个文件`}`;
    notice.value = syncSummary.value;
    ElMessage.success(syncSummary.value);
  } catch (reason) {
    if (props.path) {
      try {
        await loadRepo();
        if (repoInfo.value?.mergeInProgress || repoInfo.value?.conflictFileCount) {
          notice.value = "拉取产生了合并冲突，正在打开冲突处理。";
          resetConflictState();
          go("conflict");
          return;
        }
      } catch {
        // 保留拉取命令本身的原始错误，避免刷新失败覆盖原因。
      }
    }
    fail(reason);
    notice.value = "";
  } finally {
    running.value = false;
  }
}

const logEntries = ref<LogEntry[]>([]);
const logFilter = ref("");
const logAll = ref(false);
const logBusy = ref(false);
const logHasMore = ref(false);
const selectedLog = ref<LogEntry | null>(null);
const logDetail = ref<LogDetail | null>(null);
const selectedLogFile = ref("");
const logDiff = ref("");
const logDiffLines = computed(() => parseDiff(logDiff.value));
const visibleLogs = computed(() => {
  const query = logFilter.value.trim().toLowerCase();
  if (!query) return logEntries.value;
  return logEntries.value.filter((entry) => `${entry.subject} ${entry.author}`.toLowerCase().includes(query));
});
async function loadLogs(reset: boolean) {
  if (!props.path || logBusy.value) return;
  logBusy.value = true;
  error.value = null;
  try {
    if (reset) {
      logEntries.value = [];
      selectedLog.value = null;
      logDetail.value = null;
    }
    const page = await getLog(props.path, {
      all: logAll.value,
      file: props.file,
      skip: reset ? 0 : logEntries.value.length,
      limit: 200
    });
    logEntries.value = reset ? page : [...logEntries.value, ...page];
    logHasMore.value = page.length === 200;
  } catch (reason) {
    fail(reason);
  } finally {
    logBusy.value = false;
  }
}
function onLogScroll(event: Event) {
  const element = event.currentTarget as HTMLElement;
  if (logHasMore.value && !logBusy.value && element.scrollHeight - element.scrollTop - element.clientHeight < 56) {
    void loadLogs(false);
  }
}
async function openLog(entry: LogEntry) {
  if (!props.path) return;
  selectedLog.value = entry;
  selectedLogFile.value = "";
  logDiff.value = "";
  error.value = null;
  try {
    logDetail.value = await getLogDetail(props.path, entry.hash);
  } catch (reason) {
    fail(reason);
  }
}
async function showCommitDiff(file: string) {
  if (!props.path || !selectedLog.value) return;
  selectedLogFile.value = file;
  try {
    logDiff.value = await getCommitFileDiff(props.path, selectedLog.value.hash, file);
  } catch (reason) {
    fail(reason);
  }
}
function formatTime(seconds: number) {
  const date = new Date(seconds * 1000);
  const elapsed = Math.max(0, Date.now() - date.getTime());
  if (elapsed < 60_000) return "刚刚";
  if (elapsed < 3_600_000) return `${Math.floor(elapsed / 60_000)} 分钟前`;
  if (elapsed < 86_400_000) return `${Math.floor(elapsed / 3_600_000)} 小时前`;
  if (elapsed < 31_536_000_000) return `${Math.floor(elapsed / 86_400_000)} 天前`;
  return date.toLocaleDateString();
}

const discardCandidates = computed(() => statuses.value.filter((item) => item.status !== "conflict"));
const selectedDiscard = ref<Set<string>>(new Set());
function toggleDiscard(name: string, checked: boolean) {
  const next = new Set(selectedDiscard.value);
  if (checked) next.add(name);
  else next.delete(name);
  selectedDiscard.value = next;
}
function selectAllDiscard(checked: boolean) {
  selectedDiscard.value = checked ? new Set(discardCandidates.value.map((item) => item.path)) : new Set();
}
async function discardSelected() {
  if (!props.path || !selectedDiscard.value.size || running.value) return;
  const files = discardCandidates.value.filter((item) => selectedDiscard.value.has(item.path));
  const untracked = files.filter((item) => item.untracked).length;
  const details = files.map((item) => `${item.path}${item.untracked ? "（将被彻底删除）" : ""}`).join("；");
  try {
    await ElMessageBox.confirm(
      `将永久丢弃 ${files.length} 个文件的修改，不可恢复。${untracked ? `其中 ${untracked} 个未跟踪文件将被彻底删除。` : ""}\n\n影响文件：${details}`,
      "确认放弃修改",
      { type: "warning", confirmButtonText: "永久放弃", cancelButtonText: "返回", distinguishCancelAndClose: true }
    );
  } catch {
    return;
  }
  running.value = true;
  error.value = null;
  try {
    await discardChanges(props.path, files.map((item) => item.path));
    selectedDiscard.value = new Set();
    await loadRepo();
    ElMessage.success(`已放弃 ${files.length} 个文件的修改`);
  } catch (reason) {
    fail(reason);
  } finally {
    running.value = false;
  }
}

const conflictFiles = computed(() => statuses.value.filter((item) => item.status === "conflict"));
const selectedConflict = ref("");
const conflictData = ref<ConflictFileResult | null>(null);
const conflictChoices = ref<Array<ConflictChoice | "">>([]);
/** 已解析的冲突文件内容与每块选择；默认保留在内存，完成合并时才写回。 */
const conflictSections = ref<Record<string, ConflictFileResult>>({});
const conflictChoicesByFile = ref<Record<string, Array<ConflictChoice | "">>>({});
const mergeMessage = ref("");
function isConflictResolved(file: string) {
  const data = conflictSections.value[file];
  const choices = conflictChoicesByFile.value[file];
  return Boolean(
    data
    && data.conflictCount > 0
    && choices?.length === data.conflictCount
    && choices.every((choice) => Boolean(choice))
  );
}
const resolvedConflictCount = computed(() =>
  conflictFiles.value.filter((file) => isConflictResolved(file.path)).length
);
const allConflictsResolved = computed(() =>
  conflictFiles.value.length === 0
    ? Boolean(repoInfo.value?.mergeInProgress)
    : resolvedConflictCount.value === conflictFiles.value.length
);
function resetConflictState() {
  conflictSections.value = {};
  conflictChoicesByFile.value = {};
  selectedConflict.value = "";
  conflictData.value = null;
  conflictChoices.value = [];
  mergeMessage.value = "";
}
async function loadConflicts() {
  await loadRepo();
  if (!mergeMessage.value) mergeMessage.value = `Merge remote changes into ${repoInfo.value?.branch ?? "current branch"}`;
  // 外部已解决的文件不再出现在 unmerged 列表中，顺手清掉缓存。
  for (const file of Object.keys(conflictSections.value)) {
    if (!conflictFiles.value.some((item) => item.path === file)) {
      delete conflictSections.value[file];
      delete conflictChoicesByFile.value[file];
    }
  }
  if (!conflictFiles.value.length) {
    selectedConflict.value = "";
    conflictData.value = null;
    conflictChoices.value = [];
    return;
  }
  if (selectedConflict.value && conflictFiles.value.some((file) => file.path === selectedConflict.value)) {
    const cached = conflictSections.value[selectedConflict.value];
    if (cached) {
      conflictData.value = cached;
      conflictChoices.value = conflictChoicesByFile.value[selectedConflict.value]
        ?? Array.from<ConflictChoice | "">({ length: cached.conflictCount }, () => "");
    }
    return;
  }
  selectedConflict.value = "";
  conflictData.value = null;
  conflictChoices.value = [];
}
async function openConflict(file: string) {
  if (!props.path) return;
  selectedConflict.value = file;
  error.value = null;
  const cached = conflictSections.value[file];
  if (cached) {
    conflictData.value = cached;
    conflictChoices.value = conflictChoicesByFile.value[file]
      ?? Array.from<ConflictChoice | "">({ length: cached.conflictCount }, () => "");
    return;
  }
  conflictData.value = null;
  conflictChoices.value = [];
  try {
    const result = await getConflictFile(props.path, file);
    conflictSections.value = { ...conflictSections.value, [file]: result };
    const choices = Array.from<ConflictChoice | "">({ length: result.conflictCount }, () => "");
    conflictChoicesByFile.value = { ...conflictChoicesByFile.value, [file]: choices };
    if (selectedConflict.value === file) {
      conflictData.value = result;
      conflictChoices.value = choices;
    }
  } catch (reason) {
    fail(reason);
  }
}
/** 所有冲突块都有选择后自动标记为已解决（PRD FM-08），不立即写文件。 */
function chooseConflict(index: number, choice: ConflictChoice) {
  if (!selectedConflict.value) return;
  const file = selectedConflict.value;
  const wasResolved = isConflictResolved(file);
  const next = [...conflictChoices.value];
  next[index] = choice;
  conflictChoices.value = next;
  conflictChoicesByFile.value = { ...conflictChoicesByFile.value, [file]: next };
  if (!wasResolved && isConflictResolved(file)) {
    ElMessage.success(`${file} 已自动标记为已解决`);
  }
}
async function refreshConflicts() {
  if (running.value) return;
  error.value = null;
  try {
    await loadConflicts();
  } catch (reason) {
    fail(reason);
  }
}
const conflictPreview = computed(() => {
  if (!conflictData.value) return "";
  let conflictIndex = 0;
  const lines: string[] = [];
  for (const section of conflictData.value.sections) {
    if (section.type === "context") lines.push(...section.lines);
    else {
      const choice = conflictChoices.value[conflictIndex++];
      if (choice === "local" || choice === "both") lines.push(...section.local);
      if (choice === "both") lines.push("");
      if (choice === "theirs" || choice === "both") lines.push(...section.theirs);
    }
  }
  return lines.join("\n");
});
function conflictIndexAt(sectionIndex: number) {
  return (conflictData.value?.sections.slice(0, sectionIndex) ?? [])
    .filter((section) => section.type === "conflict").length;
}
async function finishMerge() {
  if (!props.path || running.value || !allConflictsResolved.value) return;
  running.value = true;
  error.value = null;
  try {
    // 合并前统一写回所有已选择结果，避免用户暂时改选时反复落盘。
    for (const item of conflictFiles.value) {
      const data = conflictSections.value[item.path];
      const choices = conflictChoicesByFile.value[item.path];
      if (!data || !choices || choices.length !== data.conflictCount || choices.some((choice) => !choice)) {
        throw new Error(`冲突文件还未全部处理：${item.path}`);
      }
      await resolveConflictFile(props.path, item.path, choices as ConflictChoice[]);
    }
    await completeMerge(props.path, mergeMessage.value.trim() || "Merge remote changes");
    ElMessage.success("合并提交已完成");
    go("commit");
  } catch (reason) {
    fail(reason);
    await loadConflicts();
  } finally {
    running.value = false;
  }
}
async function abortCurrentMerge() {
  if (!props.path || running.value) return;
  try {
    await ElMessageBox.confirm(
      "中止合并会恢复到拉取前的状态，并丢弃本次合并过程中的解决结果。确定继续吗？",
      "中止合并",
      { type: "warning", confirmButtonText: "中止合并", cancelButtonText: "继续处理" }
    );
  } catch {
    return;
  }
  running.value = true;
  error.value = null;
  try {
    await abortMerge(props.path);
    ElMessage.success("已中止合并并恢复工作区");
    go("commit");
  } catch (reason) {
    fail(reason);
  } finally {
    running.value = false;
  }
}

const initAlreadyRepo = computed(() => Boolean(repoInfo.value?.isRepo));
const identityMissing = ref(false);
async function initializeRepo() {
  if (!props.path || running.value || initAlreadyRepo.value) return;
  try {
    await ElMessageBox.confirm(`将在“${props.path}”创建 Git 仓库。`, "初始化 Git 仓库", {
      confirmButtonText: "创建仓库",
      cancelButtonText: "取消"
    });
  } catch {
    return;
  }
  running.value = true;
  error.value = null;
  try {
    repoInfo.value = await initRepo(props.path);
    try {
      const identity = await getAuthorIdentity(props.path);
      identityMissing.value = !identity.name || !identity.email;
    } catch {
      identityMissing.value = true;
    }
    notice.value = identityMissing.value
      ? "仓库已创建，但系统 Git 尚未配置提交身份。"
      : "仓库已创建。";
    ElMessage.success("仓库已创建");
  } catch (reason) {
    fail(reason);
  } finally {
    running.value = false;
  }
}

const cloneUrl = ref("");
const cloneDir = ref("");
const cloneKey = ref("");
const cloneTarget = ref("");
const cloneProgress = ref<CloneProgress | null>(null);
function inferCloneName(url: string): string {
  const trimmed = url.trim().replace(/[/\\]+$/, "");
  const last = trimmed.split(/[/\\]/).pop() ?? "";
  return last.replace(/\.git$/, "");
}
const inferredCloneName = computed(() => inferCloneName(cloneUrl.value));
const effectiveCloneName = computed(() => cloneDir.value.trim() || inferredCloneName.value);
const cloneDirError = computed(() => {
  const name = cloneDir.value.trim();
  if (!name) return "";
  if (name === "." || name === ".." || /[/\\\0]/.test(name)) {
    return "只填写一个目录名，不要包含路径分隔符";
  }
  return "";
});
let stopCloneListener: UnlistenFn | null = null;
const cloneEvents = new Map<string, CloneProgress>();
async function startClone() {
  if (!props.path || !cloneUrl.value.trim() || cloneDirError.value || running.value) return;
  error.value = null;
  notice.value = "";
  cloneProgress.value = null;
  try {
    stopCloneListener?.();
    stopCloneListener = await listenCloneProgress((progress) => {
      cloneEvents.set(progress.repoKey, progress);
      if (!cloneKey.value || progress.repoKey === cloneKey.value) {
        cloneProgress.value = progress;
        if (progress.done) running.value = false;
      }
    });
    running.value = true;
    const result = await cloneRepo(props.path, cloneUrl.value.trim(), cloneDir.value.trim() || undefined);
    cloneKey.value = result.repoKey;
    cloneTarget.value = result.targetDir;
    cloneProgress.value = cloneEvents.get(result.repoKey) ?? {
      repoKey: result.repoKey,
      percent: 0,
      text: "正在开始克隆…",
      done: false,
      error: false,
      message: null
    };
    if (cloneProgress.value.done) running.value = false;
  } catch (reason) {
    running.value = false;
    fail(reason);
  }
}
async function stopClone() {
  if (!cloneKey.value || !running.value) return;
  try {
    await cancelClone(cloneKey.value);
    notice.value = "已请求取消克隆…";
  } catch (reason) {
    fail(reason);
  }
}
async function revealClone() {
  if (!cloneTarget.value) return;
  try {
    await openInFinder(cloneTarget.value);
  } catch (reason) {
    fail(reason);
  }
}

async function repairFinder() {
  if (!props.tauriReady || finderBusy.value) return;
  finderBusy.value = true;
  error.value = null;
  try {
    finderIntegration.value = await repairFinderIntegration();
    ElMessage.success("访达扩展已重新注册并启用");
  } catch (reason) {
    fail(reason);
  } finally {
    finderBusy.value = false;
  }
}
async function saveSettings() {
  if (!props.tauriReady) return;
  error.value = null;
  try {
    await setSettings(settings.value);
    ElMessage.success("设置已保存");
  } catch (reason) {
    fail(reason);
  }
}
async function showDiagnostics() {
  diagnosticsBusy.value = true;
  error.value = null;
  try {
    diagnostics.value = await getDiagnostics();
  } catch (reason) {
    fail(reason);
  } finally {
    diagnosticsBusy.value = false;
  }
}
async function showProjectReleases() {
  try {
    await openProjectReleases();
  } catch (reason) {
    fail(reason);
  }
}

onBeforeUnmount(() => {
  stopCloneListener?.();
  if (props.view === "clone" && running.value && cloneKey.value) void cancelClone(cloneKey.value);
});
</script>

<template>
  <main class="ops-view">
    <header class="ops-header">
      <div class="ops-title-wrap">
        <h1>{{ title }}</h1>
        <span v-if="props.path && props.view !== 'settings'" class="ops-path" :title="workspaceLabel">{{ workspaceLabel }}</span>
      </div>
      <el-button text :disabled="running || Boolean(branchBusy)" @click="go('commit')">返回提交窗口</el-button>
    </header>

    <el-alert v-if="error" class="ops-alert" type="error" :title="error.message" :closable="false" show-icon>
      <template #default>
        <details v-if="error.stderr" class="raw-error">
          <summary>显示 Git 详细信息</summary>
          <pre>{{ error.stderr }}</pre>
        </details>
        <p v-if="error.kind === 'GitMissing'" class="git-help">macOS 安装 Git：在终端执行 <code>xcode-select --install</code>，或使用 Homebrew 执行 <code>brew install git</code>。</p>
        <el-button v-if="props.view === 'pull'" size="small" @click="runPull">重试</el-button>
      </template>
    </el-alert>
    <el-alert v-if="notice" class="ops-alert" type="success" :title="notice" :closable="false" show-icon />

    <section v-if="loading" class="ops-loading"><el-icon class="is-loading"><Loading /></el-icon> 正在读取…</section>

    <section v-else-if="props.view === 'pull'" class="ops-card">
      <div class="repo-summary">
        <span>本地分支</span><b>{{ repoInfo?.branch ?? "未知" }}</b>
        <span>当前上游</span><b>{{ repoInfo?.upstream ?? "未设置" }}</b>
      </div>
      <el-form label-position="top">
        <el-form-item label="从远端分支拉取" :error="pullSourceError">
          <el-select v-model="selectedSource" filterable allow-create default-first-option placeholder="输入远端分支名">
            <el-option v-for="branch in originBranches" :key="branch" :label="`origin/${branch}`" :value="branch" />
          </el-select>
        </el-form-item>
        <el-checkbox v-model="rememberUpstream">拉取后将此分支设为当前分支的上游</el-checkbox>
      </el-form>
      <p class="muted">Git 的合并 / rebase 策略沿用系统 Git 配置。</p>
      <footer class="ops-actions">
        <el-button @click="go('commit')">取消</el-button>
        <el-button type="primary" :loading="running" :disabled="!normalizedPullSource || Boolean(pullSourceError)" @click="runPull">拉取更新</el-button>
      </footer>
    </section>

    <section v-else-if="props.view === 'branch'" class="ops-card branch-layout">
      <div class="branch-create">
        <el-input v-model="newBranch" placeholder="新分支名称" :class="{ invalid: branchNameError }" @keyup.enter="createBranch" />
        <el-button type="primary" :disabled="!validBranchName(newBranch)" :loading="Boolean(newBranch) && branchBusy === newBranch" @click="createBranch">创建并切换</el-button>
      </div>
      <p v-if="branchNameError" class="field-error">{{ branchNameError }}</p>
      <el-input v-model="branchFilter" placeholder="按分支名过滤…" clearable />
      <div class="branch-list">
        <h3>本地分支</h3>
        <button v-for="branch in localBranches" :key="branch.name" class="branch-row" :class="{ current: branch.isCurrent }" :disabled="branch.isCurrent || Boolean(branchBusy)" @click="changeBranch(branch)">
          <span><b>{{ branch.name }}</b><small v-if="branch.upstream">{{ branch.upstream }}</small></span>
          <el-tag v-if="branch.isCurrent" size="small" type="success">当前</el-tag>
          <el-icon v-else-if="branchBusy === branch.name" class="is-loading"><Loading /></el-icon>
          <span v-else class="row-action">切换</span>
        </button>
        <el-empty v-if="localBranches.length === 0" description="没有匹配的本地分支" :image-size="54" />
        <h3 class="remote-heading">远端分支</h3>
        <button v-for="branch in remoteBranches" :key="branch.name" class="branch-row" :disabled="Boolean(branchBusy)" @click="changeBranch(branch, true)">
          <span><b>{{ branch.name }}</b></span><span class="row-action">检出并跟踪</span>
        </button>
        <el-empty v-if="remoteBranches.length === 0" description="没有远端分支" :image-size="54" />
      </div>
    </section>

    <section v-else-if="props.view === 'log'" class="ops-card log-layout">
      <div class="log-toolbar">
        <el-input v-model="logFilter" placeholder="按提交说明或作者过滤…" clearable />
        <el-checkbox v-model="logAll" @change="loadLogs(true)">所有分支</el-checkbox>
      </div>
      <div class="log-columns">
        <div class="log-list" @scroll.passive="onLogScroll">
          <button v-for="entry in visibleLogs" :key="entry.hash" class="log-row" :class="{ selected: selectedLog?.hash === entry.hash }" @click="openLog(entry)">
            <span class="hash">{{ entry.shortHash }}</span>
            <span class="log-main"><b>{{ entry.subject || "（无提交说明）" }}</b><small>{{ entry.author }} · {{ formatTime(entry.time) }}</small><small v-if="entry.refs.length" class="refs">{{ entry.refs.join(" · ") }}</small></span>
          </button>
          <el-empty v-if="visibleLogs.length === 0 && !logBusy" description="还没有提交，去完成第一次提交吧" :image-size="70" />
          <el-button v-if="logHasMore" class="load-more" :loading="logBusy" @click="loadLogs(false)">加载更早的提交</el-button>
        </div>
        <div class="log-detail">
          <template v-if="selectedLog && logDetail">
            <div class="detail-heading"><code>{{ selectedLog.shortHash }}</code><span>{{ selectedLog.author }} · {{ new Date(selectedLog.time * 1000).toLocaleString() }}</span></div>
            <pre class="commit-message">{{ logDetail.message }}</pre>
            <h3>变更文件（{{ logDetail.files.length }}）</h3>
            <button v-for="file in logDetail.files" :key="file.path" class="changed-file" :class="{ chosen: selectedLogFile === file.path }" @click="showCommitDiff(file.path)">
              <el-tag size="small">{{ file.status }}</el-tag><span>{{ file.oldPath ? `${file.oldPath} → ` : "" }}{{ file.path }}</span>
            </button>
            <div v-if="selectedLogFile" class="commit-diff">
              <div v-for="(line, index) in logDiffLines" :key="index" class="ln" :class="line.type">{{ line.text }}</div>
              <div v-if="!logDiff" class="diff-empty">该文件没有可显示的文本差异。</div>
            </div>
          </template>
          <el-empty v-else description="选择一条提交查看详情" :image-size="70" />
        </div>
      </div>
    </section>

    <section v-else-if="props.view === 'discard'" class="ops-card discard-layout">
      <el-alert v-if="discardCandidates.length === 0" title="没有可放弃的修改" type="info" :closable="false" />
      <template v-else>
        <div class="discard-top"><el-checkbox :model-value="selectedDiscard.size === discardCandidates.length" @change="selectAllDiscard(Boolean($event))">全选</el-checkbox><span>默认不选择任何文件</span></div>
        <div class="discard-list">
          <label v-for="item in discardCandidates" :key="item.path" class="discard-row">
            <el-checkbox :model-value="selectedDiscard.has(item.path)" @change="toggleDiscard(item.path, Boolean($event))" />
            <el-tag size="small" :type="item.untracked ? 'warning' : 'info'">{{ item.untracked ? "未跟踪" : item.status === "deleted" ? "删除" : "修改" }}</el-tag>
            <span class="discard-name">{{ item.path }}</span>
            <small v-if="item.untracked">将彻底删除</small>
          </label>
        </div>
        <footer class="ops-actions">
          <el-button @click="go('commit')">返回</el-button>
          <el-button type="danger" :disabled="selectedDiscard.size === 0" :loading="running" @click="discardSelected">放弃所选修改（{{ selectedDiscard.size }}）</el-button>
        </footer>
      </template>
    </section>

    <section v-else-if="props.view === 'conflict'" class="ops-card conflict-layout">
      <div class="conflict-top">
        <b>已解决 {{ resolvedConflictCount }} / {{ conflictFiles.length }}</b>
        <span v-if="conflictFiles.length">逐个文件选择冲突块的处理方式，全部选完自动标记为已解决</span>
        <span v-else-if="repoInfo?.mergeInProgress">所有冲突文件已解决，可以完成合并提交</span>
        <span v-else>当前没有需要解决的冲突</span>
        <el-button size="small" :disabled="running" @click="refreshConflicts">刷新</el-button>
      </div>
      <p v-if="conflictFiles.length" class="conflict-hint">逐个文件解决：为每个冲突块选择保留哪一方的内容，或保留双方。一个文件的所有冲突块都决定后自动标记为已解决。</p>
      <div v-if="conflictFiles.length" class="conflict-files">
        <button
          v-for="item in conflictFiles"
          :key="item.path"
          class="conflict-file-row"
          :class="{ selected: selectedConflict === item.path, resolved: isConflictResolved(item.path) }"
          @click="openConflict(item.path)"
        >
          <el-tag size="small" :type="isConflictResolved(item.path) ? 'success' : 'danger'">
            {{ isConflictResolved(item.path) ? "已解决" : "冲突" }}
          </el-tag>
          <span class="cf-name">{{ item.path }}</span>
          <span class="cf-action">{{ isConflictResolved(item.path) ? "重新编辑" : "解决 ›" }}</span>
        </button>
      </div>
      <div v-if="conflictData" class="conflict-editor">
        <h3>{{ conflictData.file }} · {{ conflictData.conflictCount }} 个冲突块</h3>
        <el-alert v-if="conflictData.conflictCount === 0" title="此冲突格式无法自动解析。请在命令行处理该文件后，点击「刷新」再完成合并。" type="warning" :closable="false" />
        <div v-for="(section, index) in conflictData.sections" :key="index" class="conflict-section">
          <pre v-if="section.type === 'context'" class="context-lines">{{ section.lines.join('\n') }}</pre>
          <div v-else class="conflict-choice">
            <div class="choice-head"><b>冲突块 {{ conflictIndexAt(index) + 1 }}</b><span v-if="!conflictChoices[conflictIndexAt(index)]">选择一个版本</span></div>
            <div class="choice-grid">
              <button :class="{ picked: conflictChoices[conflictIndexAt(index)] === 'local' }" @click="chooseConflict(conflictIndexAt(index), 'local')"><b>采用本地</b><pre>{{ section.local.join('\n') || "（空）" }}</pre></button>
              <button :class="{ picked: conflictChoices[conflictIndexAt(index)] === 'theirs' }" @click="chooseConflict(conflictIndexAt(index), 'theirs')"><b>采用远端</b><pre>{{ section.theirs.join('\n') || "（空）" }}</pre></button>
              <button :class="{ picked: conflictChoices[conflictIndexAt(index)] === 'both' }" @click="chooseConflict(conflictIndexAt(index), 'both')"><b>保留双方</b><pre>{{ [...section.local, ...section.theirs].join('\n') || "（空）" }}</pre></button>
            </div>
          </div>
        </div>
        <h3>合并结果预览</h3><pre class="merge-preview">{{ conflictPreview }}</pre>
        <p v-if="isConflictResolved(conflictData.file)" class="auto-hint">所有冲突块均已选择，该文件已自动标记为已解决。可继续调整选择，或点击上方「重新编辑」。</p>
      </div>
      <el-empty
        v-else-if="conflictFiles.length"
        description="点击上方文件开始解决冲突"
        :image-size="60"
      />
      <div v-if="repoInfo?.mergeInProgress || conflictFiles.length" class="merge-footer">
        <el-input v-model="mergeMessage" placeholder="合并提交说明" />
        <el-button type="danger" plain :disabled="running" @click="abortCurrentMerge">中止合并…</el-button>
        <el-button type="primary" :disabled="!allConflictsResolved" :loading="running" @click="finishMerge">完成合并提交</el-button>
      </div>
    </section>

    <section v-else-if="props.view === 'init'" class="ops-card compact-card">
      <el-alert v-if="initAlreadyRepo" :title="`此目录已在仓库 ${repoInfo?.path ?? ''} 中`" type="info" :closable="false" />
      <template v-else>
        <div class="large-icon">⌘</div><h2>在此目录创建 Git 仓库</h2>
        <p class="muted path-wrap">{{ props.path }}</p>
        <el-alert
          v-if="identityMissing"
          class="identity-alert"
          type="warning"
          :closable="false"
          title="系统 Git 尚未配置提交身份"
        >
          提交前请在终端执行：
          <pre>git config --global user.name "你的名字"
git config --global user.email "you@example.com"</pre>
        </el-alert>
        <el-button type="primary" :loading="running" @click="initializeRepo">初始化仓库…</el-button>
      </template>
    </section>

    <section v-else-if="props.view === 'clone'" class="ops-card compact-card clone-card">
      <el-form label-position="top">
        <el-form-item label="仓库 URL"><el-input v-model="cloneUrl" :disabled="running" placeholder="https://… 或 git@…" /></el-form-item>
        <el-form-item label="目标文件夹名（可选）" :error="cloneDirError">
          <el-input
            v-model="cloneDir"
            :disabled="running"
            :placeholder="inferredCloneName ? `默认：${inferredCloneName}` : '默认从 URL 推断'"
          />
        </el-form-item>
      </el-form>
      <p v-if="effectiveCloneName" class="muted path-wrap">克隆到：{{ props.path }}/{{ effectiveCloneName }}</p>
      <p v-else class="muted path-wrap">克隆到：{{ props.path }}</p>
      <el-progress v-if="cloneProgress" :percentage="cloneProgress.percent ?? 0" :indeterminate="cloneProgress.percent == null && !cloneProgress.done" :status="cloneProgress.error ? 'exception' : cloneProgress.done ? 'success' : undefined" />
      <pre v-if="cloneProgress?.text" class="clone-output">{{ cloneProgress.text }}</pre>
      <p v-if="cloneProgress?.error" class="error-text">{{ cloneProgress.message }}。请确认系统凭证或 SSH 已配置。</p>
      <div class="ops-actions">
        <el-button v-if="running" type="danger" plain @click="stopClone">取消克隆</el-button>
        <el-button v-else-if="cloneProgress?.done && !cloneProgress.error" type="primary" @click="revealClone">打开文件夹</el-button>
        <el-button v-else type="primary" :disabled="!cloneUrl.trim() || Boolean(cloneDirError)" :loading="running" @click="startClone">开始克隆</el-button>
      </div>
    </section>

    <section v-else-if="props.view === 'settings'" class="ops-card settings-layout">
      <el-form label-position="top">
        <el-form-item v-if="finderIntegration?.supported" label="访达集成">
          <p>{{ finderIntegration.message }}</p>
          <el-button :loading="finderBusy" :disabled="!finderIntegration.bundled" @click="repairFinder">修复访达右键菜单</el-button>
        </el-form-item>
        <el-form-item label="语言"><el-select v-model="settings.language" @change="saveSettings"><el-option label="跟随系统" value="system" /><el-option label="简体中文" value="zh-CN" /><el-option label="English" value="en" /></el-select></el-form-item>
        <el-form-item label="提交行为"><el-checkbox v-model="settings.newFilesChecked" @change="saveSettings">新增和未跟踪文件默认勾选</el-checkbox></el-form-item>
        <el-form-item label="排障"><el-checkbox v-model="settings.diagEnabled" @change="saveSettings">记录 Git 命令诊断日志</el-checkbox><p class="muted">日志保存在本机应用数据目录中，不包含凭证。</p><el-button :loading="diagnosticsBusy" @click="showDiagnostics">查看 Git 检测与诊断日志</el-button></el-form-item>
      </el-form>
      <div v-if="diagnostics" class="diagnostics">
        <p>Git：{{ diagnostics.gitVersion ?? "未检测到 Git" }}</p><p>日志：{{ diagnostics.logPath ?? "不可用" }}</p><pre>{{ diagnostics.log }}</pre>
      </div>
      <el-divider />
      <div class="about"><b>MenuGit 0.1.0</b><span>Git 配置、代理与凭证沿用系统 Git；如需修改身份，请在系统 Git 配置中设置 user.name / user.email。</span><span>诊断日志会隐藏 URL authority 和敏感查询参数中的凭证，但可能包含仓库路径；分享前请先检查。</span><span>Finder 扩展启用位置：系统设置 → 通用 → 登录项与扩展 → Finder 扩展。</span><el-button link type="primary" @click="showProjectReleases">查看项目主页与版本更新</el-button></div>
    </section>
  </main>
</template>

<style scoped lang="scss">
.ops-view { height: 100%; min-height: 0; display: flex; flex-direction: column; gap: 14px; padding: 18px 22px 22px; overflow: hidden; background: var(--bg); color: var(--ink); }
.ops-header { flex: none; display: flex; justify-content: space-between; align-items: center; min-height: 40px; }
.ops-title-wrap { min-width: 0; display: flex; align-items: baseline; gap: 14px; }
h1 { margin: 0; font-size: 20px; font-weight: 650; }
.ops-path { max-width: 60vw; overflow: hidden; color: var(--ink3); font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.ops-card { min-height: 0; flex: 1; overflow: auto; padding: 20px; border: 1px solid var(--line); border-radius: 12px; background: var(--card); }
.ops-alert { flex: none; }
.raw-error { margin-top: 8px; font-size: 12px; }
.raw-error pre, .diagnostics pre, .clone-output { max-height: 180px; overflow: auto; padding: 10px; border-radius: 7px; background: var(--bg-soft); white-space: pre-wrap; overflow-wrap: anywhere; font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
.git-help { margin: 8px 0 0; color: var(--ink2); font-size: 12px; }
.ops-loading { display: grid; flex: 1; place-content: center; color: var(--ink3); }
.repo-summary { display: grid; grid-template-columns: auto 1fr; gap: 8px 16px; margin-bottom: 20px; color: var(--ink3); font-size: 13px; }
.repo-summary b { color: var(--ink); font-weight: 600; }
.ops-card :deep(.el-select), .ops-card :deep(.el-input) { max-width: 100%; }
.ops-actions { display: flex; justify-content: flex-end; gap: 9px; margin-top: 20px; }
.muted { color: var(--ink3); font-size: 12px; }
.branch-layout { display: flex; flex-direction: column; gap: 12px; }
.branch-create { display: flex; gap: 10px; }
.branch-create .invalid { --el-input-border-color: var(--bad); }
.field-error { margin: -4px 0 0; color: var(--bad); font-size: 11px; }
.branch-list { min-height: 0; overflow: auto; }
h3 { margin: 15px 0 8px; font-size: 13px; color: var(--ink2); }
.branch-row { width: 100%; display: flex; justify-content: space-between; align-items: center; padding: 11px 12px; border: 0; border-bottom: 1px solid var(--line); background: transparent; color: var(--ink); text-align: left; cursor: pointer; }
.branch-row:hover:not(:disabled) { background: var(--bg-soft); }
.branch-row:disabled { cursor: default; }
.branch-row span:first-child { display: flex; flex-direction: column; gap: 3px; }
.branch-row small, .row-action { color: var(--ink3); font-size: 11px; }
.remote-heading { margin-top: 20px; }
.log-layout { display: flex; flex-direction: column; gap: 14px; }
.log-toolbar { display: flex; align-items: center; gap: 16px; }
.log-columns { display: grid; min-height: 0; flex: 1; grid-template-columns: minmax(250px, 42%) 1fr; border: 1px solid var(--line); border-radius: 8px; overflow: hidden; }
.log-list { min-height: 0; overflow: auto; border-right: 1px solid var(--line); }
.log-row { width: 100%; display: grid; grid-template-columns: 54px 1fr; gap: 9px; padding: 11px; border: 0; border-bottom: 1px solid var(--line); background: transparent; color: var(--ink); text-align: left; cursor: pointer; }
.log-row.selected, .log-row:hover { background: var(--bg-soft); }
.hash, .detail-heading code { color: var(--accent); font: 11px ui-monospace, SFMono-Regular, Menlo, monospace; }
.log-main { display: flex; min-width: 0; flex-direction: column; gap: 3px; }
.log-main b { overflow: hidden; font-size: 12px; text-overflow: ellipsis; white-space: nowrap; }
.log-main small { color: var(--ink3); font-size: 10px; }
.log-main .refs { color: var(--accent); }
.load-more { width: 100%; }
.log-detail { min-width: 0; min-height: 0; overflow: auto; padding: 15px; }
.detail-heading { display: flex; justify-content: space-between; gap: 12px; color: var(--ink3); font-size: 11px; }
.commit-message, .merge-preview, .context-lines { overflow: auto; padding: 12px; border-radius: 7px; background: var(--bg-soft); white-space: pre-wrap; overflow-wrap: anywhere; font: 11px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
.commit-diff { max-height: 320px; overflow: auto; padding: 7px 0; border-radius: 7px; background: var(--bg-code); font: 11px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
.commit-diff .ln { padding: 0 10px; white-space: pre-wrap; overflow-wrap: anywhere; }
.commit-diff .ln.add { background: var(--diff-add-bg); color: var(--diff-add-ink); }
.commit-diff .ln.del { background: var(--diff-del-bg); color: var(--diff-del-ink); }
.commit-diff .ln.hunk { background: var(--diff-hunk-bg); color: var(--diff-hunk-ink); }
.commit-diff .ln.ctxl { color: var(--ink2); }
.commit-diff .diff-empty { padding: 12px; text-align: center; color: var(--ink3); }
.changed-file { width: 100%; display: flex; align-items: center; gap: 8px; padding: 7px 4px; border: 0; background: transparent; color: var(--ink); text-align: left; cursor: pointer; }
.changed-file.chosen { color: var(--accent); }
.discard-layout { display: flex; flex-direction: column; }
.discard-top { display: flex; justify-content: space-between; color: var(--ink3); font-size: 12px; }
.discard-list { flex: 1; min-height: 100px; margin-top: 10px; overflow: auto; }
.discard-row { display: flex; align-items: center; gap: 9px; padding: 9px 2px; border-bottom: 1px solid var(--line); }
.discard-name { flex: 1; overflow-wrap: anywhere; font-size: 12px; }
.discard-row small { color: var(--warn, #b5781b); font-size: 10px; }
.conflict-layout { display: flex; flex-direction: column; }
.conflict-top { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; font-size: 12px; }
.conflict-top span { flex: 1; color: var(--ink3); }
.conflict-hint { margin: 0 0 10px; padding: 8px 11px; border-radius: 7px; background: var(--bg-soft); color: var(--ink2); font-size: 11.5px; }
.conflict-files { flex: none; max-height: 168px; margin-bottom: 12px; overflow: auto; border: 1px solid var(--line); border-radius: 8px; }
.conflict-file-row { width: 100%; display: flex; align-items: center; gap: 9px; padding: 9px 11px; border: 0; border-bottom: 1px solid var(--line); background: transparent; color: var(--ink); text-align: left; cursor: pointer; }
.conflict-file-row:last-child { border-bottom: 0; }
.conflict-file-row:hover, .conflict-file-row.selected { background: var(--bg-soft); }
.conflict-file-row.resolved { background: var(--ok-soft); }
.cf-name { flex: 1; overflow-wrap: anywhere; font: 11.5px ui-monospace, SFMono-Regular, Menlo, monospace; }
.cf-action { color: var(--accent); font-size: 11px; white-space: nowrap; }
.conflict-editor { min-width: 0; min-height: 0; flex: 1; padding: 12px; overflow: auto; border: 1px solid var(--line); border-radius: 8px; }
.auto-hint { margin: 8px 0 0; color: var(--ok); font-size: 11.5px; }
.conflict-editor h3 { margin-top: 7px; }
.conflict-choice { margin: 10px 0 16px; }
.choice-head { display: flex; justify-content: space-between; margin-bottom: 7px; font-size: 11px; }
.choice-head span { color: var(--ink3); }
.choice-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 7px; }
.choice-grid button { min-width: 0; padding: 9px; border: 1px solid var(--line); border-radius: 7px; background: var(--card); color: var(--ink); text-align: left; cursor: pointer; }
.choice-grid button.picked { border-color: var(--accent); box-shadow: 0 0 0 1px var(--accent); }
.choice-grid b { font-size: 11px; }
.choice-grid pre { max-height: 110px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; font: 10px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
.merge-preview { max-height: 190px; }
.merge-footer { display: flex; align-items: center; gap: 8px; padding-top: 14px; }
.merge-footer :deep(.el-input) { flex: 1; }
.compact-card { width: min(620px, 100%); align-self: center; flex: none; margin: auto; text-align: center; }
.large-icon { margin-bottom: 8px; color: var(--accent); font-size: 38px; }
.compact-card h2 { margin: 0 0 10px; font-size: 17px; }
.path-wrap { overflow-wrap: anywhere; }
.identity-alert { margin: 12px 0; text-align: left; }
.identity-alert pre { margin: 6px 0 0; padding: 8px; border-radius: 6px; background: var(--bg-soft); white-space: pre-wrap; font: 10.5px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }
.clone-card { text-align: left; }
.clone-card .ops-actions { justify-content: flex-end; }
.clone-output { max-height: 110px; }
.error-text { color: var(--danger, #c53939); font-size: 12px; }
.settings-layout { width: min(760px, 100%); align-self: center; }
.settings-layout :deep(.el-form-item) { margin-bottom: 18px; }
.settings-layout :deep(.el-form-item__content) { display: block; }
.settings-layout :deep(.el-select) { width: min(300px, 100%); }
.diagnostics { padding: 10px; border-radius: 8px; background: var(--bg-soft); }
.diagnostics p, .about span { color: var(--ink3); font-size: 11px; }
.about { display: flex; flex-direction: column; gap: 6px; }
@media (max-width: 800px) { .ops-view { padding: 12px; } .log-columns { grid-template-columns: minmax(180px, 42%) 1fr; } .choice-grid { grid-template-columns: 1fr; } }
</style>
