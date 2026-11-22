import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const packageRoot = resolve(
  process.argv[2] ??
    process.env.SKILLDOCK_RC_PACKAGE ??
    join(repoRoot, "dist", "SkillDock-PCHW-0.1.0-rc.4-win-x64"),
);
const executable = join(packageRoot, "SkillDock.exe");
const manifestPath = join(
  packageRoot,
  "skills",
  "pc-hardware-workbench",
  "workbench.manifest.json",
);
const releaseManifestPath = join(packageRoot, "RC-MANIFEST.json");

for (const required of [executable, manifestPath, releaseManifestPath]) {
  if (!existsSync(required)) {
    throw new Error(`Portable launcher test input is missing: ${required}`);
  }
}
const releaseManifest = JSON.parse(
  (await readFile(releaseManifestPath, "utf8")).replace(/^\uFEFF/u, ""),
);
const expectedSkillVersion = releaseManifest.pchw_skill.version;
const expectedContractVersion =
  releaseManifest.pchw_surface_contract?.version ?? null;

const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-portable-skill-roots-"),
);
const workspace = join(tempRoot, "workspace");
await mkdir(workspace, { recursive: true });

const inheritedEnv = { ...process.env };
for (const name of [
  "PANEL_SKILL_ROOTS",
  "PANEL_SKILL_MANIFEST",
  "PANEL_WORKBENCH_MANIFEST",
  "SKILLDOCK_SKILL_ROOTS",
]) {
  delete inheritedEnv[name];
}

function runProcess(command, args, env, timeoutMs = 60_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
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
      rejectPromise(new Error(`Launcher timed out: ${args.join(" ")}`));
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

function scenarioName(value) {
  return value.replace(/[^a-z0-9-]+/giu, "-").toLowerCase();
}

function launcherArgs() {
  return [
    "--ensure",
    "--workspace",
    workspace,
    "--silent",
    "--no-browser",
  ];
}

function baseEnv(localRoot, overrides = {}) {
  return {
    ...inheritedEnv,
    SKILLDOCK_LOCAL_ROOT: localRoot,
    NODE_NO_WARNINGS: "1",
    ...overrides,
  };
}

async function stopRuntime(localRoot) {
  await runProcess(
    executable,
    ["--stop", "--silent"],
    baseEnv(localRoot),
    20_000,
  ).catch(() => {});
}

async function readActiveState(localRoot) {
  const result = await readJson(join(localRoot, "launch-result.json"));
  assert.equal(result.ok, true);
  const token = (
    await readFile(
      join(localRoot, "runtime-pchw", "capability-token"),
      "utf8",
    )
  ).trim();
  const state = await fetch(
    `${String(result.url).replace(/\/$/u, "")}/api/state`,
    {
      headers: { Authorization: `Bearer ${token}` },
    },
  ).then((response) => response.json());
  return { result, state };
}

function assertActivePchw(state) {
  assert.equal(state.skill.skill_id, "pc-hardware-workbench");
  assert.equal(state.skill.skill_version, expectedSkillVersion);
  assert.equal(
    state.skill.surface_compatibility.compatible,
    true,
  );
  assert.equal(
    state.skill.surface_compatibility.contract_id,
    "pchw-source-hosted",
  );
  assert.equal(
    state.skill.surface_compatibility.mode,
    expectedContractVersion ? "contract" : "legacy_exact",
  );
  assert.equal(
    state.skill.surface_compatibility.contract_version,
    expectedContractVersion,
  );
  assert.equal(state.skill.status, "active");
  assert.ok(state.skill.discovery.candidate_count >= 1);
  assert.ok(state.skill.discovery.compatible_count >= 1);
  assert.equal(
    state.skill.discovery.candidates[0].surface_compatibility.compatible,
    true,
  );
  assert.ok(
    state.skill.capabilities.some(
      (capability) => capability.id === "telemetry.csv.analyze",
    ),
  );
}

async function expectLaunchFailure({
  name,
  envOverrides,
  expectedCode,
}) {
  const localRoot = join(tempRoot, scenarioName(name));
  await mkdir(localRoot, { recursive: true });
  const run = await runProcess(
    executable,
    launcherArgs(),
    baseEnv(localRoot, envOverrides),
  );
  assert.notEqual(run.code, 0, `${name} unexpectedly launched`);
  const failurePath = join(localRoot, "launch-failure.json");
  assert.equal(existsSync(failurePath), true, `${name} wrote no failure state`);
  const failure = await readJson(failurePath);
  assert.equal(failure.ok, false);
  assert.equal(failure.error_code, expectedCode, failure.error);
  assert.equal(existsSync(join(localRoot, "launch-result.json")), false);
  return failure;
}

try {
  const explicitRootsLocal = join(tempRoot, "explicit-roots");
  await mkdir(explicitRootsLocal, { recursive: true });
  const explicitRootsRun = await runProcess(
    executable,
    launcherArgs(),
    baseEnv(explicitRootsLocal, {
      PANEL_SKILL_ROOTS: join(packageRoot, "skills"),
      PANEL_SKILL_MANIFEST: manifestPath,
    }),
  );
  assert.equal(
    explicitRootsRun.code,
    0,
    `${explicitRootsRun.stdout}\n${explicitRootsRun.stderr}`,
  );
  const explicitRoots = await readActiveState(explicitRootsLocal);
  assertActivePchw(explicitRoots.state);
  await stopRuntime(explicitRootsLocal);

  const explicitManifestLocal = join(tempRoot, "explicit-manifest");
  await mkdir(explicitManifestLocal, { recursive: true });
  const explicitManifestRun = await runProcess(
    executable,
    launcherArgs(),
    baseEnv(explicitManifestLocal, {
      PANEL_SKILL_ROOTS: join(tempRoot, "deliberately-missing-root"),
      PANEL_SKILL_MANIFEST: manifestPath,
    }),
  );
  assert.equal(
    explicitManifestRun.code,
    0,
    `${explicitManifestRun.stdout}\n${explicitManifestRun.stderr}`,
  );
  const explicitManifest = await readActiveState(explicitManifestLocal);
  assertActivePchw(explicitManifest.state);
  await stopRuntime(explicitManifestLocal);

  await expectLaunchFailure({
    name: "empty-roots",
    envOverrides: { PANEL_SKILL_ROOTS: "" },
    expectedCode: "skill_runtime_mismatch",
  });
  await expectLaunchFailure({
    name: "missing-roots",
    envOverrides: {
      PANEL_SKILL_ROOTS: join(tempRoot, "missing-skill-root"),
    },
    expectedCode: "skill_runtime_mismatch",
  });
  await expectLaunchFailure({
    name: "missing-manifest",
    envOverrides: {
      PANEL_SKILL_ROOTS: join(packageRoot, "skills"),
      PANEL_SKILL_MANIFEST: join(tempRoot, "missing.manifest.json"),
    },
    expectedCode: "skill_runtime_mismatch",
  });

  console.log(
    "Portable launcher explicit roots/manifest and fail-closed discovery: PASS",
  );
} finally {
  for (const directory of [
    join(tempRoot, "explicit-roots"),
    join(tempRoot, "explicit-manifest"),
  ]) {
    await stopRuntime(directory);
  }
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept portable launcher test root: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
