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
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  beginTaskDataCleanup,
  createRuntimeBackupExport,
  createTaskDataExport,
  recoverTaskDataCleanupQuarantines,
  verifyTaskDataExport,
} from "../lib/storage-exports.mjs";
import {
  getStorageSnapshot,
} from "../lib/storage-maintenance.mjs";

const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-storage-exports-"));
const localRoot = join(tempRoot, "SkillDock");
const runtimeDir = join(localRoot, "runtime-pchw");
const backupRoot = join(tempRoot, "SkillDockBackups", "runtime");
const backupPath = join(
  backupRoot,
  "Runtime-previous-backup-20261120-120000",
);
const engineId = "node-24.22.1-0123456789abcdef";
const enginePath = join(localRoot, "engines", engineId);
const nodePath = join(enginePath, "node.exe");

async function sha256(path) {
  const { readFile } = await import("node:fs/promises");
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function archiveEntries(path) {
  const script = String.raw`
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($env:STORAGE_EXPORT_ARCHIVE)
try {
    ConvertTo-Json -Compress -InputObject @(
        $zip.Entries | ForEach-Object { $_.FullName }
    )
}
finally {
    $zip.Dispose()
}
`;
  const child = spawn(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", script],
    {
      windowsHide: true,
      env: {
        ...process.env,
        STORAGE_EXPORT_ARCHIVE: path,
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const code = await new Promise((resolvePromise) =>
    child.once("exit", resolvePromise)
  );
  assert.equal(code, 0, stderr);
  return JSON.parse(stdout);
}

try {
  await Promise.all([
    mkdir(backupPath, { recursive: true }),
    mkdir(enginePath, { recursive: true }),
    mkdir(join(runtimeDir, "tasks"), { recursive: true }),
    mkdir(join(runtimeDir, "attachments"), { recursive: true }),
    mkdir(join(runtimeDir, "artifacts"), { recursive: true }),
  ]);
  await writeFile(join(backupPath, "app.bin"), "backup");
  await writeFile(join(enginePath, "node.exe"), "node-engine");
  await writeFile(join(enginePath, "ENGINE.json"), "{}\n");
  const nodeDigest = await sha256(nodePath);
  await writeFile(
    join(backupPath, "engine-location.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      engine_id: engineId,
      node_path: nodePath,
      node_sha256: nodeDigest,
    })}\n`,
  );
  await writeFile(join(runtimeDir, "state.json"), "{}\n");
  await writeFile(join(runtimeDir, "events.jsonl"), '{"type":"seed"}\n');
  await writeFile(
    join(runtimeDir, "agent-protocol.jsonl"),
    '{"type":"agent.seed"}\n',
  );
  await writeFile(join(runtimeDir, "capability-token"), "must-not-export\n");
  await writeFile(join(runtimeDir, "tasks", "task.json"), "{}\n");
  await writeFile(join(runtimeDir, "attachments", "sample.csv"), "a,b\n");
  await writeFile(join(runtimeDir, "artifacts", "chart.svg"), "<svg/>\n");
  await writeFile(
    join(localRoot, "runtime-location.json"),
    `${JSON.stringify({
      runtime_path: join(localRoot, "Runtime-current", "SkillDock.exe"),
      previous_runtime_path: join(
        localRoot,
        "Runtime-previous",
        "SkillDock.exe",
      ),
      previous_runtime_backup_path: backupPath,
      backup_root: backupRoot,
    })}\n`,
  );

  const backupExport = await createRuntimeBackupExport({
    localRoot,
    runtimeDir,
  });
  assert.equal(backupExport.kind, "runtime-backup");
  const backupEntries = await archiveEntries(
    join(localRoot, "storage-exports", backupExport.export_id),
  );
  assert.ok(
    backupEntries.includes(
      `runtime-backup/Runtime-previous-backup-20261120-120000/app.bin`,
    ),
  );
  assert.ok(backupEntries.includes(`engines/${engineId}/node.exe`));
  assert.ok(backupEntries.includes("EXPORT-MANIFEST.json"));

  const taskExport = await createTaskDataExport(
    { localRoot, runtimeDir },
    { task_id: "task-export-test", session_ref: "thread-export-test" },
  );
  assert.equal(taskExport.kind, "task-data");
  const taskEntries = await archiveEntries(
    join(localRoot, "storage-exports", taskExport.export_id),
  );
  assert.ok(taskEntries.includes("runtime-data/state.json"));
  assert.ok(taskEntries.includes("runtime-data/agent-protocol.jsonl"));
  assert.ok(taskEntries.includes("runtime-data/tasks/task.json"));
  assert.ok(taskEntries.includes("runtime-data/attachments/sample.csv"));
  assert.ok(taskEntries.includes("runtime-data/artifacts/chart.svg"));
  assert.equal(
    taskEntries.some((entry) => entry.includes("capability-token")),
    false,
  );
  assert.equal(
    taskEntries.some((entry) => entry.includes("handoff-secret")),
    false,
  );

  await verifyTaskDataExport(
    { localRoot, runtimeDir },
    {
      export_id: taskExport.export_id,
      export_sha256: taskExport.sha256,
    },
  );
  await assert.rejects(
    () => verifyTaskDataExport(
      { localRoot, runtimeDir },
      {
        export_id: taskExport.export_id,
        export_sha256: taskExport.sha256,
      },
      {
        task_id: "task-export-test",
        session_ref: "thread-export-test",
        event_count: 0,
        state_sha256: "f".repeat(64),
      },
    ),
    (error) => error.code === "task_export_stale",
  );
  await assert.rejects(
    () => verifyTaskDataExport(
      { localRoot, runtimeDir },
      {
        export_id: taskExport.export_id,
        export_sha256: "0".repeat(64),
      },
    ),
    (error) => error.code === "task_export_invalid",
  );

  const snapshot = await getStorageSnapshot({ localRoot, runtimeDir });
  assert.equal(snapshot.categories.storage_exports.exports.length, 2);

  const recExportRecordPath = join(
    localRoot,
    "storage-exports",
    `${taskExport.export_id}.json`,
  );
  const originalTaskRecord = JSON.parse(
    await readFile(recExportRecordPath, "utf8"),
  );
  await writeFile(
    recExportRecordPath,
    `${JSON.stringify({
      ...originalTaskRecord,
      expires_at: "2000-01-01T00:00:00.000Z",
    }, null, 2)}\n`,
  );
  await assert.rejects(
    () => verifyTaskDataExport(
      { localRoot, runtimeDir },
      {
        export_id: taskExport.export_id,
        export_sha256: taskExport.sha256,
      },
    ),
    (error) => error.code === "task_export_expired",
  );
  await writeFile(
    recExportRecordPath,
    `${JSON.stringify(originalTaskRecord, null, 2)}\n`,
  );

  const interrupted = await beginTaskDataCleanup({ localRoot, runtimeDir });
  const recovery = await recoverTaskDataCleanupQuarantines({
    localRoot,
    runtimeDir,
  });
  assert.equal(recovery.restored, 1);
  assert.equal(recovery.pending, 0);
  await assert.rejects(() => stat(interrupted.quarantinePath), {
    code: "ENOENT",
  });
  assert.equal((await stat(join(runtimeDir, "state.json"))).isFile(), true);
  assert.equal((await stat(join(runtimeDir, "tasks"))).isDirectory(), true);

  const committedQuarantine = join(
    runtimeDir,
    ".task-data-cleanup-00000000-0000-4000-8000-000000000001",
  );
  await mkdir(committedQuarantine, { recursive: false });
  await writeFile(join(committedQuarantine, "old-state.json"), "{}\n");
  await writeFile(join(committedQuarantine, ".committed"), "test\n");
  const committedRecovery = await recoverTaskDataCleanupQuarantines({
    localRoot,
    runtimeDir,
  });
  assert.equal(committedRecovery.removed, 1);
  assert.equal(committedRecovery.pending, 0);
  await assert.rejects(() => stat(committedQuarantine), {
    code: "ENOENT",
  });

  const cleanup = await beginTaskDataCleanup({ localRoot, runtimeDir });
  await assert.rejects(() => stat(join(runtimeDir, "tasks")), {
    code: "ENOENT",
  });
  await cleanup.commit();
  await assert.rejects(() => stat(cleanup.quarantinePath), {
    code: "ENOENT",
  });

  console.log("Shared-engine backup and Task data exports: PASS");
} finally {
  await rm(tempRoot, { recursive: true, force: true });
}
