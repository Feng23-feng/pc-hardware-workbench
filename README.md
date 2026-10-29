# PC Hardware Workbench / 电脑硬件工作台

An evidence-gated, read-only Windows hardware workbench for Codex and DeepSeek
Harness. It routes inventory, troubleshooting, telemetry analysis, manual tuning
guidance, and upgrade decisions through one Skill while keeping all hardware
changes under the user's control.

一个面向 Codex 与 DeepSeek Harness 的 Windows 只读硬件工作台，统一处理配置
读取、故障排查、遥测分析、手动调校指导和升级判断；不会自动修改 BIOS、频率、
电压、功耗、风扇或固件。

## Project status

- Current candidate: **1.4.3**
- Automated non-live tests: passing
- Live hardware collection: opt-in only
- Broad release sign-off: pending
- Repository license: **MIT**

## Why this project exists

Hardware advice often fails in three ways: it skips the actual machine state,
treats one benchmark as proof of daily stability, or suggests settings without
a recovery path. This project keeps those decisions explicit:

1. collect only what is relevant and authorized;
2. establish a stable baseline before changing a variable;
3. state one variable, pass criteria, abort signals, and rollback;
4. treat telemetry as evidence, not proof of stability;
5. keep every persistent hardware change user-applied.

The triage route also covers everyday slowdowns, game stutter, common Windows crash
records, laptop battery versus adapter evidence, and a short peripheral/network
handoff. Monitoring screenshots are accepted only as limited single-point evidence;
CSV logs remain the basis for statistics and time-window comparisons.

Telemetry recognition includes Intel package sensors, AMD HWiNFO Tctl/Tdie
temperature, CPU PPT package power, GPU core voltage, and CPU core maximum
temperature where those columns are exposed.

## Collaboration model

This is an AI-assisted, human-controlled project:

- Codex may inspect evidence, explain tradeoffs, and propose bounded experiments.
- The user authorizes data collection, applies every hardware change manually,
  and owns rollback and recovery.
- The project never bypasses permissions, anti-cheat, vendor locks, or safety
  limits.
- Automated tests and AI reviews support quality checks but do not replace
  independent human acceptance or real-hardware judgment.

## How this project is built

This project combines human hardware experience with AI-assisted engineering:

- The maintainer contributes hands-on testing, real failure cases, safety rules,
  interpretation of results, and final product decisions.
- Codex and DeepSeek Harness assist with implementation, documentation, test
  design, code review, packaging, and CI maintenance.
- AI can propose changes, but the human owner decides what is accepted and
  released.

## What is included

```text
skill/pc-hardware-workbench/   Codex Skill, scripts, references, tests
portable/                      Standalone Windows PowerShell tool
tools/validate-skill.py        Structural validation used by CI
tools/validate-skill.ps1       Wrapper: bootstrap/offline validation
tools/check-portable-sync.ps1  Skill -> portable shared-script drift check
tools/check-package-sync.ps1   Skill tree vs shipped package drift check
.github/workflows/ci.yml       Windows CI (whitespace audit + tests + validator)
LICENSE                        MIT
CHANGELOG.md                   Version history
CONTRIBUTING.md                How to contribute safely
SECURITY.md                    How to report issues privately
```

## Codex Skill

Copy `skill/pc-hardware-workbench` into your Codex skills directory:

```text
<user-home>/.codex/skills/pc-hardware-workbench
```

Then invoke:

```text
$pc-hardware-workbench
```

The Skill is Windows-focused for automatic collection. Other operating systems
receive manual guidance. Inventory is read-only and serial numbers are omitted.

The default collection runs without elevation. Broad access denial inside an agent
sandbox is handled first by rerunning in a normal non-elevated PowerShell outside
that sandbox. Only fields that remain genuinely permission-dependent justify a
user-started elevated run. The Skill never launches UAC or elevates itself.
Elevated access does not expose firmware-hidden temperatures, clocks, voltages, or
fan sensors. NVIDIA `nvidia-smi` values are labelled as timestamped instantaneous
samples rather than stability evidence.

Battery collection preserves three outcomes: `available`, `not-present`, and
`unavailable-permission` (or generic `unavailable`). A permission failure is never
misreported as a machine without a battery. `BatteryStatusReason` identifies the
failing stage and `BatteryCimStatus` records the independent CIM result.

### Use with DeepSeek Harness

The same Skill tree loads in DeepSeek Harness. The installation directory and
the invocation syntax differ from Codex:

```text
<dsh-home>/skills/pc-hardware-workbench
```

`<dsh-home>` is `%USERPROFILE%\.dsh` unless `DSH_HOME` is set. Invoke from the
chat input with a leading slash:

```text
/pc-hardware-workbench
```

`SKILL.md` may add `disable-model-invocation: true` when the Skill should stay
explicit-only, and `user-invocable: false` when it should never be slash-invoked.
Those visibility fields are optional and do not change the scripts, references,
tests, or safety boundaries, which are the same files as the Codex copy. A
Harness-specific distribution package can be provided separately from this
repository.

## Portable Windows tool

Run:

```powershell
cd portable
.\开始使用.cmd
```

Or run the non-hardware self-test directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -SelfTest
```

Live collection requires all of the following:

- an explicit `-AllowLiveCollector` switch;
- a selected privacy mode;
- the user's consent.

## Safety boundaries

- No automatic BIOS/UEFI, clock, voltage, power-limit, fan, memory-timing, or
  firmware changes.
- No automatic elevation, driver installation, security-control bypass, sandbox
  escape, or anti-cheat interference.
- Physical danger such as smoke, sparks, liquid, a melted connector, or a
  swollen battery stops performance testing.
- Unexplained instability blocks tuning until a stable baseline is restored.
- A parameter change carries the standard safety notice in the reply's language:
  `参数仅供参考，请以安全为第一要务。` (Chinese) or
  `For reference only - put safety first.` (English). The two are never mixed in
  one reply.

Recommended tools and reference values are guidance, not universal profiles.

## Privacy

The collector omits serial numbers by default. Redacted mode hides computer,
motherboard, BIOS, memory part-number, storage, volume-label, monitor, and
battery manufacturer identifiers while preserving useful capability data.
Standard and redacted component objects keep the same keys and array lengths;
memory `Bank` and monitor `AdapterName` remain visible so channel evidence and
declared GPU identity stay usable.

Telemetry analysis rejects UNC paths, mapped network drives, cloud placeholder
files, symlinks, junctions, and reparse points. Markdown output is treated as
untrusted display text.

Review any hardware report before sharing it publicly.

## Tests

From the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\skill\pc-hardware-workbench\tests\run-all-tests.ps1 `
  -SkillRoot .\skill\pc-hardware-workbench

powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\validate-skill.ps1

powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\portable\start.ps1 -SelfTest
```

Check for drift between the Skill and portable shared scripts:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\check-portable-sync.ps1
```

Check for drift between the Skill tree and a shipped package:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\check-package-sync.ps1 `
  -LeftRoot .\skill\pc-hardware-workbench `
  -RightRoot <unpacked-package-dir>\skill\pc-hardware-workbench `
  -IgnoreEolOnly
```

The audit separates real content differences from packaging noise (line endings
and a UTF-8 BOM are reported as `EOL-ONLY`, not as content drift). Exit codes:
`0` aligned, `1` drift found, `2` usage or path error.

For an intentional one-way `Skill -> Portable` update, a maintainer may run the
same command with `-Fix`. Portable-only files are never deleted automatically,
and `-Fix` is rejected when `CI=true` or `GITHUB_ACTIONS=true`.

Real hardware smoke tests remain opt-in and are not run by CI.

The validation wrapper uses a persistent Python environment outside this
repository. By default it is created at
`%LOCALAPPDATA%\pc-hardware-workbench\.validation-venv`; override the location
with `-VenvPath <path>` or the `CODEX_VALIDATION_VENV` environment variable.
Create it once:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\validate-skill.ps1 -Bootstrap
```

Later validation runs are offline and need no temporary PyYAML download. The
wrapper runs both the repository validator and the official
`skill-creator/scripts/quick_validate.py`; the official validator receives a
temporary structural copy with UTF-8 BOMs removed.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Do not submit real serial numbers,
private hardware logs, account names, or unsanitized screenshots.

## Security reports

See [SECURITY.md](SECURITY.md). Do not open a public issue containing a
hardware log, private path, or other identifying information.

## License

This project is licensed under the [MIT License](LICENSE).

Copyright (c) 2026 Feng23-feng.

The MIT License applies to this repository's original source and documentation.
Third-party software, installers, images, or vendor materials remain subject to
their own licenses and must not be redistributed without separate permission.
