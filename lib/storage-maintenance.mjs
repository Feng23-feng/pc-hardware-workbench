import {
  lstat,
  readFile,
  readdir,
  rm,
} from "node:fs/promises";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";

const RUNTIME_BACKUP_NAME =
  /^Runtime.*-backup-(?<stamp>\d{8}-\d{6})(?:-(?<duplicate>\d+))?$/u;
const SHARED_ENGINE_NAME =
  /^node-\d+\.\d+\.\d+-[0-9a-f]{16}$/u;

function isWithin(rootPath, candidatePath) {
  const rootValue = resolve(rootPath);
  const candidateValue = resolve(candidatePath);
  const pathFromRoot = relative(rootValue, candidateValue);
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
    if (error?.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

async function listDirectory(path) {
  try {
    return await readdir(path, { withFileTypes: true });
  } catch (error) {
    if (error?.code === "ENOENT") {
      return [];
    }
    throw error;
  }
}

async function measureTree(rootPath) {
  const result = {
    exists: false,
    bytes: 0,
    file_count: 0,
    directory_count: 0,
    skipped_reparse_points: 0,
    errors: 0,
  };
  try {
    const rootStat = await lstat(rootPath);
    if (!rootStat.isDirectory() || rootStat.isSymbolicLink()) {
      return result;
    }
    result.exists = true;
  } catch (error) {
    if (error?.code === "ENOENT") {
      return result;
    }
    throw error;
  }

  const pending = [resolve(rootPath)];
  while (pending.length > 0) {
    const directory = pending.pop();
    const entries = await listDirectory(directory);
    for (const entry of entries) {
      const entryPath = join(directory, entry.name);
      try {
        const entryStat = await lstat(entryPath);
        if (entryStat.isSymbolicLink()) {
          result.skipped_reparse_points += 1;
          continue;
        }
        if (entryStat.isDirectory()) {
          result.directory_count += 1;
          pending.push(entryPath);
        } else if (entryStat.isFile()) {
          result.file_count += 1;
          result.bytes += entryStat.size;
        }
      } catch {
        result.errors += 1;
      }
    }
  }
  return result;
}

function subtractMeasurement(total, part) {
  return {
    exists: total.exists,
    bytes: Math.max(0, total.bytes - Math.max(0, part.bytes)),
    file_count: Math.max(0, total.file_count - Math.max(0, part.file_count)),
    directory_count: Math.max(
      0,
      total.directory_count - Math.max(0, part.directory_count),
    ),
    skipped_reparse_points: total.skipped_reparse_points,
    errors: total.errors,
  };
}

function sumMeasurements(values) {
  return values.reduce(
    (total, value) => ({
      bytes: total.bytes + Math.max(0, value.bytes ?? 0),
      file_count: total.file_count + Math.max(0, value.file_count ?? 0),
    }),
    { bytes: 0, file_count: 0 },
  );
}

function backupSortKey(name) {
  const match = RUNTIME_BACKUP_NAME.exec(name);
  if (!match?.groups) return "";
  return `${match.groups.stamp}-${String(
    Number.parseInt(match.groups.duplicate ?? "0", 10),
  ).padStart(10, "0")}`;
}

function normalizedComparisonPath(path) {
  return resolve(path).toLowerCase();
}

function chooseProtectedBackup(pointer, backups) {
  const recordedPath = String(
    pointer?.previous_runtime_backup_path ?? "",
  ).trim();
  if (recordedPath) {
    const recorded = backups.find(
      (backup) =>
        normalizedComparisonPath(backup.path) ===
        normalizedComparisonPath(recordedPath),
    );
    if (recorded) return recorded;
  }

  const previousRuntimePath = String(
    pointer?.previous_runtime_path ?? "",
  ).trim();
  if (previousRuntimePath) {
    const previousName = basename(dirname(previousRuntimePath));
    const previous = [...backups]
      .filter((backup) => backup.name.startsWith(`${previousName}-backup-`))
      .sort((left, right) =>
        right.sort_key.localeCompare(left.sort_key))
      .at(0);
    if (previous) return previous;
  }

  return [...backups]
    .sort((left, right) => right.sort_key.localeCompare(left.sort_key))
    .at(0) ?? null;
}

function validateBackupRoot(localRoot, backupRoot) {
  const resolvedBackupRoot = resolve(backupRoot);
  if (
    resolvedBackupRoot === resolve(dirname(resolvedBackupRoot)) ||
    resolvedBackupRoot.toLowerCase() === resolve(localRoot).toLowerCase()
  ) {
    throw new Error("Runtime backup root is unsafe.");
  }
  return resolvedBackupRoot;
}

export function resolveStorageContext({
  localRoot,
  runtimeDir,
  localAppData = process.env.LOCALAPPDATA,
} = {}) {
  if (!localRoot) {
    throw new Error("localRoot is required for storage maintenance.");
  }
  const resolvedLocalRoot = resolve(localRoot);
  const resolvedRuntimeDir = resolve(
    runtimeDir ?? join(resolvedLocalRoot, "runtime-pchw"),
  );
  const pointerPath = join(resolvedLocalRoot, "runtime-location.json");
  const defaultBackupRoot = join(
    localAppData ?? dirname(resolvedLocalRoot),
    "SkillDockBackups",
    "runtime",
  );
  return {
    localRoot: resolvedLocalRoot,
    runtimeDir: resolvedRuntimeDir,
    pointerPath,
    engineRoot: join(resolvedLocalRoot, "engines"),
    installLogsRoot: join(resolvedLocalRoot, "install-logs"),
    defaultBackupRoot: resolve(defaultBackupRoot),
  };
}

async function inspectBackups(pointer, backupRoot) {
  const managedRoot = validateBackupRoot(pointer.local_root, backupRoot);
  try {
    const backupRootStat = await lstat(managedRoot);
    if (!backupRootStat.isDirectory() || backupRootStat.isSymbolicLink()) {
      throw new Error("Runtime backup root must be a regular directory.");
    }
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        backupRoot: managedRoot,
        backups: [],
        directory_count: 0,
      };
    }
    throw error;
  }
  const entries = await listDirectory(managedRoot);
  const directoryCount = entries.filter((entry) => entry.isDirectory()).length;
  const backups = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || !RUNTIME_BACKUP_NAME.test(entry.name)) {
      continue;
    }
    const backupPath = join(managedRoot, entry.name);
    let backupStat;
    try {
      backupStat = await lstat(backupPath);
    } catch {
      continue;
    }
    if (!backupStat.isDirectory() || backupStat.isSymbolicLink()) {
      continue;
    }
    const measurement = await measureTree(backupPath);
    backups.push({
      name: entry.name,
      path: backupPath,
      sort_key: backupSortKey(entry.name),
      bytes: measurement.bytes,
      file_count: measurement.file_count,
      protected: false,
    });
  }
  const protectedBackup = chooseProtectedBackup(pointer.pointer, backups);
  if (protectedBackup) {
    protectedBackup.protected = true;
  }
  return {
    backupRoot: managedRoot,
    backups,
    directory_count: directoryCount,
  };
}

async function measureLauncherFiles(localRoot) {
  const files = [
    "launcher.log",
    "launch-result.json",
    "launch-failure.json",
  ];
  const result = {
    exists: false,
    bytes: 0,
    file_count: 0,
    directory_count: 0,
    skipped_reparse_points: 0,
    errors: 0,
  };
  for (const name of files) {
    try {
      const fileStat = await lstat(join(localRoot, name));
      if (fileStat.isFile()) {
        result.exists = true;
        result.bytes += fileStat.size;
        result.file_count += 1;
      }
    } catch (error) {
      if (error?.code !== "ENOENT") {
        result.errors += 1;
      }
    }
  }
  return result;
}

function publicBackupSummary(backup) {
  return {
    name: backup.name,
    bytes: backup.bytes,
    file_count: backup.file_count,
    protected: backup.protected,
  };
}

export async function getStorageSnapshot(options = {}) {
  const context = resolveStorageContext(options);
  const rawPointer = await readJsonOptional(context.pointerPath);
  const pointer = rawPointer
    ? { ...rawPointer, local_root: context.localRoot }
    : null;
  const runtimeProgramPath = String(
    rawPointer?.runtime_path ?? "",
  ).trim();
  const runtimeProgramRoot = runtimeProgramPath
    ? dirname(resolve(runtimeProgramPath))
    : "";
  const backupRoot = validateBackupRoot(
    context.localRoot,
    rawPointer?.backup_root || context.defaultBackupRoot,
  );
  const backups = await inspectBackups(
    { pointer: rawPointer, local_root: context.localRoot },
    backupRoot,
  );

  const [
    localRootMeasurement,
    runtimeProgram,
    sharedEngines,
    runtimeData,
    taskRecords,
    attachments,
    artifacts,
    installLogs,
    launcherFiles,
    backupRootMeasurement,
  ] = await Promise.all([
    measureTree(context.localRoot),
    runtimeProgramRoot
      ? measureTree(runtimeProgramRoot)
      : Promise.resolve({
          exists: false,
          bytes: 0,
          file_count: 0,
          directory_count: 0,
          skipped_reparse_points: 0,
          errors: 0,
        }),
    measureTree(context.engineRoot),
    measureTree(context.runtimeDir),
    measureTree(join(context.runtimeDir, "tasks")),
    measureTree(join(context.runtimeDir, "attachments")),
    measureTree(join(context.runtimeDir, "artifacts")),
    measureTree(context.installLogsRoot),
    measureLauncherFiles(context.localRoot),
    measureTree(backupRoot),
  ]);
  const runtimeOther = subtractMeasurement(
    subtractMeasurement(
      subtractMeasurement(runtimeData, taskRecords),
      attachments,
    ),
    artifacts,
  );
  const localKnown = sumMeasurements([
    runtimeProgramRoot ? runtimeProgram : {},
    sharedEngines,
    runtimeData,
    installLogs,
    launcherFiles,
  ]);
  const otherLocal = {
    exists:
      localRootMeasurement.exists &&
      localRootMeasurement.bytes > localKnown.bytes,
    bytes: Math.max(0, localRootMeasurement.bytes - localKnown.bytes),
    file_count: Math.max(
      0,
      localRootMeasurement.file_count - localKnown.file_count,
    ),
  };
  const cleanableBackups = backups.backups.filter(
    (backup) => !backup.protected,
  );
  const protectedBackups = backups.backups.filter(
    (backup) => backup.protected,
  );

  return {
    schema_version: "1.0",
    generated_at: new Date().toISOString(),
    total: {
      bytes: localRootMeasurement.bytes + backupRootMeasurement.bytes,
      file_count:
        localRootMeasurement.file_count + backupRootMeasurement.file_count,
    },
    categories: {
      current_runtime: runtimeProgram,
      runtime_backups: {
        ...backupRootMeasurement,
        directory_count: backups.directory_count,
        managed_backup_count: backups.backups.length,
        unmanaged_directory_count: Math.max(
          0,
          backups.directory_count - backups.backups.length,
        ),
      },
      shared_engines: sharedEngines,
      task_records: taskRecords,
      attachments,
      artifacts,
      runtime_state: runtimeOther,
      install_logs: installLogs,
      launcher_state: launcherFiles,
      other_local: otherLocal,
    },
    cleanup: {
      available: cleanableBackups.length > 0,
      cleanable_backup_count: cleanableBackups.length,
      protected_backup_count: protectedBackups.length,
      protected_backup_name: protectedBackups[0]?.name ?? "",
      estimated_reclaim_bytes: cleanableBackups.reduce(
        (total, backup) => total + backup.bytes,
        0,
      ),
      backups: backups.backups.map(publicBackupSummary),
    },
  };
}

async function collectReferencedEngines({
  localRoot,
  runtimeProgramRoot,
  backupRoot,
}) {
  const references = new Set();
  const failures = [];
  const runtimeDirectories = [];
  if (runtimeProgramRoot) {
    runtimeDirectories.push(runtimeProgramRoot);
  }
  for (const entry of await listDirectory(localRoot)) {
    if (entry.isDirectory() && entry.name.startsWith("Runtime")) {
      runtimeDirectories.push(join(localRoot, entry.name));
    }
  }
  for (const entry of await listDirectory(backupRoot)) {
    if (entry.isDirectory()) {
      runtimeDirectories.push(join(backupRoot, entry.name));
    }
  }
  for (const runtimeDirectory of new Set(
    runtimeDirectories.map((value) => resolve(value)),
  )) {
    const referencePath = join(runtimeDirectory, "engine-location.json");
    try {
      const reference = await readJsonOptional(referencePath);
      if (!reference) continue;
      const engineId = String(reference.engine_id ?? "");
      if (
        reference.schema_version !== "1.0" ||
        !SHARED_ENGINE_NAME.test(engineId)
      ) {
        throw new Error(`Malformed shared Node engine reference: ${referencePath}`);
      }
      references.add(engineId);
    } catch (error) {
      failures.push(error.message);
    }
  }
  return { references, failures };
}

async function cleanupUnreferencedEngines(context, runtimeProgramRoot, backupRoot) {
  const engineRoot = context.engineRoot;
  try {
    const engineRootStat = await lstat(engineRoot);
    if (!engineRootStat.isDirectory() || engineRootStat.isSymbolicLink()) {
      throw new Error("Shared Node engine root must be a regular directory.");
    }
  } catch (error) {
    if (error?.code === "ENOENT") {
      return {
        removed_engine_count: 0,
        skipped: false,
        failures: [],
      };
    }
    return {
      removed_engine_count: 0,
      skipped: true,
      failures: [error.message],
    };
  }
  const referenceResult = await collectReferencedEngines({
    localRoot: context.localRoot,
    runtimeProgramRoot,
    backupRoot,
  });
  if (referenceResult.failures.length > 0) {
    return {
      removed_engine_count: 0,
      skipped: true,
      failures: referenceResult.failures,
    };
  }
  let removed = 0;
  const failures = [];
  for (const entry of await listDirectory(engineRoot)) {
    if (
      !entry.isDirectory() ||
      !SHARED_ENGINE_NAME.test(entry.name) ||
      referenceResult.references.has(entry.name)
    ) {
      continue;
    }
    const enginePath = join(engineRoot, entry.name);
    if (!isWithin(engineRoot, enginePath)) {
      failures.push(`Unsafe shared engine path: ${enginePath}`);
      continue;
    }
    try {
      const engineStat = await lstat(enginePath);
      if (!engineStat.isDirectory() || engineStat.isSymbolicLink()) {
        continue;
      }
      await rm(enginePath, {
        recursive: true,
        force: false,
        maxRetries: 2,
        retryDelay: 100,
      });
      removed += 1;
    } catch (error) {
      failures.push(`${entry.name}: ${error.message}`);
    }
  }
  return {
    removed_engine_count: removed,
    skipped: false,
    failures,
  };
}

export async function cleanupRuntimeBackups(options = {}, request = {}) {
  if (request.confirm !== "cleanup-runtime-backups") {
    const error = new Error("Runtime backup cleanup requires confirmation.");
    error.code = "confirmation_required";
    throw error;
  }
  const context = resolveStorageContext(options);
  const pointer = await readJsonOptional(context.pointerPath);
  if (!pointer) {
    const error = new Error("Runtime pointer is unavailable.");
    error.code = "runtime_pointer_missing";
    throw error;
  }
  const backupRoot = validateBackupRoot(
    context.localRoot,
    pointer.backup_root || context.defaultBackupRoot,
  );
  const inspection = await inspectBackups(
    { pointer, local_root: context.localRoot },
    backupRoot,
  );
  const candidates = inspection.backups.filter(
    (backup) => !backup.protected,
  );
  const removed = [];
  const failures = [];
  for (const backup of candidates) {
    if (!isWithin(backupRoot, backup.path)) {
      failures.push(`${backup.name}: unsafe backup path`);
      continue;
    }
    try {
      const backupStat = await lstat(backup.path);
      if (!backupStat.isDirectory() || backupStat.isSymbolicLink()) {
        continue;
      }
      await rm(backup.path, {
        recursive: true,
        force: false,
        maxRetries: 2,
        retryDelay: 100,
      });
      removed.push({
        name: backup.name,
        bytes: backup.bytes,
      });
    } catch (error) {
      failures.push(`${backup.name}: ${error.message}`);
    }
  }
  const runtimeProgramPath = String(pointer.runtime_path ?? "").trim();
  const engineCleanup = await cleanupUnreferencedEngines(
    context,
    runtimeProgramPath ? dirname(resolve(runtimeProgramPath)) : "",
    backupRoot,
  );
  return {
    schema_version: "1.0",
    cleaned_at: new Date().toISOString(),
    removed_backup_count: removed.length,
    removed_backups: removed,
    reclaimed_bytes: removed.reduce(
      (total, backup) => total + backup.bytes,
      0,
    ),
    protected_backup_name:
      inspection.backups.find((backup) => backup.protected)?.name ?? "",
    failures,
    engine_cleanup: engineCleanup,
    storage: await getStorageSnapshot(options),
  };
}
