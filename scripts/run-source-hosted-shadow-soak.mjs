import { createHash } from "node:crypto";
import {
  mkdir,
  readFile,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";
import {
  createSourceHostedShadowObserver,
} from "../lib/source-hosted-shadow.mjs";

const root = resolve(import.meta.dirname, "..");
const configuredDuration = Number(
  process.env.SHADOW_SOAK_DURATION_MS ?? 30_000,
);
if (
  !Number.isInteger(configuredDuration) ||
  configuredDuration < 10_000 ||
  configuredDuration > 120_000
) {
  throw new Error(
    "SHADOW_SOAK_DURATION_MS must be an integer from 10000 to 120000",
  );
}
const intervalMs = 2_000;
const runId = new Date().toISOString().replaceAll(":", "-");
const runDir = join(
  root,
  "work",
  "source-hosted-shadow-soak-2026-11-16",
  runId,
);
const evidenceDir = join(runDir, "evidence");
const startedAt = new Date();
const logs = [];
const children = new Map();
const evidenceRecords = [];
const taskStats = new Map();

await mkdir(evidenceDir, { recursive: true });

function message(taskKey, sequence) {
  return {
    external_id: `soak-${taskKey}-message-${String(sequence).padStart(3, "0")}`,
    role: sequence % 2 === 0 ? "agent" : "user",
    text: `Synthetic soak ${taskKey} message ${sequence}.`,
    created_at: new Date(
      Date.parse("2026-11-16T00:00:00.000Z") + sequence * 1000,
    ).toISOString(),
    seq: sequence,
  };
}

function createTask(taskKey, initialCount) {
  return {
    key: taskKey,
    formalTaskId: `task-shadow-soak-${taskKey}`,
    channelId: `chat:shadow-soak:${taskKey}`,
    sourceSessionRef: `source-shadow-soak-${taskKey}`,
    objective: `Shadow soak Task ${taskKey}`,
    messages: Array.from(
      { length: initialCount },
      (_, index) => message(taskKey, index + 1),
    ),
  };
}

const tasks = [
  createTask("a", 105),
  createTask("b", 3),
  createTask("c", 3),
  createTask("d", 3),
];
const tasksByKey = new Map(tasks.map((task) => [task.key, task]));

for (const task of tasks) {
  taskStats.set(task.key, {
    matches: 0,
    blocked: 0,
    published: 0,
    reused: 0,
  });
}

const observer = createSourceHostedShadowObserver({
  env: {
    PANEL_SOURCE_HOSTED_SHADOW: "shadow",
    PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
  },
  onCoordinatorReady(value) {
    children.set(value.formalTaskId, value.child);
  },
  log(entry) {
    logs.push(entry);
  },
  startupTimeoutMs: 5_000,
});

function observation(task) {
  return {
    formal_task_id: task.formalTaskId,
    channel_id: task.channelId,
    source_session_ref: task.sourceSessionRef,
    objective: task.objective,
    cursor: task.messages.length,
    messages: [...task.messages],
  };
}

async function readEvidence(result) {
  if (!result.evidence_file) return null;
  const filePath = join(evidenceDir, result.evidence_file);
  const text = await readFile(filePath, "utf8");
  return {
    path: result.evidence_file,
    sha256: createHash("sha256").update(text, "utf8").digest("hex"),
    value: JSON.parse(text),
  };
}

async function observeTask(task, phase, expected) {
  const result = await observer.observeSyncImport(observation(task));
  const evidence = await readEvidence(result);
  if (!evidence) {
    throw new Error(`${phase}: missing evidence`);
  }
  const stats = taskStats.get(task.key);
  if (result.status === "match") stats.matches += 1;
  if (result.status === "blocked") stats.blocked += 1;
  const published = evidence.value.shadow?.published_count ?? 0;
  const reused = evidence.value.shadow?.reused_count ?? 0;
  stats.published += published;
  stats.reused += reused;
  if (evidence.value.formal_response_unchanged !== true) {
    throw new Error(`${phase}: formal response changed`);
  }
  if (result.status === "match" && evidence.value.profile?.identity_match !== true) {
    throw new Error(`${phase}: profile identity not bound`);
  }
  if (result.status !== expected.status) {
    throw new Error(
      `${phase}: expected ${expected.status}, got ${result.status}`,
    );
  }
  if (
    expected.reason &&
    result.reason !== expected.reason
  ) {
    throw new Error(
      `${phase}: expected ${expected.reason}, got ${result.reason}`,
    );
  }
  if (
    expected.published !== undefined &&
    published !== expected.published
  ) {
    throw new Error(
      `${phase}: expected published ${expected.published}, got ${published}`,
    );
  }
  const record = {
    phase,
    task_key: task.key,
    task_hash: evidence.value.formal.task_hash,
    status: result.status,
    reason: result.reason ?? null,
    published_count: published,
    reused_count: reused,
    formal_message_count: evidence.value.formal.message_count,
    shadow_event_count: evidence.value.shadow?.event_count ?? null,
    identity_match: evidence.value.profile?.identity_match ?? null,
    coordinator_process: evidence.value.coordinator_process,
    evidence_file: evidence.path,
    evidence_sha256: evidence.sha256,
  };
  evidenceRecords.push(record);
  return { result, evidence: evidence.value, record };
}

async function terminateCoordinator(taskKey) {
  const task = tasksByKey.get(taskKey);
  const child = children.get(task.formalTaskId);
  if (!child) throw new Error(`No coordinator child for Task ${taskKey}`);
  child.kill();
  if (child.exitCode === null && child.signalCode === null) {
    await Promise.race([
      new Promise((resolvePromise) => {
        child.once("exit", resolvePromise);
      }),
      new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000)),
    ]);
  }
  if (child.exitCode === null && child.signalCode === null) {
    throw new Error(`Coordinator child for Task ${taskKey} did not exit`);
  }
}

const exitEvents = [];
const killRound = new Map([["b", 2], ["c", 4], ["d", 6]]);
const killed = new Set();
let currentRound = 0;
let failure = null;
let summary = null;

try {
  const initial = new Map();
  for (const task of tasks) {
    initial.set(
      task.key,
      await observeTask(task, `initial_${task.key}_match`, {
        status: "match",
        published: task.messages.length,
      }),
    );
  }
  const duplicate = new Map();
  for (const task of tasks) {
    duplicate.set(
      task.key,
      await observeTask(task, `duplicate_${task.key}_match`, {
        status: "match",
        published: 0,
      }),
    );
  }

  const deadline = Date.now() + configuredDuration;
  while (Date.now() < deadline) {
    currentRound += 1;
    const taskA = tasksByKey.get("a");
    taskA.messages.push(
      message("a", taskA.messages.length + 1),
    );
    await observeTask(taskA, `round_${currentRound}_a_match`, {
      status: "match",
      published: 1,
    });
    if (currentRound % 2 === 0) {
      await observeTask(taskA, `round_${currentRound}_a_duplicate`, {
        status: "match",
        published: 0,
      });
    }

    for (const taskKey of ["b", "c", "d"]) {
      const task = tasksByKey.get(taskKey);
      if (killed.has(taskKey)) continue;
      if (killRound.get(taskKey) === currentRound) {
        await terminateCoordinator(taskKey);
        killed.add(taskKey);
        const blocked = await observeTask(
          task,
          `round_${currentRound}_${taskKey}_exit_blocked`,
          {
            status: "blocked",
            reason: "shadow_coordinator_unavailable",
          },
        );
        exitEvents.push({
          task_key: taskKey,
          round: currentRound,
          evidence_file: blocked.record.evidence_file,
          evidence_sha256: blocked.record.evidence_sha256,
          coordinator_process: blocked.record.coordinator_process,
        });
      } else {
        await observeTask(task, `round_${currentRound}_${taskKey}_match`, {
          status: "match",
          published: 0,
        });
      }
    }
    await new Promise((resolvePromise) =>
      setTimeout(
        resolvePromise,
        Math.min(intervalMs, Math.max(0, deadline - Date.now())),
      ));
  }

  const finalHealthy = await observeTask(
    tasksByKey.get("a"),
    "final_healthy_duplicate",
    { status: "match", published: 0 },
  );
  const completedAt = new Date();
  const durationMs = completedAt.getTime() - startedAt.getTime();
  const serializedLogs = JSON.stringify(logs);
  const checks = {
    duration_target_met: durationMs >= configuredDuration,
    multi_task_initial_match: tasks.every(
      (task) => initial.get(task.key).result.status === "match",
    ),
    duplicate_initial_zero_republish: tasks.every(
      (task) => duplicate.get(task.key).evidence.shadow.published_count === 0,
    ),
    multi_batch_task_a:
      initial.get("a").evidence.shadow.published_count === 105,
    repeated_coordinator_exits:
      exitEvents.length === 3 &&
      exitEvents.every(
        (item) =>
          item.coordinator_process.started === true &&
          item.coordinator_process.available === false,
      ),
    healthy_task_final_match:
      finalHealthy.result.status === "match",
    profile_identity_bound: evidenceRecords
      .filter((item) => item.status === "match")
      .every((item) => item.identity_match === true),
    formal_response_unchanged: evidenceRecords.length > 0,
    sanitized_logs:
      logs.length > 0 &&
      !serializedLogs.includes("Synthetic soak") &&
      !/[A-Za-z]:[\\/]/u.test(serializedLogs),
  };
  if (Object.values(checks).some((value) => value !== true)) {
    throw new Error(`soak check failed: ${JSON.stringify(checks)}`);
  }

  const sanitizedLogText =
    `${logs.map((entry) => JSON.stringify(entry)).join("\n")}\n`;
  await writeFile(
    join(runDir, "sanitized-log.jsonl"),
    sanitizedLogText,
    { encoding: "utf8", mode: 0o600 },
  );
  summary = {
    schema_version: "1.0",
    soak_id: runId,
    mode: "controlled-shadow-soak",
    status: "passed",
    started_at: startedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    configured_duration_ms: configuredDuration,
    actual_duration_ms: durationMs,
    interval_ms: intervalMs,
    rounds: currentRound,
    task_count: tasks.length,
    observation_count: evidenceRecords.length,
    profile_id: "source-hosted-node24-node-sqlite-process-v1",
    default_traffic: false,
    formal_ui_launcher_used: false,
    real_codex_thread_used: false,
    coordinator_recovery_attempted: false,
    task_stats: Object.fromEntries(taskStats),
    initial_multi_batch_evidence: {
      evidence_file: initial.get("a").record.evidence_file,
      evidence_sha256: initial.get("a").record.evidence_sha256,
      published_count: initial.get("a").evidence.shadow.published_count,
    },
    final_healthy_evidence: {
      evidence_file: finalHealthy.record.evidence_file,
      evidence_sha256: finalHealthy.record.evidence_sha256,
    },
    coordinator_exits: exitEvents,
    checks,
    log_entry_count: logs.length,
    log_artifact: "sanitized-log.jsonl",
    latest_evidence: "evidence/latest.json",
  };
  await writeFile(
    join(runDir, "soak-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    run_dir: runDir,
    checks,
    duration_ms: durationMs,
    rounds: currentRound,
    observations: evidenceRecords.length,
    coordinator_exits: exitEvents,
  })}\n`);
} catch (error) {
  failure = error;
  const completedAt = new Date();
  summary = {
    schema_version: "1.0",
    soak_id: runId,
    mode: "controlled-shadow-soak",
    status: "failed",
    error: String(error?.code ?? error?.message ?? error).slice(0, 300),
    configured_duration_ms: configuredDuration,
    observed_duration_ms:
      completedAt.getTime() - startedAt.getTime(),
    rounds: currentRound,
    observation_count: evidenceRecords.length,
    exit_event_count: exitEvents.length,
    default_traffic: false,
    real_codex_thread_used: false,
  };
  await writeFile(
    join(runDir, "soak-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  ).catch(() => {});
} finally {
  await observer.close();
}

if (failure) throw failure;
