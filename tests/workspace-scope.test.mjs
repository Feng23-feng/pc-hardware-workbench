import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const runtimeDir = await mkdtemp(join(tmpdir(), "skilldock-workspace-runtime-"));
const workspaceA = await mkdtemp(join(tmpdir(), "skilldock-workspace-a-"));
const workspaceB = await mkdtemp(join(tmpdir(), "skilldock-workspace-b-"));

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

async function startServer(workspace) {
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
      throw new Error(`workspace test server exited: ${stderr}`);
    }
    try {
      const health = await fetch(`http://127.0.0.1:${port}/api/health`);
      if (health.ok) {
        return { child, port };
      }
    } catch {
      // Listener is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  child.kill();
  throw new Error(`workspace test server was not ready: ${stderr}`);
}

async function tokenHeaders() {
  const token = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  return {
    Authorization: `Bearer ${token}`,
  };
}

async function state(port) {
  return fetch(`http://127.0.0.1:${port}/api/state`, {
    headers: await tokenHeaders(),
  }).then((response) => response.json());
}

async function stopServer(server) {
  await fetch(`http://127.0.0.1:${server.port}/api/shutdown`, {
    method: "POST",
    headers: {
      ...(await tokenHeaders()),
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

let first;
let second;
try {
  first = await startServer(workspaceA);
  const firstState = await state(first.port);
  assert.equal(firstState.agent.workspace, workspaceA);
  assert.ok(firstState.session_ref);
  const firstSession = firstState.session_ref;

  const submitted = await fetch(
    `http://127.0.0.1:${first.port}/api/submit`,
    {
      method: "POST",
      headers: {
        ...(await tokenHeaders()),
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        free_text: "Create one task before switching workspace.",
      }),
    },
  );
  assert.equal(submitted.ok, true);
  await stopServer(first);
  first = null;

  second = await startServer(workspaceB);
  const secondState = await state(second.port);
  assert.equal(secondState.agent.workspace, workspaceB);
  assert.notEqual(secondState.session_ref, firstSession);
  assert.equal(secondState.task, null);
  assert.equal(secondState.panel, null);
  console.log("Agent workspace isolation: PASS");
} finally {
  if (first) await stopServer(first).catch(() => {});
  if (second) await stopServer(second).catch(() => {});
  await rm(runtimeDir, { recursive: true, force: true });
  await rm(workspaceA, { recursive: true, force: true });
  await rm(workspaceB, { recursive: true, force: true });
}
