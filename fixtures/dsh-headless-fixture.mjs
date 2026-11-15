import {
  appendFileSync,
  readFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";

const args = process.argv.slice(2);
const sessionIndex = args.indexOf("--session-id");
const resumedSessionId =
  sessionIndex >= 0 ? args[sessionIndex + 1] : null;
const sessionId = resumedSessionId || `session-fixture-${randomUUID()}`;
const prompt = readFileSync(0, "utf8");
const finalOnly = prompt.includes("[DSH_FIXTURE_FINAL_ONLY]");
const invalidJson = prompt.includes("[DSH_FIXTURE_INVALID_JSON]");
const fencedJson = prompt.includes("[DSH_FIXTURE_FENCED_JSON]");
const authFailure = prompt.includes("[DSH_FIXTURE_AUTH_FAILURE]");
const noFinal = prompt.includes("[DSH_FIXTURE_NO_FINAL]");
const slow = prompt.includes("[DSH_FIXTURE_SLOW]");

const logPath = process.env.DSH_FIXTURE_LOG_PATH;
if (logPath) {
  appendFileSync(
    logPath,
    `${JSON.stringify({
      sessionId,
      resumed: Boolean(resumedSessionId),
      args: args.filter((arg) => arg !== prompt),
      prompt_sha256: createHash("sha256").update(prompt).digest("hex"),
      at: new Date().toISOString(),
    })}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

function write(event) {
  process.stdout.write(`${JSON.stringify(event)}\n`);
}

write({
  type: "session",
  sessionId,
  cwd: process.cwd(),
});
write({ type: "status", phase: "turn_start", turn: 1 });
write({ type: "status", phase: "step_start", turn: 1, step: 1 });

if (authFailure) {
  write({
    type: "status",
    phase: "turn_end",
    turn: 1,
    reason: "error",
  });
  write({ type: "final", text: "" });
  process.stderr.write(
    "dsh: MISSING_CREDENTIAL: llm-deepseek: no API key for fixture route\n",
  );
  process.exit(1);
}

if (noFinal) {
  process.exit(0);
}

if (slow) {
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 5_000));
}

const panel = finalOnly
  ? {
      schema_version: "1.2",
      turn_summary:
        "DSH fixture 已完成最小 JSON 输出并复用当前任务上下文。",
      current_goal: "验证 DSH 结构化兼容层",
      status: "ready",
      judgement:
        "当前仅验证 DSH adapter 的 JSON 输出与 session 续接，不据此形成新的硬件结论。",
      question: null,
      recommendation: {
        summary: "本轮无需继续选择。",
        option_id: null,
      },
      evidence: [
        {
          id: "dsh-session-evidence",
          label: "DSH session 事件",
          detail: "headless --json 返回了可续接的 session ID。",
          source: "observed_current",
          relation: "supports",
        },
      ],
      uncertainty: ["DSH 没有原生 JSON Schema 约束，结果依赖提示与本地校验。"],
      recommendations: [
        {
          id: "dsh-preserve-session",
          title: "保留 DSH session",
          detail: "下一轮使用 --session-id 验证上下文续接。",
          risk: "low",
          evidence_goal: "确认 session 映射可重复使用。",
        },
        {
          id: "dsh-validate-json",
          title: "继续校验 panel JSON",
          detail: "每轮最终消息都必须通过 schema 1.2 校验。",
          risk: "low",
          evidence_goal: "阻止普通文本被误当作面板结果。",
        },
      ],
      priorityAction: {
        title: "验证下一轮 session 续接",
        detail: "使用同一个 DSH session ID 再发送一条测试消息。",
      },
      actions: [
        {
          id: "copy-dsh-boundary",
          label: "复制兼容边界",
          kind: "copy",
          content:
            "DSH structured output 使用 prompt + local JSON parse + panel schema validation，不是原生 schema enforcement。",
        },
      ],
      artifact_refs: [],
      blocks: [],
    }
  : {
      schema_version: "1.2",
      turn_summary: finalOnly
        ? "已确认 DSH session 可用。"
        : "DSH 已通过独立 session 收到卡顿描述，下一步先确认可重复场景。",
      current_goal: "确认卡顿最明显的使用场景",
      status: "needs_input",
      judgement:
        "目前只能确认用户报告“电脑最近有点卡”，尚不能区分应用负载、系统调度、存储、驱动或硬件问题。应先固定一个可重复场景并记录时间，再补充组件级证据。",
      question: {
        id: "dsh-slowdown-context",
        prompt: "卡顿最常发生在哪一种使用场景？",
        options: [
          {
            id: "gaming",
            label: "玩游戏时",
            description: "主要在游戏或高图形负载中出现。",
          },
          {
            id: "desktop",
            label: "日常多任务时",
            description: "多开窗口、浏览器或办公程序时更明显。",
          },
          {
            id: "startup",
            label: "开机或唤醒后",
            description: "刚登录或从睡眠恢复的一段时间内变慢。",
          },
        ],
        allow_free_text: true,
      },
      recommendation: {
        summary: "选择最接近的主要场景；如果你无法判断，请补充具体操作。",
        option_id: null,
      },
      evidence: [
        {
          id: "dsh-user-report",
          label: "用户报告近期卡顿",
          detail: "用户只提供了“电脑最近有点卡”的主观描述。",
          source: "user_reported",
          relation: "context",
        },
      ],
      uncertainty: [
        "尚不清楚卡顿发生的场景、频率和持续时间。",
        "尚无温度、占用率、帧时间或系统事件证据。",
      ],
      recommendations: [
        {
          id: "dsh-fixed-scene",
          title: "固定一个可重复场景",
          detail:
            "保持应用、操作步骤和持续时间一致，记录卡顿发生的精确本地时间与持续秒数。",
          risk: "low",
          evidence_goal: "确认问题是否稳定复现。",
        },
        {
          id: "dsh-event-readonly",
          title: "只读检查系统事件",
          detail:
            "记录卡顿前后是否存在 Display TDR、WHEA-Logger 或 Kernel-Power 41。",
          risk: "low",
          evidence_goal: "区分驱动重置、硬件错误和异常断电。",
        },
        {
          id: "dsh-telemetry",
          title: "补录短时 GPU 遥测",
          detail:
            "在同一场景记录 GPU 温度、功耗、有效频率和 PerfCap，并保存 CSV。",
          risk: "low",
          evidence_goal: "观察卡顿时是否存在降频、功耗或温度限制。",
        },
      ],
      priorityAction: {
        title: "先完成一次固定场景复测",
        detail:
          "复测时记录精确时间；不要同时修改驱动、BIOS、电源或超频设置。",
      },
      actions: [
        {
          id: "copy-dsh-baseline",
          label: "复制基础采集清单",
          kind: "copy",
          content:
            "固定同一场景复测并记录精确时间；只读检查 Display TDR、WHEA-Logger、Kernel-Power 41；记录 GPU 温度、功耗、有效频率与 PerfCap。以上仅用于证据采集。",
        },
      ],
      artifact_refs: [],
      blocks: [],
    };

const text = invalidJson
  ? "This is plain text, not panel JSON."
  : fencedJson
    ? `\`\`\`json\n${JSON.stringify(panel)}\n\`\`\``
    : JSON.stringify(panel);
const split = Math.max(1, Math.floor(text.length / 2));
write({ type: "thinking", text: "DSH fixture planning step." });
write({ type: "text", text: text.slice(0, split) });
write({ type: "text", text: text.slice(split) });
write({
  type: "status",
  phase: "step_end",
  turn: 1,
  step: 1,
});
write({
  type: "status",
  phase: "turn_end",
  turn: 1,
  reason: "completed",
});
write({ type: "final", text });
