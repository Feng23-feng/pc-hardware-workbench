import { randomUUID } from "node:crypto";
import { AgentDriver } from "./agent-driver.mjs";

function genericSkillPanel(packet) {
  const skillId = packet?.skill_context?.skill_id ?? "unknown-skill";
  const selected =
    packet?.type === "panel_submission" &&
    packet.events?.some((event) => event.type === "option_selected");
  const text = String(packet?.text ?? packet?.free_text ?? "").trim();
  return {
    schema_version: "1.2",
    turn_summary: selected
      ? "The selected option was recorded in the current Task."
      : "The Skill context is ready for one small decision.",
    current_goal: selected
      ? "Continue with the selected option"
      : "Choose the most useful next focus",
    status: selected ? "ready" : "needs_input",
    judgement: selected
      ? "The Task now contains a concrete user choice. No domain capability was implied by the selection itself."
      : `The active Skill is ${skillId}. This provider-free demo intentionally asks one small question before producing a text artifact.`,
    question: selected
      ? null
      : {
          id: "demo-focus",
          prompt: "Which result should this Task focus on?",
          options: [
            {
              id: "brief",
              label: "Short brief",
              description: "Keep the result concise and action-oriented.",
            },
            {
              id: "detail",
              label: "Detailed notes",
              description: "Retain more context and provenance.",
            },
          ],
          allow_free_text: true,
        },
    recommendation: {
      summary: selected
        ? "The Task can continue or export a local text artifact."
        : "Choose the output style that best matches the task.",
      option_id: null,
    },
    evidence: [
      {
        id: "generic-input",
        label: "Task input",
        detail: text ? text.slice(0, 160) : "No free-text input yet.",
        source: "user_reported",
        relation: "context",
      },
    ],
    uncertainty: [
      "The Generic Demo proves runtime, interface, artifact, and persistence plumbing.",
    ],
    recommendations: [
      {
        id: "demo-choose",
        title: "Choose a result shape",
        detail: "Select the brief or detailed output style.",
        risk: "low",
        evidence_goal: "Give the local action a concrete output target.",
      },
      {
        id: "demo-export",
        title: "Generate a local text artifact",
        detail: "Use the manifest-declared local action after a text file is attached.",
        risk: "low",
        evidence_goal: "Verify Task-scoped artifact delivery.",
      },
    ],
    priorityAction: {
      title: selected ? "Continue or download the artifact" : "Choose one focus",
      detail:
        "This demo depends only on the portable Task, Skill, artifact, and Agent contracts.",
    },
    actions: [
      {
        id: "demo-copy",
        label: "Copy next step",
        kind: "copy",
        content: "Choose one focus, then optionally generate a local text artifact.",
      },
    ],
    artifact_refs: [],
    blocks: [],
  };
}

export class MockAgentDriver extends AgentDriver {
  constructor() {
    super({
      name: "mock",
      displayName: "Mock",
      capabilities: {
        supportsStreaming: true,
        supportsThreadResume: true,
        supportsActiveThreadAttach: false,
        activeThreadAttachReason:
          "The source conversation is owned by another active agent client.",
        supportsStructuredOutput: true,
        supportsApprovals: false,
        supportsCancellation: true,
        supportsThreadNaming: true,
        adapterStatus: "deterministic",
      },
    });
  }

  async initialize() {
    return { connected: true };
  }

  async startThread() {
    this.activeThreadReference = `mock-${randomUUID()}`;
    return { threadReference: this.activeThreadReference, resumed: false };
  }

  async resumeThread(threadReference) {
    this.activeThreadReference = threadReference || `mock-${randomUUID()}`;
    return {
      threadReference: this.activeThreadReference,
      resumed: Boolean(threadReference),
    };
  }

  async sendTurn({
    threadReference,
    packet,
    onEvent = null,
  }) {
    if (threadReference !== this.activeThreadReference) {
      throw this.classifyError(
        new Error("The requested mock thread is not active"),
      );
    }
    const turnId = `mock-turn-${randomUUID()}`;
    this.emit(onEvent, { type: "turn_started", turnId });
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 350));
    const skillRuntimeId = packet?.skill_context?.runtime_id;
    if (skillRuntimeId === "generic-demo" || skillRuntimeId === "compat-chat") {
      const panel = genericSkillPanel(packet);
      const finalText = JSON.stringify(panel);
      this.emit(onEvent, {
        type: "text_delta",
        turnId,
        delta: finalText,
      });
      this.emit(onEvent, {
        type: "message_completed",
        turnId,
      });
      this.emit(onEvent, {
        type: "turn_completed",
        turnId,
        status: "completed",
      });
      return {
        turnId,
        finalText,
        structuredOutput: panel,
      };
    }
    const finalOnly = /最终结论/u.test(JSON.stringify(packet));
    const displayCase = /黑屏|掉帧/u.test(JSON.stringify(packet));
    const selected =
      displayCase ||
      (packet.type === "panel_submission" &&
        packet.events.some((event) => event.type === "option_selected"));
    let panel =
      packet.type === "panel_tool_result"
        ? {
            schema_version: "1.2",
            turn_summary:
              "Workbench 已完成遥测分析，图表与关键指标由本地工具提供。",
            current_goal: "结合遥测窗口决定下一步证据",
            status: "needs_input",
            judgement: `Workbench 已验证这份 CSV 的 ${packet.tool_result?.analysis?.analyzed_rows ?? 0} 行数据，并识别到 ${packet.tool_result?.analysis?.metrics?.length ?? 0} 个数值序列。图表只描述所选窗口，不能单独证明稳定性或故障原因。`,
            question: null,
            recommendation: {
              summary:
                "查看关键指标与图表，再决定是否需要补充同一负载下的完整故障窗口。",
              option_id: null,
            },
            evidence: [
              {
                id: "workbench-telemetry",
                label: "本地 Workbench 遥测分析",
                detail:
                  "关键指标和 SVG 图表由安装的 Workbench analyzer 与 renderer 生成。",
                source: "observed_current",
                relation: "supports",
              },
            ],
            uncertainty: [
              "当前窗口的采样一致性仍需结合 Warnings 和数据列检查。",
              "遥测窗口本身不能证明黑屏、掉帧或硬件故障的因果。",
            ],
            recommendations: [
              {
                id: "telemetry-fixed-window",
                title: "固定同一负载与时间窗口",
                detail:
                  "保持游戏场景、画质和操作路线一致，再记录一次覆盖完整故障前后的 CSV。",
                risk: "low",
                evidence_goal:
                  "让图表比较使用同一工作负载和采样间隔。",
              },
              {
                id: "telemetry-correlate-events",
                title: "把故障时间与图表对齐",
                detail:
                  "记录黑屏或掉帧的精确本地时间，只与同一时间段的遥测和系统事件对照。",
                risk: "low",
                evidence_goal:
                  "判断异常表现与降频、功耗限制或温度变化是否重叠。",
              },
            ],
            priorityAction: {
              title: "确认一次完整故障窗口",
              detail:
                "先查看当前图表，再决定是否补录覆盖故障前后的同一负载窗口；不要据单段遥测直接更换硬件。",
            },
            actions: [
              {
                id: "copy-telemetry-window",
                label: "复制窗口要求",
                kind: "copy",
                content:
                  "保持同一游戏场景、画质、操作路线和采样间隔；记录故障发生前后的完整本地时间窗口，并将 CSV 与系统事件按同一时间对照。以上仅用于证据采集。",
              },
            ],
            artifact_refs: [],
            blocks: [],
          }
        : selected
          ? {
              schema_version: "1.1",
              turn_summary:
                "已确认卡顿主要在游戏时出现，下一步区分画面掉帧与整机停顿。",
              current_goal: "确认游戏卡顿的具体表现",
              status: "needs_input",
              judgement:
                "现有信息只能确认问题与游戏负载相关。还不能区分游戏画面掉帧、显示驱动短暂重置或整机输入停顿，因此先不要据此更换硬件。",
              question: {
                id: "game-symptom",
                prompt: "游戏卡顿时，最接近哪一种表现？",
                options: [
                  {
                    id: "frames-only",
                    label: "只是画面掉帧",
                    description:
                      "鼠标和窗口仍能响应，主要是帧率下降或画面不流畅。",
                  },
                  {
                    id: "whole-pc",
                    label: "整台电脑同时卡住",
                    description: "鼠标、声音或其他窗口也一起短暂停顿。",
                  },
                  {
                    id: "starts-fast",
                    label: "开始正常随后变卡",
                    description:
                      "游戏运行几分钟后逐渐恶化，可能还伴随风扇声变大。",
                  },
                ],
                allow_free_text: true,
              },
              recommendation: {
                summary:
                  "选择最影响游戏体验的表现；若两种情况同时出现，请补充先后顺序。",
                option_id: null,
              },
              evidence: [
                {
                  id: "reported-slowdown",
                  label: "用户报告近期卡顿",
                  detail: "用户只给出了“电脑最近有点卡”的主观描述。",
                  source: "user_reported",
                  relation: "context",
                },
                {
                  id: "gaming-timing",
                  label: "卡顿与游戏相关",
                  detail: "用户确认最明显的卡顿发生在玩游戏时。",
                  source: "user_reported",
                  relation: "supports",
                },
              ],
              uncertainty: [
                "尚未读取帧时间、温度、占用率和系统事件。",
                "目前不能据此判断是软件、驱动还是硬件层。",
              ],
              recommendations: [
                {
                  id: "fixed-scene-timestamp",
                  title: "在固定场景复测并记录精确时间",
                  detail:
                    "使用同一游戏、同一画面设置和同一路线复现；每次卡顿时记下本地时间、持续秒数，以及是否黑屏。",
                  risk: "low",
                  evidence_goal:
                    "判断是否稳定复现，并为日志关联提供时间戳。",
                },
                {
                  id: "display-event-check",
                  title: "检查显示与电源相关系统事件",
                  detail:
                    "在事件查看器中筛选 Display TDR、WHEA-Logger 和 Kernel-Power 41，记录卡顿前后是否出现对应事件。",
                  risk: "low",
                  evidence_goal:
                    "区分显示驱动重置、硬件错误和异常断电。",
                },
                {
                  id: "gpu-counter-log",
                  title: "记录一次 GPU 负载证据",
                  detail:
                    "用 HWiNFO Sensors-only 记录 GPU 温度、功耗、有效频率和 PerfCap，在同一场景运行后停止并保存 CSV。",
                  risk: "low",
                  evidence_goal:
                    "判断卡顿时是否存在降频、功耗限制或温度限制。",
                },
              ],
              priorityAction: {
                title: "先完成一次固定场景复测",
                detail:
                  "复测时立即记录精确时间；随后只对照事件查看器，不要同时改驱动、BIOS 或其他设置。",
              },
              actions: [
                {
                  id: "copy-evidence-plan",
                  label: "复制采集清单",
                  kind: "copy",
                  content:
                    "固定场景复测并记录本地时间；检查 Event Viewer 的 Display TDR、WHEA-Logger、Kernel-Power 41；用 HWiNFO 记录 GPU 温度、功耗、有效频率和 PerfCap。以上仅用于证据采集。",
                },
                {
                  id: "copy-event-names",
                  label: "复制事件检查项",
                  kind: "copy",
                  content:
                    "Display TDR；WHEA-Logger；Kernel-Power 41；同时记录卡顿发生的本地时间。",
                },
              ],
            }
          : {
              schema_version: "1.1",
              turn_summary:
                "现有描述不足以定位层级，先确认卡顿发生的使用场景。",
              current_goal: "确认卡顿最明显的使用场景",
              status: "needs_input",
              judgement:
                "目前只有主观的近期卡顿描述，尚不能判断是单一应用、Windows 调度还是硬件相关。先建立可重复场景与时间记录，后续才适合检查组件级证据。",
              question: {
                id: "slowdown-timing",
                prompt: "卡顿最明显发生在什么时候？",
                options: [
                  {
                    id: "gaming",
                    label: "玩游戏时",
                    description:
                      "只有在游戏或大型图形负载下明显。",
                  },
                  {
                    id: "desktop",
                    label: "日常多任务时",
                    description:
                      "多开浏览器或多个程序后开始变卡。",
                  },
                  {
                    id: "startup",
                    label: "开机或唤醒后",
                    description:
                      "刚登录或睡眠唤醒的一段时间内特别慢。",
                  },
                  {
                    id: "random",
                    label: "空闲时也卡",
                    description:
                      "没有明显负载，也会随机短暂卡顿。",
                  },
                ],
                allow_free_text: true,
              },
              recommendation: {
                summary:
                  "先选择最接近的主要场景；若场景不固定，请用补充文字说明。",
                option_id: null,
              },
              evidence: [
                {
                  id: "reported-slowdown",
                  label: "用户报告近期卡顿",
                  detail: "目前只有“电脑最近有点卡”的主观描述。",
                  source: "user_reported",
                  relation: "context",
                },
              ],
              uncertainty: [
                "尚未了解卡顿发生的时段、频率和当时运行的程序。",
                "没有温度、占用率、驱动或系统事件证据。",
              ],
              recommendations: [
                {
                  id: "define-repeatable-scene",
                  title: "确定一个可重复的场景",
                  detail:
                    "先选择最容易复现的用途，并固定应用、操作步骤和持续时间，避免每次用不同负载比较。",
                  risk: "low",
                  evidence_goal:
                    "判断卡顿是否只在特定工作负载出现。",
                },
                {
                  id: "capture-symptom-timeline",
                  title: "记录症状时间线与负载",
                  detail:
                    "卡顿时记录本地时间、持续秒数、正在运行的程序，以及是否出现黑屏、死机、异响或重启。",
                  risk: "low",
                  evidence_goal:
                    "把用户观察与后续系统日志建立时间关联。",
                },
              ],
              priorityAction: {
                title: "先选定一个可重复场景",
                detail:
                  "进入该场景复现一次，同时记录精确时间；暂时不要修改驱动、电源或 BIOS 设置。",
              },
              actions: [
                {
                  id: "copy-baseline",
                  label: "复制基础记录清单",
                  kind: "copy",
                  content:
                    "记录卡顿发生的本地时间、持续秒数、正在运行的程序，以及是否出现黑屏、死机、异响或重启；固定同一场景复测。以上仅用于证据采集。",
                },
              ],
            };
    if (finalOnly) {
      panel = {
        ...panel,
        status: "ready",
        question: null,
        recommendation: {
          summary: "本轮不需要继续选择；可复制证据清单或新建任务。",
          option_id: null,
        },
      };
    }
    panel = {
      ...panel,
      schema_version: "1.2",
      artifact_refs: panel.artifact_refs ?? [],
      blocks: panel.blocks ?? [],
    };
    const finalText = JSON.stringify(panel);
    this.emit(onEvent, {
      type: "text_delta",
      turnId,
      delta: finalText,
    });
    this.emit(onEvent, {
      type: "turn_completed",
      turnId,
      status: "completed",
    });
    return {
      turnId,
      finalText,
      structuredOutput: panel,
    };
  }

  async cancel(turnId) {
    return { turnId, cancelled: true };
  }

  async setThreadName(name) {
    this.activeThreadName = String(name).trim().slice(0, 80);
    return this.activeThreadName;
  }

  async close() {
    this.activeThreadReference = null;
  }
}
