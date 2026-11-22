export const PCHW_SOURCE_HOSTED_CONTRACT_ID = "pchw-source-hosted";
export const PCHW_SKILL_ID = "pc-hardware-workbench";

const SUPPORTED_CONTRACT_MAJOR = 1;
const MINIMUM_CONTRACT_VERSION = "1.0.0";
const MINIMUM_SKILL_VERSION = "2.8.0";
const LEGACY_EXACT_SKILL_VERSION = "2.8.0";
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
  mode = "none",
}) {
  return {
    compatible: false,
    code,
    message,
    contract_id: PCHW_SOURCE_HOSTED_CONTRACT_ID,
    contract_version: contractVersion,
    skill_version: skillVersion,
    mode,
    supported_contract_range: `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0`,
    minimum_skill_version: MINIMUM_SKILL_VERSION,
    required_capabilities: [],
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
        mode: "legacy_exact",
        supported_contract_range: `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0`,
        minimum_skill_version: MINIMUM_SKILL_VERSION,
        required_capabilities: [],
      };
    }
    return incompatible({
      code: "surface_contract_missing",
      message:
        "PCHW versions after 2.8.0 must declare the pchw-source-hosted surface contract.",
      skillVersion: skillVersion.raw,
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
      mode: "contract",
    });
  }
  if (!contractMinimumSkill) {
    return incompatible({
      code: "surface_contract_min_skill_invalid",
      message: "The surface contract min_skill_version is not valid SemVer.",
      skillVersion: skillVersion.raw,
      contractVersion: contractVersion.raw,
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
    mode: "contract",
    supported_contract_range: `>=${MINIMUM_CONTRACT_VERSION} <${SUPPORTED_CONTRACT_MAJOR + 1}.0.0`,
    minimum_skill_version: effectiveMinimum.raw,
    required_capabilities: requiredCapabilities,
  };
}

export function isPchwSurfaceCompatible(manifest) {
  return evaluatePchwSurfaceCompatibility(manifest).compatible;
}
