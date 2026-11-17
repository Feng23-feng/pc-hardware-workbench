import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { createHash, randomUUID } from "node:crypto";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { waitForPidGone } from "../scripts/child-process-lifecycle.mjs";
import {
  launchPchwBrowserPage,
} from "../scripts/pchw-browser-evidence.mjs";

const root = resolve(import.meta.dirname, "..");
const runId = randomUUID();
const buildScript = join(root, "launcher", "build-dsh-package.ps1");
const packageRoot = join(
  root,
  "dist",
  `.pchw-runtime-binding-package-${runId}`,
);
const archivePath = `${packageRoot}.zip`;
let executable = process.env.PCHW_RUNTIME_TEST_EXE
  ? resolve(process.env.PCHW_RUNTIME_TEST_EXE)
  : null;
const edgeExecutable =
  process.env.SKILLDOCK_BROWSER_EXECUTABLE ??
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";
const tempRoot = await mkdtemp(join(tmpdir(), "pchw-runtime-binding-"));
const localRoot = join(tempRoot, "local-root");
const workspace = join(tempRoot, "workspace");
const runtimeDir = join(localRoot, "runtime-dsh-web");
const evidencePath = join(
  root,
  "work",
  "pchw-runtime-binding-old-tab-20261117.json",
);
const env = {
  ...process.env,
  SKILLDOCK_LOCAL_ROOT: localRoot,
  SKILLDOCK_AGENT_DRIVER: "mock",
  SKILLDOCK_BROWSER_EXECUTABLE: edgeExecutable,
  NODE_NO_WARNINGS: "1",
};
let browserA = null;
let browserB = null;
let active = false;
let packageBuilt = false;

function runProcess(command, args, {
  env: processEnv = process.env,
  timeoutMs = 120_000,
} = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: root,
      env: processEnv,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stderr = "";
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
      resolvePromise({ code, stderr });
    });
  });
}

function sleep(milliseconds) {
  return new Promise((resolvePromise) =>
    setTimeout(resolvePromise, milliseconds)
  );
}

function runLauncher(args, timeoutMs = 45_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(executable, args, {
      env,
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

async function waitForLaunchResult(previousPort = null) {
  const resultPath = join(localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 180; attempt += 1) {
    try {
      const result = await readJson(resultPath);
      if (
        result.ok &&
        result.url &&
        result.port &&
        result.pid > 0 &&
        result.launch_id &&
        result.port !== previousPort &&
        resolve(result.workspace) === resolve(workspace)
      ) {
        const health = await fetch(
          `${String(result.url).replace(/\/$/u, "")}/api/health`,
        ).then((response) => response.json());
        if (health.ok) return { result, health };
      }
    } catch {
      // Launcher is still writing or starting.
    }
    await sleep(100);
  }
  throw new Error("Runtime did not publish a fresh launch result.");
}

async function waitForDom(cdp, expression, predicate, label) {
  let value = null;
  for (let attempt = 0; attempt < 220; attempt += 1) {
    const evaluated = await cdp.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    value = evaluated.result.value;
    if (predicate(value)) return value;
    await sleep(100);
  }
  throw new Error(`${label} timed out: ${JSON.stringify(value)}`);
}

try {
  if (!executable) {
    const nodeBundle = join(tempRoot, "node-bundle");
    await mkdir(nodeBundle, { recursive: true });
    await copyFile(process.execPath, join(nodeBundle, "node.exe"));
    const licenseCandidates = [
      process.env.SKILLDOCK_NODE_LICENSE,
      join(dirname(process.execPath), "LICENSE"),
      join(
        root,
        "..",
        "pc-hardware-workbench",
        "work",
        "node22",
        "node-v22.23.4-win-x64",
        "LICENSE",
      ),
    ].filter(Boolean);
    const licenseSource = licenseCandidates.find((item) => existsSync(item));
    if (!licenseSource) {
      throw new Error("A Node LICENSE file is required for the test package.");
    }
    await copyFile(licenseSource, join(nodeBundle, "LICENSE"));
    const build = await runProcess(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        buildScript,
        "-OutputDirectory",
        packageRoot,
        "-ArchivePath",
        archivePath,
      ],
      {
        env: {
          ...process.env,
          SKILLDOCK_NODE_DIR: nodeBundle,
        },
      },
    );
    assert.equal(build.code, 0, build.stderr);
    executable = join(packageRoot, "SkillDock.exe");
    packageBuilt = true;
  }
  assert.equal(existsSync(executable), true, "Packaged launcher is missing");
  assert.equal(existsSync(edgeExecutable), true, "Edge executable is missing");
  await mkdir(workspace, { recursive: true });

  let launched = await runLauncher([
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ]);
  assert.equal(launched.code, 0);
  const first = await waitForLaunchResult();
  active = true;
  const panelToken = (
    await readFile(join(runtimeDir, "panel-capability-token"), "utf8")
  ).trim();
  browserA = await launchPchwBrowserPage({
    baseUrl: first.result.url,
    panelToken,
    profileRoot: tempRoot,
  });
  const firstBinding = await waitForDom(
    browserA.cdp,
    `(() => {
      const node = document.querySelector("#runtime-binding");
      return {
        state: node?.dataset.bindingState ?? "",
        pid: Number(node?.dataset.runtimePid ?? 0),
        port: Number(node?.dataset.runtimePort ?? 0),
        launchId: node?.dataset.runtimeLaunchId ?? "",
        hasInput: Boolean(document.querySelector("#symptom")),
        sendDisabled: document.querySelector("#send-button")?.disabled ?? true,
        fileInputDisabled:
          document.querySelector("#composer-file-input")?.disabled ?? true
      };
    })()`,
    (value) =>
      value.state === "bound" &&
      value.pid === first.result.pid &&
      value.port === first.result.port &&
      value.launchId === first.result.launch_id &&
      value.hasInput,
    "first Runtime binding",
  );
  assert.equal(firstBinding.fileInputDisabled, false);
  assert.match(first.result.exact_url, /runtime_launch_id=/u);
  assert.match(first.result.exact_url, /runtime_pid=/u);
  assert.match(first.result.exact_url, /runtime_port=/u);

  launched = await runLauncher(["--stop", "--silent"], 15_000);
  assert.equal(launched.code, 0);
  active = false;
  await waitForPidGone(first.result.pid, 5_000);

  const oldTab = await waitForDom(
    browserA.cdp,
    `(async () => {
      const node = document.querySelector("#runtime-binding");
      let healthFailed = false;
      try {
        const response = await fetch("/api/health", { cache: "no-store" });
        healthFailed = !response.ok;
      } catch {
        healthFailed = true;
      }
      return {
        state: node?.dataset.bindingState ?? "",
        port: Number(node?.dataset.runtimePort ?? 0),
        healthFailed,
        fileInputDisabled:
          document.querySelector("#composer-file-input")?.disabled ?? false,
        filePickerDisabled:
          document.querySelector(".file-picker")?.disabled ?? false,
        sendDisabled: document.querySelector("#send-button")?.disabled ?? false
      };
    })()`,
    (value) =>
      value.state === "offline" &&
      value.healthFailed &&
      value.fileInputDisabled &&
      value.filePickerDisabled &&
      value.sendDisabled,
    "old tab offline lock",
  );
  assert.equal(oldTab.port, first.result.port);

  launched = await runLauncher([
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ]);
  assert.equal(launched.code, 0);
  const second = await waitForLaunchResult(first.result.port);
  active = true;
  assert.notEqual(second.result.launch_id, first.result.launch_id);
  assert.notEqual(second.result.port, first.result.port);

  browserB = await launchPchwBrowserPage({
    baseUrl: second.result.url,
    panelToken,
    profileRoot: tempRoot,
  });
  const secondBinding = await waitForDom(
    browserB.cdp,
    `(() => {
      const node = document.querySelector("#runtime-binding");
      return {
        state: node?.dataset.bindingState ?? "",
        pid: Number(node?.dataset.runtimePid ?? 0),
        port: Number(node?.dataset.runtimePort ?? 0),
        launchId: node?.dataset.runtimeLaunchId ?? ""
      };
    })()`,
    (value) =>
      value.state === "bound" &&
      value.pid === second.result.pid &&
      value.port === second.result.port &&
      value.launchId === second.result.launch_id,
    "second Runtime binding",
  );
  assert.equal(secondBinding.port, second.result.port);

  const oldStillOffline = await waitForDom(
    browserA.cdp,
    `(() => {
      const node = document.querySelector("#runtime-binding");
      return {
        state: node?.dataset.bindingState ?? "",
        port: Number(node?.dataset.runtimePort ?? 0),
        fileInputDisabled:
          document.querySelector("#composer-file-input")?.disabled ?? false,
        sendDisabled: document.querySelector("#send-button")?.disabled ?? false
      };
    })()`,
    (value) =>
      value.state === "offline" &&
      value.port === first.result.port &&
      value.fileInputDisabled &&
      value.sendDisabled,
    "old tab remains on old port",
  );
  assert.equal(oldStillOffline.state, "offline");
  const executableHash = createHash("sha256")
    .update(await readFile(executable))
    .digest("hex");
  await writeFile(
    evidencePath,
    `${JSON.stringify({
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_runtime_binding_old_tab",
      runtime_executable_sha256: executableHash,
      first_runtime: {
        pid: first.result.pid,
        port: first.result.port,
        launch_id: first.result.launch_id,
        exact_url_has_binding:
          /runtime_launch_id=/u.test(first.result.exact_url) &&
          /runtime_pid=/u.test(first.result.exact_url) &&
          /runtime_port=/u.test(first.result.exact_url),
      },
      second_runtime: {
        pid: second.result.pid,
        port: second.result.port,
        launch_id: second.result.launch_id,
      },
      old_tab: {
        state: oldStillOffline.state,
        retained_old_port: oldStillOffline.port,
        file_input_disabled: oldStillOffline.fileInputDisabled,
        send_disabled: oldStillOffline.sendDisabled,
        health_failed: oldTab.healthFailed,
      },
      new_tab: {
        state: secondBinding.state,
        pid: secondBinding.pid,
        port: secondBinding.port,
        launch_id: secondBinding.launchId,
      },
      thread_api_calls: 0,
      real_thread_created: false,
      observed_at: new Date().toISOString(),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  console.log("PCHW Runtime binding and old-tab isolation: PASS");
} finally {
  await browserB?.close().catch(() => {});
  await browserA?.close().catch(() => {});
  if (active) {
    await runLauncher(["--stop", "--silent"], 15_000).catch(() => {});
  }
  await rm(tempRoot, { recursive: true, force: true });
  if (packageBuilt) {
    await rm(packageRoot, { recursive: true, force: true }).catch(() => {});
    await rm(archivePath, { force: true }).catch(() => {});
  }
}
