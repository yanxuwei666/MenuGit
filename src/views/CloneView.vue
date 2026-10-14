<script setup lang="ts">
import { computed, onBeforeUnmount } from "vue";
import { useSessionStore } from "../stores/session";
import { useRepoOpsStore } from "../stores/repoops";

const session = useSessionStore();
const store = useRepoOpsStore();

/** 父目录名（request.path 最后一段；克隆入口为普通目录） */
const dirName = computed(() => {
  const p = session.request.path ?? "";
  return p.replace(/[\\/]+$/, "").split(/[\\/]/).pop() || "当前目录";
});

// 离开页面时清理进度订阅
onBeforeUnmount(() => store.dispose());
</script>

<template>
  <div class="clone-window">
    <!-- 窗口标题栏 -->
    <div class="mbar">
      <span class="t">克隆仓库到此处</span>
    </div>

    <div class="mbody">
      <!-- 表单阶段 -->
      <template v-if="store.phase === 'form'">
        <div class="fld">
          <div class="lb">仓库 URL</div>
          <el-input
            :model-value="store.url"
            placeholder="https://github.com/user/repo.git"
            clearable
            :class="{ invalid: !!store.urlError }"
            @update:model-value="store.onUrlInput($event as string)"
          />
          <div v-if="store.urlError" class="field-err">{{ store.urlError }}</div>
        </div>

        <div class="fld">
          <div class="lb">目标文件夹名</div>
          <el-input v-model="store.dir" placeholder="repo" clearable />
        </div>

        <div class="fld">
          <div class="lb">父目录</div>
          <el-input :model-value="session.request.path ?? ''" readonly />
        </div>

        <div class="soft-hint">
          凭证将使用系统配置（credential helper / ssh-agent），MenuGit
          不询问、不保存账号密码
        </div>

        <div class="win-foot">
          <span class="hint">父目录：{{ dirName }}</span>
          <el-button class="btn-cancel" @click="store.backToCommit">取消</el-button>
          <el-button
            type="primary"
            :disabled="!store.canClone"
            @click="store.startCloneFlow"
          >
            克隆
          </el-button>
        </div>
      </template>

      <!-- 进行中：进度条 + 进度文本 + 取消克隆 -->
      <template v-else-if="store.phase === 'running'">
        <div class="run-head">正在克隆 {{ store.url.trim() }} …</div>
        <el-progress
          v-if="store.percent != null"
          class="prog"
          :percentage="store.percent"
        />
        <div class="prog-text">{{ store.progress?.text }}</div>

        <div class="win-foot">
          <span class="hint">目标：{{ store.targetDir || store.dir }}</span>
          <el-button class="btn-cancel" @click="store.cancelCloneRun">
            取消克隆
          </el-button>
        </div>
      </template>

      <!-- 已结束 -->
      <template v-else>
        <!-- 成功：提示 + 打开文件夹 -->
        <template v-if="!store.failed">
          <div class="empty">
            <div class="big">✔</div>
            克隆完成
          </div>
          <div class="win-foot">
            <span class="hint">{{ store.targetDir || store.dir }}</span>
            <el-button type="primary" @click="store.openTargetDir">
              打开文件夹
            </el-button>
          </div>
        </template>

        <!-- 失败：错误条 + 原始输出折叠 + 重试 -->
        <template v-else>
          <div class="hint-bar red">
            克隆失败：{{ store.failMessage }}
            <template v-if="store.authFailed">
              <br />请先在系统凭证/SSH 中配置访问权限。
            </template>
          </div>

          <el-collapse class="raw">
            <el-collapse-item title="原始输出" name="raw">
              <pre class="raw-pre">{{ store.output || "（无输出）" }}</pre>
            </el-collapse-item>
          </el-collapse>

          <div class="win-foot">
            <span class="hint"></span>
            <el-button class="btn-cancel" @click="store.backToCommit">关闭</el-button>
            <el-button type="primary" @click="store.retryClone">重试</el-button>
          </div>
        </template>
      </template>
    </div>
  </div>
</template>

<style scoped lang="scss">
.clone-window {
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

/* 表单字段 */
.fld {
  margin-bottom: 12px;

  .lb {
    font-weight: 600;
    font-size: 13.5px;
    margin-bottom: 6px;
  }

  :deep(.el-input__wrapper) {
    background: var(--bg-soft);
    border-radius: 7px;
    box-shadow: 0 0 0 1px var(--line) inset;

    &.is-focus {
      box-shadow: 0 0 0 1px var(--accent) inset;
    }
  }

  :deep(.invalid .el-input__wrapper) {
    box-shadow: 0 0 0 1px var(--bad) inset;
  }
}

.field-err {
  font-size: 12px;
  color: var(--bad);
  margin-top: 4px;
}

/* 凭证说明（沿用原型 .soft-hint） */
.soft-hint {
  font-size: 12px;
  color: var(--ink3);
  margin: 2px 0 10px;
}

/* 进行中 */
.run-head {
  font-size: 13.5px;
  font-weight: 600;
  margin-bottom: 12px;
  word-break: break-all;
}

.prog {
  margin-bottom: 10px;

  :deep(.el-progress-bar__inner) {
    background: var(--accent);
  }
}

.prog-text {
  font-family: var(--mono);
  font-size: 12.5px;
  color: var(--ink2);
  word-break: break-all;
}

/* 失败错误条（沿用原型 .hint-bar.red） */
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

/* 原始输出折叠面板 */
.raw {
  border-top: 1px solid var(--line);
  border-bottom: 1px solid var(--line);
  margin-bottom: 12px;

  :deep(.el-collapse-item__header) {
    font-size: 13px;
    color: var(--ink2);
    background: transparent;
    border-bottom: 1px solid var(--line);
  }
  :deep(.el-collapse-item__wrap) {
    background: transparent;
    border-bottom: none;
  }
}

.raw-pre {
  margin: 0;
  padding: 10px 12px;
  max-height: 180px;
  overflow: auto;
  background: var(--bg-code);
  border-radius: 8px;
  font-family: var(--mono);
  font-size: 12px;
  color: var(--ink2);
  white-space: pre-wrap;
  word-break: break-all;
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
  }
}
</style>
