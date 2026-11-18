# Installation and Upgrade

[中文](../installation.md) | [English](installation.md)

## Requirements

- Windows 10 or Windows 11 x64.
- Windows PowerShell 5.1 or PowerShell 7 for automated collection.
- Other operating systems receive manual troubleshooting guidance only.
- Optional monitoring requires an already-running LibreHardwareMonitor instance.
  This project does not install or start it.

The current `2.8.0` build is a test build and has not been formally released.
Clean-Windows installation, uninstallation, and complete user signoff remain release
blockers.

## Choose one distribution

| Package | Use it when | Includes | Panel |
| --- | --- | --- | --- |
| Portable | You do not need a Skill host | Local read-only collection, CSV, charts, reports | No SkillDock; local menu |
| DSH core-only | You use DeepSeek Harness | PCHW Skill and DSH adapter | No SkillDock panel |
| Codex + SkillDock | You use Codex Desktop | PCHW Skill, SkillDock Runtime, one installer | Current Codex conversation only |

Current candidate names:

```text
pc-hardware-portable-v2.8.0.zip
pc-hardware-workbench-deepseek-harness-v2.8.0.zip
SkillDock-PCHW-0.1.0-rc.1-win-x64-user.zip
```

`2.8.0` has not been formally released. Use only files that actually exist in
Releases together with their SHA-256 sidecars. Do not mix old and current Skill,
Runtime, or package files.

## Codex + SkillDock

### Install

1. Download `SkillDock-PCHW-0.1.0-rc.1-win-x64-user.zip`.
2. Verify it against the `.sha256` sidecar.
3. Extract the full directory.
4. Double-click `Install.cmd`.
5. Wait for completion, then reopen Codex.

The installer automatically chooses the correct path:

- clean installation when no PCHW Skill exists;
- backup-based upgrade when an older Skill exists;
- restore of the old Skill if replacement or later Runtime validation fails.

The user does not choose a clean or upgrade mode. The installer does not run the
hardware collector, request administrator rights, or start `SkillDock.exe`.

### Install locations

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
%LOCALAPPDATA%\SkillDock
```

Existing Skill backups:

```text
%USERPROFILE%\.codex\skills\.skilldock-backups
```

Runtime and migration backups:

```text
%LOCALAPPDATA%\SkillDockBackups
```

### Open the panel from the current conversation

Do not search for a runner, port, token, or environment variable. In the current
Codex conversation, ask a hardware question:

```text
The game starts stuttering after about twenty minutes. This is the HWiNFO CSV.
Can you open the graphical analysis for this task?
```

After you agree, the page should carry in the current Task, question, and supported
attachments. For the first local analysis, choose “仅本次允许” (Allow this time only)
to view the chart, judgement, supporting and conflicting evidence, uncertainty, and
low-risk actions.

If Codex Ask-for-approval mode prevents automatic opening, use the short-lived
“Open the panel manually” link or local `.url` shortcut shown by the Skill. The page
updates when the result returns; do not press F5. Closing and reopening SkillDock
should restore the same Task, attachments, chart, and conclusion without creating a
second Thread.

## DSH core-only

DSH uses the core-only package and does not install SkillDock Runtime.

Default Skill path:

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

When `DSH_HOME` is set:

```text
%DSH_HOME%\skills\pc-hardware-workbench
```

Invoke:

```text
/pc-hardware-workbench
```

DSH can use PCHW for configuration, troubleshooting, chat, collection, and CSV
analysis. It does not provide the Codex `pchw-source-hosted` SkillDock panel. See
the [DSH adapter](../../adapters/dsh/README.md) for details.

## Portable package

No Codex, DSH, or SkillDock installation is required:

```powershell
cd portable
.\开始使用.cmd
```

Choose standard or privacy-redacted mode, then explicitly approve the read-only
collection. The portable package processes data locally and writes charts or reports
only to a location selected by the user.

## Verify installation

Codex core Skill:

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
Test-Path (Join-Path $skill "scripts")
Test-Path (Join-Path $skill "references")
```

All three checks should return `True`. If Codex still cannot see the Skill, restart
Codex.

For Codex + SkillDock, confirm the Runtime pointer:

```powershell
$pointer = Join-Path $env:LOCALAPPDATA "SkillDock\runtime-location.json"
Test-Path $pointer
```

Do not publish ports, tokens, or local absolute paths to an Issue.

## Upgrade and rollback

### Codex + SkillDock

Run `Install.cmd` from the new package. The installer validates the old Skill, backs
it up, installs the new Skill, backs up old Runtime directories, and keeps backups
when a conflict or failure occurs.

### DSH

Close DSH, move the old Skill directory to a backup location, and install the new
core-only package. Do not leave two Skill directories containing `SKILL.md` in the
same DSH scan root.

## Uninstall

### Codex + SkillDock

Open the installed SkillDock program directory and run its SkillDock uninstall
script. The default uninstall removes the program and shortcuts while preserving Task
data and backups. Purge data only when recovery is no longer needed.

### DSH

Close DSH and remove:

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

### Portable package

Confirm that no collector or report process is running, then delete the extracted
directory. User-selected report directories are not removed automatically.

## Support matrix

| Host | PCHW chat, collection, CSV | SkillDock panel |
| --- | --- | --- |
| Current Codex user conversation | Supported | Supported; only promised panel host |
| DeepSeek Harness | Supported | Not provided |
| Other Agent hosts | Use according to host file access | Not promised |
| Portable package | No Skill host required | No SkillDock; standalone local tools |

## Known limitations

- `2.8.0` has not been formally released; clean-Windows signoff remains pending.
- The SkillDock panel is supported only in the current Codex user conversation.
- If the panel is unavailable, permission is denied, or another workspace is active,
  continue in chat without exposing a developer entry.
- Live collection depends on Windows permissions and the host sandbox; do not report
  permission denial as missing hardware.
- No automatic changes to BIOS, firmware, drivers, clocks, voltage, power limits,
  fans, or memory timings.
