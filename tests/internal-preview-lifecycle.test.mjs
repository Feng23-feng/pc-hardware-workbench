import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import {
  MockAgentDriver,
} from "../lib/agents/mock-agent-driver.mjs";
import {
  signHandoffToken,
} from "../lib/handoff-capability.mjs";

if (process.platform !== "win32") {
  console.log("Internal preview lifecycle: SKIP (Windows only)");
  process.exit(0);
}

const root = resolve(import.meta.dirname, "..");
const powershell = "powershell.exe";
const buildScript = join(root, "launcher", "build-dsh-package.ps1");
const installScript = join(root, "launcher", "install-runtime.ps1");
const runId = randomUUID();
const packageDirectory = join(
  root,
  "dist",
  `.internal-preview-lifecycle-${runId}`,
);
const archivePath = join(root, "dist", `.internal-preview-lifecycle-${runId}.zip`);
const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-preview-lifecycle-"));
const nodeBundle = join(tempRoot, "node-runtime");
const localRoot = join(tempRoot, "local-app-data", "SkillDock");
const backupRoot = join(tempRoot, "local-app-data", "SkillDockBackups", "runtime");
const workspace = join(tempRoot, "workspace");
const targetRuntime = join(localRoot, "Runtime-preview");
const evidenceDir = join(
  root,
  "work",
  "internal-preview-lifecycle-2026-11-17",
);
const approvedEvidencePath = join(
  evidenceDir,
  "lifecycle-evidence-approved-b46f207bb23a19c1a2dee558171fc41cad77a2ae939b5129a287f5cdfa312379.json",
);
const approvedHardenedEvidencePath = join(
  evidenceDir,
  "lifecycle-evidence-hardened-approved-dc01a279b07e6e07376722164d1b7ee4328406033c0ceba2598151599ada3c45.json",
);
const originalEvidencePath = join(evidenceDir, "lifecycle-evidence.json");
const evidencePath = join(evidenceDir, "lifecycle-evidence-hardened.json");
const approvedEvidenceSha256 =
  "b46f207bb23a19c1a2dee558171fc41cad77a2ae939b5129a287f5cdfa312379";
const approvedHardenedEvidenceSha256 =
  "dc01a279b07e6e07376722164d1b7ee4328406033c0ceba2598151599ada3c45";
let activeUrl = null;
let launcherPath;
let launcherEnv;
let defaultOffStatus = null;
let nonMockPreviewExitCode = null;
let nonMockPreviewProducedServerInfo = null;
let sourceExternalWithoutGateExitCode = null;
let sourceExternalWithoutGateProducedServerInfo = null;
let controlledSourceExternalStarted = false;
let controlledSourceExternalPanelThreadCount = null;
let previewPhase = null;
let restartStatePersisted = false;
let packageBuilt = false;
let installedToCleanRoot = false;
const pathInventories = {};
const processInventories = {};

function runProcess(command, args, {
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
      rejectPromise(new Error(
        `Process timed out: ${command} ${args.join(" ")}\n${stderr}`,
      ));
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

async function readJson(path) {
  const text = (await readFile(path, "utf8")).replace(/^\uFEFF/u, "");
  return JSON.parse(text);
}

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

function pathInventory() {
  return {
    package_directory_exists: existsSync(packageDirectory),
    package_archive_exists: existsSync(archivePath),
    temp_root_exists: existsSync(tempRoot),
    local_root_exists: existsSync(localRoot),
    backup_root_exists: existsSync(backupRoot),
    runtime_program_exists: existsSync(targetRuntime),
    engine_root_exists: existsSync(join(localRoot, "engines")),
    storage_exports_exists: existsSync(join(localRoot, "storage-exports")),
    launcher_pointer_exists: existsSync(
      join(localRoot, "runtime-location.json"),
    ),
  };
}

async function listProcessesUnderRoot(processRoot) {
  const script = String.raw`
$scope = [string]$env:SKILLDOCK_PROCESS_SCOPE
$processes = @(
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $scope,
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        ForEach-Object {
            [pscustomobject]@{
                process_id = [int]$_.ProcessId
                executable_path = [string]$_.ExecutablePath
            }
        }
)
if ($processes.Count -eq 0) {
    Write-Output "[]"
}
else {
    ConvertTo-Json -InputObject $processes -Compress
}
`;
  const result = await runProcess(
    powershell,
    ["-NoProfile", "-NonInteractive", "-Command", script],
    {
      env: {
        ...process.env,
        SKILLDOCK_PROCESS_SCOPE: processRoot,
      },
    },
  );
  assert.equal(result.code, 0, result.stderr);
  const parsed = JSON.parse(result.stdout.trim() || "[]");
  return Array.isArray(parsed) ? parsed : [parsed];
}

function parseJsonOutput(result, label) {
  const output = result.stdout.trim();
  assert.ok(output, `${label} did not return JSON.`);
  return JSON.parse(output);
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

async function waitForLaunchResult({ previousUrl = null } = {}) {
  const resultPath = join(localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      const result = await readJson(resultPath);
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
  throw new Error("Internal preview launch result did not appear.");
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

try {
  assert.equal(
    await sha256File(originalEvidencePath),
    approvedEvidenceSha256,
    "The approved lifecycle evidence must remain byte-for-byte unchanged.",
  );
  assert.equal(
    await sha256File(approvedEvidencePath),
    approvedEvidenceSha256,
    "The versioned copy of approved lifecycle evidence is missing or changed.",
  );
  assert.equal(
    await sha256File(approvedHardenedEvidencePath),
    approvedHardenedEvidenceSha256,
    "The R2-approved hardened lifecycle evidence is missing or changed.",
  );
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
  assert.ok(licenseSource, "A Node LICENSE file is required for packaging.");
  await copyFile(licenseSource, join(nodeBundle, "LICENSE"));

  const build = await runProcess(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      buildScript,
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
  assert.equal(build.code, 0, build.stderr);
  launcherPath = join(packageDirectory, "SkillDock.exe");
  assert.equal(existsSync(launcherPath), true);
  assert.equal(existsSync(archivePath), true);
  packageBuilt = true;
  pathInventories.after_build = pathInventory();

  const install = await runProcess(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      installScript,
      "-SourceDirectory",
      packageDirectory,
      "-TargetDirectory",
      targetRuntime,
      "-LocalRoot",
      localRoot,
      "-BackupRoot",
      backupRoot,
    ],
  );
  assert.equal(install.code, 0, install.stderr);
  const pointer = await readJson(join(localRoot, "runtime-location.json"));
  assert.equal(pointer.runtime_path, join(targetRuntime, "SkillDock.exe"));
  assert.equal(
    pointer.node_engine?.engine_id,
    `node-${process.versions.node}-${createHash("sha256")
      .update(await readFile(process.execPath))
      .digest("hex")
      .slice(0, 16)}`,
  );
  assert.equal(existsSync(join(targetRuntime, "node")), false);
  assert.equal(existsSync(join(targetRuntime, "engine-location.json")), true);
  assert.equal(existsSync(pointer.node_engine.node_path), true);
  launcherPath = pointer.runtime_path;
  installedToCleanRoot = (
    existsSync(targetRuntime) &&
    pointer.runtime_path === join(targetRuntime, "SkillDock.exe")
  );
  assert.equal(installedToCleanRoot, true);
  pathInventories.after_install = pathInventory();

  const nonMockPreview = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], {
    env: {
      ...process.env,
      SKILLDOCK_LOCAL_ROOT: localRoot,
      SKILLDOCK_AGENT_DRIVER: "codex",
      SKILLDOCK_INTERNAL_PREVIEW: "1",
      PANEL_SOURCE_HOSTED_ENTRY: "",
      NODE_NO_WARNINGS: "1",
    },
  });
  nonMockPreviewExitCode = nonMockPreview.code;
  nonMockPreviewProducedServerInfo = existsSync(
    join(localRoot, "runtime-dsh-web", "server-info.json"),
  );
  assert.notEqual(nonMockPreview.code, 0);
  assert.equal(nonMockPreviewProducedServerInfo, false);

  const sourceExternalWithoutGate = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], {
    env: {
      ...process.env,
      SKILLDOCK_LOCAL_ROOT: localRoot,
      SKILLDOCK_AGENT_DRIVER: "source-external",
      SKILLDOCK_INTERNAL_PREVIEW: "1",
      SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK: "",
      NODE_NO_WARNINGS: "1",
    },
  });
  sourceExternalWithoutGateExitCode = sourceExternalWithoutGate.code;
  sourceExternalWithoutGateProducedServerInfo = existsSync(
    join(localRoot, "runtime-dsh-web", "server-info.json"),
  );
  assert.notEqual(sourceExternalWithoutGate.code, 0);
  assert.equal(sourceExternalWithoutGateProducedServerInfo, false);

  const sourceExternalWithGateEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    SKILLDOCK_AGENT_DRIVER: "source-external",
    SKILLDOCK_INTERNAL_PREVIEW: "1",
    SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK: "1",
    NODE_NO_WARNINGS: "1",
  };
  const sourceExternalWithGate = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: sourceExternalWithGateEnv });
  assert.equal(sourceExternalWithGate.code, 0, sourceExternalWithGate.stderr);
  const sourceExternalLaunch = await waitForLaunchResult();
  assert.equal(sourceExternalLaunch.driver, "source-external");
  const sourceExternalMasterToken = (
    await readFile(join(localRoot, "runtime-dsh-web", "capability-token"), "utf8")
  ).trim();
  let sourceExternalResponse = await fetch(
    `${sourceExternalLaunch.url.replace(/\/$/u, "")}/api/state`,
    {
      headers: {
        Authorization: `Bearer ${sourceExternalMasterToken}`,
      },
    },
  );
  assert.equal(sourceExternalResponse.status, 200);
  const sourceExternalState = await sourceExternalResponse.json();
  controlledSourceExternalPanelThreadCount =
    sourceExternalState.agent?.thread_id == null ? 0 : 1;
  assert.equal(controlledSourceExternalPanelThreadCount, 0);
  controlledSourceExternalStarted = true;
  const sourceExternalStop = await runProcess(
    launcherPath,
    ["--stop", "--silent"],
    {
      env: sourceExternalWithGateEnv,
      timeoutMs: 30_000,
    },
  );
  assert.equal(sourceExternalStop.code, 0, sourceExternalStop.stderr);
  assert.equal(await isHealthy(sourceExternalLaunch.url), false);

  const baseLauncherEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    SKILLDOCK_AGENT_DRIVER: "mock",
    SKILLDOCK_INTERNAL_PREVIEW: "",
    PANEL_SOURCE_HOSTED_ENTRY: "",
    NODE_NO_WARNINGS: "1",
  };
  let started = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: baseLauncherEnv });
  assert.equal(started.code, 0, started.stderr);
  let launchResult = await waitForLaunchResult();
  let response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/source-hosted/open?token=invalid`,
    { redirect: "manual" },
  );
  defaultOffStatus = response.status;
  assert.equal(defaultOffStatus, 404);
  started = await runProcess(launcherPath, ["--stop", "--silent"], {
    env: baseLauncherEnv,
    timeoutMs: 30_000,
  });
  assert.equal(started.code, 0, started.stderr);
  assert.equal(await isHealthy(launchResult.url), false);

  launcherEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    SKILLDOCK_AGENT_DRIVER: "mock",
    SKILLDOCK_INTERNAL_PREVIEW: "1",
    NODE_NO_WARNINGS: "1",
  };
  const previousDefaultUrl = launchResult.url;
  started = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: launcherEnv });
  assert.equal(started.code, 0, started.stderr);
  launchResult = await waitForLaunchResult({
    previousUrl: previousDefaultUrl,
  });
  activeUrl = launchResult.url;
  const runtimeDirectory = join(localRoot, "runtime-dsh-web");
  const panelToken = (
    await readFile(join(runtimeDirectory, "panel-capability-token"), "utf8")
  ).trim();
  const sourceToken = (
    await readFile(join(runtimeDirectory, "source-capability-token"), "utf8")
  ).trim();
  const handoffSecret = (
    await readFile(join(runtimeDirectory, "handoff-secret"), "utf8")
  ).trim();

  const sourceSessionRef = randomUUID();
  const taskId = "task-internal-preview-001";
  const channelId = `chat:source-hosted:${sourceSessionRef}`;
  const signed = signHandoffToken({
    thread_id: sourceSessionRef,
    environment_thread_id: sourceSessionRef,
    task_id: taskId,
    objective: "Internal preview clean-machine lifecycle",
    summary: "Mock-only packaged runtime preview.",
    domain_state: {},
    domain_refs: [],
    read_only: true,
    source: "agent-skill",
  }, handoffSecret, { ttlSeconds: 120 });
  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/source-hosted/open?token=${
      encodeURIComponent(signed.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 303);
  const cookie = response.headers.get("set-cookie") ?? "";
  assert.match(cookie, /panel_token=/u);

  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  let state = await response.json();
  assert.equal(state.task.task_id, taskId);
  assert.equal(state.task.shared_task.phase, "source_owned");

  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/event`,
    {
      method: "POST",
      headers: panelHeaders(panelToken, { json: true }),
      body: JSON.stringify({
        type: "evidence_added",
        label: "internal preview intent",
        detail: "One packaged-runtime mock flow.",
        source: "user_reported",
      }),
    },
  );
  assert.equal(response.status, 200);
  state = await response.json();
  assert.equal(
    state.task.shared_task.phase,
    "waiting_for_source_pull",
  );

  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: sourceHeaders(sourceToken, sourceSessionRef) },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.shared_task.phase, "waiting_for_source_pull");
  const intent = exported.messages.find(
    (message) => message.source === "source_hosted_intent",
  );
  assert.ok(intent);
  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/task/sync/claim`,
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
        intent_event_id: intent.external_id,
        submission_sequence: intent.seq,
        attachment_id: "",
        attachment_sha256: "",
        require_source_result: false,
      }),
    },
  );
  assert.equal(response.status, 200);
  const claim = await response.json();
  assert.equal(claim.phase, "source_agent_pulled");

  const mockDriver = new MockAgentDriver();
  await mockDriver.initialize();
  const thread = await mockDriver.startThread();
  const turn = await mockDriver.sendTurn({
    threadReference: thread.threadReference,
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: exported.messages.find(
        (message) => message.source === "source_hosted_intent",
      ).text,
      skill_context: {
        skill_id: "compat-chat",
        runtime_id: "compat-chat",
      },
    },
  });
  await mockDriver.close();

  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/task/sync/import`,
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
        objective: "Internal preview clean-machine lifecycle",
        summary: "Mock-only packaged Runtime preview.",
        messages: [{
          id: "internal-preview-result-001",
          role: "agent",
          text: turn.structuredOutput.turn_summary,
          created_at: new Date().toISOString(),
        }],
      }),
    },
  );
  assert.equal(response.status, 200);
  const imported = await response.json();
  previewPhase = imported.shared_task_phase;
  assert.equal(previewPhase, "source_result_synced");

  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "source_result_synced");
  assert.equal(state.panel, null);
  assert.equal(state.last_turn, null);

  started = await runProcess(launcherPath, ["--stop", "--silent"], {
    env: launcherEnv,
    timeoutMs: 30_000,
  });
  assert.equal(started.code, 0, started.stderr);
  assert.equal(await isHealthy(launchResult.url), false);

  const previousUrl = launchResult.url;
  activeUrl = null;
  started = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: launcherEnv });
  assert.equal(started.code, 0, started.stderr);
  launchResult = await waitForLaunchResult({ previousUrl });
  activeUrl = launchResult.url;
  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/api/state`,
    { headers: panelHeaders(panelToken) },
  );
  state = await response.json();
  assert.equal(state.task.task_id, taskId);
  assert.equal(state.task.shared_task.phase, "source_result_synced");
  restartStatePersisted = state.task.shared_task.phase === previewPhase;
  assert.equal(restartStatePersisted, true);

  const engineReferencePath = join(
    targetRuntime,
    "engine-location.json",
  );
  const originalEngineReference = await readFile(engineReferencePath, "utf8");
  const tamperedEngineReference = JSON.parse(originalEngineReference);
  tamperedEngineReference.node_sha256 = "0".repeat(64);
  await writeFile(
    engineReferencePath,
    `${JSON.stringify(tamperedEngineReference, null, 2)}\n`,
    "utf8",
  );
  try {
    const tamperedLaunch = await runProcess(launcherPath, [
      "--ensure",
      "--silent",
      "--no-browser",
    ], {
      env: {
        ...process.env,
        SKILLDOCK_LOCAL_ROOT: localRoot,
      },
    });
    assert.notEqual(tamperedLaunch.code, 0);
    const launchFailure = await readJson(
      join(localRoot, "launch-failure.json"),
    );
    assert.equal(launchFailure.error_code, "shared_engine_hash_mismatch");
  } finally {
    await writeFile(engineReferencePath, originalEngineReference, "utf8");
  }

  const packagedUninstallScript = join(
    targetRuntime,
    "Uninstall SkillDock.ps1",
  );
  assert.equal(existsSync(packagedUninstallScript), true);
  const retainedUninstallScript = join(
    tempRoot,
    "Uninstall SkillDock.lifecycle.ps1",
  );
  await copyFile(packagedUninstallScript, retainedUninstallScript);
  await copyFile(
    join(targetRuntime, "runtime-paths.ps1"),
    join(tempRoot, "runtime-paths.ps1"),
  );
  const backupMarkerPath = join(backupRoot, "lifecycle-retained.marker");
  await writeFile(
    backupMarkerPath,
    "Retained by default uninstall; removed only by explicit purge.\n",
    { encoding: "utf8", mode: 0o600 },
  );
  const launchFailureMarkerPath = join(localRoot, "launch-failure.json");
  await writeFile(
    launchFailureMarkerPath,
    '{"ok":false,"error_code":"lifecycle-test"}\n',
    { encoding: "utf8", mode: 0o600 },
  );
  const installLogsMarkerPath = join(
    localRoot,
    "install-logs",
    "lifecycle-install.log",
  );
  await mkdir(dirname(installLogsMarkerPath), { recursive: true });
  await writeFile(
    installLogsMarkerPath,
    "Retained by default uninstall; removed only by explicit purge.\n",
    { encoding: "utf8", mode: 0o600 },
  );
  const migrationArtifactPath = join(
    localRoot,
    `.runtime-pchw-migrating-${"a".repeat(32)}`,
  );
  await mkdir(migrationArtifactPath, { recursive: true });
  await writeFile(
    join(migrationArtifactPath, "rollback.marker"),
    "Retained by default uninstall; removed only by explicit purge.\n",
    { encoding: "utf8", mode: 0o600 },
  );
  const storageExportMarkerPath = join(
    localRoot,
    "storage-exports",
    "export.marker",
  );
  await mkdir(dirname(storageExportMarkerPath), { recursive: true });
  await writeFile(
    storageExportMarkerPath,
    "Retained by default uninstall; removed only by explicit purge.\n",
    { encoding: "utf8", mode: 0o600 },
  );

  processInventories.before_default_uninstall =
    await listProcessesUnderRoot(tempRoot);
  assert.ok(
    processInventories.before_default_uninstall.length > 0,
    "Expected a live packaged Runtime process before uninstall.",
  );
  pathInventories.before_default_uninstall = pathInventory();

  const defaultUninstallRun = await runProcess(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      retainedUninstallScript,
      "-LocalRoot",
      localRoot,
      "-BackupRoot",
      backupRoot,
    ],
  );
  assert.equal(defaultUninstallRun.code, 0, defaultUninstallRun.stderr);
  const defaultUninstall = parseJsonOutput(
    defaultUninstallRun,
    "Default uninstall",
  );
  assert.equal(defaultUninstall.ok, true);
  assert.equal(defaultUninstall.purged_user_data, false);
  assert.equal(defaultUninstall.purged_backups, false);
  assert.equal(await isHealthy(launchResult.url), false);
  processInventories.after_default_uninstall =
    await listProcessesUnderRoot(tempRoot);
  pathInventories.after_default_uninstall = pathInventory();
  const runtimeDirectoryAfterUninstall = join(localRoot, "runtime-dsh-web");
  const defaultUninstallPreservedUserData = (
    existsSync(runtimeDirectoryAfterUninstall) &&
    existsSync(join(runtimeDirectoryAfterUninstall, "server-info.json")) &&
    existsSync(join(runtimeDirectoryAfterUninstall, "panel-capability-token")) &&
    existsSync(join(runtimeDirectoryAfterUninstall, "source-capability-token")) &&
    existsSync(join(localRoot, "launch-result.json")) &&
    existsSync(launchFailureMarkerPath) &&
    existsSync(installLogsMarkerPath) &&
    existsSync(migrationArtifactPath) &&
    existsSync(storageExportMarkerPath)
  );
  const defaultUninstallPreservedBackups = existsSync(backupMarkerPath);
  assert.equal(
    pathInventories.after_default_uninstall.runtime_program_exists,
    false,
  );
  assert.equal(
    pathInventories.after_default_uninstall.launcher_pointer_exists,
    false,
  );
  assert.equal(
    pathInventories.after_default_uninstall.local_root_exists,
    true,
  );
  assert.equal(
    pathInventories.after_default_uninstall.engine_root_exists,
    true,
  );
  assert.equal(
    pathInventories.after_default_uninstall.storage_exports_exists,
    true,
  );
  assert.equal(
    pathInventories.after_default_uninstall.backup_root_exists,
    true,
  );
  assert.equal(defaultUninstallPreservedUserData, true);
  assert.equal(defaultUninstallPreservedBackups, true);
  assert.deepEqual(processInventories.after_default_uninstall, []);

  const purgeUninstallRun = await runProcess(
    powershell,
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      retainedUninstallScript,
      "-LocalRoot",
      localRoot,
      "-BackupRoot",
      backupRoot,
      "-PurgeUserData",
      "-PurgeBackups",
    ],
  );
  assert.equal(purgeUninstallRun.code, 0, purgeUninstallRun.stderr);
  const purgeUninstall = parseJsonOutput(
    purgeUninstallRun,
    "Purge uninstall",
  );
  assert.equal(purgeUninstall.ok, true);
  assert.equal(purgeUninstall.purged_user_data, true);
  assert.equal(purgeUninstall.purged_backups, true);
  assert.equal(await isHealthy(launchResult.url), false);
  processInventories.after_purge_uninstall =
    await listProcessesUnderRoot(tempRoot);
  pathInventories.after_purge_uninstall = pathInventory();
  const remainingLocalRootEntries = existsSync(localRoot)
    ? await readdir(localRoot)
    : [];
  assert.equal(
    pathInventories.after_purge_uninstall.local_root_exists,
    false,
    `LocalRoot remains after purge: ${remainingLocalRootEntries.join(", ")}`,
  );
  assert.equal(
    pathInventories.after_purge_uninstall.backup_root_exists,
    false,
  );
  assert.equal(
    pathInventories.after_purge_uninstall.engine_root_exists,
    false,
  );
  assert.equal(
    pathInventories.after_purge_uninstall.storage_exports_exists,
    false,
  );
  assert.deepEqual(processInventories.after_purge_uninstall, []);
  activeUrl = null;

  await rm(tempRoot, { recursive: true, force: true });
  await rm(packageDirectory, { recursive: true, force: true });
  await rm(archivePath, { force: true });
  pathInventories.after_fixture_cleanup = pathInventory();
  processInventories.after_fixture_cleanup =
    await listProcessesUnderRoot(tempRoot);
  assert.equal(pathInventories.after_fixture_cleanup.package_directory_exists,
    false);
  assert.equal(pathInventories.after_fixture_cleanup.package_archive_exists,
    false);
  assert.equal(pathInventories.after_fixture_cleanup.temp_root_exists, false);
  assert.equal(pathInventories.after_fixture_cleanup.local_root_exists, false);
  assert.equal(pathInventories.after_fixture_cleanup.backup_root_exists, false);
  assert.equal(pathInventories.after_fixture_cleanup.engine_root_exists, false);
  assert.equal(
    pathInventories.after_fixture_cleanup.storage_exports_exists,
    false,
  );
  assert.deepEqual(processInventories.after_fixture_cleanup, []);

  const residueCandidates = [
    ["package_directory", packageDirectory],
    ["package_archive", archivePath],
    ["temp_root", tempRoot],
    ["local_root", localRoot],
    ["backup_root", backupRoot],
    ["runtime_program", targetRuntime],
    ["launcher_pointer", join(localRoot, "runtime-location.json")],
    ["user_runtime", join(localRoot, "runtime-dsh-web")],
    ["launch_result", join(localRoot, "launch-result.json")],
  ];
  const remainingResidueKinds = residueCandidates
    .filter(([, path]) => existsSync(path))
    .map(([kind]) => kind);
  const liveProcessResidue =
    processInventories.after_fixture_cleanup.length;
  const remainingInstallResidue =
    remainingResidueKinds.length + liveProcessResidue;
  assert.equal(remainingInstallResidue, 0);

  await mkdir(evidenceDir, { recursive: true });
  await writeFile(
    evidencePath,
    `${JSON.stringify({
      schema_version: "1.1",
      status: "passed",
      approved_evidence_sha256: approvedEvidenceSha256,
      package_built: packageBuilt,
      installed_to_clean_root: installedToCleanRoot,
      internal_preview_default_off: defaultOffStatus === 404,
      internal_preview_default_off_status: defaultOffStatus,
      internal_preview_requires_mock: (
        nonMockPreviewExitCode !== 0 &&
        nonMockPreviewProducedServerInfo === false
      ),
      non_mock_preview_exit_code: nonMockPreviewExitCode,
      non_mock_preview_produced_server_info:
        nonMockPreviewProducedServerInfo,
      source_external_without_gate_exit_code:
        sourceExternalWithoutGateExitCode,
      source_external_without_gate_produced_server_info:
        sourceExternalWithoutGateProducedServerInfo,
      controlled_source_external_started: controlledSourceExternalStarted,
      controlled_source_external_panel_thread_count:
        controlledSourceExternalPanelThreadCount,
      preview_phase: previewPhase,
      restart_state_persisted: restartStatePersisted,
      default_uninstall_completed: defaultUninstall.ok === true,
      default_uninstall_preserved_user_data:
        defaultUninstallPreservedUserData,
      default_uninstall_preserved_backups:
        defaultUninstallPreservedBackups,
      purge_uninstall_completed: purgeUninstall.ok === true,
      local_root_removed: (
        pathInventories.after_purge_uninstall.local_root_exists === false
      ),
      backup_root_removed: (
        pathInventories.after_purge_uninstall.backup_root_exists === false
      ),
      remaining_install_residue: remainingInstallResidue,
      remaining_install_residue_kinds: remainingResidueKinds,
      process_counts: {
        before_default_uninstall:
          processInventories.before_default_uninstall.length,
        after_default_uninstall:
          processInventories.after_default_uninstall.length,
        after_purge_uninstall:
          processInventories.after_purge_uninstall.length,
        after_fixture_cleanup:
          processInventories.after_fixture_cleanup.length,
      },
      path_inventories: pathInventories,
      package_node_version: process.versions.node,
      observed_at: new Date().toISOString(),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  console.log(
    "Internal preview install/flow/restart/uninstall/residue: PASS",
  );
} finally {
  if (activeUrl) {
    await runProcess(launcherPath, ["--stop", "--silent"], {
      env: launcherEnv,
      timeoutMs: 15_000,
    }).catch(() => {});
  }
  await rm(tempRoot, { recursive: true, force: true });
  await rm(packageDirectory, { recursive: true, force: true });
  await rm(archivePath, { force: true });
}
