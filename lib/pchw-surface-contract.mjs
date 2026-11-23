export const PCHW_SOURCE_HOSTED_CONTRACT_ID = "pchw-source-hosted";
export const PCHW_SKILL_ID = "pc-hardware-workbench";

export const PCHW_SURFACE_COMPATIBILITY_PROFILE = Object.freeze({
  supported_contract_major: 1,
  minimum_contract_version: "1.0.0",
  minimum_skill_version: "2.8.0",
  legacy_exact_skill_version: "2.8.0",
  ui_state_schema_versions: Object.freeze(["1.2"]),
  event_schema_versions: Object.freeze(["1.0"]),
});

const SUPPORTED_CONTRACT_MAJOR =
  PCHW_SURFACE_COMPATIBILITY_PROFILE.supported_contract_major;
const MINIMUM_CONTRACT_VERSION =
  PCHW_SURFACE_COMPATIBILITY_PROFILE.minimum_contract_version;
const MINIMUM_SKILL_VERSION =
  PCHW_SURFACE_COMPATIBILITY_PROFILE.minimum_skill_version;
const LEGACY_EXACT_SKILL_VERSION =
  PCHW_SURFACE_COMPATIBILITY_PROFILE.legacy_exact_skill_version;
const SUPPORTED_UI_STATE_SCHEMAS = new Set(
  PCHW_SURFACE_COMPATIBILITY_PROFILE.ui_state_schema_versions,
);
const SUPPORTED_EVENT_SCHEMAS = new Set(
  PCHW_SURFACE_COMPATIBILITY_PROFILE.event_schema_versions,
);
const SEMVER_PATTERN =
  /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/u;

function parseSemver(value) {
  if (typeof value !== "string") return null;
  const match = SEMVER_PATTERN.exec(value);
  if (!match) return null;
  const prerelease = match[4] ? match[4].split(".") : [];
  if (
    prerelease.some(
      (part) => /^\d+$/u.test(part) && part.length > 1 && part.startsWith("0"),
    )
  ) {
    return null;
  }
  return {
    raw: value,
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    prerelease,
  };
}

function comparePrerelease(left, right) {
  if (left.length === 0 && right.length === 0) return 0;
  if (left.length === 0) return 1;
  if (right.length === 0) return -1;
  const count = Math.max(left.length, right.length);
  for (let index = 0; index < count; index += 1) {
    const leftPart = left[index];
    const rightPart = right[index];
    if (leftPart === undefined) return -1;
    if (rightPart === undefined) return 1;
    if (leftPart === rightPart) continue;
    const leftNumeric = /^\d+$/u.test(leftPart);
    const rightNumeric = /^\d+$/u.test(rightPart);
    if (leftNumeric && rightNumeric) {
      return Number(leftPart) < Number(rightPart) ? -1 : 1;
    }
    if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1;
    return leftPart.localeCompare(rightPart, "en");
  }
  return 0;
}

function compareSemver(left, right) {
  for (const key of ["major", "minor", "patch"]) {
    if (left[key] !== right[key]) return left[key] < right[key] ? -1 : 1;
  }
  return comparePrerelease(left.prerelease, right.prerelease);
}

function incompatible({
  code,
  message,
  skillVersion = null,
  contractVersion = null,
  uiStateSchemaVersion = null,
  eventSchemaVersion = null,
  mode = "none",
}) {
  return {
    compatible: false,
    code,
    message,
    contract_id: PCHW_SOURCE_HOSTED_CONTRACT_ID,
    contract_version: contractVersion,
    skill_version: skillVersion,
    ui_state_schema_version: uiStateSchemaVersion,
    event_schema_version: eventSchemaVersion,
    mode,
    supported_contract_range: `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0`,
    minimum_skill_version: MINIMUM_SKILL_VERSION,
    required_capabilities: [],
    supported_ui_state_schema_versions: [
      ...PCHW_SURFACE_COMPATIBILITY_PROFILE.ui_state_schema_versions,
    ],
    supported_event_schema_versions: [
      ...PCHW_SURFACE_COMPATIBILITY_PROFILE.event_schema_versions,
    ],
  };
}

export function evaluatePchwSurfaceCompatibility(manifest) {
  if (manifest?.status !== "active") {
    return incompatible({
      code: "skill_not_active",
      message: "The selected Skill is not active.",
      skillVersion: manifest?.skill?.version ?? null,
    });
  }
  if (manifest?.skill?.id !== PCHW_SKILL_ID) {
    return incompatible({
      code: "skill_id_mismatch",
      message: "The selected Skill id is not pc-hardware-workbench.",
      skillVersion: manifest?.skill?.version ?? null,
    });
  }

  const skillVersion = parseSemver(manifest.skill.version);
  const minimumSkillVersion = parseSemver(MINIMUM_SKILL_VERSION);
  if (!skillVersion) {
    return incompatible({
      code: "skill_version_invalid",
      message: "The selected Skill version is not valid SemVer.",
    });
  }
  if (compareSemver(skillVersion, minimumSkillVersion) < 0) {
    return incompatible({
      code: "skill_version_too_old",
      message: `PCHW ${skillVersion.raw} predates the supported minimum ${MINIMUM_SKILL_VERSION}.`,
      skillVersion: skillVersion.raw,
    });
  }

  const uiStateSchemaVersion = manifest.ui?.state_schema_version;
  const eventSchemaVersion = manifest.ui?.event_schema_version;
  if (
    typeof uiStateSchemaVersion !== "string" ||
    !SUPPORTED_UI_STATE_SCHEMAS.has(uiStateSchemaVersion)
  ) {
    return incompatible({
      code: "ui_state_schema_unsupported",
      message:
        `Runtime supports UI state schema versions ` +
        `${[...SUPPORTED_UI_STATE_SCHEMAS].join(", ")}; ` +
        `received ${String(uiStateSchemaVersion ?? "(missing)")}.`,
      skillVersion: skillVersion.raw,
      uiStateSchemaVersion: String(uiStateSchemaVersion ?? ""),
      eventSchemaVersion: String(eventSchemaVersion ?? ""),
    });
  }
  if (
    typeof eventSchemaVersion !== "string" ||
    !SUPPORTED_EVENT_SCHEMAS.has(eventSchemaVersion)
  ) {
    return incompatible({
      code: "event_schema_unsupported",
      message:
        `Runtime supports event schema versions ` +
        `${[...SUPPORTED_EVENT_SCHEMAS].join(", ")}; ` +
        `received ${String(eventSchemaVersion ?? "(missing)")}.`,
      skillVersion: skillVersion.raw,
      uiStateSchemaVersion,
      eventSchemaVersion: String(eventSchemaVersion ?? ""),
    });
  }

  const contract = manifest.surface_contracts?.[
    PCHW_SOURCE_HOSTED_CONTRACT_ID
  ];
  if (!contract) {
    if (skillVersion.raw === LEGACY_EXACT_SKILL_VERSION) {
      return {
        compatible: true,
        code: "compatible_legacy_exact",
        message:
          "PCHW 2.8.0 uses the exact-version legacy compatibility bridge.",
        contract_id: PCHW_SOURCE_HOSTED_CONTRACT_ID,
        contract_version: null,
        skill_version: skillVersion.raw,
        ui_state_schema_version: uiStateSchemaVersion,
        event_schema_version: eventSchemaVersion,
        mode: "legacy_exact",
        supported_contract_range: `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0`,
        minimum_skill_version: MINIMUM_SKILL_VERSION,
        required_capabilities: [],
        supported_ui_state_schema_versions: [
          ...PCHW_SURFACE_COMPATIBILITY_PROFILE.ui_state_schema_versions,
        ],
        supported_event_schema_versions: [
          ...PCHW_SURFACE_COMPATIBILITY_PROFILE.event_schema_versions,
        ],
      };
    }
    return incompatible({
      code: "surface_contract_missing",
      message:
        "PCHW versions after 2.8.0 must declare the pchw-source-hosted surface contract.",
      skillVersion: skillVersion.raw,
      uiStateSchemaVersion,
      eventSchemaVersion,
    });
  }

  const contractVersion = parseSemver(contract.contract_version);
  const contractMinimumSkill = parseSemver(contract.min_skill_version);
  const supportedMinimum = parseSemver(MINIMUM_CONTRACT_VERSION);
  if (!contractVersion) {
    return incompatible({
      code: "surface_contract_version_invalid",
      message: "The surface contract version is not valid SemVer.",
      skillVersion: skillVersion.raw,
      contractVersion: String(contract.contract_version ?? ""),
      uiStateSchemaVersion,
      eventSchemaVersion,
      mode: "contract",
    });
  }
  if (
    contractVersion.major !== SUPPORTED_CONTRACT_MAJOR ||
    compareSemver(contractVersion, supportedMinimum) < 0
  ) {
    return incompatible({
      code: "surface_contract_unsupported",
      message:
        `SkillDock supports ${PCHW_SOURCE_HOSTED_CONTRACT_ID} ` +
        `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0.`,
      skillVersion: skillVersion.raw,
      contractVersion: contractVersion.raw,
      uiStateSchemaVersion,
      eventSchemaVersion,
      mode: "contract",
    });
  }
  if (!contractMinimumSkill) {
    return incompatible({
      code: "surface_contract_min_skill_invalid",
      message: "The surface contract min_skill_version is not valid SemVer.",
      skillVersion: skillVersion.raw,
      contractVersion: contractVersion.raw,
      uiStateSchemaVersion,
      eventSchemaVersion,
      mode: "contract",
    });
  }
  const effectiveMinimum =
    compareSemver(contractMinimumSkill, minimumSkillVersion) > 0
      ? contractMinimumSkill
      : minimumSkillVersion;
  if (compareSemver(skillVersion, effectiveMinimum) < 0) {
    return incompatible({
      code: "skill_version_below_contract_minimum",
      message:
        `PCHW ${skillVersion.raw} is below the contract minimum ` +
        `${effectiveMinimum.raw}.`,
      skillVersion: skillVersion.raw,
      contractVersion: contractVersion.raw,
      uiStateSchemaVersion,
      eventSchemaVersion,
      mode: "contract",
    });
  }

  const capabilityIds = new Set(
    (manifest.domain?.capabilities ?? []).map((item) => item.id),
  );
  const requiredCapabilities = Array.isArray(contract.required_capabilities)
    ? [...contract.required_capabilities]
    : [];
  const missingCapabilities = requiredCapabilities.filter(
    (capability) => !capabilityIds.has(capability),
  );
  if (
    requiredCapabilities.length === 0 ||
    missingCapabilities.length > 0
  ) {
    return incompatible({
      code: "surface_contract_capability_missing",
      message:
        missingCapabilities.length > 0
          ? `Missing required capabilities: ${missingCapabilities.join(", ")}.`
          : "The surface contract must declare at least one required capability.",
      skillVersion: skillVersion.raw,
      contractVersion: contractVersion.raw,
      uiStateSchemaVersion,
      eventSchemaVersion,
      mode: "contract",
    });
  }

  return {
    compatible: true,
    code: "compatible_contract",
    message: "PCHW and the pchw-source-hosted surface contract are compatible.",
    contract_id: PCHW_SOURCE_HOSTED_CONTRACT_ID,
    contract_version: contractVersion.raw,
    skill_version: skillVersion.raw,
    ui_state_schema_version: uiStateSchemaVersion,
    event_schema_version: eventSchemaVersion,
    mode: "contract",
    supported_contract_range: `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0`,
    minimum_skill_version: effectiveMinimum.raw,
    required_capabilities: requiredCapabilities,
    supported_ui_state_schema_versions: [
      ...PCHW_SURFACE_COMPATIBILITY_PROFILE.ui_state_schema_versions,
    ],
    supported_event_schema_versions: [
      ...PCHW_SURFACE_COMPATIBILITY_PROFILE.event_schema_versions,
    ],
  };
}

export function isPchwSurfaceCompatible(manifest) {
  return evaluatePchwSurfaceCompatibility(manifest).compatible;
}
