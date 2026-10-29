# Component tuning playbooks

These are decision frameworks, not universal recipes. Use the exact controls exposed by the device and keep one primary variable under test.

Before selecting the first variable, derive a hardware-and-goal-specific direction with [expectation-direction.md](expectation-direction.md). Report the expected tradeoff and follow-up evidence, not a universal numeric profile.

For every component, name the comparison class before choosing an increment: this device's own baseline, a closely matched device profile, or a looser reference used only for strategy. A comparable public result may narrow the experiment range, but never becomes the default setting.

## CPU

Clarify whether the goal is lower temperature/noise at similar performance, higher sustained clocks, or a benchmark result.

- Record current P/E, CCD, or core ratios as applicable, voltage mode and offset, power limits, loadline or curve settings, and any vendor utility profile.
- For undervolting, change the voltage control by one smallest meaningful step while leaving ratios, power limits, and fan behavior fixed.
- For frequency tuning, change one ratio or one group of equivalent cores by one smallest meaningful step; verify that the intended ratio actually appears under the workload.
- Monitor effective/core clocks, package power, package and hotspot temperatures, throttle reasons, WHEA or machine-check events, and workload result.
- For Intel 13th/14th-gen CPUs, read [intel-13-14-gen.md](intel-13-14-gen.md).
- Do not disable security features or use firmware modifications to gain access to an otherwise unsupported control.
- Treat a stable gaming session or single benchmark as evidence for one round only; validate idle/low-load behavior, reboot behavior, and a longer normal-use period before calling the profile daily-stable. Use the daily-promotion checklist in
  [../integration/success-and-sensor-semantics.md](../integration/success-and-sensor-semantics.md).

## GPU

- Record the stock/known-good in-workload baseline and current curve before any candidate.
- Read [gpu-curve-baseline.md](gpu-curve-baseline.md) for curve-based undervolting, combined undervolt/overclock, or pure frequency overclocking.
- Improve one of core voltage/frequency curve, core offset, memory offset, or power limit per round; do not stack control classes.
- Inspect artifacts, resets, effective clocks, power, temperatures, fan behavior, and frame time, not only a benchmark score.
- On laptops, account for shared CPU/GPU power and thermal budgets; a GPU-only improvement can reduce CPU performance or the reverse.
- Separate daily and benchmark-only GPU profiles explicitly. A profile that wins one benchmark can be unacceptable for long sessions, laptop battery operation, fan noise, or protected games.

## Memory

Record JEDEC/XMP/EXPO profile, rated and actual speed, module rank, die revision when directly exposed, PMIC state, primary timings, and relevant secondary timings.

- Establish a stable non-XMP or explicitly documented profile before aggressive tuning.
- If enabling XMP/EXPO, treat that as a complete profile and validate it before editing individual timings.
- Change one timing or one related timing group per round. Keep frequency and all unrelated voltages fixed unless the chosen experiment specifically tests them.
- Do not copy timings between different die revisions, ranks, capacities, or desktop/laptop form factors.
- Include memory training, cold boot, warm reboot, sleep/wake, and data-integrity evidence; a boot alone is not stability.
- If a module PMIC is locked or BIOS values do not reach the rail, report that as a platform limitation rather than pretending the setting applied.
- Treat XMP/EXPO as a complete reference profile, not proof that individual timings are safe. Do not infer die revision, rank, or PMIC capability from a marketing name.

## Cross-component isolation

Keep the daily profile as the baseline when testing a new component. Do not tune CPU, GPU, and memory simultaneously. If the user wants a combined extreme profile, validate each component separately first and then rerun a combined workload before calling it stable.
