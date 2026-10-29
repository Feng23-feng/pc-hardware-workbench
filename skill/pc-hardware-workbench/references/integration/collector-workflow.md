# Collector workflow

Use the embedded Windows collector only when the user wants a current hardware inventory and the machine is accessible enough to run a local read-only query.

## Explain before asking

- **Standard mode:** keeps exact computer, board/laptop, BIOS, memory-part, storage-model, monitor-ID, and volume-label details. Use it for the user's own machine or trusted troubleshooting; it gives the most precise compatibility, driver, warranty, and upgrade analysis.
- **Privacy-redacted mode:** hides the identifying fields defined by the canonical [privacy-redacted contract](../upgrade/output-format.md#privacy-redacted-mode), while retaining capacities, speeds, core/thread counts, memory bank and structural slot/channel evidence, interfaces, disk mappings, battery health, display adapter identity, and display/HDR capability. Use it for public posts, group chats, or strangers; model-level compatibility, recall, warranty, and resale precision will be lower.

Both modes are local and read-only, use no network, omit serial numbers, and change no hardware setting. Explain this distinction before asking the user to choose.

Elevation is separate from privacy mode. The default non-elevated run remains
first. When broad access-denied warnings appear inside an agent sandbox, the first
remedy is to run the collector from a normal non-elevated PowerShell outside that
sandbox. Only if a decision-relevant field remains unavailable, such as Storage
Reliability counters, offer a user-started elevated run. Requested event-log
inspection is a separate read-only step. Elevation does not expose
firmware-hidden temperatures, clocks, voltages, or fan sensors and never
authorizes a configuration change.

Before offering collection, reuse a current-session snapshot, a fresh inventory report already provided by the user, or a recent relevant report whose generation time and scope are known. Do not ask the user to repeat collection merely because the conversation changed subtask. Offer a refresh when hardware, BIOS/driver, memory, storage, or display configuration may have changed.

Before reusing an older local report, explicitly ask whether the user recently changed the CPU, GPU, memory, storage, motherboard or laptop, monitor, or power adapter. If yes, collect a fresh snapshot and label the previous report stale for the current task; do not silently carry old device identity forward.

If several reports are available, present the choices with generation time, filename, and a compact platform summary. Default to the most recent only when that is unambiguous; otherwise ask which machine the current task concerns.

Always preserve the snapshot's `IdentityQuality`. It is field quality, not the
session identity status: `readable` maps to `confirmed`; `partial`, `unknown`,
and `redacted` map to `unknown`; `suspicious` and `unreadable` map to
`unreadable`. A redacted model is withheld rather than corrupted. Follow
[device-identity.md](device-identity.md) for the full mapping and mode-specific
handling. `conflict` belongs at session level when two readable sources
disagree.

## Commands

Standard:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\collect-windows.ps1" -Format Markdown
```

When `-OutputPath` is supplied, it must be a new local file in an existing local
directory. UNC paths, mapped network drives, and existing files are rejected;
the collector never overwrites a report.

Privacy-redacted:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\collect-windows.ps1" -Format Markdown -RedactIdentifiers
```

Optional elevated read-only inventory, from a PowerShell window the user has
explicitly started as Administrator:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\collect-windows.ps1" -Format Markdown -RequireElevated
```

`-RequireElevated` verifies that the current process already has administrator
rights. It does not launch UAC, self-elevate, or retry automatically.

## Exit codes

- `0`: collection completed and the requested output was produced;
- `1`: collection started but failed during processing or output generation;
- `2`: invalid input was rejected before collection, such as an existing or
  non-local `-OutputPath`, incompatible arguments, or another unsafe request.

Treat a nonzero exit as no valid snapshot. Do not parse a partial report as a
successful collection.

`-RedactIdentifiers` follows the canonical field and shape contract in
[output-format.md](../upgrade/output-format.md#privacy-redacted-mode).
It is a scoped hardware-identity redaction, not a general-purpose cleaner for
arbitrary user text or unrelated files.

## Boundaries

- Obtain consent before running the collector.
- Do not run it for a no-boot system or during urgent data recovery.
- Do not self-elevate or launch UAC. Offer a user-run elevated command only when
  named access-denied fields materially affect the decision.
- Never install drivers, bypass a sandbox, disable security features, or elevate
  merely to obtain sensors hidden by firmware or a protected process.
- Keep the seven collector files together; do not copy the PowerShell script
  without its native, identity, local-path, and inventory-context helper files.
- A snapshot proves only what was visible during collection. It does not prove the active tuning profile, stability, temperatures, power behavior, workload bottleneck, or fault cause.
- Preserve battery availability as `available`, `not-present`,
  `unavailable-permission`, or `unavailable`, together with the recorded reason
  and CIM status. Permission denial is not absence of hardware.

## Resume the calling flow

Inventory is often an evidence step inside triage, tuning, or purchase. After presenting the snapshot:

1. state which original questions the snapshot answered;
2. list only the remaining unknowns;
3. ask the next single question or continue the original gate;
4. do not end the conversation with only the inventory report unless the user requested inventory-only.

When the calling task involves tuning, noise, temperature, sustained power, or upgrade thermal headroom, establish cooling context after the form factor is known:

- desktop: after the target component is known, ask only the related cooling choice plus relevant case airflow; do not ask for GPU cooling during a CPU-only task or CPU cooling during a GPU-only task;
- laptop: do not ask the user to reconstruct the internal cooler; use the exact model, CPU/GPU class, active vendor performance mode, and official platform power envelope as a provisional ceiling;
- require measured power, temperature, throttling, fan behavior, and a fixed workload before calling the cooling capacity adequate or inadequate.

Read [cooling-evidence.md](cooling-evidence.md) for the evidence rules.

If collection is cancelled or unavailable, say that no file was produced or no snapshot was obtained, preserve the original goal, and offer a manual-value route or another safe next step.

If collection succeeds but `IdentityQuality` is not readable, retain the component evidence, label the model unreadable or uncertain, and do not claim exact model compatibility. If Windows is unavailable or the system does not boot, continue safe triage and request a readable chassis label or system-page identity rather than repeatedly offering an impossible collector.

For field meanings and fallback behavior, read [../upgrade/hardware-detection.md](../upgrade/hardware-detection.md). For inventory output shape, read [../upgrade/output-format.md](../upgrade/output-format.md).
