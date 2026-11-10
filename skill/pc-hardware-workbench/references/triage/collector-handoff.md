# Optional collector handoff

Use this reference only when a current hardware baseline could reduce repeated questions and the target Windows device is accessible.

## Preconditions

- The user wants diagnosis, tuning, or an evidence-based hardware discussion.
- The operating system is running well enough to execute a local PowerShell inventory.
- This Skill's bundled collector is present under `scripts\collect-windows.ps1` with its three native C# helper files, the `scripts\device-identity.ps1` identity helper, the `scripts\local-path-safety.ps1` path helper, and the `scripts\inventory-context.ps1` classification helper. Keep all seven collector files together.
- The user understands that the collector is local and read-only, makes no network requests, omits serial numbers, and may still expose model or part identifiers.
- The user has chosen standard or privacy-redacted output before collection starts.

Do not run the collector for a no-boot or no-POST system. For suspected storage failure, filesystem corruption, ransomware, or an untrusted device, prioritize data preservation and specialist recovery over inventory work.

## Event and log handoff

Inventory alone cannot explain a crash, driver reset, audio dropout, or intermittent
black screen. Ask which symptom and time window matter, then collect only the
related evidence:

- Windows Logs `System` and `Application`, filtered to the incident window;
- `WHEA-Logger`, `Kernel-Power`, `BugCheck`, storage, display-driver, audio, and
  device-install, USB-controller, and USB-device reset events when present;
- the exact stop code or bug-check text;
- recent driver, Windows, BIOS, game, or hardware changes;
- frame-time or audio-dropout timing on the same fixed workload.

For USB audio symptoms, Device Manager's “Devices by connection” view can help
group a device with its hub and controller. It does not reliably map that group
to the physical rear or front-panel port, so inspect the motherboard manual or
physical labels before claiming two ports are independent controllers.

Use built-in Windows tools for event logs and the bundled analyzer for telemetry
files. If using Event Viewer, open `eventvwr.msc`, select the relevant log,
filter by time and event source, and save a focused view rather than exporting
unrelated history. Do not require a third-party analyzer unless it is official
and the user chooses to use it; never install, elevate, or upload logs
automatically.

| Evidence | Usual tool | What it can show | What it cannot prove alone |
| --- | --- | --- | --- |
| `.evtx` or live Windows events | Event Viewer | Providers, IDs, timestamps, stop text | root cause, physical damage, or a safe replacement part |
| `.etl` event trace | Windows Performance Recorder + Windows Performance Analyzer | timing, DPC/ISR and driver activity when the matching capture profile was used | a permanent fault from one trace |
| `.dmp` crash dump | WinDbg | bug-check code, loaded modules, call stack | which part failed without corroborating evidence |
| HWiNFO CSV or SensorSnapshot | bundled telemetry analyzer | trends and comparable sensor windows | diagnostic cause or stability proof |

These Microsoft tools and the bundled analyzer are optional evidence readers.
Do not download or install them without the user's agreement. State which file
type is present before recommending a tool; do not tell someone with `.evtx` to
open a `.dmp` analyzer or vice versa.

Correlation is not causation. For example, `WHEA-Logger` proves that Windows
recorded a hardware error, `Kernel-Power 41` proves only that shutdown was
unclean, and an NVIDIA display-driver event proves the driver reported an issue,
not that replacing the GPU is the correct next step. Preserve competing evidence
and test one reversible change.

## Handoff sequence

1. Use the bundled collector and follow [collector-workflow.md](../integration/collector-workflow.md); it does not require another installed Skill.
2. Prefer JSON for machine-to-machine handoff because its field meanings and version metadata are explicit. Use Markdown only when a human-readable report is the intended result.
3. Preserve `SchemaVersion`, `CollectorVersion`, `GeneratedAt`, `PrivacyMode`, and collection warnings. Do not reinterpret a report from an unsupported or unknown schema as if field meanings were unchanged.
4. Treat the output as `AUTO-CURRENT`: hardware visible during this collection. It is not proof that a manual tuning profile is active, stable, or suitable.
5. Continue with the original symptom intake. Request only the missing load, temperature, power, event-log, benchmark, and reproducibility evidence that can change the diagnosis.
6. If privacy-redacted output was selected, preserve its redaction. Do not reconstruct hidden model identifiers from context or auxiliary tools.

## Handling limitations

- A denied WMI, storage, or monitor query is a collection limitation, not evidence that the hardware is absent.
- Do not infer a workload bottleneck from component tiers alone.
- Do not treat a healthy disk status as a full SMART or data-integrity audit.
- Do not treat a supported HDR capability as evidence that HDR is enabled.
- Do not treat the active display-adapter list as a complete installed-adapter inventory.
- Do not infer DDR5 die, rank, PMIC, or live timings from a module part number without direct evidence.
- Do not automatically retry with elevation. If broad access denial occurs inside
  an agent sandbox, first offer the same read-only command for a normal
  non-elevated PowerShell outside that sandbox. Only if specific fields still
  need administrator rights, such as Storage Reliability counters, offer a
  command for an Administrator PowerShell the user started themselves. Do not
  bypass the sandbox, install drivers, or disable security controls. Elevation
  cannot reveal firmware-hidden sensors.

If collection fails or the Skill is unavailable, continue the manual checklist. A collector handoff is an optimization, never a prerequisite for triage.
