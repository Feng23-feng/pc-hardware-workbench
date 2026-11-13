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
- a concrete task may exceed the current chat and needs a compact restart point;
- large evidence is about to be read and its important findings must survive;
- the user asks to save, export, resume, or audit the investigation.

Do not create a case for a quick concept question or a single-value answer that
needs no continuity.

Checkpoint at meaningful state changes: new evidence, a baseline, an experiment
start, an experiment result, recovery, a decision, or a new blocker. Do not copy
every chat turn into the case.

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

Choose a private local location outside the installed Skill and any public
repository. Do not commit `case.json` or `artifacts/`. State the chosen path once
so the user can reopen it later. If the location is unwritable, continue the
investigation and explicitly report that persistence was unavailable.

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
... -Action AddExperiment -BaselineId "B-001" -EvidenceIds "E-001","E-002" -Change "<one variable>" -Expected "<expected behavior>" -Result "<observed result>" -Outcome pending -Decision continue -PassCriteria "<pass>" -AbortCriteria "<abort>" -Recovery "<rollback>" -PersistenceStatus not-checked
... -Action UpdateExperiment -ExperimentId "X-001" -Result "<completed result>" -Outcome pass -Decision keep -EvidenceIds "E-003" -PersistenceStatus verified-active
... -Action SetNextAction -NextAction "<single next action>"
```

Read or validate:

```powershell
... -Action Show -AsJson
... -Action Resume
... -Action Validate
```

`Resume` prints a compact, redacted restart packet: device, goal, latest evidence,
open hypotheses, recent baselines and experiments, recovery, persistence, next
action, and the rule to revalidate current state. It omits external evidence
source paths. Use it when opening a new chat or after context compaction, then
read only the specific evidence needed for the next decision.

Export a static offline HTML report:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\export-hardware-case-html.ps1" -CasePath "<case-folder>\case.json" -OutputPath "<new-report>.html"
```

Artifact content is omitted by default. To embed bounded text previews and safe
PNG/JPEG/GIF/WebP/SVG images from imported artifacts:

```powershell
... -IncludeArtifacts
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
- New experiment metadata fields are optional so cases created by older versions
  remain valid. `Outcome` is `pending`, `pass`, `fail`, or `inconclusive`.
- A non-pending outcome requires a non-empty result; recording a verdict without
  the observed result is rejected.
- `PersistenceStatus` is `unknown`, `not-checked`, `verified-active`,
  `verified-after-reboot`, `not-active`, or `not-applicable`.
- Use `UpdateExperiment` to add a result later; do not create a duplicate
  experiment merely because the first record started as pending.
- `Validate` checks JSON structure, evidence-file presence, path containment,
  evidence SHA-256, and cross-references. It does not prove that the evidence
  interpretation is correct.
- The HTML exporter validates the case first. Its report has no scripts, remote
  styles, fonts, trackers, or network URLs. Safe SVG images are embedded only as
  image data; SVGs with active, linking, or external content are skipped.
- The HTML report does not expose an external evidence source path. It shows the
  original filename and metadata instead.
- The case may contain private paths and hardware details. Export only a
  separately reviewed, redacted summary.
- The case records state; it does not authorise hardware changes.
