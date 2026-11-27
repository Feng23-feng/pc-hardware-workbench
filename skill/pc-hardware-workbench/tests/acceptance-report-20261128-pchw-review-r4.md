# PC Hardware Workbench External Review R4 Fixes

Date: 2026-11-28

Scope: targeted fixes from the Phase 2 external integration review

Release status: source-level review fixes only; stable release not declared

## Findings Addressed

### 1. Mixed physical hazards

Runtime now evaluates each hazard occurrence independently. Negating one hazard
does not suppress another current hazard in the same sentence. The regression
`没有焦味且有火花` returns `blocked`.

The change does not add a broad external keyword catalogue. It narrows negation
and resolution checks to the local hazard occurrence and separates contrast
clauses.

### 2. Ordinary blocked states

Runtime no longer treats every `blocked` result as physical danger. Missing
permission, missing evidence, or a tuning gate keeps the Agent-authored block,
priority action, recommendations, and copy actions unchanged.

### 3. Canonical physical stop

Once a current physical hazard is confirmed, Runtime replaces the action with
one fixed, verified stop action. It does not reuse an Agent title/detail pair
that might contain contradictory instructions such as “continue powered
retesting”.

Ordinary non-physical titles such as “停止运行后台下载” do not trigger a physical
safety stop.

### 4. AnalysisPath and ChartData provenance

`analyze-telemetry.ps1` now binds the exact bytes it read to:

- `SourceSha256`;
- `SourceBytes`;
- the top-level JSON result;
- nested or direct `ChartData`.

`normalize-telemetry.ps1 -AnalysisPath` rejects:

- analysis from another CSV;
- missing source binding;
- internally inconsistent top-level/ChartData binding.

`render-telemetry-pack.ps1 -ChartDataPath` rejects ChartData whose source hash
or byte count differs from `-Path`.

### 5. Consistent chart-pack window

If `ChartDataPath` is not supplied, the pack runs the analyzer once, writes one
transient source-bound ChartData file, and sends that same file to every
renderer. It does not pass the CSV to separate renderers with partially copied
window settings.

The transient file is removed on success and failure, never enters the manifest,
and the source binding is checked again after rendering. Supplying both
`ChartDataPath` and new window parameters is rejected.

### 6. Analyzer pass accounting

Broker analysis records:

- `analyzer_passes: 1` and `analyzer_pass_reason: standard` for the normal path;
- `analyzer_passes: 2` and `analyzer_pass_reason: candidate_column_retry` for the
  narrow explicit-column fallback.

The fallback also adds a warning. The normal path remains single-pass; the
exceptional path is not hidden to improve a metric.

### 7. Chart generation scope

`chart_preset` is optional:

- omitted or `null`: analyzer summary only; no chart-pack renderer and no artifact;
- explicit `FirstPass`, `GpuTuning`, or `CpuTuning`: existing chart-pack path.

SkillDock's interactive chart action explicitly sends `FirstPass`. No new mode,
configuration system, or schema migration was added.

## Test Results

| Check | Status |
| --- | --- |
| Workbench Runtime contract | PASS |
| Telemetry Broker chart-pack regression | PASS |
| Telemetry analyzer regression | PASS |
| Telemetry chart regression | PASS |
| Telemetry pack regression | PASS |
| Telemetry normalization regression | PASS |
| Evidence pipeline tests | PASS |
| PCWB CLI tests | PASS |
| Full Windows Skill suite with Redacted live collector | PASS |
| SkillDock panel completion | PASS |
| SkillDock smoke | PASS |
| SkillDock frozen verification | PASS |
| PCHW source-hosted mock external-agent E2E | PASS |
| Live LHM Web/WMI | SKIP |

## Residual Risk

The existing source hash/analyzer/render checks reject persistent file
replacement. A rapid replace-and-restore race still requires OS-level sandboxing
or process-shared handles and is not claimed as solved.

Direct `render-telemetry-chart.ps1 -InputFormat ChartData` has no source CSV path
and therefore cannot perform cross-file provenance verification by itself.
Protected reuse through normalizer and chart pack does verify the binding.

## Pending Acceptance

- Real Codex Thread launch, permission, recovery, result sync, and current-Thread
  behavior.
- Human interaction acceptance.
- Clean Windows install, upgrade, repair, and uninstall.
- Reviewed package identity, rebuilt release, and real Edge checks on those exact
  bytes.

## Verdict

The confirmed review findings are covered by failing-first regressions and
current Windows test passes. This report does not establish a stable release and
does not start Phase 3.
