import { createHash, randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import {
  CAPABILITY_PROFILE_READ_ONLY,
  activeCapabilityGrants,
  artifactRootRef,
  capabilityGrantMatches,
  consumeCapabilityGrant,
  createCapabilityGrant,
  createPermissionRequest,
  defaultCapabilityProfile,
  expireCapabilityState,
  grantWindowSignature,
  revokeCapabilityGrant,
} from "./capability-grants.mjs";
import { SharedEvidenceStore } from "./shared-evidence-store.mjs";
import {
  TelemetryBroker,
  TelemetryBrokerError,
} from "./telemetry-broker.mjs";

export const CAPABILITY = "telemetry.csv.analyze";

function completedOneTimeAttachmentAnalysis(task, attachment) {
  return (task?.actions ?? []).some(
    (action) =>
      action.action_id === CAPABILITY &&
      action.attachment_id === attachment?.id &&
      action.source_sha256 === attachment?.sha256 &&
      action.permission_scope === "one-time" &&
      Boolean(action.artifact_id) &&
      Boolean(action.local_completed_at || action.completed_at),
  );
}

const PHYSICAL_HAZARD_SOURCE =
  String.raw`烧焦|焦味|焦糊|冒烟|烟味|火花|电弧|打火|漏液|明显异味|刺鼻异味|液体[^。]{0,20}(?:通电|电源|设备)|异味[^。]{0,20}(?:插头|电源|设备)|插头[^。]{0,20}过热|连接器[^。]{0,20}(?:损坏|熔化|烧)|电池[^。]{0,20}(?:鼓包|膨胀)|(?:线路|导线)[^。]{0,20}裸露|烧痕|熔痕|burning|smoke|sparks?|arcing|liquid[^.]{0,20}power|swollen battery|damaged connector|exposed wiring|electrical damage`;
const HAZARD_SEGMENT_SEPARATOR =
  /[，。；;\n]+|但仍|但是|但|不过|然而|却|仍然|依然|仍|并且|同时|且|而/iu;
const NEGATED_HAZARD_SCOPE_PATTERN =
  /(?:没有|未见|未发现|未出现|未闻到|无|不存在|不再有|已排除|并非|不是)(?:明显|任何|新的|当前)?[^且但而却]{0,20}\s*$/iu;
const RESOLVED_HAZARD_SCOPE_PATTERN =
  /^\s*(?:已经?排除|已经?修复|已恢复|不再出现|未再出现|已消失)/iu;
const BENIGN_HAZARD_CONTEXT_PATTERN =
  /\b(?:smoke\s*test(?:ing)?|signed\s+handoff\s+smoke)\b/iu;
const HISTORICAL_MARKER = /此前|之前|以前|上次|历史|昨天|前天|刚才/iu;
const CURRENT_MARKER = /现在|当前|这次|本次|最近|仍然|依然|还在|持续/iu;
const PHYSICAL_SAFETY_ACTION = Object.freeze({
  title: "立即停止使用并断开电源",
  detail:
    "停止测试、参数修改和继续通电；仅在安全时关闭设备并断开电源。不要继续通电、复测或拆装，联系合格维修处理燃烧、液体、损坏连接器或其他电气危险。",
});

function currentTaskContext(panel, packet) {
  const candidates = [
    packet?.task_context?.objective,
    packet?.task_context?.current_goal,
    packet?.current_objective,
    panel.current_goal,
  ]
    .map((value) => String(value ?? "").trim())
    .filter(Boolean);
  return [...new Set(candidates)].join("。");
}

function hasCurrentPhysicalHazard(panel, packet) {
  const currentContext = currentTaskContext(panel, packet);
  const clauses = currentContext
    .split(HAZARD_SEGMENT_SEPARATOR)
    .map((value) => value.trim())
    .filter(Boolean);
  for (const clause of clauses) {
    if (HISTORICAL_MARKER.test(clause) && !CURRENT_MARKER.test(clause)) {
      continue;
    }
    const hazardPattern = new RegExp(PHYSICAL_HAZARD_SOURCE, "giu");
    for (const match of clause.matchAll(hazardPattern)) {
      const localContext = clause.slice(
        Math.max(0, match.index - 32),
        match.index + match[0].length + 32,
      );
      if (BENIGN_HAZARD_CONTEXT_PATTERN.test(localContext)) {
        continue;
      }
      const before = clause.slice(0, match.index);
      if (NEGATED_HAZARD_SCOPE_PATTERN.test(before)) {
        continue;
      }
      const after = clause.slice(match.index + match[0].length);
      if (RESOLVED_HAZARD_SCOPE_PATTERN.test(after)) {
        continue;
      }
      return true;
    }
  }
  return false;
}

function enforcePhysicalHazardStop(panel) {
  const action = PHYSICAL_SAFETY_ACTION;
  return {
    ...panel,
    status: "blocked",
    question: null,
    result_title: "先停止使用并处理物理危险",
    turn_summary: "检测到当前物理危险信号，需要先停止使用并确认安全。",
    judgement:
      "在继续任何测试、拆装或参数调整前，先停止使用设备；仅在安全条件下断电并联系合格维修。",
    recommendation: {
      summary: action.title,
      option_id: null,
    },
    uncertainty: Array.isArray(panel.uncertainty) ? panel.uncertainty : [],
    recommendations: [
      {
        id: "runtime-safety-stop",
        title: action.title,
        detail: action.detail,
        risk: "low",
        evidence_goal: "先消除物理安全风险，不继续自动复测。",
      },
    ],
    priorityAction: action,
    actions: [],
  };
}

export function enforceSafetyStateContract(panel, packet) {
  if (!["1.1", "1.2"].includes(panel.schema_version)) {
    return panel;
  }
  return hasCurrentPhysicalHazard(panel, packet)
    ? enforcePhysicalHazardStop(panel)
    : panel;
}

export const enforceDisplayEvidenceContract = enforceSafetyStateContract;

function analysisFailureCopy(error) {
  const code = String(error?.code ?? "analysis_failed");
  const recovery = {
    no_usable_series: {
      resultTitle: "未找到可分析的传感器列",
      summary: "CSV 中没有识别到可用于图表的数值传感器列。",
      judgement:
        "本地分析器没有找到可绘制的数值传感器列，因此没有生成图表，也没有猜测数据结构。原文件仍保留在当前检查中。",
      recommendation: {
        title: "重新导出明确的传感器列",
        detail:
          "保留原始文件，重新导出带明确时间、传感器名称和单位的记录后再分析；不要修改列名冒充已识别指标。",
      },
    },
    analysis_timeout: {
      resultTitle: "本地分析超时",
      summary: "分析在限定时间内没有完成，未生成新图表。",
      judgement:
        "本地分析进程超时并已停止。未生成图表，现有判断没有被新数据更新。",
      recommendation: {
        title: "缩小分析窗口后重试",
        detail:
          "关闭占用较高的本地任务，并缩短 CSV 或时间窗口后重新分析；不要通过延长超时绕过重复失败。",
      },
    },
    analysis_runner_error: {
      resultTitle: "无法启动本地分析",
      summary: "Windows PowerShell 分析进程没有成功启动。",
      judgement:
        "本地分析入口未能启动，因此没有读取结论所需的分析结果。请检查 PowerShell 和执行策略是否可用。",
      recommendation: {
        title: "检查本地分析环境",
        detail:
          "确认 Windows PowerShell 可运行且 Skill 文件完整，再重新发起分析；不要改用未知脚本代替。",
      },
    },
    attachment_hash_mismatch: {
      resultTitle: "附件完整性校验失败",
      summary: "磁盘上的 CSV 与上传记录不一致，已停止分析。",
      judgement:
        "附件内容在上传后被修改或替换，哈希与任务记录不匹配。为避免分析错误对象，本地分析没有继续。",
      recommendation: {
        title: "重新添加可信的原始文件",
        detail:
          "从原始数据源重新导入该 CSV，等待新的哈希记录生成后再分析；不要继续使用被修改的副本。",
      },
    },
    attachment_hash_invalid: {
      resultTitle: "附件记录不完整",
      summary: "附件缺少有效的 SHA-256 完整性记录。",
      judgement:
        "当前附件记录没有可验证的哈希，不能证明磁盘文件与上传对象一致，因此没有执行分析。",
      recommendation: {
        title: "重新导入当前文件",
        detail: "重新上传原始 CSV 以生成新的完整性记录，再继续分析。",
      },
    },
    analysis_source_binding_mismatch: {
      resultTitle: "分析结果来源不一致",
      summary: "分析器返回的记录没有绑定到当前 CSV 的实际 SHA-256 和字节数。",
      judgement:
        "本地分析结果无法证明它来自当前附件，因此没有采用其中的指标或图表。不要用附件哈希补造分析器记录；应针对当前文件重新执行一次本地分析。",
      recommendation: {
        title: "重新分析当前附件",
        detail:
          "保持当前附件不变，重新执行分析；若再次出现来源不一致，保留错误信息供审查。",
      },
    },
    unsafe_attachment_path: {
      resultTitle: "附件路径不安全",
      summary: "附件路径包含链接、Junction、重解析点或越过受控目录。",
      judgement:
        "为保护本地文件边界，分析器拒绝读取该路径。没有执行分析，也没有跟随该链接。",
      recommendation: {
        title: "重新导入到受控目录",
        detail:
          "从原始文件重新上传附件，不要在附件目录内建立链接或 Junction。",
      },
    },
    unsafe_artifact: {
      resultTitle: "图表安全校验失败",
      summary: "生成的图表包含不允许的主动内容或外部引用。",
      judgement:
        "图表没有通过本地 SVG 安全校验，因此不会展示、下载或同步。",
      recommendation: {
        title: "停止使用该图表",
        detail:
          "保留 CSV 并重新运行受信任的本地渲染器；不要手动修改 SVG 绕过校验。",
      },
    },
    unverified_artifact: {
      resultTitle: "图表引用校验失败",
      summary: "结果引用的图表不属于当前检查或内容已发生变化。",
      judgement:
        "图表的任务归属、路径或 SHA-256 没有通过复核，因此没有把它加入当前结果。",
      recommendation: {
        title: "重新生成当前检查图表",
        detail:
          "用当前附件重新执行本地分析，不要复用来源不明或来自其他任务的图表。",
      },
    },
  }[code] ?? {
    resultTitle: "本地分析未完成",
    summary: "本地分析返回错误，尚未生成新的可信结果。",
    judgement:
      "本地分析没有完成，当前判断没有被新分析更新。请根据错误信息恢复后重试。",
    recommendation: {
      title: "按错误信息恢复后重试",
      detail:
        "保留原始文件，检查本地分析环境和附件完整性，再重新发起同一操作。",
    },
  };
  if (["attachment_not_found", "invalid_attachment_size"].includes(code)) {
    return {
      resultTitle: "附件不可用于分析",
      summary: error?.message || "附件不存在或不符合分析限制。",
      judgement:
        "附件的存在性、类型或大小没有通过本地检查，因此没有执行分析。",
      recommendation: {
        title: "重新添加有效 CSV",
        detail:
          "确认文件仍存在且不超过 8 MB，再重新导入并分析。",
      },
    };
  }
  return recovery;
}

export function analysisFailure(previousPanel, error, objective) {
  const copy = analysisFailureCopy(error);
  const previousEvidence = Array.isArray(previousPanel?.evidence)
    ? previousPanel.evidence.slice(0, 6)
    : [];
  const previousRecommendations =
    Array.isArray(previousPanel?.recommendations) &&
    previousPanel.recommendations.length >= 2
      ? previousPanel.recommendations.slice(0, 3)
      : [
          {
            id: `runtime-recover-${String(error?.code ?? "analysis").replace(/[^a-z0-9-]/giu, "-").toLowerCase()}`,
            title: copy.recommendation.title,
            detail: copy.recommendation.detail,
            risk: "low",
            evidence_goal: "先恢复导致本轮分析失败的具体条件。",
          },
          {
            id: "runtime-preserve-failure-context",
            title: "保留原始文件与错误上下文",
            detail:
              "不要删除原文件；记录错误码、发生时间和当时的分析窗口，再按对应恢复步骤重试。",
            risk: "low",
            evidence_goal: "避免在失败原因未知时重复分析或误判数据。",
          },
        ];
  const details = (error?.details ?? []).filter(Boolean).slice(0, 4);
  return {
    schema_version: "1.2",
    result_title: copy.resultTitle,
    turn_summary: copy.summary,
    current_goal: previousPanel?.current_goal || objective || "检查数据格式",
    status:
      previousPanel?.status === "ready" || previousPanel?.status === "blocked"
        ? previousPanel.status
        : "needs_input",
    judgement: copy.judgement,
    question: previousPanel?.question ?? null,
    recommendation: previousPanel?.recommendation ?? {
      summary: "先按错误信息恢复数据或环境，再重新分析；本轮不会自动重试。",
      option_id: null,
    },
    evidence: [
      ...previousEvidence,
      {
        id: "analysis-failure",
        label: "本地分析被拒绝",
        detail: error?.message || "数据没有返回可用分析。",
        source: "observed_current",
        relation: "conflicts",
      },
    ].slice(0, 8),
    uncertainty: [
      "未生成图表，现有判断没有被新数据更新。",
      ...details.slice(0, 3),
    ],
    recommendations: previousRecommendations,
    priorityAction: {
      title: copy.recommendation.title,
      detail: copy.recommendation.detail,
    },
    actions: [
      {
        id: "copy-analysis-recovery",
        label: "复制修正要求",
        kind: "copy",
        content: `${copy.resultTitle}：${copy.judgement} 下一步：${copy.recommendation.title}。${copy.recommendation.detail}`,
      },
    ],
    artifact_refs: [],
    blocks: [
      {
        id: "analysis-failure-callout",
        type: "callout",
        title: copy.resultTitle,
        text: copy.summary,
        tone: "warning",
        collapsed: false,
      },
      ...(details.length
        ? [
            {
              id: "analysis-failure-details",
              type: "callout",
              title: `分析诊断 · ${details.length} 项`,
              text: details.map((detail) => `• ${detail}`).join("\n"),
              tone: "neutral",
              collapsed: true,
            },
          ]
        : []),
    ],
  };
}

export async function createRuntime(context) {
  const {
    SkillRuntime,
    manifest,
    projectRoot,
    runtimeDir,
    attachmentRoot = resolve(runtimeDir, "attachments"),
    artifactRoot = resolve(runtimeDir, "artifacts"),
  } = context;
  const skillRoot = resolve(context.skillRoot ?? import.meta.dirname);
  const scriptsDir = context.scriptsDir
    ? resolve(skillRoot, context.scriptsDir)
    : resolve(skillRoot, "scripts");
  for (const scriptName of [
    "analyze-telemetry.ps1",
    "render-telemetry-chart.ps1",
  ]) {
    if (!existsSync(resolve(scriptsDir, scriptName))) {
      throw new context.SkillRuntimeError(
        "runtime_resource_missing",
        `PC Hardware Workbench runtime is missing ${scriptName}.`,
      );
    }
  }
  Object.setPrototypeOf(
    PcHardwareWorkbenchRuntime.prototype,
    context.SkillRuntime.prototype,
  );
  return new PcHardwareWorkbenchRuntime({
    ...context,
    SkillRuntime,
    manifest,
    projectRoot,
    runtimeDir,
    skillRoot,
    attachmentRoot,
    artifactRoot,
    scriptsDir,
  });
}

class PcHardwareWorkbenchRuntime {
  constructor(options) {
    this.SkillRuntimeBase = options.SkillRuntime;
    this.manifest = options.manifest;
    this.projectRoot = options.projectRoot;
    const surfaceContracts = Object.fromEntries(
      Object.entries(options.manifest.surface_contracts ?? {}).map(
        ([id, contract]) => [
          id,
          Object.freeze({
            contract_version: contract.contract_version,
            min_skill_version: contract.min_skill_version,
            required_capabilities: Object.freeze([
              ...contract.required_capabilities,
            ]),
          }),
        ],
      ),
    );
    this.identity = Object.freeze({
      api_version: "1.0",
      skill_id: options.manifest.skill.id,
      skill_version: options.manifest.skill.version,
      manifest_hash: options.manifest.resolved?.manifest_hash ?? null,
      runtime_id: options.manifest.runtime.id,
      surface_contracts: Object.freeze(surfaceContracts),
    });
    this.active = false;
    this.SkillRuntimeError = options.SkillRuntimeError;
    this.skillRoot = resolve(options.skillRoot);
    this.runtimeDir = resolve(options.runtimeDir);
    this.attachmentRoot = resolve(options.attachmentRoot);
    this.artifactRoot = resolve(options.artifactRoot);
    this.evidence = new SharedEvidenceStore(
      resolve(this.runtimeDir, "shared-evidence.json"),
    );
    this.broker = new TelemetryBroker({
      attachmentRoot: this.attachmentRoot,
      artifactRoot: this.artifactRoot,
      scriptsDir: resolve(options.scriptsDir),
    });
  }

  createTaskState({ taskId }) {
    const context = this.evidence.deviceContext();
    const evidenceRefs = this.evidence.evidenceIds();
    return {
      ...this.SkillRuntimeBase.prototype.createTaskState.call(this, { taskId }),
      domain_state: {
        device_snapshot_ref: context.device_snapshot_ref,
        evidence_refs: evidenceRefs,
      },
      domain_refs: evidenceRefs,
      // Legacy task fields remain readable by previous snapshots.
      device_snapshot_ref: context.device_snapshot_ref,
      evidence_refs: evidenceRefs,
    };
  }

  normalizeTaskState({ task, taskId }) {
    const defaults = this.createTaskState({ taskId });
    if (!task.domain_state) {
      task.domain_state = {
        device_snapshot_ref:
          task.device_snapshot_ref ?? defaults.domain_state.device_snapshot_ref,
        evidence_refs:
          task.evidence_refs ?? defaults.domain_state.evidence_refs,
      };
    }
    task.domain_refs =
      task.domain_refs ?? task.evidence_refs ?? defaults.domain_refs;
    task.capability_profile =
      task.capability_profile ?? defaults.capability_profile;
    task.grants = task.grants ?? [];
    task.permission_request = task.permission_request ?? null;
    task.actions = task.actions ?? [];
    return task;
  }

  publicContext({ task } = {}) {
    const device = this.evidence.deviceContext();
    const domainRefs = task?.domain_refs ?? device.evidence_refs.map((item) => item.id);
    const deviceRef =
      task?.domain_state?.device_snapshot_ref ?? device.device_snapshot_ref;
    return {
      title: "设备配置复用",
      summary: device.captured_date
        ? `复用自 ${device.captured_date} · ${device.age_days} 天前 · ${device.identity_quality}`
        : "尚无设备快照；新建 Task 不会自动运行采集。",
      fields: [
        { label: "设备", value: device.device_alias },
        { label: "配置日期", value: device.captured_date ?? "未采集" },
        { label: "数据年龄", value: device.age_days ?? "未知" },
        { label: "共享引用", value: `${domainRefs.length} 条` },
      ],
      detail: device.summary,
      domain_refs: domainRefs,
      device_snapshot_ref: deviceRef,
    };
  }

  buildTaskContext({ task }) {
    const device = this.evidence.deviceContext();
    const taskRefs = new Set(task?.domain_refs ?? task?.evidence_refs ?? []);
    return {
      ...this.SkillRuntimeBase.prototype.buildTaskContext.call(this, { task }),
      domain_context: {
        device_snapshot: {
          device_snapshot_ref: device.device_snapshot_ref,
          device_alias: device.device_alias,
          captured_date: device.captured_date,
          age_days: device.age_days,
          identity_quality: device.identity_quality,
          privacy_mode: device.privacy_mode,
          summary: device.summary,
          evidence: device.evidence_refs.filter((item) =>
            taskRefs.has(item.id),
          ),
        },
        instruction:
          "Reuse this compact device/evidence context. Do not request a repeated collector or inventory read unless the user explicitly asks to refresh it.",
      },
    };
  }

  promptInstructions() {
    return [
      "For a vague slowdown without a safety symptom, first establish workload timing.",
      "When the first timing question is appropriate, include an option labelled exactly '玩游戏时'.",
      "Every result must include a compact user-facing result_title and substantive judgement. Include supports/conflicts/context evidence only when it affects the result.",
      "When the answer is complete and no action, question, permission, experiment, or handoff is required, omit recommendations and priorityAction and use an empty actions array. Keep uncertainty and evidence gaps that still exist.",
      "For needs_input, blocked, an active experiment, permission confirmation, or handoff, include the necessary question or one priorityAction and only the recommendations that change the next step.",
      "Set turn_summary to the concrete reason or data limitation, not to loading, reading, or internal processing.",
      "When uncertainty is present, set uncertainty[0] to the single current unresolved item using a compact subject-based label only when the evidence supports that subject. Never hard-code thermal, power, or a placeholder status.",
      "For current single-game black screens or stutter, consider a fixed-scene retest with precise timestamp, a read-only Event Viewer check for Display TDR, WHEA-Logger and Kernel-Power 41, and HWiNFO logging of GPU temperature, power, effective clock and PerfCap. The Agent decides which are relevant.",
      "When telemetry analysis reports sampled_span_seconds, use that value for telemetry duration. Never substitute device age, driver age, or another task's elapsed time.",
      "Describe those steps as evidence collection, not hardware conclusions.",
      "Never recommend hardware changes or tuning. Never inject HTML or arbitrary UI behavior.",
    ];
  }

  commitAttachments({ task, attachments }) {
    for (const attachment of attachments) {
      this.evidence.addAttachment(attachment);
      if (!task.domain_refs?.includes(attachment.id)) {
        task.domain_refs.push(attachment.id);
      }
    }
    task.domain_state ??= {};
    task.domain_state.device_snapshot_ref =
      this.evidence.deviceContext().device_snapshot_ref;
    task.domain_state.evidence_refs = this.evidence.evidenceIds();
    task.domain_refs = this.evidence.evidenceIds();
    task.device_snapshot_ref = task.domain_state.device_snapshot_ref;
    task.evidence_refs = task.domain_refs;
    return task.domain_refs;
  }

  recordEvidence({ task, evidence }) {
    this.evidence.addEvidence(evidence);
    task.domain_refs = this.evidence.evidenceIds();
    task.evidence_refs = task.domain_refs;
    return evidence;
  }

  applyHandoff({ task, packet }) {
    task.domain_state ??= {};
    task.domain_state.device_snapshot_ref =
      packet.domain_state?.device_snapshot_ref ??
      task.domain_state.device_snapshot_ref ??
      this.evidence.deviceContext().device_snapshot_ref;
    task.domain_refs = [
      ...new Set([...(task.domain_refs ?? []), ...(packet.domain_refs ?? [])]),
    ];
    task.domain_state.evidence_refs = task.domain_refs;
    task.device_snapshot_ref = task.domain_state.device_snapshot_ref;
    task.evidence_refs = task.domain_refs;
    return task;
  }

  taskName(panel, fallback = "新任务") {
    const goal = String(panel?.current_goal || fallback)
      .replace(/[，。！？；：、]/gu, " ")
      .replace(/\s+/g, " ")
      .trim();
    return `硬件调试：${goal}`.slice(0, 80);
  }

  validatePanelResult(panel, { packet }) {
    return enforceSafetyStateContract(
      this.SkillRuntimeBase.prototype.validatePanelResult.call(this, panel),
      packet,
    );
  }

  completeSourceHostedAgentResult({
    task,
    panel,
    packet,
    localResult,
  }) {
    const analysis = localResult?.analysis;
    if (!analysis || typeof analysis !== "object") {
      throw new this.SkillRuntimeError(
        "source_result_missing_verified_tool",
        "Source-hosted PCHW result requires a verified local analysis summary.",
      );
    }
    const analysisHash = String(analysis.source_sha256 ?? "").toLowerCase();
    const analysisBytes =
      typeof analysis.source_bytes === "number"
        ? analysis.source_bytes
        : null;
    const attachmentHash = String(
      localResult?.attachment?.sha256 ??
        packet?.tool_result?.attachment?.sha256 ??
        packet?.attachment?.sha256 ??
        "",
    ).toLowerCase();
    if (
      !/^[a-f0-9]{64}$/u.test(analysisHash) ||
      !Number.isSafeInteger(analysisBytes) ||
      analysisBytes <= 0 ||
      !/^[a-f0-9]{64}$/u.test(attachmentHash) ||
      analysisHash !== attachmentHash
    ) {
      throw new this.SkillRuntimeError(
        "source_result_invalid_analysis",
        "Source-hosted PCHW analysis is not bound to the current attachment.",
      );
    }
    const chartPreset =
      localResult?.chart_preset ??
      packet?.tool_result?.chart_preset ??
      null;
    const artifacts = Array.isArray(localResult?.artifacts)
      ? localResult.artifacts.filter(Boolean)
      : localResult?.artifact
        ? [localResult.artifact]
        : [];
    if (chartPreset === null && artifacts.length > 0) {
      throw new this.SkillRuntimeError(
        "source_result_unexpected_artifact",
        "Summary-only PCHW completion must not contain chart artifacts.",
      );
    }
    if (chartPreset !== null && artifacts.length === 0) {
      throw new this.SkillRuntimeError(
        "source_result_missing_verified_tool",
        "Chart PCHW completion requires at least one verified chart artifact.",
      );
    }
    return this.validatePanelResult(
      this.broker.applyVerifiedResult(panel, localResult, {
        taskId: task.task_id,
      }),
      { packet },
    );
  }

  refreshCapabilityProfile(task) {
    if (!task) return null;
    task.capability_profile =
      task.capability_profile ??
      defaultCapabilityProfile(task.task_id, {
        [CAPABILITY]: "approval-required",
      });
    task.capability_profile.profile = CAPABILITY_PROFILE_READ_ONLY;
    task.capability_profile.capabilities[CAPABILITY] =
      activeCapabilityGrants(task, CAPABILITY).length > 0
        ? "granted"
        : "approval-required";
    return task.capability_profile;
  }

  publicPermissions(task) {
    return this.refreshCapabilityProfile(task);
  }

  ensurePermissionRequest(task, attachment, window, host) {
    const existing = task.permission_request;
    if (
      existing?.status === "pending" &&
      existing.task_id === task.task_id &&
      existing.attachment_id === attachment.id &&
      existing.attachment_sha256 === attachment.sha256 &&
      existing.window_signature === grantWindowSignature(window) &&
      Date.parse(existing.expires_at) > Date.now()
    ) {
      return existing;
    }
    const allowTask = completedOneTimeAttachmentAnalysis(task, attachment);
    const request = createPermissionRequest({
      capability: CAPABILITY,
      presentation: {
        title: "允许本地分析这份数据？",
        description:
          "只授权当前附件与当前 Task 的固定只读分析，不提升为通用命令或网络访问。",
        scope_label: "只读监督",
        facts: [
          {
            label: "附件",
            value: `${attachment.original_name} · ${attachment.size} bytes`,
          },
          {
            label: "SHA-256",
            value: attachment.sha256,
            format: "code",
          },
          {
            label: "处理能力",
            value: "固定只读分析脚本与图表渲染器",
          },
          {
            label: "写入范围",
            value: "仅当前 Task 的 artifact 目录",
          },
          {
            label: "不会",
            value: "联网、执行任意命令、修改系统或更改硬件设置",
          },
        ],
        allow_task_available: allowTask,
        task_scope_label:
          "同一附件后续分析仅在当前 Task 保留 2 小时；更换附件需重新授权。",
        approve_label: "允许本次分析",
        allow_once_label: "仅本次允许",
        allow_task_label: "同一附件后续分析",
        deny_label: "拒绝",
        approved_title: "已允许本地数据分析",
        approved_text:
          "授权仅覆盖当前 Task、此附件和固定只读分析，不扩大为通用命令或网络访问。",
        continue_label: "继续分析",
        denied_title: "已拒绝本次数据分析",
      },
      taskId: task.task_id,
      attachment,
      window,
      continuation: {
        action_id: CAPABILITY,
        attachment_id: attachment.id,
        window,
      },
    });
    task.permission_request = request;
    this.refreshCapabilityProfile(task);
    host.appendEvent({
      type: "permission.requested",
      request_id: request.request_id,
      capability: request.capability,
      profile: request.profile,
      task_id: request.task_id,
      attachment_id: request.attachment_id,
      attachment_name: request.attachment_name,
      attachment_size: request.attachment_size,
      attachment_sha256: request.attachment_sha256,
      artifact_root_ref: request.artifact_root_ref,
      window_signature: request.window_signature,
      requested_at: request.requested_at,
      expires_at: request.expires_at,
    });
    host.save();
    return request;
  }

  grantForAction(task, attachment, window) {
    return (
      task.grants.find((grant) =>
        capabilityGrantMatches(grant, {
          taskId: task.task_id,
          attachment,
          capability: CAPABILITY,
          artifactRootRef: artifactRootRef(task.task_id),
          window,
        }),
      ) ?? null
    );
  }

  async expirePermissions(task, host) {
    if (!task) return false;
    const expired = expireCapabilityState({
      permissionRequest: task.permission_request,
      grants: task.grants,
    });
    for (const grant of expired.expiredGrants) {
      host.appendEvent({
        type: "permission.expired",
        task_id: grant.task_id,
        grant_id: grant.grant_id,
        capability: grant.capability,
        scope: grant.scope,
        expired_at: grant.expired_at,
      });
    }
    if (expired.requestExpired) {
      host.appendEvent({
        type: "permission.expired",
        task_id: task.task_id,
        request_id: task.permission_request.request_id,
        capability: task.permission_request.capability,
        expired_at: task.permission_request.expired_at,
      });
    }
    this.refreshCapabilityProfile(task);
    return expired.expiredGrants.length > 0 || expired.requestExpired;
  }

  async decidePermission({ task, body, host }) {
    if (!task) return { statusCode: 409, error: "当前没有可授权的任务" };
    await this.expirePermissions(task, host);
    const current = task.permission_request;
    if (
      !current ||
      current.request_id !== body.request_id ||
      current.status !== "pending" ||
      Date.parse(current.expires_at) <= Date.now()
    ) {
      host.save();
      return { statusCode: 409, error: "权限请求已失效，请重新发起操作" };
    }
    if (body.decision === "deny") {
      current.status = "denied";
      current.decided_at = new Date().toISOString();
      this.refreshCapabilityProfile(task);
      host.appendEvent({
        type: "permission.denied",
        request_id: current.request_id,
        capability: current.capability,
        task_id: current.task_id,
        attachment_id: current.attachment_id,
        attachment_sha256: current.attachment_sha256,
        artifact_root_ref: current.artifact_root_ref,
        decided_at: current.decided_at,
      });
      host.save();
      return { statusCode: 200 };
    }
    if (!["allow_once", "allow_task"].includes(body.decision)) {
      return { statusCode: 400, error: "权限决定无效" };
    }
    if (
      body.decision === "allow_task" &&
      !completedOneTimeAttachmentAnalysis(task, {
        id: current.attachment_id,
        sha256: current.attachment_sha256,
      })
    ) {
      return {
        statusCode: 409,
        error: "同一附件完成过一次一次性分析后，才可使用后续分析授权",
      };
    }
    const scope = body.decision === "allow_once" ? "one-time" : "task";
    const grant = createCapabilityGrant({ request: current, scope });
    current.status = "approved";
    current.decided_at = new Date().toISOString();
    current.approved_grant_id = grant.grant_id;
    task.grants.push(grant);
    this.refreshCapabilityProfile(task);
    host.appendEvent({
      type: "permission.granted",
      request_id: current.request_id,
      grant_id: grant.grant_id,
      capability: grant.capability,
      profile: grant.profile,
      scope: grant.scope,
      task_id: grant.task_id,
      attachment_id: grant.attachment_id,
      attachment_sha256: grant.attachment_sha256,
      artifact_root_ref: grant.artifact_root_ref,
      created_at: grant.created_at,
      expires_at: grant.expires_at,
    });
    host.save();
    return { statusCode: 200 };
  }

  async revokePermission({ task, body, host }) {
    if (!task) return { statusCode: 409, error: "当前没有可撤销权限的任务" };
    await this.expirePermissions(task, host);
    const grant = task.grants.find((item) => item.grant_id === body.grant_id);
    if (!grant || !revokeCapabilityGrant(grant)) {
      host.save();
      return { statusCode: 409, error: "权限已失效或不能撤销" };
    }
    this.refreshCapabilityProfile(task);
    host.appendEvent({
      type: "permission.revoked",
      grant_id: grant.grant_id,
      capability: grant.capability,
      task_id: grant.task_id,
      scope: grant.scope,
      revoked_at: grant.revoked_at,
    });
    host.save();
    return { statusCode: 200 };
  }

  getLocalAction(actionId) {
    if (actionId !== CAPABILITY) return null;
    this.requireCapability(CAPABILITY);
    return {
      id: CAPABILITY,
      capability: CAPABILITY,
      requiresPermission: true,
      requiresAgent: true,
      attachmentExtensions: [".csv"],
    };
  }

  async runLocalAction({ actionId, input, task, attachment, host }) {
    if (actionId !== CAPABILITY) {
      throw new this.SkillRuntimeError(
        "local_action_unsupported",
        "Local action is not supported by this Skill.",
      );
    }
    this.requireCapability(CAPABILITY);
    const window = {
      warmup_seconds: input.warmup_seconds ?? null,
      duration_seconds: input.duration_seconds ?? null,
    };
    const chartPreset = input.chart_preset ?? null;
    let cached;
    try {
      cached = this.broker.findCached({
        taskId: task.task_id,
        attachment,
        window,
        preset: chartPreset,
      });
    } catch (error) {
      const normalized =
        error instanceof TelemetryBrokerError
          ? error
          : new TelemetryBrokerError(
              "analysis_failed",
              `Analysis failed: ${error.message}`,
            );
      host.setPanel(analysisFailure(host.getPanel(), normalized, task.objective));
      host.setError(null);
      host.pushTimeline(
        "tool",
        `本地分析拒绝了 ${attachment.original_name}：${normalized.message}`,
      );
      host.appendEvent({
        type: "action.failed",
        action_id: actionId,
        code: normalized.code,
        attachment_id: attachment.id,
        task_id: task.task_id,
        session_ref: host.getSessionReference(),
        message: normalized.message,
        details: normalized.details,
      });
      host.archive();
      host.save();
      return { statusCode: 200 };
    }
    const cachedArtifactIds = new Set(
      (cached?.artifacts ?? (cached?.artifact ? [cached.artifact] : []))
        .map((artifact) => artifact.id),
    );
    if (
      cached &&
      host.getPanel()?.artifact_refs?.some(
        (artifact) => cachedArtifactIds.has(artifact.id),
      )
    ) {
      task.permission_request = null;
      this.refreshCapabilityProfile(task);
      host.save();
      return { statusCode: 200 };
    }
    await this.expirePermissions(task, host);
    const grant = cached ? null : this.grantForAction(task, attachment, window);
    if (!cached && !grant) {
      const request = this.ensurePermissionRequest(task, attachment, window, host);
      return {
        statusCode: 403,
        body: {
          error: "permission_required",
          permission_required: true,
          request_id: request.request_id,
        },
      };
    }
    let permissionScope = "cache";
    let permissionGrantId = null;
    if (cached) {
      task.permission_request = null;
      this.refreshCapabilityProfile(task);
    } else {
      permissionScope = grant.scope;
      permissionGrantId = grant.grant_id;
      consumeCapabilityGrant(grant);
      if (grant.scope === "one-time") {
        host.appendEvent({
          type: "permission.consumed",
          grant_id: grant.grant_id,
          capability: grant.capability,
          task_id: grant.task_id,
          scope: grant.scope,
          consumed_at: grant.consumed_at,
        });
      }
    }

    host.setSubmitting(true);
    const previousPanel = host.getPanel();
    let result;
    try {
      result = await this.broker.analyze({
        taskId: task.task_id,
        attachment,
        window,
        preset: chartPreset,
      });
    } catch (error) {
      const normalized =
        error instanceof TelemetryBrokerError
          ? error
          : new TelemetryBrokerError(
              "analysis_failed",
              `Analysis failed: ${error.message}`,
            );
      host.setPanel(analysisFailure(previousPanel, normalized, task.objective));
      host.setError(null);
      host.pushTimeline(
        "tool",
        `本地分析拒绝了 ${attachment.original_name}：${normalized.message}`,
      );
      host.appendEvent({
        type: "action.failed",
        action_id: actionId,
        code: normalized.code,
        attachment_id: attachment.id,
        task_id: task.task_id,
        session_ref: host.getSessionReference(),
        message: normalized.message,
        details: normalized.details,
      });
      host.archive();
      host.save();
      host.setSubmitting(false);
      return { statusCode: 200 };
    }
    const resultArtifacts = Array.isArray(result.artifacts)
      ? result.artifacts.filter(Boolean)
      : result.artifact
        ? [result.artifact]
        : [];

    host.setRunning();
    const activityLabel = `分析数据：${attachment.original_name}`;
    host.beginActivity(activityLabel, randomUUID());
    const packet = {
      schema_version: "1.0",
      type: "panel_tool_result",
      event_id: randomUUID(),
      created_at: new Date().toISOString(),
      task_id: task.task_id,
      session_ref: host.getSessionReference(),
      attachment_id: attachment.id,
      task_context:
        typeof host.isSourceHosted === "function" && host.isSourceHosted()
          ? host.buildSourceHostedTaskContext()
          : host.buildTaskContext(),
      tool_result: {
        tool: "skill.local_action",
        read_only: true,
        cache_hit: result.cache_hit,
        attachment: result.attachment,
        analysis: result.analysis,
        chart_preset: result.chart_preset ?? chartPreset,
        artifact: result.artifact,
        artifacts: resultArtifacts,
        instruction:
          resultArtifacts.length > 0
            ? "Treat local analyzer metrics, sampled_span_seconds, window, warnings, and artifact metadata as authoritative. Preserve the artifact array as one evidence-only chart pack; keep any conclusion separate. State the telemetry span exactly; never reinterpret device age or driver age as sample duration."
            : "Treat the local analyzer summary, sampled_span_seconds, window, warnings, and uncertainty as authoritative. No chart was requested for this analysis; do not invent an artifact. State the telemetry span exactly; never reinterpret device age or driver age as sample duration.",
      },
    };
    host.appendEvent({ type: "ui.panel_tool_result", packet });
    host.save();
    if (
      typeof host.isSourceHosted === "function" &&
      host.isSourceHosted()
    ) {
      for (const artifact of resultArtifacts) {
        if (!task.artifacts.some((existing) => existing.id === artifact.id)) {
          task.artifacts.push(artifact);
        }
      }
      task.actions ??= [];
      task.actions.push({
        id: `action-${randomUUID()}`,
        action_id: actionId,
        attachment_id: attachment.id,
        source_sha256: attachment.sha256,
        window: packet.tool_result.analysis.requested_window,
        chart_preset: result.chart_preset ?? chartPreset,
        cache_hit: result.cache_hit,
        artifact_id: resultArtifacts[0]?.id ?? null,
        artifact_ids: resultArtifacts.map((artifact) => artifact.id),
        permission_scope: permissionScope,
        permission_grant_id: permissionGrantId,
        local_completed_at: new Date().toISOString(),
        source_result_pending: true,
      });
      task.permission_request = null;
      this.refreshCapabilityProfile(task);
      host.setSourceHostedToolResult({ packet, result });
      host.pushTimeline(
        "tool",
        `本地分析完成 ${attachment.original_name}：` +
          `${packet.tool_result.analysis.analyzed_rows} 行；` +
          (resultArtifacts.length > 0
            ? "证据图表包已生成，等待来源 Agent 返回结论。"
            : "摘要已生成，等待来源 Agent 返回结论。"),
      );
      host.appendEvent({
        type: "action.local_completed",
        action_id: actionId,
        attachment_id: attachment.id,
        chart_preset: result.chart_preset ?? chartPreset,
        artifact_id: resultArtifacts[0]?.id ?? null,
        artifact_ids: resultArtifacts.map((artifact) => artifact.id),
        cache_hit: result.cache_hit,
        task_id: task.task_id,
        session_ref: host.getSessionReference(),
        source_result_pending: true,
      });
      host.save();
      host.setSubmitting(false);
      return {
        statusCode: 202,
        body: {
          source_hosted_pending: true,
          artifact_ref: resultArtifacts[0]?.id ?? null,
          artifact_refs: resultArtifacts.map((artifact) => artifact.id),
        },
      };
    }
    try {
      const agentResult = await host.runAgent(packet);
      host.setAgentError(null);
      const panel = this.validatePanelResult(
        this.broker.applyVerifiedResult(agentResult.panel, result, {
          taskId: task.task_id,
        }),
        { packet },
      );
      host.setPanel(panel);
      host.setPhase(panel.status === "needs_input" ? "needs_input" : panel.status);
      host.setLastTurn(agentResult.turnId);
      host.updateTaskFromPanel(panel);
      for (const artifact of resultArtifacts) {
        if (!task.artifacts.some((existing) => existing.id === artifact.id)) {
          task.artifacts.push(artifact);
        }
      }
      task.actions ??= [];
      task.actions.push({
        id: `action-${randomUUID()}`,
        action_id: actionId,
        attachment_id: attachment.id,
        source_sha256: attachment.sha256,
        window: (resultArtifacts[0]?.source_evidence_ids?.length ?? 0) > 0
          ? packet.tool_result.analysis.requested_window
          : null,
        chart_preset: result.chart_preset ?? chartPreset,
        cache_hit: result.cache_hit,
        artifact_id: resultArtifacts[0]?.id ?? null,
        artifact_ids: resultArtifacts.map((artifact) => artifact.id),
        permission_scope: permissionScope,
        permission_grant_id: permissionGrantId,
        completed_at: new Date().toISOString(),
      });
      host.completeActivity({ turnId: agentResult.turnId, panel });
      task.permission_request = null;
      this.refreshCapabilityProfile(task);
      host.pushTimeline(
        "tool",
        `本地分析完成 ${attachment.original_name}：${packet.tool_result.analysis.analyzed_rows} 行。`,
      );
      host.pushTimeline("agent", panel.turn_summary);
      host.archive();
      host.appendEvent({
        type: "action.completed",
        action_id: actionId,
        attachment_id: attachment.id,
        chart_preset: result.chart_preset ?? chartPreset,
        artifact_id: resultArtifacts[0]?.id ?? null,
        artifact_ids: resultArtifacts.map((artifact) => artifact.id),
        cache_hit: result.cache_hit,
        task_id: task.task_id,
        session_ref: host.getSessionReference(),
      });
      host.appendEvent({
        type: "agent.panel_updated",
        turn_id: agentResult.turnId,
        summary: panel.turn_summary,
      });
      return { statusCode: 200 };
    } catch (error) {
      const agentError = host.recordAgentError(error);
      host.setAgentThread(host.getAgentReference());
      host.setPhase("error");
      task.phase = "error";
      host.setError(agentError.message);
      host.failActivity(agentError);
      host.appendEvent({
        type: "agent.turn_error",
        message: agentError.message,
        error_class: agentError.classification,
        error_code: agentError.code,
      });
      return { statusCode: 502 };
    } finally {
      host.setSubmitting(false);
      host.save();
    }
  }

  getArtifact(id, context = {}) {
    return this.broker.getArtifact(id, context);
  }

  buildHandoffContext({ task }) {
    const context = this.publicContext(task);
    return {
      title: "设备与证据",
      lines: [
        `- 设备快照：${context.fields[0]?.value ?? "未知"} · ${context.fields[1]?.value ?? "日期未知"}`,
        `- 设备：${context.fields[0]?.value ?? "未知"}`,
        `- 配置日期：${context.fields[1]?.value ?? "未知"}`,
        `- 共享引用：${context.fields[3]?.value ?? "0 条"}`,
        `- 设备引用：${task?.domain_state?.device_snapshot_ref ?? "未记录"}`,
      ],
      data: {
        device_snapshot_ref: task?.domain_state?.device_snapshot_ref ?? null,
        domain_refs: task?.domain_refs ?? [],
      },
    };
  }
}
