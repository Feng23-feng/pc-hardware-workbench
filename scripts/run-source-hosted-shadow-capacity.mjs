import { createHash } from "node:crypto";
import {
  mkdir,
  readdir,
  writeFile,
} from "node:fs/promises";
import {
  arch,
  cpus,
  freemem,
  loadavg,
  platform,
  release,
  tmpdir,
  totalmem,
  uptime,
} from "node:os";
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
const runId = new Date().toISOString().replaceAll(":", "-");
const capacityRoot = resolve(
  process.env.SHADOW_CAPACITY_RUN_ROOT ??
    join(root, "work", "source-hosted-shadow-capacity-2026-11-17"),
);
const runDir = join(
  capacityRoot,
  runId,
);
function parseBurstLevels(value) {
  if (!value) return [64, 128, 160, 192, 224, 256, 320];
  const levels = String(value)
    .split(",")
    .map((item) => Number(item.trim()));
  if (
    levels.length === 0 ||
    levels.some(
      (item) =>
        !Number.isInteger(item) ||
        item < 1 ||
        item > 512,
    )
  ) {
    throw new Error(
      "SHADOW_CAPACITY_BURST_LEVELS must contain integers from 1 to 512",
    );
  }
  return [...new Set(levels)];
}
const burstLevels = parseBurstLevels(
  process.env.SHADOW_CAPACITY_BURST_LEVELS,
);
const taskCount = 8;
const sustainedDurationMs = Number(
  process.env.SHADOW_CAPACITY_DURATION_MS ?? 10_000,
);
const sustainedConcurrency = Number(
  process.env.SHADOW_CAPACITY_CONCURRENCY ?? 128,
);
if (
  !Number.isInteger(sustainedDurationMs) ||
  (sustainedDurationMs !== 0 && sustainedDurationMs < 5_000) ||
  sustainedDurationMs > 60_000
) {
  throw new Error(
    "SHADOW_CAPACITY_DURATION_MS must be 0 or an integer from 5000 to 60000",
  );
}
if (
  !Number.isInteger(sustainedConcurrency) ||
  sustainedConcurrency < 1 ||
  sustainedConcurrency > 256
) {
  throw new Error(
    "SHADOW_CAPACITY_CONCURRENCY must be an integer from 1 to 256",
  );
}

await mkdir(runDir, { recursive: true });
const startedAt = new Date();
const processCpuBefore = process.cpuUsage();

function machineState() {
  const memory = process.memoryUsage();
  return {
    timestamp: new Date().toISOString(),
    platform: platform(),
    release: release(),
    arch: arch(),
    logical_cpu_count: cpus().length,
    load_average: loadavg(),
    os_uptime_seconds: Math.round(uptime()),
    total_memory_bytes: totalmem(),
    free_memory_bytes: freemem(),
    process_rss_bytes: memory.rss,
    process_heap_used_bytes: memory.heapUsed,
    node_version: process.versions.node,
    sqlite_version: process.versions.sqlite,
  };
}
const machineBefore = machineState();
const fixtureDirsBefore = new Set(
  (await readdir(tmpdir(), { withFileTypes: true }))
    .filter(
      (entry) =>
        entry.isDirectory() &&
        entry.name.startsWith("skilldock-sqlite-fixture-"),
    )
    .map((entry) => entry.name),
);

function snapshotBody(taskIndex, requestIndex) {
  return {
    schema_version: "1.0",
    request_id:
      `request-capacity-${taskIndex}-${String(requestIndex).padStart(5, "0")}`,
    include: [
      "task",
      "execution",
      "delivery_ack_state",
      "pending_counts",
    ],
    checkpoint: false,
  };
}

function setupProxyFixture() {
  const fixture = createTempSqliteFixture();
  const tasks = [fixture.bootstrap];
  for (let index = 1; index < taskCount; index += 1) {
    tasks.push(fixture.coordinator.bootstrapFixture({
      taskId: `task-capacity-${index}`,
      workspaceId: `workspace-capacity-${index}`,
      channelId: `chat:capacity:${index}`,
      objective: `Capacity Task ${index}`,
    }));
  }
  const sessions = new Map();
  for (let index = 0; index < tasks.length; index += 1) {
    sessions.set(`capacity-session-${index}`, {
      taskId: tasks[index].task_id,
      mailboxToken: tasks[index].tokens.panel,
      controlToken: tasks[index].tokens.control,
    });
  }
  return { fixture, tasks, sessions };
}

async function closeProxySetup(setup, coordinator, proxy) {
  await proxy?.close().catch(() => {});
  await coordinator?.close().catch(() => {});
  setup.fixture.cleanup();
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
}

function newFixtureDirectories(before) {
  return readdir(tmpdir(), { withFileTypes: true }).then((entries) =>
    entries
      .filter(
        (entry) =>
          entry.isDirectory() &&
          entry.name.startsWith("skilldock-sqlite-fixture-") &&
          !before.has(entry.name),
      )
      .map((entry) => entry.name),
  );
}

async function requestSnapshot(proxy, taskIndex, requestIndex) {
  try {
    const response = await fetch(
      `${proxy.baseUrl}/api/source-hosted/mailbox/snapshot`,
      {
        method: "POST",
        headers: {
          Origin: proxy.baseUrl,
          Cookie: `skilldock_session=capacity-session-${taskIndex}`,
          "Content-Type": "application/json; charset=utf-8",
        },
        body: JSON.stringify(snapshotBody(taskIndex, requestIndex)),
      },
    );
    const value = await response.json();
    return {
      ok:
        response.status === 200 &&
        value.ok === true &&
        value.task_id === `task-${taskIndex === 0
          ? "sqlite-fixture-01"
          : `capacity-${taskIndex}`}`,
      status: response.status,
      error: value.ok === true
        ? null
        : String(value?.error?.code ?? "response_not_ok"),
    };
  } catch (error) {
    return {
      ok: false,
      status: null,
      error: String(error?.cause?.code ?? error?.code ?? error),
      address: error?.cause?.address ?? null,
      port: error?.cause?.port ?? null,
    };
  }
}

async function runBurst(level) {
  const setup = setupProxyFixture();
  const before = new Set(fixtureDirsBefore);
  let coordinator;
  let proxy;
  try {
    coordinator = await startIsolatedHttpServer({
      dbPath: setup.fixture.dbPath,
    });
    proxy = await startIsolatedSkillDockProxy({
      coordinatorBaseUrl: coordinator.baseUrl,
      sessions: setup.sessions,
    });
    const requests = Array.from({ length: level }, (_, index) => ({
      taskIndex: index % taskCount,
      requestIndex: Math.floor(index / taskCount),
    }));
    const started = Date.now();
    const results = await Promise.all(
      requests.map((request) =>
        requestSnapshot(proxy, request.taskIndex, request.requestIndex)),
    );
    const failures = results.filter((item) => item.ok !== true);
    await closeProxySetup(setup, coordinator, proxy);
    coordinator = null;
    proxy = null;
    const leaked = await newFixtureDirectories(before);
    return {
      level,
      request_count: results.length,
      success_count: results.length - failures.length,
      failure_count: failures.length,
      duration_ms: Date.now() - started,
      failures: failures.slice(0, 10),
      fixture_leak_count: leaked.length,
    };
  } finally {
    if (proxy || coordinator) {
      await closeProxySetup(setup, coordinator, proxy);
    }
  }
}

async function runSustained() {
  const setup = setupProxyFixture();
  const before = new Set(fixtureDirsBefore);
  let coordinator;
  let proxy;
  try {
    coordinator = await startIsolatedHttpServer({
      dbPath: setup.fixture.dbPath,
    });
    proxy = await startIsolatedSkillDockProxy({
      coordinatorBaseUrl: coordinator.baseUrl,
      sessions: setup.sessions,
    });
    const deadline = Date.now() + sustainedDurationMs;
    let nextRequest = 0;
    const failures = [];
    let completed = 0;
    let failureCount = 0;
    const started = Date.now();
    async function worker() {
      while (Date.now() < deadline) {
        const requestIndex = nextRequest;
        nextRequest += 1;
        const result = await requestSnapshot(
          proxy,
          requestIndex % taskCount,
          Math.floor(requestIndex / taskCount),
        );
        completed += 1;
        if (result.ok !== true) {
          failureCount += 1;
          if (failures.length < 20) failures.push(result);
        }
      }
    }
    await Promise.all(
      Array.from({ length: sustainedConcurrency }, () => worker()),
    );
    const durationMs = Date.now() - started;
    await closeProxySetup(setup, coordinator, proxy);
    coordinator = null;
    proxy = null;
    const leaked = await newFixtureDirectories(before);
    return {
      concurrency: sustainedConcurrency,
      duration_ms: durationMs,
      request_count: completed,
      failure_count: failureCount,
      failures,
      requests_per_second:
        Math.round((completed / durationMs) * 1000 * 100) / 100,
      fixture_leak_count: leaked.length,
    };
  } finally {
    if (proxy || coordinator) {
      await closeProxySetup(setup, coordinator, proxy);
    }
  }
}

const bursts = [];
let sustained;
let failure = null;
let summary;
try {
  for (const level of burstLevels) {
    bursts.push(await runBurst(level));
  }
  sustained = sustainedDurationMs === 0
    ? null
    : await runSustained();
  const leaked = await newFixtureDirectories(fixtureDirsBefore);
  const checks = {
    burst_levels_recorded: bursts.length === burstLevels.length,
    burst_results_recorded: bursts.every(
      (item) =>
        item.success_count + item.failure_count === item.request_count,
    ),
    sustained_pressure_completed:
      sustained === null ||
      (
        sustained.request_count > 0 &&
        sustained.duration_ms >= sustainedDurationMs
      ),
    no_fixture_leaks:
      leaked.length === 0 &&
      bursts.every((item) => item.fixture_leak_count === 0) &&
      (sustained === null || sustained.fixture_leak_count === 0),
  };
  if (Object.values(checks).some((value) => value !== true)) {
    throw new Error(`capacity check failed: ${JSON.stringify(checks)}`);
  }
  summary = {
    schema_version: "1.0",
    capacity_id: runId,
    mode: "controlled-shadow-capacity",
    status: "observed",
    started_at: startedAt.toISOString(),
    completed_at: new Date().toISOString(),
    machine_context: {
      before: machineBefore,
      after: machineState(),
      process_cpu_delta: process.cpuUsage(processCpuBefore),
    },
    task_count: taskCount,
    burst_levels: burstLevels,
    bursts,
    sustained,
    sustained_skipped: sustained === null,
    checks,
    default_traffic: false,
    formal_ui_launcher_used: false,
    real_codex_thread_used: false,
    coordinator_recovery_attempted: false,
  };
  await writeFile(
    join(runDir, "capacity-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    run_dir: runDir,
    checks,
    bursts: bursts.map((item) => ({
      level: item.level,
      success: item.success_count,
      failures: item.failure_count,
      first_error: item.failures[0] ?? null,
    })),
    sustained: sustained
      ? {
          concurrency: sustained.concurrency,
          duration_ms: sustained.duration_ms,
          request_count: sustained.request_count,
          failure_count: sustained.failure_count,
          requests_per_second: sustained.requests_per_second,
        }
      : null,
  })}\n`);
} catch (error) {
  failure = error;
  summary = {
    schema_version: "1.0",
    capacity_id: runId,
    mode: "controlled-shadow-capacity",
    status: "failed",
    error: String(error?.message ?? error).slice(0, 300),
    machine_context: {
      before: machineBefore,
      after: machineState(),
      process_cpu_delta: process.cpuUsage(processCpuBefore),
    },
    bursts,
    sustained: sustained ?? null,
    default_traffic: false,
    real_codex_thread_used: false,
  };
  await writeFile(
    join(runDir, "capacity-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  ).catch(() => {});
}

if (failure) throw failure;
