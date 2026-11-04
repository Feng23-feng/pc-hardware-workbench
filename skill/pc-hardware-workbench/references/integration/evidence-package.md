# One-command telemetry evidence package

Use `scripts/run-evidence-pipeline.ps1` when the user has one or two compatible
telemetry CSV files and wants the routine sequence completed without manually
calling the normalizer, analyzer, chart renderer, and result-card steps.

The first version accepts HWiNFO, PresentMon, and compatible text CSV files. It
does not turn a screenshot into a time series and does not claim that a short
run proves long-term stability.

## Baseline only

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "<skill>\scripts\run-evidence-pipeline.ps1" `
  -BaselinePath "<baseline.csv>" `
  -OutputDirectory "<evidence-root>" `
  -Workload "<fixed workload>"
```

## Baseline and candidate

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "<skill>\scripts\run-evidence-pipeline.ps1" `
  -BaselinePath "<baseline.csv>" `
  -CandidatePath "<candidate.csv>" `
  -OutputDirectory "<evidence-root>" `
  -Workload "<same fixed workload>" `
  -Change "<one declared change>" `
  -FocusMetric "GPU temperature"
```

A candidate comparison requires a declared workload. The script checks:

- both inputs are local regular files;
- the selected analysis windows are the same;
- sampling intervals are present and materially comparable;
- metrics match by both name and unit.

Device identity, active settings, and actual workload are not inferable from the
CSV alone. Confirm them before treating the comparison as valid.

## Output

Each invocation creates a separate `evidence-<timestamp>-<id>` folder:

```text
baseline.analysis.json
baseline.normalized.json
baseline.chart.svg
candidate.analysis.json
candidate.normalized.json
candidate.chart.svg
evidence-card.html
summary.md
evidence-package.json
```

The HTML card is self-contained, has no scripts or remote resources, embeds both
SVG charts, and records the input hashes, metric deltas, warnings, and next
action. The package JSON is the machine-readable source for later model review.

## Status values

- `baseline-ready`: a baseline exists and a matching candidate is still needed.
- `ready-for-review`: common metrics and compatible sampling were found.
- `review`: a comparison exists but warnings require human or model review.
- `retest`: no common metric pair exists, so differences would be misleading.

`ready-for-review` does not mean PASS. Apply the user's fixed-workload, pass,
abort, persistence, and recovery criteria before choosing keep, continue, revert,
or stop.

## Treatment of values

- Temperature comparisons use absolute changes, not percentages relative to
  Celsius.
- P95 and maximum deltas remain visible because mean-only comparisons can hide
  stutter or thermal spikes.
- Missing and extra metrics are warnings, not silently ignored.
- Original filenames can be hidden with `-HideFileName`; full source paths are
  not written into the card or package.

## Privacy

The package is local evidence. It can still contain device details through
sensor names and metric values. Review it before sharing. Do not upload raw CSVs,
the package, or the chart without checking filenames and identifying metadata.
