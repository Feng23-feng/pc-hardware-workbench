import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  copyFile,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const installerSource = join(
  repoRoot,
  "launcher",
  "install-pchw-skill.ps1",
);
const tempRoot = await mkdtemp(
  join(tmpdir(), "skilldock-pchw-skill-upgrade-"),
);
const expectedHash = "a".repeat(64);
const oldHash = "b".repeat(64);
const badHash = "c".repeat(64);

function runProcess(command, args, env, timeoutMs = 30_000) {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(command, args, {
      env,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    const timer = setTimeout(() => {
      child.kill();
      rejectPromise(new Error(`Installer timed out: ${args.join(" ")}`));
    }, timeoutMs);
    child.once("error", (error) => {
      clearTimeout(timer);
      rejectPromise(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      resolvePromise({ code, stdout, stderr });
    });
  });
}

async function writeIdentityShim(root) {
  await writeFile(
    join(root, "skill-tree-identity.ps1"),
    [
      "function Get-SkillTreeIdentity {",
      "  param([Parameter(Mandatory = $true)][string]$Root)",
      "  $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\\')",
      "  $source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'source\\pc-hardware-workbench')).TrimEnd('\\')",
      "  $target = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'skills\\pc-hardware-workbench')).TrimEnd('\\')",
      "  if ($resolved -eq $source) {",
      `    return [pscustomobject]@{ tree_sha256 = '${expectedHash}'; tree_file_count = 2 }`,
      "  }",
      "  if ($resolved -eq $target) {",
      "    if (Test-Path -LiteralPath (Join-Path $resolved 'INSTALL-INFO.json')) {",
      "      if ($env:SKILLDOCK_TEST_FAIL_INSTALLED_IDENTITY -eq '1') {",
      `        return [pscustomobject]@{ tree_sha256 = '${badHash}'; tree_file_count = 2 }`,
      "      }",
      `      return [pscustomobject]@{ tree_sha256 = '${expectedHash}'; tree_file_count = 2 }`,
      "    }",
      `    return [pscustomobject]@{ tree_sha256 = '${oldHash}'; tree_file_count = 2 }`,
      "  }",
      "  throw \"Unexpected identity root: $resolved\"",
      "}",
      "",
    ].join("\n"),
    "utf8",
  );
}

async function createFixture(name) {
  const root = join(tempRoot, name);
  const sourceSkill = join(root, "source", "pc-hardware-workbench");
  const targetSkill = join(root, "skills", "pc-hardware-workbench");
  await mkdir(sourceSkill, { recursive: true });
  await mkdir(targetSkill, { recursive: true });
  await copyFile(
    installerSource,
    join(root, "Install PCHW Skill.ps1"),
  );
  await writeIdentityShim(root);
  await writeFile(
    join(root, "RC-MANIFEST.json"),
    `${JSON.stringify({
      pchw_skill: {
        version: "2.8.0",
        tree_sha256: expectedHash,
        tree_file_count: 2,
      },
    }, null, 2)}\n`,
    "utf8",
  );
  await writeFile(
    join(sourceSkill, "SKILL.md"),
    "---\nname: pc-hardware-workbench\n---\nnew\n",
    "utf8",
  );
  await writeFile(join(sourceSkill, "new.txt"), "new\n", "utf8");
  await writeFile(
    join(targetSkill, "SKILL.md"),
    "---\nname: old-pchw\n---\nold\n",
    "utf8",
  );
  await writeFile(join(targetSkill, "old.txt"), "old\n", "utf8");
  return {
    root,
    skillsRoot: join(root, "skills"),
    targetSkill,
  };
}

async function runInstaller(fixture, { replace = true, failIdentity = false } = {}) {
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    join(fixture.root, "Install PCHW Skill.ps1"),
    "-SourceDirectory",
    join(fixture.root, "source", "pc-hardware-workbench"),
    "-SkillsRoot",
    fixture.skillsRoot,
  ];
  if (replace) args.push("-ReplaceExisting");
  return runProcess(
    "powershell.exe",
    args,
    {
      ...process.env,
      SKILLDOCK_TEST_FAIL_INSTALLED_IDENTITY: failIdentity ? "1" : "0",
    },
  );
}

try {
  const rejectFixture = await createFixture("reject-without-replace");
  const rejected = await runInstaller(rejectFixture, { replace: false });
  assert.notEqual(rejected.code, 0);
  assert.equal(existsSync(join(rejectFixture.targetSkill, "old.txt")), true);

  const successFixture = await createFixture("success");
  const upgraded = await runInstaller(successFixture);
  assert.equal(upgraded.code, 0, `${upgraded.stdout}\n${upgraded.stderr}`);
  const upgradedResult = JSON.parse(upgraded.stdout.trim());
  assert.equal(upgradedResult.changed, true);
  assert.equal(existsSync(join(successFixture.targetSkill, "new.txt")), true);
  assert.equal(existsSync(join(successFixture.targetSkill, "old.txt")), false);
  assert.equal(existsSync(upgradedResult.backup_path), true);
  assert.equal(
    existsSync(join(upgradedResult.backup_path, "old.txt")),
    true,
  );

  const idempotent = await runInstaller(successFixture);
  assert.equal(idempotent.code, 0);
  assert.equal(JSON.parse(idempotent.stdout.trim()).changed, false);

  const rollbackFixture = await createFixture("rollback");
  const failed = await runInstaller(rollbackFixture, {
    failIdentity: true,
  });
  assert.notEqual(failed.code, 0);
  assert.equal(existsSync(join(rollbackFixture.targetSkill, "old.txt")), true);
  assert.equal(existsSync(join(rollbackFixture.targetSkill, "new.txt")), false);
  const backups = await readdir(
    join(rollbackFixture.skillsRoot, ".skilldock-backups"),
  );
  const failedBackup = backups.find((name) =>
    name.startsWith("pc-hardware-workbench-failed-install-")
  );
  assert.ok(failedBackup);
  assert.equal(
    existsSync(join(
      rollbackFixture.skillsRoot,
      ".skilldock-backups",
      failedBackup,
      "new.txt",
    )),
    true,
  );

  console.log(
    "PCHW existing-Skill backup, replacement, idempotency, and rollback: PASS",
  );
} finally {
  if (process.env.SKILLDOCK_KEEP_SMOKE === "1") {
    console.log(`Kept PCHW upgrade test root: ${tempRoot}`);
  } else {
    await rm(tempRoot, { recursive: true, force: true }).catch(() => {});
  }
}
