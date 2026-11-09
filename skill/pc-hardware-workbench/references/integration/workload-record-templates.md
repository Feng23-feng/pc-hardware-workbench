# Workload record templates

Read this reference only when the user needs a detailed experiment record, deep
validation, or an explicit workload template. For ordinary first-round tuning,
use the compact card in `fixed-workloads.md` or the beginner card in
`../tuning/beginner-gpu-auto-oc.md`.

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

Use a save point, replay, fixed route, benchmark scene, or training mode that
the user can reproduce. Record frame time or minimum/percentile FPS when
available.

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

A synthetic result is evidence for that benchmark, not proof of general
application or daily stability.

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

A stress check covers one round; it does not replace the target workload,
reboot, sleep/wake, or normal-use validation.
