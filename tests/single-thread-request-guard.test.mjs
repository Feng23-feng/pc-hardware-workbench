import assert from "node:assert/strict";
import {
  installSingleThreadRequestGuard,
} from "../scripts/single-thread-request-guard.mjs";

function createDriver() {
  const calls = [];
  return {
    calls,
    async request(method) {
      calls.push(method);
      if (method === "thread/start") {
        return { thread: { id: "thread-1" } };
      }
      if (method === "turn/start") {
        return { turn: { id: "turn-1" } };
      }
      return {};
    },
  };
}

const driver = createDriver();
const blocked = [];
const started = [];
const guard = installSingleThreadRequestGuard(driver, {
  onThreadStarted: (result) => started.push(result.thread.id),
  onTurnStarted: (result) => started.push(result.turn.id),
  onBlocked: (error) => blocked.push(error.code),
});

await driver.request("thread/start");
assert.equal(guard.threadCount, 1);
await assert.rejects(
  () => driver.request("thread/start"),
  (error) => error.code === "single_thread_violation",
);
await assert.rejects(
  () => driver.request("thread/resume"),
  (error) => error.code === "forbidden_thread_history_access",
);
await driver.request("turn/start");
assert.equal(guard.turnCount, 1);
await assert.rejects(
  () => driver.request("turn/start"),
  (error) => error.code === "single_turn_violation",
);
assert.deepEqual(driver.calls, [
  "thread/start",
  "turn/start",
]);
assert.deepEqual(started, ["thread-1", "turn-1"]);
assert.deepEqual(blocked, [
  "single_thread_violation",
  "forbidden_thread_history_access",
  "single_turn_violation",
]);

console.log("single-Thread runner request guard: PASS");
