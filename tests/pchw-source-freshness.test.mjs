import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import {
  mkdir,
  mkdtemp,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const integrationDir = join(root, "integrations", "skilldock");
const tempRoot = await mkdtemp(join(tmpdir(), "pchw-source-freshness-"));
const runtimeDir = join(tempRoot, "runtime");
const evidencePath = join(
  root,
  "work",
  "pchw-source-freshness-evidence-20261117.json",
);
const taskId = "task-pchw-freshness";
const channelId = "chat:source-hosted:freshness";
const sourceSessionRef = "11111111-1111-4111-8111-111111111111";
const oldAttachmentId = "attachment-old-result";
const newAttachmentId = "attachment-new-result";
const oldSha =
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const newSha =
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const intentEventId = "source-submission-new";
const submissionSequence = 10;
const submissionCreatedAt = "2026-11-17T10:00:00.000Z";
let mode = "stale";
let payload = null;
let server = null;
let phase = "waiting_for_source_pull";
let claimCalls = 0;
let claimMutations = 0;
let lastClaimBody = null;
let phaseAfterStaleExport = null;

function resultPacket(attachmentId, sha256, createdAt) {
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
          sha256,
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
        sha256,
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

function exportPayload() {
  const sourceToolResult =
    mode === "fresh"
      ? resultPacket(
          newAttachmentId,
          newSha,
          "2026-11-17T10:01:00.000Z",
        )
      : resultPacket(
          oldAttachmentId,
          oldSha,
          "2026-11-17T09:00:00.000Z",
        );
  return {
    ok: true,
    task_ref: taskId,
    shared_task: {
      phase,
    },
    cursor: submissionSequence,
    source_tool_result: sourceToolResult,
    panel: null,
    messages: [
      {
        seq: submissionSequence,
        external_id: intentEventId,
        role: "user",
        source: "source_hosted_intent",
        text: "Analyze the fresh uncached CSV.",
        created_at: submissionCreatedAt,
        attachments: [
          {
            id: newAttachmentId,
            sha256: newSha,
          },
        ],
      },
    ],
  };
}

function runPowerShell(script, args, timeoutMs = 30_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        join(integrationDir, script),
        ...args,
      ],
      {
        cwd: root,
        windowsHide: true,
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
    const timer = setTimeout(() => {
      child.kill();
      rejectPromise(new Error(`${script} timed out`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr });
    });
  });
}

function commonArgs() {
  return [
    "-ChannelId",
    channelId,
    "-SourceSessionRef",
    sourceSessionRef,
    "-RuntimeDirectory",
    runtimeDir,
    "-ExpectedTaskId",
    taskId,
    "-ExpectedAttachmentId",
    newAttachmentId,
    "-ExpectedAttachmentSha256",
    newSha,
    "-ExpectedSubmissionSequence",
    String(submissionSequence),
    "-ExpectedIntentEventId",
    intentEventId,
  ];
}

try {
  await mkdir(runtimeDir, { recursive: true });
  server = createServer(async (request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    response.setHeader("Content-Type", "application/json");
    if (url.pathname === "/api/health") {
      response.end(JSON.stringify({ ok: true }));
      return;
    }
    if (url.pathname === "/api/task/sync/export") {
      payload = exportPayload();
      response.end(JSON.stringify(payload));
      return;
    }
    if (url.pathname === "/api/task/sync/claim") {
      claimCalls += 1;
      if (
        request.headers.authorization !== "Bearer test-source-token" ||
        request.headers["x-source-session-ref"] !== sourceSessionRef
      ) {
        response.statusCode = 403;
        response.end(JSON.stringify({
          ok: false,
          code: "claim_source_session_mismatch",
        }));
        return;
      }
      let bodyText = "";
      for await (const chunk of request) {
        bodyText += chunk.toString();
      }
      const body = JSON.parse(bodyText);
      lastClaimBody = body;
      if (
        body.task_ref !== taskId ||
        body.channel_id !== channelId ||
        body.source_session_ref !== sourceSessionRef ||
        body.intent_event_id !== intentEventId ||
        body.submission_sequence !== submissionSequence ||
        body.attachment_id !== newAttachmentId ||
        body.attachment_sha256 !== newSha ||
        body.require_source_result !== true
      ) {
        response.statusCode = 409;
        response.end(JSON.stringify({
          ok: false,
          code: "claim_anchor_mismatch",
        }));
        return;
      }
      if (phase === "waiting_for_source_pull") {
        phase = "source_agent_pulled";
        claimMutations += 1;
        response.end(JSON.stringify({
          ok: true,
          claimed: true,
          idempotent: false,
          task_ref: taskId,
          phase,
          claim: {
            intent_event_id: intentEventId,
            submission_sequence: submissionSequence,
            attachment_id: newAttachmentId,
            attachment_sha256: newSha,
            require_source_result: true,
          },
        }));
        return;
      }
      if (phase === "source_agent_pulled") {
        response.end(JSON.stringify({
          ok: true,
          claimed: true,
          idempotent: true,
          task_ref: taskId,
          phase,
          claim: {
            intent_event_id: intentEventId,
            submission_sequence: submissionSequence,
            attachment_id: newAttachmentId,
            attachment_sha256: newSha,
            require_source_result: true,
          },
        }));
        return;
      }
      response.statusCode = 409;
      response.end(JSON.stringify({
        ok: false,
        code: "claim_phase_conflict",
        phase,
      }));
      return;
    }
    response.statusCode = 404;
    response.end(JSON.stringify({ error: "not found" }));
  });
  await new Promise((resolvePromise) =>
    server.listen(0, "127.0.0.1", resolvePromise)
  );
  const address = server.address();
  await writeFile(
    join(runtimeDir, "server-info.json"),
    `${JSON.stringify({
      pid: process.pid,
      port: address.port,
    })}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  await writeFile(
    join(runtimeDir, "source-capability-token"),
    "test-source-token\n",
    { encoding: "utf8", mode: 0o600 },
  );

  const staleWait = await runPowerShell(
    "wait-panel.ps1",
    [
      ...commonArgs(),
      "-TimeoutSeconds",
      "5",
      "-PollMilliseconds",
      "250",
    ],
    10_000,
  );
  assert.equal(staleWait.code, 1);
  assert.ok(staleWait.stdout.trim(), staleWait.stderr);
  const staleTimeout = JSON.parse(staleWait.stdout.trim());
  assert.equal(staleTimeout.error_code, "panel_wait_timeout");
  assert.equal(staleTimeout.stale_result_observed, true);
  assert.equal(staleTimeout.freshness.code, "stale_source_result");
  assert.equal(staleTimeout.freshness.returned_attachment_id, oldAttachmentId);
  assert.equal(staleTimeout.freshness.returned_sha256, oldSha);
  assert.equal(phase, "waiting_for_source_pull");
  assert.equal(claimCalls, 0);
  assert.equal(claimMutations, 0);
  phaseAfterStaleExport = phase;

  const staleSync = await runPowerShell(
    "sync-panel.ps1",
    [
      ...commonArgs(),
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-AfterSequence",
      "9",
    ],
    10_000,
  );
  assert.equal(staleSync.code, 1);
  assert.ok(staleSync.stdout.trim(), staleSync.stderr);
  const staleSyncResult = JSON.parse(staleSync.stdout.trim());
  assert.equal(staleSyncResult.error_code, "panel_sync_stale_result");
  assert.equal(staleSyncResult.freshness.code, "stale_source_result");
  assert.equal(phase, "waiting_for_source_pull");
  assert.equal(claimCalls, 0);
  assert.equal(claimMutations, 0);

  const freshWaitPromise = runPowerShell(
    "wait-panel.ps1",
    [
      ...commonArgs(),
      "-TimeoutSeconds",
      "10",
      "-PollMilliseconds",
      "250",
    ],
    15_000,
  );
  setTimeout(() => {
    mode = "fresh";
  }, 500);
  const freshWait = await freshWaitPromise;
  assert.equal(freshWait.code, 0, freshWait.stderr);
  const freshWaitResult = JSON.parse(freshWait.stdout.trim());
  assert.equal(freshWaitResult.ready, true);
  assert.equal(freshWaitResult.freshness.code, "fresh_source_result");
  assert.equal(
    freshWaitResult.source_tool_result.packet.attachment_id,
    newAttachmentId,
  );
  assert.equal(freshWaitResult.claim.idempotent, false);
  assert.equal(phase, "source_agent_pulled");
  assert.equal(claimCalls, 1);
  assert.equal(claimMutations, 1);
  assert.equal(lastClaimBody.attachment_id, newAttachmentId);
  assert.equal(lastClaimBody.attachment_sha256, newSha);

  const freshSync = await runPowerShell(
    "sync-panel.ps1",
    [
      ...commonArgs(),
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-AfterSequence",
      "9",
    ],
    10_000,
  );
  assert.equal(freshSync.code, 0, freshSync.stderr);
  const freshSyncResult = JSON.parse(freshSync.stdout.trim());
  assert.equal(freshSyncResult.freshness.code, "fresh_source_result");
  assert.equal(
    freshSyncResult.source_tool_result.packet.attachment_id,
    newAttachmentId,
  );
  assert.equal(freshSyncResult.claim.idempotent, true);
  assert.equal(phase, "source_agent_pulled");
  assert.equal(claimCalls, 2);
  assert.equal(claimMutations, 1);
  assert.deepEqual(
    freshSyncResult.messages.map((message) => message.seq),
    [submissionSequence],
  );

  await writeFile(
    evidencePath,
    `${JSON.stringify({
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_source_result_freshness",
      stale_wait: {
        code: staleTimeout.error_code,
        stale_result_observed: staleTimeout.stale_result_observed,
        returned_attachment_id: staleTimeout.freshness.returned_attachment_id,
        returned_sha256: staleTimeout.freshness.returned_sha256,
      },
      stale_sync: {
        code: staleSyncResult.error_code,
        freshness_code: staleSyncResult.freshness.code,
      },
      fresh_wait: {
        code: freshWaitResult.freshness.code,
        returned_attachment_id:
          freshWaitResult.freshness.returned_attachment_id,
        returned_sha256: freshWaitResult.freshness.returned_sha256,
      },
      fresh_sync: {
        code: freshSyncResult.freshness.code,
        returned_attachment_id:
          freshSyncResult.freshness.returned_attachment_id,
        returned_sha256: freshSyncResult.freshness.returned_sha256,
        message_sequences: freshSyncResult.messages.map(
          (message) => message.seq,
        ),
      },
      claim: {
        request_count: claimCalls,
        mutation_count: claimMutations,
        duplicate_idempotent: freshSyncResult.claim.idempotent,
        phase_after_stale_export: phaseAfterStaleExport,
      },
      expected_submission_sequence: submissionSequence,
      expected_intent_event_id: intentEventId,
      thread_api_calls: 0,
      real_thread_created: false,
      observed_at: new Date().toISOString(),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  console.log("PCHW source-result freshness guard: PASS");
} finally {
  if (server) {
    await new Promise((resolvePromise) =>
      server.close(resolvePromise)
    );
  }
  await rm(tempRoot, { recursive: true, force: true });
}
