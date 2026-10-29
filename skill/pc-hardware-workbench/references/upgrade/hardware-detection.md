# Hardware detection

## Windows

Use `scripts/collect-windows.ps1` for a read-only inventory.

The collector loads native P/Invoke declarations once per process from:

- `scripts/system-native.cs` for processor, firmware, memory, and battery probes;
- `scripts/storage-native.cs` for storage devices and volume mapping;
- `scripts/display-native.cs` for DisplayConfig, DXGI, and active-monitor probes.

It also loads `scripts/device-identity.ps1` for identity-quality assessment and
safe display text, plus `scripts/local-path-safety.ps1` for local input/output
path enforcement, and `scripts/inventory-context.ps1` for access-denied,
restricted-process, and battery-state classification. Keep all six supporting
files beside `collect-windows.ps1`;
the Skill is incomplete if any one is copied alone. Markdown identity fields
are rendered as fenced inline code so embedded links, images, emphasis, and
HTML remain inert.

Markdown output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-folder>\scripts\collect-windows.ps1" -Format Markdown
```

JSON output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-folder>\scripts\collect-windows.ps1" -Format Json
```

Optional saved report:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-folder>\scripts\collect-windows.ps1" -Format Markdown -OutputPath "<existing-folder>\hardware.md"
```

The output path must be local and must not already exist. Network paths and
overwrite operations, symbolic links, junctions, and reparse-point paths are rejected.

Privacy-redacted output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-folder>\scripts\collect-windows.ps1" -Format Markdown -RedactIdentifiers
```

Tell the user before first use that standard output preserves exact device and component identifiers for precise compatibility analysis, while redacted output hides those identifiers and retains capability data. Ask which mode they want before invoking the collector.

The script:

- uses local Windows CIM/WMI, SMBIOS, and SetupAPI data only;
- makes no network requests;
- changes no settings;
- omits disk, BIOS, system, and monitor serial numbers;
- may list manufacturer model and part numbers, which can still be personal information;
- should be run only after telling the user what it collects and obtaining consent.

The snapshot's `IdentityQuality` classifies manufacturer, model, system-family,
and motherboard identity fields as `readable`, `suspicious`, `unreadable`,
`unknown`, `partial`, or `redacted`. It detects replacement, control, invisible,
and common mojibake sequences without auto-correcting a model. Standard JSON
retains source values as evidence; Markdown uses sanitized display fields.

The script and its instructions must remain least-privilege. The default run is
non-elevated. Do not self-elevate or launch UAC from the Skill. If broad access
denial occurs inside an agent sandbox, first provide the same read-only collector
command for a normal non-elevated PowerShell outside that sandbox. If a specific
field still needs administrator rights, such as Storage Reliability counters,
explain that expected benefit and provide a command for a PowerShell the user has
manually started as Administrator. `-RequireElevated` verifies that context but
never elevates the process. Permission denial remains an expected collection
limitation: record it, continue with readable fallbacks, and state the missing
fields explicitly.

Elevation does not expose temperatures, clocks, voltages, fan RPM, or other
sensors that the firmware, driver, or monitoring tool does not expose. Do not ask
for administrator rights merely to bypass a Codex sandbox or anti-cheat boundary.

With `-RedactIdentifiers`, mark `PrivacyMode` as `Redacted identifiers` and apply
the canonical field and shape contract in
[output-format.md](output-format.md#privacy-redacted-mode). That contract
distinguishes fields replaced by `[redacted]`, correlation-safe placeholders,
capability fields that must remain visible, and the intentional identity-quality
exception.

Codex or another sandbox may deny WMI/CIM or storage access. The script records collection warnings and falls back to readable Windows registry values, `nvidia-smi`, SMBIOS, and SetupAPI when available. SMBIOS supplies populated memory-module data even when CIM is denied. SetupAPI with `DIGCF_PRESENT` supplies currently active disk-device models without treating stale registry records or disconnected devices as present.

For NVIDIA adapters, retain the Windows-reported driver version and add the public NVIDIA driver version emitted by `nvidia-smi`, for example: `driver 32.0.16.2101 (NVIDIA 621.01)`. Match `nvidia-smi` rows to NVIDIA display adapters by device name; never attach the NVIDIA version to a virtual display adapter or unrelated GPU.

When `nvidia-smi` exposes them, also record a timestamped instantaneous sample of
GPU temperature, board power, graphics clock, utilization, fan percentage, and
power limit. This requires no elevation for the normal driver channel. Preserve
`[N/A]` as unavailable rather than zero. One sample is not a sustained workload
measurement and does not prove temperatures, clocks, or stability.

`Win32_VideoController.AdapterRAM` is not a dependable modern VRAM capacity field. Some drivers cap or truncate it. Keep the raw value in JSON only if clearly named `CimAdapterRAMBytes`, mark it unreliable, and display VRAM only when it comes from a trustworthy vendor source such as `nvidia-smi`.

The GPU section lists adapters currently exposed by CIM plus readable NVIDIA fallback data. It is not a complete installed-device inventory. If an expected integrated GPU, discrete GPU, or virtual adapter is absent, ask the user to run the read-only command `pnputil /enum-devices /class Display`. In that output, `Started` means active, `Disconnected` means installed or currently exposed by PnP but not active, and devices under `ROOT\DISPLAY` are often virtual display adapters. Do not count disconnected devices as active GPUs. Use `pnputil /enum-devices /class Display /drivers` when driver packages are relevant.

Windows 11 installations can retain `ProductName = Windows 10...` in the registry for compatibility. The collector normalizes the displayed family from the actual build number: build 22000 and later is reported as Windows 11. Preserve the display version, build, update revision, and kernel version separately so the result remains auditable.

The SetupAPI fallback is intentionally a present-device enumeration, not a registry inventory. It can report the active disk model but may still lack physical-disk size, bus mode, and health because those normally require Storage cmdlets, SMART, or elevated access. Report those fields as unavailable rather than borrowing them from an old registry entry.

`Win32_DiskDrive.InterfaceType` is a Windows-reported storage-stack value, not necessarily the physical connector. It can report `SCSI` for an NVMe SSD. Prefer `MSFT_PhysicalDisk.BusType` or the storage descriptor's normalized bus type when available, and retain the raw CIM value separately in JSON. Do not tell the user that a drive uses a physical SCSI cable solely because CIM reports `SCSI`.

The collector also uses read-only `IOCTL_STORAGE_GET_DEVICE_NUMBER` calls to map readable volumes to a present physical-disk number and partition number. It uses read-only storage descriptors to correlate disk numbers with active products. This normally works without elevation, but virtual storage, RAID, or access restrictions can prevent a mapping. Report any unmapped volume explicitly; never guess it from similar capacity or model names.

## Manual DDR5 and SPD evidence

The automatic collector can report module capacity, current configured speed, manufacturer, part number, and slot, but it normally cannot decode the installed DRAM die revision, rank, PMIC identity, memory-controller clock, or complete live timings. These details are relevant when evaluating memory compatibility, tuning headroom, stability, or whether a kit is running above its SPD rating.

When needed, ask for the HWiNFO **Memory Timings** view. Useful fields are:

- module manufacturer, part number, rank (`1R`/`2R`), and die revision when explicitly reported;
- current MCLK/UCLK, Gear mode, channel count, command rate, and primary timings;
- tRFC, tREFI, tFAW, and other active secondary timings;
- VDD, VDDQ, VPP, SPD Hub temperature, and PMIC warning flags;
- PMIC model and vendor when exposed.

Do not infer a die revision only from a module part number. A vendor convention can be strong supporting evidence, but mark it as inferred unless SPD or the memory vendor directly identifies it. Do not copy timings between different dies, capacities, ranks, or devices merely because the modules look similar. CPU-Z SPD screenshots may contain module serials; ask the user to crop or omit them.

For battery-equipped devices, `GetSystemPowerStatus` first establishes whether a
system battery exists, then `powercfg /batteryreport /xml` supplies design
capacity, full-charge capacity, chemistry, and the report's cycle count when
positive. Parse only the required fields, never emit the report's serial-number
fields, and delete the temporary XML report afterward. Preserve
`CollectionStatus.Battery` as `available`, `not-present`,
`unavailable-permission`, or `unavailable`; also preserve the specific
`BatteryStatusReason` and `BatteryCimStatus`. A permission failure is not evidence
that no battery exists. Do not infer laptop or desktop status from chassis type or
model naming; MoDT systems and unusual hardware can make that classification
misleading.

When CIM does not provide logical-processor topology, `GetLogicalProcessorInformation` supplies the physical-core count without elevation. Report physical cores and logical threads separately; identical values are valid for CPUs without simultaneous multithreading.

`GetFirmwareType` distinguishes Legacy BIOS from UEFI without elevation. On UEFI systems, read `HKLM\SYSTEM\CurrentControlSet\Control\SecureBoot\State\UEFISecureBootEnabled` for the Secure Boot state; do not call `Confirm-SecureBootUEFI`, which may require unavailable privileges. Use the registry BIOS release date when CIM is blocked. Keep `ReportedClockMHz` in JSON only and omit it from default Markdown to avoid implying a base or turbo limit.

When monitor EDID data is unavailable, `EnumDisplayDevices` can enumerate active adapters and monitors without elevation. `EnumDisplaySettingsEx` can then report the current Windows resolution, refresh rate, and framebuffer bits per pixel. Return only devices explicitly marked active, suppress virtual or inactive adapters, and label the result as PnP fallback data. The PnP identifier can support later model lookup but must not be presented as the confirmed retail monitor name. The current mode is not evidence of the monitor's native maximum and can change with scaling, VDI, or user configuration. Keep framebuffer bits per pixel separate from resolution/refresh and explain that 32 bits per pixel is not GPU rendering precision or Windows architecture.

`QueryDisplayConfig` and `DisplayConfigGetDeviceInfo` with the advanced-color information packet report HDR capability, whether the Windows advanced-color pipeline is enabled, whether wide color is enforced, the color encoding, and bits per color channel. `AdvancedColorEnabled` is not the HDR switch: it may reflect wide color or automatic color management. Determine the current HDR output state from `IDXGIOutput6::GetDesc1().ColorSpace`; HDR uses PQ/HLG color spaces or a linear G10 output. Report HDR as On, Supported but off, Not supported, or Unavailable; retain API results when queries fail rather than treating failure as unsupported. This output color space is also distinct from DEVMODE framebuffer bits per pixel.

The script also uses `GlobalMemoryStatusEx` for total/available system memory and `DriveInfo` for logical volume capacity/free space when WMI or Storage cmdlets are denied. The Markdown report always emits an explicit unavailable line for failed CPU, GPU, memory-module, physical-disk, volume, and monitor sections instead of leaving them blank.

The raw CPU clock value is labeled as a reported clock, not a maximum turbo frequency. Markdown collapses repeated CIM-denial warnings into a short summary while JSON retains the per-class diagnostics.

JSON snapshots include `SchemaVersion` and `CollectorVersion` at the top level. Increment the schema version when existing field meanings or types change incompatibly, not for every additive field.

It can usually identify:

- computer manufacturer/model;
- CPU physical-core and logical-thread counts;
- GPU names, driver versions, and current adapter modes;
- memory module capacity, configured speed, manufacturer, and part number when exposed by CIM or SMBIOS;
- active disk models, volume-to-disk mappings, and any capacity, interface, and health fields available through CIM, SetupAPI, storage descriptors, or Storage cmdlets;
- motherboard and BIOS version;
- logical volume capacity and free space;
- monitor manufacturer/model through EDID, or active PnP identifiers through the fallback;
- operating system and battery information.

It cannot reliably identify:

- exact PSU model, cable types, connector count, or age;
- case, cooler, fans, airflow, and physical clearance;
- DDR5 die revision, module rank, PMIC model, or live memory timing/voltage state;
- display adapters that are installed but currently disconnected or disabled;
- which port and cable drive each monitor;
- negotiated DSC and VRR, plus full chroma and color-management details beyond the current DXGI output color space;
- purchase prices, invoices, warranty, and resale value;
- CPU, GPU, VRAM, RAM, or storage utilization under the user's workload;
- user priorities, acceptable noise/heat, and budget.

If WMI data is incomplete or the user is on another operating system, use the manual intake form. Do not infer missing hardware from the model family.
