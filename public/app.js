import { clearResetDraftStorage } from "/draft-storage.js";
import { deriveActivityMode } from "/status-model.js";
import {
  evaluateRuntimeBinding,
  parseRuntimeBindingHint,
  parseRuntimeBindingQuery,
} from "/runtime-binding.js";
import {
  evaluateSourceHostedPhase,
} from "/source-hosted-phase.js";

const app = document.querySelector("#app");
const runtimeStatus = document.querySelector("#runtime-status");
const runtimeDot = document.querySelector(".status-dot");
const saveStatus = document.querySelector("#save-status");

let state = null;
let freeText = "";
let pollTimer = null;
let pollInFlight = false;
let lastPollStateKey = "";
let stateRefreshSequence = 0;
let lastAppliedStateRefresh = 0;
let sourceResultPollingActive = false;
let noticeText = "";
let submitPending = false;
let optimisticPhase = null;
let optimisticActivity = null;
let transientReplyAt = 0;
let statusTicker = null;
let replyTransitionTimer = null;
let titleTimer = null;
let uploadingAttachments = false;
let analysisPending = null;
let resumePacketPreview = "";
let resumeFeedback = "";
let resumePending = false;
let permissionPending = false;
let permissionContinuationPending = false;
let recoveryPending = false;
let runtimeBinding = null;
let runtimeBindingFailure = null;
let runtimeBindingHealth = null;
let runtimeBindingCheckedAt = 0;
let runtimeBindingInFlight = null;
let runtimeBindingTimer = null;

function el(tag, attributes = {}, children = []) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (name === "class") {
      node.className = value;
    } else if (name === "text") {
      node.textContent = value;
    } else if (name.startsWith("on")) {
      node.addEventListener(name.slice(2), value);
    } else if (value !== null && value !== undefined && value !== false) {
      node.setAttribute(name, value === true ? "" : value);
    }
  }
  for (const child of Array.isArray(children) ? children : [children]) {
    if (child === null || child === undefined || child === false) {
      continue;
    }
    node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

function stripHeadingPunctuation(value) {
  return value.replace(/[，。！？；：、]/gu, " ").replace(/\s+/g, " ").trim();
}

function relationLabel(relation) {
  return (
    {
      supports: "支持",
      conflicts: "冲突",
      context: "背景",
    }[relation] ?? "背景"
  );
}

function normalizeResult(panel) {
  if (!panel) {
    return null;
  }
  if (panel.schema_version === "1.1" || panel.schema_version === "1.2") {
    return {
      judgement: panel.judgement,
      evidence: panel.evidence,
      uncertainty: panel.uncertainty,
      recommendations: panel.recommendations,
      priorityAction: panel.priorityAction,
      actions: panel.actions,
      blocks: panel.blocks ?? [],
      artifacts: panel.artifact_refs ?? [],
    };
  }
  const checklist =
    "保留当前 Task 输入；补充可重复步骤、精确时间和可验证的本地结果；" +
    "按当前 Skill 声明的能力执行本地检查，再决定下一步。";
  return {
    judgement:
      panel.turn_summary
        ? `当前只能确认：${panel.turn_summary} 还需要补充可验证上下文。`
        : "当前信息还不足以判断具体问题，需要先补充可验证上下文。",
    evidence: (panel.evidence ?? []).map((item) => ({
      ...item,
      relation: "context",
    })),
    uncertainty:
      panel.limitations?.length
        ? panel.limitations
        : ["尚未取得当前 Skill 可验证的本地结果。"],
    recommendations: [
      {
        id: "legacy-repeatable-input",
        title: "补全可重复输入",
        detail:
          "记录同一输入、时间范围和环境条件，让本地结果能够与当前 Task 对齐。",
        risk: "unknown",
        evidence_goal: "确认输入可以重复，并建立时间锚点。",
      },
      {
        id: "legacy-skill-context",
        title: "补充 Skill 上下文",
        detail:
          "提供当前 Skill 要求的输入或附件；未知能力不会被自动执行。",
        risk: "unknown",
        evidence_goal: "让本地验证与用户目标连接起来。",
      },
      {
        id: "legacy-agent-question",
        title: "回答 Agent 的下一步问题",
        detail:
          panel.next_action || "先补充一项最能区分当前判断的信息。",
        risk: "unknown",
        evidence_goal: "减少当前判断的不确定性。",
      },
    ],
    priorityAction: {
      title: "先补充最有区分度的一项信息",
      detail:
        panel.next_action ||
        "补充当前 Skill 可以验证的信息，再决定是否执行本地能力。",
    },
    actions: [
      {
        id: "legacy-copy",
        label: "复制下一步清单",
        kind: "copy",
        content: checklist,
      },
    ],
    blocks: [],
    artifacts: [],
  };
}

function formatElapsed(milliseconds) {
  const seconds = Math.max(1, Math.ceil(milliseconds / 1000));
  if (seconds < 60) {
    return `${seconds} 秒`;
  }
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds % 60;
  return `${minutes} 分 ${remainder} 秒`;
}

function displayActivity() {
  if ((submitPending || state?.phase === "running") && optimisticActivity) {
    return optimisticActivity;
  }
  if (state?.activity) {
    return state.activity;
  }
  if (state?.panel) {
    return {
      status: "completed",
      user_summary: "",
      submitted_at: state.last_turn?.completed_at ?? null,
      started_at: state.last_turn?.completed_at ?? null,
      completed_at: state.last_turn?.completed_at ?? null,
      agent_summary: state.panel.turn_summary ?? "",
      next_action: state.panel.next_action ?? "",
      error: null,
    };
  }
  return null;
}

function submissionSummary() {
  const selected = selectedOption();
  const pendingEvidence = (state?.draft?.events ?? [])
    .filter((event) => event.type === "evidence_added")
    .map((event) => event.label);
  const attachments = state?.draft?.attachments ?? [];
  return [
    selected ? `选择：${selected.label}` : "",
    freeText.trim() ? `补充：${freeText.trim()}` : "",
    pendingEvidence.length ? `证据：${pendingEvidence.join("、")}` : "",
    attachments.length
      ? `附件：${attachments.map((item) => item.original_name).join("、")}`
      : "",
  ]
    .filter(Boolean)
    .join("；");
}

function activityMode() {
  return deriveActivityMode({
    phase: state?.phase,
    panel: state?.panel,
    activity: state?.activity,
    submitPending,
    optimisticPhase,
    optimisticStartedAt: optimisticActivity?.submitted_at
      ? Date.parse(optimisticActivity.submitted_at)
      : null,
    transientReplyAt,
    now: Date.now(),
  });
}

function userFacingErrorText(value) {
  const text = String(value ?? "").trim();
  if (
    text.includes("panel_turn_forbidden_in_source_hosted") ||
    text.includes("panel-owned model Turn")
  ) {
    return "本次本地结果没有进入面板结论。可以恢复当前 Task 后重新继续，不会新建 Thread。";
  }
  return text || "可恢复当前 Task 后重试本轮。";
}

function statusCopy(mode) {
  const activity = displayActivity();
  if (mode === "sent") {
    return {
      label: "已发送",
      detail: "已发送，正在等待 Agent 接收本轮内容。",
    };
  }
  if (mode === "processing") {
    return {
      label: "Agent 正在判断",
      detail: "Agent 正在阅读本轮记录并准备下一步。",
    };
  }
  if (mode === "waiting_for_source") {
    return {
      label: "正在等待来源 Agent",
      detail:
        "本地分析、SVG 和指标已保存。请保持页面打开；来源 Agent 写回结论后会自动显示，无需刷新页面。",
    };
  }
  if (mode === "replied") {
    return {
      label: "Agent 已回复",
      detail: "回复已收到，正在更新当前问题和下一步。",
    };
  }
  if (mode === "error") {
    return {
      label: "Agent 回复失败",
      detail: userFacingErrorText(state.error || activity?.error),
    };
  }
  if (mode === "interrupted") {
    return {
      label: "任务已中断",
      detail: userFacingErrorText(state.error),
    };
  }
  if (mode === "completed") {
    return {
      label: "本轮结果已生成",
      detail: "请查看当前判断、未决问题和最优先行动。",
    };
  }
  if (mode === "blocked") {
    return {
      label: "任务已停止",
      detail:
        normalizeResult(state.panel)?.priorityAction?.title ||
        "请查看本轮判断中的限制。",
    };
  }
  if (state.panel && activity?.agent_summary) {
    return {
      label: "Agent 已回复",
      detail: "等待你操作。请阅读本轮判断并完成下面的下一步。",
    };
  }
  return {
    label: "等待你操作",
    detail: state.panel
      ? "Agent 已回复，请完成下面的下一步。"
      : "描述当前问题后发送给 Agent。",
  };
}

function statusElapsedText(mode) {
  if (mode !== "sent" && mode !== "processing") {
    return "";
  }
  const startedAt = displayActivity()?.submitted_at;
  const started = Date.parse(startedAt ?? "");
  return Number.isFinite(started)
    ? `已等待 ${formatElapsed(Date.now() - started)}`
    : "正在等待";
}

function focusCurrentAction() {
  document.querySelector("#primary-focus")?.scrollIntoView({
    behavior: "smooth",
    block: "start",
  });
  requestAnimationFrame(() => {
    document
      .querySelector(
        "#symptom, input[name='panel-option'], #supplement, #send-button",
      )
      ?.focus();
  });
}

function focusAnswerCard() {
  const target =
    document.querySelector("#answer-card") ||
    document.querySelector("#primary-focus");
  target?.scrollIntoView({
    behavior: "smooth",
    block: "start",
  });
  if (target?.id === "answer-card") {
    target.setAttribute("tabindex", "-1");
    requestAnimationFrame(() => target.focus());
  }
}

async function writeClipboardText(content) {
  let clipboardError = null;
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(content);
      return;
    } catch (error) {
      clipboardError = error;
    }
  }

  const activeElement = document.activeElement;
  const fallback = document.createElement("textarea");
  fallback.value = content;
  fallback.setAttribute("readonly", "");
  fallback.setAttribute("aria-hidden", "true");
  fallback.style.position = "fixed";
  fallback.style.inset = "0 auto auto 0";
  fallback.style.opacity = "0";
  fallback.style.pointerEvents = "none";
  document.body.appendChild(fallback);
  try {
    fallback.focus();
    fallback.select();
    fallback.setSelectionRange(0, content.length);
    if (!document.execCommand("copy")) {
      throw clipboardError ?? new Error("copy command was rejected");
    }
  } finally {
    fallback.remove();
    activeElement?.focus?.();
  }
}

async function copyText(
  content,
  button,
  successLabel = "已复制",
  failureMessage = "浏览器没有允许自动复制。请手动输入“同步面板”，或选中页面中的文字复制。",
) {
  const original = button.textContent;
  try {
    await writeClipboardText(content);
    button.textContent = successLabel;
    setTimeout(() => {
      button.textContent = original;
    }, 2_800);
  } catch {
    noticeText = failureMessage;
    render();
  }
}

function copyButton(
  label,
  content,
  className = "secondary",
  {
    successLabel = "已复制",
    failureMessage = "浏览器没有允许自动复制。请手动输入“同步面板”，或选中页面中的文字复制。",
  } = {},
) {
  const button = el("button", {
    class: className,
    type: "button",
    text: label,
    "aria-live": "polite",
  });
  button.addEventListener("click", () =>
    copyText(content, button, successLabel, failureMessage),
  );
  return button;
}

async function bringResumeToAgent(button) {
  if (resumePending) {
    return;
  }
  resumePending = true;
  resumeFeedback = "正在整理可带回合话的 Resume 摘要…";
  render();
  const result = await requestJson("/api/resume-packet");
  resumePending = false;
  if (!result.ok) {
    resumeFeedback =
      result.data?.error ?? "Resume 摘要生成失败；当前任务没有被修改。";
    render();
    return;
  }
  resumePacketPreview = result.data.markdown ?? "";
  try {
    await writeClipboardText(resumePacketPreview);
    resumeFeedback =
      "续接摘要已复制。回到来源 Agent 对话粘贴即可继续；来源对话未被修改。";
  } catch {
    resumeFeedback =
      "续接摘要已生成。请展开下方内容手动复制；来源对话未被修改。";
  }
  render();
  requestAnimationFrame(() => {
    document
      .querySelector(".resume-packet-preview summary")
      ?.focus?.();
  });
}

function sourceHostedPhaseState() {
  return evaluateSourceHostedPhase({
    mode: state?.task?.shared_task?.mode,
    phase: state?.task?.shared_task?.phase,
  });
}

function sourceHostedRecoveryAvailable() {
  const phaseState = sourceHostedPhaseState();
  return (
    state.task?.shared_task?.mode === "source_hosted" &&
    (
      state.phase === "error" ||
      state.phase === "interrupted" ||
      phaseState.recovery_available
    )
  );
}

function renderPrimaryStatusBlock() {
  const mode = activityMode();
  const copy = statusCopy(mode);
  const activity = displayActivity();
  const answer = normalizeResult(state.panel);
  const waitingForSource = mode === "waiting_for_source";
  const sourceHostedRecovery = sourceHostedRecoveryAvailable();
  const steps = waitingForSource
    ? [
        ["本地分析完成", "local-done"],
        ["等待当前对话 Agent", "source-waiting"],
        ["结果回到页面", "result-returned"],
      ]
    : [
        ["已发送", "sent"],
        ["Agent 处理中", "processing"],
        ["Agent 已回复", "replied"],
        ["等待你操作", "waiting"],
      ];
  const currentIndex =
    waitingForSource
      ? 1
      : mode === "sent"
      ? 0
      : mode === "processing"
        ? 1
        : mode === "replied"
          ? 2
          : 3;
  return el(
    "section",
    {
      class: `primary-status status-${mode}${activity?.agent_summary ? " has-agent-reply" : ""}`,
      id: "status-block",
      role: "status",
      "aria-live": "polite",
      "aria-atomic": "true",
    },
    [
      el("div", { class: "status-main" }, [
        el("div", { class: "status-title-row" }, [
          el("h2", { class: "status-title", text: copy.label }),
          mode === "sent" || mode === "processing"
            ? el("span", {
                class: "status-time",
                id: "activity-elapsed",
                text: statusElapsedText(mode),
              })
            : null,
        ]),
        el("p", { class: "status-detail", text: copy.detail }),
      ]),
      el(
        "ol",
        { class: "status-steps", "aria-label": "本轮进度" },
        steps.map(([label, key], index) =>
          el(
            "li",
            {
              class:
                mode === "error" || mode === "interrupted"
                  ? index === 1
                    ? "is-error"
                    : index < 1
                      ? "is-done"
                      : ""
                  : index < currentIndex
                    ? "is-done"
                    : index === currentIndex
                      ? "is-current"
                      : "",
            },
            [
              el("span", { class: "step-dot", "aria-hidden": "true" }),
              el("span", { text: label }),
            ],
          ),
        ),
      ),
      mode !== "sent" && mode !== "processing"
        ? el("div", { class: "status-next" }, [
            el("span", { class: "status-next-label", text: "现在需要你" }),
            el("p", {
              text:
                waitingForSource
                  ? "无需操作；来源 Agent 返回结论后页面会自动更新。"
                  : sourceHostedRecovery
                    ? sourceHostedPhaseState().recovery_available
                      ? "归档当前卡住的 cycle，并恢复为可提交状态。"
                      : "保留当前 Task，清除错误并恢复可重试状态。"
                    : mode === "error" || mode === "interrupted"
                      ? "检查本地连接后重试本轮，或新建任务。"
                      : answer
                        ? "查看本地验证结果与唯一优先行动。"
                        : state.panel?.next_action ||
                          "先描述电脑现在遇到的问题。",
            }),
            waitingForSource
              ? el("button", {
                  class: "status-action",
                  id: "source-result-auto-refresh",
                  type: "button",
                  disabled: true,
                  text: "等待自动刷新…",
                })
              : el("button", {
                  class: "status-action",
                  type: "button",
                  text:
                    sourceHostedRecovery
                      ? recoveryPending
                        ? "正在恢复…"
                        : "恢复当前 Task"
                      : mode === "error" || mode === "interrupted"
                        ? "检查并重试"
                        : answer
                          ? "查看结果"
                          : "填写问题",
                  disabled:
                    sourceHostedRecovery
                      ? recoveryPending
                      : (mode === "error" || mode === "interrupted") &&
                        !canSubmit(),
                  onclick:
                    sourceHostedRecovery
                      ? recoverSourceHostedTask
                      : mode === "error" || mode === "interrupted"
                        ? sendSubmission
                        : answer
                          ? focusAnswerCard
                          : focusCurrentAction,
                }),
          ])
        : null,
    ],
  );
}

function renderHandoffCard() {
  if (!state.task?.task_id) {
    return null;
  }
  const handoff = state.handoff ?? {};
  const attached = handoff.native_thread_attached === true;
  return el("section", { class: "handoff-strip", "aria-label": "任务来源" }, [
    el("div", { class: "handoff-strip-main" }, [
      el("div", { class: "handoff-copy" }, [
        el("h2", {
          text: attached ? "返回 Agent 对话" : "把本轮结果带回 Agent 对话",
        }),
        el("p", {
          text: attached
            ? "回到来源对话，输入“同步面板”即可带回本轮判断、未决问题和建议。"
            : "回到当前 Codex 对话，输入“同步面板”即可带回本轮判断、未决问题和建议。当前面板是独立 Task，不会自动接管原对话。",
        }),
      ]),
      el("div", { class: "handoff-actions" }, [
        copyButton("复制“同步面板”", "同步面板", "primary", {
          successLabel: "已复制 · 回对话粘贴",
          failureMessage:
            "自动复制未成功；请在当前 Codex 对话里手动输入“同步面板”。",
        }),
        el("button", {
          class: "secondary handoff-return",
          type: "button",
          disabled: resumePending,
          text: resumePending ? "正在整理…" : "导出续接摘要",
          onclick: (event) => bringResumeToAgent(event.currentTarget),
        }),
      ]),
    ]),
    el("p", {
      class: "handoff-note",
      text: "“复制本次遥测摘要”只复制内容，不携带 Task 游标；需要继续任务时用“同步面板”或“导出续接摘要”。",
    }),
    resumeFeedback
      ? el("p", { class: "handoff-feedback", role: "status", text: resumeFeedback })
      : null,
    resumePacketPreview
      ? el("details", { class: "resume-packet-preview" }, [
          el("summary", { text: "查看 Resume 摘要" }),
          el("pre", { text: resumePacketPreview }),
          copyButton("复制 Resume 摘要", resumePacketPreview),
        ])
      : null,
  ]);
}

function renderEndHandoff() {
  if (!state.task?.task_id) {
    return null;
  }
  return el("section", {
    class: "end-handoff",
    "aria-label": "结束本轮并带回 Agent 对话",
  }, [
    el("div", { class: "end-handoff-copy" }, [
      el("h2", { text: "把这轮结果带回 Agent 对话" }),
      el("p", {
        text:
          "可以直接在这里复制“同步面板”；也可以回到上方“任务来源”卡片点击同一按钮。",
      }),
    ]),
    copyButton("复制“同步面板”", "同步面板", "secondary", {
      successLabel: "已复制 · 回对话粘贴",
      failureMessage:
        "自动复制未成功；请在当前 Codex 对话里手动输入“同步面板”。",
    }),
  ]);
}

function permissionExpiryLabel(value) {
  const time = Date.parse(value ?? "");
  return Number.isFinite(time)
    ? new Date(time).toLocaleString("zh-CN", {
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
      })
    : "期限未知";
}

function renderPermissionCard() {
  const request = state.task?.permission_request;
  if (!request) {
    return null;
  }
  const presentation = request.presentation ?? {};
  const phaseCanDecide = sourceHostedPhaseState().can_decide_permission;
  const facts = Array.isArray(presentation.facts)
    ? presentation.facts
    : [
        {
          label: "资源",
          value: request.attachment_name ?? request.capability,
        },
        {
          label: "Capability",
          value: request.capability,
          format: "code",
        },
      ];
  if (request.status === "pending") {
    return el(
      "section",
      {
        class: "permission-card",
        id: "permission-card",
        "aria-labelledby": "permission-title",
      },
      [
        el("div", { class: "permission-card-heading" }, [
          el("div", {}, [
            el("h2", {
              id: "permission-title",
              text: presentation.title ?? "允许本次本地操作？",
            }),
            el("p", {
              text:
                presentation.description ??
                "只授权当前 Skill 声明的本地能力，不会提升为通用命令或网络访问。",
            }),
          ]),
          el("span", {
            class: "permission-scope",
            text: presentation.scope_label ?? "只读监督",
          }),
        ]),
        el(
          "dl",
          { class: "permission-facts" },
          facts.flatMap((fact) => [
            el("dt", { text: fact.label }),
            el(
              "dd",
              {
                class:
                  fact.format === "code"
                    ? "data permission-hash"
                    : "",
              },
              fact.format === "code"
                ? el("code", { text: fact.value })
                : String(fact.value ?? ""),
            ),
          ]),
        ),
        el("div", { class: "permission-card-actions" }, [
          el("button", {
            class: "primary",
            type: "button",
            disabled: permissionPending || !phaseCanDecide,
            text:
              permissionPending
                ? "正在授权…"
                : presentation.allow_once_label ??
                  presentation.approve_label ??
                  "仅本次允许",
            onclick: () => decidePermissionRequest("allow_once"),
          }),
          el("button", {
            class: "secondary",
            type: "button",
            disabled: permissionPending || !phaseCanDecide,
            text: presentation.allow_task_label ?? "本 Task 允许",
            onclick: () => decidePermissionRequest("allow_task"),
          }),
          el("button", {
            class: "secondary",
            type: "button",
            disabled: permissionPending || !phaseCanDecide,
            text: presentation.deny_label ?? "拒绝",
            onclick: () => decidePermissionRequest("deny"),
          }),
        ]),
        el("p", {
          class: "permission-scope-note",
          text:
            presentation.task_scope_label ??
            "“仅本次”使用后即失效；“本 Task”只覆盖当前 Task 中声明的同类操作，并会过期。",
        }),
        el("p", {
          class: "permission-expiry",
          text: `请求有效至 ${permissionExpiryLabel(request.expires_at)}`,
        }),
      ],
    );
  }
  const approvedGrant = (state.task?.grants ?? []).find(
    (grant) =>
      grant.grant_id === request.approved_grant_id &&
      grant.status === "active",
  );
  if (request.status === "approved" && approvedGrant) {
    const continuing =
      permissionContinuationPending ||
      analysisPending === request.attachment_id;
    const completed = permissionAnalysisCompleted(request);
    return el("section", { class: "permission-card is-approved" }, [
      el("h2", {
        text: continuing
          ? "已允许，正在继续分析"
          : completed
            ? "已允许，本轮分析已完成"
            : presentation.approved_title ?? "已允许本次本地操作",
      }),
      el("p", {
        text: continuing
          ? "授权已保存，正在自动继续分析；不需要再次点击“继续分析”。"
          : completed
            ? "本地分析已自动继续并生成本轮结果，不需要再次点击“继续分析”。"
            : presentation.approved_text ??
              "授权仅覆盖当前 Skill 声明的资源和能力范围。",
      }),
      !continuing && !completed
        ? el("button", {
            class: "primary",
            type: "button",
            disabled: !phaseCanDecide,
            text: presentation.continue_label ?? "继续执行",
            onclick: () => continuePermissionRequest(approvedGrant),
          })
        : null,
    ]);
  }
  if (["denied", "expired"].includes(request.status)) {
    return el("section", { class: "permission-card is-denied" }, [
      el("h2", {
        text:
          request.status === "denied"
            ? presentation.denied_title ?? "已拒绝本次本地操作"
            : "本地操作授权请求已过期",
      }),
      el("p", {
        text: "没有执行本地能力，也没有生成 artifact。需要时可以重新请求。",
      }),
      el("button", {
        class: "secondary",
        type: "button",
        disabled: !phaseCanDecide,
        text: presentation.retry_label ?? "重新请求",
        onclick: () => continuePermissionRequest(),
      }),
    ]);
  }
  return null;
}

function permissionAnalysisCompleted(request) {
  const decidedAt = Date.parse(request?.decided_at ?? "");
  if (!Number.isFinite(decidedAt)) {
    return false;
  }
  return (state.panel?.artifact_refs ?? []).some((artifact) => {
    const createdAt = Date.parse(artifact.created_at ?? "");
    return (
      Number.isFinite(createdAt) &&
      createdAt >= decidedAt &&
      (artifact.source_evidence_ids ?? []).includes(request.attachment_id)
    );
  });
}

async function decidePermissionRequest(decision) {
  const request = state.task?.permission_request;
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_decide_permission) {
    noticeText = phaseState.reason;
    render();
    return;
  }
  if (!request || permissionPending) {
    return;
  }
  permissionPending = true;
  render();
  const result = await requestJson("/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: request.request_id,
      decision,
    }),
  });
  permissionPending = false;
  if (!result.ok) {
    noticeText = result.data?.error ?? "权限决定未能保存。";
    await refreshState();
    render();
    return;
  }
  state = result.data;
  if (decision === "deny") {
    render();
    return;
  }
  permissionContinuationPending = true;
  render();
  const updatedRequest = state.task?.permission_request;
  const approvedGrant = (state.task?.grants ?? []).find(
    (grant) =>
      grant.grant_id === updatedRequest?.approved_grant_id &&
      grant.status === "active",
  );
  const continued = await continuePermissionRequest(approvedGrant);
  if (!continued && !noticeText) {
    noticeText = "授权已经保存，但分析没有自动继续；请在授权卡中重试。";
    render();
  }
}

async function continuePermissionRequest(grant = null) {
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_decide_permission) {
    noticeText = phaseState.reason;
    permissionContinuationPending = false;
    render();
    return false;
  }
  const request = state.task?.permission_request;
  const continuation = request?.continuation ?? {};
  const actionId =
    continuation.action_id ??
    grant?.action_id ??
    request?.action_id ??
    request?.capability;
  const attachmentId =
    continuation.attachment_id ??
    grant?.attachment_id ??
    request?.attachment_id;
  const window = continuation.window ?? grant?.window ?? request?.window;
  if (!actionId || !attachmentId) {
    noticeText = "该权限请求没有可继续执行的本地动作。";
    permissionContinuationPending = false;
    render();
    return false;
  }
  permissionContinuationPending = true;
  render();
  let continued = false;
  try {
    continued = await runSkillAttachmentAction(
      actionId,
      attachmentId,
      window,
    );
  } finally {
    permissionContinuationPending = false;
    render();
  }
  return continued;
}

function renderTimeline() {
  const entries = state.task?.timeline ?? [];
  if (!entries.length) {
    return null;
  }
  return el("section", { class: "conversation", "aria-label": "本次任务记录" }, [
    el("h3", { class: "conversation-title", text: "本次任务记录" }),
    el(
      "ol",
      { class: "timeline-list" },
      entries.map((entry) =>
        el("li", { class: `timeline-entry timeline-${entry.role}` }, [
          el("span", {
            class: "timeline-role",
            text:
              entry.role === "user"
                ? "你"
                : entry.role === "tool"
                  ? "Workbench"
                  : "Agent",
          }),
          el("p", { text: entry.text }),
          renderAttachmentCards(entry.attachments ?? []),
        ]),
      ),
    ),
  ]);
}

function artifactById(artifacts, id) {
  return artifacts.find((artifact) => artifact.id === id) ?? null;
}

function renderAnalysisBlock(block, artifacts) {
  if (block.type === "metrics") {
    return el("section", { class: "analysis-block analysis-metrics" }, [
      el("h3", { class: "analysis-block-title", text: block.title }),
      el(
        "div",
        { class: "metric-ledger" },
        block.items.map((item) =>
          el("div", { class: "metric-item" }, [
            el("span", { class: "metric-label", text: item.label }),
            el("div", { class: "metric-reading" }, [
              el("strong", { text: item.value }),
              item.unit ? el("span", { text: item.unit }) : null,
            ]),
            el("span", {
              class: "metric-source",
              text: `源列：${item.source_column}`,
            }),
          ]),
        ),
      ),
    ]);
  }

  if (block.type === "chart") {
    const artifact = artifactById(artifacts, block.artifact_ref);
    if (!artifact || !artifact.safeToEmbed) {
      return el("section", { class: "analysis-block" }, [
        el("h3", { class: "analysis-block-title", text: block.title }),
        el("p", {
          class: "analysis-block-copy",
          text: "图表引用未通过本地安全检查。",
        }),
      ]);
    }
    return el("figure", { class: "analysis-chart" }, [
      el("figcaption", { text: block.title }),
      el("img", {
        src: `/api/artifacts/${encodeURIComponent(artifact.id)}/content`,
        alt: block.alt,
        loading: "lazy",
        decoding: "async",
      }),
      el("p", {
        class: "chart-caption",
        text: "Workbench 生成的 SVG 证据图；数值与窗口以本地分析结果为准。",
      }),
    ]);
  }

  if (block.type === "table") {
    return el("section", { class: "analysis-block" }, [
      el("h3", { class: "analysis-block-title", text: block.title }),
      el("div", { class: "analysis-table-wrap" }, [
        el("table", { class: "analysis-table" }, [
          el(
            "thead",
            {},
            el(
              "tr",
              {},
              block.columns.map((column) => el("th", { scope: "col", text: column })),
            ),
          ),
          el(
            "tbody",
            {},
            block.rows.map((row) =>
              el(
                "tr",
                {},
                row.map((cell) => el("td", { text: cell })),
              ),
            ),
          ),
        ]),
      ]),
    ]);
  }

  if (block.type === "artifact-download") {
    const artifact = artifactById(artifacts, block.artifact_ref);
    if (!artifact) {
      return null;
    }
    const extension =
      artifact.relative_path?.match(/\.[A-Za-z0-9]{1,12}$/u)?.[0] ??
      (artifact.kind === "chart" ? ".svg" : "");
    return el("section", { class: "analysis-download" }, [
      el("div", {}, [
        el("h3", { class: "analysis-block-title", text: block.title }),
        el("p", {
          text: `${formatFileSize(artifact.size)} · ${artifact.mime} · ${artifact.sha256.slice(0, 12)}…`,
        }),
      ]),
      el("a", {
        class: "secondary artifact-download-link",
        href: `/api/artifacts/${encodeURIComponent(artifact.id)}/content?download=1`,
        download: `${artifact.id}${extension}`,
        text: block.label,
      }),
    ]);
  }

  if (block.type === "callout" || block.type === "markdown") {
    const className = `analysis-callout analysis-callout-${block.tone ?? "neutral"}`;
    const content = el("p", {
      class: "analysis-block-copy",
      text: block.text,
    });
    if (block.type === "callout" && block.collapsed) {
      return el("details", { class: `${className} is-collapsed` }, [
        el("summary", { text: block.title }),
        content,
      ]);
    }
    return el("section", { class: className }, [
      el("h3", { class: "analysis-block-title", text: block.title }),
      content,
    ]);
  }

  return null;
}

function renderAnalysisBlocks(blocks, artifacts) {
  if (!blocks?.length) {
    return null;
  }
  const nodes = blocks
    .map((block) => renderAnalysisBlock(block, artifacts))
    .filter(Boolean);
  return nodes.length
    ? el("div", { class: "analysis-blocks" }, nodes)
    : null;
}

function renderAnswerCard(panel) {
  const result = normalizeResult(panel);
  if (!result) {
    return null;
  }
  const checklist = [
    `最优先下一步：${result.priorityAction.title}`,
    result.priorityAction.detail,
    "",
    ...result.recommendations.map(
      (item, index) =>
        `${index + 1}. ${item.title}\n${item.detail}\n证据目标：${item.evidence_goal}`,
    ),
  ].join("\n");
  const actionButtons = result.actions
    .slice(0, 2)
    .map((action) => copyButton(action.label, action.content, "secondary"));
  if (actionButtons.length < 2) {
    actionButtons.push(copyButton("复制完整采集清单", checklist, "secondary"));
  }
  const mainBlocks = result.blocks.filter(
    (block) =>
      !(
        block.type === "callout" &&
        block.tone === "warning" &&
        block.collapsed
      ),
  );
  const warningBlocks = result.blocks.filter(
    (block) =>
      block.type === "callout" &&
      block.tone === "warning" &&
      block.collapsed,
  );
  if (panel.question) {
    actionButtons.push(
      el("button", {
        class: "primary result-action",
        type: "button",
        text: "开始回答",
        onclick: focusCurrentAction,
      }),
    );
  } else if (state.task?.shared_task?.mode !== "source_hosted") {
    actionButtons.push(
      el("button", {
        class: "secondary result-action",
        type: "button",
        text: "新建任务",
        onclick: resetSession,
      }),
    );
  }

  return el(
    "section",
    {
      class: "answer-card",
      id: "answer-card",
      tabindex: "-1",
      "aria-labelledby": "answer-title",
    },
    [
      el("h2", { class: "answer-title", id: "answer-title", text: "本轮判断与建议" }),
      el("p", { class: "answer-judgement", text: result.judgement }),
      renderAnalysisBlocks(mainBlocks, result.artifacts),
      el("section", { class: "answer-section" }, [
        el("h3", { class: "answer-section-title", text: "判断依据" }),
        result.evidence.length
          ? el(
              "ul",
              { class: "answer-evidence" },
              result.evidence.map((item) =>
                el("li", { class: "answer-evidence-item" }, [
                  el("span", {
                    class: `relation relation-${item.relation}`,
                    text: relationLabel(item.relation),
                  }),
                  el("div", {}, [
                    el("strong", { text: item.label }),
                    el("p", { text: item.detail || "无补充说明" }),
                  ]),
                ]),
              ),
            )
          : el("p", { class: "empty-copy", text: "当前还没有可验证证据。" }),
      ]),
      el("section", { class: "answer-section" }, [
        el("h3", { class: "answer-section-title", text: "仍需确认" }),
        el(
          "ul",
          { class: "answer-uncertainty" },
          result.uncertainty.map((item) => el("li", { text: item })),
        ),
      ]),
      el("section", { class: "answer-section" }, [
        el("h3", { class: "answer-section-title", text: "低风险证据采集" }),
        el(
          "ol",
          { class: "recommendation-list" },
          result.recommendations.map((item) =>
            el("li", {}, [
              el("div", { class: "recommendation-heading" }, [
                el("strong", { text: item.title }),
                el("span", { class: "risk-label", text: "低风险" }),
              ]),
              el("p", { text: item.detail }),
              el("p", { class: "evidence-goal", text: `证据目标：${item.evidence_goal}` }),
            ]),
          ),
        ),
      ]),
      el("section", { class: "priority-action", "aria-label": "最优先下一步" }, [
        el("span", { class: "priority-label", text: "最优先下一步" }),
        el("strong", { text: result.priorityAction.title }),
        el("p", { text: result.priorityAction.detail }),
      ]),
      renderAnalysisBlocks(warningBlocks, result.artifacts),
      el("div", { class: "answer-actions" }, actionButtons),
    ],
  );
}

function taskDetails(panel) {
  const agentName = state.agent?.displayName ?? "Agent";
  const skill = state.skill;
  return el("details", { class: "task-details" }, [
    el("summary", { text: "任务详情" }),
    el("dl", { class: "task-detail-list" }, [
      el("dt", { text: "保存状态" }),
      el("dd", { text: `本次任务已保存在 ${agentName}` }),
      el("dt", { text: "Task ID" }),
      el("dd", { class: "data data-identifier", text: state.task?.task_id ?? "尚未创建" }),
      el("dt", { text: "当前 Skill" }),
      el("dd", {
        text: skill
          ? `${skill.name} · ${skill.version} · ${skill.status}`
          : "兼容模式",
      }),
      el("dt", { text: "目标" }),
      el("dd", { text: state.task?.objective || "等待描述任务" }),
      el("dt", { text: "Session 名称" }),
      el("dd", { text: state.session_name || "正在命名任务" }),
      ...(state.handoff
        ? [
            el("dt", { text: "来源方式" }),
            el("dd", { text: "已从来源 Session 继续，独立执行" }),
            el("dt", { text: "来源 Session ID" }),
            el("dd", {
              class: "data data-identifier",
              text: state.handoff.thread_id,
            }),
            el("dt", { text: "环境 Session ID" }),
            el("dd", {
              class: "data data-identifier",
              text: state.handoff.environment_thread_id || "未记录",
            }),
            el("dt", { text: "来源与执行" }),
            el("dd", {
              text: state.handoff.thread_id_mismatch
                ? "来源与面板 Session 不同；未合并，也未接管来源 Session。"
                : "来源 Session 已记录为返回目标；面板仍未接管来源 Session。",
            }),
            el("dt", { text: "自动回传" }),
            el("dd", {
              text:
                state.handoff.queue_message_sent === true
                  ? "已显式发送回传事件"
                  : "未启用；仅可手动导出摘要",
            }),
          ]
        : []),
      el("dt", { text: "面板 Session ID" }),
      el("dd", { class: "data data-identifier", title: state.session_ref ?? "", text: state.session_ref ?? "尚未创建" }),
      el("dt", { text: "继续方式" }),
      el("dd", {
        text: state.handoff
          ? "导出续接摘要，或回到来源 Agent 对话继续。"
          : "使用当前 Agent 的任务历史或导出续接摘要继续。",
      }),
      el("dt", { text: "Skill 引用" }),
      el("dd", {
        class: "data data-identifier",
        text: `${state.task?.domain_refs?.length ?? 0} 条领域引用`,
      }),
      el("dt", { text: "Agent adapter" }),
      el("dd", {
        text: state.agent
          ? `${state.agent.displayName} · ${state.agent.adapterStatus ?? "connected"}`
          : "Agent 未连接",
      }),
    ]),
    el("div", { class: "task-detail-actions" }, [
      copyButton(
        "复制 Session ID",
        state.session_ref || "",
      ),
      copyButton(
        "复制任务名称",
        state.session_name || "",
      ),
      state.task?.shared_task?.mode === "source_hosted"
        ? null
        : el("button", {
            class: "secondary",
            type: "button",
            text: "新建独立 Agent Session",
            onclick: newIndependentSession,
          }),
    ]),
  ]);
}

function renderDomainContext() {
  const context = state.domain_context;
  if (!context) {
    return null;
  }
  const summary = [
    context.title,
    context.summary,
    ...(context.fields ?? []).map(
      (field) => `${field.label}：${field.value ?? "未记录"}`,
    ),
    context.detail,
  ].join("\n");
  return el("section", { class: "skill-context", "aria-label": "Skill 上下文" }, [
    el("h3", { class: "skill-context-title", text: context.title ?? "Skill 上下文" }),
    el("p", {
      class: "skill-context-summary",
      text: context.summary ?? "当前 Skill 未提供补充上下文。",
    }),
    context.fields?.length
      ? el(
          "dl",
          { class: "task-detail-list" },
          context.fields.flatMap((field) => [
            el("dt", { text: field.label }),
            el("dd", { text: String(field.value ?? "未记录") }),
          ]),
        )
      : null,
    context.detail
      ? el("p", { class: "skill-context-detail", text: context.detail })
      : null,
    el("div", { class: "skill-context-actions" }, [
      copyButton("复制 Skill 摘要", summary),
    ]),
    el("details", { class: "refresh-note" }, [
      el("summary", { text: "刷新配置（按需）" }),
      el("p", {
        text: "面板不会自动刷新领域上下文。需要更新时，请在当前 Agent 中明确启动对应操作；新 Task 和独立 Session 会继续绑定当前 Skill。",
      }),
    ]),
  ]);
}

function renderPermissionStatus() {
  const agentPermissions =
    state.agent_permissions ?? state.agent?.permission_profile ?? {};
  const surface = state.surface ?? {};
  const matrixStates = state.permission_matrix?.states ?? [];
  const activeGrants = (state.task?.grants ?? []).filter(
    (grant) =>
      grant.status === "active" &&
      Date.parse(grant.expires_at) > Date.now(),
  );
  const sandboxLabel = {
    "read-only": "只读",
    "workspace-write": "工作区写入",
    "danger-full-access": "完全访问",
  }[agentPermissions.sandbox] ?? "未声明";
  const approvalLabel =
    agentPermissions.approvalPolicy === "on-request"
      ? "请求批准"
      : agentPermissions.approvalPolicy === "never"
        ? "不询问"
        : "未声明";
  const surfaceLabel = {
    chat: "纯对话",
    "read-only": "只读",
    interactive: "交互",
    developer: "开发",
  }[surface.mode] ?? "未声明";
  const matrixStatusLabel = {
    "active-current-workspace": "当前工作区运行中",
    "chat-only": "纯对话",
    "approval-required": "逐项批准",
    pending: "等待决定",
    granted: "本 Task 已授权",
    denied: "已拒绝",
    expired: "已过期",
    unavailable: "未声明",
    blocked: "禁止",
    "host-managed": "由 Agent 宿主管理",
    disabled: "关闭",
    unknown: "未知",
    "manual-only": "仅人工",
  };
  const ownerLabel = {
    skilldock: "SkillDock",
    "skill-runtime": "Skill Runtime",
    "agent-host": "Agent 宿主",
    skill: "Skill",
  };
  return el("section", {
    class: "permission-status",
    "aria-label": "当前权限",
  }, [
    el("strong", { text: "权限边界" }),
    el("p", {
      text: `Agent：${sandboxLabel} · ${approvalLabel}`,
    }),
    el("p", {
      text: `SkillDock：${surfaceLabel} · ${
        surface.runtime_state === "running-current-workspace"
          ? "当前工作区运行中"
          : surface.runtime_state ?? "Runtime 状态未知"
      }`,
    }),
    state.agent?.supportsApprovalDecision === false
      ? el("p", { text: "宿主审批转交：当前 Driver 不支持" })
      : null,
    matrixStates.length
      ? el(
          "div",
          { class: "permission-matrix", "aria-label": "有效权限状态" },
          matrixStates.map((item) =>
            el("div", { class: "permission-matrix-row" }, [
              el("div", { class: "permission-matrix-heading" }, [
                el("span", {
                  class: "permission-matrix-label",
                  text: item.label ?? item.id,
                }),
                el("span", {
                  class: "permission-matrix-state",
                  text: `${
                    matrixStatusLabel[item.status] ?? item.status ?? "未知"
                  } · ${ownerLabel[item.owner] ?? item.owner ?? "所有者未知"}`,
                }),
              ]),
              el("p", { text: item.detail ?? "" }),
            ]),
          ),
        )
      : el("p", { text: "有效权限矩阵暂不可用。" }),
    activeGrants.length
      ? el("p", { text: "本 Task 已有本地能力授权" })
      : null,
    ...(activeGrants.length
      ? activeGrants.map((grant) =>
          el("div", { class: "permission-grant" }, [
            el("span", {
              text:
                `${grant.capability} · ${
                  grant.scope === "one-time" ? "一次性" : "本 Task"
                } · 有效至 ${permissionExpiryLabel(grant.expires_at)}`,
            }),
            el("button", {
              type: "button",
              text: "撤销",
              onclick: () => revokeSkillGrant(grant.grant_id),
            }),
          ]),
        )
      : []),
  ]);
}

async function revokeSkillGrant(grantId) {
  if (!window.confirm("撤销后，后续未缓存的操作需要重新批准。继续吗？")) {
    return;
  }
  const result = await requestJson("/api/permissions/revoke", {
    method: "POST",
    body: JSON.stringify({ grant_id: grantId }),
  });
  if (!result.ok) {
    noticeText = result.data?.error ?? "无法撤销该权限。";
    render();
    return;
  }
  state = result.data;
  noticeText = "本地能力授权已撤销。";
  render();
}

function renderSessionRecovery() {
  if (!state.session_recovered) {
    return null;
  }
  return el("p", { class: "notice session-recovery", text: state.session_recovered.message });
}

function draftKey() {
  return `agent-panel-draft:${state?.session_ref ?? "new"}:${state?.task?.task_id ?? "new-task"}`;
}

function restoreFreeText() {
  freeText = localStorage.getItem(draftKey()) ?? "";
}

function saveFreeText(value) {
  freeText = value.slice(0, 2000);
  localStorage.setItem(draftKey(), freeText);
}

function readCookie(name) {
  const prefix = `${name}=`;
  for (const part of document.cookie.split(";")) {
    const item = part.trim();
    if (item.startsWith(prefix)) {
      return decodeURIComponent(item.slice(prefix.length));
    }
  }
  return "";
}

function runtimeBindingEvaluation(stateBinding = null) {
  return evaluateRuntimeBinding({
    health: runtimeBindingHealth,
    locationValue: window.location,
    hint: parseRuntimeBindingHint(readCookie("runtime_binding_hint")),
    queryBinding: parseRuntimeBindingQuery(
      window.location.search,
      window.location,
    ),
    stateBinding,
  });
}

function applyRuntimeBindingEvaluation(evaluation) {
  runtimeBinding =
    evaluation.binding ??
    runtimeBinding ??
    state?.runtime_binding ??
    null;
  runtimeBindingFailure = evaluation.ok
    ? null
    : {
        codes: evaluation.failureCodes,
        message:
          "当前页面没有硬绑定到正在运行的 Runtime。请关闭旧页面，并使用启动器最新打开的页面。",
      };
  runtimeBindingCheckedAt = Date.now();
  return evaluation.ok;
}

async function ensureRuntimeBinding({ force = false } = {}) {
  if (
    !force &&
    !runtimeBindingFailure &&
    runtimeBindingCheckedAt &&
    Date.now() - runtimeBindingCheckedAt < 3_000
  ) {
    return true;
  }
  if (runtimeBindingInFlight) return runtimeBindingInFlight;
  runtimeBindingInFlight = (async () => {
    try {
      const response = await fetch("/api/health", {
        cache: "no-store",
        credentials: "same-origin",
        signal: AbortSignal.timeout(3_000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      runtimeBindingHealth = await response.json();
    } catch {
      runtimeBindingHealth = { ok: false };
    }
    return applyRuntimeBindingEvaluation(
      runtimeBindingEvaluation(state?.runtime_binding ?? null),
    );
  })().finally(() => {
    runtimeBindingInFlight = null;
  });
  return runtimeBindingInFlight;
}

async function requestJson(path, options = {}) {
  if (path !== "/api/health") {
    const bindingOk = await ensureRuntimeBinding({
      force: options.forceRuntimeBinding === true,
    });
    if (!bindingOk) {
      return {
        ok: false,
        status: 409,
        data: {
          error: runtimeBindingFailure?.message,
          code: runtimeBindingFailure?.codes?.[0] ?? "runtime_binding_failed",
        },
      };
    }
  }
  try {
    const isFormData = options.body instanceof FormData;
    const response = await fetch(path, {
      credentials: "same-origin",
      ...options,
      headers: {
        ...(isFormData ? {} : { "Content-Type": "application/json" }),
        ...(options.headers ?? {}),
      },
    });
    let data;
    try {
      data = await response.json();
    } catch {
      data = { error: `本地服务返回了无效响应（HTTP ${response.status}）` };
    }
    if (path === "/api/state" && response.ok) {
      const evaluation = runtimeBindingEvaluation(data.runtime_binding);
      if (!applyRuntimeBindingEvaluation(evaluation)) {
        return {
          ok: false,
          status: 409,
          data: {
            error: runtimeBindingFailure.message,
            code: runtimeBindingFailure.codes[0],
          },
        };
      }
    }
    return { ok: response.ok, status: response.status, data };
  } catch {
    runtimeBindingHealth = { ok: false };
    applyRuntimeBindingEvaluation(state?.runtime_binding ?? null);
    return {
      ok: false,
      status: 0,
      data: { error: "无法连接本地服务。请确认它仍在运行，然后重试。" },
    };
  }
}

function setRuntimeStatus(label, tone = "normal") {
  runtimeStatus.textContent = label;
  runtimeDot.classList.toggle("is-error", tone === "error");
  runtimeDot.classList.toggle("is-running", tone === "running");
}

function renderRuntimeBindingBanner() {
  if (runtimeBindingFailure) {
    return el(
      "section",
      {
        class: "runtime-binding is-error",
        id: "runtime-binding",
        "data-binding-state": "offline",
        "data-runtime-pid": runtimeBinding?.pid ?? "",
        "data-runtime-port": runtimeBinding?.port ?? "",
        "data-runtime-launch-id": runtimeBinding?.launch_id ?? "",
      },
      [
        el("strong", { text: "当前页面未连接到正在运行的 Runtime" }),
        el("p", { text: runtimeBindingFailure.message }),
        runtimeBinding
          ? el("p", {
              text: `旧页面绑定：PID ${runtimeBinding.pid} · 端口 ${runtimeBinding.port}`,
            })
          : null,
        el("code", { text: runtimeBindingFailure.codes.join(", ") }),
      ],
    );
  }
  if (!runtimeBinding) {
    return el(
      "section",
      {
        class: "runtime-binding",
        id: "runtime-binding",
        "data-binding-state": "checking",
      },
      [el("strong", { text: "正在验证 Runtime、PID 和端口" })],
    );
  }
  return el(
    "section",
    {
      class: "runtime-binding is-bound",
      id: "runtime-binding",
      "data-binding-state": "bound",
      "data-runtime-pid": runtimeBinding.pid,
      "data-runtime-port": runtimeBinding.port,
      "data-runtime-launch-id": runtimeBinding.launch_id,
    },
    [
      el("strong", {
        text: `Runtime 已硬绑定 · PID ${runtimeBinding.pid} · 端口 ${runtimeBinding.port}`,
      }),
      el("p", {
        text: `Task ${state?.task?.task_id ?? "未加载"} · Launch ${runtimeBinding.launch_id.slice(0, 12)}…`,
      }),
    ],
  );
}

function renderSourceHostedPhaseNotice() {
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.source_hosted || phaseState.submittable) {
    return null;
  }
  if (phaseState.phase === "source_agent_pulled") {
    return el(
      "section",
      {
        class: "phase-waiting",
        id: "source-agent-result-waiting",
        "data-phase": phaseState.phase,
        "data-recovery-available": String(
          phaseState.recovery_available,
        ),
        role: "status",
        "aria-live": "polite",
      },
      [
        el("strong", {
          text: "正在等待来源 Agent 返回结论",
        }),
        el("p", {
          text:
            "本地分析、SVG 和指标已经保存。请保持此页打开；结论写回后会自动显示，无需按 F5。",
        }),
        phaseState.recovery_available
          ? el("button", {
              class: "secondary",
              type: "button",
              disabled: recoveryPending,
              text: recoveryPending ? "正在恢复…" : phaseState.recovery_label,
              onclick: recoverSourceHostedTask,
            })
          : null,
      ],
    );
  }
  return el(
    "section",
    {
      class: "phase-lock",
      id: "source-hosted-phase-lock",
      "data-phase": phaseState.phase,
      "data-recovery-available": String(
        phaseState.recovery_available,
      ),
    },
    [
      el("strong", { text: phaseState.label }),
      el("code", { text: `shared_task.phase=${phaseState.phase}` }),
      el("p", { text: phaseState.reason }),
      phaseState.recovery_available
        ? el("button", {
            class: "primary",
            type: "button",
            disabled: recoveryPending,
            text: recoveryPending ? "正在恢复…" : phaseState.recovery_label,
            onclick: recoverSourceHostedTask,
          })
        : el("p", {
            class: "phase-lock-action",
            text: "请回到当前 Agent 对话处理这个 phase；面板不会创建新 Task 或 Thread。",
          }),
    ],
  );
}

function currentQuestion() {
  return state?.panel?.question ?? null;
}

function selectedOption() {
  const selected = state?.draft?.events?.find(
    (event) => event.type === "option_selected",
  );
  if (!selected) {
    return null;
  }
  return currentQuestion()?.options?.find(
    (option) => option.id === selected.option_id,
  );
}

function canSubmit() {
  const phaseState = sourceHostedPhaseState();
  if (
    !state ||
    !phaseState.can_submit ||
    runtimeBindingFailure ||
    submitPending ||
    uploadingAttachments ||
    analysisPending ||
    permissionPending ||
    state.phase === "running"
  ) {
    return false;
  }
  return (
    Boolean(selectedOption()) ||
    freeText.trim().length > 0 ||
    (state.draft?.attachments?.length ?? 0) > 0
  );
}

function noticeElement() {
  if (!noticeText) {
    return null;
  }
  return el("div", {
    class: "notice",
    role: "alert",
    text: noticeText,
  });
}

function taskSidebar(panel) {
  return el("aside", { class: "ledger", "aria-label": "任务信息" }, [
    el("h2", { class: "ledger-title", text: "当前任务" }),
    el("p", {
      class: "ledger-subtitle",
      text: "本次任务已自动保存",
    }),
    el("p", { class: "task-name", text: state.session_name || "正在命名任务" }),
    renderSessionRecovery(),
    renderPermissionStatus(),
    renderDomainContext(),
    taskDetails(panel),
  ]);
}

function initialQuestionColumn() {
  const sourceHostedTask =
    state.task?.shared_task?.mode === "source_hosted";
  return el("section", { class: "question-column" }, [
    renderPrimaryStatusBlock(),
    renderHandoffCard(),
    renderPermissionCard(),
    renderTimeline(),
    noticeElement(),
    taskDataSourcePanel(),
    sourceHostedRecoveryAvailable()
      ? el("p", {
          class: "turn-summary",
          text: "恢复会保留当前 Task，清理同内容重复附件，并保持同一 Thread。",
        })
      : el("div", {}, [
          el("h2", {
            class: "goal-title",
            id: "primary-focus",
            text: sourceHostedTask
              ? "继续当前 Workbench Task"
              : "开始一个新的 Workbench 任务",
          }),
          sourceHostedTask && state.task?.objective
            ? el("p", {
                class: "turn-summary",
                id: "current-task-objective",
                text: `当前问题：${state.task.objective}`,
              })
            : null,
          el("p", {
            class: "turn-summary",
            text: sourceHostedTask
              ? "当前附件、证据和 Task 保持绑定；提交后仍使用同一个 Codex Thread。"
              : "任务会使用当前 Agent Session 和已保存的技能证据。首次发送后才创建新的 Workbench Task。",
          }),
          composer({
            initial: true,
            submitLabel: sourceHostedTask ? "提交当前问题" : "",
          }),
        ]),
    el("div", { class: "meta-row" }, [
      el("span", { text: "本次任务已自动保存" }),
      el("span", { class: "data", text: `${state.event_count ?? 0} events` }),
    ]),
  ]);
}

function optionRows(question) {
  return question.options.map((option) => {
    const checked = selectedOption()?.id === option.id;
    return el("label", { class: "option" }, [
      el("input", {
        type: "radio",
        name: "panel-option",
        value: option.id,
        checked,
        onchange: () => selectOption(option.id),
      }),
      el("span", { class: "option-copy" }, [
        el("span", { class: "option-heading" }, [
          option.label,
          state.panel.recommendation?.option_id === option.id
            ? el("span", { class: "suggested", text: "建议" })
            : null,
        ]),
        el("span", { class: "option-description", text: option.description }),
      ]),
    ]);
  });
}

function evidenceForm() {
  const labelInput = el("input", {
    id: "evidence-label",
    type: "text",
    name: "evidence-label",
    placeholder: "证据名称，例如：游戏内最低帧明显下降",
    maxlength: "80",
  });
  const detailInput = el("textarea", {
    id: "evidence-detail",
    name: "evidence-detail",
    placeholder: "可补充发生时间、场景或结果",
    maxlength: "240",
  });
  const sourceInput = el("input", {
    type: "checkbox",
    name: "evidence-observed",
  });
  return el("details", {}, [
    el("summary", { text: "添加一条待发送证据" }),
    el("div", { class: "evidence-form" }, [
      el("label", { for: "evidence-label", text: "证据名称" }),
      labelInput,
      el("label", { for: "evidence-detail", text: "说明" }),
      detailInput,
      el("label", {}, [sourceInput, " 这是刚刚观察到的结果"]),
      el("div", {}, [
        el("button", {
          class: "secondary",
          type: "button",
          text: "加入证据列表",
          onclick: () =>
            addEvidence(
              labelInput.value,
              detailInput.value,
              sourceInput.checked ? "observed_current" : "user_reported",
            ),
        }),
      ]),
    ]),
  ]);
}

function formatFileSize(size) {
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1024 * 1024) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

function renderAttachmentCards(
  attachments,
  { removable = false, interactive = false } = {},
) {
  if (!attachments?.length) {
    return null;
  }
  return el(
    "ul",
    { class: "attachment-list", "aria-label": "待发送附件" },
    attachments.map((attachment) => {
      const actions = interactive
        ? attachmentActionsFor(attachment)
        : [];
      const extension = attachment.original_name.includes(".")
        ? attachment.original_name.split(".").pop().toUpperCase().slice(0, 6)
        : "FILE";
      return el("li", { class: "attachment-card" }, [
        attachment.mime_type.startsWith("image/")
          ? el("img", {
              class: "attachment-thumb",
              src: `/api/attachments/${encodeURIComponent(attachment.id)}/content`,
              alt: `${attachment.original_name} 预览`,
              loading: "lazy",
            })
          : el("span", { class: "attachment-filetype", text: extension }),
        el("div", { class: "attachment-copy" }, [
          el("strong", { text: attachment.original_name }),
          el("span", {
            text: `${formatFileSize(attachment.size)} · ${attachment.mime_type} · sha256 ${attachment.sha256}`,
            title: `sha256 ${attachment.sha256}`,
          }),
          attachment.preview
            ? el("details", { class: "attachment-preview" }, [
                el("summary", { text: "查看文本预览" }),
                el("pre", { text: attachment.preview }),
              ])
            : null,
          ...actions.map((action) =>
            el("button", {
              class: "secondary attachment-analyze",
              type: "button",
              disabled:
                Boolean(analysisPending) ||
                state.phase === "running" ||
                Boolean(runtimeBindingFailure) ||
                !sourceHostedPhaseState().can_analyze ||
                submitPending,
              text:
                analysisPending === attachment.id
                  ? "正在处理…"
                  : action.ui.label,
              onclick: () =>
                runSkillAttachmentAction(action.id, attachment.id),
            }),
          ),
        ]),
        removable
          ? el("button", {
              class: "attachment-remove",
              type: "button",
              "aria-label": `删除附件 ${attachment.original_name}`,
              text: "删除",
              onclick: () => removeAttachment(attachment.id),
            })
          : null,
      ]);
    }),
  );
}

function attachmentActionsFor(attachment) {
  const extension = attachment.original_name.includes(".")
    ? `.${attachment.original_name.split(".").pop().toLowerCase()}`
    : "";
  return (state.skill?.capabilities ?? []).filter((capability) =>
    capability.ui?.attachment_extensions?.includes(extension),
  );
}

async function uploadFiles(fileList) {
  if (!(await ensureRuntimeBinding({ force: true }))) {
    noticeText = runtimeBindingFailure?.message ?? "Runtime 绑定无效。";
    render();
    return;
  }
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_upload) {
    noticeText = phaseState.reason;
    render();
    return;
  }
  const files = [...fileList];
  if (!files.length) {
    return;
  }
  uploadingAttachments = true;
  noticeText = files.length > 1 ? `正在添加 ${files.length} 个附件…` : "正在添加附件…";
  render();
  try {
    for (const file of files) {
      const form = new FormData();
      form.append("file", file, file.name);
      const result = await requestJson("/api/attachments", {
        method: "POST",
        body: form,
      });
      if (!result.ok) {
        throw new Error(result.data.error ?? "附件添加失败");
      }
      state = result.data;
    }
    noticeText = "";
  } catch (error) {
    noticeText = error.message;
  } finally {
    uploadingAttachments = false;
    render();
  }
}

async function removeAttachment(id) {
  const result = await requestJson(`/api/attachments/${encodeURIComponent(id)}`, {
    method: "DELETE",
  });
  if (!result.ok) {
    noticeText = result.data.error ?? "附件删除失败";
    render();
    return;
  }
  state = result.data;
  noticeText = "";
  render();
}

async function runSkillAttachmentAction(
  actionId,
  id,
  window = { warmup_seconds: null, duration_seconds: null },
) {
  if (!(await ensureRuntimeBinding({ force: true }))) {
    noticeText = runtimeBindingFailure?.message ?? "Runtime 绑定无效。";
    render();
    return false;
  }
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_analyze) {
    noticeText = phaseState.reason;
    render();
    return false;
  }
  if (
    analysisPending ||
    permissionPending ||
    submitPending ||
    uploadingAttachments ||
    state.phase === "running"
  ) {
    return false;
  }
  const attachment = state.task?.attachments?.find((item) => item.id === id);
  if (!attachment) {
    noticeText = "当前 Task 中找不到该附件。";
    render();
    return false;
  }
  analysisPending = id;
  render();
  const result = await requestJson(
    `/api/skill/actions/${encodeURIComponent(actionId)}`,
    {
    method: "POST",
    body: JSON.stringify({
      attachment_id: id,
      warmup_seconds: window.warmup_seconds ?? null,
      duration_seconds: window.duration_seconds ?? null,
    }),
    },
  );
  analysisPending = null;
  if (result.data?.state) {
    state = result.data.state;
  }
  if (result.data?.permission_required) {
    noticeText = "";
    render();
    return false;
  }
  if (!result.ok) {
    noticeText = result.data?.error ?? "本地 Skill 操作失败。";
    await refreshState().catch(() => {});
  }
  render();
  return result.ok;
}

async function runApprovedSkillAction(
  actionId,
  id,
  window = { warmup_seconds: null, duration_seconds: null },
) {
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_analyze) {
    noticeText = phaseState.reason;
    render();
    return;
  }
  if (
    analysisPending ||
    permissionPending ||
    submitPending ||
    uploadingAttachments ||
    state.phase === "running"
  ) {
    return;
  }
  const attachment = state.task?.attachments?.find((item) => item.id === id);
  if (!attachment) {
    noticeText = "当前 Task 中找不到该附件。";
    render();
    return;
  }
  analysisPending = id;
  const startedAt = new Date().toISOString();
  optimisticPhase = "processing";
  optimisticActivity = {
    status: "running",
    user_summary: `执行本地能力：${attachment.original_name}`,
    submitted_at: startedAt,
    started_at: startedAt,
    completed_at: null,
    agent_summary: "",
    next_action: "",
    error: null,
  };
  state.phase = "running";
  render();
  const result = await requestJson(
    `/api/skill/actions/${encodeURIComponent(actionId)}`,
    {
    method: "POST",
    body: JSON.stringify({
      attachment_id: id,
      warmup_seconds: window.warmup_seconds ?? null,
      duration_seconds: window.duration_seconds ?? null,
    }),
    },
  );
  analysisPending = null;
  optimisticPhase = null;
  optimisticActivity = null;
  if (result.data?.state) {
    state = result.data.state;
  } else if (result.data?.phase) {
    state = result.data;
  } else {
    await refreshState();
  }
  if (!result.ok) {
    noticeText =
      result.data?.error ?? "本地 Skill 操作失败，原附件仍保留在当前 Task 中。";
  } else if (result.data?.panel?.artifact_refs?.length) {
    transientReplyAt = Date.now();
    if (replyTransitionTimer) {
      clearTimeout(replyTransitionTimer);
    }
    replyTransitionTimer = setTimeout(() => {
      transientReplyAt = 0;
      replyTransitionTimer = null;
      render();
    }, 3_500);
  }
  render();
  if (result.ok && result.data?.panel?.artifact_refs?.length) {
    showReplySignal();
  }
}

function taskDataSourcePanel() {
  const actionableAttachments = (state.task?.attachments ?? []).filter(
    (attachment) => attachmentActionsFor(attachment).length > 0,
  );
  if (actionableAttachments.length === 0) {
    return null;
  }
  return el("section", { class: "task-data-sources" }, [
    el("div", { class: "task-data-heading" }, [
      el("h3", { text: "任务数据" }),
      el("p", {
        text: "当前 Skill 可以为已提交附件执行声明的本地能力；结果仍属于当前 Task。",
      }),
    ]),
    renderAttachmentCards(actionableAttachments, { interactive: true }),
  ]);
}

function composer({ initial = false, submitLabel = "" } = {}) {
  const attachments = state.draft?.attachments ?? [];
  const inputId = initial ? "symptom" : "task-composer";
  const textarea = el("textarea", {
    id: inputId,
    class: initial ? "composer-input composer-input-large" : "composer-input",
    placeholder: initial
      ? "例如：只有一款游戏会黑屏掉帧；也可以直接描述新问题。"
      : "继续提问、纠错或补充想法；也可以附加日志、CSV 或截图。",
    maxlength: "2000",
    oninput: (event) => {
      saveFreeText(event.currentTarget.value);
      updateSendState();
    },
    onpaste: (event) => {
      const images = [...(event.clipboardData?.files ?? [])].filter((file) =>
        file.type.startsWith("image/"),
      );
      if (images.length) {
        event.preventDefault();
        uploadFiles(images);
      }
    },
  });
  textarea.value = freeText;
  const fileInput = el("input", {
    id: "composer-file-input",
    class: "visually-hidden",
    type: "file",
    multiple: true,
    disabled:
      Boolean(runtimeBindingFailure) ||
      !sourceHostedPhaseState().can_upload,
    accept: ".csv,.txt,.log,.json,.png,.jpg,.jpeg,.webp,text/csv,text/plain,application/json,image/png,image/jpeg,image/webp",
    onchange: (event) => uploadFiles(event.currentTarget.files),
  });
  const form = el("form", {
    class: `composer${initial ? " composer-initial" : ""}`,
    onsubmit: (event) => {
      event.preventDefault();
      sendSubmission();
    },
    ondragover: (event) => {
      event.preventDefault();
      event.currentTarget.classList.add("is-dragging");
    },
    ondragleave: (event) => {
      event.currentTarget.classList.remove("is-dragging");
    },
    ondrop: (event) => {
      event.preventDefault();
      event.currentTarget.classList.remove("is-dragging");
      uploadFiles(event.dataTransfer.files);
    },
  }, [
    el("label", {
      class: "composer-title",
      for: inputId,
      text: initial ? "你现在想解决什么？" : "继续提问或补充你的想法",
    }),
    renderAttachmentCards(attachments, { removable: true }),
    textarea,
    el("div", { class: "composer-toolbar" }, [
      el("div", { class: "composer-tools" }, [
        el("button", {
          class: "file-picker",
          type: "button",
          disabled:
            Boolean(runtimeBindingFailure) ||
            !sourceHostedPhaseState().can_upload,
          "aria-controls": "composer-file-input",
          onclick: () => fileInput.click(),
          text: uploadingAttachments ? "正在添加附件…" : "添加文件/图片",
        }),
        fileInput,
        el("span", {
          class: "action-note composer-note",
          id: "composer-note",
          text: "可拖放文件；支持 CSV/TXT/LOG/JSON/PNG/JPEG/WEBP，单个不超过 8 MB。",
        }),
      ]),
      el("button", {
        class: "primary",
        id: "send-button",
        type: "submit",
        disabled: !canSubmit(),
        text: uploadingAttachments
          ? "正在添加附件"
          : submitLabel ||
            (initial ? "开始任务" : "发送给 Agent"),
      }),
    ]),
  ]);
  return form;
}

function questionColumn() {
  const panel = state.panel;
  if (state.phase === "running") {
    return runningQuestionColumn(panel);
  }
  if (!panel) {
    return initialQuestionColumn();
  }
  const question = panel.question;
  if (!question) {
    return el("section", { class: "question-column" }, [
      renderPrimaryStatusBlock(),
      renderHandoffCard(),
      renderPermissionCard(),
      renderTimeline(),
      noticeElement(),
      taskDataSourcePanel(),
      renderAnswerCard(panel),
      composer({ initial: false }),
      renderEndHandoff(),
    ]);
  }

  return el("section", { class: "question-column" }, [
    renderPrimaryStatusBlock(),
    renderHandoffCard(),
    renderPermissionCard(),
    renderTimeline(),
    noticeElement(),
    taskDataSourcePanel(),
    renderAnswerCard(panel),
    el("p", { class: "goal-label", text: "当前目标" }),
    el("h2", { class: "goal-title", text: stripHeadingPunctuation(panel.current_goal) }),
    el("h3", {
      class: "question-prompt",
      id: "primary-focus",
      text: stripHeadingPunctuation(question.prompt),
    }),
    el(
      "fieldset",
      { class: "option-list", "aria-labelledby": "primary-focus" },
      optionRows(question),
    ),
    el("div", { class: "recommendation", text: panel.recommendation.summary }),
    evidenceForm(),
    composer({ initial: false }),
    renderEndHandoff(),
    el("div", { class: "meta-row" }, [
      state.task?.shared_task?.mode === "source_hosted"
        ? null
        : el("button", {
            class: "secondary",
            type: "button",
            text: "新建任务",
            onclick: resetSession,
          }),
      el("span", { class: "data", text: `${state.event_count ?? 0} events` }),
    ]),
  ]);
}

function runningQuestionColumn(panel) {
  return el("section", { class: "question-column", "aria-busy": "true" }, [
    renderPrimaryStatusBlock(),
    renderTimeline(),
    el("p", { class: "goal-label", text: "Agent 正在处理" }),
    el("h2", {
      class: "goal-title",
      id: "primary-focus",
      text: "正在准备你的下一条信息",
    }),
    el("p", {
      class: "turn-summary",
      text: "本轮内容已安全保存。你可以留在本页，或刷新后继续等待。",
    }),
    el("div", { class: "skeleton skeleton-row" }),
    el("div", { class: "skeleton skeleton-row" }),
    el("div", { class: "skeleton skeleton-row" }),
    panel
      ? el("p", {
          class: "muted",
          text: `上一目标：${panel.current_goal}`,
        })
      : null,
    el("div", { class: "action-zone running-action" }, [
      el("p", {
        class: "action-note",
        text: "已发送。当前回合完成前不会再次提交。",
      }),
      el("button", {
        class: "primary",
        id: "send-button",
        type: "button",
        disabled: true,
        text: "正在等待 Agent",
      }),
    ]),
  ]);
}

function render() {
  if (!state) {
    return;
  }
  saveStatus.textContent = "本次任务已自动保存";
  const agentLabel =
    state.agent?.driver === "source-external"
      ? "本地面板 · 只读"
      : "Agent 已连接";
  setRuntimeStatus(
    activityMode() === "replied"
      ? `新回复 · ${agentLabel}`
      : agentLabel,
    "normal",
  );
  if (state.error) {
    noticeText = userFacingErrorText(state.error);
  }
  restoreFreeText();
  app.replaceChildren(
    ...[
      renderRuntimeBindingBanner(),
      renderSourceHostedPhaseNotice(),
      el("div", { class: "workspace-grid" }, [
        questionColumn(),
        taskSidebar(state.panel),
      ]),
    ].filter(Boolean),
  );
  noticeText = "";
  syncStatusTicker(activityMode());
  if (shouldPollState()) {
    startPolling();
  } else {
    stopPolling();
  }
}

function syncStatusTicker(mode) {
  if (statusTicker) {
    clearInterval(statusTicker);
    statusTicker = null;
  }
  if (mode !== "sent" && mode !== "processing") {
    return;
  }
  statusTicker = setInterval(() => {
    const timer = document.querySelector("#activity-elapsed");
    if (timer) {
      timer.textContent = statusElapsedText(activityMode());
    }
  }, 1_000);
}

function showReplySignal() {
  document.title = "新回复 · SkillDock";
  if (titleTimer) {
    clearTimeout(titleTimer);
  }
  titleTimer = setTimeout(() => {
    document.title = "SkillDock";
    titleTimer = null;
  }, 4_000);
  requestAnimationFrame(() => {
    document.querySelector("#status-block")?.scrollIntoView({
      behavior: "smooth",
      block: "start",
    });
  });
}

function updateSendState() {
  const button = document.querySelector("#send-button");
  if (button) {
    button.disabled = !canSubmit();
  }
  const note = document.querySelector("#composer-note");
  if (note) {
    const selected = selectedOption();
    const attachments = state.draft?.attachments ?? [];
    note.textContent = [
      selected ? `将提交选择：${selected.label}` : "",
      attachments.length ? `附件：${attachments.map((item) => item.original_name).join("、")}` : "",
    ]
      .filter(Boolean)
      .join("；") || "可直接输入问题、拖入文件，或选择一个选项后发送。";
  }
}

async function selectOption(optionId) {
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_submit) {
    noticeText = phaseState.reason;
    render();
    return;
  }
  if (!currentQuestion() || state.phase === "running") {
    return;
  }
  const result = await requestJson("/api/event", {
    method: "POST",
    body: JSON.stringify({
      type: "option_selected",
      question_id: currentQuestion().id,
      option_id: optionId,
    }),
  });
  if (!result.ok) {
    noticeText = result.data.error ?? "选项未能保存";
    render();
    return;
  }
  state = result.data;
  render();
  document.querySelector(`input[value="${CSS.escape(optionId)}"]`)?.focus();
}

async function addEvidence(label, detail, source) {
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_submit) {
    noticeText = phaseState.reason;
    render();
    return;
  }
  if (!label.trim()) {
    noticeText = "先给证据起一个简短名称";
    render();
    return;
  }
  const result = await requestJson("/api/event", {
    method: "POST",
    body: JSON.stringify({
      type: "evidence_added",
      label,
      detail,
      source,
    }),
  });
  if (!result.ok) {
    noticeText = result.data.error ?? "证据未能保存";
    render();
    return;
  }
  state = result.data;
  render();
}

async function recoverSourceHostedTask() {
  if (
    recoveryPending ||
    !sourceHostedRecoveryAvailable() ||
    !window.confirm(
      "保留当前 Task 作为归档，清理重复附件并恢复为可重试状态？不会新建 Thread。",
    )
  ) {
    return;
  }
  recoveryPending = true;
  noticeText = "";
  render();
  const result = await requestJson("/api/task/recover", {
    method: "POST",
    body: JSON.stringify({ confirm: "recover_current_task" }),
  });
  recoveryPending = false;
  if (!result.ok) {
    noticeText =
      result.data?.error ??
      "当前 Task 未能恢复；请回到 Agent 对话检查安装态。";
    await refreshState().catch(() => {});
    render();
    return;
  }
  state = result.data;
  noticeText = "当前 Task 已恢复，可以重新提交或同步本地结果。";
  render();
}

async function sendSubmission() {
  if (!(await ensureRuntimeBinding({ force: true }))) {
    noticeText = runtimeBindingFailure?.message ?? "Runtime 绑定无效。";
    render();
    return;
  }
  const phaseState = sourceHostedPhaseState();
  if (!phaseState.can_submit) {
    noticeText = phaseState.reason;
    render();
    return;
  }
  if (!canSubmit()) {
    return;
  }
  const previousDraftKey = draftKey();
  const userSummary =
    submissionSummary() ||
    (state.panel ? "已提交本轮选择。" : freeText.trim());
  submitPending = true;
  optimisticPhase = "sent";
  optimisticActivity = {
    status: "running",
    user_summary: userSummary,
    submitted_at: new Date().toISOString(),
    started_at: new Date().toISOString(),
    completed_at: null,
    agent_summary: "",
    next_action: "",
    error: null,
  };
  state.phase = "running";
  render();
  setTimeout(() => {
    if (submitPending) {
      optimisticPhase = "processing";
      render();
    }
  }, 700);
  const result = await requestJson("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: freeText.trim() }),
  });
  submitPending = false;
  optimisticPhase = null;
  optimisticActivity = null;
  if (result.data?.phase) {
    state = result.data;
  } else {
    await refreshState();
    noticeText = result.data?.error ?? "提交失败";
    state.phase = "error";
    state.error = noticeText;
    state.activity = {
      status: "error",
      user_summary: userSummary,
      submitted_at: new Date().toISOString(),
      started_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
      agent_summary: "",
      next_action: "",
      error: noticeText,
    };
  }
  const succeeded = result.ok;
  if (succeeded) {
    freeText = "";
    localStorage.removeItem(previousDraftKey);
    localStorage.removeItem(draftKey());
    transientReplyAt = Date.now();
    if (replyTransitionTimer) {
      clearTimeout(replyTransitionTimer);
    }
    replyTransitionTimer = setTimeout(() => {
      transientReplyAt = 0;
      replyTransitionTimer = null;
      render();
    }, 3_500);
  }
  render();
  if (succeeded) {
    showReplySignal();
  }
}

async function refreshState() {
  const requestSequence = ++stateRefreshSequence;
  const result = await requestJson("/api/state");
  if (
    result.ok &&
    requestSequence >= lastAppliedStateRefresh
  ) {
    lastAppliedStateRefresh = requestSequence;
    state = result.data;
  }
  return result;
}

function stopPolling() {
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
  pollInFlight = false;
  lastPollStateKey = "";
}

function shouldPollState() {
  const sharedTask = state?.task?.shared_task;
  if (state?.phase === "running") {
    return true;
  }
  if (sharedTask?.mode !== "source_hosted") {
    return false;
  }
  if (
    ["waiting_for_source_pull", "source_agent_pulled"].includes(
      sharedTask.phase,
    )
  ) {
    sourceResultPollingActive = true;
    return true;
  }
  if (
    sharedTask.phase === "source_result_synced" &&
    sourceResultPollingActive &&
    !state.panel
  ) {
    return true;
  }
  return false;
}

function pollStateKey() {
  const sharedTask = state?.task?.shared_task;
  return JSON.stringify([
    state?.updated_at,
    state?.event_count,
    state?.phase,
    sharedTask?.phase,
    state?.activity?.status,
    state?.activity?.completed_at,
    state?.task?.permission_request?.status,
    state?.panel?.status,
    state?.panel?.judgement,
    (state?.panel?.artifact_refs ?? []).map((artifact) => artifact.id),
    state?.error,
  ]);
}

function startPolling() {
  if (pollTimer || pollInFlight) {
    return;
  }
  if (!lastPollStateKey) {
    lastPollStateKey = pollStateKey();
  }
  const poll = async () => {
    pollTimer = null;
    if (pollInFlight) {
      return;
    }
    pollInFlight = true;
    try {
      const result = await refreshState().catch(() => null);
      const nextStateKey = pollStateKey();
      if (result?.ok && nextStateKey !== lastPollStateKey) {
        lastPollStateKey = nextStateKey;
        render();
      }
      const sharedTask = state?.task?.shared_task;
      if (
        sharedTask?.phase === "source_result_synced" &&
        state?.panel
      ) {
        sourceResultPollingActive = false;
      }
    }
    finally {
      pollInFlight = false;
    }
    if (shouldPollState()) {
      pollTimer = setTimeout(poll, 1500);
    }
  };
  pollTimer = setTimeout(poll, 1500);
}

async function resetSession() {
  if (state.task?.shared_task?.mode === "source_hosted") {
    noticeText =
      "source_hosted 单 Task 模式不允许新建任务；请先恢复当前 Task。";
    render();
    return;
  }
  const reuse = state?.domain_context
    ? "复用当前 Skill 上下文和领域引用"
    : "复用当前 Task 与 Session";
  if (
    !window.confirm(
      `新建任务会在当前 Agent Session 中开启新的 Workbench Task，${reuse}。继续吗？`,
    )
  ) {
    return;
  }
  const previousDraftKey = draftKey();
  const result = await requestJson("/api/task/new", {
    method: "POST",
    body: "{}",
  });
  if (!result.ok) {
    noticeText = result.data.error ?? "无法新建任务";
    render();
    return;
  }
  submitPending = false;
  optimisticPhase = null;
  optimisticActivity = null;
  transientReplyAt = 0;
  state = result.data;
  freeText = "";
  clearResetDraftStorage({
    storage: localStorage,
    previousKey: previousDraftKey,
    currentKey: draftKey(),
  });
  render();
}

async function newIndependentSession() {
  if (state.task?.shared_task?.mode === "source_hosted") {
    noticeText =
      "source_hosted 单 Thread 模式不允许新建独立 Session。";
    render();
    return;
  }
  if (
    !window.confirm(
      "新建独立 Session 会结束当前 Task，并创建一个独立的 Agent Session。当前 Skill 和已有领域引用仍会复用。仅在切换上下文、隐私边界、上下文过长或需要并行探索时使用。继续吗？",
    )
  ) {
    return;
  }
  const previousDraftKey = draftKey();
  const result = await requestJson("/api/session/new", {
    method: "POST",
    body: "{}",
  });
  if (!result.ok) {
    noticeText = result.data.error ?? "无法新建独立 Session";
    render();
    return;
  }
  submitPending = false;
  optimisticPhase = null;
  optimisticActivity = null;
  transientReplyAt = 0;
  state = result.data;
  freeText = "";
  clearResetDraftStorage({
    storage: localStorage,
    previousKey: previousDraftKey,
    currentKey: draftKey(),
  });
  render();
}

async function boot() {
  await ensureRuntimeBinding({ force: true });
  if (!runtimeBindingTimer) {
    runtimeBindingTimer = setInterval(async () => {
      const wasBound = !runtimeBindingFailure;
      const bound = await ensureRuntimeBinding({ force: true });
      if (wasBound !== bound) render();
    }, 5_000);
  }
  const result = await refreshState();
  if (!result.ok) {
    app.replaceChildren(
      el("section", { class: "question-column" }, [
        el("h2", { class: "goal-title", text: "本地服务暂时不可用" }),
        el("p", {
          class: "turn-summary",
          text: runtimeBindingFailure?.message ?? result.data.error,
        }),
        el("button", {
          class: "primary",
          type: "button",
          text: "重试连接",
          onclick: boot,
        }),
      ]),
    );
    setRuntimeStatus(
      runtimeBindingFailure ? "Runtime 绑定失效" : "无法连接本地服务",
      "error",
    );
    return;
  }
  render();
}

let pageWakeRefreshInFlight = null;
async function refreshAfterPageWake() {
  if (
    document.visibilityState === "hidden" ||
    !state ||
    pageWakeRefreshInFlight
  ) {
    return;
  }
  pageWakeRefreshInFlight = (async () => {
    const result = await refreshState().catch(() => null);
    if (result?.ok) {
      lastPollStateKey = pollStateKey();
      render();
    }
  })();
  try {
    await pageWakeRefreshInFlight;
  }
  finally {
    pageWakeRefreshInFlight = null;
  }
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    refreshAfterPageWake();
  }
});
window.addEventListener("focus", refreshAfterPageWake);

window.addEventListener("offline", () => {
  runtimeBindingHealth = { ok: false };
  applyRuntimeBindingEvaluation(state?.runtime_binding ?? null);
  render();
});

boot();
