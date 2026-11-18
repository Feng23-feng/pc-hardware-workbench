import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const packageRoot = resolve(
  process.argv[2] ??
    join(repoRoot, "dist", "SkillDock-PCHW-0.1.0-rc.1-win-x64"),
);
const installer = join(packageRoot, "Install PCHW Skill.ps1");
for (const required of [installer]) {
  if (!existsSync(required)) {
    throw new Error(`Packaged upgrade test input is missing: ${required}`);
  }
}

const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-packaged-upgrade-"),
);
const skillsRoot = join(tempRoot, "skills");
const oldTarget = join(skillsRoot, "pc-hardware-workbench");
await mkdir(oldTarget, { recursive: true });
await writeFile(
  join(oldTarget, "SKILL.md"),
  "---\nname: old-pc-hardware-workbench\n---\nold\n",
  "utf8",
);
await writeFile(join(oldTarget, "old-only.txt"), "old\n", "utf8");

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
        "-SkillsRoot",
        skillsRoot,
        "-ReplaceExisting",
      ],
      {
        windowsHide: true,
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.once("error", rejectPromise);
    child.once("exit", (code) => resolvePromise({ code, stdout, stderr }));
  });
}

try {
  const upgraded = await runInstaller();
  assert.equal(upgraded.code, 0, `${upgraded.stdout}\n${upgraded.stderr}`);
  const result = JSON.parse(upgraded.stdout.trim());
  assert.equal(result.changed, true);
  assert.equal(existsSync(result.backup_path), true);
  assert.equal(
    existsSync(join(result.backup_path, "old-only.txt")),
    true,
  );
  assert.equal(existsSync(join(oldTarget, "old-only.txt")), false);
  const installedSkill = await readFile(
    join(oldTarget, "SKILL.md"),
    "utf8",
  );
  assert.match(installedSkill, /version:\s*"2\.8\.0"/u);

  const idempotent = await runInstaller();
  assert.equal(
    idempotent.code,
    0,
    `${idempotent.stdout}\n${idempotent.stderr}`,
  );
  assert.equal(JSON.parse(idempotent.stdout.trim()).changed, false);

  console.log(
    "Packaged PCHW existing-Skill upgrade and backup: PASS",
  );
} finally {
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept packaged upgrade test root: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
