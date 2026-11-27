# PC Hardware Workbench Phase 2 Anti-Overengineering Acceptance

Date: 2026-11-28
Scope: Runtime responsibility, natural completion, actual collection scope,
single-parse telemetry, and on-demand persistence
Baseline: `636f3e6` (`docs: simplify pchw interaction rules`)
Release status: Phase 2 implementation complete; Phase 3 not started

## Objective

Reduce Runtime decision-making, duplicate analysis, unnecessary collection, and
empty persistence while preserving physical safety, explicit permissions,
read-only boundaries, deterministic analysis, artifact integrity, the tuning
gate, and DSH non-panel capability.

The product principles used for this phase were:

- users should experience simplicity without losing functionality;
- the Agent should have freedom inside explicit constraints;
- Runtime should own structure, permissions, and integrity rather than every
  diagnostic decision;
- safety should be strict where risk requires it, not uniformly strict;
- the project should remain releasable instead of pursuing perfect
  architecture.

## Confirmed Behavior Changes

| Area | Before | After |
| --- | --- | --- |
| Runtime symptom handling | Display keywords could cause Runtime to append fixed retest recommendations and rewrite Agent advice. | Runtime preserves Agent-authored normal recommendations. A narrow physical-danger fallback can force `blocked`; an Agent-authored blocked/stop state suppresses routine recommendations, copy actions, and questions. |
| Completed panel results | `uncertainty`, recommendations, a priority action, and actions were mandatory, so the UI could invent work to satisfy schema. | These fields are optional. A completed result may omit recommendations, priorityAction, and actions while retaining real evidence gaps and uncertainty. |
| SkillDock fallback | The UI could fabricate a generic copy action. | Only Agent-authored actions are rendered for current schemas; legacy schemas retain their compatibility path. |
| CSV parsing in Broker | The analyzer parsed the CSV, then chart-pack generation parsed it again. | The analyzer produces `ChartData` during its authoritative pass. Broker consumes that result; its regression asserts exactly one analyzer invocation and no chart-pack downgrade. |
| CSV parsing in evidence package | The pipeline analyzed the CSV, then the normalizer invoked the analyzer again for `ChartData`. | `analysis.json` carries `ChartData`; the normalizer consumes it through `AnalysisPath` without reopening the CSV. |
| Hardware collection | A collector run always executed all hardware probes. | `-Sections` accepts `System,CPU,GPU,Memory,Storage,Display,Battery`. Omitted sections do not execute their probes. No `-Sections` value preserves the full-inventory default. |
| Agent inventory evidence | `pcwb.ps1 inventory` always emitted every default inventory field. | `-Sections` is passed through and the compact evidence/status contains only selected sections. |
| Shared evidence persistence | Runtime initialization created an empty evidence store. | Store initialization is in memory only; the first real evidence or attachment write creates the file. |

## Implementation Notes

Runtime:

- `enforceSafetyStateContract()` is the primary name.
- `enforceDisplayEvidenceContract` remains a compatibility alias.
- Historical and negated hazard text does not trigger a current stop.
- General symptom interpretation and diagnostic recommendation selection belong
  to the Agent.

Telemetry:

- `analyze-telemetry.ps1 -IncludeChartData` returns one authoritative summary
  plus chart data.
- PowerShell owns CSV parsing and candidate-column detection.
- `render-telemetry-chart.ps1` and `render-telemetry-pack.ps1` can consume
  analyzer-owned `ChartData`.
- Broker and evidence-package paths no longer invoke a second CSV analysis.

Collection:

- Section selection guards the corresponding WMI, Storage, display, battery,
  and `nvidia-smi` probes.
- Collector tests use an `nvidia-smi` sentinel to prove a CPU-only run does not
  execute the GPU probe and a GPU-selected run can reach it.
- The default full-inventory contract remains covered by the existing contract
  and live collector tests.

## Files Changed

Runtime and panel contract:

- `runtime.mjs`
- `schemas/ui-state.schema.json`
- `references/integration/interaction-closure.md`
- `references/integration/workbench-runtime.md`
- `tests/run-workbench-runtime-tests.mjs`

Telemetry:

- `telemetry-broker.mjs`
- `scripts/analyze-telemetry.ps1`
- `scripts/render-telemetry-chart.ps1`
- `scripts/render-telemetry-pack.ps1`
- `scripts/normalize-telemetry.ps1`
- `scripts/run-evidence-pipeline.ps1`
- `tests/run-telemetry-analysis-tests.ps1`
- `tests/run-telemetry-broker-tests.mjs`
- `tests/run-telemetry-normalization-tests.ps1`
- `tests/run-evidence-pipeline-tests.ps1`

Collection and CLI:

- `scripts/collect-windows.ps1`
- `scripts/pcwb.ps1`
- `scripts/pcwb-child-runner.ps1`
- `references/integration/collector-workflow.md`
- `references/integration/pcwb-cli.md`
- `tests/run-collector-smoke-tests.ps1`
- `tests/run-pcwb-cli-tests.ps1`
- `tests/run-contract-tests.ps1`
- `tests/run-interaction-contract-tests.ps1`

Persistence:

- `shared-evidence-store.mjs`

## Direct Measurements

| Metric | Result |
| --- | --- |
| Broker authoritative CSV analyses per normal chart run | Exactly 1 |
| Evidence-package analyzer passes per input | 1 |
| CPU-only collector `nvidia-smi` sentinel | Not executed |
| GPU-selected collector sentinel | Executed |
| Read-only Runtime evidence-store initialization | No directory or file created |
| `SKILL.md` size | 10,626 bytes, unchanged from Phase 1 |
| Quick-mode budget | 19,635 bytes |

No new metrics collection framework was added.

## Test Results

| Check | Status | Result |
| --- | --- | --- |
| Skill validator | PASS | `Skill is valid!` |
| Full Windows Skill suite | PASS | All automated tests passed; Redacted live collector included. |
| Collector section scope | PASS | Selected output, hidden output, and no GPU sentinel for CPU-only collection. |
| Telemetry analyzer/chart/pack | PASS | Analyzer-owned data path passed. |
| Telemetry Broker | PASS | One analyzer call, full chart pack, no downgrade warning. |
| Telemetry normalization | PASS | Preserves supplied `AnalysisPath` data and original CSV hash. |
| Evidence pipeline | PASS | Analysis JSON contains reusable `ChartData`; package generation passed. |
| PCWB CLI | PASS | Filtered inventory excludes unselected evidence and status fields. |
| Workbench Runtime | PASS | Natural completion, hazard stop, negation/history, and on-demand persistence passed. |
| Live LHM Web/WMI | SKIP | Requires an already-running LHM process and explicit live-read authorization. |
| SkillDock panel completion | PASS | Completed result with no recommendation/action accepted. |
| SkillDock smoke | PASS | Runtime no longer injects display recommendations; physical hazard still blocks. |
| PCHW source-hosted mock E2E | PASS | Current Thread and panel flow preserved. |
| SkillDock frozen verification | PASS | Frozen Node test gate passed. |

## Remaining Risks and Deferred Work

- Real Codex Thread end-to-end exercise, human interaction acceptance, and a
  clean Windows install/upgrade remain PENDING.
- Live LHM Web/WMI remains SKIP unless a running LHM environment is available.
- Schema migration, compatibility-state retirement, and experimental
  architecture governance remain Phase 3 work.
- Automated tests do not replace clean-machine validation or real user
  acceptance.

## Verdict

Phase 2 is complete within the approved scope. The Runtime has narrower
responsibility, common telemetry paths parse CSV once, collection can be scoped
at the probe level, completed answers no longer require invented actions, and
empty Runtime initialization no longer writes persistent state.

This result does not declare a stable release and does not start Phase 3.
