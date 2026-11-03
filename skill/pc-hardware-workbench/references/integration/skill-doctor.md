# Skill Doctor

Use `scripts/doctor.ps1` when the user asks whether the Skill is installed
correctly, a script behaves differently across sessions, an output directory
fails, PowerShell compatibility is uncertain, or optional live-monitoring tools
are unavailable.

The doctor is diagnostic and read-only with respect to hardware and Skill files.
It does not install, elevate, repair, rewrite, start, or stop anything.

## Basic check

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\doctor.ps1" -SkillRoot "<skill>" -OutputDirectory "<existing-output-folder>" -ValidatorPath "<validator>"
```

JSON output:

```powershell
... -Format Json
```

## What it checks

- Skill root and parsed Skill version;
- required scripts, metadata, and references;
- PowerShell syntax for every `.ps1`;
- UTF-8 BOM for non-ASCII PowerShell scripts;
- current PowerShell edition/version and optional PowerShell 7;
- basic Windows CIM access;
- optional `nvidia-smi`;
- optional LibreHardwareMonitor process/WMI state;
- real write/delete access in a selected output directory;
- optional validator path;
- model vision and OCR remain `UNKNOWN` because the script cannot prove runtime
  capabilities.

## LibreHardwareMonitor probe

The LHM check is skipped by default. To inspect an already-running local LHM:

```powershell
... -ProbeLhm -AllowLiveCollector
```

This read-only probe checks the process and `root/LibreHardwareMonitor` sensor
namespace. It never starts LHM or elevates.

## Status values

- `AVAILABLE`: the check succeeded.
- `OPTIONAL_MISSING`: a non-core optional capability is absent.
- `PERMISSION_REQUIRED`: the environment denies access but does not establish a
  hardware or Skill defect.
- `BROKEN`: a core file, syntax, encoding, or required capability failed.
- `UNKNOWN`: the script cannot determine the capability.
- `SKIP`: the user did not request this probe.

Exit codes:

- `0`: no core `BROKEN` result;
- `1`: one or more core `BROKEN` results;
- `2`: the path helper or command could not start.

The doctor result is environment evidence, not hardware stability evidence and
not release approval.
