import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const runtimeDir = await mkdtemp(join(tmpdir(), "skilldock-sync-runtime-"));
const workspace = await mkdtemp(join(tmpdir(), "skilldock-sync-workspace-"));

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

async function startServer() {
  const port = await freePort();
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
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`task sync server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (response.ok) {
        return { child, port };
      }
    } catch {
      // Listener is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  child.kill();
  throw new Error(`task sync server was not ready: ${stderr}`);
}

let server;
let runtimeToken;
try {
  server = await startServer();
  runtimeToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const authHeaders = {
    Authorization: `Bearer ${runtimeToken}`,
    "Content-Type": "application/json",
  };
  const baseUrl = `http://127.0.0.1:${server.port}`;
  const channelId = "chat:test-session:task-one";
  const sourceSessionRef = "source-session-test";
  const importBody = {
    schema_version: "1.0",
    channel_id: channelId,
    source_session_ref: sourceSessionRef,
    objective: "确认面板与主对话共享同一个 Task",
    summary: "主对话已经确认问题发生在游戏中，下一步需要固定场景复测。",
    messages: [
      {
        id: "chat-message-user-1",
        role: "user",
        text: "玩游戏时会短暂卡顿。",
        created_at: "2026-11-16T00:00:00.000Z",
      },
      {
        id: "chat-message-agent-1",
        role: "agent",
        text: "先固定同一场景并记录精确时间。",
        created_at: "2026-11-16T00:00:01.000Z",
      },
    ],
  };

  let response = await fetch(`${baseUrl}/api/task/sync/import`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify(importBody),
  });
  assert.equal(response.status, 200);
  const firstImport = await response.json();
  assert.equal(firstImport.ok, true);
  assert.equal(firstImport.created_task, true);
  assert.equal(firstImport.imported_count, 2);
  assert.equal(firstImport.skipped_count, 0);
  assert.ok(firstImport.task_ref);

  response = await fetch(`${baseUrl}/api/task/sync/import`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify(importBody),
  });
  const repeatedImport = await response.json();
  assert.equal(repeatedImport.created_task, false);
  assert.equal(repeatedImport.imported_count, 0);
  assert.equal(repeatedImport.skipped_count, 2);
  assert.equal(repeatedImport.task_ref, firstImport.task_ref);

  response = await fetch(`${baseUrl}/api/submit`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({
      free_text: "面板里继续：已固定游戏场景，请给出下一条证据。",
    }),
  });
  assert.equal(response.status, 200);
  const submitted = await response.json();
  assert.ok(submitted.panel);
  assert.ok(
    submitted.task.timeline.some(
      (entry) => entry.source === "chat" && entry.external_id,
    ),
  );
  assert.ok(
    submitted.task.timeline.some((entry) => entry.source === "surface"),
  );

  response = await fetch(
    `${baseUrl}/api/task/sync/export?channel_id=${encodeURIComponent(channelId)}&after_seq=0`,
    { headers: authHeaders },
  );
  assert.equal(response.status, 200);
  const exported = await response.json();
  assert.equal(exported.task_ref, firstImport.task_ref);
  assert.equal(exported.channel_id, channelId);
  assert.equal(exported.source_session_ref, sourceSessionRef);
  assert.ok(exported.panel);
  assert.ok(exported.cursor >= firstImport.cursor);
  assert.ok(exported.messages.some((message) => message.source === "chat"));
  assert.ok(exported.messages.some((message) => message.source === "surface"));
  const serialized = JSON.stringify(exported);
  assert.equal(serialized.includes(runtimeToken), false);
  assert.equal(/[A-Za-z]:[\\/]/u.test(serialized), false);

  response = await fetch(
    `${baseUrl}/api/task/sync/export?channel_id=${encodeURIComponent(channelId)}&after_seq=${exported.cursor}`,
    { headers: authHeaders },
  );
  const afterCursor = await response.json();
  assert.deepEqual(afterCursor.messages, []);
  assert.equal(afterCursor.cursor, exported.cursor);

  response = await fetch(
    `${baseUrl}/api/task/sync/export?channel_id=chat%3Awrong%3Atask&after_seq=0`,
    { headers: authHeaders },
  );
  assert.equal(response.status, 409);

  const secondChannel = "chat:test-session:task-two";
  response = await fetch(`${baseUrl}/api/task/sync/import`, {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({
      schema_version: "1.0",
      channel_id: secondChannel,
      objective: "第二个独立 Task",
      summary: "这是另一个主对话任务。",
      messages: [
        {
          id: "chat-message-user-2",
          role: "user",
          text: "换一个问题继续。",
          created_at: "2026-11-16T00:01:00.000Z",
        },
      ],
    }),
  });
  const secondImport = await response.json();
  assert.equal(secondImport.created_task, true);
  assert.notEqual(secondImport.task_ref, firstImport.task_ref);

  response = await fetch(`${baseUrl}/api/state`, {
    headers: authHeaders,
  });
  const finalState = await response.json();
  assert.equal(finalState.task.sync.channel_id, secondChannel);
  assert.equal(
    finalState.task.timeline.filter((entry) => entry.source === "chat").length,
    1,
  );

  console.log("Task chat/panel sync: PASS");
} finally {
  if (server) {
    await fetch(`http://127.0.0.1:${server.port}/api/shutdown`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${runtimeToken ?? ""}`,
        "Content-Type": "application/json",
      },
      body: "{}",
    }).catch(() => {});
    await new Promise((resolvePromise) => {
      const timer = setTimeout(() => {
        server.child.kill();
        resolvePromise();
      }, 2_000);
      server.child.once("exit", () => {
        clearTimeout(timer);
        resolvePromise();
      });
    });
  }
  await rm(runtimeDir, { recursive: true, force: true });
  await rm(workspace, { recursive: true, force: true });
}
