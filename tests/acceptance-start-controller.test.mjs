import assert from "node:assert/strict";
import { spawn } from "node:child_process";
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
import { join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const controllerRoot = join(
  repoRoot,
  "release",
  "0.1.0-rc.4",
  "acceptance-bundle",
);
const controllerSource = join(controllerRoot, "Start-Acceptance.ps1");
const commandSource = join(controllerRoot, "Start-Acceptance.cmd");

for (const required of [controllerSource, commandSource]) {
  if (!existsSync(required)) {
    throw new Error(`Acceptance controller source is missing: ${required}`);
  }
}

const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-acceptance-start-"),
);

function runProcess(command, args, cwd, timeoutMs = 120_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      cwd,
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

async function readJson(path) {
  return JSON.parse(
    (await readFile(path, "utf8")).replace(/^\uFEFF/u, ""),
  );
}

async function createFixture(name, preflightExitCode) {
  const root = join(tempRoot, name);
  await mkdir(root, { recursive: true });
  await copyFile(controllerSource, join(root, "Start-Acceptance.ps1"));
  await copyFile(commandSource, join(root, "Start-Acceptance.cmd"));
  await writeFile(
    join(root, "99-Validate-Bundle.ps1"),
    [
      "$line = '99|' + ($args -join ',')",
      "$line | Out-File -FilePath (Join-Path $PSScriptRoot 'order.log') -Append -Encoding ASCII",
      "Write-Output 'validate passed'",
      "exit 0",
      "",
    ].join("\n"),
    "utf8",
  );
  await writeFile(
    join(root, "00-Preflight.ps1"),
    [
      "$line = '00|' + ($args -join ',')",
      "$line | Out-File -FilePath (Join-Path $PSScriptRoot 'order.log') -Append -Encoding ASCII",
      `Write-Output 'preflight exit ${preflightExitCode}'`,
      `exit ${preflightExitCode}`,
      "",
    ].join("\n"),
    "utf8",
  );
  await writeFile(
    join(root, "01-Install.ps1"),
    [
      "Set-Content -LiteralPath (Join-Path $PSScriptRoot '01.ran') -Value 'ran' -Encoding ASCII",
      "$line = '01|' + ($args -join ',')",
      "$line | Out-File -FilePath (Join-Path $PSScriptRoot 'order.log') -Append -Encoding ASCII",
      "Write-Output 'install passed'",
      "exit 0",
      "",
    ].join("\n"),
    "utf8",
  );
  return root;
}

async function runController(root, extraArgs = []) {
  return runProcess(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      join(root, "Start-Acceptance.ps1"),
      ...extraArgs,
    ],
    root,
  );
}

try {
  const successRoot = await createFixture("success", 0);
  const successRun = await runController(successRoot);
  assert.equal(
    successRun.code,
    0,
    `${successRun.stdout}\n${successRun.stderr}`,
  );
  const successResult = await readJson(
    join(successRoot, "evidence", "acceptance-start-result.json"),
  );
  assert.equal(successResult.status, "passed");
  assert.equal(successResult.mode, "clean-acceptance");
  assert.equal(successResult.stages.length, 3);
  assert.deepEqual(
    successResult.stages.map((stage) => stage.status),
    ["passed", "passed", "passed"],
  );
  const successOrder = (
    await readFile(join(successRoot, "order.log"), "utf8")
  ).trim().split(/\r?\n/u);
  assert.deepEqual(successOrder, ["99|", "00|", "01|"]);
  assert.equal(existsSync(successResult.log_path), true);
  for (const stage of successResult.stages) {
    assert.equal(existsSync(stage.stdout_path), true);
    assert.equal(existsSync(stage.stderr_path), true);
  }

  const failureRoot = await createFixture("failure", 7);
  const failureRun = await runController(failureRoot);
  assert.equal(failureRun.code, 7);
  const failureResult = await readJson(
    join(failureRoot, "evidence", "acceptance-start-result.json"),
  );
  assert.equal(failureResult.status, "failed");
  assert.equal(failureResult.failed_stage, "Preflight");
  assert.equal(failureResult.failed_exit_code, 7);
  assert.deepEqual(
    failureResult.stages.map((stage) => stage.status),
    ["passed", "failed"],
  );
  const failureOrder = (
    await readFile(join(failureRoot, "order.log"), "utf8")
  ).trim().split(/\r?\n/u);
  assert.deepEqual(failureOrder, ["99|", "00|"]);
  assert.equal(existsSync(join(failureRoot, "01.ran")), false);
  const failureLog = await readFile(failureResult.log_path, "utf8");
  assert.match(failureLog, /Stage 2\/3: Preflight/u);
  assert.match(failureLog, /exited with code 7/u);

  const upgradeRoot = await createFixture("upgrade", 0);
  const upgradeRun = await runController(upgradeRoot, [
    "-UpgradeExisting",
  ]);
  assert.equal(upgradeRun.code, 0, `${upgradeRun.stdout}\n${upgradeRun.stderr}`);
  const upgradeResult = await readJson(
    join(upgradeRoot, "evidence", "acceptance-start-result.json"),
  );
  assert.equal(upgradeResult.status, "passed");
  assert.equal(upgradeResult.mode, "upgrade-existing");
  const upgradeOrder = (
    await readFile(join(upgradeRoot, "order.log"), "utf8")
  ).trim().split(/\r?\n/u);
  assert.deepEqual(upgradeOrder, [
    "99|",
    "00|-AllowExistingInstall",
    "01|-UpgradeExisting",
  ]);

  console.log(
    "Acceptance startup controller ordering and fail-fast behavior: PASS",
  );
} finally {
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept acceptance controller test root: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
