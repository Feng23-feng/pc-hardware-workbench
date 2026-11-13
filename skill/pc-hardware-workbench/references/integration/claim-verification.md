# Claim verification

Use this flow when a user supplies a current hardware value, configuration, or
applied-setting claim that could change a safety or tuning decision.

The goal is not to judge the user's honesty. Classify what the evidence can
support:

| Source type | Meaning | Permitted use |
| --- | --- | --- |
| `measured-current` | A current local read produced the value | Current observation with its documented limits |
| `user-confirmed-current` | The user explicitly states they just checked the value and it is current | Current user-reported evidence; not independently verified |
| `historical` | The value comes from an earlier report, profile, or chat | Historical context only until current state is established |
| `user-estimate` | The user is recalling or approximating the value | Planning context only; not a gate input |

## Promotion rule

A value introduced as a record, previous value, profile, or earlier result is
`historical` before any other classification. A user instruction to "use it as
current" or "do not ask" does not promote it. Ask exactly one confirmation:
whether the user just checked the value and whether it changed afterward.

Only an explicit confirmation may change the source type to
`user-confirmed-current`. Never call that value `measured-current` unless a
current local read supplied it.

## Workflow

1. Extract the claim fields: device, field, value, unit, claimed time, and source type.
2. If the wording is ambiguous, ask one question: whether the user just confirmed
   the value and whether it changed afterward.
3. If local collection is available and the user consents, read only the evidence
   needed to compare the claims. Do not launch monitoring software, request
   elevation, install tools, or write hardware settings.
4. Compare claims against a current normalized evidence object with
   `scripts/verify-hardware-claim.ps1`.
5. Report `matched-current`, `conflict`, `user-confirmed-current`, `historical`,
   `user-estimate`, or `unverified` for each field.
6. If a claim conflicts with current evidence, show both values and their sources.
   Do not silently choose one.

## What can be verified locally

| Claim | Useful local evidence | Limit |
| --- | --- | --- |
| Device model and OS | Current collector snapshot | Identity quality and permissions still matter |
| CPU model and topology | Current collector snapshot | Reported clock is not sustained performance |
| GPU identity and reported memory | Current collector plus supported vendor query | Reported capacity may differ from precise VRAM claims |
| NVIDIA current/effective power limit | `nvidia-smi` fields exposed by the collector | Requested, enforced, default, and maximum limits are distinct |
| Memory configured speed and module fields | Current collector snapshot | SPD/XMP/EXPO profile activation may not be directly exposed |
| Battery and storage health | Current collector snapshot | Permission and provider limits remain explicit |
| Application GPU offset or fan curve | Usually unavailable through standard Windows APIs | Require a vendor export, screenshot, or user-confirmed report |
| BIOS/UEFI setting | Usually unavailable outside vendor interfaces | A photo shows the visible page, not necessarily the saved state |
| Stability | Requires a fixed workload, repeatable run, and time-series evidence | A single current read or screenshot cannot prove it |

## Evidence object

The comparator accepts a JSON evidence object with dot-separated field paths.
Examples:

```json
{
  "GPU": [
    {
      "Name": "Example GPU",
      "NvidiaEffectivePowerLimitW": 480,
      "NvidiaPowerLimitW": 480
    }
  ],
  "MemoryModules": [
    {
      "ConfiguredSpeedMTs": 6000
    }
  ]
}
```

Example claims:

```json
{
  "schemaVersion": 1,
  "claims": [
    {
      "id": "gpu-power-limit",
      "path": "GPU.0.NvidiaEffectivePowerLimitW",
      "expected": 480,
      "unit": "W",
      "tolerance": 1,
      "sourceType": "user-confirmed-current"
    }
  ]
}
```

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\verify-hardware-claim.ps1 `
  -ClaimPath .\claim.json `
  -EvidencePath .\inventory.json `
  -OutputFormat Markdown
```

The comparator never acquires evidence itself. It is safe to run on a saved,
redacted snapshot without touching the live machine.

## Reporting

Lead with the verification result. Separate:

- user report;
- current observation;
- conflict or missing evidence;
- what remains usable;
- one next action.

Do not punish the user for an unreadable vendor-only field. Do not upgrade a
user-confirmed value to `measured-current`. Do not reuse a prior conversation's
value after a material driver, firmware, hardware, or profile change.
