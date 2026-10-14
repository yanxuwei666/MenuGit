<script setup lang="ts">
import { onMounted } from "vue";
import { useConflictStore } from "../stores/conflict";
import ConflictFileEditor from "../components/ConflictFileEditor.vue";

const store = useConflictStore();

onMounted(() => {
  store.load();
});
</script>

<template>
  <div class="conflict-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">解决冲突 · {{ store.repoName }}</span>
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

      <!-- 空态：无冲突文件且已解决集合为空 -->
      <div v-else-if="store.files.length === 0" class="empty">
        <div class="big">✔</div>
        没有待处理的冲突
      </div>

      <template v-else>
        <!-- 面板头：合并冲突徽章 + 解决进度 -->
        <div class="conf-head">
          <span class="b-pill">合并冲突</span>
          <span>
            已解决 <b>{{ store.resolvedCount }}</b> / {{ store.files.length }} 个文件
          </span>
        </div>

        <div class="hint-bar">
          逐个文件解决：为每个冲突块选择保留哪一方的内容，或保留双方。一个文件的所有冲突块都决定后自动标记为已解决。
        </div>

        <!-- 冲突文件列表 -->
        <div class="file-list">
          <div
            v-for="f in store.files"
            :key="f"
            class="f-li"
            :class="{ sel: store.activeFile === f }"
            @click="store.openEditor(f)"
          >
            <el-tag
              class="st"
              :class="store.resolved.includes(f) ? 'st-ok' : 'st-bad'"
              size="small"
              round
            >
              {{ store.resolved.includes(f) ? "已解决" : "冲突" }}
            </el-tag>
            <span class="nm">{{ f }}</span>
            <el-button
              v-if="store.resolved.includes(f)"
              size="small"
              text
              type="primary"
              @click.stop="store.reEdit(f)"
            >
              重新编辑
            </el-button>
            <el-button
              v-else
              size="small"
              text
              type="primary"
              @click.stop="store.openEditor(f)"
            >
              解决 ›
            </el-button>
          </div>
        </div>

        <!-- 三选一合并编辑器 -->
        <div class="editor-area">
          <div v-if="store.editorLoading" class="diff-empty">正在读取冲突内容…</div>
          <div v-else-if="!store.activeFile || !store.result" class="diff-empty">
            点击上方文件开始解决冲突
          </div>
          <ConflictFileEditor
            v-else
            :file="store.activeFile"
            :sections="store.result.sections"
            :choices="store.choices"
            :conflict-count="store.result.conflictCount"
            :local-label="store.localLabel"
            :theirs-label="store.theirsLabel"
            :merged-lines="store.mergedLines"
            @choose="store.makeChoice"
          />
        </div>

        <!-- 合并提交信息（预填，可编辑） -->
        <el-input
          v-model="store.message"
          type="textarea"
          :rows="2"
          class="msg-box"
          placeholder="合并提交信息…"
        />

        <!-- 底部操作区 -->
        <div class="win-foot">
          <span class="author">完成合并前，其他写操作将被锁定</span>
          <el-button class="btn-abort" @click="store.doAbort">中止合并</el-button>
          <el-button
            type="primary"
            :disabled="!store.allResolved"
            :loading="store.completing"
            @click="store.doComplete"
          >
            {{ store.completing ? "提交中…" : "完成合并提交" }}
          </el-button>
        </div>
      </template>
    </div>
  </div>
</template>

<style lang="scss">
/* 设计令牌（全局变量，非 scoped） */
@use "../styles/theme.scss";

/* ElMessageBox 挂载于 body，需全局样式：中止合并确认按钮的红色警示 */
.cf-abort-confirm {
  --el-button-bg-color: var(--bad);
  --el-button-border-color: var(--bad);
  --el-button-hover-bg-color: var(--bad);
  --el-button-hover-border-color: var(--bad);
  --el-button-active-bg-color: var(--bad);
  --el-button-active-border-color: var(--bad);
  color: #fff;
}
</style>

<style scoped lang="scss">
.conflict-window {
  height: 100%;
  display: flex;
  flex-direction: column;
  background: var(--card);
  color: var(--ink);
  font-size: 14px;
  line-height: 1.6;
}

/* 窗口标题栏（沿用 CommitView .mbar） */
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
  padding: 14px 18px 16px;
  overflow: auto;
}

/* 面板头（沿用原型 .conf-head / .b-pill） */
.conf-head {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-bottom: 10px;
  font-size: 13px;
  color: var(--ink2);
  flex: none;

  b {
    color: var(--ink);
  }
}

.b-pill {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  background: var(--bad-soft);
  color: var(--bad);
  font-weight: 700;
  border-radius: 6px;
  padding: 2px 10px;
  font-size: 12.5px;
}

/* 操作说明条 */
.hint-bar {
  flex: none;
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
  margin-bottom: 12px;
  background: var(--info-soft);
  color: var(--info);
}

/* 冲突文件列表（沿用原型 .file-list / .f-li） */
.file-list {
  flex: none;
  max-height: 190px;
  border: 1px solid var(--line);
  border-radius: 9px;
  overflow: auto;
  margin-bottom: 12px;
}

.f-li {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 7px 12px;
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
    min-width: 0;
    font-family: var(--mono);
    font-size: 12.5px;
    word-break: break-all;
  }
}

/* 状态标签：已解决（绿）/ 冲突（红） */
.st {
  flex: none;
  height: auto;
  padding: 0 8px;
  font-size: 11px;
  font-weight: 600;
  border-radius: 999px;

  &.st-ok {
    --el-tag-bg-color: var(--ok-soft);
    --el-tag-text-color: var(--ok);
    --el-tag-border-color: transparent;
  }
  &.st-bad {
    --el-tag-bg-color: var(--bad-soft);
    --el-tag-text-color: var(--bad);
    --el-tag-border-color: transparent;
  }
}

/* 编辑器区域：撑满剩余空间，内部滚动 */
.editor-area {
  flex: 1;
  min-height: 220px;
  display: flex;
  flex-direction: column;
  margin-bottom: 12px;
}

.diff-empty {
  flex: 1;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--ink3);
  font-size: 12.5px;
  border: 1px dashed var(--line);
  border-radius: 9px;
  min-height: 120px;
}

/* 合并提交信息（预填可编辑，沿用 CommitView .msg-box） */
.msg-box {
  flex: none;
  margin-bottom: 10px;

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

/* 底部操作区（沿用原型 .win-foot） */
.win-foot {
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;

  .author {
    flex: 1;
    font-size: 12.5px;
    color: var(--ink3);
  }

  /* 中止合并：红色 ghost 常驻 */
  :deep(.btn-abort) {
    background: transparent;
    border: 1px solid color-mix(in srgb, var(--bad) 45%, transparent);
    color: var(--bad);
    font-weight: 500;

    &:hover {
      background: var(--bad-soft);
      border-color: var(--bad);
      color: var(--bad);
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

/* 加载 / 失败 / 空状态（沿用原型 .empty，垂直居中） */
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
