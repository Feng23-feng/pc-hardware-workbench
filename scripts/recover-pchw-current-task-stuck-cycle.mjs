import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  readFile,
  readdir,
  stat,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:net";
import { dirname, join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const localRoot = join(process.env.LOCALAPPDATA ?? "", "SkillDock");
const runtimeDirectory = join(localRoot, "runtime-dsh-web");
const pointerPath = join(localRoot, "runtime-location.json");
const statePath = join(runtimeDirectory, "state.json");
const taskDirectory = join(runtimeDirectory, "tasks");
const cycleDirectory = join(taskDirectory, "cycles");
const evidencePath = join(
  root,
  "work",
  "PCHW-STUCK-CYCLE-RECOVERY-20261117.json",
);

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function hashJson(value) {
  return sha256(JSON.stringify(value));
}

function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function listJsonFiles(directory) {
  try {
    return (await readdir(directory, { withFileTypes: true }))
      .filter((entry) => entry.isFile() && entry.name.endsWith(".json"))
      .map((entry) => entry.name)
      .sort();
  } catch {
    return [];
  }
}

async function taskSetProjection(entries) {
  const files = await Promise.all(
    entries.map(async (name) => ({
      name,
      sha256: sha256(await readFile(join(taskDirectory, name))),
    })),
  );
  return {
    count: files.length,
    sha256: sha256(JSON.stringify(files)),
    names: entries,
  };
}

async function freePort() {
  return new Promise((resolvePromise, rejectPromise) => {
    const server = createServer();
    server.once("error", rejectPromise);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      server.close((error) => {
        if (error) rejectPromise(error);
        else resolvePromise(address.port);
      });
    });
  });
}

async function waitForHealth(baseUrl, child, stderr) {
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`mock recovery runtime exited: ${stderr()}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) return;
    } catch {
      // Runtime is still starting.
    }
    await new Promise((resolvePromise) =>
      setTimeout(resolvePromise, 100)
    );
  }
  throw new Error("mock recovery runtime health timeout");
}

async function stopChild(child) {
  if (child.exitCode !== null) return;
  child.kill();
  await Promise.race([
    new Promise((resolvePromise) => child.once("exit", resolvePromise)),
    new Promise((resolvePromise) => setTimeout(resolvePromise, 5_000)),
  ]);
}

const threadId = String(process.env.CODEX_THREAD_ID ?? "").trim();
assert.match(
  threadId,
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu,
  "CODEX_THREAD_ID is required",
);

const pointer = JSON.parse(
  (await readFile(pointerPath, "utf8")).replace(/^\uFEFF/u, ""),
);
const packageRoot = dirname(resolve(pointer.runtime_path));
const nodePath = join(packageRoot, "node", "node.exe");
const serverPath = join(packageRoot, "app", "server.mjs");
await stat(nodePath);
await stat(serverPath);

const before = JSON.parse(
  (await readFile(statePath, "utf8")).replace(/^\uFEFF/u, ""),
);
assert.equal(before.task?.shared_task?.mode, "source_hosted");
assert.equal(before.task?.shared_task?.phase, "source_agent_pulled");
assert.equal(before.task?.shared_task?.source_session_ref, threadId);
assert.equal(before.task?.shared_task?.environment_thread_id, threadId);

const beforeTaskFiles = await listJsonFiles(taskDirectory);
const beforeTaskSet = await taskSetProjection(beforeTaskFiles);
const beforeCycleFiles = await listJsonFiles(cycleDirectory);
const beforeSourceResultHash = hashJson(
  before.task.shared_task.source_tool_result ?? null,
);

const port = await freePort();
let child = null;
let stdout = "";
let stderr = "";
let recovered = null;
try {
  child = spawn(nodePath, [serverPath], {
    cwd: packageRoot,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "mock",
      PANEL_PORT: String(port),
      PANEL_RUNTIME_DIR: runtimeDirectory,
      PANEL_AGENT_WORKSPACE: root,
      PANEL_SKILL_MANIFEST: join(
        process.env.USERPROFILE ?? "",
        ".codex",
        "skills",
        "pc-hardware-workbench",
        "workbench.manifest.json",
      ),
      PANEL_SKILL_ID: "pc-hardware-workbench",
      PANEL_SOURCE_HOSTED_ENTRY: "1",
      PANEL_SOURCE_HOSTED_NON_MOCK: "",
      PANEL_SOURCE_HOSTED_SHADOW: "",
      PANEL_SURFACE_MODE: "read-only",
      PANEL_AGENT_SANDBOX: "read-only",
      PANEL_AGENT_APPROVAL_POLICY: "never",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  await waitForHealth(baseUrl, child, () => stderr);
  const panelToken = (
    await readFile(
      join(runtimeDirectory, "panel-capability-token"),
      "utf8",
    )
  ).trim();
  const masterToken = (
    await readFile(join(runtimeDirectory, "capability-token"), "utf8")
  ).trim();
  const response = await fetch(`${baseUrl}/api/task/recover`, {
    method: "POST",
    headers: {
      Cookie: `panel_token=${encodeURIComponent(panelToken)}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      confirm: "recover_current_task",
    }),
  });
  const responseBody = await response.json();
  assert.equal(
    response.status,
    200,
    JSON.stringify({
      status: response.status,
      code: responseBody.code,
      error: responseBody.error,
    }),
  );
  recovered = responseBody;
  await fetch(`${baseUrl}/api/shutdown`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${masterToken}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  }).catch(() => {});
  await Promise.race([
    new Promise((resolvePromise) => child.once("exit", resolvePromise)),
    new Promise((resolvePromise) => setTimeout(resolvePromise, 5_000)),
  ]);
  if (child.exitCode === null) {
    throw new Error("mock recovery runtime did not stop cleanly");
  }
  const stoppedPid = child.pid;
  child = null;
  assert.equal(processAlive(stoppedPid), false);

  const after = JSON.parse(
    (await readFile(statePath, "utf8")).replace(/^\uFEFF/u, ""),
  );
  const afterTaskFiles = await listJsonFiles(taskDirectory);
  const afterTaskSet = await taskSetProjection(afterTaskFiles);
  const afterCycleFiles = await listJsonFiles(cycleDirectory);
  assert.equal(after.task.task_id, before.task.task_id);
  assert.equal(after.task.shared_task.phase, "source_owned");
  assert.equal(after.task.shared_task.cycle_generation, 2);
  assert.equal(
    (after.task.attachments ?? []).length,
    (before.task.attachments ?? []).length,
  );
  assert.equal(
    (after.task.artifacts ?? []).length,
    (before.task.artifacts ?? []).length,
  );
  assert.equal(
    (after.task.timeline ?? []).length,
    (before.task.timeline ?? []).length,
  );
  assert.equal(afterTaskSet.count, beforeTaskSet.count);
  assert.equal(afterTaskSet.sha256, beforeTaskSet.sha256);
  assert.equal(afterCycleFiles.length, beforeCycleFiles.length + 1);
  assert.equal(
    hashJson(after.task.shared_task.source_tool_result ?? null),
    beforeSourceResultHash,
  );

  const evidence = {
    schema_version: "1.0",
    status: "passed",
    gate: "pchw_same_task_stuck_cycle_recovery",
    task_ref: after.task.task_id,
    source_session_hash: sha256(threadId),
    phase_before: before.task.shared_task.phase,
    phase_after: after.task.shared_task.phase,
    cycle_generation_before:
      Number(before.task.shared_task.cycle_generation ?? 0),
    cycle_generation_after:
      Number(after.task.shared_task.cycle_generation ?? 0),
    attachments_before: (before.task.attachments ?? []).length,
    attachments_after: (after.task.attachments ?? []).length,
    artifacts_before: (before.task.artifacts ?? []).length,
    artifacts_after: (after.task.artifacts ?? []).length,
    timeline_before: (before.task.timeline ?? []).length,
    timeline_after: (after.task.timeline ?? []).length,
    task_projection_count: afterTaskSet.count,
    task_projection_sha256: afterTaskSet.sha256,
    task_projection_unchanged:
      beforeTaskSet.sha256 === afterTaskSet.sha256,
    cycle_archive_count_before: beforeCycleFiles.length,
    cycle_archive_count_after: afterCycleFiles.length,
    cycle_archive_ref: recovered.cycle_archive_ref,
    source_tool_result_preserved: true,
    runtime_stopped: true,
    driver: "mock",
    thread_api_calls: 0,
    real_thread_created: false,
    observed_at: new Date().toISOString(),
  };
  await mkdir(dirname(evidencePath), { recursive: true });
  await writeFile(
    evidencePath,
    `${JSON.stringify(evidence, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify(evidence, null, 2)}\n`);
} finally {
  if (child) await stopChild(child);
}
