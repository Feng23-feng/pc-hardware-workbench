import assert from "node:assert/strict";
import {
  mkdir,
  mkdtemp,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  cleanupRuntimeBackups,
  getStorageSnapshot,
} from "../lib/storage-maintenance.mjs";

const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-storage-"));
const localRoot = join(tempRoot, "SkillDock");
const runtimeDir = join(localRoot, "runtime-pchw");
const runtimeProgram = join(localRoot, "Runtime-current");
const backupRoot = join(tempRoot, "SkillDockBackups", "runtime");
const engineRoot = join(localRoot, "engines");
const activeEngine = join(engineRoot, "node-24.22.1-0123456789abcdef");
const staleEngine = join(engineRoot, "node-24.22.1-fedcba9876543210");
const unmanagedEngine = join(
  engineRoot,
  "node-24.22.1-1111111111111111",
);
const protectedBackup = join(
  backupRoot,
  "Runtime-previous-backup-20261120-120000",
);
const olderBackup = join(
  backupRoot,
  "Runtime-older-backup-20261119-120000",
);
const oldestBackup = join(
  backupRoot,
  "Runtime-oldest-backup-20261118-120000",
);
const unmanagedBackup = join(backupRoot, "ManualKeep");

async function writeSizedFile(path, bytes, fill = "a") {
  await writeFile(path, Buffer.alloc(bytes, fill));
}

async function writeEngineReference(runtimeDirectory, engineId, nodePath) {
  await mkdir(runtimeDirectory, { recursive: true });
  await writeFile(
    join(runtimeDirectory, "engine-location.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      engine_id: engineId,
      node_path: nodePath,
      node_sha256: "a".repeat(64),
    })}\n`,
    "utf8",
  );
}

try {
  await Promise.all([
    mkdir(join(runtimeDir, "tasks"), { recursive: true }),
    mkdir(join(runtimeDir, "attachments"), { recursive: true }),
    mkdir(join(runtimeDir, "artifacts"), { recursive: true }),
    mkdir(join(localRoot, "install-logs"), { recursive: true }),
    mkdir(runtimeProgram, { recursive: true }),
    mkdir(activeEngine, { recursive: true }),
    mkdir(staleEngine, { recursive: true }),
    mkdir(unmanagedEngine, { recursive: true }),
    mkdir(protectedBackup, { recursive: true }),
    mkdir(olderBackup, { recursive: true }),
    mkdir(oldestBackup, { recursive: true }),
    mkdir(unmanagedBackup, { recursive: true }),
  ]);
  await Promise.all([
    writeSizedFile(join(runtimeProgram, "SkillDock.exe"), 1024),
    writeSizedFile(join(activeEngine, "node.exe"), 2048),
    writeSizedFile(join(staleEngine, "node.exe"), 4096),
    writeSizedFile(join(unmanagedEngine, "node.exe"), 8192),
    writeSizedFile(join(runtimeDir, "tasks", "task.json"), 128),
    writeSizedFile(join(runtimeDir, "attachments", "sample.csv"), 256),
    writeSizedFile(join(runtimeDir, "artifacts", "chart.svg"), 512),
    writeSizedFile(join(runtimeDir, "events.jsonl"), 64),
    writeSizedFile(join(localRoot, "install-logs", "install.log"), 32),
    writeSizedFile(join(localRoot, "launcher.log"), 16),
    writeSizedFile(join(protectedBackup, "app.bin"), 512),
    writeSizedFile(join(olderBackup, "app.bin"), 1024),
    writeSizedFile(join(oldestBackup, "app.bin"), 2048),
    writeSizedFile(join(unmanagedBackup, "keep.bin"), 8192),
  ]);
  await writeEngineReference(
    runtimeProgram,
    "node-24.22.1-0123456789abcdef",
    join(activeEngine, "node.exe"),
  );
  await writeEngineReference(
    protectedBackup,
    "node-24.22.1-0123456789abcdef",
    join(activeEngine, "node.exe"),
  );
  await writeEngineReference(
    unmanagedBackup,
    "node-24.22.1-1111111111111111",
    join(unmanagedEngine, "node.exe"),
  );
  await writeFile(
    join(localRoot, "runtime-location.json"),
    `${JSON.stringify({
      runtime_path: join(runtimeProgram, "SkillDock.exe"),
      previous_runtime_path: join(
        localRoot,
        "Runtime-previous",
        "SkillDock.exe",
      ),
      previous_runtime_backup_path: protectedBackup,
      backup_root: backupRoot,
      node_engine: {
        engine_id: "node-24.22.1-0123456789abcdef",
        node_path: join(activeEngine, "node.exe"),
      },
    })}\n`,
    "utf8",
  );

  const before = await getStorageSnapshot({ localRoot, runtimeDir });
  assert.equal(before.schema_version, "1.0");
  assert.equal(before.categories.task_records.bytes, 128);
  assert.equal(before.categories.attachments.bytes, 256);
  assert.equal(before.categories.artifacts.bytes, 512);
  assert.equal(before.categories.runtime_state.bytes, 64);
  assert.equal(before.categories.install_logs.bytes, 32);
  assert.equal(before.categories.shared_engines.bytes, 14_336);
  assert.equal(before.categories.runtime_backups.directory_count, 4);
  assert.equal(before.categories.runtime_backups.unmanaged_directory_count, 1);
  assert.ok(before.categories.runtime_backups.bytes > 11_776);
  assert.equal(before.cleanup.available, true);
  assert.equal(before.cleanup.cleanable_backup_count, 2);
  assert.equal(
    before.cleanup.protected_backup_name,
    "Runtime-previous-backup-20261120-120000",
  );
  assert.equal(before.cleanup.estimated_reclaim_bytes, 3072);

  await assert.rejects(
    () => cleanupRuntimeBackups(
      { localRoot, runtimeDir },
      { confirm: "wrong" },
    ),
    (error) => error.code === "confirmation_required",
  );
  const cleanup = await cleanupRuntimeBackups(
    { localRoot, runtimeDir },
    { confirm: "cleanup-runtime-backups" },
  );
  assert.equal(cleanup.removed_backup_count, 2);
  assert.equal(cleanup.reclaimed_bytes, 3072);
  assert.equal(
    cleanup.protected_backup_name,
    "Runtime-previous-backup-20261120-120000",
  );
  assert.equal(cleanup.engine_cleanup.removed_engine_count, 1);
  const after = await getStorageSnapshot({ localRoot, runtimeDir });
  assert.equal(after.cleanup.cleanable_backup_count, 0);
  assert.equal(
    before.categories.runtime_backups.bytes -
      after.categories.runtime_backups.bytes,
    cleanup.reclaimed_bytes,
  );
  assert.deepEqual(
    after.cleanup.backups.map((backup) => backup.name),
    ["Runtime-previous-backup-20261120-120000"],
  );
  assert.equal((await stat(protectedBackup)).isDirectory(), true);
  assert.equal((await stat(unmanagedBackup)).isDirectory(), true);
  assert.equal((await stat(activeEngine)).isDirectory(), true);
  assert.equal((await stat(unmanagedEngine)).isDirectory(), true);

  console.log("Storage inventory and safe Runtime backup cleanup: PASS");
} finally {
  await rm(tempRoot, { recursive: true, force: true });
}
