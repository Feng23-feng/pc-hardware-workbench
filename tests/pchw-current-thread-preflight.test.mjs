import assert from "node:assert/strict";
import {
  evaluatePreflightPhaseContract,
  readPersistedTaskBinding,
  resolveRuntimePackagePaths,
} from "../scripts/preflight-pchw-current-user-thread-gate.mjs";

const pointer =
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\SkillDock.exe";
const paths = resolveRuntimePackagePaths(pointer);

assert.equal(
  paths.packageRoot,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353",
);
assert.equal(paths.launcherPath, pointer);
assert.equal(
  paths.serverPath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\app\\server.mjs",
);
assert.equal(
  paths.appPath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\app\\public\\app.js",
);
assert.equal(
  paths.indexPath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\app\\public\\index.html",
);
assert.equal(
  paths.runtimeBindingPath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\app\\public\\runtime-binding.js",
);
assert.equal(
  paths.sourceHostedPhasePath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\app\\public\\source-hosted-phase.js",
);
assert.equal(
  paths.nodePath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\Runtime-0.1.0-dev-20261117191353\\node\\node.exe",
);
assert.equal(
  paths.serverPath,
  `${paths.packageRoot}\\app\\server.mjs`,
);
assert.notEqual(
  paths.serverPath,
  "C:\\Users\\Example\\AppData\\Local\\SkillDock\\app\\server.mjs",
);

const binding = readPersistedTaskBinding({
  task: {
    task_id: "task-pchw-fixture",
    shared_task: {
      mode: "source_hosted",
      phase: "source_owned",
      channel_id: "chat:source-hosted:thread-fixture",
      source_session_ref: "thread-fixture",
      environment_thread_id: "thread-fixture",
    },
  },
});
assert.deepEqual(binding, {
  taskId: "task-pchw-fixture",
  sourceSessionRef: "thread-fixture",
  environmentThreadId: "thread-fixture",
  mode: "source_hosted",
  phase: "source_owned",
  channelId: "chat:source-hosted:thread-fixture",
});

const blockedPhase = evaluatePreflightPhaseContract(
  {
    mode: "source_hosted",
    phase: "source_agent_pulled",
    channelId: "chat:source-hosted:thread-fixture",
  },
  "thread-fixture",
);
assert.equal(blockedPhase.ok, false);
assert.deepEqual(blockedPhase.failureReasons, ["phase_not_submittable"]);
assert.equal(blockedPhase.checks.phase_submittable, false);

const allowedPhase = evaluatePreflightPhaseContract(
  {
    mode: "source_hosted",
    phase: "source_owned",
    channelId: "chat:source-hosted:thread-fixture",
  },
  "thread-fixture",
);
assert.equal(allowedPhase.ok, true);

console.log("PCHW current-user-Thread preflight path derivation: PASS");
