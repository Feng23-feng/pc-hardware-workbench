import { createHash, randomUUID } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { canonicalJson, canonicalRequestHash } from "../reference/canonical-hash.mjs";
import { createContractValidator } from "../reference/contract-validator.mjs";
import { errorResult } from "../reference/error-codes.mjs";
import {
  CONTRACT,
  PROFILE_ACTIONS,
  SCHEMA_VERSION,
} from "../reference/coordinator.mjs";
import {
  configureDatabase,
  migrateToV1,
} from "./schema-v1.mjs";

function iso(ms) {
  return new Date(ms).toISOString();
}

function verifierFor(token) {
  return createHash("sha256").update(String(token), "utf8").digest("hex");
}

function payloadHash(payload) {
  return createHash("sha256")
    .update(canonicalJson(payload), "utf8")
    .digest("hex");
}

function targetIncludes(target, role) {
  return target === role || target === "both";
}

function ownerForMode(mode) {
  if (mode === "source_hosted") return "source";
  if (mode === "panel_hosted") return "panel";
  return "none";
}

function safeRequestId(value) {
  return typeof value === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u.test(value)
    ? value
    : "request-invalid";
}

export class InjectedFault extends Error {
  constructor(point) {
    super(`Injected fault at ${point}`);
    this.name = "InjectedFault";
    this.code = "INJECTED_FAULT";
    this.point = point;
  }
}

export class SqliteConformanceCoordinator {
  constructor({
    dbPath,
    now = () => Date.now(),
    uuid = randomUUID,
    validator = createContractValidator(),
    busyTimeoutMs = 5_000,
    snapshotTtlMs = 10 * 60 * 1000,
    checkpointTtlMs = 5 * 60 * 1000,
    handleTtlMs = 30 * 60 * 1000,
    maxSnapshotsPerActor = 64,
    faultInjector = null,
  }) {
    if (!dbPath || dbPath === ":memory:") {
      throw new Error("SQLite conformance requires a file-backed database");
    }
    this.dbPath = dbPath;
    this.now = now;
    this.uuid = uuid;
    this.validator = validator;
    this.snapshotTtlMs = snapshotTtlMs;
    this.checkpointTtlMs = checkpointTtlMs;
    this.handleTtlMs = handleTtlMs;
    this.maxSnapshotsPerActor = maxSnapshotsPerActor;
    this.faultInjector = faultInjector;
    this.issuedCapabilities = new Map();
    mkdirSync(dirname(dbPath), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(dbPath);
    try {
      this.pragmas = configureDatabase(this.db, { busyTimeoutMs });
      this.migration = migrateToV1(this.db, { now: this.now });
      this.integrity = this.inspectIntegrity();
    } catch (error) {
      try {
        this.db.close();
      } catch {
        // Preserve the startup/migration error.
      }
      throw error;
    }
  }

  close() {
    this.db.close();
  }

  takeIssuedCapabilities(taskId = null) {
    if (taskId !== null) {
      const value = this.issuedCapabilities.get(taskId) ?? null;
      this.issuedCapabilities.delete(taskId);
      return value;
    }
    if (this.issuedCapabilities.size === 0) return null;
    if (this.issuedCapabilities.size === 1) {
      const value = this.issuedCapabilities.values().next().value;
      this.issuedCapabilities.clear();
      return value;
    }
    const values = Object.fromEntries(this.issuedCapabilities);
    this.issuedCapabilities.clear();
    return values;
  }

  _id(prefix) {
    return `${prefix}-${this.uuid()}`;
  }

  _token(prefix) {
    return `${prefix}_${this.uuid().replaceAll("-", "")}`;
  }

  _requestId(request) {
    return safeRequestId(request?.request_id);
  }

  _error(request, code, message, details = {}, taskId = null) {
    return errorResult({
      requestId: this._requestId(request),
      taskId: taskId ?? this._taskIdFromRequest(request),
      code,
      message,
      details,
    });
  }

  _taskIdFromRequest(request) {
    try {
      const row = this.db.prepare(
        "SELECT task_id FROM tasks ORDER BY created_at_ms LIMIT 1",
      ).get();
      return row?.task_id ?? "task-fixture-01";
    } catch {
      return "task-fixture-01";
    }
  }

  _fault(point, context = {}, faultInjector = this.faultInjector) {
    if (typeof faultInjector === "function") {
      faultInjector(point, context);
    }
  }

  _schemaError(operation, request) {
    const schemaNames = {
      snapshot: "snapshot",
      pull: "pull",
      publish: "publish",
      ack: "ack",
      claim_lease: "claimLease",
      release_lease: "releaseLease",
    };
    const result = this.validator.validateRequest(
      schemaNames[operation] ?? operation,
      request,
    );
    if (result.valid) return null;
    return this._error(
      request,
      "schema_invalid",
      "The request does not match the source_hosted-shared-task-v1 schema.",
      {
        errors: result.errors.slice(0, 20).map((item) => ({
          instancePath: item.instancePath,
          keyword: item.keyword,
          message: item.message,
        })),
      },
    );
  }

  _bodySize(value) {
    try {
      const json = JSON.stringify(value ?? null);
      return typeof json === "string"
        ? Buffer.byteLength(json, "utf8")
        : null;
    } catch {
      return null;
    }
  }

  _begin(fn) {
    this.db.exec("BEGIN IMMEDIATE;");
    try {
      const result = fn();
      this.db.exec("COMMIT;");
      return result;
    } catch (error) {
      try {
        this.db.exec("ROLLBACK;");
      } catch {
        // Preserve the original error.
      }
      throw error;
    }
  }

  _writeTransaction(fn, {
    faultInjector = this.faultInjector,
    context = {},
  } = {}) {
    this._fault("before_transaction", context, faultInjector);
    this.db.exec("BEGIN IMMEDIATE;");
    try {
      const result = fn();
      this._fault("before_commit", context, faultInjector);
      this.db.exec("COMMIT;");
      this._fault("after_commit_before_response", context, faultInjector);
      return result;
    } catch (error) {
      try {
        this.db.exec("ROLLBACK;");
      } catch {
        // COMMIT may already have happened before an injected post-commit fault.
      }
      throw error;
    }
  }

  _taskRow(taskId = null) {
    if (taskId !== null) {
      return this.db.prepare(
        "SELECT * FROM tasks WHERE task_id = ?",
      ).get(taskId);
    }
    return this.db.prepare(
      "SELECT * FROM tasks ORDER BY created_at_ms LIMIT 1",
    ).get();
  }

  hasTask(taskId) {
    return Boolean(
      typeof taskId === "string" &&
      this.db.prepare(
        "SELECT 1 AS present FROM tasks WHERE task_id = ?",
      ).get(taskId),
    );
  }

  getTaskId() {
    return this._taskRow()?.task_id ?? null;
  }

  authorize(token, action, { taskId = null } = {}) {
    const auth = this._auth(
      token,
      action,
      { request_id: "request-http-auth" },
      taskId,
    );
    if (auth.error) return auth.error;
    return {
      ok: true,
      task_id: auth.task.task_id,
      actor_id: auth.row.actor_id,
      actor_role: auth.row.actor_role,
      kind: auth.row.kind,
    };
  }

  _assertGenerationInvariant(taskId) {
    const active = this.db.prepare(
      `SELECT generation FROM stream_generations
       WHERE task_id = ? AND retired_at_ms IS NULL`,
    ).all(taskId);
    const task = this.db.prepare(
      "SELECT stream_generation FROM tasks WHERE task_id = ?",
    ).get(taskId);
    if (
      active.length !== 1 ||
      !task ||
      active[0].generation !== task.stream_generation
    ) {
      throw new Error("Task must have exactly one current unretired generation");
    }
  }

  _auth(token, action, request, taskId = null) {
    const fail = (code, message, details = {}) =>
      this._error(request, code, message, details, taskId);
    if (!token) {
      return {
        error: fail(
          "capability_missing",
          "A Task-scoped capability is required.",
        ),
      };
    }
    const row = this.db.prepare(
      "SELECT * FROM authority_verifiers WHERE verifier_sha256 = ?",
    ).get(verifierFor(token));
    if (!row) {
      return {
        error: fail(
          "capability_invalid",
          "The Task-scoped capability is invalid.",
        ),
      };
    }
    if (row.revoked_at_ms !== null) {
      return {
        error: fail(
          "capability_revoked",
          "The Task-scoped capability was revoked.",
        ),
      };
    }
    if (this.now() >= Number(row.expires_at_ms)) {
      return {
        error: fail(
          "capability_expired",
          "The Task-scoped capability expired.",
        ),
      };
    }
    const task = this._taskRow(taskId);
    if (!task) {
      return {
        error: fail(
          "task_not_found",
          "The requested Task is unavailable.",
        ),
      };
    }
    if (row.task_id !== task.task_id) {
      return {
        error: fail(
          "capability_scope_mismatch",
          "The capability is bound to another Task.",
        ),
      };
    }
    if (
      row.stream_generation !== task.stream_generation ||
      row.workspace_id !== task.workspace_id
    ) {
      return {
        error: fail(
          "capability_scope_mismatch",
          "The capability no longer matches the Task generation.",
        ),
      };
    }
    const allowed = JSON.parse(row.allowed_actions_json);
    if (!Array.isArray(allowed) || !allowed.includes(action)) {
      return {
        error: fail(
          "action_not_allowed",
          "The capability does not allow this action.",
        ),
      };
    }
    if (row.kind === "mailbox") {
      const profileActions = PROFILE_ACTIONS[row.mailbox_profile];
      if (
        !profileActions ||
        allowed.length !== profileActions.length ||
        new Set(allowed).size !== allowed.length ||
        profileActions.some((item) => !allowed.includes(item)) ||
        allowed.some((item) => !profileActions.includes(item))
      ) {
        return {
          error: fail(
            "capability_invalid",
            "allowed_actions does not match mailbox_profile.",
          ),
        };
      }
      if (
        (row.mailbox_profile === "recovery" ||
          row.mailbox_profile === "recovery_ack") &&
        task.mode !== "suspended"
      ) {
        return {
          error: fail(
            "capability_scope_mismatch",
            "Recovery capability is valid only while suspended.",
          ),
        };
      }
      if (row.mailbox_profile === "standard" && task.mode === "suspended") {
        return {
          error: fail(
            "capability_rotated",
            "The standard capability is no longer current.",
          ),
        };
      }
    }
    return { row, task, allowed };
  }

  _insertVerifier({
    token,
    tokenPrefix,
    kind,
    task,
    actorId,
    actorRole,
    profile,
    permittedAuthority,
    rotationGeneration,
    issuedAt,
    expiresAt,
    handleId = null,
  }) {
    const actualHandleId = handleId ?? this._id("handle");
    const actions =
      kind === "mailbox"
        ? [...PROFILE_ACTIONS[profile]]
        : ["claim_lease", "release_lease"];
    this.db.prepare(
      `INSERT INTO authority_verifiers(
        verifier_sha256, handle_id, kind, task_id, workspace_id, actor_id,
        actor_role, mailbox_profile, execution_epoch, stream_generation,
        allowed_actions_json, permitted_authority_json, rotation_generation,
        issued_at_ms, expires_at_ms, revoked_at_ms, revoked_reason
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL)`,
    ).run(
      verifierFor(token),
      actualHandleId,
      kind,
      task.task_id,
      task.workspace_id,
      actorId,
      actorRole,
      profile,
      actorRole ? task.fencing_epoch : null,
      task.stream_generation,
      JSON.stringify(actions),
      JSON.stringify(permittedAuthority),
      rotationGeneration,
      issuedAt,
      expiresAt,
    );
    return {
      token,
      metadata: {
        handle_id: actualHandleId,
        kind,
        task_id: task.task_id,
        workspace_id: task.workspace_id,
        actor_id: actorId,
        actor_role: actorRole,
        mailbox_profile: profile,
        execution_epoch: actorRole ? task.fencing_epoch : null,
        stream_generation: task.stream_generation,
        allowed_actions: actions,
        permitted_authority: permittedAuthority,
        rotation_generation: rotationGeneration,
        issued_at: iso(issuedAt),
        expires_at: iso(expiresAt),
      },
    };
  }

  _issueVerifierSet(task, rotationGeneration, now) {
    const owner = task.owner_role;
    const profiles =
      task.mode === "suspended"
        ? {
            source: "recovery",
            panel: "recovery",
          }
        : {
            source: "standard",
            panel: "standard",
          };
    const sourceToken = this._token("sth");
    const panelToken = this._token("sth");
    const controlToken = this._token("ctl");
    const sourceAuthority =
      task.mode === "suspended"
        ? []
        : [
            "surface_input",
            ...(owner === "source" ? ["execution_result"] : []),
            "note",
          ];
    const panelAuthority =
      task.mode === "suspended"
        ? []
        : [
            "surface_input",
            ...(owner === "panel" ? ["execution_result"] : []),
            "note",
          ];
    this._insertVerifier({
      token: sourceToken,
      kind: "mailbox",
      task,
      actorId: "actor-source-sqlite",
      actorRole: "source",
      profile: profiles.source,
      permittedAuthority: sourceAuthority,
      rotationGeneration,
      issuedAt: now,
      expiresAt: now + this.handleTtlMs,
    });
    this._insertVerifier({
      token: panelToken,
      kind: "mailbox",
      task,
      actorId: "actor-panel-sqlite",
      actorRole: "panel",
      profile: profiles.panel,
      permittedAuthority: panelAuthority,
      rotationGeneration,
      issuedAt: now,
      expiresAt: now + this.handleTtlMs,
    });
    this._insertVerifier({
      token: controlToken,
      kind: "lease_control",
      task,
      actorId: "actor-control-sqlite",
      actorRole: null,
      profile: null,
      permittedAuthority: [],
      rotationGeneration,
      issuedAt: now,
      expiresAt: now + this.handleTtlMs,
    });
    return {
      source: sourceToken,
      panel: panelToken,
      control: controlToken,
    };
  }

  bootstrapFixture({
    taskId = "task-sqlite-fixture-01",
    workspaceId = "workspace-sqlite-fixture-01",
    channelId = `chat:fixture:${taskId}`,
    objective = "Synthetic SQLite conformance Task",
  } = {}) {
    if (this._taskRow(taskId)) {
      throw new Error(`Fixture database already contains Task ${taskId}`);
    }
    const now = this.now();
    const generation = this._id("stream");
    const leaseId = this._id("lease");
    const sourceToken = this._token("sth");
    const panelToken = this._token("sth");
    const controlToken = this._token("ctl");
    const sourceActorId = "actor-source-sqlite";
    const panelActorId = "actor-panel-sqlite";
    const controlActorId = "actor-control-sqlite";
    const task = {
      task_id: taskId,
      workspace_id: workspaceId,
      channel_id: channelId,
      stream_generation: generation,
      fencing_epoch: 1,
    };
    this._begin(() => {
      this.db.prepare(
        `INSERT INTO stream_generations(
          task_id, generation, created_at_ms, retired_at_ms, reason
        ) VALUES(?, ?, ?, NULL, NULL)`,
      ).run(taskId, generation, now);
      this.db.prepare(
        `INSERT INTO tasks(
          task_id, contract_version, channel_id, workspace_id, objective,
          state_json, mode, owner_role, lease_id, fencing_epoch, task_revision,
          stream_generation, head_seq, min_retained_seq, status,
          created_at_ms, updated_at_ms, closed_at_ms
        ) VALUES(?, ?, ?, ?, ?, ?, 'source_hosted', 'source', ?, 1, 1,
          ?, 0, 1, 'active', ?, ?, NULL)`,
      ).run(
        taskId,
        CONTRACT,
        channelId,
        workspaceId,
        objective,
        "{}",
        leaseId,
        generation,
        now,
        now,
      );
      for (const role of ["source", "panel"]) {
        this.db.prepare(
          `INSERT INTO mailbox_delivery_state(
            task_id, actor_role, generation, delivered_seq_prefix,
            ack_coverage_prefix, updated_at_ms
          ) VALUES(?, ?, ?, 0, 0, ?)`,
        ).run(taskId, role, generation, now);
      }
      this._insertVerifier({
        token: sourceToken,
        kind: "mailbox",
        task,
        actorId: sourceActorId,
        actorRole: "source",
        profile: "standard",
        permittedAuthority: ["surface_input", "execution_result", "note"],
        rotationGeneration: 1,
        issuedAt: now,
        expiresAt: now + this.handleTtlMs,
      });
      this._insertVerifier({
        token: panelToken,
        kind: "mailbox",
        task,
        actorId: panelActorId,
        actorRole: "panel",
        profile: "standard",
        permittedAuthority: ["surface_input", "note"],
        rotationGeneration: 1,
        issuedAt: now,
        expiresAt: now + this.handleTtlMs,
      });
      this._insertVerifier({
        token: controlToken,
        kind: "lease_control",
        task,
        actorId: controlActorId,
        actorRole: null,
        profile: null,
        permittedAuthority: [],
        rotationGeneration: 1,
        issuedAt: now,
        expiresAt: now + this.handleTtlMs,
      });
      this._assertGenerationInvariant(taskId);
    });
    return {
      task_id: taskId,
      workspace_id: workspaceId,
      channel_id: channelId,
      stream_generation: generation,
      tokens: {
        source: sourceToken,
        panel: panelToken,
        control: controlToken,
      },
    };
  }

  _executionState(task = this._taskRow()) {
    return {
      mode: task.mode,
      owner: task.owner_role,
      lease_id: task.mode === "suspended" ? null : task.lease_id,
      fencing_epoch: task.fencing_epoch,
    };
  }

  _pendingCounts(task = this._taskRow()) {
    const count = (role) => Number(this.db.prepare(
      `SELECT COUNT(*) AS count
       FROM events e
       WHERE e.task_id = ? AND e.generation = ?
         AND (e.target_role = ? OR e.target_role = 'both')
         AND NOT EXISTS (
           SELECT 1 FROM event_acks a
           WHERE a.task_id = e.task_id
             AND a.event_id = e.event_id
             AND a.actor_role = ?
         )`,
    ).get(task.task_id, task.stream_generation, role, role).count);
    return {
      for_source: count("source"),
      for_panel: count("panel"),
    };
  }

  _deliveryAckState(task = this._taskRow()) {
    const state = {};
    for (const role of ["source", "panel"]) {
      const row = this.db.prepare(
        `SELECT generation, delivered_seq_prefix, ack_coverage_prefix
         FROM mailbox_delivery_state
         WHERE task_id = ? AND actor_role = ?`,
      ).get(task.task_id, role);
      state[role] = {
        generation: row.generation,
        delivered_seq_prefix: Number(row.delivered_seq_prefix),
        ack_coverage_prefix: Number(row.ack_coverage_prefix),
      };
    }
    return state;
  }

  _taskState(task = this._taskRow()) {
    return {
      schema_version: SCHEMA_VERSION,
      contract: CONTRACT,
      task_id: task.task_id,
      channel_id: task.channel_id,
      workspace_id: task.workspace_id,
      mode: task.mode,
      execution: this._executionState(task),
      task_revision: Number(task.task_revision),
      stream: {
        generation: task.stream_generation,
        head_seq: Number(task.head_seq),
        min_retained_seq: Number(task.min_retained_seq),
      },
      snapshot_seq: Number(task.head_seq),
      objective: task.objective,
      state: JSON.parse(task.state_json),
      pending: this._pendingCounts(task),
    };
  }

  _snapshotResponse(request, task, snapshot, checkpoint = null) {
    return {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: task.task_id,
      status: "snapshot",
      task: this._taskState(task),
      snapshot: {
        snapshot_id: snapshot.snapshot_id,
        stream_generation: snapshot.generation,
        snapshot_seq: Number(snapshot.snapshot_seq),
        task_revision: Number(snapshot.task_revision),
        stream_head_seq: Number(task.head_seq),
        min_retained_seq: Number(task.min_retained_seq),
        issued_at: iso(Number(snapshot.issued_at_ms)),
        expires_at: iso(Number(snapshot.expires_at_ms)),
      },
      execution: this._executionState(task),
      delivery_ack_state: this._deliveryAckState(task),
      pending_counts: this._pendingCounts(task),
      checkpoint: checkpoint
        ? {
            checkpoint_id: checkpoint.checkpoint_id,
            generation: checkpoint.generation,
            snapshot_seq: Number(checkpoint.snapshot_seq),
            task_revision: Number(checkpoint.task_revision),
            fencing_epoch: Number(checkpoint.fencing_epoch),
            required_coverage_prefix: Number(
              checkpoint.required_coverage_prefix,
            ),
            expires_at: iso(Number(checkpoint.expires_at_ms)),
          }
        : null,
    };
  }

  _createSnapshotRow(task, actorRole, actorId, checkpoint) {
    const now = this.now();
    const reusable = this.db.prepare(
      `SELECT * FROM mailbox_snapshots
       WHERE task_id = ? AND actor_id = ? AND actor_role = ?
         AND generation = ? AND snapshot_seq = ? AND task_revision = ?
         AND fencing_epoch = ? AND invalidated_at_ms IS NULL
         AND expires_at_ms > ?
       ORDER BY issued_at_ms DESC LIMIT 1`,
    ).get(
      task.task_id,
      actorId,
      actorRole,
      task.stream_generation,
      task.head_seq,
      task.task_revision,
      task.fencing_epoch,
      now,
    );
    let snapshot = reusable;
    if (!snapshot) {
      const count = Number(this.db.prepare(
        `SELECT COUNT(*) AS count FROM mailbox_snapshots
         WHERE task_id = ? AND actor_id = ?
           AND invalidated_at_ms IS NULL AND expires_at_ms > ?`,
      ).get(task.task_id, actorId, now).count);
      if (count >= this.maxSnapshotsPerActor) {
        return null;
      }
      snapshot = {
        snapshot_id: this._id("snapshot"),
        task_id: task.task_id,
        actor_id: actorId,
        actor_role: actorRole,
        generation: task.stream_generation,
        snapshot_seq: Number(task.head_seq),
        task_revision: Number(task.task_revision),
        fencing_epoch: Number(task.fencing_epoch),
        issued_at_ms: now,
        expires_at_ms: now + this.snapshotTtlMs,
        invalidated_at_ms: null,
      };
      this.db.prepare(
        `INSERT INTO mailbox_snapshots(
          snapshot_id, task_id, actor_id, actor_role, generation,
          snapshot_seq, task_revision, fencing_epoch, issued_at_ms,
          expires_at_ms, invalidated_at_ms
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
      ).run(
        snapshot.snapshot_id,
        snapshot.task_id,
        snapshot.actor_id,
        snapshot.actor_role,
        snapshot.generation,
        snapshot.snapshot_seq,
        snapshot.task_revision,
        snapshot.fencing_epoch,
        snapshot.issued_at_ms,
        snapshot.expires_at_ms,
      );
    }
    let checkpointRow = null;
    if (checkpoint) {
      checkpointRow = {
        checkpoint_id: this._id("checkpoint"),
        snapshot_id: snapshot.snapshot_id,
        task_id: task.task_id,
        generation: snapshot.generation,
        snapshot_seq: Number(snapshot.snapshot_seq),
        task_revision: Number(snapshot.task_revision),
        fencing_epoch: Number(snapshot.fencing_epoch),
        required_coverage_prefix: Number(snapshot.snapshot_seq),
        issued_at_ms: now,
        expires_at_ms: now + this.checkpointTtlMs,
        consumed_at_ms: null,
      };
      this.db.prepare(
        `INSERT INTO mailbox_checkpoints(
          checkpoint_id, snapshot_id, task_id, generation, snapshot_seq,
          task_revision, fencing_epoch, required_coverage_prefix,
          issued_at_ms, expires_at_ms, consumed_at_ms
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)`,
      ).run(
        checkpointRow.checkpoint_id,
        checkpointRow.snapshot_id,
        checkpointRow.task_id,
        checkpointRow.generation,
        checkpointRow.snapshot_seq,
        checkpointRow.task_revision,
        checkpointRow.fencing_epoch,
        checkpointRow.required_coverage_prefix,
        checkpointRow.issued_at_ms,
        checkpointRow.expires_at_ms,
      );
    }
    return { snapshot, checkpoint: checkpointRow };
  }

  snapshot(token, request, { taskId = null } = {}) {
    const invalid = this._schemaError("snapshot", request);
    if (invalid) return invalid;
    return this._begin(() => {
      const auth = this._auth(token, "snapshot", request, taskId);
      if (auth.error) return auth.error;
      const created = this._createSnapshotRow(
        auth.task,
        auth.row.actor_role,
        auth.row.actor_id,
        request.checkpoint === true,
      );
      if (!created) {
        return this._error(
          request,
          "snapshot_capacity_exceeded",
          "The snapshot metadata cap was reached.",
        );
      }
      return this._snapshotResponse(
        request,
        auth.task,
        created.snapshot,
        created.checkpoint,
      );
    });
  }

  _loadReceipt(taskId, actorId, operation, key) {
    return this.db.prepare(
      `SELECT * FROM idempotency_receipts
       WHERE task_id = ? AND actor_id = ? AND operation = ?
         AND idempotency_key = ?`,
    ).get(taskId, actorId, operation, key);
  }

  _duplicateResponse(row, requestId) {
    const response = JSON.parse(row.response_json);
    response.request_id = requestId;
    response.status = "duplicate";
    if (response.receipt) {
      response.receipt.original_request_id = row.original_request_id;
    }
    return response;
  }

  _insertReceipt({
    mutationId,
    task,
    actorId,
    actorRole,
    operation,
    request,
    hash,
    response,
    eventReceipts = [],
    nextSnapshot = null,
    committedAtMs,
  }) {
    this.db.prepare(
      `INSERT INTO idempotency_receipts(
        receipt_id, mutation_id, task_id, actor_id, actor_role, operation,
        idempotency_key, canonical_hash_alg, canonical_hash,
        original_request_id, outcome, response_json, event_receipts_json,
        next_snapshot_json, task_revision, stream_generation, head_seq,
        committed_at_ms
      ) VALUES(?, ?, ?, ?, ?, ?, ?, 'sha256', ?, ?, 'applied',
        ?, ?, ?, ?, ?, ?, ?)`,
    ).run(
      this._id("receipt"),
      mutationId,
      task.task_id,
      actorId,
      actorRole,
      operation,
      request.idempotency_key,
      hash,
      request.request_id,
      JSON.stringify(response),
      eventReceipts.length ? JSON.stringify(eventReceipts) : null,
      nextSnapshot ? JSON.stringify(nextSnapshot) : null,
      Number(task.task_revision),
      task.stream_generation,
      Number(task.head_seq),
      committedAtMs,
    );
  }

  _validateSnapshot(task, actorId, actorRole, expected, request) {
    const snapshot = this.db.prepare(
      "SELECT * FROM mailbox_snapshots WHERE snapshot_id = ?",
    ).get(expected.snapshot_id);
    if (
      !snapshot ||
      snapshot.invalidated_at_ms !== null ||
      this.now() >= Number(snapshot.expires_at_ms) ||
      snapshot.task_id !== task.task_id ||
      snapshot.actor_id !== actorId ||
      snapshot.actor_role !== actorRole ||
      snapshot.generation !== expected.stream_generation ||
      snapshot.generation !== task.stream_generation ||
      Number(snapshot.snapshot_seq) !== expected.snapshot_seq
    ) {
      return this._error(
        request,
        "snapshot_required",
        "A current coherent snapshot is required.",
        { reason: "invalid_or_expired" },
      );
    }
    if (Number(snapshot.task_revision) !== expected.task_revision) {
      return this._error(
        request,
        "snapshot_required",
        "The snapshot revision does not match the request baseline.",
        { reason: "revision_binding_mismatch" },
      );
    }
    if (Number(snapshot.fencing_epoch) !== expected.execution_epoch) {
      return this._error(
        request,
        "lease_conflict",
        "The snapshot execution epoch does not match the request.",
      );
    }
    if (expected.task_revision !== Number(task.task_revision)) {
      return this._error(
        request,
        "revision_conflict",
        "The expected Task revision is stale.",
      );
    }
    if (expected.execution_epoch !== Number(task.fencing_epoch)) {
      return this._error(
        request,
        "lease_conflict",
        "The expected execution epoch is not current.",
      );
    }
    return { ok: true, snapshot };
  }

  _coverage(task, actorRole) {
    const rows = this.db.prepare(
      `SELECT e.event_id, e.stream_seq, e.target_role,
         EXISTS(
           SELECT 1 FROM event_acks a
           WHERE a.task_id = e.task_id
             AND a.event_id = e.event_id
             AND a.actor_role = ?
         ) AS acknowledged
       FROM events e
       WHERE e.task_id = ? AND e.generation = ?
       ORDER BY e.stream_seq`,
    ).all(actorRole, task.task_id, task.stream_generation);
    let coverage = 0;
    for (const row of rows) {
      if (!targetIncludes(row.target_role, actorRole)) {
        coverage = Number(row.stream_seq);
        continue;
      }
      if (!row.acknowledged) break;
      coverage = Number(row.stream_seq);
    }
    return coverage;
  }

  _eventJson(row) {
    return {
      event_id: row.event_id,
      stream_seq: Number(row.stream_seq),
      kind: row.kind,
      authority: row.authority,
      author_role: row.author_role,
      target_role: row.target_role,
      execution_epoch: Number(row.execution_epoch),
      origin: JSON.parse(row.origin_json),
      payload: JSON.parse(row.payload_json),
      created_at: iso(Number(row.created_at_ms)),
    };
  }

  pull(token, request, {
    faultInjector = this.faultInjector,
    taskId = null,
  } = {}) {
    const size = this._bodySize(request);
    if (size === null || size > 64 * 1024) {
      return this._error(
        request,
        size === null ? "schema_invalid" : "payload_too_large",
        size === null
          ? "The pull request is not JSON-safe."
          : "The pull request exceeds 64 KiB.",
      );
    }
    const invalid = this._schemaError("pull", request);
    if (invalid) return invalid;
    return this._writeTransaction(() => {
      const auth = this._auth(token, "pull", request, taskId);
      if (auth.error) return auth.error;
      const task = auth.task;
      if (
        request.after.generation !== task.stream_generation ||
        request.after.seq > Number(task.head_seq) ||
        request.after.seq < Number(task.min_retained_seq) - 1
      ) {
        return this._error(
          request,
          "resync_required",
          "The pull cursor is not valid for the current generation.",
          {
            reason:
              request.after.generation !== task.stream_generation
                ? "generation_mismatch"
                : request.after.seq > Number(task.head_seq)
                  ? "cursor_ahead"
                  : "cursor_too_old",
          },
        );
      }
      const limit = request.limit ?? 50;
      const rows = this.db.prepare(
        `SELECT * FROM events
         WHERE task_id = ? AND generation = ? AND stream_seq > ?
         ORDER BY stream_seq LIMIT ?`,
      ).all(
        task.task_id,
        task.stream_generation,
        request.after.seq,
        limit,
      );
      if (
        rows.length > 0 &&
        Number(rows[0].stream_seq) !== request.after.seq + 1
      ) {
        return this._error(
          request,
          "resync_required",
          "The Event stream contains a cursor gap.",
          { reason: "cursor_gap" },
        );
      }
      const delivery = this.db.prepare(
        `SELECT * FROM mailbox_delivery_state
         WHERE task_id = ? AND actor_role = ?`,
      ).get(task.task_id, auth.row.actor_role);
      let delivered = Number(delivery.delivered_seq_prefix);
      if (
        rows.length > 0 &&
        Number(rows[0].stream_seq) <= delivered + 1
      ) {
        delivered = Number(rows.at(-1).stream_seq);
        this.db.prepare(
          `UPDATE mailbox_delivery_state
           SET delivered_seq_prefix = ?, updated_at_ms = ?
           WHERE task_id = ? AND actor_role = ? AND generation = ?`,
        ).run(
          delivered,
          this.now(),
          task.task_id,
          auth.row.actor_role,
          task.stream_generation,
        );
      }
      const cursorSeq =
        rows.length > 0 ? Number(rows.at(-1).stream_seq) : request.after.seq;
      return {
        ok: true,
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        task_id: task.task_id,
        status: "ok",
        task_revision: Number(task.task_revision),
        stream: {
          generation: task.stream_generation,
          head_seq: Number(task.head_seq),
          min_retained_seq: Number(task.min_retained_seq),
        },
        events: rows.map((row) => this._eventJson(row)),
        cursor: {
          generation: task.stream_generation,
          seq: cursorSeq,
        },
        delivery: {
          generation: task.stream_generation,
          delivered_seq_prefix: delivered,
        },
        ack: {
          generation: task.stream_generation,
          ack_coverage_prefix: this._coverage(task, auth.row.actor_role),
        },
        has_more: Number(task.head_seq) > cursorSeq,
      };
    }, {
      faultInjector,
      context: { operation: "pull" },
    });
  }

  ack(token, request, {
    faultInjector = this.faultInjector,
    taskId = null,
  } = {}) {
    const size = this._bodySize(request);
    if (size === null || size > 64 * 1024) {
      return this._error(
        request,
        size === null ? "schema_invalid" : "payload_too_large",
        size === null
          ? "The ack request is not JSON-safe."
          : "The ack request exceeds 64 KiB.",
      );
    }
    if (Array.isArray(request?.event_ids)) {
      if (request.event_ids.length === 0) {
        return this._error(
          request,
          "invalid_request",
          "The ack request must contain at least one event ID.",
        );
      }
      if (request.event_ids.length > 200) {
        return this._error(
          request,
          "payload_too_large",
          "The ack request contains more than 200 event IDs.",
        );
      }
    }
    const invalid = this._schemaError("ack", request);
    if (invalid) return invalid;
    return this._writeTransaction(() => {
      const auth = this._auth(token, "ack", request, taskId);
      if (auth.error) return auth.error;
      const task = auth.task;
      if (request.stream_generation !== task.stream_generation) {
        return this._error(
          request,
          "resync_required",
          "The ack generation is not current.",
          { reason: "generation_mismatch" },
        );
      }
      const delivery = this.db.prepare(
        `SELECT * FROM mailbox_delivery_state
         WHERE task_id = ? AND actor_role = ?`,
      ).get(task.task_id, auth.row.actor_role);
      const uniqueIds = [...new Set(request.event_ids)];
      const rows = [];
      for (const eventId of uniqueIds) {
        const event = this.db.prepare(
          `SELECT * FROM events
           WHERE task_id = ? AND generation = ? AND event_id = ?`,
        ).get(task.task_id, task.stream_generation, eventId);
        if (!event) {
          return this._error(
            request,
            "resync_required",
            "An ack event ID is unknown in the current generation.",
          );
        }
        if (Number(event.stream_seq) > Number(delivery.delivered_seq_prefix)) {
          return this._error(
            request,
            "ack_not_delivered",
            "The event has not been delivered to this actor.",
            {
              event_id: event.event_id,
              delivered_seq_prefix: Number(delivery.delivered_seq_prefix),
            },
          );
        }
        if (!targetIncludes(event.target_role, auth.row.actor_role)) {
          return this._error(
            request,
            "ack_not_allowed",
            "The event is not targeted to this actor role.",
          );
        }
        rows.push(event);
      }
      const acked = [];
      const alreadyAcked = [];
      for (const event of rows) {
        const exists = this.db.prepare(
          `SELECT 1 AS present FROM event_acks
           WHERE task_id = ? AND event_id = ? AND actor_role = ?`,
        ).get(task.task_id, event.event_id, auth.row.actor_role);
        if (exists) {
          alreadyAcked.push(event.event_id);
        } else {
          this.db.prepare(
            `INSERT INTO event_acks(
              task_id, event_id, actor_role, acknowledged_at_ms
            ) VALUES(?, ?, ?, ?)`,
          ).run(
            task.task_id,
            event.event_id,
            auth.row.actor_role,
            this.now(),
          );
          acked.push(event.event_id);
        }
      }
      const coverage = this._coverage(task, auth.row.actor_role);
      this.db.prepare(
        `UPDATE mailbox_delivery_state
         SET ack_coverage_prefix = ?, updated_at_ms = ?
         WHERE task_id = ? AND actor_role = ? AND generation = ?`,
      ).run(
        coverage,
        this.now(),
        task.task_id,
        auth.row.actor_role,
        task.stream_generation,
      );
      return {
        ok: true,
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        task_id: task.task_id,
        status: "acknowledged",
        acked_event_ids: acked,
        already_acked_event_ids: alreadyAcked,
        delivery: {
          generation: task.stream_generation,
          delivered_seq_prefix: Number(delivery.delivered_seq_prefix),
        },
        ack: {
          generation: task.stream_generation,
          ack_coverage_prefix: coverage,
        },
        task_revision: Number(task.task_revision),
      };
    }, {
      faultInjector,
      context: { operation: "ack" },
    });
  }

  issueConfirmation(
    controlToken,
    kind,
    targetMode,
    { taskId = null } = {},
  ) {
    return this._writeTransaction(() => {
      const action =
        kind === "user_release" ||
        kind === "trusted_shutdown" ||
        kind === "security_reset"
          ? "release_lease"
          : "claim_lease";
      const auth = this._auth(
        controlToken,
        action,
        { request_id: "request-issue-confirmation" },
        taskId,
      );
      if (auth.error) return auth.error;
      if (auth.row.kind !== "lease_control") {
        return this._error(
          { request_id: "request-issue-confirmation" },
          "action_not_allowed",
          "Lease-control authority is required.",
        );
      }
      const now = this.now();
      const confirmationId = this._id("confirmation");
      this.db.prepare(
        `INSERT INTO confirmations(
          confirmation_id, task_id, kind, target_mode, issued_at_ms,
          expires_at_ms, consumed_at_ms, consumed_operation
        ) VALUES(?, ?, ?, ?, ?, ?, NULL, NULL)`,
      ).run(
        confirmationId,
        auth.task.task_id,
        kind,
        targetMode,
        now,
        now + 5 * 60 * 1000,
      );
      return {
        ok: true,
        confirmation_id: confirmationId,
        task_id: auth.task.task_id,
        kind,
        target_mode: targetMode,
        expires_at: iso(now + 5 * 60 * 1000),
      };
    });
  }

  publish(token, request, {
    faultInjector = this.faultInjector,
    taskId = null,
  } = {}) {
    const size = this._bodySize(request);
    if (size === null || size > 256 * 1024) {
      return this._error(
        request,
        size === null ? "schema_invalid" : "payload_too_large",
        size === null
          ? "The publish request is not JSON-safe."
          : "The publish request exceeds 256 KiB.",
      );
    }
    const invalid = this._schemaError("publish", request);
    if (invalid) return invalid;
    const hash = canonicalRequestHash("publish", request);
    this._fault(
      "before_transaction",
      { operation: "publish" },
      faultInjector,
    );
    this.db.exec("BEGIN IMMEDIATE;");
    try {
      const auth = this._auth(token, "publish", request, taskId);
      if (auth.error) {
        this.db.exec("ROLLBACK;");
        return auth.error;
      }
      const existing = this._loadReceipt(
        auth.task.task_id,
        auth.row.actor_id,
        "publish",
        request.idempotency_key,
      );
      if (existing) {
        if (existing.canonical_hash !== hash) {
          this.db.exec("ROLLBACK;");
          return this._error(
            request,
            "idempotency_conflict",
            "The idempotency key was reused with a different payload.",
          );
        }
        this.db.exec("ROLLBACK;");
        return this._duplicateResponse(existing, request.request_id);
      }
      if (auth.task.mode === "suspended") {
        this.db.exec("ROLLBACK;");
        return this._error(
          request,
          "lease_conflict",
          "The Task is suspended.",
          { reason: "task_suspended" },
        );
      }
      const snapshotCheck = this._validateSnapshot(
        auth.task,
        auth.row.actor_id,
        auth.row.actor_role,
        request.expected,
        request,
      );
      if (!snapshotCheck.ok) {
        this.db.exec("ROLLBACK;");
        return snapshotCheck;
      }
      const permittedAuthority = JSON.parse(
        auth.row.permitted_authority_json,
      );
      for (const draft of request.events) {
        if (draft.execution_epoch !== Number(auth.task.fencing_epoch)) {
          this.db.exec("ROLLBACK;");
          return this._error(
            request,
            draft.execution_epoch < Number(auth.task.fencing_epoch)
              ? "stale_owner"
              : "lease_conflict",
            "The event execution epoch is not current.",
          );
        }
        if (
          draft.authority === "execution_result" &&
          auth.task.owner_role !== auth.row.actor_role
        ) {
          this.db.exec("ROLLBACK;");
          return this._error(
            request,
            "lease_conflict",
            "The actor is not the current execution owner.",
          );
        }
        if (!permittedAuthority.includes(draft.authority)) {
          this.db.exec("ROLLBACK;");
          return this._error(
            request,
            "action_not_allowed",
            "The actor capability does not permit this event authority.",
          );
        }
      }
      const snapshotCount = Number(this.db.prepare(
        `SELECT COUNT(*) AS count FROM mailbox_snapshots
         WHERE task_id = ? AND actor_id = ?
           AND invalidated_at_ms IS NULL AND expires_at_ms > ?`,
      ).get(auth.task.task_id, auth.row.actor_id, this.now()).count);
      if (snapshotCount >= this.maxSnapshotsPerActor) {
        this.db.exec("ROLLBACK;");
        return this._error(
          request,
          "snapshot_capacity_exceeded",
          "The post-publish snapshot cap was reached.",
        );
      }

      const now = this.now();
      const mutationId = this._id("mutation");
      this.db.prepare(
        `INSERT INTO mutations(
          mutation_id, task_id, operation, actor_id, idempotency_key,
          committed_at_ms, outcome
        ) VALUES(?, ?, 'publish', ?, ?, ?, 'applied')`,
      ).run(
        mutationId,
        auth.task.task_id,
        auth.row.actor_id,
        request.idempotency_key,
        now,
      );
      const committedEvents = [];
      let nextSeq = Number(auth.task.head_seq);
      for (const draft of request.events) {
        nextSeq += 1;
        const event = {
          event_id: this._id("event"),
          task_id: auth.task.task_id,
          generation: auth.task.stream_generation,
          stream_seq: nextSeq,
          kind: draft.kind,
          authority: draft.authority,
          author_role: auth.row.actor_role,
          target_role: draft.target_role,
          execution_epoch: draft.execution_epoch,
          origin_json: JSON.stringify({
            ...draft.origin,
            client_event_id: draft.client_event_id,
          }),
          payload_json: JSON.stringify(draft.payload),
          payload_sha256: payloadHash(draft.payload),
          mutation_id: mutationId,
          created_at_ms: now,
        };
        this.db.prepare(
          `INSERT INTO events(
            event_id, task_id, generation, stream_seq, kind, authority,
            author_role, target_role, execution_epoch, origin_json,
            payload_json, payload_sha256, mutation_id, created_at_ms
          ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        ).run(
          event.event_id,
          event.task_id,
          event.generation,
          event.stream_seq,
          event.kind,
          event.authority,
          event.author_role,
          event.target_role,
          event.execution_epoch,
          event.origin_json,
          event.payload_json,
          event.payload_sha256,
          event.mutation_id,
          event.created_at_ms,
        );
        if (targetIncludes(event.target_role, auth.row.actor_role)) {
          this.db.prepare(
            `INSERT INTO event_acks(
              task_id, event_id, actor_role, acknowledged_at_ms
            ) VALUES(?, ?, ?, ?)`,
          ).run(
            event.task_id,
            event.event_id,
            auth.row.actor_role,
            now,
          );
        }
        committedEvents.push(event);
      }
      const nextRevision = Number(auth.task.task_revision) + 1;
      const updated = this.db.prepare(
        `UPDATE tasks
         SET task_revision = ?, head_seq = ?, updated_at_ms = ?
         WHERE task_id = ? AND task_revision = ? AND fencing_epoch = ?
           AND stream_generation = ? AND mode = ?`,
      ).run(
        nextRevision,
        nextSeq,
        now,
        auth.task.task_id,
        Number(auth.task.task_revision),
        Number(auth.task.fencing_epoch),
        auth.task.stream_generation,
        auth.task.mode,
      );
      if (Number(updated.changes) !== 1) {
        throw new Error("Task CAS failed");
      }
      const coverage = this._coverage(auth.task, auth.row.actor_role);
      this.db.prepare(
        `UPDATE mailbox_delivery_state
         SET ack_coverage_prefix = ?, updated_at_ms = ?
         WHERE task_id = ? AND actor_role = ? AND generation = ?`,
      ).run(
        coverage,
        now,
        auth.task.task_id,
        auth.row.actor_role,
        auth.task.stream_generation,
      );
      const refreshedTask = this._taskRow(auth.task.task_id);
      const nextCreated = this._createSnapshotRow(
        refreshedTask,
        auth.row.actor_role,
        auth.row.actor_id,
        false,
      );
      if (!nextCreated) {
        throw new Error("post-publish snapshot creation failed");
      }
      const nextSnapshot = {
        snapshot_id: nextCreated.snapshot.snapshot_id,
        snapshot_seq: Number(nextCreated.snapshot.snapshot_seq),
        task_revision: Number(nextCreated.snapshot.task_revision),
        expires_at: iso(Number(nextCreated.snapshot.expires_at_ms)),
      };
      const eventReceipts = committedEvents.map((event) => ({
        event_id: event.event_id,
        client_event_id: JSON.parse(event.origin_json).client_event_id,
        stream_seq: event.stream_seq,
        created_at: iso(event.created_at_ms),
      }));
      const response = {
        ok: true,
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        task_id: auth.task.task_id,
        status: "applied",
        receipt: {
          idempotency_key: request.idempotency_key,
          outcome: "applied",
          committed_at: iso(now),
        },
        task_revision: nextRevision,
        stream: {
          generation: auth.task.stream_generation,
          head_seq: nextSeq,
        },
        events: eventReceipts,
        next_snapshot: nextSnapshot,
      };
      this.db.prepare(
        `INSERT INTO idempotency_receipts(
          receipt_id, mutation_id, task_id, actor_id, actor_role, operation,
          idempotency_key, canonical_hash_alg, canonical_hash,
          original_request_id, outcome, response_json, event_receipts_json,
          next_snapshot_json, task_revision, stream_generation, head_seq,
          committed_at_ms
        ) VALUES(?, ?, ?, ?, ?, 'publish', ?, 'sha256', ?, ?, 'applied',
          ?, ?, ?, ?, ?, ?, ?)`,
      ).run(
        this._id("receipt"),
        mutationId,
        auth.task.task_id,
        auth.row.actor_id,
        auth.row.actor_role,
        request.idempotency_key,
        hash,
        request.request_id,
        JSON.stringify(response),
        JSON.stringify(eventReceipts),
        JSON.stringify(nextSnapshot),
        nextRevision,
        auth.task.stream_generation,
        nextSeq,
        now,
      );
      this._fault(
        "before_commit",
        { operation: "publish", mutationId },
        faultInjector,
      );
      this.db.exec("COMMIT;");
      this._fault(
        "after_commit_before_response",
        { operation: "publish", mutationId },
        faultInjector,
      );
      return response;
    } catch (error) {
      try {
        this.db.exec("ROLLBACK;");
      } catch {
        // COMMIT may already have happened before an injected response fault.
      }
      throw error;
    }
  }

  claimLease(token, request, {
    faultInjector = this.faultInjector,
    taskId = null,
  } = {}) {
    const size = this._bodySize(request);
    if (size === null || size > 64 * 1024) {
      return this._error(
        request,
        size === null ? "schema_invalid" : "payload_too_large",
        size === null
          ? "The claim request is not JSON-safe."
          : "The claim request exceeds 64 KiB.",
      );
    }
    const invalid = this._schemaError("claim_lease", request);
    if (invalid) return invalid;
    const hash = canonicalRequestHash("claim_lease", request);
    const transactionResult = this._writeTransaction(() => {
      const auth = this._auth(token, "claim_lease", request, taskId);
      if (auth.error) return { response: auth.error, tokens: null };
      const existing = this._loadReceipt(
        auth.task.task_id,
        auth.row.actor_id,
        "claim_lease",
        request.idempotency_key,
      );
      if (existing) {
        if (existing.canonical_hash !== hash) {
          return {
            response: this._error(
              request,
              "idempotency_conflict",
              "The idempotency key was reused with a different payload.",
            ),
            tokens: null,
          };
        }
        return {
          response: this._duplicateResponse(existing, request.request_id),
          tokens: null,
        };
      }
      const task = auth.task;
      if (
        request.expected.execution_epoch !== Number(task.fencing_epoch) ||
        request.expected.task_revision !== Number(task.task_revision) ||
        request.target_mode === task.mode
      ) {
        return {
          response: this._error(
            request,
            "lease_conflict",
            "The expected ownership transition is not current.",
          ),
          tokens: null,
        };
      }
      const checkpoint = this.db.prepare(
        "SELECT * FROM mailbox_checkpoints WHERE checkpoint_id = ?",
      ).get(request.expected.checkpoint_id);
      if (
        !checkpoint ||
        checkpoint.consumed_at_ms !== null ||
        this.now() >= Number(checkpoint.expires_at_ms) ||
        checkpoint.task_id !== task.task_id ||
        checkpoint.generation !== task.stream_generation ||
        Number(checkpoint.task_revision) !== Number(task.task_revision) ||
        Number(checkpoint.fencing_epoch) !== Number(task.fencing_epoch)
      ) {
        return {
          response: this._error(
            request,
            "checkpoint_required",
            "A current checkpoint is required.",
          ),
          tokens: null,
        };
      }
      const sourceCoverage = this._coverage(task, "source");
      const panelCoverage = this._coverage(task, "panel");
      if (
        sourceCoverage < Number(checkpoint.required_coverage_prefix) ||
        panelCoverage < Number(checkpoint.required_coverage_prefix)
      ) {
        return {
          response: this._error(
            request,
            "checkpoint_incomplete",
            "Source or panel acknowledgement coverage is incomplete.",
            {
              required: Number(checkpoint.required_coverage_prefix),
              source: sourceCoverage,
              panel: panelCoverage,
            },
          ),
          tokens: null,
        };
      }
      const confirmation = this.db.prepare(
        "SELECT * FROM confirmations WHERE confirmation_id = ?",
      ).get(request.user_confirmation_id);
      if (!confirmation) {
        return {
          response: this._error(
            request,
            "confirmation_required",
            "A valid confirmation is required.",
          ),
          tokens: null,
        };
      }
      if (
        confirmation.task_id !== task.task_id ||
        confirmation.kind !== "claim_switch" ||
        confirmation.target_mode !== request.target_mode
      ) {
        return {
          response: this._error(
            request,
            "confirmation_invalid",
            "The confirmation is bound to another Task, mode, or purpose.",
          ),
          tokens: null,
        };
      }
      if (this.now() >= Number(confirmation.expires_at_ms)) {
        return {
          response: this._error(
            request,
            "confirmation_expired",
            "The confirmation expired.",
          ),
          tokens: null,
        };
      }
      if (confirmation.consumed_at_ms !== null) {
        return {
          response: this._error(
            request,
            "confirmation_consumed",
            "The confirmation was already consumed.",
          ),
          tokens: null,
        };
      }

      const now = this.now();
      const nextEpoch = Number(task.fencing_epoch) + 1;
      const nextRevision = Number(task.task_revision) + 1;
      const nextHead = Number(task.head_seq) + 1;
      const nextOwner = ownerForMode(request.target_mode);
      const nextLeaseId = this._id("lease");
      const mutationId = this._id("mutation");
      this.db.prepare(
        `INSERT INTO mutations(
          mutation_id, task_id, operation, actor_id, idempotency_key,
          committed_at_ms, outcome
        ) VALUES(?, ?, 'claim_lease', ?, ?, ?, 'applied')`,
      ).run(
        mutationId,
        task.task_id,
        auth.row.actor_id,
        request.idempotency_key,
        now,
      );
      const updated = this.db.prepare(
        `UPDATE tasks
         SET mode = ?, owner_role = ?, lease_id = ?, fencing_epoch = ?,
             task_revision = ?, head_seq = ?, updated_at_ms = ?
         WHERE task_id = ? AND task_revision = ? AND fencing_epoch = ?
           AND mode = ?`,
      ).run(
        request.target_mode,
        nextOwner,
        nextLeaseId,
        nextEpoch,
        nextRevision,
        nextHead,
        now,
        task.task_id,
        Number(task.task_revision),
        Number(task.fencing_epoch),
        task.mode,
      );
      if (Number(updated.changes) !== 1) throw new Error("Task CAS failed");
      const transitionEventId = this._id("event");
      const transitionOrigin = {
        session_ref: null,
        turn_id: null,
        item_id: null,
        client_event_id: this._id("owner-switch"),
      };
      this.db.prepare(
        `INSERT INTO events(
          event_id, task_id, generation, stream_seq, kind, authority,
          author_role, target_role, execution_epoch, origin_json,
          payload_json, payload_sha256, mutation_id, created_at_ms
        ) VALUES(?, ?, ?, ?, 'owner.switched', 'owner_transition',
          'coordinator', 'both', ?, ?, '{}', ?, ?, ?)`,
      ).run(
        transitionEventId,
        task.task_id,
        task.stream_generation,
        nextHead,
        nextEpoch,
        JSON.stringify(transitionOrigin),
        payloadHash({}),
        mutationId,
        now,
      );
      this.db.prepare(
        `INSERT INTO owner_transitions(
          transition_id, task_id, from_mode, from_owner, from_epoch,
          to_mode, to_owner, to_epoch, checkpoint_id, confirmation_id,
          checkpoint_generation, checkpoint_snapshot_seq, confirmation_kind,
          confirmation_target_mode, transition_event_id, mutation_id,
          created_at_ms
        ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).run(
        this._id("transition"),
        task.task_id,
        task.mode,
        task.owner_role,
        Number(task.fencing_epoch),
        request.target_mode,
        nextOwner,
        nextEpoch,
        checkpoint.checkpoint_id,
        confirmation.confirmation_id,
        checkpoint.generation,
        Number(checkpoint.snapshot_seq),
        confirmation.kind,
        confirmation.target_mode,
        transitionEventId,
        mutationId,
        now,
      );
      this.db.prepare(
        `UPDATE mailbox_snapshots SET invalidated_at_ms = ?
         WHERE task_id = ? AND invalidated_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `UPDATE mailbox_checkpoints SET consumed_at_ms = ?
         WHERE task_id = ? AND consumed_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `UPDATE confirmations
         SET consumed_at_ms = ?, consumed_operation = 'claim_lease'
         WHERE confirmation_id = ? AND consumed_at_ms IS NULL`,
      ).run(now, confirmation.confirmation_id);
      this.db.prepare(
        `UPDATE authority_verifiers
         SET revoked_at_ms = ?, revoked_reason = 'owner_switched'
         WHERE task_id = ? AND revoked_at_ms IS NULL`,
      ).run(now, task.task_id);
      const nextTask = {
        ...task,
        mode: request.target_mode,
        owner_role: nextOwner,
        lease_id: nextLeaseId,
        fencing_epoch: nextEpoch,
        task_revision: nextRevision,
        head_seq: nextHead,
      };
      const rotationGeneration = Number(auth.row.rotation_generation) + 1;
      const tokens = this._issueVerifierSet(
        nextTask,
        rotationGeneration,
        now,
      );
      const response = {
        ok: true,
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        task_id: task.task_id,
        status: "applied",
        task_revision: nextRevision,
        stream: {
          generation: task.stream_generation,
          head_seq: nextHead,
        },
        execution: {
          mode: request.target_mode,
          owner: nextOwner,
          lease_id: nextLeaseId,
          fencing_epoch: nextEpoch,
        },
        capability_rotation_required: true,
        transition_event_id: transitionEventId,
        transition_stream_seq: nextHead,
      };
      this._insertReceipt({
        mutationId,
        task: nextTask,
        actorId: auth.row.actor_id,
        actorRole: "control",
        operation: "claim_lease",
        request,
        hash,
        response,
        committedAtMs: now,
      });
      return { response, tokens };
    }, {
      faultInjector,
      context: { operation: "claim_lease" },
    });
    if (transactionResult.tokens) {
      this.issuedCapabilities.set(
        transactionResult.response.task_id,
        transactionResult.tokens,
      );
    }
    return transactionResult.response;
  }

  releaseLease(token, request, {
    faultInjector = this.faultInjector,
    taskId = null,
  } = {}) {
    const size = this._bodySize(request);
    if (size === null || size > 64 * 1024) {
      return this._error(
        request,
        size === null ? "schema_invalid" : "payload_too_large",
        size === null
          ? "The release request is not JSON-safe."
          : "The release request exceeds 64 KiB.",
      );
    }
    const invalid = this._schemaError("release_lease", request);
    if (invalid) return invalid;
    const hash = canonicalRequestHash("release_lease", request);
    const transactionResult = this._writeTransaction(() => {
      const auth = this._auth(token, "release_lease", request, taskId);
      if (auth.error) return { response: auth.error, tokens: null };
      const existing = this._loadReceipt(
        auth.task.task_id,
        auth.row.actor_id,
        "release_lease",
        request.idempotency_key,
      );
      if (existing) {
        if (existing.canonical_hash !== hash) {
          return {
            response: this._error(
              request,
              "idempotency_conflict",
              "The idempotency key was reused with a different payload.",
            ),
            tokens: null,
          };
        }
        return {
          response: this._duplicateResponse(existing, request.request_id),
          tokens: null,
        };
      }
      const task = auth.task;
      if (task.mode === "suspended") {
        return {
          response: this._error(
            request,
            "lease_conflict",
            "The Task is already suspended.",
            { reason: "task_already_suspended" },
          ),
          tokens: null,
        };
      }
      if (
        request.expected.execution_epoch !== Number(task.fencing_epoch) ||
        request.expected.task_revision !== Number(task.task_revision)
      ) {
        return {
          response: this._error(
            request,
            "lease_conflict",
            "The expected release epoch or revision is stale.",
          ),
          tokens: null,
        };
      }
      const confirmation = this.db.prepare(
        "SELECT * FROM confirmations WHERE confirmation_id = ?",
      ).get(request.user_confirmation_id);
      if (!confirmation) {
        return {
          response: this._error(
            request,
            "confirmation_required",
            "A valid confirmation is required.",
          ),
          tokens: null,
        };
      }
      if (
        confirmation.task_id !== task.task_id ||
        confirmation.kind !== request.confirmation_kind ||
        confirmation.target_mode !== "suspended"
      ) {
        return {
          response: this._error(
            request,
            "confirmation_invalid",
            "The confirmation is bound to another Task, mode, or purpose.",
          ),
          tokens: null,
        };
      }
      if (this.now() >= Number(confirmation.expires_at_ms)) {
        return {
          response: this._error(
            request,
            "confirmation_expired",
            "The confirmation expired.",
          ),
          tokens: null,
        };
      }
      if (confirmation.consumed_at_ms !== null) {
        return {
          response: this._error(
            request,
            "confirmation_consumed",
            "The confirmation was already consumed.",
          ),
          tokens: null,
        };
      }

      const now = this.now();
      const nextEpoch = Number(task.fencing_epoch) + 1;
      const nextRevision = Number(task.task_revision) + 1;
      const nextHead = Number(task.head_seq) + 1;
      const mutationId = this._id("mutation");
      this.db.prepare(
        `INSERT INTO mutations(
          mutation_id, task_id, operation, actor_id, idempotency_key,
          committed_at_ms, outcome
        ) VALUES(?, ?, 'release_lease', ?, ?, ?, 'applied')`,
      ).run(
        mutationId,
        task.task_id,
        auth.row.actor_id,
        request.idempotency_key,
        now,
      );
      const updated = this.db.prepare(
        `UPDATE tasks
         SET mode = 'suspended', owner_role = 'none', lease_id = NULL,
             fencing_epoch = ?, task_revision = ?, head_seq = ?,
             updated_at_ms = ?
         WHERE task_id = ? AND task_revision = ? AND fencing_epoch = ?
           AND mode = ?`,
      ).run(
        nextEpoch,
        nextRevision,
        nextHead,
        now,
        task.task_id,
        Number(task.task_revision),
        Number(task.fencing_epoch),
        task.mode,
      );
      if (Number(updated.changes) !== 1) throw new Error("Task CAS failed");
      const transitionEventId = this._id("event");
      this.db.prepare(
        `INSERT INTO events(
          event_id, task_id, generation, stream_seq, kind, authority,
          author_role, target_role, execution_epoch, origin_json,
          payload_json, payload_sha256, mutation_id, created_at_ms
        ) VALUES(?, ?, ?, ?, 'owner.released', 'owner_transition',
          'coordinator', 'both', ?, ?, '{}', ?, ?, ?)`,
      ).run(
        transitionEventId,
        task.task_id,
        task.stream_generation,
        nextHead,
        nextEpoch,
        JSON.stringify({
          session_ref: null,
          turn_id: null,
          item_id: null,
          client_event_id: this._id("owner-release"),
        }),
        payloadHash({}),
        mutationId,
        now,
      );
      this.db.prepare(
        `INSERT INTO owner_transitions(
          transition_id, task_id, from_mode, from_owner, from_epoch,
          to_mode, to_owner, to_epoch, checkpoint_id, confirmation_id,
          checkpoint_generation, checkpoint_snapshot_seq, confirmation_kind,
          confirmation_target_mode, transition_event_id, mutation_id,
          created_at_ms
        ) VALUES(?, ?, ?, ?, ?, 'suspended', 'none', ?, NULL, ?, NULL, NULL,
          ?, 'suspended', ?, ?, ?)`,
      ).run(
        this._id("transition"),
        task.task_id,
        task.mode,
        task.owner_role,
        Number(task.fencing_epoch),
        nextEpoch,
        confirmation.confirmation_id,
        confirmation.kind,
        transitionEventId,
        mutationId,
        now,
      );
      this.db.prepare(
        `UPDATE mailbox_snapshots SET invalidated_at_ms = ?
         WHERE task_id = ? AND invalidated_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `UPDATE mailbox_checkpoints SET consumed_at_ms = ?
         WHERE task_id = ? AND consumed_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `UPDATE confirmations
         SET consumed_at_ms = ?, consumed_operation = 'release_lease'
         WHERE confirmation_id = ? AND consumed_at_ms IS NULL`,
      ).run(now, confirmation.confirmation_id);
      this.db.prepare(
        `UPDATE authority_verifiers
         SET revoked_at_ms = ?, revoked_reason = 'task_suspended'
         WHERE task_id = ? AND revoked_at_ms IS NULL`,
      ).run(now, task.task_id);
      const nextTask = {
        ...task,
        mode: "suspended",
        owner_role: "none",
        lease_id: null,
        fencing_epoch: nextEpoch,
        task_revision: nextRevision,
        head_seq: nextHead,
      };
      const rotationGeneration = Number(auth.row.rotation_generation) + 1;
      const tokens = this._issueVerifierSet(
        nextTask,
        rotationGeneration,
        now,
      );
      const response = {
        ok: true,
        schema_version: SCHEMA_VERSION,
        request_id: request.request_id,
        task_id: task.task_id,
        status: "applied",
        task_revision: nextRevision,
        stream: {
          generation: task.stream_generation,
          head_seq: nextHead,
        },
        execution: {
          mode: "suspended",
          owner: "none",
          lease_id: null,
          fencing_epoch: nextEpoch,
        },
        capability_rotation_required: true,
        transition_event_id: transitionEventId,
        transition_stream_seq: nextHead,
      };
      this._insertReceipt({
        mutationId,
        task: nextTask,
        actorId: auth.row.actor_id,
        actorRole: "control",
        operation: "release_lease",
        request,
        hash,
        response,
        committedAtMs: now,
      });
      return { response, tokens };
    }, {
      faultInjector,
      context: { operation: "release_lease" },
    });
    if (transactionResult.tokens) {
      this.issuedCapabilities.set(
        transactionResult.response.task_id,
        transactionResult.tokens,
      );
    }
    return transactionResult.response;
  }

  resetGeneration(
    controlToken,
    {
      faultInjector = this.faultInjector,
      taskId = null,
    } = {},
  ) {
    return this._begin(() => {
      // generation reset is an internal control operation; the dedicated
      // lease-control capability authenticates it without exposing a new
      // mailbox action.
      const auth = this._auth(
        controlToken,
        "claim_lease",
        { request_id: "request-generation-reset" },
        taskId,
      );
      if (auth.error) return auth.error;
      if (auth.row.kind !== "lease_control") {
        return this._error(
          { request_id: "request-generation-reset" },
          "action_not_allowed",
          "Lease-control authority is required.",
        );
      }
      const task = auth.task;
      const now = this.now();
      const mutationId = this._id("mutation");
      const nextGeneration = this._id("stream");
      this.db.prepare(
        `INSERT INTO stream_generations(
          task_id, generation, created_at_ms, retired_at_ms, reason
        ) VALUES(?, ?, ?, NULL, NULL)`,
      ).run(task.task_id, nextGeneration, now);
      this.db.prepare(
        `UPDATE tasks
         SET stream_generation = ?, head_seq = 0, min_retained_seq = 1,
             task_revision = task_revision + 1, updated_at_ms = ?
         WHERE task_id = ? AND stream_generation = ?`,
      ).run(nextGeneration, now, task.task_id, task.stream_generation);
      for (const role of ["source", "panel"]) {
        this.db.prepare(
          `UPDATE mailbox_delivery_state
           SET generation = ?, delivered_seq_prefix = 0,
               ack_coverage_prefix = 0, updated_at_ms = ?
           WHERE task_id = ? AND actor_role = ?`,
        ).run(nextGeneration, now, task.task_id, role);
      }
      this.db.prepare(
        `UPDATE mailbox_snapshots
         SET invalidated_at_ms = ?
         WHERE task_id = ? AND invalidated_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `UPDATE mailbox_checkpoints
         SET consumed_at_ms = ?
         WHERE task_id = ? AND consumed_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `INSERT INTO mutations(
          mutation_id, task_id, operation, actor_id, idempotency_key,
          committed_at_ms, outcome
        ) VALUES(?, ?, 'generation_reset', ?, NULL, ?, 'applied')`,
      ).run(mutationId, task.task_id, auth.row.actor_id, now);
      this.db.prepare(
        `UPDATE authority_verifiers
         SET revoked_at_ms = ?, revoked_reason = 'generation_reset'
         WHERE task_id = ? AND revoked_at_ms IS NULL`,
      ).run(now, task.task_id);
      this.db.prepare(
        `UPDATE stream_generations
         SET retired_at_ms = ?, reason = 'generation_reset'
         WHERE task_id = ? AND generation = ?`,
      ).run(now, task.task_id, task.stream_generation);

      const nextTask = {
        ...task,
        stream_generation: nextGeneration,
        head_seq: 0,
        min_retained_seq: 1,
        task_revision: Number(task.task_revision) + 1,
      };
      const sourceToken = this._token("sth");
      const panelToken = this._token("sth");
      const controlTokenNext = this._token("ctl");
      const rotationGeneration = Number(auth.row.rotation_generation) + 1;
      this._insertVerifier({
        token: sourceToken,
        kind: "mailbox",
        task: nextTask,
        actorId: "actor-source-sqlite",
        actorRole: "source",
        profile: "standard",
        permittedAuthority: ["surface_input", "execution_result", "note"],
        rotationGeneration,
        issuedAt: now,
        expiresAt: now + this.handleTtlMs,
      });
      this._insertVerifier({
        token: panelToken,
        kind: "mailbox",
        task: nextTask,
        actorId: "actor-panel-sqlite",
        actorRole: "panel",
        profile: "standard",
        permittedAuthority: ["surface_input", "note"],
        rotationGeneration,
        issuedAt: now,
        expiresAt: now + this.handleTtlMs,
      });
      this._insertVerifier({
        token: controlTokenNext,
        kind: "lease_control",
        task: nextTask,
        actorId: "actor-control-sqlite",
        actorRole: null,
        profile: null,
        permittedAuthority: [],
        rotationGeneration,
        issuedAt: now,
        expiresAt: now + this.handleTtlMs,
      });
      this._assertGenerationInvariant(task.task_id);
      this._fault(
        "before_commit",
        { operation: "generation_reset", mutationId },
        faultInjector,
      );
      return {
        task_id: task.task_id,
        previous_generation: task.stream_generation,
        stream_generation: nextGeneration,
        task_revision: Number(task.task_revision) + 1,
        mutation_id: mutationId,
        tokens: {
          source: sourceToken,
          panel: panelToken,
          control: controlTokenNext,
        },
      };
    });
  }

  inspectIntegrity() {
    return {
      integrity: this.db.prepare("PRAGMA integrity_check").all(),
      foreign_keys: this.db.prepare("PRAGMA foreign_key_check").all(),
    };
  }

  fixtureSnapshot(taskId = null) {
    const task = this._taskRow(taskId);
    return {
      task: task ? this._taskState(task) : null,
      delivery_ack_state: task ? this._deliveryAckState(task) : null,
      counts: {
        events: Number(this.db.prepare("SELECT COUNT(*) AS count FROM events").get().count),
        receipts: Number(this.db.prepare("SELECT COUNT(*) AS count FROM idempotency_receipts").get().count),
        mutations: Number(this.db.prepare("SELECT COUNT(*) AS count FROM mutations").get().count),
        snapshots: Number(this.db.prepare("SELECT COUNT(*) AS count FROM mailbox_snapshots").get().count),
      },
      integrity: this.inspectIntegrity(),
    };
  }
}

export function openSqliteConformanceCoordinator(options) {
  return new SqliteConformanceCoordinator(options);
}
