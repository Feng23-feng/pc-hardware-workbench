import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
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
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const packageValue =
  process.argv[2] ??
  process.env.SKILLDOCK_RC_PACKAGE ??
  "";
if (!packageValue) {
  throw new Error(
    "Pass the extracted RC package path or set SKILLDOCK_RC_PACKAGE.",
  );
}
const packageRoot = resolve(packageValue);
if (!existsSync(packageRoot)) {
  throw new Error(
    "Pass the extracted RC package path or set SKILLDOCK_RC_PACKAGE.",
  );
}

const launcherInstaller = join(packageRoot, "Install SkillDock Runtime.ps1");
const packagedLaunchPanel = join(
  packageRoot,
  "skills",
  "pc-hardware-workbench",
  "scripts",
  "skilldock",
  "launch-panel.ps1",
);
for (const required of [launcherInstaller, packagedLaunchPanel]) {
  if (!existsSync(required)) {
    throw new Error(`Required RC upgrade test input is missing: ${required}`);
  }
}

const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-upgrade-rc-"));
const localRoot = join(tempRoot, "local");
const workspace = join(tempRoot, "workspace");
const runtimeBackups = join(tempRoot, "runtime-backups");
const dataBackups = join(tempRoot, "data-backups");
const installedRuntimeDirectory = join(
  localRoot,
  "Runtime-0.1.0-rc.1-upgrade-test",
);
const canonicalRoot = join(localRoot, "runtime-pchw");
const legacyRoot = join(localRoot, "runtime-dsh-web");
const threadId = randomUUID();
const threadHash = createHash("sha256")
  .update(threadId.toLowerCase())
  .digest("hex")
  .slice(0, 32);
const taskId = `task-pchw-${threadHash}`;
const channelId = `chat:source-hosted:${threadId}`;
const installedManifestHash =
  "e1f99b17f912c6179f5add58e7c834f1383be27fc6ada8037aa340a38e478392";
let installedLauncher = "";
let activePid = 0;
let activePort = 0;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

async function readJson(path) {
  return JSON.parse(
    (await readFile(path, "utf8")).replace(/^\uFEFF/u, ""),
  );
}

function runtimeState(objective, task, sharedTask) {
  const now = "2026-11-17T14:00:00.000Z";
  return {
    schema_version: "1.0",
    owner: "app-owned",
    active_skill: {
      api_version: "1.0",
      skill_id: "pc-hardware-workbench",
      skill_version: "2.8.0",
      manifest_hash: installedManifestHash,
      runtime_id: "pc-hardware-workbench",
      status: "active",
      selection_reason: "preferred_skill_id",
      error: null,
      selected_at: now,
    },
    skill_discovery: null,
    session_ref: null,
    session_name: "电脑硬件工作台",
    session_recovered: null,
    thread_id: null,
    thread_name: "电脑硬件工作台",
    thread_recovered: null,
    task: {
      ...task,
      objective,
      summary: `${objective}（升级迁移回归）`,
      phase: "ready",
      shared_task: sharedTask,
    },
    phase: "ready",
    panel: null,
    draft: { events: [], attachments: [] },
    error: null,
    last_turn: null,
    activity: null,
    created_at: now,
    updated_at: now,
    event_count: 5,
    agent_workspace: workspace,
  };
}

function taskRecord(id, objective, sourceSessionRef = null) {
  return {
    task_id: id,
    skill: {
      skill_id: "pc-hardware-workbench",
      skill_version: "2.8.0",
      manifest_hash: installedManifestHash,
      runtime_id: "pc-hardware-workbench",
    },
    attachments: [],
    artifacts: [],
    actions: [],
    domain_state: {
      device_snapshot_ref: "device-snapshot:not-collected",
      evidence_refs: [],
    },
    domain_refs: [],
    capability_profile: {
      schema_version: "1.0",
      profile: "read-only-supervised",
      task_id: id,
      network: "disabled",
      general_command: "unavailable",
      system_write: "manual-only",
      capabilities: {
        "telemetry.csv.analyze": "approval-required",
      },
    },
    grants: [],
    permission_request: null,
    device_snapshot_ref: "device-snapshot:not-collected",
    evidence_refs: [],
    timeline: [
      {
        id: "timeline-upgrade-regression",
        role: "user",
        text: objective,
        created_at: "2026-11-17T14:00:00.000Z",
        attachments: [],
      },
    ],
    phase: "ready",
    summary: objective,
    last_turn: null,
    sync: null,
    shared_task: sourceSessionRef
      ? {
          mode: "source_hosted",
          source_session_ref: sourceSessionRef,
          environment_thread_id: sourceSessionRef,
          phase: "ready",
        }
      : null,
  };
}

function runProcess(command, args, {
  env = process.env,
  timeoutMs = 120_000,
} = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
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
      rejectPromise(new Error(`Process timed out: ${command} ${args.join(" ")}`));
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

function runPowerShell(script, args, env = process.env) {
  return runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      script,
      ...args,
    ],
    { env },
  );
}

async function install(policy) {
  return runPowerShell(
    launcherInstaller,
    [
      "-SourceDirectory",
      packageRoot,
      "-TargetDirectory",
      installedRuntimeDirectory,
      "-LocalRoot",
      localRoot,
      "-BackupRoot",
      runtimeBackups,
      "-DataBackupRoot",
      dataBackups,
      "-LegacyDataPolicy",
      policy,
    ],
  );
}

async function waitForLaunchResult() {
  const resultPath = join(localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      const result = await readJson(resultPath);
      const health = await fetch(
        `${String(result.url).replace(/\/$/u, "")}/api/health`,
      ).then((response) => response.json());
      if (health.ok) return { result, health };
    } catch {
      // Runtime is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  throw new Error("Upgrade Runtime did not produce a healthy launch result.");
}

async function stopRuntime() {
  if (!installedLauncher || !existsSync(installedLauncher)) return;
  await runProcess(
    installedLauncher,
    ["--stop", "--silent"],
    {
      env: { ...process.env, SKILLDOCK_LOCAL_ROOT: localRoot },
      timeoutMs: 30_000,
    },
  ).catch(() => {});
  if (activePid > 0) {
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline) {
      try {
        process.kill(activePid, 0);
      } catch {
        return;
      }
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
    }
    process.kill(activePid);
  }
}

try {
  await mkdir(workspace, { recursive: true });
  const sharedTask = {
    mode: "source_hosted",
    source_session_ref: threadId,
    environment_thread_id: threadId,
    phase: "ready",
    channel_id: channelId,
  };
  const legacyState = runtimeState(
    "旧 RC 的 R7 掉帧任务必须升级后继续可见",
    taskRecord(taskId, "旧 RC 的 R7 掉帧任务必须升级后继续可见", threadId),
    sharedTask,
  );
  const canonicalState = runtimeState(
    "已恢复任务",
    taskRecord(`task-bootstrap-${randomUUID()}`, "已恢复任务"),
    null,
  );
  await writeJson(join(legacyRoot, "state.json"), legacyState);
  await writeJson(join(canonicalRoot, "state.json"), canonicalState);
  await mkdir(join(legacyRoot, "tasks"), { recursive: true });
  await writeFile(
    join(legacyRoot, "tasks", `${taskId}.json`),
    `${JSON.stringify(legacyState, null, 2)}\n`,
    "utf8",
  );
  await mkdir(join(legacyRoot, "attachments"), { recursive: true });
  await writeFile(
    join(legacyRoot, "attachments", "legacy-telemetry.csv"),
    "metric,value\nfps,60\n",
    "utf8",
  );
  await mkdir(join(legacyRoot, "artifacts", taskId), { recursive: true });
  await writeFile(
    join(legacyRoot, "artifacts", taskId, "legacy-chart.svg"),
    "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>\n",
    "utf8",
  );
  await writeFile(
    join(legacyRoot, "shared-evidence.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      store_id: "local-device-evidence",
      device_snapshot: {
        ref: "device-snapshot:not-collected",
        captured_date: null,
        identity_quality: "unknown",
        privacy_mode: "local-private",
        device_alias: "尚未采集设备",
        summary: "没有可复用的设备配置快照。",
      },
      evidence_refs: [],
      updated_at: "2026-11-17T14:00:00.000Z",
    })}\n`,
    "utf8",
  );
  for (const [name, value] of Object.entries({
    "capability-token":
      "legacy-master-token-0123456789abcdef0123456789abcdef",
    "panel-capability-token":
      "legacy-panel-token-0123456789abcdef0123456789abcdef",
    "source-capability-token":
      "legacy-source-token-0123456789abcdef0123456789abcdef",
    "handoff-secret":
      "legacy-handoff-secret-0123456789abcdef0123456789abcdef",
  })) {
    await writeFile(join(legacyRoot, name), `${value}\n`, "utf8");
    await writeFile(join(canonicalRoot, name), `current-${value}\n`, "utf8");
  }
  const staleServerInfo = {
    pid: 424242,
    host: "127.0.0.1",
    port: 65500,
    launch_id: "stale-launch-id",
    runtime_binding: {
      pid: 424242,
      port: 65500,
      launch_id: "stale-launch-id",
      origin: "http://127.0.0.1:65500",
    },
  };
  await writeJson(join(legacyRoot, "server-info.json"), staleServerInfo);

  const legacyBefore = sha256(
    await readFile(join(legacyRoot, "state.json")),
  );
  const canonicalBefore = sha256(
    await readFile(join(canonicalRoot, "state.json")),
  );
  const autoInstall = await install("Auto");
  assert.notEqual(autoInstall.code, 0);
  assert.match(
    `${autoInstall.stdout}\n${autoInstall.stderr}`,
    /runtime_data_conflict/u,
  );
  assert.equal(
    sha256(await readFile(join(legacyRoot, "state.json"))),
    legacyBefore,
  );
  assert.equal(
    sha256(await readFile(join(canonicalRoot, "state.json"))),
    canonicalBefore,
  );

  const preferredInstall = await install("PreferLegacy");
  assert.equal(
    preferredInstall.code,
    0,
    `${preferredInstall.stdout}\n${preferredInstall.stderr}`,
  );
  const migratedState = await readJson(join(canonicalRoot, "state.json"));
  assert.equal(migratedState.task.task_id, taskId);
  assert.equal(
    sha256(await readFile(join(legacyRoot, "state.json"))),
    legacyBefore,
  );
  const migrationMarker = await readJson(
    join(canonicalRoot, "runtime-data-migration.json"),
  );
  assert.equal(migrationMarker.status, "completed");
  assert.equal(migrationMarker.policy, "PreferLegacy");
  assert.ok(existsSync(migrationMarker.backup_directory));
  assert.ok(
    existsSync(join(migrationMarker.backup_directory, "DATA-BACKUP.json")),
  );

  const pointer = await readJson(join(localRoot, "runtime-location.json"));
  installedLauncher = pointer.runtime_path;
  const launcherEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    NODE_NO_WARNINGS: "1",
  };
  const launch = await runProcess(
    installedLauncher,
    [
      "--ensure",
      "--workspace",
      workspace,
      "--silent",
      "--no-browser",
    ],
    { env: launcherEnv },
  );
  assert.equal(launch.code, 0, `${launch.stdout}\n${launch.stderr}`);
  const started = await waitForLaunchResult();
  activePid = Number(started.result.pid);
  activePort = Number(started.result.port);
  assert.equal(started.health.runtime_binding.pid, started.result.pid);
  assert.equal(started.health.runtime_binding.port, started.result.port);
  assert.equal(
    started.health.runtime_binding.launch_id,
    started.result.launch_id,
  );
  const currentServerInfo = await readJson(
    join(canonicalRoot, "server-info.json"),
  );
  assert.equal(currentServerInfo.pid, started.result.pid);
  assert.equal(currentServerInfo.port, started.result.port);
  assert.equal(
    currentServerInfo.launch_id,
    started.result.launch_id,
  );
  assert.deepEqual(
    await readJson(join(legacyRoot, "server-info.json")),
    staleServerInfo,
  );

  const masterToken = (
    await readFile(join(canonicalRoot, "capability-token"), "utf8")
  ).trim();
  const stateResponse = await fetch(
    `${String(started.result.url).replace(/\/$/u, "")}/api/state`,
    {
      headers: { Authorization: `Bearer ${masterToken}` },
    },
  );
  assert.equal(stateResponse.ok, true);
  const currentState = await stateResponse.json();
  assert.equal(currentState.task.task_id, taskId);

  const contextPath = join(tempRoot, "chat-context.json");
  await writeJson(contextPath, {
    schema_version: "1.0",
    channel_id: channelId,
    source_session_ref: threadId,
    objective: currentState.task.objective,
    summary: "升级后继续当前旧 Task。",
    messages: [
      {
        id: "upgrade-regression-user",
        role: "user",
        text: currentState.task.objective,
        created_at: "2026-11-17T14:00:01.000Z",
      },
    ],
  });
  const panel = await runPowerShell(
    packagedLaunchPanel,
    [
      "-Workspace",
      workspace,
      "-LauncherPath",
      installedLauncher,
      "-ChatContextFile",
      contextPath,
      "-NoBrowser",
    ],
    {
      ...launcherEnv,
      CODEX_THREAD_ID: threadId,
    },
  );
  assert.equal(panel.code, 0, `${panel.stdout}\n${panel.stderr}`);
  const panelResult = JSON.parse(panel.stdout.trim());
  assert.equal(panelResult.ok, true);
  assert.equal(panelResult.task_ref, taskId);
  assert.equal(panelResult.runtime_pid, started.result.pid);
  assert.equal(panelResult.runtime_port, started.result.port);
  assert.equal(
    panelResult.runtime_launch_id,
    started.result.launch_id,
  );
  assert.equal(
    resolve(panelResult.runtime_data_directory),
    resolve(canonicalRoot),
  );
  assert.ok(
    panelResult.ignored_runtime_metadata.includes(
      join(legacyRoot, "server-info.json"),
    ),
  );
  const durableState = await readJson(join(canonicalRoot, "state.json"));
  assert.equal(durableState.task.task_id, taskId);
  const taskFiles = await readdir(join(canonicalRoot, "tasks"));
  assert.ok(
    taskFiles.some((name) => name.includes(taskId)),
    "The migrated legacy Task was not retained in the Task archive.",
  );

  await stopRuntime();
  activePid = 0;
  assert.equal(
    existsSync(join(legacyRoot, "state.json")),
    true,
    "Legacy source data must remain recoverable after migration.",
  );
  console.log("Windows RC stale-metadata and legacy-data upgrade regression: PASS");
}
finally {
  await stopRuntime();
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept upgrade smoke workspace: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true });
  }
}
