<script setup lang="ts">
import { onMounted } from "vue";
import { useSettingsStore } from "../stores/settings";

const store = useSettingsStore();

onMounted(() => store.load());
</script>

<template>
  <div class="settings-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">设置 · MenuGit</span>
    </div>

    <div class="mbody">
      <!-- 加载失败（真实模式） -->
      <div v-if="store.loadError" class="hint-bar red">{{ store.loadError }}</div>

      <!-- 诊断日志 -->
      <div class="set-row">
        <div class="l">
          <b>诊断日志</b>
          <span>记录运行日志与 Git 检测结果，用于排障</span>
        </div>
        <el-switch
          :model-value="store.diagEnabled"
          :loading="store.saving"
          @change="store.setDiag($event as boolean)"
        />
      </div>

      <!-- 语言（当前版本固定中文） -->
      <div class="set-row">
        <div class="l">
          <b>语言</b>
          <span>界面显示语言</span>
        </div>
        <el-input
          class="lang"
          model-value="中文（当前版本固定）"
          disabled
          size="small"
        />
      </div>

      <!-- 关于 -->
      <div class="set-row">
        <div class="l">
          <b>关于</b>
          <span>
            MenuGit v0.1.0 · 装上就能用，右键就 Git<br />
            仅诊断日志与语言两项设置，Git 行为配置完全复用系统 Git。
          </span>
        </div>
      </div>

      <!-- 底部：完成 -->
      <div class="win-foot">
        <span class="hint"></span>
        <el-button type="primary" @click="store.backToCommit">完成</el-button>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.settings-window {
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
  padding: 10px 18px 16px;
  overflow: auto;
}

/* 加载失败提示条 */
.hint-bar.red {
  border-radius: 8px;
  padding: 8px 12px;
  font-size: 13px;
  margin-bottom: 12px;
  background: var(--bad-soft);
  color: var(--bad);
  border: 1px solid #efb2aa;
}

/* 设置行（沿用原型 .set-row） */
.set-row {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 13px 4px;
  border-bottom: 1px solid var(--line);

  &:last-of-type {
    border-bottom: none;
  }

  .l {
    flex: 1;
    min-width: 0;
  }
  .l b {
    font-size: 13.5px;
    display: block;
  }
  .l span {
    font-size: 12px;
    color: var(--ink3);
    white-space: pre-line;
  }

  .lang {
    width: 180px;

    :deep(.el-input__wrapper) {
      background: var(--bg-soft);
      border-radius: 7px;
      box-shadow: 0 0 0 1px var(--line) inset;
    }
  }
}

/* 底部操作区（沿用原型 .win-foot） */
.win-foot {
  display: flex;
  align-items: center;
  gap: 10px;
  margin-top: auto;
  padding-top: 12px;

  .hint {
    flex: 1;
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
