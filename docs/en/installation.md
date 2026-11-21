# Installation and Upgrade

[中文](../installation.md) | [English](installation.md)

## Requirements

- Windows 10 or Windows 11 x64.
- Windows PowerShell 5.1 or PowerShell 7 for automated collection.
- Other operating systems receive manual troubleshooting guidance only.
- Optional monitoring requires an already-running LibreHardwareMonitor instance.
  This project does not install or start it.

The current PCHW `2.8.0` build is a test build and the latest public package
includes SkillDock `0.1.0-rc.3`; neither has a stable release. The PCHW Skill and
Portable source trees did not change, so their matching assets remain
`2.8.0-rc.2`. Clean-Windows installation, uninstallation, and complete user
signoff remain pending.

## Choose one distribution

Most users should start with the PCHW Skill package without the panel. Choose
the SkillDock panel bundle only when Codex is already installed and you
specifically want the graphical workspace. If no Agent is available or you want
no installation at all, use PCHW Portable.

| Package | Use it when | Includes | Panel |
| --- | --- | --- | --- |
| PCHW Skill (Codex / DSH / other Agents; no panel) | Default choice; use Codex alone or with DSH / another compatible Agent host | PCHW Skill release subset only | No |
| PCHW Portable (standalone Windows; no Agent) | You do not use Codex / DSH, or want no Skill or Runtime installation | Standalone menu, collection, CSV, and evidence tools | No |
| SkillDock Runtime-only | A compatible PCHW Skill is installed and only the application and Node are missing | SkillDock Runtime, Node.js 24.22.1 | Current Codex conversation only |
| SkillDock panel bundle (for Codex) | Codex Desktop is installed and you specifically want the graphical panel | PCHW Skill, SkillDock Runtime, installer | Current Codex conversation only |

[Download the latest test build](https://github.com/Feng23-feng/pc-hardware-workbench/releases/tag/v0.1.0-rc.3):

```text
PCHW-Skill-2.8.0-rc.2.zip
pc-hardware-portable-v2.8.0-rc.2.zip
SkillDock-Runtime-0.1.0-rc.3-win-x64.zip
SkillDock-PCHW-0.1.0-rc.3-win-x64-user.zip
SHA256SUMS.txt
```

The SkillDock assets are `0.1.0-rc.3`; the unchanged PCHW Skill and Portable
assets remain `2.8.0-rc.2`. Clean-Windows installation, uninstallation, and final
signoff remain PENDING. Do not mix old and current Skill, Runtime, or package
files.

<a id="pchw-portable"></a>

## PCHW Portable (standalone Windows; no Agent)

This package requires no Codex, DSH, API key, installer, or administrator rights.
Verify the ZIP, extract the complete directory, and double-click `开始使用.cmd` to
open the menu.

The portable build provides read-only inventory, troubleshooting, HWiNFO and
PresentMon CSV analysis, evidence packages, telemetry charts, and guided manual
tuning. It does not provide an Agent conversation or the SkillDock panel. The
shared telemetry analyzer `1.2.4` recognizes `Timestamp`, `DateTime`, `Date/Time`,
and their Chinese equivalents, and reports the sampled span.

The portable build runs locally, does not initiate network access, and never
changes BIOS, firmware, drivers, clocks, voltage, power limits, fans, or memory
timings automatically.

## SkillDock panel bundle (for Codex)

Codex Desktop must already be installed.

### Install

1. Download `SkillDock-PCHW-0.1.0-rc.3-win-x64-user.zip`.
2. Verify it with `SHA256SUMS.txt` or the GitHub asset digest.
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

After a successful installation, Runtime program backups rotate to the newest
single rollback copy; older `Runtime-*` program directories are removed. Task
data, attachments, and migration-data backups do not participate in this
rotation and remain subject to uninstall or explicit cleanup.

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
updates automatically when the result returns. Closing and reopening SkillDock
should restore the same Task, attachments, chart, and conclusion without creating a
second Thread.

### Local storage

Use **Local storage** in the page header to inspect and manage SkillDock data on
this machine:

- **Export latest rollback backup** creates a ZIP containing the protected
  Runtime rollback, its exact shared Node engine, and a per-file SHA-256
  manifest. Missing, malformed, or mismatched engine references fail closed.
- A Task/evidence export bound to the current state, Session, and event count
  must be downloaded before cleanup unlocks.
- A second confirmation follows. Expired, tampered, or stale exports cannot
  delete changed Task data.
- Cleanup preserves the Agent Session, capabilities, Runtime, shared engine,
  installer logs, and rollback backup.

Exports live under `%LOCALAPPDATA%\SkillDock\storage-exports`. Download links are
valid for 24 hours; expired files are pruned when the Runtime starts or the
storage panel refreshes. Default uninstall preserves exports, while explicit
`-PurgeUserData` removes them.

<a id="pchw-skill-only"></a>

## PCHW Skill (Codex / DSH / other Agents; no panel)

This package contains the PCHW Skill only. It is not the SkillDock panel bundle
and contains no SkillDock Runtime, Node.js, or DSH observer.
It works in Codex, DSH, and other compatible Agent hosts and is intended for
users who do not need the panel. Place `pc-hardware-workbench` in the target
Agent's Skill directory.

Default Codex Skill path:

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

When `CODEX_HOME` is set:

```text
%CODEX_HOME%\skills\pc-hardware-workbench
```

Default DSH Skill path:

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

PCHW can be used for configuration, troubleshooting, chat, collection, and CSV
analysis. It does not provide the Codex `pchw-source-hosted` SkillDock panel.
See the [DSH adapter](../../adapters/dsh/README.md) for details.

## SkillDock Runtime-only

Use this only when a compatible PCHW Skill is already installed and the
SkillDock application plus Node.js are missing:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install SkillDock Runtime.ps1"
```

After installation, open the panel from the current Codex conversation. Do not
launch `SkillDock.exe` manually for the normal user path.

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

For the SkillDock panel bundle, confirm the Runtime pointer:

```powershell
$pointer = Join-Path $env:LOCALAPPDATA "SkillDock\runtime-location.json"
Test-Path $pointer
```

Do not publish ports, tokens, or local absolute paths to an Issue.

## Upgrade and rollback

### SkillDock panel bundle (for Codex)

Run `Install.cmd` from the new package. The installer validates the old Skill, backs
it up, installs the new Skill, backs up old Runtime directories, and keeps backups
when a conflict or failure occurs.

### PCHW Skill (Codex / DSH / other Agents; no panel)

Close the host, move the old Skill directory to a backup location, and install
the new PCHW Skill package. Do not leave two Skill directories containing
`SKILL.md` in the same DSH scan root.

## Uninstall

### SkillDock panel bundle (for Codex)

Open the installed SkillDock program directory and run its SkillDock uninstall
script. The default uninstall removes the program and shortcuts while preserving Task
data and backups. Purge data only when recovery is no longer needed.

### DSH

Close DSH and remove:

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

## Support matrix

| Host | PCHW chat, collection, CSV | SkillDock panel |
| --- | --- | --- |
| Current Codex user conversation | Supported | Supported; only promised panel host |
| DeepSeek Harness | Supported | Not provided |
| Other Agent hosts | Use according to host file access | Not promised |

## Known limitations

- `2.8.0` currently has no stable release; clean-Windows signoff remains pending.
- The SkillDock panel is supported only in the current Codex user conversation.
- If the panel is unavailable, permission is denied, or another workspace is active,
  continue in chat without exposing a developer entry.
- Live collection depends on Windows permissions and the host sandbox; do not report
  permission denial as missing hardware.
- No automatic changes to BIOS, firmware, drivers, clocks, voltage, power limits,
  fans, or memory timings.
