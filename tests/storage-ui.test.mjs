import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  launchPchwBrowserPage,
} from "../scripts/pchw-browser-evidence.mjs";

const root = resolve(import.meta.dirname, "..");
const serverEntry = process.env.STORAGE_SERVER_ENTRY
  ? resolve(process.env.STORAGE_SERVER_ENTRY)
  : join(root, "server.mjs");
const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-storage-ui-"));
const localRoot = join(tempRoot, "SkillDock");
const runtimeDir = join(localRoot, "runtime-pchw");
const runtimeProgram = join(localRoot, "Runtime-current");
const backupRoot = join(tempRoot, "SkillDockBackups", "runtime");
const activeEngine = join(
  localRoot,
  "engines",
  "node-24.22.1-0123456789abcdef",
);
const protectedBackup = join(
  backupRoot,
  "Runtime-previous-backup-20261120-120000",
);
const obsoleteBackup = join(
  backupRoot,
  "Runtime-old-backup-20261119-120000",
);
const installLogsRoot = join(localRoot, "install-logs");
const evidenceDir = process.env.STORAGE_UI_EVIDENCE_DIR
  ? resolve(process.env.STORAGE_UI_EVIDENCE_DIR)
  : "";
const port = await new Promise((resolvePromise, rejectPromise) => {
  const server = createTcpServer();
  server.unref();
  server.once("error", rejectPromise);
  server.listen(0, "127.0.0.1", () => {
    const address = server.address();
    const selectedPort =
      address && typeof address === "object" ? address.port : null;
    server.close((error) => {
      if (error) rejectPromise(error);
      else resolvePromise(selectedPort);
    });
  });
});
const base = `http://127.0.0.1:${port}`;

async function writeSizedFile(path, bytes, fill) {
  await writeFile(path, Buffer.alloc(bytes, fill));
}

async function writeEngineReference(
  runtimeDirectory,
  engineId,
  nodePath,
  nodeSha256,
) {
  await mkdir(runtimeDirectory, { recursive: true });
  await writeFile(
    join(runtimeDirectory, "engine-location.json"),
    `${JSON.stringify({
      schema_version: "1.0",
      engine_id: engineId,
      node_path: nodePath,
      node_sha256: nodeSha256,
    })}\n`,
    "utf8",
  );
}

await Promise.all([
  mkdir(join(runtimeDir, "tasks"), { recursive: true }),
  mkdir(join(runtimeDir, "attachments"), { recursive: true }),
  mkdir(join(runtimeDir, "artifacts"), { recursive: true }),
  mkdir(runtimeProgram, { recursive: true }),
  mkdir(activeEngine, { recursive: true }),
  mkdir(protectedBackup, { recursive: true }),
  mkdir(obsoleteBackup, { recursive: true }),
  mkdir(installLogsRoot, { recursive: true }),
]);
await Promise.all([
  writeSizedFile(join(runtimeProgram, "SkillDock.exe"), 4096, "r"),
  writeSizedFile(join(activeEngine, "node.exe"), 16_384, "n"),
  writeSizedFile(join(runtimeDir, "tasks", "task.json"), 512, "t"),
  writeSizedFile(join(runtimeDir, "attachments", "sample.csv"), 1024, "a"),
  writeSizedFile(join(runtimeDir, "artifacts", "chart.svg"), 2048, "s"),
  writeSizedFile(join(protectedBackup, "app.bin"), 1024, "p"),
  writeSizedFile(join(obsoleteBackup, "app.bin"), 2048, "o"),
  writeSizedFile(join(installLogsRoot, "install.log"), 512, "l"),
]);
const engineDigest = createHash("sha256")
  .update(await readFile(join(activeEngine, "node.exe")))
  .digest("hex");
await Promise.all([
  writeEngineReference(
    runtimeProgram,
    "node-24.22.1-0123456789abcdef",
    join(activeEngine, "node.exe"),
    engineDigest,
  ),
  writeEngineReference(
    protectedBackup,
    "node-24.22.1-0123456789abcdef",
    join(activeEngine, "node.exe"),
    engineDigest,
  ),
]);
await writeFile(
  join(localRoot, "runtime-location.json"),
  `${JSON.stringify({
    runtime_path: join(runtimeProgram, "SkillDock.exe"),
    previous_runtime_backup_path: protectedBackup,
    backup_root: backupRoot,
  })}\n`,
  "utf8",
);
if (evidenceDir) {
  await mkdir(evidenceDir, { recursive: true });
}

const child = spawn(process.execPath, [serverEntry], {
  cwd: root,
  windowsHide: true,
  env: {
    ...process.env,
    PANEL_AGENT_DRIVER: process.env.STORAGE_AGENT_DRIVER ?? "mock",
    PANEL_PORT: String(port),
    PANEL_RUNTIME_DIR: runtimeDir,
    PANEL_AGENT_WORKSPACE: root,
    PANEL_SOURCE_HOSTED_ENTRY:
      process.env.STORAGE_AGENT_DRIVER === "source-external" ? "1" : "",
    PANEL_SOURCE_HOSTED_NON_MOCK:
      process.env.STORAGE_AGENT_DRIVER === "source-external" ? "1" : "",
    PANEL_SKILL_ID: "pc-hardware-workbench",
    PANEL_SKILL_MANIFEST: join(
      root,
      "skills",
      "pc-hardware-workbench",
      "workbench.manifest.json",
    ),
    SKILLDOCK_LOCAL_ROOT: localRoot,
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let stderr = "";
child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

async function waitForHealth() {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (child.exitCode !== null) {
      throw new Error(`storage UI server exited early\n${stderr}`);
    }
    try {
      const response = await fetch(`${base}/api/health`);
      if (response.ok) return;
    } catch {
      // Listener is still starting.
    }
    await new Promise((resolvePromise) =>
      setTimeout(resolvePromise, 100)
    );
  }
  throw new Error(`storage UI server health timeout\n${stderr}`);
}

async function evaluate(cdp, expression) {
  const result = await cdp.send("Runtime.evaluate", {
    expression,
    awaitPromise: true,
    returnByValue: true,
  });
  if (result.exceptionDetails) {
    throw new Error(result.exceptionDetails.text);
  }
  return result.result.value;
}

async function waitFor(cdp, expression, message) {
  let lastValue = null;
  for (let attempt = 0; attempt < 120; attempt += 1) {
    lastValue = await evaluate(cdp, expression);
    if (lastValue) return;
    await new Promise((resolvePromise) =>
      setTimeout(resolvePromise, 100)
    );
  }
  const diagnostic = await evaluate(
    cdp,
    `(() => ({
      value: ${JSON.stringify(lastValue)},
      dialogOpen: Boolean(document.querySelector("#storage-dialog")?.open),
      content: document.querySelector("#storage-content")?.innerText ?? "",
      runtimeStatus: document.querySelector("#runtime-status")?.textContent ?? "",
      bodyText: document.body.innerText.slice(0, 2000),
    }))()`,
  );
  throw new Error(`${message}\n${JSON.stringify(diagnostic)}`);
}

let browser;
try {
  await waitForHealth();
  const panelToken = (
    await readFile(join(runtimeDir, "capability-token"), "utf8")
  ).trim();
  browser = await launchPchwBrowserPage({
    baseUrl: base,
    panelToken,
    profileRoot: tempRoot,
  });
  await waitFor(
    browser.cdp,
    `Boolean(
      document.querySelector("#storage-open-button") &&
      document.querySelector(".workspace-grid") &&
      document.querySelector("#runtime-binding")
    )`,
    "main panel did not finish booting",
  );
  await evaluate(
    browser.cdp,
    `document.querySelector("#storage-open-button").click()`,
  );
  await waitFor(
    browser.cdp,
    `(() => {
      const dialog = document.querySelector("#storage-dialog");
      return Boolean(dialog?.open) &&
        document.querySelector(".storage-total strong")?.textContent?.trim();
    })()`,
    "storage dialog did not load",
  );

  const desktop = await evaluate(
    browser.cdp,
    `(() => {
      const dialog = document.querySelector("#storage-dialog");
      const content = document.querySelector("#storage-content");
      const meter = document.querySelector(".storage-meter");
      return {
        dialogOpen: dialog.open,
        total: document.querySelector(".storage-total strong").textContent.trim(),
        rowCount: document.querySelectorAll(".storage-row").length,
        cleanupButton: [...dialog.querySelectorAll("button")]
          .some((button) => button.textContent.includes("选择清理旧备份")),
        horizontalOverflow: content.scrollWidth > content.clientWidth,
        dialogOverflow: dialog.scrollWidth > dialog.clientWidth,
        hasNullText: content.textContent.includes("null"),
        firstMeterValue: Number(meter?.value ?? 0),
        firstMeterWidth: meter?.getBoundingClientRect().width ?? 0,
        cleanupBeforeRows:
          document.querySelector(".storage-cleanup")
            .getBoundingClientRect().top <
          document.querySelector(".storage-row")
            .getBoundingClientRect().top,
      };
    })()`,
  );
  assert.equal(desktop.dialogOpen, true);
  assert.match(desktop.total, /\d/u);
  assert.equal(desktop.rowCount, 11);
  assert.equal(desktop.cleanupButton, true);
  assert.equal(desktop.horizontalOverflow, false);
  assert.equal(desktop.dialogOverflow, false);
  assert.equal(desktop.hasNullText, false);
  assert.ok(
    desktop.firstMeterValue > 0 && desktop.firstMeterValue < 50,
    `unexpected storage bar ratio: ${JSON.stringify(desktop)}`,
  );
  assert.ok(desktop.firstMeterWidth > 0);
  assert.equal(desktop.cleanupBeforeRows, true);

  await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  if (evidenceDir) {
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidenceDir, "storage-dialog-desktop.png"),
      Buffer.from(screenshot.data, "base64"),
    );
  }

  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll("#storage-dialog button")]
      .find((button) => button.textContent.includes("导出最近回退备份")).click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-export-link")?.textContent?.includes(
      "下载最近回退备份"
    )`,
    "runtime backup export link did not render",
  );

  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll("#storage-dialog button")]
      .find((button) => button.textContent.includes("选择清理旧备份")).click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-confirm h3")?.textContent === "确认清理旧备份"`,
    "storage confirmation did not render",
  );
  if (evidenceDir) {
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidenceDir, "storage-dialog-confirm.png"),
      Buffer.from(screenshot.data, "base64"),
    );
  }
  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll(".storage-confirm button")]
      .find((button) => button.textContent === "取消").click()`,
  );
  await waitFor(
    browser.cdp,
    `!document.querySelector(".storage-confirm") &&
      Boolean(document.querySelector(".storage-cleanup"))`,
    "storage confirmation did not cancel",
  );

  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll("#storage-dialog button")]
      .find((button) => button.textContent.includes("选择清理旧备份")).click()`,
  );
  await waitFor(
    browser.cdp,
    `Boolean(document.querySelector(".storage-confirm"))`,
    "storage confirmation did not reopen",
  );
  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll(".storage-confirm button")]
      .find((button) => button.textContent === "确认清理").click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-message")?.textContent?.includes("已清理")`,
    "storage cleanup result did not render",
  );
  assert.equal((await stat(protectedBackup)).isDirectory(), true);
  await assert.rejects(() => stat(obsoleteBackup), { code: "ENOENT" });

  await waitFor(
    browser.cdp,
    `[...document.querySelectorAll("#storage-dialog button")]
      .some((button) => button.textContent.includes("选择清理安装日志"))`,
    "install log cleanup action did not render",
  );
  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll("#storage-dialog button")]
      .find((button) => button.textContent.includes("选择清理安装日志")).click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-install-confirm h3")?.textContent ===
      "确认清理安装日志"`,
    "install log confirmation did not render",
  );
  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll(".storage-install-confirm button")]
      .find((button) => button.textContent === "确认清理日志").click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-message")?.textContent?.includes("安装日志")`,
    "install log cleanup result did not render",
  );
  await assert.rejects(() => stat(installLogsRoot), { code: "ENOENT" });

  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll("#storage-dialog button")]
      .find((button) => button.textContent.includes("生成 Task 数据导出")).click()`,
  );
  await waitFor(
    browser.cdp,
    `[...document.querySelectorAll(".storage-export-link")]
      .some((link) => link.textContent.includes("下载当前 Task 导出"))`,
    "Task export link did not render",
  );
  await evaluate(
    browser.cdp,
    `document.querySelector(".storage-task-danger")
      ?.scrollIntoView({ block: "start" })`,
  );
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
  if (evidenceDir) {
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidenceDir, "storage-task-export.png"),
      Buffer.from(screenshot.data, "base64"),
    );
  }
  const acknowledgementInitiallyDisabled = await evaluate(
    browser.cdp,
    `document.querySelector("#storage-task-export-ack").disabled`,
  );
  assert.equal(acknowledgementInitiallyDisabled, true);
  await evaluate(
    browser.cdp,
    `(() => {
      const link = [...document.querySelectorAll(".storage-export-link")]
        .find((item) => item.textContent.includes("下载当前 Task 导出"));
      link.addEventListener("click", (event) => event.preventDefault(), {
        once: true,
      });
      link.click();
    })()`,
  );
  await waitFor(
    browser.cdp,
    `!document.querySelector("#storage-task-export-ack").disabled`,
    "Task export acknowledgement did not unlock after download",
  );
  await evaluate(
    browser.cdp,
    `document.querySelector("#storage-task-export-ack").click()`,
  );
  await waitFor(
    browser.cdp,
    `!document.querySelector(".storage-task-danger .danger-outline").disabled`,
    "Task cleanup did not unlock after export acknowledgement",
  );
  await evaluate(
    browser.cdp,
    `document.querySelector(".storage-task-danger .danger-outline").click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-task-confirm h3")?.textContent ===
      "确认清空 Task 与证据"`,
    "Task cleanup confirmation did not render",
  );
  await evaluate(
    browser.cdp,
    `document.querySelector(".storage-task-confirm")
      ?.scrollIntoView({ block: "start" })`,
  );
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
  if (evidenceDir) {
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidenceDir, "storage-task-confirm.png"),
      Buffer.from(screenshot.data, "base64"),
    );
  }
  await evaluate(
    browser.cdp,
    `[...document.querySelectorAll(".storage-task-confirm button")]
      .find((button) => button.textContent === "确认清空 Task").click()`,
  );
  await waitFor(
    browser.cdp,
    `document.querySelector(".storage-danger-zone")?.classList.contains(
      "is-cleared"
    )`,
    "Task cleanup result did not render",
  );
  await evaluate(
    browser.cdp,
    `document.querySelector(".storage-danger-zone.is-cleared")
      ?.scrollIntoView({ block: "start" })`,
  );
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 150));
  if (evidenceDir) {
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidenceDir, "storage-task-cleared.png"),
      Buffer.from(screenshot.data, "base64"),
    );
  }
  assert.equal(
    (await stat(join(runtimeDir, "tasks"))).isDirectory(),
    true,
  );
  assert.equal(
    (await stat(join(runtimeDir, "capability-token"))).isFile(),
    true,
  );

  await browser.cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 390,
    height: 844,
    deviceScaleFactor: 1,
    mobile: true,
  });
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 200));
  const mobile = await evaluate(
    browser.cdp,
    `(() => {
      const dialog = document.querySelector("#storage-dialog");
      const rect = dialog.getBoundingClientRect();
      return {
        width: rect.width,
        viewportWidth: innerWidth,
        horizontalOverflow:
          document.documentElement.scrollWidth > document.documentElement.clientWidth,
        closeVisible:
          document.querySelector("#storage-close-button")
            .getBoundingClientRect().width > 0,
      };
    })()`,
  );
  assert.ok(mobile.width <= mobile.viewportWidth);
  assert.equal(mobile.horizontalOverflow, false);
  assert.equal(mobile.closeVisible, true);

  if (evidenceDir) {
    const screenshot = await browser.cdp.send("Page.captureScreenshot", {
      format: "png",
      captureBeyondViewport: false,
    });
    await writeFile(
      join(evidenceDir, "storage-dialog-mobile.png"),
      Buffer.from(screenshot.data, "base64"),
    );
  }

  console.log(
    "Storage dialog desktop/mobile render, confirmation and cleanup: PASS",
  );
} finally {
  await browser?.close().catch(() => {});
  if (child.exitCode === null) child.kill();
  await rm(tempRoot, { recursive: true, force: true });
}
