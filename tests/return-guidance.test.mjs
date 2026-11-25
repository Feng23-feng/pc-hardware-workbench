import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { deriveCurrentUnresolvedLabel } from "../public/status-model.js";

const root = resolve(import.meta.dirname, "..");
const [appSource, cssSource, indexSource] = await Promise.all([
  readFile(resolve(root, "public/app.js"), "utf8"),
  readFile(resolve(root, "public/styles.css"), "utf8"),
  readFile(resolve(root, "public/index.html"), "utf8"),
]);

assert.match(appSource, /把本轮结果带回 Agent 对话/u);
assert.match(appSource, /复制“同步面板”/u);
assert.match(appSource, /“复制本次遥测摘要”只复制内容/u);
assert.match(appSource, /document\.execCommand\("copy"\)/u);
assert.match(appSource, /浏览器没有允许自动复制/u);
assert.match(appSource, /已复制 · 回对话粘贴/u);
assert.match(
  appSource,
  /请在当前 Codex 对话里手动输入“同步面板”/u,
);
assert.match(appSource, /renderEndHandoff\(\)/u);
assert.match(appSource, /也可以回到上方“任务来源”卡片/u);
assert.match(appSource, /permissionContinuationPending = true/u);
assert.match(appSource, /await continuePermissionRequest\(approvedGrant\)/u);
assert.match(appSource, /本轮分析已完成/u);
assert.match(appSource, /不需要再次点击“继续分析”/u);
assert.match(appSource, /handoff-actions/u);
assert.match(cssSource, /\.handoff-actions\s*\{/u);
assert.match(cssSource, /\.end-handoff\s*\{/u);
assert.match(indexSource, /app\.js\?v=20261125-warm4/u);
assert.match(indexSource, /styles\.css\?v=20261125-warm4/u);
assert.match(appSource, /function shouldPollState\(\)/u);
assert.match(appSource, /"waiting_for_source_pull", "source_agent_pulled"/u);
assert.match(appSource, /"source_result_synced"/u);
assert.match(appSource, /正在等待来源 Agent 返回结论/u);
assert.match(appSource, /visibilitychange/u);
assert.match(appSource, /window\.addEventListener\("focus", refreshAfterPageWake\)/u);
assert.match(appSource, /requestSequence >= lastAppliedStateRefresh/u);
assert.match(appSource, /nextStateKey !== lastPollStateKey/u);
assert.equal(
  deriveCurrentUnresolvedLabel(["  热限制待确认\n", "补充说明"]),
  "热限制待确认",
);
assert.equal(deriveCurrentUnresolvedLabel(["", "  ", 4]), "");
assert.match(appSource, /id: "current-unresolved-item"/u);
assert.match(appSource, /result\.uncertainty\.slice\(1\)/u);
assert.match(cssSource, /\.answer-unresolved-chip\s*\{/u);
assert.match(appSource, /本地运行环境已连接/u);
assert.match(appSource, /runtime-binding-detail-grid/u);
assert.match(
  cssSource,
  /\.runtime-binding\.is-bound\s*\{[^}]*background:\s*transparent/isu,
);
assert.match(
  cssSource,
  /scrollbar-color:\s*var\(--line-strong\) var\(--page\)/u,
);
assert.match(
  cssSource,
  /\.skeleton\s*\{[^}]*background:\s*var\(--surface-muted\)/isu,
);
assert.match(cssSource, /\.primary:active:not\(:disabled\)/u);
assert.match(cssSource, /\.secondary:active:not\(:disabled\)/u);
assert.match(cssSource, /--page:\s*#f0efea/u);
assert.match(cssSource, /--signal:\s*#7a482e/u);
assert.match(cssSource, /--data:\s*#6c91a5/u);
assert.match(cssSource, /--danger:\s*#9b3428/u);
assert.doesNotMatch(
  cssSource,
  /#006f75|#0a7f87|#edf5f4|#edf6f5|#f2f8f7/iu,
);

console.log("Agent return guidance: PASS");
