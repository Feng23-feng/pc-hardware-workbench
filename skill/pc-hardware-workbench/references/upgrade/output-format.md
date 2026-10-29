# Recommendation output

Choose the output shape that matches the purchase intent. Do not force a
performance template onto a preference, gift, or future-project purchase.

## Functional performance or capability assessment

Use this shape for a functional performance, capability, repair, or
replacement assessment:

```markdown
## Verdict
Keep / Tune / Repair / Upgrade / Wait

## Why
The demonstrated bottleneck, or the reason no purchase is justified.

## Cheapest useful action
Settings, cleanup, configuration, repair, or component choice.

## Upgrade option
The minimum component that addresses the bottleneck. Mention a more expensive option only if it has a clear additional benefit.

## Compatibility and risk
Socket, power, cooling, physical fit, ports, firmware, recovery, and warranty.

## Current net cost
Date, region, price range, expected resale, and calculated net cash cost.

## Assumptions and omitted details
Only the optional SKU, regional, or market information that materially changed confidence. Do not ask again when the user declines to provide it.

## Buy threshold
The maximum net cost or minimum performance uplift at which the recommendation changes.

## Evidence still missing
Only the measurements that could materially change the decision.
```

Keep the answer concise. Separate performance value from aesthetic, convenience, collection, or emotional value.

## Preference, gift, or future-project assessment

Use this shape when the user explicitly identifies a preference, collection,
gift, or planning purchase:

```markdown
## Verdict
Buy / Wait / Don't buy

## Purchase goal
The actual preference, gift, collection, capability, or future-project goal.

## Evidence
How well the option satisfies that stated goal, without inventing a performance problem.

## Compatibility and practical fit
Physical fit, power, platform, software, delivery, warranty, and return conditions.

## Current cash cost
Date, region, currency, price range, retained/sold/gifted disposition, and net cash outlay.

## Tradeoff
Opportunity cost, alternatives, uncertainty, and any relevant non-purchase option.

## Decision threshold
What budget, availability, compatibility, or preference change would alter the verdict.

## Evidence still missing
Only facts that could materially change the preference or planning decision.
```

For a preference purchase, label preference value as preference value. Do not
describe it as FPS, throughput, temperature, or other performance gain. Do not
require a fabricated bottleneck or an already-tested non-purchase remedy.

## Inventory-only output

When the user only asked to inspect the local hardware, use one consolidated response:

```markdown
## System
Computer model, OS and architecture, BIOS version/release date, firmware mode, Secure Boot state, motherboard, total and available memory.

## CPU
Detected CPUs with physical core count and logical thread count. Keep any reported clock in JSON diagnostics rather than the default human-readable inventory.

## GPU
Windows-reported GPUs, drivers, and reported memory only when the source is reliable. For NVIDIA adapters, an `nvidia-smi` instantaneous sample may include temperature, power, graphics clock, utilization, fan percentage, and power limit; timestamp it and label unavailable `[N/A]` fields. One sample does not prove sustained behavior or stability. The automatic list does not prove an adapter is active; if an expected adapter is missing, request the read-only PnP display-adapter check described in `hardware-detection.md`. Do not present CIM `AdapterRAM` as accurate VRAM capacity.

## Battery
Only for devices with an actually detected system battery. Show design capacity,
full-charge capacity, health percentage, and current power state when available.
If battery data are unavailable, state the status and reason: permission denial,
`powercfg` unavailability, CIM unavailability, or confirmed absence. Omit the
section entirely only when the platform confirms that no system battery exists.

## Memory
Module-level values if available. Otherwise say they are unavailable and still list total/available memory. When die, rank, PMIC, or live timings affect the answer but were not collected, name the missing HWiNFO Memory Timings fields instead of inferring them.

## Storage
Windows-reported physical disk models and health if available. The list is not proof that every device is active or online. Map logical volumes to physical disk and partition numbers when readable. Always list fixed and removable local volumes with free space, even if physical disk details or mappings are unavailable; exclude network drives.

## Monitors
EDID models if available. Otherwise, when the active-display fallback works, list active PnP identifiers and adapters while marking them as fallback data; exclude inactive and virtual displays. Present current resolution/refresh rate, framebuffer bits per pixel, HDR state, DXGI output color space, and advanced-color-pipeline state as separate lines. Explain that 32 bits per pixel is framebuffer formatting, not GPU precision or Windows architecture. HDR must be reported as On, Supported but off, Not supported, or Unavailable. Do not equate an enabled advanced-color pipeline with HDR. Current settings are not native panel maximums.

## Unavailable in this environment
List fields that could not be collected and the minimum manual additions needed.
```

## Privacy-redacted mode

This section is the canonical field contract for `-RedactIdentifiers`. Other
references should point here instead of maintaining a second list.

### Replace or stabilize

| JSON path | Redacted form |
| --- | --- |
| `Computer.Manufacturer`, `Model`, `SystemFamily`, `ProductVendor`, `ProductName`, `ProductVersion`, and their `*Display` mirrors | `[redacted]` |
| `Motherboard.Manufacturer`, `Product`, `Version`, and their `*Display` mirrors | `[redacted]` |
| `Firmware.Manufacturer`, `Version`, `ReleaseDate` | `[redacted]` |
| `MemoryModules[].Manufacturer`, `PartNumber` | `[redacted]` when non-empty; empty/null unchanged |
| `PhysicalDisks[].Model` | `Physical disk <DeviceNumber> (redacted model)` when non-empty; empty/null unchanged |
| `PhysicalDisks[].ProductRevision` | `[redacted]` when non-empty; empty/null unchanged |
| `Volumes[].Label` | `[redacted]` for user-specific values; common defaults such as Windows, Local Disk, System Reserved, New Volume and their localized forms remain; empty/null unchanged |
| `Volumes[].PhysicalDisk` | Matching placeholder when mapped and non-empty, `[redacted]` when non-empty but unmapped, otherwise empty/null unchanged |
| `Monitors[].Manufacturer`, `ProductCode` | `[redacted]` when non-empty; empty/null unchanged |
| `Monitors[].Model` | `Display <1-based index> (redacted model)` for real models; `Generic PnP Monitor`, `Generic Monitor`, `Default Monitor` and localized generic defaults remain; empty/null unchanged |
| `Battery.Manufacturer` | `[redacted]` when non-empty; empty/null unchanged |

An empty or null optional component value carries no identity to hide. Preserve
it rather than inventing a `[redacted]` indication. The primary
computer/motherboard identity fields continue to use `[redacted]` so the
redacted identity-quality state remains unambiguous.

### Preserve

- `CPU.Name` and `GPU[].Name`, including explicitly declared integrated and discrete GPU identities;
- CPU core/thread counts, memory capacity/speed/form factor/`Bank`, structural memory `Slot` locators such as `Controller0-ChannelA-DIMM1` or `DIMM_A1`, and other non-identifying capability fields;
- disk `DeviceNumber`, interface, media type, status, mapping, and volume role;
- volume drive letter, file system, `DiskNumber`, `PartitionNumber`, capacity, and free space;
- monitor `AdapterName`, current mode, HDR state, color-space fields, luminance, and other capability data;
- battery chemistry, capacities, health, cycle count, charge state, and power source.

### Invariants

1. Standard and redacted component objects expose the same keys, and component
   arrays retain the same length. Placeholders preserve disk/volume correlation.
2. `IdentityQuality.*.Status` is always `redacted` in redacted mode and its
   identity-quality issues are intentionally empty. Do not reconstruct a hidden
   model or treat this state as corruption.
3. Placeholder numbering uses disk `DeviceNumber`, volume `DiskNumber`, and
   1-based array order for monitor models. Memory `Slot` is structural evidence
   and must remain so dual-channel operation can be assessed from a redacted
   report.

Common operating-system display and volume placeholders carry no identifying
information and remain visible. OEM-specific monitor models, custom drive labels,
memory manufacturers, part numbers, and disk models remain redacted.

Collection warning arrays are diagnostic output, not component shape: the
redacted mode deliberately suppresses identity-quality warnings, so their
cardinality may differ from a standard snapshot. Warning text and codes must
still remain paired, ordered, and deduplicated within each snapshot.

Serial numbers are omitted in both modes. When reading JSON manually on Windows,
use an explicit UTF-8 decoder, for example
`[IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)`. JSON is intentionally
BOM-free; `Get-Content -Raw` may decode UTF-8 bytes with the legacy ANSI code
page on PowerShell 5.1.

When privacy-redacted mode is active, state that identifying device and component
codes were replaced. Preserve capabilities, capacities, mappings, statuses, and
explicitly declared CPU/GPU model names so the technical summary remains coherent.

State whether collection ran as a standard user process, a restricted agent
process, or an elevated user process. If broad access denial came from an agent
sandbox, recommend a normal non-elevated run outside the sandbox first. Only name
user-started elevation for fields that remain plausibly permission-dependent, such
as Storage Reliability counters. Do not describe elevation as a way to expose
missing telemetry sensors.

Never leave a requested hardware category as a blank heading. Never defer available memory or storage status to a follow-up question.
