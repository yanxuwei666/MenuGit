<script setup lang="ts">
import { onMounted } from "vue";
import { useSessionStore } from "../stores/session";
import { useLogStore, relTime, refKind, changeKind } from "../stores/log";

const store = useLogStore();

// 进入窗口即按 CLI 目标路径加载日志；浏览器环境走 mock 演示数据
onMounted(() => {
  store.init(useSessionStore().request.path);
});

/** 列表滚动：接近底部时自动追加下一页（skip 分页） */
function onScroll(e: Event) {
  const el = e.target as HTMLElement;
  if (el.scrollTop + el.clientHeight >= el.scrollHeight - 40) {
    store.loadMore();
  }
}
</script>

<template>
  <div class="log-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">日志 · {{ store.repoName }}</span>
    </div>

    <div class="mbody">
      <!-- 加载中 / 加载失败（真实模式） -->
      <div v-if="store.loading" class="empty">
        <div class="big">…</div>
        正在读取提交日志…
      </div>
      <div v-else-if="store.loadError" class="empty">
        <div class="big err">✕</div>
        {{ store.loadError }}
      </div>

      <!-- 空仓库空态（文案按 PRD） -->
      <div v-else-if="store.entries.length === 0" class="empty">
        <div class="big">✔</div>
        还没有提交，去完成第一次提交吧
      </div>

      <template v-else>
        <!-- 顶部：过滤 + 所有分支开关 -->
        <div class="log-toolbar">
          <el-input
            v-model="store.filter"
            class="fx-filter"
            placeholder="按提交信息或作者过滤…"
            clearable
          />
          <el-checkbox :model-value="store.all" @change="store.toggleAll">
            显示所有分支
          </el-checkbox>
        </div>

        <!-- 提交列表（滚动到底自动追加） -->
        <div class="log-list" @scroll="onScroll">
          <div v-for="c in store.filtered" :key="c.hash" class="log-li">
            <div class="log-row" @click="store.toggleExpand(c.hash)">
              <span class="h">{{ c.shortHash }}</span>
              <span class="m">{{ c.subject }}</span>
              <span
                v-for="r in c.refs"
                :key="r"
                class="lb"
                :class="refKind(r)"
              >{{ r }}</span>
              <span class="a">{{ c.author }}</span>
              <span class="tm">{{ relTime(c.time) }}</span>
            </div>

            <!-- 展开详情：完整信息 + 变更文件 + 单文件差异 -->
            <div v-if="store.expanded === c.hash" class="log-detail">
              <div class="full">{{ store.fullMessage }}</div>

              <div v-if="store.filesLoading" class="detail-hint">正在读取变更文件…</div>
              <div v-else-if="store.files.length === 0" class="detail-hint">该提交没有变更文件</div>
              <div v-else class="chips">
                <span
                  v-for="f in store.files"
                  :key="f.path"
                  class="fchip"
                  :class="{ sel: store.selectedFile === f.path }"
                  @click.stop="store.selectFile(f)"
                >
                  <i class="ch" :class="'ch-' + changeKind(f.change)">{{ f.change }}</i>
                  {{ f.origPath ? `${f.origPath} → ${f.path}` : f.path }}
                </span>
              </div>

              <!-- 该提交的差异预览（对比其父提交；首个提交对比空树） -->
              <div v-if="store.selectedFile" class="diff">
                <div v-if="store.diffLoading" class="diff-empty">正在加载差异…</div>
                <div v-else-if="store.fileBinary" class="diff-empty">
                  二进制文件，不支持内容对比
                </div>
                <template v-else>
                  <div
                    v-for="(ln, i) in store.fileDiff"
                    :key="i"
                    class="ln"
                    :class="ln.type"
                  >{{ ln.text }}</div>
                </template>
              </div>
              <div v-else class="detail-hint">点击文件查看该提交的差异</div>
            </div>
          </div>

          <div v-if="store.filtered.length === 0" class="list-empty">无匹配提交</div>
          <div v-if="store.loadingMore" class="list-empty">正在加载更多…</div>
          <div v-else-if="!store.hasMore && store.entries.length > 0" class="list-empty">
            已加载全部 {{ store.entries.length }} 条提交
          </div>
        </div>

        <!-- 最近一次失败的详细输出（R5：原始 stderr 可展开） -->
        <el-collapse v-if="store.lastError" class="err-wrap">
          <el-collapse-item name="err">
            <template #title>
              <span class="err-title">操作失败：{{ store.lastError.message }}</span>
            </template>
            <pre class="stderr">{{ store.lastError.stderr || "（无详细输出）" }}</pre>
          </el-collapse-item>
        </el-collapse>

        <!-- 底部：完成（返回提交视图，提交窗口状态保留） -->
        <div class="win-foot">
          <span class="author">共 {{ store.entries.length }} 条提交</span>
          <el-button type="primary" class="btn-done" @click="store.done">完成</el-button>
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
.log-window {
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
  overflow: hidden;
}

/* 顶部工具条：过滤 + 所有分支开关 */
.log-toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  margin-bottom: 10px;
  flex: none;

  .fx-filter {
    flex: 1;

    :deep(.el-input__wrapper) {
      background: var(--bg-soft);
      border-radius: 7px;
      box-shadow: 0 0 0 1px var(--line) inset;
    }
  }

  :deep(.el-checkbox__label) {
    font-size: 12.5px;
    color: var(--ink2);
  }
}

/* 提交列表（沿用原型 .log-li / .log-row） */
.log-list {
  flex: 1;
  min-height: 0;
  overflow: auto;
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: 4px 6px;
}

.log-li {
  border-bottom: 1px solid var(--line);

  &:last-child {
    border-bottom: none;
  }
}

.log-row {
  display: flex;
  align-items: baseline;
  gap: 10px;
  padding: 9px 10px;
  cursor: pointer;
  border-radius: 7px;
  flex-wrap: wrap;

  &:hover {
    background: var(--bg-hover);
  }

  .h {
    font-family: var(--mono);
    font-size: 12px;
    color: var(--accent);
    font-weight: 700;
  }
  .m {
    flex: 1;
    font-size: 13.5px;
    min-width: 160px;
    word-break: break-all;
  }
  .a,
  .tm {
    font-size: 12px;
    color: var(--ink3);
    white-space: nowrap;
  }
}

/* refs 徽章（沿用原型 .lb.head/.br/.org） */
.lb {
  font-size: 10.5px;
  font-weight: 700;
  border-radius: 999px;
  padding: 0 8px;
  white-space: nowrap;

  &.head {
    background: var(--accent);
    color: #fff;
  }
  &.br {
    background: var(--info-soft);
    color: var(--info);
  }
  &.org {
    background: var(--purple-soft);
    color: var(--purple);
  }
  &.tag {
    background: var(--warn-soft);
    color: var(--warn);
  }
}

/* 展开详情（沿用原型 .log-detail / .full / .fchip） */
.log-detail {
  background: var(--bg-soft);
  border-radius: 8px;
  padding: 10px 14px;
  margin: 0 6px 10px;
  font-size: 13px;

  .full {
    color: var(--ink2);
    margin-bottom: 8px;
    white-space: pre-wrap;
    word-break: break-word;
  }
}

.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-bottom: 8px;
}

/* 变更文件 chip：状态字母 + 路径（重命名显示 旧名 → 新名） */
.fchip {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  font-family: var(--mono);
  font-size: 12px;
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: 6px;
  padding: 1px 8px;
  cursor: pointer;
  word-break: break-all;

  &:hover {
    border-color: var(--accent);
    color: var(--accent);
  }
  &.sel {
    border-color: var(--accent);
    color: var(--accent);
    background: var(--accent-soft);
  }

  .ch {
    font-style: normal;
    font-weight: 700;
    font-size: 11px;

    &.ch-A {
      color: var(--ok);
    }
    &.ch-M {
      color: var(--info);
    }
    &.ch-D {
      color: var(--bad);
    }
    &.ch-R {
      color: var(--purple);
    }
    &.ch-x {
      color: var(--ink3);
    }
  }
}

/* 该提交的差异预览（行样式与 DiffPreview 一致） */
.diff {
  background: var(--bg-code);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 8px 0;
  font-family: var(--mono);
  font-size: 12.5px;
  line-height: 1.55;
  overflow: auto;
  max-height: 260px;
}

.ln {
  padding: 0 14px;
  white-space: pre-wrap;
  word-break: break-all;

  &.add {
    background: var(--diff-add-bg);
    color: var(--diff-add-ink);
  }
  &.del {
    background: var(--diff-del-bg);
    color: var(--diff-del-ink);
  }
  &.hunk {
    color: var(--diff-hunk-ink);
    background: var(--diff-hunk-bg);
    font-size: 11.5px;
  }
  &.ctxl {
    color: var(--ink2);
  }
}

.diff-empty {
  color: var(--ink3);
  font-size: 12.5px;
  text-align: center;
  padding: 18px 0;
}

.detail-hint {
  color: var(--ink3);
  font-size: 12px;
  padding-top: 2px;
}

.list-empty {
  color: var(--ink3);
  font-size: 12.5px;
  text-align: center;
  padding: 14px 0;
}

/* 错误详情折叠区（原始 stderr） */
.err-wrap {
  flex: none;
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
  flex: none;
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: 12px;

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

/* 空仓库 / 加载空状态（沿用原型 .empty） */
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
