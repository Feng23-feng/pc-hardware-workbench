import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const executableValue = process.env.SKILLDOCK_TEST_EXE ?? process.argv[2];
if (!executableValue) {
  throw new Error("Pass the packaged EXE path or set SKILLDOCK_TEST_EXE.");
}
const executable = resolve(executableValue);

const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-launcher-smoke-"));
const localRoot = join(tempRoot, "local-root");
const workspaceA = join(tempRoot, "workspace-a");
const workspaceB = join(tempRoot, "workspace-b");
await Promise.all([
  mkdir(localRoot, { recursive: true }),
  mkdir(workspaceA, { recursive: true }),
  mkdir(workspaceB, { recursive: true }),
]);

const env = {
  ...process.env,
  SKILLDOCK_LOCAL_ROOT: localRoot,
  SKILLDOCK_AGENT_DRIVER: "mock",
  NODE_NO_WARNINGS: "1",
};

function runLauncher(args, timeoutMs = 45_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, args, {
      env,
      windowsHide: true,
      stdio: "ignore",
    });
    const timer = setTimeout(() => {
      child.kill();
      rejectPromise(
        new Error(
          `Launcher timed out: ${args.join(" ")}`,
        ),
      );
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolvePromise({ code });
    });
  });
}

async function readJson(path) {
  const text = (await readFile(path, "utf8")).replace(/^\uFEFF/u, "");
  return JSON.parse(text);
}

async function waitForLaunchResult(expectedWorkspace) {
  const resultPath = join(localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      const result = await readJson(resultPath);
      if (
        result.ok &&
        result.url &&
        resolve(result.workspace) === resolve(expectedWorkspace)
      ) {
        const health = await fetch(
          `${String(result.url).replace(/\/$/u, "")}/api/health`,
        ).then((response) => response.json());
        if (health.ok) return { result, health };
      }
    } catch {
      // The launcher is still writing or starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  const log = await readFile(join(localRoot, "launcher.log"), "utf8").catch(
    () => "(launcher log missing)",
  );
  throw new Error(
    `No launch result appeared for ${expectedWorkspace}\nLocal root: ${localRoot}\n${log}`,
  );
}

async function isHealthy(url) {
  try {
    const response = await fetch(
      `${String(url).replace(/\/$/u, "")}/api/health`,
      { signal: AbortSignal.timeout(2_000) },
    );
    return response.ok;
  } catch {
    return false;
  }
}

async function api(baseUrl, token, path, options = {}) {
  const isFormData = options.body instanceof FormData;
  const base = String(baseUrl).replace(/\/$/u, "");
  const response = await fetch(`${base}${path}`, {
    ...options,
    headers: {
      Authorization: `Bearer ${token}`,
      ...(isFormData ? {} : { "Content-Type": "application/json" }),
      ...(options.headers ?? {}),
    },
  });
  const data = await response.json();
  return { response, data };
}

let activeBase = null;
let completed = false;
try {
  const firstRun = await runLauncher([
    "--ensure",
    "--workspace",
    workspaceA,
    "--silent",
    "--no-browser",
  ]);
  assert.equal(firstRun.code, 0);
  const first = await waitForLaunchResult(workspaceA);
  const firstInfo = await readJson(
    join(localRoot, "runtime-dsh-web", "server-info.json"),
  );
  activeBase = first.result.url;
  assert.equal(first.health.driver, "mock");
  assert.equal(first.health.agent_permission.sandbox, "read-only");
  assert.equal(first.health.agent_permission.approvalPolicy, "never");
  assert.equal(first.health.surface.mode, "read-only");
  assert.equal(first.health.permission_matrix.states.length, 6);

  const reuseRun = await runLauncher([
    "--ensure",
    "--workspace",
    workspaceA,
    "--silent",
    "--no-browser",
  ]);
  assert.equal(reuseRun.code, 0);
  const reused = await waitForLaunchResult(workspaceA);
  const reusedInfo = await readJson(
    join(localRoot, "runtime-dsh-web", "server-info.json"),
  );
  assert.equal(reused.result.url, first.result.url);
  assert.equal(reusedInfo.pid, firstInfo.pid);

  const refusedRun = await runLauncher([
    "--ensure",
    "--workspace",
    workspaceB,
    "--silent",
    "--no-browser",
  ]);
  assert.notEqual(refusedRun.code, 0, "Different workspace was not refused");
  assert.equal(
    await isHealthy(first.result.url),
    true,
    "Workspace A stopped after a refused replacement",
  );

  const replaceRun = await runLauncher([
    "--ensure",
    "--workspace",
    workspaceB,
    "--replace-workspace",
    "--silent",
    "--no-browser",
  ]);
  assert.equal(replaceRun.code, 0);
  const replaced = await waitForLaunchResult(workspaceB);
  activeBase = replaced.result.url;
  assert.notEqual(replaced.result.url, first.result.url);
  assert.equal(await isHealthy(replaced.result.url), true);
  assert.equal(await isHealthy(first.result.url), false);

  const token = (
    await readFile(
      join(localRoot, "runtime-dsh-web", "capability-token"),
      "utf8",
    )
  ).trim();
  const csvForm = new FormData();
  csvForm.append(
    "file",
    new Blob(
      [
        [
          "Date,Time,GPU Temperature [C],GPU Power [W],GPU Effective Clock [MHz],GPU Fan [RPM],FPS",
          "2026-11-16,20:00:00,66,148,2360,1800,118",
          "2026-11-16,20:00:01,68,151,2315,1810,116",
          "2026-11-16,20:00:02,70,153,2280,1820,115",
          "2026-11-16,20:00:03,71,150,2300,1810,116",
        ].join("\n"),
      ],
      { type: "text/csv" },
    ),
    "launcher-smoke.csv",
  );
  let result = await api(activeBase, token, "/api/attachments", {
    method: "POST",
    body: csvForm,
  });
  assert.equal(result.response.ok, true, result.data.error);
  const attachment = result.data.draft.attachments.at(-1);
  assert.ok(attachment?.id);

  result = await api(activeBase, token, "/api/submit", {
    method: "POST",
    body: JSON.stringify({ free_text: "请分析这份虚拟遥测测试数据" }),
  });
  assert.equal(result.response.ok, true, result.data.error);
  assert.ok(result.data.task?.task_id);

  result = await api(activeBase, token, "/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: attachment.id }),
  });
  assert.equal(result.response.status, 403);
  assert.equal(result.data.permission_required, true);
  const requestId = result.data.state.task.permission_request.request_id;

  result = await api(activeBase, token, "/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: requestId,
      decision: "allow_task",
    }),
  });
  assert.equal(result.response.ok, true, result.data.error);
  const grant = result.data.task.grants.find(
    (item) => item.request_id === requestId && item.status === "active",
  );
  assert.ok(grant?.grant_id);

  result = await api(activeBase, token, "/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: attachment.id }),
  });
  assert.equal(result.response.ok, true, result.data.error);
  assert.ok(result.data.panel?.artifact_refs?.length > 0);
  assert.equal(
    result.data.permission_matrix.states.find(
      (item) => item.id === "task_artifact_write",
    )?.status,
    "granted",
  );

  result = await api(activeBase, token, "/api/permissions/revoke", {
    method: "POST",
    body: JSON.stringify({ grant_id: grant.grant_id }),
  });
  assert.equal(result.response.ok, true, result.data.error);
  assert.equal(
    result.data.permission_matrix.states.find(
      (item) => item.id === "task_artifact_write",
    )?.status,
    "approval-required",
  );

  console.log(
    "Packaged launcher isolation, workspace protection, and permission flow: PASS",
  );
  completed = true;
} finally {
  if (activeBase) {
    await runLauncher(["--stop", "--silent"], 15_000).catch(() => {});
  }
  if (completed && process.env.SKILLDOCK_KEEP_SMOKE !== "1") {
    await rm(tempRoot, { recursive: true, force: true });
  } else {
    console.log(`Kept smoke workspace: ${tempRoot}`);
  }
}
