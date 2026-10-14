<script setup lang="ts">
import { onMounted, watch } from "vue";
import { useSessionStore } from "./stores/session";
import { useCommitStore } from "./stores/commit";
import CommitView from "./views/CommitView.vue";
import PushView from "./views/PushView.vue";
import PullView from "./views/PullView.vue";
import BranchView from "./views/BranchView.vue";
import LogView from "./views/LogView.vue";
import DiscardView from "./views/DiscardView.vue";
import ConflictView from "./views/ConflictView.vue";
import InitView from "./views/InitView.vue";
import CloneView from "./views/CloneView.vue";
import SettingsView from "./views/SettingsView.vue";

const session = useSessionStore();
const commit = useCommitStore();

/** Tauri 环境：按 CLI 目标路径加载真实仓库数据；浏览器环境保持 mock 演示数据 */
function syncCommit() {
  if (session.tauriReady && session.request.path) {
    commit.load(session.request.path);
  }
}

onMounted(async () => {
  await session.init();
  syncCommit();
});

// 二次拉起（单实例转发 cli-args）时跟随新目标重载
watch(() => session.request, syncCommit);
</script>

<template>
  <CommitView v-if="session.view === 'commit'" />
  <PushView v-else-if="session.view === 'push'" />
  <PullView v-else-if="session.view === 'pull'" />
  <BranchView v-else-if="session.view === 'branch'" />
  <LogView v-else-if="session.view === 'log'" />
  <DiscardView v-else-if="session.view === 'discard'" />
  <ConflictView v-else-if="session.view === 'conflict'" />
  <InitView v-else-if="session.view === 'init'" />
  <CloneView v-else-if="session.view === 'clone'" />
  <SettingsView v-else-if="session.view === 'settings'" />
</template>
