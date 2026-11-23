# Install and uninstall 0.1.0-rc.6

No administrator rights are required. Do not run the RC in a production profile
before the clean-Windows acceptance is complete.

For the supported clean-Windows acceptance route, extract the outer acceptance
ZIP and double-click its root `Start-Acceptance.cmd`. That controller validates
the outer bundle and pinned RC, runs preflight, and installs both components.
The lower-level commands below are diagnostic/advanced recovery steps, not the
primary user installation path.

## 1. Verify the archive

Keep the ZIP sidecar beside the archive:

```text
SkillDock-PCHW-0.1.0-rc.6-win-x64.zip
SkillDock-PCHW-0.1.0-rc.6-win-x64.zip.sha256
```

Compare the archive digest with the sidecar before extracting:

```powershell
$archive = Resolve-Path .\SkillDock-PCHW-0.1.0-rc.6-win-x64.zip
$expected = ((Get-Content "$archive.sha256" -Raw).Split()[0]).ToLowerInvariant()
$actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "Archive hash mismatch" }
```

## 2. Install the bundled PCHW Skill

From the extracted package root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install PCHW Skill.ps1"
```

The installer refuses to overwrite a different existing Skill unless
`-ReplaceExisting` is supplied. Replacement moves the old tree to
`%USERPROFILE%\.codex\skills\.skilldock-backups` before installing.

When upgrading from an earlier RC-installed PCHW tree, add
`-ReplaceExisting`. The old tree is backed up before the atomic replacement.

The installer compares the bundled runtime/reference subset with the subset
identity in `RC-MANIFEST.json`. Test runners and fixture-only material are not
part of the package.

The bundled PCHW is `2.9.2`. The Runtime accepts exact PCHW `2.8.0` as a
legacy bridge and later versions only when they declare a compatible
`pchw-source-hosted` contract plus UI state schema `1.2`, event schema `1.0`,
and every required capability. A Runtime-only installation can therefore keep
working across compatible Skill updates without requiring a new SkillDock build
for every PCHW release. A contract-major, schema, or capability change fails
closed instead of loading an older panel against an incompatible Skill.

## 3. Install the SkillDock Runtime

From the extracted package root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install SkillDock Runtime.ps1"
```

The installer creates a versioned Runtime directory under
`%LOCALAPPDATA%\SkillDock`, atomically updates
`%LOCALAPPDATA%\SkillDock\runtime-location.json`, and backs up older active
Runtime directories under `%LOCALAPPDATA%\SkillDockBackups\runtime`.

The canonical Runtime data root is `%LOCALAPPDATA%\SkillDock\runtime-pchw`.
Before any migration write, the installer copies legacy
`runtime-dsh-web` Task/attachment/artifact/evidence data to
`%LOCALAPPDATA%\SkillDockBackups\data`. The default `Auto` policy migrates only
when the canonical data root is unused.

If both data roots contain state, installation stops with
`runtime_data_conflict`; the installer never silently merges them. A one-source
upgrade is explicit:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File ".\Install SkillDock Runtime.ps1" `
  -LegacyDataPolicy PreferLegacy
```

Use this only after reviewing the retained data backup. The legacy source
directory remains recoverable after migration.

The installed Skill is the normal user entry. Ask a hardware question in the
current Codex conversation and accept the offered graphical workspace; ordinary
use requires no command, runner, port, token, or environment-variable entry.

## 4. DSH core-only manual install

DSH can use the PCHW Skill for chat, collection, and CSV analysis, but this
release does not provide the SkillDock panel on DSH. Do not install or launch
the SkillDock Runtime for this path.

From the extracted package root, copy the bundled Skill into DSH:

```powershell
$dshRoot = if ($env:DSH_HOME) {
  $env:DSH_HOME
} else {
  Join-Path $env:USERPROFILE ".dsh"
}
$skillsRoot = Join-Path $dshRoot "skills"
$target = Join-Path $skillsRoot "pc-hardware-workbench"

if (Test-Path -LiteralPath $target) {
  throw "Back up the existing DSH Skill before replacing it."
}

New-Item -ItemType Directory -Path $skillsRoot -Force | Out-Null
Copy-Item `
  -LiteralPath ".\skills\pc-hardware-workbench" `
  -Destination $target `
  -Recurse
```

After restarting DSH, invoke:

```text
/pc-hardware-workbench
```

This DSH path is core-Skill support only. It has no `pchw-source-hosted`
SkillDock panel, no `CODEX_THREAD_ID` binding, and no claim to the Codex-only
panel workflow in this release.

## 5. Stop

Use the installed Runtime launcher:

```powershell
$pointer = Get-Content "$env:LOCALAPPDATA\SkillDock\runtime-location.json" -Raw |
  ConvertFrom-Json
& $pointer.runtime_path --stop --silent
```

## 6. Uninstall

Use the unified package-root uninstall entry:

```text
Uninstall.cmd
```

The default path removes the active PCHW Skill, active Runtime directories,
Runtime pointer, and shortcuts while preserving Task data, evidence, exports,
shared Node engines, and rollback/data backups. The PCHW Skill uninstaller
verifies the installed tree identity before moving it to the backup root and
refuses to remove a changed or unmarked Skill.

Choose the explicit full-cleanup option only when Task data, Runtime backups,
data-migration backups, storage exports, and installer logs are intentionally
disposable.
