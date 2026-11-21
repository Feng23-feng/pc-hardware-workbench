import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  lstat,
  mkdir,
  readFile,
  readdir,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";
import {
  resolveProtectedRuntimeBackup,
  resolveStorageContext,
} from "./storage-maintenance.mjs";

const archiveHelperPath = resolve(
  import.meta.dirname,
  "export-storage-archive.ps1",
);
const EXPORT_NAME =
  /^(?<kind>runtime-backup|task-data)-\d{8}-\d{6}-[0-9a-f-]{36}\.zip$/u;
const TASK_EXPORT_NAME =
  /^task-data-\d{8}-\d{6}-[0-9a-f-]{36}\.zip$/u;
const SHARED_ENGINE_NAME =
  /^node-\d+\.\d+\.\d+-[0-9a-f]{16}$/u;
const EXPORT_RETENTION_MS = 24 * 60 * 60 * 1_000;
const TASK_CLEANUP_NAME =
  /^\.task-data-cleanup-[0-9a-f-]{36}$/u;
const TASK_CLEANUP_COMMITTED = ".committed";

function isWithin(rootPath, candidatePath) {
  const pathFromRoot = relative(resolve(rootPath), resolve(candidatePath));
  return (
    pathFromRoot.length > 0 &&
    !pathFromRoot.startsWith("..") &&
    !isAbsolute(pathFromRoot)
  );
}

async function readJsonOptional(path) {
  try {
    const text = (await readFile(path, "utf8")).replace(/^\uFEFF/u, "");
    return JSON.parse(text);
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

async function ensureExportRoot(context) {
  try {
    const entry = await lstat(context.exportRoot);
    if (!entry.isDirectory() || entry.isSymbolicLink()) {
      const error = new Error("Storage export root must be a regular directory.");
      error.code = "storage_export_root_invalid";
      throw error;
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    await mkdir(context.exportRoot, { recursive: true, mode: 0o700 });
  }
}

function exportExpired(record) {
  const expiresAt = Date.parse(String(record?.expires_at ?? ""));
  return !Number.isFinite(expiresAt) || expiresAt <= Date.now();
}

function exportName(kind) {
  const stamp = new Date()
    .toISOString()
    .replace(/[-:]/gu, "")
    .replace(/\.\d{3}Z$/u, "")
    .replace("T", "-")
    .replace(/Z$/u, "");
  return `${kind}-${stamp}-${randomUUID()}.zip`;
}

function validateExportName(fileName, pattern = EXPORT_NAME) {
  if (!pattern.test(fileName)) {
    const error = new Error("Storage export name is invalid.");
    error.code = "storage_export_invalid";
    throw error;
  }
}

function exportPath(context, fileName, pattern = EXPORT_NAME) {
  validateExportName(fileName, pattern);
  const path = resolve(context.exportRoot, fileName);
  if (!isWithin(context.exportRoot, path)) {
    const error = new Error("Storage export path escaped its root.");
    error.code = "storage_export_invalid";
    throw error;
  }
  return path;
}

async function runArchive(spec, outputPath) {
  const temporarySpec = join(
    dirname(outputPath),
    `.export-spec-${randomUUID()}.json`,
  );
  await writeFile(temporarySpec, `${JSON.stringify(spec, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  try {
    const result = await new Promise((resolvePromise, rejectPromise) => {
      const child = spawn(
        "powershell.exe",
        [
          "-NoProfile",
          "-NonInteractive",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          archiveHelperPath,
          "-SpecPath",
          temporarySpec,
          "-OutputPath",
          outputPath,
        ],
        {
          windowsHide: true,
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let stdout = "";
      let stderr = "";
      const timeout = setTimeout(() => {
        child.kill();
        rejectPromise(new Error("Storage export timed out."));
      }, 180_000);
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });
      child.once("error", (error) => {
        clearTimeout(timeout);
        rejectPromise(error);
      });
      child.once("exit", (code) => {
        clearTimeout(timeout);
        if (code !== 0) {
          rejectPromise(
            new Error(`Storage export failed: ${stderr.trim()}`),
          );
          return;
        }
        const lines = stdout.trim().split(/\r?\n/u).filter(Boolean);
        try {
          resolvePromise(JSON.parse(lines.at(-1)));
        } catch (error) {
          rejectPromise(
            new Error(`Storage export returned invalid JSON: ${error.message}`),
          );
        }
      });
    });
    return result;
  } finally {
    await rm(temporarySpec, { force: true }).catch(() => {});
  }
}

async function writeExportRecord(context, outputPath, result, metadata) {
  const fileName = basename(outputPath);
  const digest = await sha256File(outputPath);
  const record = {
    schema_version: "1.0",
    export_id: fileName,
    kind: result.kind,
    created_at: new Date().toISOString(),
    expires_at: new Date(Date.now() + EXPORT_RETENTION_MS).toISOString(),
    bytes: result.bytes,
    sha256: digest,
    file_count: result.file_count,
    metadata,
  };
  const recordPath = `${outputPath}.json`;
  const temporaryRecordPath = `${recordPath}.${randomUUID()}.tmp`;
  try {
    await writeFile(temporaryRecordPath, `${JSON.stringify(record, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    await rename(temporaryRecordPath, recordPath);
  } finally {
    await rm(temporaryRecordPath, { force: true }).catch(() => {});
  }
  return record;
}

export async function pruneStorageExports(options = {}) {
  const context = resolveStorageContext(options);
  let entries = [];
  try {
    entries = await readdir(context.exportRoot, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") return { removed: 0 };
    throw error;
  }
  let removed = 0;
  const cutoff = Date.now() - EXPORT_RETENTION_MS;
  for (const entry of entries) {
    if (!entry.isFile()) continue;
    const fileName = entry.name.replace(/\.json$/u, "");
    if (!EXPORT_NAME.test(fileName)) continue;
    const path = join(context.exportRoot, entry.name);
    try {
      const fileStat = await lstat(path);
      if (fileStat.mtimeMs >= cutoff) continue;
      await rm(path, { force: true });
      removed += 1;
    } catch {
      // Export pruning is best-effort and never blocks storage inventory.
    }
  }
  return { removed };
}

export async function createRuntimeBackupExport(options = {}) {
  const context = resolveStorageContext(options);
  await ensureExportRoot(context);
  await pruneStorageExports(options);
  const { pointer, backup } = await resolveProtectedRuntimeBackup(options);
  const engineReference = await readJsonOptional(
    join(backup.path, "engine-location.json"),
  );
  const entries = [
    {
      source_path: backup.path,
      archive_path: `runtime-backup/${backup.name}`,
    },
  ];
  let engineMetadata = null;
  if (engineReference) {
    const engineId = String(engineReference.engine_id ?? "");
    if (
      engineReference.schema_version !== "1.0" ||
      !SHARED_ENGINE_NAME.test(engineId)
    ) {
      const error = new Error("Rollback engine reference is invalid.");
      error.code = "runtime_backup_engine_invalid";
      throw error;
    }
    const engineRootStat = await lstat(context.engineRoot).catch(() => null);
    if (!engineRootStat?.isDirectory() || engineRootStat.isSymbolicLink()) {
      const error = new Error("Shared engine root is not a regular directory.");
      error.code = "runtime_backup_engine_invalid";
      throw error;
    }
    const enginePath = resolve(context.engineRoot, engineId);
    if (!isWithin(context.engineRoot, enginePath)) {
      const error = new Error("Rollback engine path escaped its root.");
      error.code = "runtime_backup_engine_invalid";
      throw error;
    }
    const engineStat = await lstat(enginePath).catch(() => null);
    if (
      !engineStat?.isDirectory() ||
      engineStat.isSymbolicLink()
    ) {
      const error = new Error("Rollback engine is not a regular directory.");
      error.code = "runtime_backup_engine_invalid";
      throw error;
    }
    const nodePath = join(enginePath, "node.exe");
    const nodeStat = await lstat(nodePath).catch(() => null);
    if (!nodeStat?.isFile() || nodeStat.isSymbolicLink()) {
      const error = new Error("Rollback engine node.exe is not a regular file.");
      error.code = "runtime_backup_engine_invalid";
      throw error;
    }
    const nodeDigest = await sha256File(nodePath);
    if (nodeDigest !== String(engineReference.node_sha256 ?? "")) {
      const error = new Error("Rollback engine digest does not match.");
      error.code = "runtime_backup_engine_invalid";
      throw error;
    }
    entries.push({
      source_path: enginePath,
      archive_path: `engines/${engineId}`,
    });
    engineMetadata = {
      engine_id: engineId,
      node_sha256: nodeDigest,
    };
  }
  const fileName = exportName("runtime-backup");
  const outputPath = exportPath(context, fileName);
  let result;
  try {
    result = await runArchive(
      {
        schema_version: "1.0",
        kind: "runtime-backup",
        title: `SkillDock Runtime backup ${backup.name}`,
        entries,
        excluded_paths: [],
        metadata: {
          backup_name: backup.name,
          previous_runtime_path: String(pointer.previous_runtime_path ?? ""),
          node_engine: engineMetadata,
        },
      },
      outputPath,
    );
  } catch (error) {
    await rm(outputPath, { force: true }).catch(() => {});
    throw error;
  }
  let record;
  try {
    record = await writeExportRecord(
      context,
      outputPath,
      result,
      { backup_name: backup.name, node_engine: engineMetadata },
    );
  } catch (error) {
    await Promise.all([
      rm(outputPath, { force: true }).catch(() => {}),
      rm(`${outputPath}.json`, { force: true }).catch(() => {}),
    ]);
    throw error;
  }
  return publicExportRecord(record);
}

export async function createTaskDataExport(options = {}, metadata = {}) {
  const context = resolveStorageContext(options);
  await ensureExportRoot(context);
  await pruneStorageExports(options);
  const candidates = [
    ["state.json", "runtime-data/state.json"],
    ["events.jsonl", "runtime-data/events.jsonl"],
    ["agent-protocol.jsonl", "runtime-data/agent-protocol.jsonl"],
    ["shared-evidence.json", "runtime-data/shared-evidence.json"],
    ["tasks", "runtime-data/tasks"],
    ["attachments", "runtime-data/attachments"],
    ["artifacts", "runtime-data/artifacts"],
  ];
  const entries = [];
  for (const [sourceName, archivePath] of candidates) {
    const sourcePath = join(context.runtimeDir, sourceName);
    try {
      await lstat(sourcePath);
      entries.push({ source_path: sourcePath, archive_path: archivePath });
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
  }
  const fileName = exportName("task-data");
  const outputPath = exportPath(context, fileName);
  let result;
  try {
    result = await runArchive(
      {
        schema_version: "1.0",
        kind: "task-data",
        title: "SkillDock Task and evidence export",
        entries,
        excluded_paths: [],
        metadata,
      },
      outputPath,
    );
  } catch (error) {
    await rm(outputPath, { force: true }).catch(() => {});
    throw error;
  }
  let record;
  try {
    record = await writeExportRecord(
      context,
      outputPath,
      result,
      metadata,
    );
  } catch (error) {
    await Promise.all([
      rm(outputPath, { force: true }).catch(() => {}),
      rm(`${outputPath}.json`, { force: true }).catch(() => {}),
    ]);
    throw error;
  }
  return publicExportRecord(record);
}

function publicExportRecord(record) {
  return {
    schema_version: record.schema_version,
    export_id: record.export_id,
    kind: record.kind,
    created_at: record.created_at,
    expires_at: record.expires_at,
    bytes: record.bytes,
    file_count: record.file_count,
    sha256: record.sha256,
    download_path:
      `/api/storage/exports/${encodeURIComponent(record.export_id)}`,
    metadata: record.metadata,
  };
}

function assertCurrentTaskMetadata(record, expectedMetadata) {
  const actual = record.metadata ?? {};
  for (const key of [
    "task_id",
    "session_ref",
    "event_count",
    "state_sha256",
  ]) {
    if (
      expectedMetadata[key] !== undefined &&
      String(actual[key] ?? "") !== String(expectedMetadata[key] ?? "")
    ) {
      const error = new Error(
        "Task data changed after the export was generated.",
      );
      error.code = "task_export_stale";
      throw error;
    }
  }
}

export async function verifyTaskDataExport(
  options = {},
  request = {},
  expectedMetadata = {},
) {
  const context = resolveStorageContext(options);
  const exportId = String(request.export_id ?? "");
  const requestedSha = String(request.export_sha256 ?? "");
  const archivePath = exportPath(context, exportId, TASK_EXPORT_NAME);
  const record = await readJsonOptional(`${archivePath}.json`);
  if (
    !record ||
    record.kind !== "task-data" ||
    record.export_id !== exportId ||
    record.sha256 !== requestedSha
  ) {
    const error = new Error("Task export authorization is invalid.");
    error.code = "task_export_invalid";
    throw error;
  }
  if (exportExpired(record)) {
    const error = new Error("Task export has expired.");
    error.code = "task_export_expired";
    throw error;
  }
  assertCurrentTaskMetadata(record, expectedMetadata);
  const actualSha = await sha256File(archivePath).catch(() => "");
  if (actualSha !== record.sha256) {
    const error = new Error("Task export digest does not match.");
    error.code = "task_export_invalid";
    throw error;
  }
  return { context, archivePath, record };
}

export async function resolveStorageExportDownload(options = {}, exportId) {
  const context = resolveStorageContext(options);
  const archivePath = exportPath(context, String(exportId));
  const fileStat = await lstat(archivePath);
  if (!fileStat.isFile() || fileStat.isSymbolicLink()) {
    const error = new Error("Storage export is unavailable.");
    error.code = "storage_export_missing";
    throw error;
  }
  const record = await readJsonOptional(`${archivePath}.json`);
  if (
    !record ||
    record.export_id !== basename(archivePath) ||
    record.sha256 !== (await sha256File(archivePath).catch(() => ""))
  ) {
    const error = new Error("Storage export is invalid.");
    error.code = "storage_export_invalid";
    throw error;
  }
  if (exportExpired(record)) {
    const error = new Error("Storage export has expired.");
    error.code = "storage_export_expired";
    throw error;
  }
  return { context, path: archivePath, name: basename(archivePath) };
}

export async function beginTaskDataCleanup(options = {}) {
  const context = resolveStorageContext(options);
  const quarantinePath = join(
    context.runtimeDir,
    `.task-data-cleanup-${randomUUID()}`,
  );
  await mkdir(quarantinePath, { recursive: false });
  const names = [
    "state.json",
    "events.jsonl",
    "events.jsonl.cleanup.tmp",
    "agent-protocol.jsonl",
    "shared-evidence.json",
    "tasks",
    "attachments",
    "artifacts",
  ];
  const moved = [];
  try {
    for (const name of names) {
      const source = join(context.runtimeDir, name);
      try {
        await lstat(source);
      } catch (error) {
        if (error?.code === "ENOENT") continue;
        throw error;
      }
      const destination = join(quarantinePath, name);
      await rename(source, destination);
      moved.push({ name, source, destination });
    }
  } catch (error) {
    const rollbackFailures = [];
    for (const item of moved.reverse()) {
      await rename(item.destination, item.source).catch((rollbackError) => {
        rollbackFailures.push(rollbackError);
      });
    }
    if (rollbackFailures.length === 0) {
      await rm(quarantinePath, { recursive: true, force: true }).catch(() => {});
    }
    error.rollbackFailures = rollbackFailures;
    throw error;
  }
  return {
    quarantinePath,
    moved,
    async rollback() {
      const failures = [];
      for (const item of [...moved].reverse()) {
        await rename(item.destination, item.source).catch((error) => {
          failures.push(error);
        });
      }
      if (failures.length > 0) {
        throw new AggregateError(
          failures,
          "Task data rollback could not restore every quarantined item.",
        );
      }
      await rm(quarantinePath, { recursive: true, force: true }).catch(() => {});
    },
    async commit() {
      await writeFile(
        join(quarantinePath, TASK_CLEANUP_COMMITTED),
        `${new Date().toISOString()}\n`,
        { encoding: "utf8", mode: 0o600 },
      );
      let cleanupError = null;
      try {
        await rm(quarantinePath, { recursive: true, force: true });
      } catch (error) {
        cleanupError = error;
      }
      await Promise.all([
        mkdir(join(context.runtimeDir, "tasks"), { recursive: true }),
        mkdir(join(context.runtimeDir, "attachments"), { recursive: true }),
        mkdir(join(context.runtimeDir, "artifacts"), { recursive: true }),
      ]);
      if (cleanupError) throw cleanupError;
    },
  };
}

async function restoreTaskDataQuarantine(context, quarantinePath) {
  const entries = await readdir(quarantinePath, { withFileTypes: true });
  const moved = [];
  try {
    for (const entry of entries) {
      if (entry.name === TASK_CLEANUP_COMMITTED) continue;
      if (entry.isSymbolicLink()) {
        const error = new Error("Task cleanup quarantine contains a reparse point.");
        error.code = "task_cleanup_recovery_unsafe";
        throw error;
      }
      const source = join(quarantinePath, entry.name);
      const destination = join(context.runtimeDir, entry.name);
      try {
        await lstat(destination);
        const error = new Error(
          `Task cleanup recovery would overwrite ${entry.name}.`,
        );
        error.code = "task_cleanup_recovery_conflict";
        throw error;
      } catch (error) {
        if (error?.code !== "ENOENT") throw error;
      }
      await rename(source, destination);
      moved.push({ source: destination, destination: source });
    }
  } catch (error) {
    for (const item of moved.reverse()) {
      await rename(item.source, item.destination).catch(() => {});
    }
    throw error;
  }
  await rm(quarantinePath, { recursive: true, force: true });
}

export async function recoverTaskDataCleanupQuarantines(options = {}) {
  const context = resolveStorageContext(options);
  let entries = [];
  try {
    entries = await readdir(context.runtimeDir, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        restored: 0,
        removed: 0,
        pending: 0,
        failures: [],
      };
    }
    throw error;
  }
  const candidates = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !TASK_CLEANUP_NAME.test(entry.name)) continue;
    const path = join(context.runtimeDir, entry.name);
    try {
      const entryStat = await lstat(path);
      if (!entryStat.isDirectory() || entryStat.isSymbolicLink()) continue;
      const committed = await lstat(
        join(path, TASK_CLEANUP_COMMITTED),
      ).then((marker) => marker.isFile() && !marker.isSymbolicLink())
        .catch(() => false);
      candidates.push({
        name: entry.name,
        path,
        mtimeMs: entryStat.mtimeMs,
        committed,
      });
    } catch {
      // A disappearing quarantine is already resolved.
    }
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  let hasState = await lstat(join(context.runtimeDir, "state.json"))
    .then((entry) => entry.isFile() && !entry.isSymbolicLink())
    .catch(() => false);
  let restored = 0;
  let removed = 0;
  const failures = [];
  let unresolved = 0;

  for (const candidate of candidates) {
    try {
      if (hasState && candidate.committed) {
        await rm(candidate.path, { recursive: true, force: true });
        removed += 1;
      } else if (!hasState) {
        await restoreTaskDataQuarantine(context, candidate.path);
        restored += 1;
        hasState = true;
      } else {
        unresolved += 1;
      }
    } catch (error) {
      failures.push(`${candidate.name}: ${error.message}`);
    }
  }
  return {
    restored,
    removed,
    pending: failures.length + unresolved,
    failures,
  };
}
