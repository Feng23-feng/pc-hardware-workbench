import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForPidGone } from "../scripts/child-process-lifecycle.mjs";
import { capturePchwBrowserEvidence } from "../scripts/pchw-browser-evidence.mjs";
import {
  resolveRuntimePackagePaths,
} from "../scripts/preflight-pchw-current-user-thread-gate.mjs";

const root = resolve(import.meta.dirname, "..");
const localAppData = process.env.LOCALAPPDATA;
const pointerPath = join(localAppData, "SkillDock", "runtime-location.json");
const pointer = JSON.parse(
  (await readFile(pointerPath, "utf8")).replace(/^\uFEFF/u, ""),
);
const paths = resolveRuntimePackagePaths(pointer.runtime_path);
const installedSkillsRoot = join(homedir(), ".codex", "skills");
const installedSkillRoot = join(
  installedSkillsRoot,
  "pc-hardware-workbench",
);
const browserExecutable =
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const evidenceDir = join(
  root,
  "work",
  "pchw-installed-root-mock-edge-20261117",
);
const expected = {
  server:
    "60f2a0b88a662fbc416e8efece01a3ffcd22e9c819583e1f1bbfb0a6645b75af",
  app:
    "ba30ca86723281ff3949b99db369edbd8ce3f07aba33b42bc6b55fc754c7f267",
  index:
    "3b05b901a05c370c481936b50db0c9934ee9c92ccccc4929bd1f27fef85ebd9b",
  runtimeBinding:
    "b4141deed7ee2da928762287b25472ed2a2964387c6bd3f7731f7adfdca07295",
  sourceHostedPhase:
    "8d4c72eab38f6a51d44a487ff0d1480d233116bfce67279f47e218b99c332d70",
};
const tempRoot = await mkdtemp(join(tmpdir(), "pchw-installed-mock-edge-"));
const localRoot = join(tempRoot, "local-root");
const workspace = join(tempRoot, "workspace");
const runtimeDir = join(localRoot, "runtime-dsh-web");
const launcherEnv = {
  ...process.env,
  SKILLDOCK_LOCAL_ROOT: localRoot,
  SKILLDOCK_AGENT_DRIVER: "mock",
  SKILLDOCK_SKILL_ROOTS: installedSkillsRoot,
  SKILLDOCK_BROWSER_EXECUTABLE: browserExecutable,
  NODE_NO_WARNINGS: "1",
};
let activeBase = null;
let completed = false;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function runLauncher(args, timeoutMs = 45_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(paths.launcherPath, args, {
      env: launcherEnv,
      windowsHide: true,
      stdio: "ignore",
    });
    const timer = setTimeout(() => {
      child.kill();
      rejectPromise(new Error(`Launcher timed out: ${args.join(" ")}`));
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

async function readJson(filePath) {
  return JSON.parse(
    (await readFile(filePath, "utf8")).replace(/^\uFEFF/u, ""),
  );
}

async function waitForLaunchResult() {
  const resultPath = join(localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      const result = await readJson(resultPath);
      if (
        result.ok &&
        result.url &&
        resolve(result.workspace) === resolve(workspace)
      ) {
        const health = await fetch(
          `${String(result.url).replace(/\/$/u, "")}/api/health`,
        ).then((response) => response.json());
        if (health.ok) return { result, health };
      }
    } catch {
      // Launcher is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  throw new Error("Installed Runtime did not produce a launch result.");
}

async function api(token, path, options = {}) {
  const formData = options.body instanceof FormData;
  const response = await fetch(
    `${activeBase.replace(/\/$/u, "")}${path}`,
    {
      ...options,
      headers: {
        Authorization: `Bearer ${token}`,
        ...(formData ? {} : { "Content-Type": "application/json" }),
        ...(options.headers ?? {}),
      },
    },
  );
  const data = await response.json();
  return { response, data };
}

try {
  for (const [name, filePath, hash] of [
    ["server", paths.serverPath, expected.server],
    ["app", paths.appPath, expected.app],
    ["index", paths.indexPath, expected.index],
    [
      "runtime-binding",
      paths.runtimeBindingPath,
      expected.runtimeBinding,
    ],
    [
      "source-hosted-phase",
      paths.sourceHostedPhasePath,
      expected.sourceHostedPhase,
    ],
  ]) {
    assert.equal(existsSync(filePath), true, `${name} file missing`);
    assert.equal(sha256(await readFile(filePath)), hash, `${name} hash drift`);
  }
  assert.equal(existsSync(paths.launcherPath), true);
  assert.equal(existsSync(installedSkillRoot), true);
  assert.equal(existsSync(browserExecutable), true, "Edge executable missing");
  await mkdir(workspace, { recursive: true });

  const launched = await runLauncher([
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ]);
  assert.equal(launched.code, 0);
  const { result, health } = await waitForLaunchResult();
  activeBase = result.url;
  assert.equal(health.driver, "mock");
  assert.equal(health.surface.mode, "read-only");
  assert.equal(health.agent_permission.sandbox, "read-only");
  assert.equal(health.agent_permission.approvalPolicy, "never");

  const masterToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const panelToken = (
    await readFile(join(runtimeDir, "panel-capability-token"), "utf8")
  ).trim();
  assert.notEqual(masterToken, panelToken);

  const csvText = [
    "Date,Time,GPU Temperature [C],GPU Power [W],GPU Effective Clock [MHz],GPU Fan [RPM],FPS,PerfCap",
    "2026-11-17,23:00:00,70,297,2650,1740,121,Pwr",
    "2026-11-17,23:05:00,74,308,2638,1790,119,Pwr",
    "2026-11-17,23:10:00,78,300,2612,1850,112,Pwr",
    "2026-11-17,23:15:00,81,272,2378,1950,95,Therm",
    "2026-11-17,23:20:00,83,214,2022,2070,77,Therm",
    "2026-11-17,23:25:00,84,181,1795,2150,66,Therm",
    "2026-11-17,23:30:00,84,174,1752,2140,64,Therm",
    "2026-11-17,23:35:00,83,170,1740,2115,62,Therm",
  ].join("\n");
  const form = new FormData();
  form.append(
    "file",
    new Blob([csvText], { type: "text/csv" }),
    "installed-root-mock.csv",
  );
  let response = await api(masterToken, "/api/attachments", {
    method: "POST",
    body: form,
  });
  assert.equal(response.response.ok, true, response.data.error);
  const attachment = response.data.draft.attachments.at(-1);
  assert.ok(attachment?.id);

  response = await api(masterToken, "/api/submit", {
    method: "POST",
    body: JSON.stringify({
      free_text: "验证真实安装 root 的 mock/Edge 页面闭环。",
    }),
  });
  assert.equal(response.response.ok, true, response.data.error);
  assert.ok(response.data.task?.task_id);

  response = await api(masterToken, "/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: attachment.id }),
  });
  assert.equal(response.response.status, 403);
  assert.equal(response.data.permission_required, true);
  let request =
    response.data.state.task.permission_request;
  response = await api(masterToken, "/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: request.request_id,
      decision: "deny",
    }),
  });
  assert.equal(response.response.ok, true, response.data.error);

  response = await api(masterToken, "/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: attachment.id }),
  });
  assert.equal(response.response.status, 403);
  request = response.data.state.task.permission_request;
  response = await api(masterToken, "/api/permissions/decide", {
    method: "POST",
    body: JSON.stringify({
      request_id: request.request_id,
      decision: "allow_once",
    }),
  });
  assert.equal(response.response.ok, true, response.data.error);

  response = await api(masterToken, "/api/artifacts/analyze", {
    method: "POST",
    body: JSON.stringify({ attachment_id: attachment.id }),
  });
  assert.equal(response.response.ok, true, response.data.error);
  assert.ok(response.data.panel?.artifact_refs?.length > 0);

  const browser = await capturePchwBrowserEvidence({
    baseUrl: activeBase,
    panelToken,
    evidenceDir,
    profileRoot: tempRoot,
    suffix: "-installed-root-mock",
  });
  assert.equal(browser.status, "passed");
  assert.match(browser.browser.executable_name, /^msedge\.exe$/iu);
  assert.equal(browser.dom_assertions.answer_card_present, true);
  assert.equal(browser.dom_assertions.chart_image_loaded, true);
  assert.equal(browser.dom_assertions.runtime_binding_state, "bound");
  assert.equal(
    browser.dom_assertions.runtime_binding_port,
    Number(new URL(activeBase).port),
  );
  assert.ok(browser.dom_assertions.runtime_binding_pid > 0);
  assert.ok(browser.dom_assertions.runtime_binding_launch_id.length >= 16);
  assert.ok(browser.dom_assertions.judgement_length >= 20);
  completed = true;
  console.log("PCHW real installed root mock/Edge gate: PASS");
} finally {
  if (activeBase) {
    await runLauncher(["--stop", "--silent"], 15_000).catch(() => {});
  }
  const infoPath = join(runtimeDir, "server-info.json");
  if (existsSync(infoPath)) {
    try {
      const info = await readJson(infoPath);
      await waitForPidGone(info.pid, 5_000);
    } catch {
      // Best-effort cleanup verification.
    }
  }
  if (completed) {
    await rm(tempRoot, { recursive: true, force: true });
  } else {
    console.log(`Kept failed mock/Edge fixture: ${tempRoot}`);
  }
}
