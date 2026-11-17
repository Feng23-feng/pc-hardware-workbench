import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  readFile,
  readdir,
  writeFile,
} from "node:fs/promises";
import {
  arch,
  cpus,
  freemem,
  platform,
  release,
  tmpdir,
  totalmem,
} from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const capacityScript = join(
  root,
  "scripts",
  "run-source-hosted-shadow-capacity.mjs",
);
const boundaryLevels = [224, 232, 240, 248, 256, 320];
const expectedFailures = new Map([
  [224, 0],
  [232, 0],
  [240, 8],
  [248, 16],
  [256, 24],
  [320, 88],
]);
const seed = Number(process.env.SHADOW_CAPACITY_REPLAY_SEED ?? 20261117);
if (!Number.isInteger(seed) || seed <= 0) {
  throw new Error("SHADOW_CAPACITY_REPLAY_SEED must be a positive integer");
}
const runId = new Date().toISOString().replaceAll(":", "-");
const runDir = join(
  root,
  "work",
  "source-hosted-shadow-capacity-replay-2026-11-17",
  runId,
);
const childRoot = join(runDir, "children");
await mkdir(childRoot, { recursive: true });

function randomGenerator(value) {
  let state = value >>> 0;
  return () => {
    state += 0x6d2b79f5;
    let result = state;
    result = Math.imul(result ^ (result >>> 15), result | 1);
    result ^= result + Math.imul(result ^ (result >>> 7), result | 61);
    return ((result ^ (result >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffled(values) {
  const random = randomGenerator(seed);
  const output = [...values];
  for (let index = output.length - 1; index > 0; index -= 1) {
    const target = Math.floor(random() * (index + 1));
    [output[index], output[target]] = [output[target], output[index]];
  }
  return output;
}

function machineState() {
  return {
    timestamp: new Date().toISOString(),
    platform: platform(),
    release: release(),
    arch: arch(),
    logical_cpu_count: cpus().length,
    total_memory_bytes: totalmem(),
    free_memory_bytes: freemem(),
    node_version: process.versions.node,
    sqlite_version: process.versions.sqlite,
  };
}

async function fixtureDirectories() {
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

async function runChild(level, orderIndex) {
  const child = spawn(process.execPath, [capacityScript], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      SHADOW_CAPACITY_RUN_ROOT: childRoot,
      SHADOW_CAPACITY_BURST_LEVELS: String(level),
      SHADOW_CAPACITY_DURATION_MS: "0",
      SHADOW_CAPACITY_CONCURRENCY: "128",
      SHADOW_CAPACITY_REPLAY_ORDER_INDEX: String(orderIndex),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stdout = "";
  let stderr = "";
  child.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
  });
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const exitCode = await new Promise((resolvePromise, rejectPromise) => {
    child.once("error", rejectPromise);
    child.once("exit", resolvePromise);
  });
  const lines = stdout.split(/\r?\n/u).filter(Boolean);
  let output = null;
  try {
    output = lines.length ? JSON.parse(lines.at(-1)) : null;
  } catch {
    output = null;
  }
  if (exitCode !== 0 || output?.ok !== true) {
    return {
      level,
      order_index: orderIndex,
      status: "failed",
      exit_code: exitCode,
      error: String(stderr || output?.error || "capacity child failed").slice(
        0,
        300,
      ),
    };
  }
  const summaryPath = join(output.run_dir, "capacity-summary.json");
  const text = await readFile(summaryPath, "utf8");
  const summary = JSON.parse(text);
  const burst = summary.bursts?.[0];
  return {
    level,
    order_index: orderIndex,
    status: "observed",
    exit_code: exitCode,
    child_run: output.run_dir,
    summary_sha256:
      createHash("sha256").update(text, "utf8").digest("hex"),
    machine_context: summary.machine_context,
    request_count: burst?.request_count ?? null,
    success_count: burst?.success_count ?? null,
    failure_count: burst?.failure_count ?? null,
    failures: burst?.failures?.slice(0, 10) ?? [],
    fixture_leak_count: burst?.fixture_leak_count ?? null,
    sustained_skipped: summary.sustained_skipped === true,
  };
}

const order = shuffled(boundaryLevels);
const before = await fixtureDirectories();
const startedAt = new Date();
const machineBefore = machineState();
const results = [];
let failure = null;
try {
  for (let index = 0; index < order.length; index += 1) {
    results.push(await runChild(order[index], index));
  }
  const after = await fixtureDirectories();
  const leaked = [...after].filter((name) => !before.has(name));
  const checks = {
    independent_processes:
      results.length === boundaryLevels.length &&
      results.every((item) => item.status === "observed"),
    random_order_recorded:
      new Set(order).size === boundaryLevels.length &&
      results.every((item, index) => item.level === order[index]),
    exact_boundary_counts: results.every(
      (item) =>
        item.request_count === item.level &&
        item.success_count === Math.min(item.level, 232) &&
        item.failure_count === expectedFailures.get(item.level),
    ),
    sustained_explicitly_skipped: results.every(
      (item) => item.sustained_skipped === true,
    ),
    no_fixture_leaks:
      leaked.length === 0 &&
      results.every((item) => item.fixture_leak_count === 0),
    machine_context_recorded: results.every(
      (item) =>
        item.machine_context?.before?.platform &&
        item.machine_context?.after?.platform,
    ),
  };
  if (Object.values(checks).some((value) => value !== true)) {
    throw new Error(`capacity replay check failed: ${JSON.stringify(checks)}`);
  }
  const completedAt = new Date();
  const summary = {
    schema_version: "1.0",
    replay_id: runId,
    mode: "controlled-shadow-capacity-random-replay",
    status: "passed",
    seed,
    order,
    started_at: startedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    duration_ms: completedAt.getTime() - startedAt.getTime(),
    machine_before: machineBefore,
    machine_after: machineState(),
    results,
    checks,
    default_traffic: false,
    formal_ui_launcher_used: false,
    real_codex_thread_used: false,
    coordinator_recovery_attempted: false,
  };
  await writeFile(
    join(runDir, "replay-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    run_dir: runDir,
    seed,
    order,
    checks,
    results: results.map((item) => ({
      level: item.level,
      success_count: item.success_count,
      failure_count: item.failure_count,
      summary_sha256: item.summary_sha256,
    })),
  })}\n`);
} catch (error) {
  failure = error;
  const summary = {
    schema_version: "1.0",
    replay_id: runId,
    mode: "controlled-shadow-capacity-random-replay",
    status: "failed",
    seed,
    order,
    error: String(error?.message ?? error).slice(0, 300),
    machine_before: machineBefore,
    machine_after: machineState(),
    results,
    default_traffic: false,
    real_codex_thread_used: false,
  };
  await writeFile(
    join(runDir, "replay-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  ).catch(() => {});
}

if (failure) throw failure;
