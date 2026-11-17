import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";

const {
  PRODUCTION_PROFILE,
  PRODUCTION_PROFILE_FREEZE_SHA256,
  PRODUCTION_PROFILE_SHA256,
  compareVersions,
  evaluateActivationGate,
  evaluateDatabaseProfile,
  evaluateRuntimeProfile,
} = await import(
  "../contracts/source-hosted-shared-task/v1/persistence/production-profile.mjs"
);
const profilePath = new URL(
  "../contracts/source-hosted-shared-task/v1/persistence/production-profile.json",
  import.meta.url,
);
const packagePath = new URL("../package.json", import.meta.url);

test("production profile content and checksum are frozen", () => {
  const packageJson = JSON.parse(readFileSync(packagePath, "utf8"));
  assert.equal(
    PRODUCTION_PROFILE.profile_id,
    "source-hosted-node24-node-sqlite-process-v1",
  );
  assert.equal(PRODUCTION_PROFILE.status, "frozen");
  assert.equal(PRODUCTION_PROFILE.driver.name, "node:sqlite");
  assert.equal(PRODUCTION_PROFILE.driver.api, "DatabaseSync");
  assert.equal(
    PRODUCTION_PROFILE.driver.isolation,
    "dedicated-coordinator-process",
  );
  assert.equal(PRODUCTION_PROFILE.activation.allowed_mode, "shadow");
  assert.equal(PRODUCTION_PROFILE.activation.fail_closed, true);
  assert.equal(packageJson.engines.node, ">=24.22.1 <25.0.0");
  assert.equal(
    packageJson.sourceHostedProfile,
    "contracts/source-hosted-shared-task/v1/persistence/production-profile.json",
  );
  assert.equal(
    Object.hasOwn(packageJson.dependencies ?? {}, "better-sqlite3"),
    false,
  );
  assert.equal(
    PRODUCTION_PROFILE_SHA256,
    PRODUCTION_PROFILE_FREEZE_SHA256,
  );
  assert.equal(
    PRODUCTION_PROFILE_SHA256,
    createHash("sha256")
      .update(readFileSync(profilePath, "utf8"), "utf8")
      .digest("hex"),
  );
  assert.match(PRODUCTION_PROFILE_SHA256, /^[a-f0-9]{64}$/u);
});

test("runtime profile accepts the verified window and fails closed outside it", async () => {
  let nodeSqliteAvailable = true;
  try {
    await import("node:sqlite");
  } catch {
    nodeSqliteAvailable = false;
  }
  assert.equal(
    evaluateRuntimeProfile({
      nodeVersion: "24.22.1",
      sqliteVersion: "3.53.4",
      databaseSyncAvailable: nodeSqliteAvailable,
    }).ok,
    nodeSqliteAvailable,
  );
  assert.deepEqual(
    evaluateRuntimeProfile({
      nodeVersion: "20.19.0",
      sqliteVersion: "3.53.4",
      databaseSyncAvailable: true,
    }).blockers,
    ["node_version_outside_frozen_profile"],
  );
  assert.deepEqual(
    evaluateRuntimeProfile({
      nodeVersion: "25.0.0",
      sqliteVersion: "3.53.4",
      databaseSyncAvailable: true,
    }).blockers,
    ["node_version_outside_frozen_profile"],
  );
  assert.deepEqual(
    evaluateRuntimeProfile({
      nodeVersion: "24.22.1",
      sqliteVersion: "3.54.0",
      databaseSyncAvailable: true,
    }).blockers,
    ["sqlite_version_outside_frozen_profile"],
  );
  assert.equal(compareVersions("24.22.1", "24.22.0"), 1);
  assert.equal(compareVersions("3.53.4", "3.53.4"), 0);
});

test("database and activation probes enforce the frozen SQLite profile", async (t) => {
  let sqliteAvailable = true;
  try {
    await import("node:sqlite");
  } catch {
    sqliteAvailable = false;
  }
  if (!sqliteAvailable) {
    t.skip("node:sqlite is unavailable in this Node runtime");
    return;
  }
  const {
    createTempSqliteFixture,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/fixture.mjs"
  );
  const fixture = createTempSqliteFixture();
  try {
    const databaseGate = evaluateDatabaseProfile(fixture.coordinator.db);
    assert.deepEqual(databaseGate, {
      ok: true,
      profile_id: "source-hosted-node24-node-sqlite-process-v1",
      pragmas: {
        journal_mode: "wal",
        synchronous: 2,
        foreign_keys: 1,
        trusted_schema: 0,
        busy_timeout: 5000,
        user_version: 1,
      },
      blockers: [],
    });
    const runtimeGate = {
      ok: true,
      profile_id: PRODUCTION_PROFILE.profile_id,
      blockers: [],
    };
    assert.deepEqual(
      evaluateActivationGate({
        runtimeGate,
        databaseGate,
        processIsolated: true,
        featureFlagMode: "shadow",
      }),
      {
        allowed: true,
        profile_id: "source-hosted-node24-node-sqlite-process-v1",
        blockers: [],
      },
    );
    assert.deepEqual(
      evaluateActivationGate({
        runtimeGate,
        databaseGate,
        processIsolated: false,
        featureFlagMode: "default",
      }).blockers,
      [
        "coordinator_process_not_isolated",
        "feature_flag_mode_not_shadow",
      ],
    );
  } finally {
    fixture.cleanup();
  }
});
