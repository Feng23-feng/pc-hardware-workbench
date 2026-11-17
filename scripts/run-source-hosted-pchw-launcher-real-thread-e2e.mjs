import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { CodexAgentDriver } from "../lib/agents/codex-agent-driver.mjs";
import { MockAgentDriver } from "../lib/agents/mock-agent-driver.mjs";
import { signHandoffToken } from "../lib/handoff-capability.mjs";
import { parseStructuredOutput } from "../lib/panel-response.mjs";
import { validatePanelState } from "../lib/schema-validation.mjs";
import {
  PRODUCTION_PROFILE,
  evaluateRuntimeProfile,
} from "../contracts/source-hosted-shared-task/v1/persistence/production-profile.mjs";
import {
  processExists,
  waitForPidGone,
} from "./child-process-lifecycle.mjs";
import { createRestartableServer } from "./restartable-server.mjs";
import { capturePchwBrowserEvidence } from "./pchw-browser-evidence.mjs";
import {
  computeSkillTreeIdentity,
} from "./skill-tree-identity.mjs";
import {
  installSingleThreadRequestGuard,
} from "./single-thread-request-guard.mjs";

const root = resolve(import.meta.dirname, "..");
const dryRun =
  String(process.env.SOURCE_HOSTED_PCHW_FINAL_DRY_RUN ?? "") === "1";
const planPath = join(
  root,
  "work",
  "SOURCE-HOSTED-PCHW-LAUNCHER-REAL-THREAD-FINAL-PLAN-2026-11-17.md",
);
const expectedPlanSha256 =
  "db11aba9370a62971a039eca696661b71f00c9488ab8d445c7c89de8ff5c511d";
const pchwSkillRoot = join(
  root,
  "..",
  "pc-hardware-workbench",
  "skill",
  "pc-hardware-workbench",
);
const pchwInstaller = join(
  root,
  "..",
  "pc-hardware-workbench",
  "tools",
  "install-skill.ps1",
);
const evidenceDir = join(
  root,
  "work",
  dryRun
    ? "pchw-launcher-runner-dry-run-2026-11-17"
    : "pchw-launcher-real-thread-evidence-2026-11-17",
);
const evidencePath = join(
  evidenceDir,
  dryRun
    ? "pchw-launcher-runner-dry-run-evidence.json"
    : "pchw-launcher-real-thread-evidence.json",
);
const runStartedAt = new Date();
const timeoutEvents = [];
const phaseTransitions = [];
const r0Checks = {};
const r9Checks = {};
const serverLifecycle = createRestartableServer(startLauncher);
let executionStarted = false;
let driver = null;
let launcher = null;
let runtimeDir = null;
let workspace = null;
let tempRoot = null;
let nodeBundle = null;
let packageDirectory = null;
let archivePath = null;
let launcherPath = null;
let launcherEnv = null;
let installedSkillsRoot = null;
let installedSkillRoot = null;
let installedSkillIdentity = null;
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
let launcherRestartCount = 0;
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
let currentTurnId = null;
let turnStarted = false;
let turnCompleted = false;
let threadCreated = false;
let driverClosed = false;
let serverClosed = false;
let serverCloseFailure = null;
let beforeRestartBrowser = null;
let afterRestartBrowser = null;

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
  "温度接近上限。请判断受控 HWiNFO fixture 的主要趋势、不确定性，" +
  "以及下一步应优先补采哪些证据。";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function runProcess(command, args, {
  env = process.env,
  timeoutMs = 120_000,
} = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: root,
      env,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    const timer = setTimeout(() => {
      child.kill();
      rejectPromise(new Error(`process timed out: ${command}`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr });
    });
  });
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

async function isHealthy(url) {
  try {
    const response = await fetch(
      `${String(url).replace(/\/$/u, "")}/api/health`,
      { signal: AbortSignal.timeout(2_000) },
    );
    return response.ok;
  } catch {
    return false;
  }
}

async function waitForLaunchResult(previousUrl = null) {
  const resultPath = join(launcher.localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      const result = JSON.parse(
        (await readFile(resultPath, "utf8")).replace(/^\uFEFF/u, ""),
      );
      if (
        result.ok &&
        result.url &&
        result.url !== previousUrl &&
        await isHealthy(result.url)
      ) {
        return result;
      }
    } catch {
      // Launcher is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  throw new Error("launcher did not produce a healthy launch result");
}

async function startLauncher() {
  await rm(join(launcher.localRoot, "launch-result.json"), { force: true });
  const started = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: launcherEnv });
  if (started.code !== 0) {
    throw new Error("launcher failed to start");
  }
  const launchResult = await waitForLaunchResult();
  const serverInfo = JSON.parse(
    (await readFile(
      join(launcher.localRoot, "runtime-dsh-web", "server-info.json"),
      "utf8",
    )).replace(/^\uFEFF/u, ""),
  );
  const handle = {
    baseUrl: launchResult.url.replace(/\/$/u, ""),
    url: launchResult.url,
    driver: launchResult.driver,
    pid: serverInfo.pid,
    async close() {
      const stopped = await runProcess(
        launcherPath,
        ["--stop", "--silent"],
        { env: launcherEnv, timeoutMs: 30_000 },
      );
      if (stopped.code !== 0) {
        throw new Error("launcher failed to stop");
      }
      if (await isHealthy(launchResult.url)) {
        throw new Error("launcher server remained healthy after stop");
      }
      await waitForPidGone(serverInfo.pid);
    },
  };
  return handle;
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

async function buildLauncherPackage() {
  tempRoot = await mkdtemp(join(tmpdir(), "skilldock-pchw-launcher-final-"));
  workspace = join(tempRoot, "workspace");
  nodeBundle = join(tempRoot, "node-runtime");
  installedSkillsRoot = join(tempRoot, "installed-skills");
  installedSkillRoot = join(
    installedSkillsRoot,
    "pc-hardware-workbench",
  );
  const localRoot = join(tempRoot, "local-app-data", "SkillDock");
  runtimeDir = join(localRoot, "runtime-dsh-web");
  packageDirectory = join(
    root,
    "dist",
    `.pchw-launcher-final-${randomUUID()}`,
  );
  archivePath = `${packageDirectory}.zip`;
  await Promise.all([
    mkdir(workspace, { recursive: true }),
    mkdir(nodeBundle, { recursive: true }),
  ]);
  await copyFile(process.execPath, join(nodeBundle, "node.exe"));
  const licenseCandidates = [
    process.env.SKILLDOCK_NODE_LICENSE,
    join(dirname(process.execPath), "LICENSE"),
    join(
      root,
      "..",
      "pc-hardware-workbench",
      "work",
      "node22",
      "node-v22.23.4-win-x64",
      "LICENSE",
    ),
  ].filter(Boolean);
  const licenseSource = licenseCandidates.find((item) => existsSync(item));
  assert.ok(licenseSource, "Node LICENSE is required");
  await copyFile(licenseSource, join(nodeBundle, "LICENSE"));
  const built = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(root, "launcher", "build-dsh-package.ps1"),
      "-OutputDirectory",
      packageDirectory,
      "-ArchivePath",
      archivePath,
    ],
    {
      env: {
        ...process.env,
        SKILLDOCK_NODE_DIR: nodeBundle,
      },
    },
  );
  assert.equal(built.code, 0);
  launcherPath = join(packageDirectory, "SkillDock.exe");
  assert.equal(existsSync(launcherPath), true);
  const installed = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      pchwInstaller,
      "-SourceDirectory",
      pchwSkillRoot,
      "-Destination",
      installedSkillRoot,
      "-BackupRoot",
      join(tempRoot, "skill-backups"),
      "-Force",
    ],
  );
  assert.equal(installed.code, 0);
  installedSkillIdentity = await computeSkillTreeIdentity(
    installedSkillRoot,
  );
  const installedInfo = JSON.parse(
    (
      await readFile(
        join(installedSkillRoot, "INSTALL-INFO.json"),
        "utf8",
      )
    ).replace(/^\uFEFF/u, ""),
  );
  assert.equal(
    installedInfo.TreeSha256,
    installedSkillIdentity.tree_sha256,
  );
  assert.equal(
    installedInfo.TreeFileCount,
    installedSkillIdentity.tree_file_count,
  );
  launcher = { localRoot };
  launcherEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    SKILLDOCK_AGENT_DRIVER: "source-external",
    SKILLDOCK_INTERNAL_PREVIEW: "1",
    SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK: "1",
    SKILLDOCK_SKILL_ROOTS: installedSkillsRoot,
    NODE_NO_WARNINGS: "1",
  };
}

async function writeEvidence(status) {
  const completedAt = new Date();
  await mkdir(evidenceDir, { recursive: true });
  const evidence = {
    schema_version: "1.0",
    status,
    dry_run: dryRun,
    authorization_acknowledged: true,
    authorized_runs_remaining:
      dryRun ? 1 : executionStarted ? 0 : 1,
    execution_started: executionStarted,
    started_at: runStartedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    duration_ms: completedAt.getTime() - runStartedAt.getTime(),
    plan_sha256: expectedPlanSha256,
    node_version: process.versions.node,
    sqlite_version: process.versions.sqlite,
    profile_id: PRODUCTION_PROFILE.profile_id,
    installed_skill_tree_sha256:
      installedSkillIdentity?.tree_sha256 ?? null,
    installed_skill_tree_file_count:
      installedSkillIdentity?.tree_file_count ?? null,
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
    source_thread_count: dryRun ? 0 : sourceThreadCount,
    source_turn_count: dryRun ? 0 : sourceTurnCount,
    panel_turn_count: panelTurnCount,
    tool_event_count: dryRun ? 0 : toolEventCount,
    launcher_restart_count: launcherRestartCount,
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
    before_restart_browser: beforeRestartBrowser,
    after_restart_browser: afterRestartBrowser,
    phase_at_entry: phaseAtEntry,
    final_phase: finalPhase,
    timeout_events: timeoutEvents,
    abort_reason: abortReason,
    r0: r0Checks,
    fixture_cleanup: r9Checks,
    boundaries: {
      formal_default_entry_enabled: false,
      default_traffic_enabled: false,
      recovery_enabled: false,
      production_release: false,
    },
  };
  await writeFile(
    evidencePath,
    `${JSON.stringify(evidence, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
}

if (!dryRun && String(
  process.env.SOURCE_HOSTED_PCHW_LAUNCHER_REAL_THREAD_AUTHORIZATION ?? "",
) !== "1") {
  process.stderr.write(
    "SOURCE_HOSTED_PCHW_LAUNCHER_REAL_THREAD_AUTHORIZATION=1 required.\n",
  );
  process.exit(2);
}
if (!dryRun && existsSync(evidencePath)) {
  process.stderr.write("final PCHW evidence already exists; refusing rerun.\n");
  process.exit(3);
}

let status = "aborted_preflight";
try {
  const planSha = createHash("sha256")
    .update(await readFile(planPath))
    .digest("hex");
  assert.equal(planSha, expectedPlanSha256);
  r0Checks.plan_hash_matches = true;
  r0Checks.dry_run = dryRun;
  r0Checks.authorization_acknowledged = true;
  r0Checks.authorized_runs_remaining = dryRun ? 1 : 1;
  r0Checks.node = process.versions.node;
  r0Checks.sqlite = process.versions.sqlite;
  const profileGate = evaluateRuntimeProfile({
    databaseSyncAvailable: true,
  });
  assert.equal(profileGate.ok, true);
  r0Checks.runtime_profile_gate = true;
  fixtureDirsBefore = await fixtureDirectories();
  await buildLauncherPackage();
  r0Checks.launcher_package_built = true;
  r0Checks.isolated_runtime = existsSync(tempRoot);
  r0Checks.installed_skill_tree_sha256 =
    installedSkillIdentity.tree_sha256;
  r0Checks.installed_skill_tree_file_count =
    installedSkillIdentity.tree_file_count;
  r0Checks.source_skill_root_used = false;
  serverLifecycle; // Initialized before package paths are available.
  let server = await serverLifecycle.start();
  assert.equal(server.driver, "source-external");
  r0Checks.launcher_source_external = true;
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
  let response = await fetch(`${server.baseUrl}/api/state`, {
    headers: { Authorization: `Bearer ${masterToken}` },
  });
  assert.equal(response.status, 200);
  let state = await response.json();
  assert.equal(state.agent.thread_id, null);
  assert.equal(state.skill.skill_id, "pc-hardware-workbench");
  r0Checks.no_panel_thread = true;
  r0Checks.active_skill = "pc-hardware-workbench";

  if (!dryRun) {
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
    assert.equal(driver.permissionProfile.sandbox, "read-only");
    assert.equal(driver.permissionProfile.approvalPolicy, "never");
    r0Checks.codex_attach_disabled = true;
    r0Checks.sandbox_read_only = true;
    r0Checks.approval_never = true;
  }
  r0Checks.budget =
    "1 Task / 1 new Thread / 1 source Turn / 0 panel Turn / 180s";

  executionStarted = !dryRun;
  status = "running";
  if (!dryRun) await writeEvidence(status);
  const deadline = Date.now() + 180_000;
  const assertBudget = () => {
    if (Date.now() > deadline) {
      timeoutEvents.push("total_budget_exceeded");
      throw Object.assign(new Error("total budget exceeded"), {
        code: "total_budget_exceeded",
      });
    }
  };

  let sourceSessionRef;
  let sourceAgent;
  if (dryRun) {
    sourceSessionRef = randomUUID();
    sourceAgent = new MockAgentDriver();
    await sourceAgent.initialize();
    await sourceAgent.startThread();
  } else {
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
          abortReason = abortReason ?? "tool_event_observed";
          const turnId =
            message?.params?.turnId ?? message?.params?.turn?.id;
          if (turnId) {
            currentTurnId = turnId;
            driver.cancel(turnId).catch(() => {});
          }
        }
      } catch {
        // Preserve driver parsing.
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
    driver.resumeThread = async () => {
      throw Object.assign(new Error("resume forbidden"), {
        code: "thread_resume_forbidden",
      });
    };
    const thread = await driver.startThread();
    threadCreated = true;
    sourceSessionRef = thread.threadReference;
    sourceSessionHash = sha256(sourceSessionRef);
    threadReferenceHash = sourceSessionHash;
    await driver.setThreadName(
      "SkillDock PCHW launcher final real-thread 2026-11-17",
    );
    assert.equal(sourceThreadCount, 1);
    sourceAgent = driver;
  }

  const taskId = "task-pchw-launcher-final-20261117";
  const channelId = `chat:source-hosted:${sourceSessionRef}`;
  taskHash = sha256(taskId);
  channelHash = sha256(channelId);
  const signed = signHandoffToken({
    thread_id: sourceSessionRef,
    environment_thread_id: sourceSessionRef,
    task_id: taskId,
    objective: "PCHW launcher Internal Preview final mock/real confirmation",
    summary: "Single Task, single CSV, local chart, one source Turn.",
    domain_state: {},
    domain_refs: [],
    read_only: true,
    source: "agent-skill",
  }, handoffSecret, { ttlSeconds: 120 });
  response = await fetch(
    `${server.baseUrl}/source-hosted/open?token=${encodeURIComponent(signed.token)}`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 303);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
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
  response = await fetch(`${server.baseUrl}/api/attachments`, {
    method: "POST",
    headers: panelHeaders(panelToken),
    body: csvForm,
  });
  assert.equal(response.status, 200);
  state = await response.json();
  const csvId = state.draft.attachments[0].id;
  csvSha256 = state.draft.attachments[0].sha256;
  assert.equal(csvSha256, sha256(Buffer.from(csvText, "utf8")));

  response = await fetch(`${server.baseUrl}/api/submit`, {
    method: "POST",
    headers: panelHeaders(panelToken, { json: true }),
    body: JSON.stringify({ free_text: hardwareProblem }),
  });
  assert.equal(response.status, 200);
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "waiting_for_source_pull");
  phaseTransitions.push("waiting_for_source_pull");

  response = await fetch(`${server.baseUrl}/api/artifacts/analyze`, {
    method: "POST",
    headers: panelHeaders(panelToken, { json: true }),
    body: JSON.stringify({ attachment_id: csvId }),
  });
  assert.equal(response.status, 403);
  state = await response.json();
  const requestId = state.state.task.permission_request.request_id;
  response = await fetch(`${server.baseUrl}/api/permissions/decide`, {
    method: "POST",
    headers: panelHeaders(panelToken, { json: true }),
    body: JSON.stringify({ request_id: requestId, decision: "allow_once" }),
  });
  assert.equal(response.status, 200);
  response = await fetch(`${server.baseUrl}/api/artifacts/analyze`, {
    method: "POST",
    headers: panelHeaders(panelToken, { json: true }),
    body: JSON.stringify({ attachment_id: csvId }),
  });
  assert.equal(response.status, 202);
  state = await response.json();
  assert.equal(state.source_hosted_pending, true);
  const sourceSubmission = state.state.task.timeline.find(
    (entry) =>
      entry.source === "source_hosted_intent" &&
      (entry.attachments ?? []).some(
        (attachment) => attachment.id === csvId,
      ),
  );
  assert.ok(sourceSubmission);

  response = await fetch(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: sourceHeaders(sourceToken, sourceSessionRef) },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.shared_task.phase, "waiting_for_source_pull");
  response = await fetch(
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
  csvRows = exported.source_tool_result.result.analysis.analyzed_rows;
  metricCount = exported.source_tool_result.result.analysis.metrics.length;
  assertBudget();

  const sourcePacket = {
    ...exported.source_tool_result.packet,
    type: "panel_tool_result",
    user_intent: hardwareProblem,
    fixture_scope:
      "Controlled HWiNFO-compatible fixture; not telemetry from the user's PC.",
  };
  const stateSchema = JSON.parse(
    await readFile(
      join(root, "skills", "pc-hardware-workbench", "schemas", "ui-state.schema.json"),
      "utf8",
    ),
  );
  const agentTurn = await sourceAgent.sendTurn({
    threadReference: sourceAgent.activeThreadReference,
    eventId: `pchw-launcher-source-${randomUUID()}`,
    packet: sourcePacket,
    structuredOutputSchema: dryRun ? null : stateSchema,
  });
  turnCompleted = true;
  if (!dryRun) {
    turnIdHash = sha256(agentTurn.turnId);
    assert.equal(sourceTurnCount, 1);
    assert.equal(sourceThreadCount, 1);
    if (abortReason === "tool_event_observed") {
      throw Object.assign(new Error("tool event observed"), {
        code: "tool_event_observed",
      });
    }
  }
  const rawPanel =
    agentTurn.structuredOutput ??
    parseStructuredOutput(agentTurn.finalText);
  const panel = validatePanelState(rawPanel);
  assert.ok(panel.judgement.length >= 20);

  response = await fetch(`${server.baseUrl}/api/task/sync/import`, {
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
      objective: "PCHW launcher Internal Preview final confirmation",
      summary: panel.turn_summary,
      messages: [{
        id: `pchw-launcher-result-${randomUUID()}`,
        role: "agent",
        text: panel.judgement,
        created_at: new Date().toISOString(),
      }],
      panel,
    }),
  });
  assert.equal(response.status, 200);
  state = await response.json();
  assert.equal(state.shared_task_phase, "source_result_synced");
  phaseTransitions.push("source_result_synced");
  finalPhase = "source_result_synced";

  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  state = await response.json();
  pageVisible = (await fetch(`${server.baseUrl}/`)).status === 200;
  assert.equal(pageVisible, true);
  assert.equal(state.task.attachments[0].sha256, csvSha256);
  assert.equal(state.panel.artifact_refs.length, 1);
  artifactCount = state.panel.artifact_refs.length;
  chartBlockCount = state.panel.blocks.filter(
    (block) => block.type === "chart",
  ).length;
  chartVisible = chartBlockCount === 1;
  conclusionVisible = state.panel.judgement.length >= 20;
  artifactSha256 = state.panel.artifact_refs[0].sha256;
  panelSha256 = sha256(JSON.stringify(state.panel));
  assert.equal(chartVisible, true);
  assert.equal(conclusionVisible, true);

  response = await fetch(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: panelHeaders(panelToken) },
  );
  const panelExportStatus = response.status;
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: { Authorization: `Bearer ${sourceToken}` },
  });
  credentialCrossoverRejected = (
    panelExportStatus === 403 &&
    response.status === 403
  );
  assert.equal(credentialCrossoverRejected, true);
  const stateText = JSON.stringify(state);
  assert.equal(stateText.includes(sourceToken), false);
  assert.equal(/[A-Za-z]:\\/u.test(stateText), false);
  redactionPassed = true;

  beforeRestartBrowser = await capturePchwBrowserEvidence({
    baseUrl: server.baseUrl,
    panelToken,
    evidenceDir,
    profileRoot: tempRoot,
    suffix: "-before-restart",
  });

  await serverLifecycle.close();
  serverClosed = true;
  server = null;
  launcherRestartCount += 1;
  server = await serverLifecycle.start();
  serverClosed = false;
  assert.equal(server.driver, "source-external");
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  state = await response.json();
  postRestartTaskRestored = (
    state.task.task_id === taskId &&
    state.task.shared_task.phase === "source_result_synced" &&
    state.task.attachments[0]?.sha256 === csvSha256
  );
  postRestartChartRestored = (
    state.panel.artifact_refs[0]?.sha256 === artifactSha256 &&
    sha256(JSON.stringify(state.panel)) === panelSha256
  );
  assert.equal(postRestartTaskRestored, true);
  assert.equal(postRestartChartRestored, true);
  afterRestartBrowser = await capturePchwBrowserEvidence({
    baseUrl: server.baseUrl,
    panelToken,
    evidenceDir,
    profileRoot: tempRoot,
    suffix: "-post-restart",
    postRestart: true,
  });

  if (sourceAgent && !dryRun) {
    await sourceAgent.close();
    sourceAgent = null;
    driver = null;
    driverClosed = true;
  } else {
    await sourceAgent.close();
    sourceAgent = null;
    driverClosed = true;
  }
  status = "passed";
} catch (error) {
  if (!dryRun && executionStarted) {
    const code = String(error?.code ?? error?.name ?? "");
    status =
      turnStarted && !turnCompleted && abortReason !== "tool_event_observed"
        ? "delivery_unknown"
        : "aborted";
    abortReason = abortReason ?? (code || "execution_error");
    if (currentTurnId) {
      await driver?.cancel(currentTurnId).catch(() => {});
    }
  } else {
    status = dryRun ? "dry_run_failed" : "aborted_preflight";
    abortReason = String(error?.code ?? error?.name ?? "preflight_error");
  }
} finally {
  if (driver && !driverClosed) {
    await driver.close().catch(() => {});
    driverClosed = true;
  }
  try {
    await serverLifecycle.close();
  } catch {
    serverCloseFailure = "server_close_failed";
    if (status === "passed") status = "aborted";
    abortReason = abortReason ?? serverCloseFailure;
  } finally {
    serverClosed = !serverLifecycle.isOpen;
  }
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  const afterFixtures = await fixtureDirectories();
  const leaked = [...afterFixtures].filter(
    (name) => !fixtureDirsBefore.has(name),
  );
  r9Checks.new_fixture_residual = leaked.length;
  r9Checks.driver_closed = driverClosed;
  r9Checks.server_closed = serverClosed;
  r9Checks.server_close_failure = serverCloseFailure;
  await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  await rm(packageDirectory, { recursive: true, force: true }).catch(() => {});
  await rm(archivePath, { force: true }).catch(() => {});
  r9Checks.temp_root_removed = !existsSync(tempRoot);
  r9Checks.package_removed = !existsSync(packageDirectory);
  r9Checks.archive_removed = !existsSync(archivePath);
  if (leaked.length > 0 || !serverClosed) {
    if (status === "passed") status = "aborted";
    abortReason = abortReason ?? "fixture_residual";
  }
  await writeEvidence(status);
}

process.stdout.write(`${JSON.stringify({
  dry_run: dryRun,
  execution_started: executionStarted,
  status,
  source_thread_count: dryRun ? 0 : sourceThreadCount,
  source_turn_count: dryRun ? 0 : sourceTurnCount,
  panel_turn_count: panelTurnCount,
  tool_event_count: dryRun ? 0 : toolEventCount,
  launcher_restart_count: launcherRestartCount,
  final_phase: finalPhase,
  chart_visible: chartVisible,
  conclusion_visible: conclusionVisible,
  post_restart_task_restored: postRestartTaskRestored,
  post_restart_chart_restored: postRestartChartRestored,
  abort_reason: abortReason,
  evidence_path: evidencePath,
})}\n`);
if (status !== "passed") process.exitCode = 1;
