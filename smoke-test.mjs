import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  cp,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { delimiter, join, resolve } from "node:path";
import {
  runPanelTurn,
} from "./lib/panel-response.mjs";
import { enforceDisplayEvidenceContract } from "./skills/pc-hardware-workbench/runtime.mjs";
import { signHandoffToken } from "./lib/handoff-capability.mjs";
import {
  artifactRootRef,
  capabilityGrantMatches,
  createCapabilityGrant,
  createPermissionRequest,
  defaultCapabilityProfile,
  expireCapabilityState,
  revokeCapabilityGrant,
} from "./skills/pc-hardware-workbench/capability-grants.mjs";
import { StateStore } from "./lib/state-store.mjs";
import {
  loadWorkbenchManifest,
  publicManifestDescriptor,
} from "./lib/workbench-manifest.mjs";
import { discoverSkillManifests } from "./lib/skill-discovery.mjs";
import { clearResetDraftStorage } from "./public/draft-storage.js";
import { deriveActivityMode } from "./public/status-model.js";
import {
  AgentDriver,
  AgentDriverError,
  CodexAgentDriver,
  DSHAgentDriver,
  DSHWebAgentDriver,
  MockAgentDriver,
  createAgentDriver,
  resolveAgentDriverName,
} from "./lib/agents/index.mjs";

const root = resolve(import.meta.dirname);
const CAPABILITY_CSV_ANALYZE = "telemetry.csv.analyze";

async function getAvailablePort() {
  return new Promise((resolvePromise, rejectPromise) => {
    const server = createTcpServer();
    server.unref();
    server.once("error", rejectPromise);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const selectedPort =
        address && typeof address === "object" ? address.port : null;
      server.close((error) => {
        if (error) {
          rejectPromise(error);
          return;
        }
        resolvePromise(selectedPort);
      });
    });
  });
}

process.env.PANEL_SKILL_MANIFEST ??= join(
  root,
  "skills",
  "pc-hardware-workbench",
  "workbench.manifest.json",
);
process.env.PANEL_SKILL_ID ??= "pc-hardware-workbench";
const runtimeDir = await mkdtemp(join(tmpdir(), "agent-panel-smoke-"));
const port = await getAvailablePort();
const base = `http://127.0.0.1:${port}`;
await writeFile(
  join(runtimeDir, "shared-evidence.json"),
  `${JSON.stringify(
    {
      schema_version: "1.0",
      store_id: "smoke-device-store",
      device_snapshot: {
        ref: "device-snapshot:smoke-2026-11-13",
        captured_date: "2026-11-13",
        identity_quality: "smoke-confirmed",
        privacy_mode: "local-private",
        device_alias: "Smoke Test PC",
        summary: "Synthetic smoke-test device snapshot.",
      },
      evidence_refs: [
        {
          id: "evidence-smoke-seed",
          kind: "configuration",
          label: "Seeded device configuration",
          captured_at: "2026-11-13T12:00:00+08:00",
          sha256: "seed",
        },
      ],
    },
    null,
    2,
  )}\n`,
  "utf8",
);
const child = spawn(process.execPath, ["server.mjs"], {
  cwd: root,
  windowsHide: true,
  env: {
    ...process.env,
    PANEL_AGENT_DRIVER: "mock",
    PANEL_PORT: String(port),
    PANEL_RUNTIME_DIR: runtimeDir,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let stdout = "";
let stderr = "";
child.stdout.on("data", (chunk) => (stdout += chunk.toString()));
child.stderr.on("data", (chunk) => (stderr += chunk.toString()));

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function waitForHealth() {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`server exited early\n${stderr}`);
    }
    try {
      const response = await fetch(`${base}/api/health`);
      if (response.ok) {
        return;
      }
    } catch {
      // Listener is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
  }
  throw new Error("server did not become healthy");
}

let cookie = "";
async function request(path, options = {}) {
  const isFormData = options.body instanceof FormData;
  const response = await fetch(`${base}${path}`, {
    ...options,
    headers: {
      Cookie: cookie,
      ...(isFormData ? {} : { "Content-Type": "application/json" }),
      ...(options.headers ?? {}),
    },
  });
  const data = await response.json();
  return { response, data };
}

try {
  const storeIdentityDir = await mkdtemp(join(tmpdir(), "agent-panel-store-"));
  const identityStore = new StateStore(storeIdentityDir);
  const identityState = identityStore.load();
  identityState.thread_id = "old-thread";
  identityState.panel = { stale: true };
  identityState.draft.events.push({ type: "option_selected", option_id: "all-games" });
  identityState.activity = {
    status: "completed",
    user_summary: "old submission",
    agent_summary: "old summary",
  };
  identityStore.save();
  assert(
    identityState.session_ref === "old-thread" &&
      identityState.thread_id === identityState.session_ref,
    "legacy thread_id was not migrated to the session_ref alias",
  );
  const resetIdentityState = identityStore.reset();
  assert(
    resetIdentityState === identityState && identityStore.state === identityState,
    "StateStore.reset replaced the shared state object",
  );
  assert(resetIdentityState.thread_id === null, "StateStore.reset kept the old thread");
  assert(resetIdentityState.session_ref === null, "StateStore.reset kept the old Session");
  assert(resetIdentityState.panel === null, "StateStore.reset kept the old panel");
  assert(resetIdentityState.draft.events.length === 0, "StateStore.reset kept draft events");
  assert(resetIdentityState.activity === null, "StateStore.reset kept old activity");
  const nextTaskState = identityStore.startTask(
    {
      task_id: "task-smoke",
      objective: "smoke task",
      device_snapshot_ref: "device-snapshot:smoke",
      evidence_refs: ["evidence-smoke-seed"],
      phase: "ready",
      summary: "",
      last_turn: null,
    },
    { threadReference: "shared-thread", threadName: "hardware smoke" },
  );
  assert(nextTaskState === identityState, "StateStore.startTask replaced the state object");
  assert(nextTaskState.thread_id === "shared-thread", "new task lost the Codex thread");
  assert(
    nextTaskState.session_ref === "shared-thread" &&
      nextTaskState.session_name === "hardware smoke",
    "new task did not persist the canonical Session fields",
  );
  assert(nextTaskState.task?.task_id === "task-smoke", "new task ID was not stored");

  const fixtureManifest = loadWorkbenchManifest({ projectRoot: root });
  const fixtureSkill = publicManifestDescriptor(fixtureManifest);
  assert(
    fixtureManifest.status === "active" &&
      fixtureSkill.id === "pc-hardware-workbench" &&
      fixtureSkill.ui.state_schema_version === "1.2" &&
      fixtureSkill.capabilities.some(
        (capability) => capability.id === "telemetry.csv.analyze",
      ) &&
      !/codex|dsh|app-server/iu.test(JSON.stringify(fixtureSkill)),
    "portable Workbench Manifest was not discovered or remained provider-specific",
  );
  const compatRoot = await mkdtemp(join(tmpdir(), "agent-panel-compat-"));
  const compatManifest = loadWorkbenchManifest({
    projectRoot: root,
    manifestPath: join(compatRoot, "missing.manifest.json"),
    allowedRoot: compatRoot,
  });
  assert(
    compatManifest.status === "invalid" &&
      compatManifest.error?.code === "manifest_path_missing",
    "a configured missing manifest did not degrade safely",
  );

  const invalidManifestRoot = await mkdtemp(
    join(tmpdir(), "agent-panel-invalid-manifest-"),
  );
  const invalidStateSchema = join(invalidManifestRoot, "state.schema.json");
  const invalidEventSchema = join(invalidManifestRoot, "event.schema.json");
  const invalidRuntimeEntry = join(invalidManifestRoot, "runtime.mjs");
  const invalidManifestPath = join(invalidManifestRoot, "workbench.manifest.json");
  await writeFile(
    invalidStateSchema,
    JSON.stringify({
      type: "object",
      properties: { schema_version: { const: "1.2" } },
    }),
  );
  await writeFile(
    invalidEventSchema,
    JSON.stringify({
      anyOf: [{ properties: { schema_version: { const: "1.0" } } }],
    }),
  );
  await writeFile(invalidRuntimeEntry, "export async function createRuntime() {}\n");
  await writeFile(
    invalidManifestPath,
    JSON.stringify({
      ...JSON.parse(
        await readFile(
          join(
            root,
            "skills",
            "pc-hardware-workbench",
            "workbench.manifest.json",
          ),
          "utf8",
        ),
      ),
      ui: {
        state_schema_version: "9.9",
        state_schema_path: "state.schema.json",
        event_schema_version: "1.0",
        event_schema_path: "event.schema.json",
      },
    }),
  );
  const invalidManifest = loadWorkbenchManifest({
    projectRoot: root,
    manifestPath: invalidManifestPath,
    allowedRoot: invalidManifestRoot,
  });
  assert(
    invalidManifest.status === "invalid" &&
      invalidManifest.error?.code === "manifest_schema_version",
    "an invalid manifest schema version did not degrade safely",
  );

  const escapeManifestPath = join(
    invalidManifestRoot,
    "escape.manifest.json",
  );
  await writeFile(
    escapeManifestPath,
    JSON.stringify({
      ...JSON.parse(await readFile(invalidManifestPath, "utf8")),
      skill: {
        id: "escape.example",
        name: "Escape fixture",
        version: "1.0.0",
        root: "../../../",
      },
      ui: {
        ...JSON.parse(await readFile(invalidManifestPath, "utf8")).ui,
        state_schema_version: "1.2",
      },
    }),
  );
  const escapeManifest = loadWorkbenchManifest({
    projectRoot: root,
    manifestPath: escapeManifestPath,
    allowedRoot: invalidManifestRoot,
  });
  assert(
    escapeManifest.status === "invalid" &&
      escapeManifest.error?.code === "manifest_path_escape",
    "a manifest path escape was not rejected",
  );

  const discoveredPreferred = discoverSkillManifests({
    projectRoot: root,
    explicitValue: null,
    roots: [join(root, "skills")],
    preferredSkillId: "generic-demo",
  });
  assert(
    discoveredPreferred.selected?.skill.id === "generic-demo" &&
      discoveredPreferred.compatibleCount === 2,
    "installed-Skill discovery did not honor the preferred Skill id",
  );
  const discoveredMissingActive = discoverSkillManifests({
    projectRoot: root,
    explicitValue: null,
    roots: [join(root, "skills")],
    preferredSkillId: null,
    previousActive: {
      skill_id: "missing-active-skill",
      skill_version: "9.9.9",
      runtime_id: "missing-active-runtime",
      manifest_hash: "missing",
    },
  });
  assert(
    discoveredMissingActive.selected === null &&
      discoveredMissingActive.fallbackRequired &&
      discoveredMissingActive.selectionReason === "previous_active_missing",
    "missing active Skill silently selected a different Skill",
  );
  const duplicateManifest = join(
    root,
    "skills",
    "generic-demo",
    "workbench.manifest.json",
  );
  const discoveredDuplicate = discoverSkillManifests({
    projectRoot: root,
    explicitValue: [duplicateManifest, duplicateManifest].join(delimiter),
    roots: [],
    preferredSkillId: null,
  });
  assert(
    discoveredDuplicate.candidates.length === 1 &&
      discoveredDuplicate.selected?.skill.id === "generic-demo",
    "duplicate manifest paths were not deduplicated",
  );

  const discoveryRoot = await mkdtemp(
    join(tmpdir(), "agent-panel-discovery-"),
  );
  const codexLikeRoot = join(discoveryRoot, ".codex", "skills");
  const dshLikeRoot = join(discoveryRoot, ".dsh", "skills");
  await cp(join(root, "skills", "generic-demo"), join(codexLikeRoot, "generic-demo"), {
    recursive: true,
  });
  await cp(
    join(root, "skills", "pc-hardware-workbench"),
    join(dshLikeRoot, "pc-hardware-workbench"),
    { recursive: true },
  );
  const discoveredStandardRoots = discoverSkillManifests({
    projectRoot: root,
    explicitValue: null,
    roots: [codexLikeRoot, dshLikeRoot, codexLikeRoot],
    preferredSkillId: "pc-hardware-workbench",
  });
  assert(
    discoveredStandardRoots.selected?.skill.id === "pc-hardware-workbench" &&
      discoveredStandardRoots.compatibleCount === 2 &&
      discoveredStandardRoots.candidates.length === 2,
    "temporary Codex/DSH-like roots were not scanned, selected, or deduplicated",
  );
  const copiedSkill = join(discoveryRoot, "generic-demo");
  await cp(join(root, "skills", "generic-demo"), copiedSkill, {
    recursive: true,
  });
  const copiedManifestPath = join(copiedSkill, "workbench.manifest.json");
  await rm(join(copiedSkill, "runtime.mjs"));
  const discoveredMissingRuntime = discoverSkillManifests({
    projectRoot: root,
    explicitValue: copiedManifestPath,
    roots: [],
  });
  assert(
    discoveredMissingRuntime.selected === null &&
      discoveredMissingRuntime.candidates[0]?.status === "invalid" &&
      discoveredMissingRuntime.candidates[0]?.error === "manifest_path_missing",
    "missing Skill runtime did not degrade to compatibility chat",
  );
  const outsideRuntime = join(discoveryRoot, "outside-runtime.mjs");
  await writeFile(
    outsideRuntime,
    "export async function createRuntime(context) { return null; }\n",
  );
  const escapedManifest = JSON.parse(
    await readFile(copiedManifestPath, "utf8"),
  );
  escapedManifest.runtime.entry = "../outside-runtime.mjs";
  await writeFile(
    copiedManifestPath,
    `${JSON.stringify(escapedManifest, null, 2)}\n`,
  );
  const discoveredEscape = discoverSkillManifests({
    projectRoot: root,
    explicitValue: copiedManifestPath,
    roots: [],
  });
  assert(
    discoveredEscape.selected === null &&
      discoveredEscape.candidates[0]?.error === "manifest_path_escape",
    "discovery accepted a runtime entry outside the Skill root",
  );

  const removedDraftKeys = [];
  const clearedDraftKeys = clearResetDraftStorage({
    storage: {
      removeItem(key) {
        removedDraftKeys.push(key);
      },
    },
    previousKey: "agent-panel-draft:old-thread",
    currentKey: "agent-panel-draft:new-thread",
  });
  assert(
    clearedDraftKeys.includes("agent-panel-draft:old-thread") &&
      clearedDraftKeys.includes("agent-panel-draft:new") &&
      clearedDraftKeys.includes("agent-panel-draft:new-thread"),
    "reset draft cleanup omitted an old, new-session, or current key",
  );
  assert(removedDraftKeys.length === 3, "reset draft cleanup removed the wrong key set");

  const statusCases = [
    [
      deriveActivityMode({
        phase: "running",
        submitPending: true,
        optimisticPhase: "sent",
        optimisticStartedAt: 1_000,
        now: 1_200,
      }),
      "sent",
    ],
    [
      deriveActivityMode({
        phase: "running",
        submitPending: true,
        optimisticPhase: "sent",
        optimisticStartedAt: 1_000,
        now: 2_000,
      }),
      "processing",
    ],
    [
      deriveActivityMode({
        phase: "needs_input",
        panel: { status: "needs_input" },
        activity: { completed_at: "2026-11-15T07:00:00.000Z" },
        transientReplyAt: Date.parse("2026-11-15T07:00:01.000Z"),
        now: Date.parse("2026-11-15T07:00:02.000Z"),
      }),
      "replied",
    ],
    [
      deriveActivityMode({
        phase: "needs_input",
        panel: { status: "needs_input" },
        activity: { completed_at: "2026-11-15T07:00:00.000Z" },
        now: Date.parse("2026-11-15T07:00:10.000Z"),
      }),
      "waiting",
    ],
    [deriveActivityMode({ phase: "error" }), "error"],
    [
      deriveActivityMode({
        phase: "completed",
        panel: { status: "ready" },
      }),
      "completed",
    ],
  ];
  for (const [actual, expected] of statusCases) {
    assert(actual === expected, `status mode expected ${expected}, received ${actual}`);
  }

  const displayPanel = enforceDisplayEvidenceContract(
    {
      schema_version: "1.1",
      recommendations: [
        { id: "one", title: "记录日期", detail: "记录日期", risk: "low", evidence_goal: "时间" },
        { id: "two", title: "记录现场", detail: "记录现场", risk: "low", evidence_goal: "现场" },
        { id: "three", title: "记录日志", detail: "记录日志", risk: "low", evidence_goal: "日志" },
      ],
    },
    { text: "只有一款游戏会黑屏和掉帧" },
  );
  const displayText = displayPanel.recommendations
    .map((item) => `${item.title} ${item.detail}`)
    .join(" ");
  assert(/固定/u.test(displayText), "display guard omitted fixed-scene evidence");
  assert(/事件查看器/u.test(displayText), "display guard omitted event evidence");
  assert(/HWiNFO/u.test(displayText), "display guard omitted GPU telemetry evidence");

  const grantNow = Date.parse("2026-11-15T12:00:00.000Z");
  const grantTaskId = "task-capability-unit";
  const grantAttachment = {
    id: "attachment-capability-unit",
    original_name: "telemetry.csv",
    size: 193,
    sha256: "a".repeat(64),
  };
  const permissionPresentation = {
    title: "Allow local action",
    description: "Unit-test presentation",
    scope_label: "read-only",
    facts: [],
    task_scope_label: "Task scope",
    approve_label: "Allow",
    deny_label: "Deny",
    approved_title: "Approved",
    approved_text: "Approved",
    continue_label: "Continue",
    denied_title: "Denied",
  };
  const permissionRequest = createPermissionRequest({
    capability: CAPABILITY_CSV_ANALYZE,
    presentation: permissionPresentation,
    taskId: grantTaskId,
    attachment: grantAttachment,
    window: { warmup_seconds: null, duration_seconds: null },
    now: grantNow,
  });
  const oneTimeGrant = createCapabilityGrant({
    request: permissionRequest,
    scope: "one-time",
    now: grantNow,
  });
  const grantContext = {
    taskId: grantTaskId,
    attachment: grantAttachment,
    capability: CAPABILITY_CSV_ANALYZE,
    artifactRootRef: artifactRootRef(grantTaskId),
    window: { warmup_seconds: null, duration_seconds: null },
    now: grantNow,
  };
  let traversalRootRejected = false;
  try {
    artifactRootRef("../outside-task");
  } catch {
    traversalRootRejected = true;
  }
  assert(
    traversalRootRejected,
    "artifact root accepted a traversal-shaped Task ID",
  );
  assert(
    capabilityGrantMatches(oneTimeGrant, grantContext),
    "valid one-time capability grant did not match",
  );
  assert(
    !capabilityGrantMatches(oneTimeGrant, {
      ...grantContext,
      taskId: "task-other",
    }),
    "capability grant crossed task boundary",
  );
  assert(
    !capabilityGrantMatches(oneTimeGrant, {
      ...grantContext,
      attachment: { ...grantAttachment, sha256: "b".repeat(64) },
    }),
    "capability grant crossed attachment-hash boundary",
  );
  assert(
    !capabilityGrantMatches(oneTimeGrant, {
      ...grantContext,
      artifactRootRef: artifactRootRef("task-other"),
    }),
    "capability grant crossed artifact-root boundary",
  );
  assert(
    !capabilityGrantMatches(oneTimeGrant, {
      ...grantContext,
      window: { warmup_seconds: 0, duration_seconds: 30 },
    }),
    "one-time grant was reused for another analysis window",
  );
  assert(
    !capabilityGrantMatches(oneTimeGrant, {
      ...grantContext,
      now: Date.parse(oneTimeGrant.expires_at) + 1,
    }),
    "expired capability grant still matched",
  );
  const expiringGrant = { ...oneTimeGrant };
  const expiration = expireCapabilityState({
    permissionRequest: null,
    grants: [expiringGrant],
    now: Date.parse(expiringGrant.expires_at) + 1,
  });
  assert(
    expiration.expiredGrants.length === 1 &&
      expiringGrant.status === "expired",
    "expired capability state was not recorded",
  );
  const expiringRequest = createPermissionRequest({
    capability: CAPABILITY_CSV_ANALYZE,
    presentation: permissionPresentation,
    taskId: grantTaskId,
    attachment: grantAttachment,
    window: { warmup_seconds: null, duration_seconds: null },
    now: grantNow,
  });
  const requestExpiration = expireCapabilityState({
    permissionRequest: expiringRequest,
    grants: [],
    now: Date.parse(expiringRequest.expires_at) + 1,
  });
  assert(
    requestExpiration.requestExpired &&
      expiringRequest.status === "expired",
    "expired permission request remained pending",
  );

  const taskRequest = createPermissionRequest({
    capability: CAPABILITY_CSV_ANALYZE,
    presentation: permissionPresentation,
    taskId: grantTaskId,
    attachment: grantAttachment,
    window: { warmup_seconds: null, duration_seconds: null },
    now: grantNow,
  });
  const taskGrant = createCapabilityGrant({
    request: taskRequest,
    scope: "task",
    now: grantNow,
  });
  assert(
    capabilityGrantMatches(taskGrant, {
      ...grantContext,
      window: { warmup_seconds: 0, duration_seconds: 30 },
    }),
    "task-scoped grant did not support another window for the same CSV",
  );
  assert(
    !capabilityGrantMatches(taskGrant, {
      ...grantContext,
      taskId: "task-other",
    }),
    "task-scoped grant matched a different Task",
  );
  assert(revokeCapabilityGrant(taskGrant), "active grant could not be revoked");
  assert(
    taskGrant.status === "revoked" &&
      !capabilityGrantMatches(taskGrant, grantContext),
    "revoked capability grant still matched",
  );

  assert(
    resolveAgentDriverName({}) === "codex" &&
      resolveAgentDriverName({ PANEL_AGENT_DRIVER: "mock" }) === "mock" &&
      resolveAgentDriverName({ PANEL_AGENT_DRIVER: "dsh" }) === "dsh" &&
      resolveAgentDriverName({ PANEL_AGENT_DRIVER: "dsh-web" }) === "dsh-web",
    "Agent driver selection did not resolve default/codex/dsh/dsh-web/mock",
  );
  let invalidDriverConfig = null;
  try {
    resolveAgentDriverName({ PANEL_AGENT_DRIVER: "unknown-driver" });
  } catch (error) {
    invalidDriverConfig = error;
  }
  assert(
    invalidDriverConfig instanceof AgentDriverError &&
      invalidDriverConfig.code === "invalid_driver_configuration" &&
      /codex.*dsh.*dsh-web.*mock/u.test(invalidDriverConfig.message),
    "invalid Agent driver configuration was not rejected clearly",
  );
  const mockDriver = createAgentDriver("mock");
  await mockDriver.initialize();
  const mockStart = await mockDriver.startThread();
  const mockResume = await mockDriver.resumeThread(mockStart.threadReference);
  assert(
    mockStart.threadReference &&
      mockResume.resumed &&
      mockDriver.capabilities.supportsStructuredOutput &&
      mockDriver.capabilities.supportsStreaming,
    "MockAgentDriver did not implement the neutral thread interface",
  );
  const mockStream = [];
  const mockTurn = await mockDriver.sendTurn({
    threadReference: mockStart.threadReference,
    eventId: "driver-interface-smoke",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "电脑最近有点卡",
    },
    structuredOutputSchema: {},
    onEvent: (event) => mockStream.push(event.type),
  });
  assert(
    mockTurn.turnId &&
      mockTurn.structuredOutput?.schema_version === "1.2" &&
      mockStream.includes("turn_started") &&
      mockStream.includes("text_delta") &&
      mockStream.includes("turn_completed"),
    "MockAgentDriver did not stream and complete through the neutral interface",
  );
  await mockDriver.close();

  const unsupportedDriver = new AgentDriver({
    name: "unsupported",
    displayName: "Unsupported",
    capabilities: {
      supportsThreadResume: false,
      supportsActiveThreadAttach: false,
    },
  });
  let unsupportedResume = null;
  try {
    await unsupportedDriver.resumeThread("thread-reference");
  } catch (error) {
    unsupportedResume = error;
  }
  assert(
    unsupportedResume instanceof AgentDriverError &&
      unsupportedResume.classification === "blocked" &&
      unsupportedResume.code === "unsupported_resumeThread" &&
      unsupportedDriver.capabilities.supportsActiveThreadAttach === false,
    "unsupported resume/attach did not expose a blocked capability boundary",
  );

  const classifier = new CodexAgentDriver({ cwd: root });
  assert(
    classifier.classifyError(new Error("already has an active writer"))
      .classification === "blocked" &&
      classifier.classifyError(new Error("app-server exited"))
        .classification === "unavailable" &&
      classifier.classifyError(new Error("approval denied")).classification ===
        "permission" &&
      classifier.classifyError(new Error("unexpected response")).classification ===
        "protocol",
    "Agent error classification is incomplete",
  );
  const unavailableCodex = new CodexAgentDriver({
    cwd: root,
    executable: "p4-missing-codex-driver",
  });
  let unavailableStart = null;
  try {
    await unavailableCodex.initialize();
  } catch (error) {
    unavailableStart = unavailableCodex.classifyError(error);
  }
  assert(
    unavailableStart instanceof AgentDriverError &&
      unavailableStart.classification === "unavailable",
    "Codex driver process-start failure was not classified unavailable",
  );
  await unavailableCodex.close().catch(() => {});

  const dshFixtureLog = join(runtimeDir, "dsh-fixture-log.jsonl");
  const previousDshFixtureLog = process.env.DSH_FIXTURE_LOG_PATH;
  process.env.DSH_FIXTURE_LOG_PATH = dshFixtureLog;
  const dshSchema = JSON.parse(
    await readFile(join(root, "schemas", "panel-ui-state.schema.json"), "utf8"),
  );
  const dshDriver = new DSHAgentDriver({
    cwd: root,
    agentDataDir: runtimeDir,
    fixture: true,
    dshHome: join(runtimeDir, "dsh-fixture-home"),
  });
  await dshDriver.initialize();
  const dshStart = await dshDriver.startThread();
  const dshFirst = await runPanelTurn({
    driver: dshDriver,
    threadReference: dshStart.threadReference,
    eventId: "dsh-fixture-first",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "电脑最近有点卡",
    },
    outputSchema: dshSchema,
  });
  const dshSessionId = dshDriver.activeThreadReference;
  const dshSecond = await runPanelTurn({
    driver: dshDriver,
    threadReference: dshSessionId,
    eventId: "dsh-fixture-second",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "[DSH_FIXTURE_FINAL_ONLY] 继续验证 session",
    },
    outputSchema: dshSchema,
  });
  const dshFenced = await runPanelTurn({
    driver: dshDriver,
    threadReference: dshSessionId,
    eventId: "dsh-fixture-fenced",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "[DSH_FIXTURE_FINAL_ONLY] [DSH_FIXTURE_FENCED_JSON]",
    },
    outputSchema: dshSchema,
  });
  const dshRepaired = await runPanelTurn({
    driver: dshDriver,
    threadReference: dshSessionId,
    eventId: "dsh-fixture-invalid",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "[DSH_FIXTURE_INVALID_JSON]",
    },
    outputSchema: dshSchema,
  });
  let dshInvalid = null;
  try {
    await runPanelTurn({
      driver: dshDriver,
      threadReference: dshSessionId,
      eventId: "dsh-fixture-always-invalid",
      packet: {
        schema_version: "1.0",
        type: "user_message",
        text: "[DSH_FIXTURE_ALWAYS_INVALID_JSON]",
      },
      outputSchema: dshSchema,
    });
  } catch (error) {
    dshInvalid = error;
  }
  let dshCancelTurnId = null;
  let dshCancelled = null;
  const dshCancelTurn = runPanelTurn({
    driver: dshDriver,
    threadReference: dshSessionId,
    eventId: "dsh-fixture-cancel",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "[DSH_FIXTURE_SLOW]",
    },
    outputSchema: dshSchema,
    onEvent: (event) => {
      if (event.type === "turn_started") {
        dshCancelTurnId = event.turnId;
      }
    },
  }).catch((error) => {
    dshCancelled = dshDriver.classifyError(error);
  });
  while (!dshCancelTurnId) {
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  await dshDriver.cancel(dshCancelTurnId);
  await dshCancelTurn;
  await dshDriver.close();
  assert(
    dshSessionId.startsWith("session-") &&
      dshFirst.panel.schema_version === "1.2" &&
      dshSecond.panel.schema_version === "1.2" &&
      dshFenced.panel.schema_version === "1.2" &&
      dshRepaired.panel.schema_version === "1.2" &&
      dshRepaired.repairAttempted === true &&
      dshDriver.capabilities.supportsStructuredOutput === false &&
      dshDriver.capabilities.structuredOutputCompatibility ===
        "prompt-parse-schema-validation",
    "DSH fixture did not implement session and compatibility behavior",
  );
  assert(
    dshInvalid instanceof AgentDriverError &&
      dshInvalid.classification === "protocol" &&
      dshInvalid.diagnosticPath,
    "DSH invalid JSON was not classified as protocol with diagnostics",
  );
  assert(
    dshCancelled instanceof AgentDriverError &&
      dshCancelled.classification === "blocked" &&
      dshCancelled.code === "dsh_turn_cancelled",
    "DSH cancellation did not terminate and classify the active turn",
  );
  const dshFixtureRecords = (
    await readFile(dshFixtureLog, "utf8")
  )
    .trim()
    .split(/\r?\n/)
    .map((line) => JSON.parse(line));
  assert(
    dshFixtureRecords[0]?.resumed === false &&
      dshFixtureRecords[1]?.resumed === true &&
      dshFixtureRecords[0]?.sessionId === dshFixtureRecords[1]?.sessionId,
    "DSH second turn did not resume the first session ID",
  );
  const dshAuthDriver = new DSHAgentDriver({
    cwd: root,
    agentDataDir: runtimeDir,
    fixture: true,
    dshHome: join(runtimeDir, "dsh-auth-home"),
  });
  await dshAuthDriver.initialize();
  await dshAuthDriver.startThread();
  let dshAuth = null;
  try {
    await runPanelTurn({
      driver: dshAuthDriver,
      threadReference: dshAuthDriver.activeThreadReference,
      eventId: "dsh-fixture-auth",
      packet: {
        schema_version: "1.0",
        type: "user_message",
        text: "[DSH_FIXTURE_AUTH_FAILURE]",
      },
      outputSchema: dshSchema,
    });
  } catch (error) {
    dshAuth = dshAuthDriver.classifyError(error);
  }
  await dshAuthDriver.close();
  assert(
    dshAuth instanceof AgentDriverError &&
      dshAuth.classification === "auth",
    "DSH authentication failure was not classified as auth",
  );
  if (previousDshFixtureLog === undefined) {
    delete process.env.DSH_FIXTURE_LOG_PATH;
  } else {
    process.env.DSH_FIXTURE_LOG_PATH = previousDshFixtureLog;
  }

  const dshWebCalls = [];
  const dshWebFixtureTransport = {
    async open() {
      return { connected: true };
    },
    async close() {
      dshWebCalls.push(["close"]);
    },
    async rpc(endpoint, args) {
      dshWebCalls.push([endpoint, args]);
      if (endpoint === "session/create") {
        return { sessionId: "session-panel-web-fixture" };
      }
      if (endpoint === "session/events") {
        return { cursor: 0, records: [], hasMore: false };
      }
      if (endpoint === "session/state") {
        return {
          cursor: 0,
          active: true,
          running: false,
          queue: [],
          pendingInput: [],
        };
      }
      if (endpoint === "session/prompt") {
        return { accepted: true };
      }
      if (endpoint === "session/wait") {
        return {
          reason: "idle",
          state: {
            cursor: 1,
            active: true,
            running: false,
            queue: [],
            pendingInput: [],
          },
          output: {
            records: [
              {
                type: "event",
                event: {
                  type: "assistant/message",
                  seq: 1,
                  time: Date.now(),
                  data: {
                    turn: 1,
                    step: 1,
                    message: {
                      role: "assistant",
                      content: [
                        {
                          type: "text",
                          text: JSON.stringify(dshFirst.panel),
                        },
                      ],
                    },
                    stream: [],
                  },
                },
              },
            ],
            truncated: false,
          },
        };
      }
      if (endpoint === "session/rename") {
        return {
          title: args.request.title,
          seq: 2,
        };
      }
      throw new Error(`Unexpected DSH Web fixture endpoint: ${endpoint}`);
    },
  };
  const dshWebDriver = new DSHWebAgentDriver({
    cwd: root,
    transport: dshWebFixtureTransport,
    fixture: true,
  });
  await dshWebDriver.initialize();
  const dshWebStart = await dshWebDriver.startThread();
  await dshWebDriver.resumeThread(dshWebStart.threadReference);
  const dshWebTurn = await runPanelTurn({
    driver: dshWebDriver,
    threadReference: dshWebStart.threadReference,
    eventId: "dsh-web-fixture-turn",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "电脑最近有点卡",
    },
    outputSchema: dshSchema,
  });
  await dshWebDriver.setThreadName("DSH Web fixture task");
  await dshWebDriver.close();
  const dshWebEndpoints = dshWebCalls.map(([endpoint]) => endpoint);
  assert(
    dshWebStart.threadReference === "session-panel-web-fixture" &&
      dshWebTurn.panel.schema_version === "1.2" &&
      dshWebDriver.capabilities.supportsActiveThreadAttach === false &&
      dshWebDriver.capabilities.supportsStreaming === false &&
      dshWebDriver.capabilities.childProcessOwned === true &&
      dshWebDriver.capabilities.launchCredentialStorage === "memory-only" &&
      dshWebEndpoints.includes("session/create") &&
      dshWebEndpoints.includes("session/prompt") &&
      dshWebEndpoints.includes("session/wait") &&
      dshWebEndpoints.includes("session/rename") &&
      dshWebEndpoints.includes("close"),
    "DSH Web adapter did not honor the neutral interface and capabilities",
  );

  const coreFiles = [
    "server.mjs",
    "lib/state-store.mjs",
    "lib/handoff-capability.mjs",
    "lib/skill-runtime.mjs",
    "lib/skill-discovery.mjs",
    "lib/workbench-manifest.mjs",
    "lib/panel-response.mjs",
    "public/app.js",
  ];
  for (const file of coreFiles) {
    const source = await readFile(join(root, file), "utf8");
    assert(
      !/app-server|threadId|turn\/start|thread\/start|thread\/resume/iu.test(
        source,
      ),
      `upper layer ${file} contains adapter protocol logic`,
    );
  }

  const invalidConfigRuntime = await mkdtemp(
    join(tmpdir(), "agent-panel-invalid-driver-"),
  );
  const invalidConfigPort = await getAvailablePort();
  const invalidConfigChild = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "unsupported",
      PANEL_PORT: String(invalidConfigPort),
      PANEL_RUNTIME_DIR: invalidConfigRuntime,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let invalidConfigStdout = "";
  let invalidConfigStderr = "";
  invalidConfigChild.stdout.on("data", (chunk) => {
    invalidConfigStdout += chunk.toString();
  });
  invalidConfigChild.stderr.on("data", (chunk) => {
    invalidConfigStderr += chunk.toString();
  });
  const invalidConfigExit = await new Promise((resolvePromise) => {
    invalidConfigChild.once("close", (code) => resolvePromise(code));
  });
  assert(
    invalidConfigExit === 1 &&
      /Agent driver configuration error/iu.test(invalidConfigStderr) &&
      /codex.*dsh.*mock/iu.test(invalidConfigStderr) &&
      invalidConfigStdout === "",
    "invalid PANEL_AGENT_DRIVER did not fail with a clear configuration error",
  );

  await waitForHealth();
  const page = await fetch(`${base}/`);
  assert(page.ok, "root page did not load");
  cookie = page.headers.getSetCookie()[0].split(";")[0];

  let result = await request("/api/state");
  assert(result.response.ok, "state endpoint rejected cookie");
  assert(
    result.data.agent?.driver === "mock" &&
      result.data.agent?.displayName === "Mock" &&
      result.data.skill?.status === "active" &&
      /^[A-Za-z0-9._:-]{8,}$/u.test(result.data.session_ref ?? ""),
    "server did not select the mock AgentDriver",
  );
  const initialThread = result.data.thread_id;
  assert(initialThread, "mock app-owned thread was not created");
  assert(result.data.thread_name, "thread name was not set");
  assert(
    result.data.session_ref === result.data.thread_id &&
      result.data.session_name === result.data.thread_name,
    "public Session aliases do not match legacy state",
  );
  const initialTaskId = result.data.task?.task_id;
  const initialDeviceRef = result.data.domain_context?.device_snapshot_ref;
  const initialEvidenceIds = result.data.domain_context?.domain_refs;
  assert(initialTaskId, "initial workbench task was not created");
  assert(initialDeviceRef, "initial task was not bound to a shared device snapshot");
  assert(initialEvidenceIds.length >= 1, "shared evidence seed was not loaded");

  const handoffSigningSecret = (
    await readFile(join(runtimeDir, "handoff-secret"), "utf8")
  ).trim();
  const panelCapabilityToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const handoffThreadId = "01a1d070-0000-7000-8000-000000000001";
  const signedHandoff = signHandoffToken(
    {
      thread_id: handoffThreadId,
      task_id: initialTaskId,
      objective: "P2A signed handoff smoke",
      summary: "Reuse the current task, device, and evidence references.",
      domain_state: { device_snapshot_ref: initialDeviceRef },
      domain_refs: initialEvidenceIds,
      read_only: true,
      source: "agent-skill",
    },
    handoffSigningSecret,
    { ttlSeconds: 60 },
  );
  const handoffResponse = await fetch(
    `${base}/handoff/open?token=${encodeURIComponent(signedHandoff.token)}`,
    { redirect: "manual" },
  );
  assert(
    handoffResponse.status === 303 &&
      handoffResponse.headers.get("location") === "/",
    "signed handoff URL was not accepted",
  );
  const handoffState = await request("/api/state");
  assert(
    handoffState.data.thread_id === initialThread,
    "handoff changed the panel Codex thread",
  );
  assert(
    handoffState.data.handoff?.thread_id === handoffThreadId &&
      handoffState.data.handoff?.task_id === initialTaskId,
    "handoff packet was not persisted",
  );
  assert(
    handoffState.data.handoff?.current_domain_refs?.length ===
      initialEvidenceIds.length &&
      handoffState.data.domain_context?.device_snapshot_ref === initialDeviceRef,
    "handoff packet lost Skill domain references",
  );
  assert(
    handoffState.data.handoff?.native_thread_attached === false &&
      handoffState.data.handoff?.queue_message_sent === false &&
      handoffState.data.handoff?.context_applied === true &&
      handoffState.data.handoff?.local_surface_handoff === true &&
      handoffState.data.handoff?.native_owner_changed === false,
    "blocked handoff claimed native attachment or sent a queue message",
  );
  assert(
    handoffState.data.domain_context?.device_snapshot_ref === initialDeviceRef,
    "signed handoff did not preserve the Skill domain context",
  );
  assert(
    !JSON.stringify(handoffState.data).includes(signedHandoff.token),
    "handoff token leaked into public state",
  );
  const handoffReplay = await fetch(
    `${base}/handoff/open?token=${encodeURIComponent(signedHandoff.token)}`,
    { redirect: "manual" },
  );
  assert(handoffReplay.status === 409, "handoff token replay was not rejected");
  const tamperedHandoff = `${signedHandoff.token.slice(0, -1)}${
    signedHandoff.token.endsWith("A") ? "B" : "A"
  }`;
  const handoffTamperResponse = await fetch(
    `${base}/handoff/open?token=${encodeURIComponent(tamperedHandoff)}`,
    { redirect: "manual" },
  );
  assert(
    handoffTamperResponse.status === 401,
    "tampered handoff token was not rejected",
  );
  const expiredHandoff = signHandoffToken(
    {
      thread_id: handoffThreadId,
      task_id: initialTaskId,
      objective: "Expired handoff smoke",
      summary: "This token must be rejected.",
      domain_state: { device_snapshot_ref: initialDeviceRef },
      domain_refs: initialEvidenceIds,
      read_only: true,
      source: "agent-skill",
    },
    handoffSigningSecret,
    { ttlSeconds: 60, now: Date.now() - 120_000 },
  );
  const expiredHandoffResponse = await fetch(
    `${base}/handoff/open?token=${encodeURIComponent(expiredHandoff.token)}`,
    { redirect: "manual" },
  );
  assert(
    expiredHandoffResponse.status === 401,
    "expired handoff token was not rejected",
  );
  const handoffEventLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/);
  assert(
    handoffEventLines.some((line) => line.includes('"type":"handoff.received"')) &&
      handoffEventLines.some((line) =>
        line.includes('"type":"handoff.native_attachment_blocked"'),
      ) &&
      handoffEventLines.some((line) =>
        line.includes('"type":"handoff.local_surface_handoff"'),
      ),
    "handoff audit events were not recorded",
  );
  assert(
    handoffEventLines.every((line) => !line.includes("task.surface_changed")),
    "blocked handoff incorrectly recorded a native surface change",
  );
  assert(
    handoffEventLines.every(
      (line) =>
        !line.includes("codex.queue") &&
        !line.includes('"type":"agent.panel_updated"'),
    ),
    "default handoff queued input or produced a ghost agent reply",
  );
  const cliPacketPath = join(runtimeDir, "handoff-cli-packet.json");
  await writeFile(
    cliPacketPath,
    `${JSON.stringify(
      {
        thread_id: handoffThreadId,
        task_id: initialTaskId,
        objective: "P2A CLI handoff smoke",
        summary: "CLI-shaped Task Resume Packet.",
        domain_state: { device_snapshot_ref: initialDeviceRef },
        domain_refs: initialEvidenceIds,
        read_only: true,
        source: "agent-skill",
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  const openWorkbenchResult = await new Promise((resolvePromise) => {
    const childProcess = spawn(
      process.execPath,
      [
        "open-workbench.mjs",
        "--packet-file",
        cliPacketPath,
        "--secret-file",
        join(runtimeDir, "handoff-secret"),
        "--base-url",
        `${base}/`,
      ],
      {
        cwd: root,
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
        env: process.env,
      },
    );
    let cliStdout = "";
    let cliStderr = "";
    childProcess.stdout.on("data", (chunk) => {
      cliStdout += chunk.toString();
    });
    childProcess.stderr.on("data", (chunk) => {
      cliStderr += chunk.toString();
    });
    childProcess.once("close", (code) => {
      resolvePromise({ code, stdout: cliStdout, stderr: cliStderr });
    });
  });
  assert(
    openWorkbenchResult.code === 0,
    `open-workbench CLI failed: ${openWorkbenchResult.stderr}`,
  );
  const openWorkbenchOutput = JSON.parse(openWorkbenchResult.stdout);
  assert(
    openWorkbenchOutput.thread_id === handoffThreadId &&
      openWorkbenchOutput.task_id === initialTaskId &&
      openWorkbenchOutput.support_level === "task-resume-packet" &&
      openWorkbenchOutput.url.startsWith(`${base}/handoff/open?token=`) &&
      openWorkbenchOutput.thread_id_source ===
        (openWorkbenchOutput.environment_thread_id === handoffThreadId
          ? "environment"
          : "packet"),
    "open-workbench CLI produced an invalid signed handoff",
  );

  const firstSubmitPromise = request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "电脑最近有点卡" }),
  });
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 60));
  const duringFirstTurn = await request("/api/state");
  assert(duringFirstTurn.response.ok, "running state refresh failed");
  assert(duringFirstTurn.data.phase === "running", "running phase was not observable");
  assert(
    duringFirstTurn.data.activity?.status === "running",
    "running activity was not persisted",
  );
  assert(
    duringFirstTurn.data.activity?.user_summary === "电脑最近有点卡",
    "running activity lost the submitted user content",
  );
  const duplicateSubmit = await request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "重复提交" }),
  });
  assert(
    duplicateSubmit.response.status === 409,
    "duplicate submit was not rejected while the agent was running",
  );

  result = await firstSubmitPromise;
  assert(result.response.ok, `first submit failed: ${result.data.error}`);
  assert(result.data.panel?.question?.id === "slowdown-timing", "missing timing question");
  assert(result.data.panel?.schema_version === "1.2", "new result schema was not used");
  assert(result.data.panel?.recommendations?.length >= 2, "result has no substantive recommendations");
  assert(result.data.panel?.priorityAction?.title, "result has no priority action");
  assert(
    result.data.activity?.status === "completed",
    "completed activity was not persisted",
  );
  assert(
    result.data.activity?.agent_summary === result.data.panel.turn_summary,
    "completed activity lost the agent turn summary",
  );
  const gaming = result.data.panel.question.options.find(
    (option) => option.label === "玩游戏时",
  );
  assert(gaming, "missing exact 玩游戏时 option");
  assert(result.data.thread_id === initialThread, "thread changed after first turn");
  assert(result.data.task?.task_id === initialTaskId, "first turn changed the active task");

  result = await request("/api/event", {
    method: "POST",
    body: JSON.stringify({
      type: "option_selected",
      question_id: result.data.panel.question.id,
      option_id: gaming.id,
    }),
  });
  assert(result.response.ok, `option event failed: ${result.data.error}`);
  assert(
    result.data.draft.events.some((event) => event.type === "option_selected"),
    "selection was not persisted",
  );

  const refreshed = await request("/api/state");
  assert(refreshed.response.ok, "refresh state failed");
  assert(
    refreshed.data.draft.events.some((event) => event.type === "option_selected"),
    "selection did not survive a state refresh",
  );

  result = await request("/api/event", {
    method: "POST",
    body: JSON.stringify({
      type: "evidence_added",
      label: "测试观察",
      detail: "仅在 smoke test 中生成",
      source: "user_reported",
    }),
  });
  assert(result.response.ok, "evidence event failed");

  const secondSubmitPromise = request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "" }),
  });
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 60));
  const duringSecondTurn = await request("/api/state");
  assert(
    duringSecondTurn.data.activity?.status === "running",
    "second-turn running activity was not observable",
  );
  assert(
    duringSecondTurn.data.activity?.user_summary?.includes("选择：玩游戏时"),
    "second-turn activity lost the selected option label",
  );
  result = await secondSubmitPromise;
  assert(result.response.ok, `second submit failed: ${result.data.error}`);
  assert(result.data.panel?.question?.id === "game-symptom", "missing follow-up question");
  assert(result.data.thread_id === initialThread, "thread changed after selection turn");
  assert(result.data.task?.task_id === initialTaskId, "second turn changed the active task");
  assert(result.data.draft.events.length === 0, "draft did not clear after success");

  result = await request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "补充：我还想检查故障发生时的温度" }),
  });
  assert(result.response.ok, `free-text continuation failed: ${result.data.error}`);
  assert(result.data.thread_id === initialThread, "free-text continuation changed thread");
  assert(result.data.task?.task_id === initialTaskId, "free-text continuation changed task");

  const oldThread = result.data.thread_id;
  const oldTaskId = result.data.task?.task_id;
  const reusedDeviceRef = result.data.domain_context?.device_snapshot_ref;
  const reusedEvidenceIds = result.data.domain_context?.domain_refs;
  result = await request("/api/task/new", {
    method: "POST",
    body: JSON.stringify({}),
  });
  assert(result.response.ok, `new task failed: ${result.data.error}`);
  assert(result.data.thread_id === oldThread, "new task unexpectedly changed Codex thread");
  assert(result.data.task === null, "new task was created before the first submission");
  assert(result.data.panel === null, "new task retained the old panel");
  assert(result.data.draft.events.length === 0, "new task retained old draft events");
  assert(result.data.activity === null, "new task retained old activity");
  assert(
    result.data.domain_context?.device_snapshot_ref === reusedDeviceRef,
    "new task did not reuse the shared device snapshot",
  );
  assert(
    JSON.stringify(result.data.domain_context?.domain_refs) ===
      JSON.stringify(reusedEvidenceIds),
    "new task did not reuse shared evidence references",
  );
  assert(Boolean(result.data.domain_context), "new task lost its Skill context");
  const archivedTask = JSON.parse(
    await readFile(join(runtimeDir, "tasks", `${oldTaskId}.json`), "utf8"),
  );
  assert(archivedTask.task?.task_id === oldTaskId, "previous task was not archived");
  assert(archivedTask.panel?.judgement, "archived task lost its answer card");
  const resetStateFile = JSON.parse(
    await readFile(join(runtimeDir, "state.json"), "utf8"),
  );
  assert(resetStateFile.thread_id === oldThread, "new task thread was not persisted");
  assert(resetStateFile.task === null, "pending task unexpectedly persisted a task object");
  assert(resetStateFile.panel === null, "new task panel was not persisted");
  assert(resetStateFile.draft.events.length === 0, "new task draft was not persisted");
  assert(resetStateFile.activity === null, "new task activity was not persisted");

  const eventOffset = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).length;
  const csvForm = new FormData();
  csvForm.append(
    "file",
    new Blob(
      [
        [
          "Date,Time,GPU Temperature [C],GPU Power [W],GPU Effective Clock [MHz],GPU Fan [RPM],FPS",
          "2026-11-15,20:00:00,66,148,2360,1800,118",
          "2026-11-15,20:00:05,68,151,2315,1810,116",
          "2026-11-15,20:00:10,67,149,2342,1805,117",
        ].join("\n"),
      ],
      { type: "text/csv" },
    ),
    "gpu-log.csv",
  );
  result = await request("/api/attachments", {
    method: "POST",
    body: csvForm,
  });
  assert(result.response.ok, `CSV upload failed: ${result.data.error}`);
  assert(result.data.draft.attachments.length === 1, "CSV attachment was not added");
  assert(/GPU Temperature/.test(result.data.draft.attachments[0].preview), "CSV preview missing");
  const csvId = result.data.draft.attachments[0].id;

  const pngForm = new FormData();
  pngForm.append(
    "file",
    new Blob(
      [
        Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII=",
          "base64",
        ),
      ],
      { type: "image/png" },
    ),
    "screenshot.png",
  );
  result = await request("/api/attachments", {
    method: "POST",
    body: pngForm,
  });
  assert(result.response.ok, `image upload failed: ${result.data.error}`);
  assert(result.data.draft.attachments.length === 2, "image attachment was not added");
  const pngId = result.data.draft.attachments[1].id;
  const imageResponse = await fetch(`${base}/api/attachments/${pngId}/content`, {
    headers: { Cookie: cookie },
  });
  assert(imageResponse.ok, "uploaded image could not be previewed");
  assert(
    imageResponse.headers.get("content-type") === "image/png",
    "uploaded image MIME type changed",
  );

  const removableForm = new FormData();
  removableForm.append(
    "file",
    new Blob(["delete me"], { type: "text/plain" }),
    "../../remove-me.txt",
  );
  result = await request("/api/attachments", {
    method: "POST",
    body: removableForm,
  });
  assert(result.response.ok, "removable attachment upload failed");
  assert(
    result.data.draft.attachments[2].original_name === "remove-me.txt",
    "attachment path traversal in the original name was not removed",
  );
  const removableId = result.data.draft.attachments[2].id;
  result = await request(`/api/attachments/${removableId}`, {
    method: "DELETE",
  });
  assert(result.response.ok, `attachment delete failed: ${result.data.error}`);
  assert(result.data.draft.attachments.length === 2, "deleted attachment remained in draft");

  const unsupportedForm = new FormData();
  unsupportedForm.append(
    "file",
    new Blob(["<svg/>"], { type: "image/svg+xml" }),
    "unsafe.svg",
  );
  result = await request("/api/attachments", {
    method: "POST",
    body: unsupportedForm,
  });
  assert(result.response.status === 415, "unsupported SVG was not rejected");

  const oversizedForm = new FormData();
  oversizedForm.append(
    "file",
    new Blob([new Uint8Array(8 * 1024 * 1024 + 1)], { type: "text/plain" }),
    "too-large.txt",
  );
  result = await request("/api/attachments", {
    method: "POST",
    body: oversizedForm,
  });
  assert(result.response.status === 413, "oversized attachment was not rejected");

  const attachmentState = await request("/api/state");
  assert(
    attachmentState.data.draft.attachments.map((item) => item.id).join(",") ===
      [csvId, pngId].join(","),
    "attachment draft did not survive a refresh",
  );
  assert(attachmentState.data.phase === "ready", "attachment upload started an agent turn");
  assert(attachmentState.data.thread_id === oldThread, "attachment upload changed thread");

  result = await request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "请分析附件：只有一款游戏会黑屏和掉帧" }),
  });
  assert(result.response.ok, `new-task submit failed: ${result.data.error}`);
  assert(result.data.thread_id === oldThread, "new-task submit changed thread unexpectedly");
  const newTaskId = result.data.task?.task_id;
  assert(newTaskId && newTaskId !== oldTaskId, "first submission did not create a new task");
  assert(result.data.panel?.question?.id === "game-symptom", "new-task panel was lost");
  assert(result.data.panel?.recommendations?.length >= 2, "new-task answer lacks recommendations");
  assert(
    result.data.panel.recommendations.some((item) =>
      /Event Viewer|事件查看器/u.test(`${item.title} ${item.detail}`),
    ),
    "new-task answer lacks a system event evidence step",
  );
  assert(
    result.data.panel.recommendations.some((item) => /HWiNFO/u.test(`${item.title} ${item.detail}`)),
    "new-task answer lacks an HWiNFO evidence step",
  );
  assert(result.data.panel.priorityAction?.title, "new-task answer lacks a priority");
  assert(result.data.panel.actions?.length >= 1, "new-task answer lacks executable actions");
  assert(result.data.draft.events.length === 0, "new-task draft was not empty");
  assert(result.data.draft.attachments.length === 0, "sent attachments remained in draft");
  assert(
    result.data.task?.timeline?.some(
      (entry) =>
        entry.role === "user" &&
        entry.attachments?.some((item) => item.id === csvId) &&
        entry.attachments?.some((item) => item.id === pngId),
    ),
    "task timeline lost sent attachments",
  );
  assert(result.data.task?.device_snapshot_ref === reusedDeviceRef, "task lost device reuse");
  assert(
    result.data.task?.evidence_refs?.some((id) => reusedEvidenceIds.includes(id)),
    "task lost shared evidence references",
  );

  const postTaskLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).slice(eventOffset);
  assert(
    postTaskLines.some((line) => line.includes("ui.user_message")),
    "new-task first submission was not a user_message",
  );
  assert(
    postTaskLines.every((line) => !line.includes("ui.panel_submission")),
    "new-task first submission included a stale panel_submission",
  );
  assert(
    postTaskLines.every((line) => !line.includes("gaming-scope")),
    "new-task first submission carried the old gaming-scope selection",
  );
  assert(
    postTaskLines.some((line) => line.includes("agent.panel_updated")),
    "new-task agent update was not logged",
  );
  assert(
    postTaskLines.some(
      (line) =>
        line.includes("attachment_added") &&
        line.includes("gpu-log.csv") &&
        line.includes("sha256") &&
        line.includes("mime_type") &&
        line.includes("size") &&
        line.includes("created_at"),
    ),
    "attachment event log is missing metadata",
  );
  assert(
    postTaskLines.some(
      (line) =>
        line.includes("ui.user_message") &&
        line.includes(csvId) &&
        line.includes(pngId) &&
        line.includes("local_path"),
    ),
    "agent input did not receive local attachment references",
  );
  assert(
    postTaskLines.some(
      (line) =>
        line.includes('"type":"task_submitted"') &&
        line.includes(csvId) &&
        line.includes(pngId),
    ),
    "task submission event did not list committed attachments",
  );
  assert(
    postTaskLines
      .filter((line) => line.includes("ui.user_message"))
      .every((line) => !line.includes(removableId)),
    "deleted attachment entered the agent request",
  );
  assert(
    postTaskLines.some(
      (line) =>
        line.includes("ui.user_message") &&
        line.includes(reusedDeviceRef) &&
        line.includes("task_context"),
    ),
    "new task did not inject compact Skill domain context",
  );

  const recoveredState = await request("/api/state");
  assert(recoveredState.response.ok, "new-task refresh state failed");
  assert(recoveredState.data.thread_id === oldThread, "refresh lost the reused thread");
  assert(recoveredState.data.task?.task_id === newTaskId, "refresh lost the new task");
  assert(
    recoveredState.data.panel?.question?.id === "game-symptom",
    "refresh lost the new-task panel",
  );
  assert(
    recoveredState.data.activity?.agent_summary ===
      recoveredState.data.panel.turn_summary,
    "refresh lost the persisted round record",
  );
  assert(
    recoveredState.data.panel?.schema_version === "1.2",
    "refresh lost the artifact-capable panel schema",
  );

  const beforeAnalysisState = await request("/api/state");
  const analysisThreadId = beforeAnalysisState.data.thread_id;
  const analysisTaskId = beforeAnalysisState.data.task?.task_id;
  const analysisDeviceRef = beforeAnalysisState.data.task?.device_snapshot_ref;

  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: pngId }),
  });
  assert(result.response.status === 415, "non-CSV analysis was not rejected");

  const analysisEventOffset = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).length;
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      warmup_seconds: null,
      duration_seconds: null,
    }),
  });
  assert(
    result.response.status === 403 &&
      result.data.permission_required === true &&
      result.data.state?.task?.permission_request?.status === "pending",
    "unauthorized analysis did not create a permission request",
  );
  const permissionRequestId =
    result.data.state.task.permission_request.request_id;
  const unauthorizedLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).slice(analysisEventOffset);
  assert(
    unauthorizedLines.some((line) =>
      line.includes('"type":"permission.requested"'),
    ) &&
      unauthorizedLines.every(
        (line) =>
          !line.includes('"type":"action.completed"') &&
          !line.includes('"type":"ui.panel_tool_result"') &&
          !line.includes('"type":"agent.panel_updated"'),
      ),
    "permission request ran analysis or started an agent turn",
  );
  const noArtifactAfterRequest = JSON.parse(
    await readFile(join(runtimeDir, "artifacts", "index.json"), "utf8").catch(
      () => '{"artifacts":[]}',
    ),
  );
  assert(
    noArtifactAfterRequest.artifacts.length === 0,
    "permission request created an artifact before approval",
  );

  result = await request("/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: permissionRequestId,
      decision: "deny",
    }),
  });
  assert(
    result.response.ok &&
      result.data.task?.permission_request?.status === "denied",
    "permission denial was not recorded",
  );
  const deniedEventOffset = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).length;
  const deniedPermissionLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).slice(analysisEventOffset, deniedEventOffset);
  assert(
    deniedPermissionLines.some((line) =>
      line.includes('"type":"permission.denied"'),
    ) &&
      deniedPermissionLines.every(
        (line) =>
          !line.includes('"type":"action.completed"') &&
          !line.includes('"type":"ui.panel_tool_result"') &&
          !line.includes('"type":"agent.panel_updated"'),
      ),
    "denied permission ran analysis or started an agent turn",
  );

  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      warmup_seconds: null,
      duration_seconds: null,
    }),
  });
  assert(
    result.response.status === 403 &&
      result.data.state.task.permission_request.request_id !== permissionRequestId,
    "retry after denial did not create a fresh request",
  );
  const approvedRequestId =
    result.data.state.task.permission_request.request_id;
  result = await request("/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: approvedRequestId,
      decision: "allow_once",
    }),
  });
  assert(
    result.response.ok &&
      result.data.task?.permission_request?.status === "approved" &&
      result.data.task?.grants?.some(
        (grant) =>
          grant.request_id === approvedRequestId &&
          grant.scope === "one-time" &&
          grant.status === "active",
      ),
    "one-time permission grant was not created",
  );
  const afterDenialLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).slice(deniedEventOffset);
  assert(
    afterDenialLines.some((line) =>
      line.includes('"type":"permission.granted"'),
    ) &&
      afterDenialLines.every(
        (line) =>
          !line.includes('"type":"action.completed"') &&
          !line.includes('"type":"ui.panel_tool_result"'),
      ),
    "granting permission started analysis before the explicit run",
  );

  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      warmup_seconds: null,
      duration_seconds: null,
    }),
  });
  assert(result.response.ok, `valid CSV analysis failed: ${result.data.error}`);
  assert(result.data.thread_id === analysisThreadId, "analysis changed the Codex thread");
  assert(result.data.task?.task_id === analysisTaskId, "analysis changed the workbench task");
  assert(
    result.data.task?.device_snapshot_ref === analysisDeviceRef,
    "analysis changed the device snapshot reference",
  );
  assert(result.data.panel?.schema_version === "1.2", "analysis panel schema is not 1.2");
  assert(
    result.data.task?.permission_request === null &&
      result.data.task?.grants?.some(
        (grant) =>
          grant.request_id === approvedRequestId &&
          grant.status === "consumed" &&
          grant.scope === "one-time",
      ),
    "one-time capability was not consumed after analysis",
  );
  assert(
    result.data.panel?.artifact_refs?.length === 1,
    "analysis did not attach exactly one chart artifact",
  );
  const artifact = result.data.panel.artifact_refs[0];
  assert(artifact.kind === "chart", "artifact kind is not chart");
  assert(artifact.mime === "image/svg+xml", "artifact MIME is not SVG");
  assert(artifact.safeToEmbed === true, "artifact was not marked safe to embed");
  assert(
    artifact.source_evidence_ids.includes(csvId),
    "artifact does not reference the analyzed CSV evidence",
  );
  assert(
    artifact.relative_path.startsWith(`${analysisTaskId}/`) &&
      !artifact.relative_path.includes("..") &&
      !artifact.relative_path.includes("\\"),
    "artifact relative path is not task-scoped or safe",
  );
  const artifactPath = join(
    runtimeDir,
    "artifacts",
    ...artifact.relative_path.split("/"),
  );
  const artifactBytes = await readFile(artifactPath);
  assert(
    createHash("sha256").update(artifactBytes).digest("hex") === artifact.sha256,
    "artifact SHA-256 does not match stored metadata",
  );
  assert(artifactBytes.toString("utf8").includes("<svg"), "stored artifact is not SVG");
  const allowedBlockTypes = new Set([
    "markdown",
    "metrics",
    "chart",
    "table",
    "callout",
    "artifact-download",
  ]);
  assert(
    result.data.panel.blocks?.length >= 4 &&
      result.data.panel.blocks.every((block) => allowedBlockTypes.has(block.type)),
    "analysis panel contains a non-whitelisted block",
  );
  assert(
    result.data.panel.blocks
      .filter((block) => block.type === "callout" && block.tone === "warning")
      .every((block) => block.collapsed === true),
    "analysis warnings are not collapsed",
  );
  assert(
    result.data.panel.blocks.some(
      (block) =>
        block.type === "chart" && block.artifact_ref === artifact.id,
    ),
    "analysis panel has no verified chart block",
  );
  assert(
    result.data.panel.blocks.some(
      (block) =>
        block.type === "table" &&
        block.rows?.length >= 1 &&
        block.columns?.length === 6,
    ),
    "analysis panel has no verified telemetry table",
  );

  const artifactContent = await fetch(
    `${base}/api/artifacts/${artifact.id}/content`,
    { headers: { Cookie: cookie } },
  );
  assert(artifactContent.ok, "authorized artifact content request failed");
  assert(
    artifactContent.headers.get("content-type") === "image/svg+xml",
    "artifact content type changed",
  );
  assert(
    artifactContent.headers.get("cache-control")?.includes("immutable"),
    "artifact cache policy is not immutable",
  );
  assert((await artifactContent.text()).includes("<svg"), "artifact endpoint returned no SVG");
  const artifactDownload = await fetch(
    `${base}/api/artifacts/${artifact.id}/content?download=1`,
    { headers: { Cookie: cookie } },
  );
  assert(
    artifactDownload.headers.get("content-disposition")?.startsWith("attachment;"),
    "artifact download did not switch to attachment disposition",
  );

  const unauthorizedArtifact = await fetch(
    `${base}/api/artifacts/${artifact.id}/content`,
  );
  assert(
    unauthorizedArtifact.status === 401,
    "artifact endpoint allowed an unauthenticated request",
  );
  const traversalArtifact = await fetch(
    `${base}/api/artifacts/artifact-not-real%2F..%2Fstate.json/content`,
    { headers: { Cookie: cookie } },
  );
  assert(
    traversalArtifact.status === 404,
    "artifact endpoint did not reject a traversal-shaped request",
  );

  const stateAfterArtifact = await request("/api/state");
  assert(
    stateAfterArtifact.data.panel?.artifact_refs?.[0]?.sha256 === artifact.sha256,
    "artifact metadata did not survive refresh",
  );
  assert(
    stateAfterArtifact.data.panel?.blocks?.some((block) => block.type === "metrics"),
    "analysis metrics did not survive refresh",
  );
  const resumePacket = await request("/api/resume-packet");
  assert(
    resumePacket.response.ok,
    `Resume packet generation failed: ${resumePacket.data.error}`,
  );
  assert(
    resumePacket.data.source_thread_id === analysisThreadId &&
      resumePacket.data.task_id === analysisTaskId &&
      resumePacket.data.artifact_refs?.some((item) => item.id === artifact.id),
    "Resume packet lost source task or artifact references",
  );
  for (const heading of [
    "Task：",
    "设备快照：",
    "## 已完成关键证据",
    "## 当前判断",
    "## 未决问题",
    "## 最优先下一步",
    "## 面板引用",
  ]) {
    assert(
      resumePacket.data.markdown?.includes(heading),
      `Resume packet is missing ${heading}`,
    );
  }
  assert(
    !/[A-Za-z]:[\\/]/u.test(resumePacket.data.markdown) &&
      !/capability-token|handoff-secret|local_path|panel_token=\/?[A-Za-z0-9_-]{16,}/u.test(
        resumePacket.data.markdown,
      ) &&
      resumePacket.data.contains_absolute_paths === false &&
      resumePacket.data.contains_raw_transcript === false,
    "Resume packet contains a token, private path, or transcript marker",
  );

  const beforeCachedRepeat = await request("/api/state");
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      warmup_seconds: null,
      duration_seconds: null,
    }),
  });
  assert(result.response.ok, "repeat CSV analysis failed");
  assert(
    result.data.panel?.artifact_refs?.[0]?.id === artifact.id,
    "repeat analysis changed the cached artifact",
  );
  assert(
    result.data.event_count === beforeCachedRepeat.data.event_count &&
      result.data.activity?.turn_id === beforeCachedRepeat.data.activity?.turn_id,
    `cached analysis repeated an agent turn or audit event (before=${beforeCachedRepeat.data.event_count}/${beforeCachedRepeat.data.activity?.turn_id}, after=${result.data.event_count}/${result.data.activity?.turn_id})`,
  );

  const taskScopedWindow = {
    warmup_seconds: 0,
    duration_seconds: 10,
  };
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      ...taskScopedWindow,
    }),
  });
  assert(
    result.response.status === 403 &&
      result.data.state.task.permission_request.status === "pending",
    "different uncached window bypassed permission",
  );
  const taskScopedRequestId =
    result.data.state.task.permission_request.request_id;
  result = await request("/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: taskScopedRequestId,
      decision: "allow_task",
    }),
  });
  assert(
    result.response.ok &&
      result.data.task?.grants?.some(
        (grant) =>
          grant.request_id === taskScopedRequestId &&
          grant.scope === "task" &&
          grant.status === "active",
      ),
    "task-scoped permission grant was not created",
  );
  const taskScopedGrant = result.data.task.grants.find(
    (grant) => grant.request_id === taskScopedRequestId,
  );
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      ...taskScopedWindow,
    }),
  });
  assert(
    result.response.ok &&
      result.data.task?.permission_request === null &&
      result.data.task?.grants?.some(
        (grant) =>
          grant.grant_id === taskScopedGrant.grant_id &&
          grant.status === "active",
      ),
    "task-scoped capability did not authorize the second window",
  );

  result = await request("/api/permissions/revoke", {
    method: "POST",
    body: JSON.stringify({ grant_id: taskScopedGrant.grant_id }),
  });
  assert(
    result.response.ok &&
      result.data.task?.grants?.some(
        (grant) =>
          grant.grant_id === taskScopedGrant.grant_id &&
          grant.status === "revoked",
      ),
    "task-scoped capability could not be revoked",
  );
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({
      attachment_id: csvId,
      warmup_seconds: 1,
      duration_seconds: 2,
    }),
  });
  assert(
    result.response.status === 403 &&
      result.data.state.task.permission_request.status === "pending",
    "revoked capability still authorized analysis",
  );
  const permissionAuditLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  )
    .trim()
    .split(/\r?\n/)
    .filter((line) => line.includes('"type":"permission.'));
  for (const eventType of [
    "permission.requested",
    "permission.granted",
    "permission.denied",
    "permission.revoked",
    "permission.consumed",
  ]) {
    assert(
      permissionAuditLines.some((line) => line.includes(`"type":"${eventType}"`)),
      `permission audit omitted ${eventType}`,
    );
  }
  assert(
    permissionAuditLines.every(
      (line) =>
        !line.includes(handoffSigningSecret) &&
        !line.includes(panelCapabilityToken) &&
        !/[A-Za-z]:[\\/]/u.test(line) &&
        !line.includes("local_path"),
    ),
    "permission audit contains a token or private path",
  );

  const invalidCsvForm = new FormData();
  invalidCsvForm.append(
    "file",
    new Blob(["notes,result\nno numeric sensor,not available\n"], {
      type: "text/csv",
    }),
    "unrecognized.csv",
  );
  result = await request("/api/attachments", {
    method: "POST",
    body: invalidCsvForm,
  });
  assert(result.response.ok, "invalid CSV upload failed");
  const invalidCsvId = result.data.draft.attachments.at(-1).id;
  result = await request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "请把这份无效 CSV 留作证据" }),
  });
  assert(result.response.ok, "invalid CSV could not be committed to the task");
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: invalidCsvId }),
  });
  assert(
    result.response.status === 403 &&
      result.data.state.task.permission_request.status === "pending",
    "invalid CSV bypassed the permission request",
  );
  const invalidRequestId =
    result.data.state.task.permission_request.request_id;
  result = await request("/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: invalidRequestId,
      decision: "allow_once",
    }),
  });
  assert(result.response.ok, "invalid CSV permission could not be granted");
  const invalidEventOffset = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).length;
  result = await request("/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: invalidCsvId }),
  });
  assert(result.response.ok, "invalid CSV should return a deterministic failure panel");
  assert(
    result.data.panel?.artifact_refs?.length === 0,
    "invalid CSV produced a fake chart artifact",
  );
  assert(
    result.data.panel?.blocks?.some(
      (block) =>
        block.type === "callout" &&
        block.tone === "warning" &&
        /无法生成图表/u.test(block.title),
    ),
    "invalid CSV did not return a deterministic failure card",
  );
  assert(
    result.data.thread_id === analysisThreadId &&
      result.data.task?.task_id === analysisTaskId,
    "invalid analysis changed thread or task identity",
  );
  const invalidLines = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/).slice(invalidEventOffset);
  assert(
    invalidLines.some((line) => line.includes('"type":"action.failed"')),
    "invalid analysis failure was not recorded",
  );
  assert(
    invalidLines.every((line) => !line.includes("ui.panel_tool_result")),
    "invalid CSV sent a model tool-result turn",
  );
  assert(
    invalidLines.every((line) => !line.includes("agent.panel_updated")),
    "invalid CSV unexpectedly completed an agent panel turn",
  );
  const artifactIndex = JSON.parse(
    await readFile(join(runtimeDir, "artifacts", "index.json"), "utf8"),
  );
  assert(
    artifactIndex.artifacts.length === 2,
    "invalid analysis added an artifact to the local index",
  );

  result = await request("/api/task/new", {
    method: "POST",
    body: JSON.stringify({}),
  });
  assert(result.response.ok, "could not prepare a completion-only task");
  result = await request("/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "最终结论：只有一款游戏会黑屏和掉帧" }),
  });
  assert(result.response.ok, `completion-only task failed: ${result.data.error}`);
  assert(result.data.panel?.status === "ready", "completion panel status was not ready");
  assert(result.data.panel?.question === null, "completion panel still required an option");
  assert(
    result.data.panel?.recommendations?.length >= 2 &&
      result.data.panel?.actions?.length >= 1 &&
      result.data.panel?.priorityAction?.title,
    "completion panel lacked substantive actions",
  );
  assert(result.data.thread_id === oldThread, "completion-only task changed thread");
  assert(
    result.data.permissions?.profile === "read-only-supervised" &&
      result.data.task?.grants?.length === 0 &&
      result.data.task?.permission_request === null,
    "new Task inherited a capability grant or elevated profile",
  );

  const sharedAfterTasks = JSON.parse(
    await readFile(join(runtimeDir, "shared-evidence.json"), "utf8"),
  );
  assert(
    sharedAfterTasks.device_snapshot.ref === initialDeviceRef,
    "shared device snapshot changed between tasks",
  );
  assert(
    sharedAfterTasks.evidence_refs.length > initialEvidenceIds.length,
    "shared evidence store did not retain evidence added during a task",
  );

  result = await request("/api/thread/new", {
    method: "POST",
    body: JSON.stringify({}),
  });
  assert(result.response.ok, `new independent thread failed: ${result.data.error}`);
  assert(result.data.thread_id !== oldThread, "new independent dialog did not change thread");
  assert(result.data.task === null, "new dialog created a task before the first submission");
  assert(
    result.data.domain_context?.device_snapshot_ref === reusedDeviceRef,
    "new independent dialog did not reuse the shared device snapshot",
  );
  assert(Boolean(result.data.domain_context), "new Session lost its Skill context");

  const stateFile = JSON.parse(await readFile(join(runtimeDir, "state.json"), "utf8"));
  assert(stateFile.thread_id === result.data.thread_id, "persisted state lost the advanced thread");
  assert(
    stateFile.task === null &&
      stateFile.panel === null &&
      stateFile.draft.events.length === 0,
    "advanced-thread task did not start clean",
  );

  await request("/api/shutdown", { method: "POST", body: "{}" });
  await new Promise((resolvePromise) => {
    const timeout = setTimeout(resolvePromise, 2_000);
    child.once("exit", () => {
      clearTimeout(timeout);
      resolvePromise();
    });
  });

  const degradedRuntime = await mkdtemp(
    join(tmpdir(), "agent-panel-degraded-manifest-"),
  );
  const degradedPort = await getAvailablePort();
  const degradedBase = `http://127.0.0.1:${degradedPort}`;
  const degradedChild = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "mock",
      PANEL_PORT: String(degradedPort),
      PANEL_RUNTIME_DIR: degradedRuntime,
      PANEL_SKILL_MANIFEST: join(
        degradedRuntime,
        "missing.manifest.json",
      ),
      PANEL_MANIFEST_ALLOWED_ROOT: degradedRuntime,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let degradedReady = false;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (degradedChild.exitCode !== null) break;
    try {
      const health = await fetch(`${degradedBase}/api/health`);
      if (health.ok) {
        degradedReady = true;
        break;
      }
    } catch {
      // Keep waiting for the fallback server.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  assert(degradedReady, "invalid manifest prevented the server from starting");
  const degradedPage = await fetch(`${degradedBase}/`);
  const degradedCookie = degradedPage.headers.getSetCookie()[0].split(";")[0];
  const degradedHeaders = {
    Cookie: degradedCookie,
    "Content-Type": "application/json",
  };
  let degradedResponse = await fetch(`${degradedBase}/api/state`, {
    headers: degradedHeaders,
  });
  let degradedState = await degradedResponse.json();
  assert(
    degradedResponse.ok &&
      degradedState.skill?.status === "fallback" &&
      degradedState.skill?.error?.code === "manifest_path_missing",
    "missing manifest did not expose a safe compatibility fallback",
  );
  degradedResponse = await fetch(`${degradedBase}/api/submit`, {
    method: "POST",
    headers: degradedHeaders,
    body: JSON.stringify({ free_text: "没有 Manifest 时仍可纯聊天" }),
  });
  degradedState = await degradedResponse.json();
  assert(
    degradedResponse.ok &&
      degradedState.task?.task_id &&
      degradedState.panel?.turn_summary,
    "missing manifest blocked the Task/composer/chat fallback",
  );
  await fetch(`${degradedBase}/api/shutdown`, {
    method: "POST",
    headers: degradedHeaders,
    body: "{}",
  });
  await new Promise((resolvePromise) => {
    const timeout = setTimeout(resolvePromise, 2_000);
    degradedChild.once("exit", () => {
      clearTimeout(timeout);
      resolvePromise();
    });
  });

  const genericRuntime = await mkdtemp(
    join(tmpdir(), "agent-panel-generic-demo-"),
  );
  const genericPort = await getAvailablePort();
  const genericBase = `http://127.0.0.1:${genericPort}`;
  const genericManifest = join(
    root,
    "skills",
    "generic-demo",
    "workbench.manifest.json",
  );
  async function startGenericServer() {
    const serverProcess = spawn(process.execPath, ["server.mjs"], {
      cwd: root,
      windowsHide: true,
      env: {
        ...process.env,
        PANEL_AGENT_DRIVER: "mock",
        PANEL_PORT: String(genericPort),
        PANEL_RUNTIME_DIR: genericRuntime,
        PANEL_SKILL_MANIFEST: genericManifest,
        PANEL_SKILL_ID: "generic-demo",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let ready = false;
    for (let attempt = 0; attempt < 60; attempt += 1) {
      if (serverProcess.exitCode !== null) break;
      try {
        const health = await fetch(`${genericBase}/api/health`);
        if (health.ok) {
          ready = true;
          break;
        }
      } catch {
        // Wait for the Generic Demo runtime.
      }
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    }
    assert(ready, "Generic Demo server did not start");
    return serverProcess;
  }
  async function stopServerProcess(serverProcess) {
    const page = await fetch(`${genericBase}/`);
    const serverCookie = page.headers.getSetCookie()[0].split(";")[0];
    await fetch(`${genericBase}/api/shutdown`, {
      method: "POST",
      headers: {
        Cookie: serverCookie,
        "Content-Type": "application/json",
      },
      body: "{}",
    });
    await new Promise((resolvePromise) => {
      const timeout = setTimeout(resolvePromise, 2_000);
      serverProcess.once("exit", () => {
        clearTimeout(timeout);
        resolvePromise();
      });
    });
  }

  let genericChild = await startGenericServer();
  let genericPage = await fetch(`${genericBase}/`);
  let genericCookie = genericPage.headers.getSetCookie()[0].split(";")[0];
  let genericHeaders = {
    Cookie: genericCookie,
    "Content-Type": "application/json",
  };
  let genericResponse = await fetch(`${genericBase}/api/state`, {
    headers: genericHeaders,
  });
  let genericState = await genericResponse.json();
  assert(
    genericState.skill?.id === "generic-demo" &&
      genericState.skill?.runtime_id === "generic-demo" &&
      genericState.skill?.status === "active",
    "Generic Demo Skill was not selected",
  );
  genericResponse = await fetch(
    `${genericBase}/api/skill/actions/unknown.capability`,
    {
      method: "POST",
      headers: genericHeaders,
      body: JSON.stringify({ attachment_id: "attachment-unknown" }),
    },
  );
  assert(
    genericResponse.status === 404,
    "undeclared Skill capability was not rejected",
  );
  genericResponse = await fetch(`${genericBase}/api/submit`, {
    method: "POST",
    headers: genericHeaders,
    body: JSON.stringify({ free_text: "Choose a concise output." }),
  });
  genericState = await genericResponse.json();
  assert(
    genericResponse.ok &&
      genericState.panel?.schema_version === "1.2" &&
      genericState.panel?.question?.options?.length === 2 &&
      genericState.panel?.question?.prompt &&
      genericState.task?.skill?.skill_id === "generic-demo" &&
      genericState.task?.skill?.runtime_id === "generic-demo" &&
      !/device_snapshot|telemetry|hardware/iu.test(
        JSON.stringify(genericState.panel),
      ),
    "Generic Demo did not complete a provider-free Task turn",
  );
  const genericForm = new FormData();
  genericForm.append(
    "file",
    new Blob(["A generic text input for the demo artifact.\n"], {
      type: "text/plain",
    }),
    "demo-input.txt",
  );
  genericResponse = await fetch(`${genericBase}/api/attachments`, {
    method: "POST",
    headers: { Cookie: genericCookie },
    body: genericForm,
  });
  genericState = await genericResponse.json();
  assert(genericResponse.ok, "Generic Demo text upload failed");
  genericResponse = await fetch(`${genericBase}/api/submit`, {
    method: "POST",
    headers: genericHeaders,
    body: JSON.stringify({ free_text: "Create the text artifact now." }),
  });
  genericState = await genericResponse.json();
  const genericAttachment = genericState.task?.attachments?.find(
    (item) => item.original_name === "demo-input.txt",
  );
  assert(genericAttachment, "Generic Demo attachment was not committed");
  genericResponse = await fetch(
    `${genericBase}/api/skill/actions/demo.text.export`,
    {
      method: "POST",
      headers: genericHeaders,
      body: JSON.stringify({ attachment_id: genericAttachment.id }),
    },
  );
  genericState = await genericResponse.json();
  const genericArtifact = genericState.task?.artifacts?.[0];
  assert(
    genericResponse.ok &&
      genericArtifact?.kind === "text" &&
      genericState.panel?.artifact_refs?.some(
        (item) => item.id === genericArtifact.id,
      ),
    "Generic Demo local action did not produce a Task artifact",
  );
  genericResponse = await fetch(
    `${genericBase}/api/artifacts/${genericArtifact.id}/content`,
    { headers: { Cookie: genericCookie } },
  );
  const genericArtifactText = await genericResponse.text();
  assert(
    genericResponse.ok &&
      genericArtifactText.includes("Generic Workbench Demo") &&
      genericArtifactText.includes("demo-input.txt"),
    "Generic Demo artifact was not delivered",
  );
  genericResponse = await fetch(`${genericBase}/api/resume-packet`, {
    headers: genericHeaders,
  });
  const genericResume = await genericResponse.json();
  assert(
    genericResponse.ok &&
      genericResume.markdown?.includes("Generic Decision Demo") &&
      genericResume.artifact_refs?.some(
        (item) => item.id === genericArtifact.id,
      ),
    "Generic Demo Resume/export lost the active Skill or artifact",
  );
  const persistedGenericSkill = genericState.skill;
  await stopServerProcess(genericChild);
  genericChild = await startGenericServer();
  genericPage = await fetch(`${genericBase}/`);
  genericCookie = genericPage.headers.getSetCookie()[0].split(";")[0];
  genericHeaders = {
    Cookie: genericCookie,
    "Content-Type": "application/json",
  };
  genericResponse = await fetch(`${genericBase}/api/state`, {
    headers: genericHeaders,
  });
  genericState = await genericResponse.json();
  assert(
    genericResponse.ok &&
      genericState.skill?.id === persistedGenericSkill.id &&
      genericState.skill?.runtime_id === persistedGenericSkill.runtime_id &&
      genericState.skill?.manifest_hash === persistedGenericSkill.manifest_hash &&
      genericState.task?.artifacts?.some(
        (item) => item.id === genericArtifact.id,
      ),
    "active Skill identity or artifact was not restored across restart",
  );
  await stopServerProcess(genericChild);

  const expiryRuntime = await mkdtemp(join(tmpdir(), "agent-panel-expiry-"));
  const expiryTaskId = "task-expiry-smoke";
  const expiredGrant = {
    schema_version: "1.0",
    grant_id: "grant-expired-smoke",
    status: "active",
    scope: "task",
    capability: "telemetry.csv.analyze",
    profile: "read-only-supervised",
    task_id: expiryTaskId,
    attachment_id: "attachment-expired-smoke",
    attachment_sha256: "c".repeat(64),
    artifact_root_ref: artifactRootRef(expiryTaskId),
    window: { warmup_seconds: null, duration_seconds: null },
    window_signature: "all",
    network: "disabled",
    general_command: "unavailable",
    system_write: "unavailable",
    created_at: "2026-11-15T00:00:00.000Z",
    expires_at: "2026-11-15T00:01:00.000Z",
    consumed_at: null,
    revoked_at: null,
    expired_at: null,
    request_id: "permission-request-expired",
  };
  const expiryNow = new Date().toISOString();
  await writeFile(
    join(expiryRuntime, "state.json"),
    `${JSON.stringify(
      {
        schema_version: "1.0",
        owner: "app-owned",
        thread_id: null,
        thread_name: null,
        thread_recovered: null,
        task: {
          task_id: expiryTaskId,
          objective: "Expired grant restart smoke",
          device_snapshot_ref: "device-snapshot:smoke-2026-11-13",
          evidence_refs: ["evidence-smoke-seed"],
          attachments: [],
          artifacts: [],
          analyses: [],
          capability_profile: defaultCapabilityProfile(expiryTaskId),
          grants: [expiredGrant],
          permission_request: null,
          timeline: [],
          phase: "ready",
          summary: "",
          last_turn: null,
        },
        phase: "ready",
        panel: null,
        draft: { events: [], attachments: [] },
        error: null,
        last_turn: null,
        activity: null,
        handoff: null,
        handoff_consumed_nonces: [],
        created_at: expiryNow,
        updated_at: expiryNow,
        event_count: 0,
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  await writeFile(
    join(expiryRuntime, "shared-evidence.json"),
    `${JSON.stringify(
      {
        schema_version: "1.0",
        store_id: "expiry-device-store",
        device_snapshot: {
          ref: "device-snapshot:smoke-2026-11-13",
          captured_date: "2026-11-13",
          identity_quality: "smoke-confirmed",
          privacy_mode: "local-private",
          device_alias: "Expiry Test PC",
          summary: "Expired grant restart fixture.",
        },
        evidence_refs: [
          {
            id: "evidence-smoke-seed",
            kind: "configuration",
            label: "Seed",
            captured_at: "2026-11-13T12:00:00+08:00",
            sha256: "seed",
          },
        ],
      },
      null,
      2,
    )}\n`,
    "utf8",
  );
  const expiryPort = await getAvailablePort();
  const expiryBase = `http://127.0.0.1:${expiryPort}`;
  const expiryChild = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "mock",
      PANEL_PORT: String(expiryPort),
      PANEL_RUNTIME_DIR: expiryRuntime,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let expiryStderr = "";
  expiryChild.stderr.on("data", (chunk) => {
    expiryStderr += chunk.toString();
  });
  let expiryReady = false;
  for (let attempt = 0; attempt < 60; attempt += 1) {
    if (expiryChild.exitCode !== null) {
      break;
    }
    try {
      const health = await fetch(`${expiryBase}/api/health`);
      if (health.ok) {
        expiryReady = true;
        break;
      }
    } catch {
      // Listener is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  assert(
    expiryReady,
    `expired-grant restart server failed: ${expiryStderr}`,
  );
  const expiryEvents = (
    await readFile(join(expiryRuntime, "events.jsonl"), "utf8")
  ).trim().split(/\r?\n/);
  assert(
    expiryEvents.some(
      (line) =>
        line.includes('"type":"permission.expired"') &&
        line.includes("grant-expired-smoke"),
    ),
    "expired grant did not append permission.expired on restart",
  );
  const expiryState = JSON.parse(
    await readFile(join(expiryRuntime, "state.json"), "utf8"),
  );
  assert(
    expiryState.task.grants[0].status === "expired",
    "expired grant remained active after restart",
  );
  const expiryToken = (
    await readFile(join(expiryRuntime, "capability-token"), "utf8")
  ).trim();
  assert(
    expiryEvents.every(
      (line) =>
        !line.includes(expiryToken) &&
        !/[A-Za-z]:[\\/]/u.test(line),
    ),
    "permission.expired audit contains a token or absolute path",
  );
  await fetch(`${expiryBase}/api/shutdown`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${expiryToken}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  }).catch(() => {});
  await new Promise((resolvePromise) => {
    const timeout = setTimeout(resolvePromise, 2_000);
    expiryChild.once("exit", () => {
      clearTimeout(timeout);
      resolvePromise();
    });
  });

  process.stdout.write(
    "PASS: installed-Skill discovery from explicit and standard-like roots, runtime containment/import failure fallback, active Skill persistence, Generic Demo Task/composer/text artifact/Resume flow, PC Workbench runtime parity, scoped capability grants, provider/domain-free neutral core, legacy Session migration, authenticated artifact delivery, refresh/restart recovery, and advanced Session creation\n",
  );
} catch (error) {
  if (child.exitCode === null) {
    child.kill();
  }
  process.stderr.write(`${error.stack ?? error}\n\nSERVER STDOUT\n${stdout}\nSERVER STDERR\n${stderr}\n`);
  process.exitCode = 1;
}
