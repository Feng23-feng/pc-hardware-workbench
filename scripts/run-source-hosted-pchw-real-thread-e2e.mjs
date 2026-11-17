import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
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
import { CodexAgentDriver } from "../lib/agents/codex-agent-driver.mjs";
import { signHandoffToken } from "../lib/handoff-capability.mjs";
import {
  parseStructuredOutput,
} from "../lib/panel-response.mjs";
import {
  validatePanelState,
} from "../lib/schema-validation.mjs";
import {
  PRODUCTION_PROFILE,
  evaluateRuntimeProfile,
} from "../contracts/source-hosted-shared-task/v1/persistence/production-profile.mjs";
import { createRestartableServer } from "./restartable-server.mjs";
import {
  terminateChildAndWait,
  waitForChildExit,
  waitForPidGone,
} from "./child-process-lifecycle.mjs";
import {
  computeSkillTreeIdentity,
} from "./skill-tree-identity.mjs";
import {
  installSingleThreadRequestGuard,
} from "./single-thread-request-guard.mjs";

const root = resolve(import.meta.dirname, "..");
const planPath = join(
  root,
  "work",
  "SOURCE-HOSTED-PCHW-CONTROLLED-REAL-THREAD-PLAN-2026-11-17.md",
);
const expectedPlanSha256 =
  "cf000a7f66483272cb57096472c038acd295dd17cfb808569323ec77cc62eb7e";
const evidenceDir = join(
  root,
  "work",
  "pchw-real-thread-evidence-2026-11-17",
);
const evidencePath = join(
  evidenceDir,
  "pchw-real-thread-evidence.json",
);
const installedSkillRoot =
  process.env.PCHW_INSTALLED_SKILL_ROOT ||
  join(
    process.env.USERPROFILE ?? process.env.HOME ?? "",
    ".codex",
    "skills",
    "pc-hardware-workbench",
  );
const skillManifest = join(
  installedSkillRoot,
  "workbench.manifest.json",
);
const serverLifecycle = createRestartableServer(startServer);
const runStartedAt = new Date();
const timeoutEvents = [];
const phaseTransitions = [];
const r0Checks = {};
const r9Checks = {};
let executionStarted = false;
let driver = null;
let server = null;
let runtimeDir = null;
let workspace = null;
let fixtureDirsBefore = new Set();
let taskHash = null;
let channelHash = null;
let sourceSessionHash = null;
let threadReferenceHash = null;
let turnIdHash = null;
let csvSha256 = null;
let artifactSha256 = null;
let panelSha256 = null;
let sourceThreadCount = 0;
let sourceTurnCount = 0;
let panelTurnCount = 0;
let toolEventCount = 0;
let restartCount = 0;
let phaseAtEntry = null;
let finalPhase = null;
let pageVisible = false;
let conclusionVisible = false;
let chartVisible = false;
let postRestartTaskRestored = false;
let postRestartChartRestored = false;
let credentialCrossoverRejected = false;
let redactionPassed = false;
let csvRows = 0;
let metricCount = 0;
let artifactCount = 0;
let chartBlockCount = 0;
let abortReason = null;
let cancelAttempted = false;
let currentTurnId = null;
let turnStarted = false;
let turnCompleted = false;
let threadCreated = false;
let driverClosed = false;
let serverClosed = false;
let serverCloseFailure = null;
let tempRuntimeRemoved = false;
let tempWorkspaceRemoved = false;

const csvText = [
  "Date,Time,GPU Temperature [C],GPU Power [W],GPU Effective Clock [MHz],GPU Fan [RPM],FPS,PerfCap",
  "2026-11-17,20:00:00,73,301,2670,1760,118,Pwr",
  "2026-11-17,20:05:00,77,312,2655,1810,116,Pwr",
  "2026-11-17,20:10:00,81,305,2630,1880,109,Pwr",
  "2026-11-17,20:15:00,84,278,2410,1980,92,Therm",
  "2026-11-17,20:20:00,86,221,2070,2100,74,Therm",
  "2026-11-17,20:25:00,87,188,1840,2180,63,Therm",
  "2026-11-17,20:30:00,86,181,1795,2170,61,Therm",
  "2026-11-17,20:35:00,85,176,1760,2140,59,Therm",
].join("\n");
const hardwareProblem =
  "4K 高画质游戏约 20 分钟后明显掉帧；GPU 功耗下降、有效频率降低、" +
  "温度接近上限。请判断这份受控 HWiNFO fixture 显示的主要趋势、" +
  "不确定性，以及下一步应优先补采哪些证据。";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
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
    plan_sha256: expectedPlanSha256,
    node_version: process.versions.node,
    sqlite_version: process.versions.sqlite,
    profile_id: PRODUCTION_PROFILE.profile_id,
    task_hash: taskHash,
    channel_hash: channelHash,
    source_session_hash: sourceSessionHash,
    thread_reference_hash: threadReferenceHash,
    turn_id_hash: turnIdHash,
    csv_sha256: csvSha256,
    artifact_sha256: artifactSha256,
    panel_sha256: panelSha256,
    phase_transitions: phaseTransitions,
    task_count: taskHash ? 1 : 0,
    source_thread_count: sourceThreadCount,
    source_turn_count: sourceTurnCount,
    panel_turn_count: panelTurnCount,
    tool_event_count: toolEventCount,
    restart_count: restartCount,
    csv_rows: csvRows,
    metric_count: metricCount,
    artifact_count: artifactCount,
    chart_block_count: chartBlockCount,
    page_visible: pageVisible,
    conclusion_visible: conclusionVisible,
    chart_visible: chartVisible,
    post_restart_task_restored: postRestartTaskRestored,
    post_restart_chart_restored: postRestartChartRestored,
    credential_crossover_rejected: credentialCrossoverRejected,
    redaction_passed: redactionPassed,
    phase_at_entry: phaseAtEntry,
    final_phase: finalPhase,
    timeout_events: timeoutEvents,
    abort_reason: abortReason,
    r0: r0Checks,
    fixture_cleanup: r9Checks,
    boundaries: {
      default_traffic_enabled: false,
      formal_ui_launcher_wired: false,
      recovery_enabled: false,
      production_release: false,
    },
  };
  await mkdir(evidenceDir, { recursive: true });
  await writeFile(
    evidencePath,
    `${JSON.stringify(evidence, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
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

async function startServer() {
  const port = await freePort();
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_APPROVAL_POLICY: "never",
      PANEL_AGENT_DRIVER: "source-external",
      PANEL_AGENT_SANDBOX: "read-only",
      PANEL_AGENT_WORKSPACE: workspace,
      PANEL_PORT: String(port),
      PANEL_RUNTIME_DIR: runtimeDir,
      PANEL_SKILL_ID: "pc-hardware-workbench",
      PANEL_SKILL_MANIFEST: skillManifest,
      PANEL_SOURCE_HOSTED_ENTRY: "1",
      PANEL_SOURCE_HOSTED_NON_MOCK: "1",
      PANEL_SOURCE_HOSTED_SHADOW: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 16_384) stderr += chunk.toString();
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`PCHW real-thread server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        return {
          baseUrl,
          child,
          async close() {
            if (child.exitCode === null && child.signalCode === null) {
              const masterToken = (
                await readFile(join(runtimeDir, "capability-token"), "utf8")
              ).trim();
              const gracefulExit = waitForChildExit(child);
              await fetch(`${baseUrl}/api/shutdown`, {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${masterToken}`,
                  "Content-Type": "application/json",
                },
                body: "{}",
                signal: AbortSignal.timeout(5_000),
              }).catch(() => {});
              try {
                await gracefulExit;
              } catch {
                await terminateChildAndWait(child);
              }
            }
            await waitForPidGone(child.pid);
          },
        };
      }
    } catch {
      // Server is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  child.kill();
  throw new Error(`PCHW real-thread server timeout: ${stderr}`);
}

async function fetchWithTimeout(url, options = {}, timeoutMs = 15_000) {
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
  String(
    process.env.SOURCE_HOSTED_PCHW_REAL_THREAD_AUTHORIZATION ?? "",
  ) !== "1"
) {
  process.stderr.write(
    "SOURCE_HOSTED_PCHW_REAL_THREAD_AUTHORIZATION=1 is required; " +
      "no run started.\n",
  );
  process.exit(2);
}
if (existsSync(evidencePath)) {
  process.stderr.write(
    "PCHW real-thread evidence already exists; refusing a second run.\n",
  );
  process.exit(3);
}

let status = "aborted_preflight";
try {
  const planSha256 = createHash("sha256")
    .update(await readFile(planPath))
    .digest("hex");
  assert.equal(planSha256, expectedPlanSha256);
  r0Checks.plan_hash_matches = true;
  r0Checks.authorization_acknowledged = true;
  r0Checks.authorized_runs_remaining = 1;
  r0Checks.execution_started_before_r1 = false;
  r0Checks.node = process.versions.node;
  r0Checks.sqlite = process.versions.sqlite;
  const runtimeGate = evaluateRuntimeProfile({
    databaseSyncAvailable: true,
  });
  assert.equal(runtimeGate.ok, true);
  r0Checks.runtime_profile_gate = true;

  fixtureDirsBefore = await fixtureDirectories();
  runtimeDir = await mkdtemp(join(tmpdir(), "skilldock-pchw-real-runtime-"));
  workspace = await mkdtemp(join(tmpdir(), "skilldock-pchw-real-workspace-"));
  assert.equal(existsSync(runtimeDir), true);
  assert.equal(existsSync(workspace), true);
  r0Checks.isolated_runtime = true;
  r0Checks.isolated_workspace = true;

  server = await serverLifecycle.start();
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
  assert.equal(new Set([masterToken, panelToken, sourceToken]).size, 3);
  r0Checks.credentials_distinct = true;

  let response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: { Authorization: `Bearer ${masterToken}` } },
  );
  assert.equal(response.status, 200);
  let state = await response.json();
  assert.equal(state.agent.driver, "source-external");
  assert.equal(state.agent.thread_id, null);
  assert.equal(state.task.shared_task ?? null, null);
  assert.equal(state.task.sync ?? null, null);
  assert.equal(state.skill.skill_id, "pc-hardware-workbench");
  r0Checks.no_panel_thread = true;
  r0Checks.no_active_source_hosted_task = true;
  r0Checks.active_skill = "pc-hardware-workbench";

  driver = new CodexAgentDriver({
    cwd: workspace,
    timeoutMs: 90_000,
    permissionProfile: {
      sandbox: "read-only",
      approvalPolicy: "never",
      source: "environment",
    },
  });
  assert.equal(driver.capabilities.supportsActiveThreadAttach, false);
  assert.equal(driver.capabilities.supportsThreadResume, true);
  assert.equal(driver.permissionProfile.sandbox, "read-only");
  assert.equal(driver.permissionProfile.approvalPolicy, "never");
  r0Checks.codex_attach_disabled = true;
  r0Checks.sandbox_read_only = true;
  r0Checks.approval_never = true;
  r0Checks.budget =
    "1 Task / 1 new Thread / 1 source Turn / 0 panel Turn / " +
    "180s total / 90s Turn";

  executionStarted = true;
  status = "running";
  await writeEvidence(status);
  const executionDeadline = Date.now() + 180_000;
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
  installSingleThreadRequestGuard(driver, {
    onThreadStarted: () => {
      sourceThreadCount += 1;
    },
    onTurnStarted: (result) => {
      sourceTurnCount += 1;
      turnStarted = true;
      currentTurnId = result.turn.id;
    },
    onBlocked: (error) => {
      abortReason = abortReason ?? error.code;
    },
  });
  const originalResumeThread = driver.resumeThread.bind(driver);
  driver.resumeThread = async () => {
    void originalResumeThread;
    throw Object.assign(new Error("resume is forbidden"), {
      code: "thread_resume_forbidden",
    });
  };

  const thread = await driver.startThread();
  threadCreated = true;
  sourceSessionHash = sha256(thread.threadReference);
  threadReferenceHash = sourceSessionHash;
  assert.equal(sourceThreadCount, 1);
  await driver.setThreadName(
    "SkillDock PCHW controlled real-thread E2E 2026-11-17",
  );

  const sourceSessionRef = thread.threadReference;
  const taskId = "task-pchw-real-thread-20261117-001";
  const channelId = `chat:source-hosted:${sourceSessionRef}`;
  taskHash = sha256(taskId);
  channelHash = sha256(channelId);
  const signed = signHandoffToken({
    thread_id: sourceSessionRef,
    environment_thread_id: sourceSessionRef,
    task_id: taskId,
    objective: "PCHW 受控真实 Thread 单 Task 端到端验收",
    summary: "单 CSV、单本地图表、单真实模型 Turn。",
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
  assert.match(response.headers.get("set-cookie") ?? "", /panel_token=/u);
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  state = await response.json();
  phaseAtEntry = state.task.shared_task.phase;
  assert.equal(phaseAtEntry, "source_owned");
  phaseTransitions.push("source_owned");

  const csvForm = new FormData();
  csvForm.append(
    "file",
    new Blob([csvText], { type: "text/csv" }),
    "controlled-hwinfo-stutter.csv",
  );
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/attachments`,
    {
      method: "POST",
      headers: panelHeaders(panelToken),
      body: csvForm,
    },
  );
  assert.equal(response.status, 200);
  state = await response.json();
  assert.equal(state.draft.attachments.length, 1);
  const csvId = state.draft.attachments[0].id;
  csvSha256 = state.draft.attachments[0].sha256;
  assert.equal(
    csvSha256,
    sha256(Buffer.from(csvText, "utf8")),
  );

  response = await fetchWithTimeout(
    `${server.baseUrl}/api/submit`,
    {
      method: "POST",
      headers: panelHeaders(panelToken, { json: true }),
      body: JSON.stringify({ free_text: hardwareProblem }),
    },
  );
  assert.equal(response.status, 200);
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "waiting_for_source_pull");
  assert.equal(state.task.attachments[0].id, csvId);
  phaseTransitions.push("waiting_for_source_pull");
  assertBudget();

  response = await fetchWithTimeout(
    `${server.baseUrl}/api/artifacts/analyze`,
    {
      method: "POST",
      headers: panelHeaders(panelToken, { json: true }),
      body: JSON.stringify({ attachment_id: csvId }),
    },
  );
  assert.equal(response.status, 403);
  state = await response.json();
  assert.equal(state.permission_required, true);
  const requestId = state.state.task.permission_request.request_id;
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/permissions/decide`,
    {
      method: "POST",
      headers: panelHeaders(panelToken, { json: true }),
      body: JSON.stringify({
        request_id: requestId,
        decision: "allow_once",
      }),
    },
  );
  assert.equal(response.status, 200);
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/artifacts/analyze`,
    {
      method: "POST",
      headers: panelHeaders(panelToken, { json: true }),
      body: JSON.stringify({ attachment_id: csvId }),
    },
    30_000,
  );
  assert.equal(response.status, 202);
  state = await response.json();
  assert.equal(state.source_hosted_pending, true);
  assert.equal(state.state.task.shared_task.source_tool_result, undefined);
  assert.equal(state.state.activity.status, "waiting_for_source");
  const sourceSubmission = state.state.task.timeline.find(
    (entry) =>
      entry.source === "source_hosted_intent" &&
      (entry.attachments ?? []).some(
        (attachment) => attachment.id === csvId,
      ),
  );
  assert.ok(sourceSubmission);

  response = await fetchWithTimeout(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: sourceHeaders(sourceToken, sourceSessionRef) },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.shared_task.phase, "waiting_for_source_pull");
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
        intent_event_id: sourceSubmission.external_id,
        submission_sequence: sourceSubmission.seq,
        attachment_id: csvId,
        attachment_sha256: csvSha256,
        require_source_result: true,
      }),
    },
  );
  assert.equal(response.status, 200);
  const claim = await response.json();
  assert.equal(claim.phase, "source_agent_pulled");
  exported.shared_task.phase = claim.phase;
  phaseTransitions.push("source_agent_pulled");
  assert.ok(exported.source_tool_result?.packet?.tool_result?.analysis);
  const exportText = JSON.stringify(exported);
  assert.equal(exportText.includes("local_path"), false);
  assert.equal(/[A-Za-z]:\\/u.test(exportText), false);
  const localResult = exported.source_tool_result.result;
  csvRows = localResult.analysis.analyzed_rows;
  metricCount = localResult.analysis.metrics.length;
  assert.ok(csvRows >= 8);
  assert.ok(metricCount >= 3);
  assertBudget();

  const sourcePacket = {
    ...exported.source_tool_result.packet,
    type: "panel_tool_result",
    user_intent: hardwareProblem,
    fixture_scope:
      "Controlled HWiNFO-compatible fixture; not telemetry from the user's PC.",
  };
  const manifest = JSON.parse(
    (await readFile(skillManifest, "utf8")).replace(/^\uFEFF/u, ""),
  );
  delete manifest.$schema;
  const stateSchema = JSON.parse(
    await readFile(
      join(installedSkillRoot, "schemas", "ui-state.schema.json"),
      "utf8",
    ),
  );
  assert.ok(stateSchema);
  assert.ok(manifest);

  const turn = await driver.sendTurn({
    threadReference: thread.threadReference,
    eventId: `pchw-source-event-${randomUUID()}`,
    packet: sourcePacket,
    structuredOutputSchema: stateSchema,
  });
  turnCompleted = true;
  turnIdHash = sha256(turn.turnId);
  assert.equal(sourceTurnCount, 1);
  assert.equal(sourceThreadCount, 1);
  if (abortReason === "tool_event_observed") {
    throw Object.assign(new Error("tool event observed"), {
      code: "tool_event_observed",
    });
  }
  assertBudget();

  const rawPanel =
    turn.structuredOutput ?? parseStructuredOutput(turn.finalText);
  const panel = validatePanelState(rawPanel);
  assert.ok(panel.judgement.length >= 40);
  assert.ok(panel.turn_summary.length >= 10);

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
        objective: "PCHW 受控真实 Thread 单 Task 端到端验收",
        summary: panel.turn_summary,
        messages: [{
          id: `pchw-real-result-${sha256(turn.turnId).slice(0, 24)}`,
          role: "agent",
          text: panel.judgement,
          created_at: new Date().toISOString(),
        }],
        panel,
      }),
    },
    30_000,
  );
  assert.equal(response.status, 200);
  const imported = await response.json();
  assert.equal(imported.shared_task_phase, "source_result_synced");
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
  assert.equal(state.task.attachments[0].sha256, csvSha256);
  assert.equal(state.task.shared_task.source_tool_result, undefined);
  assert.equal(state.last_turn, null);
  assert.equal(state.agent.thread_id, null);
  assert.equal(state.panel.artifact_refs.length, 1);
  artifactCount = state.panel.artifact_refs.length;
  chartBlockCount = state.panel.blocks.filter(
    (block) => block.type === "chart",
  ).length;
  assert.equal(chartBlockCount, 1);
  chartVisible = chartBlockCount === 1;
  conclusionVisible = (
    state.panel.judgement.length >= 40 &&
    state.task.timeline.some(
      (entry) => entry.role === "agent" && entry.text.length >= 40,
    )
  );
  assert.equal(conclusionVisible, true);
  const artifact = state.panel.artifact_refs[0];
  artifactSha256 = artifact.sha256;
  panelSha256 = sha256(JSON.stringify(state.panel));
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/artifacts/${artifact.id}/content`,
    { headers: panelHeaders(panelToken) },
  );
  assert.equal(response.status, 200);
  const svg = Buffer.from(await response.arrayBuffer());
  assert.equal(sha256(svg), artifactSha256);
  assert.match(svg.toString("utf8", 0, 512), /<svg\b/u);

  response = await fetchWithTimeout(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: panelHeaders(panelToken) },
  );
  const panelExportStatus = response.status;
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: { Authorization: `Bearer ${sourceToken}` } },
  );
  const sourceStateStatus = response.status;
  credentialCrossoverRejected = (
    panelExportStatus === 403 &&
    sourceStateStatus === 403
  );
  assert.equal(credentialCrossoverRejected, true);
  const serializedState = JSON.stringify(state);
  assert.equal(serializedState.includes(sourceToken), false);
  assert.equal(/[A-Za-z]:\\/u.test(serializedState), false);
  redactionPassed = true;

  await driver.close();
  driverClosed = true;
  driver = null;
  await serverLifecycle.close();
  serverClosed = true;
  server = null;
  restartCount += 1;

  server = await serverLifecycle.start();
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  state = await response.json();
  postRestartTaskRestored = (
    state.task.task_id === taskId &&
    state.task.shared_task.phase === "source_result_synced" &&
    state.task.attachments[0]?.sha256 === csvSha256
  );
  postRestartChartRestored = (
    state.panel?.artifact_refs?.[0]?.sha256 === artifactSha256 &&
    sha256(JSON.stringify(state.panel)) === panelSha256
  );
  assert.equal(postRestartTaskRestored, true);
  assert.equal(postRestartChartRestored, true);
  response = await fetchWithTimeout(
    `${server.baseUrl}/api/artifacts/${artifact.id}/content`,
    { headers: panelHeaders(panelToken) },
  );
  assert.equal(response.status, 200);
  assert.equal(
    sha256(Buffer.from(await response.arrayBuffer())),
    artifactSha256,
  );

  status = "passed";
} catch (error) {
  if (executionStarted) {
    const code = String(error?.code ?? error?.name ?? "");
    status =
      turnStarted &&
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
    abortReason = String(error?.code ?? error?.name ?? "preflight_error");
  }
} finally {
  if (driver && !driverClosed) {
    try {
      await driver.close();
    } catch {
      // Best effort only.
    }
    driverClosed = true;
  }
  try {
    await serverLifecycle.close();
  } catch {
    serverCloseFailure = "server_close_failed";
    if (status === "passed") {
      status = "aborted";
      abortReason = serverCloseFailure;
    }
  } finally {
    serverClosed = !serverLifecycle.isOpen;
  }
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  const fixtureDirsAfter = await fixtureDirectories();
  const leaked = [...fixtureDirsAfter].filter(
    (name) => !fixtureDirsBefore.has(name),
  );
  r9Checks.new_fixture_residual = leaked.length;
  r9Checks.thread_created = threadCreated;
  r9Checks.thread_count = sourceThreadCount;
  r9Checks.source_turn_count = sourceTurnCount;
  r9Checks.panel_turn_count = panelTurnCount;
  r9Checks.driver_closed = driverClosed;
  r9Checks.server_closed = serverClosed;
  r9Checks.server_close_failure = serverCloseFailure;
  await rm(runtimeDir, { recursive: true, force: true }).catch(() => {});
  await rm(workspace, { recursive: true, force: true }).catch(() => {});
  tempRuntimeRemoved = !existsSync(runtimeDir);
  tempWorkspaceRemoved = !existsSync(workspace);
  r9Checks.temp_runtime_removed = tempRuntimeRemoved;
  r9Checks.temp_workspace_removed = tempWorkspaceRemoved;
  if (leaked.length > 0 || !tempRuntimeRemoved || !tempWorkspaceRemoved) {
    if (!abortReason) abortReason = "fixture_residual";
    if (status === "passed") status = "aborted";
  }
  await writeEvidence(status);
}

process.stdout.write(`${JSON.stringify({
  execution_started: executionStarted,
  status,
  authorization_acknowledged: true,
  authorized_runs_remaining: executionStarted ? 0 : 1,
  source_thread_count: sourceThreadCount,
  task_count: taskHash ? 1 : 0,
  source_turn_count: sourceTurnCount,
  panel_turn_count: panelTurnCount,
  tool_event_count: toolEventCount,
  restart_count: restartCount,
  phase_transitions: phaseTransitions,
  final_phase: finalPhase,
  csv_sha256: csvSha256,
  artifact_sha256: artifactSha256,
  panel_sha256: panelSha256,
  conclusion_visible: conclusionVisible,
  chart_visible: chartVisible,
  post_restart_task_restored: postRestartTaskRestored,
  post_restart_chart_restored: postRestartChartRestored,
  abort_reason: abortReason,
  evidence_path: evidencePath,
})}\n`);
if (status !== "passed") process.exitCode = 1;
