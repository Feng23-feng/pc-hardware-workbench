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

function startServer(rootDirectory) {
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
    let filePath = path.resolve(rootDirectory, `.${requestPath}`);
    if (!filePath.startsWith(`${rootDirectory}${path.sep}`) && filePath !== rootDirectory) {
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
      const details = message.params.exceptionDetails;
      pageErrors.push(
        `${details.exception?.description || details.text}` +
        (details.url ? ` (${details.url}:${details.lineNumber || 0})` : "")
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

async function waitForViewTransition(connection) {
  await waitFor(connection, `(() => {
    try {
      return !document.documentElement.matches(":active-view-transition");
    } catch {
      return true;
    }
  })()`, 2500);
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
  const connection = await createConnection("about:blank");
  const prefix = `home ${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, siteUrl);
    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
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
      heroVersion: document.getElementById("dse-hero-version")?.textContent.trim() || "",
      visibleVersionCount: (
        document.getElementById("dse-root")?.innerText.match(/2\.7\.4/g) || []
      ).length,
      technicalClosed: !document.querySelector(".dse-home-technical")?.open,
      technicalSummary: document.querySelector(".dse-home-technical > summary")?.innerText.trim() || "",
      technicalExpanded: document.getElementById("dse-home-technical-summary")?.getAttribute("aria-expanded") || "",
      technicalHeight: Math.round(document.getElementById("dse-home-technical-summary")?.getBoundingClientRect().height || 0),
      viewportWidth: Math.round(window.innerWidth || 0),
      rootClientWidth: Math.round(document.getElementById("dse-root")?.clientWidth || 0),
      rootScrollWidth: Math.round(document.getElementById("dse-root")?.scrollWidth || 0),
      bodyScrollWidth: Math.round(document.body?.scrollWidth || 0),
      headerCopyLeft: Math.round(document.querySelector(".dse-hero .dse-header-copy")?.getBoundingClientRect().left || 0),
      headerCopyRight: Math.round(document.querySelector(".dse-hero .dse-header-copy")?.getBoundingClientRect().right || 0)
    }))()`);
    check(initial.title.includes("电脑硬件工作台"), `${prefix}browser title is not user-facing.`);
    check(
      initial.h1.includes("电脑调试") && initial.h1.includes("Skill 来帮你"),
      `${prefix}hero headline does not cover the full decision scope.`
    );
    check(
      initial.subtitle.includes("配置") &&
      initial.subtitle.includes("排查问题") &&
      initial.subtitle.includes("调参或升级"),
      `${prefix}hero subtitle still narrows the Skill to troubleshooting.`
    );
    check(
      initial.safety.includes("测试版") &&
      initial.safety.includes("只读") &&
      initial.safety.includes("不会自动修改硬件"),
      `${prefix}hero action result and safety boundary are not explicit.`
    );
    check(initial.ctaHref === "#dse-home-flow", `${prefix}primary CTA does not lead to the inline simple flow.`);
    check(initial.ctaText === "开始自查", `${prefix}hero CTA does not match the simplified entry.`);
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
      initial.heroVersion === "2.7.4" &&
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
      initial.technicalClosed &&
      initial.technicalSummary.includes("版本与技术资料") &&
      initial.technicalSummary.includes("项目地图、文件结构与历史版本") &&
      initial.technicalExpanded === "false" &&
      initial.technicalHeight >= 44,
      `${prefix}technical archive is not folded.`
    );
    check(
      initial.rootClientWidth > 0 &&
      initial.rootScrollWidth <= initial.rootClientWidth + 1 &&
      initial.bodyScrollWidth <= initial.viewportWidth + 1 &&
      initial.headerCopyLeft >= 12 &&
      initial.headerCopyRight <= initial.rootClientWidth - 12,
      `${prefix}hero content overflows the viewport safe area (${JSON.stringify({
        rootClientWidth: initial.rootClientWidth,
        viewportWidth: initial.viewportWidth,
        rootScrollWidth: initial.rootScrollWidth,
        bodyScrollWidth: initial.bodyScrollWidth,
        headerCopyLeft: initial.headerCopyLeft,
        headerCopyRight: initial.headerCopyRight
      })}).`
    );
    await screenshot(connection, `previous-style-home-${name}.png`);
    await evaluate(connection, `document.querySelector(".dse-explore-primary a")?.scrollIntoView({ block: "center" })`);
    await waitFor(connection, `(() => {
      const image = document.querySelector(".dse-orrery-preview img");
      return Boolean(image && image.complete && image.naturalWidth > 0);
    })()`, 2500);
    const filePlanetCard = await evaluate(connection, `(() => {
      const link = document.querySelector(".dse-explore-primary a");
      const copy = link?.querySelector(".dse-explore-copy");
      const preview = link?.querySelector(".dse-orrery-preview");
      const image = preview?.querySelector("img");
      return {
        title: link?.querySelector(".dse-explore-title")?.textContent.trim() || "",
        cta: link?.querySelector(".dse-explore-cta")?.textContent.replace(/\\s+/g, " ").trim() || "",
        linkColumns: getComputedStyle(link).gridTemplateColumns,
        previewWidth: Math.round(preview?.getBoundingClientRect().width || 0),
        previewHeight: Math.round(preview?.getBoundingClientRect().height || 0),
        previewBeforeCopy: (preview?.getBoundingClientRect().top || 0) < (copy?.getBoundingClientRect().top || 0),
        imageLoaded: Boolean(image?.complete && image?.naturalWidth > 0),
        canvasCount: link?.querySelectorAll("canvas").length || 0
      };
    })()`);
    check(
      filePlanetCard.title.includes("114 个文件") &&
      filePlanetCard.cta.includes("进入文件星球") &&
      filePlanetCard.previewWidth >= 280 &&
      filePlanetCard.previewHeight >= (name === "desktop" ? 300 : 160) &&
      filePlanetCard.imageLoaded &&
      filePlanetCard.canvasCount === 0 &&
      (name === "desktop"
        ? filePlanetCard.linkColumns.split(" ").filter(Boolean).length === 2
        : filePlanetCard.previewBeforeCopy),
      `${prefix}file planet entry is not a working two-column/mobile preview card (${JSON.stringify(filePlanetCard)}).`
    );
    const candidateStatus = await evaluate(connection, `(() => {
      const section = document.querySelector(".dse-candidate");
      const explore = document.querySelector(".dse-explore-primary");
      const rows = [...document.querySelectorAll(".dse-candidate-summary > div")];
      return {
        state: section?.querySelector(".dse-candidate-state")?.textContent.trim() || "",
        title: section?.querySelector("#dse-candidate-title")?.textContent.trim() || "",
        lead: section?.querySelector(".dse-candidate-lead")?.textContent.trim() || "",
        rowLabels: rows.map(row => row.querySelector("dt")?.textContent.trim() || ""),
        rowCopies: rows.map(row => row.querySelector("dd")?.textContent.trim() || ""),
        gapAfterFilePlanet: Math.round(
          (section?.getBoundingClientRect().top || 0) -
          (explore?.getBoundingClientRect().bottom || 0)
        ),
        belowFilePlanet: Boolean(
          section &&
          explore &&
          section.getBoundingClientRect().top >= explore.getBoundingClientRect().bottom - 1
        )
      };
    })()`);
    check(
      candidateStatus.state === "当前测试版" &&
      candidateStatus.title === "可以使用 尚未正式稳定" &&
      candidateStatus.lead.includes("真实设备覆盖") &&
      candidateStatus.rowLabels.join(",") === "版本状态,读取方式,当前限制" &&
      candidateStatus.rowCopies.every(copy => copy.length > 0) &&
      candidateStatus.gapAfterFilePlanet >= (name === "desktop" ? 72 : 44) &&
      candidateStatus.belowFilePlanet,
      `${prefix}candidate status is missing or no longer follows the file planet (${JSON.stringify(candidateStatus)}).`
    );

    await clickByPointer(connection, ".dse-hero-action.primary");
    const howtoVisible = await waitFor(connection, `(() => {
      const target = document.getElementById("dse-how-title");
      const section = document.querySelector(".dse-howto");
      return target && target.getBoundingClientRect().top >= -10 &&
        target.getBoundingClientRect().top < 180 &&
        Number(getComputedStyle(section).opacity) > .99 &&
        document.activeElement?.id === "dse-how-title";
    })()`, 3000);
    check(howtoVisible, `${prefix}primary CTA left a blank or invisible usage section.`);

    const homeFlowInitial = await evaluate(connection, `(() => ({
      stepOneVisible: !document.getElementById("dse-home-step-1")?.hidden,
      stepTwoHidden: Boolean(document.getElementById("dse-home-step-2")?.hidden),
      stepThreeHidden: Boolean(document.getElementById("dse-home-step-3")?.hidden),
      questionCount: document.querySelectorAll("[data-home-scenario]").length,
      questionLabels: [...document.querySelectorAll("[data-home-scenario] strong")]
        .map(item => item.textContent.trim()),
      questionMarkers: document.querySelectorAll(".dse-home-question-marker").length,
      quickPathCount: document.querySelectorAll("#dse-home-quick-paths button, #dse-home-quick-paths a").length,
      questionControlMinHeight: Math.min(
        ...[...document.querySelectorAll(".dse-home-question-option")]
          .map(item => Math.round(item.getBoundingClientRect().height))
      ),
      flowColumns: getComputedStyle(document.querySelector(".dse-home-flow-steps")).gridTemplateColumns
    }))()`);
    check(
      homeFlowInitial.stepOneVisible &&
      homeFlowInitial.stepTwoHidden &&
      homeFlowInitial.stepThreeHidden &&
      homeFlowInitial.questionCount === 5 &&
      homeFlowInitial.questionLabels.includes("查看当前配置") &&
      homeFlowInitial.questionLabels.includes("考虑升级") &&
      homeFlowInitial.questionMarkers === 5 &&
      homeFlowInitial.quickPathCount === 1 &&
      homeFlowInitial.questionControlMinHeight >= 44 &&
      homeFlowInitial.flowColumns.split(" ").filter(Boolean).length === 1,
      `${prefix}inline simple flow does not start with one visible question step (${JSON.stringify(homeFlowInitial)}).`
    );
    await screenshot(connection, `home-flow-initial-${name}.png`);
    await clickByPointer(connection, '[data-home-scenario="temperature"]');
    const selectedQuestionState = await evaluate(connection, `(() => ({
      optionsHidden: Boolean(document.getElementById("dse-home-question-options")?.hidden),
      leadHidden: Boolean(document.getElementById("dse-home-question-lead")?.hidden),
      summaryVisible: !document.getElementById("dse-home-question-summary")?.hidden,
      summary: document.getElementById("dse-home-question-summary-label")?.textContent.trim() || "",
      backdropScene: document.documentElement.dataset.crtSceneIntent || "",
      backdropScanning: document.getElementById("dse-crt-backdrop")?.classList.contains("is-scanning") || false,
      priorityBadge: document.querySelector(".dse-home-priority-badge")?.textContent.trim() || "",
      noEvidenceVisible: (document.getElementById("dse-home-no-evidence")?.getBoundingClientRect().height || 0) > 0
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
      selectedQuestionState.backdropScanning === false &&
      selectedQuestionState.priorityBadge.includes("优先补这个") &&
      selectedQuestionState.noEvidenceVisible &&
      await waitFor(connection, `document.activeElement?.id === "dse-home-step-2-title"`, 1500),
      `${prefix}completed question step did not collapse or drive the background (${JSON.stringify(selectedQuestionState)}).`
    );
    await evaluate(connection, `(() => {
      const first = document.querySelector("#dse-home-evidence-options input");
      if (!first) throw new Error("Missing home evidence choice");
      first.click();
      return true;
    })()`);
    await clickByPointer(connection, "#dse-home-no-evidence");
    const minimumEvidence = await evaluate(connection, `(() => ({
      visible: !document.getElementById("dse-home-minimum-evidence")?.hidden,
      text: document.getElementById("dse-home-minimum-evidence")?.textContent.trim() || ""
    }))()`);
    check(
      minimumEvidence.visible && minimumEvidence.text.includes("最小起点"),
      `${prefix}no-evidence help does not provide a smallest first step (${JSON.stringify(minimumEvidence)}).`
    );
    await clickByPointer(connection, "#dse-home-generate");
    await waitFor(connection, `document.activeElement?.id === "dse-home-step-3-title"`, 1500);
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
      detailVisible: !document.getElementById("dse-home-result-detail")?.hidden,
      detailOpen: Boolean(document.getElementById("dse-home-result-detail")?.open),
      advancedHref: document.getElementById("dse-home-open-advanced")?.getAttribute("href") || "",
      standaloneAdvancedHidden: Boolean(document.querySelector(".dse-advanced-entry")?.hidden),
      verticalOrder: [
        document.getElementById("dse-home-step-1"),
        document.getElementById("dse-home-step-2"),
        document.getElementById("dse-home-step-3")
      ].every((element, index, elements) => (
        index === 0 ||
        element.getBoundingClientRect().top > elements[index - 1].getBoundingClientRect().top
      ))
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
      homeResult.detailVisible &&
      !homeResult.detailOpen &&
      homeResult.advancedHref === "interactive/#triage" &&
      homeResult.standaloneAdvancedHidden &&
      homeResult.verticalOrder,
      `${prefix}inline simple flow does not produce a result in vertical order (${JSON.stringify(homeResult)}).`
    );
    await clickByPointer(connection, "#dse-home-result-detail > summary");
    const homeDetail = await evaluate(connection, `(() => ({
      open: Boolean(document.getElementById("dse-home-result-detail")?.open),
      texts: [
        "dse-home-detail-confirmed",
        "dse-home-detail-unknown",
        "dse-home-detail-why",
        "dse-home-detail-terms"
      ].map(id => document.getElementById(id)?.textContent.trim() || "")
    }))()`);
    check(
      homeDetail.open && homeDetail.texts.every(text => text.length > 0),
      `${prefix}home detailed judgment is missing or empty (${JSON.stringify(homeDetail)}).`
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
      pressedOptions: document.querySelectorAll('[data-home-scenario][aria-pressed="true"]').length,
      backdropScene: document.documentElement.dataset.crtSceneIntent || ""
    }))()`);
    check(
      changedQuestion.optionsVisible &&
      changedQuestion.questionSummaryHidden &&
      changedQuestion.evidenceStepHidden &&
      changedQuestion.resultHidden &&
      changedQuestion.pressedOptions === 0 &&
      changedQuestion.backdropScene === "",
      `${prefix}changing the question does not reopen the collapsed choice step (${JSON.stringify(changedQuestion)}).`
    );
    await clickByPointer(connection, "#dse-home-unknown-toggle");
    await clickByPointer(connection, '[data-home-unknown="slowEveryday"]');
    const unknownRoute = await evaluate(connection, `(() => ({
      summary: document.getElementById("dse-home-question-summary-label")?.textContent.trim() || "",
      evidenceVisible: !document.getElementById("dse-home-step-2")?.hidden,
      evidenceLabels: [...document.querySelectorAll("#dse-home-evidence-options input")]
        .map(input => input.closest("label")?.innerText.trim() || ""),
      priorityBadge: document.querySelector(".dse-home-priority-badge")?.textContent.trim() || ""
    }))()`);
    check(
      unknownRoute.summary.includes("平时用软件会卡") &&
      unknownRoute.evidenceVisible &&
      unknownRoute.evidenceLabels.length === 3 &&
      unknownRoute.priorityBadge.includes("优先补这个"),
      `${prefix}unknown-symptom entry does not route to a concrete plain-language flow (${JSON.stringify(unknownRoute)}).`
    );

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
      version: document.querySelector(".dse-home-technical")?.innerText.includes("2.7.4") || false,
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
      opened.versionButtons === 114 &&
      opened.summaryExpanded === "true" &&
      opened.actionText.includes("收起技术资料"),
      `${prefix}technical archive does not open correctly (${JSON.stringify(opened)}).`
    );
    const homeFontSizes = await evaluate(connection, fontSizeExpression());
    check(
      homeFontSizes.length <= 4,
      `${prefix}home uses more than four font-size levels (${JSON.stringify(homeFontSizes)}).`
    );
    await evaluate(connection, `(() => {
      document.querySelector('[data-version-id="wb-2-7-4"]')?.click();
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
      archiveSelection.title.includes("2.7.4") &&
      archiveSelection.date.includes("测试版") &&
      !archiveSelection.date.includes("CANDIDATE") &&
      archiveSelection.hash === "#wb-2-7-4",
      `${prefix}version selection or deep link was lost (${JSON.stringify(archiveSelection)}).`
    );

    await navigate(connection, siteUrl);
    await navigate(connection, `${siteUrl}#wb-2-7-4`);
    const deepLinked = await waitFor(connection, `(() => (
      document.querySelector(".dse-home-technical")?.open &&
      !document.getElementById("dse-version-detail")?.hidden
    ))()`, 2500);
    check(deepLinked, `${prefix}direct version deep link does not reopen the archive.`);
    const publicMap = await evaluate(connection, `(() => ({
      filters: [...document.querySelectorAll(".dse-filters [data-filter]")]
        .map(button => button.dataset.filter),
      prototypeFilter: Boolean(document.querySelector('[data-filter="prototype"]')),
      mergeFilter: Boolean(document.querySelector('[data-filter="merge"]')),
      prototypeTrack: Boolean(document.querySelector('.dse-track[data-track="prototype"]')),
      convergence: Boolean(document.querySelector(".dse-convergence")),
      coreCodes: [...document.querySelectorAll("#dse-core-lane .dse-node-code")]
        .map(node => node.textContent.trim()),
      integrationTitle: [...document.querySelectorAll("#dse-core-lane .dse-node")]
        .find(node => node.textContent.includes("GPU 自动候选整合"))?.innerText.trim() || "",
      archiveSeries: [...document.querySelectorAll("#dse-version-archive .dse-series")]
        .map(series => series.querySelector(".dse-series-label")?.innerText.replace(/\\s+/g, " ").trim() || "")
    }))()`);
    check(
      publicMap.filters.join(",") === "core,triage" &&
      !publicMap.prototypeFilter &&
      !publicMap.mergeFilter &&
      !publicMap.prototypeTrack &&
      !publicMap.convergence &&
      publicMap.coreCodes.includes("WB-09") &&
      publicMap.integrationTitle.includes("2.7.4 测试版") &&
      publicMap.archiveSeries.some(label => label.includes("GPU 自动候选整合史 / 3.x")),
      `${prefix}public map still exposes the retired prototype as a parallel product (${JSON.stringify(publicMap)}).`
    );
    await evaluate(connection, `(() => {
      const root = document.getElementById("dse-root");
      const map = document.querySelector(".dse-map-stage");
      if (root && map) root.scrollTop += map.getBoundingClientRect().top - root.getBoundingClientRect().top - 80;
      return true;
    })()`);
    await sleep(100);
    await screenshot(connection, `public-map-${name}.png`);
    await navigate(connection, `${siteUrl}#ao-3-0-2`);
    const archivedPrototype = await waitFor(connection, `(() => (
      document.querySelector(".dse-home-technical")?.open &&
      !document.getElementById("dse-version-detail")?.hidden &&
      (document.getElementById("dse-version-detail-title")?.textContent || "").includes("3.0.2")
    ))()`, 2500);
    check(archivedPrototype, `${prefix}archived GPU candidate history is no longer reachable by deep link.`);
    await navigate(connection, siteUrl);
    await clickByPointer(connection, '[data-home-scenario="temperature"]');
    await evaluate(connection, `(() => {
      document.querySelector("#dse-home-evidence-options input")?.click();
      return true;
    })()`);
    await clickByPointer(connection, "#dse-home-generate");
    const beforeAdvancedReturn = await evaluate(connection, `(async () => {
      const link = document.getElementById("dse-home-open-advanced");
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
    await clickByPointer(connection, "#dse-home-open-advanced");
    check(
      await waitFor(connection, `(() => (
        document.readyState === "complete" &&
        location.pathname.endsWith("/interactive/") &&
        Boolean(document.getElementById("dse-context-bridge"))
      ))()`, 5000),
      `${prefix}advanced-mode entry did not navigate.`
    );
    await waitForViewTransition(connection);
    await sleep(600);
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
    check(previousStepAction.includes("返回首页"), `${prefix}advanced page return label does not match its destination.`);
    await clickByPointer(connection, "#dse-return-home");
    check(
      await waitFor(connection, `(() => (
        document.readyState === "complete" &&
        location.pathname.endsWith("/docs/skill-evolution/") &&
        Boolean(document.getElementById("dse-home-step-3")) &&
        !document.getElementById("dse-home-step-3").hidden
      ))()`, 5000),
      `${prefix}advanced page did not restore the homepage interaction state.`
    );
    await waitForViewTransition(connection);
    await sleep(600);
    await waitFor(connection, `Math.abs(
      Number(document.getElementById("dse-root")?.scrollTop || 0) - ${beforeAdvancedReturn.scrollTop}
    ) < 60`, 2500);
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
    await clickByPointer(connection, '.dse-explore-primary a[href="orrery/"]');
    check(
      await waitFor(connection, `(() => (
        document.readyState === "complete" &&
        location.pathname.endsWith("/orrery/") &&
        Boolean(document.querySelector('.global-nav a[href="../"]'))
      ))()`, 5000),
      `${prefix}file planet entry did not navigate.`
    );
    await waitForViewTransition(connection);
    await sleep(600);
    await clickByPointer(connection, '.global-nav a[href="../"]');
    check(
      await waitFor(connection, `(() => (
        document.readyState === "complete" &&
        location.pathname.endsWith("/docs/skill-evolution/") &&
        Boolean(document.getElementById("dse-home-step-3")) &&
        !document.getElementById("dse-home-step-3").hidden
      ))()`, 5000),
      `${prefix}file planet did not restore the homepage interaction state.`
    );
    await waitForViewTransition(connection);
    await sleep(600);
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

    if (name === "desktop") {
      await clickByPointer(connection, "#dse-home-restart");
      await sleep(600);
      const beforeFreshReturn = await evaluate(connection, `(async () => {
        const link = document.querySelector(".dse-advanced-entry a");
        link.scrollIntoView({ block: "center" });
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
        return {
          scrollTop: Math.round(document.getElementById("dse-root").scrollTop),
          selected: document.querySelector("[data-home-scenario][aria-pressed='true']")?.dataset.homeScenario || "",
          resultVisible: !document.getElementById("dse-home-step-3")?.hidden
        };
      })()`);
      await clickByPointer(connection, ".dse-advanced-entry a");
      check(
        await waitFor(connection, `(() => (
          document.readyState === "complete" &&
          location.pathname.endsWith("/interactive/")
        ))()`, 5000),
        `${prefix}fresh advanced-mode entry did not navigate.`
      );
      await waitForViewTransition(connection);
      await sleep(600);
      await clickByPointer(connection, "#dse-return-home");
      check(
        await waitFor(connection, `(() => (
          document.readyState === "complete" &&
          location.pathname.endsWith("/docs/skill-evolution/") &&
          document.getElementById("dse-home-step-3")?.hidden &&
          !document.querySelector("[data-home-scenario][aria-pressed='true']")
        ))()`, 5000),
        `${prefix}fresh advanced return did not restore the homepage without fabricating interaction state.`
      );
      await waitForViewTransition(connection);
      await sleep(600);
      await waitFor(connection, `Math.abs(
        Number(document.getElementById("dse-root")?.scrollTop || 0) - ${beforeFreshReturn.scrollTop}
      ) < 60`, 2500);
      const afterFreshReturn = await evaluate(connection, `(() => ({
        scrollTop: Math.round(document.getElementById("dse-root").scrollTop),
        selected: document.querySelector("[data-home-scenario][aria-pressed='true']")?.dataset.homeScenario || "",
        resultVisible: !document.getElementById("dse-home-step-3")?.hidden
      }))()`);
      check(
        beforeFreshReturn.scrollTop > 100 &&
        beforeFreshReturn.selected === "" &&
        !beforeFreshReturn.resultVisible &&
        afterFreshReturn.selected === "" &&
        !afterFreshReturn.resultVisible &&
        Math.abs(afterFreshReturn.scrollTop - beforeFreshReturn.scrollTop) < 60,
        `${prefix}fresh advanced return lost the homepage scroll position (${JSON.stringify({
          before: beforeFreshReturn,
          after: afterFreshReturn
        })}).`
      );
    }
    // Programmatic CDP navigation can race an in-flight cross-document transition.
    // The real browser click path is covered separately; ignore only that abort.
    const unexpectedPageErrors = connection.pageErrors.filter(error =>
      !error.includes("Transition was aborted because of invalid state. ViewTransition opt-in disabled")
    );
    check(unexpectedPageErrors.length === 0, `${prefix}page errors: ${unexpectedPageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testPreviewRootReturn(siteUrl) {
  const connection = await createConnection("about:blank");
  const prefix = "preview root return: ";
  const homePath = new URL("./", siteUrl).pathname;
  const interactivePath = new URL("interactive/", siteUrl).pathname;
  try {
    await setViewport(connection, 1440, 1000);
    await navigate(connection, siteUrl);
    runIntegrityChecks(await evaluate(connection, integrityExpression()), prefix);
    const beforeReturn = await evaluate(connection, `(async () => {
      const root = document.getElementById("dse-root");
      const link = document.querySelector(".dse-advanced-entry a");
      root.style.scrollBehavior = "auto";
      link.scrollIntoView({ block: "center" });
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const linkRect = link.getBoundingClientRect();
      return {
        path: location.pathname,
        scrollTop: Math.round(root.scrollTop),
        entryVisible: linkRect.height > 0 && linkRect.top >= 0 && linkRect.bottom <= innerHeight
      };
    })()`);
    await clickByPointer(connection, ".dse-advanced-entry a");
    check(
      await waitFor(connection, `(() => (
        document.readyState === "complete" &&
        location.pathname === ${JSON.stringify(interactivePath)} &&
        Boolean(document.getElementById("dse-return-home"))
      ))()`, 5000),
      `${prefix}advanced-mode entry did not navigate (${JSON.stringify(beforeReturn)}).`
    );
    await waitForViewTransition(connection);
    await sleep(600);
    await clickByPointer(connection, "#dse-return-home");
    check(
      await waitFor(connection, `(() => (
        document.readyState === "complete" &&
        location.pathname === ${JSON.stringify(homePath)} &&
        Boolean(document.getElementById("dse-root"))
      ))()`, 5000),
      `${prefix}return did not reach the preview homepage.`
    );
    await waitForViewTransition(connection);
    await sleep(600);
    await waitFor(connection, `Math.abs(
      Number(document.getElementById("dse-root")?.scrollTop || 0) - ${beforeReturn.scrollTop}
    ) < 60`, 2500);
    const afterReturn = await evaluate(connection, `(() => {
      const link = document.querySelector(".dse-advanced-entry a");
      const linkRect = link?.getBoundingClientRect();
      return {
        path: location.pathname,
        scrollTop: Math.round(document.getElementById("dse-root")?.scrollTop || 0),
        entryVisible: Boolean(
          linkRect &&
          linkRect.height > 0 &&
          linkRect.top >= 0 &&
          linkRect.bottom <= innerHeight
        )
      };
    })()`);
    check(
      beforeReturn.path === homePath &&
      beforeReturn.scrollTop > 100 &&
      beforeReturn.entryVisible &&
      afterReturn.path === homePath &&
      afterReturn.entryVisible &&
      Math.abs(afterReturn.scrollTop - beforeReturn.scrollTop) < 60,
      `${prefix}advanced-mode return lost the originating scroll position (${JSON.stringify({
        before: beforeReturn,
        after: afterReturn
      })}).`
    );
    const unexpectedPageErrors = connection.pageErrors.filter(error =>
      !error.includes("Transition was aborted because of invalid state. ViewTransition opt-in disabled")
    );
    check(unexpectedPageErrors.length === 0, `${prefix}page errors: ${unexpectedPageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testInteractiveViewport(interactiveUrl, name, width, height) {
  const connection = await createConnection("about:blank");
  const prefix = `interactive ${name}: `;
  const desktopLayout = width > 760;
  const compactNavigation = width <= 360;
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
      const rootElement = document.getElementById("dse-root");
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
        currentTheme: document.getElementById("dse-advanced-current")?.textContent.trim() || "",
        modeButtonCount: modeButtons.length,
        pressedModeCount: modeButtons.filter(button => button.getAttribute("aria-pressed") === "true").length,
        taskChooserVisible: (document.getElementById("dse-task-chooser")?.getBoundingClientRect().height || 0) > 0,
        taskChoiceCount: document.querySelectorAll("#dse-task-chooser [data-demo-choice]").length,
        modeColumns: getComputedStyle(document.querySelector(".dse-demo-modes")).gridTemplateColumns,
        modeWidth: Math.round(document.querySelector(".dse-demo-modes")?.getBoundingClientRect().width || 0),
        demoWidth: Math.round(document.querySelector(".dse-demo")?.getBoundingClientRect().width || 0),
        rootWidth: Math.round(rootElement?.getBoundingClientRect().width || 0),
        groupWidths: [...document.querySelectorAll(".dse-demo-mode-group")]
          .map(group => Math.round(group.getBoundingClientRect().width)),
        buttonWidths: modeButtons.map(button => Math.round(button.getBoundingClientRect().width)),
        modeTops: modeButtons.map(button => Math.round(button.getBoundingClientRect().top)),
        modeButtonOverflow: modeButtons
          .filter(button => button.scrollWidth > button.clientWidth + 1)
          .map(button => button.textContent.trim()),
        horizontalOverflow: Math.max(
          document.documentElement.scrollWidth - document.documentElement.clientWidth,
          Number(rootElement?.scrollWidth || 0) - Number(rootElement?.clientWidth || 0)
        ),
        tuneStepsHidden: Boolean(document.getElementById("dse-tune-steps")?.hidden),
        contextBridgeVisible: !document.getElementById("dse-context-bridge")?.hidden,
        backdropScene: document.documentElement.dataset.crtSceneIntent || "",
        compareStepPresent: Boolean(document.querySelector('[data-tune-step-link="compare"]')),
        comparePanelVisible: (document.getElementById("dse-tune-compare-panel")?.getBoundingClientRect().height || 0) > 0,
        visibleVersionNumber: document.getElementById("dse-root")?.innerText.includes("2.7.4") || false
      };
    })()`);
    check(initial.title.includes("高级模式"), `${prefix}browser title is not user-facing.`);
    check(initial.h1 === "高级模式", `${prefix}advanced-mode headline is not named consistently.`);
    check(
      initial.status.includes("当前测试版") &&
      initial.status.includes("只读演示") &&
      !initial.status.includes("2.7.4"),
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
      initial.visiblePanelCount === 0 &&
      initial.currentTheme === "尚未选择" &&
      initial.modeButtonCount === 4 &&
      initial.pressedModeCount === 0 &&
      initial.taskChooserVisible &&
      initial.taskChoiceCount === 4 &&
      initial.tuneStepsHidden &&
      !initial.contextBridgeVisible &&
      initial.backdropScene === "",
      `${prefix}advanced mode does not start with a neutral task chooser (${JSON.stringify(initial)}).`
    );
    check(
      (
        compactNavigation
          ? initial.modeColumns.split(" ").filter(Boolean).length >= 1
          : initial.modeColumns.split(" ").filter(Boolean).length > 1
      ) &&
      initial.modeButtonOverflow.length === 0 &&
      initial.horizontalOverflow <= 1 &&
      !initial.compareStepPresent &&
      !initial.comparePanelVisible,
      `${prefix}advanced peer navigation lost its compact horizontal layout (${JSON.stringify({
        modeColumns: initial.modeColumns,
        modeWidth: initial.modeWidth,
        demoWidth: initial.demoWidth,
        rootWidth: initial.rootWidth,
        groupWidths: initial.groupWidths,
        buttonWidths: initial.buttonWidths,
        modeTops: initial.modeTops,
        modeButtonOverflow: initial.modeButtonOverflow,
        horizontalOverflow: initial.horizontalOverflow
      })}).`
    );
    await clickByPointer(connection, '[data-demo-mode="terms"]');
    const initialTerms = await evaluate(connection, `(() => ({
      coreCount: document.querySelectorAll("#dse-term-core-row [data-term-id]").length,
      coreLabels: [...document.querySelectorAll("#dse-term-core-row [data-term-id]")]
        .map(item => item.textContent.trim()),
      moreClosed: !document.querySelector(".dse-term-more")?.open,
      moreSummaryHeight: Math.round(document.querySelector(".dse-term-more > summary")?.getBoundingClientRect().height || 0)
    }))()`);
    check(
      initialTerms.coreCount === 6 &&
      initialTerms.coreLabels.some(label => label.includes("MoDT")) &&
      initialTerms.coreLabels.some(label => label.includes("稳定基线")) &&
      initialTerms.coreLabels.some(label => label.includes("恢复路径")) &&
      initialTerms.moreClosed &&
      initialTerms.moreSummaryHeight >= 44,
      `${prefix}terms do not start with six core choices and a secondary disclosure (${JSON.stringify(initialTerms)}).`
    );
    const modtTerm = await evaluate(connection, `(async () => {
      document.querySelector('#dse-term-core-row [data-term-id="modt"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        visible: !document.getElementById("dse-term-detail")?.hidden,
        title: document.getElementById("dse-term-detail-title")?.textContent.trim() || "",
        summary: document.getElementById("dse-term-summary")?.textContent.trim() || "",
        mistake: document.getElementById("dse-term-mistake")?.textContent.trim() || "",
        hash: location.hash
      };
    })()`);
    check(
      modtTerm.visible &&
      modtTerm.title === "MoDT" &&
      modtTerm.summary.includes("Mobile on Desktop") &&
      modtTerm.mistake.includes("不是") &&
      modtTerm.hash === "#term-modt",
      `${prefix}MoDT term does not explain its platform boundary (${JSON.stringify(modtTerm)}).`
    );
    await screenshot(connection, `term-modt-${name}.png`);
    await clickByPointer(connection, "#dse-term-close");
    await screenshot(connection, `advanced-terms-${name}.png`);
    await clickByPointer(connection, '[data-demo-mode="tune"]');
    const selectedTune = await evaluate(connection, `(() => ({
      pressed: document.querySelector('[data-demo-mode="tune"]')?.getAttribute("aria-pressed") || "",
      tunePanelVisible: (document.querySelector('.dse-demo-panel[data-demo-mode="tune"]')?.getBoundingClientRect().height || 0) > 0,
      tuneStepsHidden: Boolean(document.getElementById("dse-tune-steps")?.hidden),
      tuneStepColumns: getComputedStyle(document.getElementById("dse-tune-steps")).gridTemplateColumns,
      tuneStepOverflow: [...document.querySelectorAll("#dse-tune-steps strong, #dse-tune-steps small")]
        .filter(label => {
          const rect = label.getBoundingClientRect();
          return rect.width > 0 && rect.height > 0 &&
            label.scrollWidth > label.clientWidth + 1;
        })
        .map(label => label.textContent.trim()),
      backdropScene: document.documentElement.dataset.crtSceneIntent || "",
      backdropScanning: document.getElementById("dse-crt-backdrop")?.classList.contains("is-scanning") || false
    }))()`);
    check(
      selectedTune.pressed === "true" &&
      selectedTune.tunePanelVisible &&
      !selectedTune.tuneStepsHidden &&
      selectedTune.backdropScene === "cpu" &&
      selectedTune.backdropScanning === false &&
      selectedTune.tuneStepOverflow.length === 0 &&
      selectedTune.tuneStepColumns.split(" ").filter(Boolean).length === (desktopLayout ? 3 : 1),
      `${prefix}tuning theme does not reveal its step rail (${JSON.stringify(selectedTune)}).`
    );
    const expandedScenarios = await evaluate(connection, `(async () => {
      const picker = document.getElementById("dse-scenario-picker");
      const choose = async id => {
        picker.value = id;
        picker.dispatchEvent(new Event("change", { bubbles: true }));
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      };
      const read = id => ({
        id,
        copy: document.getElementById("dse-gate-copy")?.textContent.trim() || "",
        missing: [...document.querySelectorAll("#dse-gate-missing span")]
          .map(item => item.textContent.trim()),
        detail: [...document.querySelectorAll("#dse-gate-detail [id]")]
          .map(item => item.textContent.trim()),
        checkLabel: document.querySelector('[data-gate-action="check"]')?.textContent.trim() || "",
        enterDisabled: Boolean(document.getElementById("dse-enter-experiment")?.disabled)
      });
      await choose("concept");
      document.querySelector('[data-gate-action="check"]')?.click();
      await new Promise(resolve => requestAnimationFrame(resolve));
      const concept = {
        ...read("concept"),
        answerVisible: !document.getElementById("dse-concept-answer")?.hidden,
        answerCount: document.querySelectorAll("#dse-concept-answer li").length,
        controls: document.querySelector('[data-gate-action="check"]')?.getAttribute("aria-controls") || ""
      };
      document.querySelector('[data-gate-action="direct"]')?.click();
      await new Promise(resolve => requestAnimationFrame(resolve));
      const conceptDirect = {
        title: document.getElementById("dse-direct-feedback-title")?.textContent.trim() || "",
        copy: document.getElementById("dse-direct-feedback-copy")?.textContent.trim() || "",
        answerHidden: Boolean(document.getElementById("dse-concept-answer")?.hidden)
      };
      await choose("modt");
      const modt = read("modt");
      await choose("detailedMissing");
      const detailed = read("detailedMissing");
      await choose("xmp");
      const xmp = read("xmp");
      await choose("staleControl");
      const stale = read("staleControl");
      await choose("cpu");
      return { concept, conceptDirect, modt, detailed, xmp, stale };
    })()`);
    check(
      expandedScenarios.concept.answerVisible &&
      expandedScenarios.concept.answerCount >= 3 &&
      expandedScenarios.concept.checkLabel.includes("已解释") &&
      expandedScenarios.concept.controls === "dse-concept-answer" &&
      expandedScenarios.concept.enterDisabled &&
      expandedScenarios.conceptDirect.title.includes("不需要设备门禁") &&
      expandedScenarios.conceptDirect.copy.includes("只有继续判断") &&
      expandedScenarios.conceptDirect.answerHidden &&
      expandedScenarios.modt.copy.includes("MoDT") &&
      expandedScenarios.modt.detail.join(" ").includes("MoDT") &&
      expandedScenarios.modt.missing.some(item => item.includes("主板")) &&
      expandedScenarios.modt.detail.every(text => text.length > 0) &&
      expandedScenarios.detailed.detail.join(" ").includes("详细") &&
      expandedScenarios.detailed.missing.some(item => item.includes("稳定状态")) &&
      expandedScenarios.xmp.missing.some(item => item.includes("内存")) &&
      expandedScenarios.stale.copy.includes("控制值") &&
      expandedScenarios.stale.missing.some(item => item.includes("控制值")),
      `${prefix}expanded scenarios do not expose concept, detailed, MoDT, XMP or stale-control guidance (${JSON.stringify(expandedScenarios)}).`
    );
    const scenarioSpecificGate = await evaluate(connection, `(async () => {
      const picker = document.getElementById("dse-scenario-picker");
      picker.value = "modt";
      picker.dispatchEvent(new Event("change", { bubbles: true }));
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      document.querySelector('[data-gate-action="check"]')?.click();
      [...document.querySelectorAll("[data-gate-check]")].forEach(input => input.click());
      await new Promise(resolve => requestAnimationFrame(resolve));
      const genericOnly = {
        extraCount: document.querySelectorAll("[data-gate-extra]").length,
        extraVisible: !document.getElementById("dse-gate-extra")?.hidden,
        enterDisabled: Boolean(document.getElementById("dse-enter-experiment")?.disabled),
        score: document.getElementById("dse-gate-summary-score")?.textContent.trim() || "",
        note: document.getElementById("dse-gate-summary-note")?.textContent.trim() || ""
      };
      [...document.querySelectorAll("[data-gate-extra]")].forEach(input => input.click());
      await new Promise(resolve => requestAnimationFrame(resolve));
      const complete = {
        enterDisabled: Boolean(document.getElementById("dse-enter-experiment")?.disabled),
        score: document.getElementById("dse-gate-summary-score")?.textContent.trim() || "",
        note: document.getElementById("dse-gate-summary-note")?.textContent.trim() || ""
      };
      picker.value = "cpu";
      picker.dispatchEvent(new Event("change", { bubbles: true }));
      return { genericOnly, complete };
    })()`);
    check(
      scenarioSpecificGate.genericOnly.extraVisible &&
      scenarioSpecificGate.genericOnly.extraCount >= 3 &&
      scenarioSpecificGate.genericOnly.enterDisabled &&
      scenarioSpecificGate.genericOnly.note.includes("本场景") &&
      !scenarioSpecificGate.complete.enterDisabled &&
      scenarioSpecificGate.complete.note.includes("都已确认"),
      `${prefix}scenario-specific evidence does not participate in the gate (${JSON.stringify(scenarioSpecificGate)}).`
    );
    await screenshot(connection, `vertical-advanced-${name}.png`);
    const interactiveFontSizes = await evaluate(connection, fontSizeExpression());
    check(
      interactiveFontSizes.length <= 4,
      `${prefix}interactive lab uses more than four font-size levels (${JSON.stringify(interactiveFontSizes)}).`
    );
    const scenarioToolsBefore = await evaluate(connection, `(() => ({
      detailsOpen: Boolean(document.querySelector(".dse-scenario-tools")?.open),
      pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
      label: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || "",
      meta: document.querySelector(".dse-scenario-meta > span")?.textContent.trim() || ""
    }))()`);
    await clickByPointer(connection, ".dse-scenario-tools > summary");
    await clickByPointer(connection, "[data-scenario-auto-toggle]");
    const scenarioToolsManual = await evaluate(connection, `(() => ({
      pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
      label: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || "",
      checklistOpen: !document.getElementById("dse-gate-checklist")?.hidden
    }))()`);
    await clickByPointer(connection, '[data-gate-action="check"]');
    const scenarioAutoPaused = await evaluate(connection, `(() => ({
      pressed: document.querySelector("[data-scenario-auto-toggle]")?.getAttribute("aria-pressed") || "",
      label: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || "",
      summaryScore: document.getElementById("dse-gate-summary-score")?.textContent.trim() || "",
      summaryState: document.getElementById("dse-gate-summary")?.dataset.state || "",
      summaryNote: document.getElementById("dse-gate-summary-note")?.textContent.trim() || "",
      summaryLights: document.querySelectorAll(".dse-gate-summary-light").length
    }))()`);
    check(
      !scenarioToolsBefore.detailsOpen &&
      scenarioToolsBefore.pressed === "true" &&
      scenarioToolsBefore.label.includes("继续自动演示") &&
      scenarioToolsBefore.meta.includes("主动开启") &&
      scenarioToolsManual.pressed === "false" &&
      scenarioToolsManual.label.includes("暂停自动演示") &&
      !scenarioToolsManual.checklistOpen &&
      scenarioAutoPaused.pressed === "true" &&
      scenarioAutoPaused.label.includes("继续自动演示") &&
      scenarioAutoPaused.summaryScore === "0 / 5" &&
      scenarioAutoPaused.summaryState === "incomplete" &&
      scenarioAutoPaused.summaryNote.includes("还缺 5 项") &&
      scenarioAutoPaused.summaryLights === 1,
      `${prefix}scenario auto-demo is not a paused secondary tool (${JSON.stringify({
        before: scenarioToolsBefore,
        manual: scenarioToolsManual,
        paused: scenarioAutoPaused,
      })}).`
    );
    await evaluate(connection, `(async () => {
      document.querySelector('[data-demo-mode="triage"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return true;
    })()`);
    const triageCategoryInitial = await evaluate(connection, `(() => ({
      categoryCount: document.querySelectorAll("[data-triage-category]").length,
      categoryColumns: getComputedStyle(document.getElementById("dse-triage-category-grid")).gridTemplateColumns,
      caseStageHidden: Boolean(document.getElementById("dse-triage-case-stage")?.hidden),
      workflowHidden: Boolean(document.getElementById("dse-triage-workflow")?.hidden),
      autoToolsOpen: Boolean(document.querySelector(".dse-triage-tools")?.open),
      evidenceGuideOpen: Boolean(document.querySelector(".dse-triage-evidence-guide")?.open)
    }))()`);
    check(
      triageCategoryInitial.categoryCount === 6 &&
      triageCategoryInitial.categoryColumns.split(" ").filter(Boolean).length === (desktopLayout ? 3 : 1) &&
      triageCategoryInitial.caseStageHidden &&
      triageCategoryInitial.workflowHidden &&
      !triageCategoryInitial.autoToolsOpen &&
      !triageCategoryInitial.evidenceGuideOpen,
      `${prefix}triage does not start with symptom categories (${JSON.stringify(triageCategoryInitial)}).`
    );
    await screenshot(connection, `triage-categories-${name}.png`);
    await clickByPointer(connection, '[data-triage-category="performance"]');
    await clickByPointer(connection, '#dse-triage-case-grid [data-triage-case="stutter"]');
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
      triageProgressInitial.bodySize >= (desktopLayout ? 18 : 16) &&
      triageProgressInitial.actionSizes.length === 1 &&
      triageProgressInitial.actionSizes.every(size =>
        size.height === 44 &&
        size.fontSize === (desktopLayout ? 18 : 16) &&
        size.width >= 44
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
        autoToggleInDetails: Boolean(
          document.getElementById("dse-triage-auto-toggle")?.closest(".dse-triage-tools")
        ),
        autoToolsOpen: Boolean(document.querySelector(".dse-triage-tools")?.open)
      };
    })()`);
    check(
      triageStack.columns.split(" ").filter(Boolean).length === 1 &&
      triageStack.caseCount > 1 &&
      new Set(triageStack.caseTops).size === triageStack.caseTops.length &&
      !triageStack.horizontalOverflow &&
      triageStack.touchAction === "pan-y" &&
      triageStack.autoToggleInDetails &&
      !triageStack.autoToolsOpen,
      `${prefix}triage cases are not a vertical explicit-choice list (${JSON.stringify(triageStack)}).`
    );
    if (!desktopLayout) {
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
    const audioTriage = await evaluate(connection, `(async () => {
      document.querySelector('[data-triage-category="display"]')?.click();
      document.querySelector('#dse-triage-case-grid [data-triage-case="audioStutter"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const guide = document.querySelector(".dse-triage-evidence-guide");
      if (guide) guide.open = true;
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        category: document.querySelector('[data-triage-category="display"] strong')?.textContent.trim() || "",
        title: document.getElementById("dse-triage-copy-title")?.textContent.trim() || "",
        body: document.getElementById("dse-triage-copy-body")?.textContent.trim() || "",
        evidence: document.getElementById("dse-triage-evidence-state")?.textContent.trim() || "",
        caseCount: document.querySelectorAll("#dse-triage-case-grid [data-triage-case]").length,
        evidenceGuide: guide?.innerText || ""
      };
    })()`);
    check(
      audioTriage.category.includes("画面与声音") &&
      audioTriage.caseCount === 3 &&
      audioTriage.title.includes("声音路径") &&
      audioTriage.body.includes("HDMI") &&
      audioTriage.body.includes("USB") &&
      audioTriage.body.includes("根控制器") &&
      audioTriage.body.includes("供电") &&
      audioTriage.evidence.includes("USB") &&
      audioTriage.evidence.includes("NVIDIA") &&
      audioTriage.evidence.includes("尚未") &&
      audioTriage.evidenceGuide.includes("Windows Performance Analyzer") &&
      audioTriage.evidenceGuide.includes("WinDbg"),
      `${prefix}audio-stutter triage does not distinguish output paths and evidence (${JSON.stringify(audioTriage)}).`
    );
    await screenshot(connection, `triage-audio-${name}.png`);
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
      const lifecyclePresets = panel?.querySelector(".dse-lifecycle-presets");
      if (lifecyclePresets) lifecyclePresets.open = true;
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
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
          lifecycleCopy
        ].map(element => Math.round(element?.getBoundingClientRect().left || 0)),
        right: [
          lifecycleGrid,
          lifecycleCopy
        ].map(element => Math.round(element?.getBoundingClientRect().right || 0))
      };
      const gridRect = lifecycleGrid?.getBoundingClientRect();
      const eventsRect = lifecycleEvents?.getBoundingClientRect();
      const eventsContained = Boolean(
        gridRect &&
        eventsRect &&
        eventsRect.left >= gridRect.left - 1 &&
        eventsRect.right <= gridRect.right + 1
      );
      document.querySelector('[data-demo-mode="tune"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return { samples, alignment, eventsContained };
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
      spread(lifecycleStability.alignment.right) <= 1 &&
      lifecycleStability.eventsContained,
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
    await evaluate(connection, `(() => {
      const details = document.querySelector('[data-gate-action="direct"]')?.closest("details");
      if (details) details.open = true;
      return Boolean(details);
    })()`);
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
      lights: document.querySelectorAll(".dse-gate-summary-light").length,
      detailConfirmed: document.getElementById("dse-gate-detail-confirmed")?.textContent.trim() || "",
      detailUnknown: document.getElementById("dse-gate-detail-unknown")?.textContent.trim() || "",
      detailTerms: document.getElementById("dse-gate-detail-terms")?.textContent.trim() || ""
    }))()`);
    check(
      gateButtonsInitial.length === 1 &&
      gateButtonsOpen.length === 1 &&
      gateButtonsReady.length === 2 &&
      gateButtonsInitial[0].width === gateButtonsOpen[0].width &&
      gateButtonsInitial[0].height === 44 &&
      gateButtonsOpen[0].height === 44 &&
      gateButtonsReady.every(button =>
        button.height === 44 && button.fontSize === (desktopLayout ? 18 : 16)
      ) &&
      gateButtonSpread <= 1 &&
      gateSummaryReady.score === "5 / 5" &&
      gateSummaryReady.state === "ready" &&
      gateSummaryReady.note.includes("条件齐全") &&
      gateSummaryReady.lights === 1 &&
      gateSummaryReady.detailConfirmed.includes("通用条件") &&
      gateSummaryReady.detailUnknown.includes("真实") &&
      gateSummaryReady.detailTerms.includes("固定测试场景"),
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
      const detail = document.getElementById("dse-experiment-detail");
      return {
        visible: !output?.hidden,
        className: output?.className || "",
        outcome: output?.dataset.outcome || "",
        actionsVisible: !document.getElementById("dse-sim-actions")?.hidden,
        reviewEnabled: !document.getElementById("dse-open-review")?.disabled,
        detailVisible: !detail?.hidden,
        detailOpen: Boolean(detail?.open),
        detailText: [
          "dse-detail-confirmed",
          "dse-detail-unknown",
          "dse-detail-why",
          "dse-detail-terms"
        ].map(id => document.getElementById(id)?.textContent.trim() || "")
      };
    })()`);
    check(
      experimentPlan.visible &&
      experimentPlan.className.includes("demo") &&
      experimentPlan.outcome === "" &&
      !experimentPlan.actionsVisible &&
      experimentPlan.reviewEnabled &&
      experimentPlan.detailVisible &&
      !experimentPlan.detailOpen &&
      experimentPlan.detailText.every(text => text.length > 0),
      `${prefix}experiment plan appears pre-colored as a final outcome (${JSON.stringify(experimentPlan)}).`
    );
    await clickByPointer(connection, "#dse-open-review");
    const reviewReady = await evaluate(connection, `(() => ({
      panelVisible: (document.getElementById("dse-tune-review-panel")?.getBoundingClientRect().height || 0) > 0,
      emptyHidden: Boolean(document.getElementById("dse-review-empty")?.hidden),
      actionsVisible: !document.getElementById("dse-sim-actions")?.hidden,
      actionCount: document.querySelectorAll("[data-sim-result]").length,
      labels: [...document.querySelectorAll("[data-sim-result]")].map(button => button.textContent.trim()),
      label: document.getElementById("dse-review-state-label")?.textContent.trim() || "",
      choiceColumns: getComputedStyle(document.getElementById("dse-sim-actions")).gridTemplateColumns,
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
    }))()`);
    check(
      reviewReady.panelVisible &&
      reviewReady.emptyHidden &&
      reviewReady.actionsVisible &&
      reviewReady.actionCount === 4 &&
      reviewReady.labels.some(label => label.includes("没收益")) &&
      reviewReady.labels.some(label => label.includes("失败")) &&
      reviewReady.label.includes("选择") &&
      reviewReady.choiceColumns.split(" ").filter(Boolean).length === (desktopLayout ? 4 : 2) &&
      reviewReady.selected === 0 &&
      reviewReady.actionSizes.every(size =>
        size.height >= 44 &&
        size.fontSize === (desktopLayout ? 18 : 16) &&
        size.width >= 44
      ) &&
      Math.max(...reviewReady.actionSizes.map(size => size.width)) -
        Math.min(...reviewReady.actionSizes.map(size => size.width)) <= 1,
      `${prefix}result-review step is not available after the plan (${JSON.stringify(reviewReady)}).`
    );
    await screenshot(connection, `result-review-${name}.png`);
    const experimentOutcomes = await evaluate(connection, `(async () => {
      const samples = {};
      for (const outcome of ["pass", "no-benefit", "fail", "inconclusive"]) {
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
      new Set(outcomeBorders).size === 4 &&
      new Set(outcomeStatusColors).size === 4 &&
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
  const connection = await createConnection("about:blank");
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
    const connection = await createConnection("about:blank");
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
  const siteRoot = path.join(repositoryRoot, "docs", "skill-evolution");
  const { server, port } = await startServer(repositoryRoot);
  const { server: previewServer, port: previewPort } = await startServer(siteRoot);
  const siteUrl = `http://127.0.0.1:${port}/docs/skill-evolution/`;
  const previewRootUrl = `http://127.0.0.1:${previewPort}/`;
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
    await testPreviewRootReturn(previewRootUrl);
    await testInteractiveViewport(interactiveUrl, "desktop", 1440, 1000);
    await testInteractiveViewport(interactiveUrl, "compact-desktop", 1024, 768);
    await testInteractiveViewport(interactiveUrl, "tablet", 768, 1024);
    await testInteractiveViewport(interactiveUrl, "mobile", 390, 844);
    await testInteractiveViewport(interactiveUrl, "compact", 320, 740);
    await testOrrerySmoke(orreryUrl, "desktop", 1440, 1000);
    await testOrrerySmoke(orreryUrl, "mobile", 390, 844);
    await testReducedMotion(siteUrl, interactiveUrl, orreryUrl);
  } finally {
    browser.kill();
    server.close();
    previewServer.close();
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
