# PC Hardware Workbench

[中文](README.md) | [English](README.en.md)

PC Hardware Workbench is a Windows-focused, read-only hardware workbench usable
from Codex, DeepSeek Harness, or another compatible Agent. It also provides a
standalone portable tool that needs no Agent, API, or installation. It brings
system inventory, troubleshooting, telemetry analysis, guided tuning, and upgrade
decisions into one workflow while leaving every persistent hardware change to the
user.

The current PCHW source and test version is **2.9.1-test.1**. The public
download remains `2.9.0-test.1 + SkillDock 0.1.0-rc.5`, and GitHub main may be
ahead of the latest public release. This source line tightens the memory-profile
identity gates for the GPU, raw tool, and display-tool versions and narrows the
memory-chart presentation. It retains the deterministic local evidence CLI and
the PCHW Skill, Portable, and DeepSeek Harness packages added in 2.9.0. PCHW
2.9.0 also declares the
`pchw-source-hosted` `1.0.0` surface contract so later Skill releases can
negotiate a minimum product version, contract SemVer, and required
capabilities instead of hard-coding one Skill version. SkillDock
`0.1.0-rc.5` is available as a public test build for that contract. The previous
`0.1.0-rc.4` package remains available for PCHW `2.8.0`. There is no stable
release yet.
Automated tests and targeted human review pass, but broad real-device coverage,
clean-Windows install/uninstall, and the remaining human scenarios are still in
progress. The project does not claim this test build is stable or fully
validated.

![File orrery preview](docs/skill-evolution/assets/orrery-preview.png)

The interactive project pages are currently available in Chinese:
[Project overview](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/) ·
[Scenario Walkthrough](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/interactive/) ·
[File orrery](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/orrery/)

## Contents

- [What it does](#what-it-does)
- [Quick start](#quick-start)
- [Open the SkillDock panel](#open-the-skilldock-panel)
- [Example prompts](#example-prompts)
- [Safety model](#safety-model)
- [Support matrix](#support-matrix)
- [Known limitations](#known-limitations)
- [Documentation](#documentation)
- [FAQ](#faq)
- [Version and license](#version-and-license)

## What it does

- **Reads the current system configuration.** Inspect visible CPU, GPU, motherboard,
  memory, storage, display, and battery information without guessing missing models.
- **Prioritizes safe troubleshooting.** Address physical safety, boot and data risk,
  stability, functional faults, and performance in that order.
- **Analyzes real telemetry.** Read CSV files, HWiNFO exports, and structured sensor
  snapshots while preserving sample interval, missing values, source, and time range,
  and render an SVG overview when a usable series exists.
- **Keeps memory-clock bases traceable.** The default overview preserves the raw
  HWiNFO value. An explicit deep view derives the Afterburner-equivalent value only
  when the GPU, raw tool, display tool, and versions all match a controlled profile.
  Provisional profiles fail closed by default.
- **Provides deterministic local evidence.** `pcwb.ps1` returns a fixed JSON envelope,
  structured status/exit codes, and SHA-256-linked inputs and artifacts for read-only
  inventory, telemetry, PresentMon, evidence-package, claim, and Doctor routes.
- **Visualizes timed plans.** Render a Gantt view for multi-phase tuning, warm-up,
  validation, reboot, and soak schedules; skip it for one-step or untimed guidance.
  `done` means execution ended without a verdict; `pass/fail` remain outcome labels.
- **Verifies user claims.** Separate measured current values, explicit user confirmation,
  historical records, estimates, and conflicts instead of silently promoting old values.
- **Analyzes frame time.** Read user-exported PresentMon CSV files and report average FPS,
  P95/P99, 1%/0.1% low, spikes, and spike clusters without launching the tool or attaching
  to a game.
- **Preserves debugging continuity.** Multi-turn, multi-evidence, or tuning work can keep a
  private local case with evidence, baselines, experiments, pass/abort criteria, recovery,
  and the next action. A compact resume packet lets a new chat continue without replaying
  the old conversation.
- **Requires evidence before tuning.** Device identity, baseline, recovery path, fixed
  workload, and stop conditions must be clear before a test candidate is produced.
- **Provides bounded GPU starting points.** When the device and evidence are complete,
  the Skill can propose one conservative, reversible, single-variable starting point.
- **Compares repair, retain, and upgrade decisions.** It does not reduce a decision to
  one benchmark score.
- **Uses additional evidence on demand.** A local RAG evidence cache, runtime web
  lookup when the host supports it, an already-running local LibreHardwareMonitor
  instance, screenshots, and hardware cases that persist across sessions are optional
  inputs.
- **Remains read-only.** It does not modify BIOS, clocks, voltage, power limits, fans,
  memory timings, or firmware automatically.

## Download packages and version lines

[Download the current PCHW 2.9.0 + SkillDock rc.5 test build](https://github.com/Feng23-feng/pc-hardware-workbench/releases/tag/v0.1.0-rc.5),
then choose exactly one package. Do not place multiple copies of the same Skill
in one host's scan directory.
Most users should start with the PCHW Skill package without the panel. Choose
the SkillDock panel bundle only when Codex is already installed and you
specifically want the graphical workspace. If no Agent is available, or you want
no installation at all, use the standalone Portable tool.

| Package | Choose it when | Includes | SkillDock panel |
| --- | --- | --- | --- |
| PCHW Skill (Codex / DSH / other Agents; no panel) | Default choice; use Codex alone or with DSH / another compatible Agent host | PCHW Skill 2.9.0 release subset only | No |
| PCHW Portable (standalone Windows; no Agent) | You do not use Codex / DSH, or want no Skill or Runtime installation | Standalone menu, collection, CSV, and evidence tools | No |
| DeepSeek Harness adapter | You use DSH and want PCHW Skill plus its adapter files | 2.9.0 Skill and DSH adapter files | Not provided |
| SkillDock Runtime-only | A compatible PCHW Skill is installed and only the Runtime and Node are missing | SkillDock Runtime + Node.js 24.22.1 | Current Codex conversation only |
| SkillDock panel bundle (public rc.5 test build) | Codex Desktop is installed and you want the PCHW 2.9.0 surface contract | PCHW 2.9.0 Skill, SkillDock rc.5 Runtime, installer | Current Codex conversation only |

The 2.9.0-test.1 release files are:

```text
PCHW-Skill-2.9.0-test.1-installer.zip
PCHW-Skill-2.9.0-test.1-manual.zip
pc-hardware-portable-v2.9.0-test.1.zip
pc-hardware-workbench-deepseek-harness-v2.9.0-test.1.zip
SkillDock-PCHW-0.1.0-rc.5-win-x64-user.zip
SkillDock-Runtime-0.1.0-rc.5-win-x64.zip
SHA256SUMS.txt
```

The SkillDock panel files for this test line are now in `v0.1.0-rc.5`. The
`v0.1.0-rc.4` release remains the previous PCHW 2.8.0 panel build. Do not mix the
2.8.0 and 2.9.0 Skill directories in one host.

This is a public test build. Clean-Windows installation, uninstallation, and
final signoff remain PENDING. Do not mix multiple Skills or old Runtime
directories.

<a id="what-is-skilldock"></a>

### What is SkillDock?

SkillDock is an optional graphical workspace for PCHW in the **current Codex
task**. After the user asks a hardware question and provides files such as CSV
exports, the panel carries in the current task, question, and attachments and
shows charts, conclusions, conflicting evidence, uncertainty, and next actions.
Local analysis requires explicit authorization; results update the page
automatically, and closing and reopening SkillDock restores the same task.

SkillDock is not a separate Agent and does not replace Codex. Reasoning and
conversation still happen in Codex; SkillDock provides the local visual and
interactive layer. The panel is supported only in Codex. DSH and other Agents use
the generic Skill without a panel.

If you only need chat, hardware collection, and CSV analysis, use the PCHW Skill
without SkillDock. Use the standalone Portable build only when you do not want an
Agent at all. SkillDock is read-only with respect to hardware and never changes
hardware settings automatically.

rc.4 inherits the rc.3 local storage panel. It exports the protected Runtime rollback
backup with its shared Node engine and a per-file SHA-256 manifest. For an
ordinary, non-source-hosted Task, a Task/evidence export must be downloaded
before cleanup is unlocked; stale, expired, or tampered exports fail closed.
Source-hosted Tasks remain blocked because another source owns their
collaboration state. Cleanup preserves the Agent Session, capabilities,
Runtime, shared engine, and rollback backup.

<a id="pchw-portable"></a>

### PCHW Portable (standalone Windows; no Agent)

1. Download `pc-hardware-portable-v2.9.0-test.1.zip` and verify it with the
   release checksum or the GitHub asset digest.
2. Extract the complete directory. No installation, administrator rights, API key,
   or network connection is required.
3. Double-click `开始使用.cmd` to open the menu.

The portable build covers inventory, troubleshooting, telemetry CSV, PresentMon,
evidence packages, and guided manual tuning, but it does not provide the SkillDock
panel. Its shared telemetry analyzer `1.2.4` recognizes `Timestamp`, `DateTime`,
`Date/Time`, and their Chinese equivalents, and reports the sampled span. Every
hardware change remains manual.

### SkillDock panel bundle (for Codex)

Codex Desktop must already be installed.

1. Download the SkillDock panel bundle and verify it with `SHA256SUMS.txt` or
   the asset digest shown on GitHub.
2. Extract it and double-click `Install.cmd`.
3. If an older PCHW Skill exists, the installer backs it up and upgrades it; do
   not delete the old Skill first.
4. Open the current Codex conversation after installation.
5. Describe the hardware problem and explicitly accept the graphical workspace.

Do not look for a runner, port, token, environment variable, or manually start
`SkillDock.exe`. The installer places both the PCHW Skill and SkillDock Runtime
from the same verified package.

<a id="pchw-skill-only"></a>

### PCHW Skill (Codex / DSH / other Agents; no panel)

This package contains the PCHW Skill only. It is not the SkillDock panel bundle
and contains no SkillDock application, Node.js, test runner,
or DSH observer. It works in Codex, DSH, and other compatible Agent hosts and is
intended for users who do not need the panel. Put `pc-hardware-workbench` in the
target Agent's Skill directory. The default Codex location is:

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

The default DSH location is:

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

Then invoke:

```text
/pc-hardware-workbench
```

See [Installation and upgrade](docs/en/installation.md#pchw-skill-only) for details.

### SkillDock Runtime-only

Use this package only when a compatible PCHW Skill is already installed and the
SkillDock application plus Node.js are missing. rc.5 preserves exact PCHW
`2.8.0` as a legacy bridge. A later PCHW must declare
`surface_contracts["pchw-source-hosted"]` in the supported
`>=1.0.0 <2.0.0` range, satisfy `min_skill_version`, and include every required
capability such as `telemetry.csv.analyze`. The previous rc.4 Runtime does not
have this negotiation path and remains limited to PCHW 2.8.0. Extract the
applicable Runtime and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install SkillDock Runtime.ps1"
```

After installation, open the panel from the current Codex conversation. Do not
launch `SkillDock.exe` manually for the normal user path. This release verifies
the Runtime-only package inventory and Runtime installation; every Skill-only
plus Runtime-only cross-package combination is not yet separately certified.

The portable tools perform only user-approved local read-only collection and
generate charts or reports when needed.

## Open the SkillDock panel

After the PCHW Skill and SkillDock Runtime are installed, describe the problem and
your evidence in the current Codex conversation:

```text
The game starts stuttering after about twenty minutes. Here is the HWiNFO CSV.
Can you open the graphical analysis?
```

After you agree, the Skill opens the local panel with the current question, Task,
and supported attachment context. The first analysis asks for an explicit
one-time permission. The result includes a real SVG chart, a concrete judgement,
supporting and conflicting evidence, uncertainty, and two or three low-risk
actions. The page updates automatically when the result returns. Copy the
result back to the current Codex conversation. The same Task, chart, and
conclusion remain available after SkillDock is closed and restarted.

After the same attachment has completed one successful local analysis, a repeat
analysis may offer “同一附件后续分析” (repeat analysis for this attachment). It
still covers only that CSV in the current Task and lasts for two hours. A
different attachment requires a new one-time decision.

If Codex Ask-for-approval mode prevents automatic opening, use the short-lived
manual link or local `.url` shortcut shown by the Skill. If the default runtime
directory is not writable, the panel cannot start, or another workspace is
active, continue in the current conversation without creating a second Thread.

This release promises the `pchw-source-hosted` SkillDock panel only for the
current Codex conversation. DSH and other hosts may use the PCHW Skill for
chat, collection, and CSV analysis, but they are not promised this panel. If
permission is denied, the panel cannot start, or another workspace is active,
continue in chat; losing the panel must not break the conversation.

Use **Local storage** in the panel header to export the protected Runtime
rollback backup, including its shared Node engine and per-file SHA-256 manifest.
Task and evidence cleanup for ordinary, non-source-hosted Tasks requires a
downloaded, state-bound export and a second confirmation; stale, expired, or
tampered exports fail closed. Source-hosted Tasks remain blocked because another
source owns their collaboration state. Cleanup preserves the current Agent
Session, capabilities, Runtime, shared engine, installer logs, and rollback
backup. Export links expire after 24 hours, and expired files are pruned on
Runtime startup or storage-panel refresh.

The panel performs only user-approved read-only analysis and Task artifact
writes. It never changes BIOS, firmware, drivers, clocks, voltages, power
limits, fans, or memory timings automatically.

## Example prompts

```text
Show me the current hardware configuration and identify what could not be read.
```

```text
The game occasionally stutters. Tell me what evidence is still missing before
recommending any overclocking values.
```

```text
Analyze this HWiNFO CSV for trends, missing data, and abnormal time windows.
```

```text
Analyze this PresentMon CSV for stutter and render a frame-time chart I can inspect.
```

```text
Turn this timed tuning plan into a timeline I can inspect.
```

```text
I want this GPU to run quieter, but I do not have a recovery point or a fixed test
workload yet.
```

The Skill routes the request to inventory, troubleshooting, telemetry, tuning, or
upgrade planning. When evidence is incomplete, it asks for the smallest useful next
step instead of bypassing safety gates.

## Safety model

- No automatic BIOS/UEFI, clock, voltage, power-limit, fan, memory-timing, or firmware
  changes.
- No automatic elevation, driver installation, or monitoring-software startup.
- No bypass of permissions, anti-cheat, vendor locks, or other safety controls.
- Stop when there is a burning smell, spark, liquid, melted connector, swollen battery,
  or visible damage.
- No tuning experiment without a recovery path and stop conditions.
- The Skill reads LibreHardwareMonitor only when the user has already started it and
  explicitly allows access through the local loopback endpoint or the read-only WMI
  fallback.

Hardware parameters are test starting points, not guarantees. Safety takes priority.

Read [Privacy and safety boundaries](docs/en/privacy-and-safety.md) for the full policy.

## Support matrix

| Host | Configuration, troubleshooting, chat, CSV | SkillDock panel |
| --- | --- | --- |
| Current Codex conversation | Supported | Supported |
| DeepSeek Harness | Supported | Not provided |
| Other Agent hosts | Use according to the host's file access | Not promised |

## Known limitations

- `2.9.1` is the current source PCHW Skill/Portable test line and has no stable release;
- the current public SkillDock test bundle is `0.1.0-rc.5` with PCHW `2.9.0`;
- the previous `0.1.0-rc.4` bundle remains the PCHW `2.8.0` panel build;
- Clean-Windows acceptance for the rc.5 final ZIP bytes is still pending;
- clean-Windows install/uninstall, real-device coverage, and complete user signoff
  are still in progress;
- the SkillDock panel is promised only for the current Codex conversation;
- Ask-for-approval mode may require the “Open the panel manually” link or `.url`
  shortcut;
- DSH and other hosts do not receive this SkillDock panel;
- background autonomous analysis, automatic recovery, and automatic hardware
  changes are not provided.

## Documentation

- [English installation and upgrade](docs/en/installation.md)
- [English privacy and safety](docs/en/privacy-and-safety.md)
- [Chinese installation and upgrade](docs/installation.md)
- [Chinese usage guide](docs/usage.md)
- [Chinese architecture](docs/architecture.md)
- [Chinese troubleshooting](docs/troubleshooting.md)
- [Changelog](CHANGELOG.md)
- [GitHub Releases](https://github.com/Feng23-feng/pc-hardware-workbench/releases)
- [Contributing](CONTRIBUTING.md)
- [Security policy](SECURITY.md)

Advanced architecture and behavior-test documentation are currently available in
Chinese. The contributing and security policies are available in English.

## FAQ

- **Codex does not show the Skill.** Confirm that `SKILL.md` exists in the installed
  directory, then restart Codex.
- **Collection returns access denied.** Retry in a normal, non-elevated PowerShell
  session. The Agent sandbox may restrict CIM, storage, or display queries.
- **LibreHardwareMonitor returns no data.** LHM must already be running, either its web
  server must be bound to loopback or read-only WMI must be available, and the user
  must explicitly allow access.
- **A CSV is rejected.** Do not use UNC paths, mapped network drives, cloud placeholder
  files, symbolic links, directory junctions, or other reparse points.
- **GPU tuning is blocked.** Provide the exact GPU, current control values, baseline,
  fixed workload, recovery path, and stop conditions.

## Version and license

Use [GitHub Releases](https://github.com/Feng23-feng/pc-hardware-workbench/releases)
and [CHANGELOG.md](CHANGELOG.md) as the source of version status. The current
build is a `2.9.1` test build, and no stable release has been published. GitHub
main may be ahead of the downloadable test build.

Source code is available under the [MIT License](LICENSE).

Copyright (c) 2026 Feng23-feng.

Third-party software, installers, images, and vendor materials remain subject to their
own licenses and may not be redistributed without separate permission.
