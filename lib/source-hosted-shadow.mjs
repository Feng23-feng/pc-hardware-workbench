import { spawn } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { isAbsolute, join, resolve, sep } from "node:path";

const FLAG_NAME = "PANEL_SOURCE_HOSTED_SHADOW";
const EVIDENCE_DIR_NAME =
  "PANEL_SOURCE_HOSTED_SHADOW_EVIDENCE_DIR";
const SHADOW_TASK_PREFIX = "shadow-task-";
const SHADOW_PUBLISH_BATCH_SIZE = 50;
const FIXTURE_ROOT_PREFIX = "skilldock-sqlite-fixture-";
const SHUTDOWN_TIMEOUT = Symbol("shadow-shutdown-timeout");

function digest(value) {
  return createHash("sha256")
    .update(typeof value === "string" ? value : JSON.stringify(value), "utf8")
    .digest("hex");
}

function redactedId(value) {
  return digest(String(value ?? ""));
}

function shadowTaskId(formalTaskId) {
  return `${SHADOW_TASK_PREFIX}${redactedId(formalTaskId).slice(0, 40)}`;
}

function createFixtureRoot() {
  return mkdtempSync(join(tmpdir(), FIXTURE_ROOT_PREFIX));
}

function removeFixtureRoot(fixtureRoot) {
  if (!fixtureRoot) return false;
  const absolute = resolve(fixtureRoot);
  const tempRoot = `${resolve(tmpdir())}${sep}`;
  if (
    !absolute.startsWith(tempRoot) ||
    !absolute.slice(tempRoot.length).startsWith(FIXTURE_ROOT_PREFIX)
  ) {
    return false;
  }
  try {
    rmSync(absolute, { recursive: true, force: true });
    return true;
  } catch {
    return false;
  }
}

function sortedMessages(messages) {
  return [...messages].sort((left, right) =>
    String(left.external_id).localeCompare(String(right.external_id)),
  );
}

function messageDigest(messages) {
  return digest(sortedMessages(messages).map((message) => ({
    external_id: message.external_id,
    role: message.role,
    text: message.text,
    created_at: message.created_at,
  })));
}

function errorCode(error) {
  return String(error?.code ?? error?.name ?? "shadow_error")
    .replace(/[^A-Za-z0-9._:-]/gu, "_")
    .slice(0, 80);
}

async function defaultProfileProvider() {
  let databaseSyncAvailable = true;
  try {
    await import("node:sqlite");
  } catch {
    databaseSyncAvailable = false;
  }
  const {
    evaluateRuntimeProfile,
    PRODUCTION_PROFILE,
    PRODUCTION_PROFILE_SHA256,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/production-profile.mjs"
  );
  return {
    runtimeGate: evaluateRuntimeProfile({ databaseSyncAvailable }),
    profileId: PRODUCTION_PROFILE.profile_id,
    profileSha256: PRODUCTION_PROFILE_SHA256,
  };
}

function safeChildEnv() {
  const names = [
    "PATH",
    "SystemRoot",
    "TEMP",
    "TMP",
    "LOCALAPPDATA",
    "PATHEXT",
  ];
  return Object.fromEntries(
    names
      .filter((name) => typeof process.env[name] === "string")
      .map((name) => [name, process.env[name]]),
  );
}

export function loadSourceHostedShadowConfig({
  env = process.env,
  evidenceDir = null,
} = {}) {
  const rawMode = String(env[FLAG_NAME] ?? "").trim();
  const configured = rawMode !== "";
  const rawEvidenceDir = String(env[EVIDENCE_DIR_NAME] ?? "").trim();
  const selectedEvidenceDir = evidenceDir ?? rawEvidenceDir;
  let configError = null;
  if (!configured) {
    configError = "flag_absent";
  } else if (rawMode !== "shadow") {
    configError = "flag_not_shadow";
  } else if (!selectedEvidenceDir) {
    configError = "evidence_dir_missing";
  } else if (!isAbsolute(selectedEvidenceDir)) {
    configError = "evidence_dir_not_absolute";
  }
  return {
    configured,
    enabled: configured && configError === null,
    mode: rawMode || "off",
    evidenceDir:
      selectedEvidenceDir && isAbsolute(selectedEvidenceDir)
        ? resolve(selectedEvidenceDir)
        : null,
    configError,
  };
}

class ShadowCoordinatorRuntime {
  constructor({
    formalTaskId,
    channelId,
    objective,
    workerPath,
    spawnProcess,
    timeoutMs,
    expectedProfileId,
    expectedProfileSha256,
    onCoordinatorReady,
  }) {
    this.formalTaskId = formalTaskId;
    this.channelId = channelId;
    this.objective = objective;
    this.workerPath = workerPath;
    this.spawnProcess = spawnProcess;
    this.timeoutMs = timeoutMs;
    this.expectedProfileId = expectedProfileId;
    this.expectedProfileSha256 = expectedProfileSha256;
    this.onCoordinatorReady = onCoordinatorReady;
    this.child = null;
    this.baseUrl = null;
    this.taskId = shadowTaskId(formalTaskId);
    this.tokens = null;
    this.profile = null;
    this.observedProfile = null;
    this.fixtureRoot = null;
    this.closed = false;
    this.startPromise = null;
  }

  cleanupFixtureRoot() {
    const root = this.fixtureRoot;
    if (!root) return false;
    const removed = removeFixtureRoot(root);
    if (removed) this.fixtureRoot = null;
    return removed;
  }

  start() {
    if (this.baseUrl && !this.closed) {
      return Promise.resolve(this);
    }
    if (this.startPromise) return this.startPromise;
    this.startPromise = new Promise((resolvePromise, rejectPromise) => {
      this.fixtureRoot = createFixtureRoot();
      let child;
      try {
        child = this.spawnProcess(process.execPath, [this.workerPath], {
          cwd: resolve(import.meta.dirname, ".."),
          windowsHide: true,
          stdio: ["pipe", "pipe", "pipe"],
          env: {
            ...safeChildEnv(),
            SHADOW_TASK_ID: this.taskId,
            SHADOW_WORKSPACE_ID:
              `shadow-workspace-${redactedId(this.channelId).slice(0, 32)}`,
            SHADOW_CHANNEL_ID:
              `shadow-channel-${redactedId(this.channelId).slice(0, 32)}`,
            SHADOW_OBJECTIVE: this.objective,
            SHADOW_FIXTURE_ROOT: this.fixtureRoot,
          },
        });
      } catch (error) {
        this.cleanupFixtureRoot();
        rejectPromise(error);
        return;
      }
      this.child = child;
      let stdout = "";
      let stderr = "";
      let settled = false;
      const timer = setTimeout(() => {
        if (settled) return;
        settled = true;
        child.kill();
        rejectPromise(Object.assign(
          new Error("shadow coordinator startup timeout"),
          { code: "shadow_startup_timeout" },
        ));
      }, this.timeoutMs);
      const finish = (fn, value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        fn(value);
      };
      child.stderr.on("data", (chunk) => {
        if (stderr.length < 4_096) stderr += chunk.toString();
      });
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
        const newline = stdout.search(/\r?\n/u);
        if (newline < 0) return;
        const line = stdout.slice(0, newline).trim();
        if (!line) return;
        try {
          const ready = JSON.parse(line);
          if (!ready.ready) {
            finish(
              rejectPromise,
              Object.assign(
                new Error(String(ready.code ?? "shadow_start_failed")),
                {
                  code: String(ready.code ?? "shadow_start_failed"),
                  blockers: ready.blockers ?? [],
                },
              ),
            );
            child.kill();
            return;
          }
          this.observedProfile = {
            profile_id:
              typeof ready.profile_id === "string"
                ? ready.profile_id
                : null,
            profile_sha256:
              typeof ready.profile_sha256 === "string"
                ? ready.profile_sha256
                : null,
          };
          if (
            this.observedProfile.profile_id !== this.expectedProfileId ||
            this.observedProfile.profile_sha256 !==
              this.expectedProfileSha256
          ) {
            throw Object.assign(
              new Error("shadow coordinator profile identity mismatch"),
              {
                code: "shadow_profile_mismatch",
                blockers: [
                  ...(this.observedProfile.profile_id !==
                  this.expectedProfileId
                    ? ["profile_id_mismatch"]
                    : []),
                  ...(this.observedProfile.profile_sha256 !==
                  this.expectedProfileSha256
                    ? ["profile_sha256_mismatch"]
                    : []),
                ],
                expectedProfile: {
                  profile_id: this.expectedProfileId,
                  profile_sha256: this.expectedProfileSha256,
                },
                observedProfile: this.observedProfile,
              },
            );
          }
          const baseUrl = new URL(ready.base_url);
          if (
            baseUrl.protocol !== "http:" ||
            baseUrl.hostname !== "127.0.0.1" ||
            typeof ready.tokens?.source !== "string" ||
            typeof ready.tokens?.panel !== "string" ||
            typeof ready.tokens?.control !== "string" ||
            ready.runtime_gate?.ok !== true ||
            ready.database_gate?.ok !== true
          ) {
            throw Object.assign(
              new Error("shadow coordinator returned an invalid profile"),
              { code: "shadow_profile_invalid" },
            );
          }
          this.baseUrl = baseUrl.origin;
          this.tokens = { ...ready.tokens };
          this.profile = {
            profile_id: ready.profile_id,
            profile_sha256: ready.profile_sha256,
            identity_match: true,
            runtime_gate: ready.runtime_gate,
            database_gate: ready.database_gate,
          };
          this.onCoordinatorReady?.({
            child: this.child,
            formalTaskId: this.formalTaskId,
            taskId: this.taskId,
            baseUrl: this.baseUrl,
            fixtureRoot: this.fixtureRoot,
            profile: { ...this.profile },
          });
          finish(resolvePromise, this);
        } catch (error) {
          finish(rejectPromise, error);
          child.kill();
        }
      });
      child.once("error", (error) => {
        this.cleanupFixtureRoot();
        finish(rejectPromise, error);
      });
      child.once("exit", (code) => {
        this.closed = true;
        this.cleanupFixtureRoot();
        if (!settled) {
          finish(
            rejectPromise,
            Object.assign(
              new Error(`shadow coordinator exited ${code}: ${stderr}`),
              { code: "shadow_coordinator_unavailable" },
            ),
          );
        }
      });
    });
    return this.startPromise;
  }

  async close() {
    if (this.closed || !this.child) return;
    this.closed = true;
    if (
      this.child.exitCode === null &&
      this.child.signalCode === null
    ) {
      try {
        this.child.stdin?.end();
      } catch {
        // Fall back to process termination below.
      }
      const gracefulResult = await Promise.race([
        new Promise((resolvePromise) => {
          this.child.once("exit", resolvePromise);
        }),
        new Promise((resolvePromise) =>
          setTimeout(() => resolvePromise(SHUTDOWN_TIMEOUT), 2_000)),
      ]);
      if (
        gracefulResult === SHUTDOWN_TIMEOUT &&
        this.child.exitCode === null &&
        this.child.signalCode === null
      ) {
        this.child.kill();
        const killResult = await Promise.race([
          new Promise((resolvePromise) => {
            this.child.once("exit", resolvePromise);
          }),
          new Promise((resolvePromise) =>
            setTimeout(() => resolvePromise(SHUTDOWN_TIMEOUT), 1_000)),
        ]);
        if (
          killResult === SHUTDOWN_TIMEOUT &&
          this.child.exitCode === null &&
          this.child.signalCode === null
        ) {
          this.child.kill("SIGKILL");
        }
      }
    }
    this.cleanupFixtureRoot();
  }
}

export function createSourceHostedShadowObserver({
  env = process.env,
  evidenceDir = null,
  workerPath = resolve(
    import.meta.dirname,
    "..",
    "contracts",
    "source-hosted-shared-task",
    "v1",
    "persistence",
    "shadow-coordinator-worker.mjs",
  ),
  spawnProcess = spawn,
  fetchImpl = globalThis.fetch,
  profileProvider = defaultProfileProvider,
  now = () => new Date(),
  uuid = randomUUID,
  startupTimeoutMs = 10_000,
  requestTimeoutMs = 5_000,
  onCoordinatorReady = null,
  log = null,
} = {}) {
  const config = loadSourceHostedShadowConfig({ env, evidenceDir });
  const runtimes = new Map();
  let queue = Promise.resolve();

  function writeEvidence(value) {
    if (!config.evidenceDir) return null;
    try {
      mkdirSync(config.evidenceDir, { recursive: true, mode: 0o700 });
      const observedAt = now().toISOString();
      const fileName = `sync-${observedAt.replaceAll(":", "-")}-${
        uuid()
      }.json`;
      const payload = {
        schema_version: "1.0",
        evidence_type: "source_hosted_shadow_sync_import",
        observed_at: observedAt,
        ...value,
      };
      const text = `${JSON.stringify(payload, null, 2)}\n`;
      writeFileSync(
        resolve(config.evidenceDir, fileName),
        text,
        { encoding: "utf8", mode: 0o600 },
      );
      writeFileSync(
        resolve(config.evidenceDir, "latest.json"),
        text,
        { encoding: "utf8", mode: 0o600 },
      );
      return fileName;
    } catch {
      return null;
    }
  }

  function emitLog(status, ok, formalTaskId) {
    log?.({
      component: "source_hosted_shadow",
      action: "sync_import",
      status,
      ok,
      formal_ref: redactedId(formalTaskId),
    });
  }

  async function blocked(reason, input, profile = null, blockers = []) {
    const evidenceFile = writeEvidence({
      mode: config.mode,
      status: "blocked",
      ok: false,
      reason,
      blockers,
      formal: {
        task_hash: redactedId(input?.formal_task_id),
        channel_hash: redactedId(input?.channel_id),
        message_count: Array.isArray(input?.messages)
          ? input.messages.length
          : 0,
      },
      profile,
      coordinator_process: {
        required: true,
        started: false,
        available: false,
      },
      formal_response_unchanged: true,
    });
    emitLog("blocked", false, input?.formal_task_id);
    return {
      ok: false,
      status: "blocked",
      reason,
      evidence_file: evidenceFile,
    };
  }

  async function postJson(runtime, path, token, body) {
    let response;
    try {
      response = await fetchImpl(`${runtime.baseUrl}${path}`, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json; charset=utf-8",
        },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(requestTimeoutMs),
      });
    } catch (error) {
      throw Object.assign(
        new Error("shadow coordinator is unavailable"),
        {
          code: "shadow_coordinator_unavailable",
          cause: error,
        },
      );
    }
    const text = await response.text();
    let value;
    try {
      value = JSON.parse(text);
    } catch {
      throw Object.assign(
        new Error("shadow coordinator returned invalid JSON"),
        { code: "shadow_invalid_response" },
      );
    }
    if (!response.ok || value?.ok !== true) {
      throw Object.assign(
        new Error(String(value?.error?.code ?? "shadow_request_failed")),
        {
          code: String(value?.error?.code ?? "shadow_request_failed"),
          status: response.status,
        },
      );
    }
    return value;
  }

  async function pullAll(runtime, generation) {
    const events = [];
    let seq = 0;
    let hasMore = true;
    while (hasMore) {
      const pulled = await postJson(
        runtime,
        `/v1/tasks/${encodeURIComponent(runtime.taskId)}/mailbox/pull`,
        runtime.tokens.source,
        {
          schema_version: "1.0",
          request_id: `request-shadow-pull-${uuid()}`,
          after: { generation, seq },
          limit: 200,
        },
      );
      events.push(...pulled.events);
      seq = pulled.cursor.seq;
      hasMore = pulled.has_more === true;
      if (pulled.events.length === 0 && hasMore) {
        throw Object.assign(
          new Error("shadow pull made no cursor progress"),
          { code: "shadow_pull_stalled" },
        );
      }
    }
    return events;
  }

  async function observe(input) {
    const formalMessages = Array.isArray(input.messages)
      ? input.messages
        .filter((message) => message.external_id)
        .map((message) => ({
          external_id: String(message.external_id),
          role: message.role === "agent" ? "agent" : "user",
          text: String(message.text),
          created_at: String(message.created_at),
          seq: Number.isInteger(message.seq) ? message.seq : 0,
        }))
      : [];
    let profile;
    try {
      profile = await profileProvider();
    } catch (error) {
      return blocked(
        "profile_load_failed",
        input,
        null,
        [errorCode(error)],
      );
    }
    if (profile?.runtimeGate?.ok !== true) {
      return blocked(
        "runtime_profile_mismatch",
        input,
        {
          profile_id: profile?.profileId ?? null,
          profile_sha256: profile?.profileSha256 ?? null,
        },
        profile?.runtimeGate?.blockers ?? ["runtime_probe_not_passed"],
      );
    }
    const runtimeKey = redactedId(input.formal_task_id);
    let runtime = runtimes.get(runtimeKey);
    if (!runtime) {
      runtime = new ShadowCoordinatorRuntime({
        formalTaskId: input.formal_task_id,
        channelId: input.channel_id,
        objective: input.objective,
        workerPath,
        spawnProcess,
        timeoutMs: startupTimeoutMs,
        expectedProfileId: profile.profileId,
        expectedProfileSha256: profile.profileSha256,
        onCoordinatorReady,
      });
      runtimes.set(runtimeKey, runtime);
    }
    try {
      await runtime.start();
      let snapshot = await postJson(
        runtime,
        `/v1/tasks/${encodeURIComponent(runtime.taskId)}/mailbox/snapshot`,
        runtime.tokens.source,
        {
          schema_version: "1.0",
          request_id: `request-shadow-snapshot-${uuid()}`,
          include: [
            "task",
            "execution",
            "delivery_ack_state",
            "pending_counts",
          ],
          checkpoint: false,
        },
      );
      const initialGeneration = snapshot.snapshot.stream_generation;
      let existingEvents = await pullAll(runtime, initialGeneration);
      const existingIds = new Set(
        existingEvents
          .map((event) => event.payload?.external_id)
          .filter((value) => typeof value === "string"),
      );
      let missing = sortedMessages(formalMessages).filter(
        (message) => !existingIds.has(message.external_id),
      );
      let publishedCount = 0;
      while (missing.length > 0) {
        const batch = missing.slice(0, SHADOW_PUBLISH_BATCH_SIZE);
        const requestIds = batch.map((message) => message.external_id);
        const idempotencyKey =
          `shadow-${digest(requestIds.sort()).slice(0, 96)}`;
        const published = await postJson(
          runtime,
          `/v1/tasks/${encodeURIComponent(runtime.taskId)}/mailbox/publish`,
          runtime.tokens.source,
          {
            schema_version: "1.0",
            request_id: `request-shadow-publish-${uuid()}`,
            idempotency_key: idempotencyKey,
            expected: {
              stream_generation: snapshot.snapshot.stream_generation,
              snapshot_id: snapshot.snapshot.snapshot_id,
              snapshot_seq: snapshot.snapshot.snapshot_seq,
              task_revision: snapshot.task.task_revision,
              execution_epoch: snapshot.execution.fencing_epoch,
            },
            events: batch.map((message) => ({
              client_event_id: message.external_id,
              kind: "note",
              authority: "note",
              target_role: "panel",
              execution_epoch: snapshot.execution.fencing_epoch,
              origin: {
                session_ref: null,
                turn_id: null,
                item_id: null,
              },
              payload: {
                external_id: message.external_id,
                role: message.role,
                text: message.text,
                created_at: message.created_at,
              },
            })),
          },
        );
        publishedCount += published.events.length;
        missing = missing.slice(batch.length);
        if (missing.length > 0) {
          snapshot = await postJson(
            runtime,
            `/v1/tasks/${encodeURIComponent(runtime.taskId)}/mailbox/snapshot`,
            runtime.tokens.source,
            {
              schema_version: "1.0",
              request_id: `request-shadow-snapshot-${uuid()}`,
              include: [
                "task",
                "execution",
                "delivery_ack_state",
                "pending_counts",
              ],
              checkpoint: false,
            },
          );
        }
      }
      const generation =
        snapshot.snapshot.stream_generation ?? initialGeneration;
      existingEvents = await pullAll(runtime, generation);
      const shadowMessages = existingEvents
        .map((event) => event.payload)
        .filter(
          (payload) =>
            payload &&
            typeof payload.external_id === "string" &&
            typeof payload.text === "string",
        )
        .map((payload) => ({
          external_id: payload.external_id,
          role: payload.role,
          text: payload.text,
          created_at: payload.created_at,
        }));
      const formalDigest = messageDigest(formalMessages);
      const shadowDigest = messageDigest(shadowMessages);
      const match =
        formalMessages.length === shadowMessages.length &&
        formalDigest === shadowDigest;
      const evidenceFile = writeEvidence({
        mode: "shadow",
        status: match ? "match" : "mismatch",
        ok: match,
        formal: {
          task_hash: redactedId(input.formal_task_id),
          channel_hash: redactedId(input.channel_id),
          source_session_hash: redactedId(input.source_session_ref),
          cursor: input.cursor,
          message_count: formalMessages.length,
          content_sha256: formalDigest,
        },
        shadow: {
          task_hash: redactedId(runtime.taskId),
          generation_hash: redactedId(generation),
          event_count: shadowMessages.length,
          published_count: publishedCount,
          reused_count: formalMessages.length - publishedCount,
          content_sha256: shadowDigest,
        },
        profile: runtime.profile,
        coordinator_process: {
          required: true,
          started: true,
          isolated: true,
          available: true,
        },
        formal_response_unchanged: true,
      });
      emitLog(match ? "match" : "mismatch", match, input.formal_task_id);
      return {
        ok: match,
        status: match ? "match" : "mismatch",
        evidence_file: evidenceFile,
      };
    } catch (error) {
      const reason = errorCode(error);
      const expectedProfile = {
        profile_id: profile.profileId,
        profile_sha256: profile.profileSha256,
      };
      const evidenceFile = writeEvidence({
        mode: "shadow",
        status: "blocked",
        ok: false,
        reason,
        blockers: error?.blockers ?? [],
        formal: {
          task_hash: redactedId(input.formal_task_id),
          channel_hash: redactedId(input.channel_id),
          source_session_hash: redactedId(input.source_session_ref),
          cursor: input.cursor,
          message_count: formalMessages.length,
        },
        profile: runtime.profile ?? {
          profile_id:
            runtime.observedProfile?.profile_id ?? null,
          profile_sha256:
            runtime.observedProfile?.profile_sha256 ?? null,
          identity_match: false,
          expected_profile: expectedProfile,
          observed_profile: runtime.observedProfile ?? null,
        },
        coordinator_process: {
          required: true,
          started: Boolean(runtime.baseUrl),
          isolated: true,
          available: !runtime.closed,
        },
        formal_response_unchanged: true,
      });
      emitLog("blocked", false, input.formal_task_id);
      return {
        ok: false,
        status: "blocked",
        reason,
        evidence_file: evidenceFile,
      };
    }
  }

  return {
    config,
    get shouldObserve() {
      return config.configured;
    },
    async observeSyncImport(input) {
      if (!config.configured) {
        return {
          ok: false,
          status: "disabled",
          reason: "flag_absent",
        };
      }
      if (!config.enabled) {
        return blocked(config.configError, input);
      }
      const run = queue.then(
        () => observe(input),
        () => observe(input),
      );
      queue = run.catch(() => {});
      return run;
    },
    async close() {
      await queue.catch(() => {});
      await Promise.all(
        [...runtimes.values()].map((runtime) => runtime.close()),
      );
      runtimes.clear();
    },
  };
}
