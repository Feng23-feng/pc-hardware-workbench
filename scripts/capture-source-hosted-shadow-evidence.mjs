import { spawn } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const outputRoot = resolve(
  process.argv[2] ??
    join(
      root,
      "work",
      "source-hosted-shadow-evidence-2026-11-16",
    ),
);
const runId = `${new Date().toISOString().replaceAll(":", "-")}-${
  randomUUID()
}`;
const runDir = join(outputRoot, runId);

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

async function waitForEvidence(deadlineMs = 20_000) {
  const deadline = Date.now() + deadlineMs;
  while (Date.now() < deadline) {
    try {
      return JSON.parse(
        await readFile(join(runDir, "latest.json"), "utf8"),
      );
    } catch {
      // The shadow observation is intentionally asynchronous.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  throw new Error("shadow evidence timed out");
}

await mkdir(runDir, { recursive: true });
const runtimeDir = await mkdtemp(join(tmpdir(), "skilldock-shadow-run-"));
const workspace = await mkdtemp(join(tmpdir(), "skilldock-shadow-work-"));
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
    PANEL_SOURCE_HOSTED_SHADOW: "shadow",
    PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: runDir,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let stderr = "";
child.stderr.on("data", (chunk) => {
  if (stderr.length < 16_384) stderr += chunk.toString();
});

const baseUrl = `http://127.0.0.1:${port}`;
let token = "";
try {
  let ready = false;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`formal server exited: ${stderr}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        ready = true;
        break;
      }
    } catch {
      // Wait for the formal server.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
  }
  if (!ready) throw new Error(`formal server timeout: ${stderr}`);
  token = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const response = await fetch(`${baseUrl}/api/task/sync/import`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      schema_version: "1.0",
      channel_id: "chat:shadow-evidence:main",
      source_session_ref: "source-shadow-evidence",
      objective: "Capture source_hosted shadow evidence",
      summary: "Mock-only shadow evidence run.",
      messages: [
        {
          id: "shadow-evidence-user-1",
          role: "user",
          text: "Synthetic shadow evidence user message.",
          created_at: "2026-11-16T00:00:00.000Z",
        },
        {
          id: "shadow-evidence-agent-1",
          role: "agent",
          text: "Synthetic shadow evidence agent message.",
          created_at: "2026-11-16T00:00:01.000Z",
        },
      ],
    }),
  });
  if (!response.ok) {
    throw new Error(`formal sync import failed ${response.status}`);
  }
  const formal = await response.json();
  const evidence = await waitForEvidence();
  if (
    evidence.status !== "match" ||
    evidence.formal_response_unchanged !== true
  ) {
    throw new Error(`shadow evidence failed: ${evidence.status}`);
  }
  const summary = {
    schema_version: "1.0",
    run_id: runId,
    formal_import: {
      ok: formal.ok,
      imported_count: formal.imported_count,
      skipped_count: formal.skipped_count,
      created_task: formal.created_task,
    },
    evidence: {
      status: evidence.status,
      formal_response_unchanged: evidence.formal_response_unchanged,
      profile_id: evidence.profile?.profile_id,
      profile_sha256: evidence.profile?.profile_sha256,
      profile_identity_match: evidence.profile?.identity_match,
      message_count: evidence.formal?.message_count,
      shadow_event_count: evidence.shadow?.event_count,
      isolated_coordinator_process:
        evidence.coordinator_process?.isolated,
    },
    evidence_file: "latest.json",
  };
  await writeFile(
    join(runDir, "run-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    run_dir: runDir,
    ...summary,
  })}\n`);
} finally {
  if (child.exitCode === null) {
    await fetch(`${baseUrl}/api/shutdown`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
      },
    }).catch(() => {});
    await Promise.race([
      new Promise((resolvePromise) => child.once("exit", resolvePromise)),
      new Promise((resolvePromise) => setTimeout(resolvePromise, 5_000)),
    ]);
  }
  if (child.exitCode === null) child.kill();
  await rm(runtimeDir, { recursive: true, force: true });
  await rm(workspace, { recursive: true, force: true });
}
