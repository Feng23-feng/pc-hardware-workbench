# Hardware case continuity

Use a local hardware case when a task spans multiple turns, combines several
evidence sources, or must be resumed without relying on chat memory.

The case is private local state. Do not upload it, commit it to a shared Skill,
or include raw case files in a public report without reviewing and redacting the
device and user fields.

## When to create one

Create a case when at least one of these is true:

- the user expects to continue the investigation later;
- the task combines inventory, telemetry, screenshots, hypotheses, and tests;
- a baseline or change must be compared with later evidence;
- the user asks to save, export, resume, or audit the investigation.

Do not create a case for a quick concept question or a single-value answer that
needs no continuity.

## Storage

```text
case-folder/
  case.json
  artifacts/
    <timestamp>-<evidence-file>
```

`case.json` is the source of truth. `artifacts/` contains only files that the
user explicitly chose to import. For an imported file, the case keeps the
original filename, capture time, relative imported path, and SHA-256; it does not
retain the private source path. For an external reference, the source path and
SHA-256 are recorded instead.

## Commands

Create:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\hardware-case.ps1" -Action New -CasePath "<private-case-folder>" -DeviceAlias "<alias>" -Platform "<platform>" -Goal "<goal>"
```

Add evidence and optionally copy it into the case:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\hardware-case.ps1" -Action AddEvidence -CasePath "<private-case-folder>\case.json" -EvidenceType telemetry -EvidencePath "<telemetry.csv>" -EvidenceCapturedAt "2026-11-03T12:30:00+08:00" -Summary "<what this file proves>" -ImportArtifact
```

Add and update a hypothesis:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\hardware-case.ps1" -Action AddHypothesis -CasePath "<case-folder>" -Hypothesis "<candidate explanation>" -NextTest "<discriminating test>"
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\hardware-case.ps1" -Action UpdateHypothesis -CasePath "<case-folder>" -HypothesisId "H-001" -Status supported -Supporting "<new evidence>"
```

Record timeline, baseline, experiment, and next action:

```powershell
... -Action AddTimeline -EventType driver -OccurredAt "2026-11-03T12:30:00+08:00" -Summary "<event>"
... -Action AddBaseline -BaselineStatus valid -Workload "<fixed workload>" -Conditions "<driver, power mode, cooling>" -EvidenceId "E-001" -Summary "<baseline metrics>"
... -Action AddExperiment -Change "<one variable>" -Expected "<expected behavior>" -Result "<result>" -Decision "<keep/revert/continue/stop>"
... -Action SetNextAction -NextAction "<single next action>"
```

Read or validate:

```powershell
... -Action Show -AsJson
... -Action Validate
```

## Rules

- Hypothesis statuses are `verified`, `supported`, `pending`, `contradicted`, and `unknown`.
- Never convert `supported` into `verified` without direct evidence.
- Timeline order is not causation. State correlation and missing evidence separately.
- A baseline records its workload, conditions, evidence ID, and date. Do not reuse
  it after a material hardware, firmware, driver, power-limit, or workload change
  as if it were still directly comparable.
- Use `-BaselineStatus valid|provisional|none`. A valid baseline requires
  evidence; use `none` when the evidence only shows mixed or unusable phases.
- Preserve history when a state changes. Mark old baselines as historical rather
  than deleting or rewriting them.
- `Validate` checks JSON structure, evidence-file presence, path containment,
  evidence SHA-256, and cross-references. It does not prove that the evidence
  interpretation is correct.
- The case may contain private paths and hardware details. Export only a
  separately reviewed, redacted summary.
- The case records state; it does not authorise hardware changes.
