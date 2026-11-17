import {
  evaluateDatabaseProfile,
  evaluateRuntimeProfile,
  PRODUCTION_PROFILE,
  PRODUCTION_PROFILE_SHA256,
} from "./production-profile.mjs";
import { createTempSqliteFixture } from "./fixture.mjs";
import { startIsolatedHttpServer } from "./http-server.mjs";

const taskId = String(process.env.SHADOW_TASK_ID ?? "");
const workspaceId = String(process.env.SHADOW_WORKSPACE_ID ?? "");
const channelId = String(process.env.SHADOW_CHANNEL_ID ?? "");
const fixtureRoot = String(process.env.SHADOW_FIXTURE_ROOT ?? "");

function emit(value) {
  process.stdout.write(`${JSON.stringify(value)}\n`);
}

function fail(code, blockers = []) {
  emit({
    ready: false,
    code,
    blockers,
    profile_id: PRODUCTION_PROFILE.profile_id,
    profile_sha256: PRODUCTION_PROFILE_SHA256,
  });
  process.exit(78);
}

if (!taskId || !workspaceId || !channelId || !fixtureRoot) {
  fail("missing_shadow_fixture_identity");
}

let databaseSyncAvailable = true;
try {
  await import("node:sqlite");
} catch {
  databaseSyncAvailable = false;
}
const runtimeGate = evaluateRuntimeProfile({ databaseSyncAvailable });
if (!runtimeGate.ok) {
  fail("runtime_profile_mismatch", runtimeGate.blockers);
}

let fixture;
let coordinatorServer;
let shuttingDown = false;

async function shutdown() {
  if (shuttingDown) return;
  shuttingDown = true;
  await coordinatorServer?.close().catch(() => {});
  fixture?.cleanup();
  process.exit(0);
}

process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
process.stdin.resume();
process.stdin.once("end", shutdown);
process.stdin.once("close", shutdown);

try {
  fixture = createTempSqliteFixture({
    directory: fixtureRoot,
    fixture: {
      taskId,
      workspaceId,
      channelId,
      objective: "Synthetic source_hosted shadow fixture",
    },
  });
  const databaseGate = evaluateDatabaseProfile(fixture.coordinator.db);
  if (!databaseGate.ok) {
    fixture.cleanup();
    fail("database_profile_mismatch", databaseGate.blockers);
  }
  const bootstrap = fixture.bootstrap;
  fixture.close();
  coordinatorServer = await startIsolatedHttpServer({
    dbPath: fixture.dbPath,
  });
  emit({
    ready: true,
    base_url: coordinatorServer.baseUrl,
    task_id: taskId,
    tokens: {
      source: bootstrap.tokens.source,
      panel: bootstrap.tokens.panel,
      control: bootstrap.tokens.control,
    },
    profile_id: PRODUCTION_PROFILE.profile_id,
    profile_sha256: PRODUCTION_PROFILE_SHA256,
    runtime_gate: runtimeGate,
    database_gate: databaseGate,
  });
} catch (error) {
  fixture?.cleanup();
  emit({
    ready: false,
    code: "shadow_coordinator_start_failed",
    message: String(error?.message ?? error).slice(0, 300),
    profile_id: PRODUCTION_PROFILE.profile_id,
    profile_sha256: PRODUCTION_PROFILE_SHA256,
  });
  process.exitCode = 1;
}
