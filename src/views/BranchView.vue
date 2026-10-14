<script setup lang="ts">
import { onMounted } from "vue";
import { useSessionStore } from "../stores/session";
import { useBranchStore } from "../stores/branch";

const store = useBranchStore();

// 进入窗口即按 CLI 目标路径加载分支列表；浏览器环境走 mock 演示数据
onMounted(() => {
  store.init(useSessionStore().request.path);
});
</script>

<template>
  <div class="branch-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">分支 · {{ store.repoName }}</span>
    </div>

    <div class="mbody">
      <!-- 加载中 / 加载失败（真实模式） -->
      <div v-if="store.loading" class="empty">
        <div class="big">…</div>
        正在读取分支列表…
      </div>
      <div v-else-if="store.loadError" class="empty">
        <div class="big err">✕</div>
        {{ store.loadError }}
      </div>

      <template v-else>
        <!-- 顶部状态条：当前分支 -->
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
            当前：{{ store.repo.branch }}
          </span>
          <span v-if="store.repo.upstream" class="ab up">{{
            store.repo.ahead > 0
              ? `领先 ${store.repo.ahead} 个提交`
              : store.repo.behind > 0
                ? `落后 ${store.repo.behind} 个提交`
                : `跟踪 ${store.repo.upstream}`
          }}</span>
        </div>

        <!-- 分支名过滤 -->
        <el-input
          v-model="store.filter"
          class="fx-filter"
          placeholder="按分支名过滤…"
          clearable
        />

        <!-- 本地分支（点击切换；当前分支置顶标"当前"徽章） -->
        <h4 class="sec-title">本地分支（点击切换）</h4>
        <div class="br-list">
          <div
            v-for="b in store.filteredLocal"
            :key="b.name"
            class="br-item"
            :class="{ currow: b.isCurrent }"
            @click="store.switchTo(b.name)"
          >
            <svg
              class="b-ic"
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
            <span class="nm">{{ b.name }}</span>
            <span v-if="b.upstream" class="up">{{ b.upstream }}</span>
            <span v-if="b.isCurrent" class="cur">当前</span>
          </div>
          <div v-if="store.filteredLocal.length === 0" class="list-empty">无匹配分支</div>
        </div>

        <!-- 远端分支：折叠区，点击检出为本地 -->
        <el-collapse class="remote-wrap">
          <el-collapse-item name="remote">
            <template #title>
              <span class="remote-title">远端分支（点击检出为本地）</span>
            </template>
            <div
              v-for="b in store.filteredRemote"
              :key="b.name"
              class="br-item"
              @click="store.checkoutRemoteBranch(b.name)"
            >
              <span class="remote-ic">☁</span>
              <span class="nm">{{ b.name }}</span>
              <span v-if="store.remoteCheckedOut(b.name)" class="has-local">本地已存在</span>
            </div>
            <div v-if="store.filteredRemote.length === 0" class="list-empty">无匹配远端分支</div>
          </el-collapse-item>
        </el-collapse>

        <!-- 新建分支（基于当前 HEAD 创建并立即切换） -->
        <div class="new-branch">
          <el-input
            v-model="store.newName"
            placeholder="新建分支名称，如 feature-search"
            :disabled="store.busy"
            @keyup.enter="store.createAndSwitch"
          />
          <el-button
            type="primary"
            :disabled="!!store.nameError || !store.newName.trim() || store.busy"
            :loading="store.busy"
            @click="store.createAndSwitch"
          >
            创建并切换
          </el-button>
        </div>
        <div v-if="store.newName.trim() && store.nameError" class="field-err">
          {{ store.nameError }}
        </div>

        <!-- 最近一次失败的详细输出（R5：原始 stderr 可展开） -->
        <el-collapse v-if="store.lastError" class="err-wrap">
          <el-collapse-item name="err">
            <template #title>
              <span class="err-title">操作失败：{{ store.lastError.message }}</span>
            </template>
            <div v-if="store.lastError.files.length" class="err-files">
              <div class="cap">受影响的文件：</div>
              <div v-for="f in store.lastError.files" :key="f" class="mono">{{ f }}</div>
            </div>
            <pre class="stderr">{{ store.lastError.stderr || "（无详细输出）" }}</pre>
          </el-collapse-item>
        </el-collapse>

        <!-- 底部：完成（返回提交视图，提交窗口状态保留） -->
        <div class="win-foot">
          <span class="author">切换分支后，新提交将落在所选分支上</span>
          <el-button
            type="primary"
            class="btn-done"
            :disabled="store.busy"
            @click="store.done"
          >
            完成
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
.branch-window {
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

/* 过滤输入框 */
.fx-filter {
  margin-bottom: 10px;

  :deep(.el-input__wrapper) {
    background: var(--bg-soft);
    border-radius: 7px;
    box-shadow: 0 0 0 1px var(--line) inset;
  }
}

/* 分区标题（沿用原型 h4） */
.sec-title {
  margin: 0 0 6px;
  font-size: 13px;
  font-weight: 600;
  color: var(--ink2);
}

/* 分支列表（沿用原型 .br-item / .cur） */
.br-list {
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: 4px;
  margin-bottom: 10px;
  overflow: auto;
}

.br-item {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 8px 12px;
  border-radius: 8px;
  cursor: pointer;
  font-size: 13.5px;

  &:hover {
    background: var(--accent-soft);
  }
  &.currow {
    cursor: default;
  }

  .b-ic {
    color: var(--ink3);
    flex: none;
  }
  .nm {
    flex: 1;
    font-family: var(--mono);
    font-size: 12.5px;
    word-break: break-all;
  }
  .up {
    font-size: 11.5px;
    color: var(--ink3);
    white-space: nowrap;
  }

  /* 当前分支徽章（沿用原型 .cur） */
  .cur {
    font-size: 10.5px;
    background: var(--ok);
    color: #fff;
    border-radius: 999px;
    padding: 0 8px;
    font-weight: 700;
  }
  .remote-ic {
    color: var(--ink3);
    font-size: 12px;
    flex: none;
  }
  .has-local {
    font-size: 11px;
    color: var(--ink3);
    white-space: nowrap;
  }
}

/* 远端分支折叠区（沿用原型 details.remote） */
.remote-wrap {
  margin-top: 2px;
  border: none;

  :deep(.el-collapse-item__header) {
    background: transparent;
    border-bottom: 1px solid var(--line);
    height: 34px;
    line-height: 34px;
  }
  :deep(.el-collapse-item__wrap) {
    background: transparent;
    border-bottom: none;
  }
  :deep(.el-collapse-item__content) {
    padding-bottom: 4px;
  }

  .remote-title {
    font-size: 12.5px;
    color: var(--ink3);
  }
}

/* 新建分支（沿用原型 .new-branch / .field-err） */
.new-branch {
  display: flex;
  gap: 8px;
  margin-top: 14px;
  padding-top: 14px;
  border-top: 1px solid var(--line);

  :deep(.el-input__wrapper) {
    background: var(--bg-soft);
    border-radius: 7px;
    box-shadow: 0 0 0 1px var(--line) inset;
  }

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

.field-err {
  color: var(--bad);
  font-size: 12px;
  margin-top: 4px;
}

/* 错误详情折叠区（原始 stderr） */
.err-wrap {
  margin-top: 10px;
  border: 1px solid #efb2aa;
  border-radius: 8px;

  :deep(.el-collapse-item__header) {
    background: var(--bad-soft);
    height: 34px;
    line-height: 34px;
    padding: 0 10px;
    border-bottom-color: #efb2aa;
  }
  :deep(.el-collapse-item__wrap) {
    background: var(--bad-soft);
    border-bottom: none;
  }
  :deep(.el-collapse-item__content) {
    padding: 8px 12px;
  }

  .err-title {
    font-size: 12.5px;
    color: var(--bad);
  }
}

.err-files {
  margin-bottom: 8px;

  .cap {
    font-size: 12px;
    color: var(--bad);
    font-weight: 600;
    margin-bottom: 2px;
  }
  .mono {
    font-family: var(--mono);
    font-size: 12px;
    color: var(--ink2);
  }
}

.stderr {
  margin: 0;
  font-family: var(--mono);
  font-size: 11.5px;
  line-height: 1.5;
  color: var(--ink2);
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 160px;
  overflow: auto;
}

/* 底部操作区（沿用原型 .win-foot） */
.win-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 14px;

  .author {
    flex: 1;
    font-size: 12.5px;
    color: var(--ink3);
  }

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

/* 列表空占位 */
.list-empty {
  color: var(--ink3);
  font-size: 12.5px;
  text-align: center;
  padding: 14px 0;
}

/* 加载 / 失败空状态（沿用原型 .empty） */
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
