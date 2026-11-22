import {
  existsSync,
  readFileSync,
  realpathSync,
  statSync,
} from "node:fs";
import { createHash } from "node:crypto";
import {
  isAbsolute,
  relative,
  resolve,
} from "node:path";

const MAX_MANIFEST_BYTES = 131_072;
const BLOCK_TYPES = new Set([
  "markdown",
  "metrics",
  "chart",
  "table",
  "callout",
  "artifact-download",
]);

function fail(code, message) {
  const error = new Error(message);
  error.code = code;
  throw error;
}

function isRecord(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function assertRecord(value, path, keys) {
  if (!isRecord(value)) fail("manifest_invalid", `${path} must be an object`);
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  if (
    actual.length !== expected.length ||
    actual.some((key, index) => key !== expected[index])
  ) {
    fail("manifest_invalid", `${path} has unsupported or missing fields`);
  }
}

function assertString(value, path, pattern, max = 512) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > max ||
    (pattern && !pattern.test(value))
  ) {
    fail("manifest_invalid", `${path} is not a valid string`);
  }
  return value;
}

function assertStringArray(value, path, { min = 0, max = 32, pattern } = {}) {
  if (
    !Array.isArray(value) ||
    value.length < min ||
    value.length > max ||
    value.some((item) => typeof item !== "string" || !pattern.test(item)) ||
    new Set(value).size !== value.length
  ) {
    fail("manifest_invalid", `${path} is not a valid unique string array`);
  }
  return value;
}

function assertSemver(value, path) {
  return assertString(
    value,
    path,
    /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/u,
    64,
  );
}

function isInsideRoot(root, candidate) {
  const rel = relative(root, candidate);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function resolveContained(root, base, value, label, { dir = false } = {}) {
  const unresolved = isAbsolute(value) ? value : resolve(base, value);
  const resolved = existsSync(unresolved) ? realpathSync(unresolved) : unresolved;
  if (!isInsideRoot(root, resolved)) {
    fail("manifest_path_escape", `${label} escapes the allowed manifest root`);
  }
  if (!existsSync(resolved)) {
    fail("manifest_path_missing", `${label} does not exist`);
  }
  const stats = statSync(resolved);
  if (dir ? !stats.isDirectory() : !stats.isFile()) {
    fail("manifest_path_type", `${label} has the wrong file type`);
  }
  return resolved;
}

function validateManifest(manifest, manifestPath, allowedRoot, manifestHash) {
  const manifestKeys = [
    "schema_version",
    "skill",
    "runtime",
    "ui",
    ...(manifest.surface_contracts === undefined
      ? []
      : ["surface_contracts"]),
    "artifacts",
    "domain",
    "permissions",
    "components",
    "resume_handoff",
    "adapter_requirements",
  ];
  assertRecord(manifest, "manifest", manifestKeys);
  if (manifest.schema_version !== "1.0") {
    fail("manifest_version", "Only Workbench Manifest 1.0 is supported");
  }
  assertRecord(manifest.skill, "skill", ["id", "name", "version", "root"]);
  assertString(manifest.skill.id, "skill.id", /^[a-z0-9][a-z0-9._-]{2,95}$/u, 96);
  assertString(manifest.skill.name, "skill.name", null, 120);
  assertString(
    manifest.skill.version,
    "skill.version",
    /^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$/u,
    64,
  );
  assertString(manifest.skill.root, "skill.root", null, 512);

  assertRecord(manifest.runtime, "runtime", ["id", "entry"]);
  assertString(
    manifest.runtime.id,
    "runtime.id",
    /^[a-z0-9][a-z0-9._-]{2,95}$/u,
    96,
  );
  assertString(manifest.runtime.entry, "runtime.entry", null, 512);

  assertRecord(manifest.ui, "ui", [
    "state_schema_version",
    "state_schema_path",
    "event_schema_version",
    "event_schema_path",
  ]);
  for (const key of Object.keys(manifest.ui)) {
    assertString(manifest.ui[key], `ui.${key}`, null, 512);
  }

  let contractRequiredCapabilities = [];
  if (manifest.surface_contracts !== undefined) {
    assertRecord(manifest.surface_contracts, "surface_contracts", [
      "pchw-source-hosted",
    ]);
    const contract = manifest.surface_contracts["pchw-source-hosted"];
    assertRecord(contract, "surface_contracts.pchw-source-hosted", [
      "contract_version",
      "min_skill_version",
      "required_capabilities",
    ]);
    assertSemver(
      contract.contract_version,
      "surface_contracts.pchw-source-hosted.contract_version",
    );
    assertSemver(
      contract.min_skill_version,
      "surface_contracts.pchw-source-hosted.min_skill_version",
    );
    contractRequiredCapabilities = assertStringArray(
      contract.required_capabilities,
      "surface_contracts.pchw-source-hosted.required_capabilities",
      {
        min: 1,
        max: 32,
        pattern: /^[a-z0-9][a-z0-9._-]{2,95}$/u,
      },
    );
  }

  assertRecord(manifest.artifacts, "artifacts", [
    "namespace",
    "allowed_kinds",
  ]);
  assertString(
    manifest.artifacts.namespace,
    "artifacts.namespace",
    /^[a-z0-9][a-z0-9._-]{1,63}$/u,
    64,
  );
  assertStringArray(
    manifest.artifacts.allowed_kinds,
    "artifacts.allowed_kinds",
    { min: 1, max: 16, pattern: /^[a-z][a-z0-9._-]{1,63}$/u },
  );

  assertRecord(manifest.domain, "domain", ["capabilities"]);
  if (!Array.isArray(manifest.domain.capabilities) || manifest.domain.capabilities.length > 32) {
    fail("manifest_invalid", "domain.capabilities must be an array");
  }
  const capabilityIds = new Set();
  for (const [index, capability] of manifest.domain.capabilities.entries()) {
    const capabilityKeys = ["id", "kind", "implementation", "permissions"];
    if (capability.ui !== undefined) capabilityKeys.push("ui");
    assertRecord(
      capability,
      `domain.capabilities[${index}]`,
      capabilityKeys,
    );
    assertString(
      capability.id,
      `domain.capabilities[${index}].id`,
      /^[a-z0-9][a-z0-9._-]{2,95}$/u,
      96,
    );
    if (!["broker", "script", "builtin"].includes(capability.kind)) {
      fail("manifest_invalid", `domain.capabilities[${index}].kind is unsupported`);
    }
    assertString(
      capability.implementation,
      `domain.capabilities[${index}].implementation`,
      /^[A-Za-z0-9][A-Za-z0-9._:/ -]{1,159}$/u,
      160,
    );
    assertStringArray(
      capability.permissions,
      `domain.capabilities[${index}].permissions`,
      { max: 16, pattern: /^[a-z][a-z0-9._-]{1,63}$/u },
    );
    if (capabilityIds.has(capability.id)) {
      fail("manifest_invalid", "domain capability ids must be unique");
    }
    capabilityIds.add(capability.id);
    if (capability.ui !== undefined) {
      assertRecord(capability.ui, `domain.capabilities[${index}].ui`, [
        "label",
        "description",
        "attachment_extensions",
      ]);
      assertString(
        capability.ui.label,
        `domain.capabilities[${index}].ui.label`,
        null,
        80,
      );
      assertString(
        capability.ui.description,
        `domain.capabilities[${index}].ui.description`,
        null,
        240,
      );
      assertStringArray(
        capability.ui.attachment_extensions,
        `domain.capabilities[${index}].ui.attachment_extensions`,
        { min: 1, max: 16, pattern: /^\.[a-z0-9]{1,12}$/u },
      );
    }
  }
  const missingContractCapabilities = contractRequiredCapabilities.filter(
    (capabilityId) => !capabilityIds.has(capabilityId),
  );
  if (missingContractCapabilities.length > 0) {
    fail(
      "manifest_invalid",
      `surface_contracts requires undeclared capabilities: ${missingContractCapabilities.join(", ")}`,
    );
  }

  assertRecord(manifest.permissions, "permissions", [
    "default_profile",
    "required",
  ]);
  assertRecord(manifest.permissions.default_profile, "permissions.default_profile", [
    "profile",
    "network",
    "general_command",
    "system_write",
  ]);
  for (const [key, value] of Object.entries(manifest.permissions.default_profile)) {
    assertString(value, `permissions.default_profile.${key}`, /^[a-z][a-z0-9._-]{1,63}$/u, 64);
  }
  if (!Array.isArray(manifest.permissions.required) || manifest.permissions.required.length > 32) {
    fail("manifest_invalid", "permissions.required must be an array");
  }
  for (const [index, requirement] of manifest.permissions.required.entries()) {
    assertRecord(requirement, `permissions.required[${index}]`, [
      "capability",
      "scope",
      "reason",
    ]);
    assertString(requirement.capability, `permissions.required[${index}].capability`, /^[a-z0-9][a-z0-9._-]{2,95}$/u, 96);
    if (!["action", "task", "session"].includes(requirement.scope)) {
      fail("manifest_invalid", `permissions.required[${index}].scope is unsupported`);
    }
    assertString(requirement.reason, `permissions.required[${index}].reason`, null, 240);
  }

  assertRecord(manifest.components, "components", ["block_types"]);
  assertStringArray(
    manifest.components.block_types,
    "components.block_types",
    { min: 1, max: 16, pattern: /^[a-z][a-z0-9._-]{1,63}$/u },
  );
  if (manifest.components.block_types.some((item) => !BLOCK_TYPES.has(item))) {
    fail("manifest_invalid", "components.block_types contains an unsupported block");
  }

  assertRecord(manifest.resume_handoff, "resume_handoff", [
    "required",
    "format",
    "includes",
  ]);
  if (typeof manifest.resume_handoff.required !== "boolean") {
    fail("manifest_invalid", "resume_handoff.required must be boolean");
  }
  if (!["markdown", "json", "both"].includes(manifest.resume_handoff.format)) {
    fail("manifest_invalid", "resume_handoff.format is unsupported");
  }
  assertStringArray(
    manifest.resume_handoff.includes,
    "resume_handoff.includes",
    { min: 1, max: 24, pattern: /^[a-z][a-z0-9._-]{1,63}$/u },
  );

  assertRecord(manifest.adapter_requirements, "adapter_requirements", [
    "required_capabilities",
    "optional_capabilities",
  ]);
  assertStringArray(
    manifest.adapter_requirements.required_capabilities,
    "adapter_requirements.required_capabilities",
    { max: 16, pattern: /^[a-z][a-z0-9._-]{1,63}$/u },
  );
  assertStringArray(
    manifest.adapter_requirements.optional_capabilities,
    "adapter_requirements.optional_capabilities",
    { max: 16, pattern: /^[a-z][a-z0-9._-]{1,63}$/u },
  );

  const skillRoot = resolveContained(
    allowedRoot,
    resolve(manifestPath, ".."),
    manifest.skill.root,
    "skill.root",
    { dir: true },
  );
  const stateSchemaPath = resolveContained(
    allowedRoot,
    resolve(manifestPath, ".."),
    manifest.ui.state_schema_path,
    "ui.state_schema_path",
  );
  const eventSchemaPath = resolveContained(
    allowedRoot,
    resolve(manifestPath, ".."),
    manifest.ui.event_schema_path,
    "ui.event_schema_path",
  );
  const runtimeEntry = resolveContained(
    allowedRoot,
    resolve(manifestPath, ".."),
    manifest.runtime.entry,
    "runtime.entry",
  );
  if (!runtimeEntry.endsWith(".mjs")) {
    fail("manifest_runtime_type", "runtime.entry must be an .mjs module");
  }
  if (statSync(runtimeEntry).size > 262_144) {
    fail("manifest_runtime_size", "runtime.entry exceeds the module size limit");
  }
  const stateSchema = JSON.parse(readFileSync(stateSchemaPath, "utf8"));
  const eventSchema = JSON.parse(readFileSync(eventSchemaPath, "utf8"));
  if (stateSchema.properties?.schema_version?.const !== manifest.ui.state_schema_version) {
    fail("manifest_schema_version", "UI state schema version does not match the manifest");
  }
  if (
    !eventSchema.anyOf?.every(
      (item) => item.properties?.schema_version?.const === manifest.ui.event_schema_version,
    )
  ) {
    fail("manifest_schema_version", "Event schema version does not match the manifest");
  }

  return {
    ...manifest,
    resolved: {
      manifest_path: manifestPath,
      skill_root: skillRoot,
      state_schema_path: stateSchemaPath,
      event_schema_path: eventSchemaPath,
      runtime_entry: runtimeEntry,
      manifest_hash: manifestHash,
    },
    stateSchema,
    eventSchema,
  };
}

function compatManifest(projectRoot, error = null) {
  const manifest = {
    schema_version: "1.0",
    skill: {
      id: "workbench.compat-fixture",
      name: "Workbench compatibility fixture",
      version: "0.0.0",
      root: ".",
    },
    runtime: {
      id: "compat-chat",
      entry: "compat-chat",
    },
    ui: {
      state_schema_version: "1.2",
      state_schema_path: "schemas/panel-ui-state.schema.json",
      event_schema_version: "1.0",
      event_schema_path: "schemas/panel-event.schema.json",
    },
    artifacts: {
      namespace: "workbench",
      allowed_kinds: ["chart", "table", "report"],
    },
    domain: { capabilities: [] },
    permissions: {
      default_profile: {
        profile: "read-only-supervised",
        network: "disabled",
        general_command: "unavailable",
        system_write: "manual-only",
      },
      required: [],
    },
    components: {
      block_types: [
        "markdown",
        "metrics",
        "chart",
        "table",
        "callout",
        "artifact-download",
      ],
    },
    resume_handoff: {
      required: true,
      format: "markdown",
      includes: [
        "task",
        "session_ref",
        "domain_context",
        "domain_refs",
        "judgement",
        "uncertainty",
        "priority_action",
        "artifact_refs",
      ],
    },
    adapter_requirements: {
      required_capabilities: ["text_input", "session_resume"],
      optional_capabilities: ["structured_output", "cancellation"],
    },
  };
  const stateSchemaPath = resolve(projectRoot, manifest.ui.state_schema_path);
  const eventSchemaPath = resolve(projectRoot, manifest.ui.event_schema_path);
  return {
    ...manifest,
    resolved: {
      manifest_path: null,
      skill_root: projectRoot,
      state_schema_path: stateSchemaPath,
      event_schema_path: eventSchemaPath,
      runtime_entry: null,
      manifest_hash: null,
    },
    stateSchema: JSON.parse(readFileSync(stateSchemaPath, "utf8")),
    eventSchema: JSON.parse(readFileSync(eventSchemaPath, "utf8")),
    status: error ? "invalid" : "compat",
    error,
  };
}

export function loadWorkbenchManifest({
  projectRoot,
  manifestPath =
    process.env.PANEL_SKILL_MANIFEST ??
    process.env.PANEL_WORKBENCH_MANIFEST,
  allowedRoot = process.env.PANEL_MANIFEST_ALLOWED_ROOT ?? projectRoot,
  fallbackPath = null,
} = {}) {
  if (!projectRoot) fail("manifest_project_root", "projectRoot is required");
  const explicit = typeof manifestPath === "string" && manifestPath.trim()
    ? resolve(manifestPath)
    : null;
  const selected = explicit ?? fallbackPath;
  if (!selected) {
    return compatManifest(projectRoot);
  }
  if (!existsSync(selected)) {
    return {
      ...compatManifest(
        projectRoot,
        explicit
          ? {
              code: "manifest_path_missing",
              message: "Configured Workbench Manifest does not exist; chat fallback is active.",
            }
          : null,
      ),
      status: explicit ? "invalid" : "compat",
    };
  }
  try {
    const root = realpathSync(resolve(allowedRoot));
    const resolvedManifest = realpathSync(selected);
    if (!isInsideRoot(root, resolvedManifest)) {
      fail("manifest_path_escape", "Manifest path escapes the allowed root");
    }
    if (statSync(resolvedManifest).size > MAX_MANIFEST_BYTES) {
      fail("manifest_too_large", "Manifest exceeds the size limit");
    }
    const manifestText = readFileSync(resolvedManifest, "utf8");
    const parsed = JSON.parse(manifestText);
    const manifestHash = createHash("sha256")
      .update(manifestText)
      .digest("hex");
    return {
      ...validateManifest(parsed, resolvedManifest, root, manifestHash),
      status: "active",
      error: null,
    };
  } catch (error) {
    return {
      ...compatManifest(projectRoot, {
        code: String(error?.code ?? "manifest_invalid"),
        message: String(error?.message ?? "Workbench Manifest validation failed")
          .slice(0, 240),
      }),
      status: "invalid",
    };
  }
}

export function publicManifestDescriptor(manifest) {
  return {
    schema_version: manifest.schema_version,
    id: manifest.skill.id,
    name: manifest.skill.name,
    version: manifest.skill.version,
    status: manifest.status,
    runtime_id: manifest.runtime.id,
    manifest_hash: manifest.resolved?.manifest_hash ?? null,
    surface_contracts: manifest.surface_contracts ?? null,
    ui: {
      state_schema_version: manifest.ui.state_schema_version,
      event_schema_version: manifest.ui.event_schema_version,
    },
    artifacts: manifest.artifacts,
    capabilities: manifest.domain.capabilities.map((capability) => ({
      id: capability.id,
      kind: capability.kind,
      ...(capability.ui ? { ui: capability.ui } : {}),
    })),
    block_types: manifest.components.block_types,
    adapter_requirements: manifest.adapter_requirements,
    error: manifest.error
      ? {
          code: manifest.error.code,
          message: manifest.error.message,
        }
      : null,
  };
}
