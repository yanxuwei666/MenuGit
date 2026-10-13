<script setup lang="ts">
import type { ChangeFile } from "../stores/commit";
import { fileStat } from "../stores/commit";

defineProps<{
  /** 当前选中文件；null 时显示引导占位 */
  file: ChangeFile | null;
}>();
</script>

<template>
  <div class="diff-wrap">
    <!-- 标题行：选中文件名 + 统计；未选中显示默认文案（沿用原型） -->
    <div class="diff-title">
      <template v-if="file">
        <b>{{ file.name }}</b>
        <span>{{
          file.status === "D" ? "文件已删除" : file.binary ? "二进制文件" : fileStat(file)
        }}</span>
      </template>
      <span v-else>差异预览</span>
    </div>

    <div class="diff">
      <!-- 未选中文件：引导占位 -->
      <div v-if="!file" class="diff-empty">点击左侧文件查看差异</div>
      <!-- 二进制文件：不支持内容对比 -->
      <div v-else-if="file.binary" class="diff-empty">二进制文件，不支持内容对比</div>
      <!-- 逐行渲染 diff：hunk 头 / 上下文 / 新增 / 删除 -->
      <template v-else>
        <div v-for="(ln, i) in file.diff" :key="i" class="ln" :class="ln.type">{{ ln.text }}</div>
      </template>
    </div>
  </div>
</template>

<style scoped lang="scss">
.diff-wrap {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.diff-title {
  font-size: 12px;
  color: var(--ink3);
  padding: 0 2px 6px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  min-height: 24px;
  flex: none;

  b {
    color: var(--ink2);
    font-family: var(--mono);
    font-size: 12px;
    word-break: break-all;
  }
}

.diff {
  flex: 1;
  min-height: 120px;
  background: var(--bg-code);
  border: 1px solid var(--line);
  border-radius: 9px;
  padding: 8px 0;
  font-family: var(--mono);
  font-size: 12.5px;
  line-height: 1.55;
  overflow: auto;
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
</style>
