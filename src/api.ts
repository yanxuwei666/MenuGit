/**
 * api.ts —— Tauri 命令的类型化封装（M2）。
 *
 * 与 src-tauri/src/ops/* 的命令一一对应；错误统一归一化为 GitErrorPayload
 * （{ kind, message, stderr }，R5：可读原因 + 可展开原始输出）。
 * 本文件只做 invoke / 事件包装，不改任何视图逻辑。
 */

import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

/** 统一错误类别（与 Rust GitErrorKind 一一对应） */
export type GitErrorKind =
  | "GitMissing"
  | "NotARepo"
  | "Network"
  | "AuthRejected"
  | "Locked"
  | "Cancelled"
  | "Other";

/** 统一错误结构 */
export interface GitErrorPayload {
  kind: GitErrorKind;
  message: string;
  stderr: string;
}

/** 把任意抛错归一化为 GitErrorPayload */
export function toGitError(e: unknown): GitErrorPayload {
  if (e && typeof e === "object" && "kind" in e && "message" in e) {
    const obj = e as Record<string, unknown>;
    return {
      kind: obj.kind as GitErrorKind,
      message: String(obj.message ?? ""),
      stderr: String(obj.stderr ?? "")
    };
  }
  return {
    kind: "Other",
    message: e instanceof Error ? e.message : String(e),
    stderr: ""
  };
}

/** invoke 包装：失败时统一抛出 GitErrorPayload */
async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>(cmd, args);
  } catch (e) {
    throw toGitError(e);
  }
}

// ---------------------------------------------------------------------------
// 数据类型（与 Rust 侧 serde 结构对应，字段为 camelCase）
// ---------------------------------------------------------------------------

/** 仓库概要信息 */
export interface RepoInfo {
  /** 仓库根目录；非仓库时为 null */
  path: string | null;
  isRepo: boolean;
  /** 当前分支；detached 时为 7 位短 hash */
  branch: string | null;
  detached: boolean;
  upstream: string | null;
  ahead: number;
  behind: number;
  /** 是否存在合并冲突状态（MERGE_HEAD） */
  mergeInProgress: boolean;
  /** 冲突文件数 */
  conflictFileCount: number;
}

/** 文件状态标签 */
export type FileStatus =
  | "added"
  | "modified"
  | "deleted"
  | "renamed"
  | "untracked"
  | "conflict";

/** 变更文件条目 */
export interface StatusFile {
  path: string;
  status: FileStatus;
  /** 重命名前的旧路径（旧名 → 新名） */
  origPath: string | null;
  /** 新增行数（二进制文件为 null） */
  added: number | null;
  /** 删除行数（二进制文件为 null） */
  deleted: number | null;
  binary: boolean;
  /** 是否有已暂存变更 */
  staged: boolean;
  untracked: boolean;
}

/** 单文件 diff 结果 */
export interface DiffResult {
  isBinary: boolean;
  text: string;
}

/** 提交结果 */
export interface CommitResult {
  hash: string;
}

/** 当前系统 Git 配置的提交身份；未配置时字段为 null */
export interface AuthorIdentity {
  name: string | null;
  email: string | null;
}

/** 可配置 HTTPS 凭据的远端（SSH / 未配置远端时为 null） */
export interface HttpsRemoteInfo {
  /** 远端名，通常是 origin */
  remote: string;
  /** 主机[:端口]，用于钥匙串匹配 */
  host: string;
  /** 远端 URL 自带用户名（通常为 null） */
  username: string | null;
}

/** 拉取结果摘要 */
export interface PullResult {
  /** 拉入的提交数（解析失败为 null） */
  commits: number | null;
  /** 更新的文件数（解析失败为 null） */
  filesChanged: number | null;
  /** 原始输出 */
  raw: string;
}

/** 分支条目 */
export interface BranchInfo {
  name: string;
  isCurrent: boolean;
  upstream: string | null;
}

/** 分支列表 */
export interface BranchList {
  current: string | null;
  local: BranchInfo[];
  remote: BranchInfo[];
}

/** 提交日志条目（time 为 epoch 秒，展示格式由前端决定） */
export interface LogEntry {
  hash: string;
  shortHash: string;
  subject: string;
  author: string;
  time: number;
  refs: string[];
}

export interface LogDetail {
  message: string;
  files: LogFile[];
}

export interface LogFile {
  status: string;
  path: string;
  oldPath: string | null;
}

/** 冲突块三选一 */
export type ConflictChoice = "local" | "theirs" | "both";

/** 冲突文件中的一段：上下文行 */
export interface ConflictSectionContext {
  type: "context";
  lines: string[];
}

/** 冲突文件中的一段：冲突块（diff3 模式下含共同祖先段） */
export interface ConflictSectionConflict {
  type: "conflict";
  local: string[];
  theirs: string[];
  base: string[] | null;
}

export type ConflictSection = ConflictSectionContext | ConflictSectionConflict;

/** 冲突文件解析结果 */
export interface ConflictFileResult {
  file: string;
  sections: ConflictSection[];
  conflictCount: number;
}

/** 冲突解决结果 */
export interface ResolveResult {
  remainingConflicts: number;
}

/** 克隆启动结果 */
export interface CloneStartResult {
  /** 用于订阅进度与取消 */
  repoKey: string;
  /** 克隆目标目录（绝对路径） */
  targetDir: string;
}

/** 克隆进度事件 payload（事件名 clone-progress） */
export interface CloneProgress {
  repoKey: string;
  /** 0-100；无百分比输出时为 null */
  percent: number | null;
  text: string;
  done: boolean;
  error: boolean;
  /** 失败原因（done=true 且 error=true 时有值） */
  message: string | null;
}

/** 应用设置 */
export interface AppSettings {
  language: "system" | "zh-CN" | "en";
  newFilesChecked: boolean;
  diagEnabled: boolean;
}

export interface Diagnostics {
  gitVersion: string | null;
  logPath: string | null;
  log: string;
}

export interface FinderIntegration {
  supported: boolean;
  bundled: boolean;
  registered: boolean;
  enabled: boolean;
  extensionPath: string | null;
  message: string;
}

// ---------------------------------------------------------------------------
// 命令封装
// ---------------------------------------------------------------------------

/** 仓库概要：根目录 / 分支 / 上游 / 领先落后 / 合并冲突状态 */
export const getRepoInfo = (path: string) => call<RepoInfo>("get_repo_info", { path });

/** 工作区变更文件列表 */
export const getStatus = (path: string) => call<StatusFile[]>("get_status", { path });

/** 单文件 diff 文本；staged=true 时对比 HEAD（暂存区差异） */
export const getDiff = (path: string, file: string, staged?: boolean) =>
  call<DiffResult>("get_diff", { path, file, staged });

/** 批量暂存（git add -A -- paths） */
export const stageFiles = (path: string, files: string[]) =>
  call<void>("stage_files", { path, files });

/** 提交（信息经 stdin 走 git commit -F -），返回新提交 hash */
export const commit = (path: string, message: string, files: string[]) =>
  call<CommitResult>("commit", { path, message, files });

/** 读取系统 Git 当前提交身份 */
export const getAuthorIdentity = (path: string) =>
  call<AuthorIdentity>("get_author_identity", { path });

/** 读取仓库的 HTTPS 远端；SSH 或未配置远端时为 null */
export const getHttpsRemote = (path: string) =>
  call<HttpsRemoteInfo | null>("get_https_remote", { path });

/** 把 HTTPS 用户名 + 密码/令牌写入 macOS 钥匙串（令牌只经 stdin，不进命令行） */
export const saveHttpsCredential = (host: string, username: string, secret: string) =>
  call<void>("save_https_credential", { host, username, secret });

/** 在系统浏览器打开 GitHub Token 创建页 */
export const openGitHubTokens = () => call<void>("open_github_tokens");

/** 推送：git push [-u] origin <branch>；branch 缺省为当前分支 */
export const push = (path: string, branch?: string, setUpstream?: boolean) =>
  call<void>("push", { path, branch, setUpstream });

/** 拉取：默认 git pull；返回摘要（提交数/文件数，解析不出时回传原始输出） */
export const pull = (path: string, branch?: string, setUpstream?: boolean) =>
  call<PullResult>("pull", { path, branch, setUpstream });

/** 列出本地 + 远端分支（含当前分支标记与上游） */
export const listBranches = (path: string) => call<BranchList>("list_branches", { path });

/** 切换分支；create=true 时新建分支（git switch -c） */
export const switchBranch = (path: string, branch: string, create?: boolean) =>
  call<void>("switch_branch", { path, branch, create });

/** 检出远端分支（git switch -t origin/<b>） */
export const checkoutRemote = (path: string, remoteBranch: string) =>
  call<void>("checkout_remote", { path, remoteBranch });

/** 提交日志（默认 200 条，滚动加载用 skip） */
export const getLog = (
  path: string,
  opts?: { all?: boolean; file?: string; skip?: number; limit?: number }
) =>
  call<LogEntry[]>("get_log", {
    path,
    all: opts?.all,
    file: opts?.file,
    skip: opts?.skip,
    limit: opts?.limit
  });

/** 读取提交完整说明与涉及文件 */
export const getLogDetail = (path: string, hash: string) =>
  call<LogDetail>("get_log_detail", { path, hash });

/** 读取提交与父提交之间的单文件差异 */
export const getCommitFileDiff = (path: string, hash: string, file: string) =>
  call<string>("get_commit_file_diff", { path, hash, file });

/** 放弃修改：已跟踪 git restore --，未跟踪 git clean -f --（调用方负责二次确认） */
export const discardChanges = (path: string, files: string[]) =>
  call<void>("discard_changes", { path, files });

/** 读取工作区冲突文件并解析为结构化块列表（三选一渲染） */
export const getConflictFile = (path: string, file: string) =>
  call<ConflictFileResult>("get_conflict_file", { path, file });

/** 按每块选择（local/theirs/both）重组写回并 git add，返回剩余未解决冲突数 */
export const resolveConflictFile = (path: string, file: string, choices: ConflictChoice[]) =>
  call<ResolveResult>("resolve_conflict_file", { path, file, choices });

/** 完成合并提交（git commit -F -），返回合并提交 hash */
export const completeMerge = (path: string, message: string) =>
  call<CommitResult>("complete_merge", { path, message });

/** 中止合并（git merge --abort） */
export const abortMerge = (path: string) => call<void>("abort_merge", { path });

/** 初始化仓库（git init），返回新仓库概要 */
export const initRepo = (path: string) => call<RepoInfo>("init_repo", { path });

/** 克隆仓库：异步执行，进度经 listenCloneProgress 订阅；返回 repoKey */
export const cloneRepo = (path: string, url: string, dir?: string) =>
  call<CloneStartResult>("clone_repo", { path, url, dir });

/** 取消克隆（终止整个 git 进程树） */
export const cancelClone = (repoKey: string) => call<void>("cancel_clone", { repoKey });

/** 在 Finder 中定位克隆完成的目录（macOS） */
export const openInFinder = (path: string) => call<void>("open_in_finder", { path });

/** 读取应用设置 */
export const getSettings = () => call<AppSettings>("get_settings");
export const chooseRepository = () => call<string | null>("choose_repository");

/** 保存应用设置（同步诊断日志开关） */
export const setSettings = (settings: AppSettings) =>
  call<void>("set_settings", { settings });

/** 读取诊断日志与 Git 版本 */
export const getDiagnostics = () => call<Diagnostics>("get_diagnostics");

/** 检查和修复 Finder 扩展，不启动访达或应用窗口 */
export const getFinderIntegration = () => call<FinderIntegration>("get_finder_integration");
export const repairFinderIntegration = () => call<FinderIntegration>("repair_finder_integration");

/** 在系统浏览器打开项目发布页 */
export const openProjectReleases = () => call<void>("open_project_releases");

/** 订阅克隆进度事件；返回取消监听函数 */
export function listenCloneProgress(
  handler: (progress: CloneProgress) => void
): Promise<UnlistenFn> {
  return listen<CloneProgress>("clone-progress", (event) => handler(event.payload));
}
