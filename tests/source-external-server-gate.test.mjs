import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-source-gate-"));
const runtimeDir = join(tempRoot, "runtime");

async function expectRejected(env) {
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: root,
    windowsHide: true,
    env: {
      ...process.env,
      PANEL_AGENT_DRIVER: "source-external",
      PANEL_AGENT_SANDBOX: "read-only",
      PANEL_AGENT_APPROVAL_POLICY: "never",
      PANEL_AGENT_WORKSPACE: root,
      PANEL_PORT: "0",
      PANEL_RUNTIME_DIR: runtimeDir,
      PANEL_SOURCE_HOSTED_ENTRY: "",
      PANEL_SOURCE_HOSTED_NON_MOCK: "",
      ...env,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const code = await Promise.race([
    new Promise((resolvePromise) => {
      child.once("exit", resolvePromise);
    }),
    new Promise((_, rejectPromise) => {
      setTimeout(() => {
        child.kill();
        rejectPromise(new Error("source gate process did not exit"));
      }, 5_000);
    }),
  ]);
  assert.notEqual(code, 0);
  assert.match(stderr, /PANEL_SOURCE_HOSTED_ENTRY=1/);
  assert.equal(existsSync(join(runtimeDir, "server-info.json")), false);
}

try {
  await expectRejected({
    PANEL_SOURCE_HOSTED_ENTRY: "",
    PANEL_SOURCE_HOSTED_NON_MOCK: "1",
  });
  await expectRejected({
    PANEL_SOURCE_HOSTED_ENTRY: "1",
    PANEL_SOURCE_HOSTED_NON_MOCK: "",
  });
  console.log("source-external server gate: PASS");
} finally {
  await rm(tempRoot, { recursive: true, force: true });
}
