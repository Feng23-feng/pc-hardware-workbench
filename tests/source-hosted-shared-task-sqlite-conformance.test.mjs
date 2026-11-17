import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  existsSync,
  readdirSync,
  readFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import test from "node:test";

let sqliteAvailable = true;
try {
  await import("node:sqlite");
} catch {
  sqliteAvailable = false;
}

if (!sqliteAvailable) {
  test("SQLite conformance harness requires node:sqlite", {
    skip: "node:sqlite is unavailable in this Node runtime",
  }, () => {});
} else {
  const { DatabaseSync } = await import("node:sqlite");
  const {
    createTempSqliteFixture,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/fixture.mjs"
  );
  const {
    SCHEMA_V1_SHA256,
    SQLITE_SCHEMA_VERSION,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/schema-v1.mjs"
  );
  const {
    InjectedFault,
    openSqliteConformanceCoordinator,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/sqlite-coordinator.mjs"
  );
  const {
    createContractValidator,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/reference/contract-validator.mjs"
  );

  const root = resolve(import.meta.dirname, "..");
  const workerPath = resolve(
    root,
    "contracts",
    "source-hosted-shared-task",
    "v1",
    "persistence",
    "worker.mjs",
  );
  const validator = createContractValidator();

  function snapshotRequest(requestId = "request-sqlite-snapshot-01") {
    return {
      schema_version: "1.0",
      request_id: requestId,
      include: [
        "task",
        "execution",
        "delivery_ack_state",
        "pending_counts",
      ],
      checkpoint: false,
    };
  }

  function publishRequest(snapshot, {
    requestId = "request-sqlite-publish-01",
    key = "sqlite-publish-key-01",
    clientEventId = "sqlite-client-event-01",
    payload = { text: "Synthetic SQLite event" },
    expectedRevision = snapshot.task.task_revision,
  } = {}) {
    return {
      schema_version: "1.0",
      request_id: requestId,
      idempotency_key: key,
      expected: {
        stream_generation: snapshot.snapshot.stream_generation,
        snapshot_id: snapshot.snapshot.snapshot_id,
        snapshot_seq: snapshot.snapshot.snapshot_seq,
        task_revision: expectedRevision,
        execution_epoch: snapshot.execution.fencing_epoch,
      },
      events: [
        {
          client_event_id: clientEventId,
          kind: "note",
          authority: "note",
          target_role: "panel",
          execution_epoch: snapshot.execution.fencing_epoch,
          origin: {
            session_ref: null,
            turn_id: null,
            item_id: null,
          },
          payload,
        },
      ],
    };
  }

  function pullRequest(generation, afterSeq, {
    requestId = "request-sqlite-pull-01",
    limit = 50,
  } = {}) {
    return {
      schema_version: "1.0",
      request_id: requestId,
      after: {
        generation,
        seq: afterSeq,
      },
      limit,
    };
  }

  function ackRequest(generation, eventIds, {
    requestId = "request-sqlite-ack-01",
  } = {}) {
    return {
      schema_version: "1.0",
      request_id: requestId,
      stream_generation: generation,
      event_ids: eventIds,
    };
  }

  function assertIntegrity(db) {
    assert.deepEqual(db.prepare("PRAGMA foreign_key_check").all(), []);
    const integrity = db.prepare("PRAGMA integrity_check").all();
    assert.equal(integrity.length, 1);
    assert.equal(integrity[0].integrity_check, "ok");
  }

  function runWorker({ dbPath, token, request, faultPoint = "" }) {
    return new Promise((resolvePromise, rejectPromise) => {
      const child = spawn(process.execPath, [workerPath], {
        cwd: root,
        windowsHide: true,
        env: {
          ...process.env,
          SQ_DB_PATH: dbPath,
          SQ_ACTION: "publish",
          SQ_FAULT_POINT: faultPoint,
        },
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });
      child.once("error", rejectPromise);
      child.once("exit", (code, signal) => {
        let response = null;
        if (stdout.trim()) {
          try {
            response = JSON.parse(stdout.trim());
          } catch {
            // The caller will fail on the malformed worker response.
          }
        }
        resolvePromise({
          code,
          signal,
          stdout,
          stderr,
          response,
        });
      });
      child.stdin.end(JSON.stringify({ token, request }));
    });
  }

  test("SQLite schema v1 applies WAL profile and is migration-idempotent", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, dbPath } = fixture;
      assert.equal(coordinator.pragmas.journal_mode, "wal");
      assert.equal(coordinator.pragmas.synchronous, 2);
      assert.equal(coordinator.pragmas.foreign_keys, 1);
      assert.equal(coordinator.migration.applied, true);
      assert.deepEqual(coordinator.integrity.foreign_keys, []);
      assert.equal(
        coordinator.db.prepare("PRAGMA user_version").get().user_version,
        SQLITE_SCHEMA_VERSION,
      );
      const migration = coordinator.db.prepare(
        "SELECT checksum FROM schema_migrations WHERE version = 1",
      ).get();
      assert.equal(migration.checksum, SCHEMA_V1_SHA256);

      fixture.close();
      const reopened = openSqliteConformanceCoordinator({ dbPath });
      try {
        assert.equal(reopened.migration.applied, false);
        assert.equal(reopened.migration.version, 1);
      } finally {
        reopened.close();
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("migration checksum mismatch fails closed on reopen", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { dbPath } = fixture;
      fixture.coordinator.db.prepare(
        "UPDATE schema_migrations SET checksum = ? WHERE version = 1",
      ).run("0".repeat(64));
      fixture.close();
      assert.throws(
        () => openSqliteConformanceCoordinator({ dbPath }),
        /checksum mismatch/u,
      );
    } finally {
      fixture.cleanup();
    }
  });

  test("fixture stores only capability verifiers and preserves raw tokens in memory", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const rows = coordinator.db.prepare(
        "SELECT verifier_sha256, handle_id FROM authority_verifiers",
      ).all();
      assert.equal(rows.length, 3);
      assert.ok(
        rows.every((row) => /^[a-f0-9]{64}$/u.test(row.verifier_sha256)),
      );
      const serialized = JSON.stringify(rows);
      for (const token of Object.values(bootstrap.tokens)) {
        assert.equal(serialized.includes(token), false);
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("raw capability tokens never appear in DB or sidecar bytes", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { dir, bootstrap } = fixture;
      fixture.close();
      const bytes = readdirSync(dir)
        .map((name) => readFileSync(join(dir, name)))
        .reduce((all, part) => Buffer.concat([all, part]), Buffer.alloc(0));
      for (const token of Object.values(bootstrap.tokens)) {
        assert.equal(bytes.includes(Buffer.from(token, "utf8")), false);
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("snapshot and publish commit Task, event, revision, snapshot and receipt atomically", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const snapshot = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest(),
      );
      assert.equal(validator.validateResponse("snapshot", snapshot).valid, true);
      const request = publishRequest(snapshot);
      assert.equal(validator.validateRequest("publish", request).valid, true);
      const response = coordinator.publish(bootstrap.tokens.panel, request);
      assert.equal(
        validator.validateResponse("publish", response).valid,
        true,
      );
      assert.equal(response.status, "applied");
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.task.task_revision, 2);
      assert.equal(state.task.stream.head_seq, 1);
      assert.equal(state.counts.events, 1);
      assert.equal(state.counts.receipts, 1);
      assert.equal(state.counts.mutations, 1);
      assert.equal(state.integrity.foreign_keys.length, 0);
    } finally {
      fixture.cleanup();
    }
  });

  test("duplicate publish replays from persisted receipt after restart", () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const snapshot = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest(),
      );
      const request = publishRequest(snapshot);
      const applied = coordinator.publish(
        fixture.bootstrap.tokens.panel,
        request,
      );
      assert.equal(applied.status, "applied");

      coordinator = fixture.reopen();
      const duplicate = coordinator.publish(
        fixture.bootstrap.tokens.panel,
        {
          ...request,
          request_id: "request-sqlite-publish-duplicate",
        },
      );
      assert.equal(duplicate.status, "duplicate");
      assert.equal(duplicate.receipt.original_request_id, request.request_id);
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.counts.events, 1);
      assert.equal(state.counts.receipts, 1);
      assert.equal(state.task.task_revision, 2);
    } finally {
      fixture.cleanup();
    }
  });

  test("pull watermark and sparse ack coverage persist across restart", () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const snapshot = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-pull-ack-snapshot"),
      );
      const request = publishRequest(snapshot, {
        requestId: "request-pull-ack-publish",
        key: "pull-ack-publish-key",
        clientEventId: "pull-ack-client-1",
        payload: { text: "First event" },
      });
      request.events.push({
        ...request.events[0],
        client_event_id: "pull-ack-client-2",
        payload: { text: "Second event" },
      });
      for (const event of request.events) {
        event.target_role = "source";
      }
      const published = coordinator.publish(
        fixture.bootstrap.tokens.panel,
        request,
      );
      assert.equal(published.events.length, 2);
      const generation = published.stream.generation;
      const eventA = published.events[0].event_id;
      const eventB = published.events[1].event_id;

      const pulled = coordinator.pull(
        fixture.bootstrap.tokens.source,
        pullRequest(generation, 0, {
          requestId: "request-pull-source-events",
        }),
      );
      assert.equal(validator.validateResponse("pull", pulled).valid, true);
      assert.equal(pulled.events.length, 2);
      assert.equal(pulled.delivery.delivered_seq_prefix, 2);

      const ackOne = coordinator.ack(
        fixture.bootstrap.tokens.source,
        ackRequest(generation, [eventA], {
          requestId: "request-ack-source-sparse",
        }),
      );
      assert.equal(validator.validateResponse("ack", ackOne).valid, true);
      assert.equal(ackOne.ack.ack_coverage_prefix, 1);
      assert.equal(
        coordinator.fixtureSnapshot().task.task_revision,
        published.task_revision,
      );

      coordinator = fixture.reopen();
      const ackTwo = coordinator.ack(
        fixture.bootstrap.tokens.source,
        ackRequest(generation, [eventB], {
          requestId: "request-ack-source-after-restart",
        }),
      );
      assert.equal(ackTwo.ack.ack_coverage_prefix, 2);
      const duplicateAck = coordinator.ack(
        fixture.bootstrap.tokens.source,
        ackRequest(generation, [eventA], {
          requestId: "request-ack-source-duplicate",
        }),
      );
      assert.deepEqual(duplicateAck.already_acked_event_ids, [eventA]);
      assert.equal(
        coordinator.fixtureSnapshot().delivery_ack_state.source
          .delivered_seq_prefix,
        2,
      );
      assert.equal(
        coordinator.fixtureSnapshot().delivery_ack_state.source
          .ack_coverage_prefix,
        2,
      );
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("pull and ack fault before COMMIT roll back delivery and coverage", () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const snapshot = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-pull-fault-snapshot"),
      );
      const published = coordinator.publish(
        fixture.bootstrap.tokens.panel,
        (() => {
          const request = publishRequest(snapshot, {
          requestId: "request-pull-fault-publish",
          key: "pull-fault-publish-key",
          clientEventId: "pull-fault-client",
          });
          request.events[0].target_role = "source";
          return request;
        })(),
      );
      const generation = published.stream.generation;
      const eventId = published.events[0].event_id;
      assert.throws(
        () => coordinator.pull(
          fixture.bootstrap.tokens.source,
          pullRequest(generation, 0, {
            requestId: "request-pull-fault-injected",
          }),
          {
            faultInjector(point) {
              if (point === "before_commit") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      assert.equal(
        coordinator.fixtureSnapshot().delivery_ack_state.source
          .delivered_seq_prefix,
        0,
      );
      const pulled = coordinator.pull(
        fixture.bootstrap.tokens.source,
        pullRequest(generation, 0, {
          requestId: "request-pull-after-fault",
        }),
      );
      assert.equal(pulled.delivery.delivered_seq_prefix, 1);
      assert.throws(
        () => coordinator.ack(
          fixture.bootstrap.tokens.source,
          ackRequest(generation, [eventId], {
            requestId: "request-ack-fault-injected",
          }),
          {
            faultInjector(point) {
              if (point === "before_commit") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.delivery_ack_state.source.ack_coverage_prefix, 0);
      coordinator = fixture.reopen();
      const ack = coordinator.ack(
        fixture.bootstrap.tokens.source,
        ackRequest(generation, [eventId], {
          requestId: "request-ack-after-fault",
        }),
      );
      assert.equal(ack.ack.ack_coverage_prefix, 1);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("pull/ack conflicts fail without changing delivery or coverage", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const snapshot = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest("request-ack-conflict-snapshot"),
      );
      const published = coordinator.publish(
        bootstrap.tokens.panel,
        publishRequest(snapshot, {
          requestId: "request-ack-conflict-publish",
          key: "ack-conflict-publish-key",
          clientEventId: "ack-conflict-client",
          payload: { text: "Panel-targeted event" },
        }),
      );
      const generation = published.stream.generation;
      const eventId = published.events[0].event_id;
      const wrongGeneration = coordinator.pull(
        bootstrap.tokens.source,
        pullRequest("stream-wrong-generation", 0, {
          requestId: "request-pull-wrong-generation",
        }),
      );
      assert.equal(wrongGeneration.error.code, "resync_required");

      const notDelivered = coordinator.ack(
        bootstrap.tokens.source,
        ackRequest(generation, [eventId], {
          requestId: "request-ack-not-delivered",
        }),
      );
      assert.equal(notDelivered.error.code, "ack_not_delivered");
      const pulled = coordinator.pull(
        bootstrap.tokens.source,
        pullRequest(generation, 0, {
          requestId: "request-pull-panel-event-for-source",
        }),
      );
      assert.equal(pulled.delivery.delivered_seq_prefix, 1);
      const notAllowed = coordinator.ack(
        bootstrap.tokens.source,
        ackRequest(generation, [eventId], {
          requestId: "request-ack-not-allowed",
        }),
      );
      assert.equal(notAllowed.error.code, "ack_not_allowed");
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.delivery_ack_state.source.ack_coverage_prefix, 0);
      assert.equal(state.task.task_revision, published.task_revision);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("fault before COMMIT rolls back event, revision, snapshot and receipt", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const snapshot = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest(),
      );
      const request = publishRequest(snapshot);
      assert.throws(
        () => coordinator.publish(
          bootstrap.tokens.panel,
          request,
          {
            faultInjector(point) {
              if (point === "before_commit") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.task.task_revision, 1);
      assert.equal(state.task.stream.head_seq, 0);
      assert.equal(state.counts.events, 0);
      assert.equal(state.counts.receipts, 0);
      assert.equal(state.counts.mutations, 0);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("fault after COMMIT leaves replayable receipt and complete Task state", () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const snapshot = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest(),
      );
      const request = publishRequest(snapshot);
      assert.throws(
        () => coordinator.publish(
          fixture.bootstrap.tokens.panel,
          request,
          {
            faultInjector(point) {
              if (point === "after_commit_before_response") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      coordinator = fixture.reopen();
      const duplicate = coordinator.publish(
        fixture.bootstrap.tokens.panel,
        {
          ...request,
          request_id: "request-sqlite-after-commit-replay",
        },
      );
      assert.equal(duplicate.status, "duplicate");
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.counts.events, 1);
      assert.equal(state.counts.receipts, 1);
      assert.equal(state.task.task_revision, 2);
    } finally {
      fixture.cleanup();
    }
  });

  test("claim lease rotates capabilities and duplicate replays after restart", () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const checkpoint = coordinator.snapshot(
        fixture.bootstrap.tokens.source,
        {
          ...snapshotRequest("request-claim-checkpoint"),
          checkpoint: true,
        },
      );
      assert.ok(checkpoint.checkpoint);
      const confirmation = coordinator.issueConfirmation(
        fixture.bootstrap.tokens.control,
        "claim_switch",
        "panel_hosted",
      );
      assert.equal(confirmation.ok, true);
      const request = {
        schema_version: "1.0",
        request_id: "request-claim-panel",
        idempotency_key: "claim-panel-key",
        expected: {
          execution_epoch: checkpoint.execution.fencing_epoch,
          task_revision: checkpoint.task.task_revision,
          checkpoint_id: checkpoint.checkpoint.checkpoint_id,
        },
        target_mode: "panel_hosted",
        user_confirmation_id: confirmation.confirmation_id,
        reason: "Synthetic SQLite claim",
      };
      const claimed = coordinator.claimLease(
        fixture.bootstrap.tokens.control,
        request,
      );
      assert.equal(validator.validateResponse("claimLease", claimed).valid, true);
      assert.equal(claimed.execution.fencing_epoch, 2);
      const rotated = coordinator.takeIssuedCapabilities();
      assert.ok(rotated?.panel);
      assert.ok(rotated?.control);
      const oldToken = coordinator.snapshot(
        fixture.bootstrap.tokens.source,
        snapshotRequest("request-old-token-after-claim"),
      );
      assert.equal(oldToken.error.code, "capability_revoked");
      const newPanelSnapshot = coordinator.snapshot(
        rotated.panel,
        snapshotRequest("request-new-token-after-claim"),
      );
      assert.equal(newPanelSnapshot.ok, true);

      coordinator = fixture.reopen();
      const duplicate = coordinator.claimLease(rotated.control, {
        ...request,
        request_id: "request-claim-panel-duplicate",
      });
      assert.equal(
        validator.validateResponse("claimLease", duplicate).valid,
        true,
      );
      assert.equal(duplicate.status, "duplicate");
      assert.equal(duplicate.execution.fencing_epoch, 2);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("claim conflict and incomplete checkpoint fail without mutation", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const snapshot = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest("request-claim-conflict-snapshot"),
      );
      const applied = coordinator.publish(
        bootstrap.tokens.panel,
        publishRequest(snapshot, {
          requestId: "request-claim-conflict-publish",
          key: "claim-conflict-publish-key",
          clientEventId: "claim-conflict-client",
          ...{},
          payload: { text: "Both roles must ack this" },
        }),
      );
      // The event targets panel by default; create a separate both-target event.
      const nextSnapshot = {
        snapshot: {
          stream_generation: applied.stream.generation,
          snapshot_id: applied.next_snapshot.snapshot_id,
          snapshot_seq: applied.next_snapshot.snapshot_seq,
        },
        task: { task_revision: applied.next_snapshot.task_revision },
        execution: { fencing_epoch: snapshot.execution.fencing_epoch },
      };
      const bothRequest = publishRequest(nextSnapshot, {
        requestId: "request-claim-conflict-publish-both",
        key: "claim-conflict-publish-both-key",
        clientEventId: "claim-conflict-client-both",
      });
      bothRequest.events[0].target_role = "both";
      coordinator.publish(bootstrap.tokens.panel, bothRequest);
      const checkpoint = coordinator.snapshot(
        bootstrap.tokens.source,
        {
          ...snapshotRequest("request-claim-conflict-checkpoint"),
          checkpoint: true,
        },
      );
      const confirmation = coordinator.issueConfirmation(
        bootstrap.tokens.control,
        "claim_switch",
        "panel_hosted",
      );
      const request = {
        schema_version: "1.0",
        request_id: "request-claim-conflict",
        idempotency_key: "claim-conflict-key",
        expected: {
          execution_epoch: checkpoint.execution.fencing_epoch,
          task_revision: checkpoint.task.task_revision,
          checkpoint_id: checkpoint.checkpoint.checkpoint_id,
        },
        target_mode: "panel_hosted",
        user_confirmation_id: confirmation.confirmation_id,
        reason: "Synthetic incomplete claim",
      };
      const before = coordinator.fixtureSnapshot();
      const incomplete = coordinator.claimLease(
        bootstrap.tokens.control,
        request,
      );
      assert.equal(incomplete.error.code, "checkpoint_incomplete");
      const after = coordinator.fixtureSnapshot();
      assert.equal(after.task.mode, before.task.mode);
      assert.equal(after.task.task_revision, before.task.task_revision);

      const wrongEpoch = coordinator.claimLease(
        bootstrap.tokens.control,
        {
          ...request,
          request_id: "request-claim-conflict-epoch",
          idempotency_key: "claim-conflict-epoch-key",
          expected: {
            ...request.expected,
            execution_epoch: request.expected.execution_epoch + 1,
          },
        },
      );
      assert.equal(wrongEpoch.error.code, "lease_conflict");
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("claim fault before COMMIT preserves owner, checkpoint and confirmation", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const checkpoint = coordinator.snapshot(
        bootstrap.tokens.source,
        {
          ...snapshotRequest("request-claim-fault-checkpoint"),
          checkpoint: true,
        },
      );
      const confirmation = coordinator.issueConfirmation(
        bootstrap.tokens.control,
        "claim_switch",
        "panel_hosted",
      );
      const request = {
        schema_version: "1.0",
        request_id: "request-claim-fault",
        idempotency_key: "claim-fault-key",
        expected: {
          execution_epoch: checkpoint.execution.fencing_epoch,
          task_revision: checkpoint.task.task_revision,
          checkpoint_id: checkpoint.checkpoint.checkpoint_id,
        },
        target_mode: "panel_hosted",
        user_confirmation_id: confirmation.confirmation_id,
        reason: "Synthetic claim fault",
      };
      assert.throws(
        () => coordinator.claimLease(
          bootstrap.tokens.control,
          request,
          {
            faultInjector(point) {
              if (point === "before_commit") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.task.mode, "source_hosted");
      assert.equal(state.task.execution.fencing_epoch, 1);
      assert.equal(state.task.task_revision, 1);
      assert.equal(
        coordinator.db.prepare(
          "SELECT consumed_at_ms FROM confirmations WHERE confirmation_id = ?",
        ).get(confirmation.confirmation_id).consumed_at_ms,
        null,
      );
      assert.equal(
        coordinator.db.prepare(
          "SELECT consumed_at_ms FROM mailbox_checkpoints WHERE checkpoint_id = ?",
        ).get(checkpoint.checkpoint.checkpoint_id).consumed_at_ms,
        null,
      );
      const stillValid = coordinator.snapshot(
        bootstrap.tokens.source,
        snapshotRequest("request-claim-fault-old-token"),
      );
      assert.equal(stillValid.ok, true);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("release lease persists recovery capabilities and duplicate after restart", () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const confirmation = coordinator.issueConfirmation(
        fixture.bootstrap.tokens.control,
        "user_release",
        "suspended",
      );
      const request = {
        schema_version: "1.0",
        request_id: "request-release-sqlite",
        idempotency_key: "release-sqlite-key",
        expected: {
          execution_epoch: 1,
          task_revision: 1,
        },
        target_mode: "suspended",
        user_confirmation_id: confirmation.confirmation_id,
        confirmation_kind: "user_release",
        reason: "Synthetic SQLite release",
      };
      const released = coordinator.releaseLease(
        fixture.bootstrap.tokens.control,
        request,
      );
      assert.equal(validator.validateResponse("releaseLease", released).valid, true);
      assert.equal(released.execution.mode, "suspended");
      const rotated = coordinator.takeIssuedCapabilities();
      assert.ok(rotated?.source);
      assert.ok(rotated?.panel);
      assert.ok(rotated?.control);
      const recoverySnapshot = coordinator.snapshot(
        rotated.panel,
        snapshotRequest("request-release-recovery-snapshot"),
      );
      assert.equal(recoverySnapshot.ok, true);
      const oldToken = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-old-panel-after-release"),
      );
      assert.equal(oldToken.error.code, "capability_revoked");

      coordinator = fixture.reopen();
      const duplicate = coordinator.releaseLease(rotated.control, {
        ...request,
        request_id: "request-release-sqlite-duplicate",
      });
      assert.equal(
        validator.validateResponse("releaseLease", duplicate).valid,
        true,
      );
      assert.equal(duplicate.status, "duplicate");
      assert.equal(duplicate.execution.mode, "suspended");
      const secondRelease = coordinator.releaseLease(rotated.control, {
        ...request,
        request_id: "request-release-sqlite-conflict",
        idempotency_key: "release-sqlite-conflict-key",
      });
      assert.equal(secondRelease.error.code, "lease_conflict");
      assert.equal(secondRelease.error.details.reason, "task_already_suspended");
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("release fault before COMMIT keeps source owner and confirmation usable", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const confirmation = coordinator.issueConfirmation(
        bootstrap.tokens.control,
        "user_release",
        "suspended",
      );
      const request = {
        schema_version: "1.0",
        request_id: "request-release-fault",
        idempotency_key: "release-fault-key",
        expected: {
          execution_epoch: 1,
          task_revision: 1,
        },
        target_mode: "suspended",
        user_confirmation_id: confirmation.confirmation_id,
        confirmation_kind: "user_release",
        reason: "Synthetic release fault",
      };
      assert.throws(
        () => coordinator.releaseLease(
          bootstrap.tokens.control,
          request,
          {
            faultInjector(point) {
              if (point === "before_commit") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.task.mode, "source_hosted");
      assert.equal(state.task.execution.fencing_epoch, 1);
      assert.equal(
        coordinator.db.prepare(
          "SELECT consumed_at_ms FROM confirmations WHERE confirmation_id = ?",
        ).get(confirmation.confirmation_id).consumed_at_ms,
        null,
      );
      const stillValid = coordinator.snapshot(
        bootstrap.tokens.source,
        snapshotRequest("request-release-fault-old-token"),
      );
      assert.equal(stillValid.ok, true);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("two worker processes commit one transaction for the same idempotency key", async () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const snapshot = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest(),
      );
      const request = publishRequest(snapshot);
      const { dbPath } = fixture;
      const token = fixture.bootstrap.tokens.panel;
      fixture.close();
      coordinator = null;

      const results = await Promise.all([
        runWorker({ dbPath, token, request }),
        runWorker({ dbPath, token, request }),
      ]);
      assert.deepEqual(results.map((item) => item.code), [0, 0]);
      assert.deepEqual(
        results.map((item) => item.response?.status).sort(),
        ["applied", "duplicate"],
      );

      const inspect = openSqliteConformanceCoordinator({ dbPath });
      try {
        const state = inspect.fixtureSnapshot();
        assert.equal(state.counts.events, 1);
        assert.equal(state.counts.receipts, 1);
        assert.equal(state.counts.mutations, 1);
        assertIntegrity(inspect.db);
      } finally {
        inspect.close();
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("two worker processes different keys racing one revision yield one conflict", async () => {
    const fixture = createTempSqliteFixture();
    try {
      let coordinator = fixture.coordinator;
      const snapshot = coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-race-revision-snapshot"),
      );
      const firstRequest = publishRequest(snapshot, {
        requestId: "request-race-revision-a",
        key: "race-revision-key-a",
        clientEventId: "race-client-event-a",
      });
      const secondRequest = publishRequest(snapshot, {
        requestId: "request-race-revision-b",
        key: "race-revision-key-b",
        clientEventId: "race-client-event-b",
      });
      const { dbPath } = fixture;
      const token = fixture.bootstrap.tokens.panel;
      fixture.close();
      coordinator = null;

      const results = await Promise.all([
        runWorker({ dbPath, token, request: firstRequest }),
        runWorker({ dbPath, token, request: secondRequest }),
      ]);
      assert.deepEqual(results.map((item) => item.code), [0, 0]);
      const outcomes = results.map(
        (item) => item.response?.status ?? item.response?.error?.code,
      ).sort();
      assert.deepEqual(outcomes, ["applied", "revision_conflict"]);
      const inspect = openSqliteConformanceCoordinator({ dbPath });
      try {
        const state = inspect.fixtureSnapshot();
        assert.equal(state.counts.events, 1);
        assert.equal(state.counts.receipts, 1);
        assert.equal(state.task.task_revision, 2);
      } finally {
        inspect.close();
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("worker crash before COMMIT leaves no partial transaction", async () => {
    const fixture = createTempSqliteFixture();
    try {
      const snapshot = fixture.coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-crash-before-snapshot"),
      );
      const request = publishRequest(snapshot, {
        requestId: "request-crash-before-publish",
        key: "crash-before-key",
        clientEventId: "crash-before-client",
      });
      const { dbPath } = fixture;
      const token = fixture.bootstrap.tokens.panel;
      fixture.close();
      const worker = await runWorker({
        dbPath,
        token,
        request,
        faultPoint: "before_commit",
      });
      assert.equal(worker.code, 78);
      const inspect = openSqliteConformanceCoordinator({ dbPath });
      try {
        const state = inspect.fixtureSnapshot();
        assert.equal(state.task.task_revision, 1);
        assert.equal(state.task.stream.head_seq, 0);
        assert.equal(state.counts.events, 0);
        assert.equal(state.counts.receipts, 0);
        assertIntegrity(inspect.db);
      } finally {
        inspect.close();
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("worker crash after COMMIT is recovered through duplicate replay", async () => {
    const fixture = createTempSqliteFixture();
    try {
      const snapshot = fixture.coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-crash-after-snapshot"),
      );
      const request = publishRequest(snapshot, {
        requestId: "request-crash-after-publish",
        key: "crash-after-key",
        clientEventId: "crash-after-client",
      });
      const { dbPath } = fixture;
      const token = fixture.bootstrap.tokens.panel;
      fixture.close();
      const worker = await runWorker({
        dbPath,
        token,
        request,
        faultPoint: "after_commit_before_response",
      });
      assert.equal(worker.code, 77);
      const inspect = openSqliteConformanceCoordinator({ dbPath });
      try {
        const duplicate = inspect.publish(token, {
          ...request,
          request_id: "request-crash-after-replay",
        });
        assert.equal(duplicate.status, "duplicate");
        const state = inspect.fixtureSnapshot();
        assert.equal(state.counts.events, 1);
        assert.equal(state.counts.receipts, 1);
        assert.equal(state.task.task_revision, 2);
        assertIntegrity(inspect.db);
      } finally {
        inspect.close();
      }
    } finally {
      fixture.cleanup();
    }
  });

  test("generation reset rotates capabilities and clears delivery/ack watermarks", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const oldGeneration = bootstrap.stream_generation;
      const oldSnapshot = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest("request-pre-reset-snapshot"),
      );
      const oldPublishRequest = publishRequest(oldSnapshot, {
        requestId: "request-pre-reset-publish",
        key: "pre-reset-publish-key",
        clientEventId: "pre-reset-client-event",
      });
      const oldPublish = coordinator.publish(
        bootstrap.tokens.panel,
        oldPublishRequest,
      );
      assert.equal(oldPublish.status, "applied");
      coordinator.db.prepare(
        `UPDATE mailbox_delivery_state
         SET delivered_seq_prefix = 7, ack_coverage_prefix = 5
         WHERE task_id = ?`,
      ).run(bootstrap.task_id);
      const reset = coordinator.resetGeneration(bootstrap.tokens.control);
      assert.notEqual(reset.stream_generation, oldGeneration);
      assert.equal(reset.task_revision, 3);
      const task = coordinator.fixtureSnapshot();
      assert.equal(task.task.stream.generation, reset.stream_generation);
      assert.equal(
        task.delivery_ack_state.source.delivered_seq_prefix,
        0,
      );
      assert.equal(
        task.delivery_ack_state.source.ack_coverage_prefix,
        0,
      );
      assert.equal(
        task.delivery_ack_state.panel.delivered_seq_prefix,
        0,
      );

      const oldTokenResponse = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest("request-old-token-after-reset"),
      );
      assert.equal(oldTokenResponse.error.code, "capability_revoked");

      const oldReceiptReplay = coordinator.publish(
        reset.tokens.panel,
        {
          ...oldPublishRequest,
          request_id: "request-post-reset-old-receipt",
        },
      );
      assert.equal(oldReceiptReplay.status, "duplicate");

      const newSnapshot = coordinator.snapshot(
        reset.tokens.panel,
        snapshotRequest("request-new-generation-snapshot"),
      );
      assert.equal(newSnapshot.ok, true);
      assert.equal(
        coordinator.db.prepare(
          `SELECT COUNT(*) AS count FROM stream_generations
           WHERE task_id = ? AND retired_at_ms IS NULL`,
        ).get(bootstrap.task_id).count,
        1,
      );
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("generation reset fault before COMMIT rolls back generation and capabilities", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      assert.throws(
        () => coordinator.resetGeneration(
          bootstrap.tokens.control,
          {
            faultInjector(point) {
              if (point === "before_commit") {
                throw new InjectedFault(point);
              }
            },
          },
        ),
        /Injected fault/u,
      );
      const state = coordinator.fixtureSnapshot();
      assert.equal(state.task.stream.generation, bootstrap.stream_generation);
      assert.equal(state.task.task_revision, 1);
      assert.equal(
        coordinator.db.prepare(
          `SELECT COUNT(*) AS count FROM stream_generations
           WHERE task_id = ? AND retired_at_ms IS NULL`,
        ).get(bootstrap.task_id).count,
        1,
      );
      const stillValid = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest("request-reset-rollback-old-token"),
      );
      assert.equal(stillValid.ok, true);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("foreign keys reject orphan generations and retired current generation", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      assert.throws(() => {
        coordinator.db.prepare(
          `UPDATE mailbox_delivery_state SET generation = ?
           WHERE task_id = ? AND actor_role = 'source'`,
        ).run("stream-missing-generation", bootstrap.task_id);
      }, /FOREIGN KEY constraint failed/u);

      coordinator.db.prepare(
        `INSERT INTO stream_generations(
          task_id, generation, created_at_ms, retired_at_ms, reason
        ) VALUES(?, ?, ?, ?, ?)`,
      ).run(
        bootstrap.task_id,
        "stream-retired-generation",
        Date.now(),
        Date.now(),
        "fixture",
      );
      assert.throws(() => {
        coordinator.db.prepare(
          "UPDATE tasks SET stream_generation = ? WHERE task_id = ?",
        ).run("stream-retired-generation", bootstrap.task_id);
      }, /task current generation missing or retired/u);
      assert.throws(() => {
        coordinator.db.prepare(
          `UPDATE authority_verifiers SET stream_generation = ?
           WHERE task_id = ? AND kind = 'mailbox'`,
        ).run("stream-retired-generation", bootstrap.task_id);
      }, /authority verifier generation is missing or retired/u);
      assert.throws(() => {
        coordinator.db.prepare(
          `UPDATE authority_verifiers SET stream_generation = ?
           WHERE task_id = ? AND kind = 'mailbox'`,
        ).run("stream-missing-generation", bootstrap.task_id);
      }, /authority verifier generation is missing or retired|FOREIGN KEY constraint failed/u);
      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("composite foreign keys reject cross-Task event, ack, receipt and transition references", () => {
    const fixture = createTempSqliteFixture();
    try {
      const { coordinator, bootstrap } = fixture;
      const snapshot = coordinator.snapshot(
        bootstrap.tokens.panel,
        snapshotRequest("request-cross-task-snapshot"),
      );
      const applied = coordinator.publish(
        bootstrap.tokens.panel,
        publishRequest(snapshot, {
          requestId: "request-cross-task-publish-a",
          key: "cross-task-key-a",
          clientEventId: "cross-task-client-a",
        }),
      );
      const eventA = coordinator.db.prepare(
        "SELECT event_id FROM events WHERE task_id = ? LIMIT 1",
      ).get(bootstrap.task_id);
      const mutationA = coordinator.db.prepare(
        "SELECT mutation_id FROM mutations WHERE task_id = ? LIMIT 1",
      ).get(bootstrap.task_id);
      assert.ok(applied.events[0].event_id);

      const taskB = "task-sqlite-isolation-b";
      const generationB = "stream-sqlite-isolation-b";
      const channelB = "chat:fixture:task-sqlite-isolation-b";
      const workspaceB = "workspace-sqlite-fixture-b";
      const now = Date.now();
      coordinator.db.exec("BEGIN IMMEDIATE;");
      try {
        coordinator.db.prepare(
          `INSERT INTO stream_generations(
            task_id, generation, created_at_ms, retired_at_ms, reason
          ) VALUES(?, ?, ?, NULL, NULL)`,
        ).run(taskB, generationB, now);
        coordinator.db.prepare(
          `INSERT INTO tasks(
            task_id, contract_version, channel_id, workspace_id, objective,
            state_json, mode, owner_role, lease_id, fencing_epoch, task_revision,
            stream_generation, head_seq, min_retained_seq, status,
            created_at_ms, updated_at_ms, closed_at_ms
          ) VALUES(?, 'source_hosted-shared-task-v1', ?, ?, ?, '{}',
            'source_hosted', 'source', 'lease-isolation-b', 1, 1, ?, 0, 1,
            'active', ?, ?, NULL)`,
        ).run(
          taskB,
          channelB,
          workspaceB,
          "Task B isolation fixture",
          generationB,
          now,
          now,
        );
        for (const role of ["source", "panel"]) {
          coordinator.db.prepare(
            `INSERT INTO mailbox_delivery_state(
              task_id, actor_role, generation, delivered_seq_prefix,
              ack_coverage_prefix, updated_at_ms
            ) VALUES(?, ?, ?, 0, 0, ?)`,
          ).run(taskB, role, generationB, now);
        }
        coordinator.db.prepare(
          `INSERT INTO mutations(
            mutation_id, task_id, operation, actor_id, idempotency_key,
            committed_at_ms, outcome
          ) VALUES('mutation-isolation-b', ?, 'generation_reset', 'control-b',
            NULL, ?, 'applied')`,
        ).run(taskB, now);
        coordinator.db.prepare(
          `INSERT INTO mutations(
            mutation_id, task_id, operation, actor_id, idempotency_key,
            committed_at_ms, outcome
          ) VALUES('mutation-isolation-a-for-receipt', ?, 'publish',
            'actor-a', 'isolation-a-receipt-key', ?, 'applied')`,
        ).run(bootstrap.task_id, now);
        coordinator.db.exec("COMMIT;");
      } catch (error) {
        coordinator.db.exec("ROLLBACK;");
        throw error;
      }

      assert.throws(() => {
        coordinator.db.prepare(
          `INSERT INTO event_acks(task_id, event_id, actor_role, acknowledged_at_ms)
           VALUES(?, ?, 'panel', ?)`,
        ).run(taskB, eventA.event_id, now);
      }, /FOREIGN KEY constraint failed/u);

      assert.throws(() => {
        coordinator.db.prepare(
          `INSERT INTO events(
            event_id, task_id, generation, stream_seq, kind, authority,
            author_role, target_role, execution_epoch, origin_json,
            payload_json, payload_sha256, mutation_id, created_at_ms
          ) VALUES('event-isolation-cross-mutation', ?, ?, 1, 'note', 'note',
            'source', 'panel', 1, '{}', '{}', ?, ?, ?)`,
        ).run(
          taskB,
          generationB,
          "0".repeat(64),
          "mutation-isolation-a-for-receipt",
          now,
        );
      }, /FOREIGN KEY constraint failed/u);

      assert.throws(() => {
        coordinator.db.prepare(
          `INSERT INTO idempotency_receipts(
            receipt_id, mutation_id, task_id, actor_id, actor_role, operation,
            idempotency_key, canonical_hash_alg, canonical_hash,
            original_request_id, outcome, response_json, event_receipts_json,
            next_snapshot_json, task_revision, stream_generation, head_seq,
            committed_at_ms
          ) VALUES('receipt-isolation-cross-mutation', ?, ?, 'actor-b', 'panel',
            'publish', 'cross-task-receipt-key', 'sha256', ?, 'request-b-01',
            'applied', '{}', NULL, NULL, 1, ?, 0, ?)`,
        ).run(
          "mutation-isolation-a-for-receipt",
          taskB,
          "0".repeat(64),
          generationB,
          now,
        );
      }, /FOREIGN KEY constraint failed/u);

      coordinator.db.prepare(
        `INSERT INTO events(
          event_id, task_id, generation, stream_seq, kind, authority,
          author_role, target_role, execution_epoch, origin_json,
          payload_json, payload_sha256, mutation_id, created_at_ms
        ) VALUES('event-isolation-b', ?, ?, 1, 'note', 'note',
          'source', 'panel', 1, '{}', '{}', ?, 'mutation-isolation-b', ?)`,
      ).run(taskB, generationB, "0".repeat(64), now);

      assert.throws(() => {
        coordinator.db.prepare(
          `INSERT INTO owner_transitions(
            transition_id, task_id, from_mode, from_owner, from_epoch,
            to_mode, to_owner, to_epoch, checkpoint_id, confirmation_id,
            checkpoint_generation, checkpoint_snapshot_seq, confirmation_kind,
            confirmation_target_mode, transition_event_id, mutation_id,
            created_at_ms
          ) VALUES('transition-isolation-cross-event', ?, 'source_hosted',
            'source', 1, 'panel_hosted', 'panel', 2, NULL, NULL, NULL, NULL,
            NULL, NULL, ?, 'mutation-isolation-b', ?)`,
        ).run(taskB, eventA.event_id, now);
      }, /FOREIGN KEY constraint failed/u);

      assert.throws(() => {
        coordinator.db.prepare(
          `INSERT INTO owner_transitions(
            transition_id, task_id, from_mode, from_owner, from_epoch,
            to_mode, to_owner, to_epoch, checkpoint_id, confirmation_id,
            checkpoint_generation, checkpoint_snapshot_seq, confirmation_kind,
            confirmation_target_mode, transition_event_id, mutation_id,
            created_at_ms
          ) VALUES('transition-isolation-cross-mutation', ?, 'source_hosted',
            'source', 1, 'panel_hosted', 'panel', 3, NULL, NULL, NULL, NULL,
            NULL, NULL, 'event-isolation-b', ?, ?)`,
        ).run(taskB, mutationA.mutation_id, now);
      }, /FOREIGN KEY constraint failed/u);

      assertIntegrity(coordinator.db);
    } finally {
      fixture.cleanup();
    }
  });

  test("temporary fixture cleanup removes DB, WAL and SHM files", () => {
    const fixture = createTempSqliteFixture();
    const { dir } = fixture;
    assert.equal(existsSync(dir), true);
    fixture.cleanup();
    assert.equal(existsSync(dir), false);
  });
}
