# PC Hardware Workbench

[中文](README.md) | [English](README.en.md)

PC Hardware Workbench is a Windows-focused, read-only hardware Skill for Codex and
DeepSeek Harness. It brings system inventory, troubleshooting, telemetry analysis,
guided tuning, and upgrade decisions into one workflow while leaving every
persistent hardware change to the user.

The current release line is a **2.8.0 test build** and has not been formally
released. Automated tests and targeted human review pass, but broad real-device
coverage, clean-Windows install/uninstall, and the remaining human scenarios are
still in progress. The project does not claim this test build is stable or fully
validated.

![File orrery preview](docs/skill-evolution/assets/orrery-preview.png)

The interactive project pages are currently available in Chinese:
[Project overview](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/) ·
[Interactive lab](https://feng23-feng.github.io/pc-hardware-workbench/skill-evolution/interactive/) ·
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

## Choose one package

Choose the package that matches where you use the Workbench. Do not place
multiple copies of the same Skill in one host's scan directory.

| Package | Choose it when | Includes | Panel |
| --- | --- | --- | --- |
| Portable | You do not want a Skill host | Local read-only collection, CSV analysis, charts, reports | No SkillDock; local menu |
| DSH core-only | You use DeepSeek Harness | PCHW Skill and DSH adapter | No SkillDock panel |
| Codex + SkillDock | You use Codex Desktop and want the panel | PCHW Skill, SkillDock Runtime, one installer | Current Codex conversation only |

Current candidate asset names:

```text
pc-hardware-portable-v2.8.0.zip
pc-hardware-workbench-deepseek-harness-v2.8.0.zip
SkillDock-PCHW-0.1.0-rc.1-win-x64-user.zip
```

Version 2.8.0 has not been formally released. Treat the files and SHA-256
sidecars actually present in Releases as authoritative, and do not mix assets
from older package schemes.

### Codex + SkillDock

1. Download the Codex integrated package and verify its `.sha256` sidecar.
2. Extract it and double-click `Install.cmd`.
3. If an older PCHW Skill exists, the installer backs it up and upgrades it; do
   not delete the old Skill first.
4. Open the current Codex conversation after installation.
5. Describe the hardware problem and explicitly accept the graphical workspace.

Do not look for a runner, port, token, environment variable, or manually start
`SkillDock.exe`. The installer places both the PCHW Skill and SkillDock Runtime
from the same verified package.

### DSH core-only

The DSH package contains the PCHW Skill and Harness adapter, but no SkillDock
panel. Place the Skill under
`%USERPROFILE%\.dsh\skills\pc-hardware-workbench`, then invoke:

```text
/pc-hardware-workbench
```

See [Installation and upgrade](docs/en/installation.md) for details.

### Portable Windows tools

No Codex, DSH, or SkillDock installation is required. Extract the portable
package and run:

```powershell
cd portable
.\开始使用.cmd
```

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
actions. The page updates when the result returns; do not press F5. Copy the
result back to the current Codex conversation. The same Task, chart, and
conclusion remain available after SkillDock is closed and restarted.

If Codex Ask-for-approval mode prevents automatic opening, use the short-lived
manual link or local `.url` shortcut shown by the Skill. If the default runtime
directory is not writable, the panel cannot start, or another workspace is
active, continue in the current conversation without creating a second Thread.

This release promises the `pchw-source-hosted` SkillDock panel only for the
current Codex conversation. DSH and other hosts may use the PCHW Skill for
chat, collection, and CSV analysis, but they are not promised this panel. If
permission is denied, the panel cannot start, or another workspace is active,
continue in chat; losing the panel must not break the conversation.

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
| Portable package | No Skill host required | No SkillDock |

## Known limitations

- `2.8.0` remains a test build and has not been formally released;
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
and [CHANGELOG.md](CHANGELOG.md) as the source of version status. The current release
line is a `2.8.0` test build and has not been formally released. GitHub main may be
ahead of the latest public Release.

Source code is available under the [MIT License](LICENSE).

Copyright (c) 2026 Feng23-feng.

Third-party software, installers, images, and vendor materials remain subject to their
own licenses and may not be redistributed without separate permission.
