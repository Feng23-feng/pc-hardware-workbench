# Fixed workloads and one-screen experiment card

A fixed workload makes before/after comparisons meaningful. Define it once for the user's goal, then reuse it for the stock and candidate rounds.

## Required fixed conditions

Record only conditions relevant to the workload:

- exact application/game and version or build;
- GPU driver and tuning-tool version;
- profile name and stock/candidate state;
- resolution, refresh rate, window mode, and frame cap;
- graphics preset, ray tracing, upscaling, frame generation, and synchronization settings;
- fan mode, Windows power mode, AC/battery state, ambient conditions, and relevant background applications;
- cooling baseline: desktop cooler/airflow answer, or laptop model and official power-envelope reference;
- for formal noise comparison: SPL/device, microphone distance and position, background noise, ambient temperature, duration, and repeated samples;
- warm-up, start point, route or operation, and measurement window.

Do not change an unrelated test condition between baseline and candidate. If it must change, mark the comparison as inconclusive and repeat the baseline.

## Template 1: game or interactive workload

```text
Workload ID:
Game and build:
Store/launcher:
Resolution and refresh:
Window/fullscreen:
Graphics preset:
RT/upscaling/frame generation:
V-Sync/VRR/frame cap:
Fan/power mode:
Cooling baseline:
Official/measured power envelope:
Noise measurement:
AC/battery and ambient:
Relevant background apps:
Warm-up:
Start point and route:
Sample duration:
Primary metric:
Guard metrics:
Known failure signs:
```

Use a save point, replay, fixed route, benchmark scene, or training mode that the user can reproduce. Record frame time or minimum/percentile FPS when available.

## Template 2: synthetic benchmark

```text
Benchmark name and exact version:
Preset/resolution:
Run count:
Score:
Minimum/average FPS or frame time:
GPU/CPU behavior:
Temperatures/power/clocks:
Errors or artifacts:
```

A synthetic result is evidence for that benchmark, not proof of general application or daily stability.

## Template 3: rendering or production workload

```text
Application and version:
Project or representative sample:
Render/export/compile settings:
Caches or shader state:
Input/export duration:
Warm-up:
Measured wall time or throughput:
Power/temperature/clocks:
Errors or correctness check:
```

Use a non-sensitive sample when the record will be shared.

## Template 4: stability check

```text
Tool and version:
Test mode/resolution:
Duration:
Pass criteria:
Artifacts/errors:
Maximum temperature/power/clock behavior:
Recovery observed:
```

The stress check supports one round. It does not replace the target workload, reboot, sleep/wake, or normal-use validation.

## One-screen experiment card

Use this before the user applies a candidate. Present the required information
as compact prose by default. When the user asks for a plan, card, or comparison,
a compact table, card, or fenced block is valid content.

```text
Route: GPU / CPU / memory
Goal:
Stable baseline:
Cooling/power evidence:
Explanation (depth adapted to the user and risk):
  What changes / stays fixed:
  Practical tradeoff / analogy when useful:
  Stop / recovery:
One variable:
Before -> candidate (same paragraph): <localized safety notice from SKILL.md>
Expected improvement:
Pass criteria:
Abort signals:
Rollback:
Required persistence: session-only / reboot-verified / daily-verified
Sensor limitations:
Noise measurement limitations:
Decision after test: keep / continue / revert / stop
```

For quick mode, fill the smallest useful set. For deep mode, attach the workload record and telemetry summary.

A settings card, table, or fenced block is content when the user asked for a
plan, a card, or a comparison; keep it. Never place a mode label (`模式：X`,
`Mode:`, `【模式】`, or a parenthetical quick/deep tag) inside the answer body or
card. Name quick/deep once in a natural sentence only when it helps the user
understand the evidence depth. Never repeat status lines or decorative
subheadings inside a card.
