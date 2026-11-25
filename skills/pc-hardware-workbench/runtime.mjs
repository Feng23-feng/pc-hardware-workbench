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

export function enforceDisplayEvidenceContract(panel, packet) {
  if (
    !["1.1", "1.2"].includes(panel.schema_version) ||
    !/黑屏|掉帧|帧数暴降/iu.test(JSON.stringify(packet))
  ) {
    return panel;
  }
  const required = [
    {
      test: /固定|同一场景|复现/u,
      recommendation: {
        id: "runtime-fixed-scene",
        title: "固定同一场景复测",
        detail:
          "保持游戏、场景、画质和操作路线一致，记录每次黑屏或掉帧的精确本地时间、持续秒数和是否退出游戏。",
        risk: "low",
        evidence_goal: "确认是否稳定复现，并建立可与系统日志关联的时间锚点。",
      },
    },
    {
      test: /事件查看器|Event Viewer|TDR|WHEA|Kernel-Power/iu,
      recommendation: {
        id: "runtime-event-check",
        title: "检查显示与异常事件",
        detail:
          "在事件查看器中只读查看黑屏前后的 Display TDR、WHEA-Logger 和 Kernel-Power 41，不要据此单独判定硬件故障。",
        risk: "low",
        evidence_goal: "区分显示驱动重置、硬件错误和异常断电。",
      },
    },
    {
      test: /HWiNFO|PerfCap|有效频率|GPU.*功耗/iu,
      recommendation: {
        id: "runtime-hwinfo-gpu",
        title: "记录一次 GPU 运行证据",
        detail:
          "用 HWiNFO Sensors-only 记录同一复现场景中的 GPU 温度、功耗、有效频率和 PerfCap，结束后保存 CSV。",
        risk: "low",
        evidence_goal: "判断异常时是否存在降频、功耗限制或温度限制。",
      },
    },
  ];
  const recommendations = required.map((requirement) => {
    return (
      panel.recommendations.find((item) =>
        requirement.test.test(`${item.title} ${item.detail}`),
      ) ?? requirement.recommendation
    );
  });
  return { ...panel, recommendations };
}

function analysisFailure(previousPanel, error, objective) {
  const previousEvidence = Array.isArray(previousPanel?.evidence)
    ? previousPanel.evidence.slice(0, 6)
    : [];
  const previousRecommendations =
    Array.isArray(previousPanel?.recommendations) &&
    previousPanel.recommendations.length >= 2
      ? previousPanel.recommendations.slice(0, 3)
      : [
          {
            id: "capture-supported-data",
            title: "使用运行时支持的传感器列",
            detail:
              "重新导出包含明确时间列和传感器名称的数据；不要通过改列名伪造已识别的测量。",
            risk: "low",
            evidence_goal: "让本地分析器能够验证列语义、单位和时间窗口。",
          },
          {
            id: "preserve-source-context",
            title: "保留故障时间与负载上下文",
            detail:
              "记录数据对应的工作负载、采样间隔和故障精确时间，再与系统事件按同一窗口对照。",
            risk: "low",
            evidence_goal: "避免把无上下文的数值窗口解释成稳定性结论。",
          },
        ];
  const details = (error?.details ?? []).filter(Boolean).slice(0, 4);
  return {
    schema_version: "1.2",
    turn_summary: "本地 Skill Runtime 未能从这份数据生成可信图表。",
    current_goal: previousPanel?.current_goal || objective || "检查数据格式",
    status:
      previousPanel?.status === "ready" || previousPanel?.status === "blocked"
        ? previousPanel.status
        : "needs_input",
    judgement:
      "本地分析器没有找到可绘制的数值传感器列，因此没有生成图表，也没有让 Agent 猜测数据结构。原文件仍保留在当前 Task 中。",
    question: previousPanel?.question ?? null,
    recommendation: previousPanel?.recommendation ?? {
      summary: "先修正数据来源或窗口，再重新分析；本轮不会自动重试。",
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
      title: "换用可识别的传感器列",
      detail:
        "保留原始文件，重新导出带明确时间、传感器名称和单位的记录后再分析；不要修改列名冒充已识别指标。",
    },
    actions: [
      {
        id: "copy-analysis-recovery",
        label: "复制修正要求",
        kind: "copy",
        content:
          "保留原始数据；重新导出包含时间、明确传感器名称和单位的记录，并记录工作负载、采样间隔和故障时间。不要修改列名冒充已识别指标。",
      },
    ],
    artifact_refs: [],
    blocks: [
      {
        id: "analysis-failure-callout",
        type: "callout",
        title: "无法生成图表",
        text:
          "本地分析返回了确定性失败。没有创建图表，也没有发送模型回合；请修正列语义或采样窗口后再试。",
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
      "Every turn must include a substantive result card with judgement, supports/conflicts/context evidence, uncertainty, two or three low-risk evidence recommendations, one priorityAction, and copy-only actions.",
      "Set uncertainty[0] to the single current unresolved item, using a compact subject-based label such as '热限制待确认' only when the current evidence actually supports that subject. Replace or omit a resolved item; never hard-code thermal, power, or a placeholder status.",
      "For single-game brief black screens or stutter, recommendations must cover a fixed-scene retest with precise timestamp, a read-only Event Viewer check for Display TDR, WHEA-Logger and Kernel-Power 41, and HWiNFO logging of GPU temperature, power, effective clock and PerfCap.",
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
    return enforceDisplayEvidenceContract(
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
    if (
      !localResult?.analysis ||
      (!localResult?.artifact && !localResult?.artifacts?.length)
    ) {
      throw new this.SkillRuntimeError(
        "source_result_missing_verified_tool",
        "Source-hosted PCHW result requires a verified local analysis.",
      );
    }
    return this.validatePanelResult(
      this.broker.applyVerifiedResult(panel, localResult),
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
    const chartPreset = input.chart_preset ?? "FirstPass";
    let cached;
    try {
      cached = this.broker.findCached({
        taskId: task.task_id,
        attachment,
        window,
        preset: chartPreset,
      });
      this.broker.validateAttachment(attachment);
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
        artifacts: result.artifacts ?? [result.artifact],
        instruction:
          "Treat local analyzer metrics, sampled_span_seconds, window, warnings, and artifact metadata as authoritative. Preserve the artifact array as one evidence-only chart pack; keep any conclusion separate. State the telemetry span exactly; never reinterpret device age or driver age as sample duration.",
      },
    };
    host.appendEvent({ type: "ui.panel_tool_result", packet });
    host.save();
    if (
      typeof host.isSourceHosted === "function" &&
      host.isSourceHosted()
    ) {
      for (const artifact of result.artifacts ?? [result.artifact]) {
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
        artifact_id: result.artifact.id,
        artifact_ids: (result.artifacts ?? [result.artifact]).map(
          (artifact) => artifact.id,
        ),
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
          "证据图表包已生成，等待来源 Agent 返回结论。",
      );
      host.appendEvent({
        type: "action.local_completed",
        action_id: actionId,
        attachment_id: attachment.id,
        chart_preset: result.chart_preset ?? chartPreset,
        artifact_id: result.artifact.id,
        artifact_ids: (result.artifacts ?? [result.artifact]).map(
          (artifact) => artifact.id,
        ),
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
          artifact_ref: result.artifact.id,
          artifact_refs: (result.artifacts ?? [result.artifact]).map(
            (artifact) => artifact.id,
          ),
        },
      };
    }
    try {
      const agentResult = await host.runAgent(packet);
      host.setAgentError(null);
      const panel = this.validatePanelResult(
        this.broker.applyVerifiedResult(agentResult.panel, result),
        { packet },
      );
      host.setPanel(panel);
      host.setPhase(panel.status === "needs_input" ? "needs_input" : panel.status);
      host.setLastTurn(agentResult.turnId);
      host.updateTaskFromPanel(panel);
      for (const artifact of result.artifacts ?? [result.artifact]) {
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
        window: result.artifact.source_evidence_ids.length > 0
          ? packet.tool_result.analysis.requested_window
          : null,
        chart_preset: result.chart_preset ?? chartPreset,
        cache_hit: result.cache_hit,
        artifact_id: result.artifact.id,
        artifact_ids: (result.artifacts ?? [result.artifact]).map(
          (artifact) => artifact.id,
        ),
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
        artifact_id: result.artifact.id,
        artifact_ids: (result.artifacts ?? [result.artifact]).map(
          (artifact) => artifact.id,
        ),
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

  getArtifact(id) {
    return this.broker.getArtifact(id);
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
