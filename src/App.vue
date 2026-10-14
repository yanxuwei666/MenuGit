<script setup lang="ts">
import { onMounted, watch } from "vue";
import { useSessionStore } from "./stores/session";
import { useCommitStore } from "./stores/commit";
import CommitView from "./views/CommitView.vue";

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
  <div v-else class="view-placeholder">
    <el-empty
      :description="`${session.view} 视图将按里程碑（M2+）逐步实现`"
    />
  </div>
</template>

<style scoped lang="scss">
.view-placeholder {
  height: 100%;
  display: flex;
  align-items: center;
  justify-content: center;
}
</style>
