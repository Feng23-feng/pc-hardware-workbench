import { createServer } from "node:http";
import {
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import {
  createHash,
  randomBytes,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";
import {
  basename,
  dirname,
  extname,
  isAbsolute,
  relative,
  resolve,
} from "node:path";
import { Readable } from "node:stream";
import {
  AgentDriverError,
  createAgentDriver,
  driverPublicDescriptor,
  resolveAgentDriverName,
} from "./lib/agents/index.mjs";
import {
  DEFAULT_AGENT_PERMISSION_PROFILE,
  DEFAULT_SURFACE_MODE,
  RUNTIME_RUNNING_CURRENT_WORKSPACE,
  normalizeAgentPermissionProfile,
  normalizeSurfaceMode,
} from "./lib/agent-permissions.mjs";
import { buildPermissionMatrix } from "./lib/permission-matrix.mjs";
import { runPanelTurn } from "./lib/panel-response.mjs";
import { mergePersistentPanelState } from "./lib/panel-state-merge.mjs";
import { StateStore } from "./lib/state-store.mjs";
import {
  buildDraftEvent,
  validatePanelState,
} from "./lib/schema-validation.mjs";
import {
  SOURCE_HOSTED_SUBMITTABLE_PHASES,
  isSourceHostedStuckPhase,
  isSourceHostedSubmittablePhase,
} from "./lib/source-hosted-phase.mjs";
import {
  signHandoffToken,
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
import {
  createSourceHostedShadowObserver,
} from "./lib/source-hosted-shadow.mjs";
import {
  cleanupRuntimeBackups,
  cleanupInstallLogs,
  getStorageSnapshot,
} from "./lib/storage-maintenance.mjs";
import {
  beginTaskDataCleanup,
  createRuntimeBackupExport,
  createTaskDataExport,
  hasTaskDataCleanupReceipt,
  pruneStorageExports,
  recoverTaskDataCleanupQuarantines,
  resolveStorageExportDownload,
  verifyTaskDataExport,
} from "./lib/storage-exports.mjs";

const root = resolve(import.meta.dirname);
const host = "127.0.0.1";
const port = Number.parseInt(process.env.PANEL_PORT ?? "4319", 10);
const runtimeStartedAt = new Date().toISOString();
const runtimeLaunchId =
  String(process.env.PANEL_LAUNCH_ID ?? "").trim() ||
  `runtime-${process.pid}-${runtimeStartedAt}`;
const runtimeOrigin = `http://${host}:${port}`;
const runtimeDir = resolve(
  root,
  process.env.PANEL_RUNTIME_DIR ?? "runtime",
);
const storageLocalRoot = resolve(
  process.env.SKILLDOCK_LOCAL_ROOT || dirname(runtimeDir),
);

function writeTextFileAtomic(filePath, text, options = {}) {
  const temporaryPath =
    `${filePath}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporaryPath, text, options);
    renameSync(temporaryPath, filePath);
  }
  finally {
    if (existsSync(temporaryPath)) {
      unlinkSync(temporaryPath);
    }
  }
}

const agentWorkspace = resolve(process.env.PANEL_AGENT_WORKSPACE ?? root);
if (!existsSync(agentWorkspace) || !statSync(agentWorkspace).isDirectory()) {
  throw new Error(`PANEL_AGENT_WORKSPACE is not a directory: ${agentWorkspace}`);
}
const configuredSandbox = String(process.env.PANEL_AGENT_SANDBOX ?? "").trim();
const configuredApprovalPolicy = String(
  process.env.PANEL_AGENT_APPROVAL_POLICY ?? "",
).trim();
const agentPermissionProfile = normalizeAgentPermissionProfile({
  sandbox: configuredSandbox || DEFAULT_AGENT_PERMISSION_PROFILE.sandbox,
  approvalPolicy:
    configuredApprovalPolicy ||
    DEFAULT_AGENT_PERMISSION_PROFILE.approvalPolicy,
  source:
    configuredSandbox || configuredApprovalPolicy
      ? "environment"
      : DEFAULT_AGENT_PERMISSION_PROFILE.source,
});
const surfaceMode = normalizeSurfaceMode(
  process.env.PANEL_SURFACE_MODE ?? DEFAULT_SURFACE_MODE,
);
const sourceHostedEntryEnabled =
  String(process.env.PANEL_SOURCE_HOSTED_ENTRY ?? "").trim() === "1";
const sourceHostedNonMockEnabled =
  String(process.env.PANEL_SOURCE_HOSTED_NON_MOCK ?? "").trim() === "1";
let agentDriverName;
try {
  agentDriverName = resolveAgentDriverName();
} catch (error) {
  process.stderr.write(`Agent driver configuration error: ${error.message}\n`);
  process.exit(1);
}
if (
  agentDriverName === "source-external" &&
  (!sourceHostedEntryEnabled || !sourceHostedNonMockEnabled)
) {
  process.stderr.write(
    "source-external requires PANEL_SOURCE_HOSTED_ENTRY=1 and " +
      "PANEL_SOURCE_HOSTED_NON_MOCK=1; no server started.\n",
  );
  process.exit(1);
}
const sourceExternalDriver = agentDriverName === "source-external";
const resetRequested = process.argv.includes("--reset-state");
mkdirSync(runtimeDir, { recursive: true });
const startupCleanupRecovery = await recoverTaskDataCleanupQuarantines({
  localRoot: storageLocalRoot,
  runtimeDir,
  localAppData: process.env.LOCALAPPDATA,
});
if (startupCleanupRecovery.failures.length > 0) {
  process.stderr.write(
    `Task cleanup recovery left ${startupCleanupRecovery.pending} ` +
      `pending item(s): ${startupCleanupRecovery.failures.join(" | ")}\n`,
  );
}
try {
  await pruneStorageExports({
    localRoot: storageLocalRoot,
    runtimeDir,
    localAppData: process.env.LOCALAPPDATA,
  });
} catch (error) {
  process.stderr.write(
    `Expired storage export cleanup failed: ${error?.message ?? error}\n`,
  );
}
const attachmentRoot = resolve(runtimeDir, "attachments");
const taskArchiveDir = resolve(runtimeDir, "tasks");
const artifactRoot = resolve(runtimeDir, "artifacts");
mkdirSync(attachmentRoot, { recursive: true });
mkdirSync(taskArchiveDir, { recursive: true });
mkdirSync(artifactRoot, { recursive: true });

function publicRuntimeBinding() {
  return {
    launch_id: runtimeLaunchId,
    pid: process.pid,
    port,
    origin: runtimeOrigin,
    started_at: runtimeStartedAt,
  };
}

function panelCookie() {
  return `panel_token=${encodeURIComponent(panelCapabilityToken)}; HttpOnly; SameSite=Strict; Path=/; Max-Age=86400`;
}

function runtimeBindingCookie() {
  return `runtime_binding_hint=${encodeURIComponent(
    JSON.stringify(publicRuntimeBinding()),
  )}; SameSite=Strict; Path=/; Max-Age=86400`;
}

const browserHandoffProbes = new Map();
const sourceHostedOpenTickets = new Map();

function getRequestCookie(request, name) {
  for (const part of String(request.headers.cookie ?? "").split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const key = part.slice(0, separator).trim();
    if (key !== name) continue;
    try {
      return decodeURIComponent(part.slice(separator + 1).trim());
    } catch {
      return "";
    }
  }
  return "";
}

function browserHandoffProbeCookie(probeId) {
  return `skilldock_handoff_probe=${encodeURIComponent(
    probeId,
  )}; HttpOnly; SameSite=Strict; Path=/; Max-Age=120`;
}

function pruneBrowserHandoffProbes() {
  const now = Date.now();
  for (const [probeId, probe] of browserHandoffProbes) {
    if (probe.expires_at_ms <= now) {
      browserHandoffProbes.delete(probeId);
    }
  }
}

function pruneSourceHostedOpenTickets() {
  const now = Date.now();
  for (const [openId, ticket] of sourceHostedOpenTickets) {
    if (ticket.expires_at_ms <= now) {
      sourceHostedOpenTickets.delete(openId);
    }
  }
}

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
const panelCapabilityToken =
  loadOrCreateSecret("panel-capability-token");
const sourceCapabilityToken =
  loadOrCreateSecret("source-capability-token");
const handoffSecret = loadOrCreateSecret("handoff-secret");
const store = new StateStore(runtimeDir);
const state = store.load();
const sourceHostedShadow = createSourceHostedShadowObserver({
  log(entry) {
    process.stderr.write(`${JSON.stringify(entry)}\n`);
  },
});
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
state.task.timeline = state.task.timeline.map((entry, index) => ({
  ...entry,
  seq: Number.isInteger(entry.seq) && entry.seq > 0 ? entry.seq : index + 1,
  source: String(entry.source ?? "surface"),
}));
state.task.sync ??= null;
state.task.shared_task ??= null;
await skillRuntime.expirePermissions(state.task, {
  appendEvent: (event) => store.appendEvent(event),
  save: () => store.save(),
});
store.save();

function createAgentDriverInstance() {
  return createAgentDriver(agentDriverName, {
    cwd: agentWorkspace,
    agentDataDir: runtimeDir,
    permissionProfile: agentPermissionProfile,
    protocolLogPath:
      process.env.PANEL_PROTOCOL_LOG === "1"
        ? resolve(runtimeDir, "agent-protocol.jsonl")
        : null,
  });
}

let agentDriver = createAgentDriverInstance();

let shuttingDown = false;
let submitInFlight = false;
let taskDataOperationInFlight = false;

function rejectTaskDataOperation(response) {
  if (!taskDataOperationInFlight) return false;
  writeJson(response, 409, {
    error: "Task data export or cleanup is in progress.",
    code: "task_data_operation_in_progress",
  });
  return true;
}

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
    "/runtime-binding.js",
    [
      "text/javascript; charset=utf-8",
      resolve(root, "public", "runtime-binding.js"),
    ],
  ],
  [
    "/source-hosted-phase.js",
    [
      "text/javascript; charset=utf-8",
      resolve(root, "public", "source-hosted-phase.js"),
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

function normalizeThreadReference(value) {
  return String(value ?? "").trim().toLowerCase();
}

function isThreadReference(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/u
    .test(normalizeThreadReference(value));
}

function requestCredentialRole(request) {
  const bearer = request.headers.authorization?.replace(/^Bearer\s+/i, "");
  const cookies = parseCookies(request.headers.cookie);
  if (bearer && safeEqual(bearer, sourceCapabilityToken)) return "source";
  if (bearer && safeEqual(bearer, panelCapabilityToken)) return "panel";
  if (bearer && safeEqual(bearer, token)) return "master";
  if (
    cookies.panel_token &&
    safeEqual(cookies.panel_token, panelCapabilityToken)
  ) {
    return "panel";
  }
  return null;
}

function isAuthorized(request) {
  return requestCredentialRole(request) !== null;
}

function hasValidHost(request) {
  const hostHeader = request.headers.host;
  return (
    hostHeader === `127.0.0.1:${port}` ||
    hostHeader === `localhost:${port}`
  );
}

async function readJson(request, { maxBytes = 32_768 } = {}) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > maxBytes) {
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

function validateSyncImport(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Chat context must be an object");
  }
  if (value.schema_version !== "1.0") {
    throw new Error("Chat context schema_version must be 1.0");
  }
  const channelId = String(value.channel_id ?? "").trim();
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{7,199}$/u.test(channelId)) {
    throw new Error("Chat context channel_id is invalid");
  }
  const objective = String(value.objective ?? "").trim().slice(0, 120);
  const summary = String(value.summary ?? "").trim().slice(0, 4000);
  const sourceSessionRef = String(value.source_session_ref ?? "")
    .trim()
    .slice(0, 256);
  if (!Array.isArray(value.messages) || value.messages.length > 40) {
    throw new Error("Chat context messages must contain at most 40 items");
  }
  const seen = new Set();
  const messages = value.messages.map((message, index) => {
    const externalId = String(message?.id ?? "").trim();
    if (
      !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/u.test(externalId) ||
      seen.has(externalId)
    ) {
      throw new Error(`Chat context message ${index} has an invalid id`);
    }
    seen.add(externalId);
    const role =
      message.role === "assistant" ? "agent" : String(message.role ?? "");
    if (!["user", "agent"].includes(role)) {
      throw new Error(`Chat context message ${index} has an invalid role`);
    }
    const text = String(message.text ?? "").trim();
    if (!text || text.length > 8000) {
      throw new Error(`Chat context message ${index} has invalid text`);
    }
    const createdAt =
      typeof message.created_at === "string" &&
      Number.isFinite(Date.parse(message.created_at))
        ? new Date(message.created_at).toISOString()
        : new Date().toISOString();
    return { externalId, role, text, createdAt };
  });
  return {
    channelId,
    objective,
    summary,
    sourceSessionRef,
    messages,
    panel: value.panel ?? null,
  };
}

function publicAttachment(attachment) {
  return {
    id: attachment.id,
    source_attachment_id: attachment.source_attachment_id ?? null,
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
  let publicSharedTask = task.shared_task;
  if (task.shared_task && typeof task.shared_task === "object") {
    const {
      source_tool_result: _sourceToolResult,
      ...sharedTaskWithoutPrivateResult
    } = task.shared_task;
    publicSharedTask = sharedTaskWithoutPrivateResult;
  }
  return {
    ...task,
    shared_task: publicSharedTask,
    attachments: (task.attachments ?? []).map(publicAttachment),
    timeline: (task.timeline ?? []).map((entry) => {
      const {
        source_payload: _sourcePayload,
        ...publicEntry
      } = entry;
      return {
        ...publicEntry,
        attachments: (entry.attachments ?? []).map(publicAttachment),
      };
    }),
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
    agent_permissions: agentDriver.permissionProfile,
    surface: publicSurfaceState(),
    permission_matrix: publicPermissionMatrix(),
    runtime_binding: publicRuntimeBinding(),
    updated_at: state.updated_at,
    event_count: state.event_count,
    agent: {
      ...driverPublicDescriptor(agentDriver),
      workspace: sourceHostedTaskActive() ? null : agentWorkspace,
    },
    skill: {
      ...publicManifestDescriptor(workbenchManifest),
      ...state.active_skill,
      discovery: state.skill_discovery,
    },
    agent_error: state.agent_error ?? null,
  };
}

function taskDataExportMetadata() {
  return {
    task_id: String(state.task?.task_id ?? ""),
    session_ref: String(state.session_ref ?? state.thread_id ?? ""),
    event_count: Number(state.event_count ?? 0),
    state_sha256: createHash("sha256")
      .update(JSON.stringify(state))
      .digest("hex"),
  };
}

function publicSurfaceState() {
  return {
    mode: surfaceMode,
    runtime_state: RUNTIME_RUNNING_CURRENT_WORKSPACE,
    loopback: true,
    host,
    port,
    launch_id: runtimeLaunchId,
    pid: process.pid,
    origin: runtimeOrigin,
  };
}

function publicPermissionMatrix() {
  return buildPermissionMatrix({
    agentPermission: agentDriver.permissionProfile,
    surface: publicSurfaceState(),
    task: state.task,
    manifest: workbenchManifest,
  });
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

function sanitizeSourceHostedPayload(value) {
  if (Array.isArray(value)) {
    return value.map(sanitizeSourceHostedPayload);
  }
  if (!value || typeof value !== "object") {
    return value;
  }
  const deniedKeys = new Set([
    "absolute_path",
    "authorization",
    "capability",
    "cookie",
    "local_path",
    "panel_token",
    "runtime_dir",
    "source_token",
    "token",
    "workspace",
  ]);
  return Object.fromEntries(
    Object.entries(value)
      .filter(([key]) => !deniedKeys.has(key))
      .map(([key, item]) => [key, sanitizeSourceHostedPayload(item)]),
  );
}

function sourceHostedTaskContext() {
  return sanitizeSourceHostedPayload(taskContext());
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
    buildSourceHostedTaskContext: () => sourceHostedTaskContext(),
    isSourceHosted: () => sourceHostedTaskActive(),
    setSourceHostedToolResult: ({ packet, result }) => {
      const receivedAt = new Date().toISOString();
      state.task.shared_task.source_tool_result = {
        schema_version: "1.0",
        packet: sanitizeSourceHostedPayload(packet),
        result: sanitizeSourceHostedPayload(result),
        received_at: receivedAt,
      };
      markSourceHostedPhase("waiting_for_source_pull", {
        last_tool_result_at: receivedAt,
      });
      state.phase = "ready";
      state.task.phase = "ready";
      state.activity = {
        status: "waiting_for_source",
        user_summary: result?.attachment?.original_name ?? "本地遥测分析",
        started_at: receivedAt,
        completed_at: null,
        agent_summary: "",
        next_action: "等待来源 Agent 返回结论。",
        error: null,
        turn_id: null,
      };
      store.appendEvent({
        type: "source_hosted.local_tool_result",
        task_id: state.task.task_id,
        channel_id: state.task.shared_task.channel_id,
        artifact_id: result?.artifact?.id ?? null,
        analyzed_rows: result?.analysis?.analyzed_rows ?? null,
        panel_turn_created: false,
      });
      store.save();
    },
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
    draft: state.draft,
    activity: state.activity,
    last_turn: state.last_turn,
  };
  writeFileSync(
    resolve(taskArchiveDir, `${state.task.task_id}.json`),
    `${JSON.stringify(snapshot, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

function archiveSourceHostedCycle(reason) {
  if (!sourceHostedTaskActive()) {
    throw Object.assign(new Error("source-hosted Task is unavailable"), {
      code: "recovery_unavailable",
      statusCode: 409,
    });
  }
  const cycleId = `cycle-${Date.now()}-${randomUUID()}`;
  const fileName = `${state.task.task_id}-${cycleId}.json`;
  const cycleArchiveDir = resolve(taskArchiveDir, "cycles");
  mkdirSync(cycleArchiveDir, { recursive: true });
  const filePath = resolve(cycleArchiveDir, fileName);
  const snapshot = {
    schema_version: "1.0",
    archive_kind: "source_hosted_cycle_recovery",
    archive_id: cycleId,
    archived_at: new Date().toISOString(),
    reason,
    thread_id: state.thread_id,
    thread_name: state.thread_name,
    active_skill: structuredClone(state.active_skill),
    phase: state.phase,
    task: structuredClone(state.task),
    panel: structuredClone(state.panel),
    draft: structuredClone(state.draft),
    activity: structuredClone(state.activity),
    last_turn: structuredClone(state.last_turn),
    error: state.error,
  };
  writeFileSync(
    filePath,
    `${JSON.stringify(snapshot, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  return {
    archive_id: cycleId,
    archive_ref: relative(taskArchiveDir, filePath).replaceAll("\\", "/"),
    draft_attachment_count: state.draft.attachments.length,
    attachment_count: state.task.attachments.length,
    artifact_count: state.task.artifacts?.length ?? 0,
    timeline_count: state.task.timeline.length,
  };
}

function restoreStateSnapshot(snapshot) {
  store.replaceStateInPlace(snapshot);
}

function sourceHostedTaskActive() {
  return state.task?.shared_task?.mode === "source_hosted";
}

function rejectNonSubmittableSourceHostedPhase(response) {
  if (!sourceHostedTaskActive()) return false;
  const phase = state.task.shared_task.phase;
  if (isSourceHostedSubmittablePhase(phase)) return false;
  writeJson(response, 409, {
    error:
      "source_hosted panel operation is not valid in the current phase",
    code: "phase_not_submittable",
    phase,
    recovery_available: isSourceHostedStuckPhase(phase),
  });
  return true;
}

function normalizeThreadBindingRef(value) {
  return normalizeThreadReference(value);
}

function normalizeSourceAttachmentId(value) {
  const normalized = String(value ?? "").trim();
  if (!normalized) return null;
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{7,199}$/u.test(normalized)) {
    throw Object.assign(
      new Error("source attachment id is invalid"),
      {
        code: "attachment_source_identity_invalid",
        statusCode: 400,
      },
    );
  }
  return normalized;
}

function findReusableAttachment(sourceAttachmentId, sha256) {
  const candidates = [
    ...(state.task?.attachments ?? []),
    ...state.draft.attachments,
  ];
  if (sourceAttachmentId) {
    const sameSource = candidates.find(
      (attachment) =>
        attachment.source_attachment_id === sourceAttachmentId,
    );
    if (sameSource && sameSource.sha256 !== sha256) {
      throw Object.assign(
        new Error("source attachment id is bound to different content"),
        {
          code: "attachment_source_identity_conflict",
          statusCode: 409,
        },
      );
    }
    if (sameSource) return sameSource;
  }
  return candidates.find(
    (attachment) =>
      attachment.sha256 === sha256 &&
      (
        !attachment.source_attachment_id ||
        attachment.source_attachment_id === sourceAttachmentId
      ),
  ) ?? null;
}

function deduplicateTaskAttachmentsByContent() {
  if (!state.task) return [];
  const seen = new Map();
  const kept = [];
  const removed = [];
  for (const attachment of state.task.attachments ?? []) {
    const key = String(attachment.sha256 ?? "").toLowerCase();
    if (!key || !seen.has(key)) {
      if (key) seen.set(key, attachment.id);
      kept.push(attachment);
      continue;
    }
    removed.push(attachment);
  }
  if (removed.length === 0) return removed;
  const removedIds = new Set(removed.map((attachment) => attachment.id));
  state.task.attachments = kept;
  state.task.domain_refs = (state.task.domain_refs ?? []).filter(
    (reference) => !removedIds.has(reference),
  );
  state.task.evidence_refs = (state.task.evidence_refs ?? []).filter(
    (reference) => !removedIds.has(reference),
  );
  if (state.task.domain_state?.evidence_refs) {
    state.task.domain_state.evidence_refs =
      state.task.domain_state.evidence_refs.filter(
        (reference) => !removedIds.has(reference),
      );
  }
  // Keep the superseded files so the archived Task remains a complete,
  // verifiable snapshot. Only the active Task projection is deduplicated.
  return removed;
}

function markSourceHostedPhase(phase, extra = {}) {
  if (!sourceHostedTaskActive()) return false;
  state.task.shared_task = {
    ...state.task.shared_task,
    phase,
    updated_at: new Date().toISOString(),
    ...extra,
  };
  return true;
}

function sourceHostedClaimFailure(
  status,
  code,
  message,
  extra = {},
) {
  return {
    ok: false,
    status,
    code,
    message,
    ...extra,
  };
}

function sourceHostedClaimIdentity(claim) {
  return {
    intent_event_id: claim.intentEventId,
    submission_sequence: claim.submissionSequence,
    attachment_id: claim.attachmentId || null,
    attachment_sha256: claim.attachmentSha256 || null,
    require_source_result: claim.requireSourceResult,
  };
}

function sourceHostedClaimsMatch(left, right) {
  if (!left || !right) return false;
  return (
    left.intent_event_id === right.intent_event_id &&
    left.submission_sequence === right.submission_sequence &&
    (left.attachment_id ?? null) === (right.attachment_id ?? null) &&
    (left.attachment_sha256 ?? null) ===
      (right.attachment_sha256 ?? null) &&
    Boolean(left.require_source_result) ===
      Boolean(right.require_source_result)
  );
}

function inspectSourceHostedClaim(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return sourceHostedClaimFailure(
      400,
      "claim_contract_invalid",
      "source-hosted claim must be an object",
    );
  }
  if (value.schema_version !== "1.0") {
    return sourceHostedClaimFailure(
      400,
      "claim_contract_invalid",
      "source-hosted claim schema_version must be 1.0",
    );
  }
  const taskRef = String(value.task_ref ?? "").trim();
  const channelId = String(value.channel_id ?? "").trim();
  const sourceSessionRef = normalizeThreadReference(
    value.source_session_ref,
  );
  const intentEventId = String(value.intent_event_id ?? "").trim();
  const submissionSequence = Number(value.submission_sequence);
  const attachmentId = String(value.attachment_id ?? "").trim();
  const attachmentSha256 = String(value.attachment_sha256 ?? "")
    .trim()
    .toLowerCase();
  const requireSourceResult = value.require_source_result === true;
  if (
    !taskRef ||
    !channelId ||
    !intentEventId ||
    !Number.isInteger(submissionSequence) ||
    submissionSequence <= 0
  ) {
    return sourceHostedClaimFailure(
      400,
      "claim_anchor_missing",
      "task_ref, channel_id, intent_event_id, and submission_sequence are required",
    );
  }
  if (
    (attachmentId && !/^[A-Za-z0-9][A-Za-z0-9._:-]{7,199}$/u.test(attachmentId)) ||
    (attachmentSha256 && !/^[0-9a-f]{64}$/u.test(attachmentSha256))
  ) {
    return sourceHostedClaimFailure(
      400,
      "claim_anchor_invalid",
      "attachment identity is invalid",
    );
  }
  if (requireSourceResult && (!attachmentId || !attachmentSha256)) {
    return sourceHostedClaimFailure(
      400,
      "claim_anchor_missing",
      "source result claims require attachment_id and attachment_sha256",
    );
  }
  const sharedTask = state.task?.shared_task;
  if (!sharedTask || sharedTask.mode !== "source_hosted") {
    return sourceHostedClaimFailure(
      409,
      "claim_unavailable",
      "the active Task is not source host owned",
    );
  }
  if (taskRef !== state.task.task_id) {
    return sourceHostedClaimFailure(
      409,
      "claim_task_mismatch",
      "source-hosted Task binding mismatch",
      {
        expected_task_ref: taskRef,
        actual_task_ref: state.task.task_id,
      },
    );
  }
  if (channelId !== sharedTask.channel_id) {
    return sourceHostedClaimFailure(
      409,
      "claim_channel_mismatch",
      "source-hosted channel binding mismatch",
    );
  }
  if (
    !sourceSessionRef ||
    sourceSessionRef !== sharedTask.source_session_ref
  ) {
    return sourceHostedClaimFailure(
      409,
      "claim_source_session_mismatch",
      "source-hosted source Session binding mismatch",
    );
  }
  const timeline = state.task.timeline ?? [];
  const intentEntry = timeline.find(
    (entry) =>
      entry.seq === submissionSequence &&
      entry.source === "source_hosted_intent" &&
      entry.external_id === intentEventId,
  );
  if (!intentEntry) {
    return sourceHostedClaimFailure(
      409,
      "claim_anchor_mismatch",
      "source intent does not match the current submission",
    );
  }
  if (attachmentId) {
    const submissionAttachment = (intentEntry.attachments ?? []).find(
      (attachment) => attachment.id === attachmentId,
    );
    if (
      !submissionAttachment ||
      String(submissionAttachment.sha256 ?? "").toLowerCase() !==
        attachmentSha256
    ) {
      return sourceHostedClaimFailure(
        409,
        "claim_anchor_mismatch",
        "attachment does not match the current source intent",
      );
    }
  }
  if (requireSourceResult) {
    const sourceToolResult = sharedTask.source_tool_result;
    const packet = sourceToolResult?.packet;
    const toolResult = packet?.tool_result;
    const returnedAttachmentId = String(
      toolResult?.attachment?.id ?? "",
    ).trim();
    const returnedSha256 = String(
      toolResult?.attachment?.sha256 ?? "",
    )
      .trim()
      .toLowerCase();
    const sourceEvidenceIds = Array.isArray(
      toolResult?.artifact?.source_evidence_ids,
    )
      ? toolResult.artifact.source_evidence_ids
      : [];
    const packetCreatedAt = Date.parse(String(packet?.created_at ?? ""));
    const submissionCreatedAt = Date.parse(
      String(intentEntry.created_at ?? ""),
    );
    if (
      packet?.task_id !== state.task.task_id ||
      returnedAttachmentId !== attachmentId ||
      returnedSha256 !== attachmentSha256 ||
      !sourceEvidenceIds.includes(attachmentId)
    ) {
      return sourceHostedClaimFailure(
        409,
        "claim_result_stale",
        "the pending source result belongs to another attachment",
        {
          returned_attachment_id: returnedAttachmentId || null,
          returned_sha256: returnedSha256 || null,
        },
      );
    }
    if (
      !Number.isFinite(packetCreatedAt) ||
      !Number.isFinite(submissionCreatedAt) ||
      packetCreatedAt < submissionCreatedAt
    ) {
      return sourceHostedClaimFailure(
        409,
        "claim_result_stale",
        "the pending source result predates the current submission",
      );
    }
  }
  return {
    ok: true,
    claim: {
      taskRef,
      channelId,
      sourceSessionRef,
      intentEventId,
      submissionSequence,
      attachmentId: attachmentId || null,
      attachmentSha256: attachmentSha256 || null,
      requireSourceResult,
    },
  };
}

function appendTimelineEntry({
  role,
  text,
  attachments = [],
  createdAt = new Date().toISOString(),
  source = "surface",
  externalId = null,
  sourcePayload = null,
}) {
  const nextSequence =
    state.task.timeline.reduce(
      (maximum, entry) =>
        Number.isInteger(entry.seq) ? Math.max(maximum, entry.seq) : maximum,
      0,
    ) + 1;
  const entry = {
    seq: nextSequence,
    id: `timeline-${crypto.randomUUID()}`,
    role,
    text: String(text),
    created_at: createdAt,
    source,
    external_id: externalId,
    attachments: attachments.map(publicAttachment),
    ...(sourcePayload ? { source_payload: sourcePayload } : {}),
  };
  state.task.timeline.push(entry);
  return entry;
}

function pushTimeline(role, text, attachments = []) {
  return appendTimelineEntry({
    role,
    text,
    attachments,
    source: "surface",
  });
}

function queueSourceHostedInteraction(event) {
  if (!sourceHostedTaskActive()) return null;
  let text;
  if (event.type === "option_selected") {
    const option = state.panel?.question?.options?.find(
      (item) => item.id === event.option_id,
    );
    text = [
      state.panel?.question?.prompt
        ? `用户回答：${state.panel.question.prompt}`
        : "用户选择了一个面板选项。",
      `选择：${option?.label ?? event.option_id}`,
    ].join("\n");
  } else if (event.type === "evidence_added") {
    text = [
      `用户补充证据：${event.label}`,
      event.detail || null,
    ].filter(Boolean).join("\n");
  } else {
    return null;
  }
  const entry = appendTimelineEntry({
    role: "user",
    text,
    source: "source_hosted_intent",
    externalId: `source-intent-${event.event_id}`,
  });
  markSourceHostedPhase("waiting_for_source_pull", {
    last_intent_at: entry.created_at,
    last_intent_id: event.event_id,
  });
  state.task.phase = "ready";
  state.phase = "ready";
  return entry;
}

function queueSourceHostedSubmission({ freeText, attachments }) {
  const text = [
    freeText || "用户提交了受控硬件分析请求。",
    attachments.length
      ? `附件：${attachments.map((item) => item.original_name).join("、")}`
      : "",
  ].filter(Boolean).join("\n");
  const entry = appendTimelineEntry({
    role: "user",
    text,
    attachments,
    source: "source_hosted_intent",
    externalId: `source-submission-${crypto.randomUUID()}`,
    sourcePayload: {
      type: "source_hosted_panel_submission",
      free_text: freeText,
      attachments: attachments.map(publicAttachmentForAgent)
        .map(({ local_path: _localPath, ...attachment }) => attachment),
    },
  });
  markSourceHostedPhase("waiting_for_source_pull", {
    last_intent_at: entry.created_at,
    last_intent_id: entry.external_id,
  });
  state.task.phase = "ready";
  state.phase = "ready";
  return entry;
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
    source_attachment_id: attachment.source_attachment_id ?? null,
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
  const result = await runPanelTurn({
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
  const mergedPanel = mergePersistentPanelState(state.panel, result.panel);
  if (mergedPanel !== result.panel) {
    return {
      ...result,
      panel: await skillRuntime.validatePanelResult(mergedPanel, {
        task: state.task,
        packet: enrichedPacket,
      }),
    };
  }
  return result;
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

async function submitSourceHosted(request, response) {
  const phase = state.task.shared_task.phase;
  if (!isSourceHostedSubmittablePhase(phase)) {
    writeJson(response, 409, {
      error: "source_hosted panel submission is not valid in the current phase",
      code: "phase_not_submittable",
      phase,
      recovery_available: isSourceHostedStuckPhase(phase),
    });
    return;
  }
  const body = await readJson(request);
  const freeText = String(body.free_text ?? "").trim().slice(0, 2000);
  if (!freeText && state.draft.attachments.length === 0) {
    throw new Error("请输入电脑遇到的问题或上传 CSV");
  }
  const attachments = commitDraftAttachments();
  const entry = queueSourceHostedSubmission({
    freeText,
    attachments: state.task.attachments.filter((attachment) =>
      attachments.some((item) => item.id === attachment.id)
    ),
  });
  state.draft = { events: [], attachments: [] };
  state.last_turn = null;
  state.error = null;
  store.appendEvent({
    type: "source_hosted.panel_submission",
    task_id: state.task.task_id,
    channel_id: state.task.shared_task.channel_id,
    intent_message_id: entry.id,
    intent_external_id: entry.external_id,
    attachment_count: attachments.length,
    panel_turn_created: false,
  });
  store.save();
  writeJson(response, 200, publicState());
}

async function submit(request, response) {
  if (rejectTaskDataOperation(response)) return;
  if (sourceHostedTaskActive()) {
    if (sourceHostedNonMockEnabled) {
      await submitSourceHosted(request, response);
    } else {
      writeJson(response, 409, {
        error: "source_hosted Task 不允许面板创建模型 Turn",
        code: "panel_turn_forbidden_in_source_hosted",
        execution_owner: "source",
      });
    }
    return;
  }
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
  if (taskDataOperationInFlight) {
    throw new Error("Task data export or cleanup is in progress.");
  }
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

async function recoverSourceHostedTask(request, response) {
  if (!sourceHostedTaskActive()) {
    writeJson(response, 409, {
      error: "source_hosted recovery is not available for this Task",
      code: "recovery_unavailable",
    });
    return;
  }
  const errorRecovery =
    state.phase === "error" || state.task.phase === "error";
  const stuckCycleRecovery = isSourceHostedStuckPhase(
    state.task.shared_task.phase,
  );
  if (!errorRecovery && !stuckCycleRecovery) {
    writeJson(response, 409, {
      error: "source_hosted Task is not in a recoverable error state",
      code: "recovery_not_required",
    });
    return;
  }
  const body = await readJson(request, { maxBytes: 8_192 });
  if (body.confirm !== "recover_current_task") {
    writeJson(response, 403, {
      error: "explicit current-Task recovery confirmation is required",
      code: "confirmation_required",
    });
    return;
  }

  const before = structuredClone(state);
  try {
    if (stuckCycleRecovery) {
      const previousPhase = state.task.shared_task.phase;
      const previousIntentId = state.task.shared_task.last_intent_id ?? null;
      const previousSourceToolResultAt =
        state.task.shared_task.source_tool_result?.received_at ?? null;
      const cycleArchive = archiveSourceHostedCycle(
        "stuck_source_agent_pulled",
      );
      const recoveredAt = new Date().toISOString();
      state.draft = { events: [], attachments: [] };
      state.panel = null;
      state.last_turn = null;
      state.activity = null;
      state.error = null;
      state.agent_error = null;
      state.task.permission_request = null;
      state.task.phase = "ready";
      state.phase = "ready";
      markSourceHostedPhase("source_owned", {
        cycle_generation:
          Number(state.task.shared_task.cycle_generation ?? 0) + 1,
        last_intent_at: null,
        last_intent_id: null,
        cycle_recovery: {
          recovered_at: recoveredAt,
          previous_phase: previousPhase,
          previous_intent_id: previousIntentId,
          previous_source_tool_result_at:
            previousSourceToolResultAt,
          archive_id: cycleArchive.archive_id,
          archive_ref: cycleArchive.archive_ref,
        },
      });
      store.appendEvent({
        type: "source_hosted.stuck_cycle_recovered",
        task_id: state.task.task_id,
        channel_id: state.task.shared_task.channel_id,
        previous_phase: previousPhase,
        previous_intent_id: previousIntentId,
        archive_ref: cycleArchive.archive_ref,
        draft_attachment_count: cycleArchive.draft_attachment_count,
        attachment_count: cycleArchive.attachment_count,
        artifact_count: cycleArchive.artifact_count,
        timeline_count: cycleArchive.timeline_count,
        panel_turn_created: false,
        thread_created: false,
      });
      store.save();
      writeJson(response, 200, {
        ...publicState(),
        recovered: true,
        recovery_kind: "stuck_cycle",
        cycle_archive_ref: cycleArchive.archive_ref,
        archived_draft_attachment_count:
          cycleArchive.draft_attachment_count,
        deduplicated_attachment_count: 0,
      });
      return;
    }

    const cycleArchive = archiveSourceHostedCycle(
      "source_hosted_error_recovery",
    );
    archiveCurrentTask();
    const deduplicated = deduplicateTaskAttachmentsByContent();
    state.draft = { events: [], attachments: [] };
    state.panel = null;
    state.last_turn = null;
    state.activity = null;
    state.error = null;
    state.agent_error = null;
    state.task.permission_request = null;
    state.task.phase = "ready";
    state.phase = "ready";

    const sourceToolResult = state.task.shared_task.source_tool_result;
    if (sourceToolResult) {
      const waitingAt = new Date().toISOString();
      markSourceHostedPhase("waiting_for_source_pull", {
        last_tool_result_at:
          sourceToolResult.received_at ?? waitingAt,
      });
      state.activity = {
        status: "waiting_for_source",
        user_summary:
          sourceToolResult.result?.attachment?.original_name ??
          "本地遥测分析",
        started_at:
          sourceToolResult.received_at ?? waitingAt,
        completed_at: null,
        agent_summary: "",
        next_action: "回到当前 Agent 对话发送“同步面板”继续。",
        error: null,
        turn_id: null,
      };
    } else {
      markSourceHostedPhase("source_owned");
    }

    store.appendEvent({
      type: "source_hosted.task_recovered",
      task_id: state.task.task_id,
      channel_id: state.task.shared_task.channel_id,
      deduplicated_attachment_count: deduplicated.length,
      archive_ref: cycleArchive.archive_ref,
      phase: state.task.shared_task.phase,
      panel_turn_created: false,
      thread_created: false,
    });
    store.save();
    writeJson(response, 200, {
      ...publicState(),
      recovered: true,
      recovery_kind: "error",
      cycle_archive_ref: cycleArchive.archive_ref,
      deduplicated_attachment_count: deduplicated.length,
    });
  } catch (error) {
    restoreStateSnapshot(before);
    writeJson(response, error.statusCode ?? 500, {
      error: error.message || "source_hosted recovery failed",
      code: error.code || "recovery_failed",
    });
  }
}

async function uploadAttachment(request, response) {
  if (rejectTaskDataOperation(response)) return;
  if (rejectNonSubmittableSourceHostedPhase(response)) return;
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
  const sha256 = createHash("sha256").update(buffer).digest("hex");
  let sourceAttachmentId;
  try {
    sourceAttachmentId = normalizeSourceAttachmentId(
      request.headers["x-source-attachment-id"],
    );
  } catch (error) {
    writeJson(response, error.statusCode ?? 400, {
      error: error.message,
      code: error.code ?? "attachment_source_identity_invalid",
    });
    return;
  }
  if (!sourceAttachmentId) {
    sourceAttachmentId = `upload-file:${sha256}`;
  }
  let reusedAttachment;
  try {
    reusedAttachment = findReusableAttachment(
      sourceAttachmentId,
      sha256,
    );
  } catch (error) {
    writeJson(response, error.statusCode ?? 409, {
      error: error.message,
      code: error.code ?? "attachment_source_identity_conflict",
    });
    return;
  }
  if (reusedAttachment) {
    state.error = null;
    store.appendEvent({
      type: "attachment_reused",
      event_id: crypto.randomUUID(),
      created_at: new Date().toISOString(),
      attachment_id: reusedAttachment.id,
      source_attachment_id:
        reusedAttachment.source_attachment_id ?? sourceAttachmentId,
      sha256,
    });
    store.save();
    writeJson(response, 200, {
      ...publicState(),
      attachment_reuse: {
        id: reusedAttachment.id,
        source_attachment_id:
          reusedAttachment.source_attachment_id ?? sourceAttachmentId,
        sha256,
      },
    });
    return;
  }
  const id = `attachment-${randomUUID()}`;
  const storedName = `${id}-${originalName}`;
  const localPath = resolve(attachmentRoot, storedName);
  if (!isInsideAttachmentRoot(localPath)) {
    throw new Error("unsafe attachment path");
  }
  writeFileSync(localPath, buffer, { mode: 0o600 });
  const attachment = {
    id,
    source_attachment_id: sourceAttachmentId,
    original_name: originalName,
    mime_type: mimeType,
    size: buffer.length,
    sha256,
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
  if (rejectTaskDataOperation(response)) return;
  if (!state.task) {
    writeJson(response, 409, { error: "当前没有可授权的任务" });
    return;
  }
  if (rejectNonSubmittableSourceHostedPhase(response)) return;
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
  if (rejectTaskDataOperation(response)) return;
  if (!state.task) {
    writeJson(response, 409, { error: "当前没有可撤销权限的任务" });
    return;
  }
  if (rejectNonSubmittableSourceHostedPhase(response)) return;
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
  if (rejectTaskDataOperation(response)) return;
  if (submitInFlight) {
    writeJson(response, 409, { error: "agent 正在进行上一回合" });
    return;
  }
  if (!state.task) {
    writeJson(response, 409, { error: "请先创建 Task" });
    return;
  }
  if (rejectNonSubmittableSourceHostedPhase(response)) return;
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

function receiveHandoff(
  request,
  response,
  url,
  { sourceHostedEntry = false } = {},
) {
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
  const packet = verified.packet;
  const packetThreadId = normalizeThreadBindingRef(packet.thread_id);
  const packetEnvironmentThreadId = normalizeThreadBindingRef(
    packet.environment_thread_id,
  );
  if (
    sourceHostedEntry &&
    !packetEnvironmentThreadId
  ) {
    writeJson(response, 409, {
      error:
        "source_hosted entry requires the current environment Thread id",
      code: "thread_binding_missing",
    });
    return;
  }
  if (
    sourceHostedEntry &&
    packetEnvironmentThreadId &&
    packetEnvironmentThreadId !== packetThreadId
  ) {
    writeJson(response, 409, {
      error:
        "source_session_ref must equal the current environment Thread id",
      code: "thread_binding_mismatch",
      source_session_ref: packetThreadId,
      environment_thread_id: packetEnvironmentThreadId,
    });
    return;
  }
  if (
    sourceHostedEntry &&
    state.task?.shared_task?.environment_thread_id &&
    state.task.shared_task.environment_thread_id !==
      packetEnvironmentThreadId
  ) {
    writeJson(response, 409, {
      error:
        "source_hosted Task is already bound to another environment Thread",
      code: "thread_rebinding_forbidden",
    });
    return;
  }
  if (
    sourceHostedEntry &&
    state.task?.shared_task?.mode === "source_hosted" &&
    state.task.task_id !== packet.task_id
  ) {
    writeJson(response, 409, {
      error: "source_hosted entry is limited to one current Task",
      code: "single_task_scope",
    });
    return;
  }
  const sourceHostedChannelId = sourceHostedEntry
    ? `chat:source-hosted:${packetThreadId}`
    : null;
  if (
    sourceHostedEntry &&
    state.task?.shared_task?.mode === "source_hosted" &&
    state.task.sync?.source_session_ref &&
    state.task.sync.source_session_ref !== packetThreadId
  ) {
    writeJson(response, 409, {
      error: "source_hosted Task is already bound to another source Session",
      code: "source_session_scope",
    });
    return;
  }
  state.handoff_consumed_nonces.push(verified.nonce);
  state.handoff_consumed_nonces =
    state.handoff_consumed_nonces.slice(-200);
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
  const preserveSourceHostedError =
    sourceHostedEntry &&
    state.task?.shared_task?.mode === "source_hosted" &&
    (
      state.phase === "error" ||
      state.task.phase === "error"
    );
  if (sourceHostedEntry) {
    const previousSharedTask = state.task.shared_task;
    const reopensSameTask = (
      previousSharedTask?.mode === "source_hosted" &&
      previousSharedTask.channel_id === sourceHostedChannelId &&
      previousSharedTask.source_session_ref === packetThreadId &&
      (
        !previousSharedTask.environment_thread_id ||
        previousSharedTask.environment_thread_id ===
          packetEnvironmentThreadId
      )
    );
    const boundAt =
      reopensSameTask
        ? previousSharedTask.bound_at
        : new Date().toISOString();
    state.task.sync = {
      schema_version: "1.0",
      channel_id: sourceHostedChannelId,
      source_session_ref: packetThreadId,
      created_at:
        state.task.sync?.channel_id === sourceHostedChannelId
          ? state.task.sync.created_at
          : new Date().toISOString(),
    };
    state.task.shared_task = {
      ...(reopensSameTask ? previousSharedTask : {}),
      schema_version: "1.0",
      mode: "source_hosted",
      execution_owner: "source",
      channel_id: sourceHostedChannelId,
      source_session_ref: packetThreadId,
      environment_thread_id:
        packetEnvironmentThreadId ||
        previousSharedTask?.environment_thread_id ||
        null,
      phase: reopensSameTask ? previousSharedTask.phase : "source_owned",
      bound_at: boundAt,
      updated_at: new Date().toISOString(),
    };
    state.task.phase =
      preserveSourceHostedError ? "error" : "ready";
  }
  state.handoff = {
    schema_version: "1.0",
    status: sourceHostedEntry
      ? "source_hosted_entry"
      : "task_resume_packet",
    support_level: sourceHostedEntry
      ? "source-hosted-shared-task-entry"
      : "task-resume-packet",
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
    panel_view_mode: sourceHostedEntry
      ? "source_hosted_shared_task"
      : "independent",
    source_thread_role: "return-target",
    context_applied: true,
    local_surface_handoff: true,
    native_owner_changed: false,
    thread_id: packetThreadId,
    environment_thread_id: packetEnvironmentThreadId || null,
    thread_id_mismatch:
      Boolean(packetEnvironmentThreadId) &&
      packetEnvironmentThreadId !== packetThreadId,
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
  if (!preserveSourceHostedError) {
    state.error = null;
  }
  store.appendEvent({
    type: "handoff.received",
    thread_id: packetThreadId,
    environment_thread_id: packetEnvironmentThreadId || null,
    thread_id_mismatch: state.handoff.thread_id_mismatch,
    task_id: packet.task_id,
    active_skill_id: state.active_skill?.skill_id ?? null,
    domain_ref_count: state.task?.domain_refs?.length ?? 0,
    support_level: "task-resume-packet",
    native_thread_attached: false,
  });
  store.appendEvent({
    type: "handoff.native_attachment_blocked",
    thread_id: packetThreadId,
    reason: state.handoff.native_attachment_error,
    queue_message_sent: false,
  });
  store.appendEvent({
    type: "handoff.local_surface_handoff",
    thread_id: packetThreadId,
    task_id: packet.task_id,
    panel_thread_id: state.thread_id,
    panel_view_mode: sourceHostedEntry
      ? "source_hosted_shared_task"
      : "independent",
    native_owner_changed: false,
  });
  if (sourceHostedEntry) {
    store.appendEvent({
      type: "source_hosted.entry_opened",
      task_id: packet.task_id,
      channel_id: sourceHostedChannelId,
      source_session_ref: packetThreadId,
      panel_view_mode: "source_hosted_shared_task",
      panel_turn_created: false,
    });
  }
  store.save();
  const redirectUrl = new URL("/", `http://${request.headers.host}`);
  for (const name of [
    "runtime_launch_id",
    "runtime_pid",
    "runtime_port",
  ]) {
    if (url.searchParams.has(name)) {
      redirectUrl.searchParams.set(name, url.searchParams.get(name));
    }
  }
  response.writeHead(303, {
    Location: `${redirectUrl.pathname}${redirectUrl.search}`,
    "Cache-Control": "no-store",
    "Set-Cookie": [
      panelCookie(),
      runtimeBindingCookie(),
      ...(
        url.searchParams.has("handoff_probe") &&
        browserHandoffProbes.has(url.searchParams.get("handoff_probe"))
          ? [browserHandoffProbeCookie(url.searchParams.get("handoff_probe"))]
          : []
      ),
    ],
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
  let url = new URL(request.url, `http://${request.headers.host}`);

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
      headers["Set-Cookie"] = [panelCookie(), runtimeBindingCookie()];
      const probeId = getRequestCookie(request, "skilldock_handoff_probe");
      const probe = browserHandoffProbes.get(probeId);
      if (probe && probe.expires_at_ms > Date.now()) {
        probe.acknowledged_at = new Date().toISOString();
      }
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
      workspace: agentWorkspace,
      capabilities: agentDriver.capabilities,
      agent_permission: agentDriver.permissionProfile,
      surface: publicSurfaceState(),
      runtime_binding: publicRuntimeBinding(),
      permission_matrix: publicPermissionMatrix(),
      limitations:
        agentDriver.capabilities.supportsApprovalDecision === true
          ? []
          : ["Host approval decisions are unavailable in this driver."],
    });
    return;
  }

  if (
    request.method === "GET" &&
    url.pathname === "/source-hosted/open"
  ) {
    if (!sourceHostedEntryEnabled) {
      writeJson(response, 404, { error: "not found" });
      return;
    }
    const openId = url.searchParams.get("open_id");
    if (openId) {
      pruneSourceHostedOpenTickets();
      const ticket = sourceHostedOpenTickets.get(openId);
      sourceHostedOpenTickets.delete(openId);
      if (!ticket || ticket.expires_at_ms <= Date.now()) {
        writeJson(response, 410, {
          error: "source-hosted open ticket is invalid or expired",
          code: "source_hosted_open_expired",
        });
        return;
      }
      url = new URL(request.url, `http://${request.headers.host}`);
      url.searchParams.delete("open_id");
      url.searchParams.set("token", ticket.token);
    }
    receiveHandoff(
      request,
      response,
      url,
      { sourceHostedEntry: true },
    );
    return;
  }

  if (request.method === "GET" && url.pathname === "/handoff/open") {
    if (sourceHostedTaskActive()) {
      writeJson(response, 409, {
        error: "source_hosted 单 Task 模式不允许普通 handoff 切换",
        code: "single_task_scope",
      });
      return;
    }
    receiveHandoff(request, response, url);
    return;
  }

  if (!isAuthorized(request)) {
    writeJson(response, 401, { error: "missing or invalid capability token" });
    return;
  }
  const credentialRole = requestCredentialRole(request);
  const sourceSyncEndpoint =
    url.pathname === "/api/task/sync/import" ||
    url.pathname === "/api/task/sync/export" ||
    url.pathname === "/api/task/sync/claim";
  if (sourceSyncEndpoint) {
    // source_hosted Tasks require the dedicated source credential. In normal
    // mode sync remains a host/master operation; the browser panel credential
    // is never sufficient.
    const requiredRole = sourceHostedTaskActive() ? "source" : "master";
    if (credentialRole !== requiredRole) {
      writeJson(response, 403, {
        error: "source capability is required for this endpoint",
        code: "source_capability_required",
      });
      return;
    }
  } else if (credentialRole === "source") {
    writeJson(response, 403, {
      error: "source capability cannot use the panel API",
      code: "panel_capability_required",
    });
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/browser-handoff/probe"
  ) {
    pruneBrowserHandoffProbes();
    const probeId = randomUUID();
    const expiresAt = Date.now() + 600_000;
    browserHandoffProbes.set(probeId, {
      probe_id: probeId,
      launch_id: runtimeLaunchId,
      created_at: new Date().toISOString(),
      expires_at_ms: expiresAt,
      acknowledged_at: null,
    });
    writeJson(response, 201, {
      ok: true,
      probe_id: probeId,
      launch_id: runtimeLaunchId,
      expires_at: new Date(expiresAt).toISOString(),
    });
    return;
  }

  if (
    request.method === "GET" &&
    url.pathname === "/api/browser-handoff/status"
  ) {
    pruneBrowserHandoffProbes();
    const probeId = url.searchParams.get("probe_id") ?? "";
    const probe = browserHandoffProbes.get(probeId);
    if (!probe) {
      writeJson(response, 404, {
        ok: false,
        status: "unknown_or_expired",
      });
      return;
    }
    writeJson(response, 200, {
      ok: true,
      status: probe.acknowledged_at ? "acknowledged" : "pending",
      probe_id: probe.probe_id,
      launch_id: probe.launch_id,
      acknowledged_at: probe.acknowledged_at,
      expires_at: new Date(probe.expires_at_ms).toISOString(),
    });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/state") {
    writeJson(response, 200, publicState());
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/storage") {
    try {
      await pruneStorageExports({
        localRoot: storageLocalRoot,
        runtimeDir,
        localAppData: process.env.LOCALAPPDATA,
      });
      await recoverTaskDataCleanupQuarantines({
        localRoot: storageLocalRoot,
        runtimeDir,
        localAppData: process.env.LOCALAPPDATA,
      });
      writeJson(
        response,
        200,
        await getStorageSnapshot({
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        }),
      );
    } catch {
      writeJson(response, 500, {
        error: "storage inventory failed",
        code: "storage_inventory_failed",
      });
    }
    return;
  }

  const storageExportMatch = url.pathname.match(
    /^\/api\/storage\/exports\/([^/]+)$/u,
  );
  if (request.method === "GET" && storageExportMatch) {
    try {
      const exportId = decodeURIComponent(storageExportMatch[1]);
      const exportFile = await resolveStorageExportDownload(
        {
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        },
        exportId,
      );
      const fileStat = statSync(exportFile.path);
      response.writeHead(200, {
        "Content-Type": "application/zip",
        "Content-Length": fileStat.size,
        "Content-Disposition":
          `attachment; filename*=UTF-8''${encodeURIComponent(exportFile.name)}`,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      });
      const stream = createReadStream(exportFile.path);
      stream.once("error", () => response.destroy());
      stream.pipe(response);
    } catch (error) {
      const code = String(error?.code ?? "storage_export_missing");
      writeJson(response, code === "storage_export_expired" ? 410 : 404, {
        error:
          code === "storage_export_expired"
            ? "storage export expired"
            : "storage export not found",
        code,
      });
    }
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/storage/export-runtime-backup"
  ) {
    try {
      const result = await createRuntimeBackupExport({
        localRoot: storageLocalRoot,
        runtimeDir,
        localAppData: process.env.LOCALAPPDATA,
      });
      const storage = await getStorageSnapshot({
        localRoot: storageLocalRoot,
        runtimeDir,
        localAppData: process.env.LOCALAPPDATA,
      }).catch(() => null);
      writeJson(response, 201, { ...result, storage });
    } catch (error) {
      writeJson(response, 409, {
        error: error?.message ?? "Runtime backup export failed",
        code: error?.code ?? "storage_export_failed",
      });
    }
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/storage/export-task-data"
  ) {
    if (taskDataOperationInFlight) {
      writeJson(response, 409, {
        error: "Another Task data operation is already running.",
        code: "task_data_operation_in_progress",
      });
      return;
    }
    if (submitInFlight || state.phase === "running") {
      writeJson(response, 409, {
        error: "Wait for the current Agent turn before exporting.",
        code: "agent_turn_running",
      });
      return;
    }
    taskDataOperationInFlight = true;
    try {
      const result = await createTaskDataExport(
        {
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        },
        taskDataExportMetadata(),
      );
      const storage = await getStorageSnapshot({
        localRoot: storageLocalRoot,
        runtimeDir,
        localAppData: process.env.LOCALAPPDATA,
      }).catch(() => null);
      writeJson(response, 201, { ...result, storage });
    } catch (error) {
      writeJson(response, 500, {
        error: "Task export failed",
        code: error?.code ?? "task_export_failed",
      });
    } finally {
      taskDataOperationInFlight = false;
    }
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/storage/cleanup-task-data"
  ) {
    const body = await readJson(request, { maxBytes: 4_096 });
    if (body.confirm !== "cleanup-task-data") {
      writeJson(response, 400, {
        error: "Task data cleanup requires confirmation.",
        code: "confirmation_required",
      });
      return;
    }
    if (taskDataOperationInFlight) {
      writeJson(response, 409, {
        error: "Another Task data operation is already running.",
        code: "task_data_operation_in_progress",
      });
      return;
    }
    if (submitInFlight || state.phase === "running") {
      writeJson(response, 409, {
        error: "Wait for the current Agent turn before cleaning Task data.",
        code: "agent_turn_running",
      });
      return;
    }
    if (sourceHostedTaskActive()) {
      writeJson(response, 409, {
        error:
          "Source-hosted Tasks cannot be cleaned while another source owns them.",
        code: "source_hosted_task_cleanup_blocked",
      });
      return;
    }
    taskDataOperationInFlight = true;
    let quarantine;
    let resetCommitted = false;
    try {
      const verified = await verifyTaskDataExport(
        {
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        },
        body,
        taskDataExportMetadata(),
      );
      quarantine = await beginTaskDataCleanup(
        {
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        },
        {
          exportId: verified.record.export_id,
          exportSha256: verified.record.sha256,
        },
      );
      const resetResult = store.resetForUserDataCleanup({
        exportId: verified.record.export_id,
        exportSha256: verified.record.sha256,
        transactionId: quarantine.transactionId,
        threadReference: state.session_ref,
        threadName: state.session_name,
      });
      resetCommitted = true;
      let quarantineCleanupPending = false;
      try {
        await quarantine.commit();
      } catch {
        const recovery = await recoverTaskDataCleanupQuarantines({
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        });
        quarantineCleanupPending = recovery.pending > 0;
      }
      writeJson(response, 200, {
        ok: true,
        cleanup_completed: true,
        quarantine_cleanup_pending: quarantineCleanupPending,
        export_id: verified.record.export_id,
        export_sha256: verified.record.sha256,
        audit_recorded: resetResult.auditRecorded,
        state: publicState(),
        storage: await getStorageSnapshot({
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        }).catch(() => null),
      });
    } catch (error) {
      const code = String(error?.code ?? "task_data_cleanup_failed");
      if (code.startsWith("task_export_")) {
        const duplicate = await hasTaskDataCleanupReceipt(
          {
            localRoot: storageLocalRoot,
            runtimeDir,
            localAppData: process.env.LOCALAPPDATA,
          },
          {
            exportId: String(body.export_id ?? ""),
            exportSha256: String(body.export_sha256 ?? ""),
          },
        ).catch(() => false);
        if (duplicate) {
          writeJson(response, 200, {
            ok: true,
            cleanup_completed: true,
            duplicate: true,
            quarantine_cleanup_pending: false,
            export_id: String(body.export_id ?? ""),
            export_sha256: String(body.export_sha256 ?? ""),
            audit_recorded: true,
            state: publicState(),
            storage: await getStorageSnapshot({
              localRoot: storageLocalRoot,
              runtimeDir,
              localAppData: process.env.LOCALAPPDATA,
            }).catch(() => null),
          });
          return;
        }
      }
      if (quarantine && !resetCommitted) {
        await quarantine.rollback().catch(() => {});
      }
      const clientError =
        code === "task_export_stale"
          ? "Task data changed after the export was generated. Generate a new export."
          : code === "task_export_expired"
            ? "Task export has expired. Generate a new export."
            : code === "task_export_invalid"
              ? "Task export is invalid. Generate and download a new export."
              : "Task data cleanup failed";
      writeJson(response, code.startsWith("task_export_") ? 409 : 500, {
        error: clientError,
        code,
      });
    } finally {
      taskDataOperationInFlight = false;
    }
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/storage/cleanup-runtime-backups"
  ) {
    const body = await readJson(request, { maxBytes: 4_096 });
    try {
      const result = await cleanupRuntimeBackups(
        {
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        },
        body,
      );
      let auditRecorded = true;
      try {
        store.appendEvent({
          type: "storage.runtime_backup_cleanup",
          removed_backup_count: result.removed_backup_count,
          reclaimed_bytes: result.reclaimed_bytes,
          removed_engine_count:
            result.engine_cleanup?.removed_engine_count ?? 0,
          failure_count: result.failures.length,
        });
      } catch {
        auditRecorded = false;
        process.stderr.write(
          "Storage cleanup completed without an audit event.\n",
        );
      }
      writeJson(response, 200, {
        ...result,
        audit_recorded: auditRecorded,
      });
    } catch (error) {
      const statusCode =
        error?.code === "confirmation_required"
          ? 400
          : error?.code === "runtime_pointer_missing"
            ? 409
            : 500;
      writeJson(response, statusCode, {
        error: statusCode === 500
          ? "storage cleanup failed"
          : error.message,
        code: error?.code ?? "storage_cleanup_failed",
      });
    }
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/storage/cleanup-install-logs"
  ) {
    const body = await readJson(request, { maxBytes: 4_096 });
    try {
      const result = await cleanupInstallLogs(
        {
          localRoot: storageLocalRoot,
          runtimeDir,
          localAppData: process.env.LOCALAPPDATA,
        },
        body,
      );
      let auditRecorded = true;
      try {
        store.appendEvent({
          type: "storage.install_log_cleanup",
          removed_file_count: result.removed_file_count,
          reclaimed_bytes: result.reclaimed_bytes,
        });
      } catch {
        auditRecorded = false;
        process.stderr.write(
          "Install log cleanup completed without an audit event.\n",
        );
      }
      writeJson(response, 200, {
        ...result,
        audit_recorded: auditRecorded,
      });
    } catch (error) {
      writeJson(
        response,
        error?.code === "confirmation_required" ? 400 : 500,
        {
          error: error?.code === "confirmation_required"
            ? error.message
            : "install log cleanup failed",
          code: error?.code ?? "storage_cleanup_failed",
        },
      );
    }
    return;
  }

  if (
    request.method === "POST" &&
    url.pathname === "/api/source-hosted/entry"
  ) {
    if (
      !sourceHostedEntryEnabled ||
      !sourceHostedNonMockEnabled
    ) {
      writeJson(response, 404, {
        error: "source-hosted entry is unavailable",
        code: "source_hosted_entry_disabled",
      });
      return;
    }
    if (credentialRole !== "master") {
      writeJson(response, 403, {
        error: "master capability is required for source-hosted entry",
        code: "master_capability_required",
      });
      return;
    }
    const body = await readJson(request, { maxBytes: 32_768 });
    const taskId = String(body.task_id ?? "").trim();
    const sourceSessionRef = String(body.source_session_ref ?? "")
      .trim()
      .toLowerCase();
    const environmentThreadId = normalizeThreadBindingRef(
      body.environment_thread_id,
    );
    const objective = String(body.objective ?? "").trim().slice(0, 160);
    const summary = String(body.summary ?? "").trim().slice(0, 800);
    if (
      !isThreadReference(sourceSessionRef) ||
      (environmentThreadId && !isThreadReference(environmentThreadId))
    ) {
      writeJson(response, 400, {
        error: "source-hosted Thread references must be UUIDs",
        code: "thread_binding_invalid",
      });
      return;
    }
    if (!environmentThreadId) {
      writeJson(response, 409, {
        error:
          "source_hosted entry requires the current environment Thread id",
        code: "thread_binding_missing",
      });
      return;
    }
    if (environmentThreadId !== sourceSessionRef) {
      writeJson(response, 409, {
        error:
          "source_session_ref must equal the current environment Thread id",
        code: "thread_binding_mismatch",
        source_session_ref: sourceSessionRef,
        environment_thread_id: environmentThreadId,
      });
      return;
    }
    if (
      sourceHostedTaskActive() &&
      state.task.task_id !== taskId
    ) {
      writeJson(response, 409, {
        error: "source_hosted entry is limited to one current Task",
        code: "single_task_scope",
      });
      return;
    }
    if (
      sourceHostedTaskActive() &&
      state.task.shared_task.source_session_ref !== sourceSessionRef
    ) {
      writeJson(response, 409, {
        error: "source_hosted Task is already bound to another source Session",
        code: "source_session_scope",
      });
      return;
    }
    if (
      sourceHostedTaskActive() &&
      state.task.shared_task.environment_thread_id &&
      state.task.shared_task.environment_thread_id !== environmentThreadId
    ) {
      writeJson(response, 409, {
        error:
          "source_hosted Task is already bound to another environment Thread",
        code: "thread_rebinding_forbidden",
      });
      return;
    }
    const signed = signHandoffToken({
      thread_id: sourceSessionRef,
      environment_thread_id: environmentThreadId,
      task_id: taskId,
      objective,
      summary,
      domain_state:
        body.domain_state && typeof body.domain_state === "object"
          ? body.domain_state
          : {},
      domain_refs: Array.isArray(body.domain_refs) ? body.domain_refs : [],
      read_only: true,
      source: "agent-skill",
    }, handoffSecret, {
      ttlSeconds: Math.max(
        15,
        Math.min(600, Number(body.ttl_seconds ?? 120)),
      ),
    });
    const entryUrl = new URL(`http://${host}:${port}/source-hosted/open`);
    pruneSourceHostedOpenTickets();
    const openId = randomBytes(18).toString("base64url");
    sourceHostedOpenTickets.set(openId, {
      token: signed.token,
      expires_at_ms: Date.parse(signed.expires_at),
    });
    entryUrl.searchParams.set("open_id", openId);
    const channelId = `chat:source-hosted:${signed.packet.thread_id}`;
    writeJson(response, 200, {
      ok: true,
      url: entryUrl.toString(),
      task_ref: signed.packet.task_id,
      channel_id: channelId,
      source_session_ref: signed.packet.thread_id,
      expires_at: signed.expires_at,
    });
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task/sync/import") {
    const sync = validateSyncImport(
      await readJson(request, { maxBytes: 262_144 }),
    );
    let sourcePanel = null;
    const existingMessageIds = new Set(
      state.task?.timeline
        ?.map((entry) => entry.external_id)
        .filter(Boolean) ?? [],
    );
    if (sourceHostedTaskActive()) {
      const sharedTask = state.task.shared_task;
      if (sync.channelId !== sharedTask.channel_id) {
        writeJson(response, 409, {
          error: "source_hosted channel binding mismatch",
          code: "channel_binding_mismatch",
        });
        return;
      }
      if (
        !sync.sourceSessionRef ||
        sync.sourceSessionRef !== sharedTask.source_session_ref
      ) {
        writeJson(response, 409, {
          error: "source_hosted source Session binding mismatch",
          code: "source_session_scope",
        });
        return;
      }
      if (sharedTask.phase !== "source_agent_pulled") {
        writeJson(response, 409, {
          error: "source result import requires source_agent_pulled phase",
          code: "phase_conflict",
          phase: sharedTask.phase,
        });
        return;
      }
      const hasNewAgentResult = sync.messages.some(
        (message) =>
          message.role === "agent" &&
          !existingMessageIds.has(message.externalId),
      );
      if (!hasNewAgentResult) {
        writeJson(response, 409, {
          error: "a new agent result is required",
          code: "source_result_required",
          phase: sharedTask.phase,
        });
        return;
      }
      if (sync.panel !== null) {
        const pendingResult = sharedTask.source_tool_result ?? null;
        if (!sourceHostedNonMockEnabled) {
          writeJson(response, 403, {
            error: "source-hosted panel result requires the non-mock gate",
            code: "source_hosted_non_mock_disabled",
          });
          return;
        }
        if (!pendingResult) {
          writeJson(response, 409, {
            error: "no verified local tool result is pending",
            code: "source_tool_result_required",
          });
          return;
        }
        try {
          const candidatePanel = validatePanelState(sync.panel);
          sourcePanel =
            await skillRuntime.completeSourceHostedAgentResult({
              task: state.task,
              panel: candidatePanel,
              packet: pendingResult.packet,
              localResult: pendingResult.result,
            });
        } catch (error) {
          writeJson(response, 422, {
            error: error?.message || "source-hosted panel result is invalid",
            code: error?.code || "source_panel_invalid",
          });
          return;
        }
      }
    }
    let createdTask = false;
    const placeholderTask =
      Boolean(state.task) &&
      !state.task.sync?.channel_id &&
      state.task.timeline.length === 0 &&
      (state.task.attachments?.length ?? 0) === 0;
    if (
      !state.task ||
      (state.task.sync?.channel_id &&
        state.task.sync.channel_id !== sync.channelId) ||
      placeholderTask
    ) {
      if (state.task && !placeholderTask) {
        archiveCurrentTask();
      }
      discardDraftAttachmentFiles();
      state.task = createTask(
        sync.objective ||
          sync.summary ||
          "从主 Skill 对话继续任务",
      );
      state.panel = null;
      state.draft = { events: [], attachments: [] };
      state.activity = null;
      state.last_turn = null;
      state.handoff = null;
      createdTask = true;
    }
    state.task.sync ??= {
      schema_version: "1.0",
      channel_id: sync.channelId,
      source_session_ref: sync.sourceSessionRef || null,
      created_at: new Date().toISOString(),
    };
    if (state.task.sync.channel_id !== sync.channelId) {
      writeJson(response, 409, {
        error: "当前 Task 已绑定另一个主对话通道",
      });
      return;
    }
    if (sync.objective) {
      state.task.objective = sync.objective;
    }
    if (sync.summary) {
      state.task.summary = sync.summary;
    }
    if (sync.sourceSessionRef) {
      state.task.sync.source_session_ref = sync.sourceSessionRef;
    }
    let importedCount = 0;
    let importedAgentCount = 0;
    let skippedCount = 0;
    for (const message of sync.messages) {
      if (existingMessageIds.has(message.externalId)) {
        skippedCount += 1;
        continue;
      }
      appendTimelineEntry({
        role: message.role,
        text: message.text,
        createdAt: message.createdAt,
        source: "chat",
        externalId: message.externalId,
      });
      existingMessageIds.add(message.externalId);
      importedCount += 1;
      if (message.role === "agent") importedAgentCount += 1;
    }
    state.task.sync.last_import_at = new Date().toISOString();
    if (sourceHostedTaskActive() && importedAgentCount > 0) {
      const sourceResultAt = new Date().toISOString();
      markSourceHostedPhase("source_result_synced", {
        last_source_result_at: new Date().toISOString(),
      });
      if (sourcePanel) {
        state.panel = sourcePanel;
        state.phase =
          sourcePanel.status === "needs_input"
            ? "needs_input"
            : sourcePanel.status;
        state.last_turn = null;
        updateTaskFromPanel(sourcePanel);
        state.task.last_turn = null;
        state.task.shared_task.source_tool_result.resolved_at =
          sourceResultAt;
        state.activity = {
          status: "completed",
          user_summary:
            state.task.shared_task.source_tool_result
              ?.result?.attachment?.original_name ?? "PCHW telemetry analysis",
          started_at:
            state.task.shared_task.source_tool_result?.received_at ??
            sourceResultAt,
          completed_at: sourceResultAt,
          agent_summary: sourcePanel.turn_summary,
          next_action: sourcePanel.priorityAction?.title ?? "",
          error: null,
          turn_id: null,
          source_hosted: true,
        };
      }
      store.appendEvent({
        type: "source_hosted.result_synced",
        task_id: state.task.task_id,
        channel_id: state.task.shared_task.channel_id,
        imported_count: importedCount,
        source_session_ref: sync.sourceSessionRef || null,
        panel_turn_created: false,
        panel_result_present: Boolean(sourcePanel),
        artifact_count: sourcePanel?.artifact_refs?.length ?? 0,
      });
    }
    state.task.phase = "ready";
    state.phase = "ready";
    state.error = null;
    state.agent_error = null;
    if (sync.objective) {
      await updateThreadName(
        { current_goal: sync.objective },
        sync.objective,
      );
    }
    archiveCurrentTask();
    store.appendEvent({
      type: "task.sync.imported",
      task_id: state.task.task_id,
      channel_id: sync.channelId,
      source_session_ref: sync.sourceSessionRef || null,
      imported_count: importedCount,
      skipped_count: skippedCount,
      created_task: createdTask,
    });
    store.save();
    const formalTaskId = state.task.task_id;
    const formalObjective = state.task.objective;
    const formalCursor = state.task.timeline.reduce(
      (maximum, entry) =>
        Number.isInteger(entry.seq) ? Math.max(maximum, entry.seq) : maximum,
      0,
    );
    writeJson(response, 200, {
      ok: true,
      task_ref: formalTaskId,
      channel_id: sync.channelId,
      imported_count: importedCount,
      skipped_count: skippedCount,
      created_task: createdTask,
      cursor: formalCursor,
      shared_task_phase:
        state.task.shared_task?.phase ?? null,
    });
    if (sourceHostedShadow.shouldObserve) {
      const formalMessages = state.task.timeline
        .filter(
          (entry) =>
            entry.source === "chat" &&
            typeof entry.external_id === "string",
        )
        .map((entry) => ({
          external_id: entry.external_id,
          role: entry.role,
          text: entry.text,
          created_at: entry.created_at,
          seq: entry.seq,
        }));
      setImmediate(() => {
        sourceHostedShadow.observeSyncImport({
          formal_task_id: formalTaskId,
          channel_id: sync.channelId,
          source_session_ref: sync.sourceSessionRef,
          objective: formalObjective,
          cursor: formalCursor,
          messages: formalMessages,
        }).catch(() => {});
      });
    }
    return;
  }

  if (request.method === "POST" && url.pathname === "/api/task/sync/claim") {
    const suppliedSourceSessionRef = normalizeThreadReference(
      request.headers["x-source-session-ref"],
    );
    if (
      !sourceHostedTaskActive() ||
      !suppliedSourceSessionRef ||
      suppliedSourceSessionRef !==
        state.task.shared_task.source_session_ref
    ) {
      writeJson(response, 409, {
        ok: false,
        error: "source_hosted source Session binding mismatch",
        code: "claim_source_session_mismatch",
      });
      return;
    }
    const inspected = inspectSourceHostedClaim(
      await readJson(request, { maxBytes: 16_384 }),
    );
    if (!inspected.ok) {
      writeJson(response, inspected.status, {
        ok: false,
        error: inspected.message,
        code: inspected.code,
        ...Object.fromEntries(
          Object.entries(inspected).filter(
            ([key]) => !["ok", "status", "code", "message"].includes(key),
          ),
        ),
      });
      return;
    }
    const claim = inspected.claim;
    if (claim.sourceSessionRef !== suppliedSourceSessionRef) {
      writeJson(response, 409, {
        ok: false,
        error: "source-hosted source Session binding mismatch",
        code: "claim_source_session_mismatch",
      });
      return;
    }
    const claimIdentity = sourceHostedClaimIdentity(claim);
    const sharedTask = state.task.shared_task;
    if (
      ["source_agent_pulled", "source_result_synced"].includes(
        sharedTask.phase,
      ) &&
      sourceHostedClaimsMatch(sharedTask.last_source_pull_claim, claimIdentity)
    ) {
      writeJson(response, 200, {
        ok: true,
        claimed: true,
        idempotent: true,
        task_ref: state.task.task_id,
        phase: sharedTask.phase,
        claim: sharedTask.last_source_pull_claim,
      });
      return;
    }
    if (sharedTask.phase !== "waiting_for_source_pull") {
      writeJson(response, 409, {
        ok: false,
        error: "source pull claim is not valid in the current phase",
        code: "claim_phase_conflict",
        phase: sharedTask.phase,
        recovery_available: isSourceHostedStuckPhase(sharedTask.phase),
      });
      return;
    }
    const claimedAt = new Date().toISOString();
    markSourceHostedPhase("source_agent_pulled", {
      last_source_pull_at: claimedAt,
      last_source_pull_cursor: claim.submissionSequence,
      last_source_pull_intent_id: claim.intentEventId,
      last_source_pull_attachment_id: claim.attachmentId,
      last_source_pull_attachment_sha256: claim.attachmentSha256,
      last_source_pull_claim: claimIdentity,
    });
    store.appendEvent({
      type: claim.requireSourceResult
        ? "source_hosted.source_result_claimed"
        : "source_hosted.agent_pulled",
      task_id: state.task.task_id,
      channel_id: sharedTask.channel_id,
      source_session_ref: claim.sourceSessionRef,
      intent_event_id: claim.intentEventId,
      submission_sequence: claim.submissionSequence,
      attachment_id: claim.attachmentId,
      attachment_sha256: claim.attachmentSha256,
      source_result_required: claim.requireSourceResult,
      explicit_claim: true,
      panel_turn_created: false,
      thread_created: false,
    });
    store.save();
    writeJson(response, 200, {
      ok: true,
      claimed: true,
      idempotent: false,
      task_ref: state.task.task_id,
      phase: state.task.shared_task.phase,
      claim: state.task.shared_task.last_source_pull_claim,
    });
    return;
  }

  if (request.method === "GET" && url.pathname === "/api/task/sync/export") {
    const afterSequence = Number.parseInt(
      url.searchParams.get("after_seq") ?? "0",
      10,
    );
    if (!Number.isInteger(afterSequence) || afterSequence < 0) {
      writeJson(response, 400, { error: "after_seq must be a non-negative integer" });
      return;
    }
    const requestedChannel = String(
      url.searchParams.get("channel_id") ?? "",
    ).trim();
    const currentChannel = state.task?.sync?.channel_id ?? null;
    if (sourceHostedTaskActive()) {
      const sourceSessionRef = String(
        request.headers["x-source-session-ref"] ?? "",
      ).trim();
      if (requestedChannel !== state.task.shared_task.channel_id) {
        writeJson(response, 409, {
          error: "source_hosted channel binding mismatch",
          code: "channel_binding_mismatch",
        });
        return;
      }
      if (
        !sourceSessionRef ||
        sourceSessionRef !== state.task.shared_task.source_session_ref
      ) {
        writeJson(response, 409, {
          error: "source_hosted source Session binding mismatch",
          code: "source_session_scope",
        });
        return;
      }
    }
    if (requestedChannel && requestedChannel !== currentChannel) {
      writeJson(response, 409, {
        error: "当前 Task 不属于请求的主对话通道",
      });
      return;
    }
    const timeline = state.task?.timeline ?? [];
    const messages = timeline
      .filter(
        (entry) =>
          Number.isInteger(entry.seq) && entry.seq > afterSequence,
      )
      .map((entry) => ({
        seq: entry.seq,
        id: entry.id,
        external_id: entry.external_id ?? null,
        role: entry.role,
        text: entry.text,
        created_at: entry.created_at,
        source: entry.source ?? "surface",
        attachments: (entry.attachments ?? []).map(publicAttachment),
        source_payload: entry.source_payload ?? null,
      }));
    if (
      sourceHostedTaskActive() &&
      messages.some((message) => message.source === "source_hosted_intent")
    ) {
      if (
        ![
          "waiting_for_source_pull",
          "source_agent_pulled",
          "source_result_synced",
        ].includes(state.task.shared_task.phase)
      ) {
        writeJson(response, 409, {
          error: "source intent export is not valid in the current phase",
          code: "phase_conflict",
          phase: state.task.shared_task.phase,
        });
        return;
      }
    }
    const cursor = timeline.reduce(
      (maximum, entry) =>
        Number.isInteger(entry.seq) ? Math.max(maximum, entry.seq) : maximum,
      afterSequence,
    );
    writeJson(response, 200, {
      schema_version: "1.0",
      task_ref: state.task?.task_id ?? null,
      channel_id: currentChannel,
      source_session_ref: state.task?.sync?.source_session_ref ?? null,
      panel_session_ref: state.session_ref ?? state.thread_id ?? null,
      objective: state.task?.objective ?? "",
      summary: state.task?.summary ?? "",
      phase: state.phase,
      shared_task: state.task?.shared_task ?? null,
      panel: state.panel,
      last_turn: state.last_turn,
      messages,
      source_tool_result:
        state.task?.shared_task?.source_tool_result ?? null,
      cursor,
    });
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
    if (rejectNonSubmittableSourceHostedPhase(response)) return;
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
    const sourceIntent = queueSourceHostedInteraction(event);
    if (sourceIntent) {
      store.appendEvent({
        type: "source_hosted.intent_queued",
        task_id: state.task.task_id,
        channel_id: state.task.shared_task.channel_id,
        intent_message_id: sourceIntent.id,
        intent_event_id: event.event_id,
        intent_type: event.type,
        panel_turn_created: false,
      });
    }
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
    url.pathname === "/api/task/recover"
  ) {
    await recoverSourceHostedTask(request, response);
    return;
  }

  if (
    request.method === "POST" &&
    (url.pathname === "/api/task/new" || url.pathname === "/api/reset")
  ) {
    if (sourceHostedTaskActive()) {
      writeJson(response, 409, {
        error: "source_hosted 单 Task 模式不允许清空当前任务",
        code: "single_task_scope",
      });
      return;
    }
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
    if (sourceHostedTaskActive()) {
      writeJson(response, 409, {
        error: "source_hosted 单 Task 模式不允许创建新对话",
        code: "single_task_scope",
      });
      return;
    }
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
  await sourceHostedShadow.close().catch(() => {});
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2_000).unref();
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

const previousAgentWorkspace = state.agent_workspace ?? root;
const workspaceChanged = previousAgentWorkspace !== agentWorkspace;
if (workspaceChanged && state.session_ref) {
  archiveCurrentTask();
  discardDraftAttachmentFiles();
  store.appendEvent({
    type: "agent.workspace_changed",
    previous_workspace: previousAgentWorkspace,
    workspace: agentWorkspace,
  });
  setSessionReference(null);
  setSessionName(null);
  setSessionRecovered(null);
  state.task = null;
  state.panel = null;
  state.draft = { events: [], attachments: [] };
  state.activity = null;
  state.last_turn = null;
  state.handoff = null;
  state.phase = "ready";
  state.error = null;
  state.agent_error = null;
}
state.agent_workspace = agentWorkspace;
store.save();

try {
  await agentDriver.initialize();
  if (sourceExternalDriver) {
    setSessionReference(null);
    setSessionName("电脑硬件工作台");
    setSessionRecovered(null);
    state.agent_error = null;
  } else {
    const previousThreadReference = state.session_ref;
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
    await updateThreadName(
      state.panel,
      workspaceChanged ? "新任务" : "已恢复任务",
    );
    if (!state.last_turn) {
      store.appendEvent({
        type: "session.started",
        thread_id: activeThreadReference,
        thread_name: state.thread_name,
      });
    }
  }
  archiveCurrentTask();
  store.save();
  server.listen(port, host, () => {
    const info = {
      pid: process.pid,
      host,
      port,
      driver: agentDriverName,
      workspace: agentWorkspace,
      capabilities: agentDriver.capabilities,
      agent_permission: agentDriver.permissionProfile,
      surface: publicSurfaceState(),
      runtime_binding: publicRuntimeBinding(),
      launch_id: runtimeLaunchId,
      exact_url: `${runtimeOrigin}/?runtime_launch_id=${encodeURIComponent(
        runtimeLaunchId,
      )}&runtime_pid=${process.pid}&runtime_port=${port}`,
      started_at: new Date().toISOString(),
    };
    writeTextFileAtomic(
      resolve(runtimeDir, "server-info.json"),
      `${JSON.stringify(info, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    process.stdout.write(
      `SkillDock listening at http://${host}:${port}/ (${agentDriverName})\n`,
    );
  });
} catch (error) {
  const agentError = agentDriver.classifyError(error);
  process.stderr.write(
    `Failed to start SkillDock [${agentError.classification}/${agentError.code}]: ${agentError.message}\n`,
  );
  await agentDriver.close().catch(() => {});
  process.exit(1);
}
