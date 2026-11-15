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
      skill_version: "2.7.4",
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

for (const scriptName of [
  "analyze-telemetry.ps1",
  "render-telemetry-chart.ps1",
]) {
  assertPathContained(join("scripts", scriptName), scriptName);
}

const runtimeModule = await import(`${pathToFileURL(runtimePath).href}?test`);
assert.equal(typeof runtimeModule.createRuntime, "function");
assert.equal(runtimeModule.CAPABILITY, capability.id);

const tempRoot = mkdtempSync(join(tmpdir(), "pcwb-runtime-"));
try {
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

  assert.equal(runtime.identity.skill_id, manifest.skill.id);
  assert.equal(
    runtime.broker.analyzerPath,
    join(skillRoot, "scripts", "analyze-telemetry.ps1"),
  );
  assert.equal(
    runtime.broker.rendererPath,
    join(skillRoot, "scripts", "render-telemetry-chart.ps1"),
  );
  assert.ok(isInside(tempRoot, runtime.evidence.filePath));
  assert.ok(isInside(tempRoot, runtime.broker.artifactRoot));

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
  assert.ok(task.domain_refs.includes(attachment.id));
  assert.equal(runtime.evidence.deviceContext().collector_runs, 0);

  const request = createPermissionRequest({
    capability: capability.id,
    presentation: { title: "fixture" },
    taskId,
    attachment,
    window: { warmup_seconds: 0, duration_seconds: 30 },
    now: Date.parse("2026-11-15T00:00:00Z"),
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
