import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  compareSkillTrees,
} from "../scripts/skill-tree-identity.mjs";

const root = resolve(import.meta.dirname, "..");
const pchwRoot = resolve(root, "..", "pc-hardware-workbench");
const sourceSkill = join(
  pchwRoot,
  "skill",
  "pc-hardware-workbench",
);
const installer = join(pchwRoot, "tools", "install-skill.ps1");
const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-pchw-install-identity-"),
);
const installedSkillsRoot = join(tempRoot, "skills");
const installedSkill = join(
  installedSkillsRoot,
  "pc-hardware-workbench",
);

function runInstaller() {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(
      "powershell.exe",
      [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        installer,
        "-SourceDirectory",
        sourceSkill,
        "-Destination",
        installedSkill,
        "-BackupRoot",
        join(tempRoot, "backups"),
        "-Force",
      ],
      {
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.once("error", rejectPromise);
    child.once("exit", (code) => resolvePromise({ code, stderr }));
  });
}

try {
  const installed = await runInstaller();
  assert.equal(installed.code, 0, installed.stderr);

  const installInfo = JSON.parse(
    (
      await readFile(
        join(installedSkill, "INSTALL-INFO.json"),
        "utf8",
      )
    ).replace(/^\uFEFF/u, ""),
  );
  assert.equal(installInfo.InstallSource, "local-source");
  assert.match(installInfo.TreeSha256, /^[a-f0-9]{64}$/u);
  assert.ok(installInfo.TreeFileCount > 0);
  assert.equal(
    installInfo.RuntimeSha256,
    createHash("sha256")
      .update(await readFile(join(installedSkill, "runtime.mjs")))
      .digest("hex"),
  );

  const comparison = await compareSkillTrees(
    sourceSkill,
    installedSkill,
  );
  assert.equal(
    comparison.ok,
    true,
    JSON.stringify({
      missing: comparison.missing,
      changed: comparison.changed,
      extra: comparison.extra,
    }),
  );
  assert.equal(
    installInfo.TreeSha256,
    comparison.installed.tree_sha256,
  );
  assert.equal(
    installInfo.TreeFileCount,
    comparison.installed.tree_file_count,
  );

  const runtimePath = join(installedSkill, "runtime.mjs");
  await writeFile(
    runtimePath,
    `${await readFile(runtimePath, "utf8")}\n// tampered\n`,
    "utf8",
  );
  const tampered = await compareSkillTrees(
    sourceSkill,
    installedSkill,
  );
  assert.equal(tampered.ok, false);
  assert.deepEqual(tampered.changed, ["runtime.mjs"]);

  console.log(
    "PCHW installed Skill tree identity and tamper detection: PASS",
  );
} finally {
  await rm(tempRoot, { recursive: true, force: true });
}
