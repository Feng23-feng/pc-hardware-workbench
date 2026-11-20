import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import {
  mkdir,
  readFile,
  readdir,
  stat,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";
import { pathToFileURL } from "node:url";
import {
  computeSkillTreeIdentity,
} from "./skill-tree-identity.mjs";
import {
  isSourceHostedSubmittablePhase,
} from "../lib/source-hosted-phase.mjs";

const root = resolve(import.meta.dirname, "..");
const expected = Object.freeze({
  workspace: root,
  localRoot: join(process.env.LOCALAPPDATA ?? "", "SkillDock"),
  runtimePointerPath: join(
    process.env.LOCALAPPDATA ?? "",
    "SkillDock",
    "runtime-location.json",
  ),
  runtimePackage: join(
    process.env.LOCALAPPDATA ?? "",
    "SkillDock",
    "Runtime-0.1.0-dev-20261117191420",
  ),
  threadSha256:
    "00a0ee1b758bd3e04174877bca4e401859497648025fdaeabc08d9f1654d48c2",
  taskId: "task-pchw-00a0ee1b758bd3e04174877bca4e4018",
  installedSkillRoot: join(
    homedir(),
    ".codex",
    "skills",
    "pc-hardware-workbench",
  ),
  installedTreeSha256:
    "f6eab543414ef6b208706b4367b7adb152db3bd5c5288390a0f30a5189a95eb1",
  installedTreeFileCount: 134,
  installedRuntimeSha256:
    "97ecce02c40ee622c0a261ee7143e2f14af1926f20604db67dfaed9d18fc4c51",
  nodeSha256:
    "6b9088f99e93cc50ec7f2e7a2f0b6380e0ec4288a4f558453e8a28785ed14bb0",
  launcherSha256:
    "1cf681003b238f625324e70461d552a1b0f314a697bf8a44ad0517efacb081ca",
  serverSha256:
    "60f2a0b88a662fbc416e8efece01a3ffcd22e9c819583e1f1bbfb0a6645b75af",
  appSha256:
    "ba30ca86723281ff3949b99db369edbd8ce3f07aba33b42bc6b55fc754c7f267",
  indexSha256:
    "3b05b901a05c370c481936b50db0c9934ee9c92ccccc4929bd1f27fef85ebd9b",
  runtimeBindingSha256:
    "b4141deed7ee2da928762287b25472ed2a2964387c6bd3f7731f7adfdca07295",
  sourceHostedPhaseSha256:
    "8d4c72eab38f6a51d44a487ff0d1480d233116bfce67279f47e218b99c332d70",
  integrationDir: join(root, "integrations", "skilldock"),
  launchPanelSha256:
    "94e1015fddeac39bb0f17e7608024d360fd37714f831fb1315f48b4d6a4568dd",
  waitPanelSha256:
    "9efe567ce6fd3803721934e6126fbd4111bd7f5de6d32fa47e3ba357438527fa",
  syncPanelSha256:
    "1a61fe8f928148be022b256ef517154010b4b451f168c32502749725e036edac",
  freshnessSha256:
    "8712f8468a2def8ddc428ddf1a615667f884af35d8f2d0d0eeaa05cd25fe87ee",
  csvPath: join(
    root,
    "work",
    "PCHW-FRESHNESS-GATE-R7-20261117.csv",
  ),
  csvSha256:
    "5aba3e3f86d04d12a9facc0bae7b036eaa02fc2cb484f3f428da2b7acaee7b48",
});
const defaultEvidencePath = join(
  root,
  "work",
  "PCHW-CURRENT-USER-THREAD-PREFLIGHT-DRY-RUN-20261117.json",
);

export function resolveRuntimePackagePaths(runtimePointerPath) {
  const pointerPath = resolve(runtimePointerPath);
  const packageRoot = dirname(pointerPath);
  const engineReferencePath = join(packageRoot, "engine-location.json");
  let nodePath = join(packageRoot, "node", "node.exe");
  if (existsSync(engineReferencePath)) {
    const reference = JSON.parse(readFileSync(engineReferencePath, "utf8"));
    if (
      reference?.schema_version !== "1.0" ||
      typeof reference.engine_id !== "string" ||
      reference.engine_id.length === 0 ||
      typeof reference.node_path !== "string" ||
      !isAbsolute(reference.node_path) ||
      typeof reference.node_sha256 !== "string" ||
      !/^[0-9a-f]{64}$/u.test(reference.node_sha256)
    ) {
      throw new Error("Shared Node engine reference is malformed.");
    }
    const engineRoot = resolve(packageRoot, "..", "engines");
    const resolvedNodePath = resolve(reference.node_path);
    const nodeRelativePath = relative(engineRoot, resolvedNodePath);
    if (
      nodeRelativePath.length === 0 ||
      nodeRelativePath.startsWith("..") ||
      isAbsolute(nodeRelativePath)
    ) {
      throw new Error("Shared Node engine path escapes the engine root.");
    }
    nodePath = resolvedNodePath;
  }
  return {
    pointerPath,
    packageRoot,
    launcherPath: join(packageRoot, "SkillDock.exe"),
    serverPath: join(packageRoot, "app", "server.mjs"),
    appPath: join(packageRoot, "app", "public", "app.js"),
    indexPath: join(packageRoot, "app", "public", "index.html"),
    runtimeBindingPath: join(
      packageRoot,
      "app",
      "public",
      "runtime-binding.js",
    ),
    sourceHostedPhasePath: join(
      packageRoot,
      "app",
      "public",
      "source-hosted-phase.js",
    ),
    engineReferencePath,
    nodePath,
  };
}

export function readPersistedTaskBinding(record) {
  const task = record?.task ?? record;
  return {
    taskId: String(task?.task_id ?? ""),
    sourceSessionRef: String(task?.shared_task?.source_session_ref ?? ""),
    environmentThreadId: String(
      task?.shared_task?.environment_thread_id ?? "",
    ),
    mode: String(task?.shared_task?.mode ?? ""),
    phase: String(task?.shared_task?.phase ?? ""),
    channelId: String(task?.shared_task?.channel_id ?? ""),
  };
}

export function evaluatePreflightPhaseContract(task, threadId) {
  const checks = {
    source_hosted_mode_matches: task.mode === "source_hosted",
    phase_submittable: isSourceHostedSubmittablePhase(task.phase),
    channel_id_matches:
      task.channelId === `chat:source-hosted:${threadId}`,
  };
  const failureReasons = [];
  if (!checks.source_hosted_mode_matches) {
    failureReasons.push("source_hosted_mode_mismatch");
  }
  if (!checks.phase_submittable) {
    failureReasons.push("phase_not_submittable");
  }
  if (!checks.channel_id_matches) {
    failureReasons.push("channel_id_mismatch");
  }
  return {
    ok: failureReasons.length === 0,
    phase: task.phase,
    checks,
    failureReasons,
  };
}

function hashBody(body) {
  return createHash("sha256").update(body).digest("hex");
}

async function hashFile(filePath) {
  return hashBody(await readFile(filePath));
}

function processAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function findTextHashHits(roots, needle) {
  const hits = [];
  const allowedExtensions = new Set([
    ".csv",
    ".json",
    ".jsonl",
    ".log",
    ".md",
    ".mjs",
    ".ps1",
    ".txt",
  ]);
  async function walk(current) {
    const entries = await readdir(current, { withFileTypes: true });
    for (const entry of entries) {
      const filePath = join(current, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        await walk(filePath);
        continue;
      }
      if (!entry.isFile()) continue;
      const extensionIndex = entry.name.lastIndexOf(".");
      const extension =
        extensionIndex >= 0
          ? entry.name.slice(extensionIndex).toLowerCase()
          : "";
      if (!allowedExtensions.has(extension)) continue;
      const fileStat = await stat(filePath);
      if (fileStat.size > 8 * 1024 * 1024) continue;
      const body = (await readFile(filePath)).toString("utf8");
      if (body.toLowerCase().includes(needle)) {
        hits.push(filePath);
      }
    }
  }
  for (const current of roots) {
    if (existsSync(current)) await walk(current);
  }
  return hits;
}

async function findActiveHashHits(runtimeDirectory, needle) {
  const hits = [];
  const statePath = join(runtimeDirectory, "state.json");
  if (existsSync(statePath)) {
    const state = JSON.parse(
      (await readFile(statePath, "utf8")).replace(/^\uFEFF/u, ""),
    );
    const activeAttachments = [
      ...(state.task?.attachments ?? []),
      ...(state.draft?.attachments ?? []),
    ];
    if (
      activeAttachments.some(
        (attachment) =>
          String(attachment.sha256 ?? "").toLowerCase() === needle,
      )
    ) {
      hits.push("state.json:active-attachment");
    }
  }
  const artifactIndex = join(runtimeDirectory, "artifacts", "index.json");
  if (existsSync(artifactIndex)) {
    const index = JSON.parse(
      (await readFile(artifactIndex, "utf8")).replace(/^\uFEFF/u, ""),
    );
    if (
      (index.artifacts ?? []).some(
        (artifact) =>
          String(artifact.cache_key ?? "").toLowerCase().includes(needle) ||
          (artifact.source_evidence_ids ?? []).some(
            (id) => String(id).toLowerCase().includes(needle),
          ),
      )
    ) {
      hits.push("artifacts/index.json:cache-key");
    }
  }
  return hits;
}

async function taskSetIdentity(taskDirectory) {
  const names = (await readdir(taskDirectory, { withFileTypes: true }))
    .filter((entry) => entry.isFile())
    .map((entry) => entry.name)
    .sort();
  return {
    count: names.length,
    sha256: hashBody(names.join("\n")),
    names,
  };
}

function parseArgs(argv) {
  const dryRun = argv.includes("--dry-run");
  const evidenceIndex = argv.indexOf("--evidence");
  const evidencePath =
    evidenceIndex >= 0 && argv[evidenceIndex + 1]
      ? resolve(argv[evidenceIndex + 1])
      : defaultEvidencePath;
  return { dryRun, evidencePath };
}

export async function runPreflight({
  dryRun,
  evidencePath = defaultEvidencePath,
} = {}) {
  const startedAt = new Date();
  const checks = {};
  const failureReasons = [];
  const fail = (name, reason) => {
    checks[name] = false;
    failureReasons.push(reason);
  };
  const pass = (name) => {
    checks[name] = true;
  };

  if (!dryRun) {
    fail("dry_run_required", "dry_run_required");
  } else {
    pass("dry_run_required");
  }

  const threadId = String(process.env.CODEX_THREAD_ID ?? "");
  const threadSha256 = hashBody(threadId.toLowerCase());
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(threadId)) {
    fail("thread_id_format_valid", "thread_id_format_invalid");
  } else {
    pass("thread_id_format_valid");
  }
  if (threadSha256 !== expected.threadSha256) {
    fail("thread_hash_matches", "thread_hash_mismatch");
  } else {
    pass("thread_hash_matches");
  }

  if (!existsSync(expected.workspace)) {
    fail("workspace_exists", "workspace_missing");
  } else {
    pass("workspace_exists");
  }

  const pointer = JSON.parse(
    (await readFile(expected.runtimePointerPath, "utf8"))
      .replace(/^\uFEFF/u, ""),
  );
  const runtimePaths = resolveRuntimePackagePaths(pointer.runtime_path);
  if (
    resolve(runtimePaths.packageRoot).toLowerCase() !==
    resolve(expected.runtimePackage).toLowerCase()
  ) {
    fail("runtime_pointer_package_matches", "runtime_package_mismatch");
  } else {
    pass("runtime_pointer_package_matches");
  }
  for (const [name, filePath] of Object.entries({
    launcher: runtimePaths.launcherPath,
    server: runtimePaths.serverPath,
    app: runtimePaths.appPath,
    index: runtimePaths.indexPath,
    runtimeBinding: runtimePaths.runtimeBindingPath,
    sourceHostedPhase: runtimePaths.sourceHostedPhasePath,
    node: runtimePaths.nodePath,
  })) {
    if (!existsSync(filePath)) {
      fail(`${name}_exists`, `${name}_missing`);
    } else {
      pass(`${name}_exists`);
    }
  }

  let nodeVersion = null;
  if (existsSync(runtimePaths.nodePath)) {
    nodeVersion = execFileSync(
      runtimePaths.nodePath,
      ["--version"],
      { encoding: "utf8" },
    ).trim();
  }
  if (nodeVersion !== "v24.22.1") {
    fail("node_version_matches", "node_version_mismatch");
  } else {
    pass("node_version_matches");
  }

  for (const [name, filePath, expectedHash] of [
    ["launcher", runtimePaths.launcherPath, expected.launcherSha256],
    ["node", runtimePaths.nodePath, expected.nodeSha256],
    ["server", runtimePaths.serverPath, expected.serverSha256],
    ["app", runtimePaths.appPath, expected.appSha256],
    ["index", runtimePaths.indexPath, expected.indexSha256],
    [
      "runtime_binding",
      runtimePaths.runtimeBindingPath,
      expected.runtimeBindingSha256,
    ],
    [
      "source_hosted_phase",
      runtimePaths.sourceHostedPhasePath,
      expected.sourceHostedPhaseSha256,
    ],
  ]) {
    if (!existsSync(filePath)) continue;
    const actualHash = await hashFile(filePath);
    checks[`${name}_sha256`] = actualHash;
    if (actualHash !== expectedHash) {
      fail(`${name}_hash_matches`, `${name}_hash_mismatch`);
    } else {
      pass(`${name}_hash_matches`);
    }
  }

  for (const [name, fileName, expectedHash] of [
    ["launch_panel", "launch-panel.ps1", expected.launchPanelSha256],
    ["wait_panel", "wait-panel.ps1", expected.waitPanelSha256],
    ["sync_panel", "sync-panel.ps1", expected.syncPanelSha256],
    ["freshness_guard", "source-result-freshness.ps1", expected.freshnessSha256],
  ]) {
    const filePath = join(expected.integrationDir, fileName);
    if (!existsSync(filePath)) {
      fail(`${name}_exists`, `${name}_missing`);
      continue;
    }
    pass(`${name}_exists`);
    const actualHash = await hashFile(filePath);
    checks[`${name}_sha256`] = actualHash;
    if (actualHash !== expectedHash) {
      fail(`${name}_hash_matches`, `${name}_hash_mismatch`);
    } else {
      pass(`${name}_hash_matches`);
    }
  }

  const installedTree = await computeSkillTreeIdentity(
    expected.installedSkillRoot,
  );
  checks.installed_tree_file_count = installedTree.tree_file_count;
  checks.installed_tree_sha256 = installedTree.tree_sha256;
  if (
    installedTree.tree_sha256 !== expected.installedTreeSha256 ||
    installedTree.tree_file_count !== expected.installedTreeFileCount
  ) {
    fail("installed_tree_hash_matches", "installed_tree_hash_mismatch");
  } else {
    pass("installed_tree_hash_matches");
  }
  const installedRuntime = await hashFile(
    join(expected.installedSkillRoot, "runtime.mjs"),
  );
  checks.installed_runtime_sha256 = installedRuntime;
  if (installedRuntime !== expected.installedRuntimeSha256) {
    fail("installed_runtime_hash_matches", "installed_runtime_hash_mismatch");
  } else {
    pass("installed_runtime_hash_matches");
  }

  const runtimeStateDirectory = join(expected.localRoot, "runtime-dsh-web");
  const taskDirectory = join(runtimeStateDirectory, "tasks");
  const activeStatePath = join(runtimeStateDirectory, "state.json");
  if (!existsSync(activeStatePath)) {
    fail("active_state_exists", "active_state_missing");
  } else {
    pass("active_state_exists");
    const activeState = JSON.parse(
      (await readFile(activeStatePath, "utf8")).replace(/^\uFEFF/u, ""),
    );
    const task = readPersistedTaskBinding(activeState);
    checks.task_exists = Boolean(task.taskId);
    if (!task.taskId) {
      fail("task_exists", "task_missing");
    } else {
      pass("task_exists");
    }
    checks.task_id = task.taskId;
    checks.source_session_ref_matches = task.sourceSessionRef === threadId;
    checks.environment_thread_id_matches =
      task.environmentThreadId === threadId;
    checks.source_and_environment_equal =
      task.sourceSessionRef === task.environmentThreadId;
    for (const name of [
      "task_id",
      "source_session_ref_matches",
      "environment_thread_id_matches",
      "source_and_environment_equal",
    ]) {
      if (name === "task_id") {
        if (task.taskId !== expected.taskId) {
          fail("task_id_matches", "task_id_mismatch");
        } else {
          pass("task_id_matches");
        }
      } else if (!checks[name]) {
        fail(name, `${name}_failed`);
      } else {
        pass(name);
      }
    }
    const phaseContract = evaluatePreflightPhaseContract(task, threadId);
    const phaseFailureByCheck = {
      source_hosted_mode_matches: "source_hosted_mode_mismatch",
      phase_submittable: "phase_not_submittable",
      channel_id_matches: "channel_id_mismatch",
    };
    for (const [name, passed] of Object.entries(phaseContract.checks)) {
      if (passed) {
        pass(name);
      } else {
        fail(name, phaseFailureByCheck[name] ?? `${name}_failed`);
      }
    }
    checks.shared_task_phase = task.phase;
    checks.shared_task_mode = task.mode;
    checks.channel_id = task.channelId;
  }

  const taskIdentity = existsSync(taskDirectory)
    ? await taskSetIdentity(taskDirectory)
    : { count: 0, sha256: null, names: [] };
  checks.task_count = taskIdentity.count;
  checks.task_set_sha256 = taskIdentity.sha256;
  checks.current_task_preserved =
    taskIdentity.names.includes(`${expected.taskId}.json`);
  if (!checks.current_task_preserved) {
    fail("current_task_preserved", "current_task_missing");
  } else {
    pass("current_task_preserved");
  }

  const csvSha256 = await hashFile(expected.csvPath);
  checks.csv_sha256 = csvSha256;
  if (csvSha256 !== expected.csvSha256) {
    fail("csv_hash_matches", "csv_hash_mismatch");
  } else {
    pass("csv_hash_matches");
  }
  const csvHits = await findActiveHashHits(
    join(expected.localRoot, "runtime-dsh-web"),
    expected.csvSha256,
  );
  checks.csv_preflight_hit_count = csvHits.length;
  checks.csv_uncached = csvHits.length === 0;
  if (!checks.csv_uncached) {
    fail("csv_uncached", "csv_already_cached_or_attached");
  } else {
    pass("csv_uncached");
  }

  const serverInfoPath = join(
    expected.localRoot,
    "runtime-dsh-web",
    "server-info.json",
  );
  let serverPid = null;
  if (existsSync(serverInfoPath)) {
    try {
      const serverInfo = JSON.parse(
        (await readFile(serverInfoPath, "utf8")).replace(/^\uFEFF/u, ""),
      );
      serverPid = Number(serverInfo.pid);
    } catch {
      serverPid = null;
    }
  }
  checks.runtime_process_alive = processAlive(serverPid);
  if (checks.runtime_process_alive) {
    fail("runtime_stopped", "runtime_process_alive");
  } else {
    pass("runtime_stopped");
  }

  checks.execution_started = false;
  checks.authorized_runs_remaining = 0;
  checks.real_thread_run_count = 0;
  checks.thread_api_calls = 0;
  checks.runtime_started = false;
  checks.status =
    failureReasons.length === 0 ? "dry_run_passed" : "dry_run_failed";
  const completedAt = new Date();
  const evidence = {
    schema_version: "1.0",
    dry_run: true,
    status: checks.status,
    started_at: startedAt.toISOString(),
    completed_at: completedAt.toISOString(),
    duration_ms: completedAt.getTime() - startedAt.getTime(),
    execution_started: false,
    authorized_runs_remaining: 0,
    real_thread_run_count: 0,
    thread_api_calls: 0,
    runtime_started: false,
    thread_sha256: threadSha256,
    expected,
    runtime_paths: runtimePaths,
    checks,
    failure_reasons: failureReasons,
  };
  await mkdir(dirname(evidencePath), { recursive: true });
  await writeFile(
    evidencePath,
    `${JSON.stringify(evidence, null, 2)}\n`,
    { encoding: "utf8", mode: 0o600 },
  );
  return {
    ok: failureReasons.length === 0,
    evidencePath,
    evidence,
  };
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const result = await runPreflight(options);
  process.stdout.write(`${JSON.stringify({
    ok: result.ok,
    dry_run: true,
    status: result.evidence.status,
    execution_started: false,
    authorized_runs_remaining: 0,
    real_thread_run_count: 0,
    thread_api_calls: 0,
    runtime_started: false,
    failure_reasons: result.evidence.failure_reasons,
    evidence_path: result.evidencePath,
  })}\n`);
  if (!result.ok) process.exitCode = 1;
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  await main();
}
