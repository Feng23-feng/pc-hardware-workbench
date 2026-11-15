import { createServer } from "node:http";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import { basename, extname, isAbsolute, relative, resolve } from "node:path";
import { Readable } from "node:stream";
import {
  AgentDriverError,
  createAgentDriver,
  driverPublicDescriptor,
  resolveAgentDriverName,
} from "./lib/agents/index.mjs";
import { runPanelTurn } from "./lib/panel-response.mjs";
import { StateStore } from "./lib/state-store.mjs";
import { buildDraftEvent } from "./lib/schema-validation.mjs";
import {
  verifyHandoffToken,
} from "./lib/handoff-capability.mjs";
import {
  CompatChatRuntime,
  SkillRuntimeError,
  loadSkillRuntime,
} from "./lib/skill-runtime.mjs";
import { discoverSkillManifests } from "./lib/skill-discovery.mjs";
import {
  loadWorkbenchManifest,
  publicManifestDescriptor,
} from "./lib/workbench-manifest.mjs";

const root = resolve(import.meta.dirname);
const host = "127.0.0.1";
const port = Number.parseInt(process.env.PANEL_PORT ?? "4319", 10);
const runtimeDir = resolve(
  root,
  process.env.PANEL_RUNTIME_DIR ?? "runtime",
);
let agentDriverName;
try {
  agentDriverName = resolveAgentDriverName();
} catch (error) {
  process.stderr.write(`Agent driver configuration error: ${error.message}\n`);
  process.exit(1);
}
const resetRequested = process.argv.includes("--reset-state");
mkdirSync(runtimeDir, { recursive: true });
const attachmentRoot = resolve(runtimeDir, "attachments");
const taskArchiveDir = resolve(runtimeDir, "tasks");
const artifactRoot = resolve(runtimeDir, "artifacts");
mkdirSync(attachmentRoot, { recursive: true });
mkdirSync(taskArchiveDir, { recursive: true });
mkdirSync(artifactRoot, { recursive: true });

function loadOrCreateSecret(fileName) {
  const tokenPath = resolve(runtimeDir, fileName);
  if (existsSync(tokenPath)) {
    return readFileSync(tokenPath, "utf8").trim();
  }
  const token = randomBytes(32).toString("base64url");
  writeFileSync(tokenPath, `${token}\n`, { encoding: "utf8", mode: 0o600 });
  return token;
}

const token = loadOrCreateSecret("capability-token");
const handoffSecret = loadOrCreateSecret("handoff-secret");
const store = new StateStore(runtimeDir);
const state = store.load();
const previousActiveSkill = state.active_skill ?? null;
if (resetRequested) {
  store.reset();
}
const skillDiscovery = discoverSkillManifests({
  projectRoot: root,
  previousActive: previousActiveSkill,
});
let workbenchManifest = skillDiscovery.selected;
let skillRuntime = null;
let skillRuntimeFailure = null;
if (workbenchManifest) {
  try {
    skillRuntime = await loadSkillRuntime({
      manifest: workbenchManifest,
      projectRoot: root,
      runtimeDir,
      runtimeOptions: { attachmentRoot, artifactRoot },
    });
  } catch (error) {
    skillRuntimeFailure = {
      code: String(error?.code ?? "runtime_unavailable"),
      message: String(error?.message ?? "Skill runtime failed to start").slice(
        0,
        240,
      ),
    };
  }
}
if (!skillRuntime) {
  workbenchManifest = loadWorkbenchManifest({ projectRoot: root });
  skillRuntime = new CompatChatRuntime({
    manifest: workbenchManifest,
    projectRoot: root,
  });
  await skillRuntime.initialize();
}
const panelOutputSchema = workbenchManifest.stateSchema;
state.active_skill = {
  ...skillRuntime.identity,
  status:
    skillDiscovery.fallbackRequired || skillRuntimeFailure
      ? "fallback"
      : "active",
  selection_reason: skillDiscovery.selectionReason,
  error: skillRuntimeFailure ?? skillDiscovery.error ?? null,
  selected_at: new Date().toISOString(),
};
state.skill_discovery = {
  compatible_count: skillDiscovery.compatibleCount,
  candidate_count: skillDiscovery.candidates.length,
  candidates: skillDiscovery.candidates.map((candidate) => ({
    id: candidate.id,
    name: candidate.name,
    version: candidate.version,
    runtime_id: candidate.runtime_id,
    status: candidate.status,
    error: candidate.error,
  })),
};
if (!state.task) {
  state.task = createTask(state.panel?.current_goal || "已恢复任务");
}
state.task.skill ??= {
  skill_id: state.active_skill.skill_id,
  skill_version: state.active_skill.skill_version,
  manifest_hash: state.active_skill.manifest_hash,
  runtime_id: state.active_skill.runtime_id,
};
skillRuntime.normalizeTaskState({
  task: state.task,
  taskId: state.task.task_id,
});
state.task.attachments ??= [];
state.task.artifacts ??= [];
state.task.actions ??= [];
state.handoff ??= null;
state.handoff_consumed_nonces ??= [];
if (!Array.isArray(state.task.timeline)) {
  state.task.timeline = [];
  if (state.activity?.user_summary) {
    state.task.timeline.push({
      id: `timeline-${crypto.randomUUID()}`,
      role: "user",
      text: state.activity.user_summary,
      created_at: state.activity.submitted_at ?? state.updated_at,
      attachments: [],
    });
  }
  if (state.activity?.agent_summary) {
    state.task.timeline.push({
      id: `timeline-${crypto.randomUUID()}`,
      role: "agent",
      text: state.activity.agent_summary,
      created_at: state.activity.completed_at ?? state.updated_at,
      attachments: [],
    });
  }
}
await skillRuntime.expirePermissions(state.task, {
  appendEvent: (event) => store.appendEvent(event),
  save: () => store.save(),
});
store.save();

function createAgentDriverInstance() {
  return createAgentDriver(agentDriverName, {
    cwd: root,
    agentDataDir: runtimeDir,
    protocolLogPath:
      process.env.PANEL_PROTOCOL_LOG === "1"
        ? resolve(runtimeDir, "agent-protocol.jsonl")
        : null,
  });
}

let agentDriver = createAgentDriverInstance();

let shuttingDown = false;
let submitInFlight = false;

function setSessionReference(reference) {
  state.session_ref = reference ?? null;
  state.thread_id = state.session_ref;
}

function setSessionName(name) {
  state.session_name = name ?? null;
  state.thread_name = state.session_name;
}

function setSessionRecovered(value) {
  state.session_recovered = value;
  state.thread_recovered = value;
}

const staticFiles = new Map([
  ["/", ["text/html; charset=utf-8", resolve(root, "public", "index.html")]],
  [
    "/app.js",
    ["text/javascript; charset=utf-8", resolve(root, "public", "app.js")],
  ],
  [
    "/draft-storage.js",
    [
      "text/javascript; charset=utf-8",
      resolve(root, "public", "draft-storage.js"),
    ],
  ],
  [
    "/status-model.js",
    [
      "text/javascript; charset=utf-8",
      resolve(root, "public", "status-model.js"),
    ],
  ],
  [
    "/styles.css",
    ["text/css; charset=utf-8", resolve(root, "public", "styles.css")],
  ],
]);

function writeJson(response, statusCode, payload) {
  const body = JSON.stringify(payload);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
  });
  response.end(body);
}

function safeEqual(left, right) {
  const leftBuffer = Buffer.from(left);
  const rightBuffer = Buffer.from(right);
  return (
    leftBuffer.length === rightBuffer.length &&
    timingSafeEqual(leftBuffer, rightBuffer)
  );
}

function parseCookies(header = "") {
  const result = {};
  for (const part of header.split(";")) {
    const [rawName, ...rawValue] = part.trim().split("=");
    if (rawName) {
      result[rawName] = decodeURIComponent(rawValue.join("="));
    }
  }
  return result;
}

function isAuthorized(request) {
  const bearer = request.headers.authorization?.replace(/^Bearer\s+/i, "");
  const cookies = parseCookies(request.headers.cookie);
  return (
    (bearer && safeEqual(bearer, token)) ||
    (cookies.panel_token && safeEqual(cookies.panel_token, token))
  );
}

function hasValidHost(request) {
  const hostHeader = request.headers.host;
  return (
    hostHeader === `127.0.0.1:${port}` ||
    hostHeader === `localhost:${port}`
  );
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 32_768) {
      throw new Error("request body is too large");
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) {
    return {};
  }
  const contentType = request.headers["content-type"] ?? "";
  if (!contentType.startsWith("application/json")) {
    throw new Error("Content-Type must be application/json");
  }
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function publicAttachment(attachment) {
  return {
    id: attachment.id,
    original_name: attachment.original_name,
    mime_type: attachment.mime_type,
    size: attachment.size,
    sha256: attachment.sha256,
    added_at: attachment.added_at,
    preview: attachment.preview ?? "",
  };
}

function publicTask(task) {
  if (!task) {
    return null;
  }
  return {
    ...task,
    attachments: (task.attachments ?? []).map(publicAttachment),
    timeline: (task.timeline ?? []).map((entry) => ({
      ...entry,
      attachments: (entry.attachments ?? []).map(publicAttachment),
    })),
  };
}

function publicState() {
  const sessionRef = state.session_ref ?? state.thread_id ?? null;
  const sessionName = state.session_name ?? state.thread_name ?? null;
  const sessionRecovered =
    state.session_recovered ?? state.thread_recovered ?? null;
  return {
    schema_version: state.schema_version,
    owner: state.owner,
    session_ref: sessionRef,
    session_name: sessionName,
    session_recovered: sessionRecovered,
    // Compatibility aliases for pre-P8 clients and task snapshots.
    thread_id: sessionRef,
    thread_name: sessionName,
    thread_recovered: sessionRecovered,
    task: publicTask(state.task),
    domain_context: skillRuntime.publicContext({ task: state.task }),
    permissions: skillRuntime.publicPermissions(state.task),
    phase: state.phase,
    panel: state.panel,
    draft: {
      events: state.draft.events,
      attachments: state.draft.attachments.map(publicAttachment),
    },
    error: state.error,
    last_turn: state.last_turn,
    activity: state.activity,
    handoff: state.handoff,
    updated_at: state.updated_at,
    event_count: state.event_count,
    agent: driverPublicDescriptor(agentDriver),
    skill: {
      ...publicManifestDescriptor(workbenchManifest),
      ...state.active_skill,
      discovery: state.skill_discovery,
    },
    agent_error: state.agent_error ?? null,
  };
}

function createTask(objective = "等待描述新任务") {
  const taskId = `task-${crypto.randomUUID()}`;
  const domain = skillRuntime.createTaskState({ taskId });
  return {
    task_id: taskId,
    skill: {
      skill_id: state.active_skill.skill_id,
      skill_version: state.active_skill.skill_version,
      manifest_hash: state.active_skill.manifest_hash,
      runtime_id: state.active_skill.runtime_id,
    },
    objective,
    attachments: [],
    artifacts: [],
    actions: [],
    ...domain,
    timeline: [],
    phase: "ready",
    summary: "",
    last_turn: null,
  };
}

function taskContext() {
  return {
    task_id: state.task.task_id,
    session_ref: state.session_ref ?? state.thread_id,
    objective: state.task.objective,
    phase: state.task.phase,
    summary: state.task.summary,
    attachments: state.task.attachments.map(publicAttachmentForAgent),
    skill_context: skillRuntime.buildTaskContext({
      task: state.task,
      attachments: state.task.attachments,
    }),
    instruction:
      "Reuse the supplied Skill context. Do not request repeated local collection unless the user explicitly asks.",
  };
}

function actionHost() {
  return {
    getPanel: () => state.panel,
    setPanel: (panel) => {
      state.panel = panel;
    },
    getSessionReference: () => state.session_ref ?? state.thread_id,
    setError: (message) => {
      state.error = message;
    },
    setPhase: (phase) => {
      state.phase = phase;
    },
    setSubmitting: (value) => {
      submitInFlight = Boolean(value);
    },
    setRunning: () => {
      state.phase = "running";
      state.task.phase = "running";
      state.error = null;
    },
    beginActivity: (label, eventId) => beginActivity(label, eventId),
    completeActivity: (result) => completeActivity(result),
    failActivity: (error) => failActivity(error),
    pushTimeline: (role, text, attachments = []) =>
      pushTimeline(role, text, attachments),
    appendEvent: (event) => store.appendEvent(event),
    save: () => store.save(),
    archive: () => archiveCurrentTask(),
    runAgent: (packet) => sendPanelTurn(packet),
    recordAgentError: (error) => recordAgentError(error),
    setAgentError: (error) => {
      state.agent_error = error;
    },
    setAgentThread: (reference) => {
      setSessionReference(reference ?? state.session_ref);
    },
    getAgentReference: () => agentDriver.activeThreadReference,
    setLastTurn: (turnId) => {
      state.last_turn = {
        id: turnId,
        status: "completed",
        completed_at: new Date().toISOString(),
      };
    },
    updateTaskFromPanel: (panel) => updateTaskFromPanel(panel),
    buildTaskContext: () => taskContext(),
  };
}

function enrichPacket(packet) {
  return skillRuntime.enrichPacket(
    {
      ...packet,
      task_context: packet.task_context ?? taskContext(),
    },
    {
      task: state.task,
      attachments: state.task.attachments,
    },
  );
}

function updateTaskFromPanel(panel) {
  state.task.objective = panel.current_goal;
  state.task.phase = state.phase;
  state.task.summary = panel.turn_summary;
  state.task.last_turn = state.last_turn;
  return state.task;
}

function archiveCurrentTask() {
  if (!state.task) {
    return;
  }
  const snapshot = {
    schema_version: "1.0",
    archived_at: new Date().toISOString(),
    thread_id: state.thread_id,
    thread_name: state.thread_name,
    active_skill: state.active_skill,
    task: state.task,
    panel: state.panel,
    activity: state.activity,
    last_turn: state.last_turn,
  };
  writeFileSync(
    resolve(taskArchiveDir, `${state.task.task_id}.json`),
    `${JSON.stringify(snapshot, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

function pushTimeline(role, text, attachments = []) {
  state.task.timeline.push({
    id: `timeline-${crypto.randomUUID()}`,
    role,
    text,
    created_at: new Date().toISOString(),
    attachments: attachments.map(publicAttachment),
  });
}

function findTaskAttachment(id) {
  return state.task?.attachments?.find((item) => item.id === id) ?? null;
}

function panelSubmission(freeText, attachments) {
  const events = [...state.draft.events];
  if (events.length === 0 && freeText) {
    events.push({
      schema_version: "1.0",
      type: "user_message",
      event_id: crypto.randomUUID(),
      created_at: new Date().toISOString(),
      text: freeText,
    });
  }
  return {
    schema_version: "1.0",
    type: "panel_submission",
    submission_id: crypto.randomUUID(),
    created_at: new Date().toISOString(),
    events,
    free_text: freeText || "",
    task_context: taskContext(),
    attachments,
  };
}

function summarizeSubmission(packet) {
  const selected = packet.events?.find(
    (event) => event.type === "option_selected",
  );
  const selectedLabel = selected
    ? state.panel?.question?.options?.find(
        (option) => option.id === selected.option_id,
      )?.label ?? selected.option_id
    : "";
  const evidence = (packet.events ?? [])
    .filter((event) => event.type === "evidence_added")
    .map((event) => event.label);
  return [
    selectedLabel ? `选择：${selectedLabel}` : "",
    packet.free_text ? `补充：${packet.free_text}` : "",
    evidence.length ? `证据：${evidence.join("、")}` : "",
  ]
    .filter(Boolean)
    .join("；");
}

function beginActivity(userSummary, eventId) {
  const now = new Date().toISOString();
  state.activity = {
    status: "running",
    user_summary: userSummary,
    submitted_at: now,
    started_at: now,
    completed_at: null,
    agent_summary: "",
    next_action: "",
    error: null,
    turn_id: eventId ?? null,
  };
}

function completeActivity(result) {
  const completedAt = new Date().toISOString();
  state.activity = {
    ...(state.activity ?? {}),
    status: "completed",
    completed_at: completedAt,
    agent_summary: result.panel.turn_summary,
    next_action:
      result.panel.priorityAction?.title || result.panel.next_action || "",
    error: null,
    turn_id: result.turnId,
    elapsed_ms: Math.max(
      0,
      Date.parse(completedAt) - Date.parse(state.activity?.started_at ?? completedAt),
    ),
  };
}

function failActivity(error) {
  const completedAt = new Date().toISOString();
  state.activity = {
    ...(state.activity ?? {}),
    status: "error",
    completed_at: completedAt,
    error: error.message,
    elapsed_ms: Math.max(
      0,
      Date.parse(completedAt) - Date.parse(state.activity?.started_at ?? completedAt),
    ),
  };
}

function threadNameForPanel(panel, fallback = "新任务") {
  return skillRuntime.taskName(panel, fallback);
}

const MAX_ATTACHMENT_BYTES = 8 * 1024 * 1024;
const ALLOWED_ATTACHMENT_TYPES = new Map([
  [".csv", ["text/csv", "application/vnd.ms-excel", "text/plain", "application/octet-stream"]],
  [".txt", ["text/plain", "application/octet-stream"]],
  [".log", ["text/plain", "text/x-log", "application/octet-stream"]],
  [".json", ["application/json", "text/plain", "application/octet-stream"]],
  [".png", ["image/png"]],
  [".jpg", ["image/jpeg"]],
  [".jpeg", ["image/jpeg"]],
  [".webp", ["image/webp"]],
]);

function sanitizeOriginalName(name) {
  const normalized = basename(String(name).replaceAll("\\", "/"))
    .replace(/[\u0000-\u001f<>:"/\\|?*]/g, "_")
    .trim();
  return (normalized || "attachment").slice(0, 120);
}

function attachmentPreview(buffer, extension) {
  if (![".csv", ".txt", ".log", ".json"].includes(extension)) {
    return "";
  }
  return buffer
    .toString("utf8")
    .replace(/\u0000/g, "")
    .slice(0, 800);
}

async function parseMultipart(request) {
  const contentLength = Number(request.headers["content-length"] ?? "0");
  if (!contentLength || contentLength > MAX_ATTACHMENT_BYTES + 512 * 1024) {
    const error = new Error("附件请求超过 8 MB 限制");
    error.statusCode = 413;
    throw error;
  }
  const headers = new Headers();
  for (const [name, value] of Object.entries(request.headers)) {
    if (value !== undefined) {
      headers.set(name, Array.isArray(value) ? value.join(", ") : value);
    }
  }
  const webRequest = new Request(`http://${host}${request.url}`, {
    method: request.method,
    headers,
    body: Readable.toWeb(request),
    duplex: "half",
  });
  return webRequest.formData();
}

function publicAttachmentForAgent(attachment) {
  return {
    id: attachment.id,
    original_name: attachment.original_name,
    mime_type: attachment.mime_type,
    size: attachment.size,
    sha256: attachment.sha256,
    local_path: attachment.local_path,
  };
}

function commitDraftAttachments() {
  if (!state.task) {
    throw new Error("Task must exist before attaching evidence");
  }
  const committed = [];
  for (const attachment of state.draft.attachments) {
    if (!state.task.attachments.some((item) => item.id === attachment.id)) {
      state.task.attachments.push(attachment);
    }
    committed.push(publicAttachmentForAgent(attachment));
  }
  skillRuntime.commitAttachments({
    task: state.task,
    attachments: state.draft.attachments,
  });
  return committed;
}

function findAttachment(id) {
  return (
    state.draft.attachments.find((item) => item.id === id) ??
    state.task?.attachments?.find((item) => item.id === id) ??
    null
  );
}

function isInsideAttachmentRoot(filePath) {
  return isInsideRoot(attachmentRoot, filePath);
}

function isInsideRoot(rootPath, filePath) {
  const relativePath = relative(rootPath, resolve(filePath));
  return (
    relativePath !== "" &&
    !relativePath.startsWith("..") &&
    !isAbsolute(relativePath)
  );
}

async function updateThreadName(panel, fallback = "新任务") {
  const desired = threadNameForPanel(panel, fallback);
  if (
    state.session_name === desired &&
    agentDriver.activeThreadName === desired
  ) {
    return desired;
  }
  try {
    if (agentDriver.capabilities.supportsThreadNaming) {
      setSessionName(await agentDriver.setThreadName(desired));
    } else {
      setSessionName(desired);
    }
  } catch (error) {
    const agentError = agentDriver.classifyError(error);
    setSessionName(state.session_name || desired);
    store.appendEvent({
      type: "thread.name_error",
      message: agentError.message,
      error_class: agentError.classification,
    });
  }
  return state.thread_name;
}

async function sendPanelTurn(packet) {
  const enrichedPacket = enrichPacket(packet);
  return runPanelTurn({
    driver: agentDriver,
    threadReference: state.thread_id,
    eventId:
      enrichedPacket.event_id ??
      enrichedPacket.submission_id ??
      crypto.randomUUID(),
    packet: enrichedPacket,
    outputSchema: panelOutputSchema,
    domainValidator: (panel, context) =>
      skillRuntime.validatePanelResult(panel, {
        task: state.task,
        packet: context.packet,
      }),
  });
}

function recordAgentError(error) {
  const agentError = agentDriver.classifyError(error);
  state.agent_error = {
    classification: agentError.classification,
    code: agentError.code,
    message: agentError.message,
    diagnostic_ref:
      error?.diagnosticPath &&
      isInsideRoot(runtimeDir, error.diagnosticPath)
        ? relative(runtimeDir, error.diagnosticPath).replaceAll("\\", "/")
        : null,
    occurred_at: new Date().toISOString(),
  };
  return agentError;
}

async function submit(request, response) {
  if (submitInFlight) {
    writeJson(response, 409, { error: "agent 正在进行上一回合" });
    return;
  }
  const body = await readJson(request);
  const freeText = String(body.free_text ?? "").trim().slice(0, 2000);
  if (state.panel === null) {
    if (!freeText && state.draft.attachments.length === 0) {
      throw new Error("请输入电脑遇到的问题");
    }
    if (!state.task) {
      state.task = createTask(
        freeText ||
          `分析附件：${state.draft.attachments.map((item) => item.original_name).join("、")}`,
      );
    }
    const attachments = commitDraftAttachments();
    store.appendEvent({
      type: "task.created",
      task_id: state.task.task_id,
      thread_id: state.thread_id,
      objective: state.task.objective,
    });
    const eventText =
      freeText ||
      `请分析附件：${state.draft.attachments.map((item) => item.original_name).join("、")}`;
    submitInFlight = true;
    const event = enrichPacket({
      schema_version: "1.0",
      type: "user_message",
      event_id: crypto.randomUUID(),
      created_at: new Date().toISOString(),
      text: eventText,
      task_context: taskContext(),
      attachments,
    });
    state.phase = "running";
    state.task.phase = "running";
    state.error = null;
    state.task.objective = eventText.slice(0, 120);
    beginActivity(eventText, event.event_id);
    pushTimeline("user", eventText, state.draft.attachments);
    store.appendEvent({
      type: "task_submitted",
      event_id: crypto.randomUUID(),
      created_at: new Date().toISOString(),
      task_id: state.task.task_id,
      thread_id: state.thread_id,
      user_event_id: event.event_id,
      user_summary: eventText,
      attachment_ids: attachments.map((item) => item.id),
    });
    store.appendEvent({ type: "ui.user_message", event });
    store.save();
    try {
      const result = await sendPanelTurn(event);
      setSessionReference(agentDriver.activeThreadReference);
      state.agent_error = null;
      await updateThreadName(result.panel, freeText);
      state.panel = result.panel;
      state.phase =
        result.panel.status === "needs_input" ? "needs_input" : result.panel.status;
      state.last_turn = {
        id: result.turnId,
        status: "completed",
        completed_at: new Date().toISOString(),
      };
      updateTaskFromPanel(result.panel);
      state.draft.events = [];
      state.draft.attachments = [];
      state.error = null;
      completeActivity(result);
      pushTimeline("agent", result.panel.turn_summary);
      archiveCurrentTask();
      store.appendEvent({
        type: "agent.panel_updated",
        turn_id: result.turnId,
        summary: result.panel.turn_summary,
        thread_name: state.thread_name,
      });
    } catch (error) {
      const agentError = recordAgentError(error);
      if (agentDriver.activeThreadReference) {
        setSessionReference(agentDriver.activeThreadReference);
      }
      state.phase = "error";
      state.task.phase = "error";
      state.error = agentError.message;
      failActivity(agentError);
      store.appendEvent({
        type: "agent.turn_error",
        message: agentError.message,
        error_class: agentError.classification,
        error_code: agentError.code,
      });
    } finally {
      submitInFlight = false;
      store.save();
    }
    writeJson(response, state.phase === "error" ? 502 : 200, publicState());
    return;
  }

  const hasOption = state.draft.events.some(
    (event) => event.type === "option_selected",
  );
  if (!hasOption && !freeText && state.draft.attachments.length === 0) {
    throw new Error("请选择一个选项或补充一条说明");
  }
  const attachments = commitDraftAttachments();
  const packet = enrichPacket(panelSubmission(freeText, attachments));
  submitInFlight = true;
  state.phase = "running";
  state.task.phase = "running";
  state.error = null;
  beginActivity(summarizeSubmission(packet), packet.submission_id);
  const userSummary =
    summarizeSubmission(packet) ||
    `请分析附件：${state.draft.attachments.map((item) => item.original_name).join("、")}`;
  pushTimeline("user", userSummary, state.draft.attachments);
  store.appendEvent({
    type: "task_submitted",
    event_id: crypto.randomUUID(),
    created_at: new Date().toISOString(),
    task_id: state.task.task_id,
    thread_id: state.thread_id,
    user_event_id: packet.submission_id,
    user_summary: userSummary,
    attachment_ids: attachments.map((item) => item.id),
  });
  store.appendEvent({ type: "ui.panel_submission", packet });
  store.save();
  try {
    const result = await sendPanelTurn(packet);
    setSessionReference(agentDriver.activeThreadReference);
    state.agent_error = null;
    await updateThreadName(result.panel);
    state.panel = result.panel;
    state.phase =
      result.panel.status === "needs_input" ? "needs_input" : result.panel.status;
    state.last_turn = {
      id: result.turnId,
      status: "completed",
      completed_at: new Date().toISOString(),
    };
    updateTaskFromPanel(result.panel);
    state.draft.events = [];
    state.draft.attachments = [];
    state.error = null;
    completeActivity(result);
    pushTimeline("agent", result.panel.turn_summary);
    archiveCurrentTask();
    store.appendEvent({
      type: "agent.panel_updated",
      turn_id: result.turnId,
      summary: result.panel.turn_summary,
      thread_name: state.thread_name,
    });
  } catch (error) {
    const agentError = recordAgentError(error);
    if (agentDriver.activeThreadReference) {
      setSessionReference(agentDriver.activeThreadReference);
    }
    state.phase = "error";
    state.task.phase = "error";
    state.error = agentError.message;
    failActivity(agentError);
    store.appendEvent({
      type: "agent.turn_error",
      message: agentError.message,
      error_class: agentError.classification,
      error_code: agentError.code,
    });
  } finally {
    submitInFlight = false;
    store.save();
  }
  writeJson(response, state.phase === "error" ? 502 : 200, publicState());
}

async function startNewTask({ newThread }) {
  if (submitInFlight) {
    throw new Error("agent 回合进行中，暂时不能新建任务");
  }
  discardDraftAttachmentFiles();
  archiveCurrentTask();
  if (!newThread) {
    store.startTaskDraft({
      threadReference: state.thread_id,
      threadName: state.thread_name,
    });
    setSessionName(await updateThreadName(null, "新任务"));
    state.phase = "ready";
    store.save();
    return;
  }

  await agentDriver.close();
  agentDriver = createAgentDriverInstance();
  await agentDriver.initialize();
  const started = await agentDriver.startThread();
  const activeThreadReference = started.threadReference;
  store.startTaskDraft({
    threadReference: activeThreadReference,
    threadName: null,
  });
  setSessionReference(activeThreadReference);
  setSessionRecovered(null);
  await updateThreadName(null, "新任务");
  state.phase = "ready";
  store.appendEvent({
    type: "thread.created",
    thread_id: activeThreadReference,
    skill_id: state.active_skill?.skill_id ?? null,
  });
  store.save();
}

async function uploadAttachment(request, response) {
  const form = await parseMultipart(request);
  const file = form.get("file");
  if (!file || typeof file.arrayBuffer !== "function" || typeof file.name !== "string") {
    writeJson(response, 400, { error: "附件请求缺少文件" });
    return;
  }
  const originalName = sanitizeOriginalName(file.name);
  const extension = extname(originalName).toLowerCase();
  const mimeType = file.type || "application/octet-stream";
  const allowedMimeTypes = ALLOWED_ATTACHMENT_TYPES.get(extension);
  if (!allowedMimeTypes || !allowedMimeTypes.includes(mimeType)) {
    writeJson(response, 415, {
      error: "仅支持 CSV、TXT、LOG、JSON、PNG、JPEG 或 WEBP 文件",
    });
    return;
  }
  if (file.size > MAX_ATTACHMENT_BYTES) {
    writeJson(response, 413, { error: "单个附件不能超过 8 MB" });
    return;
  }
  const buffer = Buffer.from(await file.arrayBuffer());
  const id = `attachment-${randomUUID()}`;
  const storedName = `${id}-${originalName}`;
  const localPath = resolve(attachmentRoot, storedName);
  if (!isInsideAttachmentRoot(localPath)) {
    throw new Error("unsafe attachment path");
  }
  writeFileSync(localPath, buffer, { mode: 0o600 });
  const attachment = {
    id,
    original_name: originalName,
    mime_type: mimeType,
    size: buffer.length,
    sha256: createHash("sha256").update(buffer).digest("hex"),
    added_at: new Date().toISOString(),
    local_path: localPath,
    preview: attachmentPreview(buffer, extension),
  };
  state.draft.attachments.push(attachment);
  store.appendEvent({
    type: "attachment_added",
    event_id: crypto.randomUUID(),
    created_at: attachment.added_at,
    attachment: publicAttachmentForAgent(attachment),
  });
  state.error = null;
  store.save();
  writeJson(response, 200, publicState());
}

// P9_SKILL_ACTION_ROUTES

async function decidePermission(request, response) {
  if (!state.task) {
    writeJson(response, 409, { error: "当前没有可授权的任务" });
    return;
  }
  const body = await readJson(request);
  const outcome = await skillRuntime.decidePermission({
    task: state.task,
    body,
    host: actionHost(),
  });
  if (outcome.error) {
    writeJson(response, outcome.statusCode ?? 400, {
      error: outcome.error,
    });
    return;
  }
  store.save();
  writeJson(response, outcome.statusCode ?? 200, publicState());
}

async function revokePermission(request, response) {
  if (!state.task) {
    writeJson(response, 409, { error: "当前没有可撤销权限的任务" });
    return;
  }
  const body = await readJson(request);
  const outcome = await skillRuntime.revokePermission({
    task: state.task,
    body,
    host: actionHost(),
  });
  if (outcome.error) {
    writeJson(response, outcome.statusCode ?? 400, {
      error: outcome.error,
    });
    return;
  }
  store.save();
  writeJson(response, outcome.statusCode ?? 200, publicState());
}

async function invokeSkillAction(
  actionId,
  request,
  response,
  bodyOverride = null,
) {
  if (submitInFlight) {
    writeJson(response, 409, { error: "agent 正在进行上一回合" });
    return;
  }
  if (!state.task) {
    writeJson(response, 409, { error: "请先创建 Task" });
    return;
  }
  const action = skillRuntime.getLocalAction(actionId);
  if (!action) {
    writeJson(response, 404, {
      error: "当前 Skill 不提供该本地操作",
      code: "local_action_not_found",
    });
    return;
  }
  const body = bodyOverride ?? await readJson(request);
  const attachmentId = String(body.attachment_id ?? "");
  if (!/^attachment-[a-f0-9-]{20,60}$/u.test(attachmentId)) {
    writeJson(response, 400, { error: "attachment_id 无效" });
    return;
  }
  const attachment = findTaskAttachment(attachmentId);
  if (!attachment) {
    writeJson(response, 404, { error: "当前 Task 中找不到该附件" });
    return;
  }
  const extension = extname(attachment.original_name ?? "").toLowerCase();
  if (!action.attachmentExtensions.includes(extension)) {
    writeJson(response, 415, {
      error: "该附件类型不适用于当前操作",
    });
    return;
  }
  let outcome;
  try {
    outcome = await skillRuntime.runLocalAction({
      actionId,
      input: body,
      task: state.task,
      attachment,
      host: actionHost(),
    });
  } catch (error) {
    writeJson(response, error?.statusCode ?? 400, {
      error: error?.message || "本地操作失败",
      code: error?.code || "local_action_failed",
    });
    return;
  }
  const nextState = publicState();
  const payload = {
    ...nextState,
    ...(outcome.body ?? {}),
    state: nextState,
  };
  writeJson(response, outcome.statusCode ?? 200, payload);
}

function serveArtifact(url, response) {
  const match = url.pathname.match(
    /^\/api\/artifacts\/(artifact-[a-f0-9-]{20,80})\/content$/u,
  );
  if (!match) {
    return false;
  }
  const artifact = skillRuntime.getArtifact(match[1]);
  if (!artifact) {
    writeJson(response, 404, { error: "图表不存在" });
    return true;
  }
  const body = readFileSync(artifact.absolute_path);
  const hash = createHash("sha256").update(body).digest("hex");
  if (hash !== artifact.sha256) {
    writeJson(response, 409, { error: "图表哈希校验失败" });
    return true;
  }
  const download = url.searchParams.get("download") === "1";
  const extension = extname(artifact.relative_path ?? "");
  const filename = `${artifact.id}${extension || ""}`;
  response.writeHead(200, {
    "Content-Type": artifact.mime,
    "Content-Length": body.length,
    "Cache-Control": "private, max-age=31536000, immutable",
    ETag: `"${artifact.sha256}"`,
    "Content-Disposition": download
      ? `attachment; filename="${filename}"`
      : `inline; filename="${filename}"`,
    "Content-Security-Policy":
      "default-src 'none'; style-src 'unsafe-inline'; img-src data:",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  response.end(body);
  return true;
}

function removeDraftAttachment(id, response) {
  const index = state.draft.attachments.findIndex((item) => item.id === id);
  if (index < 0) {
    writeJson(response, 409, { error: "已发送的文件保存在任务证据中，不能从当前草稿删除" });
    return;
  }
  const [attachment] = state.draft.attachments.splice(index, 1);
  if (isInsideAttachmentRoot(attachment.local_path) && existsSync(attachment.local_path)) {
    unlinkSync(attachment.local_path);
  }
  store.appendEvent({
    type: "attachment_removed",
    event_id: crypto.randomUUID(),
    created_at: new Date().toISOString(),
    attachment_id: attachment.id,
  });
  store.save();
  writeJson(response, 200, publicState());
}

function discardDraftAttachmentFiles() {
  for (const attachment of state.draft.attachments) {
    if (
      isInsideAttachmentRoot(attachment.local_path) &&
      existsSync(attachment.local_path)
    ) {
      try {
        unlinkSync(attachment.local_path);
      } catch {
        // A stale draft file should not prevent the user from starting a task.
      }
    }
  }
}

function sanitizeResumeText(value, maxLength = 1200) {
  return String(value ?? "")
    .replace(/\u0000/g, "")
    .replace(/[\u0001-\u0008\u000b\u000c\u000e-\u001f\u007f]/gu, "")
    .replace(/[\u202a-\u202e\u2066-\u2069]/gu, "")
    .replace(/[A-Za-z]:[\\/][^\r\n<>"'`]+/gu, "[本地路径已移除]")
    .replace(/\\\\[^\\\r\n]+\\.*/gu, "[本地路径已移除]")
    .replace(/file:\/\/[^\s]+/giu, "[本地路径已移除]")
    .replace(
      /(^|[\s(])\/(?:Users|home|tmp|var|private|mnt)\/[^\s)]+/gu,
      "$1[本地路径已移除]",
    )
    .replace(
      /(?:panel_token|capability-token|handoff-secret|token)\s*[=:]\s*\S+/giu,
      "[凭据已移除]",
    )
    .replace(/[ \t]+/gu, " ")
    .replace(/\n{3,}/gu, "\n\n")
    .trim()
    .slice(0, maxLength);
}

function buildResumePacket() {
  if (!state.task) {
    throw new Error("No active task to resume");
  }
  const panel = state.panel;
  const handoffContext = skillRuntime.buildHandoffContext({
    task: state.task,
    panel,
  });
  const panelEvidence = (panel?.evidence ?? [])
    .filter((item) => ["supports", "conflicts"].includes(item.relation))
    .slice(0, 4);
  const evidenceLines = [
    ...panelEvidence.map(
      (item) =>
        `${item.relation === "conflicts" ? "冲突" : "支持"}：${sanitizeResumeText(item.label, 100)} — ${sanitizeResumeText(item.detail, 260)}`,
    ),
  ].filter((item, index, list) => item && list.indexOf(item) === index);
  const uncertainty = (
    panel?.uncertainty ??
    panel?.limitations ??
    ["当前没有补充的不确定性记录。"]
  )
    .slice(0, 6)
    .map((item) => sanitizeResumeText(item, 280));
  if (panel?.question?.prompt) {
    uncertainty.push(
      `待选择：${sanitizeResumeText(panel.question.prompt, 240)}`,
    );
  }
  const priority =
    panel?.priorityAction ??
    (panel?.next_action
      ? { title: "继续下一步", detail: panel.next_action }
      : null);
  const judgement =
    panel?.judgement ??
    panel?.turn_summary ??
    state.task.summary ??
    "尚未形成当前判断。";
  const artifacts = (panel?.artifact_refs ?? []).slice(0, 6);
  const sourceThreadReference =
    state.handoff?.thread_id ?? state.session_ref ?? state.thread_id;
  const panelSessionReference = state.session_ref ?? state.thread_id;
  const lines = [
    "# Workbench 任务继续摘要",
    "",
    "这是从独立面板带回来源 Agent 对话的紧凑摘要，不包含聊天全文、凭据或本地绝对路径。",
    "",
    `- Task：${sanitizeResumeText(state.task.objective, 160)}`,
    `- 来源 Session：${sourceThreadReference ?? "未记录"}`,
    `- 面板 Session：${panelSessionReference ?? "未记录"}（独立执行，不是来源 Session 的 owner）`,
    `- Panel task：${state.task.task_id}`,
    `- Skill：${sanitizeResumeText(workbenchManifest.skill.name, 120)} · ${sanitizeResumeText(workbenchManifest.skill.version, 40)}`,
    ...handoffContext.lines,
    "",
    "## 已完成关键证据",
    ...(evidenceLines.length
      ? evidenceLines.map((item) => `- ${item}`)
      : ["- 暂无结构化证据摘要。"]),
    "",
    "## 当前判断",
    sanitizeResumeText(judgement, 1600),
    "",
    "## 未决问题",
    ...(uncertainty.length
      ? uncertainty.map((item) => `- ${item}`)
      : ["- 暂无记录。"]),
    "",
    "## 最优先下一步",
    `**${sanitizeResumeText(priority?.title ?? "继续任务", 120)}**`,
    "",
    sanitizeResumeText(priority?.detail ?? "等待新的本地证据。", 900),
    "",
    "## 面板引用",
    `- Task：${state.task.task_id}`,
    ...(artifacts.length
      ? artifacts.map(
          (artifact) =>
            `- ${artifact.id} · ${sanitizeResumeText(artifact.title, 100)} · ${sanitizeResumeText(artifact.relative_path, 200)}`,
        )
      : ["- 暂无 artifact。" ]),
    `- Domain refs：${(state.task.domain_refs ?? [])
      .slice(0, 12)
      .map((item) => sanitizeResumeText(item, 160))
      .join("、") || "无"}`,
    "",
    "## 返回方式",
    `- 返回来源 Session 继续：${sourceThreadReference ?? "未记录"}`,
    "- Panel 未接管来源 Session；本条摘要可复制到来源 Agent 对话继续。",
  ];
  const markdown = lines.join("\n");
  return {
    schema_version: "1.0",
    generated_at: new Date().toISOString(),
    session_ref: panelSessionReference,
    source_session_ref: sourceThreadReference,
    // Compatibility aliases for existing handoff consumers.
    source_thread_id: sourceThreadReference,
    panel_thread_id: panelSessionReference,
    active_skill: state.active_skill,
    skill_handoff: handoffContext.data,
    task_id: state.task.task_id,
    artifact_refs: artifacts.map((artifact) => ({
      id: artifact.id,
      kind: artifact.kind,
      relative_path: artifact.relative_path,
    })),
    markdown,
    contains_absolute_paths:
      /(?:[A-Za-z]:[\\/]|(?:^|\s)\/(?:Users|home|tmp|var|private|mnt)\/)/u.test(
        markdown,
      ),
    contains_raw_transcript: false,
  };
}

function receiveHandoff(request, response, url) {
  const handoffToken = url.searchParams.get("token");
  let verified;
  try {
    verified = verifyHandoffToken(handoffToken, handoffSecret);
  } catch (error) {
    writeJson(response, 401, { error: error.message });
    return;
  }
  if (state.handoff_consumed_nonces.includes(verified.nonce)) {
    writeJson(response, 409, { error: "handoff token has already been used" });
    return;
  }
  state.handoff_consumed_nonces.push(verified.nonce);
  state.handoff_consumed_nonces =
    state.handoff_consumed_nonces.slice(-200);
  const packet = verified.packet;
  if (!state.task || state.task.task_id !== packet.task_id) {
    archiveCurrentTask();
    const domain = skillRuntime.createTaskState({ taskId: packet.task_id });
    state.task = {
      task_id: packet.task_id,
      skill: {
        skill_id: state.active_skill.skill_id,
        skill_version: state.active_skill.skill_version,
        manifest_hash: state.active_skill.manifest_hash,
        runtime_id: state.active_skill.runtime_id,
      },
      objective: packet.objective,
      attachments: [],
      artifacts: [],
      actions: [],
      ...domain,
      timeline: [
        {
          id: `timeline-${crypto.randomUUID()}`,
          role: "tool",
          text: "已从来源对话继续任务；当前面板是独立执行视图。",
          created_at: new Date().toISOString(),
          attachments: [],
        },
      ],
      phase: "ready",
      summary: packet.summary,
      last_turn: null,
    };
    state.panel = null;
    state.phase = "ready";
    state.activity = null;
    state.last_turn = null;
    state.draft = { events: [], attachments: [] };
    skillRuntime.applyHandoff({ task: state.task, packet });
  } else {
    state.task.objective = packet.objective || state.task.objective;
    state.task.summary = packet.summary || state.task.summary;
    skillRuntime.applyHandoff({ task: state.task, packet });
  }
  state.handoff = {
    schema_version: "1.0",
    status: "task_resume_packet",
    support_level: "task-resume-packet",
    native_thread_attached:
      agentDriver.capabilities.supportsActiveThreadAttach === true,
    native_attachment_error:
      agentDriver.capabilities.supportsActiveThreadAttach === true
        ? null
        : agentDriver.capabilities.activeThreadAttachReason ??
          "The source conversation cannot be attached by this Agent driver.",
    queue_capability: "one-way-experimental",
    queue_message_sent: false,
    reply_visibility: "unavailable",
    panel_view_mode: "independent",
    source_thread_role: "return-target",
    context_applied: true,
    local_surface_handoff: true,
    native_owner_changed: false,
    thread_id: packet.thread_id,
    environment_thread_id: packet.environment_thread_id,
    thread_id_mismatch:
      Boolean(packet.environment_thread_id) &&
      packet.environment_thread_id !== packet.thread_id,
    task_id: packet.task_id,
    objective: packet.objective,
    summary: packet.summary,
    active_skill: state.active_skill,
    domain_refs: state.task.domain_refs,
    source: packet.source,
    current_task_matches: state.task?.task_id === packet.task_id,
    current_domain_refs: state.task?.domain_refs ?? [],
    received_at: new Date().toISOString(),
    token_expires_at: verified.expires_at,
  };
  state.error = null;
  store.appendEvent({
    type: "handoff.received",
    thread_id: packet.thread_id,
    environment_thread_id: packet.environment_thread_id,
    thread_id_mismatch: state.handoff.thread_id_mismatch,
    task_id: packet.task_id,
    active_skill_id: state.active_skill?.skill_id ?? null,
    domain_ref_count: state.task?.domain_refs?.length ?? 0,
    support_level: "task-resume-packet",
    native_thread_attached: false,
  });
  store.appendEvent({
    type: "handoff.native_attachment_blocked",
    thread_id: packet.thread_id,
    reason: state.handoff.native_attachment_error,
    queue_message_sent: false,
  });
  store.appendEvent({
    type: "handoff.local_surface_handoff",
    thread_id: packet.thread_id,
    task_id: packet.task_id,
    panel_thread_id: state.thread_id,
    panel_view_mode: "independent",
    native_owner_changed: false,
  });
  store.save();
  response.writeHead(303, {
    Location: "/",
    "Cache-Control": "no-store",
    "Set-Cookie":
      `panel_token=${encodeURIComponent(token)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400`,
    "Referrer-Policy": "no-referrer",
    "Content-Length": 0,
  });
  response.end();
}

async function route(request, response) {
  if (!hasValidHost(request)) {
    writeJson(response, 403, { error: "invalid host" });
    return;
  }
  const url = new URL(request.url, `http://${request.headers.host}`);

  if (request.method === "GET" && staticFiles.has(url.pathname)) {
    const [contentType, filePath] = staticFiles.get(url.pathname);
    const body = readFileSync(filePath);
    const headers = {
      "Content-Type": contentType,
      "Cache-Control": "no-store",
      "Content-Security-Policy":
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
    };
    if (url.pathname === "/") {
      headers["Set-Cookie"] =
        `panel_token=${encodeURIComponent(token)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400`;
    }
    response.writeHead(200, headers);
    response.end(body);
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/health") {
    writeJson(response, 200, {
      ok: !shuttingDown,
      driver: agentDriverName,
      agent_ready: Boolean(agentDriver.activeThreadReference),
      capabilities: agentDriver.capabilities,
    });
    return;
  }

  if (request.method === "GET" && url.pathname === "/handoff/open") {
    receiveHandoff(request, response, url);
    return;
  }

  if (!isAuthorized(request)) {
    writeJson(response, 401, { error: "missing or invalid capability token" });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/state") {
    writeJson(response, 200, publicState());
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/resume-packet") {
    try {
      writeJson(response, 200, buildResumePacket());
    } catch (error) {
      writeJson(response, 409, { error: error.message });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/permissions/request") {
    const body = await readJson(request);
    const attachment = findTaskAttachment(String(body.attachment_id ?? ""));
    const extension = extname(attachment?.original_name ?? "").toLowerCase();
    const capability = workbenchManifest.domain.capabilities.find(
      (item) => item.ui?.attachment_extensions?.includes(extension),
    );
    if (!capability) {
      writeJson(response, 415, {
        error: "该附件类型没有对应的本地 Skill 操作",
      });
      return;
    }
    await invokeSkillAction(
      String(body.action_id ?? capability?.id ?? ""),
      request,
      response,
      body,
    );
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/permissions/decide") {
    await decidePermission(request, response);
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/permissions/revoke") {
    await revokePermission(request, response);
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/attachments") {
    await uploadAttachment(request, response);
    return;
  }

  const skillActionMatch = url.pathname.match(
    /^\/api\/skill\/actions\/([a-z0-9._-]+)$/u,
  );
  if (request.method === "POST" && skillActionMatch) {
    await invokeSkillAction(skillActionMatch[1], request, response);
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/artifacts/analyze") {
    const body = await readJson(request);
    const attachment = findTaskAttachment(String(body.attachment_id ?? ""));
    const extension = extname(attachment?.original_name ?? "").toLowerCase();
    const capability = workbenchManifest.domain.capabilities.find(
      (item) => item.ui?.attachment_extensions?.includes(extension),
    );
    if (!capability) {
      writeJson(response, 415, {
        error: "该附件类型没有对应的本地 Skill 操作",
      });
      return;
    }
    await invokeSkillAction(
      String(body.action_id ?? capability?.id ?? ""),
      request,
      response,
      body,
    );
    return;
  }

  if (
    request.method === "GET" &&
    url.pathname.startsWith("/api/artifacts/") &&
    serveArtifact(url, response)
  ) {
    return;
  }

  const attachmentContentMatch = url.pathname.match(
    /^\/api\/attachments\/([A-Za-z0-9_-]+)\/content$/,
  );
  if (request.method === "GET" && attachmentContentMatch) {
    const attachment = findAttachment(attachmentContentMatch[1]);
    if (!attachment || !isInsideAttachmentRoot(attachment.local_path)) {
      writeJson(response, 404, { error: "附件不存在" });
      return;
    }
    const body = readFileSync(attachment.local_path);
    response.writeHead(200, {
      "Content-Type": attachment.mime_type,
      "Content-Length": body.length,
      "Cache-Control": "no-store",
      "Content-Disposition": `inline; filename*=UTF-8''${encodeURIComponent(attachment.original_name)}`,
      "X-Content-Type-Options": "nosniff",
    });
    response.end(body);
    return;
  }

  const attachmentRemoveMatch = url.pathname.match(
    /^\/api\/attachments\/([A-Za-z0-9_-]+)$/,
  );
  if (request.method === "DELETE" && attachmentRemoveMatch) {
    removeDraftAttachment(attachmentRemoveMatch[1], response);
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/event") {
    const body = await readJson(request);
    const event = buildDraftEvent(body, state.panel);
    if (event.type === "option_selected") {
      state.draft.events = state.draft.events.filter(
        (item) => item.type !== "option_selected",
      );
    }
    state.draft.events.push(event);
    if (event.type === "evidence_added") {
      skillRuntime.recordEvidence({ task: state.task, evidence: event });
    }
    store.appendEvent({ type: `ui.${event.type}`, event });
    state.error = null;
    store.save();
    writeJson(response, 200, publicState());
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/submit") {
    await submit(request, response);
    return;
  }

  if (
    request.method === "POST" &&
    (url.pathname === "/api/task/new" || url.pathname === "/api/reset")
  ) {
    if (submitInFlight) {
      writeJson(response, 409, { error: "agent 回合进行中，暂时不能重置" });
      return;
    }
    await startNewTask({ newThread: false });
    writeJson(response, 200, publicState());
    return;
  }

  if (
    request.method === "POST" &&
    (url.pathname === "/api/session/new" ||
      url.pathname === "/api/thread/new")
  ) {
    if (submitInFlight) {
      writeJson(response, 409, { error: "agent 回合进行中，暂时不能新建对话" });
      return;
    }
    await startNewTask({ newThread: true });
    writeJson(response, 200, publicState());
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/shutdown") {
    writeJson(response, 200, { ok: true });
    setImmediate(shutdown);
    return;
  }

  writeJson(response, 404, { error: "not found" });
}

const server = createServer((request, response) => {
  route(request, response).catch((error) => {
    if (!response.headersSent) {
      writeJson(response, 400, { error: error.message });
    } else {
      response.end();
    }
  });
});

async function shutdown() {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  await agentDriver.close().catch(() => {});
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2_000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

try {
  const previousThreadReference = state.session_ref;
  await agentDriver.initialize();
  let started;
  let resumeError = null;
  if (
    previousThreadReference &&
    agentDriver.capabilities.supportsThreadResume
  ) {
    try {
      started = await agentDriver.resumeThread(previousThreadReference);
    } catch (error) {
      resumeError = agentDriver.classifyError(error);
      started = await agentDriver.startThread();
    }
  } else {
    started = await agentDriver.startThread();
    if (previousThreadReference) {
      resumeError = new AgentDriverError(
        "blocked",
        "thread_resume_unsupported",
        `${agentDriver.displayName} does not support Session resume`,
      );
    }
  }
  const activeThreadReference = started.threadReference;
  setSessionReference(activeThreadReference);
  if (resumeError) {
    state.agent_error = {
      classification: resumeError.classification,
      code: resumeError.code,
      message: resumeError.message,
      occurred_at: new Date().toISOString(),
    };
    setSessionRecovered({
      previous_thread_id: previousThreadReference,
      thread_id: activeThreadReference,
      recovered_at: new Date().toISOString(),
      message:
        "原 Agent Session 不可用，已创建新 Session；任务与共享证据仍已复用。",
    });
    store.appendEvent({
      type: "thread.resume_failed",
      previous_error: resumeError.message,
      error_class: resumeError.classification,
      error_code: resumeError.code,
      previous_thread_id: previousThreadReference,
      new_thread_id: activeThreadReference,
    });
  } else {
    setSessionRecovered(null);
    state.agent_error = null;
  }
  await updateThreadName(state.panel, "已恢复任务");
  if (!state.last_turn) {
    store.appendEvent({
      type: "session.started",
      thread_id: activeThreadReference,
      thread_name: state.thread_name,
    });
  }
  archiveCurrentTask();
  store.save();
  server.listen(port, host, () => {
    const info = {
      pid: process.pid,
      host,
      port,
      driver: agentDriverName,
      capabilities: agentDriver.capabilities,
      started_at: new Date().toISOString(),
    };
    writeFileSync(
      resolve(runtimeDir, "server-info.json"),
      `${JSON.stringify(info, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    process.stdout.write(
      `Agent Panel listening at http://${host}:${port}/ (${agentDriverName})\n`,
    );
  });
} catch (error) {
  const agentError = agentDriver.classifyError(error);
  process.stderr.write(
    `Failed to start Agent Panel [${agentError.classification}/${agentError.code}]: ${agentError.message}\n`,
  );
  await agentDriver.close().catch(() => {});
  process.exit(1);
}
