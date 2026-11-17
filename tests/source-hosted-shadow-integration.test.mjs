import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import test from "node:test";
import {
  createSourceHostedShadowObserver,
  loadSourceHostedShadowConfig,
} from "../lib/source-hosted-shadow.mjs";

const root = resolve(import.meta.dirname, "..");
const FROZEN_PROFILE_ID =
  "source-hosted-node24-node-sqlite-process-v1";
const FROZEN_PROFILE_SHA256 =
  "36f023d9274b6924da1beeb7c01c72b583420744b17aa58039b3e060c9b38a2a";

async function tempDir(prefix) {
  return mkdtemp(join(tmpdir(), prefix));
}

async function fixtureDirectorySet() {
  return new Set(
    (await readdir(tmpdir(), { withFileTypes: true }))
      .filter(
        (entry) =>
          entry.isDirectory() &&
          entry.name.startsWith("skilldock-sqlite-fixture-"),
      )
      .map((entry) => entry.name),
  );
}

async function waitForNoNewFixtureDirectories(before, timeoutMs = 3_000) {
  const deadline = Date.now() + timeoutMs;
  let leaked = [];
  while (Date.now() < deadline) {
    const after = await fixtureDirectorySet();
    leaked = [...after].filter((name) => !before.has(name));
    if (leaked.length === 0) return leaked;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  return leaked;
}

async function freePort() {
  return new Promise((resolvePromise, rejectPromise) => {
    const server = createTcpServer();
    server.once("error", rejectPromise);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port =
        address && typeof address === "object" ? address.port : null;
      server.close((error) => {
        if (error) rejectPromise(error);
        else resolvePromise(port);
      });
    });
  });
}

async function startFormalServer({
  shadowMode = "",
  evidenceDir = "",
} = {}) {
  const port = await freePort();
  const runtimeDir = await tempDir("skilldock-shadow-runtime-");
  const workspace = await tempDir("skilldock-shadow-workspace-");
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "mock",
      PANEL_PORT: String(port),
      PANEL_RUNTIME_DIR: runtimeDir,
      PANEL_AGENT_WORKSPACE: workspace,
      PANEL_SKILL_MANIFEST: join(
        root,
        "skills",
        "generic-demo",
        "workbench.manifest.json",
      ),
      PANEL_SKILL_ID: "generic-demo",
      PANEL_SOURCE_HOSTED_SHADOW: shadowMode,
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`shadow formal server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.ok) {
        const token = (
          await readFile(join(runtimeDir, "capability-token"), "utf8")
        ).trim();
        return {
          child,
          port,
          runtimeDir,
          workspace,
          token,
          baseUrl: `http://127.0.0.1:${port}`,
          get stderr() {
            return stderr;
          },
          async close() {
            if (child.exitCode === null) {
              await fetch(`http://127.0.0.1:${port}/api/shutdown`, {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${token}`,
                },
              }).catch(() => {});
              await Promise.race([
                new Promise((resolvePromise) => {
                  child.once("exit", resolvePromise);
                }),
                new Promise((resolvePromise) =>
                  setTimeout(resolvePromise, 5_000)),
              ]);
            }
            if (child.exitCode === null) child.kill();
            await rm(runtimeDir, { recursive: true, force: true });
            await rm(workspace, { recursive: true, force: true });
          },
        };
      }
    } catch {
      // The formal server is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  child.kill();
  await rm(runtimeDir, { recursive: true, force: true });
  await rm(workspace, { recursive: true, force: true });
  throw new Error(`shadow formal server was not ready: ${stderr}`);
}

function importBody() {
  return {
    schema_version: "1.0",
    channel_id: "chat:shadow-test:task-one",
    source_session_ref: "source-session-shadow-test",
    objective: "验证 shadow 不改变正式 Task 结果",
    summary: "主对话与面板共享一个 fixture Task。",
    messages: [
      {
        id: "chat-message-shadow-user-1",
        role: "user",
        text: "游戏中出现短暂卡顿。",
        created_at: "2026-11-16T00:00:00.000Z",
      },
      {
        id: "chat-message-shadow-agent-1",
        role: "agent",
        text: "先固定场景并记录时间。",
        created_at: "2026-11-16T00:00:01.000Z",
      },
    ],
  };
}

async function syncImport(server, body = importBody()) {
  const response = await fetch(`${server.baseUrl}/api/task/sync/import`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${server.token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  const json = await response.json();
  const stateResponse = await fetch(`${server.baseUrl}/api/state`, {
    headers: {
      Authorization: `Bearer ${server.token}`,
    },
  });
  const state = await stateResponse.json();
  return { status: response.status, json, state };
}

function formalTimeline(state) {
  return state.task.timeline.map((entry) => ({
    seq: entry.seq,
    role: entry.role,
    text: entry.text,
    created_at: entry.created_at,
    source: entry.source,
    external_id: entry.external_id,
  }));
}

function formalImportResult(value) {
  return {
    ok: value.json.ok,
    channel_id: value.json.channel_id,
    imported_count: value.json.imported_count,
    skipped_count: value.json.skipped_count,
    created_task: value.json.created_task,
    cursor: value.json.cursor,
  };
}

async function waitForEvidence(
  evidenceDir,
  predicate,
  timeoutMs = 20_000,
) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const evidence = JSON.parse(
        await readFile(join(evidenceDir, "latest.json"), "utf8"),
      );
      if (predicate(evidence)) return evidence;
    } catch {
      // Evidence is written asynchronously after the formal response.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  throw new Error("shadow evidence did not arrive");
}

async function runProfileIdentityMismatchCase({
  reportedProfileId,
  reportedProfileSha256,
  expectedBlocker,
}) {
  const temp = await tempDir("skilldock-shadow-profile-mismatch-");
  const evidenceDir = join(temp, "evidence");
  const workerPath = join(temp, "fake-shadow-worker.mjs");
  await writeFile(
    workerPath,
    `
const ready = {
  ready: true,
  base_url: "http://127.0.0.1:9",
  task_id: process.env.SHADOW_TASK_ID,
  tokens: {
    source: "fake-source-token",
    panel: "fake-panel-token",
    control: "fake-control-token"
  },
  profile_id: process.env.FAKE_PROFILE_ID,
  profile_sha256: process.env.FAKE_PROFILE_SHA256,
  runtime_gate: { ok: true, blockers: [] },
  database_gate: { ok: true, blockers: [] }
};
process.stdout.write(JSON.stringify(ready) + "\\n");
process.stdin.resume();
`,
    "utf8",
  );
  const childRef = { child: null };
  let fetchCalls = 0;
  const observer = createSourceHostedShadowObserver({
    env: {
      PANEL_SOURCE_HOSTED_SHADOW: "shadow",
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    workerPath,
    profileProvider: async () => ({
      runtimeGate: {
        ok: true,
        blockers: [],
        node_version: "24.22.1",
        sqlite_version: "3.53.4",
      },
      profileId: FROZEN_PROFILE_ID,
      profileSha256: FROZEN_PROFILE_SHA256,
    }),
    spawnProcess(command, args, options) {
      const child = spawn(command, args, {
        ...options,
        env: {
          ...options.env,
          FAKE_PROFILE_ID: reportedProfileId,
          FAKE_PROFILE_SHA256: reportedProfileSha256,
        },
      });
      childRef.child = child;
      return child;
    },
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("profile mismatch must not fetch");
    },
    startupTimeoutMs: 2_000,
  });
  try {
    const result = await observer.observeSyncImport({
      formal_task_id: "task-profile-identity-test",
      channel_id: "chat:shadow:profile-identity",
      source_session_ref: "source-profile-identity",
      objective: "profile identity mismatch",
      cursor: 1,
      messages: [{
        external_id: "profile-identity-message",
        role: "user",
        text: "profile identity test",
        created_at: "2026-11-16T00:00:00.000Z",
        seq: 1,
      }],
    });
    assert.equal(fetchCalls, 0);
    assert.equal(result.status, "blocked");
    assert.equal(result.reason, "shadow_profile_mismatch");
    assert.ok(result.evidence_file);
    const evidence = JSON.parse(
      await readFile(join(evidenceDir, result.evidence_file), "utf8"),
    );
    assert.equal(evidence.status, "blocked");
    assert.equal(evidence.ok, false);
    assert.equal(evidence.reason, "shadow_profile_mismatch");
    assert.deepEqual(evidence.blockers, [expectedBlocker]);
    assert.equal(evidence.profile.identity_match, false);
    assert.equal(evidence.profile.profile_id, reportedProfileId);
    assert.equal(
      evidence.profile.profile_sha256,
      reportedProfileSha256,
    );
    assert.deepEqual(evidence.profile.expected_profile, {
      profile_id: FROZEN_PROFILE_ID,
      profile_sha256: FROZEN_PROFILE_SHA256,
    });
    assert.deepEqual(evidence.profile.observed_profile, {
      profile_id: reportedProfileId,
      profile_sha256: reportedProfileSha256,
    });
    assert.equal(evidence.coordinator_process.started, false);
    if (
      childRef.child.exitCode === null &&
      childRef.child.signalCode === null
    ) {
      await Promise.race([
        new Promise((resolvePromise) => {
          childRef.child.once("exit", resolvePromise);
        }),
        new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000)),
      ]);
    }
    assert.ok(
      childRef.child.exitCode !== null ||
      childRef.child.signalCode !== null,
    );
    return evidence;
  } finally {
    await observer.close();
    await rm(temp, { recursive: true, force: true });
  }
}

test("shadow sync import preserves formal results and produces match evidence", {
  timeout: 60_000,
}, async () => {
  let baseline;
  let shadow;
  const evidenceDir = await tempDir("skilldock-shadow-evidence-");
  try {
    baseline = await startFormalServer();
    const baselineResult = await syncImport(baseline);
    assert.equal(baselineResult.status, 200);

    shadow = await startFormalServer({
      shadowMode: "shadow",
      evidenceDir,
    });
    const shadowResult = await syncImport(shadow);
    assert.equal(shadowResult.status, 200);
    assert.deepEqual(
      formalImportResult(shadowResult),
      formalImportResult(baselineResult),
    );
    assert.deepEqual(
      formalTimeline(shadowResult.state),
      formalTimeline(baselineResult.state),
    );
    assert.equal(
      JSON.stringify(shadowResult.state).includes("source_hosted_shadow"),
      false,
    );

    const evidence = await waitForEvidence(
      evidenceDir,
      (value) =>
        value.status === "match" && value.formal?.message_count === 2,
    );
    assert.equal(evidence.ok, true);
    assert.equal(
      evidence.profile.profile_id,
      "source-hosted-node24-node-sqlite-process-v1",
    );
    assert.equal(
      evidence.profile.profile_sha256,
      "36f023d9274b6924da1beeb7c01c72b583420744b17aa58039b3e060c9b38a2a",
    );
    assert.equal(evidence.coordinator_process.isolated, true);
    assert.equal(evidence.formal_response_unchanged, true);
    assert.equal(evidence.formal.message_count, 2);
    assert.equal(evidence.shadow.event_count, 2);
    assert.equal(evidence.shadow.published_count, 2);

    const evidenceText = JSON.stringify(evidence);
    assert.equal(evidenceText.includes(shadow.token), false);
    assert.equal(evidenceText.includes("游戏中出现短暂卡顿"), false);
    assert.equal(evidenceText.includes("先固定场景并记录时间"), false);
    assert.equal(/[A-Za-z]:[\\/]/u.test(evidenceText), false);
    assert.equal(shadow.stderr.includes(shadow.token), false);
    assert.equal(shadow.stderr.includes("游戏中出现短暂卡顿"), false);

    const repeated = await syncImport(shadow);
    assert.equal(repeated.status, 200);
    assert.equal(repeated.json.imported_count, 0);
    assert.equal(repeated.json.skipped_count, 2);
    assert.deepEqual(
      formalTimeline(repeated.state),
      formalTimeline(shadowResult.state),
    );
    const repeatedEvidence = await waitForEvidence(
      evidenceDir,
      (value) =>
        value.status === "match" &&
        value.shadow?.published_count === 0 &&
        value.shadow?.reused_count === 2,
    );
    assert.equal(repeatedEvidence.formal_response_unchanged, true);

    const health = await fetch(`${shadow.baseUrl}/api/health`);
    const healthText = await health.text();
    assert.equal(healthText.includes("source_hosted_shadow"), false);
  } finally {
    await shadow?.close().catch(() => {});
    await baseline?.close().catch(() => {});
    await rm(evidenceDir, { recursive: true, force: true });
  }
});

test("shadow publishes multi-batch imports beyond the 50-event schema limit", {
  timeout: 15_000,
}, async () => {
  const evidenceDir = await tempDir("skilldock-shadow-multibatch-");
  const observer = createSourceHostedShadowObserver({
    env: {
      PANEL_SOURCE_HOSTED_SHADOW: "shadow",
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    startupTimeoutMs: 5_000,
  });
  const messages = Array.from({ length: 55 }, (_, index) => ({
    external_id: `shadow-multibatch-${String(index + 1).padStart(2, "0")}`,
    role: index % 2 === 0 ? "user" : "agent",
    text: `Multi-batch shadow message ${index + 1}.`,
    created_at: new Date(
      Date.parse("2026-11-16T00:00:00.000Z") + index * 1000,
    ).toISOString(),
    seq: index + 1,
  }));
  try {
    const result = await observer.observeSyncImport({
      formal_task_id: "task-shadow-multibatch",
      channel_id: "chat:shadow:multibatch",
      source_session_ref: "source-shadow-multibatch",
      objective: "multi-batch shadow",
      cursor: messages.length,
      messages,
    });
    assert.equal(result.status, "match");
    assert.ok(result.evidence_file);
    const evidence = JSON.parse(
      await readFile(join(evidenceDir, result.evidence_file), "utf8"),
    );
    assert.equal(evidence.profile.identity_match, true);
    assert.equal(evidence.formal.message_count, 55);
    assert.equal(evidence.shadow.event_count, 55);
    assert.equal(evidence.shadow.published_count, 55);
    assert.equal(evidence.formal_response_unchanged, true);
  } finally {
    await observer.close();
    await rm(evidenceDir, { recursive: true, force: true });
  }
});

test("shadow coordinator shutdown removes its temporary SQLite fixture", {
  timeout: 15_000,
}, async () => {
  const evidenceDir = await tempDir("skilldock-shadow-cleanup-");
  const before = await fixtureDirectorySet();
  const observer = createSourceHostedShadowObserver({
    env: {
      PANEL_SOURCE_HOSTED_SHADOW: "shadow",
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    startupTimeoutMs: 5_000,
  });
  try {
    const result = await observer.observeSyncImport({
      formal_task_id: "task-shadow-cleanup",
      channel_id: "chat:shadow:cleanup",
      source_session_ref: "source-shadow-cleanup",
      objective: "shadow cleanup",
      cursor: 1,
      messages: [{
        external_id: "shadow-cleanup-message",
        role: "user",
        text: "shadow cleanup message",
        created_at: "2026-11-16T00:00:00.000Z",
        seq: 1,
      }],
    });
    assert.equal(result.status, "match");
    await observer.close();
    const deadline = Date.now() + 3_000;
    let leaked = [];
    while (Date.now() < deadline) {
      const after = await fixtureDirectorySet();
      leaked = [...after].filter((name) => !before.has(name));
      if (leaked.length === 0) break;
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    }
    assert.deepEqual(leaked, []);
  } finally {
    await observer.close();
    await rm(evidenceDir, { recursive: true, force: true });
  }
});

test("shadow fallback kill runs after stdin shutdown timeout and cleans fixture", {
  timeout: 15_000,
}, async () => {
  const temp = await tempDir("skilldock-shadow-ignore-stdin-");
  const evidenceDir = join(temp, "evidence");
  const workerPath = join(temp, "ignore-stdin-worker.mjs");
  const fixtureDirsBefore = await fixtureDirectorySet();
  await writeFile(
    workerPath,
    `
import { writeFileSync } from "node:fs";
import { join } from "node:path";
writeFileSync(
  join(process.env.SHADOW_FIXTURE_ROOT, "ignore-stdin.marker"),
  "ready",
);
process.stdout.write(JSON.stringify({
  ready: true,
  base_url: "http://127.0.0.1:9",
  task_id: process.env.SHADOW_TASK_ID,
  tokens: {
    source: "ignore-source-token",
    panel: "ignore-panel-token",
    control: "ignore-control-token"
  },
  profile_id: "${FROZEN_PROFILE_ID}",
  profile_sha256: "${FROZEN_PROFILE_SHA256}",
  runtime_gate: {
    ok: true,
    profile_id: "${FROZEN_PROFILE_ID}",
    blockers: []
  },
  database_gate: {
    ok: true,
    profile_id: "${FROZEN_PROFILE_ID}",
    blockers: []
  }
}) + "\\n");
process.stdin.resume();
setInterval(() => {}, 1000);
`,
    "utf8",
  );
  const ready = {
    child: null,
    fixtureRoot: null,
  };
  const observer = createSourceHostedShadowObserver({
    env: {
      PANEL_SOURCE_HOSTED_SHADOW: "shadow",
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    workerPath,
    profileProvider: async () => ({
      runtimeGate: { ok: true, blockers: [] },
      profileId: FROZEN_PROFILE_ID,
      profileSha256: FROZEN_PROFILE_SHA256,
    }),
    onCoordinatorReady(value) {
      ready.child = value.child;
      ready.fixtureRoot = value.fixtureRoot;
    },
    startupTimeoutMs: 2_000,
  });
  try {
    await observer.observeSyncImport({
      formal_task_id: "task-shadow-ignore-stdin",
      channel_id: "chat:shadow:ignore-stdin",
      source_session_ref: "source-shadow-ignore-stdin",
      objective: "ignore stdin shutdown",
      cursor: 1,
      messages: [{
        external_id: "shadow-ignore-stdin-message",
        role: "user",
        text: "ignore stdin message",
        created_at: "2026-11-16T00:00:00.000Z",
        seq: 1,
      }],
    });
    assert.ok(ready.child);
    assert.ok(ready.fixtureRoot);
    assert.equal(existsSync(ready.fixtureRoot), true);
    const closeStartedAt = Date.now();
    await observer.close();
    const closeElapsed = Date.now() - closeStartedAt;
    assert.ok(closeElapsed >= 1_800);
    assert.ok(
      ready.child.exitCode !== null ||
      ready.child.signalCode !== null,
    );
    assert.equal(existsSync(ready.fixtureRoot), false);
    assert.deepEqual(
      await waitForNoNewFixtureDirectories(fixtureDirsBefore),
      [],
    );
  } finally {
    await observer.close();
    await rm(temp, { recursive: true, force: true });
  }
});

test("shadow rejects child profile_id mismatch before mailbox fetch", {
  timeout: 15_000,
}, async () => {
  await runProfileIdentityMismatchCase({
    reportedProfileId: "unexpected-shadow-profile",
    reportedProfileSha256: FROZEN_PROFILE_SHA256,
    expectedBlocker: "profile_id_mismatch",
  });
});

test("shadow rejects child profile_sha256 mismatch before mailbox fetch", {
  timeout: 15_000,
}, async () => {
  await runProfileIdentityMismatchCase({
    reportedProfileId: FROZEN_PROFILE_ID,
    reportedProfileSha256: "0".repeat(64),
    expectedBlocker: "profile_sha256_mismatch",
  });
});

test("shadow blocks after coordinator exit without changing formal evidence", {
  timeout: 15_000,
}, async () => {
  const evidenceDir = await tempDir("skilldock-shadow-exit-");
  const fixtureDirsBefore = await fixtureDirectorySet();
  const logs = [];
  const ready = { child: null };
  const observer = createSourceHostedShadowObserver({
    env: {
      PANEL_SOURCE_HOSTED_SHADOW: "shadow",
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    onCoordinatorReady(value) {
      ready.child = value.child;
    },
    log(entry) {
      logs.push(entry);
    },
    startupTimeoutMs: 5_000,
  });
  const input = {
    formal_task_id: "task-shadow-exit-test",
    channel_id: "chat:shadow:coordinator-exit",
    source_session_ref: "source-shadow-exit",
    objective: "coordinator exit",
    cursor: 2,
    messages: [
      {
        external_id: "shadow-exit-user",
        role: "user",
        text: "coordinator exit user message",
        created_at: "2026-11-16T00:00:00.000Z",
        seq: 1,
      },
      {
        external_id: "shadow-exit-agent",
        role: "agent",
        text: "coordinator exit agent message",
        created_at: "2026-11-16T00:00:01.000Z",
        seq: 2,
      },
    ],
  };
  try {
    const matched = await observer.observeSyncImport(input);
    assert.equal(matched.status, "match");
    assert.ok(ready.child);
    ready.child.kill();
    if (ready.child.exitCode === null && ready.child.signalCode === null) {
      await Promise.race([
        new Promise((resolvePromise) => {
          ready.child.once("exit", resolvePromise);
        }),
        new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000)),
      ]);
    }
    assert.ok(
      ready.child.exitCode !== null ||
      ready.child.signalCode !== null,
    );

    const blocked = await observer.observeSyncImport(input);
    assert.equal(blocked.status, "blocked");
    assert.equal(blocked.reason, "shadow_coordinator_unavailable");
    const evidence = JSON.parse(
      await readFile(join(evidenceDir, blocked.evidence_file), "utf8"),
    );
    assert.equal(evidence.formal_response_unchanged, true);
    assert.equal(evidence.coordinator_process.started, true);
    assert.equal(evidence.coordinator_process.available, false);
    const serialized = JSON.stringify({
      evidence,
      logs,
    });
    assert.equal(serialized.includes("coordinator exit user message"), false);
    assert.equal(serialized.includes("coordinator exit agent message"), false);
    assert.equal(/[A-Za-z]:[\\/]/u.test(serialized), false);
    const leaked = await waitForNoNewFixtureDirectories(fixtureDirsBefore);
    assert.deepEqual(leaked, []);
  } finally {
    await observer.close();
    await rm(evidenceDir, { recursive: true, force: true });
  }
});

test("shadow configuration and observation failures fail closed", {
  timeout: 30_000,
}, async () => {
  assert.deepEqual(
    loadSourceHostedShadowConfig({ env: {} }),
    {
      configured: false,
      enabled: false,
      mode: "off",
      evidenceDir: null,
      configError: "flag_absent",
    },
  );
  assert.equal(
    loadSourceHostedShadowConfig({
      env: {
        PANEL_SOURCE_HOSTED_SHADOW: "default",
        PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: tmpdir(),
      },
    }).configError,
    "flag_not_shadow",
  );
  assert.equal(
    loadSourceHostedShadowConfig({
      env: {
        PANEL_SOURCE_HOSTED_SHADOW: "shadow",
      },
    }).configError,
    "evidence_dir_missing",
  );

  const evidenceDir = await tempDir("skilldock-shadow-blocked-");
  const input = {
    formal_task_id: "task-synthetic-shadow-failure",
    channel_id: "chat:shadow:test",
    source_session_ref: "source-shadow-failure",
    objective: "shadow failure",
    cursor: 1,
    messages: [{
      external_id: "shadow-failure-message",
      role: "user",
      text: "must not affect formal path",
      created_at: "2026-11-16T00:00:00.000Z",
      seq: 1,
    }],
  };
  try {
    const profileMismatch = createSourceHostedShadowObserver({
      env: {
        PANEL_SOURCE_HOSTED_SHADOW: "shadow",
        PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
      },
      profileProvider: async () => ({
        runtimeGate: {
          ok: false,
          blockers: ["node_version_outside_frozen_profile"],
        },
        profileId: "source-hosted-node24-node-sqlite-process-v1",
        profileSha256:
          "36f023d9274b6924da1beeb7c01c72b583420744b17aa58039b3e060c9b38a2a",
      }),
      spawnProcess() {
        throw new Error("spawn must not run on profile mismatch");
      },
    });
    const mismatchResult =
      await profileMismatch.observeSyncImport(input);
    assert.equal(mismatchResult.status, "blocked");
    assert.equal(mismatchResult.reason, "runtime_profile_mismatch");
    const mismatchEvidence = await waitForEvidence(
      evidenceDir,
      (value) => value.reason === "runtime_profile_mismatch",
      2_000,
    );
    assert.equal(mismatchEvidence.formal_response_unchanged, true);
    assert.equal(mismatchEvidence.coordinator_process.started, false);
    await profileMismatch.close();

    const unavailable = createSourceHostedShadowObserver({
      env: {
        PANEL_SOURCE_HOSTED_SHADOW: "shadow",
        PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
      },
      workerPath: join(evidenceDir, "missing-shadow-worker.mjs"),
      profileProvider: async () => ({
        runtimeGate: { ok: true, blockers: [] },
        profileId: "source-hosted-node24-node-sqlite-process-v1",
        profileSha256:
          "36f023d9274b6924da1beeb7c01c72b583420744b17aa58039b3e060c9b38a2a",
      }),
      startupTimeoutMs: 2_000,
    });
    const unavailableResult =
      await unavailable.observeSyncImport(input);
    assert.equal(unavailableResult.status, "blocked");
    assert.match(
      unavailableResult.reason,
      /shadow_coordinator_unavailable|MODULE_NOT_FOUND/u,
    );
    const unavailableEvidence = await waitForEvidence(
      evidenceDir,
      (value) =>
        value.status === "blocked" &&
        value.reason !== "runtime_profile_mismatch",
      3_000,
    );
    assert.equal(unavailableEvidence.formal_response_unchanged, true);
    assert.equal(unavailableEvidence.coordinator_process.started, false);
    await unavailable.close();
  } finally {
    await rm(evidenceDir, { recursive: true, force: true });
  }
});

test("explicit invalid shadow mode does not spawn and remains formally visible", {
  timeout: 30_000,
}, async () => {
  const evidenceDir = await tempDir("skilldock-shadow-invalid-");
  let server;
  try {
    server = await startFormalServer({
      shadowMode: "default",
      evidenceDir,
    });
    const result = await syncImport(server);
    assert.equal(result.status, 200);
    assert.equal(result.json.imported_count, 2);
    assert.equal(result.state.task.timeline.length, 2);
    const evidence = await waitForEvidence(
      evidenceDir,
      (value) => value.reason === "flag_not_shadow",
    );
    assert.equal(evidence.ok, false);
    assert.equal(evidence.formal_response_unchanged, true);
    assert.equal(evidence.coordinator_process.started, false);
    const evidenceFiles = await readdir(evidenceDir);
    assert.equal(evidenceFiles.length, 2);
    assert.equal(evidenceFiles.includes("latest.json"), true);
  } finally {
    await server?.close().catch(() => {});
    await rm(evidenceDir, { recursive: true, force: true });
  }
});

test("enabled shadow with missing evidence config keeps the formal path", {
  timeout: 30_000,
}, async () => {
  let server;
  try {
    server = await startFormalServer({
      shadowMode: "shadow",
      evidenceDir: "",
    });
    const result = await syncImport(server);
    assert.equal(result.status, 200);
    assert.equal(result.json.imported_count, 2);
    assert.equal(result.state.task.timeline.length, 2);
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
    assert.match(server.stderr, /"status":"blocked"/u);
    assert.equal(server.stderr.includes(server.token), false);
    assert.equal(server.stderr.includes("游戏中出现短暂卡顿"), false);
    assert.equal(server.stderr.includes("source-session-shadow-test"), false);
  } finally {
    await server?.close().catch(() => {});
  }
});
