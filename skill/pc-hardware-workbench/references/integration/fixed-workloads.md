# Fixed workloads and one-screen experiment card

Define one fixed workload and reuse it for both rounds.

## Required fixed conditions

Record only relevant conditions:

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

For a deep record, read
[workload-record-templates.md](workload-record-templates.md) only when the user
needs the full game, synthetic, production, or stability template.

## One-screen experiment card

Use this before the user applies a candidate. Present the required information
as compact prose by default. When the user asks for a plan, card, or comparison,
a compact table, card, or fenced block is valid content.

For the beginner GPU route, use the compact card in
`references/tuning/beginner-gpu-auto-oc.md`. This full template is a data
checklist, not a form to dump on a novice.

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
Required persistence: test-only / survives reboot / normal-use validated
Sensor limitations:
Noise measurement limitations:
Decision after test: keep / continue / repeat-or-diagnose / revert / stop
```

Quick mode uses the smallest useful set; deep mode also attaches the record.

Inconclusive -> repeat-or-diagnose; do not force a final decision.

A settings card, table, or fenced block is content when the user asked for a
plan, a card, or a comparison; keep it. Never place a mode label (`模式：X`,
`Mode:`, `【模式】`, or a parenthetical quick/deep tag) inside the answer body or
card. Name quick/deep once in a natural sentence only when it helps the user
understand the evidence depth. Never repeat status lines or decorative
subheadings inside a card.
