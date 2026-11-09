# GPU automatic overclock candidates

Use this reference only inside the normal GPU tuning route. "Automatic" means
deterministically deriving a usable-start candidate and follow-up step from the
user's verified baseline and exposed controls. It does not mean reading the
machine without consent, applying a setting, enabling persistence, or claiming
that a candidate is universally safe.

The GPU must pass the five-item tuning entry gate in `SKILL.md` and
`intake.md`. Reliability failures, suspicious power-path evidence, missing
recovery, or a thermal restriction override every candidate in this file.

The helper also requires a named target component, one fixed workload, explicit
pass criteria, and one or more abort signals. The Skill should populate these
from the current device and existing measurement context before asking the user.
If one cannot be inferred, ask only for that one item. Missing content returns
`Blocked` with no numeric candidate.

When the user lacks hands-on experience or asks to be guided, read
[beginner-gpu-auto-oc.md](beginner-gpu-auto-oc.md). It changes how evidence is
collected and explained, not which candidates are allowed.

Read [gpu-family-playbooks.md](gpu-family-playbooks.md) for NVIDIA and AMD
generation-specific tendencies. The family prior selects the starting step and
risk emphasis; it never replaces local evidence.

For the default usable-start workflow, result evaluation, fallback, state IDs,
and curve-start semantics, read
[usable-start-and-state.md](usable-start-and-state.md).

For laptop candidates, also read
[laptop-power-state.md](laptop-power-state.md). Never substitute a displayed
power percentage for a board-specific watt limit.

The displayed power percentage is the power-limit ceiling, not actual power
draw. Keep `MeasuredPowerWatts` separate from ceiling values in every card.

## Authority and evidence precedence

[gpu-auto-oc-tier-authority.json](gpu-auto-oc-tier-authority.json) is the sole
normative source for automatic first-step, follow-up-step, boundary, and memory
ladder values. `suggest-gpu-overclock.ps1` loads that file directly.

`gpu-family-playbooks.md`, `usable-start-and-state.md`, and the RTX public
references explain how to interpret the authority values. They must not
maintain competing numeric tables. Public observations remain evidence for the
authority's `StartEvidenceClass`, source count, confidence, and evidence note;
they do not become candidate values by themselves. Local measurements decide
whether a generated candidate is kept or rejected.

## Choose the automatic variable

Use the current baseline's dominant limit, not the GPU model alone.

| Baseline evidence | First automatic round | Candidate rule |
| --- | --- | --- |
| Unexplained artifacts, resets, corruption, or instability | Stop | Return to the known-good profile and use triage. |
| GPU utilization is not representative or the workload is CPU/frame-cap limited | Diagnose first | Do not overclock until the target workload exercises the GPU and frame-cap/CPU effects are excluded. |
| Thermal headroom is tight or the dominant limit is thermal | Power/efficiency | Reduce an exposed power ceiling by one 5-point step; if no supported power control exists, stop and improve cooling or the supported vendor mode. |
| Dominant limit is power | Power/efficiency | Test a 5-point lower ceiling before adding a positive core offset. A clock offset may otherwise consume the same power budget with no sustained gain. |
| Dominant limit is voltage or has no usable limit interpretation | Diagnose first | Compare the same workload's clock, power, and performance behavior before proposing a numeric change. |
| Stable baseline, useful workload, no tight thermal limit, core not yet validated | Core offset | Use the exact tier entry from the authority file. |
| Core round passed; memory not yet validated | Memory | Use the memory entry from the authority file, with the core offset held fixed. |
| Core and memory ladders passed or reached their reference boundary | Stop | Validate daily behavior or move to a separate supported power experiment. Do not stack variables just to continue. |

When the user explicitly asks for efficiency, use the power route first. A
benchmark-only goal changes persistence and validation expectations, not the
one-variable safety order.

## Core authority

Read `CoreStartDesktop`, `CoreStep`, and `CoreBoundaryDesktop` from the matching
authority profile. `InitialStep` describes this round; `FollowupStep` describes
the next incremental core round. They are separate fields and must not be
inferred from each other.

If thermal evidence is `Unknown`, use the authority profile's `CoreStep` as the
first desktop step as well. If the user already has a positive offset, add one
step to that value and keep all other controls unchanged. The reference
boundary is a default stopping point for further automatic progression; it is
not evidence that the hardware is safe there.

Use this numeric ladder when the exact tool exposes a direct core **offset** or
an editable actual-clock target in megahertz. Tell the helper which control kind
it is. If the tool exposes a voltage/frequency curve or a coarser preset,
change one UI step or one coordinated curve segment as described in
`gpu-curve-baseline.md`; do not invent a conversion.

## Memory authority

Test memory only after the retained core candidate passes. Keep the validated
core offset fixed, then read `MemoryStartDesktop`, `MemoryStep`, and
`MemoryBoundaryDesktop` from the same authority profile.

The displayed unit is the tool's current offset unit. Never convert between
Afterburner-style values, transfer-rate labels, or vendor UI units. Use this
ladder only for an exposed offset control. If the platform exposes actual
memory clocks or timing modes instead, change one supported UI step and retain
the core profile. On a laptop, stop rather than escalating if memory heat,
shared power, artifacts, or performance loss appears.

## Power/efficiency round

When the baseline is thermal- or power-limited, a conservative first candidate
is the current exposed power ceiling minus five percentage points. Do not go
below 65% through this automatic ladder. Do not raise a power ceiling
automatically; the desktop raised-ceiling gate in `gpu-curve-baseline.md`
requires separate PSU, connector, cooling, and limit evidence.

If no supported power control is exposed, provide no substitute target. A
laptop should use only its supported vendor performance mode, not a hidden or
modified control. Lowering power can improve sustained clocks or noise, but it
can also reduce throughput; the same target workload decides.

## Generate and present the card

Use `scripts/suggest-gpu-overclock.ps1` when all of the following are known:

- a verified baseline, stable starting state, and saved recovery;
- vendor, readable model or family, desktop/laptop form factor, goal, dominant
  limit, and thermal headroom;
- MoDT may use the desktop-like candidate path only with its board, cooling,
  exposed power path, and platform limits recorded; `Other` blocks numeric
  candidates instead of silently becoming Desktop;
- whether the next control is actually exposed;
- whether a core/memory control is a direct offset, actual-clock target, curve,
  or mode;
- the current displayed value of that control;
- whether the core or memory round has passed.
- one exact active consumer GPU model; an empty or unrecognized model blocks the
  numeric candidate, and confirmation cannot replace the missing model.
- the target component, fixed workload, pass criteria, and abort signals.
- for a laptop, board model and power-limit state evidence; when no unlock is
  declared, use the correctable `assumed-stock` default.
- a fresh current report or session baseline. An omitted current control value
  is not treated as zero or 100%; the helper blocks until the displayed value is
  recorded.

Example:

```powershell
.\scripts\suggest-gpu-overclock.ps1 `
  -Vendor NVIDIA `
  -GpuModel "NVIDIA GeForce RTX 4070" `
  -FormFactor Desktop `
  -Goal Balanced `
  -DominantLimit None `
  -ThermalHeadroom Good `
  -CurrentCoreOffsetMhz 0 `
  -BaselineRecorded `
  -StableStartingState `
  -RecoverySaved `
  -TargetComponent "GPU" `
  -FixedWorkload "Recorded game benchmark, same scene and settings" `
  -PassCriteria "Repeated result exceeds baseline noise with no artifact or error" `
  -AbortSignals "Artifact, black screen, driver reset, or rapid thermal rise" `
  -ReportFreshness Fresh `
  -ExposedCoreOffset
```

The script returns JSON only and changes nothing. The serialized values come
from the authority file. If the status is `Blocked`, coach the first missing
item and do not show a candidate value. If it is `DiagnoseFirst` or `Stop`,
follow that decision. Translate a `Ready` result into the user's language and
adapt explanation depth without weakening its stop and recovery fields.

The candidate paragraph must include the localized safety notice from
`SKILL.md`. Substitute the generated `CandidateDisplayedValue` and preserve
`InitialStep` and `FollowupStep` without swapping their meanings.

Then give the complete experiment card:

- fixed workload and primary result;
- expected direction and measurement-noise limit;
- pass criteria and abort signals;
- saved rollback profile and how the user applies it;
- session-only first; reboot and normal-use validation are separate;
- exact sensor limitations.

Never call a first round daily-stable. On a pass with a material benefit above
noise and acceptable guards, recommend `keep` for the default usable-start
intent. Continue only when the result has no material benefit, is inconclusive,
or the user explicitly chooses `explore-limit`. On an artifact, reset, black
screen, corruption, unexpected clock collapse, rapid thermal rise, or
performance loss, revert to `FallbackCandidate`.

An official vendor auto-tuning scan may be used as another candidate source
only when the current supported vendor software exposes it. Record the values
it applies and validate them with the same baseline card. Its completion is not
proof of daily stability.

Always preserve the candidate's evidence fields:

- `EvidenceBasis`, `LocalEvidenceLevel`, and `FamilyPrior` explain what drove
  the candidate;
- `PriorSourceClass`, `PriorReviewedAt`, `PriorRuleVersion`, and
  `PriorUnitAssumption` identify the automatic ladder's provenance;
- `StartEvidenceClass`, `StartConfidence`, `PublicSourceCount`,
  `ObservedMaxCoreOffsetMhz`, and `StartToObservedMaxPercent` keep a tier
  start's evidence strength visible;
- `ResolvedGpuModel`, `AdapterIdentityStatus`, and
  `TargetComponentValidated` bind the experiment to one active GPU;
- `Confidence` cannot be `high` without repeated local or matched-board
  evidence;
- `ExpectedMagnitude` is `unknown` until calibrated real results exist;
- `ReferenceBoundaryMeaning` says the boundary is an internal stop, not a safe
  hardware maximum;
- `RequiredUserActions` lists only the action for this round;
- `EvidenceGaps` names what remains unknown.
- `TuningIntent`, `CandidateRole`, `StopWhenGoodEnough`, `FallbackCandidate`,
  and `SuggestedAction` express whether the result is a starting point,
  incremental step, fallback, or limit exploration.
- `InitialStep` is the change proposed in this round; `FollowupStep` is the
  smaller next-round increment.
- `DeviceFingerprint`, `BaselineId`, `ExperimentId`, `ParentCandidateId`,
  `ReportFreshness`, and `ResumeState` support state reuse without repeating
  completed questions. `CandidateId` identifies the concrete result; the
  integrated workflow otherwise reports `session-only` rather than pretending
  to have a persistent experiment store.

Use the user's current report, recent telemetry summary, and saved experiment
card to fill the gate automatically. Do not turn the fields into a novice
questionnaire.

Consumer classification is a positive gate. A recognized single consumer model
may continue. Empty, unresolved, or generation-unknown models receive no numeric
candidate. `-ConsumerGpuConfirmed` is compatibility metadata only; it cannot
replace an exact model and never overrides a known professional, data-center,
integrated, virtual, or multi-adapter product class.

Adapter text is normalized before counting. Treat ASCII and full-width
semicolons, commas, slashes, backslashes, ampersands, the word `and`,
parenthesized vendor names, pipes, newlines, the ideographic comma, and
space-delimited plus signs as possible adapter boundaries. Count explicit
models and generic integrated `Graphics` names within the same segment; do not
let an explicit discrete GPU hide a second adapter token.

Blocked results must report `EvidenceBasis: none`, `LocalEvidenceLevel: none`,
`Confidence: none`, no candidate object or displayed value, one current
`RequiredUserActions` item, and non-empty `EvidenceGaps`. This prevents a
missing or ambiguous baseline from being recorded later as accepted evidence.

For AMD Adrenalin, use `-CoreControlKind ClockTarget` or
`-MemoryControlKind ClockTarget` only when the current control really displays an
absolute clock. Supply the stock/default clock with `-BaselineCoreValueMhz` or
`-BaselineMemoryValueMhz`; the automatic boundary is then measured from that
baseline, not compared with an absolute clock value. Use `Offset` for an offset
control and `Mode` for a coarser preset. Do not translate an NVIDIA displayed
offset to an AMD actual clock or the reverse.

After testing, pass the observed result fields (`ResultVerdict`,
`MaterialBenefit`, `NoiseExceeded`, `EffectiveClockImproved`,
`ThermalAcceptable`, `PowerAcceptable`, and `Artifacts`) so the helper can
return keep, repeat, diagnose, or fallback instead of merely advancing to the
next number.

Reliability and utilization restrictions take precedence over all submitted
Pass fields. Power/efficiency success may be based on lower temperature, noise,
power, or better sustained behavior without requiring a higher effective clock.
Core success still requires a real effective-clock/performance benefit.
