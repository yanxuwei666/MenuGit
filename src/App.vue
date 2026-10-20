<script setup lang="ts">
import { onMounted } from "vue";
import { useSessionStore } from "./stores/session";
import CommitView from "./views/CommitView.vue";
import PushView from "./views/PushView.vue";
import OperationsView from "./views/OperationsView.vue";
import RepositoryPicker from "./views/RepositoryPicker.vue";

const session = useSessionStore();

onMounted(() => {
  void session.init();
});
</script>

<template>
  <template v-if="session.ready">
    <RepositoryPicker
      v-if="!session.request.path && session.view !== 'settings'"
      :tauri-ready="session.tauriReady"
      @open="session.openWorkspace"
      @settings="session.setView('settings')"
    />
    <CommitView
      v-else-if="session.view === 'commit'"
      :key="session.requestId"
      :path="session.request.path"
      :file="session.request.file"
      :tauri-ready="session.tauriReady"
      @submitted="session.openPushAfterCommit"
      @choose-workspace="session.chooseWorkspace"
      @open-branch="session.setView('branch')"
      @open-conflict="session.setView('conflict')"
      @open-pull="session.setView('pull')"
      @open-log="session.setView('log')"
      @open-push="session.openPushFromCommit"
      @close="session.closeWindow"
    />
    <PushView
      v-else-if="session.view === 'push'"
      :path="session.request.path"
      :tauri-ready="session.tauriReady"
      :from-commit="session.pushFromCommit"
      :after-commit="session.afterCommit"
      :key="session.requestId"
      @return-to-commit="session.setView('commit')"
      @close="session.closeWindow"
      @open-pull="session.setView('pull')"
    />
    <OperationsView
      v-else
      :view="session.view"
      :key="session.requestId"
      :path="session.request.path"
      :file="session.request.file"
      :url="session.request.url"
      :tauri-ready="session.tauriReady"
      @navigate="session.setView"
    />
  </template>
  <div v-else class="view-placeholder">
    <el-empty description="正在读取启动参数…" />
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
