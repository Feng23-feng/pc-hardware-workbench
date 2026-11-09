# GPU core clock behavior and V/F interpretation

Use this reference before interpreting GPU clocks, a clock offset, a voltage
offset, a voltage/frequency curve, a performance-limit reason, or whether a GPU
setting actually applied.

Last source review: 2026-11-02.

## Core distinction

Keep these states separate:

1. the value requested in a tuning tool;
2. the profile that is saved and currently active;
3. the clock/voltage points the GPU selects while running the workload;
4. the measured effective clock and performance;
5. stability across reboot, idle/light load, sleep/wake, and normal use.

Evidence for one state does not prove the next. An applied curve is a
voltage/frequency relationship or constraint set, not a command to hold one
exact voltage and MHz coordinate.

## Terminology

- **GPU Boost (NVIDIA):** a GeForce/Tesla feature that raises core and memory
  clocks when sufficient power and thermal headroom exists. It is not a fixed
  clock setting.
- **GPU Boost Clock:** the boost-clock reference used in NVIDIA specifications
  and peak-rate calculations. It is not a guaranteed sustained clock.
- **Dynamic voltage and frequency scaling (DVFS):** a vendor-neutral engineering
  term for changing voltage and frequency as workload and limits change. Do not
  present it as a vendor-specific software feature name.
- **Voltage/frequency (V/F) curve:** the allowed or requested relationship
  between voltage and clock. The runtime boost controller selects an operating
  point under power, thermal, voltage, reliability, and workload constraints.
- **Requested clock / configured max:** a control input, not proof of the
  current effective clock.
- **Effective clock:** the measured clock actually delivered over a sampling
  window. It may be lower than the requested maximum.
- **Operating-point distribution:** the range or clusters of voltage/frequency
  samples observed during a fixed workload. This is an analysis term, not a
  vendor API field.
- **Performance-limit reason / PerfCap:** the dominant cap reported by the GPU
  or monitoring tool, such as power, thermal, voltage, reliability, or
  utilization.
- **GPU memory clock:** a source-dependent observation. It may represent a
  physical memory clock, effective data rate, or vendor-scaled value; the label
  alone does not establish which.
- **Memory bandwidth:** a calculated property, not a sensor. A valid calculation
  requires the memory data-rate basis plus bus width and configuration, and does
  not by itself prove achieved application performance.

## NVIDIA generations

The official NVIDIA GPUBoost description applies to GeForce and Tesla GPUs:
clocks rise when power and thermal headroom is available. Across the reviewed
RTX generations, “GPU Boost Clock” is a specification/reference value, and peak
throughput figures are explicitly based on that clock rather than a promise of
a fixed sustained operating point.

| NVIDIA family | Confirmed interpretation |
| --- | --- |
| Turing / RTX 20 and GTX 16 | Uses NVIDIA GPU Boost. The official whitepaper exposes GPU Boost Clock and calculates peak rates from it, but does not publish a generation-level boost-controller curve. Infer behavior from the device's workload telemetry, not from the clock name. |
| Ampere / RTX 30 | Same general GPU Boost interpretation. Again, the public whitepaper exposes GPU Boost Clock and peak-rate basis, not a public exact boost algorithm. Do not invent generation-specific voltage steps. |
| Ada / RTX 40 | Same general GPU Boost interpretation. Public material confirms GPU Boost Clock as a peak-rate reference. Do not backport Blackwell-only terminology unless the source explicitly supports it. |
| Blackwell / RTX 50 | In addition to GPU Boost, NVIDIA documents **Accelerated Frequency Switching**: clocks can react to dynamic workloads about 1000x faster than previous GPU architectures and move up/down within workload execution. The whitepaper says previous architectures were effectively locked to one frequency while generating a frame. Blackwell also adds separate core/memory voltage rails and independent per-workload voltage control. Expect more intra-frame V/F movement and a wider operating-point distribution. |

The Blackwell finding explains why one exact target frequency is especially weak
evidence on RTX 50. It does not mean every sample is equally desirable, that the
curve is safe, or that a higher clock always improves performance.

## AMD RDNA family

Do not use “GPU Boost” as the AMD term. AMD product specifications distinguish:

- **Game Frequency:** the expected GPU clock in typical gaming applications at
  typical TGP; individual game results may vary.
- **Boost Clock Frequency:** the maximum frequency achievable in a bursty
  workload; attainability, frequency, and sustainability vary with thermal
  conditions and the application/workload.

AMD Radeon Boost is not core-clock boost; it dynamically adjusts render
resolution in supported games. Do not confuse it with GPU clock behavior.

Generation scope:

| AMD family | Terminology and evidence boundary |
| --- | --- |
| RDNA1 / RX 5000 | Use AMD's architecture and installed-Adrenalin labels; the current public source set does not justify a specific boost-controller formula. |
| RDNA2 / RX 6000 | Official product pages define Game Frequency and Boost Clock Frequency with the variability caveats above. |
| RDNA3 / RX 7000 | Same official clock categories and variability boundaries; do not infer one universal voltage/frequency curve. |
| RDNA4 / RX 9000 | Same official clock categories and variability boundaries; verify the exact Adrenalin control type and current profile. |

RDNA1 through RDNA4 must use the labels and controls exposed by the installed
Adrenalin driver and the exact GPU profile. The reviewed official materials do
not support a universal per-RDNA voltage step or a common curve shape. Treat an
Adrenalin clock target or offset as a request, then verify actual clock, power,
temperature, throttling, and performance under the fixed workload.

## Intel Arc

Do not import NVIDIA GPU Boost or AMD Game Frequency terminology into Intel
guidance. Intel's Xe kernel documentation describes automated GT frequency
management where GuC SLPC requests a frequency between configured bounds and
PCODE makes the final actual-frequency decision from thermal and other running
conditions. The documented values include the requested frequency, actual
resolved frequency, efficiency/achievable levels, and hardware/firmware throttle
reasons.

For Arc A-series / Alchemist, use the terminology and controls exposed by its
current Intel driver; the reviewed source set did not establish an
Alchemist-specific public boost formula. For Arc B-series / Battlemage with the
Xe driver, the documented requested-versus-actual distinction applies. In both
cases, do not assume the requested maximum is the effective clock or that the
driver's internal frequency policy can be reconstructed from one telemetry
point.

## How to decide whether a curve or offset is active

Use convergent evidence:

- confirm the profile is selected and that the editor reopens with the intended
  curve/offset after applying or saving it;
- compare stock and candidate under the same workload, resolution, frame cap,
  temperature range, and monitoring window;
- compare the voltage/frequency **region or distribution**, not only one exact
  coordinate;
- compare effective clock, performance/frame time, power, temperature, and
  dominant limit reason;
- verify persistence only after reboot or sleep/wake when the tool claims a
  persistent profile.

The absence of one intended point does **not** prove the curve did not apply.
For example, a candidate described by one target frequency may run at nearby
clocks, at another voltage point, or under a different power/thermal limit. The
curve can be active while the exact coordinate is never sampled.

The presence of one intended point also does not prove the curve is active or
safe. It may be a transient sample, another profile may be loaded, or the
workload may not be repeatable.

## Wording rules

Avoid:

- “The curve failed because the target MHz did not appear.”
- “The GPU did not reach the requested clock, so the setting was not applied.”
- “A confirmed voltage/frequency point proves the profile is stable.”

Prefer:

- “The profile is saved/applied, but the workload sampled a different area of
  the V/F distribution.”
- “Compare the stock and candidate operating envelopes and the fixed-workload
  result.”
- “The requested point was observed, but stability still depends on the full
  workload and persistence checks.”

These rules apply to monitoring and concept questions without triggering the
tuning-entry gate. They become tuning safety rules when the user asks for a
candidate value, a curve edit, or a conclusion about whether to keep a profile.

Memory tuning follows the GPU memory interpretation gate in
[intake.md](intake.md) and the detailed rules in
[vram-and-memory-bus.md](vram-and-memory-bus.md). A high memory-clock reading is
not automatically an error: GDDR7, effective-clock reporting, and vendor
scaling can all produce values above older GDDR6/GDDR6X displays. A family name
such as “RTX 50” or “GDDR7” is not a substitute for the installed card, VRAM
configuration, firmware, and observed clock basis.

## Sources reviewed

NVIDIA:

- NVIDIA, “GPU Boost” technology definition:
  <https://www.nvidia.com/en-us/technologies/>
- NVIDIA, *NVIDIA Turing GPU Architecture*, WP-09183-001_v01, pp. 9 and 15:
  <https://www.nvidia.com/content/dam/en-zz/Solutions/design-visualization/technologies/turing-architecture/NVIDIA-Turing-Architecture-Whitepaper.pdf>
- NVIDIA, *NVIDIA Ampere GA102 GPU Architecture*, pp. 14 and 45:
  <https://www.nvidia.com/content/PDF/nvidia-ampere-ga-102-gpu-architecture-whitepaper-v2.pdf>
- NVIDIA, *NVIDIA Ada GPU Architecture*, pp. 12-13, 31, and 35:
  <https://images.nvidia.com/aem-dam/Solutions/geforce/ada/nvidia-ada-gpu-architecture.pdf>
- NVIDIA, *NVIDIA RTX Blackwell GPU Architecture* v1.1, pp. 5, 14, 31-33, and
  48:
  <https://images.nvidia.com/aem-dam/Solutions/geforce/blackwell/nvidia-rtx-blackwell-gpu-architecture.pdf>

AMD:

- AMD Radeon RX 6800 XT specifications, Game Frequency GD-147 and Boost Clock
  Frequency GD-151:
  <https://www.amd.com/en/products/graphics/desktops/radeon/6000-series/amd-radeon-rx-6800-xt.html>
- AMD Radeon RX 7900 XTX specifications:
  <https://www.amd.com/en/products/graphics/desktops/radeon/7000-series/amd-radeon-rx-7900xtx.html>
- AMD Radeon RX 9070 XT specifications:
  <https://www.amd.com/en/products/graphics/desktops/radeon/9000-series/amd-radeon-rx-9070xt.html>
- AMD Radeon Boost feature definition:
  <https://www.amd.com/en/products/software/adrenalin/radeon-boost.html>
- AMD RDNA architecture overview:
  <https://gpuopen.com/rdna/>

Intel / kernel:

- Linux kernel, “Xe GT Frequency Management”:
  <https://docs.kernel.org/gpu/xe/xe_gt_freq.html>

The exact boost policy remains opaque on many products. Do not infer unpublished
firmware behavior, exact voltage steps, or vendor-equivalent curve semantics
from marketing clock names.
