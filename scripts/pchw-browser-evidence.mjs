import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
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
    if (this.socket.readyState === WebSocket.OPEN) return Promise.resolve();
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

async function launchBrowserPage(baseUrl, panelToken, profileRoot) {
  const executable = await findBrowserExecutable();
  const profile = await mkdtemp(join(profileRoot, "browser-profile-"));
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
      // Browser is still creating its endpoint.
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
  if (!targetResponse.ok) {
    child.kill();
    throw new Error("Browser target creation failed.");
  }
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
  const cookie = await cdp.send("Network.setCookie", {
    name: "panel_token",
    value: panelToken,
    url: `${baseUrl}/`,
    path: "/",
    httpOnly: true,
    sameSite: "Strict",
  });
  if (!cookie.success) throw new Error("Panel cookie could not be set.");
  await cdp.send("Page.navigate", { url: `${baseUrl}/` });
  return {
    executable,
    child,
    profile,
    cdp,
    async close() {
      try {
        await cdp.send("Browser.close", {}, 5_000);
      } catch {
        // Browser.close is not available on every target.
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

export async function launchPchwBrowserPage({
  baseUrl,
  panelToken,
  profileRoot = tmpdir(),
}) {
  const normalizedBaseUrl = String(baseUrl).replace(/\/+$/u, "");
  return launchBrowserPage(normalizedBaseUrl, panelToken, profileRoot);
}

async function waitForRenderedAnswer(cdp) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const evaluated = await cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const card = document.querySelector("#answer-card");
        const judgement = document.querySelector(".answer-judgement");
        const chart = document.querySelector(".analysis-chart");
        const images = [...document.querySelectorAll(".analysis-chart img")];
        const binding = document.querySelector("#runtime-binding");
        return {
          readyState: document.readyState,
          cardPresent: Boolean(card),
          judgementText: judgement?.textContent?.trim() ?? "",
          chartPresent: Boolean(chart),
          imageCount: images.length,
          imagesLoaded: images.length > 0 && images.every(
            (image) => image.complete && image.naturalWidth > 0
          ),
          bindingState: binding?.dataset.bindingState ?? "",
          bindingPid: Number(binding?.dataset.runtimePid ?? 0),
          bindingPort: Number(binding?.dataset.runtimePort ?? 0),
          bindingLaunchId: binding?.dataset.runtimeLaunchId ?? "",
          locationPort: Number(location.port),
          hasRequiredHeadings:
            document.body.innerText.includes("本轮判断与建议") &&
            document.body.innerText.includes("遥测概览")
        };
      })()`,
      returnByValue: true,
    });
    const value = evaluated.result.value;
    if (
      value.readyState === "complete" &&
      value.cardPresent &&
      value.judgementText.length >= 20 &&
      value.chartPresent &&
      value.imageCount >= 1 &&
      value.imagesLoaded &&
      value.bindingState === "bound" &&
      value.bindingPid > 0 &&
      value.bindingPort === value.locationPort &&
      value.bindingLaunchId.length >= 16 &&
      value.hasRequiredHeadings
    ) {
      return value;
    }
    await sleep(100);
  }
  throw new Error("PCHW answer DOM did not finish rendering.");
}

export async function capturePchwBrowserEvidence({
  baseUrl,
  panelToken,
  evidenceDir,
  profileRoot = tmpdir(),
  suffix = "",
  postRestart = false,
}) {
  const browser = await launchPchwBrowserPage({
    baseUrl,
    panelToken,
    profileRoot,
  });
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
    if (
      dom.title !== "SkillDock" ||
      dom.judgementText.length < 20 ||
      dom.chartImageWidth <= 0 ||
      dom.chartImageHeight <= 0 ||
      !dom.answerCardHtml.includes("analysis-chart") ||
      !dom.answerCardHtml.includes("answer-judgement") ||
      !rendered.imagesLoaded
    ) {
      throw new Error("Rendered PCHW DOM failed its acceptance checks.");
    }
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
    const screenshotName = `pchw-panel-answer-card${suffix}.png`;
    const domName = `pchw-panel-answer-card${suffix}.html`;
    const evidenceName = `browser-evidence${suffix}.json`;
    await mkdir(evidenceDir, { recursive: true });
    await writeFile(join(evidenceDir, screenshotName), screenshotBuffer, {
      mode: 0o600,
    });
    await writeFile(join(evidenceDir, domName), answerDomText, {
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
        executable_name: browser.executable.split(/[\\/]/u).at(-1),
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
      runtime_binding_state: rendered.bindingState,
      runtime_binding_pid: rendered.bindingPid,
      runtime_binding_port: rendered.bindingPort,
      runtime_binding_launch_id: rendered.bindingLaunchId,
      },
      artifacts: {
        screenshot_path: screenshotName,
        screenshot_bytes: screenshotBuffer.length,
        screenshot_sha256: sha256(screenshotBuffer),
        screenshot_width: Math.round(clip.width),
        screenshot_height: Math.round(clip.height),
        answer_dom_path: domName,
        answer_dom_sha256: sha256(answerDomText),
      },
      evidence_source: "real_headless_browser_dom",
      api_state_used_for_browser_acceptance: false,
      observed_at: new Date().toISOString(),
    };
    await writeFile(
      join(evidenceDir, evidenceName),
      `${JSON.stringify(evidence, null, 2)}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    return evidence;
  } finally {
    await browser.close();
  }
}
