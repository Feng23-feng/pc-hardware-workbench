import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import {
  compareSkillTrees,
  computeSkillTreeIdentity,
} from "./skill-tree-identity.mjs";

function argument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : "";
}

const sourceRoot = resolve(
  argument("--source") ||
  resolve(
    import.meta.dirname,
    "..",
    "..",
    "pc-hardware-workbench",
    "skill",
    "pc-hardware-workbench",
  ),
);
const installedRoot = resolve(
  argument("--installed") ||
  resolve(
    process.env.USERPROFILE ?? process.env.HOME ?? "",
    ".codex",
    "skills",
    "pc-hardware-workbench",
  ),
);

const comparison = await compareSkillTrees(sourceRoot, installedRoot);
assert.equal(
  comparison.ok,
  true,
  `Skill tree mismatch:\n${JSON.stringify({
    source_tree_sha256: comparison.source.tree_sha256,
    installed_tree_sha256: comparison.installed.tree_sha256,
    missing: comparison.missing,
    changed: comparison.changed,
    extra: comparison.extra,
  }, null, 2)}`,
);
const installInfoPath = resolve(installedRoot, "INSTALL-INFO.json");
let installInfo = null;
try {
  installInfo = JSON.parse(
    (await readFile(installInfoPath, "utf8")).replace(/^\uFEFF/u, ""),
  );
} catch {
  // Older installations may predate identity metadata.
}
if (installInfo?.TreeSha256) {
  assert.equal(
    installInfo.TreeSha256.toLowerCase(),
    comparison.installed.tree_sha256,
  );
  assert.equal(
    installInfo.TreeFileCount,
    comparison.installed.tree_file_count,
  );
}
const runtime = await computeSkillTreeIdentity(installedRoot);
console.log(JSON.stringify({
  ok: true,
  source_root: sourceRoot,
  installed_root: installedRoot,
  tree_sha256: runtime.tree_sha256,
  tree_file_count: runtime.tree_file_count,
  install_info_tree_sha256:
    installInfo?.TreeSha256?.toLowerCase() ?? null,
}, null, 2));
