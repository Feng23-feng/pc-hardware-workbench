import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
} from "node:fs";
import {
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  CodexAgentDriver,
} from "../lib/agents/codex-agent-driver.mjs";
import {
  signHandoffToken,
} from "../lib/handoff-capability.mjs";
import {
  PRODUCTION_PROFILE,
  evaluateRuntimeProfile,
} from "../contracts/source-hosted-shared-task/v1/persistence/production-profile.mjs";

const root = resolve(import.meta.dirname, "..");
const planPath = join(
  root,
  "work",
  "SOURCE-HOSTED-SHARED-TASK-V1-CONTROLLED-REAL-THREAD-TEST-PLAN.md",
);
const expectedPlanSha256 =
  "88519f3dc9af82f6e19238328cfc20139af5b72aac6510bda59341dc4f6ddc4d";
const evidenceDir = join(
  root,
  "work",
  "real-thread-evidence-2026-11-17",
);
const evidencePath = join(evidenceDir, "real-thread-evidence.json");
const runStartedAt = new Date();
const timeoutEvents = [];
let executionStarted = false;
let driver = null;
let server = null;
let runtimeDir = null;
let workspace = null;
let fixtureDirsBefore = new Set();
let taskHash = null;
let sourceSessionHash = null;
let channelHash = null;
let threadReferenceHash = null;
let turnIdHash = null;
let intentCount = 0;
let agentResultCount = 0;
let sourceTurnCount = 0;
let panelTurnCount = 0;
let pageVisible = false;
let abortReason = null;
let cancelAttempted = false;
let finalPhase = null;
let currentTurnId = null;
let toolEventCount = 0;
let turnCompleted = false;
const phaseTransitions = [];
const r0Checks = {};
const r8Checks = {};

function sha256(value) {
  return createHash("sha256").update(String(value), "utf8").digest("hex");
}

async function writeEvidence(status) {
  const completedAt = new Date();
  const evidence = {
    schema_version: "1.0",
    status,
    authorization_acknowledged: true,
    authorized_runs_remaining: executionStarted ? 0 : 1,
    execution_started: executionStarted,
    started_at: runStartedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    duration_ms: completedAt.getTime() - runStartedAt.getTime(),
    node_version: process.versions.node,
    sqlite_version: process.versions.sqlite,
    profile_id: PRODUCTION_PROFILE.profile_id,
    task_hash: taskHash,
    source_session_hash: sourceSessionHash,
    channel_hash: channelHash,
    thread_reference_hash: threadReferenceHash,
    turn_id_hash: turnIdHash,
    phase_transitions: phaseTransitions,
    intent_count: intentCount,
    agent_result_count: agentResultCount,
    source_turn_count: sourceTurnCount,
    panel_turn_count: panelTurnCount,
    page_visible: pageVisible,
    tool_event_count: toolEventCount,
    timeout_events: timeoutEvents,
    abort_reason: abortReason,
    fixture_cleanup: r8Checks,
  };
  await mkdir(evidenceDir, { recursive: true });
  await writeFile(
    evidencePath,
    `${JSON.stringify(evidence, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  return evidencePath;
}

async function fixtureDirectories() {
  return new Set(
    (await readdir(tmpdir(), { withFileTypes: true }))
      .filter(
        (entry) =>
          entry.isDirectory() &&
          entry.name.startsWith("skilldock-sqlite-fixture-"),
      )
      .map((entry) => entry.name),
  );
}

async function freePort() {
  return new Promise((resolvePromise, rejectPromise) => {
    const server = createTcpServer();
    server.once("error", rejectPromise);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port =
        address && typeof address === "object" ? address.port : null;
      server.close((error) => {
        if (error) rejectPromise(error);
        else resolvePromise(port);
      });
    });
  });
}

async function startSkillDockServer() {
  const port = await freePort();
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "mock",
      PANEL_AGENT_SANDBOX: "read-only",
      PANEL_AGENT_APPROVAL_POLICY: "never",
      PANEL_PORT: String(port),
      PANEL_RUNTIME_DIR: runtimeDir,
      PANEL_AGENT_WORKSPACE: workspace,
      PANEL_SKILL_MANIFEST: join(
        root,
        "skills",
        "generic-demo",
        "workbench.manifest.json",
      ),
      PANEL_SKILL_ID: "generic-demo",
      PANEL_SOURCE_HOSTED_ENTRY: "1",
      PANEL_SOURCE_HOSTED_SHADOW: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 16_384) stderr += chunk.toString();
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`SkillDock preflight server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        return {
          child,
          baseUrl,
          async close() {
            if (child.exitCode === null) {
              await fetch(`${baseUrl}/api/shutdown`, {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${
                    (
                      await readFile(
                        join(runtimeDir, "capability-token"),
                        "utf8",
                      )
                    ).trim()
                  }`,
                  "Content-Type": "application/json",
                },
                body: "{}",
              }).catch(() => {});
              await Promise.race([
                new Promise((resolvePromise) => {
                  child.once("exit", resolvePromise);
                }),
                new Promise((resolvePromise) =>
                  setTimeout(resolvePromise, 5_000)),
              ]);
            }
            if (child.exitCode === null) child.kill();
          },
        };
      }
    } catch {
      // R0 server is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  child.kill();
  throw new Error(`SkillDock preflight server timeout: ${stderr}`);
}

async function fetchWithTimeout(url, options = {}, timeoutMs = 10_000) {
  return fetch(url, {
    ...options,
    signal: AbortSignal.timeout(timeoutMs),
  });
}

function panelHeaders(panelToken, { json = false } = {}) {
  return {
    Cookie: `panel_token=${encodeURIComponent(panelToken)}`,
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

function sourceHeaders(sourceToken, sourceSessionRef, { json = false } = {}) {
  return {
    Authorization: `Bearer ${sourceToken}`,
    "X-Source-Session-Ref": sourceSessionRef,
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

if (
  String(process.env.SOURCE_HOSTED_REAL_THREAD_AUTHORIZATION ?? "") !== "1"
) {
  process.stderr.write(
    "SOURCE_HOSTED_REAL_THREAD_AUTHORIZATION=1 is required; no run started.\n",
  );
  process.exit(2);
}
if (existsSync(evidencePath)) {
  process.stderr.write(
    "real-thread evidence already exists; refusing a second run.\n",
  );
  process.exit(3);
}

let status = "aborted_preflight";
try {
  const planBytes = await readFile(planPath);
  const planSha256 = createHash("sha256")
    .update(planBytes)
    .digest("hex");
  r0Checks.plan_hash_matches = planSha256 === expectedPlanSha256;
  assert.equal(planSha256, expectedPlanSha256);
  r0Checks.authorization_acknowledged = true;
  r0Checks.authorized_runs_remaining = 1;
  r0Checks.execution_started_before_r1 = false;
  r0Checks.node = process.versions.node;
  r0Checks.sqlite = process.versions.sqlite;
  const runtimeGate = evaluateRuntimeProfile({
    databaseSyncAvailable: true,
  });
  r0Checks.runtime_profile_gate = runtimeGate.ok;
  assert.equal(runtimeGate.ok, true);

  fixtureDirsBefore = await fixtureDirectories();
  runtimeDir = await mkdtemp(join(tmpdir(), "skilldock-real-thread-runtime-"));
  workspace = await mkdtemp(join(tmpdir(), "skilldock-real-thread-workspace-"));
  r0Checks.temp_runtime_created = existsSync(runtimeDir);
  r0Checks.temp_workspace_created = existsSync(workspace);
  server = await startSkillDockServer();
  const masterToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const panelToken = (
    await readFile(join(runtimeDir, "panel-capability-token"), "utf8")
  ).trim();
  const sourceToken = (
    await readFile(join(runtimeDir, "source-capability-token"), "utf8")
  ).trim();
  const handoffSecret = (
    await readFile(join(runtimeDir, "handoff-secret"), "utf8")
  ).trim();
  r0Checks.credentials_distinct =
    new Set([masterToken, panelToken, sourceToken]).size === 3;
  assert.equal(r0Checks.credentials_distinct, true);
  let response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: { Authorization: `Bearer ${masterToken}` } },
  );
  assert.equal(response.status, 200);
  let state = await response.json();
  r0Checks.no_active_source_hosted_task =
    state.task?.shared_task == null;
  assert.equal(r0Checks.no_active_source_hosted_task, true);

  driver = new CodexAgentDriver({
    cwd: workspace,
    timeoutMs: 60_000,
    permissionProfile: {
      sandbox: "read-only",
      approvalPolicy: "never",
      source: "environment",
    },
  });
  r0Checks.codex_attach_disabled =
    driver.capabilities.supportsActiveThreadAttach === false;
  r0Checks.sandbox_read_only =
    driver.permissionProfile.sandbox === "read-only";
  r0Checks.approval_never =
    driver.permissionProfile.approvalPolicy === "never";
  r0Checks.budget =
    "1 Task / 1 Thread / 1 panel intent / 1 Turn / 120s total / 60s Turn";
  assert.equal(r0Checks.codex_attach_disabled, true);
  assert.equal(r0Checks.sandbox_read_only, true);
  assert.equal(r0Checks.approval_never, true);

  executionStarted = true;
  status = "running";
  await writeEvidence(status);
  const executionDeadline = Date.now() + 120_000;
  const assertBudget = () => {
    if (Date.now() > executionDeadline) {
      timeoutEvents.push("total_budget_exceeded");
      throw Object.assign(new Error("total budget exceeded"), {
        code: "total_budget_exceeded",
      });
    }
  };

  await driver.initialize();
  const originalHandleLine = driver.handleLine.bind(driver);
  driver.handleLine = (line) => {
    try {
      const message = JSON.parse(line);
      const itemType = message?.params?.item?.type;
      if (
        /commandExecution|fileChange|mcpToolCall|webSearch|toolCall/u.test(
          String(itemType ?? ""),
        ) ||
        /tool|command|fileChange/u.test(String(message?.method ?? ""))
      ) {
        toolEventCount += 1;
        if (!abortReason) abortReason = "tool_event_observed";
        const turnId =
          message?.params?.turnId ?? message?.params?.turn?.id;
        if (turnId) {
          currentTurnId = turnId;
          cancelAttempted = true;
          driver.cancel(turnId).catch(() => {});
        }
      }
    } catch {
      // Preserve protocol parsing in the driver.
    }
    originalHandleLine(line);
  };
  const originalRequest = driver.request.bind(driver);
  driver.request = async (method, params, timeoutMs) => {
    const result = await originalRequest(method, params, timeoutMs);
    if (method === "turn/start") {
      sourceTurnCount += 1;
      currentTurnId = result.turn.id;
    }
    return result;
  };

  const thread = await driver.startThread();
  threadReferenceHash = sha256(thread.threadReference);
  await driver.setThreadName(
    "SkillDock source_hosted real-thread E2E 2026-11-17",
  );

  const taskId = "task-real-thread-e2e-001";
  const sourceSessionRef = thread.threadReference;
  const channelId = `chat:source-hosted:${sourceSessionRef}`;
  taskHash = sha256(taskId);
  sourceSessionHash = sha256(sourceSessionRef);
  channelHash = sha256(channelId);
  const signed = signHandoffToken({
    thread_id: sourceSessionRef,
    task_id: taskId,
    objective: "受控真实 Thread 单 Task E2E",
    summary: "一次性 app-owned Thread，单 panel intent，单模型 Turn。",
    domain_state: {},
    domain_refs: [],
    read_only: true,
    source: "agent-skill",
  }, handoffSecret, { ttlSeconds: 120 });
  response = await fetchWithTimeout(
    `${server.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(signed.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 303);
  const cookie = response.headers.get("set-cookie") ?? "";
  const panelCookieMatch = cookie.match(/panel_token=([^;]+)/u);
  assert.ok(panelCookieMatch);
  assert.equal(
    decodeURIComponent(panelCookieMatch[1]),
    panelToken,
  );
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "source_owned");
  phaseTransitions.push("source_owned");

  response = await fetchWithTimeout(
    `${server.baseUrl}/api/event`,
    {
      method: "POST",
      headers: panelHeaders(panelToken, { json: true }),
      body: JSON.stringify({
        type: "evidence_added",
        label: "one-shot intent",
        detail: "Read the supplied Task intent and acknowledge it once.",
        source: "user_reported",
      }),
    },
  );
  assert.equal(response.status, 200);
  intentCount = 1;
  state = await response.json();
  assert.equal(
    state.task.shared_task.phase,
    "waiting_for_source_pull",
  );
  phaseTransitions.push("waiting_for_source_pull");

  response = await fetchWithTimeout(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    {
      headers: sourceHeaders(sourceToken, sourceSessionRef),
    },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.shared_task.phase, "waiting_for_source_pull");
  const exportedIntent = exported.messages.find(
    (message) => message.source === "source_hosted_intent",
  );
  assert.ok(exportedIntent);
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(
        sourceToken,
        sourceSessionRef,
        { json: true },
      ),
      body: JSON.stringify({
        schema_version: "1.0",
        task_ref: taskId,
        channel_id: channelId,
        source_session_ref: sourceSessionRef,
        intent_event_id: exportedIntent.external_id,
        submission_sequence: exportedIntent.seq,
        attachment_id: "",
        attachment_sha256: "",
        require_source_result: false,
      }),
    },
  );
  assert.equal(response.status, 200);
  const claim = await response.json();
  assert.equal(claim.phase, "source_agent_pulled");
  exported.shared_task.phase = claim.phase;
  assert.equal(
    exported.messages.filter(
      (message) => message.source === "source_hosted_intent",
    ).length,
    1,
  );
  phaseTransitions.push("source_agent_pulled");
  assertBudget();

  const turn = await driver.sendTurn({
    threadReference: thread.threadReference,
    eventId: "source-hosted-real-thread-event-001",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: [
        "SOURCE_HOSTED_E2E_ONE_SHOT",
        "Read this sanitized Task intent and return one short acknowledgement.",
        "Do not use tools, inspect files, create artifacts, or modify settings.",
        exported.messages.find(
          (message) => message.source === "source_hosted_intent",
        ).text,
      ].join("\n"),
    },
    structuredOutputSchema: null,
  });
  turnCompleted = true;
  turnIdHash = sha256(turn.turnId);
  if (abortReason === "tool_event_observed") {
    throw Object.assign(new Error("tool event observed"), {
      code: "tool_event_observed",
    });
  }
  assert.equal(sourceTurnCount, 1);
  assertBudget();

  const resultId =
    `real-thread-result-${sha256(turn.turnId).slice(0, 24)}`;
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        sourceToken,
        sourceSessionRef,
        { json: true },
      ),
      body: JSON.stringify({
        schema_version: "1.0",
        channel_id: channelId,
        source_session_ref: sourceSessionRef,
        objective: state.task.objective,
        summary: state.task.summary,
        messages: [{
          id: resultId,
          role: "agent",
          text: turn.finalText.slice(0, 4000),
          created_at: new Date().toISOString(),
        }],
      }),
    },
  );
  assert.equal(response.status, 200);
  const imported = await response.json();
  assert.equal(imported.imported_count, 1);
  assert.equal(imported.shared_task_phase, "source_result_synced");
  agentResultCount = 1;
  phaseTransitions.push("source_result_synced");
  finalPhase = "source_result_synced";

  response = await fetchWithTimeout(`${server.baseUrl}/`);
  pageVisible = response.status === 200;
  assert.equal(pageVisible, true);
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  state = await response.json();
  assert.equal(state.task.shared_task.phase, finalPhase);
  assert.equal(state.panel, null);
  assert.equal(state.last_turn, null);
  assert.ok(
    state.task.timeline.some((entry) => entry.external_id === resultId),
  );
  assert.equal(
    JSON.stringify(state).includes(sourceToken),
    false,
  );
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: panelHeaders(panelToken) },
  );
  assert.equal(response.status, 403);
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: { Authorization: `Bearer ${sourceToken}` } },
  );
  assert.equal(response.status, 403);
  panelTurnCount = 0;
  status = "passed";
} catch (error) {
  if (executionStarted) {
    const code = String(error?.code ?? error?.name ?? "");
    status =
      sourceTurnCount > 0 &&
      !turnCompleted &&
      abortReason !== "tool_event_observed"
        ? "delivery_unknown"
        : "aborted";
    abortReason = abortReason ?? (code || "execution_error");
    if (currentTurnId && !cancelAttempted) {
      cancelAttempted = true;
      await driver?.cancel(currentTurnId).catch(() => {});
    }
  } else {
    status = "aborted_preflight";
    abortReason = String(error?.code ?? error?.message ?? error);
  }
} finally {
  try {
    await driver?.close();
  } catch {
    // Best effort only.
  }
  try {
    await server?.close();
  } catch {
    // Best effort only.
  }
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  const fixtureDirsAfter = await fixtureDirectories();
  const leaked = [...fixtureDirsAfter].filter(
    (name) => !fixtureDirsBefore.has(name),
  );
  r8Checks.new_fixture_residual = leaked.length;
  r8Checks.driver_closed =
    !driver ||
    driver.child?.exitCode !== null ||
    driver.child?.signalCode !== null;
  r8Checks.server_closed =
    !server ||
    server.child?.exitCode !== null ||
    server.child?.signalCode !== null;
  await rm(runtimeDir, { recursive: true, force: true }).catch(() => {});
  await rm(workspace, { recursive: true, force: true }).catch(() => {});
  r8Checks.temp_runtime_removed = !existsSync(runtimeDir);
  r8Checks.temp_workspace_removed = !existsSync(workspace);
  if (leaked.length > 0 && !abortReason) {
    abortReason = "fixture_residual";
    status = "aborted";
  }
  await writeEvidence(status);
}

process.stdout.write(`${JSON.stringify({
  execution_started: executionStarted,
  status,
  authorization_acknowledged: true,
  authorized_runs_remaining: executionStarted ? 0 : 1,
  r0_passed: Object.values(r0Checks).every(
    (value) => value !== false,
  ),
  r8: r8Checks,
  source_thread_count: threadReferenceHash ? 1 : 0,
  task_count: taskHash ? 1 : 0,
  panel_intent_count: intentCount,
  source_turn_count: sourceTurnCount,
  panel_turn_count: panelTurnCount,
  turn_completed: turnCompleted,
  tool_event_count: toolEventCount,
  phase_transitions: phaseTransitions,
  final_phase: finalPhase,
  abort_reason: abortReason,
  evidence_path: evidencePath,
})}\n`);
if (status !== "passed") process.exitCode = 1;
