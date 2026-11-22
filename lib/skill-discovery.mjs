import {
  lstatSync,
  readdirSync,
  realpathSync,
  statSync,
} from "node:fs";
import { homedir } from "node:os";
import {
  delimiter,
  dirname,
  join,
  resolve,
} from "node:path";
import { loadWorkbenchManifest } from "./workbench-manifest.mjs";
import {
  evaluatePchwSurfaceCompatibility,
  PCHW_SKILL_ID,
} from "./pchw-surface-contract.mjs";

const MANIFEST_NAME = "workbench.manifest.json";
const MAX_SCAN_DEPTH = 4;

function splitPaths(value) {
  return String(value ?? "")
    .split(delimiter)
    .map((item) => item.trim())
    .filter(Boolean);
}

function safeRealpath(path) {
  try {
    return realpathSync(path);
  } catch {
    return resolve(path);
  }
}

function isDirectory(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function isFile(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function scanManifestFiles(root, depth = 0) {
  if (depth > MAX_SCAN_DEPTH || !isDirectory(root)) return [];
  const output = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (
      entry.name.startsWith(".") ||
      entry.name === "node_modules" ||
      entry.isSymbolicLink()
    ) {
      continue;
    }
    const child = join(root, entry.name);
    if (entry.isFile() && entry.name === MANIFEST_NAME) {
      output.push(child);
    } else if (entry.isDirectory()) {
      output.push(...scanManifestFiles(child, depth + 1));
    }
  }
  return output;
}

function defaultRoots(projectRoot) {
  return [
    join(homedir(), ".codex", "skills"),
    join(homedir(), ".dsh", "skills"),
  ];
}

function inputManifestPaths({ explicitValue, roots }) {
  const explicit = splitPaths(explicitValue);
  const sourcePaths = explicit.length > 0 ? explicit : roots;
  const manifests = [];
  for (const input of sourcePaths) {
    const path = safeRealpath(input);
    if (isFile(path) && path.endsWith(MANIFEST_NAME)) {
      manifests.push(path);
    } else if (isDirectory(path)) {
      manifests.push(...scanManifestFiles(path));
    }
  }
  return manifests;
}

function candidateDescriptor(manifest) {
  return {
    id: manifest.skill.id,
    name: manifest.skill.name,
    version: manifest.skill.version,
    runtime_id: manifest.runtime.id,
    manifest_hash: manifest.resolved?.manifest_hash ?? null,
    status: manifest.status,
    error: manifest.error?.code ?? null,
    surface_contracts: manifest.surface_contracts ?? null,
  };
}

function evaluateCandidateSurfaceCompatibility(manifest) {
  if (manifest?.skill?.id === PCHW_SKILL_ID) {
    return evaluatePchwSurfaceCompatibility(manifest);
  }
  const active = manifest?.status === "active";
  return {
    compatible: active,
    code: active ? "not_pchw_surface" : "skill_not_active",
    message: active
      ? "This Skill is not the PC Hardware Workbench panel surface."
      : "The selected Skill is not active.",
    contract_id: null,
    contract_version: null,
    skill_version: manifest?.skill?.version ?? null,
    mode: "not_pchw_surface",
    supported_contract_range: null,
    minimum_skill_version: null,
    required_capabilities: [],
  };
}

export function discoverSkillManifests({
  projectRoot,
  explicitValue =
    process.env.PANEL_SKILL_MANIFEST ??
    process.env.PANEL_WORKBENCH_MANIFEST,
  configuredRoots = process.env.PANEL_SKILL_ROOTS,
  roots = configuredRoots !== undefined
    ? splitPaths(configuredRoots)
    : defaultRoots(projectRoot),
  previousActive = null,
  preferredSkillId = process.env.PANEL_SKILL_ID ?? null,
}) {
  const manifestPaths = [
    ...new Set(
      inputManifestPaths({ explicitValue, roots }).map(safeRealpath),
    ),
  ].sort((left, right) => left.localeCompare(right));
  const candidates = [];
  for (const manifestPath of manifestPaths) {
    const allowedRoot = dirname(manifestPath);
    const manifest = loadWorkbenchManifest({
      projectRoot,
      manifestPath,
      allowedRoot,
    });
    const surfaceCompatibility =
      evaluateCandidateSurfaceCompatibility(manifest);
    candidates.push({
      manifest,
      surfaceCompatibility,
      public: {
        ...candidateDescriptor(manifest),
        surface_compatibility: surfaceCompatibility,
        manifest_path: manifestPath,
      },
    });
  }
  const compatible = candidates.filter(
    ({ manifest, surfaceCompatibility }) =>
      manifest.status === "active" &&
      surfaceCompatibility.compatible,
  );

  let selected = null;
  let selectionReason = "none";
  if (preferredSkillId) {
    selected =
      compatible.find(
        ({ manifest }) => manifest.skill.id === preferredSkillId,
      ) ?? null;
    selectionReason = selected ? "preferred_skill_id" : "preferred_missing";
  } else if (previousActive?.skill_id) {
    selected =
      compatible.find(({ manifest }) => {
        return (
          manifest.skill.id === previousActive.skill_id &&
          manifest.skill.version === previousActive.skill_version &&
          manifest.runtime.id === previousActive.runtime_id &&
          (manifest.resolved?.manifest_hash ?? null) ===
            (previousActive.manifest_hash ?? null)
        );
      }) ?? null;
    selectionReason = selected
      ? "previous_active_match"
      : "previous_active_missing";
  } else if (compatible.length > 0) {
    selected = compatible[0];
    selectionReason = "first_compatible";
  }

  return {
    selected: selected?.manifest ?? null,
    selectedCompatibility: selected?.surfaceCompatibility ?? null,
    selectionReason,
    candidates: candidates.map(({ public: descriptor }) => descriptor),
    compatibleCount: compatible.length,
    fallbackRequired: selected === null,
    error:
      selected === null && manifestPaths.length === 0 && splitPaths(explicitValue).length
        ? {
            code: "manifest_path_missing",
            message: "Configured Skill manifest paths did not resolve to a manifest.",
          }
        : null,
  };
}
