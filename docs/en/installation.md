# Installation and Upgrade

[中文](../installation.md) | [English](installation.md)

## Requirements

- Windows 10 or Windows 11 x64.
- Windows PowerShell 5.1 or PowerShell 7 for automated collection.
- Other operating systems receive manual troubleshooting guidance only.
- Optional monitoring requires an already-running LibreHardwareMonitor instance.
  This project does not install or start it.

The current PCHW public test version is `2.9.3-test.2`. When you need the
graphical panel, use the independent `SkillDock 0.1.0-rc.7 + PCHW 2.9.3` test
bundle; it checks UI schema `1.2`, event schema `1.0`, and required capabilities
before loading. The rc.7 user bundle contains a PCHW release subset based on
`2.9.3-test.1`, not the newer `2.9.3-test.2`; it is contract-compatible with
`test.2`, but the cross-package combination remains PENDING. Neither release line
has a stable version yet.

Clean-Windows install, upgrade, repair, and uninstall, real Codex Thread behavior,
human interaction, and multi-platform acceptance remain `PENDING`. Live LHM
remains `SKIP` when no authorized process is already running. These statuses do
not block the public pre-release, but they must not be reported as stable-release
acceptance.

## Choose one distribution

Most users should start with the PCHW Skill package without the panel. Choose
the SkillDock panel bundle only when Codex is already installed and you
specifically want the graphical workspace. If no Agent is available or you want
no installation at all, use PCHW Portable.

| Package | Use it when | Includes | Panel |
| --- | --- | --- | --- |
| PCHW Skill (Codex / DSH / other Agents; no panel) | Default choice; use Codex alone or with DSH / another compatible Agent host | PCHW Skill 2.9.3 release subset | No |
| SkillDock panel bundle (public rc.7) | Codex Desktop is installed and you use the PCHW 2.9.3 surface contract | PCHW 2.9.3 release subset based on `2.9.3-test.1`, SkillDock Runtime, installer | Current Codex conversation only |
| PCHW Portable (standalone Windows; no Agent) | You do not use Codex / DSH, or want no Skill or Runtime installation | Standalone menu, collection, CSV, and evidence tools | No |

Direct downloads for the primary paths:

- PCHW Skill: [installer ZIP](https://github.com/Feng23-feng/pc-hardware-workbench/releases/download/v2.9.3-test.2/pc-hardware-workbench-v2.9.3-test.2-installer.zip)
- SkillDock: [rc.7 user bundle ZIP](https://github.com/Feng23-feng/pc-hardware-workbench/releases/download/v0.1.0-rc.7/SkillDock-PCHW-0.1.0-rc.7-win-x64-user.zip)
- Portable: [standalone ZIP](https://github.com/Feng23-feng/pc-hardware-workbench/releases/download/v2.9.3-test.2/pc-hardware-portable-v2.9.3-test.2.zip)

[Download the current PCHW 2.9.3 public test build](https://github.com/Feng23-feng/pc-hardware-workbench/releases/tag/v2.9.3-test.2):

```text
pc-hardware-workbench-v2.9.3-test.2-installer.zip
pc-hardware-workbench-v2.9.3-test.2-manual.zip
pc-hardware-portable-v2.9.3-test.2.zip
pc-hardware-workbench-deepseek-harness-v2.9.3-test.2.zip
One SHA256SUMS file per channel
```

The current SkillDock panel test build is `v0.1.0-rc.7` with a PCHW `2.9.3`
release subset based on `2.9.3-test.1`. It is contract-compatible with
`2.9.3-test.2`, but the cross-package combination remains PENDING.
Clean-Windows installation, uninstallation, and final signoff for the rc.7 bytes
also remain PENDING and do not block the public test build. Do not mix multiple
PCHW Skill directories.

### Advanced options

| Advanced package | Use it when | Download |
| --- | --- | --- |
| DeepSeek Harness adapter | You use DSH and need the PCHW Skill plus adapter files | [Download DSH ZIP](https://github.com/Feng23-feng/pc-hardware-workbench/releases/download/v2.9.3-test.2/pc-hardware-workbench-deepseek-harness-v2.9.3-test.2.zip) |
| Manual package | You need to inspect the package or run the installation steps yourself | [Download manual ZIP](https://github.com/Feng23-feng/pc-hardware-workbench/releases/download/v2.9.3-test.2/pc-hardware-workbench-v2.9.3-test.2-manual.zip) |
| SkillDock Runtime-only | A compatible PCHW Skill is installed and only the application and Node are missing | [Download Runtime-only ZIP](https://github.com/Feng23-feng/pc-hardware-workbench/releases/download/v0.1.0-rc.7/SkillDock-Runtime-0.1.0-rc.7-win-x64.zip) |

<a id="pchw-portable"></a>

## PCHW Portable (standalone Windows; no Agent)

This package requires no Codex, DSH, API key, installer, or administrator rights.
Verify the ZIP, extract the complete directory, and double-click `开始使用.cmd` to
open the menu.

The portable build provides read-only inventory, troubleshooting, HWiNFO and
PresentMon CSV analysis, evidence packages, telemetry charts, and guided manual
tuning. It does not provide an Agent conversation or the SkillDock panel. The
shared telemetry analyzer `1.2.5` recognizes `Timestamp`, `DateTime`, `Date/Time`,
and their Chinese equivalents, and reports the sampled span.

The portable build runs locally, does not initiate network access, and never
changes BIOS, firmware, drivers, clocks, voltage, power limits, fans, or memory
timings automatically.

## SkillDock panel bundle (for Codex)

Codex Desktop must already be installed.

### Install

1. Download `SkillDock-PCHW-0.1.0-rc.7-win-x64-user.zip`.
2. Verify it with `SHA256SUMS.txt` or the GitHub asset digest.
3. Extract the full directory.
4. Double-click `Install.cmd`.
5. Wait for completion, then reopen Codex.

The installer automatically chooses the correct path:

- clean installation when no PCHW Skill exists;
- backup-based upgrade when an older Skill exists;
- restore of the old Skill if replacement or later Runtime validation fails.

If PCHW `2.9.3-test.2` is already installed, note that the rc.7 integrated user
bundle backs it up and replaces it. To keep `test.2`, install the standalone Skill
and use Runtime-only from Advanced options; that Skill-only plus Runtime-only
combination remains PENDING.

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
- For an ordinary, non-source-hosted Task, a Task/evidence export bound to the
  current state, Session, and event count must be downloaded before cleanup
  unlocks.
- A second confirmation follows. Expired, tampered, or stale exports cannot
  delete changed Task data.
- Cleanup preserves the Agent Session, capabilities, Runtime, shared engine,
  installer logs, and rollback backup. A source-hosted Task remains blocked
  while another source owns its collaboration state.

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

In Codex, invoke:

```text
$pc-hardware-workbench
```

After DSH restarts and discovers the Skill, invoke:

```text
/pc-hardware-workbench
```

PCHW can be used for configuration, troubleshooting, chat, collection, and CSV
analysis. It does not provide the Codex `pchw-source-hosted` SkillDock panel.
See the [DSH adapter](../../adapters/dsh/README.md) for details.

## SkillDock Runtime-only

Use this only when a compatible PCHW Skill is already installed and the
SkillDock application plus Node.js are missing. rc.7 preserves exact PCHW
`2.8.0` as a legacy bridge. A later PCHW must declare
`surface_contracts["pchw-source-hosted"]` in the supported
`>=1.0.0 <2.0.0` range, satisfy `min_skill_version`, and provide every required
capability such as `telemetry.csv.analyze`. It must also use UI state schema
`1.2` and event schema `1.0`; a mismatch fails closed before the panel runtime
loads:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install SkillDock Runtime.ps1"
```

After installation, open the panel from the current Codex conversation. Do not
launch `SkillDock.exe` manually for the normal user path.
This release verifies the Runtime-only package inventory and installation; the
cross-package combination that keeps PCHW `2.9.3-test.2` and adds only the rc.7
Runtime has not completed independent human signoff.

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

- `2.9.3` is the current PCHW Skill/Portable test release; clean-Windows signoff remains pending.
- the current public SkillDock test bundle is `0.1.0-rc.7` with PCHW `2.9.3`;
- the rc.7 user bundle contains a PCHW release subset based on `2.9.3-test.1`, not `2.9.3-test.2`;
- the Skill-only `2.9.3-test.2` plus Runtime-only rc.7 combination is contract-compatible but remains PENDING;
- Clean-Windows acceptance for the rc.7 final ZIP bytes remains PENDING.
- real Codex Thread behavior, human interaction, and multi-platform acceptance remain PENDING;
- Live LHM Web/WMI remains SKIP unless an authorized process is already running;
- The SkillDock panel is supported only in the current Codex user conversation.
- If the panel is unavailable, permission is denied, or another workspace is active,
  continue in chat without exposing a developer entry.
- Live collection depends on Windows permissions and the host sandbox; do not report
  permission denial as missing hardware.
- No automatic changes to BIOS, firmware, drivers, clocks, voltage, power limits,
  fans, or memory timings.
