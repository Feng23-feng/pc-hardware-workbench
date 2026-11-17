import { createHash, randomUUID } from "node:crypto";
import { canonicalRequestHash } from "./canonical-hash.mjs";
import { createContractValidator } from "./contract-validator.mjs";
import { errorResult } from "./error-codes.mjs";

export const CONTRACT = "source_hosted-shared-task-v1";
export const SCHEMA_VERSION = "1.0";

export const PROFILE_ACTIONS = Object.freeze({
  standard: Object.freeze(["snapshot", "pull", "publish", "ack"]),
  recovery: Object.freeze(["snapshot", "pull"]),
  recovery_ack: Object.freeze(["snapshot", "pull", "ack"]),
});

const OPERATION_VALIDATORS = Object.freeze({
  snapshot: "snapshot",
  pull: "pull",
  publish: "publish",
  ack: "ack",
  claim_lease: "claimLease",
  release_lease: "releaseLease",
});

const OWNER_EVENT_KINDS = new Set([
  "owner.claimed",
  "owner.released",
  "owner.switched",
]);

const EVENT_MATRIX = Object.freeze({
  "intent.user_action": {
    authorities: ["surface_input"],
    authorRoles: ["source", "panel"],
    targetRoles: ["source", "both"],
  },
  "intent.analysis_request": {
    authorities: ["surface_input"],
    authorRoles: ["panel"],
    targetRoles: ["source"],
  },
  "evidence.added": {
    authorities: ["surface_input"],
    authorRoles: ["source", "panel"],
    targetRoles: ["source", "panel", "both"],
  },
  "artifact.reference": {
    authorities: ["surface_input", "note"],
    authorRoles: ["panel"],
    targetRoles: ["source", "panel", "both"],
  },
  "agent.result": {
    authorities: ["execution_result"],
    authorRoles: ["source", "panel"],
    targetRoles: ["panel", "both"],
  },
  "decision.proposal": {
    authorities: ["surface_input", "note"],
    authorRoles: ["source", "panel"],
    targetRoles: ["source", "panel", "both"],
  },
  "decision.accepted": {
    authorities: ["execution_result"],
    authorRoles: ["source", "panel"],
    targetRoles: ["panel", "both"],
  },
  note: {
    authorities: ["note"],
    authorRoles: ["source", "panel"],
    targetRoles: ["source", "panel", "both"],
  },
});

function iso(ms) {
  return new Date(ms).toISOString();
}

function clone(value) {
  return structuredClone(value);
}

function includesTarget(event, role) {
  return (
    event.target_role === role ||
    event.target_role === "both"
  );
}

function ownerForMode(mode) {
  if (mode === "source_hosted") return "source";
  if (mode === "panel_hosted") return "panel";
  return "none";
}

function actorIdForRole(role) {
  if (role === "source") return "actor-source-fixture";
  if (role === "panel") return "actor-panel-fixture";
  return "actor-control-fixture";
}

function verifier(token) {
  return createHash("sha256").update(String(token), "utf8").digest("hex");
}

function safeRequestId(value) {
  return typeof value === "string" &&
    /^[A-Za-z0-9][A-Za-z0-9._:-]{7,127}$/u.test(value)
    ? value
    : "request-invalid";
}

function schemaDetails(result) {
  return {
    errors: result.errors.slice(0, 20).map((item) => ({
      instancePath: item.instancePath,
      keyword: item.keyword,
      message: item.message,
    })),
  };
}

function containsUnsafePayload(value, path = "$", seen = new Set()) {
  if (typeof value === "string") {
    return (
      /<script\b|<\/script\s*>|onerror\s*=/iu.test(value) ||
      /(?:^|[^A-Za-z])[A-Za-z]:[\\/]/u.test(value) ||
      /\/(?:Users|home|var|etc|private|tmp)\//u.test(value) ||
      /\bsth_[A-Za-z0-9_-]{8,}/u.test(value)
    );
  }
  if (value === null || typeof value !== "object") {
    return false;
  }
  if (seen.has(value)) {
    return true;
  }
  seen.add(value);
  try {
    if (Array.isArray(value)) {
      return value.some((item, index) =>
        containsUnsafePayload(item, `${path}[${index}]`, seen));
    }
    return Object.entries(value).some(([key, item]) =>
      containsUnsafePayload(item, `${path}.${key}`, seen));
  } finally {
    seen.delete(value);
  }
}

function eventMatrixViolation(event, authorRole) {
  const rule = EVENT_MATRIX[event.kind];
  if (
    !rule ||
    !rule.authorities.includes(event.authority) ||
    !rule.authorRoles.includes(authorRole) ||
    !rule.targetRoles.includes(event.target_role)
  ) {
    return {
      reason: "kind_authority_target_mismatch",
      kind: event.kind,
      authority: event.authority,
      author_role: authorRole,
      target_role: event.target_role,
    };
  }
  return null;
}

export class ReferenceCoordinator {
  constructor({
    now = () => Date.now(),
    uuid = randomUUID,
    validator = createContractValidator(),
    snapshotTtlMs = 10 * 60 * 1000,
    checkpointTtlMs = 5 * 60 * 1000,
    confirmationTtlMs = 5 * 60 * 1000,
    handleTtlMs = 30 * 60 * 1000,
    maxSnapshotsPerActor = 64,
    maxAckIds = 200,
    maxAckBytes = 64 * 1024,
    maxPublishBytes = 256 * 1024,
    maxEventPayloadBytes = 64 * 1024,
    onCapabilityIssued = () => {},
  } = {}) {
    this.now = now;
    this.uuid = uuid;
    this.validator = validator;
    this.snapshotTtlMs = snapshotTtlMs;
    this.checkpointTtlMs = checkpointTtlMs;
    this.confirmationTtlMs = confirmationTtlMs;
    this.handleTtlMs = handleTtlMs;
    this.maxSnapshotsPerActor = maxSnapshotsPerActor;
    this.maxAckIds = maxAckIds;
    this.maxAckBytes = maxAckBytes;
    this.maxPublishBytes = maxPublishBytes;
    this.maxEventPayloadBytes = maxEventPayloadBytes;
    this.onCapabilityIssued = onCapabilityIssued;

    this.taskId = "task-fixture-01";
    this.channelId = "chat:fixture:task-fixture-01";
    this.workspaceId = "workspace-fixture-01";
    this.sourceActorId = actorIdForRole("source");
    this.panelActorId = actorIdForRole("panel");
    this.controlActorId = actorIdForRole("control");
    this.rotationGeneration = 1;

    this.task = {
      mode: "source_hosted",
      owner: "source",
      leaseId: `lease-${uuid()}`,
      epoch: 1,
      revision: 1,
      generation: `stream-${uuid()}`,
      headSeq: 0,
      minRetainedSeq: 1,
      objective: "Synthetic source_hosted conformance Task",
      state: {},
      events: [],
    };

    this.actors = {
      source: {
        actorId: this.sourceActorId,
        deliveredSeq: 0,
        acknowledged: new Set(),
      },
      panel: {
        actorId: this.panelActorId,
        deliveredSeq: 0,
        acknowledged: new Set(),
      },
    };
    this.authorities = new Map();
    this.snapshots = new Map();
    this.checkpoints = new Map();
    this.confirmations = new Map();
    this.idempotency = new Map();
    this.receipts = new Map();
    this._rotateMailboxHandles();
    this._issueLeaseControl();
  }

  _id(prefix) {
    return `${prefix}-${this.uuid()}`;
  }

  _requestId(request) {
    return safeRequestId(request?.request_id);
  }

  _error(request, code, message, details = {}) {
    return errorResult({
      requestId: this._requestId(request),
      taskId: this.taskId,
      code,
      message,
      details,
    });
  }

  _validateRequest(operation, request) {
    const schemaName = OPERATION_VALIDATORS[operation];
    const result = this.validator.validateRequest(schemaName, request);
    if (result.valid) return null;
    return this._error(
      request,
      "schema_invalid",
      "The request does not match the source_hosted-shared-task-v1 schema.",
      schemaDetails(result),
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

  _issueMailboxHandle(role, profile) {
    const actions = PROFILE_ACTIONS[profile];
    const owner = ownerForMode(this.task.mode);
    const permittedAuthority =
      profile === "standard"
        ? [
            "surface_input",
            ...(owner === role ? ["execution_result"] : []),
            "note",
          ]
        : [];
    const issuedAt = this.now();
    const handleId = this._id("handle");
    const token = `sth_${this.uuid().replaceAll("-", "")}`;
    const metadata = {
      handle_id: handleId,
      contract: CONTRACT,
      audience: "skilldock-task-mailbox",
      actor_id: actorIdForRole(role),
      actor_role: role,
      mailbox_profile: profile,
      workspace_id: this.workspaceId,
      task_id: this.taskId,
      channel_id: this.channelId,
      execution_epoch: this.task.epoch,
      allowed_actions: [...actions],
      permitted_authority: permittedAuthority,
      issued_at: iso(issuedAt),
      expires_at: iso(issuedAt + this.handleTtlMs),
      rotation_generation: this.rotationGeneration,
    };
    this.authorities.set(verifier(token), {
      kind: "mailbox",
      metadata,
      expiresAt: issuedAt + this.handleTtlMs,
      revoked: null,
    });
    this.onCapabilityIssued({
      kind: "mailbox",
      token,
      metadata: clone(metadata),
    });
    return { token, metadata };
  }

  _issueLeaseControl() {
    const issuedAt = this.now();
    const handleId = this._id("control");
    const token = `ctl_${this.uuid().replaceAll("-", "")}`;
    const metadata = {
      handle_id: handleId,
      contract: CONTRACT,
      audience: "skilldock-lease-control",
      actor_id: this.controlActorId,
      workspace_id: this.workspaceId,
      task_id: this.taskId,
      allowed_actions: ["claim_lease", "release_lease"],
      issued_at: iso(issuedAt),
      expires_at: iso(issuedAt + this.handleTtlMs),
      rotation_generation: this.rotationGeneration,
    };
    this.authorities.set(verifier(token), {
      kind: "lease_control",
      metadata,
      expiresAt: issuedAt + this.handleTtlMs,
      revoked: null,
    });
    this.onCapabilityIssued({
      kind: "lease_control",
      token,
      metadata: clone(metadata),
    });
    return { token, metadata };
  }

  _revokeMailboxHandles(reason) {
    for (const record of this.authorities.values()) {
      if (record.kind === "mailbox") {
        record.revoked = reason;
      }
    }
  }

  _revokeLeaseControls(reason) {
    for (const record of this.authorities.values()) {
      if (record.kind === "lease_control") {
        record.revoked = reason;
      }
    }
  }

  _rotateMailboxHandles() {
    this.rotationGeneration += 1;
    if (this.task.mode === "suspended") {
      this._issueMailboxHandle("source", "recovery");
      this._issueMailboxHandle("panel", "recovery");
    } else {
      this._issueMailboxHandle("source", "standard");
      this._issueMailboxHandle("panel", "standard");
    }
  }

  _authorize(token, kind, action, request) {
    if (!token) {
      return {
        error: this._error(
          request,
          "capability_missing",
          "A Task-scoped capability is required.",
        ),
      };
    }
    const record = this.authorities.get(verifier(token));
    if (!record || record.kind !== kind) {
      return {
        error: this._error(
          request,
          "capability_invalid",
          "The Task-scoped capability is invalid.",
        ),
      };
    }
    if (record.revoked === "rotated") {
      return {
        error: this._error(
          request,
          "capability_rotated",
          "A newer capability generation exists.",
          { rotation_generation: this.rotationGeneration },
        ),
      };
    }
    if (record.revoked) {
      return {
        error: this._error(
          request,
          "capability_revoked",
          "The Task-scoped capability was revoked.",
        ),
      };
    }
    if (this.now() >= record.expiresAt) {
      return {
        error: this._error(
          request,
          "capability_expired",
          "The Task-scoped capability expired.",
        ),
      };
    }
    const metadata = record.metadata;
    if (
      metadata.workspace_id !== this.workspaceId ||
      metadata.task_id !== this.taskId ||
      metadata.contract !== CONTRACT
    ) {
      return {
        error: this._error(
          request,
          "capability_scope_mismatch",
          "The capability is bound to another Task scope.",
        ),
      };
    }
    if (
      kind === "mailbox" &&
      metadata.channel_id !== this.channelId
    ) {
      return {
        error: this._error(
          request,
          "channel_mismatch",
          "The capability channel does not match the Task.",
        ),
      };
    }
    if (
      kind === "mailbox" &&
      metadata.execution_epoch !== this.task.epoch
    ) {
      return {
        error: this._error(
          request,
          "capability_rotated",
          "The capability execution epoch is no longer current.",
        ),
      };
    }
    if (kind === "mailbox") {
      const profileActions = PROFILE_ACTIONS[metadata.mailbox_profile];
      if (
        !profileActions ||
        !Array.isArray(metadata.allowed_actions) ||
        metadata.allowed_actions.length !== profileActions.length ||
        new Set(metadata.allowed_actions).size !== metadata.allowed_actions.length ||
        profileActions.some((item) => !metadata.allowed_actions.includes(item)) ||
        metadata.allowed_actions.some((item) => !profileActions.includes(item))
      ) {
        return {
          error: this._error(
            request,
            "capability_invalid",
            "allowed_actions does not match mailbox_profile exactly.",
          ),
        };
      }
      if (
        metadata.mailbox_profile !== "standard" &&
        this.task.mode !== "suspended"
      ) {
        return {
          error: this._error(
            request,
            "capability_scope_mismatch",
            "Recovery capabilities are valid only while suspended.",
          ),
        };
      }
      if (
        metadata.mailbox_profile === "standard" &&
        this.task.mode === "suspended"
      ) {
        return {
          error: this._error(
            request,
            "capability_rotated",
            "The standard mailbox capability is no longer current.",
          ),
        };
      }
      if (!profileActions.includes(action)) {
        return {
          error: this._error(
            request,
            "action_not_allowed",
            "The action is outside the profile-derived capability set.",
          ),
        };
      }
    } else if (!metadata.allowed_actions.includes(action)) {
      return {
        error: this._error(
          request,
          "action_not_allowed",
          "The action is outside the lease-control capability set.",
        ),
      };
    }
    return { record };
  }

  _taskState() {
    return {
      schema_version: SCHEMA_VERSION,
      contract: CONTRACT,
      task_id: this.taskId,
      channel_id: this.channelId,
      workspace_id: this.workspaceId,
      mode: this.task.mode,
      execution: this._executionState(),
      task_revision: this.task.revision,
      stream: {
        generation: this.task.generation,
        head_seq: this.task.headSeq,
        min_retained_seq: this.task.minRetainedSeq,
      },
      snapshot_seq: this.task.headSeq,
      objective: this.task.objective,
      state: clone(this.task.state),
      pending: this._pendingCounts(),
    };
  }

  _executionState() {
    return {
      mode: this.task.mode,
      owner: this.task.owner,
      lease_id: this.task.mode === "suspended" ? null : this.task.leaseId,
      fencing_epoch: this.task.epoch,
    };
  }

  _pendingCounts() {
    const pending = { for_source: 0, for_panel: 0 };
    for (const event of this.task.events) {
      if (
        includesTarget(event, "source") &&
        !this.actors.source.acknowledged.has(event.event_id)
      ) {
        pending.for_source += 1;
      }
      if (
        includesTarget(event, "panel") &&
        !this.actors.panel.acknowledged.has(event.event_id)
      ) {
        pending.for_panel += 1;
      }
    }
    return pending;
  }

  _deliveryAckState() {
    return {
      source: {
        generation: this.task.generation,
        delivered_seq_prefix: this.actors.source.deliveredSeq,
        ack_coverage_prefix: this._coverage("source"),
      },
      panel: {
        generation: this.task.generation,
        delivered_seq_prefix: this.actors.panel.deliveredSeq,
        ack_coverage_prefix: this._coverage("panel"),
      },
    };
  }

  _coverage(role) {
    let coverage = 0;
    for (const event of this.task.events) {
      if (!includesTarget(event, role)) {
        coverage = event.stream_seq;
        continue;
      }
      if (!this.actors[role].acknowledged.has(event.event_id)) {
        break;
      }
      coverage = event.stream_seq;
    }
    return coverage;
  }

  _cleanupSnapshots() {
    const now = this.now();
    for (const [id, snapshot] of this.snapshots) {
      if (
        snapshot.invalidated ||
        now >= snapshot.expiresAt
      ) {
        this.snapshots.delete(id);
      }
    }
  }

  _findReusableSnapshot(actor) {
    this._cleanupSnapshots();
    return [...this.snapshots.values()].find(
      (snapshot) =>
        !snapshot.invalidated &&
        snapshot.actorId === actor.actorId &&
        snapshot.actorRole === actor.role &&
        snapshot.generation === this.task.generation &&
        snapshot.snapshotSeq === this.task.headSeq &&
        snapshot.taskRevision === this.task.revision &&
        snapshot.fencingEpoch === this.task.epoch,
    );
  }

  _createSnapshot(actor, checkpoint = false) {
    let snapshot = this._findReusableSnapshot(actor);
    if (!snapshot) {
      this._cleanupSnapshots();
      const actorCount = [...this.snapshots.values()].filter(
        (item) => item.actorId === actor.actorId,
      ).length;
      if (actorCount >= this.maxSnapshotsPerActor) {
        return null;
      }
      const issuedAt = this.now();
      snapshot = {
        snapshotId: this._id("snapshot"),
        actorId: actor.actorId,
        actorRole: actor.role,
        generation: this.task.generation,
        snapshotSeq: this.task.headSeq,
        taskRevision: this.task.revision,
        fencingEpoch: this.task.epoch,
        issuedAt,
        expiresAt: issuedAt + this.snapshotTtlMs,
        invalidated: false,
      };
      this.snapshots.set(snapshot.snapshotId, snapshot);
    }
    let checkpointRecord = null;
    if (checkpoint) {
      const checkpointId = this._id("checkpoint");
      const issuedAt = this.now();
      checkpointRecord = {
        checkpointId,
        snapshotId: snapshot.snapshotId,
        generation: snapshot.generation,
        snapshotSeq: snapshot.snapshotSeq,
        taskRevision: snapshot.taskRevision,
        fencingEpoch: snapshot.fencingEpoch,
        requiredCoveragePrefix: snapshot.snapshotSeq,
        issuedAt,
        expiresAt: issuedAt + this.checkpointTtlMs,
        consumed: false,
      };
      this.checkpoints.set(checkpointId, checkpointRecord);
    }
    return { snapshot, checkpoint: checkpointRecord };
  }

  _snapshotMetadata(snapshot) {
    return {
      snapshot_id: snapshot.snapshotId,
      stream_generation: snapshot.generation,
      snapshot_seq: snapshot.snapshotSeq,
      task_revision: snapshot.taskRevision,
      stream_head_seq: this.task.headSeq,
      min_retained_seq: this.task.minRetainedSeq,
      issued_at: iso(snapshot.issuedAt),
      expires_at: iso(snapshot.expiresAt),
    };
  }

  _checkpointMetadata(checkpoint) {
    return {
      checkpoint_id: checkpoint.checkpointId,
      generation: checkpoint.generation,
      snapshot_seq: checkpoint.snapshotSeq,
      task_revision: checkpoint.taskRevision,
      fencing_epoch: checkpoint.fencingEpoch,
      required_coverage_prefix: checkpoint.requiredCoveragePrefix,
      expires_at: iso(checkpoint.expiresAt),
    };
  }

  snapshot(token, request) {
    const invalid = this._validateRequest("snapshot", request);
    if (invalid) return invalid;
    const auth = this._authorize(token, "mailbox", "snapshot", request);
    if (auth.error) return auth.error;
    const actor = {
      actorId: auth.record.metadata.actor_id,
      role: auth.record.metadata.actor_role,
    };
    const created = this._createSnapshot(actor, request.checkpoint === true);
    if (!created) {
      return this._error(
        request,
        "snapshot_capacity_exceeded",
        "The active snapshot metadata cap was reached.",
      );
    }
    const task = this._taskState();
    return {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: this.taskId,
      status: "snapshot",
      task,
      snapshot: this._snapshotMetadata(created.snapshot),
      execution: this._executionState(),
      delivery_ack_state: this._deliveryAckState(),
      pending_counts: this._pendingCounts(),
      checkpoint: created.checkpoint
        ? this._checkpointMetadata(created.checkpoint)
        : null,
    };
  }

  pull(token, request) {
    const invalid = this._validateRequest("pull", request);
    if (invalid) return invalid;
    const auth = this._authorize(token, "mailbox", "pull", request);
    if (auth.error) return auth.error;
    const role = auth.record.metadata.actor_role;
    const actor = this.actors[role];
    const generation = request.after.generation;
    const after = request.after.seq;
    if (generation !== this.task.generation) {
      return this._error(
        request,
        "resync_required",
        "The cursor generation is not current.",
        { reason: "generation_mismatch" },
      );
    }
    if (after > this.task.headSeq) {
      return this._error(
        request,
        "resync_required",
        "The cursor is ahead of the stream.",
        { reason: "cursor_ahead" },
      );
    }
    if (after < this.task.minRetainedSeq - 1) {
      return this._error(
        request,
        "resync_required",
        "The requested cursor is outside retained history.",
        { reason: "cursor_too_old" },
      );
    }
    const limit = request.limit ?? 50;
    const events = this.task.events
      .filter((event) => event.stream_seq > after)
      .slice(0, limit)
      .map(clone);
    const expectedFirst = after + 1;
    if (
      events.length > 0 &&
      events[0].stream_seq !== expectedFirst
    ) {
      return this._error(
        request,
        "resync_required",
        "The stream contains a cursor gap.",
        { reason: "cursor_gap" },
      );
    }
    if (
      events.length > 0 &&
      events[0].stream_seq <= actor.deliveredSeq + 1
    ) {
      actor.deliveredSeq = events.at(-1).stream_seq;
    }
    const cursorSeq = events.length > 0 ? events.at(-1).stream_seq : after;
    return {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: this.taskId,
      status: "ok",
      task_revision: this.task.revision,
      stream: {
        generation: this.task.generation,
        head_seq: this.task.headSeq,
        min_retained_seq: this.task.minRetainedSeq,
      },
      events,
      cursor: { generation, seq: cursorSeq },
      delivery: {
        generation,
        delivered_seq_prefix: actor.deliveredSeq,
      },
      ack: {
        generation,
        ack_coverage_prefix: this._coverage(role),
      },
      has_more: this.task.headSeq > cursorSeq,
    };
  }

  _idempotencyMapKey(operation, actorId, key) {
    return `${operation}\u0000${actorId}\u0000${key}`;
  }

  _findIdempotent(operation, actorId, request, hash) {
    const key = this._idempotencyMapKey(
      operation,
      actorId,
      request.idempotency_key,
    );
    const receipt = this.idempotency.get(key);
    if (!receipt) return { key, receipt: null };
    if (receipt.canonical_hash !== hash) {
      return { key, conflict: true, receipt };
    }
    return { key, receipt };
  }

  _duplicateResponse(receipt, requestId) {
    const response = clone(receipt.response);
    response.request_id = requestId;
    response.status = "duplicate";
    if (response.receipt) {
      response.receipt.original_request_id = receipt.response.request_id;
    }
    return response;
  }

  _storeReceipt({
    operation,
    actorId,
    actorRole,
    request,
    hash,
    response,
    eventReceipts = [],
    nextSnapshot = null,
  }) {
    const receiptId = this._id("receipt");
    const receipt = {
      schema_version: SCHEMA_VERSION,
      contract: CONTRACT,
      receipt_id: receiptId,
      task_id: this.taskId,
      actor_id: actorId,
      actor_role: actorRole,
      operation,
      idempotency_key: request.idempotency_key,
      canonical_hash_algorithm: "sha256",
      canonical_hash: hash,
      original_request_id: request.request_id,
      outcome: "applied",
      committed_at: iso(this.now()),
      task_revision: this.task.revision,
      stream_generation: this.task.generation,
      head_seq: this.task.headSeq,
      response: clone(response),
      event_receipts: clone(eventReceipts),
      ...(nextSnapshot ? { next_snapshot: clone(nextSnapshot) } : {}),
    };
    this.receipts.set(receiptId, receipt);
    return receipt;
  }

  _validateSnapshotExpected(actor, expected, request) {
    const snapshot = this.snapshots.get(expected.snapshot_id);
    if (
      !snapshot ||
      snapshot.invalidated ||
      this.now() >= snapshot.expiresAt ||
      snapshot.actorId !== actor.actorId ||
      snapshot.actorRole !== actor.role ||
      snapshot.generation !== expected.stream_generation ||
      snapshot.generation !== this.task.generation ||
      snapshot.snapshotSeq !== expected.snapshot_seq ||
      snapshot.snapshotSeq < this.task.minRetainedSeq - 1
    ) {
      return this._error(
        request,
        "snapshot_required",
        "A current coherent snapshot is required.",
        { reason: "invalid_or_expired" },
      );
    }
    if (snapshot.taskRevision !== expected.task_revision) {
      return this._error(
        request,
        "snapshot_required",
        "The snapshot revision does not match the request baseline.",
        { reason: "revision_binding_mismatch" },
      );
    }
    if (snapshot.fencingEpoch !== expected.execution_epoch) {
      return this._error(
        request,
        "lease_conflict",
        "The snapshot execution epoch does not match the request.",
        {
          snapshot_epoch: snapshot.fencingEpoch,
          expected_epoch: expected.execution_epoch,
        },
      );
    }
    if (expected.task_revision !== this.task.revision) {
      return this._error(
        request,
        "revision_conflict",
        "The expected Task revision is stale.",
        {
          expected_revision: expected.task_revision,
          current_revision: this.task.revision,
        },
      );
    }
    if (expected.execution_epoch !== this.task.epoch) {
      return this._error(
        request,
        "lease_conflict",
        "The expected execution epoch is not current.",
        {
          expected_epoch: expected.execution_epoch,
          current_epoch: this.task.epoch,
        },
      );
    }
    return { ok: true, snapshot };
  }

  _ensureNewSnapshotCapacity(actor) {
    this._cleanupSnapshots();
    return [...this.snapshots.values()].filter(
      (snapshot) => snapshot.actorId === actor.actorId,
    ).length < this.maxSnapshotsPerActor;
  }

  publish(token, request) {
    const bodySize = this._bodySize(request);
    if (bodySize === null) {
      return this._error(
        request,
        "schema_invalid",
        "The publish request is not JSON-safe.",
      );
    }
    if (bodySize > this.maxPublishBytes) {
      return this._error(
        request,
        "payload_too_large",
        "The publish request exceeds 256 KiB.",
      );
    }
    const invalid = this._validateRequest("publish", request);
    if (invalid) return invalid;
    const auth = this._authorize(token, "mailbox", "publish", request);
    if (auth.error) return auth.error;
    const actor = {
      actorId: auth.record.metadata.actor_id,
      role: auth.record.metadata.actor_role,
    };
    const hash = canonicalRequestHash("publish", request);
    const idem = this._findIdempotent(
      "publish",
      actor.actorId,
      request,
      hash,
    );
    if (idem.conflict) {
      return this._error(
        request,
        "idempotency_conflict",
        "The idempotency key was reused with a different payload.",
      );
    }
    if (idem.receipt) {
      return this._duplicateResponse(idem.receipt, request.request_id);
    }
    if (this.task.mode === "suspended") {
      return this._error(
        request,
        "lease_conflict",
        "The Task is suspended.",
        { reason: "task_suspended" },
      );
    }
    const snapshotCheck = this._validateSnapshotExpected(
      actor,
      request.expected,
      request,
    );
    if (!snapshotCheck.ok) return snapshotCheck;
    for (const draft of request.events) {
      if (draft.execution_epoch !== this.task.epoch) {
        if (
          draft.authority === "execution_result" &&
          draft.execution_epoch < this.task.epoch
        ) {
          return this._error(
            request,
            "stale_owner",
            "The execution result belongs to an older epoch.",
            {
              origin_epoch: draft.execution_epoch,
              current_epoch: this.task.epoch,
              current_owner: this.task.owner,
            },
          );
        }
        return this._error(
          request,
          "lease_conflict",
          "The event execution epoch is not current.",
          { reason: "epoch_mismatch" },
        );
      }
      if (draft.authority === "execution_result" && this.task.owner !== actor.role) {
        return this._error(
          request,
          "lease_conflict",
          "The actor is not the current execution owner.",
          { reason: "not_execution_owner" },
        );
      }
      if (
        !auth.record.metadata.permitted_authority.includes(draft.authority)
      ) {
        return this._error(
          request,
          "action_not_allowed",
          "The actor capability does not permit this event authority.",
        );
      }
      const matrixViolation = eventMatrixViolation(draft, actor.role);
      if (matrixViolation) {
        return this._error(
          request,
          "schema_invalid",
          "kind, authority, author role, or target role is invalid.",
          matrixViolation,
        );
      }
      if (
        OWNER_EVENT_KINDS.has(draft.kind) ||
        Buffer.byteLength(JSON.stringify(draft.payload), "utf8") >
          this.maxEventPayloadBytes ||
        containsUnsafePayload(draft.payload)
      ) {
        return this._error(
          request,
          "schema_invalid",
          "An event payload is invalid or unsafe.",
        );
      }
    }
    const clientEventIds = new Set();
    for (const event of request.events) {
      if (clientEventIds.has(event.client_event_id)) {
        return this._error(
          request,
          "invalid_request",
          "client_event_id values must be unique in a batch.",
        );
      }
      clientEventIds.add(event.client_event_id);
    }
    if (!this._ensureNewSnapshotCapacity(actor)) {
      return this._error(
        request,
        "snapshot_capacity_exceeded",
        "The active snapshot metadata cap was reached.",
      );
    }

    const committedAt = iso(this.now());
    const committedEvents = request.events.map((draft) => {
      const event = {
        event_id: this._id("event"),
        stream_seq: this.task.headSeq + 1,
        kind: draft.kind,
        authority: draft.authority,
        author_role: actor.role,
        target_role: draft.target_role,
        execution_epoch: draft.execution_epoch,
        origin: {
          ...clone(draft.origin),
          client_event_id: draft.client_event_id,
        },
        payload: clone(draft.payload),
        created_at: committedAt,
      };
      this.task.headSeq += 1;
      this.task.events.push(event);
      if (includesTarget(event, actor.role)) {
        this.actors[actor.role].acknowledged.add(event.event_id);
      }
      return event;
    });
    this.task.revision += 1;
    const nextSnapshotRecord = this._createSnapshot(actor).snapshot;
    const nextSnapshot = {
      snapshot_id: nextSnapshotRecord.snapshotId,
      snapshot_seq: nextSnapshotRecord.snapshotSeq,
      task_revision: nextSnapshotRecord.taskRevision,
      expires_at: iso(nextSnapshotRecord.expiresAt),
    };
    const eventReceipts = committedEvents.map((event) => ({
      event_id: event.event_id,
      client_event_id: event.origin.client_event_id,
      stream_seq: event.stream_seq,
      created_at: event.created_at,
    }));
    const response = {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: this.taskId,
      status: "applied",
      receipt: {
        idempotency_key: request.idempotency_key,
        outcome: "applied",
        committed_at: committedAt,
      },
      task_revision: this.task.revision,
      stream: {
        generation: this.task.generation,
        head_seq: this.task.headSeq,
      },
      events: eventReceipts,
      next_snapshot: nextSnapshot,
    };
    const receipt = this._storeReceipt({
      operation: "publish",
      actorId: actor.actorId,
      actorRole: actor.role,
      request,
      hash,
      response,
      eventReceipts,
      nextSnapshot,
    });
    this.idempotency.set(idem.key, receipt);
    return response;
  }

  ack(token, request) {
    const bodySize = this._bodySize(request);
    if (bodySize === null) {
      return this._error(
        request,
        "schema_invalid",
        "The ack request is not JSON-safe.",
      );
    }
    if (bodySize > this.maxAckBytes) {
      return this._error(
        request,
        "payload_too_large",
        "The ack request exceeds 64 KiB.",
      );
    }
    if (
      Array.isArray(request?.event_ids) &&
      request.event_ids.length > this.maxAckIds
    ) {
      return this._error(
        request,
        "payload_too_large",
        "The ack request contains more than 200 event IDs.",
      );
    }
    if (
      Array.isArray(request?.event_ids) &&
      request.event_ids.length === 0
    ) {
      return this._error(
        request,
        "invalid_request",
        "The ack request must contain at least one event ID.",
      );
    }
    const invalid = this._validateRequest("ack", request);
    if (invalid) return invalid;
    const auth = this._authorize(token, "mailbox", "ack", request);
    if (auth.error) return auth.error;
    if (request.stream_generation !== this.task.generation) {
      return this._error(
        request,
        "resync_required",
        "The ack generation is not current.",
        { reason: "generation_mismatch" },
      );
    }
    const role = auth.record.metadata.actor_role;
    const actor = this.actors[role];
    const uniqueIds = [...new Set(request.event_ids)];
    const events = [];
    for (const eventId of uniqueIds) {
      const event = this.task.events.find(
        (candidate) => candidate.event_id === eventId,
      );
      if (!event) {
        return this._error(
          request,
          "resync_required",
          "An ack event ID is unknown or from another generation.",
        );
      }
      if (event.stream_seq > actor.deliveredSeq) {
        return this._error(
          request,
          "ack_not_delivered",
          "The event has not been delivered to this actor.",
          {
            event_id: event.event_id,
            delivered_seq_prefix: actor.deliveredSeq,
          },
        );
      }
      if (!includesTarget(event, role)) {
        return this._error(
          request,
          "ack_not_allowed",
          "The event is not targeted to this actor role.",
          {
            actor_role: role,
            target_role: event.target_role,
          },
        );
      }
      events.push(event);
    }
    const acked = [];
    const alreadyAcked = [];
    for (const event of events) {
      if (actor.acknowledged.has(event.event_id)) {
        alreadyAcked.push(event.event_id);
      } else {
        actor.acknowledged.add(event.event_id);
        acked.push(event.event_id);
      }
    }
    return {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: this.taskId,
      status: "acknowledged",
      acked_event_ids: acked,
      already_acked_event_ids: alreadyAcked,
      delivery: {
        generation: this.task.generation,
        delivered_seq_prefix: actor.deliveredSeq,
      },
      ack: {
        generation: this.task.generation,
        ack_coverage_prefix: this._coverage(role),
      },
      task_revision: this.task.revision,
    };
  }

  issueConfirmation(kind, targetMode) {
    const id = this._id("confirmation");
    const issuedAt = this.now();
    this.confirmations.set(id, {
      id,
      kind,
      taskId: this.taskId,
      targetMode,
      issuedAt,
      expiresAt: issuedAt + this.confirmationTtlMs,
      consumed: false,
    });
    return id;
  }

  _validateConfirmation(id, kind, targetMode, request) {
    const confirmation = this.confirmations.get(id);
    if (!confirmation) {
      return this._error(
        request,
        "confirmation_required",
        "A valid confirmation is required.",
      );
    }
    if (
      confirmation.taskId !== this.taskId ||
      confirmation.targetMode !== targetMode ||
      (kind && confirmation.kind !== kind)
    ) {
      return this._error(
        request,
        "confirmation_invalid",
        "The confirmation is bound to another Task, mode, or purpose.",
      );
    }
    if (this.now() >= confirmation.expiresAt) {
      return this._error(
        request,
        "confirmation_expired",
        "The confirmation expired.",
      );
    }
    if (confirmation.consumed) {
      return this._error(
        request,
        "confirmation_consumed",
        "The confirmation was already consumed.",
      );
    }
    return { ok: true, confirmation };
  }

  _appendOwnerEvent(kind, clientEventId) {
    const event = {
      event_id: this._id("event"),
      stream_seq: this.task.headSeq + 1,
      kind,
      authority: "owner_transition",
      author_role: "coordinator",
      target_role: "both",
      execution_epoch: this.task.epoch,
      origin: {
        session_ref: null,
        turn_id: null,
        item_id: null,
        client_event_id: clientEventId,
      },
      payload: {},
      created_at: iso(this.now()),
    };
    this.task.headSeq += 1;
    this.task.events.push(event);
    return event;
  }

  _invalidateTransitionArtifacts() {
    for (const snapshot of this.snapshots.values()) {
      snapshot.invalidated = true;
    }
    for (const checkpoint of this.checkpoints.values()) {
      checkpoint.consumed = true;
    }
  }

  claimLease(token, request) {
    const invalid = this._validateRequest("claim_lease", request);
    if (invalid) return invalid;
    const auth = this._authorize(token, "lease_control", "claim_lease", request);
    if (auth.error) return auth.error;
    const actorId = auth.record.metadata.actor_id;
    const hash = canonicalRequestHash("claim_lease", request);
    const idem = this._findIdempotent("claim_lease", actorId, request, hash);
    if (idem.conflict) {
      return this._error(
        request,
        "idempotency_conflict",
        "The idempotency key was reused with a different payload.",
      );
    }
    if (idem.receipt) {
      return this._duplicateResponse(idem.receipt, request.request_id);
    }
    if (
      request.expected.execution_epoch !== this.task.epoch ||
      request.target_mode === this.task.mode
    ) {
      return this._error(
        request,
        "lease_conflict",
        "The expected epoch or target mode is not current.",
        { reason: "epoch_mismatch" },
      );
    }
    if (request.expected.task_revision !== this.task.revision) {
      return this._error(
        request,
        "revision_conflict",
        "The expected Task revision is stale.",
      );
    }
    const checkpoint = this.checkpoints.get(
      request.expected.checkpoint_id,
    );
    if (
      !checkpoint ||
      checkpoint.consumed ||
      this.now() >= checkpoint.expiresAt ||
      checkpoint.generation !== this.task.generation ||
      checkpoint.taskRevision !== this.task.revision ||
      checkpoint.fencingEpoch !== this.task.epoch
    ) {
      return this._error(
        request,
        "checkpoint_required",
        "A current checkpoint is required.",
      );
    }
    if (
      this._coverage("source") < checkpoint.requiredCoveragePrefix ||
      this._coverage("panel") < checkpoint.requiredCoveragePrefix
    ) {
      return this._error(
        request,
        "checkpoint_incomplete",
        "Source or panel acknowledgement coverage is incomplete.",
        {
          required: checkpoint.requiredCoveragePrefix,
          source: this._coverage("source"),
          panel: this._coverage("panel"),
        },
      );
    }
    const confirmationResult = this._validateConfirmation(
      request.user_confirmation_id,
      "claim_switch",
      request.target_mode,
      request,
    );
    if (!confirmationResult.ok) return confirmationResult;

    confirmationResult.confirmation.consumed = true;
    checkpoint.consumed = true;
    this.task.epoch += 1;
    this.task.mode = request.target_mode;
    this.task.owner = ownerForMode(request.target_mode);
    this.task.leaseId = this._id("lease");
    this.task.revision += 1;
    const transition = this._appendOwnerEvent(
      "owner.switched",
      `owner-switch-${this.uuid()}`,
    );
    this._invalidateTransitionArtifacts();
    this._revokeMailboxHandles("rotated");
    this._revokeLeaseControls("rotated");
    this._rotateMailboxHandles();
    this._issueLeaseControl();
    const response = {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: this.taskId,
      status: "applied",
      task_revision: this.task.revision,
      stream: {
        generation: this.task.generation,
        head_seq: this.task.headSeq,
      },
      execution: this._executionState(),
      capability_rotation_required: true,
      transition_event_id: transition.event_id,
      transition_stream_seq: transition.stream_seq,
    };
    const receipt = this._storeReceipt({
      operation: "claim_lease",
      actorId,
      actorRole: "control",
      request,
      hash,
      response,
    });
    this.idempotency.set(idem.key, receipt);
    return response;
  }

  releaseLease(token, request) {
    const invalid = this._validateRequest("release_lease", request);
    if (invalid) return invalid;
    const auth = this._authorize(
      token,
      "lease_control",
      "release_lease",
      request,
    );
    if (auth.error) return auth.error;
    const actorId = auth.record.metadata.actor_id;
    const hash = canonicalRequestHash("release_lease", request);
    const idem = this._findIdempotent(
      "release_lease",
      actorId,
      request,
      hash,
    );
    if (idem.conflict) {
      return this._error(
        request,
        "idempotency_conflict",
        "The idempotency key was reused with a different payload.",
      );
    }
    if (idem.receipt) {
      return this._duplicateResponse(idem.receipt, request.request_id);
    }
    if (this.task.mode === "suspended") {
      return this._error(
        request,
        "lease_conflict",
        "The Task is already suspended.",
        { reason: "task_already_suspended" },
      );
    }
    if (
      request.expected.execution_epoch !== this.task.epoch ||
      request.expected.task_revision !== this.task.revision
    ) {
      return this._error(
        request,
        "lease_conflict",
        "The expected release epoch or revision is stale.",
        { reason: "epoch_or_revision_mismatch" },
      );
    }
    const confirmationResult = this._validateConfirmation(
      request.user_confirmation_id,
      request.confirmation_kind,
      "suspended",
      request,
    );
    if (!confirmationResult.ok) return confirmationResult;

    confirmationResult.confirmation.consumed = true;
    this.task.epoch += 1;
    this.task.mode = "suspended";
    this.task.owner = "none";
    this.task.leaseId = null;
    this.task.revision += 1;
    const transition = this._appendOwnerEvent(
      "owner.released",
      `owner-release-${this.uuid()}`,
    );
    this._invalidateTransitionArtifacts();
    this._revokeMailboxHandles("rotated");
    this._revokeLeaseControls("rotated");
    this._rotateMailboxHandles();
    this._issueLeaseControl();
    const response = {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: request.request_id,
      task_id: this.taskId,
      status: "applied",
      task_revision: this.task.revision,
      stream: {
        generation: this.task.generation,
        head_seq: this.task.headSeq,
      },
      execution: this._executionState(),
      capability_rotation_required: true,
      transition_event_id: transition.event_id,
      transition_stream_seq: transition.stream_seq,
    };
    const receipt = this._storeReceipt({
      operation: "release_lease",
      actorId,
      actorRole: "control",
      request,
      hash,
      response,
    });
    this.idempotency.set(idem.key, receipt);
    return response;
  }

  issueRecoveryAckHandle(role) {
    if (this.task.mode !== "suspended") {
      throw new Error("recovery_ack handles are valid only while suspended");
    }
    return this._issueMailboxHandle(role, "recovery_ack");
  }

  requestPanelTurn() {
    if (this.task.mode === "source_hosted") {
      return this._error(
        { request_id: "request-panel-turn-01" },
        "panel_turn_forbidden_in_source_hosted",
        "Panel model Turns are forbidden in source_hosted mode.",
      );
    }
    return {
      ok: true,
      schema_version: SCHEMA_VERSION,
      request_id: "request-panel-turn-01",
      task_id: this.taskId,
      status: "synthetic_only",
    };
  }

  configureCapabilityForTest(token, patch) {
    const record = this.authorities.get(verifier(token));
    if (!record) throw new Error("Test capability was not found");
    record.metadata = {
      ...record.metadata,
      ...clone(patch),
    };
  }

  getTaskFixture() {
    return {
      task: this._taskState(),
      events: clone(this.task.events),
      receipts: [...this.receipts.values()].map(clone),
    };
  }
}

export function createReferenceCoordinator(options) {
  return new ReferenceCoordinator(options);
}
