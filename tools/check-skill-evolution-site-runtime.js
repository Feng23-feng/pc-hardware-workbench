const fs = require("node:fs");
const http = require("node:http");
const net = require("node:net");
const os = require("node:os");
const path = require("node:path");
const { spawn } = require("node:child_process");

const repositoryRoot = path.resolve(__dirname, "..");
let debugPort = 0;
const profileDir = fs.mkdtempSync(path.join(os.tmpdir(), "pcwb-interactive-runtime-"));
const browserCandidates = [
  process.env.EDGE_PATH,
  "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
  "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe"
].filter(Boolean);
const browserPath = browserCandidates.find(candidate => fs.existsSync(candidate));
const failures = [];

function check(condition, message) {
  if (!condition) failures.push(message);
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
      // Edge is still starting.
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

async function click(connection, selector) {
  await evaluate(connection, `(async () => {
    const element = document.querySelector(${JSON.stringify(selector)});
    if (!element) throw new Error("Missing control: " + ${JSON.stringify(selector)});
    element.click();
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return true;
  })()`);
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
  await sleep(120);
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

async function navigate(connection, url) {
  await connection.send("Page.navigate", { url });
  const loaded = await waitFor(connection, `document.readyState === "complete"`, 5000);
  if (!loaded) throw new Error(`Page did not finish loading: ${url}`);
  await sleep(80);
}

async function waitFor(connection, expression, timeout = 3500) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      if (await evaluate(connection, expression)) return true;
    } catch {
      // Navigation may replace the execution context while the condition is polling.
    }
    await sleep(100);
  }
  return false;
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
      horizontalOverflow:
        document.documentElement.scrollWidth > document.documentElement.clientWidth ||
        Boolean(root && root.scrollWidth > root.clientWidth),
      title: document.title
    };
  })()`;
}

async function openAdvancedByPointer(connection) {
  const point = await evaluate(connection, `(async () => {
    const root = document.getElementById("dse-root");
    const shell = document.getElementById("dse-advanced-shell");
    const summary = shell?.querySelector(":scope > summary");
    if (!root || !shell || !summary) throw new Error("Advanced summary is missing.");
    if (shell.open) shell.open = false;
    root.style.scrollBehavior = "auto";
    shell.scrollIntoView({ block: "center" });
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    const rect = summary.getBoundingClientRect();
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
  await sleep(250);
}

async function visibleState(connection) {
  return evaluate(connection, `(() => {
    const root = document.getElementById("dse-root");
    const shell = document.getElementById("dse-advanced-shell");
    const demo = document.getElementById("dse-demo");
    const visiblePanels = [...document.querySelectorAll(".dse-demo-panel[data-demo-mode]")]
      .filter(panel => !panel.hidden && panel.getBoundingClientRect().height > 0);
    return {
      shellOpen: Boolean(shell?.open),
      demoHidden: Boolean(demo?.hidden),
      demoVisibleText: demo?.innerText.trim().length || 0,
      demoStaticText: demo?.textContent.trim().length || 0,
      visiblePanelCount: visiblePanels.length,
      visiblePanelText: visiblePanels.map(panel => panel.innerText.trim().length),
      activeMode: document.querySelector("[data-demo-mode][aria-pressed=true]")?.dataset.demoMode || "",
      currentTheme: document.getElementById("dse-advanced-current")?.textContent.trim() || "",
      progress: document.getElementById("dse-advanced-progress")?.textContent.trim() || "",
      hash: location.hash,
      overflow:
        document.documentElement.scrollWidth > document.documentElement.clientWidth ||
        root.scrollWidth > root.clientWidth
    };
  })()`);
}

async function testHomeViewport(siteUrl, name, width, height) {
  const connection = await createConnection(siteUrl);
  const prefix = `home ${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, siteUrl);

    const integrity = await evaluate(connection, integrityExpression());
    check(integrity.duplicateIds.length === 0, `${prefix}duplicate IDs: ${integrity.duplicateIds.join(", ")}`);
    check(
      integrity.brokenAriaControls.length === 0,
      `${prefix}broken aria-controls: ${integrity.brokenAriaControls.join(", ")}`
    );
    check(integrity.unnamedControls.length === 0, `${prefix}visible controls without names.`);
    check(
      integrity.brokenHashLinks.length === 0,
      `${prefix}broken same-page links: ${integrity.brokenHashLinks.join(", ")}`
    );
    check(integrity.horizontalOverflow === false, `${prefix}page has horizontal overflow.`);

    const initial = await evaluate(connection, `(() => ({
      total: document.getElementById("dse-total-count")?.textContent.trim() || "",
      workbench: document.getElementById("dse-wb-count")?.textContent.trim() || "",
      prototype: document.getElementById("dse-proto-count")?.textContent.trim() || "",
      currentSelected: document.querySelector('[data-version-id="wb-2-5-0"]')?.classList.contains("is-selected") || false,
      currentSeriesExpanded: !document.querySelector('[data-series-id="wb-2-2"] .dse-version-grid')?.hidden,
      versionCount: document.querySelectorAll(".dse-version").length
    }))()`);
    check(initial.total === "107", `${prefix}archive total is ${initial.total}, expected 107.`);
    check(initial.workbench === "91" && initial.prototype === "16", `${prefix}archive totals are inconsistent.`);
    check(initial.versionCount === 107, `${prefix}rendered ${initial.versionCount} version controls, expected 107.`);
    check(initial.currentSelected, `${prefix}version 2.5.0 is not selected initially.`);
    check(initial.currentSeriesExpanded, `${prefix}current version series starts collapsed.`);

    await clickByPointer(connection, ".dse-hero-action");
    const ctaReached = await waitFor(connection, `(() => {
      const target = document.getElementById("dse-overview-title");
      return target && target.getBoundingClientRect().top >= 0 &&
        target.getBoundingClientRect().top < 140;
    })()`, 2500);
    check(ctaReached, `${prefix}hero CTA did not reveal its target.`);
    check(
      await evaluate(connection, `location.hash === "#dse-overview-title"`),
      `${prefix}hero CTA did not update the hash.`
    );

    await navigate(connection, siteUrl);
    await click(connection, '[data-filter="prototype"]');
    const prototypeState = await evaluate(connection, `(() => ({
      trackVisible: !document.querySelector('.dse-track[data-track="prototype"]')?.hidden,
      seriesVisible: !document.querySelector('.dse-series[data-track="prototype"]')?.hidden,
      archiveVisible: !document.querySelector(".dse-archive")?.hidden,
      pressed: document.querySelector('[data-filter="prototype"]')?.getAttribute("aria-pressed") === "true"
    }))()`);
    check(prototypeState.trackVisible, `${prefix}prototype filter did not reveal its track.`);
    check(prototypeState.seriesVisible, `${prefix}prototype filter did not reveal its archive series.`);
    check(prototypeState.archiveVisible, `${prefix}prototype filter hid the version archive.`);
    check(prototypeState.pressed, `${prefix}prototype filter did not update pressed state.`);

    await click(connection, "#dse-series-toggle-proto-3");
    const collapsed = await evaluate(connection, `(() => ({
      expanded: document.getElementById("dse-series-toggle-proto-3")?.getAttribute("aria-expanded"),
      gridHidden: Boolean(document.getElementById("dse-series-grid-proto-3")?.hidden)
    }))()`);
    check(collapsed.expanded === "false" && collapsed.gridHidden, `${prefix}series collapse control failed.`);
    await click(connection, "#dse-series-toggle-proto-3");
    check(
      await evaluate(connection, `document.getElementById("dse-series-toggle-proto-3")?.getAttribute("aria-expanded") === "true"`),
      `${prefix}series expand control failed.`
    );

    const firstPrototypeVersion = await evaluate(connection, `(() => {
      const button = document.querySelector('[data-series-id="proto-3"] .dse-version');
      return button ? { id: button.dataset.versionId, label: button.textContent.trim() } : null;
    })()`);
    check(Boolean(firstPrototypeVersion?.id), `${prefix}prototype archive has no version controls.`);
    if (firstPrototypeVersion?.id) {
      await clickByPointer(connection, `[data-version-id="${firstPrototypeVersion.id}"]`);
      const versionState = await evaluate(connection, `(() => ({
        detailVisible: !document.getElementById("dse-version-detail")?.hidden,
        detailTitle: document.getElementById("dse-version-detail-title")?.textContent.trim() || "",
        hash: location.hash,
        selected: document.querySelector('[data-version-id="${firstPrototypeVersion.id}"]')?.classList.contains("is-selected") || false
      }))()`);
      check(versionState.detailVisible, `${prefix}version card did not open its detail panel.`);
      check(versionState.detailTitle.length > 8, `${prefix}version detail title is empty.`);
      check(versionState.selected, `${prefix}version card did not show a selected state.`);
      check(versionState.hash === `#${firstPrototypeVersion.id}`, `${prefix}version card did not update its route.`);

      await clickByPointer(connection, "#dse-version-detail [data-window-close]");
      const restore = await evaluate(connection, `(() => ({
        detailHidden: Boolean(document.getElementById("dse-version-detail")?.hidden),
        restoreVisible: !document.getElementById("dse-inspector-restore")?.hidden
      }))()`);
      check(restore.detailHidden && restore.restoreVisible, `${prefix}version close/restore state is incomplete.`);
      await clickByPointer(connection, "#dse-inspector-restore");
      check(
        await evaluate(connection, `!document.getElementById("dse-version-detail")?.hidden`),
        `${prefix}restore control did not reopen version details.`
      );
    }

    await click(connection, '[data-filter="triage"]');
    const triageState = await evaluate(connection, `(() => ({
      trackVisible: !document.querySelector('.dse-track[data-track="triage"]')?.hidden,
      detailVisible: !document.querySelector(".dse-detail")?.hidden,
      detailTitle: document.getElementById("dse-detail-title")?.textContent.trim() || "",
      archiveHidden: Boolean(document.querySelector(".dse-archive")?.hidden)
    }))()`);
    check(triageState.trackVisible, `${prefix}triage filter did not reveal its track.`);
    check(triageState.detailVisible && triageState.detailTitle.includes("TR-"), `${prefix}triage detail is missing.`);
    check(triageState.archiveHidden, `${prefix}triage filter left the version archive visible.`);

    await click(connection, '[data-filter="merge"]');
    const mergeState = await evaluate(connection, `(() => ({
      convergenceVisible: !document.querySelector(".dse-convergence")?.hidden,
      archiveHidden: Boolean(document.querySelector(".dse-archive")?.hidden),
      detailTitle: document.getElementById("dse-detail-title")?.textContent.trim() || "",
      detailVisible: !document.querySelector(".dse-detail")?.hidden
    }))()`);
    check(mergeState.convergenceVisible, `${prefix}merge filter did not reveal convergence content.`);
    check(mergeState.archiveHidden, `${prefix}merge filter left the archive visible.`);
    check(
      mergeState.detailVisible && mergeState.detailTitle.includes("MERGE"),
      `${prefix}merge filter did not select a merge milestone.`
    );

    await click(connection, '[data-filter="core"]');
    await clickByPointer(connection, '[data-version-id="wb-2-5-0"]');
    const currentVersion = await evaluate(connection, `(() => ({
      title: document.getElementById("dse-version-detail-title")?.textContent.trim() || "",
      date: document.getElementById("dse-version-detail-date")?.textContent.trim() || "",
      changes: [...document.querySelectorAll("#dse-version-changes li")].map(item => item.textContent.trim()),
      validation: document.getElementById("dse-version-validation")?.textContent.trim() || "",
      hash: location.hash
    }))()`);
    check(currentVersion.title.includes("2.5.0"), `${prefix}current version detail is not 2.5.0.`);
    check(currentVersion.date.length > 0, `${prefix}current version date is missing.`);
    check(currentVersion.changes.length > 0, `${prefix}current version change list is empty.`);
    check(currentVersion.validation.length > 20, `${prefix}current version validation is missing.`);
    check(currentVersion.hash === "#wb-2-5-0", `${prefix}current version deep link is not stable.`);

    await click(connection, "#dse-version-detail [data-window-toggle]");
    const versionCollapsed = await evaluate(connection, `(() => ({
      collapsed: document.getElementById("dse-version-detail")?.classList.contains("is-collapsed") || false,
      expanded: document.querySelector("#dse-version-detail [data-window-toggle]")?.getAttribute("aria-expanded")
    }))()`);
    check(
      versionCollapsed.collapsed && versionCollapsed.expanded === "false",
      `${prefix}version detail collapse control failed.`
    );
    await click(connection, "#dse-version-detail [data-window-toggle]");
    check(
      await evaluate(
        connection,
        `!document.getElementById("dse-version-detail")?.classList.contains("is-collapsed")`
      ),
      `${prefix}version detail expand control failed.`
    );

    await clickByPointer(connection, '.dse-node[data-milestone-id="core-instrumentation"]');
    const milestone = await evaluate(connection, `(() => ({
      detailVisible: !document.querySelector(".dse-detail")?.hidden,
      title: document.getElementById("dse-detail-title")?.textContent.trim() || "",
      goal: document.getElementById("dse-detail-goal")?.textContent.trim() || "",
      selected: document.querySelector('.dse-node[data-milestone-id="core-instrumentation"]')?.classList.contains("is-selected") || false
    }))()`);
    check(milestone.detailVisible && milestone.title.includes("2.5.0"), `${prefix}current milestone detail failed.`);
    check(milestone.goal.length > 20 && milestone.selected, `${prefix}current milestone content/state is incomplete.`);

    await click(connection, ".dse-detail [data-window-toggle]");
    const milestoneCollapsed = await evaluate(connection, `(() => ({
      collapsed: document.querySelector(".dse-detail")?.classList.contains("is-collapsed") || false,
      expanded: document.querySelector(".dse-detail [data-window-toggle]")?.getAttribute("aria-expanded")
    }))()`);
    check(
      milestoneCollapsed.collapsed && milestoneCollapsed.expanded === "false",
      `${prefix}milestone detail collapse control failed.`
    );
    await click(connection, ".dse-detail [data-window-toggle]");
    await click(connection, ".dse-detail [data-window-close]");
    const milestoneClosed = await evaluate(connection, `(() => ({
      hidden: Boolean(document.querySelector(".dse-detail")?.hidden),
      restoreVisible: !document.getElementById("dse-inspector-restore")?.hidden
    }))()`);
    check(
      milestoneClosed.hidden && milestoneClosed.restoreVisible,
      `${prefix}milestone close/restore state is incomplete.`
    );
    await click(connection, "#dse-inspector-restore");
    check(
      await evaluate(connection, `!document.querySelector(".dse-detail")?.hidden`),
      `${prefix}milestone restore control failed.`
    );

    await clickByPointer(connection, ".dse-candidate-details > summary");
    check(
      await evaluate(connection, `Boolean(document.querySelector(".dse-candidate-details")?.open)`),
      `${prefix}candidate details did not open.`
    );

    const currentDeepLink = `${siteUrl}#wb-2-5-0`;
    await navigate(connection, siteUrl);
    await navigate(connection, currentDeepLink);
    const deepLinkState = await evaluate(connection, `(() => ({
      detailVisible: !document.getElementById("dse-version-detail")?.hidden,
      title: document.getElementById("dse-version-detail-title")?.textContent.trim() || "",
      corePressed: document.querySelector('[data-filter="core"]')?.getAttribute("aria-pressed") === "true",
      seriesExpanded: !document.querySelector('[data-series-id="wb-2-2"] .dse-version-grid')?.hidden
    }))()`);
    check(deepLinkState.detailVisible && deepLinkState.title.includes("2.5.0"), `${prefix}version deep link did not open.`);
    check(deepLinkState.corePressed && deepLinkState.seriesExpanded, `${prefix}version deep link did not restore archive context.`);

    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testViewport(browserUrl, name, width, height, testAutoRotation) {
  const connection = await createConnection(browserUrl);
  const prefix = `${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, browserUrl);

    const initial = await visibleState(connection);
    check(initial.demoHidden === false, `${prefix}#dse-demo remains hidden before advanced mode.`);
    check(initial.demoStaticText > 500, `${prefix}#dse-demo has no static fallback content.`);
    check(initial.shellOpen === false, `${prefix}advanced details should start closed.`);
    check(initial.overflow === false, `${prefix}page has horizontal overflow before interaction.`);

    const integrity = await evaluate(connection, integrityExpression());
    check(integrity.duplicateIds.length === 0, `${prefix}duplicate IDs: ${integrity.duplicateIds.join(", ")}`);
    check(
      integrity.brokenAriaControls.length === 0,
      `${prefix}broken aria-controls: ${integrity.brokenAriaControls.join(", ")}`
    );
    check(integrity.unnamedControls.length === 0, `${prefix}visible controls without names.`);
    check(
      integrity.brokenHashLinks.length === 0,
      `${prefix}broken same-page links: ${integrity.brokenHashLinks.join(", ")}`
    );

    await openAdvancedByPointer(connection);
    const direct = await visibleState(connection);
    check(direct.shellOpen, `${prefix}real pointer click did not open advanced details.`);
    check(direct.demoHidden === false, `${prefix}#dse-demo is hidden after advanced details open.`);
    check(direct.demoVisibleText > 200, `${prefix}advanced content is empty after direct summary click.`);
    check(direct.visiblePanelCount >= 1, `${prefix}no advanced mode panel is visible after opening.`);
    check(direct.overflow === false, `${prefix}page has horizontal overflow after opening advanced mode.`);

    for (const mode of ["terms", "tune", "triage", "identity", "evidence"]) {
      await click(connection, `[data-demo-mode="${mode}"]`);
      const state = await visibleState(connection);
      check(state.activeMode === mode, `${prefix}${mode} tab is not marked active.`);
      check(state.hash === `#${mode}`, `${prefix}${mode} mode did not update the hash.`);
      check(state.visiblePanelCount >= 1, `${prefix}${mode} mode has no visible panel.`);
      check(state.visiblePanelText.some(length => length > 80), `${prefix}${mode} panel text is empty.`);
    }

    await click(connection, '[data-demo-mode="terms"]');
    const termsBefore = await evaluate(connection, `(() => ({
      coreCount: document.querySelectorAll("#dse-term-core-row [data-term-id]").length,
      branchCount: document.querySelectorAll("#dse-term-rotating-row [data-term-id]").length,
      cycle: document.getElementById("dse-term-cycle-label")?.textContent.trim() || ""
    }))()`);
    check(termsBefore.coreCount === 6, `${prefix}term core row has ${termsBefore.coreCount} items, expected 6.`);
    check(termsBefore.branchCount > 0, `${prefix}term branch row is empty.`);
    await clickByPointer(connection, "#dse-term-next");
    const termsAfter = await evaluate(connection, `(() => ({
      cycle: document.getElementById("dse-term-cycle-label")?.textContent.trim() || "",
      branchCount: document.querySelectorAll("#dse-term-rotating-row [data-term-id]").length
    }))()`);
    check(termsAfter.cycle !== termsBefore.cycle, `${prefix}term next-group control did not advance.`);
    check(termsAfter.branchCount > 0, `${prefix}term branch row disappeared after rotation.`);

    await click(connection, '[data-term-id="power-limit"]');
    const openTerm = await evaluate(connection, `(() => ({
      visible: !document.getElementById("dse-term-detail")?.hidden,
      title: document.getElementById("dse-term-detail-title")?.textContent.trim() || "",
      copyLength: document.getElementById("dse-term-detail")?.innerText.trim().length || 0,
      hash: location.hash
    }))()`);
    check(openTerm.visible && openTerm.title.includes("功耗墙"), `${prefix}term detail did not open.`);
    check(openTerm.copyLength > 100, `${prefix}term detail content is empty.`);
    check(openTerm.hash === "#term-power-limit", `${prefix}term detail did not update its deep link.`);
    await connection.send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27
    });
    await connection.send("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27
    });
    await sleep(80);
    const escapedTerm = await evaluate(connection, `(() => ({
      hidden: Boolean(document.getElementById("dse-term-detail")?.hidden),
      hash: location.hash
    }))()`);
    check(escapedTerm.hidden, `${prefix}Escape did not close the term detail.`);
    check(escapedTerm.hash === "#terms", `${prefix}closing a term did not restore the terms route.`);

    await click(connection, '[data-term-id="power-limit"]');
    await click(connection, "#dse-close-advanced");
    const closedTermShell = await evaluate(connection, `(() => ({
      shellOpen: Boolean(document.getElementById("dse-advanced-shell")?.open),
      termHidden: Boolean(document.getElementById("dse-term-detail")?.hidden),
      hash: location.hash
    }))()`);
    check(
      !closedTermShell.shellOpen && closedTermShell.termHidden && closedTermShell.hash === "",
      `${prefix}advanced close left a term deep link or open term behind.`
    );
    await openAdvancedByPointer(connection);

    await click(connection, '[data-demo-mode="identity"]');
    const lifecycleIds = await evaluate(
      connection,
      `[...document.querySelectorAll("#dse-lifecycle-events [data-lifecycle-event]")].map(button => button.dataset.lifecycleEvent)`
    );
    check(lifecycleIds.length >= 3, `${prefix}lifecycle event controls are missing.`);
    const lifecycleResults = [];
    for (const eventId of lifecycleIds) {
      await click(connection, `[data-lifecycle-event="${eventId}"]`);
      lifecycleResults.push(await evaluate(connection, `(() => ({
        title: document.getElementById("dse-lifecycle-copy-title")?.textContent.trim() || "",
        body: document.getElementById("dse-lifecycle-copy-body")?.textContent.trim() || "",
        pressed: document.querySelector('[data-lifecycle-event="${eventId}"]')?.getAttribute("aria-pressed") === "true",
        identityRail: document.getElementById("dse-identity-state-rail")?.textContent.trim() || "",
        baselineRail: document.getElementById("dse-baseline-state-rail")?.textContent.trim() || ""
      }))()`));
    }
    check(
      lifecycleResults.every(result =>
        result.pressed && result.title.length > 0 && result.body.length > 20 &&
        result.identityRail.length > 0 && result.baselineRail.length > 0
      ),
      `${prefix}one or more lifecycle events produced incomplete content.`
    );
    check(
      new Set(lifecycleResults.map(result => result.title)).size > 1,
      `${prefix}lifecycle events do not change the displayed conclusion.`
    );

    await click(connection, "#dse-advanced-reset");
    check((await visibleState(connection)).currentTheme === "安全调参", `${prefix}reset did not restore safe tuning.`);
    await click(connection, "#dse-advanced-next");
    check((await visibleState(connection)).currentTheme === "排查故障", `${prefix}advanced next control failed.`);
    await click(connection, "#dse-advanced-prev");
    check((await visibleState(connection)).currentTheme === "安全调参", `${prefix}advanced previous control failed.`);
    await click(connection, "#dse-close-advanced");
    const closed = await visibleState(connection);
    check(closed.shellOpen === false, `${prefix}advanced close control failed.`);
    check(closed.hash === "", `${prefix}advanced close left a mode hash that reopens the panel.`);

    const guided = await evaluate(connection, `(async () => {
      const select = document.getElementById("dse-guided-scenario");
      const next = document.getElementById("dse-guided-next");
      const previous = document.getElementById("dse-guided-prev");
      const reset = document.getElementById("dse-guided-reset");
      const settle = () => new Promise(resolve => (
        requestAnimationFrame(() => requestAnimationFrame(resolve))
      ));
      const readResult = () => ({
        progress: document.getElementById("dse-guided-progress")?.textContent.trim() || "",
        status: document.getElementById("dse-guided-outcome-status")?.textContent.trim() || "",
        missing: document.getElementById("dse-guided-missing")?.textContent.trim() || "",
        recommendation: document.getElementById("dse-guided-recommendation")?.textContent.trim() || "",
        action: next?.textContent.trim() || "",
        evidenceCount: document.getElementById("dse-guided-evidence-count")?.textContent.trim() || "",
        pathStates: [...document.querySelectorAll(".dse-guided-path-state")].map(node => node.textContent.trim())
      });
      const completeScenario = async scenario => {
        select.value = scenario;
        select.dispatchEvent(new Event("change", { bubbles: true }));
        await settle();
        next.click();
        await settle();
        const boxes = [...document.querySelectorAll("#dse-guided-evidence-options input")];
        if (boxes[1]) {
          boxes[1].checked = true;
          boxes[1].dispatchEvent(new Event("change", { bubbles: true }));
        }
        next.click();
        await settle();
        return readResult();
      };
      const scenarios = {};
      for (const scenario of ["temperature", "stutter", "tuning"]) {
        scenarios[scenario] = await completeScenario(scenario);
      }

      reset.click();
      await settle();
      const resetState = {
        progress: document.getElementById("dse-guided-progress")?.textContent.trim() || "",
        evidenceCount: document.getElementById("dse-guided-evidence-count")?.textContent.trim() || "",
        resultHidden: Boolean(document.getElementById("dse-guided-result-actions")?.hidden)
      };

      await completeScenario("tuning");
      document.getElementById("dse-guided-switch")?.click();
      await settle();
      const switchedState = {
        scenario: select.value,
        progress: document.getElementById("dse-guided-progress")?.textContent.trim() || "",
        resultHidden: Boolean(document.getElementById("dse-guided-result-actions")?.hidden)
      };
      const finalScenario = select.value;
      await completeScenario(finalScenario);

      previous.click();
      await settle();
      const previousProgress = document.getElementById("dse-guided-progress")?.textContent.trim() || "";
      next.click();
      await settle();

      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: {
          writeText: async value => {
            window.__pcwbCopiedPrompt = value;
          }
        }
      });
      next.click();
      await new Promise(resolve => setTimeout(resolve, 80));
      const copyLabel = next.textContent.trim();
      const prompt = String(window.__pcwbCopiedPrompt || "");
      document.getElementById("dse-guided-show-reason")?.click();
      await settle();

      const final = readResult();
      return {
        ...final,
        scenarios,
        resetState,
        switchedState,
        previousProgress,
        copiedLabel: copyLabel,
        promptHasSkill: prompt.includes("$pc-hardware-workbench"),
        promptHasSafety: prompt.includes("不要自动修改硬件"),
        reasonOpened: Boolean(document.getElementById("dse-guided-reason")?.open)
      };
    })()`);
    check(guided.progress.includes("已完成 3 步"), `${prefix}guided lab did not reach step 3.`);
    check(guided.missing.includes("缺少的证据"), `${prefix}guided result has no missing-evidence section.`);
    check(guided.recommendation.includes("推荐下一步"), `${prefix}guided result has no recommendation.`);
    check(guided.action.includes("已复制"), `${prefix}guided final copy action gave no confirmation.`);
    check(guided.pathStates.every(state => state === "已完成"), `${prefix}guided path did not complete.`);
    check(
      Object.values(guided.scenarios).every(scenario =>
        scenario.progress.includes("已完成 3 步") &&
        scenario.missing.includes("缺少的证据") &&
        scenario.recommendation.includes("推荐下一步")
      ),
      `${prefix}one or more guided scenarios produced an incomplete result.`
    );
    check(
      new Set(Object.values(guided.scenarios).map(scenario => scenario.missing)).size >= 2,
      `${prefix}guided scenarios do not produce distinct evidence guidance.`
    );
    check(
      guided.resetState.progress.includes("第 1 步") &&
      guided.resetState.evidenceCount.includes("已选 0") &&
      guided.resetState.resultHidden,
      `${prefix}guided reset did not restore the initial state.`
    );
    check(
      guided.switchedState.scenario !== "tuning" &&
      guided.switchedState.progress.includes("第 1 步") &&
      guided.switchedState.resultHidden,
      `${prefix}guided switch-scenario control failed.`
    );
    check(guided.previousProgress.includes("第 2 步"), `${prefix}guided previous control failed.`);
    check(guided.copiedLabel.includes("已复制"), `${prefix}guided copy action gave no feedback.`);
    check(
      guided.promptHasSkill && guided.promptHasSafety,
      `${prefix}guided copy action did not include the Skill and safety boundary.`
    );
    check(guided.reasonOpened, `${prefix}guided reason disclosure did not open.`);

    await click(connection, "#dse-guided-open-advanced");
    await sleep(350);
    const reopened = await visibleState(connection);
    check(reopened.shellOpen, `${prefix}guided result did not reopen advanced mode.`);
    check(reopened.currentTheme === "排查故障", `${prefix}guided result opened the wrong advanced mode.`);
    check(reopened.visiblePanelCount >= 1, `${prefix}guided-opened advanced mode is blank.`);

    await click(connection, '[data-demo-mode="tune"]');
    await click(connection, '[data-scenario="odor"]');
    const hardStop = await evaluate(connection, `(() => ({
      title: document.getElementById("dse-gate-title")?.textContent.trim() || "",
      copy: document.getElementById("dse-gate-copy")?.textContent.trim() || "",
      checkDisabled: Boolean(document.querySelector('[data-gate-action="check"]')?.disabled),
      pressed: document.querySelector('[data-scenario="odor"]')?.getAttribute("aria-pressed") === "true"
    }))()`);
    check(
      hardStop.title.includes("先停") && hardStop.copy.length > 20 && hardStop.checkDisabled && hardStop.pressed,
      `${prefix}physical-hard-stop scenario did not block the tuning gate.`
    );
    const scenarioBeforeRotate = await evaluate(connection, `(() => ({
      request: document.getElementById("dse-gate-request")?.textContent.trim() || ""
    }))()`);
    await click(connection, '[data-scenario-rotate]');
    const scenarioAfterRotate = await evaluate(connection, `(() => ({
      request: document.getElementById("dse-gate-request")?.textContent.trim() || "",
      toggle: document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim() || ""
    }))()`);
    check(
      scenarioAfterRotate.request !== scenarioBeforeRotate.request &&
      scenarioAfterRotate.toggle.includes("继续"),
      `${prefix}scenario rotate/pause controls failed.`
    );
    await click(connection, "[data-scenario-auto-toggle]");
    check(
      await evaluate(
        connection,
        `document.querySelector("[data-scenario-auto-toggle]")?.textContent.trim().includes("暂停")`
      ),
      `${prefix}scenario resume control failed.`
    );

    const forms = await evaluate(connection, `(async () => {
      const component = document.getElementById("dse-demo-component");
      const route = document.getElementById("dse-demo-route");
      const alternateComponent = [...component.options].find(option => option.value !== component.value);
      if (alternateComponent) {
        component.value = alternateComponent.value;
        component.dispatchEvent(new Event("change", { bubbles: true }));
      }
      const workload = document.getElementById("dse-demo-workload");
      workload.value = "可重复基准测试";
      workload.dispatchEvent(new Event("change", { bubbles: true }));
      document.querySelector('[data-gate-action="check"]')?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      const checklistVisible = !document.getElementById("dse-gate-checklist").hidden;
      const checks = [...document.querySelectorAll("[data-gate-check]")];
      checks.forEach(input => {
        input.checked = true;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      });
      const enabled = !document.getElementById("dse-enter-experiment").disabled;
      document.getElementById("dse-enter-experiment")?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      document.getElementById("dse-generate-experiment")?.click();
      await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
      return {
        checklistVisible,
        checkedCount: checks.filter(input => input.checked).length,
        enabled,
        workload: workload.value,
        component: component.value,
        routeCount: route.options.length,
        routeContext: document.getElementById("dse-route-context")?.textContent.trim() || "",
        resultVisible: !document.getElementById("dse-experiment-output").hidden,
        resultText: document.getElementById("dse-experiment-output")?.innerText.trim().length || 0,
        simulationVisible: !document.getElementById("dse-sim-actions").hidden
      };
    })()`);
    check(forms.checklistVisible, `${prefix}tuning checklist did not open.`);
    check(forms.checkedCount === 5 && forms.enabled, `${prefix}five evidence checks did not unlock the experiment.`);
    check(forms.workload === "可重复基准测试", `${prefix}workload selector failed.`);
    check(forms.routeCount > 0 && forms.routeContext.startsWith("·"), `${prefix}component route selector failed.`);
    check(forms.resultVisible && forms.resultText > 100, `${prefix}generated experiment result is empty.`);
    check(forms.simulationVisible, `${prefix}generated experiment did not offer result simulation.`);

    const simulationResults = [];
    for (const result of ["pass", "fail", "inconclusive"]) {
      await click(connection, `[data-sim-result="${result}"]`);
      simulationResults.push(await evaluate(connection, `(() => ({
        output: document.getElementById("dse-sim-outcome")?.textContent.trim() || "",
        state: document.getElementById("dse-experiment-state-label")?.textContent.trim() || "",
        visible: !document.getElementById("dse-sim-outcome")?.hidden
      }))()`));
    }
    check(
      simulationResults.every(result => result.visible && result.output.length > 20 && result.state.length > 0),
      `${prefix}one or more simulated outcomes are incomplete.`
    );
    check(
      new Set(simulationResults.map(result => result.output)).size === 3,
      `${prefix}simulated outcomes do not produce distinct next-step guidance.`
    );

    await clickByPointer(connection, ".dse-secondary-actions > summary");
    await click(connection, '[data-gate-action="rules"]');
    const gateRules = await evaluate(connection, `(() => ({
      visible: !document.getElementById("dse-gate-rules")?.hidden,
      expanded: document.querySelector('[data-gate-action="rules"]')?.getAttribute("aria-expanded") === "true",
      text: document.getElementById("dse-gate-rules")?.innerText.trim().length || 0
    }))()`);
    check(gateRules.visible && gateRules.expanded && gateRules.text > 50, `${prefix}gate explanation control failed.`);
    await click(connection, '[data-gate-action="direct"]');
    const directParameterRequest = await evaluate(connection, `(() => ({
      title: document.getElementById("dse-gate-title")?.textContent.trim() || "",
      enterDisabled: Boolean(document.getElementById("dse-enter-experiment")?.disabled),
      outputHidden: Boolean(document.getElementById("dse-experiment-output")?.hidden)
    }))()`);
    check(
      directParameterRequest.title.includes("信息") &&
      directParameterRequest.enterDisabled &&
      directParameterRequest.outputHidden,
      `${prefix}direct-parameter refusal path is incomplete.`
    );

    await click(connection, '[data-tune-step-link="compare"]');
    const compareCurrent = await waitFor(connection, `(() => {
      const link = document.querySelector('[data-tune-step-link="compare"]');
      const target = document.getElementById("dse-tune-compare-panel");
      return link?.getAttribute("aria-current") === "step" &&
        target && target.getBoundingClientRect().bottom > 52 &&
        target.getBoundingClientRect().top < window.innerHeight;
    })()`, 2500);
    const compareStepState = await evaluate(connection, `(() => ({
      current: document.querySelector('[data-tune-step-link="compare"]')?.getAttribute("aria-current") || "",
      targetTop: Math.round(document.getElementById("dse-tune-compare-panel")?.getBoundingClientRect().top || 0),
      targetBottom: Math.round(document.getElementById("dse-tune-compare-panel")?.getBoundingClientRect().bottom || 0),
      viewportHeight: window.innerHeight
    }))()`);
    check(
      compareCurrent,
      `${prefix}tune step navigation did not mark the compare step current (${JSON.stringify(compareStepState)}).`
    );
    await click(connection, '[data-tune-step-link="experiment"]');
    const experimentCurrent = await waitFor(connection, `(() => {
      const link = document.querySelector('[data-tune-step-link="experiment"]');
      const target = document.getElementById("dse-tune-experiment-panel");
      return link?.getAttribute("aria-current") === "step" &&
        target && target.getBoundingClientRect().bottom > 52 &&
        target.getBoundingClientRect().top < window.innerHeight;
    })()`, 2500);
    const experimentStepState = await evaluate(connection, `(() => ({
      current: document.querySelector('[data-tune-step-link="experiment"]')?.getAttribute("aria-current") || "",
      targetTop: Math.round(document.getElementById("dse-tune-experiment-panel")?.getBoundingClientRect().top || 0),
      targetBottom: Math.round(document.getElementById("dse-tune-experiment-panel")?.getBoundingClientRect().bottom || 0),
      viewportHeight: window.innerHeight
    }))()`);
    check(
      experimentCurrent,
      `${prefix}tune step navigation did not mark the experiment step current (${JSON.stringify(experimentStepState)}).`
    );

    await click(connection, '[data-demo-mode="triage"]');
    const triageBefore = await evaluate(connection, `(() => ({
      active: [...document.querySelectorAll("#dse-triage-case-grid .dse-scenario")]
        .find(button => button.getAttribute("aria-pressed") === "true")?.textContent.trim() || "",
      text: document.getElementById("dse-triage-copy")?.innerText.trim().length || 0
    }))()`);
    check(triageBefore.active.length > 0 && triageBefore.text > 20, `${prefix}triage panel has no active scenario content.`);
    if (testAutoRotation) {
      await sleep(8300);
      const triageAfter = await evaluate(connection, `(() => ({
        active: [...document.querySelectorAll("#dse-triage-case-grid .dse-scenario")]
          .find(button => button.getAttribute("aria-pressed") === "true")?.textContent.trim() || ""
      }))()`);
      check(triageAfter.active !== triageBefore.active, `${prefix}triage auto rotation did not advance.`);
    }
    await click(connection, "#dse-triage-auto-toggle");
    const pausedText = await evaluate(connection, "document.getElementById('dse-triage-auto-toggle')?.textContent.trim() || ''");
    check(pausedText.includes("继续"), `${prefix}triage pause control has no feedback.`);
    await click(connection, "#dse-triage-reset");
    const resetLabel = await evaluate(connection, "document.getElementById('dse-triage-state-label')?.textContent.trim() || ''");
    check(resetLabel.includes("安全范围"), `${prefix}triage reset did not return to the first stage.`);

    await click(connection, '[data-triage-case="hazard"]');
    const triageHazard = await evaluate(connection, `(() => ({
      label: document.getElementById("dse-triage-state-label")?.textContent.trim() || "",
      copy: document.getElementById("dse-triage-copy")?.textContent.trim() || "",
      advanceDisabled: Boolean(document.getElementById("dse-triage-advance")?.disabled),
      pressed: document.querySelector('[data-triage-case="hazard"]')?.getAttribute("aria-pressed") === "true"
    }))()`);
    check(
      triageHazard.label.includes("先停") &&
      triageHazard.copy.length > 20 &&
      triageHazard.advanceDisabled &&
      triageHazard.pressed,
      `${prefix}triage physical-hazard path did not stop the flow.`
    );

    await click(connection, '[data-triage-case="stutter"]');
    const triageCopyBefore = await evaluate(
      connection,
      "document.getElementById('dse-triage-copy')?.innerText.trim() || ''"
    );
    await click(connection, "#dse-triage-advance");
    const triageAdvanced = await evaluate(connection, `(() => ({
      label: document.getElementById("dse-triage-state-label")?.textContent.trim() || "",
      copy: document.getElementById("dse-triage-copy")?.innerText.trim() || "",
      advanceDisabled: Boolean(document.getElementById("dse-triage-advance")?.disabled)
    }))()`);
    check(
      triageAdvanced.label.includes("补充") &&
      triageAdvanced.copy !== triageCopyBefore &&
      !triageAdvanced.advanceDisabled,
      `${prefix}triage advance control failed.`
    );
    await click(connection, "#dse-triage-reset");

    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testDirectRoutes(siteUrl, interactiveUrl, name, width, height) {
  const connection = await createConnection(`${siteUrl}#evidence`);
  const prefix = `direct ${name}: `;
  try {
    await setViewport(connection, width, height);
    await navigate(connection, `${siteUrl}#evidence`);
    const homeRedirected = await waitFor(
      connection,
      `location.pathname.endsWith("/interactive/")`,
      3500
    );
    const homeRedirectState = await evaluate(connection, `(() => ({
      pathname: location.pathname,
      hash: location.hash,
      shellOpen: Boolean(document.getElementById("dse-advanced-shell")?.open),
      activeMode: document.querySelector("[data-demo-mode][aria-pressed=true]")?.dataset.demoMode || ""
    }))()`);
    check(
      homeRedirected && homeRedirectState.shellOpen && homeRedirectState.activeMode === "evidence",
      `${prefix}home #evidence route did not transfer to visible evidence content (${JSON.stringify(homeRedirectState)}).`
    );

    await navigate(connection, `${interactiveUrl}#evidence`);
    const evidence = await visibleState(connection);
    check(evidence.shellOpen, `${prefix}#evidence did not open advanced mode.`);
    check(evidence.activeMode === "evidence", `${prefix}#evidence selected the wrong mode.`);
    check(evidence.visiblePanelCount >= 1 && evidence.demoVisibleText > 200, `${prefix}#evidence is blank.`);
    check(evidence.overflow === false, `${prefix}#evidence has horizontal overflow.`);

    await navigate(connection, `${interactiveUrl}#term-vf-curve`);
    const term = await evaluate(connection, `(() => ({
      shellOpen: Boolean(document.getElementById("dse-advanced-shell")?.open),
      activeMode: document.querySelector("[data-demo-mode][aria-pressed=true]")?.dataset.demoMode || "",
      detailVisible: !document.getElementById("dse-term-detail")?.hidden,
      title: document.getElementById("dse-term-detail-title")?.textContent.trim() || "",
      copyLength: document.getElementById("dse-term-detail")?.innerText.trim().length || 0,
      hash: location.hash
    }))()`);
    check(term.shellOpen && term.activeMode === "terms", `${prefix}term deep link did not open the term lab.`);
    check(
      term.detailVisible && term.title.includes("V/F") && term.copyLength > 100,
      `${prefix}term deep link has no visible explanation.`
    );
    check(term.hash === "#term-vf-curve", `${prefix}term deep link changed its route unexpectedly.`);
    await clickAllowingNavigation(connection, '.dse-global-nav a[href="../"]');
    const returnedHome = await waitFor(
      connection,
      `document.title.startsWith("pc-hardware-workbench") && !document.getElementById("dse-advanced-shell")`,
      3500
    );
    check(returnedHome, `${prefix}global return link did not reach the project home.`);
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
      title: document.title,
      categoryCount: document.querySelectorAll(".category-node").length,
      dossierText: document.getElementById("dossier")?.innerText.trim().length || 0,
      motionPressed: document.getElementById("motionToggle")?.getAttribute("aria-pressed") || "",
      motionLabel: document.getElementById("motionToggle")?.textContent.trim() || "",
      zoom: document.getElementById("cameraZoomLabel")?.textContent.trim() || ""
    }))()`);
    check(initial.title.includes("2.5.0"), `${prefix}page title does not identify the current snapshot.`);
    check(initial.categoryCount === 7, `${prefix}expected 7 category nodes, found ${initial.categoryCount}.`);
    check(initial.dossierText > 80, `${prefix}overview dossier is empty.`);
    check(initial.motionPressed === "false" && initial.motionLabel.length > 0, `${prefix}motion control is mislabeled.`);
    check(initial.zoom === "100", `${prefix}camera does not start at 100.`);

    await clickByPointer(connection, ".category-node.is-core");
    const groupOpened = await waitFor(connection, "document.querySelectorAll('.file-node').length > 0", 2500);
    const groupState = await evaluate(connection, `(() => ({
      fileCount: document.querySelectorAll(".file-node").length,
      dossierText: document.getElementById("dossier")?.innerText.trim().length || 0,
      breadcrumb: document.getElementById("breadcrumb")?.innerText.trim() || ""
    }))()`);
    check(groupOpened && groupState.fileCount > 0, `${prefix}category click did not reveal files.`);
    check(groupState.dossierText > 50 && groupState.breadcrumb.length > 0, `${prefix}category dossier is incomplete.`);

    await click(connection, ".file-node");
    const fileState = await evaluate(connection, `(() => ({
      selected: Boolean(document.querySelector(".file-node.is-active")),
      related: document.querySelectorAll(".file-node.is-related").length,
      dossierText: document.getElementById("dossier")?.innerText.trim().length || 0,
      resetVisible: document.getElementById("selectionReset")?.classList.contains("is-visible") || false,
      selectionClass: document.getElementById("stage")?.classList.contains("has-file-selection") || false
    }))()`);
    check(fileState.selected, `${prefix}file click did not select a file.`);
    check(fileState.dossierText > 80, `${prefix}selected file dossier is empty.`);
    check(fileState.resetVisible && fileState.selectionClass, `${prefix}file selection reset state is not exposed.`);

    await connection.send("Input.dispatchKeyEvent", {
      type: "keyDown",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27
    });
    await connection.send("Input.dispatchKeyEvent", {
      type: "keyUp",
      key: "Escape",
      code: "Escape",
      windowsVirtualKeyCode: 27
    });
    await sleep(80);
    const escFiltered = await evaluate(connection, `(() => ({
      selected: Boolean(document.querySelector(".file-node.is-active")),
      selectionClass: document.getElementById("stage")?.classList.contains("has-file-selection") || false
    }))()`);
    check(
      !escFiltered.selected && !escFiltered.selectionClass,
      `${prefix}Escape did not clear the selected file.`
    );
    await click(connection, ".file-node");

    await click(connection, "#motionToggle");
    const motionOn = await evaluate(connection, `(() => ({
      pressed: document.getElementById("motionToggle")?.getAttribute("aria-pressed"),
      label: document.getElementById("motionToggle")?.textContent.trim() || ""
    }))()`);
    check(motionOn.pressed === "true" && motionOn.label.includes("停止"), `${prefix}motion toggle failed.`);
    await click(connection, "#motionToggle");
    check(
      await evaluate(connection, `document.getElementById("motionToggle")?.getAttribute("aria-pressed") === "false"`),
      `${prefix}motion toggle did not restore its off state.`
    );

    await click(connection, "#zoomIn");
    const zoomed = await evaluate(connection, "Number(document.getElementById('cameraZoomLabel')?.textContent || 0)");
    check(zoomed > 100, `${prefix}zoom-in control did not change the camera.`);
    await click(connection, "#zoomOut");
    const zoomedOut = await evaluate(connection, "Number(document.getElementById('cameraZoomLabel')?.textContent || 0)");
    check(zoomedOut < zoomed, `${prefix}zoom-out control did not change the camera.`);
    await click(connection, "#zoomReset");
    check(
      await evaluate(connection, `document.getElementById("cameraZoomLabel")?.textContent.trim() === "100"`),
      `${prefix}zoom reset control failed.`
    );

    await click(connection, "#selectionReset");
    const cleared = await evaluate(connection, `(() => ({
      selected: Boolean(document.querySelector(".file-node.is-active")),
      selectionClass: document.getElementById("stage")?.classList.contains("has-file-selection") || false,
      resetVisible: document.getElementById("selectionReset")?.classList.contains("is-visible") || false
    }))()`);
    check(
      !cleared.selected && !cleared.selectionClass && !cleared.resetVisible,
      `${prefix}selection reset did not clear file highlights.`
    );

    await click(connection, "#backButton");
    check(
      await waitFor(connection, "document.querySelectorAll('.category-node').length === 7", 1500),
      `${prefix}back control did not restore the galaxy overview.`
    );
    await clickAllowingNavigation(connection, '.global-nav a[href="../"]');
    const returnedHome = await waitFor(
      connection,
      `document.title.startsWith("pc-hardware-workbench") && !document.getElementById("stage")`,
      3500
    );
    check(returnedHome, `${prefix}global return link did not reach the project home.`);
    check(connection.pageErrors.length === 0, `${prefix}page errors: ${connection.pageErrors.join(" | ")}`);
  } finally {
    connection.close();
    await fetch(`http://127.0.0.1:${debugPort}/json/close/${connection.targetId}`).catch(() => {});
  }
}

async function testReducedMotion(siteUrl, interactiveUrl, orreryUrl) {
  const pages = [
    { name: "home", url: siteUrl },
    { name: "interactive", url: interactiveUrl },
    { name: "orrery", url: orreryUrl }
  ];
  for (const page of pages) {
    const connection = await createConnection(page.url);
    const prefix = `reduced motion ${page.name}: `;
    try {
      await setViewport(connection, 390, 844);
      await connection.send("Emulation.setEmulatedMedia", {
        media: "screen",
        features: [{ name: "prefers-reduced-motion", value: "reduce" }]
      });
      await navigate(connection, page.url);
      const initial = await evaluate(connection, `(() => ({
        matches: matchMedia("(prefers-reduced-motion: reduce)").matches,
        h1Text: document.querySelector("h1")?.textContent.trim() || "",
        h1Opacity: Number(getComputedStyle(document.querySelector("h1")).opacity),
        enterClass: document.documentElement.classList.contains("dse-hero-enter"),
        runningAnimations: document.getAnimations()
          .filter(animation => animation.playState === "running")
          .length,
        overflow: (() => {
          const root = document.getElementById("dse-root");
          return document.documentElement.scrollWidth > document.documentElement.clientWidth ||
            Boolean(root && root.scrollWidth > root.clientWidth);
        })()
      }))()`);
      check(initial.matches, `${prefix}reduced-motion media query did not apply.`);
      check(initial.h1Text.length > 0 && initial.h1Opacity > .9, `${prefix}heading is not immediately visible.`);
      check(initial.overflow === false, `${prefix}page has horizontal overflow.`);
      if (page.name === "home") {
        check(!initial.enterClass, `${prefix}home entrance animation still runs.`);
      } else {
        check(initial.runningAnimations === 0, `${prefix}${initial.runningAnimations} animations still run.`);
      }

      if (page.name === "interactive") {
        await openAdvancedByPointer(connection);
        const advanced = await visibleState(connection);
        check(advanced.shellOpen && advanced.demoVisibleText > 200, `${prefix}advanced content is unavailable.`);
      }
      if (page.name === "orrery") {
        const motion = await evaluate(connection, `(() => ({
          pressed: document.getElementById("motionToggle")?.getAttribute("aria-pressed"),
          label: document.getElementById("motionToggle")?.textContent.trim() || ""
        }))()`);
        check(motion.pressed === "false" && motion.label.includes("自动"), `${prefix}motion control is not in its reduced state.`);
      }
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
    await testViewport(interactiveUrl, "desktop", 1440, 1000, true);
    await testViewport(interactiveUrl, "mobile", 390, 844, false);
    await testDirectRoutes(siteUrl, interactiveUrl, "desktop", 1440, 1000);
    await testDirectRoutes(siteUrl, interactiveUrl, "mobile", 390, 844);
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
  console.log("Skill evolution runtime regression: PASS (home, interactive, orrery; desktop and mobile)");
}

main().catch(error => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
