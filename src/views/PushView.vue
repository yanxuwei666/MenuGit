<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { ElMessage, ElMessageBox } from "element-plus";
import { getStatus, listBranches, push as pushRepo, toGitError } from "../api";
import { useCommitStore } from "../stores/commit";

const props = defineProps<{ path?: string; tauriReady: boolean; fromCommit: boolean; afterCommit: boolean }>();
const emit = defineEmits<{ returnToCommit: []; close: []; openPull: [] }>();
const store = useCommitStore();
const pushing = ref(false);
const pushed = ref(false);
const errorMessage = ref("");
const errorDetails = ref("");
const destination = ref("");
const setUpstream = ref(false);
const remoteBranches = ref<string[]>([]);
const successText = ref("");
const suggestedDestination = computed(() => store.repo.upstream?.startsWith("origin/")
  ? store.repo.upstream.slice("origin/".length)
  : /^[0-9a-f]{7,40}$/i.test(store.repo.branch) ? "" : store.repo.branch);

/** 允许用户直接输入 origin/xxx；实际 ref 只保留分支名。 */
function normalizeDestination(value: string): string {
  return value.trim().replace(/^origin\//, "").replace(/^refs\/heads\//, "");
}
const normalizedDestination = computed(() => normalizeDestination(destination.value));
function validBranchName(name: string): boolean {
  return Boolean(name)
    && !name.startsWith("-")
    && !name.includes("..")
    && !name.includes("@{")
    && !name.startsWith("/")
    && !name.endsWith("/")
    && !name.endsWith(".")
    && !name.endsWith(".lock")
    && !/[\s\u4e00-\u9fa5]/.test(name)
    && /^[A-Za-z0-9_\-/.]+$/.test(name);
}
const destinationError = computed(() =>
  normalizedDestination.value && !validBranchName(normalizedDestination.value)
    ? "分支名不能含空格、中文或特殊字符"
    : ""
);
const isNewTarget = computed(() =>
  Boolean(normalizedDestination.value) && !remoteBranches.value.includes(normalizedDestination.value)
);
function normalizeDestinationField() {
  if (destination.value !== normalizedDestination.value) {
    destination.value = normalizedDestination.value;
  }
}

watch(
  () => [props.path, props.tauriReady] as const,
  async ([path, tauriReady]) => {
    if (!tauriReady) return;
    if (store.workspacePath === path) await store.refresh();
    else await store.initialize(path, true);
    if (!path) return;
    try {
      const branches = await listBranches(path);
      remoteBranches.value = branches.remote
        .map((branch) => branch.name)
        .filter((name) => name.startsWith("origin/"))
        .map((name) => name.slice("origin/".length));
      destination.value = suggestedDestination.value;
      setUpstream.value = !store.repo.upstream;
    } catch (reason) {
      const gitError = toGitError(reason);
      errorMessage.value = gitError.message;
      errorDetails.value = gitError.stderr;
    }
  },
  { immediate: true }
);

async function finishOrReturn() {
  if (!props.fromCommit) {
    emit("close");
    return;
  }
  if (!props.path || !props.tauriReady) {
    emit("returnToCommit");
    return;
  }
  if (!props.afterCommit) {
    await store.refresh();
    emit("returnToCommit");
    return;
  }
  try {
    const remaining = await getStatus(props.path);
    if (remaining.length > 0) {
      await store.refresh(undefined, { resetChecks: true });
      emit("returnToCommit");
      return;
    }
    emit("close");
  } catch (reason) {
    const gitError = toGitError(reason);
    errorMessage.value = gitError.message;
    errorDetails.value = gitError.stderr;
    await store.refresh();
  }
}

async function pushNow() {
  if (!props.path || pushing.value) return;
  const target = normalizedDestination.value;
  if (!target || !validBranchName(target)) {
    if (destinationError.value) ElMessage.warning(destinationError.value);
    return;
  }
  errorMessage.value = "";
  errorDetails.value = "";
  const isNew = isNewTarget.value;
  if (isNew) {
    try {
      await ElMessageBox.confirm(
        `将创建远端分支 origin/${target} 并设为当前分支上游。`,
        "推送到新远端分支",
        { confirmButtonText: "继续推送", cancelButtonText: "取消" }
      );
    } catch {
      return;
    }
  }
  pushing.value = true;
  try {
    // 新建远端分支必须建立跟踪，否则后续领先/落后状态无法显示。
    await pushRepo(props.path, target, setUpstream.value || isNew);
    await store.refresh(undefined, { resetChecks: true });
    successText.value = `已推送到 origin/${target}`;
    pushed.value = true;
    ElMessage.success(successText.value);
    if (props.fromCommit) await finishOrReturn();
  } catch (reason) {
    const gitError = toGitError(reason);
    errorMessage.value = gitError.message;
    errorDetails.value = gitError.stderr;
  } finally {
    pushing.value = false;
  }
}
</script>

<template>
  <main class="push-view">
    <section class="push-card">
      <div v-if="pushed" class="success-mark">✓</div>
      <h1>{{ pushed ? "推送完成" : afterCommit ? "本地提交已完成" : "推送本地提交" }}</h1>
      <p class="summary">分支 <b>{{ store.repo.branch }}</b> · {{ store.syncText }}</p>
      <p v-if="successText" class="success-text">{{ successText }}</p>
      <template v-if="!pushed">
        <el-form label-position="top" class="push-form">
          <el-form-item label="推送到 origin" :error="destinationError">
            <el-select
              v-model="destination"
              filterable
              allow-create
              default-first-option
              placeholder="远端分支名"
              @change="normalizeDestinationField"
              @blur="normalizeDestinationField"
            >
              <el-option v-for="branch in remoteBranches" :key="branch" :label="`origin/${branch}`" :value="branch" />
            </el-select>
          </el-form-item>
          <el-checkbox v-if="!isNewTarget" v-model="setUpstream">设为当前分支的上游</el-checkbox>
        </el-form>
        <p v-if="normalizedDestination && !destinationError" class="hint">
          <template v-if="isNewTarget">目标远端不存在，将<b>创建 origin/{{ normalizedDestination }}</b>并设为当前分支上游。</template>
          <template v-else>将推送到已存在的 <b>origin/{{ normalizedDestination }}</b>。</template>
        </p>
        <p v-else-if="!store.repo.upstream" class="hint">当前分支还没有上游，推送后会建立跟踪。</p>
      </template>
      <el-alert v-if="errorMessage" class="error" type="error" :title="errorMessage" :closable="false" show-icon>
        <template #default><el-button v-if="errorMessage.includes('先拉取') || errorDetails.includes('rejected')" size="small" @click="emit('openPull')">立即拉取</el-button></template>
      </el-alert>
      <details v-if="errorDetails" class="details"><summary>显示 Git 详细信息</summary><pre>{{ errorDetails }}</pre></details>
      <div class="actions">
        <el-button :disabled="pushing" @click="finishOrReturn">{{ pushed ? "完成" : "取消" }}</el-button>
        <el-button v-if="!pushed" type="primary" :loading="pushing" :disabled="!normalizedDestination || Boolean(destinationError)" @click="pushNow">{{ pushing ? "推送中…" : "立即推送" }}</el-button>
      </div>
    </section>
  </main>
</template>

<style scoped lang="scss">
.push-view { height: 100%; display: grid; place-items: center; padding: 28px; overflow: auto; background: var(--bg); color: var(--ink); }
.push-card { width: min(500px, 100%); padding: 30px; border: 1px solid var(--line); border-radius: 14px; background: var(--card); box-shadow: 0 12px 38px rgb(20 35 55 / 9%); text-align: center; }
.success-mark { width: 42px; height: 42px; display: grid; place-items: center; margin: 0 auto 12px; border-radius: 50%; background: var(--ok-soft); color: var(--ok); font-size: 22px; font-weight: 700; }
h1 { margin: 0; font-size: 19px; }
.summary, .hint, .success-text { margin: 12px 0 0; color: var(--ink2); font-size: 13px; }
.hint { color: var(--ink3); }
.success-text { color: var(--ok); font-weight: 600; }
.push-form { margin-top: 18px; text-align: left; }
.push-form :deep(.el-select) { width: 100%; }
.error { margin-top: 18px; text-align: left; }
.details { margin-top: 10px; color: var(--ink3); font-size: 12px; text-align: left; }
.details pre { max-height: 180px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
.actions { display: flex; justify-content: center; gap: 10px; margin-top: 24px; }
</style>
