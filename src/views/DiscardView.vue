<script setup lang="ts">
import { computed, onMounted } from "vue";
import { useSessionStore } from "../stores/session";
import {
  useDiscardStore,
  DISCARD_LABEL,
  DISCARD_TAG,
  type DiscardStatus
} from "../stores/discard";

const session = useSessionStore();
const store = useDiscardStore();

/** 目标目录名（request.path 最后一段） */
const dirName = computed(() => {
  const p = session.request.path ?? "";
  return p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "当前目录";
});

onMounted(() => {
  const p = session.request.path;
  if (session.tauriReady && p) store.load(p);
  else if (!session.tauriReady) store.loadMock();
  else store.loadError = "未指定仓库路径";
});
</script>

<template>
  <div class="discard-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">放弃修改 · {{ dirName }}</span>
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

      <!-- 空状态：没有可放弃的修改 -->
      <div v-else-if="store.files.length === 0" class="empty">
        <div class="big">✔</div>
        没有可放弃的修改
      </div>

      <template v-else>
        <!-- 警示条（沿用原型 .hint-bar.red） -->
        <div class="hint-bar red">
          放弃的修改<b>不可恢复</b>。请勾选要放弃的文件（默认全部未勾选）。
        </div>

        <!-- 全选 -->
        <div class="chk-all">
          <el-checkbox
            :model-value="store.allChecked"
            :indeterminate="store.someChecked"
            @change="store.setAll($event as boolean)"
          >
            全选
          </el-checkbox>
        </div>

        <!-- 文件列表 -->
        <div class="file-list">
          <label v-for="f in store.files" :key="f.path" class="f-li">
            <el-checkbox v-model="f.checked" />
            <el-tag class="st" :class="'st-' + DISCARD_TAG[f.status as DiscardStatus]" size="small" round>
              {{ DISCARD_LABEL[f.status as DiscardStatus] }}
            </el-tag>
            <span class="nm">{{ f.path }}</span>
            <span v-if="f.status === 'untracked'" class="u-warn">文件将被彻底删除</span>
          </label>
        </div>

        <!-- 底部：提示 + 完成 + 放弃 -->
        <div class="win-foot">
          <span class="hint">未跟踪文件删除后无法从 Git 恢复</span>
          <el-button class="btn-cancel" @click="store.finish">完成</el-button>
          <el-button
            type="danger"
            :disabled="store.checkedCount === 0"
            :loading="store.discarding"
            @click="store.doDiscard"
          >
            {{ store.checkedCount > 0 ? `放弃 ${store.checkedCount} 个文件` : "放弃" }}
          </el-button>
        </div>
      </template>
    </div>
  </div>
</template>

<style scoped lang="scss">
.discard-window {
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

/* 警示条（沿用原型 .hint-bar.red） */
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

/* 文件列表（沿用原型 .file-list / .f-li） */
.file-list {
  flex: 1;
  min-height: 120px;
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

  .nm {
    flex: 1;
    font-family: var(--mono);
    font-size: 12.5px;
    word-break: break-all;
  }
  .u-warn {
    flex: none;
    font-size: 12px;
    color: var(--bad);
  }
}

/* 状态标签：对齐提交视图的 M/D/U 配色 */
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
}

/* 底部操作区（沿用原型 .win-foot） */
.win-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 12px;

  .hint {
    flex: 1;
    font-size: 12.5px;
    color: var(--ink3);
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

  /* 危险按钮：对齐主题 --bad */
  :deep(.el-button--danger) {
    --el-button-bg-color: var(--bad);
    --el-button-border-color: var(--bad);
    --el-button-hover-bg-color: var(--bad);
    --el-button-hover-border-color: var(--bad);
    --el-button-active-bg-color: var(--bad);
    --el-button-active-border-color: var(--bad);
    --el-button-disabled-bg-color: var(--bad);
    --el-button-disabled-border-color: var(--bad);
    font-weight: 600;
  }
}

/* 空状态（沿用原型 .empty） */
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
