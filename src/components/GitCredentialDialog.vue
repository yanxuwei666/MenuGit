<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { ElMessage } from "element-plus";
import { Loading } from "@element-plus/icons-vue";
import {
  getHttpsRemote,
  openGitHubTokens,
  saveHttpsCredential,
  toGitError,
  type HttpsRemoteInfo
} from "../api";

const props = defineProps<{ modelValue: boolean; path?: string }>();
const emit = defineEmits<{
  "update:modelValue": [value: boolean];
  saved: [];
}>();

const visible = computed({
  get: () => props.modelValue,
  set: (value: boolean) => emit("update:modelValue", value)
});
const remote = ref<HttpsRemoteInfo | null>(null);
const loading = ref(false);
const saving = ref(false);
const username = ref("");
const secret = ref("");
const error = ref("");
const isGitHub = computed(() =>
  remote.value?.host === "github.com" || remote.value?.host === "www.github.com"
);

async function loadRemote() {
  remote.value = null;
  error.value = "";
  secret.value = "";
  username.value = "";
  if (!props.path) {
    error.value = "没有收到仓库目录，请从 Finder 右键菜单重新打开。";
    return;
  }
  loading.value = true;
  try {
    remote.value = await getHttpsRemote(props.path);
    username.value = remote.value?.username ?? "";
    if (!remote.value) {
      error.value = "当前仓库的远端不是 HTTPS 地址（可能是 SSH），或还没有配置远端。";
    }
  } catch (reason) {
    error.value = toGitError(reason).message;
  } finally {
    loading.value = false;
  }
}

watch(
  () => props.modelValue,
  (open) => {
    if (open) void loadRemote();
    else {
      secret.value = "";
      error.value = "";
    }
  }
);

async function createToken() {
  try {
    await openGitHubTokens();
  } catch (reason) {
    ElMessage.error(toGitError(reason).message);
  }
}

async function save() {
  if (!remote.value || saving.value) return;
  const name = username.value.trim();
  if (!name || !secret.value) {
    error.value = "请填写用户名和密码 / 令牌。";
    return;
  }
  saving.value = true;
  error.value = "";
  try {
    // GitHub Token 粘贴时常带末尾空白；普通密码保持原样。
    const value = isGitHub.value ? secret.value.trim() : secret.value;
    await saveHttpsCredential(remote.value.host, name, value);
    secret.value = "";
    ElMessage.success("凭据已保存到 macOS 钥匙串");
    emit("saved");
    visible.value = false;
  } catch (reason) {
    error.value = toGitError(reason).message;
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <el-dialog
    v-model="visible"
    title="配置 HTTPS 凭据"
    width="480px"
    :close-on-click-modal="false"
    class="credential-dialog"
  >
    <div v-if="loading" class="credential-loading">
      <el-icon class="is-loading"><Loading /></el-icon>
      正在读取远端地址…
    </div>
    <template v-else-if="remote">
      <p class="credential-remote">
        远端 <b>{{ remote.remote }}</b>
        <span>{{ remote.host }}</span>
      </p>
      <p v-if="isGitHub" class="credential-hint">
        GitHub 已不接受账户登录密码。请在 GitHub 生成 Personal Access Token（classic，勾选
        <b>repo</b> 权限），粘贴到下方作为密码。配置一次后，推送和拉取都会自动使用。
      </p>
      <p v-else class="credential-hint">
        请填写该仓库的 HTTPS 用户名和密码 / 访问令牌。凭据只会保存在本机钥匙串，不会写入仓库。
      </p>
      <el-form label-position="top" @submit.prevent>
        <el-form-item :label="isGitHub ? 'GitHub 用户名' : '用户名'">
          <el-input v-model="username" :placeholder="isGitHub ? 'GitHub 账户名' : '用户名'" autocomplete="username" />
        </el-form-item>
        <el-form-item :label="isGitHub ? 'Personal Access Token' : '密码 / 访问令牌'">
          <el-input
            v-model="secret"
            type="password"
            show-password
            :placeholder="isGitHub ? '粘贴 PAT（不是账户密码）' : '密码或访问令牌'"
            autocomplete="off"
            @keyup.enter="save"
          />
        </el-form-item>
      </el-form>
      <div class="credential-actions">
        <el-button v-if="isGitHub" text type="primary" size="small" @click="createToken">
          生成 GitHub Token
        </el-button>
        <span class="credential-storage">保存在 macOS 钥匙串，仅需配置一次</span>
      </div>
      <el-alert v-if="error" type="error" :title="error" :closable="false" show-icon class="credential-error" />
    </template>
    <template v-else>
      <el-alert type="warning" :title="error || '当前无法使用 HTTPS 凭据'" :closable="false" show-icon />
      <p class="credential-hint">
        请检查仓库的远端地址。若使用 SSH，请确认本机 SSH 密钥已添加到 GitHub；也可以把远端改为
        <code>https://github.com/用户名/仓库.git</code> 后重试。
      </p>
    </template>
    <template #footer>
      <el-button @click="visible = false">取消</el-button>
      <el-button type="primary" :loading="saving" :disabled="!remote" @click="save">保存并重试</el-button>
    </template>
  </el-dialog>
</template>

<style scoped lang="scss">
.credential-loading {
  display: flex;
  align-items: center;
  gap: 8px;
  color: var(--ink3);
  font-size: 13px;
}
.credential-remote {
  margin: 0 0 12px;
  color: var(--ink2);
  font-size: 13px;
}
.credential-remote span {
  margin-left: 8px;
  color: var(--ink3);
}
.credential-hint {
  margin: 0 0 14px;
  color: var(--ink3);
  font-size: 12px;
  line-height: 1.7;
}
.credential-actions {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  margin-top: -4px;
}
.credential-storage {
  color: var(--ink3);
  font-size: 12px;
}
.credential-error {
  margin-top: 14px;
}
</style>
