import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import test from "node:test";
import {
  canonicalJson,
  canonicalRequestHash,
  canonicalizeJson,
} from "../contracts/source-hosted-shared-task/v1/reference/canonical-hash.mjs";
import {
  ERROR_CODES,
  ERROR_CATALOG,
} from "../contracts/source-hosted-shared-task/v1/reference/error-codes.mjs";
import {
  createContractValidator,
} from "../contracts/source-hosted-shared-task/v1/reference/contract-validator.mjs";
import {
  createReferenceCoordinator,
} from "../contracts/source-hosted-shared-task/v1/reference/coordinator.mjs";

const root = resolve(import.meta.dirname, "..");
const contractRoot = resolve(
  root,
  "contracts",
  "source-hosted-shared-task",
  "v1",
);
const validator = createContractValidator();

function createFixture(options = {}) {
  const issued = [];
  const coordinator = createReferenceCoordinator({
    ...options,
    onCapabilityIssued(item) {
      issued.push(item);
    },
  });
  return { coordinator, issued };
}

function mailbox(issued, role, profile = "standard") {
  const record = [...issued].reverse().find(
    (item) =>
      item.kind === "mailbox" &&
      item.metadata.actor_role === role &&
      item.metadata.mailbox_profile === profile,
  );
  assert.ok(record, `Missing ${role}/${profile} mailbox capability`);
  return record;
}

function control(issued) {
  const record = [...issued].reverse().find(
    (item) => item.kind === "lease_control",
  );
  assert.ok(record, "Missing lease-control capability");
  return record;
}

function snapshotRequest(requestId = "request-snapshot-01", checkpoint = false) {
  return {
    schema_version: "1.0",
    request_id: requestId,
    include: ["task", "execution", "delivery_ack_state", "pending_counts"],
    checkpoint,
  };
}

function eventDraft({
  id = "client-event-01",
  authority = "surface_input",
  kind = "intent.user_action",
  target = "source",
  epoch = 1,
  payload = { summary: "Synthetic conformance intent" },
} = {}) {
  return {
    client_event_id: id,
    kind,
    authority,
    target_role: target,
    execution_epoch: epoch,
    origin: {
      session_ref: null,
      turn_id: null,
      item_id: null,
    },
    payload,
  };
}

function publishRequest({
  requestId = "request-publish-01",
  key = "publish-key-01",
  snapshot,
  event,
  taskRevision = snapshot.task.task_revision,
  epoch = snapshot.execution.fencing_epoch,
}) {
  return {
    schema_version: "1.0",
    request_id: requestId,
    idempotency_key: key,
    expected: {
      stream_generation: snapshot.snapshot.stream_generation,
      snapshot_id: snapshot.snapshot.snapshot_id,
      snapshot_seq: snapshot.snapshot.snapshot_seq,
      task_revision: taskRevision,
      execution_epoch: epoch,
    },
    events: [event],
  };
}

function ackRequest(requestId, generation, eventIds) {
  return {
    schema_version: "1.0",
    request_id: requestId,
    stream_generation: generation,
    event_ids: eventIds,
  };
}

function expectValidRequest(name, request) {
  const result = validator.validateRequest(name, request);
  assert.equal(result.valid, true, JSON.stringify(result.errors));
}

function expectValidResponse(name, response) {
  const result = validator.validateResponse(name, response);
  assert.equal(result.valid, true, JSON.stringify(result.errors));
}

function expectError(response, code) {
  assert.equal(response.ok, false);
  assert.equal(response.error.code, code);
  expectValidResponse("error", response);
  return response;
}

function capabilityFixture(overrides = {}) {
  return {
    handle_id: "handle-fixture-01",
    contract: "source_hosted-shared-task-v1",
    audience: "skilldock-task-mailbox",
    actor_id: "actor-panel-fixture",
    actor_role: "panel",
    mailbox_profile: "standard",
    workspace_id: "workspace-fixture-01",
    task_id: "task-fixture-01",
    channel_id: "chat:fixture:task-fixture-01",
    execution_epoch: 1,
    allowed_actions: ["snapshot", "pull", "publish", "ack"],
    permitted_authority: ["surface_input", "note"],
    issued_at: "2026-11-16T12:00:00.000Z",
    expires_at: "2026-11-16T12:30:00.000Z",
    rotation_generation: 1,
    ...overrides,
  };
}

test("all contract schemas compile and valid capabilities satisfy profile action rules", () => {
  const standard = capabilityFixture();
  assert.equal(validator.validateCapability(standard).valid, true);
  assert.equal(
    validator.validateCapability(
      capabilityFixture({
        mailbox_profile: "recovery",
        allowed_actions: ["pull", "snapshot"],
        permitted_authority: [],
      }),
    ).valid,
    true,
  );
  assert.equal(
    validator.validateCapability(
      capabilityFixture({
        mailbox_profile: "recovery_ack",
        allowed_actions: ["ack", "snapshot", "pull"],
        permitted_authority: [],
      }),
    ).valid,
    true,
  );
});

test("capability schema rejects profile/action drift regardless of set order", () => {
  const cases = [
    capabilityFixture({
      allowed_actions: ["snapshot", "pull", "publish"],
    }),
    capabilityFixture({
      allowed_actions: ["snapshot", "pull", "publish", "ack", "claim_lease"],
    }),
    capabilityFixture({
      mailbox_profile: "recovery",
      allowed_actions: ["snapshot", "pull", "ack"],
      permitted_authority: [],
    }),
    capabilityFixture({
      mailbox_profile: "recovery_ack",
      allowed_actions: ["snapshot", "pull", "ack", "publish"],
      permitted_authority: [],
    }),
    capabilityFixture({
      allowed_actions: ["snapshot", "pull", "publish", "ack", "ack"],
    }),
  ];
  for (const value of cases) {
    assert.equal(validator.validateCapability(value).valid, false);
  }
});

test("reference coordinator rejects runtime profile/action drift", () => {
  const { coordinator, issued } = createFixture();
  const source = mailbox(issued, "source");
  coordinator.configureCapabilityForTest(source.token, {
    allowed_actions: ["snapshot", "pull", "publish", "ack", "claim_lease"],
  });
  const response = coordinator.snapshot(
    source.token,
    snapshotRequest("request-capability-mismatch"),
  );
  expectError(response, "capability_invalid");
});

test("execution state schema enforces mode, owner, and lease combinations", () => {
  const valid = [
    {
      mode: "source_hosted",
      owner: "source",
      lease_id: "lease-source-01",
      fencing_epoch: 1,
    },
    {
      mode: "panel_hosted",
      owner: "panel",
      lease_id: "lease-panel-01",
      fencing_epoch: 2,
    },
    {
      mode: "suspended",
      owner: "none",
      lease_id: null,
      fencing_epoch: 3,
    },
  ];
  for (const value of valid) {
    const result = validator.validateExecutionState(value);
    assert.equal(result.valid, true, JSON.stringify(result.errors));
  }
  const invalid = [
    {
      mode: "source_hosted",
      owner: "panel",
      lease_id: "lease-invalid-01",
      fencing_epoch: 1,
    },
    {
      mode: "panel_hosted",
      owner: "none",
      lease_id: "lease-invalid-02",
      fencing_epoch: 1,
    },
    {
      mode: "suspended",
      owner: "none",
      lease_id: "lease-invalid-03",
      fencing_epoch: 1,
    },
  ];
  for (const value of invalid) {
    assert.equal(validator.validateExecutionState(value).valid, false);
  }
});

test("event schema enforces kind, authority, and target routing matrix", () => {
  const base = {
    schema_version: "1.0",
    request_id: "request-kind-matrix-01",
    idempotency_key: "kind-matrix-key-01",
    expected: {
      stream_generation: "stream-kind-matrix-01",
      snapshot_id: "snapshot-kind-matrix-01",
      snapshot_seq: 0,
      task_revision: 1,
      execution_epoch: 1,
    },
  };
  const invalidDrafts = [
    eventDraft({
      id: "client-agent-result-fake",
      kind: "agent.result",
      authority: "surface_input",
      target: "panel",
    }),
    eventDraft({
      id: "client-intent-wrong-target",
      kind: "intent.user_action",
      authority: "surface_input",
      target: "panel",
    }),
    eventDraft({
      id: "client-note-wrong-authority",
      kind: "note",
      authority: "surface_input",
      target: "both",
    }),
    eventDraft({
      id: "client-owner-event",
      kind: "owner.switched",
      authority: "note",
      target: "both",
    }),
  ];
  for (const draft of invalidDrafts) {
    const result = validator.validateRequest("publish", {
      ...base,
      events: [draft],
    });
    assert.equal(result.valid, false);
  }
});

test("error catalog and JSON error-code enum remain identical", () => {
  const schema = JSON.parse(
    readFileSync(resolve(contractRoot, "errors.schema.json"), "utf8"),
  );
  assert.deepEqual(
    [...ERROR_CODES].sort(),
    [...schema.$defs.errorCode.enum].sort(),
  );
  assert.equal(new Set(ERROR_CODES).size, ERROR_CODES.length);
  for (const code of ERROR_CODES) {
    assert.equal(ERROR_CATALOG[code].code, code);
  }
});

test("canonical request hash is stable across transport metadata and key order", () => {
  const first = {
    schema_version: "1.0",
    request_id: "request-publish-a1",
    idempotency_key: "publish-key-a1",
    expected: {
      stream_generation: "stream-fixture-01",
      snapshot_id: "snapshot-fixture-01",
      snapshot_seq: 0,
      task_revision: 1,
      execution_epoch: 1,
    },
    events: [
      eventDraft({ payload: { z: 1, a: { y: 2, x: 3 } } }),
    ],
  };
  const second = {
    events: [
      eventDraft({ payload: { a: { x: 3, y: 2 }, z: 1 } }),
    ],
    expected: {
      execution_epoch: 1,
      task_revision: 1,
      snapshot_seq: 0,
      snapshot_id: "snapshot-fixture-01",
      stream_generation: "stream-fixture-01",
    },
    idempotency_key: "different-key-01",
    request_id: "request-publish-b2",
    schema_version: "1.0",
  };
  assert.equal(
    canonicalRequestHash("publish", first),
    canonicalRequestHash("publish", second),
  );
  const changed = structuredClone(first);
  changed.expected.task_revision = 2;
  assert.notEqual(
    canonicalRequestHash("publish", first),
    canonicalRequestHash("publish", changed),
  );
  expectValidRequest("publish", first);
});

test("canonicalizer rejects cyclic and non-JSON values", () => {
  const cyclic = {};
  cyclic.self = cyclic;
  assert.throws(() => canonicalizeJson(cyclic), /cycle/u);
  assert.throws(() => canonicalizeJson({ value: Number.NaN }), /finite/u);
  assert.throws(() => canonicalizeJson({ value: 1n }), /JSON value/u);
  assert.deepEqual(
    canonicalizeJson({ 结果: "通过", 阶段: "schema" }),
    canonicalizeJson({ 阶段: "schema", 结果: "通过" }),
  );
});

test("canonicalizer preserves prototype-like keys and sorts numeric keys lexically", () => {
  const first = JSON.parse(
    '{"__proto__":{"x":1},"constructor":{"y":2},"prototype":3,"10":1,"2":2}',
  );
  const second = JSON.parse(
    '{"__proto__":{"x":9},"constructor":{"y":2},"prototype":3,"10":1,"2":2}',
  );
  const canonical = canonicalJson(first);
  assert.equal(
    canonical,
    '{"10":1,"2":2,"__proto__":{"x":1},"constructor":{"y":2},"prototype":3}',
  );
  const normalized = canonicalizeJson(first);
  assert.equal(Object.hasOwn(normalized, "__proto__"), true);
  assert.deepEqual(normalized.__proto__, { x: 1 });
  assert.notEqual(
    canonicalRequestHash("publish", { payload: first }),
    canonicalRequestHash("publish", { payload: second }),
  );
});

test("source_hosted panel model Turn is rejected without a provider call", () => {
  const coordinator = createReferenceCoordinator();
  const response = coordinator.requestPanelTurn();
  expectError(response, "panel_turn_forbidden_in_source_hosted");
  assert.equal(response.error.details.driver_called, undefined);
});

test("coordinator rejects fake execution results and non-owner execution authority", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(
    panel.token,
    snapshotRequest("request-kind-runtime-snapshot"),
  );
  const fakeResult = publishRequest({
    requestId: "request-fake-result-01",
    key: "fake-result-key-01",
    snapshot: snap,
    event: eventDraft({
      id: "client-fake-result-01",
      kind: "agent.result",
      authority: "surface_input",
      target: "panel",
      payload: { text: "Not an owner result" },
    }),
  });
  expectError(coordinator.publish(panel.token, fakeResult), "schema_invalid");

  const nonOwner = publishRequest({
    requestId: "request-non-owner-result",
    key: "non-owner-result-key",
    snapshot: snap,
    event: eventDraft({
      id: "client-non-owner-result",
      kind: "agent.result",
      authority: "execution_result",
      target: "panel",
      payload: { text: "Panel is not the owner" },
    }),
  });
  expectError(coordinator.publish(panel.token, nonOwner), "lease_conflict");

  const source = mailbox(issued, "source");
  const sourceSnapshot = coordinator.snapshot(
    source.token,
    snapshotRequest("request-kind-source-snapshot"),
  );
  const sourceAnalysisRequest = publishRequest({
    requestId: "request-source-analysis-invalid",
    key: "source-analysis-invalid-key",
    snapshot: sourceSnapshot,
    event: eventDraft({
      id: "client-source-analysis-invalid",
      kind: "intent.analysis_request",
      authority: "surface_input",
      target: "source",
      payload: { request: "Only panel may request analysis" },
    }),
  });
  expectError(
    coordinator.publish(source.token, sourceAnalysisRequest),
    "schema_invalid",
  );
});

test("snapshot, publish, pull, target-aware ack, and duplicate replay conform", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const source = mailbox(issued, "source");

  const snap = coordinator.snapshot(panel.token, snapshotRequest());
  expectValidResponse("snapshot", snap);

  const publish = publishRequest({
    snapshot: snap,
    event: eventDraft(),
  });
  expectValidRequest("publish", publish);
  const applied = coordinator.publish(panel.token, publish);
  expectValidResponse("publish", applied);
  assert.equal(applied.status, "applied");
  const eventId = applied.events[0].event_id;

  const earlyAck = coordinator.ack(
    source.token,
    ackRequest("request-ack-early", snap.snapshot.stream_generation, [eventId]),
  );
  expectError(earlyAck, "ack_not_delivered");

  const sourcePull = coordinator.pull(source.token, {
    schema_version: "1.0",
    request_id: "request-pull-source-01",
    after: {
      generation: snap.snapshot.stream_generation,
      seq: 0,
    },
    limit: 50,
  });
  expectValidResponse("pull", sourcePull);
  assert.equal(sourcePull.events.length, 1);

  const sourceAck = coordinator.ack(
    source.token,
    ackRequest("request-ack-source-01", snap.snapshot.stream_generation, [eventId]),
  );
  expectValidResponse("ack", sourceAck);
  assert.equal(sourceAck.ack.ack_coverage_prefix, 1);

  const panelPull = coordinator.pull(panel.token, {
    schema_version: "1.0",
    request_id: "request-pull-panel-01",
    after: {
      generation: snap.snapshot.stream_generation,
      seq: 0,
    },
    limit: 50,
  });
  expectValidResponse("pull", panelPull);
  const panelAck = coordinator.ack(
    panel.token,
    ackRequest("request-ack-panel-01", snap.snapshot.stream_generation, [eventId]),
  );
  expectError(panelAck, "ack_not_allowed");

  const duplicateRequest = {
    ...publish,
    request_id: "request-publish-duplicate-02",
  };
  const duplicate = coordinator.publish(panel.token, duplicateRequest);
  expectValidResponse("publish", duplicate);
  assert.equal(duplicate.status, "duplicate");
  assert.equal(duplicate.receipt.original_request_id, publish.request_id);
  assert.equal(
    coordinator.getTaskFixture().task.task_revision,
    applied.task_revision,
  );

  const conflictRequest = {
    ...publish,
    request_id: "request-publish-conflict-03",
    events: [
      eventDraft({
        payload: { summary: "Different payload with the same key" },
      }),
    ],
  };
  expectError(
    coordinator.publish(panel.token, conflictRequest),
    "idempotency_conflict",
  );
});

test("publish returns revision conflict after another publish advances revision", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(panel.token, snapshotRequest());
  const first = publishRequest({
    requestId: "request-publish-first-01",
    key: "publish-first-key-01",
    snapshot: snap,
    event: eventDraft({ id: "client-event-first-01" }),
  });
  const applied = coordinator.publish(panel.token, first);
  expectValidResponse("publish", applied);

  const second = publishRequest({
    requestId: "request-publish-second-02",
    key: "publish-second-key-02",
    snapshot: snap,
    event: eventDraft({ id: "client-event-second-02" }),
  });
  expectError(
    coordinator.publish(panel.token, second),
    "revision_conflict",
  );
});

test("old snapshot cannot be paired with current revision or another epoch", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(
    panel.token,
    snapshotRequest("request-snapshot-binding-base"),
  );
  const first = coordinator.publish(
    panel.token,
    publishRequest({
      requestId: "request-snapshot-binding-first",
      key: "snapshot-binding-first-key",
      snapshot: snap,
      event: eventDraft({ id: "client-snapshot-binding-01" }),
    }),
  );
  expectValidResponse("publish", first);

  const oldSnapshotCurrentRevision = publishRequest({
    requestId: "request-snapshot-binding-current",
    key: "snapshot-binding-current-key",
    snapshot: snap,
    taskRevision: first.task_revision,
    event: eventDraft({ id: "client-snapshot-binding-02" }),
  });
  expectError(
    coordinator.publish(panel.token, oldSnapshotCurrentRevision),
    "snapshot_required",
  );

  const wrongEpoch = publishRequest({
    requestId: "request-snapshot-binding-epoch",
    key: "snapshot-binding-epoch-key",
    snapshot: snap,
    epoch: snap.execution.fencing_epoch + 1,
    event: eventDraft({
      id: "client-snapshot-binding-03",
      epoch: snap.execution.fencing_epoch + 1,
    }),
  });
  expectError(coordinator.publish(panel.token, wrongEpoch), "lease_conflict");
});

test("next_snapshot issued by publish supports the following transaction", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(
    panel.token,
    snapshotRequest("request-next-snapshot-base"),
  );
  const first = coordinator.publish(
    panel.token,
    publishRequest({
      requestId: "request-next-snapshot-first",
      key: "next-snapshot-first-key",
      snapshot: snap,
      event: eventDraft({ id: "client-event-next-01" }),
    }),
  );
  expectValidResponse("publish", first);
  const secondRequest = {
    schema_version: "1.0",
    request_id: "request-next-snapshot-second",
    idempotency_key: "next-snapshot-second-key",
    expected: {
      stream_generation: first.stream.generation,
      snapshot_id: first.next_snapshot.snapshot_id,
      snapshot_seq: first.next_snapshot.snapshot_seq,
      task_revision: first.next_snapshot.task_revision,
      execution_epoch: snap.execution.fencing_epoch,
    },
    events: [eventDraft({ id: "client-event-next-02" })],
  };
  const second = coordinator.publish(panel.token, secondRequest);
  expectValidResponse("publish", second);
  assert.equal(second.task_revision, first.task_revision + 1);
  assert.notEqual(
    second.next_snapshot.snapshot_id,
    first.next_snapshot.snapshot_id,
  );
});

test("publish fails before commit when a post-publish snapshot cannot be retained", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const initial = coordinator.snapshot(
    panel.token,
    snapshotRequest("request-capacity-base"),
  );
  let expected = {
    stream_generation: initial.snapshot.stream_generation,
    snapshot_id: initial.snapshot.snapshot_id,
    snapshot_seq: initial.snapshot.snapshot_seq,
    task_revision: initial.task.task_revision,
    execution_epoch: initial.execution.fencing_epoch,
  };
  for (let index = 0; index < 63; index += 1) {
    const applied = coordinator.publish(panel.token, {
      schema_version: "1.0",
      request_id: `request-capacity-${String(index).padStart(2, "0")}`,
      idempotency_key: `capacity-key-${String(index).padStart(2, "0")}`,
      expected: { ...expected },
      events: [
        eventDraft({
          id: `client-capacity-${String(index).padStart(2, "0")}`,
          kind: "note",
          authority: "note",
          target: "panel",
          payload: { index },
        }),
      ],
    });
    expectValidResponse("publish", applied);
    expected = {
      stream_generation: applied.stream.generation,
      snapshot_id: applied.next_snapshot.snapshot_id,
      snapshot_seq: applied.next_snapshot.snapshot_seq,
      task_revision: applied.next_snapshot.task_revision,
      execution_epoch: initial.execution.fencing_epoch,
    };
  }
  const before = coordinator.getTaskFixture().task;
  const capacityError = coordinator.publish(panel.token, {
    schema_version: "1.0",
    request_id: "request-capacity-overflow",
    idempotency_key: "capacity-overflow-key",
    expected: { ...expected },
    events: [
      eventDraft({
        id: "client-capacity-overflow",
        kind: "note",
        authority: "note",
        target: "panel",
        payload: { overflow: true },
      }),
    ],
  });
  expectError(capacityError, "snapshot_capacity_exceeded");
  const after = coordinator.getTaskFixture().task;
  assert.equal(after.task_revision, before.task_revision);
  assert.equal(after.stream.head_seq, before.stream.head_seq);
});

test("snapshot TTL expiry requires a new snapshot before publish", () => {
  let now = Date.parse("2026-11-16T12:00:00.000Z");
  const { coordinator, issued } = createFixture({ now: () => now });
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(panel.token, snapshotRequest());
  now += 11 * 60 * 1000;
  const request = publishRequest({
    snapshot: snap,
    event: eventDraft(),
  });
  expectError(coordinator.publish(panel.token, request), "snapshot_required");
});

test("cursor generation mismatch returns resync_required", () => {
  const { coordinator, issued } = createFixture();
  const source = mailbox(issued, "source");
  const response = coordinator.pull(source.token, {
    schema_version: "1.0",
    request_id: "request-pull-wrong-generation",
    after: {
      generation: "stream-wrong-generation-01",
      seq: 0,
    },
    limit: 50,
  });
  const error = expectError(response, "resync_required");
  assert.equal(error.error.details.reason, "generation_mismatch");
});

test("claim lease advances fence and stale source result is rejected", () => {
  const { coordinator, issued } = createFixture();
  const source = mailbox(issued, "source");
  const snap = coordinator.snapshot(
    source.token,
    snapshotRequest("request-checkpoint-01", true),
  );
  expectValidResponse("snapshot", snap);
  assert.ok(snap.checkpoint);

  const confirmationId = coordinator.issueConfirmation(
    "claim_switch",
    "panel_hosted",
  );
  const claimRequest = {
    schema_version: "1.0",
    request_id: "request-claim-01",
    idempotency_key: "claim-key-01",
    expected: {
      execution_epoch: snap.execution.fencing_epoch,
      task_revision: snap.task.task_revision,
      checkpoint_id: snap.checkpoint.checkpoint_id,
    },
    target_mode: "panel_hosted",
    user_confirmation_id: confirmationId,
    reason: "Synthetic owner switch",
  };
  const claim = coordinator.claimLease(control(issued).token, claimRequest);
  expectValidResponse("claimLease", claim);
  assert.equal(claim.execution.fencing_epoch, 2);
  const claimReplay = coordinator.claimLease(control(issued).token, {
    ...claimRequest,
    request_id: "request-claim-duplicate-02",
  });
  expectValidResponse("claimLease", claimReplay);
  assert.equal(claimReplay.status, "duplicate");
  assert.equal(claimReplay.execution.fencing_epoch, 2);
  assert.equal(coordinator.requestPanelTurn().status, "synthetic_only");
  const claimReceipt = coordinator
    .getTaskFixture()
    .receipts.find((receipt) => receipt.operation === "claim_lease");
  assert.ok(claimReceipt);
  const claimReceiptResult = validator.validateReceipt(claimReceipt);
  assert.equal(
    claimReceiptResult.valid,
    true,
    JSON.stringify(claimReceiptResult.errors),
  );

  const newSource = mailbox(issued, "source");
  const sourceSnap = coordinator.snapshot(
    newSource.token,
    snapshotRequest("request-snapshot-after-switch"),
  );
  const stale = publishRequest({
    requestId: "request-stale-publish-01",
    key: "stale-publish-key-01",
    snapshot: sourceSnap,
    event: eventDraft({
      id: "client-event-stale-01",
      authority: "execution_result",
      kind: "agent.result",
      target: "panel",
      epoch: 1,
      payload: { result: "Old epoch result" },
    }),
  });
  expectError(coordinator.publish(newSource.token, stale), "stale_owner");
  assert.equal(
    coordinator.getTaskFixture().task.task_revision,
    claim.task_revision,
  );
});

test("release consumes confirmation, issues recovery handles, and keeps replay idempotent", () => {
  const { coordinator, issued } = createFixture();
  const controlToken = control(issued).token;
  const confirmationId = coordinator.issueConfirmation(
    "user_release",
    "suspended",
  );
  const request = {
    schema_version: "1.0",
    request_id: "request-release-01",
    idempotency_key: "release-key-01",
    expected: {
      execution_epoch: 1,
      task_revision: 1,
    },
    target_mode: "suspended",
    user_confirmation_id: confirmationId,
    confirmation_kind: "user_release",
    reason: "Synthetic user release",
  };
  const released = coordinator.releaseLease(controlToken, request);
  expectValidResponse("releaseLease", released);
  assert.equal(released.execution.mode, "suspended");
  const releaseReceipt = coordinator
    .getTaskFixture()
    .receipts.find((receipt) => receipt.operation === "release_lease");
  assert.ok(releaseReceipt);
  const releaseReceiptResult = validator.validateReceipt(releaseReceipt);
  assert.equal(
    releaseReceiptResult.valid,
    true,
    JSON.stringify(releaseReceiptResult.errors),
  );

  const duplicate = coordinator.releaseLease(control(issued).token, {
    ...request,
    request_id: "request-release-duplicate-02",
  });
  expectValidResponse("releaseLease", duplicate);
  assert.equal(duplicate.status, "duplicate");

  const recovery = mailbox(issued, "source", "recovery");
  const recoverySnap = coordinator.snapshot(
    recovery.token,
    snapshotRequest("request-recovery-snapshot-01"),
  );
  expectValidResponse("snapshot", recoverySnap);
  const recoveryAck = coordinator.ack(
    recovery.token,
    ackRequest(
      "request-recovery-ack-denied",
      recoverySnap.snapshot.stream_generation,
      [recoverySnap.task.stream.generation],
    ),
  );
  expectError(recoveryAck, "action_not_allowed");

  const recoveryPublish = publishRequest({
    requestId: "request-recovery-publish-denied",
    key: "recovery-publish-key-01",
    snapshot: recoverySnap,
    event: eventDraft({
      id: "client-event-recovery-01",
      kind: "note",
      authority: "note",
      target: "panel",
      payload: { text: "Recovery is read-only" },
    }),
  });
  expectError(
    coordinator.publish(recovery.token, recoveryPublish),
    "action_not_allowed",
  );

  const recoveryAckHandle = coordinator.issueRecoveryAckHandle("source");
  const pulled = coordinator.pull(recoveryAckHandle.token, {
    schema_version: "1.0",
    request_id: "request-recovery-pull-01",
    after: {
      generation: recoverySnap.snapshot.stream_generation,
      seq: 0,
    },
    limit: 50,
  });
  expectValidResponse("pull", pulled);
  assert.equal(pulled.events.length, 1);
  const acknowledged = coordinator.ack(
    recoveryAckHandle.token,
    ackRequest(
      "request-recovery-ack-02",
      recoveredGeneration(pulled),
      [pulled.events[0].event_id],
    ),
  );
  expectValidResponse("ack", acknowledged);
});

test("release rejects unknown and expired confirmations", () => {
  let now = Date.parse("2026-11-16T12:00:00.000Z");
  const { coordinator, issued } = createFixture({ now: () => now });
  const controlToken = control(issued).token;
  const request = (confirmationId) => ({
    schema_version: "1.0",
    request_id: `request-release-${confirmationId}`,
    idempotency_key: `release-key-${confirmationId}`,
    expected: {
      execution_epoch: 1,
      task_revision: 1,
    },
    target_mode: "suspended",
    user_confirmation_id: confirmationId,
    confirmation_kind: "user_release",
    reason: "Synthetic confirmation test",
  });
  expectError(
    coordinator.releaseLease(
      controlToken,
      request("confirmation-unknown-01"),
    ),
    "confirmation_required",
  );
  const expiredId = coordinator.issueConfirmation("user_release", "suspended");
  now += 6 * 60 * 1000;
  expectError(
    coordinator.releaseLease(controlToken, request(expiredId)),
    "confirmation_expired",
  );
});

test("checkpoint switch is blocked until both roles acknowledge", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(
    panel.token,
    snapshotRequest("request-snapshot-both-01"),
  );
  const applied = coordinator.publish(
    panel.token,
    publishRequest({
      requestId: "request-publish-both-01",
      key: "publish-both-key-01",
      snapshot: snap,
      event: eventDraft({ target: "both" }),
    }),
  );
  expectValidResponse("publish", applied);
  const checkpoint = coordinator.snapshot(
    panel.token,
    snapshotRequest("request-checkpoint-both-02", true),
  );
  expectValidResponse("snapshot", checkpoint);
  const confirmationId = coordinator.issueConfirmation(
    "claim_switch",
    "panel_hosted",
  );
  const response = coordinator.claimLease(control(issued).token, {
    schema_version: "1.0",
    request_id: "request-claim-incomplete-01",
    idempotency_key: "claim-incomplete-key-01",
    expected: {
      execution_epoch: checkpoint.execution.fencing_epoch,
      task_revision: checkpoint.task.task_revision,
      checkpoint_id: checkpoint.checkpoint.checkpoint_id,
    },
    target_mode: "panel_hosted",
    user_confirmation_id: confirmationId,
    reason: "Synthetic incomplete checkpoint",
  });
  expectError(response, "checkpoint_incomplete");
});

function recoveredGeneration(pullResponse) {
  return pullResponse.cursor.generation;
}

test("ack limits return payload_too_large or invalid_request before mutation", () => {
  const { coordinator, issued } = createFixture();
  const source = mailbox(issued, "source");
  const generation =
    coordinator.getTaskFixture().task.stream.generation;

  const tooMany = coordinator.ack(
    source.token,
    ackRequest(
      "request-ack-too-many",
      generation,
      Array.from({ length: 201 }, (_, index) => `event-${index}`),
    ),
  );
  expectError(tooMany, "payload_too_large");

  const empty = coordinator.ack(
    source.token,
    ackRequest("request-ack-empty", generation, []),
  );
  expectError(empty, "invalid_request");

  const oversized = coordinator.ack(source.token, {
    schema_version: "1.0",
    request_id: "request-ack-oversized",
    stream_generation: generation,
    event_ids: ["x".repeat(70_000)],
  });
  expectError(oversized, "payload_too_large");
});

test("body-size measurement fails closed for cyclic and BigInt requests", () => {
  const { coordinator, issued } = createFixture();
  const source = mailbox(issued, "source");
  const cyclic = {
    schema_version: "1.0",
    request_id: "request-cyclic-publish",
  };
  cyclic.self = cyclic;
  let response;
  assert.doesNotThrow(() => {
    response = coordinator.publish(source.token, cyclic);
  });
  expectError(response, "schema_invalid");

  const bigintAck = {
    schema_version: "1.0",
    request_id: "request-bigint-ack",
    stream_generation:
      coordinator.getTaskFixture().task.stream.generation,
    event_ids: [1n],
  };
  assert.doesNotThrow(() => {
    response = coordinator.ack(source.token, bigintAck);
  });
  expectError(response, "schema_invalid");
});

test("idempotency receipts validate and contain no raw capabilities", () => {
  const { coordinator, issued } = createFixture();
  const panel = mailbox(issued, "panel");
  const snap = coordinator.snapshot(panel.token, snapshotRequest());
  const applied = coordinator.publish(
    panel.token,
    publishRequest({
      snapshot: snap,
      event: eventDraft(),
    }),
  );
  expectValidResponse("publish", applied);
  const receipts = coordinator.getTaskFixture().receipts;
  assert.equal(receipts.length, 1);
  const result = validator.validateReceipt(receipts[0]);
  assert.equal(result.valid, true, JSON.stringify(result.errors));
  const serialized = JSON.stringify(receipts[0]);
  assert.equal(serialized.includes(panel.token), false);
  assert.equal(/[A-Za-z]:[\\/]/u.test(serialized), false);
});

test("reference coordinator stores only SHA-256 capability verifiers", () => {
  const { coordinator, issued } = createFixture();
  assert.ok(issued.length >= 3);
  const verifierKeys = [...coordinator.authorities.keys()];
  assert.ok(verifierKeys.length >= 3);
  assert.ok(
    verifierKeys.every((value) => /^[a-f0-9]{64}$/u.test(value)),
  );
  const serialized = JSON.stringify(verifierKeys);
  for (const item of issued) {
    assert.equal(serialized.includes(item.token), false);
  }
});
