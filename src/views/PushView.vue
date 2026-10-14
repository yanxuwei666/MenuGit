<!-- PushView.vue —— 推送面板（PRD FM-04）：本地分支 → 远端分支，极简 TortoiseGit 风格 -->
<script setup lang="ts">
import { computed, onMounted } from "vue";
import { useSessionStore } from "../stores/session";
import { useSyncStore } from "../stores/sync";

const session = useSessionStore();
const store = useSyncStore();

// 进入面板即载入仓库概要与远端分支列表（同实例内已载入同一仓库则跳过）
onMounted(() => {
  const path = session.request.path;
  if (path && store.repoPath !== path) store.load(path);
});

/** 顶部信息条：领先 n 个提交未推送时提示待推送 */
const headText = computed(() => {
  if (store.repo.ahead > 0) return `${store.repo.ahead} 个提交待推送`;
  return store.repo.upstream ? "已同步" : "未设置上游分支";
});
</script>

<template>
  <div class="sync-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">推送 · {{ store.repo.name }}</span>
    </div>

    <div class="mbody">
      <!-- 加载中 / 加载失败（真实模式） -->
      <div v-if="store.loading" class="empty">
        <div class="big">…</div>
        正在读取仓库状态…
      </div>
      <div v-else-if="store.loadError" class="empty">
        <div class="big err">✕</div>
        {{ store.loadError }}
      </div>

      <template v-else>
        <!-- 顶部信息条：当前分支 + 待推送提示 -->
        <div class="stat-head">
          <span class="b-pill">
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
          </span>
          <span class="ab up">{{ headText }}</span>
        </div>

        <!-- 本地区：当前分支只读展示 -->
        <div class="fsec">
          <h5>本地</h5>
          <div class="frow2">
            <label>分支(L)</label>
            <span class="b-pill">
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
            </span>
            <span class="ab up">{{ store.localSyncText }}</span>
          </div>
        </div>

        <!-- 目标区：默认远端 + 目标分支（可输入新名称） -->
        <div class="fsec">
          <h5>目标</h5>
          <div class="frow2">
            <label>远端(M)</label>
            <span class="b-pill origin">origin</span>
            <span class="dim">轻量版仅支持默认远端</span>
          </div>
          <div class="frow2">
            <label>分支(R)</label>
            <el-select
              v-model="store.pushTarget"
              class="br-select"
              filterable
              allow-create
              default-first-option
              :disabled="store.pushDone"
              placeholder="选择或输入目标分支…"
            >
              <el-option v-for="b in store.remoteBranches" :key="b" :label="b" :value="b" />
            </el-select>
          </div>
          <!-- 输入新名称：创建远端分支警示条 -->
          <div v-if="store.isNewTarget" class="hint-bar warn">
            将创建远端分支 origin/{{ store.pushTarget.trim() }} 并设为上游
          </div>
          <!-- 无上游：将自动设置上游 -->
          <div v-else-if="!store.hasUpstream" class="soft-hint">将自动设置上游</div>
        </div>

        <!-- 推送被拒：引导先拉取（PRD 闭环） -->
        <div v-if="store.pushRejected" class="hint-bar red reject-row">
          <span>远端有新提交，请先拉取</span>
          <el-button size="small" :loading="store.pulling" @click="store.pullNow">
            立即拉取
          </el-button>
        </div>

        <!-- 进行中状态文字（推送 / 立即拉取共用） -->
        <div v-if="store.pushing || store.pulling" class="soft-hint running">
          {{ store.pulling ? store.pullStatus : store.pushStatus }}
        </div>

        <!-- 成功：已同步 -->
        <div v-if="store.pushDone" class="sync-ok">✔ 已同步</div>

        <!-- 底部操作区 -->
        <div class="win-foot">
          <span class="author">凭证来自系统 Git 配置</span>
          <el-button
            v-if="!store.pushDone"
            class="btn-cancel"
            :disabled="store.pushing || store.pulling"
            @click="store.cancel"
          >
            取消
          </el-button>
          <el-button v-if="store.pushDone" type="primary" @click="store.cancel">完成</el-button>
          <el-button
            v-else
            type="primary"
            :loading="store.pushing"
            :disabled="!store.canPush"
            @click="store.doPush"
          >
            {{ store.pushing ? "推送中…" : "推送" }}
          </el-button>
        </div>
      </template>
    </div>
  </div>
</template>

<style lang="scss">
/* 设计令牌（全局变量，非 scoped；单独拉起本窗口时也需加载） */
@use "../styles/theme.scss";
</style>

<style scoped lang="scss">
.sync-window {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: var(--card);
  color: var(--ink);
  font-size: 14px;
  line-height: 1.6;
}

/* 窗口标题栏（沿用原型 .mbar） */
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

  /* origin 固定远端徽章（沿用原型灰底样式） */
  &.origin {
    background: var(--line);
    color: var(--ink2);
  }
}

.ab {
  font-weight: 600;

  &.up {
    color: var(--ok);
  }
}

/* 分组区块（沿用原型 .fsec / .frow2） */
.fsec {
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: 10px 12px;
  margin-bottom: 12px;

  h5 {
    margin: 0 0 8px;
    font-size: 12px;
    color: var(--ink3);
    font-weight: 600;
  }
}

.frow2 {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 8px;

  &:last-child {
    margin-bottom: 0;
  }

  label {
    width: 64px;
    flex: none;
    font-size: 12.5px;
    color: var(--ink2);
    text-align: right;
  }

  .dim {
    font-size: 12px;
    color: var(--ink3);
  }
}

/* 远端分支下拉：对齐原型输入框观感 */
.br-select {
  flex: 1;

  :deep(.el-select__wrapper) {
    background: var(--bg-soft);
    border-radius: 7px;
    box-shadow: 0 0 0 1px var(--line) inset;
    min-height: 32px;
    font-size: 13.5px;
  }
}

/* 提示条（沿用原型 .hint-bar） */
.hint-bar {
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
  margin-top: 10px;

  &.red {
    background: var(--bad-soft);
    color: var(--bad);
    border: 1px solid #efb2aa;
  }
  &.warn {
    background: var(--warn-soft);
    color: var(--warn);
    border: 1px solid #ecd9b0;
  }
}

/* 推送被拒：红色提示条 + 立即拉取按钮 */
.reject-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  margin-bottom: 12px;
}

/* 软提示（沿用原型 .soft-hint） */
.soft-hint {
  font-size: 12px;
  color: var(--warn);
  margin-top: 4px;

  &.running {
    color: var(--accent);
  }
}

/* 成功状态条：已同步 */
.sync-ok {
  margin-top: 2px;
  padding: 8px 12px;
  border-radius: 8px;
  background: var(--ok-soft);
  color: var(--ok);
  font-weight: 600;
  font-size: 13px;
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

/* 加载 / 失败空状态（沿用原型 .empty，垂直居中） */
.empty {
  margin: auto;
  padding: 40px 0;
  text-align: center;
  color: var(--ink3);

  .big {
    font-size: 34px;
    margin-bottom: 8px;
    color: var(--ok);

    &.err {
      color: var(--bad);
    }
  }
}
</style>
