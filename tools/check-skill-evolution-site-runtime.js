const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const repositoryRoot = path.resolve(__dirname, "..");
const outputRoot = path.join(repositoryRoot, "work");
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), "pcwb-site-runtime-"));
const browserCandidates = [
  process.env.EDGE_PATH,
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"
].filter(Boolean);
const browserPath = browserCandidates.find(candidate => fs.existsSync(candidate));
const failures = [];
let debugPort = 0;

function check(condition, message) {
  if (condition) return;
  failures.push(message);
  const encoded = message
    .replaceAll("%", "%25")
    .replaceAll("\r", "%0D")
    .replaceAll("\n", "%0A");
  console.log(`::error title=Runtime regression::${encoded}`);
}

function sleep(milliseconds) {
  return new Promise(resolve => setTimeout(resolve, milliseconds));
}

function findFreePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(error => {
        if (error) reject(error);
        else resolve(port);
      });
    });
  });
}

function startServer() {
  const contentTypes = {
    ".html": "text/html; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png"
  };
  const server = http.createServer((request, response) => {
    const requestPath = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    let filePath = path.resolve(repositoryRoot, `.${requestPath}`);
    if (!filePath.startsWith(`${repositoryRoot}${path.sep}`) && filePath !== repositoryRoot) {
      response.writeHead(400).end("Bad request");
      return;
    }
    fs.stat(filePath, (error, stats) => {
      if (error) {
        response.writeHead(404).end("Not found");
        return;
      }
      if (stats.isDirectory()) filePath = path.join(filePath, "index.html");
      fs.readFile(filePath, (readError, data) => {
        if (readError) {
          response.writeHead(404).end("Not found");
          return;
        }
        response.writeHead(200, {
          "Content-Type": contentTypes[path.extname(filePath)] || "application/octet-stream",
          "Cache-Control": "no-store"
        });
        response.end(data);
      });
    });
  });
  return new Promise(resolve => {
    server.listen(0, "127.0.0.1", () => {
      resolve({ server, port: server.address().port });
    });
  });
}

async function waitForDebugEndpoint() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${debugPort}/json/version`);
      if (response.ok) return;
    } catch {
      // Browser is still starting.
    }
    await sleep(100);
  }
  throw new Error("Browser debugging endpoint did not become ready.");
}

async function createConnection(url) {
  const response = await fetch(
    `http://127.0.0.1:${debugPort}/json/new?${encodeURIComponent(url)}`,
    { method: "PUT" }
  );
  if (!response.ok) throw new Error(`Unable to open browser target: HTTP ${response.status}`);
  const target = await response.json();
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });

  let nextId = 1;
  const pending = new Map();
  const pageErrors = [];
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    if (message.id) {
      const handler = pending.get(message.id);
      if (!handler) return;
      pending.delete(message.id);
      if (message.error) handler.reject(new Error(message.error.message));
      else handler.resolve(message.result);
      return;
    }
    if (message.method === "Runtime.exceptionThrown") {
      pageErrors.push(
        message.params.exceptionDetails.exception?.description ||
        message.params.exceptionDetails.text
      );
    }
    if (message.method === "Runtime.consoleAPICalled" && message.params.type === "error") {
      pageErrors.push(message.params.args.map(argument => (
        argument.value || argument.description || ""
      )).join(" "));
    }
  });

  function send(method, params = {}) {
    const id = nextId++;
    socket.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
  }

  await Promise.all([send("Page.enable"), send("Runtime.enable")]);
  return {
    targetId: target.id,
    pageErrors,
    send,
    close: () => socket.close()
  };
}

async function evaluate(connection, expression) {
  const result = await connection.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
    userGesture: true
  });
  if (result.exceptionDetails) {
    throw new Error(
      result.exceptionDetails.exception?.description ||
      result.exceptionDetails.text ||
      "Page evaluation failed."
    );
  }
  return result.result.value;
}

async function waitFor(connection, expression, timeout = 3500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(connection, expression)) return true;
    } catch {
      // Navigation can replace the execution context while polling.
    }
    await sleep(80);
  }
  return false;
}

async function navigate(connection, url) {
  await connection.send("Page.navigate", { url });
  const loaded = await waitFor(connection, `document.readyState === "complete"`, 5000);
  if (!loaded) throw new Error(`Page did not finish loading: ${url}`);
  await sleep(120);
}

async function setViewport(connection, width, height) {
  await connection.send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: width <= 760
  });
  await connection.send("Emulation.setTouchEmulationEnabled", {
    enabled: width <= 760,
    maxTouchPoints: width <= 760 ? 5 : 1
  });
  await connection.send("Emulation.setEmulatedMedia", {
    media: "screen",
    features: [{ name: "prefers-reduced-motion", value: "no-preference" }]
  });
}

async function clickByPointer(connection, selector) {
  const point = await evaluate(connection, `(async () => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) throw new Error("Missing control: " + ${JSON.stringify(selector)});
    const root = document.getElementById("dse-root");
    if (root) root.style.scrollBehavior = "auto";
    element.scrollIntoView({ block: "center", inline: "center" });
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const rect = element.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) {
      throw new Error("Control has no layout: " + ${JSON.stringify(selector)});
    }
    return { x: rect.left + rect.width / 2, y: rect.top + rect.height / 2 };
  })()`);
  await connection.send("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: point.x,
    y: point.y,
    button: "left",
    clickCount: 1
  });
  await connection.send("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: point.x,
    y: point.y,
    button: "left",
    clickCount: 1
  });
  await sleep(240);
}

async function clickAllowingNavigation(connection, selector) {
  try {
    await evaluate(connection, `(() => {
      const element = document.querySelector(${JSON.stringify(selector)});
      if (!element) throw new Error("Missing control: " + ${JSON.stringify(selector)});
      element.click();
      return true;
    })()`);
  } catch (error) {
    if (!/navigated|context|target|closed/i.test(error.message)) throw error;
  }
}

async function pressKey(connection, key, code, windowsVirtualKeyCode) {
  await connection.send("Input.dispatchKeyEvent", {
    type: "keyDown",
    key,
    code,
    windowsVirtualKeyCode
  });
  await connection.send("Input.dispatchKeyEvent", {
    type: "keyUp",
    key,
    code,
    windowsVirtualKeyCode
  });
  await sleep(220);
}

async function screenshot(connection, name) {
  const result = await connection.send("Page.captureScreenshot", {
    format: "png",
    fromSurface: true,
    captureBeyondViewport: false
  });
  fs.mkdirSync(outputRoot, { recursive: true });
  fs.writeFileSync(path.join(outputRoot, name), Buffer.from(result.data, "base64"));
}

function integrityExpression() {
  return `(() => {
    const root = document.getElementById("dse-root");
    const visible = element => {
      if (!element || element.hidden) return false;
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== "none" && style.visibility !== "hidden";
    };
    const ids = [...document.querySelectorAll("[id]")].map(element => element.id);
    const duplicateIds = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
    const brokenAriaControls = [...document.querySelectorAll("[aria-controls]")]
      .flatMap(element => element.getAttribute("aria-controls").split(/\\s+/).filter(Boolean))
      .filter(id => !document.getElementById(id))
      .filter((id, index, values) => values.indexOf(id) === index);
    const unnamedControls = [...document.querySelectorAll("button, a[href]")]
      .filter(visible)
      .filter(element => !(
        element.getAttribute("aria-label") ||
        element.getAttribute("title") ||
        element.textContent
      ).trim())
      .map(element => element.outerHTML.slice(0, 160));
    const brokenHashLinks = [...document.querySelectorAll('a[href^="#"]')]
      .filter(link => {
        const hash = link.getAttribute("href").slice(1);
        return hash && !document.getElementById(decodeURIComponent(hash));
      })
      .map(link => link.getAttribute("href"));
    return {
      duplicateIds,
      brokenAriaControls,
      unnamedControls,
      brokenHashLinks,
      h1Count: [...document.querySelectorAll("h1")].filter(visible).length,
      horizontalOverflow:
        document.documentElement.scrollWidth > document.documentElement.clientWidth ||
        Boolean(root && root.scrollWidth > root.clientWidth)
    };
  })()`;
}

function fontSizeExpression() {
  return `(() => {
    const ignored = new Set(["SCRIPT", "STYLE", "NOSCRIPT", "SVG", "PATH"]);
    const hasDirectText = element => [...element.childNodes].some(
      node => node.nodeType === Node.TEXT_NODE && node.textContent.trim()
    );
    const sizes = new Set();
    for (const element of document.querySelectorAll("#dse-root *")) {
      if (ignored.has(element.tagName) || !hasDirectText(element)) continue;
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      if (
        style.display === "none" ||
        style.visibility === "hidden" ||
        Number(style.opacity) === 0 ||
        rect.width <= 0 ||
        rect.height <= 0
      ) {
        continue;
      }
      const size = Number.parseFloat(style.fontSize);
      if (Number.isFinite(size)) sizes.add(Number(size.toFixed(1)));
    }
    return [...sizes].sort((left, right) => left - right);
  })()`;
}

function mobileControlSizeExpression() {
  return `(() => {
    const visible = element => {
      const rect = element.getBoundingClientRect();
      const style = getComputedStyle(element);
      return rect.width > 0 && rect.height > 0 &&
        style.display !== "none" && style.visibility !== "hidden";
    };
    return [...document.querySelectorAll(
      "#dse-root button, #dse-root summary, #dse-root a.dse-filter, #dse-root [role='button']"
    )]
      .filter(visible)
      .map(element => {
        const rect = element.getBoundingClientRect();
        return {
          text: (element.getAttribute("aria-label") || element.innerText || "").trim().slice(0, 70),
          width: Math.round(rect.width),
          height: Math.round(rect.height)
        };
      })
      .filter(target => target.width < 44 || target.height < 44);
  })()`;
}

function runIntegrityChecks(state, prefix) {
  check(state.duplicateIds.length === 0, `${prefix}duplicate IDs: ${state.duplicateIds.join(", ")}`);
  check(
    state.brokenAriaControls.length === 0,
    `${prefix}broken aria-controls: ${state.brokenAriaControls.join(", ")}`
  );
  check(state.unnamedControls.length === 0, `${prefix}visible controls without accessible names.`);
  check(
    state.brokenHashLinks.length === 0,
    `${prefix}broken same-page links: ${state.brokenHashLinks.join(", ")}`
  );
  check(state.h1Count === 1, `${prefix}expected one visible h1, found ${state.h1Count}.`);
  check(state.horizontalOverflow === false, `${prefix}page has horizontal overflow.`);
}

async function testHomeViewport(siteUrl, name, width, height) {
  const connection = await createConnection(siteUrl);
  const prefix = `home ${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, siteUrl);
    runIntegrityChecks(await evaluate(connection, integrityExpression()), prefix);

    const initial = await evaluate(connection, `(() => ({
      title: document.title,
      h1: document.querySelector(".dse-hero h1")?.textContent.trim() || "",
      subtitle: document.querySelector(".dse-hero .dse-subtitle")?.textContent.trim() || "",
      safety: document.querySelector(".dse-hero .dse-hero-safety")?.textContent.trim() || "",
      ctaHref: document.querySelector(".dse-hero-action.primary")?.getAttribute("href") || "",
      ctaText: document.querySelector(".dse-hero-action.primary")?.textContent.trim() || "",
      status: document.querySelector(".dse-hero-status")?.innerText.trim() || "",
      heroHeight: Math.round(document.querySelector(".dse-hero")?.getBoundingClientRect().height || 0),
      viewportHeight: Math.round(document.getElementById("dse-root")?.clientHeight || 0),
      nextSectionTop: Math.round(document.querySelector(".dse-howto")?.getBoundingClientRect().top || 0),
      aboutPresent: Boolean(document.querySelector(".dse-about")),
      advancedEntryHref: document.querySelector(".dse-advanced-entry a")?.getAttribute("href") || "",
      primaryPaths: [...document.querySelectorAll(".dse-explore-primary a")].map(link => link.getAttribute("href")),
      candidateText: document.querySelector(".dse-candidate")?.innerText.trim() || "",
      candidateVisible: (document.querySelector(".dse-candidate")?.getBoundingClientRect().height || 0) > 0,
      candidateInsideDetails: Boolean(document.querySelector(".dse-candidate")?.closest("details")),
      candidateDetailsExpanded: document.getElementById("dse-candidate-details-summary")?.getAttribute("aria-expanded") || "",
      candidateDetailsHeight: Math.round(document.getElementById("dse-candidate-details-summary")?.getBoundingClientRect().height || 0),
      candidateState: document.querySelector(".dse-candidate-state")?.textContent.trim() || "",
      candidateStateSize: Number.parseFloat(getComputedStyle(document.querySelector(".dse-candidate-state")).fontSize),
      heroVersion: document.getElementById("dse-hero-version")?.textContent.trim() || "",
      visibleVersionCount: (
        document.getElementById("dse-root")?.innerText.match(/2\.5\.0/g) || []
      ).length,
      technicalClosed: !document.querySelector(".dse-home-technical")?.open,
      technicalSummary: document.querySelector(".dse-home-technical > summary")?.innerText.trim() || "",
      technicalExpanded: document.getElementById("dse-home-technical-summary")?.getAttribute("aria-expanded") || "",
      technicalHeight: Math.round(document.getElementById("dse-home-technical-summary")?.getBoundingClientRect().height || 0)
    }))()`);
    check(initial.title.includes("电脑硬件工作台"), `${prefix}browser title is not user-facing.`);
    check(
      initial.h1.includes("电脑调试") && initial.h1.includes("Skill 来帮你"),
      `${prefix}hero headline does not match the approved copy.`
    );
    check(
      initial.subtitle.includes("把问题和手头的资料交给我") &&
      initial.subtitle.includes("可靠、能马上执行的下一步") &&
      !initial.subtitle.includes("不会自动修改硬件"),
      `${prefix}hero subtitle does not match the approved two-layer copy.`
    );
    check(
      initial.safety.includes("先选择现象") &&
      initial.safety.includes("只读取你允许的信息") &&
      initial.safety.includes("不会自动修改硬件"),
      `${prefix}hero action result and safety boundary are not explicit.`
    );
    check(initial.ctaHref === "#dse-home-flow", `${prefix}primary CTA does not lead to the inline simple flow.`);
    check(initial.ctaText === "开始排查", `${prefix}hero CTA does not match the simple-flow entry.`);
    check(
      initial.heroHeight >= initial.viewportHeight - 1 &&
      initial.nextSectionTop >= initial.viewportHeight - 1,
      `${prefix}hero does not occupy the complete first viewport (${JSON.stringify({
        heroHeight: initial.heroHeight,
        viewportHeight: initial.viewportHeight,
        nextSectionTop: initial.nextSectionTop
      })}).`
    );
    check(!initial.aboutPresent, `${prefix}removed philosophy section still exists.`);
    check(
      initial.heroVersion === "2.5.0" &&
      initial.visibleVersionCount === 1,
      `${prefix}homepage should expose the current version exactly once (${JSON.stringify({
        heroVersion: initial.heroVersion,
        visibleVersionCount: initial.visibleVersionCount
      })}).`
    );
    check(
      initial.advancedEntryHref === "interactive/" &&
      initial.primaryPaths.length === 1 &&
      initial.primaryPaths.includes("orrery/"),
      `${prefix}primary paths are incomplete.`
    );
    check(
      initial.candidateVisible &&
      initial.candidateText.includes("可以使用 尚未正式稳定") &&
      initial.candidateText.includes("当前能做什么") &&
      initial.candidateText.includes("为什么仍是测试版") &&
      initial.candidateText.includes("不自动修改硬件") &&
      !initial.candidateInsideDetails &&
      initial.candidateDetailsExpanded === "false" &&
      initial.candidateDetailsHeight >= 44 &&
      initial.candidateState.includes("当前测试版") &&
      !/\d+\.\d+\.\d+/.test(initial.candidateState) &&
      initial.candidateStateSize >= 14,
      `${prefix}usable-state summary is not visible in the main flow (${JSON.stringify({
        visible: initial.candidateVisible,
        insideDetails: initial.candidateInsideDetails,
        expanded: initial.candidateDetailsExpanded,
        height: initial.candidateDetailsHeight,
        text: initial.candidateText.slice(0, 160)
      })}).`
    );
    check(
      initial.technicalClosed &&
      initial.technicalSummary.includes("了解这个 Skill") &&
      initial.technicalSummary.includes("功能说明、测试状态与历史版本") &&
      initial.technicalExpanded === "false" &&
      initial.technicalHeight >= 44,
      `${prefix}technical archive is not folded.`
    );
    await screenshot(connection, `previous-style-home-${name}.png`);

    await clickByPointer(connection, ".dse-hero-action.primary");
    const howtoVisible = await waitFor(connection, `(() => {
      const target = document.getElementById("dse-how-title");
      const section = document.querySelector(".dse-howto");
      return target && target.getBoundingClientRect().top >= -10 &&
        target.getBoundingClientRect().top < 180 &&
        Number(getComputedStyle(section).opacity) > .99;
    })()`, 3000);
    check(howtoVisible, `${prefix}primary CTA left a blank or invisible usage section.`);

    const homeFlowInitial = await evaluate(connection, `(() => ({
      stepOneVisible: !document.getElementById("dse-home-step-1")?.hidden,
      stepTwoHidden: Boolean(document.getElementById("dse-home-step-2")?.hidden),
      stepThreeHidden: Boolean(document.getElementById("dse-home-step-3")?.hidden),
      questionCount: document.querySelectorAll("[data-home-scenario]").length,
      flowColumns: getComputedStyle(document.querySelector(".dse-home-flow-steps")).gridTemplateColumns
    }))()`);
    check(
      homeFlowInitial.stepOneVisible &&
      homeFlowInitial.stepTwoHidden &&
      homeFlowInitial.stepThreeHidden &&
      homeFlowInitial.questionCount === 3 &&
      homeFlowInitial.flowColumns.split(" ").filter(Boolean).length === 1,
      `${prefix}inline simple flow does not start with one visible question step (${JSON.stringify(homeFlowInitial)}).`
    );
    await clickByPointer(connection, '[data-home-scenario="temperature"]');
    const selectedQuestionState = await evaluate(connection, `(() => ({
      optionsHidden: Boolean(document.getElementById("dse-home-question-options")?.hidden),
      leadHidden: Boolean(document.getElementById("dse-home-question-lead")?.hidden),
      summaryVisible: !document.getElementById("dse-home-question-summary")?.hidden,
      summary: document.getElementById("dse-home-question-summary-label")?.textContent.trim() || "",
      backdropScene: document.documentElement.dataset.crtSceneIntent || "",
      backdropScanning: document.getElementById("dse-crt-backdrop")?.classList.contains("is-scanning") || false
    }))()`);
    check(
      await waitFor(connection, `(() => (
        !document.getElementById("dse-home-step-2")?.hidden &&
        document.querySelectorAll("#dse-home-evidence-options input").length === 3
      ))()`, 2500),
      `${prefix}selecting a question did not reveal the evidence step directly below.`
    );
    check(
      selectedQuestionState.optionsHidden &&
      selectedQuestionState.leadHidden &&
      selectedQuestionState.summaryVisible &&
      selectedQuestionState.summary.includes("电脑温度偏高") &&
      selectedQuestionState.backdropScene === "fan" &&
      selectedQuestionState.backdropScanning === false,
      `${prefix}completed question step did not collapse or drive the background (${JSON.stringify(selectedQuestionState)}).`
    );
    await evaluate(connection, `(() => {
      const first = document.querySelector("#dse-home-evidence-options input");
      if (!first) throw new Error("Missing home evidence choice");
      first.click();
      return true;
    })()`);
    await clickByPointer(connection, "#dse-home-generate");
    const homeResult = await evaluate(connection, `(() => ({
      stepTwoVisible: !document.getElementById("dse-home-step-2")?.hidden,
      stepThreeVisible: !document.getElementById("dse-home-step-3")?.hidden,
      evidenceEditorHidden: Boolean(document.getElementById("dse-home-evidence-editor")?.hidden),
      evidenceSummaryVisible: !document.getElementById("dse-home-evidence-summary")?.hidden,
      evidenceSummaryCount: document.getElementById("dse-home-evidence-summary-count")?.textContent.trim() || "",
      status: document.getElementById("dse-home-result-status")?.textContent.trim() || "",
      copy: document.getElementById("dse-home-result-copy")?.textContent.trim() || "",
      missing: document.getElementById("dse-home-result-missing")?.textContent.trim() || "",
      next: document.getElementById("dse-home-result-next")?.textContent.trim() || "",
      advancedHref: document.getElementById("dse-home-open-advanced")?.getAttribute("href") || "",
      verticalOrder: [
        document.getElementById("dse-home-step-1"),
        document.getElementById("dse-home-step-2"),
        document.getElementById("dse-home-step-3"),
        document.querySelector(".dse-candidate")
      ].every((element, index, elements) => (
        index === 0 ||
        element.getBoundingClientRect().top > elements[index - 1].getBoundingClientRect().top
      )),
      candidateFollowsResult: Boolean(
        document.getElementById("dse-home-step-3")?.compareDocumentPosition(
          document.querySelector(".dse-candidate")
        ) & Node.DOCUMENT_POSITION_FOLLOWING
      )
    }))()`);
    check(
      homeResult.stepTwoVisible &&
      homeResult.stepThreeVisible &&
      homeResult.evidenceEditorHidden &&
      homeResult.evidenceSummaryVisible &&
      homeResult.evidenceSummaryCount === "1 / 3 项" &&
      homeResult.status.includes("还需补齐") &&
      homeResult.copy.includes("检查方向") &&
      homeResult.missing.includes("缺少的信息") &&
      homeResult.next.includes("推荐下一步") &&
      homeResult.advancedHref === "interactive/#triage" &&
      homeResult.verticalOrder &&
      homeResult.candidateFollowsResult,
      `${prefix}inline simple flow does not produce a result in vertical order (${JSON.stringify(homeResult)}).`
    );
    await evaluate(connection, `(() => {
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: async value => { window.__homeCopiedPrompt = value; } }
      });
      return true;
    })()`);
    await clickByPointer(connection, "#dse-home-copy-next");
    const homeCopy = await evaluate(connection, `(() => ({
      label: document.getElementById("dse-home-copy-next")?.textContent.trim() || "",
      prompt: String(window.__homeCopiedPrompt || "")
    }))()`);
    check(
      homeCopy.label.includes("已复制") &&
      homeCopy.prompt.includes("$pc-hardware-workbench") &&
      homeCopy.prompt.includes("不要自动修改硬件"),
      `${prefix}home result copy action has no completion feedback or safety boundary (${JSON.stringify(homeCopy)}).`
    );
    await screenshot(connection, `inline-simple-flow-${name}.png`);
    await clickByPointer(connection, "#dse-home-change-question");
    const changedQuestion = await evaluate(connection, `(() => ({
      optionsVisible: !document.getElementById("dse-home-question-options")?.hidden,
      questionSummaryHidden: Boolean(document.getElementById("dse-home-question-summary")?.hidden),
      evidenceStepHidden: Boolean(document.getElementById("dse-home-step-2")?.hidden),
      resultHidden: Boolean(document.getElementById("dse-home-step-3")?.hidden),
      backdropScene: document.documentElement.dataset.crtSceneIntent || ""
    }))()`);
    check(
      changedQuestion.optionsVisible &&
      changedQuestion.questionSummaryHidden &&
      changedQuestion.evidenceStepHidden &&
      changedQuestion.resultHidden &&
      changedQuestion.backdropScene === "",
      `${prefix}changing the question does not reopen the collapsed choice step (${JSON.stringify(changedQuestion)}).`
    );

    await evaluate(connection, `(() => {
      document.getElementById("dse-candidate-details-summary")?.focus();
      return true;
    })()`);
    await pressKey(connection, " ", "Space", 32);
    const candidateDisclosure = await evaluate(connection, `(() => ({
      open: Boolean(document.getElementById("dse-candidate-details")?.open),
      expanded: document.getElementById("dse-candidate-details-summary")?.getAttribute("aria-expanded") || "",
      action: document.querySelector("[data-candidate-details-action]")?.textContent.trim() || ""
    }))()`);
    check(
      candidateDisclosure.open &&
      candidateDisclosure.expanded === "true" &&
      candidateDisclosure.action.includes("收起技术与发布说明"),
      `${prefix}candidate technical disclosure is not a usable control.`
    );
    await pressKey(connection, " ", "Space", 32);

    await evaluate(connection, `(() => {
      document.getElementById("dse-home-technical-summary")?.focus();
      return true;
    })()`);
    await pressKey(connection, " ", "Space", 32);
    const archiveOpened = await waitFor(connection, `(() => {
      const details = document.querySelector(".dse-home-technical");
      return Boolean(details?.open);
    })()`, 2500);
    const opened = await evaluate(connection, `(() => ({
      open: Boolean(document.querySelector(".dse-home-technical")?.open),
      version: document.querySelector(".dse-home-technical")?.innerText.includes("2.5.0") || false,
      versionCodeSize: Number.parseFloat(getComputedStyle(document.querySelector(".dse-version-code")).fontSize),
      versionButtons: document.querySelectorAll(".dse-version").length,
      summaryExpanded: document.getElementById("dse-home-technical-summary")?.getAttribute("aria-expanded") || "",
      actionText: document.querySelector("[data-technical-action]")?.textContent.trim() || ""
    }))()`);
    check(
      archiveOpened &&
      opened.open &&
      opened.version &&
      opened.versionCodeSize >= 16 &&
      opened.versionButtons === 107 &&
      opened.summaryExpanded === "true" &&
      opened.actionText.includes("收起说明"),
      `${prefix}technical archive does not open correctly (${JSON.stringify(opened)}).`
    );
    const homeFontSizes = await evaluate(connection, fontSizeExpression());
    check(
      homeFontSizes.length <= 4,
      `${prefix}home uses more than four font-size levels (${JSON.stringify(homeFontSizes)}).`
    );
    await evaluate(connection, `(() => {
      document.querySelector('[data-version-id="wb-2-5-0"]')?.click();
      return true;
    })()`);
    await sleep(120);
    const archiveSelection = await evaluate(connection, `(() => ({
      detailVisible: !document.getElementById("dse-version-detail")?.hidden,
      title: document.getElementById("dse-version-detail-title")?.textContent.trim() || "",
      date: document.getElementById("dse-version-detail-date")?.textContent.trim() || "",
      hash: location.hash
    }))()`);
    check(
      archiveSelection.detailVisible &&
      archiveSelection.title.includes("2.5.0") &&
      archiveSelection.date.includes("测试版") &&
      !archiveSelection.date.includes("CANDIDATE") &&
      archiveSelection.hash === "#wb-2-5-0",
      `${prefix}version selection or deep link was lost (${JSON.stringify(archiveSelection)}).`
    );

    await navigate(connection, siteUrl);
    await navigate(connection, `${siteUrl}#wb-2-5-0`);
    const deepLinked = await waitFor(connection, `(() => (
      document.querySelector(".dse-home-technical")?.open &&
      !document.getElementById("dse-version-detail")?.hidden
    ))()`, 2500);
    check(deepLinked, `${prefix}direct version deep link does not reopen the archive.`);
    await evaluate(connection, `(async () => {
      document.querySelector('.dse-filter[data-filter="merge"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return true;
    })()`);
    const mergeLayout = await evaluate(connection, `(() => {
      const map = document.querySelector(".dse-map-stage");
      const convergence = document.querySelector(".dse-convergence");
      const detail = map?.querySelector(":scope > .dse-detail");
      const convergenceRect = convergence?.getBoundingClientRect();
      const detailRect = detail?.getBoundingClientRect();
      return {
        mergeClass: map?.classList.contains("is-merge-layout") || false,
        convergenceInsideMap: convergence?.parentElement === map,
        tracksVisible: [...map.querySelectorAll(":scope > .dse-tracks")].some(
          element => getComputedStyle(element).display !== "none"
        ),
        convergenceRect: {
          left: Math.round(convergenceRect?.left || 0),
          top: Math.round(convergenceRect?.top || 0),
          right: Math.round(convergenceRect?.right || 0)
        },
        detailRect: {
          left: Math.round(detailRect?.left || 0),
          top: Math.round(detailRect?.top || 0)
        }
      };
    })()`);
    const mergeBalanced =
      mergeLayout.mergeClass &&
      mergeLayout.convergenceInsideMap &&
      !mergeLayout.tracksVisible &&
      (name === "desktop"
        ? mergeLayout.convergenceRect.left < mergeLayout.detailRect.left &&
          Math.abs(mergeLayout.convergenceRect.top - mergeLayout.detailRect.top) < 120
        : mergeLayout.convergenceRect.top < mergeLayout.detailRect.top &&
          Math.abs(mergeLayout.convergenceRect.left - mergeLayout.detailRect.left) <= 20);
    check(
      mergeBalanced,
      `${prefix}merge stage leaves an unbalanced empty column (${JSON.stringify(mergeLayout)}).`
    );
    await navigate(connection, siteUrl);
    await clickByPointer(connection, '[data-home-scenario="temperature"]');
    await evaluate(connection, `(() => {
      document.querySelector("#dse-home-evidence-options input")?.click();
      return true;
    })()`);
    await clickByPointer(connection, "#dse-home-generate");
    const beforeAdvancedReturn = await evaluate(connection, `(async () => {
      const link = document.querySelector(".dse-advanced-entry a");
      link.scrollIntoView({ block: "center" });
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        scrollTop: Math.round(document.getElementById("dse-root").scrollTop),
        selected: document.querySelector("[data-home-scenario][aria-pressed='true']")?.dataset.homeScenario || "",
        evidenceChecked: Boolean(document.querySelector("#dse-home-evidence-options input:checked")),
        resultVisible: !document.getElementById("dse-home-step-3")?.hidden,
        href: link.href
      };
    })()`);
    await evaluate(connection, `(() => {
      document.querySelector(".dse-advanced-entry a")?.click();
      return true;
    })()`);
    check(
      await waitFor(connection, `location.pathname.endsWith("/interactive/")`, 3500),
      `${prefix}advanced-mode entry did not navigate.`
    );
    const advancedContext = await evaluate(connection, `(() => {
      const bridge = document.getElementById("dse-context-bridge");
      return {
        visible: Boolean(bridge && !bridge.hidden),
        title: document.getElementById("dse-context-title")?.textContent.trim() || "",
        summary: document.getElementById("dse-context-summary")?.textContent.trim() || "",
        selectedMode: document.querySelector(".dse-demo-modes [data-demo-mode][aria-pressed='true']")?.dataset.demoMode || ""
      };
    })()`);
    check(
      advancedContext.visible &&
      advancedContext.title.includes("电脑温度偏高") &&
      advancedContext.summary.includes("已生成下一步") &&
      advancedContext.summary.includes("已选 1 项信息") &&
      advancedContext.selectedMode === "triage",
      `${prefix}advanced page did not carry the home task context (${JSON.stringify(advancedContext)}).`
    );
    const previousStepAction = await evaluate(connection,
      "document.getElementById('dse-return-home')?.textContent.trim() || ''");
    check(previousStepAction.includes("返回上一步"), `${prefix}advanced page still says return home instead of previous step.`);
    await clickByPointer(connection, "#dse-return-home");
    check(
      await waitFor(connection, `(() => (
        location.pathname.endsWith("/docs/skill-evolution/") &&
        !document.getElementById("dse-home-step-3")?.hidden
      ))()`, 3500),
      `${prefix}advanced page did not restore the homepage interaction state.`
    );
    const afterAdvancedReturn = await evaluate(connection, `(() => ({
      scrollTop: Math.round(document.getElementById("dse-root").scrollTop),
      selected: document.querySelector("[data-home-scenario][aria-pressed='true']")?.dataset.homeScenario || "",
      evidenceChecked: Boolean(document.querySelector("#dse-home-evidence-options input:checked")),
      resultVisible: !document.getElementById("dse-home-step-3")?.hidden
    }))()`);
    check(
      afterAdvancedReturn.selected === beforeAdvancedReturn.selected &&
      afterAdvancedReturn.evidenceChecked === beforeAdvancedReturn.evidenceChecked &&
      afterAdvancedReturn.resultVisible &&
      Math.abs(afterAdvancedReturn.scrollTop - beforeAdvancedReturn.scrollTop) < 60,
      `${prefix}advanced return lost homepage state (${JSON.stringify({
        before: beforeAdvancedReturn,
        after: afterAdvancedReturn
      })}).`
    );

    const beforeOrreryReturn = await evaluate(connection, `(async () => {
      const link = document.querySelector('.dse-explore-primary a[href="orrery/"]');
      link.scrollIntoView({ block: "center" });
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        scrollTop: Math.round(document.getElementById("dse-root").scrollTop),
        selected: document.querySelector("[data-home-scenario][aria-pressed='true']")?.dataset.homeScenario || "",
        evidenceChecked: Boolean(document.querySelector("#dse-home-evidence-options input:checked")),
        resultVisible: !document.getElementById("dse-home-step-3")?.hidden
      };
    })()`);
    await evaluate(connection, `(() => {
      document.querySelector('.dse-explore-primary a[href="orrery/"]')?.click();
      return true;
    })()`);
    check(
      await waitFor(connection, `location.pathname.endsWith("/orrery/")`, 3500),
      `${prefix}file planet entry did not navigate.`
    );
    await clickByPointer(connection, 'a[href="../"]');
    check(
      await waitFor(connection, `(() => (
        location.pathname.endsWith("/docs/skill-evolution/") &&
        !document.getElementById("dse-home-step-3")?.hidden
      ))()`, 3500),
      `${prefix}file planet did not restore the homepage interaction state.`
    );
    await waitFor(connection, `Math.abs(
      document.getElementById("dse-root")?.scrollTop - ${beforeOrreryReturn.scrollTop}
    ) < 60`, 2500);
    const afterOrreryReturn = await evaluate(connection, `(() => ({
      scrollTop: Math.round(document.getElementById("dse-root").scrollTop),
      selected: document.querySelector("[data-home-scenario][aria-pressed='true']")?.dataset.homeScenario || "",
      evidenceChecked: Boolean(document.querySelector("#dse-home-evidence-options input:checked")),
      resultVisible: !document.getElementById("dse-home-step-3")?.hidden
    }))()`);
    check(
      afterOrreryReturn.selected === beforeOrreryReturn.selected &&
      afterOrreryReturn.evidenceChecked === beforeOrreryReturn.evidenceChecked &&
      afterOrreryReturn.resultVisible &&
      Math.abs(afterOrreryReturn.scrollTop - beforeOrreryReturn.scrollTop) < 60,
      `${prefix}file planet return lost homepage state (${JSON.stringify({
        before: beforeOrreryReturn,
        after: afterOrreryReturn
      })}).`
    );
    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testInteractiveViewport(interactiveUrl, name, width, height) {
  const connection = await createConnection(interactiveUrl);
  const prefix = `interactive ${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, interactiveUrl);
    await evaluate(connection, `(() => {
      const root = document.getElementById("dse-root");
      if (root) root.scrollTo({ top: 0, behavior: "auto" });
      return true;
    })()`);
    runIntegrityChecks(await evaluate(connection, integrityExpression()), prefix);

    const initial = await evaluate(connection, `(() => {
      const shell = document.getElementById("dse-advanced-shell");
      const visiblePanels = [...document.querySelectorAll(".dse-demo-panel[data-demo-mode]")]
        .filter(panel => !panel.hidden && panel.getBoundingClientRect().height > 0);
      const modeButtons = [...document.querySelectorAll(".dse-demo-modes [data-demo-mode]")];
      return {
        title: document.title,
        h1: document.querySelector(".dse-advanced-page-head h1")?.textContent.trim() || "",
        status: document.querySelector(".dse-advanced-page-head > small")?.textContent.trim() || "",
        pageHeadRect: (() => {
          const rect = document.querySelector(".dse-advanced-page-head")?.getBoundingClientRect();
          return {
            top: Math.round(rect?.top || 0),
            height: Math.round(rect?.height || 0)
          };
        })(),
        scrollTop: Math.round(document.getElementById("dse-root")?.scrollTop || 0),
        hash: window.location.hash,
        technicalOpen: Boolean(document.querySelector(".dse-interactive-technical")?.open),
        shellOpen: Boolean(shell?.open),
        advancedVisible: (shell?.getBoundingClientRect().height || 0) > 0,
        simpleModePresent: Boolean(document.querySelector(".dse-guided")),
        statusActionsVisible: (document.querySelector(".dse-advanced-actions")?.getBoundingClientRect().height || 0) > 0,
        visiblePanelCount: visiblePanels.length,
        visiblePanelMode: visiblePanels[0]?.dataset.demoMode || "",
        currentTheme: document.getElementById("dse-advanced-current")?.textContent.trim() || "",
        modeButtonCount: modeButtons.length,
        pressedModeCount: modeButtons.filter(button => button.getAttribute("aria-pressed") === "true").length,
        modeColumns: getComputedStyle(document.querySelector(".dse-demo-modes")).gridTemplateColumns,
        modeTops: modeButtons.map(button => Math.round(button.getBoundingClientRect().top)),
        tuneStepsHidden: Boolean(document.getElementById("dse-tune-steps")?.hidden),
        contextBridgeVisible: !document.getElementById("dse-context-bridge")?.hidden,
        backdropScene: document.documentElement.dataset.crtSceneIntent || "",
        compareStepPresent: Boolean(document.querySelector('[data-tune-step-link="compare"]')),
        comparePanelVisible: (document.getElementById("dse-tune-compare-panel")?.getBoundingClientRect().height || 0) > 0,
        visibleVersionNumber: document.getElementById("dse-root")?.innerText.includes("2.5.0") || false
      };
    })()`);
    check(initial.title.includes("高级模式"), `${prefix}browser title is not user-facing.`);
    check(initial.h1 === "选择一个主题", `${prefix}advanced-mode headline is not concise and task-oriented.`);
    check(
      initial.status.includes("当前测试版") &&
      initial.status.includes("只读演示") &&
      !initial.status.includes("2.5.0"),
      `${prefix}advanced page does not use the public test-release label.`
    );
    check(
      initial.pageHeadRect.height > 0 &&
      initial.pageHeadRect.top >= -1 &&
      initial.pageHeadRect.top < 180,
      `${prefix}advanced page headline is not visible at the top (${JSON.stringify({
        rect: initial.pageHeadRect,
        scrollTop: initial.scrollTop,
        hash: initial.hash
      })}).`
    );
    check(!initial.visibleVersionNumber, `${prefix}version number is repeated outside the version archive.`);
    check(
      initial.technicalOpen &&
      initial.shellOpen &&
      initial.advancedVisible &&
      !initial.simpleModePresent &&
      !initial.statusActionsVisible &&
      initial.visiblePanelCount === 1 &&
      initial.visiblePanelMode === "choose" &&
      initial.currentTheme === "尚未选择" &&
      initial.modeButtonCount === 4 &&
      initial.pressedModeCount === 0 &&
      initial.tuneStepsHidden &&
      !initial.contextBridgeVisible &&
      initial.backdropScene === "",
      `${prefix}advanced mode does not start with a neutral task chooser (${JSON.stringify(initial)}).`
    );
    check(
      initial.modeColumns.split(" ").filter(Boolean).length > 1 &&
      !initial.compareStepPresent &&
      !initial.comparePanelVisible,
      `${prefix}advanced peer navigation lost its compact horizontal layout (${JSON.stringify({
        modeColumns: initial.modeColumns,
        modeTops: initial.modeTops
      })}).`
    );
    await clickByPointer(connection, '[data-demo-mode="tune"]');
    const selectedTune = await evaluate(connection, `(() => ({
      pressed: document.querySelector('[data-demo-mode="tune"]')?.getAttribute("aria-pressed") || "",
      tunePanelVisible: (document.querySelector('.dse-demo-panel[data-demo-mode="tune"]')?.getBoundingClientRect().height || 0) > 0,
      tuneStepsHidden: Boolean(document.getElementById("dse-tune-steps")?.hidden),
      tuneStepColumns: getComputedStyle(document.getElementById("dse-tune-steps")).gridTemplateColumns,
      backdropScene: document.documentElement.dataset.crtSceneIntent || "",
      backdropScanning: document.getElementById("dse-crt-backdrop")?.classList.contains("is-scanning") || false
    }))()`);
    check(
      selectedTune.pressed === "true" &&
      selectedTune.tunePanelVisible &&
      !selectedTune.tuneStepsHidden &&
      selectedTune.backdropScene === "cpu" &&
      selectedTune.backdropScanning === false &&
      selectedTune.tuneStepColumns.split(" ").filter(Boolean).length === (name === "desktop" ? 2 : 1),
      `${prefix}tuning theme does not reveal its step rail (${JSON.stringify(selectedTune)}).`
    );
    await screenshot(connection, `vertical-advanced-${name}.png`);
    const interactiveFontSizes = await evaluate(connection, fontSizeExpression());
    check(
      interactiveFontSizes.length <= 4,
      `${prefix}interactive lab uses more than four font-size levels (${JSON.stringify(interactiveFontSizes)}).`
    );
    await evaluate(connection, `(() => {
      document.querySelector("[data-scenario-auto-toggle]").dataset.autoResumeMs = "700";
      return true;
    })()`);
    const scenarioAutoBefore = await evaluate(connection, `(() => ({
      active: document.querySelector("#dse-scenario-grid [data-scenario][aria-pressed='true']")?.dataset.scenario || "",
      autoResumeMs: document.querySelector("[data-scenario-auto-toggle]")?.dataset.autoResumeMs || "",
      meta: document.querySelector(".dse-scenario-meta > span")?.textContent.trim() || ""
    }))()`);
    const scenarioAfterScroll = await evaluate(connection, `(async () => {
      const root = document.getElementById("dse-root");
      root.scrollTop += 12;
      root.dispatchEvent(new Event("scroll"));
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
        checklistOpen: !document.getElementById("dse-gate-checklist")?.hidden
      };
    })()`);
    await clickByPointer(connection, '[data-gate-action="check"]');
    const scenarioAutoPaused = await evaluate(connection, `(() => ({
      active: document.querySelector("#dse-scenario-grid [data-scenario][aria-pressed='true']")?.dataset.scenario || "",
      pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
      label: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || "",
      summaryScore: document.getElementById("dse-gate-summary-score")?.textContent.trim() || "",
      summaryState: document.getElementById("dse-gate-summary")?.dataset.state || "",
      summaryNote: document.getElementById("dse-gate-summary-note")?.textContent.trim() || "",
      summaryLights: document.querySelectorAll(".dse-gate-summary-light").length
    }))()`);
    await sleep(650);
    const scenarioWithOpenDraft = await evaluate(connection, `(() => ({
      pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
      label: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || "",
      checklistOpen: !document.getElementById("dse-gate-checklist")?.hidden
    }))()`);
    await clickByPointer(connection, '[data-gate-action="check"]');
    await sleep(650);
    const scenarioAutoResumed = await evaluate(connection, `(() => ({
      pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
      label: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || "",
      checklistOpen: !document.getElementById("dse-gate-checklist")?.hidden
    }))()`);
    await evaluate(connection, `(() => {
      document.querySelector("[data-scenario-auto-toggle]").dataset.autoResumeMs = "25000";
      return true;
    })()`);
    check(
      scenarioAutoBefore.active.length > 0 &&
      scenarioAutoBefore.autoResumeMs === "700" &&
      scenarioAutoBefore.meta.includes("5 秒轮换") &&
      scenarioAutoBefore.meta.includes("停手 25 秒后自动继续") &&
      scenarioAfterScroll.pressed === "false" &&
      !scenarioAfterScroll.checklistOpen &&
      scenarioAutoPaused.active === scenarioAutoBefore.active &&
      scenarioAutoPaused.pressed === "true" &&
      scenarioAutoPaused.label.includes("立即继续演示") &&
      scenarioAutoPaused.summaryScore === "0 / 5" &&
      scenarioAutoPaused.summaryState === "incomplete" &&
      scenarioAutoPaused.summaryNote.includes("还缺 5 项") &&
      scenarioAutoPaused.summaryLights === 1 &&
      scenarioWithOpenDraft.pressed === "true" &&
      scenarioWithOpenDraft.checklistOpen &&
      scenarioAutoResumed.checklistOpen === false &&
      scenarioAutoResumed.pressed === "false" &&
      scenarioAutoResumed.label.includes("暂停自动演示"),
      `${prefix}scenario rotation does not pause on interaction and resume after idle (${JSON.stringify({
        before: scenarioAutoBefore,
        afterScroll: scenarioAfterScroll,
        paused: scenarioAutoPaused,
        withOpenDraft: scenarioWithOpenDraft,
        resumed: scenarioAutoResumed
      })}).`
    );
    await evaluate(connection, `(async () => {
      document.querySelector('[data-demo-mode="triage"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return true;
    })()`);
    const triageProgressInitial = await evaluate(connection, `(() => {
      const progress = document.getElementById("dse-triage-progress");
      const rail = document.getElementById("dse-triage-state-rail");
      const active = rail?.querySelector('.dse-state-node[aria-current="step"]');
      return {
        visible: Boolean(progress && progress.getBoundingClientRect().height > 0),
        insideDetails: Boolean(rail?.closest(".dse-tech-details")),
        stepCount: rail?.querySelectorAll(".dse-state-node").length || 0,
        active: active?.textContent.trim() || "",
        position: document.getElementById("dse-triage-progress-position")?.textContent.trim() || "",
        button: document.getElementById("dse-triage-advance")?.textContent.trim() || "",
        bodySize: Number.parseFloat(
          getComputedStyle(document.getElementById("dse-triage-copy-body")).fontSize
        ),
        actionSizes: [...document.querySelectorAll(".dse-machine-panel.triage .dse-gate-actions .dse-demo-action")]
          .filter(item => getComputedStyle(item).display !== "none")
          .map(item => {
            const rect = item.getBoundingClientRect();
            return {
              width: Math.round(rect.width),
              height: Math.round(rect.height),
              fontSize: Number.parseFloat(getComputedStyle(item).fontSize)
            };
          })
      };
    })()`);
    check(
      triageProgressInitial.visible &&
      !triageProgressInitial.insideDetails &&
      triageProgressInitial.stepCount === 4 &&
      triageProgressInitial.active.includes("安全与范围") &&
      triageProgressInitial.position.includes("第 1 / 4 步") &&
      triageProgressInitial.button === "补充信息" &&
      triageProgressInitial.bodySize >= (name === "desktop" ? 18 : 16) &&
      triageProgressInitial.actionSizes.length === 2 &&
      triageProgressInitial.actionSizes.every(size =>
        size.height === 44 &&
        size.fontSize === (name === "desktop" ? 18 : 16) &&
        Math.abs(size.width - triageProgressInitial.actionSizes[0].width) <= 1
      ),
      `${prefix}triage progress is not visible at the action (${JSON.stringify(triageProgressInitial)}).`
    );
    const triageAdvance = await evaluate(connection, `(async () => {
      const button = document.getElementById("dse-triage-advance");
      button?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const rail = document.getElementById("dse-triage-state-rail");
      return {
        active: rail?.querySelector('.dse-state-node[aria-current="step"]')?.textContent.trim() || "",
        position: document.getElementById("dse-triage-progress-position")?.textContent.trim() || "",
        label: document.getElementById("dse-triage-state-label")?.textContent.trim() || "",
        next: document.getElementById("dse-triage-state-next")?.textContent.trim() || "",
        button: button?.textContent.trim() || "",
        progressAdvanced: document.getElementById("dse-triage-progress")?.classList.contains("is-advancing") || false,
        copyUpdated: document.getElementById("dse-triage-copy")?.classList.contains("is-updated") || false
      };
    })()`);
    check(
      triageAdvance.active.includes("当前证据") &&
      triageAdvance.position.includes("第 2 / 4 步") &&
      triageAdvance.label.includes("补充当前信息") &&
      triageAdvance.next.includes("下一步只补") &&
      triageAdvance.button === "做一个小检查" &&
      triageAdvance.progressAdvanced &&
      triageAdvance.copyUpdated,
      `${prefix}triage advance has no clear step feedback (${JSON.stringify(triageAdvance)}).`
    );
    const triageComplete = await evaluate(connection, `(async () => {
      const button = document.getElementById("dse-triage-advance");
      button?.click();
      await new Promise(resolve => requestAnimationFrame(resolve));
      button?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const rail = document.getElementById("dse-triage-state-rail");
      return {
        active: rail?.querySelector('.dse-state-node[aria-current="step"]')?.textContent.trim() || "",
        position: document.getElementById("dse-triage-progress-position")?.textContent.trim() || "",
        disabled: Boolean(button?.disabled),
        button: button?.textContent.trim() || ""
      };
    })()`);
    check(
      triageComplete.active.includes("分流") &&
      triageComplete.position.includes("已完成 4 / 4") &&
      triageComplete.disabled &&
      triageComplete.button.includes("这组已经看完"),
      `${prefix}triage completion state is unclear (${JSON.stringify(triageComplete)}).`
    );
    const triageStack = await evaluate(connection, `(() => {
      const stack = document.getElementById("dse-triage-case-grid");
      const cases = [...stack.querySelectorAll("[data-triage-case]")];
      return {
        columns: getComputedStyle(stack).gridTemplateColumns,
        caseCount: cases.length,
        caseTops: cases.map(item => Math.round(item.getBoundingClientRect().top)),
        horizontalOverflow: stack.scrollWidth > stack.clientWidth,
        touchAction: getComputedStyle(stack).touchAction,
        autoToggleVisible: getComputedStyle(
          document.getElementById("dse-triage-auto-toggle")
        ).display !== "none"
      };
    })()`);
    check(
      triageStack.columns.split(" ").filter(Boolean).length === 1 &&
      triageStack.caseCount > 1 &&
      new Set(triageStack.caseTops).size === triageStack.caseTops.length &&
      !triageStack.horizontalOverflow &&
      triageStack.touchAction === "pan-y" &&
      triageStack.autoToggleVisible,
      `${prefix}triage cases are not a vertical explicit-choice list (${JSON.stringify(triageStack)}).`
    );
    if (name === "mobile") {
      const swipePoint = await evaluate(connection, `(async () => {
        const firstCase = document.querySelector("#dse-triage-case-grid [data-triage-case]");
        firstCase.scrollIntoView({ block: "center" });
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const rect = firstCase.getBoundingClientRect();
        return {
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
          before: document.getElementById("dse-root").scrollTop
        };
      })()`);
      const touchPoint = (x, y) => [{ x, y, radiusX: 2, radiusY: 2, force: 1, id: 1 }];
      await connection.send("Input.dispatchTouchEvent", {
        type: "touchStart",
        touchPoints: touchPoint(swipePoint.x, swipePoint.y)
      });
      for (let step = 1; step <= 4; step += 1) {
        await connection.send("Input.dispatchTouchEvent", {
          type: "touchMove",
          touchPoints: touchPoint(swipePoint.x, swipePoint.y - step * 32)
        });
        await sleep(35);
      }
      await connection.send("Input.dispatchTouchEvent", {
        type: "touchEnd",
        touchPoints: []
      });
      await sleep(260);
      const afterTouchScroll = await evaluate(connection,
        "Math.round(document.getElementById('dse-root').scrollTop)");
      check(
        afterTouchScroll > swipePoint.before + 60,
        `${prefix}touching a triage option prevents vertical page scrolling (${JSON.stringify({
          before: swipePoint.before,
          after: afterTouchScroll
        })}).`
      );
    }
    /*
    const advancedThemes = await evaluate(connection, `(async () => {
      const results = {};
      for (const mode of ["terms", "tune", "triage", "record"]) {
        document.querySelector([31m`[data-demo-mode="${mode}"]`[0m)?.click();
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        results[mode] = {
          pressed: document.querySelector([31m`[data-demo-mode="${mode}"]`[0m)?.getAttribute("aria-pressed") === "true",
          visiblePanels: [...document.querySelectorAll(".dse-demo-panel[data-demo-mode]")]
            .filter(panel => !panel.hidden && panel.getBoundingClientRect().height > 0).length
        };
      }
      document.querySelector('[data-demo-mode="tune"]')?.click();
      return results;
    })()`);
    check(
      Object.values(advancedThemes).every(result => result.pressed && result.visiblePanels === 1),
      `${prefix}one or more advanced themes are missing or shown together (${JSON.stringify(advancedThemes)}).`
    );
    */
    const advancedThemes = await evaluate(connection, `(async () => {
      const results = {};
      for (const mode of ["terms", "tune", "triage", "record"]) {
        document.querySelector('[data-demo-mode="' + mode + '"]')?.click();
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        results[mode] = {
          pressed: document.querySelector('[data-demo-mode="' + mode + '"]')?.getAttribute("aria-pressed") === "true",
          backdropScene: document.documentElement.dataset.crtSceneIntent || "",
          visibleThemes: [...new Set(
            [...document.querySelectorAll(".dse-demo-panel[data-demo-mode]")]
              .filter(panel => !panel.hidden && panel.getBoundingClientRect().height > 0)
              .map(panel => panel.dataset.demoMode)
          )]
        };
      }
      document.querySelector('[data-demo-mode="tune"]')?.click();
      return results;
    })()`);
    check(
      Object.values(advancedThemes).every(result => result.pressed && result.visibleThemes.length === 1) &&
      advancedThemes.terms.backdropScene === "space" &&
      advancedThemes.tune.backdropScene === "cpu" &&
      advancedThemes.triage.backdropScene === "fan" &&
      advancedThemes.record.backdropScene === "gpu",
      `${prefix}one or more advanced themes are missing or shown together (${JSON.stringify(advancedThemes)}).`
    );
    const lifecycleStability = await evaluate(connection, `(async () => {
      document.querySelector('[data-demo-mode="record"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const panel = document.querySelector('.dse-demo-panel[data-demo-mode="record"]');
      const lifecycleGrid = panel?.querySelector(".dse-lifecycle-grid");
      const lifecycleEvents = panel?.querySelector(".dse-lifecycle-events");
      const lifecycleCopy = panel?.querySelector("#dse-lifecycle-copy");
      const lifecycleLabel = panel?.querySelector(".dse-lifecycle-track-label");
      const lifecycleNode = panel?.querySelector("#dse-identity-state-rail .dse-state-node");
      const buttons = [...document.querySelectorAll("#dse-lifecycle-events [data-lifecycle-event]")];
      const samples = [];
      for (const button of buttons) {
        button.click();
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        const rect = panel?.getBoundingClientRect();
        const copy = document.getElementById("dse-lifecycle-copy")?.getBoundingClientRect();
        samples.push({
          event: button.dataset.lifecycleEvent || "",
          width: Math.round(rect?.width || 0),
          height: Math.round(rect?.height || 0),
          copyHeight: Math.round(copy?.height || 0)
        });
      }
      const alignment = {
        left: [
          lifecycleGrid,
          lifecycleEvents,
          lifecycleCopy,
          lifecycleLabel,
          panel?.querySelector("#dse-identity-state-rail .dse-state-node")
        ].map(element => Math.round(element?.getBoundingClientRect().left || 0)),
        right: [
          lifecycleGrid,
          lifecycleEvents,
          lifecycleCopy
        ].map(element => Math.round(element?.getBoundingClientRect().right || 0))
      };
      document.querySelector('[data-demo-mode="tune"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return { samples, alignment };
    })()`);
    const lifecycleWidths = lifecycleStability.samples.map(sample => sample.width);
    const lifecycleHeights = lifecycleStability.samples.map(sample => sample.height);
    const lifecycleCopyHeights = lifecycleStability.samples.map(sample => sample.copyHeight);
    const spread = values => Math.max(...values) - Math.min(...values);
    check(
      lifecycleStability.samples.length === 5 &&
      spread(lifecycleWidths) <= 2 &&
      spread(lifecycleHeights) <= 2 &&
      spread(lifecycleCopyHeights) <= 2 &&
      spread(lifecycleStability.alignment.left) <= 1 &&
      spread(lifecycleStability.alignment.right) <= 1,
      `${prefix}identity panel changes size between events (${JSON.stringify(lifecycleStability)}).`
    );
    const tuneSteps = await evaluate(connection, `(async () => {
      const visibleStep = () => [...document.querySelectorAll('[data-demo-mode="tune"][data-tune-step]')]
        .filter(panel => !panel.hidden)
        .map(panel => panel.dataset.tuneStep);
      const results = { gate: visibleStep() };
      document.querySelector('[data-tune-step-link="experiment"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      results.experiment = visibleStep();
      return results;
    })()`);
    check(
      tuneSteps.gate.join(",") === "gate" &&
      tuneSteps.experiment.join(",") === "experiment",
      `${prefix}tuning steps still show multiple panels at once (${JSON.stringify(tuneSteps)}).`
    );
    await clickByPointer(connection, '[data-tune-step-link="gate"]');
    await clickByPointer(connection, ".dse-secondary-actions > summary");
    await clickByPointer(connection, '[data-gate-action="direct"]');
    const directFeedback = await evaluate(connection, `(() => ({
      visible: !document.getElementById("dse-direct-feedback")?.hidden,
      title: document.getElementById("dse-direct-feedback-title")?.textContent.trim() || "",
      copy: document.getElementById("dse-direct-feedback-copy")?.textContent.trim() || "",
      expanded: document.querySelector('[data-gate-action="direct"]')?.getAttribute("aria-expanded") || "",
      label: document.querySelector('[data-gate-action="direct"]')?.textContent.trim() || ""
    }))()`);
    check(
      directFeedback.visible &&
      directFeedback.title.includes("参数请求已被拦下") &&
      directFeedback.copy.includes("不会显示") &&
      directFeedback.expanded === "true" &&
      directFeedback.label.includes("已演示"),
      `${prefix}direct-parameter feedback is not visible at the action (${JSON.stringify(directFeedback)}).`
    );
    await clickByPointer(connection, '[data-scenario="cpu"]');
    const gateButtonsInitial = await evaluate(connection, `(() => (
      [...document.querySelectorAll("#dse-tune-gate-panel .dse-gate-actions > .dse-demo-action")]
        .filter(button => getComputedStyle(button).display !== "none")
        .map(button => {
          const rect = button.getBoundingClientRect();
          return {
            text: button.textContent.trim(),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            fontSize: Number.parseFloat(getComputedStyle(button).fontSize)
          };
        })
    ))()`);
    await clickByPointer(connection, '[data-gate-action="check"]');
    const gateButtonsOpen = await evaluate(connection, `(() => (
      [...document.querySelectorAll("#dse-tune-gate-panel .dse-gate-actions > .dse-demo-action")]
        .filter(button => getComputedStyle(button).display !== "none")
        .map(button => {
          const rect = button.getBoundingClientRect();
          return {
            text: button.textContent.trim(),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            fontSize: Number.parseFloat(getComputedStyle(button).fontSize)
          };
        })
    ))()`);
    await evaluate(connection, `(() => {
      document.querySelectorAll("[data-gate-check]").forEach(input => input.click());
      return true;
    })()`);
    await sleep(160);
    const gateButtonsReady = await evaluate(connection, `(() => (
      [...document.querySelectorAll("#dse-tune-gate-panel .dse-gate-actions > .dse-demo-action")]
        .filter(button => getComputedStyle(button).display !== "none")
        .map(button => {
          const rect = button.getBoundingClientRect();
          return {
            text: button.textContent.trim(),
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            fontSize: Number.parseFloat(getComputedStyle(button).fontSize)
          };
        })
    ))()`);
    const gateButtonSpread = Math.max(...gateButtonsReady.map(button => button.width)) -
      Math.min(...gateButtonsReady.map(button => button.width));
    const gateSummaryReady = await evaluate(connection, `(() => ({
      score: document.getElementById("dse-gate-summary-score")?.textContent.trim() || "",
      state: document.getElementById("dse-gate-summary")?.dataset.state || "",
      note: document.getElementById("dse-gate-summary-note")?.textContent.trim() || "",
      lights: document.querySelectorAll(".dse-gate-summary-light").length
    }))()`);
    check(
      gateButtonsInitial.length === 1 &&
      gateButtonsOpen.length === 1 &&
      gateButtonsReady.length === 2 &&
      gateButtonsInitial[0].width === gateButtonsOpen[0].width &&
      gateButtonsInitial[0].height === 44 &&
      gateButtonsOpen[0].height === 44 &&
      gateButtonsReady.every(button =>
        button.height === 44 && button.fontSize === (name === "desktop" ? 18 : 16)
      ) &&
      gateButtonSpread <= 1 &&
      gateSummaryReady.score === "5 / 5" &&
      gateSummaryReady.state === "ready" &&
      gateSummaryReady.note.includes("条件齐全") &&
      gateSummaryReady.lights === 1,
      `${prefix}gate action buttons change size between states (${JSON.stringify({
        initial: gateButtonsInitial,
        open: gateButtonsOpen,
        ready: gateButtonsReady,
        summary: gateSummaryReady
      })}).`
    );
    await clickByPointer(connection, "#dse-enter-experiment");
    await clickByPointer(connection, "#dse-generate-experiment");
    const experimentPlan = await evaluate(connection, `(() => {
      const output = document.getElementById("dse-experiment-output");
      return {
        visible: !output?.hidden,
        className: output?.className || "",
        outcome: output?.dataset.outcome || "",
        actionsVisible: !document.getElementById("dse-sim-actions")?.hidden,
        actionSizes: [...document.querySelectorAll("[data-sim-result]")].map(button => {
          const rect = button.getBoundingClientRect();
          return {
            width: Math.round(rect.width),
            height: Math.round(rect.height),
            fontSize: Number.parseFloat(getComputedStyle(button).fontSize)
          };
        }),
        selected: [...document.querySelectorAll("[data-sim-result]")]
          .filter(button => button.getAttribute("aria-pressed") === "true").length
      };
    })()`);
    check(
      experimentPlan.visible &&
      experimentPlan.className.includes("demo") &&
      experimentPlan.outcome === "" &&
      experimentPlan.actionsVisible &&
      experimentPlan.actionSizes.every(size =>
        size.height >= 44 &&
        size.fontSize === (name === "desktop" ? 18 : 16) &&
        Math.abs(size.width - experimentPlan.actionSizes[0].width) <= 1
      ) &&
      Math.max(...experimentPlan.actionSizes.map(size => size.height)) -
        Math.min(...experimentPlan.actionSizes.map(size => size.height)) <= 1 &&
      experimentPlan.selected === 0,
      `${prefix}experiment plan appears pre-colored as a final outcome (${JSON.stringify(experimentPlan)}).`
    );
    const experimentOutcomes = await evaluate(connection, `(async () => {
      const samples = {};
      for (const outcome of ["pass", "fail", "inconclusive"]) {
        const button = document.querySelector('[data-sim-result="' + outcome + '"]');
        button?.click();
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        await new Promise(resolve => setTimeout(resolve, 220));
        const output = document.getElementById("dse-experiment-output");
        const card = document.getElementById("dse-sim-outcome");
        const title = document.getElementById("dse-sim-outcome-title");
        const body = document.getElementById("dse-sim-outcome-body");
        const status = document.getElementById("dse-exp-status");
        samples[outcome] = {
          className: output?.className || "",
          outcome: output?.dataset.outcome || "",
          borderColor: getComputedStyle(output).borderTopColor,
          statusColor: getComputedStyle(status).color,
          status: status?.textContent.trim() || "",
          title: title?.textContent.trim() || "",
          body: body?.textContent.trim() || "",
          active: button?.getAttribute("aria-pressed") || "",
          hidden: Boolean(card?.hidden),
          titleSize: Number.parseFloat(getComputedStyle(title).fontSize),
          bodySize: Number.parseFloat(getComputedStyle(body).fontSize)
        };
      }
      return samples;
    })()`);
    const outcomeNames = Object.keys(experimentOutcomes);
    const outcomeBorders = outcomeNames.map(outcome => experimentOutcomes[outcome].borderColor);
    const outcomeStatusColors = outcomeNames.map(outcome => experimentOutcomes[outcome].statusColor);
    check(
      new Set(outcomeBorders).size === 3 &&
      new Set(outcomeStatusColors).size === 3 &&
      outcomeNames.every(outcome => {
        const sample = experimentOutcomes[outcome];
        return sample.className.includes(`outcome-${outcome}`) &&
          sample.outcome === outcome &&
          sample.active === "true" &&
          sample.hidden === false &&
          sample.status.includes("假设结果") &&
          sample.title.length > 0 &&
          sample.body.length > 0 &&
          sample.titleSize >= 15 &&
          sample.bodySize >= 14;
      }),
      `${prefix}experiment outcomes are not visually and semantically distinct (${JSON.stringify(experimentOutcomes)}).`
    );
    const advancedFinal = await evaluate(connection, `(() => ({
      open: Boolean(document.querySelector(".dse-interactive-technical")?.open),
      advancedOpen: Boolean(document.getElementById("dse-advanced-shell")?.open),
      nestedSummaryVisible: (document.getElementById("dse-advanced-summary")?.getBoundingClientRect().height || 0) > 0,
      simpleModePresent: Boolean(document.querySelector(".dse-guided"))
    }))()`);
    check(
      advancedFinal.open &&
      advancedFinal.advancedOpen &&
      !advancedFinal.nestedSummaryVisible &&
      !advancedFinal.simpleModePresent,
      `${prefix}advanced page reintroduced a disclosure or simple-mode flow (${JSON.stringify(advancedFinal)}).`
    );

    await clickAllowingNavigation(connection, '.dse-global-nav a[href="../"]');
    check(
      await waitFor(connection, `location.pathname.endsWith("/docs/skill-evolution/")`, 3500),
      `${prefix}return-home navigation failed.`
    );
    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testOrrerySmoke(orreryUrl, name, width, height) {
  const connection = await createConnection(orreryUrl);
  const prefix = `orrery ${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, orreryUrl);
    const initial = await evaluate(connection, `(() => ({
      categoryCount: document.querySelectorAll(".category-node").length,
      dossierText: document.getElementById("dossier")?.innerText.trim().length || 0
    }))()`);
    check(initial.categoryCount === 7, `${prefix}expected 7 category nodes.`);
    check(initial.dossierText > 80, `${prefix}overview dossier is empty.`);
    await clickByPointer(connection, ".category-node.is-core");
    check(
      await waitFor(connection, "document.querySelectorAll('.file-node').length > 0", 2500),
      `${prefix}category expansion failed.`
    );
    await clickByPointer(connection, ".file-node");
    check(
      await evaluate(connection, `Boolean(document.querySelector(".file-node.is-active")) && document.getElementById("selectionReset")?.classList.contains("is-visible")`),
      `${prefix}file selection state is incomplete.`
    );
    await clickByPointer(connection, "#selectionReset");
    check(
      await evaluate(connection, `!document.querySelector(".file-node.is-active")`),
      `${prefix}selection reset failed.`
    );
    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testReducedMotion(siteUrl, interactiveUrl, orreryUrl) {
  for (const page of [
    { name: "home", url: siteUrl },
    { name: "interactive", url: interactiveUrl },
    { name: "orrery", url: orreryUrl }
  ]) {
    const connection = await createConnection(page.url);
    const prefix = `reduced motion ${page.name}: `;
    try {
      await setViewport(connection, 390, 844);
      await connection.send("Emulation.setEmulatedMedia", {
        media: "screen",
        features: [{ name: "prefers-reduced-motion", value: "reduce" }]
      });
      await navigate(connection, page.url);
      await sleep(180);
      const state = await evaluate(connection, `(() => {
        const visible = element => {
          if (!element) return false;
          const rect = element.getBoundingClientRect();
          const style = getComputedStyle(element);
          return rect.width > 0 && rect.height > 0 &&
            style.display !== "none" && style.visibility !== "hidden";
        };
        const heading = [...document.querySelectorAll("h1")].find(visible);
        return {
          matches: matchMedia("(prefers-reduced-motion: reduce)").matches,
          h1Text: heading?.textContent.trim() || "",
          h1Opacity: Number(heading ? getComputedStyle(heading).opacity : 0),
          runningAnimations: document.getAnimations().filter(animation => animation.playState === "running").length,
          overflow:
            document.documentElement.scrollWidth > document.documentElement.clientWidth ||
            document.getElementById("dse-root")?.scrollWidth > document.getElementById("dse-root")?.clientWidth
        };
      })()`);
      check(state.matches, `${prefix}media preference did not apply.`);
      check(state.h1Text.length > 0 && state.h1Opacity > .9, `${prefix}heading is not immediately visible.`);
      check(state.runningAnimations === 0, `${prefix}${state.runningAnimations} animations still run.`);
      check(state.overflow === false, `${prefix}page has horizontal overflow.`);
      check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
    } finally {
      connection.close();
      await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
    }
  }
}

async function main() {
  if (!browserPath) {
    throw new Error("Microsoft Edge or Google Chrome was not found. Set EDGE_PATH to its executable.");
  }
  debugPort = await findFreePort();
  const { server, port } = await startServer();
  const siteUrl = `http://127.0.0.1:${port}/docs/skill-evolution/`;
  const interactiveUrl = `${siteUrl}interactive/`;
  const orreryUrl = `${siteUrl}orrery/`;
  const browser = spawn(
    browserPath,
    [
      "--headless",
      "--no-sandbox",
      "--disable-gpu",
      "--disable-software-rasterizer",
      "--disable-dev-shm-usage",
      "--no-first-run",
      "--disable-extensions",
      `--remote-debugging-port=${debugPort}`,
      `--user-data-dir=${profileDir}`,
      "about:blank"
    ],
    { stdio: "ignore" }
  );

  try {
    await waitForDebugEndpoint();
    await testHomeViewport(siteUrl, "desktop", 1440, 1000);
    await testHomeViewport(siteUrl, "mobile", 390, 844);
    await testInteractiveViewport(interactiveUrl, "desktop", 1440, 1000);
    await testInteractiveViewport(interactiveUrl, "mobile", 390, 844);
    await testOrrerySmoke(orreryUrl, "desktop", 1440, 1000);
    await testOrrerySmoke(orreryUrl, "mobile", 390, 844);
    await testReducedMotion(siteUrl, interactiveUrl, orreryUrl);
  } finally {
    browser.kill();
    server.close();
  }

  if (failures.length) {
    console.error("Skill evolution runtime regression: FAIL");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exitCode = 1;
    return;
  }
  console.log("Skill evolution runtime regression: PASS (previous visual system, single guided path, orrery; desktop and mobile)");
}

main().catch(error => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
