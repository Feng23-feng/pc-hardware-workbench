import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

const profileText = readFileSync(
  new URL("./production-profile.json", import.meta.url),
  "utf8",
);

export const PRODUCTION_PROFILE_SHA256 = createHash("sha256")
  .update(profileText, "utf8")
  .digest("hex");
export const PRODUCTION_PROFILE_FREEZE_SHA256 =
  "36f023d9274b6924da1beeb7c01c72b583420744b17aa58039b3e060c9b38a2a";

if (PRODUCTION_PROFILE_SHA256 !== PRODUCTION_PROFILE_FREEZE_SHA256) {
  throw new Error("Frozen production SQLite profile checksum mismatch");
}

export const PRODUCTION_PROFILE = Object.freeze(
  JSON.parse(profileText),
);

function versionTuple(value) {
  const match = String(value ?? "").match(/^(\d+)\.(\d+)\.(\d+)/u);
  if (!match) return null;
  return match.slice(1).map(Number);
}

export function compareVersions(left, right) {
  const a = versionTuple(left);
  const b = versionTuple(right);
  if (!a || !b) throw new Error("Invalid semantic version");
  for (let index = 0; index < 3; index += 1) {
    if (a[index] < b[index]) return -1;
    if (a[index] > b[index]) return 1;
  }
  return 0;
}

export function evaluateRuntimeProfile({
  nodeVersion = process.versions.node,
  sqliteVersion = process.versions.sqlite,
  databaseSyncAvailable = false,
} = {}) {
  const runtime = PRODUCTION_PROFILE.runtime;
  const blockers = [];
  if (
    compareVersions(nodeVersion, runtime.node_minimum) < 0 ||
    compareVersions(nodeVersion, runtime.node_maximum_exclusive) >= 0
  ) {
    blockers.push("node_version_outside_frozen_profile");
  }
  if (
    compareVersions(sqliteVersion, runtime.sqlite_minimum) < 0 ||
    compareVersions(sqliteVersion, runtime.sqlite_maximum_exclusive) >= 0
  ) {
    blockers.push("sqlite_version_outside_frozen_profile");
  }
  if (!databaseSyncAvailable) {
    blockers.push("node_sqlite_database_sync_unavailable");
  }
  return {
    ok: blockers.length === 0,
    profile_id: PRODUCTION_PROFILE.profile_id,
    node_version: nodeVersion,
    sqlite_version: sqliteVersion,
    blockers,
  };
}

export function evaluateDatabaseProfile(db) {
  const expected = PRODUCTION_PROFILE.database;
  const pragmas = {
    journal_mode: String(
      db.prepare("PRAGMA journal_mode").get().journal_mode,
    ).toLowerCase(),
    synchronous: Number(
      db.prepare("PRAGMA synchronous").get().synchronous,
    ),
    foreign_keys: Number(
      db.prepare("PRAGMA foreign_keys").get().foreign_keys,
    ),
    trusted_schema: Number(
      db.prepare("PRAGMA trusted_schema").get().trusted_schema,
    ),
    busy_timeout: Number(
      db.prepare("PRAGMA busy_timeout").get().timeout,
    ),
    user_version: Number(
      db.prepare("PRAGMA user_version").get().user_version,
    ),
  };
  const blockers = [];
  if (pragmas.journal_mode !== expected.journal_mode) {
    blockers.push("journal_mode_not_wal");
  }
  if (pragmas.synchronous !== 2) {
    blockers.push("synchronous_not_full");
  }
  if (pragmas.foreign_keys !== 1) {
    blockers.push("foreign_keys_not_enabled");
  }
  if (pragmas.trusted_schema !== 0) {
    blockers.push("trusted_schema_not_disabled");
  }
  if (pragmas.busy_timeout !== expected.busy_timeout_ms) {
    blockers.push("busy_timeout_mismatch");
  }
  if (pragmas.user_version !== expected.schema_version) {
    blockers.push("schema_version_mismatch");
  }
  return {
    ok: blockers.length === 0,
    profile_id: PRODUCTION_PROFILE.profile_id,
    pragmas,
    blockers,
  };
}

export function evaluateActivationGate({
  runtimeGate,
  databaseGate,
  processIsolated,
  featureFlagMode,
} = {}) {
  const blockers = [];
  if (runtimeGate?.ok !== true) {
    blockers.push("runtime_probe_not_passed");
  }
  if (databaseGate?.ok !== true) {
    blockers.push("database_probe_not_passed");
  }
  if (processIsolated !== true) {
    blockers.push("coordinator_process_not_isolated");
  }
  if (featureFlagMode !== "shadow") {
    blockers.push("feature_flag_mode_not_shadow");
  }
  return {
    allowed: blockers.length === 0,
    profile_id: PRODUCTION_PROFILE.profile_id,
    blockers,
  };
}
