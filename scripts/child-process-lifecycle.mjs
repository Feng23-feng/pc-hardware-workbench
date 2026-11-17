import { once } from "node:events";

export function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error.code === "ESRCH") return false;
    if (error.code === "EPERM") return true;
    throw error;
  }
}

export async function waitForChildExit(child, timeoutMs = 5_000) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  await Promise.race([
    once(child, "exit"),
    new Promise((_, rejectPromise) => {
      setTimeout(() => {
        rejectPromise(new Error(`child ${child.pid} did not exit`));
      }, timeoutMs);
    }),
  ]);
}

export async function waitForPidGone(pid, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!processExists(pid)) return;
    await new Promise((resolvePromise) =>
      setTimeout(resolvePromise, 50)
    );
  }
  throw new Error(`child PID ${pid} still exists after exit`);
}

export async function terminateChildAndWait(child, timeoutMs = 5_000) {
  if (child.exitCode === null && child.signalCode === null) {
    const exited = waitForChildExit(child, timeoutMs);
    if (!child.kill()) {
      throw new Error(`failed to kill child ${child.pid}`);
    }
    await exited;
  }
  await waitForPidGone(child.pid, timeoutMs);
}
