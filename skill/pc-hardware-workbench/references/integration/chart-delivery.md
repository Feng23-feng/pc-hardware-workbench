# Chart delivery

Use this reference when a telemetry analysis should produce one or more SVG
figures. A chart is an evidence view, not a new measurement source and not a
stability or safety verdict.

## Two separate deliverables

Keep these outputs distinct:

- **evidence-only charts** contain measured curves, units, run boundaries,
  missing-data markers, and recorded extrema; they do not contain keep/revert,
  recommendation, or pass/fail language;
- **conclusion charts** summarize a decision after the objective, comparison
  context, and evidence are available. They reference the supporting curves and
  keep limitations visible.

When both are useful, produce the evidence pack first and derive the conclusion
from it. Do not repeat a verdict in every curve, and do not make the conclusion
chart the only copy of the underlying data.

## First CSV without an objective

For a timestamped HWiNFO-style CSV and no stated tuning goal, produce an
evidence pack and no conclusion:

1. telemetry overview with data window, sample count, warnings, run segments,
   and a small set of performance/context series, including memory clock when
   the source exposes it;
2. GPU clock-and-voltage timeline when effective/core clock and core voltage
   both exist;
3. GPU power and thermal timeline when power/temperature columns exist;
4. laptop CPU/GPU shared-budget timeline when CPU package power/temperature and
   GPU power/temperature exist.

The first-pass pack is normally two to four charts. Do not expand every
recognized metric unless the user asks for a full diagnostic export.

Generate it with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "<suite-folder>\scripts\render-telemetry-pack.ps1" `
  -Path "<telemetry.csv>" `
  -OutputDirectory "<new-pack-folder>" `
  -Preset FirstPass
```

`GpuTuning` and `CpuTuning` use the same command and change the required chart
families. The pack returns a manifest and never writes a conclusion.

## GPU tuning

Always start with the applicable evidence-only charts:

- tuning summary: baseline/candidate identity, fixed workload, repeat count,
  performance delta, frame delivery, and noise/variance, with memory clock
  immediately after the selected GPU core/effective clock;
- GPU clock-and-voltage timeline when both signals exist; do not split memory
  frequency into a standalone default chart;
- GPU power/thermal/limit evidence;
- GPU memory clock in the ordered overview and memory-junction evidence in the
  thermal chart;
- laptop shared CPU/GPU power and temperature evidence.

Add these only when the experiment needs them:

- frame-delivery timeline for gameplay, stutter, or frame-time claims;
- a deeper memory-only analysis when memory is the primary variable and the
  user explicitly requests it. Use a verified memory profile so the raw field
  and tool-equivalent display remain separate;
- stability/event evidence when WHEA, crashes, resets, artifacts, reboot, or a
  long validation run is available.

If core voltage is absent, do not invent a V/F figure. If limit flags are
absent, do not label a chart as proof of a specific limiting reason.

Render an explicitly requested deep memory view with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "<suite-folder>\scripts\render-memory-basis.ps1" `
  -Path "<telemetry.csv>" `
  -OutputPath "<new-memory-basis.svg>" `
  -ProfilePath "<suite-folder>\references\tuning\memory-clock-profiles.json" `
  -ProfileId "<verified-profile-id>" `
  -GpuIdentity "<exact GPU identity or profile alias>" `
  -RawToolIdentity "<exact raw-tool identity from the profile>" `
  -DisplayToolIdentity "<exact display-tool identity from the profile>"
```

This explicit deep view is not a default extra panel. In the default sequence,
memory clock stays immediately after the selected GPU core/effective clock.
Use `-AllowProvisional` only when the user explicitly accepts a provisional
profile; the output must remain visibly marked `provisional`. A missing or
mismatched GPU, raw tool, display tool, version, source field, or profile shape
fails closed and shows no derived equivalent value.

## CPU tuning

Use CPU summary and CPU core/power/thermal evidence as the base. On a laptop,
include shared GPU/CPU power and temperature. Add voltage-response evidence only
for a supported undervolt/curve experiment, gaming latency only when reliable
frame or PresentMon data exists, and stability evidence only when the required
event/test data exists.

Group P-core/E-core, CCD/core-complex, or representative cores instead of
plotting every thread by default. A per-core anomaly map is a diagnostic view,
not a normal conclusion chart.

## Visual rules

- Use a shared time axis for time-series evidence from the same run.
- Do not overlay frequency and voltage when the traces follow the same shape;
  use aligned lanes.
- Put numeric extrema and summary text outside the plotted data area. Inside the
  plot, use point markers only.
- Inset right-aligned `min / mean / max / samples` text from the panel edge;
  never let the final unit or letter touch the border.
- Preserve units, sample counts, window, missing values, and warnings.
- Mark a missing sensor as unavailable or omit its chart. Never estimate,
  interpolate, or fabricate a hidden sensor.
- Keep category mappings and colors stable across baseline and candidate views.
- Give the memory-clock series a stable distinct color, slightly heavier but
  secondary stroke, and sparse point markers so a flat line remains visible
  without outranking the core clock, power, or temperature signals.
- A potentially flat SVG series must not rely on an object-bounding filter
  region; use `filterUnits="userSpaceOnUse"` or no filter so a zero-height line
  is not clipped.

## Pack manifest and naming

Give pack files a stable order and descriptive names such as
`01-telemetry-overview.svg`, `02-gpu-vf-timeline.svg`,
`03-gpu-power-thermal.svg`, and `04-laptop-shared-budget.svg`. Record:

- preset and status (`complete` or `partial`);
- source file hash, window, and analyzed-row count;
- each chart's title, relative path, SHA-256, dimensions, and semantic role;
- skipped optional charts and their reasons.

Never label a partial pack as complete. Never overwrite an existing chart;
create a new output directory or fail closed.

## Conclusion renderer

When a conclusion is justified, provide the evidence pack in the conversation
or Task and generate the separate summary from a grounded JSON document:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "<suite-folder>\scripts\render-tuning-conclusion.ps1" `
  -InputPath "<conclusion.json>" `
  -OutputPath "<new-conclusion.svg>"
```

The input contains the title, verdict tone and label, context, performance or
other metrics, telemetry observations, up to three decisions, limitations,
sources, and an optional safety notice. Do not put unsupported claims into the
conclusion merely to fill the layout.
