# Usable-start candidates and resumable experiments

Use this reference for a normal user request such as “give me a practical
overclock”, “I want something I can use daily”, or “don't make me climb one
tiny step at a time”. The product goal is one bounded experiment that is useful
enough to keep if it passes, not the lowest possible number and not a claimed
hardware maximum.

## Tuning intent

Keep intent separate from performance goal:

- `usable-start`: default for a practical first-round candidate. If a candidate
  passes with a material benefit above noise and acceptable guards, stop and
  recommend `keep` for that tested context; this is not a daily-stability claim.
- `explore-limit`: continue one-variable exploration after a validated benefit.
  The user must explicitly ask to find the limit or continue tuning.

Do not expose these as top-level Skill modes. Infer `usable-start` from ordinary
requests and choose `explore-limit` only when the user asks to continue toward a
benchmark or stable maximum.

## Candidate roles

Every numeric or curve result identifies its role:

- `usable-start`: useful first-round candidate suitable for keeping only after
  the stated tests pass;
- `incremental`: a later one-variable addition after a validated result;
- `fallback`: the saved baseline to restore after failure or ambiguity;
- `limit-exploration`: a step that continues toward a boundary by explicit
  request.

The first core candidate is normally `usable-start`. A core pass does not by
itself justify testing memory. Record whether the core result produced a
material benefit above noise first.

## First-round authority

[gpu-auto-oc-tier-authority.json](gpu-auto-oc-tier-authority.json) is the only
normative table for first-round values, follow-up increments, internal
boundaries, and evidence labels. The candidate helper loads it directly.

`InitialStep` describes the current experiment. `FollowupStep` describes the
next incremental round; a first-round candidate must not copy its large initial
start into `FollowupStep`. The authority's `StartEvidenceClass`,
`StartConfidence`, `PublicSourceCount`, `ObservedMaxCoreOffsetMhz`, and
`StartToObservedMaxPercent` must travel with the candidate.

Generic and laptop reductions are encoded in the same authority or applied by
the helper's safety gates. They are not calibrated stable limits. Unknown
thermal evidence lowers the first desktop step to the authority's `CoreStep`.

## Result semantics

A boolean pass is insufficient. Evaluate the tested round with:

```text
ResultVerdict: pass | fail | inconclusive
MaterialBenefit: yes | no | unknown
NoiseExceeded: yes | no | unknown
EffectiveClockImproved: yes | no | unknown
ThermalAcceptable: yes | no | unknown
PowerAcceptable: yes | no | unknown
Artifacts: none | observed | unknown
```

Apply these decisions:

- reliability or a non-representative workload overrides every Pass field and
  prevents `keep`;
- `fail`, observed artifacts, unacceptable temperature, or unacceptable power:
  return `Revert` and the pre-generated fallback;
- `inconclusive`, unknown benefit, or unresolved noise: return `DiagnoseFirst`
  and ask to repeat the same workload without increasing the value;
- pass with no material benefit: return `DiagnoseFirst`; do not mark the value
  as optimized;
- pass with material benefit, noise separation, improved effective clock,
  acceptable thermal/power, and no artifacts: `keep` for `usable-start`;
- only `explore-limit` may continue after that accepted result.

Evaluate route-specific evidence:

- core: effective clock and target performance must improve above noise;
- memory: the memory-sensitive target result must improve without artifacts or
  correction-driven loss;
- power/efficiency: lower temperature, noise, power, or improved sustained
  behavior can be success without a higher effective clock;
- curve: a higher frequency at the same measured anchor or an efficiency gain
  at the same frequency can be success, depending on the goal.

Never infer a material benefit from a clean launch or a higher requested
offset. Expected performance magnitude remains `unknown` without calibrated
local history.

## Fallback

Every Ready candidate includes a `FallbackCandidate` object using the saved
baseline or the last accepted value and the exact displayed unit. On failure or
artifact:

1. restore the fallback;
2. preserve device, workload, thermal, tool, and experiment context;
3. do not ask the user to repeat completed gate questions;
4. do not offer a larger value until the baseline is stable again.

## State reuse

Laptop power-limit state is part of the fingerprint. Read
[laptop-power-state.md](laptop-power-state.md) before generating or reusing a
laptop candidate.

Power-limit percentages and watt fields are **ceiling settings**, not measured
power use. Keep measured draw in a separate `MeasuredPowerWatts` field.

Use stable IDs and preserve them across a conversation. The integrated workflow
does not write a persistent state store, so the default resume status must say
`session-only` rather than implying that a profile was loaded from disk:

```text
DeviceFingerprint
BaselineId
ExperimentId
ParentCandidateId
CandidateId
ReportFreshness
ResumeState
```

The fingerprint includes normalized GPU model, vendor, desktop/laptop form,
driver, tuning-tool version, VBIOS when available, and cooling summary.
`BaselineId` includes the fixed workload and baseline control values.
`ExperimentId` includes the baseline, selected route, tuning intent, goal,
dominant limit, thermal headroom, control kind, and curve anchor. `CandidateId`
identifies the concrete candidate value and can be supplied with
`ParentExperimentId`, `ParentCandidateValue`, and `ParentControlKind` to
validate a session-level resume. A mismatched or incomplete parent context is
rejected rather than treated as restored state.

Reuse a current report without asking again when the fingerprint and baseline
remain valid. Mark prior results stale after a GPU, driver, tuning-tool,
cooling, power-path, form-factor, or workload change. Do not silently migrate a
result to a new fingerprint.

Use three identity layers:

- `HardwareFingerprint`: GPU/board/vBIOS/driver/tool/cooling identity;
- `ConfigurationFingerprint`: hardware plus current power state and limits;
- `ExperimentLineageId`: a stable history key across configuration revisions.

A power-limit change creates a new `ExperimentId`/revision. It does not erase
the old baseline, candidate, or fallback. Those records are retained as
historical and marked stale for continuation. A default-profile fallback is
still a recovery option, but it is profile-only and may not restore an external
power-limit modification.

The workflow's honest resume states are:

- `session-only`: no validated parent candidate was supplied;
- `session-validated`: parent candidate context matched;
- `blocked`: the parent or current context could not be validated.

Do not call these states persistent until a separately authorized local
experiment store exists.

## Curve start

For an exposed voltage/frequency curve, do not fabricate an offset. Require the
measured steady-workload voltage and frequency anchor, then emit a
`curve-start` object:

- measured voltage anchor;
- current and candidate anchor frequency;
- points to flatten above the anchor;
- unchanged power limit for the first round;
- applied-curve verification;
- measured-anchor fallback.

The user manually edits the supported curve. Reopen the editor after editing to
record clamped or smoothed values. A curve start is not a direct MHz offset and
is not a daily-stable claim.

Laptop curve starts use at most +25 MHz for the first step and +75 MHz for the
internal reference boundary. Unknown thermal headroom also caps the first curve
step to +25 MHz.

## Must not claim

Every result keeps these limitations visible:

- final stable limit;
- calibrated FPS gain;
- daily-verified profile.

The candidate is an experiment plan only. Hardware writes remain `none` and
persistence remains user-controlled.
