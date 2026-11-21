import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const serverEntry = process.env.STORAGE_SERVER_ENTRY
  ? resolve(process.env.STORAGE_SERVER_ENTRY)
  : join(root, "server.mjs");
const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-storage-api-"));
const localRoot = join(tempRoot, "SkillDock");
const runtimeDir = join(localRoot, "runtime-pchw");
const runtimeProgram = join(localRoot, "Runtime-current");
const backupRoot = join(tempRoot, "SkillDockBackups", "runtime");
const engineRoot = join(localRoot, "engines");
const activeEngine = join(engineRoot, "node-24.22.1-0123456789abcdef");
const protectedBackup = join(
  backupRoot,
  "Runtime-previous-backup-20261120-120000",
);
const obsoleteBackup = join(
  backupRoot,
  "Runtime-old-backup-20261119-120000",
);
const unmanagedBackup = join(backupRoot, "ManualKeep");
const installLogsRoot = join(localRoot, "install-logs");
const port = await new Promise((resolvePromise, rejectPromise) => {
  const server = createTcpServer();
  server.unref();
  server.once("error", rejectPromise);
  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    const selectedPort =
      address && typeof address === "object" ? address.port : null;
    server.close((error) => {
      if (error) rejectPromise(error);
      else resolvePromise(selectedPort);
    });
  });
});
const base = `http://127.0.0.1:${port}`;

async function writeSizedFile(path, bytes, fill) {
  await writeFile(path, Buffer.alloc(bytes, fill));
}

async function writeEngineReference(
  runtimeDirectory,
  engineId,
  nodePath,
  nodeSha256,
) {
  await mkdir(runtimeDirectory, { recursive: true });
  await writeFile(
    join(runtimeDirectory, "engine-location.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      engine_id: engineId,
      node_path: nodePath,
      node_sha256: nodeSha256,
    })}\n`,
    "utf8",
  );
}

await Promise.all([
  mkdir(runtimeDir, { recursive: true }),
  mkdir(runtimeProgram, { recursive: true }),
  mkdir(activeEngine, { recursive: true }),
  mkdir(protectedBackup, { recursive: true }),
  mkdir(obsoleteBackup, { recursive: true }),
  mkdir(unmanagedBackup, { recursive: true }),
  mkdir(installLogsRoot, { recursive: true }),
]);
await Promise.all([
  writeSizedFile(join(runtimeProgram, "SkillDock.exe"), 1024, "r"),
  writeSizedFile(join(activeEngine, "node.exe"), 2048, "n"),
  writeSizedFile(join(protectedBackup, "app.bin"), 512, "p"),
  writeSizedFile(join(obsoleteBackup, "app.bin"), 1024, "o"),
  writeSizedFile(join(unmanagedBackup, "keep.bin"), 4096, "k"),
  writeSizedFile(join(installLogsRoot, "install.log"), 128, "l"),
]);
const engineDigest = createHash("sha256")
  .update(await readFile(join(activeEngine, "node.exe")))
  .digest("hex");
await Promise.all([
  writeEngineReference(
    runtimeProgram,
    "node-24.22.1-0123456789abcdef",
    join(activeEngine, "node.exe"),
    engineDigest,
  ),
  writeEngineReference(
    protectedBackup,
    "node-24.22.1-0123456789abcdef",
    join(activeEngine, "node.exe"),
    engineDigest,
  ),
]);
await writeFile(
  join(localRoot, "runtime-location.json"),
  `${JSON.stringify({
    runtime_path: join(runtimeProgram, "SkillDock.exe"),
    previous_runtime_backup_path: protectedBackup,
    backup_root: backupRoot,
  })}\n`,
  "utf8",
);

const child = spawn(process.execPath, [serverEntry], {
  cwd: root,
  windowsHide: true,
  env: {
    ...process.env,
    PANEL_AGENT_DRIVER: process.env.STORAGE_AGENT_DRIVER ?? "mock",
    PANEL_PORT: String(port),
    PANEL_RUNTIME_DIR: runtimeDir,
    PANEL_AGENT_WORKSPACE: root,
    PANEL_SOURCE_HOSTED_ENTRY:
      process.env.STORAGE_AGENT_DRIVER === "source-external" ? "1" : "",
    PANEL_SOURCE_HOSTED_NON_MOCK:
      process.env.STORAGE_AGENT_DRIVER === "source-external" ? "1" : "",
    PANEL_SKILL_ID: "pc-hardware-workbench",
    PANEL_SKILL_MANIFEST: join(
      root,
      "skills",
      "pc-hardware-workbench",
      "workbench.manifest.json",
    ),
    SKILLDOCK_LOCAL_ROOT: localRoot,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let stderr = "";
child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

async function waitForHealth() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`storage API server exited early\n${stderr}`);
    }
    try {
      const response = await fetch(`${base}/api/health`);
      if (response.ok) return;
    } catch {
      // Listener is still starting.
    }
    await new Promise((resolvePromise) =>
      setTimeout(resolvePromise, 100)
    );
  }
  throw new Error(`storage API server health timeout\n${stderr}`);
}

try {
  await waitForHealth();
  const page = await fetch(`${base}/`);
  const cookie = page.headers.getSetCookie()[0].split(";")[0];
  const request = async (path, options = {}) => {
    const response = await fetch(`${base}${path}`, {
      ...options,
      headers: {
        Cookie: cookie,
        "Content-Type": "application/json",
        ...(options.headers ?? {}),
      },
    });
    return { response, data: await response.json() };
  };

  let result = await request("/api/storage");
  assert.equal(result.response.status, 200);
  assert.equal(result.data.cleanup.available, true);
  assert.equal(result.data.cleanup.cleanable_backup_count, 1);
  assert.equal(
    result.data.cleanup.protected_backup_name,
    "Runtime-previous-backup-20261120-120000",
  );

  const runtimeExport = await request(
    "/api/storage/export-runtime-backup",
    { method: "POST", body: "{}" },
  );
  assert.equal(runtimeExport.response.status, 201);
  assert.equal(runtimeExport.data.kind, "runtime-backup");
  assert.match(runtimeExport.data.export_id, /^runtime-backup-/u);
  const runtimeDownload = await fetch(
    `${base}${runtimeExport.data.download_path}`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(runtimeDownload.status, 200);
  assert.equal(runtimeDownload.headers.get("content-type"), "application/zip");
  const runtimeBytes = Buffer.from(await runtimeDownload.arrayBuffer());
  assert.equal(runtimeBytes.subarray(0, 2).toString(), "PK");

  const staleTaskExport = await request("/api/storage/export-task-data", {
    method: "POST",
    body: "{}",
  });
  assert.equal(staleTaskExport.response.status, 201);
  assert.equal(staleTaskExport.data.kind, "task-data");
  assert.match(staleTaskExport.data.export_id, /^task-data-/u);
  const taskDownload = await fetch(
    `${base}${staleTaskExport.data.download_path}`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(taskDownload.status, 200);
  const taskBytes = Buffer.from(await taskDownload.arrayBuffer());
  assert.equal(taskBytes.subarray(0, 2).toString(), "PK");

  result = await request("/api/storage/cleanup-runtime-backups", {
    method: "POST",
    body: JSON.stringify({ confirm: "wrong" }),
  });
  assert.equal(result.response.status, 400);
  assert.equal(result.data.code, "confirmation_required");

  result = await request("/api/storage/cleanup-runtime-backups", {
    method: "POST",
    body: JSON.stringify({ confirm: "cleanup-runtime-backups" }),
  });
  assert.equal(result.response.status, 200);
  assert.equal(result.data.removed_backup_count, 1);
  assert.equal(result.data.reclaimed_bytes, 1024);
  assert.equal(result.data.audit_recorded, true);
  assert.equal((await stat(protectedBackup)).isDirectory(), true);
  assert.equal((await stat(unmanagedBackup)).isDirectory(), true);
  await assert.rejects(() => stat(obsoleteBackup), { code: "ENOENT" });

  const events = await readFile(join(runtimeDir, "events.jsonl"), "utf8");
  assert.match(events, /"type":"storage\.runtime_backup_cleanup"/u);
  assert.equal(events.includes(backupRoot), false);
  assert.equal(events.includes(localRoot), false);

  result = await request("/api/storage/cleanup-install-logs", {
    method: "POST",
    body: JSON.stringify({ confirm: "wrong" }),
  });
  assert.equal(result.response.status, 400);
  assert.equal(result.data.code, "confirmation_required");

  result = await request("/api/storage/cleanup-install-logs", {
    method: "POST",
    body: JSON.stringify({ confirm: "cleanup-install-logs" }),
  });
  assert.equal(result.response.status, 200);
  assert.equal(result.data.removed_file_count, 1);
  assert.equal(result.data.reclaimed_bytes, 128);
  assert.equal(result.data.audit_recorded, true);
  await assert.rejects(() => stat(installLogsRoot), { code: "ENOENT" });

  const finalEvents = await readFile(
    join(runtimeDir, "events.jsonl"),
    "utf8",
  );
  assert.match(finalEvents, /"type":"storage\.install_log_cleanup"/u);
  assert.equal(finalEvents.includes(installLogsRoot), false);

  result = await request("/api/storage/cleanup-task-data", {
    method: "POST",
    body: JSON.stringify({
      confirm: "cleanup-task-data",
      export_id: staleTaskExport.data.export_id,
      export_sha256: staleTaskExport.data.sha256,
    }),
  });
  assert.equal(result.response.status, 409);
  assert.equal(result.data.code, "task_export_stale");
  assert.equal((await stat(join(runtimeDir, "tasks"))).isDirectory(), true);

  const taskExport = await request("/api/storage/export-task-data", {
    method: "POST",
    body: "{}",
  });
  assert.equal(taskExport.response.status, 201);
  const freshTaskDownload = await fetch(
    `${base}${taskExport.data.download_path}`,
    { headers: { Cookie: cookie } },
  );
  assert.equal(freshTaskDownload.status, 200);

  result = await request("/api/storage/cleanup-task-data", {
    method: "POST",
    body: JSON.stringify({
      confirm: "wrong",
      export_id: taskExport.data.export_id,
      export_sha256: taskExport.data.sha256,
    }),
  });
  assert.equal(result.response.status, 400);
  assert.equal(result.data.code, "confirmation_required");

  result = await request("/api/storage/cleanup-task-data", {
    method: "POST",
    body: JSON.stringify({
      confirm: "cleanup-task-data",
      export_id: taskExport.data.export_id,
      export_sha256: taskExport.data.sha256,
    }),
  });
  assert.equal(result.response.status, 200);
  assert.equal(result.data.cleanup_completed, true);
  assert.equal(result.data.audit_recorded, true);
  assert.equal(result.data.state.task, null);
  assert.equal(
    (await stat(join(runtimeDir, "tasks"))).isDirectory(),
    true,
  );
  assert.equal(
    (await stat(join(runtimeDir, "capability-token"))).isFile(),
    true,
  );
  const taskCleanupEvents = await readFile(
    join(runtimeDir, "events.jsonl"),
    "utf8",
  );
  assert.match(taskCleanupEvents, /"type":"storage\.task_data_cleanup"/u);
  assert.equal(taskCleanupEvents.includes("capability-token"), false);

  console.log("Storage API read and confirmed cleanup: PASS");
} finally {
  if (child.exitCode === null) {
    await fetch(`${base}/api/shutdown`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}",
    }).catch(() => {});
    child.kill();
  }
  await rm(tempRoot, { recursive: true, force: true });
}
