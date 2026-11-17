# Install and uninstall 0.1.0-rc.1

No administrator rights are required. Do not run the RC in a production profile
before the clean-Windows acceptance is complete.

## 1. Verify the archive

Keep the ZIP sidecar beside the archive:

```text
SkillDock-PCHW-0.1.0-rc.1-win-x64.zip
SkillDock-PCHW-0.1.0-rc.1-win-x64.zip.sha256
```

Compare the archive digest with the sidecar before extracting:

```powershell
$archive = Resolve-Path .\SkillDock-PCHW-0.1.0-rc.1-win-x64.zip
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

The installer compares the bundled runtime/reference subset with the subset
identity in `RC-MANIFEST.json`. Test runners and fixture-only material are not
part of the package.

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

Run the packaged Runtime uninstaller from the installed Runtime directory:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File ".\Uninstall SkillDock.ps1"
```

Default uninstall removes active Runtime program directories and the Runtime
pointer while preserving user data and Runtime backups.

Remove the RC-installed PCHW Skill with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File ".\Uninstall PCHW Skill.ps1"
```

The uninstaller verifies the installed tree identity before moving it to the
backup root. It refuses to remove a changed or unmarked Skill. Use
`-PurgeBackups` only when the tester explicitly wants the Skill backup removed.
Use the Runtime uninstaller's `-PurgeUserData -PurgeBackups` only when Task data
and Runtime backups are intentionally disposable.
