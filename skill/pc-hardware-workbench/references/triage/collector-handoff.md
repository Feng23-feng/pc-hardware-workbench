# Optional collector handoff

Use this reference only when a current hardware baseline could reduce repeated questions and the target Windows device is accessible.

## Preconditions

- The user wants diagnosis, tuning, or an evidence-based hardware discussion.
- The operating system is running well enough to execute a local PowerShell inventory.
- This Skill's bundled collector is present under `scripts\collect-windows.ps1` with its three native C# helper files, the `scripts\device-identity.ps1` identity helper, the `scripts\local-path-safety.ps1` path helper, and the `scripts\inventory-context.ps1` classification helper. Keep all seven collector files together.
- The user understands that the collector is local and read-only, makes no network requests, omits serial numbers, and may still expose model or part identifiers.
- The user has chosen standard or privacy-redacted output before collection starts.

Do not run the collector for a no-boot or no-POST system. For suspected storage failure, filesystem corruption, ransomware, or an untrusted device, prioritize data preservation and specialist recovery over inventory work.

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
