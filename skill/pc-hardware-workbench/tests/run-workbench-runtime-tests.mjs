import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  existsSync,
  readFileSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  statSync,
} from "node:fs";
import { tmpdir } from "node:os";
import {
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  artifactRootRef,
  capabilityGrantMatches,
  consumeCapabilityGrant,
  createCapabilityGrant,
  createPermissionRequest,
} from "../capability-grants.mjs";
import { SharedEvidenceStore } from "../shared-evidence-store.mjs";
import { verifiedBlocks } from "../telemetry-broker.mjs";

const skillRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const readJson = (path) => JSON.parse(readFileSync(path, "utf8"));

function isInside(root, candidate) {
  const relativePath = relative(resolve(root), resolve(candidate));
  return relativePath === "" ||
    (!relativePath.startsWith("..") && !isAbsolute(relativePath));
}

function assertPathContained(relativePath, label, { directory = false } = {}) {
  const candidate = resolve(skillRoot, relativePath);
  assert.ok(existsSync(candidate), `${label} does not exist`);
  const realCandidate = realpathSync(candidate);
  const realRoot = realpathSync(skillRoot);
  assert.ok(isInside(realRoot, realCandidate), `${label} escapes the Skill root`);
  if (directory) {
    assert.ok(statSync(realCandidate).isDirectory(), `${label} is not a directory`);
  }
  else {
    assert.ok(statSync(realCandidate).isFile(), `${label} is not a file`);
  }
  return candidate;
}

function typeMatches(value, type) {
  if (type === "null") return value === null;
  if (type === "array") return Array.isArray(value);
  if (type === "object") {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }
  if (type === "integer") return Number.isInteger(value);
  return typeof value === type;
}

function validateAgainstSchema(value, schema, path = "$") {
  if (Object.hasOwn(schema, "const")) {
    assert.deepEqual(value, schema.const, `${path} must equal its const value`);
  }
  if (Array.isArray(schema.enum)) {
    assert.ok(schema.enum.includes(value), `${path} is outside its enum`);
  }
  if (schema.type) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    assert.ok(
      types.some((type) => typeMatches(value, type)),
      `${path} has the wrong type`,
    );
  }
  if (typeof value === "string") {
    if (schema.minLength !== undefined) {
      assert.ok(value.length >= schema.minLength, `${path} is too short`);
    }
    if (schema.maxLength !== undefined) {
      assert.ok(value.length <= schema.maxLength, `${path} is too long`);
    }
    if (schema.pattern) {
      assert.match(value, new RegExp(schema.pattern, "u"), `${path} pattern failed`);
    }
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined) {
      assert.ok(value.length >= schema.minItems, `${path} has too few items`);
    }
    if (schema.maxItems !== undefined) {
      assert.ok(value.length <= schema.maxItems, `${path} has too many items`);
    }
    if (schema.uniqueItems) {
      assert.equal(
        new Set(value.map((item) => JSON.stringify(item))).size,
        value.length,
        `${path} contains duplicate items`,
      );
    }
    if (schema.items) {
      value.forEach((item, index) => {
        validateAgainstSchema(item, schema.items, `${path}[${index}]`);
      });
    }
  }
  if (value !== null && typeof value === "object" && !Array.isArray(value)) {
    for (const key of schema.required ?? []) {
      assert.ok(Object.hasOwn(value, key), `${path}.${key} is required`);
    }
    if (schema.additionalProperties === false) {
      for (const key of Object.keys(value)) {
        assert.ok(
          Object.hasOwn(schema.properties ?? {}, key),
          `${path}.${key} is not declared by the schema`,
        );
      }
    }
    for (const [key, propertySchema] of Object.entries(schema.properties ?? {})) {
      if (Object.hasOwn(value, key)) {
        validateAgainstSchema(value[key], propertySchema, `${path}.${key}`);
      }
    }
  }
}

class TestSkillRuntimeError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "TestSkillRuntimeError";
    this.code = code;
  }
}

class TestSkillRuntime {
  createTaskState({ taskId }) {
    return {
      domain_state: {},
      domain_refs: [],
      capability_profile: {
        schema_version: "1.0",
        profile: "read-only-supervised",
        task_id: taskId,
        network: "disabled",
        general_command: "unavailable",
        system_write: "manual-only",
        capabilities: {
          "telemetry.csv.analyze": "approval-required",
        },
      },
      grants: [],
      permission_request: null,
    };
  }

  buildTaskContext({ task }) {
    return {
      skill_id: "pc-hardware-workbench",
      skill_version: "2.9.3",
      runtime_id: "pc-hardware-workbench",
      domain_context: task?.domain_state ?? {},
      domain_refs: task?.domain_refs ?? [],
    };
  }

  validatePanelResult(panel) {
    return panel;
  }
}

const manifestPath = assertPathContained("workbench.manifest.json", "manifest");
const manifest = readJson(manifestPath);
const manifestSchema = readJson(assertPathContained(
  "schemas/workbench-manifest.schema.json",
  "manifest schema",
));
const stateSchemaPath = assertPathContained(
  manifest.ui.state_schema_path,
  "UI state schema",
);
const eventSchemaPath = assertPathContained(
  manifest.ui.event_schema_path,
  "event schema",
);
const runtimePath = assertPathContained(manifest.runtime.entry, "runtime entry");
assertPathContained(manifest.skill.root, "Skill root", { directory: true });
assert.ok(runtimePath.endsWith(".mjs"), "runtime entry must be an .mjs file");
assert.ok(statSync(runtimePath).size <= 262_144, "runtime entry is too large");

const stateSchema = readJson(stateSchemaPath);
const eventSchema = readJson(eventSchemaPath);
const skillText = readFileSync(join(skillRoot, "SKILL.md"), "utf8");
const skillVersion = skillText.match(/^metadata:\s*[\s\S]*?^\s+version:\s+"([^"]+)"/m)?.[1];

validateAgainstSchema(manifest, manifestSchema);
assert.equal(manifest.schema_version, "1.0");
assert.equal(manifest.skill.id, "pc-hardware-workbench");
assert.equal(manifest.skill.version, skillVersion);
const sourceHostedContract =
  manifest.surface_contracts["pchw-source-hosted"];
assert.ok(sourceHostedContract, "pchw-source-hosted contract is missing");
assert.match(
  sourceHostedContract.contract_version,
  /^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/,
);
assert.match(
  sourceHostedContract.min_skill_version,
  /^\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?$/,
);
assert.ok(
  sourceHostedContract.required_capabilities.includes("telemetry.csv.analyze"),
  "source-hosted contract must require the telemetry capability",
);
assert.equal(manifest.permissions.default_profile.profile, "read-only-supervised");
assert.equal(manifest.permissions.default_profile.network, "disabled");
assert.equal(manifest.permissions.default_profile.general_command, "unavailable");
assert.equal(manifest.permissions.default_profile.system_write, "manual-only");
assert.equal(
  stateSchema.properties.schema_version.const,
  manifest.ui.state_schema_version,
);
assert.ok(
  eventSchema.anyOf.every(
    (entry) => entry.properties.schema_version.const ===
      manifest.ui.event_schema_version,
  ),
);

const capability = manifest.domain.capabilities.find(
  (item) => item.id === "telemetry.csv.analyze",
);
assert.ok(capability, "telemetry capability is not declared");
assert.equal(capability.kind, "broker");
assert.equal(capability.implementation, "telemetry-broker");
assert.deepEqual(
  [...capability.permissions].sort(),
  ["artifact_write", "local_file_read"],
);
assert.ok(
  manifest.permissions.required.some(
    (item) =>
      item.capability === capability.id &&
      item.scope === "action",
  ),
);

const chartPackAnalysis = {
  analyzed_rows: 120,
  window: "0-120 s",
  sampled_span_seconds: 120,
  sampling: {
    Consistency: "stable",
    IntervalSecondsMedian: 1,
  },
  warnings: [],
  categorical_columns: [],
  metrics: [
    {
      metric: "GPU power (W)",
      source_column: "GPU Power [W]",
      unit: "W",
      samples: 120,
      min: 10,
      mean: 100,
      max: 150,
    },
  ],
};
const chartPackArtifacts = Array.from({ length: 4 }, (_, index) => ({
  id: `artifact-pack-${index + 1}`,
  title: `Evidence chart ${index + 1}`,
}));
const chartPackBlocks = verifiedBlocks(
  chartPackAnalysis,
  chartPackArtifacts,
);
assert.equal(
  chartPackBlocks.filter((block) => block.type === "chart").length,
  4,
  "multi-artifact pack must produce one chart block per artifact",
);
assert.equal(
  chartPackBlocks.filter((block) => block.type === "artifact-download").length,
  4,
  "multi-artifact pack must expose each verified artifact",
);
assert.ok(
  chartPackBlocks.length <= 12,
  "multi-artifact blocks must remain within the UI schema limit",
);
const warningPackBlocks = verifiedBlocks(
  {
    ...chartPackAnalysis,
    warnings: ["one", "two", "three", "four"],
  },
  Array.from({ length: 5 }, (_, index) => ({
    id: `artifact-warning-pack-${index + 1}`,
    title: `Evidence chart ${index + 1}`,
  })),
);
assert.equal(
  warningPackBlocks.filter((block) => block.type === "chart").length,
  5,
);
assert.equal(
  warningPackBlocks.filter((block) => block.type === "artifact-download").length,
  5,
);
assert.ok(
  warningPackBlocks.length <= 12,
  "warning-heavy five-chart packs must fit the UI schema",
);

for (const scriptName of [
  "analyze-telemetry.ps1",
  "render-telemetry-chart.ps1",
  "render-telemetry-pack.ps1",
  "render-memory-basis.ps1",
  "render-tuning-conclusion.ps1",
]) {
  assertPathContained(join("scripts", scriptName), scriptName);
}

const runtimeModule = await import(`${pathToFileURL(runtimePath).href}?test`);
assert.equal(typeof runtimeModule.createRuntime, "function");
assert.equal(runtimeModule.CAPABILITY, capability.id);
assert.equal(typeof runtimeModule.enforceSafetyStateContract, "function");
assert.equal(typeof runtimeModule.enforceDisplayEvidenceContract, "function");
assert.equal(
  typeof runtimeModule.analysisFailure,
  "function",
  "analysis failure mapping must be directly regression-testable",
);

const normalRecommendation = {
  id: "runtime-acoustic-check",
  title: "记录风扇噪音",
  detail: "保持相同负载记录风扇噪音与转速变化。",
  risk: "low",
  evidence_goal: "确认噪音是否与转速同步。",
};
const normalPanel = {
  schema_version: "1.2",
  status: "ready",
  question: null,
  current_goal: "检查稳定后的风扇噪音",
  judgement: "当前先记录风扇噪音与转速的关系。",
  evidence: [],
  uncertainty: [],
  recommendations: [normalRecommendation],
  priorityAction: {
    title: "记录一次噪音与转速",
    detail: "保持相同负载观察两者是否同步变化。",
  },
  actions: [],
  artifact_refs: [],
  blocks: [],
};

const displayPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "游戏中黑屏并掉帧",
    recommendations: [
      {
        id: "agent-display-context",
        title: "记录当前显示异常",
        detail: "记录黑屏和掉帧发生的时间与场景。",
        risk: "low",
        evidence_goal: "建立当前显示证据。",
      },
    ],
  },
  {
    task_context: { objective: "游戏中黑屏并掉帧" },
  },
);
assert.deepEqual(
  displayPanel.recommendations,
  [
    {
      id: "agent-display-context",
      title: "记录当前显示异常",
      detail: "记录黑屏和掉帧发生的时间与场景。",
      risk: "low",
      evidence_goal: "建立当前显示证据。",
    },
  ],
  "Runtime must not infer display evidence recommendations",
);
assert.equal(
  displayPanel.priorityAction.title,
  normalPanel.priorityAction.title,
  "Runtime must preserve the Agent-authored priority action",
);

const hazardPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "游戏掉帧，电脑有明显异味且插头过热",
    recommendations: [normalRecommendation],
  },
  {
    task_context: { objective: "游戏掉帧，电脑有明显异味且插头过热" },
  },
);
assert.equal(
  hazardPanel.status,
  "blocked",
  "an independently detected physical hazard must force blocked status",
);
assert.match(
  hazardPanel.priorityAction.title,
  /停止|断电|断开/u,
  "physical hazard must force a stop action",
);
assert.equal(
  hazardPanel.actions.length,
  0,
  "physical hazard must suppress routine copy actions",
);
assert.equal(
  hazardPanel.recommendations.some(
    (item) => item.id === normalRecommendation.id,
  ),
  false,
  "physical hazard must not retain routine recommendations",
);

const negatedHazardPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "没有焦味和冒烟，只是风扇噪音偏大",
    recommendations: [normalRecommendation],
  },
  {
    task_context: { objective: "没有焦味和冒烟，只是风扇噪音偏大" },
  },
);
assert.deepEqual(
  negatedHazardPanel,
  {
    ...normalPanel,
    current_goal: "没有焦味和冒烟，只是风扇噪音偏大",
    recommendations: [normalRecommendation],
  },
  "a negated hazard must not trigger the physical safety stop",
);

const historicalHazardPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "此前冒烟已经修复，现在检查风扇噪音",
    recommendations: [normalRecommendation],
  },
  {
    task_context: {
      objective: "此前冒烟已经修复，现在检查风扇噪音",
    },
    history: [{ summary: "以前闻到焦味" }],
  },
);
assert.equal(
  historicalHazardPanel.status,
  "ready",
  "historical packet text alone must not force a current safety stop",
);

const mixedHazardPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "没有焦味且有火花",
    recommendations: [normalRecommendation],
  },
  {
    task_context: { objective: "没有焦味且有火花" },
  },
);
assert.equal(
  mixedHazardPanel.status,
  "blocked",
  "negating one hazard must not hide a different current physical hazard",
);

const originalObjectiveHazardPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "检查游戏掉帧",
    recommendations: [normalRecommendation],
  },
  {
    task_context: { objective: "电脑冒烟，有火花" },
  },
);
assert.equal(
  originalObjectiveHazardPanel.status,
  "blocked",
  "an Agent summary must not hide a physical hazard in the user's objective",
);

const smokeTestLabelPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    current_goal: "确认卡顿最明显的使用场景",
  },
  {
    task_context: {
      objective: "P2A signed handoff smoke。确认卡顿最明显的使用场景",
    },
  },
);
assert.equal(
  smokeTestLabelPanel.status,
  "ready",
  "technical smoke-test labels must not be treated as physical smoke",
);

const ordinaryBlockedPanel = {
  ...normalPanel,
  status: "blocked",
  current_goal: "当前没有权限读取传感器数据",
  result_title: "需要只读权限后才能继续",
  recommendations: [normalRecommendation],
  priorityAction: {
    title: "允许一次只读分析",
    detail: "重新授权当前附件后继续检查。",
  },
  actions: [
    {
      id: "copy-permission-step",
      label: "复制授权步骤",
      kind: "copy",
      content: "在当前 Task 中允许一次只读分析。",
    },
  ],
};
assert.deepEqual(
  runtimeModule.enforceSafetyStateContract(ordinaryBlockedPanel, {
    task_context: { objective: "当前没有权限读取传感器数据" },
  }),
  ordinaryBlockedPanel,
  "ordinary blocked states must not be converted into a physical safety stop",
);

const ordinaryStopPanel = {
  ...normalPanel,
  current_goal: "下载官方驱动",
  priorityAction: {
    title: "停止运行后台下载",
    detail: "结束下载进程后重新选择官方页面。",
  },
};
assert.deepEqual(
  runtimeModule.enforceSafetyStateContract(ordinaryStopPanel, {
    task_context: { objective: "下载官方驱动" },
  }),
  ordinaryStopPanel,
  "a non-physical stop action must not trigger the physical safety stop",
);

const contradictoryHazardPanel = runtimeModule.enforceSafetyStateContract(
  {
    ...normalPanel,
    status: "blocked",
    current_goal: "没有焦味且有火花",
    result_title: "停止测试",
    recommendations: [normalRecommendation],
    priorityAction: {
      title: "停止测试",
      detail: "然后继续通电复测。",
    },
    actions: [
      {
        id: "copy-hazard-step",
        label: "复制",
        kind: "copy",
        content: "继续通电复测",
      },
    ],
  },
  {
    task_context: { objective: "没有焦味且有火花" },
  },
);
assert.equal(contradictoryHazardPanel.status, "blocked");
assert.equal(
  contradictoryHazardPanel.priorityAction.title,
  "立即停止使用并断开电源",
  "a confirmed physical hazard must use the canonical stop action",
);
assert.doesNotMatch(
  contradictoryHazardPanel.priorityAction.detail,
  /然后继续|继续通电复测|重新通电/u,
  "an Agent-authored stop detail must not bypass the safety contract",
);
assert.deepEqual(
  contradictoryHazardPanel.recommendations.map((item) => item.id),
  ["runtime-safety-stop"],
  "a confirmed physical hazard must replace routine recommendations",
);
assert.deepEqual(
  contradictoryHazardPanel.actions,
  [],
  "a confirmed physical hazard must suppress routine copy actions",
);

for (const [code, titlePattern, copyPattern] of [
  ["analysis_timeout", /超时/u, /缩小分析窗口|时间窗口/u],
  ["analysis_runner_error", /无法启动/u, /PowerShell|分析环境/u],
  ["attachment_hash_mismatch", /完整性|哈希/u, /重新添加|原始文件/u],
  ["analysis_source_binding_mismatch", /来源|绑定/u, /重新分析|当前附件/u],
  ["no_usable_series", /传感器列/u, /重新导出/u],
]) {
  const failure = runtimeModule.analysisFailure(
    {
      current_goal: "分析当前 CSV",
      status: "needs_input",
    },
    Object.assign(new Error(`fixture ${code}`), { code }),
    "分析当前 CSV",
  );
  assert.match(failure.result_title, titlePattern);
  assert.doesNotMatch(
    failure.turn_summary,
    /没有提供足够明确的传感器列/u,
    `${code} must not be misreported as a sensor-column problem`,
  );
  assert.match(
    `${failure.priorityAction.title} ${failure.priorityAction.detail}`,
    copyPattern,
  );
  assert.equal(failure.recommendations.length, 2);
}

const tempRoot = mkdtempSync(join(tmpdir(), "pcwb-runtime-"));
try {
  const lazyStoreRoot = join(tempRoot, "lazy-evidence");
  const lazyStorePath = join(lazyStoreRoot, "shared-evidence.json");
  const lazyStore = new SharedEvidenceStore(lazyStorePath);
  assert.equal(
    existsSync(lazyStoreRoot),
    false,
    "reading an empty evidence store must not create its directory",
  );
  assert.equal(lazyStore.deviceContext().device_snapshot_ref, "device-snapshot:not-collected");
  lazyStore.addEvidence({
    label: "fixture",
    detail: "first persisted evidence",
    source: "runtime-test",
  });
  assert.equal(
    existsSync(lazyStorePath),
    true,
    "the first real evidence write must create the store",
  );
  const reopenedStore = new SharedEvidenceStore(lazyStorePath);
  assert.equal(reopenedStore.evidenceIds().length, 1);
  reopenedStore.addAttachment({
    id: "attachment-lazy-store",
    original_name: "fixture.csv",
    mime_type: "text/csv",
    size: 4,
    sha256: "c".repeat(64),
    local_path: join(tempRoot, "fixture.csv"),
    added_at: new Date().toISOString(),
  });
  assert.equal(
    new SharedEvidenceStore(lazyStorePath).evidenceIds().length,
    2,
    "an existing store must remain readable and appendable",
  );

  const runtime = await runtimeModule.createRuntime({
    SkillRuntime: TestSkillRuntime,
    SkillRuntimeError: TestSkillRuntimeError,
    manifest: {
      ...manifest,
      resolved: { manifest_hash: createHash("sha256").update("runtime").digest("hex") },
    },
    projectRoot: skillRoot,
    skillRoot,
    runtimeDir: tempRoot,
    attachmentRoot: join(tempRoot, "attachments"),
    artifactRoot: join(tempRoot, "artifacts"),
  });
  assert.equal(
    existsSync(join(tempRoot, "shared-evidence.json")),
    false,
    "read-only Runtime initialization must not create an evidence store",
  );

  assert.equal(runtime.identity.skill_id, manifest.skill.id);
  assert.deepEqual(
    runtime.identity.surface_contracts["pchw-source-hosted"],
    sourceHostedContract,
  );
  assert.match(
    runtime.promptInstructions().join("\n"),
    /uncertainty\[0\].*current unresolved item.*never hard-code/isu,
    "runtime prompt must derive the current unresolved status from evidence",
  );
  assert.equal(
    runtime.broker.analyzerPath,
    join(skillRoot, "scripts", "analyze-telemetry.ps1"),
  );
  assert.equal(
    runtime.broker.rendererPath,
    join(skillRoot, "scripts", "render-telemetry-chart.ps1"),
  );
  assert.equal(
    runtime.broker.packScriptPath,
    join(skillRoot, "scripts", "render-telemetry-pack.ps1"),
  );
  assert.ok(isInside(tempRoot, runtime.evidence.filePath));
  assert.ok(isInside(tempRoot, runtime.broker.artifactRoot));

  const sourceSummaryHash = "d".repeat(64);
  const sourceSummaryAnalysis = {
    source_sha256: sourceSummaryHash,
    source_bytes: 128,
    analyzer_passes: 1,
    analyzer_pass_reason: "standard",
    analyzed_rows: 4,
    window: "rows 0 to 3",
  };
  const sourceSummaryPanel = {
    ...normalPanel,
    artifact_refs: [],
  };
  const originalApplyVerifiedResult = runtime.broker.applyVerifiedResult;
  const originalValidatePanelResult = runtime.validatePanelResult;
  try {
    runtime.broker.applyVerifiedResult = (panel, result, { taskId }) => {
      assert.equal(taskId, "task-source-summary");
      assert.deepEqual(result.artifacts, []);
      assert.equal(result.chart_preset, null);
      return { ...panel, artifact_refs: [], blocks: [] };
    };
    runtime.validatePanelResult = (panel) => panel;
    const summaryCompletion = runtime.completeSourceHostedAgentResult({
      task: { task_id: "task-source-summary" },
      panel: sourceSummaryPanel,
      packet: {
        attachment_id: "attachment-source-summary",
        tool_result: {
          chart_preset: null,
          attachment: { sha256: sourceSummaryHash },
          analysis: sourceSummaryAnalysis,
        },
      },
      localResult: {
        chart_preset: null,
        attachment: { sha256: sourceSummaryHash },
        analysis: sourceSummaryAnalysis,
        artifact: null,
        artifacts: [],
      },
    });
    assert.deepEqual(summaryCompletion.artifact_refs, []);
    assert.deepEqual(summaryCompletion.blocks, []);

    assert.throws(
      () =>
        runtime.completeSourceHostedAgentResult({
          task: { task_id: "task-source-summary" },
          panel: sourceSummaryPanel,
          packet: {
            tool_result: {
              chart_preset: "FirstPass",
              attachment: { sha256: sourceSummaryHash },
              analysis: sourceSummaryAnalysis,
            },
          },
          localResult: {
            chart_preset: "FirstPass",
            attachment: { sha256: sourceSummaryHash },
            analysis: sourceSummaryAnalysis,
            artifact: null,
            artifacts: [],
          },
        }),
      (error) => error.code === "source_result_missing_verified_tool",
      "explicit chart completion must still require a verified artifact",
    );

    assert.throws(
      () =>
        runtime.completeSourceHostedAgentResult({
          task: { task_id: "task-source-summary" },
          panel: sourceSummaryPanel,
          packet: {
            tool_result: {
              chart_preset: null,
              attachment: { sha256: sourceSummaryHash },
              analysis: sourceSummaryAnalysis,
            },
          },
          localResult: {
            chart_preset: null,
            attachment: { sha256: sourceSummaryHash },
            analysis: {
              ...sourceSummaryAnalysis,
              source_sha256: "e".repeat(64),
            },
            artifact: null,
            artifacts: [],
          },
        }),
      (error) => error.code === "source_result_invalid_analysis",
      "summary completion must reject an analysis from another source",
    );
  } finally {
    runtime.broker.applyVerifiedResult = originalApplyVerifiedResult;
    runtime.validatePanelResult = originalValidatePanelResult;
  }

  const preauthTask = runtime.createTaskState({
    taskId: "task-runtime-preauth",
  });
  preauthTask.task_id = "task-runtime-preauth";
  const preauthAttachment = {
    id: "attachment-runtime-preauth",
    original_name: "telemetry.csv",
    mime_type: "text/csv",
    size: 20,
    sha256: "c".repeat(64),
    local_path: join(tempRoot, "preauth-telemetry.csv"),
    added_at: new Date().toISOString(),
  };
  let preauthReads = 0;
  const preauthHost = {
    events: [],
    panel: null,
    appendEvent(event) {
      this.events.push(event);
    },
    save() {},
    setPanel(panel) {
      this.panel = panel;
    },
    getPanel() {
      return this.panel;
    },
    setError() {},
    pushTimeline() {},
    archive() {},
    getSessionReference() {
      return "session-runtime-preauth";
    },
    isSourceHosted() {
      return false;
    },
    buildTaskContext() {
      return { skill_id: "pc-hardware-workbench" };
    },
  };
  const originalFindCached = runtime.broker.findCached;
  const originalValidateAttachment = runtime.broker.validateAttachment;
  const originalRequireCapability = runtime.requireCapability;
  let preauthOutcome;
  try {
    runtime.requireCapability = () => {};
    runtime.broker.findCached = () => null;
    runtime.broker.validateAttachment = () => {
      preauthReads += 1;
      return { actualHash: preauthAttachment.sha256 };
    };
    preauthOutcome = await runtime.runLocalAction({
      actionId: capability.id,
      input: {},
      task: preauthTask,
      attachment: preauthAttachment,
      host: preauthHost,
    });
  } finally {
    runtime.requireCapability = originalRequireCapability;
    runtime.broker.findCached = originalFindCached;
    runtime.broker.validateAttachment = originalValidateAttachment;
  }
  assert.equal(
    preauthOutcome.statusCode,
    403,
    "uncached attachment analysis should request permission",
  );
  assert.equal(
    preauthReads,
    0,
    "attachment content must not be read before permission is granted",
  );

  const taskId = "task-runtime-test";
  const task = runtime.createTaskState({ taskId });
  task.task_id = taskId;
  assert.equal(task.domain_state.device_snapshot_ref, "device-snapshot:not-collected");
  const attachment = {
    id: "attachment-runtime-test",
    original_name: "telemetry.csv",
    mime_type: "text/csv",
    size: 20,
    sha256: "a".repeat(64),
    local_path: join(tempRoot, "telemetry.csv"),
    added_at: new Date().toISOString(),
  };
  runtime.commitAttachments({ task, attachments: [attachment] });
  assert.equal(
    existsSync(join(tempRoot, "shared-evidence.json")),
    true,
    "committing a real attachment must persist evidence",
  );
  assert.ok(task.domain_refs.includes(attachment.id));
  assert.equal(runtime.evidence.deviceContext().collector_runs, 0);

  const request = createPermissionRequest({
    capability: capability.id,
    presentation: { title: "fixture" },
    taskId,
    attachment,
    window: { warmup_seconds: 0, duration_seconds: 30 },
    continuation: {
      action_id: capability.id,
      attachment_id: attachment.id,
      window: { warmup_seconds: 0, duration_seconds: 30 },
    },
    now: Date.parse("2026-11-15T00:00:00Z"),
  });
  assert.deepEqual(request.continuation, {
    action_id: capability.id,
    attachment_id: attachment.id,
    window: { warmup_seconds: 0, duration_seconds: 30 },
  });
  const grant = createCapabilityGrant({
    request,
    scope: "one-time",
    now: Date.parse("2026-11-15T00:00:00Z"),
  });
  assert.equal(
    grant.artifact_root_ref,
    artifactRootRef(taskId),
  );
  assert.ok(
    capabilityGrantMatches(grant, {
      taskId,
      attachment,
      capability: capability.id,
      artifactRootRef: artifactRootRef(taskId),
      window: { warmup_seconds: 0, duration_seconds: 30 },
      now: Date.parse("2026-11-15T00:00:01Z"),
    }),
  );
  assert.ok(
    !capabilityGrantMatches(grant, {
      taskId,
      attachment: { ...attachment, sha256: "b".repeat(64) },
      capability: capability.id,
      artifactRootRef: artifactRootRef(taskId),
      window: { warmup_seconds: 0, duration_seconds: 30 },
      now: Date.parse("2026-11-15T00:00:01Z"),
    }),
  );
  assert.equal(consumeCapabilityGrant(grant).status, "consumed");

  const permissionHost = {
    events: [],
    appendEvent(event) {
      this.events.push(event);
    },
    save() {},
  };
  const firstPermissionTask = runtime.createTaskState({
    taskId: "task-runtime-first-permission",
  });
  firstPermissionTask.task_id = "task-runtime-first-permission";
  const firstPermissionRequest = runtime.ensurePermissionRequest(
    firstPermissionTask,
    attachment,
    { warmup_seconds: 0, duration_seconds: 30 },
    permissionHost,
  );
  assert.equal(
    firstPermissionRequest.presentation.allow_task_available,
    false,
    "first analysis must not expose a reusable attachment grant",
  );
  assert.equal(
    firstPermissionRequest.presentation.allow_task_label,
    "同一附件后续分析",
  );
  const prematureTaskGrant = await runtime.decidePermission({
    task: firstPermissionTask,
    body: {
      request_id: firstPermissionRequest.request_id,
      decision: "allow_task",
    },
    host: permissionHost,
  });
  assert.equal(prematureTaskGrant.statusCode, 409);

  const repeatPermissionTask = runtime.createTaskState({
    taskId: "task-runtime-repeat-permission",
  });
  repeatPermissionTask.task_id = "task-runtime-repeat-permission";
  repeatPermissionTask.actions = [];
  repeatPermissionTask.actions.push({
    action_id: capability.id,
    attachment_id: attachment.id,
    source_sha256: attachment.sha256,
    artifact_id: "artifact-runtime-repeat",
    permission_scope: "one-time",
    local_completed_at: "2026-11-15T00:01:00Z",
  });
  const repeatPermissionRequest = runtime.ensurePermissionRequest(
    repeatPermissionTask,
    attachment,
    { warmup_seconds: 0, duration_seconds: 60 },
    permissionHost,
  );
  assert.equal(
    repeatPermissionRequest.presentation.allow_task_available,
    true,
    "completed one-time analysis should enable repeat analysis",
  );
  const repeatTaskGrant = await runtime.decidePermission({
    task: repeatPermissionTask,
    body: {
      request_id: repeatPermissionRequest.request_id,
      decision: "allow_task",
    },
    host: permissionHost,
  });
  assert.equal(repeatTaskGrant.statusCode, 200);
  assert.equal(repeatPermissionTask.grants.at(-1).scope, "task");

  const differentAttachmentTask = runtime.createTaskState({
    taskId: "task-runtime-other-attachment",
  });
  differentAttachmentTask.task_id = "task-runtime-other-attachment";
  differentAttachmentTask.actions = [];
  differentAttachmentTask.actions.push({
    action_id: capability.id,
    attachment_id: attachment.id,
    source_sha256: attachment.sha256,
    artifact_id: "artifact-runtime-original",
    permission_scope: "one-time",
    local_completed_at: "2026-11-15T00:01:00Z",
  });
  const differentAttachmentRequest = runtime.ensurePermissionRequest(
    differentAttachmentTask,
    { ...attachment, id: "attachment-runtime-other", sha256: "b".repeat(64) },
    { warmup_seconds: 0, duration_seconds: 30 },
    permissionHost,
  );
  assert.equal(
    differentAttachmentRequest.presentation.allow_task_available,
    false,
    "a different attachment must require a new one-time analysis",
  );
} finally {
  rmSync(tempRoot, { recursive: true, force: true });
}

for (const file of [
  "runtime.mjs",
  "capability-grants.mjs",
  "shared-evidence-store.mjs",
  "telemetry-broker.mjs",
]) {
  const source = readFileSync(join(skillRoot, file), "utf8");
  assert.doesNotMatch(
    source,
    /\b(?:codex|dsh|deepseek|openai|anthropic|app-server|cookie|oauth)\b/i,
    `${file} contains provider-specific logic`,
  );
  assert.doesNotMatch(source, /\bfetch\s*\(/u, `${file} contains network transport`);
}

console.log("Workbench runtime contract: PASS");
