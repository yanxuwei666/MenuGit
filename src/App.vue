<script setup lang="ts">
import { onMounted } from "vue";
import { useSessionStore } from "./stores/session";
import CommitView from "./views/CommitView.vue";

const session = useSessionStore();

onMounted(() => {
  session.init();
});
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
