# Cooling and power-envelope evidence

Use this only after inventory has identified the device form. Cooling information is not reliably available from the read-only collector.

## Timing

Do not ask about coolers, fans, case layout, or thermal capacity before knowing whether the device is a desktop, laptop, or MoDT. Inventory first; cooling context second.

## Desktop

Ask one compact multiple-choice question covering only what affects the current target:

- CPU tuning or CPU thermal work: CPU air cooling / all-in-one liquid / other / unknown, plus relevant case airflow;
- GPU tuning or GPU thermal work: original air cooler classified as single/turbo, dual-fan, triple-fan, or four-plus-fan / modified air cooler / modified liquid cooler / unknown, plus relevant case airflow;
- memory or whole-system thermal work: relevant case airflow and only the component heat sources that can change the decision;
- ambient conditions only when they materially affect the test.

Do not ask for an unrelated component's cooling merely because it exists. Do not require the exact cooler model or dimensions unless a fitment issue is the actual problem. Fan class is a useful coarse proxy because dual-fan cards and larger three/four-plus-fan cooling modules often have materially different heatsink mass, heatpipe count, thickness, and supported TGP. It is not sufficient by itself; combine it with GPU power, temperatures, effective clocks, throttling, noise, and a fixed workload. “Unknown” is an acceptable answer. Continue with cooling labeled unknown, and do not promise temperature, noise, or sustained-performance headroom.

## Laptop

Do not ask the user to describe an internal cooling solution as though it were a desktop build. After inventory identifies a laptop:

1. use the exact model, CPU/GPU class, active vendor performance mode, and official platform power envelope as a provisional ceiling;
2. record the source and date of any official power numbers;
3. treat the official CPU base/TDP and GPU TGP range as platform configuration evidence, not measured cooling capacity;
4. calibrate the actual thermal limit with package/GPU power, temperatures, effective clocks, throttling, fan behavior, and a fixed workload;
5. if the exact OEM envelope or mode cannot be verified, leave the number unknown rather than inventing it.

Do not compare a laptop's official power ceiling with a desktop cooler's capacity. Shared CPU/GPU power, firmware mode, ambient conditions, fan curves, and skin/VRM limits can dominate the result.

## Purchase decisions

Cooling evidence may rule out a configuration that cannot sustain the task. It does not authorize a purchase by itself. Compare repair, cleaning, fan/power-mode settings, and a matched measured workload before recommending replacement.
