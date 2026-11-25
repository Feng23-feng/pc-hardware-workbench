import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  existsSync,
} from "node:fs";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { MockAgentDriver } from "../lib/agents/mock-agent-driver.mjs";
import { validatePanelState } from "../lib/schema-validation.mjs";
import { waitForPidGone } from "../scripts/child-process-lifecycle.mjs";
import {
  compareSkillTrees,
} from "../scripts/skill-tree-identity.mjs";

const root = resolve(import.meta.dirname, "..");
const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-pchw-source-mock-"));
const runId = randomUUID();
const packageDirectory = join(
  root,
  "dist",
  `.pchw-launcher-preview-${runId}`,
);
const archivePath = join(
  root,
  "dist",
  `.pchw-launcher-preview-${runId}.zip`,
);
const nodeBundle = join(tempRoot, "node-runtime");
const localRoot = join(tempRoot, "local-app-data", "SkillDock");
const runtimeDir = join(localRoot, "runtime-dsh-web");
const workspace = join(tempRoot, "workspace");
const pchwRoot = join(root, "..", "pc-hardware-workbench");
const pchwSkillSource = join(
  pchwRoot,
  "skill",
  "pc-hardware-workbench",
);
const pchwInstaller = join(pchwRoot, "tools", "install-skill.ps1");
const installedSkillsRoot = join(tempRoot, "installed-skills");
const installedSkillRoot = join(
  installedSkillsRoot,
  "pc-hardware-workbench",
);
const buildScript = join(root, "launcher", "build-dsh-package.ps1");
const integrationDir = join(root, "integrations", "skilldock");
const chatContextPath = join(tempRoot, "chat-context.json");
const csvPath = join(tempRoot, "gpu-stutter.csv");
const browserEvidenceDir = join(
  root,
  "work",
  "pchw-browser-evidence-2026-11-17",
);
const launcherEvidenceDir = join(
  root,
  "work",
  "pchw-launcher-preview-evidence-2026-11-17",
);
let launcherPath = null;
let launcherEnv = null;
let activeUrl = null;
let installedSkillIdentity = null;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function sha256CanonicalTextFile(filePath) {
  const text = (await readFile(filePath, "utf8"))
    .replaceAll("\r\n", "\n")
    .replaceAll("\r", "\n");
  return sha256(text);
}

function runProcess(command, args, {
  env = process.env,
  timeoutMs = 120_000,
} = {}) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd: root,
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
      rejectPromise(new Error(
        `Process timed out: ${command} ${args.join(" ")}\n${stderr}`,
      ));
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

async function launchFormalPanel(sourceSessionRef) {
  const environmentThreadId = sourceSessionRef;
  const launched = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "launch-panel.ps1"),
      "-Workspace",
      workspace,
      "-ChatContextFile",
      chatContextPath,
      "-NoBrowser",
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-SourceSessionRef",
      sourceSessionRef,
    ],
    {
      env: {
        ...launcherEnv,
        CODEX_THREAD_ID: environmentThreadId,
      },
    },
  );
  let result;
  try {
    result = JSON.parse(launched.stdout.trim());
  } catch {
    result = null;
  }
  if (launched.code !== 0 || !result?.ok) {
    throw new Error(
      `launch-panel failed: ${result?.error_code ?? "unknown"} ` +
      `${result?.error ?? launched.stderr}`,
    );
  }
  assert.equal(result.driver, "source-external");
  const resultUrl = new URL(result.url);
  assert.equal(Number(result.runtime_port), Number(resultUrl.port));
  assert.ok(Number(result.runtime_pid) > 0);
  assert.ok(String(result.runtime_launch_id).length >= 16);
  assert.equal(
    resultUrl.searchParams.get("runtime_launch_id"),
    result.runtime_launch_id,
  );
  assert.equal(
    Number(resultUrl.searchParams.get("runtime_pid")),
    Number(result.runtime_pid),
  );
  assert.equal(
    Number(resultUrl.searchParams.get("runtime_port")),
    Number(result.runtime_port),
  );
  activeUrl = result.url;
  return {
    entryUrl: result.url,
    baseUrl: new URL(result.url).origin,
    taskRef: result.task_ref,
    channelId: result.channel_id,
    sourceSessionRef: result.source_session_ref,
    runtimeLaunchId: result.runtime_launch_id,
    runtimePid: result.runtime_pid,
    runtimePort: result.runtime_port,
    runtimeOrigin: result.runtime_origin,
  };
}

async function stopFormalPanel(baseUrl = "") {
  const serverInfo = JSON.parse(
    (await readFile(join(runtimeDir, "server-info.json"), "utf8"))
      .replace(/^\uFEFF/u, ""),
  );
  const resolvedBaseUrl =
    baseUrl || `http://127.0.0.1:${serverInfo.port}`;
  const stopped = await runProcess(
    launcherPath,
    ["--stop", "--silent"],
    { env: launcherEnv, timeoutMs: 30_000 },
  );
  if (stopped.code !== 0) {
    throw new Error(`launcher stop failed: ${stopped.stderr}`);
  }
  if (await isHealthy(resolvedBaseUrl)) {
    throw new Error("launcher server remained healthy after stop");
  }
  await waitForPidGone(serverInfo.pid);
  activeUrl = null;
}

function panelHeaders(panelToken, { json = false } = {}) {
  return {
    Cookie: `panel_token=${encodeURIComponent(panelToken)}`,
    ...(json ? { "Content-Type": "application/json" } : {}),
  };
}

function sleep(milliseconds) {
  return new Promise((resolvePromise) =>
    setTimeout(resolvePromise, milliseconds)
  );
}

async function findBrowserExecutable() {
  const candidates = [
    process.env.SKILLDOCK_BROWSER_EXECUTABLE,
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  ].filter(Boolean);
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  throw new Error("A real Chrome or Edge executable is required.");
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
    this.events = [];
    this.closed = false;
    this.socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      if (message.id && this.pending.has(message.id)) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message));
        else pending.resolve(message.result);
      } else if (message.method) {
        this.events.push(message);
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
      const timer = setTimeout(() => {
        rejectPromise(new Error("CDP connection timed out"));
      }, timeoutMs);
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

  send(method, params = {}, timeoutMs = 15_000) {
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
    if (!this.closed) this.socket.close();
  }
}

async function launchBrowserPage(baseUrl, panelToken, {
  initScript = "",
} = {}) {
  const normalizedBaseUrl = String(baseUrl).replace(/\/+$/u, "");
  const executable = await findBrowserExecutable();
  const profile = await mkdtemp(join(tempRoot, "browser-profile-"));
  const child = spawn(executable, [
    "--headless=new",
    "--disable-gpu",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-breakpad",
    "--disable-crash-reporter",
    "--no-first-run",
    "--no-default-browser-check",
    "--remote-debugging-port=0",
    `--user-data-dir=${profile}`,
    "about:blank",
  ], {
    windowsHide: true,
    stdio: ["ignore", "ignore", "pipe"],
  });
  let stderr = "";
  child.stderr.on("data", (chunk) => {
    if (stderr.length < 16_384) stderr += chunk.toString();
  });
  const activePortPath = join(profile, "DevToolsActivePort");
  let port = null;
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`Browser exited before CDP was ready: ${stderr}`);
    }
    try {
      const [portLine] = (await readFile(activePortPath, "utf8")).split(
        /\r?\n/u,
      );
      port = Number.parseInt(portLine, 10);
      if (Number.isInteger(port) && port > 0) break;
    } catch {
      // Browser is still creating its DevTools endpoint.
    }
    await sleep(100);
  }
  if (!port) {
    child.kill();
    throw new Error(`Browser DevTools endpoint did not start: ${stderr}`);
  }
  const targetResponse = await fetch(
    `http://127.0.0.1:${port}/json/new?about%3Ablank`,
    { method: "PUT" },
  );
  assert.equal(targetResponse.ok, true);
  const target = await targetResponse.json();
  const cdp = await CdpConnection.connect(target.webSocketDebuggerUrl);
  await cdp.send("Network.enable");
  await cdp.send("Page.enable");
  await cdp.send("Runtime.enable");
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 1440,
    height: 900,
    deviceScaleFactor: 1,
    mobile: false,
  });
  const cookieResult = await cdp.send("Network.setCookie", {
    name: "panel_token",
    value: panelToken,
    url: `${normalizedBaseUrl}/`,
    path: "/",
    httpOnly: true,
    sameSite: "Strict",
  });
  assert.equal(cookieResult.success, true);
  if (initScript) {
    await cdp.send("Page.addScriptToEvaluateOnNewDocument", {
      source: initScript,
    });
  }
  await cdp.send("Page.navigate", { url: `${normalizedBaseUrl}/` });

  return {
    executable,
    profile,
    child,
    cdp,
    async close() {
      try {
        await cdp.send("Browser.close", {}, 5_000);
      } catch {
        // Browser.close is not available on every page target.
      }
      cdp.close();
      await Promise.race([
        new Promise((resolvePromise) => {
          if (child.exitCode !== null) resolvePromise();
          else child.once("exit", resolvePromise);
        }),
        sleep(5_000),
      ]);
      if (child.exitCode === null) child.kill();
      await sleep(250);
      await rm(profile, { recursive: true, force: true }).catch(() => {});
    },
  };
}

async function waitForRenderedAnswer(cdp) {
  let lastValue = null;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const evaluated = await cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const card = document.querySelector("#answer-card");
        const judgement = document.querySelector(".answer-judgement");
        const unresolved = document.querySelector("#current-unresolved-item");
        const chart = document.querySelector(".analysis-chart");
        const images = [...document.querySelectorAll(".analysis-chart img")];
        return {
          readyState: document.readyState,
          title: document.title,
          cardPresent: Boolean(card),
          judgementText: judgement?.textContent?.trim() ?? "",
          unresolvedText: unresolved?.textContent?.trim() ?? "",
          chartPresent: Boolean(chart),
          imageCount: images.length,
          imagesLoaded: images.length > 0 && images.every(
            (image) => image.complete && image.naturalWidth > 0
          ),
          hasAnswerHeading:
            document.body.innerText.includes("本轮判断与建议")
        };
      })()`,
      returnByValue: true,
    });
    const value = evaluated.result.value;
    lastValue = value;
    if (
      value.readyState === "complete" &&
      value.cardPresent &&
      value.judgementText.length >= 20 &&
      value.unresolvedText.length > 0 &&
      value.chartPresent &&
      value.imageCount >= 1 &&
      value.imagesLoaded &&
      value.hasAnswerHeading
    ) {
      return value;
    }
    await sleep(100);
  }
  throw new Error(
    `PCHW answer DOM did not finish rendering: ${JSON.stringify(lastValue)}`,
  );
}

async function captureBrowserEvidence(baseUrl, panelToken, {
  suffix = "",
  postRestart = false,
} = {}) {
  const browser = await launchBrowserPage(baseUrl, panelToken);
  try {
    const rendered = await waitForRenderedAnswer(browser.cdp);
    const domEvaluation = await browser.cdp.send("Runtime.evaluate", {
      expression: `(async () => {
        const image = document.querySelector(".analysis-chart img");
        if (image) {
          try {
            await image.decode();
          } catch {}
        }
        return {
          title: document.title,
          userAgent: navigator.userAgent,
          judgementText:
            document.querySelector(".answer-judgement")?.textContent?.trim() ?? "",
          unresolvedText:
            document.querySelector("#current-unresolved-item")?.textContent?.trim() ?? "",
          uncertaintyTexts: [
            ...document.querySelectorAll(".answer-uncertainty li")
          ].map((item) => item.textContent?.trim() ?? ""),
          chartCaption:
            document.querySelector(".chart-caption")?.textContent?.trim() ?? "",
          chartImageWidth: image?.naturalWidth ?? 0,
          chartImageHeight: image?.naturalHeight ?? 0,
          answerCardHtml:
            document.querySelector("#answer-card")?.outerHTML ?? "",
          bodyTextHash: (() => {
            const text = document.body.innerText;
            let hash = 2166136261;
            for (let index = 0; index < text.length; index += 1) {
              hash ^= text.charCodeAt(index);
              hash = Math.imul(hash, 16777619);
            }
            return (hash >>> 0).toString(16).padStart(8, "0");
          })()
        };
      })()`,
      awaitPromise: true,
      returnByValue: true,
    });
    const dom = domEvaluation.result.value;
    assert.equal(dom.title, "SkillDock");
    assert.ok(dom.judgementText.length >= 20);
    assert.ok(dom.unresolvedText.length > 0);
    assert.equal(dom.uncertaintyTexts.includes(dom.unresolvedText), false);
    assert.ok(dom.chartImageWidth > 0);
    assert.ok(dom.chartImageHeight > 0);
    assert.ok(dom.answerCardHtml.includes("analysis-chart"));
    assert.ok(dom.answerCardHtml.includes("answer-judgement"));
    assert.ok(dom.answerCardHtml.includes("current-unresolved-item"));
    assert.ok(rendered.imagesLoaded);

    const answerCardRect = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const card = document.querySelector("#answer-card");
        card.scrollIntoView({ block: "start" });
        const rect = card.getBoundingClientRect();
        return {
          x: rect.left + window.scrollX,
          y: rect.top + window.scrollY,
          width: rect.width,
          height: rect.height
        };
      })()`,
      returnByValue: true,
    });
    const clip = answerCardRect.result.value;
    assert.ok(clip.width >= 600);
    assert.ok(clip.height >= 600);
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
      captureBeyondViewport: true,
      clip: {
        x: clip.x,
        y: clip.y,
        width: clip.width,
        height: clip.height,
        scale: 1,
      },
    }, 20_000);
    const screenshotBuffer = Buffer.from(screenshot.data, "base64");
    await browser.cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 390,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true,
    });
    const mobileLayoutEvaluation = await browser.cdp.send(
      "Runtime.evaluate",
      {
        expression: `(() => {
          const binding = document.querySelector("#runtime-binding");
          binding?.querySelector("summary")?.click();
          window.scrollTo(0, 0);
          const answer = document.querySelector("#answer-card");
          const topbar = document.querySelector(".topbar");
          const handoff = document.querySelector(".handoff-strip-main");
          const statusSteps = document.querySelector(".status-steps");
          return {
            viewportWidth: document.documentElement.clientWidth,
            documentScrollWidth: document.documentElement.scrollWidth,
            bodyScrollWidth: document.body.scrollWidth,
            answerRight:
              answer?.getBoundingClientRect().right ?? 0,
            bindingRight:
              binding?.getBoundingClientRect().right ?? 0,
            bindingOpen: binding?.open ?? false,
            topbarDirection:
              topbar ? getComputedStyle(topbar).flexDirection : "",
            handoffDirection:
              handoff ? getComputedStyle(handoff).flexDirection : "",
            statusStepColumns:
              statusSteps
                ? getComputedStyle(statusSteps)
                    .gridTemplateColumns
                    .split(" ")
                    .filter(Boolean)
                    .length
                : 0
          };
        })()`,
        returnByValue: true,
      },
    );
    const mobileLayout = mobileLayoutEvaluation.result.value;
    assert.equal(mobileLayout.viewportWidth, 390);
    assert.equal(
      mobileLayout.documentScrollWidth,
      mobileLayout.viewportWidth,
    );
    assert.equal(mobileLayout.bodyScrollWidth, mobileLayout.viewportWidth);
    assert.ok(mobileLayout.answerRight <= mobileLayout.viewportWidth);
    assert.ok(mobileLayout.bindingRight <= mobileLayout.viewportWidth);
    assert.equal(mobileLayout.bindingOpen, true);
    assert.equal(mobileLayout.topbarDirection, "column");
    assert.equal(mobileLayout.handoffDirection, "column");
    assert.equal(mobileLayout.statusStepColumns, 2);
    await browser.cdp.send("Runtime.evaluate", {
      expression:
        `document.querySelector("#runtime-binding > summary")?.click()`,
      returnByValue: true,
    });
    const mobileScreenshot = await browser.cdp.send(
      "Page.captureScreenshot",
      {
        format: "png",
        fromSurface: true,
      },
      20_000,
    );
    const mobileScreenshotBuffer = Buffer.from(
      mobileScreenshot.data,
      "base64",
    );
    await browser.cdp.send("Runtime.evaluate", {
      expression:
        `document.querySelector("#answer-card")
          ?.scrollIntoView({ block: "start" })`,
      returnByValue: true,
    });
    const mobileAnswerScreenshot = await browser.cdp.send(
      "Page.captureScreenshot",
      {
        format: "png",
        fromSurface: true,
      },
      20_000,
    );
    const mobileAnswerScreenshotBuffer = Buffer.from(
      mobileAnswerScreenshot.data,
      "base64",
    );
    await browser.cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 320,
      height: 844,
      deviceScaleFactor: 1,
      mobile: true,
    });
    const narrowLayoutEvaluation = await browser.cdp.send(
      "Runtime.evaluate",
      {
        expression: `(() => ({
          viewportWidth: document.documentElement.clientWidth,
          documentScrollWidth: document.documentElement.scrollWidth,
          bodyScrollWidth: document.body.scrollWidth,
          topbarDirection:
            getComputedStyle(document.querySelector(".topbar")).flexDirection,
          handoffDirection:
            getComputedStyle(
              document.querySelector(".handoff-strip-main")
            ).flexDirection
        }))()`,
        returnByValue: true,
      },
    );
    const narrowLayout = narrowLayoutEvaluation.result.value;
    assert.equal(narrowLayout.viewportWidth, 320);
    assert.equal(
      narrowLayout.documentScrollWidth,
      narrowLayout.viewportWidth,
    );
    assert.equal(narrowLayout.bodyScrollWidth, narrowLayout.viewportWidth);
    assert.equal(narrowLayout.topbarDirection, "column");
    assert.equal(narrowLayout.handoffDirection, "column");
    await browser.cdp.send("Emulation.clearDeviceMetricsOverride");
    const answerDomText = `${dom.answerCardHtml}\n`;
    const screenshotName = `pchw-panel-answer-card${suffix}.png`;
    const mobileScreenshotName = `pchw-panel-mobile-shell${suffix}.png`;
    const mobileAnswerScreenshotName =
      `pchw-panel-answer-card-mobile${suffix}.png`;
    const domName = `pchw-panel-answer-card${suffix}.html`;
    const evidenceName = `browser-evidence${suffix}.json`;
    const screenshotPath = join(browserEvidenceDir, screenshotName);
    const domPath = join(browserEvidenceDir, domName);
    await mkdir(browserEvidenceDir, { recursive: true });
    await writeFile(screenshotPath, screenshotBuffer, { mode: 0o600 });
    await writeFile(
      join(browserEvidenceDir, mobileScreenshotName),
      mobileScreenshotBuffer,
      { mode: 0o600 },
    );
    await writeFile(
      join(browserEvidenceDir, mobileAnswerScreenshotName),
      mobileAnswerScreenshotBuffer,
      { mode: 0o600 },
    );
    await writeFile(domPath, answerDomText, {
      encoding: "utf8",
      mode: 0o600,
    });
    const evidence = {
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_real_browser_dom",
      post_restart: postRestart,
      browser: {
        engine: "Chromium",
        executable_name: browser.executable
          .split(/[\\/]/u)
          .at(-1),
        user_agent: dom.userAgent,
        viewport: { width: 1440, height: 900 },
      },
      dom_assertions: {
        document_title: dom.title,
        answer_card_present: rendered.cardPresent,
        judgement_length: dom.judgementText.length,
        judgement_sha256: sha256(dom.judgementText),
        chart_present: rendered.chartPresent,
        chart_image_count: rendered.imageCount,
        chart_image_loaded: rendered.imagesLoaded,
        chart_image_width: dom.chartImageWidth,
        chart_image_height: dom.chartImageHeight,
        chart_caption: dom.chartCaption,
        body_text_fnv1a32: dom.bodyTextHash,
      },
      mobile_layout: {
        viewport_width: mobileLayout.viewportWidth,
        document_scroll_width: mobileLayout.documentScrollWidth,
        body_scroll_width: mobileLayout.bodyScrollWidth,
        horizontal_overflow: false,
        binding_details_opened: mobileLayout.bindingOpen,
        narrow_viewport: {
          width: narrowLayout.viewportWidth,
          document_scroll_width: narrowLayout.documentScrollWidth,
          body_scroll_width: narrowLayout.bodyScrollWidth,
          horizontal_overflow: false,
        },
      },
      artifacts: {
        screenshot_path: screenshotName,
        screenshot_bytes: screenshotBuffer.length,
        screenshot_sha256: sha256(screenshotBuffer),
        screenshot_width: Math.round(clip.width),
        screenshot_height: Math.round(clip.height),
        mobile_screenshot_path: mobileScreenshotName,
        mobile_screenshot_bytes: mobileScreenshotBuffer.length,
        mobile_screenshot_sha256: sha256(mobileScreenshotBuffer),
        mobile_answer_screenshot_path: mobileAnswerScreenshotName,
        mobile_answer_screenshot_bytes: mobileAnswerScreenshotBuffer.length,
        mobile_answer_screenshot_sha256:
          sha256(mobileAnswerScreenshotBuffer),
        answer_dom_path: domName,
        answer_dom_sha256: sha256(answerDomText),
      },
      evidence_source: "real_headless_browser_dom",
      api_state_used_for_browser_acceptance: false,
      observed_at: new Date().toISOString(),
    };
    await writeFile(
      join(browserEvidenceDir, evidenceName),
      `${JSON.stringify(evidence, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    return evidence;
  } finally {
    await browser.close();
  }
}

async function captureWaitingForSourceEvidence(
  baseUrl,
  panelToken,
  { existingBrowser = null } = {},
) {
  const ownsBrowser = existingBrowser === null;
  const browser =
    existingBrowser ?? await launchBrowserPage(baseUrl, panelToken);
  try {
    let value = null;
    for (let attempt = 0; attempt < 160; attempt += 1) {
      const evaluated = await browser.cdp.send("Runtime.evaluate", {
        expression: `(() => ({
          title:
            document.querySelector("#status-block .status-title")
              ?.textContent?.trim() ?? "",
          detail:
            document.querySelector("#status-block .status-detail")
              ?.textContent?.trim() ?? "",
          instruction:
            document.querySelector("#status-block .status-next p")
              ?.textContent?.trim() ?? "",
          autoRefresh:
            document.querySelector("#source-result-auto-refresh")
              ?.textContent?.trim() ?? "",
          handoffPresent:
            Boolean(document.querySelector(".handoff-strip")),
          waitingPanel:
            document.querySelector("#source-agent-result-waiting")
              ?.textContent?.trim() ?? ""
        }))()`,
        returnByValue: true,
      });
      value = evaluated.result.value;
      if (
        value.title === "正在等待来源 Agent" &&
        value.detail.includes("自动显示") &&
        value.instruction.includes("无需操作") &&
        value.autoRefresh.includes("等待自动刷新") &&
        value.handoffPresent === false &&
        value.waitingPanel.includes("正在等待来源 Agent 返回结论")
      ) {
        break;
      }
      await sleep(100);
    }
    assert.equal(value?.title, "正在等待来源 Agent");
    assert.match(value.detail, /自动显示/u);
    assert.match(value.instruction, /无需操作/u);
    assert.match(value.autoRefresh, /等待自动刷新/u);
    assert.equal(value.handoffPresent, false);
    assert.match(value.waitingPanel, /正在等待来源 Agent 返回结论/u);
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
    }, 20_000);
    const screenshotBuffer = Buffer.from(screenshot.data, "base64");
    await mkdir(browserEvidenceDir, { recursive: true });
    const screenshotName = "pchw-panel-waiting-source.png";
    await writeFile(join(browserEvidenceDir, screenshotName), screenshotBuffer, {
      mode: 0o600,
    });
    const evidence = {
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_waiting_for_conversation_agent",
      dom: value,
      screenshot_path: screenshotName,
      screenshot_sha256: sha256(screenshotBuffer),
      evidence_source: "same_page_browser_polling_dom",
      api_state_used_for_browser_acceptance: false,
      observed_at: new Date().toISOString(),
    };
    await writeFile(
      join(browserEvidenceDir, "waiting-source-evidence.json"),
      `${JSON.stringify(evidence, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    return evidence;
  } finally {
    if (ownsBrowser) {
      await browser.close();
    }
  }
}

async function performHumanPanelFlow(
  baseUrl,
  panelToken,
  hardwareProblem,
  { keepOpen = false } = {},
) {
  const browser = await launchBrowserPage(baseUrl, panelToken, {
    initScript: `
      window.__panelInstanceId = crypto.randomUUID();
      window.__panelBootErrors = [];
      window.addEventListener("error", (event) => {
        window.__panelBootErrors.push(
          "error: " + (event.error?.stack || event.message || "unknown")
        );
      });
      window.addEventListener("unhandledrejection", (event) => {
        window.__panelBootErrors.push(
          "rejection: " + (event.reason?.stack || event.reason || "unknown")
        );
      });
    `,
  });
  try {
    const waitFor = async (expression, predicate, label) => {
      let value = null;
      for (let attempt = 0; attempt < 220; attempt += 1) {
        const evaluated = await browser.cdp.send("Runtime.evaluate", {
          expression,
          returnByValue: true,
        });
        value = evaluated.result.value;
        if (predicate(value)) return value;
        await sleep(100);
      }
      throw new Error(`${label} timed out: ${JSON.stringify(value)}`);
    };

    await waitFor(
      `(() => ({
        attachment:
          document.querySelector(".attachment-card strong")?.textContent?.trim() ?? "",
        hasInput: Boolean(document.querySelector("#symptom")),
        bindingState:
          document.querySelector("#runtime-binding")?.dataset.bindingState ?? "",
        bindingText:
          document.querySelector("#runtime-binding")?.textContent?.trim() ?? "",
        bodyText: document.body.innerText.slice(0, 1200),
        errors: window.__panelBootErrors ?? []
      }))()`,
      (value) =>
        value.attachment === "gpu-stutter.csv" &&
        value.hasInput,
      "prefilled human panel",
    );
    const bindingDetails = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const binding = document.querySelector("#runtime-binding");
        const summary = binding?.querySelector("summary");
        summary?.click();
        return {
          tag: binding?.tagName ?? "",
          state: binding?.dataset.bindingState ?? "",
          open: binding?.open ?? false,
          labels: [...(binding?.querySelectorAll("dt") ?? [])]
            .map((item) => item.textContent.trim())
        };
      })()`,
      returnByValue: true,
    });
    assert.equal(bindingDetails.result.value.tag, "DETAILS");
    assert.equal(bindingDetails.result.value.state, "bound");
    assert.equal(bindingDetails.result.value.open, true);
    assert.deepEqual(bindingDetails.result.value.labels, [
      "Runtime PID",
      "端口",
      "Task",
      "Launch",
    ]);
    const bindingScreenshot = await browser.cdp.send(
      "Page.captureScreenshot",
      {
        format: "png",
        fromSurface: true,
      },
      20_000,
    );
    await mkdir(browserEvidenceDir, { recursive: true });
    await writeFile(
      join(browserEvidenceDir, "pchw-runtime-binding-details.png"),
      Buffer.from(bindingScreenshot.data, "base64"),
      { mode: 0o600 },
    );
    await browser.cdp.send("Runtime.evaluate", {
      expression: `document.querySelector("#runtime-binding > summary")?.click()`,
      returnByValue: true,
    });
    const submitted = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const input = document.querySelector("#symptom");
        input.value = ${JSON.stringify(hardwareProblem)};
        input.dispatchEvent(new Event("input", { bubbles: true }));
        const button = document.querySelector("#send-button");
        if (!button || button.disabled) return false;
        button.click();
        return true;
      })()`,
      returnByValue: true,
    });
    assert.equal(submitted.result.value, true);

    await waitFor(
      `(() => {
        const button = document.querySelector(".attachment-analyze");
        return {
          present: Boolean(button),
          disabled: button?.disabled ?? true,
          text: button?.textContent?.trim() ?? ""
        };
      })()`,
      (value) => value.present && !value.disabled,
      "submitted attachment action",
    );
    const analyze = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const button = document.querySelector(".attachment-analyze");
        if (!button || button.disabled) return false;
        button.click();
        return true;
      })()`,
      returnByValue: true,
    });
    assert.equal(analyze.result.value, true);

    const permission = await waitFor(
      `(() => {
        const card = document.querySelector("#permission-card");
        return {
          present: Boolean(card),
          buttons: card
            ? [...card.querySelectorAll("button")]
              .map((button) => button.textContent.trim())
            : []
        };
      })()`,
      (value) =>
        value.present &&
        value.buttons.includes("拒绝") &&
        value.buttons.includes("仅本次允许"),
      "first permission",
    );
    assert.equal(permission.present, true);
    assert.equal(permission.buttons.includes("本 Task 允许"), false);
    assert.equal(permission.buttons.includes("同一附件后续分析"), false);

    const deny = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const button = [...document.querySelectorAll("#permission-card button")]
          .find((item) => item.textContent.trim() === "拒绝");
        if (!button) return false;
        button.click();
        return true;
      })()`,
      returnByValue: true,
    });
    assert.equal(deny.result.value, true);
    await waitFor(
      `(() => ({
        denied:
          Boolean(document.querySelector(".permission-card.is-denied")),
        retry:
          [...document.querySelectorAll(".permission-card button")]
            .some((button) => button.textContent.trim() === "重新请求")
      }))()`,
      (value) => value.denied && value.retry,
      "denied permission retry",
    );

    const retry = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const button = [...document.querySelectorAll(".permission-card button")]
          .find((item) => item.textContent.trim() === "重新请求");
        if (!button) return false;
        button.click();
        return true;
      })()`,
      returnByValue: true,
    });
    assert.equal(retry.result.value, true);
    const retryPermission = await waitFor(
      `(() => {
        const card = document.querySelector("#permission-card");
        return {
          present: Boolean(card),
          buttons: card
            ? [...card.querySelectorAll("button")]
              .map((button) => button.textContent.trim())
            : []
        };
      })()`,
      (value) =>
        value.present &&
        value.buttons.includes("仅本次允许"),
      "retry permission",
    );
    assert.equal(retryPermission.buttons.includes("本 Task 允许"), false);
    assert.equal(retryPermission.buttons.includes("同一附件后续分析"), false);
    const allow = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const button = [...document.querySelectorAll("#permission-card button")]
          .find((item) => item.textContent.trim() === "仅本次允许");
        if (!button) return false;
        button.click();
        return true;
      })()`,
      returnByValue: true,
    });
    assert.equal(allow.result.value, true);
    await waitFor(
      `(() => ({
        title:
          document.querySelector("#status-block .status-title")
            ?.textContent?.trim() ?? "",
        detail:
          document.querySelector("#status-block .status-detail")
            ?.textContent?.trim() ?? "",
        autoRefresh:
          document.querySelector("#source-result-auto-refresh")
            ?.textContent?.trim() ?? ""
      }))()`,
      (value) =>
        value.title === "正在等待来源 Agent" &&
        value.detail.includes("会自动显示") &&
        value.autoRefresh.includes("等待自动刷新"),
      "human local-analysis completion",
    );
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
    }, 20_000);
    const screenshotBuffer = Buffer.from(screenshot.data, "base64");
    const screenshotName = "pchw-human-panel-flow.png";
    await mkdir(browserEvidenceDir, { recursive: true });
    await writeFile(
      join(browserEvidenceDir, screenshotName),
      screenshotBuffer,
      { mode: 0o600 },
    );
    const evidence = {
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_installed_human_panel_flow",
      attachment_prefill_checked: true,
      submit_clicked: true,
      analyze_clicked: true,
      deny_clicked: true,
      retry_clicked: true,
      allow_once_clicked: true,
      waiting_for_source_visible: true,
      evidence_source: "real_headless_browser_dom_clicks",
      screenshot_path: screenshotName,
      screenshot_sha256: sha256(screenshotBuffer),
      observed_at: new Date().toISOString(),
    };
    await writeFile(
      join(browserEvidenceDir, "human-panel-flow-evidence.json"),
      `${JSON.stringify(evidence, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    return {
      evidence,
      browser: keepOpen ? browser : null,
    };
  } finally {
    if (!keepOpen) {
      await browser.close();
    }
  }
}

async function captureRecoveryUiEvidence(baseUrl, panelToken, currentState) {
  const fakeStuckState = structuredClone(currentState);
  fakeStuckState.phase = "ready";
  fakeStuckState.task.phase = "ready";
  fakeStuckState.task.shared_task.phase = "source_agent_pulled";
  fakeStuckState.task.shared_task.last_intent_id = "stuck-ui-intent";
  fakeStuckState.error = null;
  const firstAttachment = fakeStuckState.task.attachments[0];
  const recoveredState = {
    ...structuredClone(currentState),
    phase: "ready",
    panel: null,
    error: null,
    activity: null,
    last_turn: null,
    recovered: true,
    recovery_kind: "stuck_cycle",
    deduplicated_attachment_count: 0,
  };
  recoveredState.task = {
    ...recoveredState.task,
    phase: "ready",
    last_turn: null,
    shared_task: {
      ...recoveredState.task.shared_task,
      phase: "source_owned",
      cycle_generation:
        Number(recoveredState.task.shared_task.cycle_generation ?? 0) + 1,
      cycle_recovery: {
        previous_phase: "source_agent_pulled",
        previous_intent_id: "stuck-ui-intent",
        archive_ref: "fixture-cycle-archive.json",
      },
    },
    attachments: fakeStuckState.task.attachments,
  };
  const initScript = `(() => {
    const stuckState = ${JSON.stringify(fakeStuckState)};
    const recoveredState = ${JSON.stringify(recoveredState)};
    const nativeFetch = window.fetch.bind(window);
    window.__pchwRecoveryCalls = 0;
    window.confirm = () => true;
    window.fetch = async (input, init = {}) => {
      const url = new URL(
        typeof input === "string" ? input : input.url,
        location.href
      );
      if (url.pathname === "/api/state") {
        return new Response(JSON.stringify(stuckState), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      if (url.pathname === "/api/task/recover") {
        window.__pchwRecoveryCalls += 1;
        return new Response(JSON.stringify(recoveredState), {
          status: 200,
          headers: { "Content-Type": "application/json" },
        });
      }
      return nativeFetch(input, init);
    };
  })();`;
  const browser = await launchBrowserPage(baseUrl, panelToken, {
    initScript,
  });
  try {
    let before = null;
    for (let attempt = 0; attempt < 160; attempt += 1) {
      const evaluated = await browser.cdp.send("Runtime.evaluate", {
        expression: `(() => ({
          phase:
            document.querySelector("#source-agent-result-waiting")
              ?.dataset.phase ?? "",
          recoveryAvailable:
            document.querySelector("#source-agent-result-waiting")
              ?.dataset.recoveryAvailable ?? "",
          recoveryAction:
            [...document.querySelectorAll("#source-agent-result-waiting button")]
              .some((button) =>
                button.textContent.includes("恢复当前 Task")
              ),
          fileInputDisabled:
            document.querySelector("#composer-file-input")?.disabled ?? true,
          sendDisabled:
            document.querySelector("#send-button")?.disabled ?? true,
          analyzeDisabled:
            document.querySelector(".attachment-analyze")?.disabled ?? true,
          attachmentCount:
            document.querySelectorAll(".task-data-sources .attachment-card")
              .length
        }))()`,
        returnByValue: true,
      });
      before = evaluated.result.value;
      if (
        before.phase === "source_agent_pulled" &&
        before.recoveryAvailable === "true" &&
        before.recoveryAction &&
        before.fileInputDisabled &&
        before.sendDisabled &&
        before.analyzeDisabled &&
        before.attachmentCount >= 1
      ) {
        break;
      }
      await sleep(100);
    }
    assert.equal(before?.phase, "source_agent_pulled");
    assert.equal(before?.recoveryAvailable, "true");
    assert.equal(before?.recoveryAction, true);
    assert.equal(before?.fileInputDisabled, true);
    assert.equal(before?.sendDisabled, true);
    assert.equal(before?.analyzeDisabled, true);
    assert.ok(before?.attachmentCount >= 1);
    const beforeScreenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
    }, 20_000);
    const beforeScreenshotBuffer = Buffer.from(
      beforeScreenshot.data,
      "base64",
    );
    const beforeScreenshotName = "pchw-recovery-ui-before.png";
    await mkdir(browserEvidenceDir, { recursive: true });
    await writeFile(
      join(browserEvidenceDir, beforeScreenshotName),
      beforeScreenshotBuffer,
      { mode: 0o600 },
    );
    const clicked = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const button = [...document.querySelectorAll("#source-agent-result-waiting button")]
          .find((item) => item.textContent.includes("恢复当前 Task"));
        if (!button) return false;
        button.click();
        return true;
      })()`,
      returnByValue: true,
    });
    assert.equal(clicked.result.value, true);
    let after = null;
    for (let attempt = 0; attempt < 160; attempt += 1) {
      const evaluated = await browser.cdp.send("Runtime.evaluate", {
        expression: `(() => ({
          calls: window.__pchwRecoveryCalls,
          notice: document.querySelector(".notice")?.textContent?.trim() ?? "",
          phaseLockPresent:
            Boolean(document.querySelector("#source-agent-result-waiting")),
          fileInputDisabled:
            document.querySelector("#composer-file-input")?.disabled ?? true,
          attachmentCount:
            document.querySelectorAll(".task-data-sources .attachment-card")
              .length
        }))()`,
        returnByValue: true,
      });
      after = evaluated.result.value;
      if (
        after.calls === 1 &&
        after.notice.includes("当前 Task 已恢复") &&
        after.phaseLockPresent === false &&
        after.fileInputDisabled === false &&
        after.attachmentCount >= 1
      ) {
        break;
      }
      await sleep(100);
    }
    assert.equal(after?.calls, 1);
    assert.match(after?.notice ?? "", /当前 Task 已恢复/u);
    assert.equal(after?.phaseLockPresent, false);
    assert.equal(after?.fileInputDisabled, false);
    assert.ok(after?.attachmentCount >= 1);
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      fromSurface: true,
    }, 20_000);
    const screenshotBuffer = Buffer.from(screenshot.data, "base64");
    const screenshotName = "pchw-recovery-ui.png";
    await mkdir(browserEvidenceDir, { recursive: true });
    await writeFile(
      join(browserEvidenceDir, screenshotName),
      screenshotBuffer,
      { mode: 0o600 },
    );
    const evidence = {
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_source_hosted_stuck_phase_recovery_ui",
      before,
      after,
      screenshot_path: screenshotName,
      screenshot_sha256: sha256(screenshotBuffer),
      before_screenshot_path: beforeScreenshotName,
      before_screenshot_sha256: sha256(beforeScreenshotBuffer),
      evidence_source: "real_headless_browser_dom_with_network_fixture",
      production_state_mutated: false,
      api_recovery_behavior_covered_by: "source-hosted-entry-e2e.test.mjs",
      observed_at: new Date().toISOString(),
    };
    await writeFile(
      join(browserEvidenceDir, "recovery-ui-evidence.json"),
      `${JSON.stringify(evidence, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    return evidence;
  } finally {
    await browser.close();
  }
}

const csvText = [
  "Date,Time,GPU Temperature [C],GPU Power [W],GPU Effective Clock [MHz],GPU Fan [RPM],FPS,PerfCap",
  "2026-11-17,20:00:00,73,301,2670,1760,118,Pwr",
  "2026-11-17,20:05:00,77,312,2655,1810,116,Pwr",
  "2026-11-17,20:10:00,81,305,2630,1880,109,Pwr",
  "2026-11-17,20:15:00,84,278,2410,1980,92,Therm",
  "2026-11-17,20:20:00,86,221,2070,2100,74,Therm",
  "2026-11-17,20:25:00,87,188,1840,2180,63,Therm",
  "2026-11-17,20:30:00,86,181,1795,2170,61,Therm",
  "2026-11-17,20:35:00,85,176,1760,2140,59,Therm",
].join("\n");

let server = null;
let browser = null;
let launcherRestartCount = 0;
try {
  await Promise.all([
    mkdir(workspace, { recursive: true }),
    mkdir(nodeBundle, { recursive: true }),
  ]);
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
  assert.ok(licenseSource, "A Node LICENSE file is required for packaging.");
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
      packageDirectory,
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
  launcherPath = join(packageDirectory, "SkillDock.exe");
  assert.equal(existsSync(launcherPath), true);
  const installSkill = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      pchwInstaller,
      "-SourceDirectory",
      pchwSkillSource,
      "-Destination",
      installedSkillRoot,
      "-BackupRoot",
      join(tempRoot, "skill-backups"),
      "-Force",
    ],
  );
  assert.equal(installSkill.code, 0, installSkill.stderr);
  installedSkillIdentity = JSON.parse(
    (
      await readFile(
        join(installedSkillRoot, "INSTALL-INFO.json"),
        "utf8",
      )
    ).replace(/^\uFEFF/u, ""),
  );
  assert.match(installedSkillIdentity.TreeSha256, /^[a-f0-9]{64}$/u);
  assert.ok(installedSkillIdentity.TreeFileCount > 0);
  const treeComparison = await compareSkillTrees(
    pchwSkillSource,
    installedSkillRoot,
  );
  assert.equal(
    treeComparison.ok,
    true,
    JSON.stringify({
      missing: treeComparison.missing,
      changed: treeComparison.changed,
      extra: treeComparison.extra,
    }),
  );
  assert.equal(
    installedSkillIdentity.TreeSha256,
    treeComparison.installed.tree_sha256,
  );
  assert.equal(
    installedSkillIdentity.TreeFileCount,
    treeComparison.installed.tree_file_count,
  );
  assert.equal(
    await sha256CanonicalTextFile(join(installedSkillRoot, "runtime.mjs")),
    await sha256CanonicalTextFile(
      join(root, "skills", "pc-hardware-workbench", "runtime.mjs"),
    ),
  );
  launcherEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    SKILLDOCK_SKILL_ROOTS: installedSkillsRoot,
    SKILLDOCK_LAUNCHER: "",
    NODE_NO_WARNINGS: "1",
  };
  await mkdir(localRoot, { recursive: true });
  await writeFile(
    join(localRoot, "runtime-location.json"),
    `${JSON.stringify({
      runtime_path: launcherPath,
      version: "0.1.0-dev",
      installed_at: new Date().toISOString(),
      backup_root: join(tempRoot, "local-app-data", "SkillDockBackups", "runtime"),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  const sourceSessionRef = randomUUID();
  await writeFile(
    csvPath,
    csvText,
    { encoding: "utf8", mode: 0o600 },
  );
  await writeFile(
    chatContextPath,
    `${JSON.stringify({
      schema_version: "1.0",
      channel_id: `chat:${sourceSessionRef}:current`,
      source_session_ref: sourceSessionRef,
      objective: "分析受控 HWiNFO 游戏掉帧数据",
      summary: "PCHW formal source-hosted mock user entry.",
      attachments: [{
        path: csvPath,
        name: "gpu-stutter.csv",
        mime_type: "text/csv",
      }],
      messages: [],
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  const fallbackRun = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "launch-panel.ps1"),
      "-Workspace",
      workspace,
      "-LauncherPath",
      join(tempRoot, "missing-runtime", "SkillDock.exe"),
      "-ChatContextFile",
      chatContextPath,
      "-NoBrowser",
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-SourceSessionRef",
      sourceSessionRef,
    ],
    {
      env: {
        ...launcherEnv,
        CODEX_THREAD_ID: sourceSessionRef,
      },
    },
  );
  const fallback = JSON.parse(fallbackRun.stdout.trim());
  assert.equal(fallbackRun.code, 1);
  assert.equal(fallback.ok, false);
  assert.equal(fallback.error_code, "runtime_missing");
  assert.match(fallback.fallback_reason, /Continue in chat/u);

  const formalEntry = await launchFormalPanel(sourceSessionRef);
  server = {
    baseUrl: formalEntry.baseUrl,
    async close() {
      await stopFormalPanel(formalEntry.baseUrl);
    },
  };
  const masterToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  const panelToken = (
    await readFile(join(runtimeDir, "panel-capability-token"), "utf8")
  ).trim();
  const sourceToken = (
    await readFile(join(runtimeDir, "source-capability-token"), "utf8")
  ).trim();
  assert.equal(new Set([masterToken, panelToken, sourceToken]).size, 3);

  const taskId = formalEntry.taskRef;
  const channelId = formalEntry.channelId;
  const otherWorkspace = join(tempRoot, "other-workspace");
  await mkdir(otherWorkspace, { recursive: true });
  const conflictRun = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "launch-panel.ps1"),
      "-Workspace",
      otherWorkspace,
      "-LauncherPath",
      launcherPath,
      "-ChatContextFile",
      chatContextPath,
      "-NoBrowser",
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-SourceSessionRef",
      sourceSessionRef,
    ],
    {
      env: {
        ...launcherEnv,
        CODEX_THREAD_ID: sourceSessionRef,
      },
    },
  );
  const conflictFallback = JSON.parse(conflictRun.stdout.trim());
  assert.equal(conflictRun.code, 1);
  assert.equal(conflictFallback.ok, false);
  assert.equal(conflictFallback.error_code, "workspace_conflict");
  assert.match(conflictFallback.fallback_reason, /Continue in chat/u);
  const mismatchedThreadRun = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "launch-panel.ps1"),
      "-Workspace",
      workspace,
      "-LauncherPath",
      launcherPath,
      "-ChatContextFile",
      chatContextPath,
      "-NoBrowser",
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-SourceSessionRef",
      randomUUID(),
    ],
    {
      env: {
        ...launcherEnv,
        CODEX_THREAD_ID: sourceSessionRef,
      },
    },
  );
  const mismatchedThread = JSON.parse(mismatchedThreadRun.stdout.trim());
  assert.equal(mismatchedThreadRun.code, 1);
  assert.equal(mismatchedThread.ok, false);
  assert.equal(
    mismatchedThread.error_code,
    "thread_binding_mismatch",
  );
  assert.equal(mismatchedThread.url, "");
  const missingThreadEnv = {
    ...launcherEnv,
  };
  delete missingThreadEnv.CODEX_THREAD_ID;
  const missingThreadRun = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "launch-panel.ps1"),
      "-Workspace",
      workspace,
      "-LauncherPath",
      launcherPath,
      "-ChatContextFile",
      chatContextPath,
      "-NoBrowser",
      "-SurfaceProfile",
      "pchw-source-hosted",
    ],
    { env: missingThreadEnv },
  );
  const missingThread = JSON.parse(missingThreadRun.stdout.trim());
  assert.equal(missingThreadRun.code, 1);
  assert.equal(missingThread.ok, false);
  assert.equal(
    missingThread.error_code,
    "thread_binding_missing",
  );
  assert.equal(missingThread.url, "");

  let response = await fetch(formalEntry.entryUrl, { redirect: "manual" });
  assert.equal(
    response.status,
    303,
    `entry path ${new URL(formalEntry.entryUrl).pathname}`,
  );
  assert.match(response.headers.get("set-cookie") ?? "", /panel_token=/u);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  let state = await response.json();
  assert.equal(state.task.shared_task.phase, "source_owned");
  assert.equal(state.task.task_id, taskId);
  assert.equal(state.task.sync.channel_id, channelId);
  assert.equal(state.agent.thread_id, null);

  assert.equal(state.draft.attachments.length, 1);
  assert.equal(
    state.draft.attachments[0].original_name,
    "gpu-stutter.csv",
  );
  assert.equal("local_path" in state.draft.attachments[0], false);
  const csvId = state.draft.attachments[0].id;
  const csvSha256 = state.draft.attachments[0].sha256;
  assert.equal(csvSha256, sha256(Buffer.from(csvText, "utf8")));
  assert.equal(
    state.draft.attachments[0].source_attachment_id,
    `chat-file:${csvSha256}`,
  );

  const reopenedEntry = await launchFormalPanel(sourceSessionRef);
  assert.equal(reopenedEntry.taskRef, taskId);
  assert.equal(reopenedEntry.channelId, channelId);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  state = await response.json();
  assert.equal(state.draft.attachments.length, 1);
  assert.equal(state.draft.attachments[0].id, csvId);
  assert.equal(state.task.attachments.length, 0);
  const attachmentEvents = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  )
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter(
      (entry) =>
        entry.type === "attachment_added" &&
        entry.attachment?.sha256 === csvSha256,
    );
  assert.equal(attachmentEvents.length, 1);

  const humanFlow = await performHumanPanelFlow(
    server.baseUrl,
    panelToken,
    "4K 高画质游戏约 20 分钟后掉帧，GPU 功耗和有效频率下降，温度接近上限。",
    { keepOpen: true },
  );
  const humanFlowEvidence = humanFlow.evidence;
  browser = humanFlow.browser;
  const panelInstance = await browser.cdp.send("Runtime.evaluate", {
    expression: "window.__panelInstanceId",
    returnByValue: true,
  });
  const panelInstanceId = panelInstance.result.value;
  assert.match(panelInstanceId, /^[a-f0-9-]{20,}$/u);
  assert.equal(humanFlowEvidence.waiting_for_source_visible, true);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "waiting_for_source_pull");
  assert.equal(state.task.attachments[0].id, csvId);
  assert.equal(state.draft.attachments.length, 0);
  assert.equal(state.activity.status, "waiting_for_source");
  const submission = state.task.timeline
    .filter(
      (entry) =>
        entry.source === "source_hosted_intent" &&
        (entry.attachments ?? []).some(
          (attachment) => attachment.id === csvId,
        ),
    )
    .at(-1);
  assert.ok(submission?.seq > 0);
  assert.ok(submission.external_id);
  const automaticWaitResult = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "wait-panel.ps1"),
      "-ChannelId",
      channelId,
      "-SourceSessionRef",
      sourceSessionRef,
      "-ExpectedTaskId",
      taskId,
      "-ExpectedAttachmentId",
      csvId,
      "-ExpectedAttachmentSha256",
      csvSha256,
      "-ExpectedSubmissionSequence",
      String(submission.seq),
      "-ExpectedIntentEventId",
      String(submission.external_id),
      "-RuntimeDirectory",
      runtimeDir,
      "-TimeoutSeconds",
      "120",
      "-PollMilliseconds",
      "250",
    ],
    { env: launcherEnv, timeoutMs: 130_000 },
  );
  assert.equal(
    automaticWaitResult.code,
    0,
    automaticWaitResult.stderr,
  );
  const waited = JSON.parse(automaticWaitResult.stdout.trim());
  assert.equal(waited.ok, true);
  assert.equal(waited.ready, true);
  assert.equal(waited.freshness.code, "fresh_source_result");
  assert.equal(waited.freshness.submission_sequence, submission.seq);
  assert.equal(waited.freshness.returned_attachment_id, csvId);
  assert.equal(waited.freshness.returned_sha256, csvSha256);
  assert.ok(waited.source_tool_result?.packet?.tool_result?.analysis);
  let phaseUi = null;
  for (let attempt = 0; attempt < 220; attempt += 1) {
    const evaluated = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const waiting = document.querySelector("#source-agent-result-waiting");
        return {
          phase: waiting?.dataset.phase ?? "",
          recoveryAvailable:
            waiting?.dataset.recoveryAvailable ?? "",
          waitingText: waiting?.textContent?.trim() ?? "",
          statusTitle:
            document.querySelector("#status-block .status-title")
              ?.textContent?.trim() ?? "",
          statusDetail:
            document.querySelector("#status-block .status-detail")
              ?.textContent?.trim() ?? "",
          recoveryButton:
            [...(waiting?.querySelectorAll("button") ?? [])]
              .some((button) => button.textContent.includes("恢复当前 Task")),
          fileInputDisabled:
            document.querySelector("#composer-file-input")?.disabled ?? true,
          sendDisabled:
            document.querySelector("#send-button")?.disabled ?? true,
          analyzeDisabled:
            document.querySelector(".attachment-analyze")?.disabled ?? true
        };
      })()`,
      returnByValue: true,
    });
    phaseUi = evaluated.result.value;
    if (
      phaseUi.phase === "source_agent_pulled" &&
      phaseUi.waitingText.includes("正在等待来源 Agent 返回结论") &&
      phaseUi.statusTitle === "正在等待来源 Agent" &&
      phaseUi.statusDetail.includes("自动显示") &&
      phaseUi.recoveryAvailable === "true" &&
      phaseUi.recoveryButton === true &&
      phaseUi.fileInputDisabled &&
      phaseUi.sendDisabled &&
      phaseUi.analyzeDisabled
    ) {
      break;
    }
    await sleep(100);
  }
  assert.equal(phaseUi.phase, "source_agent_pulled");
  assert.match(phaseUi.waitingText, /正在等待来源 Agent 返回结论/u);
  assert.equal(phaseUi.statusTitle, "正在等待来源 Agent");
  assert.match(phaseUi.statusDetail, /自动显示/u);
  assert.equal(phaseUi.recoveryAvailable, "true");
  assert.equal(phaseUi.recoveryButton, true);
  assert.equal(phaseUi.fileInputDisabled, true);
  assert.equal(phaseUi.sendDisabled, true);
  assert.equal(phaseUi.analyzeDisabled, true);
  const waitingEvidence = await captureWaitingForSourceEvidence(
    server.baseUrl,
    panelToken,
    { existingBrowser: browser },
  );
  assert.equal(waitingEvidence.dom.title, "正在等待来源 Agent");
  const exported = waited;
  assert.equal(exported.phase, "source_agent_pulled");
  assert.equal(
    JSON.stringify(exported.source_tool_result).includes("local_path"),
    false,
  );
  const runtimeEvents = (
    await readFile(join(runtimeDir, "events.jsonl"), "utf8")
  )
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const permissionGrantEvents = runtimeEvents.filter(
    (entry) =>
      entry.type === "permission.granted" &&
      entry.attachment_id === csvId,
  );
  assert.equal(permissionGrantEvents.length, 1);
  assert.equal(permissionGrantEvents[0].scope, "one-time");
  const permissionConsumedEvents = runtimeEvents.filter(
    (entry) =>
      entry.type === "permission.consumed" &&
      entry.grant_id === permissionGrantEvents[0].grant_id,
  );
  assert.equal(permissionConsumedEvents.length, 1);
  assert.equal(
    runtimeEvents.some(
      (entry) => entry.type === "action.local_completed",
    ),
    true,
  );
  assert.equal(
    runtimeEvents.some(
      (entry) =>
        entry.type === "agent.turn_error" &&
        entry.error_code === "panel_turn_forbidden_in_source_hosted",
    ),
    false,
  );

  const synced = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "sync-panel.ps1"),
      "-ChannelId",
      channelId,
      "-AfterSequence",
      "0",
      "-RuntimeDirectory",
      runtimeDir,
      "-SurfaceProfile",
      "pchw-source-hosted",
      "-SourceSessionRef",
      sourceSessionRef,
      "-ExpectedTaskId",
      taskId,
      "-ExpectedAttachmentId",
      csvId,
      "-ExpectedAttachmentSha256",
      csvSha256,
      "-ExpectedSubmissionSequence",
      String(submission.seq),
      "-ExpectedIntentEventId",
      String(submission.external_id),
    ],
    { env: launcherEnv },
  );
  assert.equal(synced.code, 0, synced.stderr);
  const manualSyncFallback = JSON.parse(synced.stdout.trim());
  assert.equal(
    manualSyncFallback.shared_task.phase,
    "source_agent_pulled",
  );
  assert.ok(
    manualSyncFallback.source_tool_result?.packet?.tool_result?.analysis,
  );
  assert.equal(manualSyncFallback.freshness.code, "fresh_source_result");
  assert.equal(
    manualSyncFallback.source_tool_result.packet.attachment_id,
    csvId,
  );

  const sourcePacket = {
    ...exported.source_tool_result.packet,
    user_intent: exported.messages
      .filter((message) => message.source === "source_hosted_intent")
      .map((message) => message.text)
      .join("\n"),
  };
  const mock = new MockAgentDriver();
  await mock.initialize();
  const thread = await mock.startThread();
  const turn = await mock.sendTurn({
    threadReference: thread.threadReference,
    packet: sourcePacket,
    structuredOutputSchema: null,
  });
  await mock.close();
  const panel = validatePanelState(turn.structuredOutput);

  const panelFile = join(tempRoot, "pchw-panel-result.json");
  await writeFile(
    panelFile,
    `${JSON.stringify(panel, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  let beforeImport;
  for (let attempt = 0; attempt < 100; attempt += 1) {
    beforeImport = await browser.cdp.send("Runtime.evaluate", {
      expression: `(() => ({
        readyState: document.readyState,
        answerPresent: Boolean(document.querySelector("#answer-card")),
        bodyText: document.body.innerText
      }))()`,
      returnByValue: true,
    });
    const value = beforeImport?.result?.value;
    if (
      value?.readyState === "complete" &&
      /本地分析已完成|等待/u.test(value.bodyText)
    ) {
      break;
    }
    await sleep(100);
  }
  assert.equal(beforeImport.result.value.readyState, "complete");
  assert.equal(beforeImport.result.value.answerPresent, false);
  assert.match(beforeImport.result.value.bodyText, /本地分析已完成|等待/u);
  const submitted = await runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(integrationDir, "submit-panel-result.ps1"),
      "-ChannelId",
      channelId,
      "-SourceSessionRef",
      sourceSessionRef,
      "-PanelFile",
      panelFile,
      "-MessageText",
      panel.judgement,
      "-Objective",
      state.task.objective,
      "-Summary",
      panel.turn_summary,
      "-RuntimeDirectory",
      runtimeDir,
    ],
    { env: launcherEnv },
  );
  assert.equal(submitted.code, 0, submitted.stderr);
  const imported = JSON.parse(submitted.stdout.trim());
  assert.equal(imported.ok, true);
  assert.equal(imported.phase, "source_result_synced");
  assert.equal(imported.imported_count, 1);

  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  state = await response.json();
  assert.equal(state.task.shared_task.phase, "source_result_synced");
  assert.ok(state.panel.artifact_refs.length >= 2);
  assert.ok(
    state.panel.blocks.some((block) => block.type === "chart"),
  );
  assert.ok(state.panel.judgement.length > 20);
  assert.equal(state.task.attachments[0].sha256, csvSha256);
  assert.equal(state.last_turn, null);
  const artifact = state.panel.artifact_refs[0];
  const persistedPanelHash = sha256(JSON.stringify(state.panel));
  response = await fetch(
    `${server.baseUrl}/api/artifacts/${artifact.id}/content`,
    { headers: panelHeaders(panelToken) },
  );
  assert.equal(response.status, 200);
  const svg = Buffer.from(await response.arrayBuffer());
  assert.match(svg.toString("utf8", 0, 512), /<svg\b/u);
  assert.equal(sha256(svg), artifact.sha256);

  const rendered = await waitForRenderedAnswer(browser.cdp);
  const domEvaluation = await browser.cdp.send("Runtime.evaluate", {
    expression: `(async () => {
      const image = document.querySelector(".analysis-chart img");
      if (image) {
        try {
          await image.decode();
        } catch {}
      }
      return {
        title: document.title,
        userAgent: navigator.userAgent,
        panelInstanceId: window.__panelInstanceId,
        navigationType:
          performance.getEntriesByType("navigation")[0]?.type ?? "",
        judgementText:
          document.querySelector(".answer-judgement")?.textContent?.trim() ?? "",
        chartCaption:
          document.querySelector(".chart-caption")?.textContent?.trim() ?? "",
        chartImageWidth: image?.naturalWidth ?? 0,
        chartImageHeight: image?.naturalHeight ?? 0,
        answerCardHtml:
          document.querySelector("#answer-card")?.outerHTML ?? "",
        bodyTextHash: (() => {
          const text = document.body.innerText;
          let hash = 2166136261;
          for (let index = 0; index < text.length; index += 1) {
            hash ^= text.charCodeAt(index);
            hash = Math.imul(hash, 16777619);
          }
          return (hash >>> 0).toString(16).padStart(8, "0");
        })()
      };
    })()`,
    awaitPromise: true,
    returnByValue: true,
  });
  const dom = domEvaluation.result.value;
  assert.equal(dom.title, "SkillDock");
  assert.equal(dom.panelInstanceId, panelInstanceId);
  assert.notEqual(dom.navigationType, "reload");
  assert.ok(dom.judgementText.length >= 20);
  assert.ok(dom.chartImageWidth > 0);
  assert.ok(dom.chartImageHeight > 0);
  assert.ok(dom.answerCardHtml.includes("analysis-chart"));
  assert.ok(dom.answerCardHtml.includes("answer-judgement"));
  assert.ok(rendered.imagesLoaded);

  const answerCardRect = await browser.cdp.send("Runtime.evaluate", {
    expression: `(() => {
      const card = document.querySelector("#answer-card");
      card.scrollIntoView({ block: "start" });
      const rect = card.getBoundingClientRect();
      return {
        x: rect.left + window.scrollX,
        y: rect.top + window.scrollY,
        width: rect.width,
        height: rect.height
      };
    })()`,
    returnByValue: true,
  });
  const clip = answerCardRect.result.value;
  assert.ok(clip.width >= 600);
  assert.ok(clip.height >= 600);
  const screenshot = await browser.cdp.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: true,
    clip: {
      x: clip.x,
      y: clip.y,
      width: clip.width,
      height: clip.height,
      scale: 1,
    },
  }, 20_000);
  const screenshotBuffer = Buffer.from(screenshot.data, "base64");
  const answerDomText = `${dom.answerCardHtml}\n`;
  const screenshotPath = join(
    browserEvidenceDir,
    "pchw-panel-answer-card.png",
  );
  const domPath = join(
    browserEvidenceDir,
    "pchw-panel-answer-card.html",
  );
  await mkdir(browserEvidenceDir, { recursive: true });
  await writeFile(screenshotPath, screenshotBuffer, { mode: 0o600 });
  await writeFile(domPath, answerDomText, {
    encoding: "utf8",
    mode: 0o600,
  });
  const browserEvidence = {
    schema_version: "1.0",
    status: "passed",
    gate: "pchw_real_browser_dom",
    browser: {
      engine: "Chromium",
      executable_name: browser.executable
        .split(/[\\/]/u)
        .at(-1),
      user_agent: dom.userAgent,
      viewport: { width: 1440, height: 900 },
    },
    dom_assertions: {
      document_title: dom.title,
      answer_card_present: rendered.cardPresent,
      judgement_length: dom.judgementText.length,
      judgement_sha256: sha256(dom.judgementText),
      chart_present: rendered.chartPresent,
      chart_image_count: rendered.imageCount,
      chart_image_loaded: rendered.imagesLoaded,
      chart_image_width: dom.chartImageWidth,
      chart_image_height: dom.chartImageHeight,
      chart_caption: dom.chartCaption,
      body_text_fnv1a32: dom.bodyTextHash,
    },
    artifacts: {
      screenshot_path: "pchw-panel-answer-card.png",
      screenshot_bytes: screenshotBuffer.length,
      screenshot_sha256: sha256(screenshotBuffer),
      screenshot_width: Math.round(clip.width),
      screenshot_height: Math.round(clip.height),
      answer_dom_path: "pchw-panel-answer-card.html",
      answer_dom_sha256: sha256(answerDomText),
    },
    evidence_source: "real_headless_browser_dom",
    api_state_used_for_browser_acceptance: false,
    observed_at: new Date().toISOString(),
  };
  await writeFile(
    join(browserEvidenceDir, "browser-evidence.json"),
    `${JSON.stringify(browserEvidence, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  await browser.close();
  browser = null;

  const taskHash = sha256(taskId);
  await server.close();
  server = null;

  const restartedEntry = await launchFormalPanel(sourceSessionRef);
  assert.equal(restartedEntry.taskRef, taskId);
  assert.equal(restartedEntry.channelId, channelId);
  server = {
    baseUrl: restartedEntry.baseUrl,
    async close() {
      await stopFormalPanel(restartedEntry.baseUrl);
    },
  };
  launcherRestartCount += 1;
  response = await fetch(restartedEntry.entryUrl, { redirect: "manual" });
  assert.equal(response.status, 303);
  response = await fetch(`${server.baseUrl}/api/state`, {
    headers: panelHeaders(panelToken),
  });
  state = await response.json();
  assert.equal(sha256(state.task.task_id), taskHash);
  assert.equal(state.task.shared_task.phase, "source_result_synced");
  assert.equal(state.task.attachments[0].sha256, csvSha256);
  assert.equal(state.task.attachments.length, 1);
  assert.equal(state.panel.artifact_refs[0].sha256, artifact.sha256);
  assert.equal(sha256(JSON.stringify(state.panel)), persistedPanelHash);
  assert.equal(state.agent.thread_id, null);
  response = await fetch(
    `${server.baseUrl}/api/artifacts/${artifact.id}/content`,
    { headers: panelHeaders(panelToken) },
  );
  assert.equal(response.status, 200);
  const postRestartBrowserEvidence = await captureBrowserEvidence(
    server.baseUrl,
    panelToken,
    {
      suffix: "-post-restart",
      postRestart: true,
    },
  );
  assert.equal(postRestartBrowserEvidence.post_restart, true);
  assert.equal(
    postRestartBrowserEvidence.dom_assertions.chart_image_loaded,
    true,
  );
  const recoveryUiEvidence = await captureRecoveryUiEvidence(
    server.baseUrl,
    panelToken,
    state,
  );
  assert.equal(recoveryUiEvidence.after.calls, 1);
  const postRestartEvidencePath = join(
    browserEvidenceDir,
    "browser-evidence-post-restart.json",
  );
  const postRestartScreenshotPath = join(
    browserEvidenceDir,
    "pchw-panel-answer-card-post-restart.png",
  );
  const postRestartDomPath = join(
    browserEvidenceDir,
    "pchw-panel-answer-card-post-restart.html",
  );
  await mkdir(launcherEvidenceDir, { recursive: true });
  await writeFile(
    join(launcherEvidenceDir, "launcher-evidence.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      status: "passed",
      gate: "pchw_internal_preview_launcher_mock_e2e",
      user_entry: "launch-panel.ps1",
      launcher_entry: "SkillDock.exe --ensure invoked by launch-panel.ps1",
      direct_server_bypass: false,
      default_runtime_pointer_discovery: true,
      internal_preview: true,
      default_off: true,
      non_mock_gate_enabled: true,
      driver: server.driver,
      panel_thread_count: 0,
      task_count: 1,
      source_external_mock_panel_imports: 1,
      source_sync_entry: "sync-panel.ps1",
      automatic_wait_entry: "wait-panel.ps1",
      manual_sync_fallback_verified: true,
      wait_timeout_replay_verified: true,
      post_wait_timeout_sync_success: true,
      source_result_entry: "submit-panel-result.ps1",
      source_hosted_local_action_202: true,
      source_hosted_panel_turn_error_absent: true,
      installed_skill_root_used: true,
      source_skill_root_used: false,
      installed_skill_tree_sha256:
        installedSkillIdentity.TreeSha256,
      installed_skill_tree_file_count:
        installedSkillIdentity.TreeFileCount,
      installed_runtime_sha256:
        installedSkillIdentity.RuntimeSha256,
      recovery_ui_verified: true,
      recovery_ui_no_new_thread: true,
      recovery_ui_evidence_sha256:
        sha256(await readFile(join(
          browserEvidenceDir,
          "recovery-ui-evidence.json",
        ))),
      recovery_ui_before_screenshot_sha256:
        sha256(await readFile(join(
          browserEvidenceDir,
          "pchw-recovery-ui-before.png",
        ))),
      human_panel_flow_verified: true,
      human_panel_flow_evidence_sha256:
        sha256(await readFile(join(
          browserEvidenceDir,
          "human-panel-flow-evidence.json",
        ))),
      human_panel_flow_screenshot_sha256:
        sha256(await readFile(join(
          browserEvidenceDir,
          "pchw-human-panel-flow.png",
        ))),
      conversation_attachment_bridge: true,
      prefilled_draft_attachment_count: 1,
      attachment_idempotent_reopen: true,
      duplicate_attachment_count_after_reopen: 0,
      attachment_local_path_exposed: false,
      analysis_permission_denied_retryable: true,
      runtime_missing_fallback: {
        ok: fallback.ok,
        error_code: fallback.error_code,
        continue_in_chat:
          /Continue in chat/u.test(fallback.fallback_reason),
      },
      workspace_conflict_fallback: {
        ok: conflictFallback.ok,
        error_code: conflictFallback.error_code,
        continue_in_chat:
          /Continue in chat/u.test(conflictFallback.fallback_reason),
      },
      thread_binding_mismatch_fallback: {
        ok: mismatchedThread.ok,
        error_code: mismatchedThread.error_code,
        panel_url_returned: Boolean(mismatchedThread.url),
      },
      thread_binding_missing_fallback: {
        ok: missingThread.ok,
        error_code: missingThread.error_code,
        panel_url_returned: Boolean(missingThread.url),
      },
      launcher_restart_count: launcherRestartCount,
      post_restart_task_restored: true,
      post_restart_phase: state.task.shared_task.phase,
      post_restart_browser_dom_restored: true,
      waiting_for_source_browser_dom: true,
      waiting_for_source_evidence_sha256:
        sha256(await readFile(join(
          browserEvidenceDir,
          "waiting-source-evidence.json",
        ))),
      waiting_for_source_screenshot_sha256:
        sha256(await readFile(join(
          browserEvidenceDir,
          "pchw-panel-waiting-source.png",
        ))),
      browser_evidence_sha256:
        sha256(await readFile(postRestartEvidencePath)),
      browser_screenshot_sha256:
        sha256(await readFile(postRestartScreenshotPath)),
      browser_dom_sha256:
        sha256(await readFile(postRestartDomPath)),
      observed_at: new Date().toISOString(),
    }, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  console.log("PCHW source-hosted mock external-agent E2E: PASS");
} finally {
  await browser?.close().catch(() => {});
  await server?.close().catch(() => {});
  if (
    launcherPath &&
    launcherEnv &&
    existsSync(join(runtimeDir, "server-info.json"))
  ) {
    await stopFormalPanel(
      activeUrl ? new URL(activeUrl).origin : "",
    ).catch(() => {});
  }
  await rm(tempRoot, { recursive: true, force: true });
  await rm(packageDirectory, { recursive: true, force: true });
  await rm(archivePath, { force: true });
}
