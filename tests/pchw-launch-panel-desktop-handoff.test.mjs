import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const packageRoot = resolve(
  process.argv[2] ??
    process.env.SKILLDOCK_RC_PACKAGE ??
    join(repoRoot, "dist", "SkillDock-PCHW-0.1.0-rc.2-win-x64"),
);
const executable = join(packageRoot, "SkillDock.exe");
const launchPanelPath = join(
  packageRoot,
  "skills",
  "pc-hardware-workbench",
  "scripts",
  "skilldock",
  "launch-panel.ps1",
);

for (const required of [executable, launchPanelPath]) {
  if (!existsSync(required)) {
    throw new Error(`Desktop handoff test input is missing: ${required}`);
  }
}

const launchPanelText = await readFile(launchPanelPath, "utf8");
assert.equal(
  launchPanelText.includes("msedge.exe"),
  false,
  "launch-panel still starts Edge directly from the sandbox",
);
assert.ok(
  launchPanelText.includes('Join-Path $env:WINDIR "explorer.exe"'),
  "launch-panel does not resolve the interactive Explorer executable",
);
assert.ok(
  launchPanelText.includes("-FilePath $explorerPath"),
  "launch-panel does not hand the URL to Explorer",
);
assert.ok(
  launchPanelText.includes("runtime_access_blocked"),
  "launch-panel does not expose the runtime access failure state",
);
assert.ok(
  launchPanelText.includes("interactive_desktop_unavailable"),
  "launch-panel does not expose the desktop handoff failure state",
);
const explorerHandoffBody = launchPanelText
  .split("function Open-InteractiveDesktopUrl")[1]
  ?.split("\nfunction ")[0] ?? "";
assert.equal(
  explorerHandoffBody.includes("-WindowStyle Hidden"),
  false,
  "the Explorer URL handoff must remain visible/interactive",
);
const releaseLauncherSource = await readFile(
  join(repoRoot, "launcher", "release", "SkillDockLauncher.cs"),
  "utf8",
);
assert.equal(
  releaseLauncherSource.includes(
    "browser.WindowStyle = ProcessWindowStyle.Hidden",
  ),
  false,
  "the release launcher must not hide the interactive browser handoff",
);

const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-launch-panel-desktop-"),
);
const workspace = join(tempRoot, "workspace");
const fakeWindir = join(tempRoot, "fake-windows");
const missingWindir = join(tempRoot, "missing-windows");
const handoffLog = join(tempRoot, "handoff.txt");
const chatContextPath = join(tempRoot, "chat-context.json");
const sourceSessionRef = randomUUID();
await Promise.all([
  mkdir(workspace, { recursive: true }),
  mkdir(fakeWindir, { recursive: true }),
]);
await writeFile(
  chatContextPath,
  `${JSON.stringify({
    schema_version: "1.0",
    source_session_ref: sourceSessionRef,
    objective: "验证 SkillDock 安全启动与回退状态。",
    summary: "不打开浏览器，只验证路径权限和 Shell 交接契约。",
    attachments: [],
    messages: [],
  }, null, 2)}\n`,
  "utf8",
);

function runProcess(command, args, env, timeoutMs = 120_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      env,
      windowsHide: true,
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
    const timer = setTimeout(() => {
      child.kill();
      rejectPromise(new Error(`Process timed out: ${command}`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr });
    });
  });
}

function cleanLauncherEnv(overrides = {}) {
  const env = { ...process.env };
  for (const name of [
    "PANEL_SKILL_ROOTS",
    "PANEL_SKILL_MANIFEST",
    "PANEL_WORKBENCH_MANIFEST",
  ]) {
    delete env[name];
  }
  return {
    ...env,
    SKILLDOCK_LAUNCHER: executable,
    SKILLDOCK_LOCAL_ROOT: join(tempRoot, "default-local"),
    CODEX_THREAD_ID: sourceSessionRef,
    PANEL_SKILL_ROOTS: join(packageRoot, "skills"),
    NODE_NO_WARNINGS: "1",
    ...overrides,
  };
}

async function readJson(path) {
  return JSON.parse(
    (await readFile(path, "utf8")).replace(/^\uFEFF/u, ""),
  );
}

async function isHealthy(url) {
  try {
    return await fetch(
      `${String(url).replace(/\/$/u, "")}/api/health`,
      { signal: AbortSignal.timeout(2_000) },
    ).then((response) => response.ok);
  } catch {
    return false;
  }
}

async function buildFakeExplorer() {
  const sourcePath = join(tempRoot, "FakeExplorer.cs");
  await writeFile(
    sourcePath,
    [
      "using System;",
      "using System.IO;",
      "internal static class FakeExplorer {",
      "  private static void Main(string[] args) {",
      "    string path = Environment.GetEnvironmentVariable(",
      "      \"SKILLDOCK_TEST_HANDOFF_LOG\");",
      "    if (!String.IsNullOrWhiteSpace(path)) {",
      "      File.WriteAllText(path, args.Length > 0 ? args[0] : \"\");",
      "    }",
      "    if (",
      "      args.Length > 0 &&",
      "      Environment.GetEnvironmentVariable(",
      "        \"SKILLDOCK_TEST_FETCH_HANDOFF\") == \"1\"",
      "    ) {",
      "      var request = (System.Net.HttpWebRequest)System.Net.WebRequest.Create(",
      "        args[0]);",
      "      request.CookieContainer = new System.Net.CookieContainer();",
      "      using (var response = request.GetResponse()) { }",
      "    }",
      "  }",
      "}",
      "",
    ].join("\n"),
    "utf8",
  );
  const windowsDirectory = process.env.WINDIR ?? process.env.windir;
  const csc = join(
    windowsDirectory,
    "Microsoft.NET",
    "Framework64",
    "v4.0.30319",
    "csc.exe",
  );
  const output = join(fakeWindir, "explorer.exe");
  const compiled = await runProcess(
    csc,
    ["/nologo", "/target:winexe", `/out:${output}`, sourcePath],
    process.env,
    30_000,
  );
  assert.equal(compiled.code, 0, `${compiled.stdout}\n${compiled.stderr}`);
}

async function runLaunchPanel(env, { noBrowser = false } = {}) {
  return runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      launchPanelPath,
      "-Workspace",
      workspace,
      "-LauncherPath",
      executable,
      "-ChatContextFile",
      chatContextPath,
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-SurfaceMode",
      "read-only",
      "-TimeoutSeconds",
      "60",
      ...(noBrowser ? ["-NoBrowser"] : []),
    ],
    env,
  );
}

async function stopRuntime(localRoot) {
  await runProcess(
    executable,
    ["--stop", "--silent"],
    cleanLauncherEnv({ SKILLDOCK_LOCAL_ROOT: localRoot }),
    20_000,
  ).catch(() => {});
}

try {
  await buildFakeExplorer();
  const shellLocalRoot = join(tempRoot, "shell-local");
  const shellRun = await runLaunchPanel(
    cleanLauncherEnv({
      SKILLDOCK_LOCAL_ROOT: shellLocalRoot,
      WINDIR: fakeWindir,
      SKILLDOCK_TEST_HANDOFF_LOG: handoffLog,
      SKILLDOCK_TEST_FETCH_HANDOFF: "1",
    }),
  );
  assert.equal(shellRun.code, 0, `${shellRun.stdout}\n${shellRun.stderr}`);
  const shellResult = JSON.parse(shellRun.stdout.trim());
  assert.equal(shellResult.ok, true);
  assert.equal(shellResult.browser_handoff, "windows-shell");
  assert.equal(shellResult.manual_open_required, false);
  assert.equal(shellResult.manual_open_url, "");
  assert.equal(shellResult.manual_open_file, "");
  const handedUrl = (await readFile(handoffLog, "utf8")).trim();
  assert.match(handedUrl, /^http:\/\/127\.0\.0\.1:\d+\//u);
  await stopRuntime(shellLocalRoot);

  const noWindowLocalRoot = join(tempRoot, "no-window-local");
  const noWindowRun = await runLaunchPanel(
    cleanLauncherEnv({
      SKILLDOCK_LOCAL_ROOT: noWindowLocalRoot,
      WINDIR: fakeWindir,
      SKILLDOCK_TEST_HANDOFF_LOG: join(tempRoot, "no-window-handoff.txt"),
      SKILLDOCK_TEST_HANDOFF_TIMEOUT_MS: "750",
    }),
  );
  assert.notEqual(noWindowRun.code, 0);
  const noWindowResult = JSON.parse(noWindowRun.stdout.trim());
  assert.equal(noWindowResult.ok, false);
  assert.equal(noWindowResult.error_code, "interactive_desktop_unavailable");
  assert.equal(noWindowResult.browser_handoff, "manual-required");
  assert.equal(noWindowResult.manual_open_required, true);
  assert.match(noWindowResult.manual_open_url, /^http:\/\/127\.0\.0\.1:/u);
  assert.equal(existsSync(noWindowResult.manual_open_file), true);
  const noWindowLaunchResult = await readJson(
    join(noWindowLocalRoot, "launch-result.json"),
  );
  assert.equal(
    await isHealthy(noWindowLaunchResult.url),
    true,
    "manual-open fallback must keep the Runtime available",
  );
  const firstManualResponse = await fetch(noWindowResult.manual_open_url, {
    redirect: "manual",
  });
  assert.equal(firstManualResponse.status, 303);
  const cookieHeader = firstManualResponse.headers
    .getSetCookie()
    .map((value) => value.split(";")[0])
    .join("; ");
  const manualTarget = new URL(
    firstManualResponse.headers.get("location"),
    noWindowResult.manual_open_url,
  );
  const manualPage = await fetch(manualTarget, {
    headers: { Cookie: cookieHeader },
    redirect: "manual",
  });
  assert.equal(manualPage.status, 200);
  const probeId = new URL(noWindowResult.manual_open_url).searchParams.get(
    "handoff_probe",
  );
  const masterToken = (
    await readFile(
      join(noWindowLocalRoot, "runtime-pchw", "capability-token"),
      "utf8",
    )
  ).trim();
  const ackStatus = await fetch(
    `${noWindowLaunchResult.url.replace(/\/$/u, "")}` +
      `/api/browser-handoff/status?probe_id=${encodeURIComponent(probeId)}`,
    { headers: { Authorization: `Bearer ${masterToken}` } },
  ).then((response) => response.json());
  assert.equal(ackStatus.status, "acknowledged");
  await stopRuntime(noWindowLocalRoot);

  const noBrowserLocalRoot = join(tempRoot, "no-browser-local");
  const noBrowserRun = await runLaunchPanel(
    cleanLauncherEnv({
      SKILLDOCK_LOCAL_ROOT: noBrowserLocalRoot,
    }),
    { noBrowser: true },
  );
  assert.equal(
    noBrowserRun.code,
    0,
    `${noBrowserRun.stdout}\n${noBrowserRun.stderr}`,
  );
  const noBrowserResult = JSON.parse(noBrowserRun.stdout.trim());
  assert.equal(noBrowserResult.ok, true);
  assert.equal(noBrowserResult.browser_handoff, "");
  await stopRuntime(noBrowserLocalRoot);

  const unavailableLocalRoot = join(tempRoot, "unavailable-local");
  const unavailableRun = await runLaunchPanel(
    cleanLauncherEnv({
      SKILLDOCK_LOCAL_ROOT: unavailableLocalRoot,
      WINDIR: missingWindir,
    }),
  );
  assert.notEqual(unavailableRun.code, 0);
  const unavailableResult = JSON.parse(unavailableRun.stdout.trim());
  assert.equal(unavailableResult.ok, false);
  assert.equal(
    unavailableResult.error_code,
    "interactive_desktop_unavailable",
  );
  assert.equal(unavailableResult.manual_open_required, true);
  assert.ok(unavailableResult.manual_open_url.length > 0);
  assert.equal(existsSync(unavailableResult.manual_open_file), true);
  assert.ok(unavailableResult.fallback_reason.length > 0);
  await stopRuntime(unavailableLocalRoot);

  const blockedLocalRoot = join(tempRoot, "blocked-local-file");
  await writeFile(blockedLocalRoot, "not a directory\n", "utf8");
  const blockedRun = await runLaunchPanel(
    cleanLauncherEnv({
      SKILLDOCK_LOCAL_ROOT: blockedLocalRoot,
    }),
  );
  assert.notEqual(blockedRun.code, 0);
  const blockedResult = JSON.parse(blockedRun.stdout.trim());
  assert.equal(blockedResult.ok, false);
  assert.equal(blockedResult.error_code, "runtime_access_blocked");
  assert.ok(blockedResult.fallback_reason.length > 0);

  console.log(
    "Launch-panel Explorer handoff and safe fallbacks: PASS",
  );
} finally {
  await stopRuntime(join(tempRoot, "shell-local"));
  await stopRuntime(join(tempRoot, "no-window-local"));
  await stopRuntime(join(tempRoot, "no-browser-local"));
  await stopRuntime(join(tempRoot, "unavailable-local"));
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept launch-panel test root: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
