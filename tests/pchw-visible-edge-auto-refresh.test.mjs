import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { validatePanelState } from "../lib/schema-validation.mjs";

const root = resolve(import.meta.dirname, "..");
const packageRoot = resolve(
  process.argv[2] ??
    process.env.SKILLDOCK_RC_PACKAGE ??
    join(root, "dist", "SkillDock-PCHW-0.1.0-rc.1-win-x64"),
);
const csvSource = resolve(
  process.env.PCHW_VISIBLE_EDGE_CSV ??
    join(root, "work", "PCHW-FRESHNESS-GATE-R7-20261117.csv"),
);
const panelTemplatePath = resolve(
  process.env.PCHW_VISIBLE_EDGE_PANEL ??
    join(root, "work", "PCHW-R7-LIVE-PANEL-20261117.json"),
);
const edgeExecutable =
  process.env.EDGE_PATH ??
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe";

for (const required of [
  join(packageRoot, "SkillDock.exe"),
  join(
    packageRoot,
    "skills",
    "pc-hardware-workbench",
    "scripts",
    "skilldock",
    "wait-panel.ps1",
  ),
  join(
    packageRoot,
    "skills",
    "pc-hardware-workbench",
    "scripts",
    "skilldock",
    "submit-panel-result.ps1",
  ),
  csvSource,
  panelTemplatePath,
  edgeExecutable,
]) {
  if (!existsSync(required)) {
    throw new Error(`Visible Edge regression input is missing: ${required}`);
  }
}

const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-visible-edge-auto-refresh-"),
);
const localRoot = join(tempRoot, "local");
const workspace = join(tempRoot, "workspace");
const csvPath = join(tempRoot, "visible-edge-auto-refresh.csv");
const profile = join(tempRoot, "edge-profile");
const evidenceRoot = join(
  root,
  "work",
  "pchw-visible-edge-auto-refresh-20261117",
);
let launcherPath = join(packageRoot, "SkillDock.exe");
let runtimePid = 0;
let edgeProcess = null;
let cdp = null;

function sleep(milliseconds) {
  return new Promise((resolvePromise) =>
    setTimeout(resolvePromise, milliseconds)
  );
}

async function readJson(path) {
  return JSON.parse(
    (await readFile(path, "utf8")).replace(/^\uFEFF/u, ""),
  );
}

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

function runProcess(command, args, {
  env = process.env,
  timeoutMs = 120_000,
  visible = false,
} = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      env,
      windowsHide: !visible,
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

function runPowerShell(script, args, env = process.env) {
  return runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      script,
      ...args,
    ],
    { env },
  );
}

class CdpConnection {
  static async connect(url, timeoutMs = 10_000) {
    const connection = new CdpConnection(url);
    await connection.opened(timeoutMs);
    return connection;
  }

  constructor(url) {
    this.socket = new WebSocket(url);
    this.nextId = 1;
    this.pending = new Map();
    this.closed = false;
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (message.id && this.pending.has(message.id)) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
      }
    });
    this.socket.addEventListener("close", () => {
      this.closed = true;
      for (const pending of this.pending.values()) {
        pending.reject(new Error("CDP connection closed"));
      }
      this.pending.clear();
    });
  }

  opened(timeoutMs) {
    if (this.socket.readyState === WebSocket.OPEN) {
      return Promise.resolve();
    }
    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(
        () => rejectPromise(new Error("CDP connection timed out")),
        timeoutMs,
      );
      this.socket.addEventListener("open", () => {
        clearTimeout(timer);
        resolvePromise();
      }, { once: true });
      this.socket.addEventListener("error", () => {
        clearTimeout(timer);
        rejectPromise(new Error("CDP connection failed"));
      }, { once: true });
    });
  }

  send(method, params = {}, timeoutMs = 20_000) {
    if (this.closed || this.socket.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("CDP connection is not open"));
    }
    const id = this.nextId++;
    this.socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolvePromise, rejectPromise) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rejectPromise(new Error(`CDP ${method} timed out`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolvePromise(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          rejectPromise(error);
        },
      });
    });
  }

  close() {
    if (!this.closed) {
      this.socket.close();
    }
  }
}

async function evaluate(expression, {
  awaitPromise = false,
} = {}) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    awaitPromise,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(
      result.exceptionDetails.exception?.description ??
        result.exceptionDetails.text,
    );
  }
  return result.result.value;
}

async function waitForDom(expression, predicate, label, attempts = 220) {
  let value = null;
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      value = await evaluate(expression);
      if (predicate(value)) return value;
    } catch {
      // Page may still be navigating.
    }
    await sleep(100);
  }
  throw new Error(`${label} timed out: ${JSON.stringify(value)}`);
}

async function findFreePort() {
  return new Promise((resolvePromise, rejectPromise) => {
    import("node:net").then(({ createServer }) => {
      const server = createServer();
      server.once("error", rejectPromise);
      server.listen(0, "127.0.0.1", () => {
        const port = server.address().port;
        server.close(() => resolvePromise(port));
      });
    }).catch(rejectPromise);
  });
}

async function stopRuntime() {
  if (!launcherPath || !existsSync(launcherPath)) {
    return;
  }
  await runProcess(
    launcherPath,
    ["--stop", "--silent"],
    {
      env: { ...process.env, SKILLDOCK_LOCAL_ROOT: localRoot },
      timeoutMs: 30_000,
    },
  ).catch(() => {});
  if (runtimePid > 0) {
    const deadline = Date.now() + 8_000;
    while (Date.now() < deadline) {
      try {
        process.kill(runtimePid, 0);
      } catch {
        return;
      }
      await sleep(150);
    }
    process.kill(runtimePid);
  }
}

async function closeBrowser() {
  if (cdp) {
    await cdp.send("Browser.close", {}, 5_000).catch(() => {});
    cdp.close();
    cdp = null;
  }
  if (edgeProcess && edgeProcess.exitCode === null) {
    edgeProcess.kill();
  }
}

try {
  await mkdir(workspace, { recursive: true });
  await copyFile(csvSource, csvPath);
  const launcherEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    NODE_NO_WARNINGS: "1",
  };
  const launched = await runProcess(
    launcherPath,
    [
      "--ensure",
      "--workspace",
      workspace,
      "--silent",
      "--no-browser",
    ],
    { env: launcherEnv },
  );
  assert.equal(launched.code, 0, `${launched.stdout}\n${launched.stderr}`);
  const launchResultPath = join(localRoot, "launch-result.json");
  let launchResult = null;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (existsSync(launchResultPath)) {
      launchResult = await readJson(launchResultPath);
      if (launchResult.ok) break;
    }
    await sleep(100);
  }
  assert.ok(launchResult?.url);
  runtimePid = Number(launchResult.pid);
  const baseUrl = String(launchResult.url).replace(/\/$/u, "");
  const runtimeDir = join(localRoot, "runtime-pchw");
  const masterToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const sourceToken = (
    await readFile(join(runtimeDir, "source-capability-token"), "utf8")
  ).trim();
  const sourceSessionRef = randomUUID();
  const taskId = `task-pchw-visible-${sourceSessionRef}`;
  const objective =
    "4K 游戏约 20 分钟后掉帧，请结合 CSV 判断温度、功耗和有效频率趋势。";
  const entryResponse = await fetch(
    `${baseUrl}/api/source-hosted/entry`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${masterToken}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        task_id: taskId,
        source_session_ref: sourceSessionRef,
        environment_thread_id: sourceSessionRef,
        objective,
        summary: "可见 Edge 自动刷新回归；不创建真实 Thread。",
        domain_state: {
          device_snapshot_ref: "device-snapshot:not-collected",
          evidence_refs: [],
        },
        domain_refs: [],
        ttl_seconds: 120,
      }),
    },
  );
  assert.equal(entryResponse.ok, true, await entryResponse.text());
  const entry = await entryResponse.json();

  const debuggingPort = await findFreePort();
  edgeProcess = spawn(
    edgeExecutable,
    [
      "--disable-extensions",
      "--no-first-run",
      "--no-default-browser-check",
      `--remote-debugging-port=${debuggingPort}`,
      `--user-data-dir=${profile}`,
      "about:blank",
    ],
    {
      windowsHide: false,
      stdio: ["ignore", "ignore", "pipe"],
    },
  );
  let edgeStderr = "";
  edgeProcess.stderr.on("data", (chunk) => {
    edgeStderr += chunk.toString().slice(0, 16_384);
  });
  let targets = null;
  for (let attempt = 0; attempt < 120; attempt += 1) {
    try {
      targets = await fetch(
        `http://127.0.0.1:${debuggingPort}/json/list`,
      ).then((response) => response.json());
      if (Array.isArray(targets) && targets.some((item) => item.type === "page")) {
        break;
      }
    } catch {
      // Edge is still starting.
    }
    await sleep(100);
  }
  const pageTarget = targets?.find((item) => item.type === "page");
  assert.ok(pageTarget?.webSocketDebuggerUrl, edgeStderr);
  cdp = await CdpConnection.connect(pageTarget.webSocketDebuggerUrl);
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("DOM.enable");
  await cdp.send("Network.enable");
  await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
    source: "window.__panelInstanceId = crypto.randomUUID();",
  });
  await cdp.send("Page.navigate", { url: entry.url });
  const panelInstanceId = await waitForDom(
    `(() => ({
      id: window.__panelInstanceId,
      ready: document.readyState,
      hasInput: Boolean(document.querySelector("#symptom")),
      binding: document.querySelector("#runtime-binding")?.dataset.bindingState ?? ""
    }))()`,
    (value) =>
      value.ready === "complete" &&
      value.hasInput &&
      value.binding === "bound" &&
      /^[a-f0-9-]{20,}$/u.test(value.id),
    "initial visible Edge panel",
  );
  const documentNode = await cdp.send("DOM.getDocument", {
    depth: -1,
    pierce: true,
  });
  const fileInputNode = await cdp.send("DOM.querySelector", {
    nodeId: documentNode.root.nodeId,
    selector: "#composer-file-input",
  });
  assert.ok(fileInputNode.nodeId > 0);
  await cdp.send("DOM.setFileInputFiles", {
    nodeId: fileInputNode.nodeId,
    files: [csvPath],
  });
  await waitForDom(
    `(() => ({
      inputDisabled: document.querySelector("#composer-file-input")?.disabled ?? true,
      attachmentText:
        document.querySelector(".task-data-sources .attachment-card strong")
          ?.textContent?.trim() ?? "",
      draftAttachment:
        document.querySelector(".composer-attachment strong")
          ?.textContent?.trim() ?? ""
    }))()`,
    (value) =>
      value.inputDisabled === false &&
      (
        value.attachmentText.includes("visible-edge-auto-refresh.csv") ||
        value.draftAttachment.includes("visible-edge-auto-refresh.csv")
      ),
    "CSV upload in visible Edge",
  );
  await evaluate(`(() => {
    const input = document.querySelector("#symptom");
    input.value = ${JSON.stringify(objective)};
    input.dispatchEvent(new Event("input", { bubbles: true }));
    return true;
  })()`);
  const sendClicked = await evaluate(`(() => {
    const button = document.querySelector("#send-button");
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`);
  assert.equal(sendClicked, true);
  await waitForDom(
    `(() => {
      const button = document.querySelector(".attachment-analyze");
      return { present: Boolean(button), disabled: button?.disabled ?? true };
    })()`,
    (value) => value.present && value.disabled === false,
    "analyze action",
  );
  assert.equal(await evaluate(`(() => {
    const button = document.querySelector(".attachment-analyze");
    if (!button || button.disabled) return false;
    button.click();
    return true;
  })()`), true);
  await waitForDom(
    `(() => ({
      present: Boolean(document.querySelector("#permission-card")),
      labels: [...document.querySelectorAll("#permission-card button")]
        .map((button) => button.textContent.trim())
    }))()`,
    (value) =>
      value.present &&
      value.labels.includes("仅本次允许"),
    "permission card",
  );
  assert.equal(await evaluate(`(() => {
    const button = [...document.querySelectorAll("#permission-card button")]
      .find((item) => item.textContent.trim() === "仅本次允许");
    if (!button) return false;
    button.click();
    return true;
  })()`), true);
  const waitingDom = await waitForDom(
    `(() => ({
      title:
        document.querySelector("#status-block .status-title")
          ?.textContent?.trim() ?? "",
      detail:
        document.querySelector("#status-block .status-detail")
          ?.textContent?.trim() ?? "",
      autoButton:
        document.querySelector("#source-result-auto-refresh")
          ?.textContent?.trim() ?? "",
      instanceId: window.__panelInstanceId,
      navigationType:
        performance.getEntriesByType("navigation")[0]?.type ?? ""
    }))()`,
    (value) =>
      value.title === "正在等待来源 Agent" &&
      value.detail.includes("无需刷新页面") &&
      value.autoButton.includes("等待自动刷新"),
    "waiting for source Agent",
  );
  await mkdir(evidenceRoot, { recursive: true });
  const waitingScreenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
  });
  const waitingPng = Buffer.from(waitingScreenshot.data, "base64");
  await writeFile(
    join(evidenceRoot, "edge-auto-refresh-waiting.png"),
    waitingPng,
  );

  const stateResponse = await fetch(`${baseUrl}/api/state`, {
    headers: { Authorization: `Bearer ${masterToken}` },
  });
  assert.equal(stateResponse.ok, true);
  const state = await stateResponse.json();
  const attachment = state.task.attachments.at(-1);
  const submission = [...state.task.timeline]
    .reverse()
    .find(
      (item) =>
        item.source === "source_hosted_intent" &&
        (item.attachments ?? []).some((itemAttachment) =>
          itemAttachment.id === attachment.id
        ),
    );
  assert.ok(attachment?.id);
  assert.ok(submission?.seq > 0);
  const commonPanelArgs = [
    "-ChannelId",
    `chat:source-hosted:${sourceSessionRef}`,
    "-SourceSessionRef",
    sourceSessionRef,
    "-ExpectedTaskId",
    state.task.task_id,
    "-ExpectedAttachmentId",
    attachment.id,
    "-ExpectedAttachmentSha256",
    attachment.sha256,
    "-ExpectedSubmissionSequence",
    String(submission.seq),
    "-ExpectedIntentEventId",
    String(submission.external_id ?? ""),
    "-RuntimeDirectory",
    runtimeDir,
  ];
  const skilldockScriptRoot = join(
    packageRoot,
    "skills",
    "pc-hardware-workbench",
    "scripts",
    "skilldock",
  );
  const claim = await runPowerShell(
    join(skilldockScriptRoot, "wait-panel.ps1"),
    [
      ...commonPanelArgs,
      "-TimeoutSeconds",
      "30",
      "-PollMilliseconds",
      "250",
    ],
    launcherEnv,
  );
  assert.equal(claim.code, 0, `${claim.stdout}\n${claim.stderr}`);
  const claimed = JSON.parse(claim.stdout.trim());
  assert.equal(claimed.ok, true);
  await waitForDom(
    `(() => ({
      waiting:
        document.querySelector("#source-agent-result-waiting")
          ?.textContent?.trim() ?? "",
      title:
        document.querySelector("#status-block .status-title")
          ?.textContent?.trim() ?? "",
      instanceId: window.__panelInstanceId
    }))()`,
    (value) =>
      value.waiting.includes("正在等待来源 Agent 返回结论") &&
      value.title === "正在等待来源 Agent",
    "Agent-pulled DOM state",
  );
  const agentWaitingScreenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
  });
  const agentWaitingPng = Buffer.from(
    agentWaitingScreenshot.data,
    "base64",
  );
  await writeFile(
    join(evidenceRoot, "edge-auto-refresh-agent-pulled.png"),
    agentWaitingPng,
  );

  const artifact =
    claimed.source_tool_result?.packet?.tool_result?.artifact;
  assert.ok(artifact?.id);
  const template = await readJson(panelTemplatePath);
  const oldArtifact = template.artifact_refs?.[0];
  assert.ok(oldArtifact?.id);
  let panel = JSON.parse(
    JSON.stringify(template)
      .replaceAll(oldArtifact.id, artifact.id)
      .replaceAll(oldArtifact.sha256, artifact.sha256)
      .replaceAll(
        String(oldArtifact.relative_path ?? ""),
        String(artifact.relative_path ?? ""),
      ),
  );
  panel.artifact_refs = [artifact];
  panel.current_goal = objective;
  panel = validatePanelState(panel);
  const panelPath = join(tempRoot, "visible-edge-panel.json");
  await writeJson(panelPath, panel);
  const imported = await runPowerShell(
    join(skilldockScriptRoot, "submit-panel-result.ps1"),
    [
      ...commonPanelArgs,
      "-PanelFile",
      panelPath,
      "-MessageText",
      panel.judgement,
      "-Objective",
      objective,
      "-Summary",
      panel.turn_summary ?? "",
    ],
    launcherEnv,
  );
  assert.equal(imported.code, 0, `${imported.stdout}\n${imported.stderr}`);
  const importedResult = JSON.parse(imported.stdout.trim());
  assert.equal(importedResult.phase, "source_result_synced");
  const answerDom = await waitForDom(
    `(() => {
      const image = document.querySelector(".analysis-chart img");
      return {
        instanceId: window.__panelInstanceId,
        navigationType:
          performance.getEntriesByType("navigation")[0]?.type ?? "",
        answerPresent: Boolean(document.querySelector("#answer-card")),
        waitingPresent:
          Boolean(document.querySelector("#source-agent-result-waiting")),
        judgement:
          document.querySelector(".answer-judgement")?.textContent?.trim() ?? "",
        chartLoaded: Boolean(
          image && image.complete && image.naturalWidth > 0
        ),
        title: document.title
      };
    })()`,
    (value) =>
      value.answerPresent &&
      !value.waitingPresent &&
      value.judgement.length > 20 &&
      value.chartLoaded,
    "automatic answer render without reload",
  );
  assert.equal(answerDom.instanceId, panelInstanceId.id);
  assert.notEqual(answerDom.navigationType, "reload");
  const answerScreenshot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: true,
  });
  const answerPng = Buffer.from(answerScreenshot.data, "base64");
  await writeFile(
    join(evidenceRoot, "edge-auto-refresh-answer.png"),
    answerPng,
  );
  const evidence = {
    schema_version: "1.0",
    status: "passed",
    gate: "pchw_visible_edge_auto_refresh",
    headless: false,
    mock_agent: false,
    real_thread_created: false,
    synthetic_source_session: true,
    task_id: state.task.task_id,
    attachment_id: attachment.id,
    attachment_sha256: attachment.sha256,
    panel_instance_id: panelInstanceId.id,
    waiting_dom: waitingDom,
    agent_pulled_dom_confirmed: true,
    answer_dom: answerDom,
    screenshot_paths: [
      join(evidenceRoot, "edge-auto-refresh-waiting.png"),
      join(evidenceRoot, "edge-auto-refresh-agent-pulled.png"),
      join(evidenceRoot, "edge-auto-refresh-answer.png"),
    ],
    observed_at: new Date().toISOString(),
  };
  await writeJson(
    join(evidenceRoot, "visible-edge-auto-refresh-evidence.json"),
    evidence,
  );
  console.log("PCHW visible Edge automatic source-result refresh: PASS");
}
finally {
  await closeBrowser();
  await stopRuntime();
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept visible Edge smoke workspace: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
