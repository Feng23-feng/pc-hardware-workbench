import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve, sep } from "node:path";

if (process.platform !== "win32") {
  console.log("Internal preview package usability: SKIP (Windows only)");
  process.exit(0);
}

const root = resolve(import.meta.dirname, "..");
const powershell = "powershell.exe";
const buildScript = join(root, "launcher", "build-dsh-package.ps1");
const runId = randomUUID();
const packageDirectory = join(
  root,
  "dist",
  `.internal-preview-usability-${runId}`,
);
const archivePath = join(
  root,
  "dist",
  `.internal-preview-usability-${runId}.zip`,
);
const tempRoot = await mkdtemp(join(tmpdir(), "skilldock-preview-usability-"));
const nodeBundle = join(tempRoot, "node-runtime");
const workspace = join(tempRoot, "workspace");
const localRoot = join(tempRoot, "local-app-data", "SkillDock");
const extractionRoot = join(tempRoot, "extracted-package");
const evidenceDir = join(
  root,
  "work",
  "internal-preview-usability-2026-11-17",
);
const approvedEvidencePath = join(
  evidenceDir,
  "usability-evidence-approved-31baef108d9ec3e0ab92f1de2a3225ab67d1e810db56b2c953601e3257a5f2d8.json",
);
const approvedEvidenceSha256 =
  "31baef108d9ec3e0ab92f1de2a3225ab67d1e810db56b2c953601e3257a5f2d8";
const evidencePath = join(evidenceDir, "usability-evidence.json");
const manifestPath = join(evidenceDir, "package-file-manifest.json");
const expectedPackageFiles = Object.freeze([
  "SkillDock.exe",
  "README.txt",
  "Start-DSH-SkillDock.ps1",
  "Start-DSH-SkillDock-Dev.ps1",
  "Stop SkillDock.cmd",
  "Uninstall SkillDock.ps1",
  "runtime-paths.ps1",
  "app/VERSIONING.md",
  "app/agent-bridge-host.mjs",
  "app/lib/agent-permissions.mjs",
  "app/lib/agents/README.md",
  "app/lib/agents/agent-bridge-driver.mjs",
  "app/lib/agents/agent-driver.mjs",
  "app/lib/agents/codex-agent-driver.mjs",
  "app/lib/agents/dsh-agent-driver.mjs",
  "app/lib/agents/dsh-web-agent-driver.mjs",
  "app/lib/agents/dsh-web-rpc-client.mjs",
  "app/lib/agents/index.mjs",
  "app/lib/agents/mock-agent-driver.mjs",
  "app/lib/agents/source-external-agent-driver.mjs",
  "app/lib/handoff-capability.mjs",
  "app/lib/panel-response.mjs",
  "app/lib/panel-state-merge.mjs",
  "app/lib/permission-matrix.mjs",
  "app/lib/schema-validation.mjs",
  "app/lib/skill-discovery.mjs",
  "app/lib/skill-runtime.mjs",
  "app/lib/source-hosted-phase.mjs",
  "app/lib/source-hosted-shadow.mjs",
  "app/lib/storage-maintenance.mjs",
  "app/lib/state-store.mjs",
  "app/lib/workbench-manifest.mjs",
  "app/open-workbench.mjs",
  "app/package.json",
  "app/public/app.js",
  "app/public/draft-storage.js",
  "app/public/index.html",
  "app/public/runtime-binding.js",
  "app/public/source-hosted-phase.js",
  "app/public/status-model.js",
  "app/public/styles.css",
  "app/schemas/panel-event.schema.json",
  "app/schemas/panel-ui-state.schema.json",
  "app/schemas/workbench-manifest.schema.json",
  "app/server.mjs",
  "node/LICENSE",
  "node/node.exe",
].sort());
let activeUrl = null;
let launcherPath = null;
let launcherEnv = null;

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

async function readJson(path) {
  const text = (await readFile(path, "utf8")).replace(/^\uFEFF/u, "");
  return JSON.parse(text);
}

async function sha256File(path) {
  return createHash("sha256").update(await readFile(path)).digest("hex");
}

function sha256Text(text) {
  return createHash("sha256").update(text, "utf8").digest("hex");
}

function pathIsInside(parent, child) {
  const parentPath = resolve(parent).replace(/[\\/]+$/u, "");
  const childPath = resolve(child);
  return (
    childPath.startsWith(`${parentPath}${sep}`) ||
    childPath === parentPath
  );
}

async function walkFiles(directory, prefix = "") {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const relativePath = prefix ? join(prefix, entry.name) : entry.name;
    const absolutePath = join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...await walkFiles(absolutePath, relativePath));
    } else if (entry.isFile()) {
      files.push(relativePath);
    }
  }
  return files;
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

async function waitForLaunchResult() {
  const resultPath = join(localRoot, "launch-result.json");
  for (let attempt = 0; attempt < 160; attempt += 1) {
    try {
      const result = await readJson(resultPath);
      if (result.ok && result.url && await isHealthy(result.url)) {
        return result;
      }
    } catch {
      // Launcher is still starting.
    }
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 250));
  }
  throw new Error("Portable package launch result did not appear.");
}

async function listProcessesUnderRoot(processRoot) {
  const script = String.raw`
$scope = [string]$env:SKILLDOCK_PROCESS_SCOPE
$processes = @(
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.ExecutablePath -and
            $_.ExecutablePath.StartsWith(
                $scope,
                [StringComparison]::OrdinalIgnoreCase
            )
        } |
        ForEach-Object {
            [pscustomobject]@{
                process_id = [int]$_.ProcessId
                executable_path = [string]$_.ExecutablePath
            }
        }
)
if ($processes.Count -eq 0) {
    Write-Output "[]"
}
else {
    ConvertTo-Json -InputObject $processes -Compress
}
`;
  const result = await runProcess(
    powershell,
    ["-NoProfile", "-NonInteractive", "-Command", script],
    {
      env: {
        ...process.env,
        SKILLDOCK_PROCESS_SCOPE: processRoot,
      },
    },
  );
  assert.equal(result.code, 0, result.stderr);
  const parsed = JSON.parse(result.stdout.trim() || "[]");
  return Array.isArray(parsed) ? parsed : [parsed];
}

try {
  assert.equal(
    await sha256File(approvedEvidencePath),
    approvedEvidenceSha256,
    "The R2-approved usability evidence is missing or changed.",
  );
  await Promise.all([
    mkdir(workspace, { recursive: true }),
    mkdir(nodeBundle, { recursive: true }),
    mkdir(extractionRoot, { recursive: true }),
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
    powershell,
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
  assert.equal(existsSync(packageDirectory), true);
  assert.equal(existsSync(archivePath), true);

  const expand = await runProcess(
    powershell,
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "Expand-Archive -LiteralPath $env:SKILLDOCK_ARCHIVE_PATH " +
        "-DestinationPath $env:SKILLDOCK_EXTRACT_PATH -Force",
    ],
    {
      env: {
        ...process.env,
        SKILLDOCK_ARCHIVE_PATH: archivePath,
        SKILLDOCK_EXTRACT_PATH: extractionRoot,
      },
    },
  );
  assert.equal(expand.code, 0, expand.stderr);

  const extractedFiles = await walkFiles(extractionRoot);
  const launcherCandidates = extractedFiles.filter(
    (path) => path.split(sep).at(-1) === "SkillDock.exe",
  );
  assert.equal(
    launcherCandidates.length,
    1,
    "The archive must contain exactly one SkillDock.exe.",
  );
  launcherPath = join(extractionRoot, launcherCandidates[0]);
  const packageRoot = dirname(launcherPath);
  const packageFiles = await walkFiles(packageRoot);
  const packageRelativeFiles = packageFiles.map(
    (path) => relative(packageRoot, join(packageRoot, path))
      .split(sep)
      .join("/"),
  ).sort();
  const missingEntries = expectedPackageFiles.filter(
    (entry) => !packageRelativeFiles.includes(entry),
  );
  const unexpectedEntries = packageRelativeFiles.filter(
    (entry) => !expectedPackageFiles.includes(entry),
  );
  assert.deepEqual(missingEntries, []);
  assert.deepEqual(unexpectedEntries, []);
  assert.equal(
    packageRelativeFiles.length,
    expectedPackageFiles.length,
    `The extracted package must contain exactly ${expectedPackageFiles.length} files.`,
  );
  assert.deepEqual(packageRelativeFiles, [...expectedPackageFiles]);

  const forbiddenSegments = new Set([
    ".git",
    "node_modules",
    "tests",
    "work",
  ]);
  const forbiddenBasenames = new Set([
    ".env",
    "capability-token",
    "handoff-secret",
    "launch-result.json",
    "panel-capability-token",
    "server-info.json",
    "source-capability-token",
  ]);
  const forbiddenEntries = packageRelativeFiles.filter((path) => {
    const segments = path.split("/");
    return (
      segments.some((segment) => forbiddenSegments.has(segment)) ||
      forbiddenBasenames.has(segments.at(-1))
    );
  });
  assert.deepEqual(forbiddenEntries, []);

  const fileManifest = [];
  for (const relativePath of packageRelativeFiles) {
    const absolutePath = join(packageRoot, ...relativePath.split("/"));
    const fileStat = await stat(absolutePath);
    fileManifest.push({
      path: relativePath,
      bytes: fileStat.size,
      sha256: await sha256File(absolutePath),
    });
  }
  assert.equal(fileManifest.length, expectedPackageFiles.length);
  assert.deepEqual(
    fileManifest.map((entry) => entry.path),
    fileManifest.map((entry) => entry.path).sort(),
  );
  const manifestText = `${JSON.stringify(fileManifest, null, 2)}\n`;
  const packageManifestSha256 = sha256Text(manifestText);

  const readmePath = join(packageRoot, "README.txt");
  const readme = (await readFile(readmePath, "utf8")).replace(/\r\n/gu, "\n");
  const readmeChecks = {
    internal_test: readme.includes("INTERNAL TEST"),
    default_off: readme.includes("DEFAULT OFF"),
    mock_only: readme.includes("MOCK ONLY"),
    preview_flag: readme.includes("SKILLDOCK_INTERNAL_PREVIEW=1"),
    mock_driver: readme.includes("SKILLDOCK_AGENT_DRIVER=mock"),
    no_real_thread: readme.includes("real Codex Thread"),
    isolated_local_root: readme.includes(
      "LOCALAPPDATA\\SkillDockInternalPreview",
    ),
    retention_semantics: readme.includes("preserves user data"),
    purge_user_data: readme.includes("-PurgeUserData"),
    purge_backups: readme.includes("-PurgeBackups"),
    portable_cleanup: readme.includes("portably"),
  };
  assert.deepEqual(
    Object.entries(readmeChecks).filter(([, value]) => !value),
    [],
  );

  const packagedPackageJson = await readJson(join(
    packageRoot,
    "app",
    "package.json",
  ));
  const nodeVersionRun = await runProcess(
    join(packageRoot, "node", "node.exe"),
    ["--version"],
  );
  assert.equal(nodeVersionRun.code, 0, nodeVersionRun.stderr);
  const bundledNodeVersion = nodeVersionRun.stdout.trim().replace(/^v/u, "");
  assert.equal(bundledNodeVersion, "24.22.1");

  const launcherInsideExtractionRoot = (
    pathIsInside(extractionRoot, launcherPath) &&
    !pathIsInside(packageDirectory, launcherPath)
  );
  assert.equal(launcherInsideExtractionRoot, true);
  const baseEnv = {
    ...process.env,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    SKILLDOCK_AGENT_DRIVER: "mock",
    SKILLDOCK_INTERNAL_PREVIEW: "",
    NODE_NO_WARNINGS: "1",
  };
  const nonMockPreview = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], {
    env: {
      ...baseEnv,
      SKILLDOCK_AGENT_DRIVER: "codex",
      SKILLDOCK_INTERNAL_PREVIEW: "1",
    },
  });
  assert.notEqual(nonMockPreview.code, 0);
  const nonMockServerInfoProduced = existsSync(
    join(localRoot, "runtime-dsh-web", "server-info.json"),
  );
  assert.equal(nonMockServerInfoProduced, false);

  let started = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: baseEnv });
  assert.equal(started.code, 0, started.stderr);
  const defaultLaunchExitCode = started.code;
  let launchResult = await waitForLaunchResult();
  const portableStartWithoutInstall = (
    launcherInsideExtractionRoot &&
    defaultLaunchExitCode === 0 &&
    new URL(launchResult.url).hostname === "127.0.0.1"
  );
  assert.equal(portableStartWithoutInstall, true);
  activeUrl = launchResult.url;
  let response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/source-hosted/open?token=invalid`,
    { redirect: "manual" },
  );
  const defaultOffStatus = response.status;
  assert.equal(defaultOffStatus, 404);
  response = await fetch(launchResult.url);
  const defaultHomepageStatus = response.status;
  assert.equal(defaultHomepageStatus, 200);

  started = await runProcess(launcherPath, ["--stop", "--silent"], {
    env: baseEnv,
    timeoutMs: 30_000,
  });
  assert.equal(started.code, 0, started.stderr);
  assert.equal(await isHealthy(launchResult.url), false);
  activeUrl = null;

  launcherEnv = {
    ...baseEnv,
    SKILLDOCK_INTERNAL_PREVIEW: "1",
  };
  await rm(join(localRoot, "launch-result.json"), { force: true });
  started = await runProcess(launcherPath, [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ], { env: launcherEnv });
  assert.equal(started.code, 0, started.stderr);
  launchResult = await waitForLaunchResult();
  activeUrl = launchResult.url;
  assert.equal(launchResult.driver, "mock");
  response = await fetch(
    `${launchResult.url.replace(/\/$/u, "")}/source-hosted/open?token=invalid`,
    { redirect: "manual" },
  );
  const enabledPreviewStatus = response.status;
  assert.equal(enabledPreviewStatus, 401);
  response = await fetch(launchResult.url);
  const previewHomepageStatus = response.status;
  assert.equal(previewHomepageStatus, 200);

  started = await runProcess(launcherPath, ["--stop", "--silent"], {
    env: launcherEnv,
    timeoutMs: 30_000,
  });
  assert.equal(started.code, 0, started.stderr);
  assert.equal(await isHealthy(launchResult.url), false);
  activeUrl = null;
  const runtimeProcessesAfterStop = await listProcessesUnderRoot(tempRoot);
  assert.deepEqual(runtimeProcessesAfterStop, []);

  const archiveBytes = (await readFile(archivePath)).length;
  const archiveSha256 = await sha256File(archivePath);
  const observed = {
    schema_version: "1.0",
    status: "passed",
    gate: "internal_preview_package_usability",
    package_version: packagedPackageJson.version,
    packaged_node_version: bundledNodeVersion,
    archive: {
      bytes: archiveBytes,
      sha256: archiveSha256,
      file_count: packageRelativeFiles.length,
      extracted: true,
    },
    contents: {
      expected_file_count: expectedPackageFiles.length,
      actual_file_count: packageRelativeFiles.length,
      allowlist_exact: (
        missingEntries.length === 0 &&
        unexpectedEntries.length === 0 &&
        packageRelativeFiles.length === expectedPackageFiles.length
      ),
      expected_entries_missing: missingEntries,
      unexpected_entries: unexpectedEntries,
      forbidden_entries: forbiddenEntries,
      manifest_path: "package-file-manifest.json",
      manifest_entry_count: fileManifest.length,
      manifest_encoding: "UTF-8 JSON, 2-space indent, LF",
      manifest_order:
        "path ascending, JavaScript default UTF-16 code-unit order",
      manifest_sha256: packageManifestSha256,
    },
    readme: readmeChecks,
    usability: {
      portable_start_without_install: portableStartWithoutInstall,
      launcher_inside_extraction_root: launcherInsideExtractionRoot,
      default_launch_exit_code: defaultLaunchExitCode,
      non_mock_preview_exit_code: nonMockPreview.code,
      non_mock_preview_produced_server_info: nonMockServerInfoProduced,
      default_off_entry_status: defaultOffStatus,
      default_off_homepage_status: defaultHomepageStatus,
      enabled_preview_invalid_token_status: enabledPreviewStatus,
      enabled_preview_driver: launchResult.driver,
      enabled_preview_homepage_status: previewHomepageStatus,
    },
    cleanup: {
      runtime_processes_after_stop: runtimeProcessesAfterStop.length,
    },
    boundaries: {
      formal_entry_enabled: false,
      default_traffic_enabled: false,
      real_codex_thread_used: false,
      recovery_enabled: false,
      production_release: false,
    },
    observed_at: new Date().toISOString(),
  };

  await rm(tempRoot, { recursive: true, force: true });
  await rm(packageDirectory, { recursive: true, force: true });
  await rm(archivePath, { force: true });
  const residueCandidates = [
    ["temp_root", tempRoot],
    ["package_directory", packageDirectory],
    ["package_archive", archivePath],
    ["local_root", localRoot],
  ];
  const remainingResidueKinds = residueCandidates
    .filter(([, path]) => existsSync(path))
    .map(([kind]) => kind);
  assert.deepEqual(remainingResidueKinds, []);
  observed.cleanup.fixture_residue_kinds = remainingResidueKinds;
  observed.cleanup.fixture_residue_count = remainingResidueKinds.length;

  await mkdir(evidenceDir, { recursive: true });
  await writeFile(
    manifestPath,
    manifestText,
    { encoding: "utf8", mode: 0o600 },
  );
  await writeFile(
    evidencePath,
    `${JSON.stringify(observed, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );

  console.log(
    "Internal preview ZIP extract/default-off/mock preview/stop/residue: PASS",
  );
} finally {
  if (activeUrl && launcherPath && launcherEnv) {
    await runProcess(launcherPath, ["--stop", "--silent"], {
      env: launcherEnv,
      timeoutMs: 15_000,
    }).catch(() => {});
  }
  await rm(tempRoot, { recursive: true, force: true });
  await rm(packageDirectory, { recursive: true, force: true });
  await rm(archivePath, { force: true });
}
