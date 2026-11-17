import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { createRestartableServer } from "../scripts/restartable-server.mjs";
import {
  processExists,
  terminateChildAndWait,
} from "../scripts/child-process-lifecycle.mjs";

const children = new Set();
const root = resolve(import.meta.dirname, "..");
const evidenceDir = join(
  root,
  "work",
  "pchw-runner-cleanup-evidence-2026-11-17",
);

function pidHash(pid) {
  return createHash("sha256")
    .update(`${pid}:${randomUUID()}`, "utf8")
    .digest("hex");
}

function sleep(milliseconds) {
  return new Promise((resolvePromise) =>
    setTimeout(resolvePromise, milliseconds)
  );
}

async function startDummyChild(id) {
  const marker = `SKILLDOCK_RESTART_TEST_${id}_${process.pid}`;
  const child = spawn(process.execPath, [
    "-e",
    `process.title=${JSON.stringify(marker)}; setInterval(() => {}, 1000);`,
  ], {
    windowsHide: true,
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  await Promise.race([
    once(child, "spawn"),
    new Promise((_, rejectPromise) => {
      child.once("error", rejectPromise);
    }),
  ]);
  assert.equal(processExists(child.pid), true);
  const handle = {
    id,
    marker,
    child,
    pid: child.pid,
    async close() {
      await terminateChildAndWait(child);
    },
  };
  children.add(handle);
  return handle;
}

try {
  const opened = [];
  const closed = [];
  let sequence = 0;
  const lifecycle = createRestartableServer(async () => {
    const handle = await startDummyChild(++sequence);
    opened.push(handle);
    const close = handle.close.bind(handle);
    handle.close = async () => {
      await close();
      closed.push(handle.pid);
    };
    return handle;
  });

  const first = await lifecycle.start();
  const firstPidHash = pidHash(first.pid);
  assert.equal(processExists(first.pid), true);
  assert.equal(lifecycle.isOpen, true);
  await assert.rejects(() => lifecycle.start(), /already open/u);
  await lifecycle.close();
  assert.deepEqual(closed, [first.pid]);
  assert.equal(processExists(first.pid), false);
  assert.equal(lifecycle.isOpen, false);
  await lifecycle.close();
  assert.deepEqual(closed, [first.pid]);

  const second = await lifecycle.start();
  const secondPidHash = pidHash(second.pid);
  assert.equal(processExists(second.pid), true);
  assert.equal(lifecycle.isOpen, true);
  await lifecycle.close();
  assert.deepEqual(opened.map((item) => item.pid), [first.pid, second.pid]);
  assert.deepEqual(closed, [first.pid, second.pid]);
  assert.equal(processExists(second.pid), false);
  assert.equal(lifecycle.isOpen, false);

  let rejectNextClose = true;
  let rejectionHandle = null;
  let finalizerStatusAfterRejection = "passed";
  const rejectionLifecycle = createRestartableServer(async () => {
    const handle = await startDummyChild(99);
    const close = handle.close.bind(handle);
    handle.close = async () => {
      if (rejectNextClose) {
        rejectNextClose = false;
        await sleep(150);
        throw new Error("simulated child close failure");
      }
      await close();
    };
    rejectionHandle = handle;
    return handle;
  });

  await rejectionLifecycle.start();
  const rejectionPidHash = pidHash(rejectionHandle.pid);
  try {
    await rejectionLifecycle.close();
  } catch (error) {
    assert.match(error.message, /simulated child close failure/u);
    finalizerStatusAfterRejection = "aborted";
  }
  assert.equal(finalizerStatusAfterRejection, "aborted");
  assert.equal(rejectionLifecycle.isOpen, true);
  assert.equal(processExists(rejectionHandle.pid), true);

  const retryClose = rejectionLifecycle.close();
  await assert.rejects(
    () => rejectionLifecycle.start(),
    /already open/u,
  );
  await retryClose;
  assert.equal(rejectionLifecycle.isOpen, false);
  assert.equal(processExists(rejectionHandle.pid), false);

  await mkdir(evidenceDir, { recursive: true });
  await writeFile(
    join(evidenceDir, "cleanup-evidence.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      status: "passed",
      gate: "runner_real_child_process_cleanup",
      child_executable: "node.exe",
      real_child_processes: [
        {
          slot: "first",
          pid_hash: firstPidHash,
          spawned: true,
          exit_observed: true,
          pid_gone_after_close: true,
        },
        {
          slot: "second",
          pid_hash: secondPidHash,
          spawned: true,
          exit_observed: true,
          pid_gone_after_close: true,
        },
      ],
      close_rejection: {
        simulated_error_rejected: true,
        pid_hash: rejectionPidHash,
        is_open_after_rejection: true,
        child_alive_after_rejection: true,
        retry_close_succeeded: true,
        pid_gone_after_retry: true,
        finalizer_status_after_rejection: finalizerStatusAfterRejection,
        would_record_server_closed_after_rejection: false,
      },
      duplicate_start_during_close_rejected: true,
      final_is_open: false,
      observed_at: new Date().toISOString(),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  console.log("real child restartable server lifecycle: PASS");
} finally {
  for (const handle of children) {
    if (processExists(handle.pid)) {
      await terminateChildAndWait(handle.child).catch(() => {});
    }
  }
}
