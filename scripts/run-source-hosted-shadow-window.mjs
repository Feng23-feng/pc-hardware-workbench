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
const runId = new Date().toISOString().replaceAll(":", "-");
const runDir = join(
  root,
  "work",
  "source-hosted-shadow-window-2026-11-16",
  runId,
);
const evidenceDir = join(runDir, "evidence");
const startedAt = new Date();
const logs = [];
const ready = { child: null };

await mkdir(evidenceDir, { recursive: true });

const observer = createSourceHostedShadowObserver({
  env: {
    PANEL_SOURCE_HOSTED_SHADOW: "shadow",
    PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR: evidenceDir,
  },
  onCoordinatorReady(value) {
    ready.child = value.child;
  },
  log(entry) {
    logs.push(entry);
  },
  startupTimeoutMs: 5_000,
});

function observation(messages) {
  return {
    formal_task_id: "task-controlled-shadow-window",
    channel_id: "chat:controlled-shadow-window",
    source_session_ref: "source-controlled-shadow-window",
    objective: "Controlled shadow observation window",
    cursor: messages.length,
    messages,
  };
}

async function evidenceFor(result) {
  if (!result.evidence_file) return null;
  const filePath = join(evidenceDir, result.evidence_file);
  const text = await readFile(filePath, "utf8");
  return {
    path: result.evidence_file,
    sha256: createHash("sha256").update(text, "utf8").digest("hex"),
    value: JSON.parse(text),
  };
}

async function phase(name, messages) {
  const result = await observer.observeSyncImport(observation(messages));
  const evidence = await evidenceFor(result);
  return {
    name,
    status: result.status,
    ok: result.ok === true,
    reason: result.reason ?? null,
    evidence_file: evidence?.path ?? null,
    evidence_sha256: evidence?.sha256 ?? null,
    formal_response_unchanged:
      evidence?.value.formal_response_unchanged ?? null,
    identity_match:
      evidence?.value.profile?.identity_match ?? null,
    coordinator_process:
      evidence?.value.coordinator_process ?? null,
    formal_message_count:
      evidence?.value.formal?.message_count ?? null,
    shadow_event_count:
      evidence?.value.shadow?.event_count ?? null,
    published_count:
      evidence?.value.shadow?.published_count ?? null,
    reused_count:
      evidence?.value.shadow?.reused_count ?? null,
  };
}

const firstMessages = [
  {
    external_id: "window-user-1",
    role: "user",
    text: "Controlled window user message one.",
    created_at: "2026-11-16T00:00:00.000Z",
    seq: 1,
  },
  {
    external_id: "window-agent-1",
    role: "agent",
    text: "Controlled window agent message one.",
    created_at: "2026-11-16T00:00:01.000Z",
    seq: 2,
  },
];
const incrementalMessages = [
  ...firstMessages,
  {
    external_id: "window-agent-2",
    role: "agent",
    text: "Controlled window agent message two.",
    created_at: "2026-11-16T00:00:02.000Z",
    seq: 3,
  },
];

const phases = [];
try {
  phases.push(await phase("initial_match", firstMessages));
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  phases.push(await phase("duplicate_match", firstMessages));
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  phases.push(await phase("incremental_match", incrementalMessages));

  if (!ready.child) {
    throw new Error("shadow coordinator child was not observed");
  }
  ready.child.kill();
  if (ready.child.exitCode === null && ready.child.signalCode === null) {
    await Promise.race([
      new Promise((resolvePromise) => {
        ready.child.once("exit", resolvePromise);
      }),
      new Promise((resolvePromise) => setTimeout(resolvePromise, 2_000)),
    ]);
  }
  if (
    ready.child.exitCode === null &&
    ready.child.signalCode === null
  ) {
    throw new Error("shadow coordinator child did not exit");
  }
  phases.push(await phase("coordinator_exit_blocked", incrementalMessages));

  const checks = {
    initial_match:
      phases[0].status === "match" &&
      phases[0].published_count === 2,
    duplicate_no_republish:
      phases[1].status === "match" &&
      phases[1].published_count === 0 &&
      phases[1].reused_count === 2,
    incremental_only_new_event:
      phases[2].status === "match" &&
      phases[2].published_count === 1 &&
      phases[2].reused_count === 2,
    coordinator_exit_blocked:
      phases[3].status === "blocked" &&
      phases[3].reason === "shadow_coordinator_unavailable" &&
      phases[3].coordinator_process?.available === false,
    profile_identity_bound: phases
      .slice(0, 3)
      .every((item) => item.identity_match === true),
    formal_response_unchanged: phases.every(
      (item) => item.formal_response_unchanged === true,
    ),
  };
  const serializedLogs = JSON.stringify(logs);
  checks.sanitized_logs =
    !serializedLogs.includes("Controlled window user message one.") &&
    !serializedLogs.includes("Controlled window agent message one.") &&
    !serializedLogs.includes("Controlled window agent message two.") &&
    !/[A-Za-z]:[\\/]/u.test(serializedLogs);
  if (Object.values(checks).some((value) => value !== true)) {
    throw new Error(`shadow window check failed: ${JSON.stringify(checks)}`);
  }
  const sanitizedLogText = logs.length
    ? `${logs.map((entry) => JSON.stringify(entry)).join("\n")}\n`
    : "";
  await writeFile(
    join(runDir, "sanitized-log.jsonl"),
    sanitizedLogText,
    { encoding: "utf8", mode: 0o600 },
  );

  const completedAt = new Date();
  const summary = {
    schema_version: "1.0",
    window_id: runId,
    mode: "controlled-shadow-observation",
    started_at: startedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    duration_ms: completedAt.getTime() - startedAt.getTime(),
    profile_id: "source-hosted-node24-node-sqlite-process-v1",
    default_traffic: false,
    formal_ui_launcher_used: false,
    real_codex_thread_used: false,
    phases,
    checks,
    log_entry_count: logs.length,
    log_artifact: "sanitized-log.jsonl",
    latest_evidence: "evidence/latest.json",
  };
  await writeFile(
    join(runDir, "window-summary.json"),
    `${JSON.stringify(summary, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  process.stdout.write(`${JSON.stringify({
    ok: true,
    run_dir: runDir,
    checks,
    phases: phases.map((item) => ({
      name: item.name,
      status: item.status,
      reason: item.reason,
      published_count: item.published_count,
      reused_count: item.reused_count,
      evidence_sha256: item.evidence_sha256,
    })),
  })}\n`);
} finally {
  await observer.close();
}
