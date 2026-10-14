<script setup lang="ts">
import { computed, reactive, watch } from "vue";
import type { ConflictChoice, ConflictSection } from "../api";

const props = defineProps<{
  /** 冲突文件路径（标题展示用） */
  file: string;
  /** 文件解析出的段列表（context / conflict，顺序与文件一致） */
  sections: ConflictSection[];
  /** 每个冲突块的当前选择，顺序与冲突块出现顺序一致 */
  choices: (ConflictChoice | null)[];
  /** 冲突块总数 */
  conflictCount: number;
  /** 左栏标题：你的（当前分支 xxx） */
  localLabel: string;
  /** 右栏标题：传入的（origin/xxx） */
  theirsLabel: string;
  /** 按当前选择重组的合并结果（逐行） */
  mergedLines: string[];
}>();

const emit = defineEmits<{
  (e: "choose", index: number, choice: ConflictChoice): void;
}>();

/** 渲染模型：context 段直接输出行；conflict 段携带块序号与选择状态 */
type Rendered =
  | { kind: "ctx"; lines: string[] }
  | {
      kind: "conf";
      idx: number;
      choice: ConflictChoice | null;
      local: string[];
      theirs: string[];
      base: string[] | null;
    };

/** 把段列表映射为渲染模型（conflict 段按出现顺序编号，与 choices 对齐） */
const rendered = computed<Rendered[]>(() => {
  const out: Rendered[] = [];
  let ci = -1;
  for (const s of props.sections) {
    if (s.type === "context") {
      out.push({ kind: "ctx", lines: s.lines });
    } else {
      ci += 1;
      out.push({
        kind: "conf",
        idx: ci,
        choice: props.choices[ci] ?? null,
        local: s.local,
        theirs: s.theirs,
        base: s.base
      });
    }
  }
  return out;
});

/** 各块"共同祖先"（diff3 base 段）折叠展开状态，默认折叠 */
const openBases = reactive<Record<number, boolean>>({});
watch(
  () => props.file,
  () => {
    for (const k of Object.keys(openBases)) delete openBases[Number(k)];
  }
);

function choiceText(c: ConflictChoice | null): string {
  if (c === "local") return "✔ 采用本地";
  if (c === "theirs") return "✔ 采用远端";
  if (c === "both") return "✔ 保留双方";
  return "未决定";
}
</script>

<template>
  <div class="cfe-root">
    <div class="cfe-scroll">
      <template v-for="(sec, si) in rendered" :key="si">
        <!-- 上下文段：只读代码行（等宽、不换行、横向滚动） -->
        <div v-if="sec.kind === 'ctx'" class="sec-ctx">
          <div v-for="(l, li) in sec.lines" :key="li" class="ln">{{ l || " " }}</div>
        </div>

        <!-- 冲突段：左右并列对比 + 三选一 -->
        <div v-else class="mg-hunk" :class="sec.choice ? 'decided' : 'undecided'">
          <div class="mg-head">
            <span>冲突块 {{ sec.idx + 1 }}/{{ conflictCount }}</span>
            <span :class="sec.choice ? 'ok' : 'warn'">{{ choiceText(sec.choice) }}</span>
          </div>

          <!-- diff3 共同祖先段：折叠显示，不影响三选一 -->
          <div v-if="sec.base && sec.base.length" class="mg-base">
            <button
              class="base-tgl"
              type="button"
              @click="openBases[sec.idx] = !openBases[sec.idx]"
            >
              {{ openBases[sec.idx] ? "▾" : "▸" }} 共同祖先（{{ sec.base.length }} 行）
            </button>
            <div v-show="openBases[sec.idx]" class="base-code">
              <div v-for="(l, bi) in sec.base" :key="bi">{{ l || " " }}</div>
            </div>
          </div>

          <div class="mg-cols">
            <div
              class="mg-col"
              :class="{ pick: sec.choice === 'local' || sec.choice === 'both' }"
            >
              <div class="cap">{{ localLabel }}</div>
              <div class="code">
                <div v-for="(l, i) in sec.local" :key="i" class="cln">{{ l || " " }}</div>
              </div>
            </div>
            <div
              class="mg-col"
              :class="{ pick: sec.choice === 'theirs' || sec.choice === 'both' }"
            >
              <div class="cap">{{ theirsLabel }}</div>
              <div class="code">
                <div v-for="(l, i) in sec.theirs" :key="i" class="cln">{{ l || " " }}</div>
              </div>
            </div>
          </div>

          <div class="mg-acts">
            <el-button
              size="small"
              :class="{ picked: sec.choice === 'local' }"
              :disabled="!!sec.choice"
              @click="emit('choose', sec.idx, 'local')"
            >
              {{ sec.choice === "local" ? "✔ 采用本地" : "采用本地" }}
            </el-button>
            <el-button
              size="small"
              :class="{ picked: sec.choice === 'theirs' }"
              :disabled="!!sec.choice"
              @click="emit('choose', sec.idx, 'theirs')"
            >
              {{ sec.choice === "theirs" ? "✔ 采用远端" : "采用远端" }}
            </el-button>
            <el-button
              size="small"
              :class="{ picked: sec.choice === 'both' }"
              :disabled="!!sec.choice"
              @click="emit('choose', sec.idx, 'both')"
            >
              {{ sec.choice === "both" ? "✔ 保留双方" : "保留双方" }}
            </el-button>
          </div>
        </div>
      </template>

      <!-- 合并结果实时预览 -->
      <div class="diff-title">
        <b>合并结果（实时预览）</b>
        <span>{{ file }}</span>
      </div>
      <div class="preview">
        <div v-for="(l, i) in mergedLines" :key="i" class="ln">{{ l || " " }}</div>
        <div v-if="mergedLines.length === 0" class="pv-empty">
          为每个冲突块做出选择后，此处展示合并结果
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped lang="scss">
.cfe-root {
  flex: 1;
  min-height: 0;
  display: flex;
  flex-direction: column;
}

.cfe-scroll {
  flex: 1;
  min-height: 0;
  overflow: auto;
  padding-right: 2px;
}

/* 上下文段：只读代码行，等宽字体、行内不换行、横向滚动 */
.sec-ctx {
  border: 1px solid var(--line);
  border-radius: 8px;
  background: var(--bg-code);
  overflow-x: auto;
  padding: 6px 0;
  margin-bottom: 10px;
}

.ln {
  padding: 0 12px;
  font-family: var(--mono);
  font-size: 12.5px;
  line-height: 1.55;
  white-space: pre;
  color: var(--ink2);
}

/* 冲突块容器（沿用原型 .mg-hunk） */
.mg-hunk {
  border: 1px solid var(--line);
  border-radius: 10px;
  padding: 10px 12px;
  margin-bottom: 10px;

  &.undecided {
    border-color: color-mix(in srgb, var(--bad) 55%, transparent);
  }
  &.decided {
    border-color: var(--ok);
  }
}

.mg-head {
  display: flex;
  justify-content: space-between;
  font-size: 12px;
  color: var(--ink3);
  margin-bottom: 8px;

  .ok {
    color: var(--ok);
    font-weight: 600;
  }
  .warn {
    color: var(--warn);
    font-weight: 600;
  }
}

/* diff3 共同祖先折叠区 */
.mg-base {
  margin-bottom: 8px;
}

.base-tgl {
  border: none;
  background: none;
  cursor: pointer;
  padding: 0;
  font-size: 11.5px;
  color: var(--ink3);

  &:hover {
    color: var(--accent);
  }
}

.base-code {
  margin-top: 4px;
  border: 1px dashed var(--line);
  border-radius: 6px;
  background: var(--bg-soft);
  overflow-x: auto;
  padding: 4px 0;
  font-family: var(--mono);
  font-size: 11.5px;
  color: var(--ink3);

  div {
    padding: 0 10px;
    white-space: pre;
  }
}

/* 左右并列对比（沿用原型 .mg-cols / .mg-col） */
.mg-cols {
  display: flex;
  gap: 10px;
}

.mg-col {
  flex: 1;
  min-width: 0;
  border: 1px solid var(--line);
  border-radius: 8px;
  overflow: hidden;

  .cap {
    font-size: 11.5px;
    padding: 5px 10px;
    background: var(--bg-soft);
    color: var(--ink2);
    font-weight: 600;
    border-bottom: 1px solid var(--line);
  }

  .code {
    font-family: var(--mono);
    font-size: 12px;
    padding: 8px 10px;
    background: var(--bg-code);
    min-height: 34px;
    overflow-x: auto;
  }

  .cln {
    white-space: pre;
    line-height: 1.55;
    color: var(--ink);
  }

  /* 已选中一侧的高亮标记 */
  &.pick {
    border-color: var(--ok);
    box-shadow: inset 0 0 0 1px var(--ok);

    .cap {
      background: var(--ok-soft);
      color: var(--ok);
    }
  }
}

/* 三选一按钮（沿用原型 .mg-acts） */
.mg-acts {
  display: flex;
  gap: 8px;
  margin-top: 8px;

  :deep(.el-button) {
    background: transparent;
    border-color: var(--line);
    color: var(--ink2);
    font-weight: 500;

    &:hover {
      background: transparent;
      border-color: var(--accent);
      color: var(--accent);
    }
  }

  /* 已决定块：全部置灰，当前选择以强调色显示 */
  :deep(.el-button.is-disabled) {
    opacity: 0.55;
    background: transparent;
    border-color: var(--line);
    color: var(--ink3);
  }

  :deep(.el-button.picked) {
    opacity: 1;
    background: var(--ok-soft);
    border-color: var(--ok);
    color: var(--ok);
  }
}

/* 预览标题（沿用原型 .diff-title） */
.diff-title {
  font-size: 12px;
  color: var(--ink3);
  padding: 2px 2px 6px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 10px;
  min-height: 24px;

  b {
    color: var(--ink2);
    font-family: var(--mono);
    font-size: 12px;
    word-break: break-all;
  }
  span {
    font-family: var(--mono);
    word-break: break-all;
  }
}

/* 合并结果预览：只读、纵向 + 横向滚动 */
.preview {
  max-height: 200px;
  overflow: auto;
  border: 1px solid var(--line);
  border-radius: 9px;
  background: var(--bg-code);
  padding: 8px 0;
  font-family: var(--mono);
  font-size: 12.5px;

  .ln {
    color: var(--ink);
  }
}

.pv-empty {
  color: var(--ink3);
  font-size: 12.5px;
  text-align: center;
  padding: 18px 0;
}
</style>
