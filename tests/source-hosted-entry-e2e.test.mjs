import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  MockAgentDriver,
} from "../lib/agents/mock-agent-driver.mjs";
import {
  signHandoffToken,
} from "../lib/handoff-capability.mjs";

const root = resolve(import.meta.dirname, "..");

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

async function startServer({
  entryEnabled,
  runtimeDir = "",
  workspace = "",
  port = 0,
  nonMock = false,
}) {
  const resolvedPort = port || await freePort();
  const resolvedRuntimeDir =
    runtimeDir || await mkdtemp(join(tmpdir(), "skilldock-e2e-runtime-"));
  const resolvedWorkspace =
    workspace || await mkdtemp(join(tmpdir(), "skilldock-e2e-workspace-"));
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "mock",
      PANEL_PORT: String(resolvedPort),
      PANEL_RUNTIME_DIR: resolvedRuntimeDir,
      PANEL_AGENT_WORKSPACE: resolvedWorkspace,
      PANEL_SKILL_MANIFEST: join(
        root,
        "skills",
        "generic-demo",
        "workbench.manifest.json",
      ),
      PANEL_SKILL_ID: "generic-demo",
      PANEL_SOURCE_HOSTED_ENTRY: entryEnabled ? "1" : "",
      PANEL_SOURCE_HOSTED_NON_MOCK: nonMock ? "1" : "",
      PANEL_SOURCE_HOSTED_SHADOW: "",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const baseUrl = `http://127.0.0.1:${resolvedPort}`;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`entry server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        const token = (
          await readFile(join(resolvedRuntimeDir, "capability-token"), "utf8")
        ).trim();
        const panelToken = (
          await readFile(
            join(resolvedRuntimeDir, "panel-capability-token"),
            "utf8",
          )
        ).trim();
        const sourceToken = (
          await readFile(
            join(resolvedRuntimeDir, "source-capability-token"),
            "utf8",
          )
        ).trim();
        const handoffSecret = (
          await readFile(join(resolvedRuntimeDir, "handoff-secret"), "utf8")
        ).trim();
        return {
          child,
          port: resolvedPort,
          baseUrl,
          runtimeDir: resolvedRuntimeDir,
          workspace: resolvedWorkspace,
          token,
          panelToken,
          sourceToken,
          handoffSecret,
          get stderr() {
            return stderr;
          },
          async close({ removeData = true } = {}) {
            if (child.exitCode === null) {
              await fetch(`${baseUrl}/api/shutdown`, {
                method: "POST",
                headers: {
                  Authorization: `Bearer ${token}`,
                  "Content-Type": "application/json",
                },
                body: "{}",
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
            if (removeData) {
              await rm(resolvedRuntimeDir, { recursive: true, force: true });
              await rm(resolvedWorkspace, { recursive: true, force: true });
            }
          },
        };
      }
    } catch {
      // Server is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  child.kill();
  await rm(resolvedRuntimeDir, { recursive: true, force: true });
  await rm(resolvedWorkspace, { recursive: true, force: true });
  throw new Error(`entry server readiness timeout: ${stderr}`);
}

function packet(taskId, threadId, environmentThreadId = threadId) {
  return {
    thread_id: threadId,
    environment_thread_id: environmentThreadId,
    task_id: taskId,
    objective: "验证单 Task source_hosted 端到端闭环",
    summary: "从来源 Task 进入页面，提交本地操作，由 mock Agent 继续并回传结果。",
    domain_state: {},
    domain_refs: [],
    read_only: true,
    source: "agent-skill",
  };
}

function authHeaders(server) {
  return {
    Authorization: `Bearer ${server.token}`,
    "Content-Type": "application/json",
  };
}

function panelHeaders(server, { json = false } = {}) {
  return {
    Cookie: `panel_token=${encodeURIComponent(server.panelToken)}`,
    ...(json
      ? { "Content-Type": "application/json" }
      : {}),
  };
}

function sourceHeaders(server, sourceSessionRef, { json = false } = {}) {
  return {
    Authorization: `Bearer ${server.sourceToken}`,
    "X-Source-Session-Ref": sourceSessionRef,
    ...(json
      ? { "Content-Type": "application/json" }
      : {}),
  };
}

function agentImportBody(channelId, sourceThreadId, messageId, {
  role = "agent",
} = {}) {
  return {
    schema_version: "1.0",
    channel_id: channelId,
    source_session_ref: sourceThreadId,
    objective: "验证单 Task source_hosted 端到端闭环",
    summary: "来源 Agent 返回结果。",
    messages: [{
      id: messageId,
      role,
      text: "Mock source Agent result.",
      created_at: "2026-11-17T00:00:02.000Z",
    }],
  };
}

function sourcePullClaimBody(channelId, sourceThreadId, taskId, intent) {
  return {
    schema_version: "1.0",
    task_ref: taskId,
    channel_id: channelId,
    source_session_ref: sourceThreadId,
    intent_event_id: intent.external_id,
    submission_sequence: intent.seq,
    attachment_id: "",
    attachment_sha256: "",
    require_source_result: false,
  };
}

let enabledServer;
let disabledServer;
let recoveryServer;
try {
  enabledServer = await startServer({ entryEnabled: true });
  const sourceThreadId = "01a1e2d0-0000-7000-8000-000000000101";
  const taskId = "task-source-hosted-e2e-001";
  const signed = signHandoffToken(
    packet(taskId, sourceThreadId),
    enabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  const entryResponse = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(signed.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(entryResponse.status, 303);
  assert.equal(entryResponse.headers.get("location"), "/");
  const panelCookie = entryResponse.headers.get("set-cookie") ?? "";
  const panelCookieMatch = panelCookie.match(/panel_token=([^;]+)/u);
  assert.ok(panelCookieMatch);
  assert.equal(
    decodeURIComponent(panelCookieMatch[1]),
    enabledServer.panelToken,
  );
  assert.notEqual(enabledServer.panelToken, enabledServer.sourceToken);
  assert.notEqual(enabledServer.panelToken, enabledServer.token);
  assert.notEqual(enabledServer.sourceToken, enabledServer.token);

  const page = await fetch(`${enabledServer.baseUrl}/`);
  assert.equal(page.status, 200);
  const pageText = await page.text();
  assert.match(pageText, /SkillDock/u);
  for (const secret of [
    enabledServer.token,
    enabledServer.panelToken,
    enabledServer.sourceToken,
  ]) {
    assert.equal(pageText.includes(secret), false);
  }

  let response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  let currentState = await response.json();
  const stateText = JSON.stringify(currentState);
  assert.equal(stateText.includes(enabledServer.token), false);
  assert.equal(stateText.includes(enabledServer.sourceToken), false);
  const channelId = `chat:source-hosted:${sourceThreadId}`;
  assert.equal(currentState.task.task_id, taskId);
  assert.equal(currentState.task.shared_task.mode, "source_hosted");
  assert.equal(currentState.task.shared_task.phase, "source_owned");
  assert.equal(currentState.task.sync.channel_id, channelId);
  assert.equal(
    currentState.task.sync.source_session_ref,
    sourceThreadId,
  );
  assert.equal(currentState.panel, null);
  const mismatchedBindingSigned = signHandoffToken(
    packet(
      taskId,
      sourceThreadId,
      "01a1e2d0-0000-7000-8000-000000000199",
    ),
    enabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(mismatchedBindingSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 409);
  assert.equal(
    (await response.json()).code,
    "thread_binding_mismatch",
  );
  const missingBindingPacket = packet(
    taskId,
    sourceThreadId,
  );
  delete missingBindingPacket.environment_thread_id;
  const missingBindingSigned = signHandoffToken(
    missingBindingPacket,
    enabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(missingBindingSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "thread_binding_missing");
  const normalHandoffSigned = signHandoffToken(
    packet(
      "task-normal-handoff-blocked-001",
      "01a1e2d0-0000-7000-8000-000000000190",
    ),
    enabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${enabledServer.baseUrl}/handoff/open?token=${
      encodeURIComponent(normalHandoffSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 409);
  assert.equal(
    (await response.json()).code,
    "single_task_scope",
  );
  response = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(signed.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 409);

  const tamperedSigned = signHandoffToken(
    packet(
      "task-source-hosted-tampered-001",
      "01a1e2d0-0000-7000-8000-000000000191",
    ),
    enabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  const tampered = `${
    tamperedSigned.token.slice(0, -1)
  }${tamperedSigned.token.endsWith("A") ? "B" : "A"}`;
  response = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(tampered)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 401);

  const expiredSigned = signHandoffToken(
    packet(
      "task-source-hosted-expired-001",
      "01a1e2d0-0000-7000-8000-000000000192",
    ),
    enabledServer.handoffSecret,
    {
      ttlSeconds: 15,
      now: Date.now() - 60_000,
    },
  );
  response = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(expiredSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 401);
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: {
      Authorization: `Bearer ${enabledServer.sourceToken}`,
    },
  });
  assert.equal(response.status, 403);
  assert.equal(
    (await response.json()).code,
    "panel_capability_required",
  );

  response = await fetch(`${enabledServer.baseUrl}/api/submit`, {
    method: "POST",
    headers: panelHeaders(enabledServer, { json: true }),
    body: JSON.stringify({ free_text: "面板不应创建 Turn" }),
  });
  assert.equal(response.status, 409);
  assert.equal(
    (await response.json()).code,
    "panel_turn_forbidden_in_source_hosted",
  );
  for (const resetPath of [
    "/api/task/new",
    "/api/reset",
    "/api/session/new",
    "/api/thread/new",
  ]) {
    response = await fetch(`${enabledServer.baseUrl}${resetPath}`, {
      method: "POST",
      headers: panelHeaders(enabledServer, { json: true }),
      body: "{}",
    });
    assert.equal(response.status, 409);
    assert.equal((await response.json()).code, "single_task_scope");
  }
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  assert.equal((await response.json()).task.task_id, taskId);

  response = await fetch(`${enabledServer.baseUrl}/api/event`, {
    method: "POST",
    headers: panelHeaders(enabledServer, { json: true }),
    body: JSON.stringify({
      type: "evidence_added",
      label: "固定场景复测",
      detail: "保持同一画质和路线记录一次卡顿。",
      source: "user_reported",
    }),
  });
  assert.equal(response.status, 200);
  currentState = await response.json();
  assert.equal(
    currentState.task.shared_task.phase,
    "waiting_for_source_pull",
  );
  const queuedIntent = currentState.task.timeline.find(
    (entry) => entry.source === "source_hosted_intent",
  );
  assert.ok(queuedIntent);
  assert.match(queuedIntent.text, /固定场景复测/u);
  const phaseAtWaiting = currentState.task.shared_task.phase;
  const timelineAtWaiting = currentState.task.timeline.length;

  response = await fetch(`${enabledServer.baseUrl}/api/event`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${enabledServer.sourceToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      type: "evidence_added",
      label: "不应被 source 接受",
      detail: "source capability 不能使用 panel API。",
    }),
  });
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "panel_capability_required");
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: {
      Cookie: `panel_token=${encodeURIComponent(enabledServer.sourceToken)}`,
    },
  });
  assert.equal(response.status, 401);

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: panelHeaders(enabledServer, { json: true }),
      body: JSON.stringify(
        agentImportBody(
          channelId,
          sourceThreadId,
          "panel-forged-agent-result",
        ),
      ),
    },
  );
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "source_capability_required");

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: authHeaders(enabledServer),
      body: JSON.stringify(
        agentImportBody(
          channelId,
          sourceThreadId,
          "master-forged-agent-result",
        ),
      ),
    },
  );
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "source_capability_required");

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(
        agentImportBody(
          `chat:wrong:${sourceThreadId}`,
          sourceThreadId,
          "wrong-channel-agent-result",
        ),
      ),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "channel_binding_mismatch");

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(
        agentImportBody(
          channelId,
          "01a1e2d0-0000-7000-8000-000000000199",
          "wrong-session-agent-result",
        ),
      ),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "source_session_scope");

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(
        agentImportBody(
          channelId,
          sourceThreadId,
          "skip-export-agent-result",
        ),
      ),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "phase_conflict");

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    { headers: panelHeaders(enabledServer) },
  );
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "source_capability_required");

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    {
      headers: sourceHeaders(
        enabledServer,
        "01a1e2d0-0000-7000-8000-000000000199",
      ),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "source_session_scope");
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(currentState.task.shared_task.phase, phaseAtWaiting);
  assert.equal(currentState.task.timeline.length, timelineAtWaiting);

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    {
      headers: sourceHeaders(enabledServer, sourceThreadId),
    },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.task_ref, taskId);
  assert.equal(exported.shared_task.phase, "waiting_for_source_pull");
  assert.ok(
    exported.messages.some(
      (message) => message.source === "source_hosted_intent",
    ),
  );
  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/export?channel_id=${
      encodeURIComponent(channelId)
    }&after_seq=0`,
    {
      headers: sourceHeaders(enabledServer, sourceThreadId),
    },
  );
  assert.equal(response.status, 200);
  const repeatedExport = await response.json();
  assert.equal(repeatedExport.shared_task.phase, "waiting_for_source_pull");
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(
    currentState.task.shared_task.phase,
    "waiting_for_source_pull",
  );
  const eventCountBeforeClaim = currentState.event_count;
  const claimBody = sourcePullClaimBody(
    channelId,
    sourceThreadId,
    taskId,
    queuedIntent,
  );
  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify({
        ...claimBody,
        intent_event_id: "source-intent-wrong",
      }),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "claim_anchor_mismatch");
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(
    currentState.task.shared_task.phase,
    "waiting_for_source_pull",
  );
  assert.equal(currentState.event_count, eventCountBeforeClaim);
  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(claimBody),
    },
  );
  assert.equal(response.status, 200);
  const firstClaim = await response.json();
  assert.equal(firstClaim.claimed, true);
  assert.equal(firstClaim.idempotent, false);
  assert.equal(firstClaim.phase, "source_agent_pulled");
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(
    currentState.task.shared_task.phase,
    "source_agent_pulled",
  );
  const eventCountAfterClaim = currentState.event_count;
  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/claim`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(claimBody),
    },
  );
  assert.equal(response.status, 200);
  const repeatedClaim = await response.json();
  assert.equal(repeatedClaim.claimed, true);
  assert.equal(repeatedClaim.idempotent, true);
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(currentState.event_count, eventCountAfterClaim);
  const phaseAtPulled = repeatedClaim.phase;

  const mockDriver = new MockAgentDriver();
  await mockDriver.initialize();
  const agentThread = await mockDriver.startThread();
  const turn = await mockDriver.sendTurn({
    threadReference: agentThread.threadReference,
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: exported.messages.map((message) => message.text).join("\n"),
      skill_context: {
        skill_id: "generic-demo",
        runtime_id: "generic-demo",
      },
    },
  });
  await mockDriver.close();
  assert.equal(turn.structuredOutput?.schema_version, "1.2");
  assert.ok(turn.structuredOutput.turn_summary);

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(
        agentImportBody(
          channelId,
          sourceThreadId,
          "user-only-result",
          { role: "user" },
        ),
      ),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "source_result_required");
  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(
    currentState.task.shared_task.phase,
    "source_agent_pulled",
  );
  assert.equal(
    currentState.task.timeline.reduce(
      (max, entry) =>
        Number.isInteger(entry.seq) ? Math.max(max, entry.seq) : max,
      0,
    ),
    exported.cursor,
  );

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify({
        schema_version: "1.0",
        channel_id: channelId,
        source_session_ref: sourceThreadId,
        objective: currentState.task.objective,
        summary: currentState.task.summary,
        messages: [{
          id: "mock-agent-result-001",
          role: "agent",
          text: turn.structuredOutput.turn_summary,
          created_at: "2026-11-17T00:00:02.000Z",
        }],
      }),
    },
  );
  assert.equal(response.status, 200);
  const imported = await response.json();
  assert.equal(imported.imported_count, 1);
  assert.equal(imported.shared_task_phase, "source_result_synced");
  const timelineAfterResult = imported.cursor;

  response = await fetch(
    `${enabledServer.baseUrl}/api/task/sync/import`,
    {
      method: "POST",
      headers: sourceHeaders(
        enabledServer,
        sourceThreadId,
        { json: true },
      ),
      body: JSON.stringify(
        agentImportBody(
          channelId,
          sourceThreadId,
          "double-import-agent-result",
        ),
      ),
    },
  );
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "phase_conflict");

  response = await fetch(`${enabledServer.baseUrl}/api/state`, {
    headers: panelHeaders(enabledServer),
  });
  currentState = await response.json();
  assert.equal(
    currentState.task.shared_task.phase,
    "source_result_synced",
  );
  assert.ok(
    currentState.task.timeline.some(
      (entry) =>
        entry.external_id === "mock-agent-result-001" &&
        entry.text === turn.structuredOutput.turn_summary,
    ),
  );
  assert.equal(currentState.panel, null);
  assert.equal(currentState.last_turn, null);
  assert.equal(
    currentState.task.timeline.reduce(
      (max, entry) =>
        Number.isInteger(entry.seq) ? Math.max(max, entry.seq) : max,
      0,
    ),
    timelineAfterResult,
  );
  assert.equal(phaseAtPulled, "source_agent_pulled");

  const secondThreadId = "01a1e2d0-0000-7000-8000-000000000102";
  const secondSigned = signHandoffToken(
    packet("task-source-hosted-e2e-002", secondThreadId),
    enabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${enabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(secondSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 409);
  assert.equal(
    (await response.json()).code,
    "thread_rebinding_forbidden",
  );

  disabledServer = await startServer({ entryEnabled: false });
  const disabledSigned = signHandoffToken(
    packet(
      "task-source-hosted-disabled-001",
      "01a1e2d0-0000-7000-8000-000000000103",
    ),
    disabledServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${disabledServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(disabledSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 404);
  response = await fetch(`${disabledServer.baseUrl}/api/state`, {
    headers: authHeaders(disabledServer),
  });
  const disabledState = await response.json();
  assert.equal(disabledState.task.shared_task, null);
  response = await fetch(`${disabledServer.baseUrl}/api/state`, {
    headers: {
      Authorization: `Bearer ${disabledServer.sourceToken}`,
    },
  });
  assert.equal(response.status, 403);
  assert.equal(
    (await response.json()).code,
    "panel_capability_required",
  );
  response = await fetch(`${disabledServer.baseUrl}/api/task/sync/import`, {
    method: "POST",
    headers: {
      Cookie: `panel_token=${encodeURIComponent(disabledServer.panelToken)}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(agentImportBody(
      "chat:normal:sync",
      "normal-source-session",
      "normal-panel-import",
    )),
  });
  assert.equal(response.status, 403);
  assert.equal(
    (await response.json()).code,
    "source_capability_required",
  );

  recoveryServer = await startServer({ entryEnabled: true });
  const recoveryRuntimeDir = recoveryServer.runtimeDir;
  const recoveryWorkspace = recoveryServer.workspace;
  const recoveryThreadId =
    "01a1e2d0-0000-7000-8000-000000000104";
  const recoveryTaskId = "task-source-hosted-recovery-001";
  const recoverySigned = signHandoffToken(
    packet(recoveryTaskId, recoveryThreadId),
    recoveryServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${recoveryServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(recoverySigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 303);
  response = await fetch(`${recoveryServer.baseUrl}/api/task/recover`, {
    method: "POST",
    headers: panelHeaders(recoveryServer, { json: true }),
    body: JSON.stringify({ confirm: "recover_current_task" }),
  });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "recovery_not_required");

  await recoveryServer.close({ removeData: false });
  recoveryServer = null;
  const recoveryStatePath = join(recoveryRuntimeDir, "state.json");
  const recoveryState = JSON.parse(
    (await readFile(recoveryStatePath, "utf8")).replace(/^\uFEFF/u, ""),
  );
  recoveryState.phase = "error";
  recoveryState.error =
    "A source-external preview cannot create a panel-owned model Turn.";
  recoveryState.activity = {
    status: "error",
    user_summary: "受控 CSV 分析",
    submitted_at: new Date().toISOString(),
    started_at: new Date().toISOString(),
    completed_at: new Date().toISOString(),
    agent_summary: "",
    next_action: "",
    error: recoveryState.error,
    turn_id: null,
  };
  recoveryState.task.phase = "error";
  const duplicateHash =
    "8a7c1047d407a6aeae517a268261d59451d826a6c5beff2029da662fadd7fab6";
  recoveryState.task.attachments = [1, 2, 3].map((index) => ({
    id: `attachment-00000000-0000-4000-8000-00000000000${index}`,
    source_attachment_id: index === 1
      ? `chat-file:${duplicateHash}`
      : null,
    original_name: index === 2
      ? "gpu-stutter-copy.csv"
      : "gpu-stutter.csv",
    mime_type: "text/csv",
    size: 461,
    sha256: duplicateHash,
    added_at: new Date().toISOString(),
    local_path: null,
    preview: "Date,Time\n2026-11-17,20:00:00\n",
  }));
  recoveryState.task.domain_refs = recoveryState.task.attachments
    .map((attachment) => attachment.id);
  await writeFile(
    recoveryStatePath,
    `${JSON.stringify(recoveryState, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  recoveryServer = await startServer({
    entryEnabled: true,
    runtimeDir: recoveryRuntimeDir,
    workspace: recoveryWorkspace,
    nonMock: true,
  });
  const reopenErrorSigned = signHandoffToken(
    packet(recoveryTaskId, recoveryThreadId),
    recoveryServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${recoveryServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(reopenErrorSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 303);
  response = await fetch(`${recoveryServer.baseUrl}/api/state`, {
    headers: panelHeaders(recoveryServer),
  });
  const reopenedErrorState = await response.json();
  assert.equal(reopenedErrorState.phase, "error");
  assert.equal(reopenedErrorState.task.phase, "error");
  assert.ok(reopenedErrorState.error);
  response = await fetch(`${recoveryServer.baseUrl}/api/task/recover`, {
    method: "POST",
    headers: panelHeaders(recoveryServer, { json: true }),
    body: JSON.stringify({ confirm: "recover_current_task" }),
  });
  assert.equal(response.status, 200);
  const recovered = await response.json();
  assert.equal(recovered.recovered, true);
  assert.equal(recovered.task.task_id, recoveryTaskId);
  assert.equal(recovered.task.shared_task.phase, "source_owned");
  assert.equal(recovered.task.shared_task.environment_thread_id, recoveryThreadId);
  assert.equal(recovered.task.attachments.length, 1);
  assert.equal(recovered.task.attachments[0].sha256, duplicateHash);
  assert.equal(recovered.deduplicated_attachment_count, 2);
  const archivedState = JSON.parse(
    (
      await readFile(
        join(recoveryRuntimeDir, "tasks", `${recoveryTaskId}.json`),
        "utf8",
      )
    ).replace(/^\uFEFF/u, ""),
  );
  assert.equal(archivedState.task.attachments.length, 3);
  response = await fetch(`${recoveryServer.baseUrl}/api/task/recover`, {
    method: "POST",
    headers: panelHeaders(recoveryServer, { json: true }),
    body: JSON.stringify({ confirm: "recover_current_task" }),
  });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).code, "recovery_not_required");

  await recoveryServer.close({ removeData: false });
  recoveryServer = null;
  const stuckState = JSON.parse(
    (await readFile(recoveryStatePath, "utf8")).replace(/^\uFEFF/u, ""),
  );
  const stuckAttachmentCount = stuckState.task.attachments.length;
  const stuckTimelineCount = stuckState.task.timeline.length;
  stuckState.phase = "ready";
  stuckState.task.phase = "ready";
  stuckState.task.shared_task.phase = "source_agent_pulled";
  stuckState.task.shared_task.last_intent_id = "stuck-intent-001";
  stuckState.task.shared_task.source_tool_result = {
    schema_version: "1.0",
    packet: {
      created_at: "2026-11-17T10:00:00.000Z",
      attachment_id: "attachment-old-cycle",
      tool_result: {
        attachment: {
          id: "attachment-old-cycle",
          sha256: "a".repeat(64),
        },
        artifact: {
          id: "artifact-old-cycle",
          source_evidence_ids: ["attachment-old-cycle"],
        },
      },
    },
    result: {
      attachment: {
        id: "attachment-old-cycle",
        original_name: "old-cycle.csv",
      },
    },
    received_at: "2026-11-17T10:00:00.000Z",
  };
  stuckState.task.artifacts = [
    {
      id: "artifact-old-cycle",
      kind: "chart",
      sha256: "b".repeat(64),
      created_at: "2026-11-17T10:00:00.000Z",
    },
  ];
  stuckState.draft = {
    events: [],
    attachments: [
      {
        id: "attachment-draft-cycle",
        original_name: "draft-cycle.csv",
        mime_type: "text/csv",
        size: 12,
        sha256: "c".repeat(64),
        local_path: null,
        preview: "Date,Time\n",
      },
    ],
  };
  await writeFile(
    recoveryStatePath,
    `${JSON.stringify(stuckState, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  recoveryServer = await startServer({
    entryEnabled: true,
    runtimeDir: recoveryRuntimeDir,
    workspace: recoveryWorkspace,
    nonMock: true,
  });
  const stuckSigned = signHandoffToken(
    packet(recoveryTaskId, recoveryThreadId),
    recoveryServer.handoffSecret,
    { ttlSeconds: 120 },
  );
  response = await fetch(
    `${recoveryServer.baseUrl}/source-hosted/open?token=${
      encodeURIComponent(stuckSigned.token)
    }`,
    { redirect: "manual" },
  );
  assert.equal(response.status, 303);

  response = await fetch(`${recoveryServer.baseUrl}/api/task/recover`, {
    method: "POST",
    headers: panelHeaders(recoveryServer, { json: true }),
    body: JSON.stringify({ confirm: "wrong" }),
  });
  assert.equal(response.status, 403);
  assert.equal((await response.json()).code, "confirmation_required");
  response = await fetch(`${recoveryServer.baseUrl}/api/state`, {
    headers: panelHeaders(recoveryServer),
  });
  const unchangedStuckState = await response.json();
  assert.equal(
    unchangedStuckState.task.shared_task.phase,
    "source_agent_pulled",
  );
  assert.equal(unchangedStuckState.draft.attachments.length, 1);
  assert.equal(
    unchangedStuckState.task.attachments.length,
    stuckAttachmentCount,
  );

  response = await fetch(`${recoveryServer.baseUrl}/api/task/recover`, {
    method: "POST",
    headers: panelHeaders(recoveryServer, { json: true }),
    body: JSON.stringify({ confirm: "recover_current_task" }),
  });
  assert.equal(response.status, 200);
  const stuckRecovered = await response.json();
  assert.equal(stuckRecovered.recovered, true);
  assert.equal(stuckRecovered.recovery_kind, "stuck_cycle");
  assert.equal(stuckRecovered.task.task_id, recoveryTaskId);
  assert.equal(stuckRecovered.task.shared_task.phase, "source_owned");
  assert.equal(stuckRecovered.task.shared_task.cycle_generation, 1);
  assert.equal(
    stuckRecovered.task.shared_task.cycle_recovery.previous_phase,
    "source_agent_pulled",
  );
  assert.equal(
    stuckRecovered.task.shared_task.cycle_recovery.previous_intent_id,
    "stuck-intent-001",
  );
  assert.equal(stuckRecovered.task.attachments.length, stuckAttachmentCount);
  assert.equal(stuckRecovered.task.timeline.length, stuckTimelineCount);
  assert.equal(stuckRecovered.task.artifacts.length, 1);
  const recoveredRawState = JSON.parse(
    (await readFile(recoveryStatePath, "utf8")).replace(/^\uFEFF/u, ""),
  );
  assert.equal(
    recoveredRawState.task.shared_task.source_tool_result.received_at,
    "2026-11-17T10:00:00.000Z",
  );
  assert.equal(stuckRecovered.draft.attachments.length, 0);
  assert.ok(stuckRecovered.cycle_archive_ref);
  assert.equal(stuckRecovered.archived_draft_attachment_count, 1);
  const cycleArchive = JSON.parse(
    (
      await readFile(
        join(
          recoveryRuntimeDir,
          "tasks",
          stuckRecovered.cycle_archive_ref,
        ),
        "utf8",
      )
    ).replace(/^\uFEFF/u, ""),
  );
  assert.equal(cycleArchive.draft.attachments.length, 1);
  assert.equal(cycleArchive.task.attachments.length, stuckAttachmentCount);
  assert.equal(
    cycleArchive.task.shared_task.phase,
    "source_agent_pulled",
  );

  response = await fetch(`${recoveryServer.baseUrl}/api/submit`, {
    method: "POST",
    headers: panelHeaders(recoveryServer, { json: true }),
    body: JSON.stringify({
      free_text: "开始恢复后的新分析周期。",
    }),
  });
  assert.equal(response.status, 200);
  const newCycle = await response.json();
  assert.equal(newCycle.task.task_id, recoveryTaskId);
  assert.equal(
    newCycle.task.shared_task.phase,
    "waiting_for_source_pull",
  );
  assert.equal(newCycle.task.attachments.length, stuckAttachmentCount);

  console.log("source_hosted single-Task mock end-to-end loop: PASS");
} finally {
  await enabledServer?.close().catch(() => {});
  await disabledServer?.close().catch(() => {});
  await recoveryServer?.close().catch(() => {});
}
