# Success criteria and sensor semantics

Use this reference when defining a pass condition or interpreting telemetry.

## Goal-specific success

| Goal | Primary pass evidence | Guard evidence | Reject as success when |
| --- | --- | --- | --- |
| Efficiency / undervolt | Same or acceptable performance with lower power, temperature, noise, or improved sustained behavior | Idle/low-load stability, reboot, sleep/wake, artifacts, errors | Performance drops beyond the user's tolerance or only a short load is clean |
| Performance / overclock | Repeatable improvement in FPS, frame time, throughput, or benchmark | Correctness, limits, artifacts, errors, shared laptop power | Gain is within noise or hides worse frame pacing |
| Balanced daily | Better usability without unacceptable heat, noise, instability, or portability loss | Idle, load, reboot, sleep/wake, normal use | One synthetic pass is presented as daily-stable |
| Benchmark-only | Repeatable completion of the defined benchmark | Artifacts, resets, thermal abnormality, data loss | It is silently promoted to a daily profile |
| Diagnostic only | Clearer fault hypothesis and next discriminating test | Evidence changes the diagnosis | Tuning is recommended before diagnosis is established |

Define the primary metric and guard condition before the user applies a setting. Repeat the stock baseline when measurement noise is comparable to the expected gain.

For benchmark pass rates or stability percentages, name the exact test and
settings. A high result demonstrates consistency only within that test window;
it does not prove that every game, application, idle state, sleep/wake path, or
driver reload is stable.

## Promoting a profile to daily use

A benchmark pass, a short game session, or a clean ten minutes is screening
evidence, not daily stability. When the user asks to keep a profile for
everyday use, say that explicitly and answer with this checklist item by item
instead of summarizing it in prose. Ask for whatever is missing; do not call
the profile daily-stable until all six are satisfied.

1. Test identity and result: which benchmark or workload, exact version or
   scene, resolution, preset, frame cap, sampling window, and the recorded
   frame-time result (average, minimum, and low percentile as reported).
2. Conditions during that run: limit reasons, peak and sustained temperature,
   power, and clocks.
3. Target workload versus baseline: a repeat run of the workload the user
   actually cares about, compared against the stock or known-good baseline on
   that same workload.
4. Layers: idle, light load, reboot, sleep/wake, and driver reload behavior.
5. Applied values: when curve smoothing or offsets changed what the hardware
   actually applies, the final applied voltage and frequency range.
6. Recovery and notice: the saved restore point, the sequence that returns to
   stock, and the reference-only safety notice required by SKILL.md.

Keep a daily profile and a benchmark-only profile as separate records.

## Noise as evidence

Fan RPM or percentage is not a sound-level measurement. If noise is only observed informally, label it a subjective impression. Use noise as a formal pass metric only when recording:

- sound-pressure level and measurement device/app;
- distance and microphone or phone position relative to device;
- room background noise and ambient temperature;
- fan/power profile and workload;
- repeated measurement duration and number of samples;
- dominant frequency, rattle, whine, pump noise, or other subjective characteristics when relevant.

Compare the same position, room, workload, and fan mode. A lower RPM can still sound worse because of motor, pump, coil, or tonal noise.

## Sensor semantics

| Reading | Meaning | Does not prove |
| --- | --- | --- |
| Requested clock/offset | Requested target | Actual sustained clock or completed work |
| Effective clock | Device-reported active operation | A performance or stability improvement |
| Core/package temperature | Temperature at the named location | Another core, hotspot, memory junction, or whole-device temperature |
| GPU hotspot | High-temperature processor point | Global memory temperature |
| GPU memory junction | A memory temperature sensor when exposed | Core temperature or thermal headroom elsewhere |
| Power and limit reason | Observed draw and a limiting cap | The full performance bottleneck |
| Voltage request/reading | Requested point or reported rail | That firmware accepted it or the sensor is calibrated |
| Fan percentage/RPM | Requested duty or measured rotation | Effective airflow at the hottest component |
| Average FPS | Average frames in the sample | Minimum FPS or frame-time consistency |
| Minimum/percentile FPS | A sampling-dependent distribution statistic | The same as average FPS or absence of stutter |

Limit reasons are context, not a diagnosis by themselves. A GPU can be power-limited while more voltage reduces efficiency; a CPU can report a high clock while thermal or power limits reduce sustained work.

## Sampling and hidden sensors

- Use the same monitoring source, interval, workload, and window for baseline and candidate.
- Identify idle, warm-up, steady-load, transition, and recovery periods.
- Compare sustained effective clocks, not a peak boost against a steady value.
- Mark missing, stale, implausible, or differently sampled sensors as unknown.
- When two tools disagree, state both and compare versions, polling intervals, sensor choices, and calculations.
- Do not estimate a hidden hotspot or memory-junction temperature from core temperature or a fixed offset.
- If a critical sensor is unavailable, reduce test aggressiveness and rely more on artifacts, resets, power-limit behavior, workload stability, and frame time.

Recommend the current official stable monitoring tool from its official source. Keep an older known-good build only as a private, device-specific fallback with source, hash/signature when available, driver, date, and observed sensor scope.
