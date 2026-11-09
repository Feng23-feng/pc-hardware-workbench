# GPU family playbooks

Use this reference after identifying the vendor, exact enough model, desktop or
laptop form factor, exposed controls, and a stable local baseline. A family
prior narrows the next experiment; it never replaces local measurements. Do not
describe a public-range number or an automatic boundary as a safe maximum.

## Two layers

Keep these layers separate:

1. **Family prior:** architecture-specific tendencies, likely limiting factor,
   useful control order, and common failure signatures.
2. **Local automatic candidate:** the smaller one-variable step generated from
   the user's baseline by `gpu-auto-candidates.md` and
   `scripts/suggest-gpu-overclock.ps1`.

Public reports cluster around different values by generation, board, cooling,
firmware, driver, and tool unit. The broad ranges in this file are unverified
community priors without a maintained source, date, matched workload, or
normalized tool unit. They are not evidence, must not be used as a predicted
magnitude, and should not be presented as precise numbers in a short answer.
Only the narrower automatic ladder and the user's local measurements drive a
candidate.

## Evidence precedence

Prefer evidence in this order:

1. this device's repeated, same-workload, same-tool pass/fail history;
2. this device's current baseline and telemetry;
3. a verified matched model, board, cooling, firmware, and workload record;
4. a conservative same-vendor family prior;
5. a generic conservative rule.

The helper currently uses layers 2, 4, and 5; its `EvidenceBasis` field makes
that explicit. It must not imply layer 1 or 3 without the corresponding record.

## Prior provenance

Every automatic tier in the integrated candidate workflow carries:

```text
PriorSourceClass: internal-tiered-heuristic
PriorReviewedAt: 2026-11-10
PriorRuleVersion: 2.6.0
PriorUnitAssumption: displayed core MHz or clock target; displayed memory tool
                     unit; displayed power percent
```

These values are reviewed with the integrated candidate rules, not with a maintained
catalogue of matched hardware samples. Re-evaluate them when the control model,
architecture coverage, or available local evidence changes. Do not upgrade the
source class merely because many devices share a family name.

## Model-to-family recognition

Use these patterns only when the model text is readable and supplied by a
trusted local inventory or user evidence:

| Model text | Family |
| --- | --- |
| NVIDIA GeForce RTX 50xx | `NVIDIA-Blackwell` |
| NVIDIA GeForce RTX 40xx | `NVIDIA-Ada` |
| NVIDIA GeForce RTX 30xx | `NVIDIA-Ampere` |
| NVIDIA GeForce RTX 20xx / GTX 16xx | `NVIDIA-Turing` |
| NVIDIA GeForce GTX 10xx | `NVIDIA-Pascal` |
| AMD Radeon RX 9xxx | `AMD-RDNA4` |
| AMD Radeon RX 7xxx | `AMD-RDNA3` |
| AMD Radeon RX 6xxx | `AMD-RDNA2` |
| AMD Radeon RX 5xxx | `AMD-RDNA1` |
| Intel Arc B-series | `Intel-Battlemage` |
| Intel Arc A-series | `Intel-Alchemist` |

Workstation, mobile, rebadged, virtual, integrated, unknown, or conflicting
model strings need their exact exposed control evidence. Do not classify from a
single marketing name when the form factor or product class is unclear.
Professional, workstation, data-center, integrated, virtual, and
multi-adapter-concatenated model text is blocked from numeric candidate
generation. Generic is reserved for a single readable consumer-looking model
whose generation cannot be resolved, or for an empty/unreadable model only
after the user or collector confirms one active consumer GPU. Confirmation
cannot override a known non-consumer class.

Multi-adapter splitting covers both ASCII and Chinese punctuation commonly
pasted into hardware reports. Known variants such as `A10G` remain in the
data-center class even if the user confirms a consumer GPU by mistake.

## NVIDIA generation strategy

The observations below are qualitative exploration priors. Because their source
metadata is incomplete, no numeric public range from this workflow is treated
as validated evidence.

For the current RTX 50 tier reference and source links, read
[rtx-50-series-public-reference.md](rtx-50-series-public-reference.md).

For the current RTX 40 tier reference and source links, read
[rtx-40-series-public-reference.md](rtx-40-series-public-reference.md).

For the current RTX 30 tier reference and source links, read
[rtx-30-series-public-reference.md](rtx-30-series-public-reference.md).

| Family | Useful first tendency | Rough public exploration context | Main guard |
| --- | --- | --- | --- |
| NVIDIA Ampere / RTX 30 | Small core steps; memory may matter, but power and memory-junction heat often dominate. | Public observations suggest modest core headroom and significant memory variation; hot GDDR6X cards require lower memory expectations. | Power-limit behavior, transient load, GDDR6X memory-junction temperature, hotspot, and artifacts. |
| NVIDIA Ada / RTX 40 | Better efficiency makes power/curve tuning a strong option; core then memory remains a useful order. | Public observations generally discuss more headroom than Ampere, but exact UI units and board headroom vary too much to predict. | Power connector/path on high-end cards, hotspot, memory temperature, and bus errors visible as artifacts or performance loss. |
| NVIDIA Blackwell / RTX 50 | Do not assume a higher generation means more free headroom; validate driver/firmware and power-path behavior first. | Public reports vary widely and are not calibrated; the desktop RTX 5090 has a separate whole-curve/reduced-power reference route. | Connector/power-path review, sustained power, hotspot, driver behavior, and new-tool unit differences. |

Rough public ranges must never become a default candidate. For example, a
public RTX 30 core offset in the low hundreds of MHz does not make that value
appropriate for a power-limited RTX 3080 with hot GDDR6X memory. Conversely, a
well-cooled Ada card passing repeated target workloads can justify continuing
through a record rather than stopping at its first small step.

## AMD generation strategy

AMD Software: Adrenalin Edition commonly exposes clock ranges, voltage, power,
and memory controls rather than the same Afterburner-style offset fields used
for NVIDIA. Read the actual labels and units in the installed version:

- if the control is an **offset**, retain the displayed offset unit;
- if it is a **clock target or minimum/maximum range**, treat the current and
  candidate as actual clocks and do not call them offsets;
- if it is a **profile or mode**, change one supported profile step and do not
  infer its internal voltage or clock changes.

| Family | Useful first tendency | Rough public exploration context | Main guard |
| --- | --- | --- | --- |
| AMD RDNA2 / RX 6000 | Undervolt and efficiency tuning are often more useful than blindly adding voltage; memory-clock tuning can be meaningful. | Public observations suggest modest clock increases and undervolts can help, but this workflow has no normalized cross-model evidence. | Hotspot, memory stability, driver resets, and per-model firmware limits. |
| AMD RDNA3 / RX 7000 | Treat core clock range, power, and hotspot as a coordinated system; memory is a separate later round. | Public observations suggest larger clock targets may be tried than on RDNA2, but sustained hotspot/power and firmware limits decide. | Hotspot, board power, shared limits, artifacts, and profile persistence. |
| AMD RDNA4 / RX 9000 | Start conservatively because model-specific evidence and firmware behavior are newer; prefer vendor-supported per-game profiles. | The integrated workflow has insufficient normalized model-level data; use local baseline and supported official controls only. | Driver/firmware version, hotspot, power behavior, memory errors, and profile reset. |

For AMD, “stable” memory clock or offset is decided by artifacts, application
correctness, frame-time behavior, and repeated runs. A higher reported clock is
not proof of higher effective bandwidth.

## Automatic tier authority

[gpu-auto-oc-tier-authority.json](gpu-auto-oc-tier-authority.json) is the sole
normative source for automatic core and memory values. The helper loads that
file directly. This playbook explains family tendencies and evidence labels; it
does not maintain a second numeric ladder.

The helper's memory units are whatever the current control displays. Never
convert an offset to a transfer rate, compare an NVIDIA and AMD slider number
directly, or treat an absolute AMD clock target as an NVIDIA offset.

Every laptop override reduces the core boundary to +75 MHz and memory boundary
to +200 displayed tool units. Shared CPU/GPU power, temperature, and platform
firmware take precedence over architecture-specific desktop behavior.

## Family-specific progression

- RTX 30 / Ampere: after a core pass, check whether power or memory-junction
  temperature dominates before testing memory. Stop memory escalation when its
  temperature or correction behavior is unknown on a hot GDDR6X card.
- RTX 40 / Ada: compare a modest core result with a reduced-power or curve
  option. Keep the connector and power path in scope on high-end cards.
- RTX 50 / Blackwell: identify the exact desktop/laptop SKU before applying any
  general 50-series intuition. Use the RTX 5090 reference only for the exact
  desktop model and exact exposed controls.
- AMD RDNA2: record whether Adrenalin exposes minimum/maximum clocks, an
  offset, voltage offset, or a percentage profile. Do not translate controls
  from another vendor.
- AMD RDNA3/RDNA4: treat hotspot, power, and sustained clock as one review,
  then test memory separately. Prefer per-game profiles when available.

If the family is unknown, use the generic conservative path and say that the
candidate lacks generation-specific calibration.
