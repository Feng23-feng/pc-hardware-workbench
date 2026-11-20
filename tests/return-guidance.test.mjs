import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

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
assert.match(indexSource, /app\.js\?v=20261120-storage1/u);
assert.match(indexSource, /styles\.css\?v=20261120-storage1/u);
assert.match(appSource, /function shouldPollState\(\)/u);
assert.match(appSource, /"waiting_for_source_pull", "source_agent_pulled"/u);
assert.match(appSource, /"source_result_synced"/u);
assert.match(appSource, /正在等待来源 Agent 返回结论/u);
assert.match(appSource, /visibilitychange/u);
assert.match(appSource, /window\.addEventListener\("focus", refreshAfterPageWake\)/u);
assert.match(appSource, /requestSequence >= lastAppliedStateRefresh/u);
assert.match(appSource, /nextStateKey !== lastPollStateKey/u);

console.log("Agent return guidance: PASS");
