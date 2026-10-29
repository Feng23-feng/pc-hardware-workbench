# Device and objective routes

Tune the route to the user's goal and the machine's actual controls. Component order is not a universal curriculum.

## First choose the objective

- **Efficiency-first undervolt:** lower voltage, power, heat, or noise while keeping performance acceptable.
- **Performance-first overclock:** improve sustained clocks, frame time, throughput, or a benchmark result.
- **Balanced daily profile:** improve usability without chasing the highest score.
- **Diagnostic only:** collect evidence and explain a limitation without changing a setting.

High FPS and low temperatures are different objectives. Do not label every voltage experiment as “more performance,” and do not label every frequency increase as a good daily profile.

## Undervolt and overclock are related but not identical

An undervolt changes the voltage/frequency relationship. With the same requested frequency it may preserve performance at lower power; on a dynamic GPU curve it can also change boost frequency and perceived performance. A frequency overclock may need more voltage, or may fit under the existing limit depending on the platform.

When the user wants both:

1. establish one stable efficiency-oriented change first;
2. verify performance, idle behavior, reboot, and the target workload;
3. only then consider a separate performance-oriented change;
4. keep the two results as separate rounds, not one blended “stable” claim.

Undervolting is not automatically risk-free. It can cause idle or low-load failure just as overclocking can cause load failure.

## Laptop route

Start with the controls that actually survive reboot and are supported by the laptop firmware or vendor tool. GPU-first is valid when the user mainly cares about games or graphics workloads.

For a laptop:

- record AC/battery state, adapter, fan mode, ambient temperature, and shared CPU/GPU power limits;
- monitor both GPU and CPU behavior because reducing one component's power can leave more or less for the other;
- validate the daily route with a combined CPU+GPU workload in addition to the single component test;
- expect CPU undervolting, GPU voltage, power limits, and memory timings to be locked or hidden on some models;
- do not treat a desktop VBIOS, Afterburner profile, or BIOS setting as transferable;
- do not imply that a profile autostart survives reboot if it does not.
- do not use third-party or modified tools to expose or raise a hidden power
  limit; use only supported vendor performance modes.

## Desktop route

A desktop may have easier physical recovery and more exposed controls, but it can still fail to boot, corrupt data, trip power delivery, or damage an unstable connector. GPU-first, CPU-first, and memory-first are all valid choices if the user has a reason.

Before a persistent BIOS or memory experiment, record the exact Clear CMOS route, saved profile, boot device, and whether the user can reach the machine. Ensure the power connector and cable are rated for the intended load and visibly sound; do not use “desktop is safer” as a substitute for checking the power path.

A supported highest power-limit setting can be tested on a suitable
mainstream/mid-range desktop card only after the exact PSU, connectors,
cooling, baseline limit reason, and temperatures support it. Do not apply that
rule blindly to RTX 4090/5090, low-end card designs, unknown PSUs, or laptops.

## GPU-preferred route

Use this when the user wants to learn on graphics or asks for GPU graphics performance.

1. Record the GPU model, driver, tool version, default profile, and a repeatable workload.
2. Choose one route: efficiency-oriented voltage/curve work, one core-frequency change, one memory change, or one power-limit change.
3. Use one supported configurator and monitoring source; do not stack afterburner-style offsets with a vendor tool applying the same controls.
4. Test artifacts, driver resets, black screens, effective clocks, power, fan behavior, temperatures, and frame time—not only the average benchmark score.
5. On a laptop, rerun the combined CPU+GPU workload after the GPU-only pass.
6. Keep daily and benchmark profiles separate and save the stock profile before experimenting.

For an efficiency-oriented GPU route, first verify that the same or acceptable workload performance remains while temperature, power, noise, or sustained clocks improve. For a performance-oriented GPU route, do not infer success from a higher reported offset; verify that the intended clocks and work completed actually improve.

## CPU-preferred and memory-preferred routes

Use a CPU-first route for compile, rendering, CPU-bound simulation, or a user who explicitly wants to learn CPU controls. Use a memory-first route only when memory capacity, bandwidth, or latency is the stated bottleneck, or when the user explicitly wants to learn memory tuning.

Do not recommend memory timing work merely because it is available on a desktop. It adds training, boot, sleep/wake, and data-integrity failure modes that are unnecessary for a GPU-focused user.
