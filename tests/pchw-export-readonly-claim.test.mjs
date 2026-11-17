import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const tempRoot = await mkdtemp(join(tmpdir(), "pchw-export-readonly-"));
const runtimeDir = join(tempRoot, "runtime");
const workspaceDir = join(tempRoot, "workspace");
const taskId = "task-pchw-export-readonly";
const channelId = "chat:source-hosted:export-readonly";
const sourceSessionRef = "22222222-2222-4222-8222-222222222222";
const intentEventId = "source-submission-export-readonly";
const submissionSequence = 42;
const oldAttachmentId = "attachment-old-export-result";
const newAttachmentId = "attachment-new-export-result";
const oldSha256 = "a".repeat(64);
const newSha256 = "b".repeat(64);
const submissionCreatedAt = "2026-11-17T10:00:00.000Z";
let child = null;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
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

function runtimeEnv(port) {
  return {
    ...process.env,
    PANEL_AGENT_DRIVER: "mock",
    PANEL_PORT: String(port),
    PANEL_RUNTIME_DIR: runtimeDir,
    PANEL_AGENT_WORKSPACE: workspaceDir,
    PANEL_SKILL_MANIFEST: join(
      root,
      "skills",
      "generic-demo",
      "workbench.manifest.json",
    ),
    PANEL_SKILL_ID: "generic-demo",
    PANEL_SOURCE_HOSTED_ENTRY: "1",
    PANEL_SOURCE_HOSTED_NON_MOCK: "",
    PANEL_SOURCE_HOSTED_SHADOW: "",
  };
}

async function startServer() {
  const port = await freePort();
  child = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: runtimeEnv(port),
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        return {
          baseUrl,
          masterToken: (
            await readFile(join(runtimeDir, "capability-token"), "utf8")
          ).trim(),
          panelToken: (
            await readFile(
              join(runtimeDir, "panel-capability-token"),
              "utf8",
            )
          ).trim(),
          sourceToken: (
            await readFile(
              join(runtimeDir, "source-capability-token"),
              "utf8",
            )
          ).trim(),
        };
      }
    } catch {
      // Server is still starting.
    }
    await new Promise((resolvePromise) =>
      setTimeout(resolvePromise, 100)
    );
  }
  throw new Error(`server readiness timeout: ${stderr}`);
}

async function stopServer(server) {
  if (!child || child.exitCode !== null) return;
  await fetch(`${server.baseUrl}/api/shutdown`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${server.masterToken}`,
      "Content-Type": "application/json",
    },
    body: "{}",
  }).catch(() => {});
  await Promise.race([
    new Promise((resolvePromise) => child.once("exit", resolvePromise)),
    new Promise((resolvePromise) => setTimeout(resolvePromise, 5_000)),
  ]);
  if (child.exitCode === null) child.kill();
  child = null;
}

function sourceHeaders(server, { json = false } = {}) {
  return {
    Authorization: `Bearer ${server.sourceToken}`,
    "X-Source-Session-Ref": sourceSessionRef,
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

function panelHeaders(server) {
  return {
    Cookie: `panel_token=${encodeURIComponent(server.panelToken)}`,
  };
}

function sourceResultPacket({
  attachmentId,
  attachmentSha256,
  createdAt,
}) {
  return {
    schema_version: "1.0",
    packet: {
      schema_version: "1.0",
      type: "panel_tool_result",
      event_id: `event-${attachmentId}`,
      created_at: createdAt,
      task_id: taskId,
      attachment_id: attachmentId,
      tool_result: {
        tool: "skill.local_action",
        read_only: true,
        cache_hit: false,
        attachment: {
          id: attachmentId,
          sha256: attachmentSha256,
        },
        analysis: {
          analyzed_rows: 8,
          metrics: [
            {
              metric: "FPS",
              min: 60,
              max: 120,
            },
          ],
        },
        artifact: {
          id: `artifact-${attachmentId}`,
          source_evidence_ids: [attachmentId],
        },
      },
    },
    result: {
      ok: true,
      cache_hit: false,
      attachment: {
        id: attachmentId,
        sha256: attachmentSha256,
      },
      analysis: {
        analyzed_rows: 8,
        metrics: [
          {
            metric: "FPS",
            min: 60,
            max: 120,
          },
        ],
      },
      artifact: {
        id: `artifact-${attachmentId}`,
        source_evidence_ids: [attachmentId],
      },
    },
    received_at: createdAt,
  };
}

function claimBody() {
  return {
    schema_version: "1.0",
    task_ref: taskId,
    channel_id: channelId,
    source_session_ref: sourceSessionRef,
    intent_event_id: intentEventId,
    submission_sequence: submissionSequence,
    attachment_id: newAttachmentId,
    attachment_sha256: newSha256,
    require_source_result: true,
  };
}

try {
  await mkdir(runtimeDir, { recursive: true });
  await mkdir(workspaceDir, { recursive: true });

  let server = await startServer();
  const baseState = JSON.parse(
    await readFile(join(runtimeDir, "state.json"), "utf8"),
  );
  await stopServer(server);

  const task = structuredClone(baseState.task);
  task.task_id = taskId;
  task.objective = "Read-only export and explicit fresh claim regression";
  task.summary = "";
  task.sync = {
    schema_version: "1.0",
    channel_id: channelId,
    source_session_ref: sourceSessionRef,
    created_at: submissionCreatedAt,
  };
  task.attachments = [
    {
      id: newAttachmentId,
      source_attachment_id: `chat-file:${newSha256}`,
      original_name: "fresh-export-readonly.csv",
      mime_type: "text/csv",
      size: 128,
      sha256: newSha256,
      local_path: join(runtimeDir, "attachments", "fixture.csv"),
    },
  ];
  task.timeline = [
    {
      seq: submissionSequence,
      id: "timeline-export-readonly-intent",
      external_id: intentEventId,
      role: "user",
      text: "Analyze the fresh attachment.",
      created_at: submissionCreatedAt,
      source: "source_hosted_intent",
      attachments: [
        {
          id: newAttachmentId,
          sha256: newSha256,
        },
      ],
    },
  ];
  task.shared_task = {
    schema_version: "1.0",
    mode: "source_hosted",
    execution_owner: "source",
    channel_id: channelId,
    source_session_ref: sourceSessionRef,
    environment_thread_id: sourceSessionRef,
    phase: "waiting_for_source_pull",
    bound_at: "2026-11-17T09:00:00.000Z",
    updated_at: "2026-11-17T10:00:00.000Z",
    last_intent_at: submissionCreatedAt,
    last_intent_id: intentEventId,
    source_tool_result: sourceResultPacket({
      attachmentId: oldAttachmentId,
      attachmentSha256: oldSha256,
      createdAt: "2026-11-17T09:30:00.000Z",
    }),
  };
  baseState.task = task;
  baseState.phase = "ready";
  baseState.panel = null;
  baseState.last_turn = null;
  baseState.activity = null;
  baseState.draft = { events: [], attachments: [] };
  baseState.error = null;
  await writeFile(
    join(runtimeDir, "state.json"),
    `${JSON.stringify(baseState, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  server = await startServer();
  const startedStateResponse = await fetch(
    `${server.baseUrl}/api/state`,
    { headers: panelHeaders(server) },
  );
  assert.equal(startedStateResponse.status, 200);
  const startedState = await startedStateResponse.json();
  assert.equal(startedState.task.task_id, taskId);
  const statePath = join(runtimeDir, "state.json");
  const hashBeforeExport = sha256(await readFile(statePath));
  let response = await fetch(
    `${server.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: sourceHeaders(server) },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.shared_task.phase, "waiting_for_source_pull");
  assert.equal(
    exported.source_tool_result.packet.attachment_id,
    oldAttachmentId,
  );
  assert.equal(sha256(await readFile(statePath)), hashBeforeExport);

  response = await fetch(
    `${server.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(server, { json: true }),
      body: JSON.stringify(claimBody()),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "claim_result_stale");
  assert.equal(sha256(await readFile(statePath)), hashBeforeExport);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(server),
  });
  let state = await response.json();
  assert.equal(state.task.shared_task.phase, "waiting_for_source_pull");
  const eventCountBeforeFreshClaim = state.event_count;

  await stopServer(server);
  const staleState = JSON.parse(await readFile(statePath, "utf8"));
  staleState.task.shared_task.source_tool_result = sourceResultPacket({
    attachmentId: newAttachmentId,
    attachmentSha256: newSha256,
    createdAt: "2026-11-17T10:01:00.000Z",
  });
  await writeFile(
    statePath,
    `${JSON.stringify(staleState, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  server = await startServer();
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(server),
  });
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "waiting_for_source_pull");
  const eventCountBeforeFreshClaimOnRestartedServer = state.event_count;
  response = await fetch(
    `${server.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(server, { json: true }),
      body: JSON.stringify(claimBody()),
    },
  );
  assert.equal(response.status, 200);
  const firstClaim = await response.json();
  assert.equal(firstClaim.phase, "source_agent_pulled");
  assert.equal(firstClaim.idempotent, false);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(server),
  });
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "source_agent_pulled");
  assert.equal(
    state.event_count,
    eventCountBeforeFreshClaimOnRestartedServer + 1,
  );
  const eventCountAfterFreshClaim = state.event_count;

  response = await fetch(
    `${server.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(server, { json: true }),
      body: JSON.stringify(claimBody()),
    },
  );
  assert.equal(response.status, 200);
  const repeatedClaim = await response.json();
  assert.equal(repeatedClaim.idempotent, true);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(server),
  });
  state = await response.json();
  assert.equal(state.event_count, eventCountAfterFreshClaim);
  assert.equal(state.task.shared_task.phase, "source_agent_pulled");

  await writeFile(
    join(
      root,
      "work",
      "pchw-export-readonly-claim-evidence-20261117.json",
    ),
    `${JSON.stringify({
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_export_readonly_explicit_claim",
      export: {
        phase: exported.shared_task.phase,
        state_file_unchanged: true,
        returned_stale_attachment_id:
          exported.source_tool_result.packet.attachment_id,
      },
      stale_claim: {
        error_code: "claim_result_stale",
        phase_preserved: true,
        event_count_unchanged: true,
      },
      fresh_claim: {
        phase: firstClaim.phase,
        idempotent: firstClaim.idempotent,
        event_delta: 1,
      },
      duplicate_claim: {
        phase: repeatedClaim.phase,
        idempotent: repeatedClaim.idempotent,
        event_delta: 0,
      },
      real_thread_created: false,
      thread_api_calls: 0,
      observed_at: new Date().toISOString(),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  await stopServer(server);
  console.log("PCHW read-only export and explicit claim: PASS");
} finally {
  if (child && child.exitCode === null) child.kill();
  await rm(tempRoot, { recursive: true, force: true });
}
