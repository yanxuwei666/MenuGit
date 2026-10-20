<script setup lang="ts">
import { ref } from "vue";
import { chooseRepository, getRepoInfo, toGitError } from "../api";
import type { ViewName } from "../stores/session";
const props = defineProps<{ tauriReady: boolean }>();
const emit = defineEmits<{ open: [path: string, view?: ViewName]; settings: [] }>();
const path = ref("");
const busy = ref(false);
const error = ref("");
const ordinaryDirectory = ref(false);
async function openRepository() {
  if (!path.value.trim() || busy.value || !props.tauriReady) return;
  busy.value = true; error.value = ""; ordinaryDirectory.value = false;
  try {
    const info = await getRepoInfo(path.value.trim());
    if (!info.isRepo) {
      ordinaryDirectory.value = true;
      error.value = "这个目录还不是 Git 仓库，可以在这里初始化或克隆。";
      return;
    }
    emit("open", info.path ?? path.value.trim());
  } catch (reason) { error.value = toGitError(reason).message; }
  finally { busy.value = false; }
}
async function browse() {
  if (!props.tauriReady || busy.value) return;
  try {
    const selected = await chooseRepository();
    if (selected) { path.value = selected; await openRepository(); }
  } catch (reason) { error.value = toGitError(reason).message; }
}
</script>
<template>
  <main class="repository-picker">
    <section class="repository-card">
      <h1>打开 Git 仓库</h1>
      <p>选择一个仓库目录，查看改动、提交和推送。也可以从访达的 MenuGit 右键菜单打开。</p>
      <el-input v-model="path" placeholder="输入或粘贴仓库目录路径" @keyup.enter="openRepository" />
      <div class="repository-actions">
        <el-button :disabled="!tauriReady || busy" @click="browse">选择目录…</el-button>
        <el-button type="primary" :loading="busy" :disabled="!path.trim() || !tauriReady" @click="openRepository">打开仓库</el-button>
      </div>
      <el-alert v-if="error" :title="error" type="warning" :closable="false" />
      <div v-if="ordinaryDirectory" class="repository-actions">
        <el-button @click="emit('open', path.trim(), 'init')">在此初始化仓库</el-button>
        <el-button @click="emit('open', path.trim(), 'clone')">克隆仓库到此处</el-button>
      </div>
      <el-button link @click="emit('settings')">设置与访达集成</el-button>
    </section>
  </main>
</template>
<style scoped>
.repository-picker { height: 100%; display: grid; place-items: center; padding: 28px; background: var(--bg); color: var(--ink); }
.repository-card { width: min(560px, 100%); display: grid; gap: 18px; padding: 30px; background: var(--card); border: 1px solid var(--line); border-radius: 12px; }
h1 { margin: 0; font-size: 22px; }
p { margin: 0; color: var(--ink3); font-size: 13px; line-height: 1.7; }
.repository-actions { display: flex; gap: 10px; justify-content: flex-end; }
</style>
