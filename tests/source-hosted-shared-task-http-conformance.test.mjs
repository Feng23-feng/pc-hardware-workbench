import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { request as httpRequest } from "node:http";
import { resolve } from "node:path";
import test from "node:test";

let sqliteAvailable = true;
try {
  await import("node:sqlite");
} catch {
  sqliteAvailable = false;
}

if (!sqliteAvailable) {
  test("isolated HTTP conformance requires node:sqlite", {
    skip: "node:sqlite is unavailable in this Node runtime",
  }, () => {});
} else {
  const {
    createTempSqliteFixture,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/fixture.mjs"
  );
  const {
    startIsolatedHttpServer,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/http-server.mjs"
  );
  const {
    startIsolatedSkillDockProxy,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/persistence/same-origin-proxy.mjs"
  );
  const {
    createContractValidator,
  } = await import(
    "../contracts/source-hosted-shared-task/v1/reference/contract-validator.mjs"
  );
  const root = resolve(import.meta.dirname, "..");
  const httpWorkerPath = resolve(
    root,
    "contracts",
    "source-hosted-shared-task",
    "v1",
    "persistence",
    "http-worker.mjs",
  );
  const validator = createContractValidator();

  function snapshotRequest(requestId = "request-http-snapshot-01") {
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
    requestId = "request-http-publish-01",
    key = "http-publish-key-01",
    clientEventId = "http-client-event-01",
    target = "source",
  } = {}) {
    return {
      schema_version: "1.0",
      request_id: requestId,
      idempotency_key: key,
      expected: {
        stream_generation: snapshot.snapshot.stream_generation,
        snapshot_id: snapshot.snapshot.snapshot_id,
        snapshot_seq: snapshot.snapshot.snapshot_seq,
        task_revision: snapshot.task.task_revision,
        execution_epoch: snapshot.execution.fencing_epoch,
      },
      events: [
        {
          client_event_id: clientEventId,
          kind: "note",
          authority: "note",
          target_role: target,
          execution_epoch: snapshot.execution.fencing_epoch,
          origin: {
            session_ref: null,
            turn_id: null,
            item_id: null,
          },
          payload: { text: "Synthetic HTTP event" },
        },
      ],
    };
  }

  function endpoint(taskId, group, action) {
    return `/v1/tasks/${encodeURIComponent(taskId)}/${group}/${action}`;
  }

  function rawHttp(baseUrl, path, {
    method = "POST",
    headers = {},
    body = "",
  } = {}) {
    const url = new URL(path, baseUrl);
    return new Promise((resolvePromise, rejectPromise) => {
      const request = httpRequest(url, {
        method,
        headers,
        timeout: 5_000,
      }, (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.once("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let json = null;
          if (text.trim()) {
            try {
              json = JSON.parse(text);
            } catch {
              // Preserve raw text for malformed transport tests.
            }
          }
          resolvePromise({
            status: response.statusCode,
            headers: response.headers,
            text,
            json,
          });
        });
      });
      request.once("timeout", () => {
        request.destroy(new Error("request timeout"));
      });
      request.once("error", (error) => {
        resolvePromise({
          status: null,
          headers: {},
          text: "",
          json: null,
          transportError: error,
        });
      });
      if (Array.isArray(body)) {
        for (const chunk of body) request.write(chunk);
      } else if (body !== undefined && body !== null) {
        request.write(body);
      }
      request.end();
    });
  }

  function authenticatedHeaders(token, extra = {}) {
    return {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json; charset=utf-8",
      ...extra,
    };
  }

  function createAdditionalTask(fixture, suffix) {
    return fixture.coordinator.bootstrapFixture({
      taskId: `task-http-fixture-${suffix}`,
      workspaceId: `workspace-http-fixture-${suffix}`,
      channelId: `chat:fixture:task-http-fixture-${suffix}`,
      objective: `Synthetic HTTP Task ${suffix}`,
    });
  }

  function proxyHeaders(proxy, sessionId, extra = {}) {
    return {
      Origin: proxy.baseUrl,
      Cookie: `skilldock_session=${sessionId}`,
      "Content-Type": "application/json; charset=utf-8",
      ...extra,
    };
  }

  function abortHttp(baseUrl, path, { headers = {}, chunks = [] } = {}) {
    const url = new URL(path, baseUrl);
    return new Promise((resolvePromise) => {
      const request = httpRequest(url, {
        method: "POST",
        headers,
        timeout: 5_000,
      });
      request.once("error", resolvePromise);
      request.once("close", resolvePromise);
      for (const chunk of chunks) request.write(chunk);
      request.destroy();
    });
  }

  async function startHttpWorker(dbPath) {
    const child = spawn(process.execPath, [httpWorkerPath], {
      cwd: root,
      windowsHide: true,
      env: {
        ...process.env,
        SQ_DB_PATH: dbPath,
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
    const ready = await new Promise((resolvePromise, rejectPromise) => {
      const deadline = setTimeout(() => {
        rejectPromise(new Error(`HTTP worker startup timeout: ${stderr}`));
      }, 10_000);
      const check = () => {
        const line = stdout.split(/\r?\n/u).find(Boolean);
        if (!line) return;
        try {
          const value = JSON.parse(line);
          if (value.ready && value.base_url) {
            clearTimeout(deadline);
            resolvePromise(value);
          }
        } catch {
          // Wait for a complete line.
        }
      };
      child.stdout.on("data", check);
      child.once("exit", (code) => {
        clearTimeout(deadline);
        rejectPromise(new Error(`HTTP worker exited ${code}: ${stderr}`));
      });
    });
    return {
      child,
      ready,
      get stdout() {
        return stdout;
      },
      get stderr() {
        return stderr;
      },
      async close() {
        if (child.exitCode === null) {
          child.kill();
          await new Promise((resolvePromise) => child.once("exit", resolvePromise));
        }
      },
    };
  }

  test("isolated HTTP profile enforces Host, Bearer, Origin and response headers", async () => {
    const fixture = createTempSqliteFixture();
    let server;
    try {
      server = await startIsolatedHttpServer({ dbPath: fixture.dbPath });
      const path = endpoint(fixture.bootstrap.task_id, "mailbox", "snapshot");
      for (const host of [
        `localhost:${server.port}`,
        `LOCALHOST:${server.port}`,
        `127.0.0.1:${server.port + 1}`,
      ]) {
        const wrongHost = await rawHttp(server.baseUrl, path, {
          headers: {
            Host: host,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(snapshotRequest()),
        });
        assert.equal(wrongHost.status, 403);
        assert.equal(wrongHost.json.error.code, "invalid_host");
      }

      const noBearer = await rawHttp(server.baseUrl, path, {
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(snapshotRequest()),
      });
      assert.equal(noBearer.status, 401);
      assert.equal(noBearer.json.error.code, "capability_missing");

      const cookieOnly = await rawHttp(server.baseUrl, path, {
        headers: {
          Cookie: `panel_token=${fixture.bootstrap.tokens.panel}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(snapshotRequest()),
      });
      assert.equal(cookieOnly.status, 401);

      const malformedBearer = await rawHttp(server.baseUrl, path, {
        headers: {
          Authorization: `Basic ${fixture.bootstrap.tokens.panel}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(snapshotRequest()),
      });
      assert.equal(malformedBearer.status, 401);
      assert.equal(malformedBearer.json.error.code, "capability_missing");

      const directOrigin = await rawHttp(server.baseUrl, path, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel, {
          Origin: server.baseUrl,
        }),
        body: JSON.stringify(snapshotRequest()),
      });
      assert.equal(directOrigin.status, 403);
      assert.equal(directOrigin.headers["access-control-allow-origin"], undefined);

      const valid = await rawHttp(server.baseUrl, path, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: JSON.stringify(snapshotRequest()),
      });
      assert.equal(valid.status, 200);
      assert.equal(valid.headers["cache-control"], "no-store");
      assert.equal(valid.headers["x-content-type-options"], "nosniff");
      assert.equal(valid.headers["referrer-policy"], "no-referrer");
      assert.equal(valid.headers["set-cookie"], undefined);
      assert.equal(valid.headers["access-control-allow-origin"], undefined);
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("isolated HTTP profile enforces content type, JSON, size, method and path", async () => {
    const fixture = createTempSqliteFixture();
    let server;
    try {
      server = await startIsolatedHttpServer({ dbPath: fixture.dbPath });
      const path = endpoint(fixture.bootstrap.task_id, "mailbox", "snapshot");
      const wrongType = await rawHttp(server.baseUrl, path, {
        headers: {
          Authorization: `Bearer ${fixture.bootstrap.tokens.panel}`,
          "Content-Type": "text/plain",
        },
        body: "{}",
      });
      assert.equal(wrongType.status, 415);
      assert.equal(wrongType.json.error.code, "invalid_request");

      const malformed = await rawHttp(server.baseUrl, path, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: "{broken",
      });
      assert.equal(malformed.status, 400);
      assert.equal(malformed.json.error.code, "schema_invalid");

      const query = await rawHttp(
        server.baseUrl,
        `${path}?token=secret`,
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
          body: JSON.stringify(snapshotRequest()),
        },
      );
      assert.equal(query.status, 400);

      const getRequest = await rawHttp(server.baseUrl, path, {
        method: "GET",
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
      });
      assert.equal(getRequest.status, 405);
      assert.equal(getRequest.headers.allow, "POST");

      const unknown = await rawHttp(
        server.baseUrl,
        "/api/artifacts/anything",
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
          body: "{}",
        },
      );
      assert.equal(unknown.status, 404);

      for (const malformedPath of [
        "/v1/tasks/task-http-fixture-01%2Fescape/mailbox/snapshot",
        "/v1/tasks/task-http-fixture-01%5Cescape/mailbox/snapshot",
        "/v1/tasks/%2E%2E/mailbox/snapshot",
        `${path}/extra`,
      ]) {
        const rejected = await rawHttp(server.baseUrl, malformedPath, {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
          body: JSON.stringify(snapshotRequest()),
        });
        assert.equal(rejected.status, 404);
        assert.equal(rejected.json.error.code, "invalid_request");
      }

      const chunked = await rawHttp(server.baseUrl, path, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: [
          JSON.stringify(snapshotRequest("request-http-chunked")).slice(0, 20),
          JSON.stringify(snapshotRequest("request-http-chunked")).slice(20),
        ],
      });
      assert.equal(chunked.status, 200);

      const publishPath = endpoint(
        fixture.bootstrap.task_id,
        "mailbox",
        "publish",
      );
      const tooLarge = await rawHttp(server.baseUrl, publishPath, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: "x".repeat(256 * 1024 + 1),
      });
      assert.equal(tooLarge.status, 413);
      assert.equal(tooLarge.json.error.code, "payload_too_large");
      const ackTooLarge = await rawHttp(
        server.baseUrl,
        endpoint(fixture.bootstrap.task_id, "mailbox", "ack"),
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.source),
          body: "x".repeat(64 * 1024 + 1),
        },
      );
      assert.equal(ackTooLarge.status, 413);
      assert.equal(ackTooLarge.json.error.code, "payload_too_large");
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("isolated HTTP enforces exact body limits and aborted upload boundaries", async () => {
    const fixture = createTempSqliteFixture();
    let server;
    try {
      server = await startIsolatedHttpServer({ dbPath: fixture.dbPath });
      const taskId = fixture.bootstrap.task_id;
      const snapshot = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "snapshot"),
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
          body: JSON.stringify(
            snapshotRequest("request-http-exact-snapshot"),
          ),
        },
      );
      assert.equal(snapshot.status, 200);
      const publish = publishRequest(snapshot.json, {
        requestId: "request-http-exact-publish",
        key: "http-exact-key",
        clientEventId: "http-exact-client",
      });
      publish.events[0].payload.text = "";
      const publishBaseBytes = Buffer.byteLength(JSON.stringify(publish));
      publish.events[0].payload.text = "x".repeat(
        256 * 1024 - publishBaseBytes,
      );
      const exactPublish = JSON.stringify(publish);
      assert.equal(Buffer.byteLength(exactPublish), 256 * 1024);
      const publishPath = endpoint(taskId, "mailbox", "publish");
      const exactPublishResponse = await rawHttp(
        server.baseUrl,
        publishPath,
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
          body: exactPublish,
        },
      );
      assert.equal(exactPublishResponse.status, 200);

      const generation = exactPublishResponse.json.stream.generation;
      const eventId = exactPublishResponse.json.events[0].event_id;
      const ack = {
        schema_version: "1.0",
        request_id: "request-http-exact-ack",
        stream_generation: generation,
        event_ids: [eventId],
        padding: "",
      };
      const ackBaseBytes = Buffer.byteLength(JSON.stringify(ack));
      ack.padding = "x".repeat(64 * 1024 - ackBaseBytes);
      const exactAck = JSON.stringify(ack);
      assert.equal(Buffer.byteLength(exactAck), 64 * 1024);
      const exactAckResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "ack"),
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.source),
          body: exactAck,
        },
      );
      assert.equal(exactAckResponse.status, 400);
      assert.equal(exactAckResponse.json.error.code, "schema_invalid");

      const before = Number(fixture.coordinator.db.prepare(
        "SELECT COUNT(*) AS count FROM mutations",
      ).get().count);
      const partial = exactPublish.slice(0, 128);
      await abortHttp(server.baseUrl, publishPath, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        chunks: [partial],
      });
      await new Promise((resolvePromise) => setTimeout(resolvePromise, 50));
      const after = Number(fixture.coordinator.db.prepare(
        "SELECT COUNT(*) AS count FROM mutations",
      ).get().count);
      assert.equal(after, before);
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("isolated HTTP supports snapshot, publish, pull, ack, claim and release", async () => {
    const fixture = createTempSqliteFixture();
    let server;
    try {
      server = await startIsolatedHttpServer({ dbPath: fixture.dbPath });
      const taskId = fixture.bootstrap.task_id;
      const panelToken = fixture.bootstrap.tokens.panel;
      const sourceToken = fixture.bootstrap.tokens.source;
      const snapshotResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "snapshot"),
        {
          headers: authenticatedHeaders(panelToken),
          body: JSON.stringify(snapshotRequest()),
        },
      );
      assert.equal(snapshotResponse.status, 200);
      assert.equal(
        validator.validateResponse("snapshot", snapshotResponse.json).valid,
        true,
      );
      const publishBody = publishRequest(snapshotResponse.json);
      const publishResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "publish"),
        {
          headers: authenticatedHeaders(panelToken),
          body: JSON.stringify(publishBody),
        },
      );
      assert.equal(publishResponse.status, 200);
      assert.equal(
        validator.validateResponse("publish", publishResponse.json).valid,
        true,
      );
      const generation = publishResponse.json.stream.generation;
      const eventId = publishResponse.json.events[0].event_id;
      const pullResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "pull"),
        {
          headers: authenticatedHeaders(sourceToken),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-http-pull-01",
            after: { generation, seq: 0 },
            limit: 50,
          }),
        },
      );
      assert.equal(pullResponse.status, 200);
      assert.equal(
        validator.validateResponse("pull", pullResponse.json).valid,
        true,
      );
      const ackResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "ack"),
        {
          headers: authenticatedHeaders(sourceToken),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-http-ack-01",
            stream_generation: generation,
            event_ids: [eventId],
          }),
        },
      );
      assert.equal(ackResponse.status, 200);
      assert.equal(
        validator.validateResponse("ack", ackResponse.json).valid,
        true,
      );

      const checkpointResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "mailbox", "snapshot"),
        {
          headers: authenticatedHeaders(sourceToken),
          body: JSON.stringify({
            ...snapshotRequest("request-http-claim-checkpoint"),
            checkpoint: true,
          }),
        },
      );
      assert.equal(checkpointResponse.status, 200);
      const confirmation = server.coordinator.issueConfirmation(
        fixture.bootstrap.tokens.control,
        "claim_switch",
        "panel_hosted",
      );
      const claimResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "lease", "claim"),
        {
          headers: authenticatedHeaders(fixture.bootstrap.tokens.control),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-http-claim-01",
            idempotency_key: "http-claim-key",
            expected: {
              execution_epoch: checkpointResponse.json.execution.fencing_epoch,
              task_revision: checkpointResponse.json.task.task_revision,
              checkpoint_id: checkpointResponse.json.checkpoint.checkpoint_id,
            },
            target_mode: "panel_hosted",
            user_confirmation_id: confirmation.confirmation_id,
            reason: "Synthetic HTTP claim",
          }),
        },
      );
      assert.equal(claimResponse.status, 200);
      assert.equal(
        validator.validateResponse("claimLease", claimResponse.json).valid,
        true,
      );
      const claimTokens = server.coordinator.takeIssuedCapabilities();
      const releaseConfirmation = server.coordinator.issueConfirmation(
        claimTokens.control,
        "user_release",
        "suspended",
      );
      const releaseResponse = await rawHttp(
        server.baseUrl,
        endpoint(taskId, "lease", "release"),
        {
          headers: authenticatedHeaders(claimTokens.control),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-http-release-01",
            idempotency_key: "http-release-key",
            expected: {
              execution_epoch: claimResponse.json.execution.fencing_epoch,
              task_revision: claimResponse.json.task_revision,
            },
            target_mode: "suspended",
            user_confirmation_id: releaseConfirmation.confirmation_id,
            confirmation_kind: "user_release",
            reason: "Synthetic HTTP release",
          }),
        },
      );
      assert.equal(releaseResponse.status, 200);
      assert.equal(
        validator.validateResponse("releaseLease", releaseResponse.json).valid,
        true,
      );
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("isolated HTTP routes each Task without single-fixture fallback", async () => {
    const fixture = createTempSqliteFixture();
    const taskA = fixture.bootstrap;
    const taskB = createAdditionalTask(fixture, "multi-b");
    let server;
    try {
      server = await startIsolatedHttpServer({ dbPath: fixture.dbPath });
      const unknown = await rawHttp(
        server.baseUrl,
        endpoint("task-http-fixture-missing", "mailbox", "snapshot"),
        {
          headers: authenticatedHeaders(taskA.tokens.panel),
          body: JSON.stringify(snapshotRequest("request-http-unknown-task")),
        },
      );
      assert.equal(unknown.status, 404);
      assert.equal(unknown.json.error.code, "task_not_found");

      const crossTask = await rawHttp(
        server.baseUrl,
        endpoint(taskB.task_id, "mailbox", "snapshot"),
        {
          headers: authenticatedHeaders(taskA.tokens.panel),
          body: JSON.stringify(snapshotRequest("request-http-cross-task")),
        },
      );
      assert.equal(crossTask.status, 403);
      assert.equal(crossTask.json.error.code, "capability_scope_mismatch");
      assert.equal(crossTask.json.task_id, taskB.task_id);

      const [snapshotA, snapshotB] = await Promise.all([
        rawHttp(
          server.baseUrl,
          endpoint(taskA.task_id, "mailbox", "snapshot"),
          {
            headers: authenticatedHeaders(taskA.tokens.panel),
            body: JSON.stringify(snapshotRequest("request-http-task-a")),
          },
        ),
        rawHttp(
          server.baseUrl,
          endpoint(taskB.task_id, "mailbox", "snapshot"),
          {
            headers: authenticatedHeaders(taskB.tokens.panel),
            body: JSON.stringify(snapshotRequest("request-http-task-b")),
          },
        ),
      ]);
      assert.deepEqual([snapshotA.status, snapshotB.status], [200, 200]);
      assert.equal(snapshotA.json.task_id, taskA.task_id);
      assert.equal(snapshotB.json.task_id, taskB.task_id);

      const [publishA, publishB] = await Promise.all([
        rawHttp(
          server.baseUrl,
          endpoint(taskA.task_id, "mailbox", "publish"),
          {
            headers: authenticatedHeaders(taskA.tokens.panel),
            body: JSON.stringify(publishRequest(snapshotA.json, {
              requestId: "request-http-task-a-publish",
              key: "http-shared-key-across-tasks",
              clientEventId: "http-task-a-client",
              target: "source",
            })),
          },
        ),
        rawHttp(
          server.baseUrl,
          endpoint(taskB.task_id, "mailbox", "publish"),
          {
            headers: authenticatedHeaders(taskB.tokens.panel),
            body: JSON.stringify(publishRequest(snapshotB.json, {
              requestId: "request-http-task-b-publish",
              key: "http-shared-key-across-tasks",
              clientEventId: "http-task-b-client",
              target: "source",
            })),
          },
        ),
      ]);
      assert.deepEqual([publishA.status, publishB.status], [200, 200]);
      assert.deepEqual(
        [publishA.json.status, publishB.json.status],
        ["applied", "applied"],
      );
      const snapshotCounts = Object.fromEntries(
        fixture.coordinator.db.prepare(
          `SELECT task_id, COUNT(*) AS count
           FROM mailbox_snapshots GROUP BY task_id`,
        ).all().map((row) => [row.task_id, Number(row.count)]),
      );
      assert.deepEqual(snapshotCounts, {
        [taskA.task_id]: 2,
        [taskB.task_id]: 2,
      });

      const [pullA, pullB] = await Promise.all([
        rawHttp(
          server.baseUrl,
          endpoint(taskA.task_id, "mailbox", "pull"),
          {
            headers: authenticatedHeaders(taskA.tokens.source),
            body: JSON.stringify({
              schema_version: "1.0",
              request_id: "request-http-task-a-pull",
              after: {
                generation: taskA.stream_generation,
                seq: 0,
              },
              limit: 50,
            }),
          },
        ),
        rawHttp(
          server.baseUrl,
          endpoint(taskB.task_id, "mailbox", "pull"),
          {
            headers: authenticatedHeaders(taskB.tokens.source),
            body: JSON.stringify({
              schema_version: "1.0",
              request_id: "request-http-task-b-pull",
              after: {
                generation: taskB.stream_generation,
                seq: 0,
              },
              limit: 50,
            }),
          },
        ),
      ]);
      assert.deepEqual([pullA.status, pullB.status], [200, 200]);
      assert.deepEqual([pullA.json.events.length, pullB.json.events.length], [1, 1]);
      assert.equal(pullA.json.events[0].payload.text, "Synthetic HTTP event");
      assert.equal(pullB.json.events[0].payload.text, "Synthetic HTTP event");

      const ackB = await rawHttp(
        server.baseUrl,
        endpoint(taskB.task_id, "mailbox", "ack"),
        {
          headers: authenticatedHeaders(taskB.tokens.source),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-http-task-b-ack",
            stream_generation: taskB.stream_generation,
            event_ids: [pullB.json.events[0].event_id],
          }),
        },
      );
      assert.equal(ackB.status, 200);
      const checkpointB = await rawHttp(
        server.baseUrl,
        endpoint(taskB.task_id, "mailbox", "snapshot"),
        {
          headers: authenticatedHeaders(taskB.tokens.source),
          body: JSON.stringify({
            ...snapshotRequest("request-http-task-b-checkpoint"),
            checkpoint: true,
          }),
        },
      );
      assert.equal(checkpointB.status, 200);
      const confirmationB = server.coordinator.issueConfirmation(
        taskB.tokens.control,
        "claim_switch",
        "panel_hosted",
        { taskId: taskB.task_id },
      );
      const claimB = await rawHttp(
        server.baseUrl,
        endpoint(taskB.task_id, "lease", "claim"),
        {
          headers: authenticatedHeaders(taskB.tokens.control),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-http-task-b-claim",
            idempotency_key: "http-task-b-claim-key",
            expected: {
              execution_epoch: checkpointB.json.execution.fencing_epoch,
              task_revision: checkpointB.json.task.task_revision,
              checkpoint_id: checkpointB.json.checkpoint.checkpoint_id,
            },
            target_mode: "panel_hosted",
            user_confirmation_id: confirmationB.confirmation_id,
            reason: "Synthetic Task B claim",
          }),
        },
      );
      assert.equal(claimB.status, 200);
      assert.equal(claimB.json.task_id, taskB.task_id);
      const taskModes = Object.fromEntries(
        fixture.coordinator.db.prepare(
          "SELECT task_id, mode, fencing_epoch FROM tasks ORDER BY task_id",
        ).all().map((row) => [
          row.task_id,
          {
            mode: row.mode,
            fencing_epoch: Number(row.fencing_epoch),
          },
        ]),
      );
      assert.deepEqual(taskModes[taskA.task_id], {
        mode: "source_hosted",
        fencing_epoch: 1,
      });
      assert.deepEqual(taskModes[taskB.task_id], {
        mode: "panel_hosted",
        fencing_epoch: 2,
      });

      const counts = fixture.coordinator.db.prepare(
        `SELECT task_id, COUNT(*) AS count
         FROM events GROUP BY task_id ORDER BY task_id`,
      ).all();
      assert.deepEqual(
        Object.fromEntries(
          counts.map((row) => [row.task_id, Number(row.count)]),
        ),
        {
          [taskA.task_id]: 1,
          [taskB.task_id]: 2,
        },
      );
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("same-origin proxy binds browser sessions to independent Tasks", async () => {
    const fixture = createTempSqliteFixture();
    const taskA = fixture.bootstrap;
    const taskB = createAdditionalTask(fixture, "proxy-b");
    const sessions = new Map([
      [
        "session-task-a",
        {
          taskId: taskA.task_id,
          mailboxToken: taskA.tokens.panel,
          controlToken: taskA.tokens.control,
        },
      ],
      [
        "session-task-b",
        {
          taskId: taskB.task_id,
          mailboxToken: taskB.tokens.panel,
          controlToken: taskB.tokens.control,
        },
      ],
      [
        "session-task-b-source",
        {
          taskId: taskB.task_id,
          mailboxToken: taskB.tokens.source,
          controlToken: taskB.tokens.control,
        },
      ],
    ]);
    const observed = [];
    const logs = [];
    let coordinatorServer;
    let proxy;
    try {
      coordinatorServer = await startIsolatedHttpServer({
        dbPath: fixture.dbPath,
      });
      proxy = await startIsolatedSkillDockProxy({
        coordinatorBaseUrl: coordinatorServer.baseUrl,
        sessions,
        accessLog(entry) {
          logs.push(entry);
        },
        upstreamObserver(entry) {
          observed.push(entry);
        },
      });
      const [responseA, responseB] = await Promise.all([
        rawHttp(
          proxy.baseUrl,
          "/api/source-hosted/mailbox/snapshot",
          {
            headers: proxyHeaders(proxy, "session-task-a"),
            body: JSON.stringify(
              snapshotRequest("request-proxy-task-a-snapshot"),
            ),
          },
        ),
        rawHttp(
          proxy.baseUrl,
          "/api/source-hosted/mailbox/snapshot",
          {
            headers: proxyHeaders(proxy, "session-task-b"),
            body: JSON.stringify(
              snapshotRequest("request-proxy-task-b-snapshot"),
            ),
          },
        ),
      ]);
      assert.deepEqual([responseA.status, responseB.status], [200, 200]);
      assert.equal(responseA.json.task_id, taskA.task_id);
      assert.equal(responseB.json.task_id, taskB.task_id);
      assert.equal(responseA.headers["set-cookie"], undefined);
      assert.equal(responseA.headers["access-control-allow-origin"], undefined);

      const [publishA, publishB] = await Promise.all([
        rawHttp(
          proxy.baseUrl,
          "/api/source-hosted/mailbox/publish",
          {
            headers: proxyHeaders(proxy, "session-task-a"),
            body: JSON.stringify(publishRequest(responseA.json, {
              requestId: "request-proxy-task-a-publish",
              key: "proxy-task-a-publish-key",
              clientEventId: "proxy-task-a-client",
              target: "source",
            })),
          },
        ),
        rawHttp(
          proxy.baseUrl,
          "/api/source-hosted/mailbox/publish",
          {
            headers: proxyHeaders(proxy, "session-task-b"),
            body: JSON.stringify(publishRequest(responseB.json, {
              requestId: "request-proxy-task-b-publish",
              key: "proxy-task-b-publish-key",
              clientEventId: "proxy-task-b-client",
              target: "source",
            })),
          },
        ),
      ]);
      assert.deepEqual([publishA.status, publishB.status], [200, 200]);

      const pullB = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/pull",
        {
            headers: proxyHeaders(proxy, "session-task-b-source"),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-proxy-task-b-pull",
            after: {
              generation: taskB.stream_generation,
              seq: 0,
            },
            limit: 50,
          }),
        },
      );
      assert.equal(pullB.status, 200);
      const ackB = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/ack",
        {
            headers: proxyHeaders(proxy, "session-task-b-source"),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-proxy-task-b-ack",
            stream_generation: taskB.stream_generation,
            event_ids: [pullB.json.events[0].event_id],
          }),
        },
      );
      assert.equal(ackB.status, 200);
      const checkpointB = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
            headers: proxyHeaders(proxy, "session-task-b-source"),
          body: JSON.stringify({
            ...snapshotRequest("request-proxy-task-b-checkpoint"),
            checkpoint: true,
          }),
        },
      );
      assert.equal(checkpointB.status, 200);
      const confirmationB = coordinatorServer.coordinator.issueConfirmation(
        taskB.tokens.control,
        "claim_switch",
        "panel_hosted",
        { taskId: taskB.task_id },
      );
      const claimB = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/lease/claim",
        {
          headers: proxyHeaders(proxy, "session-task-b"),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-proxy-task-b-claim",
            idempotency_key: "proxy-task-b-claim-key",
            expected: {
              execution_epoch: checkpointB.json.execution.fencing_epoch,
              task_revision: checkpointB.json.task.task_revision,
              checkpoint_id: checkpointB.json.checkpoint.checkpoint_id,
            },
            target_mode: "panel_hosted",
            user_confirmation_id: confirmationB.confirmation_id,
            reason: "Synthetic proxy claim",
          }),
        },
      );
      assert.equal(claimB.status, 200);
      assert.equal(
        coordinatorServer.coordinator.takeIssuedCapabilities(taskA.task_id),
        null,
      );
      const claimTokens =
        coordinatorServer.coordinator.takeIssuedCapabilities(taskB.task_id);
      sessions.get("session-task-b").controlToken = claimTokens.control;
      const releaseConfirmation =
        coordinatorServer.coordinator.issueConfirmation(
          claimTokens.control,
          "user_release",
          "suspended",
          { taskId: taskB.task_id },
        );
      const releaseB = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/lease/release",
        {
          headers: proxyHeaders(proxy, "session-task-b"),
          body: JSON.stringify({
            schema_version: "1.0",
            request_id: "request-proxy-task-b-release",
            idempotency_key: "proxy-task-b-release-key",
            expected: {
              execution_epoch: claimB.json.execution.fencing_epoch,
              task_revision: claimB.json.task_revision,
            },
            target_mode: "suspended",
            user_confirmation_id: releaseConfirmation.confirmation_id,
            confirmation_kind: "user_release",
            reason: "Synthetic proxy release",
          }),
        },
      );
      assert.equal(releaseB.status, 200, JSON.stringify(releaseB.json));
      assert.equal(releaseB.json.execution.mode, "suspended");

      assert.equal(
        observed.find(
          (entry) =>
            entry.action === "snapshot" &&
            entry.taskId === taskA.task_id,
        ).headers.Authorization,
        `Bearer ${taskA.tokens.panel}`,
      );
      assert.equal(
        observed.some(
          (entry) =>
            entry.action === "snapshot" &&
            entry.taskId === taskB.task_id &&
            entry.headers.Authorization === `Bearer ${taskB.tokens.panel}`,
        ),
        true,
      );
      for (const entry of observed) {
        assert.equal(entry.headers.Cookie, undefined);
        assert.equal(entry.headers.Origin, undefined);
      }
      const snapshotCounts = Object.fromEntries(
        fixture.coordinator.db.prepare(
          `SELECT task_id, COUNT(*) AS count
           FROM mailbox_snapshots GROUP BY task_id`,
        ).all().map((row) => [row.task_id, Number(row.count)]),
      );
      assert.deepEqual(snapshotCounts, {
        [taskA.task_id]: 2,
        [taskB.task_id]: 3,
      });
      const logsText = JSON.stringify(logs);
      assert.equal(logsText.includes("session-task-a"), false);
      assert.equal(logsText.includes("session-task-b"), false);
      assert.equal(logsText.includes("session-task-b-source"), false);
      assert.equal(logsText.includes(taskA.tokens.panel), false);
      assert.equal(logsText.includes(taskB.tokens.panel), false);
    } finally {
      await proxy?.close().catch(() => {});
      await coordinatorServer?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("same-origin proxy rejects browser overrides and sanitizes failures", async () => {
    const fixture = createTempSqliteFixture();
    const taskA = fixture.bootstrap;
    const taskB = createAdditionalTask(fixture, "proxy-override-b");
    const sessionId = "session-proxy-override-a";
    const sessions = new Map([
      [
        sessionId,
        {
          taskId: taskA.task_id,
          mailboxToken: taskA.tokens.panel,
          controlToken: taskA.tokens.control,
        },
      ],
    ]);
    const logs = [];
    let coordinatorServer;
    let proxy;
    let coordinatorClosed = false;
    try {
      coordinatorServer = await startIsolatedHttpServer({
        dbPath: fixture.dbPath,
      });
      proxy = await startIsolatedSkillDockProxy({
        coordinatorBaseUrl: coordinatorServer.baseUrl,
        sessions,
        accessLog(entry) {
          logs.push(entry);
        },
      });

      const missingSession = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          headers: {
            Origin: proxy.baseUrl,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(snapshotRequest("request-proxy-missing")),
        },
      );
      assert.equal(missingSession.status, 401);

      const fakeBearer = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          headers: proxyHeaders(proxy, sessionId, {
            Authorization: `Bearer ${taskA.tokens.panel}`,
          }),
          body: JSON.stringify(snapshotRequest("request-proxy-bearer")),
        },
      );
      assert.equal(fakeBearer.status, 400);
      assert.equal(fakeBearer.json.error.code, "invalid_request");

      for (const [index, override] of [
        { task_id: taskB.task_id },
        { action: "claim_lease" },
        { capability: taskA.tokens.control },
      ].entries()) {
        const overridden = await rawHttp(
          proxy.baseUrl,
          "/api/source-hosted/mailbox/snapshot",
          {
            headers: proxyHeaders(proxy, sessionId),
            body: JSON.stringify({
              ...snapshotRequest(`request-proxy-override-${index}`),
              ...override,
            }),
          },
        );
        assert.equal(overridden.status, 400);
        assert.equal(overridden.json.error.code, "invalid_request");
      }

      const query = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot?task_id=other",
        {
          headers: proxyHeaders(proxy, sessionId),
          body: JSON.stringify(snapshotRequest("request-proxy-query")),
        },
      );
      assert.equal(query.status, 400);

      const directPath = await rawHttp(
        proxy.baseUrl,
        endpoint(taskA.task_id, "mailbox", "snapshot"),
        {
          headers: proxyHeaders(proxy, sessionId),
          body: JSON.stringify(snapshotRequest("request-proxy-direct")),
        },
      );
      assert.equal(directPath.status, 404);

      const wrongOrigin = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          headers: proxyHeaders(proxy, sessionId, {
            Origin: "http://localhost:1",
          }),
          body: JSON.stringify(snapshotRequest("request-proxy-origin")),
        },
      );
      assert.equal(wrongOrigin.status, 403);

      const wrongType = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          headers: proxyHeaders(proxy, sessionId, {
            "Content-Type": "text/plain",
          }),
          body: "{}",
        },
      );
      assert.equal(wrongType.status, 415);

      const malformed = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          headers: proxyHeaders(proxy, sessionId),
          body: "{broken",
        },
      );
      assert.equal(malformed.status, 400);
      assert.equal(malformed.json.error.code, "schema_invalid");

      const getRequest = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          method: "GET",
          headers: proxyHeaders(proxy, sessionId),
        },
      );
      assert.equal(getRequest.status, 405);

      const tooLarge = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/publish",
        {
          headers: proxyHeaders(proxy, sessionId),
          body: "x".repeat(256 * 1024 + 1),
        },
      );
      assert.equal(tooLarge.status, 413);

      await coordinatorServer.close();
      coordinatorClosed = true;
      const upstreamFailure = await rawHttp(
        proxy.baseUrl,
        "/api/source-hosted/mailbox/snapshot",
        {
          headers: proxyHeaders(proxy, sessionId),
          body: JSON.stringify({
            ...snapshotRequest("request-proxy-upstream-failure"),
            payload: "private-upstream-payload",
          }),
        },
      );
      assert.equal(upstreamFailure.status, 500);
      assert.equal(upstreamFailure.json.error.code, "internal_error");
      assert.equal(upstreamFailure.text.includes(taskA.tokens.panel), false);
      assert.equal(
        upstreamFailure.text.includes("private-upstream-payload"),
        false,
      );

      const logsText = JSON.stringify(logs);
      assert.equal(logsText.includes(sessionId), false);
      assert.equal(logsText.includes(taskA.tokens.panel), false);
      assert.equal(logsText.includes("private-upstream-payload"), false);
    } finally {
      await proxy?.close().catch(() => {});
      if (!coordinatorClosed) {
        await coordinatorServer?.close().catch(() => {});
      }
      fixture.cleanup();
    }
  });

  test("HTTP response loss after COMMIT is recovered by duplicate replay", async () => {
    const fixture = createTempSqliteFixture();
    let server;
    try {
      const snapshot = fixture.coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-http-loss-snapshot"),
      );
      const request = publishRequest(snapshot, {
        requestId: "request-http-loss-publish",
        key: "http-loss-key",
        clientEventId: "http-loss-client",
      });
      let dropOnce = true;
      server = await startIsolatedHttpServer({
        dbPath: fixture.dbPath,
        responseFault({ action, result }) {
          if (
            dropOnce &&
            action === "publish" &&
            result.ok === true
          ) {
            dropOnce = false;
            return "drop";
          }
        },
      });
      const url = endpoint(
        fixture.bootstrap.task_id,
        "mailbox",
        "publish",
      );
      const dropped = await rawHttp(server.baseUrl, url, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: JSON.stringify(request),
      });
      assert.ok(dropped.transportError);
      const replay = await rawHttp(server.baseUrl, url, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: JSON.stringify({
          ...request,
          request_id: "request-http-loss-replay",
        }),
      });
      assert.equal(replay.status, 200);
      assert.equal(replay.json.status, "duplicate");
      assert.equal(server.coordinator.fixtureSnapshot().counts.events, 1);
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("HTTP response serialization failure leaves a replayable receipt", async () => {
    const fixture = createTempSqliteFixture();
    let server;
    let failOnce = true;
    try {
      const snapshot = fixture.coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-http-serialization-snapshot"),
      );
      const request = publishRequest(snapshot, {
        requestId: "request-http-serialization-publish",
        key: "http-serialization-key",
        clientEventId: "http-serialization-client",
      });
      server = await startIsolatedHttpServer({
        dbPath: fixture.dbPath,
        responseFault({ action }) {
          if (failOnce && action === "publish") {
            failOnce = false;
            throw new Error("private serialization failure detail");
          }
        },
      });
      const path = endpoint(
        fixture.bootstrap.task_id,
        "mailbox",
        "publish",
      );
      const failed = await rawHttp(server.baseUrl, path, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: JSON.stringify(request),
      });
      assert.equal(failed.status, 500);
      assert.equal(failed.json.error.code, "internal_error");
      assert.equal(
        failed.text.includes("private serialization failure detail"),
        false,
      );
      const replay = await rawHttp(server.baseUrl, path, {
        headers: authenticatedHeaders(fixture.bootstrap.tokens.panel),
        body: JSON.stringify(request),
      });
      assert.equal(replay.status, 200);
      assert.equal(replay.json.status, "duplicate");
      assert.equal(
        Number(fixture.coordinator.db.prepare(
          "SELECT COUNT(*) AS count FROM events",
        ).get().count),
        1,
      );
    } finally {
      await server?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("two HTTP server processes share one Task with single-commit idempotency", async () => {
    const fixture = createTempSqliteFixture();
    let serverA;
    let serverB;
    try {
      const snapshot = fixture.coordinator.snapshot(
        fixture.bootstrap.tokens.panel,
        snapshotRequest("request-http-mp-snapshot"),
      );
      const request = publishRequest(snapshot, {
        requestId: "request-http-mp-publish",
        key: "http-mp-key",
        clientEventId: "http-mp-client",
      });
      const { dbPath } = fixture;
      const taskId = fixture.bootstrap.task_id;
      const token = fixture.bootstrap.tokens.panel;
      fixture.close();
      serverA = await startHttpWorker(dbPath);
      serverB = await startHttpWorker(dbPath);
      const path = endpoint(taskId, "mailbox", "publish");
      const [left, right] = await Promise.all([
        rawHttp(serverA.ready.base_url, path, {
          headers: authenticatedHeaders(token),
          body: JSON.stringify(request),
        }),
        rawHttp(serverB.ready.base_url, path, {
          headers: authenticatedHeaders(token),
          body: JSON.stringify(request),
        }),
      ]);
      assert.deepEqual([left.status, right.status], [200, 200]);
      assert.deepEqual(
        [left.json.status, right.json.status].sort(),
        ["applied", "duplicate"],
      );
      assert.equal(serverA.stdout.includes(token), false);
      assert.equal(serverB.stdout.includes(token), false);
    } finally {
      await serverA?.close().catch(() => {});
      await serverB?.close().catch(() => {});
      fixture.cleanup();
    }
  });

  test("two HTTP processes route different Tasks concurrently", async () => {
    const fixture = createTempSqliteFixture();
    const taskA = fixture.bootstrap;
    const taskB = createAdditionalTask(fixture, "process-b");
    let serverA;
    let serverB;
    try {
      const snapshotA = fixture.coordinator.snapshot(
        taskA.tokens.panel,
        snapshotRequest("request-http-process-a-snapshot"),
        { taskId: taskA.task_id },
      );
      const snapshotB = fixture.coordinator.snapshot(
        taskB.tokens.panel,
        snapshotRequest("request-http-process-b-snapshot"),
        { taskId: taskB.task_id },
      );
      const requestA = publishRequest(snapshotA, {
        requestId: "request-http-process-a-publish",
        key: "http-process-shared-key",
        clientEventId: "http-process-a-client",
      });
      const requestB = publishRequest(snapshotB, {
        requestId: "request-http-process-b-publish",
        key: "http-process-shared-key",
        clientEventId: "http-process-b-client",
      });
      const { dbPath } = fixture;
      fixture.close();
      serverA = await startHttpWorker(dbPath);
      serverB = await startHttpWorker(dbPath);
      const [resultA, resultB] = await Promise.all([
        rawHttp(
          serverA.ready.base_url,
          endpoint(taskA.task_id, "mailbox", "publish"),
          {
            headers: authenticatedHeaders(taskA.tokens.panel),
            body: JSON.stringify(requestA),
          },
        ),
        rawHttp(
          serverB.ready.base_url,
          endpoint(taskB.task_id, "mailbox", "publish"),
          {
            headers: authenticatedHeaders(taskB.tokens.panel),
            body: JSON.stringify(requestB),
          },
        ),
      ]);
      assert.deepEqual([resultA.status, resultB.status], [200, 200]);
      assert.deepEqual(
        [resultA.json.status, resultB.json.status],
        ["applied", "applied"],
      );
      assert.equal(resultA.json.task_id, taskA.task_id);
      assert.equal(resultB.json.task_id, taskB.task_id);
      assert.equal(serverA.stdout.includes(taskA.tokens.panel), false);
      assert.equal(serverB.stdout.includes(taskB.tokens.panel), false);
    } finally {
      await serverA?.close().catch(() => {});
      await serverB?.close().catch(() => {});
      fixture.cleanup();
    }
  });
}
