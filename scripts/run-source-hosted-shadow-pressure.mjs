import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdtemp,
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  createTempSqliteFixture,
} from "../contracts/source-hosted-shared-task/v1/persistence/fixture.mjs";
import {
  startIsolatedHttpServer,
} from "../contracts/source-hosted-shared-task/v1/persistence/http-server.mjs";
import {
  startIsolatedSkillDockProxy,
} from "../contracts/source-hosted-shared-task/v1/persistence/same-origin-proxy.mjs";

const root = resolve(import.meta.dirname, "..");
function integerSetting(name, fallback, minimum, maximum) {
  const value = Number(process.env[name] ?? fallback);
  if (
    !Number.isInteger(value) ||
    value < minimum ||
    value > maximum
  ) {
    throw new Error(
      `${name} must be an integer from ${minimum} to ${maximum}`,
    );
  }
  return value;
}
const pressureConfig = {
  servers: integerSetting("SHADOW_PRESSURE_SERVERS", 4, 1, 12),
  rounds: integerSetting("SHADOW_PRESSURE_ROUNDS", 10, 1, 50),
  proxyTasks: integerSetting("SHADOW_PRESSURE_PROXY_TASKS", 4, 1, 12),
  proxyRequestsPerTask: integerSetting(
    "SHADOW_PRESSURE_REQUESTS_PER_TASK",
    40,
    1,
    48,
  ),
  proxyConcurrency: integerSetting(
    "SHADOW_PRESSURE_PROXY_CONCURRENCY",
    128,
    1,
    256,
  ),
  rssLimitMb: integerSetting("SHADOW_PRESSURE_RSS_LIMIT_MB", 128, 32, 1024),
};
const runId = new Date().toISOString().replaceAll(":", "-");
const runDir = join(
  root,
  "work",
  "source-hosted-shadow-pressure-2026-11-16",
  runId,
);
let currentStage = "initializing";
const startedAt = new Date();
const rssBefore = process.memoryUsage().rss;
const fixtureDirsBefore = new Set(
  (await readdir(tmpdir(), { withFileTypes: true }))
    .filter(
      (entry) =>
        entry.isDirectory() &&
        entry.name.startsWith("skilldock-sqlite-fixture-"),
    )
    .map((entry) => entry.name),
);

await mkdir(runDir, { recursive: true });

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

async function tempDir(prefix) {
  return mkdtemp(join(tmpdir(), prefix));
}

async function waitForEvidence(evidenceDir, predicate, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const text = await readFile(join(evidenceDir, "latest.json"), "utf8");
      const evidence = JSON.parse(text);
      if (predicate(evidence)) {
        return {
          evidence,
          sha256: createHash("sha256").update(text, "utf8").digest("hex"),
        };
      }
    } catch {
      // Shadow evidence is written after the formal response.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  throw new Error("pressure evidence timeout");
}

async function startFormalServer(index) {
  const port = await freePort();
  const runtimeDir = await tempDir(`skilldock-pressure-runtime-${index}-`);
  const workspace = await tempDir(`skilldock-pressure-workspace-${index}-`);
  const evidenceDir = join(runDir, `server-${index}`, "evidence");
  await mkdir(evidenceDir, { recursive: true });
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
      PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 16_384) stderr += chunk.toString();
  });
  const baseUrl = `http://127.0.0.1:${port}`;
  for (let attempt = 0; attempt < 150; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`formal server ${index} exited: ${stderr}`);
    }
    try {
      const response = await fetch(`${baseUrl}/api/health`);
      if (response.ok) {
        const token = (
          await readFile(join(runtimeDir, "capability-token"), "utf8")
        ).trim();
        return {
          index,
          port,
          runtimeDir,
          workspace,
          evidenceDir,
          child,
          token,
          baseUrl,
          get stderr() {
            return stderr;
          },
          async close() {
            if (child.exitCode === null) {
              await fetch(`${baseUrl}/api/shutdown`, {
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
      // Wait for server readiness.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
  }
  child.kill();
  await rm(runtimeDir, { recursive: true, force: true });
  await rm(workspace, { recursive: true, force: true });
  throw new Error(`formal server ${index} readiness timeout: ${stderr}`);
}

async function runFormalPressure(server) {
  const rounds = pressureConfig.rounds;
  const messages = [];
  const evidence = [];
  const channelId = `chat:shadow-pressure:${server.index}`;
  for (let round = 1; round <= rounds; round += 1) {
    messages.push({
      id: `pressure-${server.index}-message-${String(round).padStart(2, "0")}`,
      role: round % 2 === 0 ? "agent" : "user",
      text: `Synthetic pressure server ${server.index} message ${round}.`,
      created_at: new Date(
        Date.parse("2026-11-16T00:00:00.000Z") + round * 1000,
      ).toISOString(),
    });
    const response = await fetch(`${server.baseUrl}/api/task/sync/import`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${server.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        schema_version: "1.0",
        channel_id: channelId,
        source_session_ref: `source-pressure-${server.index}`,
        objective: `Pressure Task ${server.index}`,
        summary: "Controlled shadow pressure.",
        messages,
      }),
    }).catch((error) => {
      throw Object.assign(
        new Error(
          `formal server ${server.index} round ${round} fetch failed`,
        ),
        {
          code: "formal_pressure_fetch_failed",
          details: {
            server: server.index,
            round,
            cause: String(error?.cause?.code ?? error?.code ?? error),
            address: error?.cause?.address ?? null,
            port: error?.cause?.port ?? null,
          },
        },
      );
    });
    if (!response.ok) {
      throw new Error(`server ${server.index} import ${round}: ${response.status}`);
    }
    await response.json();
    const observed = await waitForEvidence(
      server.evidenceDir,
      (value) =>
        value.status === "match" &&
        value.formal?.message_count === messages.length,
    );
    if (
      observed.evidence.profile?.identity_match !== true ||
      observed.evidence.formal_response_unchanged !== true
    ) {
      throw new Error(`server ${server.index} observation ${round} invalid`);
    }
    evidence.push({
      round,
      message_count: messages.length,
      sha256: observed.sha256,
    });
  }
  return {
    index: server.index,
    rounds,
    evidence_count: evidence.length,
    final_message_count: messages.length,
    final_evidence_sha256: evidence.at(-1).sha256,
    stderr_sanitized:
      !server.stderr.includes(server.token) &&
      !server.stderr.includes("Synthetic pressure") &&
      !/[A-Za-z]:[\\/]/u.test(server.stderr),
  };
}

async function runProxyPressure() {
  const fixture = createTempSqliteFixture();
  const tasks = [fixture.bootstrap];
  for (let index = 1; index < pressureConfig.proxyTasks; index += 1) {
    tasks.push(fixture.coordinator.bootstrapFixture({
      taskId: `task-pressure-proxy-${index}`,
      workspaceId: `workspace-pressure-proxy-${index}`,
      channelId: `chat:pressure-proxy:${index}`,
      objective: `Proxy pressure Task ${index}`,
    }));
  }
  const sessions = new Map();
  for (let index = 0; index < tasks.length; index += 1) {
    sessions.set(`pressure-session-${index}`, {
      taskId: tasks[index].task_id,
      mailboxToken: tasks[index].tokens.panel,
      controlToken: tasks[index].tokens.control,
    });
  }
  let coordinator;
  let proxy;
  try {
    coordinator = await startIsolatedHttpServer({ dbPath: fixture.dbPath });
    proxy = await startIsolatedSkillDockProxy({
      coordinatorBaseUrl: coordinator.baseUrl,
      sessions,
    });
    const requests = [];
    for (let index = 0; index < tasks.length; index += 1) {
      for (
        let requestIndex = 0;
        requestIndex < pressureConfig.proxyRequestsPerTask;
        requestIndex += 1
      ) {
        requests.push({
          taskIndex: index,
          requestIndex,
        });
      }
    }
    const responses = new Array(requests.length);
    let nextRequest = 0;
    async function runRequestWorker() {
      while (nextRequest < requests.length) {
        const requestIndex = nextRequest;
        nextRequest += 1;
        const request = requests[requestIndex];
        const task = tasks[request.taskIndex];
        let response;
        try {
          response = await fetch(
            `${proxy.baseUrl}/api/source-hosted/mailbox/snapshot`,
            {
              method: "POST",
              headers: {
                Origin: proxy.baseUrl,
                Cookie:
                  `skilldock_session=pressure-session-${request.taskIndex}`,
                "Content-Type": "application/json; charset=utf-8",
              },
              body: JSON.stringify({
                schema_version: "1.0",
                request_id:
                  `request-pressure-proxy-${request.taskIndex}-${request.requestIndex}`,
                include: [
                  "task",
                  "execution",
                  "delivery_ack_state",
                  "pending_counts",
                ],
                checkpoint: false,
              }),
            },
          );
        } catch (error) {
          throw Object.assign(
            new Error(
              `proxy fetch failed for Task ${request.taskIndex} request ${request.requestIndex}`,
            ),
            {
              code: "proxy_pressure_fetch_failed",
              details: {
                task: request.taskIndex,
                request: request.requestIndex,
                cause: String(error?.cause?.code ?? error?.code ?? error),
                address: error?.cause?.address ?? null,
                port: error?.cause?.port ?? null,
              },
            },
          );
        }
        const value = await response.json();
        responses[requestIndex] = {
          status: response.status,
          ok: value.ok,
          taskId: value.task_id,
          expectedTaskId: task.task_id,
        };
      }
    }
    await Promise.all(
      Array.from(
        {
          length: Math.min(
            pressureConfig.proxyConcurrency,
            requests.length,
          ),
        },
        () => runRequestWorker(),
      ),
    );
    const failed = responses.filter(
      (item) =>
        item.status !== 200 ||
        item.ok !== true ||
        item.taskId !== item.expectedTaskId,
    );
    return {
      task_count: tasks.length,
      request_count: responses.length,
      failed_count: failed.length,
      per_task_requests: pressureConfig.proxyRequestsPerTask,
      max_concurrency: pressureConfig.proxyConcurrency,
    };
  } finally {
    await proxy?.close().catch(() => {});
    await coordinator?.close().catch(() => {});
    fixture.cleanup();
  }
}

const servers = [];
let failure = null;
let summary = null;
const serverResults = [];
let proxyResult = null;
try {
  currentStage = "starting_formal_servers";
  for (let index = 0; index < pressureConfig.servers; index += 1) {
    servers.push(await startFormalServer(index));
  }
  currentStage = "formal_pressure";
  const formalResults = await Promise.all(
    servers.map((server) => runFormalPressure(server)),
  );
  serverResults.push(...formalResults);
  currentStage = "closing_formal_servers";
  for (const server of servers) await server.close();
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 500));

  currentStage = "proxy_pressure";
  proxyResult = await runProxyPressure();
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 500));

  currentStage = "resource_check";
  const fixtureDirsAfter = new Set(
    (await readdir(tmpdir(), { withFileTypes: true }))
      .filter(
        (entry) =>
          entry.isDirectory() &&
          entry.name.startsWith("skilldock-sqlite-fixture-"),
      )
      .map((entry) => entry.name),
  );
  const leakedFixtureDirs = [...fixtureDirsAfter].filter(
    (name) => !fixtureDirsBefore.has(name),
  );
  const rssAfter = process.memoryUsage().rss;
  const rssGrowth = rssAfter - rssBefore;
  const completedAt = new Date();
  const checks = {
    formal_servers_match:
      serverResults.length === pressureConfig.servers &&
      serverResults.every(
        (item) =>
          item.rounds === pressureConfig.rounds &&
          item.evidence_count === pressureConfig.rounds &&
          item.stderr_sanitized === true,
      ),
    concurrent_shadow_tasks:
      new Set(serverResults.map((item) => item.index)).size ===
        pressureConfig.servers,
    proxy_pressure:
      proxyResult.failed_count === 0 &&
      proxyResult.request_count ===
        pressureConfig.proxyTasks *
          pressureConfig.proxyRequestsPerTask,
    fixture_cleanup: leakedFixtureDirs.length === 0,
    rss_growth_bounded:
      rssGrowth < pressureConfig.rssLimitMb * 1024 * 1024,
  };
  if (Object.values(checks).some((value) => value !== true)) {
    throw new Error(`pressure check failed: ${JSON.stringify(checks)}`);
  }
  summary = {
    schema_version: "1.0",
    pressure_id: runId,
    mode: "controlled-shadow-pressure",
    status: "passed",
    started_at: startedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    duration_ms: completedAt.getTime() - startedAt.getTime(),
    pressure_config: pressureConfig,
    formal_servers: pressureConfig.servers,
    formal_imports:
      pressureConfig.servers * pressureConfig.rounds,
    shadow_observations:
      pressureConfig.servers * pressureConfig.rounds,
    concurrent_shadow_tasks: pressureConfig.servers,
    proxy_tasks: proxyResult.task_count,
    proxy_requests: proxyResult.request_count,
    server_results: serverResults,
    proxy_result: proxyResult,
    resource_check: {
      fixture_dirs_before: fixtureDirsBefore.size,
      fixture_dirs_after: fixtureDirsAfter.size,
      leaked_fixture_dirs: leakedFixtureDirs.length,
      rss_before_bytes: rssBefore,
      rss_after_bytes: rssAfter,
      rss_growth_bytes: rssGrowth,
    },
    checks,
    default_traffic: false,
    formal_ui_launcher_used: false,
    real_codex_thread_used: false,
    coordinator_recovery_attempted: false,
  };
  await writeFile(
    join(runDir, "pressure-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    run_dir: runDir,
    checks,
    duration_ms: summary.duration_ms,
    formal_imports: summary.formal_imports,
    shadow_observations: summary.shadow_observations,
    proxy_requests: summary.proxy_requests,
    pressure_config: summary.pressure_config,
    resource_check: summary.resource_check,
  })}\n`);
} catch (error) {
  failure = error;
  summary = {
    schema_version: "1.0",
    pressure_id: runId,
    mode: "controlled-shadow-pressure",
    status: "failed",
    stage: currentStage,
    error: String(error?.message ?? error).slice(0, 300),
    error_code: String(error?.code ?? error?.name ?? "error"),
    error_details: error?.details ?? null,
    default_traffic: false,
    real_codex_thread_used: false,
  };
  await writeFile(
    join(runDir, "pressure-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  ).catch(() => {});
} finally {
  await Promise.all(
    servers
      .filter((server) => server.child.exitCode === null)
      .map((server) => server.close().catch(() => {})),
  );
}

if (failure) throw failure;
