<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, watch } from "vue";
import { useCommitStore, STATUS_LABEL, fileStat } from "../stores/commit";
import DiffPreview from "../components/DiffPreview.vue";

const store = useCommitStore();
const props = defineProps<{
  path?: string;
  file?: string;
  tauriReady: boolean;
}>();
const emit = defineEmits<{
  submitted: [hash: string];
  openBranch: [];
  openConflict: [];
  openPull: [];
  openLog: [];
  openPush: [];
  chooseWorkspace: [];
  close: [];
}>();

watch(
  () => [props.path, props.file, props.tauriReady] as const,
  ([path, file, tauriReady]) => {
    if (tauriReady && store.workspacePath === path) void store.refresh(file);
    else void store.initialize(path, tauriReady, file);
  },
  { immediate: true }
);

// 提交信息首行超长提示（沿用原型：建议不超过 50 字符，不强制）
const firstLineTooLong = computed(() => store.message.split("\n")[0].length > 50);

// 初始化主题：跟随系统深浅色偏好写入 data-theme
onMounted(() => {
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  window.addEventListener("keydown", onKeydown);
});
onBeforeUnmount(() => {
  window.removeEventListener("keydown", onKeydown);
});

// Ctrl/Cmd + A 全选（输入框聚焦时不拦截，沿用原型）
function onKeydown(e: KeyboardEvent) {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "a") {
    const tag = (document.activeElement?.tagName ?? "").toUpperCase();
    if (tag === "INPUT" || tag === "TEXTAREA") return;
    e.preventDefault();
    store.setAll(!store.allChecked);
  }
}

async function submit() {
  const hash = await store.doCommit();
  if (hash && props.tauriReady) emit("submitted", hash);
}

function cancel() {
  store.resetForm();
  emit("close");
}
</script>

<template>
  <div class="commit-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">提交 · {{ store.repo.name }}</span>
      <div class="workspace-actions">
        <el-button size="small" :disabled="store.loading || store.committing" @click="store.refresh(props.file)">刷新</el-button>
        <el-button size="small" :disabled="store.committing" @click="emit('chooseWorkspace')">选择仓库</el-button>
      </div>
    </div>

    <div class="mbody">
      <!-- 工作区干净：空状态（文案参照原型） -->
      <div v-if="store.loading" class="empty">
        <div class="big">…</div>
        正在读取仓库状态…
      </div>
      <div v-else-if="store.loadError" class="empty">
        <div class="big">!</div>
        {{ store.loadError }}
        <div class="empty-actions"><el-button @click="store.refresh(props.file)">重试</el-button><el-button @click="emit('chooseWorkspace')">选择仓库</el-button></div>
      </div>
      <div v-else-if="store.files.length === 0" class="empty">
        <div class="big">✔</div>
        工作区干净，{{
          !store.repo.upstream
            ? "尚未设置上游，等待下一次修改"
            : store.repo.ahead > 0
            ? `领先 ${store.repo.upstream} ${store.repo.ahead} 个提交`
            : `与 ${store.repo.upstream} 同步，等待下一次修改`
        }}
        <div class="empty-actions">
          <el-button size="small" @click="emit('openBranch')">分支</el-button>
          <el-button size="small" @click="emit('openPull')">拉取</el-button>
          <el-button size="small" @click="emit('openPush')">推送</el-button>
          <el-button size="small" @click="emit('openLog')">日志</el-button>
        </div>
      </div>

      <template v-else>
        <!-- 顶部状态条：分支徽章 + 与上游的同步描述 -->
        <div class="stat-head">
          <button class="b-pill" @click="emit('openBranch')" title="切换或创建分支">
            <svg
              viewBox="0 0 16 16"
              width="13"
              height="13"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              stroke-linecap="round"
            >
              <circle cx="4" cy="3.2" r="1.9" />
              <circle cx="4" cy="12.8" r="1.9" />
              <circle cx="12" cy="3.2" r="1.9" />
              <path d="M4 5.1v5.8M12 5.1c0 3-2.2 3.6-4.6 4" />
            </svg>
            {{ store.repo.branch }}
          </button>
          <span class="ab up">{{ store.syncText }}</span>
          <el-button
            v-if="store.repo.ahead > 0 && !store.hasConflict && !store.repo.mergeInProgress"
            class="push-now"
            size="small"
            @click="emit('openPush')"
          >
            ↑ 推送
          </el-button>
        </div>

        <!-- 存在冲突文件时顶部提示条 -->
        <div v-if="store.hasConflict || store.repo.mergeInProgress" class="hint-bar red">
          <template v-if="store.conflictCount > 0">
            存在 {{ store.conflictCount }} 个冲突文件，请先解决冲突再提交（冲突文件不可勾选）。
          </template>
          <template v-else>合并仍在进行，请完成或中止合并后再提交。</template>
          <el-button size="small" @click="emit('openConflict')">打开冲突处理</el-button>
        </div>

        <el-alert v-if="store.commitError" class="commit-error" type="error" :title="store.commitError.message" :closable="false" show-icon>
          <template #default>
            <details v-if="store.commitError.stderr" class="commit-error-details">
              <summary>显示 Git / hook 详细信息</summary>
              <pre>{{ store.commitError.stderr }}</pre>
            </details>
          </template>
        </el-alert>

        <!-- 文件名过滤 -->
        <el-input
          v-model="store.filter"
          class="fx-filter"
          placeholder="按文件名过滤…"
          clearable
        />

        <!-- 全选 -->
        <div class="chk-all">
          <el-checkbox
            :model-value="store.allChecked"
            :indeterminate="store.someChecked"
            @change="store.setAll($event as boolean)"
          >
            全选（Ctrl+A）<template v-if="store.filteredFiles.some((f) => f.status === 'C')">，不含冲突文件</template>
          </el-checkbox>
        </div>

        <!-- 左：变更文件列表 / 右：差异预览 -->
        <div class="c-cols">
          <div class="c-left">
            <div class="file-list">
              <div
                v-for="f in store.filteredFiles"
                :key="f.name"
                class="f-li"
                :class="{ sel: store.selected === f.name }"
                @click="store.selectFile(f.name)"
              >
                <el-checkbox
                  v-model="f.checked"
                  :disabled="f.status === 'C'"
                  @click.stop
                />
                <el-tag class="st" :class="'st-' + f.status" size="small" round>
                  {{ STATUS_LABEL[f.status] }}
                </el-tag>
                <span class="nm">{{ f.origPath ? `${f.origPath} → ${f.name}` : f.name }}</span>
                <span class="stat">{{ fileStat(f) }}</span>
              </div>
              <div v-if="store.filteredFiles.length === 0" class="diff-empty">无匹配文件</div>
            </div>
          </div>
          <div class="c-right">
            <DiffPreview :file="store.selectedFile" />
          </div>
        </div>

        <!-- 提交信息（必填） -->
        <el-input
          v-model="store.message"
          type="textarea"
          :rows="3"
          class="msg-box"
          placeholder="提交信息（必填）…"
        />
        <div v-if="firstLineTooLong" class="soft-hint">
          提示：首行建议不超过 50 字符（不强制）
        </div>

        <!-- 底部：作者 + 取消 + 提交 -->
        <div class="win-foot">
          <span class="author">作者：{{ store.author }}（来自系统 Git 配置）</span>
          <el-button class="btn-cancel" @click="cancel">取消</el-button>
          <el-button
            type="primary"
            :disabled="!store.canCommit"
            :loading="store.committing"
            @click="submit"
          >
            {{ store.committing ? "提交中…" : store.checkedCount > 0 ? `提交 ${store.checkedCount} 个文件` : "提交" }}
          </el-button>
        </div>
      </template>
    </div>
  </div>
</template>

<style lang="scss">
/* 设计令牌（全局变量，非 scoped） */
@use "../styles/theme.scss";
</style>

<style scoped lang="scss">
.workspace-actions { display: flex; gap: 8px; margin-left: auto; }
.commit-window {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: var(--card);
  color: var(--ink);
  font-size: 14px;
  line-height: 1.6;
}

/* 窗口标题栏（沿用原型 .mbar，Windows 主题标题居左） */
.mbar {
  flex: none;
  display: flex;
  align-items: center;
  height: 44px;
  padding: 0 14px;
  background: var(--bg-soft);
  border-bottom: 1px solid var(--line);

  .t {
    font-weight: 600;
    font-size: 13.5px;
    color: var(--ink2);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }
}

.b-pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 5px 9px;
  border: 1px solid var(--line);
  border-radius: 999px;
  background: var(--bg-soft);
  color: var(--ink2);
  font: inherit;
  font-size: 12px;
  cursor: pointer;
}
.b-pill:hover { border-color: var(--accent); color: var(--accent); }
.commit-error { margin: 0 0 9px; }
.commit-error-details { margin-top: 8px; font-size: 11px; }
.commit-error-details pre { max-height: 140px; overflow: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
.empty-actions { display: flex; justify-content: center; flex-wrap: wrap; gap: 5px; margin-top: 14px; }

.mbody {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
  padding: 16px 18px;
  overflow: auto;
}

/* 顶部状态条（沿用原型 .stat-head / .b-pill / .ab） */
.stat-head {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 12px;
  font-size: 13px;
  color: var(--ink2);
}

.b-pill {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  background: var(--accent-soft);
  color: var(--accent);
  font-weight: 700;
  border-radius: 6px;
  padding: 2px 10px;
  font-size: 12.5px;
}

.ab {
  font-weight: 600;

  &.up {
    color: var(--ok);
  }
}

.push-now {
  margin-left: auto;
}

/* 冲突提示条（沿用原型 .hint-bar.red） */
.hint-bar {
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
  margin-bottom: 12px;

  &.red {
    background: var(--bad-soft);
    color: var(--bad);
    border: 1px solid #efb2aa;
  }
}

/* 过滤输入框 */
.fx-filter {
  margin-bottom: 10px;

  :deep(.el-input__wrapper) {
    background: var(--bg-soft);
    border-radius: 7px;
    box-shadow: 0 0 0 1px var(--line) inset;
  }
}

/* 全选行（沿用原型 .chk-all） */
.chk-all {
  display: flex;
  align-items: center;
  gap: 6px;
  font-size: 12.5px;
  color: var(--ink2);
  padding: 0 2px 8px;

  :deep(.el-checkbox__label) {
    font-size: 12.5px;
    color: var(--ink2);
  }
}

/* 左右分栏（沿用原型 .c-cols，高度自适应撑满窗口） */
.c-cols {
  flex: 1;
  min-height: 220px;
  display: flex;
  gap: 14px;
  margin-bottom: 12px;
  align-items: stretch;
}

.c-left {
  width: 290px;
  flex: none;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.c-right {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
  min-height: 0;
}

/* 变更文件列表（沿用原型 .file-list / .f-li） */
.file-list {
  flex: 1;
  min-height: 0;
  border: 1px solid var(--line);
  border-radius: 9px;
  overflow: auto;
}

.f-li {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 8px 12px;
  border-bottom: 1px solid var(--line);
  font-size: 13.5px;
  cursor: pointer;

  &:last-child {
    border-bottom: none;
  }
  &:hover {
    background: var(--bg-hover);
  }
  &.sel {
    background: var(--accent-soft);
  }

  .nm {
    flex: 1;
    font-family: var(--mono);
    font-size: 12.5px;
    word-break: break-all;
  }
  .stat {
    font-size: 12px;
    color: var(--ink3);
    font-family: var(--mono);
    white-space: nowrap;
  }
}

/* 状态标签：复用 el-tag 变量调整为原型 pill 观感 */
.st {
  flex: none;
  height: auto;
  padding: 0 8px;
  font-size: 11px;
  font-weight: 600;
  border-radius: 999px;

  &.st-M {
    --el-tag-bg-color: var(--info-soft);
    --el-tag-text-color: var(--info);
    --el-tag-border-color: transparent;
  }
  &.st-A {
    --el-tag-bg-color: var(--ok-soft);
    --el-tag-text-color: var(--ok);
    --el-tag-border-color: transparent;
  }
  &.st-D {
    --el-tag-bg-color: var(--bad-soft);
    --el-tag-text-color: var(--bad);
    --el-tag-border-color: transparent;
  }
  &.st-U {
    --el-tag-bg-color: var(--purple-soft);
    --el-tag-text-color: var(--purple);
    --el-tag-border-color: transparent;
  }
  &.st-C {
    --el-tag-bg-color: var(--bad-soft);
    --el-tag-text-color: var(--bad);
    --el-tag-border-color: #efb2aa;
  }
  &.st-R {
    --el-tag-bg-color: var(--accent-soft);
    --el-tag-text-color: var(--accent);
    --el-tag-border-color: transparent;
  }
}

/* 提交信息输入 */
.msg-box {
  :deep(.el-textarea__inner) {
    background: var(--bg-soft);
    border-radius: 8px;
    font-size: 13.5px;
    color: var(--ink);
    box-shadow: 0 0 0 1px var(--line) inset;
    resize: vertical;

    &:focus {
      box-shadow: 0 0 0 1px var(--accent) inset;
    }
  }
}

.soft-hint {
  font-size: 12px;
  color: var(--warn);
  margin-top: 4px;
}

/* 底部操作区（沿用原型 .win-foot） */
.win-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 12px;

  .author {
    flex: 1;
    font-size: 12.5px;
    color: var(--ink3);
  }

  /* 取消按钮：ghost 观感 */
  :deep(.btn-cancel) {
    background: transparent;
    border: 1px solid var(--line);
    color: var(--ink2);
    font-weight: 500;

    &:hover {
      background: var(--bg-hover);
      color: var(--ink2);
      border-color: var(--line);
    }
  }

  /* 主按钮：对齐原型强调色 */
  :deep(.el-button--primary) {
    --el-button-bg-color: var(--accent);
    --el-button-border-color: var(--accent);
    --el-button-hover-bg-color: var(--accent);
    --el-button-hover-border-color: var(--accent);
    --el-button-active-bg-color: var(--accent);
    --el-button-active-border-color: var(--accent);
    --el-button-disabled-bg-color: var(--accent);
    --el-button-disabled-border-color: var(--accent);
    font-weight: 600;
  }
}

/* 工作区干净空状态（沿用原型 .empty，垂直居中） */
.empty {
  margin: auto;
  padding: 40px 0;
  text-align: center;
  color: var(--ink3);

  .big {
    font-size: 34px;
    margin-bottom: 8px;
    color: var(--ok);
  }
}

/* 复用原型 .diff-empty 作为列表空占位 */
.diff-empty {
  color: var(--ink3);
  font-size: 12.5px;
  text-align: center;
  padding: 18px 0;
}
</style>
