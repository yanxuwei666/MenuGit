<script setup lang="ts">
import { computed } from "vue";
import { useSessionStore } from "../stores/session";
import { useRepoOpsStore } from "../stores/repoops";

const session = useSessionStore();
const store = useRepoOpsStore();

/** 目标目录名（request.path 最后一段；init/clone 场景为普通目录） */
const dirName = computed(() => {
  const p = session.request.path ?? "";
  return p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "当前目录";
});
</script>

<template>
  <div class="init-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">在此初始化 Git 仓库</span>
    </div>

    <div class="mbody">
      <!-- 确认正文：目标目录 + 说明 -->
      <div class="stat-head">
        将在目录 <span class="b-pill">{{ dirName }}</span> 中创建新的 Git 仓库
      </div>

      <div class="hint-bar info">
        初始化后即可在此目录进行提交、推送、分支等 Git 操作；身份信息取自系统
        Git 配置（user.name / user.email）。
      </div>

      <!-- 底部：路径 + 取消 + 初始化 -->
      <div class="win-foot">
        <span class="hint">{{ session.request.path ?? "" }}</span>
        <el-button class="btn-cancel" @click="store.backToCommit">取消</el-button>
        <el-button
          type="primary"
          :loading="store.initializing"
          @click="store.startInit"
        >
          初始化
        </el-button>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.init-window {
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

/* 顶部确认行（沿用原型 .stat-head / .b-pill） */
.stat-head {
  display: flex;
  align-items: center;
  gap: 8px;
  flex-wrap: wrap;
  margin-bottom: 12px;
  font-size: 13.5px;
  color: var(--ink);
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

/* 说明条：强调色软底 */
.hint-bar {
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
  margin-bottom: 12px;

  &.info {
    background: var(--accent-soft);
    color: var(--accent);
    border: 1px solid color-mix(in srgb, var(--accent) 30%, transparent);
  }
}

/* 底部操作区（沿用原型 .win-foot） */
.win-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: auto;

  .hint {
    flex: 1;
    font-size: 12.5px;
    color: var(--ink3);
    font-family: var(--mono);
    word-break: break-all;
  }

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
</style>
