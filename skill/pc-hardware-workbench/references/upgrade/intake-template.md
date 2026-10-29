# Upgrade intake template

Use the shortest version that can answer the current question. Do not force the user to complete every field.

## Ask first

Determine the mode before collecting:

- **Inventory only:** present the complete local hardware snapshot and stop.
- **Upgrade advice:** collect the snapshot, then ask about the target workload and constraints.

If the user's intent is ambiguous, ask:

> 你只是想读取这台电脑的当前配置，还是要基于它判断是否升级？

Before the first collection, explain both output modes:

- **Standard:** use for the user's own machine, trusted local troubleshooting, exact compatibility/recall/warranty checks, or resale valuation. It keeps exact model and part identifiers.
- **Privacy-redacted:** use for public posts, group chats, screenshots, or reports sent to strangers. It retains capabilities but lowers model-specific compatibility, recall, warranty, and resale precision. CPU/GPU names remain visible and can still fingerprint the machine. Exact fields and invariants are defined in [output-format.md](output-format.md#privacy-redacted-mode).

Only after that explanation, ask them to choose standard or privacy-redacted output.

## Automatic collection

On Windows, offer the read-only collector from the skill:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-folder>\scripts\collect-windows.ps1" -Format Markdown
```

For privacy-redacted collection:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill-folder>\scripts\collect-windows.ps1" -Format Markdown -RedactIdentifiers
```

Use its output to prefill CPU, GPU, memory, storage, motherboard, BIOS, operating system, and available monitor EDID data. Ask the user before running it. Do not collect serial numbers by default.

If CIM or Storage cmdlets are denied, use the built-in SMBIOS memory fallback and SetupAPI active-disk fallback. Do not scan stale registry device lists for disk models; report only present devices and mark missing size, interface, or health as unavailable.

In the initial response, report every section in one pass. Empty sections must become explicit unavailable messages, not blank headings. For example:

- "内存条明细当前环境不可读取；系统总内存为 32GB。"
- "物理硬盘型号和健康状态不可读取；逻辑卷容量如下。"

## Minimum intake

```markdown
What I currently use:
- Desktop/laptop model:
- CPU:
- GPU:
- Memory:
- Storage:
- Display:
- PSU or power adapter:
- Main workload:
- Resolution/settings:
- What feels inadequate:
- Buying new/used:
- Willing to sell the current part:
- Hard budget:
```

## Optional precision details

```markdown
Optional information that improves accuracy:
- Exact model code/SKU:
- Regional or retailer variant:
- Broad market region and currency:
- Warranty status:
```

Explain once:

- exact SKU improves compatibility, recall, warranty, and model-variant checks;
- market region improves price interpretation;
- none of these are mandatory;
- an approximate component category is enough to begin;
- if these fields are deliberately withheld or unknown, recommendations continue with lower confidence;
- corrupted replacement text, mojibake, placeholders, or conflicting identities are `unreadable`, not merely low-confidence values; follow [device-identity.md](../integration/device-identity.md) and do not claim exact compatibility;
- never ask for a serial number, exact address, password, API key, or account login.

## Optional purchase history

```markdown
Original purchase information (optional):
- Component:
- Purchase date:
- Purchase price:
- Warranty remaining:
- Current condition:
```

Explain:

- purchase price is not current market value;
- the skill will not use sunk cost as a reason to spend more;
- a price is useful only for historical comparison or depreciation discussion.

## Desktop hardware card

- CPU and cooler:
- Motherboard and BIOS version:
- GPU and driver:
- Memory capacity, speed, and configuration:
- Storage models and health:
- PSU model, wattage, and age:
- Case and cooling layout:
- Displays and cables:

## Laptop hardware card

- Exact model:
- CPU:
- GPU and VRAM:
- Memory:
- Storage:
- Display:
- Power adapter:
- Cooling setup:
- Current power or performance mode:

## Optional memory diagnostics

Use HWiNFO's Memory Timings view only when memory compatibility or tuning matters:

- module manufacturer, part number, die revision, and rank:
- current MCLK/UCLK and Gear mode:
- primary timings, tRFC, tREFI, and tFAW:
- VDD, VDDQ, VPP, SPD Hub temperatures, and PMIC warnings:
- PMIC model/vendor:

Do not require every field. If software does not expose the die or PMIC, leave it unknown. Crop module serial numbers before sharing screenshots.

## Optional installed display adapters

The report's GPU section lists active adapters. To inspect all display devices and installed drivers without elevation, the user may run:

```powershell
pnputil /enum-devices /class Display
pnputil /enum-devices /class Display /drivers
```

Treat `Disconnected` as not active and identify virtual adapters separately. These commands may show the integrated GPU even when the active-GPU inventory does not.

## Goal

Ask the user to rank:

- higher FPS;
- higher resolution;
- better minimum FPS;
- shorter render or compile times;
- more VRAM or memory capacity;
- lower noise or temperature;
- better portability;
- reliability;
- aesthetics or collection value.

## Existing evidence

Useful evidence includes:

- CPU and GPU utilization;
- VRAM or RAM usage;
- temperatures and throttling;
- frame time or 1% low data;
- render/export/compile times;
- storage SMART and free space;
- current BIOS or software limits;
- the exact workload and settings.
