# GPU curve baseline and routes

Use this reference for GPU core-curve undervolting, combined undervolt and
overclocking, or pure frequency overclocking. Do not treat a spot on the curve
as a universal value for another GPU.

## Compact route

Use this as the shortest safe overall sequence:

1. Save the default/known-good profile and record one complete baseline.
2. Select one fixed target workload, such as a repeatable game scene or one
   benchmark.
3. Tune the core voltage/frequency curve first; leave memory and power limit
   unchanged.
4. After the core route passes, test memory as a separate round.
5. Finally compare power-limit alternatives using sustained effective clock
   and actual frame time or throughput.
6. Repeat each retained profile at least twice; record frame time, maximum
   temperature, power, and the dominant limit reason.
7. Reboot and check idle, light load, sleep/wake, and several hours of normal
   target use before calling it daily-ready.
8. Keep only the winning daily profile and a separate benchmark profile.

The desktop RTX 5090 reduced-power whole-curve route is a platform-specific
coordinated exception to step 3; it is not the default sequence for other GPUs
or laptops.

## Required baseline report

Before proposing a curve edit, ask for one fixed-workload report under the
current stock or known-good profile:

- exact GPU, driver, tuning-tool version, and current profile;
- game or benchmark, resolution, preset, frame cap, and sampling window;
- representative sustained core voltage and core/effective clock at that
  voltage, not one transient spike;
- board power, core temperature, hotspot and memory-junction temperature when
  exposed, fan mode, and ambient conditions;
- the dominant performance-limit reason when exposed, such as power, thermal,
  voltage, reliability, or utilization limit;
- average and minimum/percentile FPS or frame time;
- artifacts, crashes, driver resets, or other failures;
- how to restore the current curve and the previous known-good profile.

Use a CSV, monitoring summary, screenshot with stable values, or a manually
recorded table. If core voltage is not exposed or no stable load point can be
identified, do not invent a voltage-point procedure. Continue monitoring or
use a supported offset-only route.

## Distinguish the routes

After the baseline and current/default curve or offset are recorded in the
experiment card, ask the user to choose the route before asking for a candidate.
Do not ask for a curve shape before the pure-frequency versus curve route is
known.

### Pure frequency overclock

This route raises performance without intentionally reducing voltage. Change
one core offset or one frequency control, leave memory and power controls
unchanged, and compare against the same baseline report.

### Curve undervolt and lift

This route changes several curve points as one coordinated profile:

1. Record the representative voltage and frequency reached by the selected
   game workload.
2. In the supported tuning tool, identify that voltage point on the curve.
3. Raise the target voltage point toward the chosen candidate frequency.
4. Flatten the points to the right so higher voltage does not keep adding the
   same or a higher clock unintentionally.
5. If raising lower-voltage points to the left, treat that as part of the same
   candidate curve and test idle, low-load, and light-load behavior carefully.
6. Keep memory offset, power limit, and unrelated controls fixed.
7. Test the target workload, idle/low load, a driver reset, and reboot before
   calling the curve stable.
8. After applying the curve, reopen the editor and compare requested values
   with the values that remain after clamping, smoothing, or neighbour-point
   adjustment. Record the applied curve, not only the intended drag.

The observed baseline frequency is a starting reference, not proof that the
same point is safe after flattening or lifting neighbours. Record the edited
curve before saving it.

## Desktop RTX 5090 reference route

This route is a desktop RTX 5090 reference template, not a universal 50-series
or RTX 5090 Laptop setting. Require the exact GPU and desktop form factor,
supported curve and power controls, the baseline report above, and a saved
restore point.

### Reduced power ceiling plus lifted curve

1. Set the power limit to 93% as the reference starting point.
2. Raise the whole core curve by +150 MHz as the initial coordinated profile.
3. Tune the core frequency in small follow-up steps, such as +/-15 MHz or
   +/-50 MHz, against the same baseline.
4. Treat the power limit and curve as one coordinated candidate rather than
   two independent experiments.
5. Test idle, low-load, the target game, driver reset, and reboot because a
   whole-curve lift also changes low-voltage regions.

## Desktop bounded mid-voltage curve lift

This route is available for desktop GPUs, but not for laptops. The 0.8 V and
1.025 V boundaries below are the RTX 5090 reference example; other desktop
GPUs must derive the upper cap and idle-protection boundary from their own
reported curve and supported controls.

1. Flatten every point above 1.025 V.
2. Leave the curve below 0.8 V unchanged to reduce the risk of excessive idle
   or light-load power behavior.
3. Lift only the 0.8-1.025 V segment, starting with +150 MHz as a reference.
4. Tune that segment in small follow-up steps, such as +/-15 MHz or +/-50 MHz.
5. Keep memory and unrelated controls fixed and test idle, light load, target
   workload, driver reset, and reboot before retaining the profile.

Do not offer this bounded mid-voltage route to a laptop user. On a laptop,
continue with a supported core-only route and use its own measured voltage
behavior; large VRAM overclocks remain discouraged.

The voltage ranges and frequency values are reference hypotheses. Tool
clamping, firmware behavior, silicon variation, cooling, and the measured
baseline decide the actual candidate.

## Power-limit direction

A lower power limit is a candidate direction when the baseline shows thermal
pressure or repeated large clock swings. Reduced power can sometimes produce a
more stable sustained clock by lowering temperature and voltage variation.
This is not a general rule: compare sustained effective clock, frame time,
temperatures, limit reasons, and stability against the baseline before keeping
the change.

### Desktop raised power ceiling

For a mainstream or mid-range desktop GPU that is not a low-end cooling/power
delivery design and is not RTX 4090 or RTX 5090, the vendor's highest exposed
power-limit setting can be a candidate test after the core baseline is stable.
Before offering it, verify:

- the exact GPU SKU, cooler class, PCIe power connectors, and whether the card
  is a reduced power-delivery model;
- the exact PSU model, wattage, age, cable/connector condition, and available
  transient headroom;
- that the baseline is power-limited rather than thermal-limited or already
  unstable;
- that temperatures, hotspot, fan behavior, frame time, and sustained clock
  improve or remain acceptable at the higher ceiling.

Treat the higher power ceiling as blocked when any of the following is true:

- the exact PSU model, rated 12 V capacity, age, or connector count is unknown;
- the GPU uses a modified, daisy-chained, adapter-heavy, damaged, discolored, or
  loose power path;
- the baseline is already thermal-limited, unstable, or shows unexplained
  connector/hotspot heating;
- the card's cooling or power-delivery design is visibly reduced and no
  matched evidence establishes headroom.

Do not ask an ordinary user to perform mains-side transient measurements.
Manufacturer specifications, the exact connector topology, a conservative
system-power budget, and observed stability can support a bounded test; if
those facts cannot be established, keep the stock power ceiling.

Do not infer eligibility from wattage or brand alone. A slider value such as
111% is a vendor-tool reference, not a safe universal target. RTX 4090 and RTX
5090 require a conservative high-end power-path review instead of defaulting to
the maximum ceiling.

Do not offer this route for a laptop. If firmware hides the power control, do
not use third-party or modified tools to expose or raise it; use only supported
vendor performance modes and continue with core monitoring.

If the user says a hidden or manufacturer-limited power change is already active
and asks only for assessment, follow [advice-intensity.md](advice-intensity.md).
Assessment does not authorize tool names, operational steps, target values, or a
safety claim.

## Memory is a separate round

Validate the core route before changing memory. A higher requested memory
clock is not proof of higher bandwidth or performance. Errors, correction
overhead, throttling, or a worse frame time require reverting to the previous
memory step. Stop on artifacts, texture or geometry corruption, screen
flicker, driver resets, or unstable temperatures.

## Laptop GPU memory

Do not recommend a large VRAM overclock on a laptop. It can increase shared
power and heat, reduce the core budget, and cause artifacts that are harder to
separate from core-curve instability. Validate the core route first; use only
a small memory step when explicitly useful, and revert on artifacts, resets,
or performance loss.

## Pass and abort evidence

Pass only when the same workload preserves acceptable frame time or throughput,
temperature/power behavior improves or stays within the stated goal, and idle,
low-load, reboot, and normal-use checks show no artifacts, black screens,
driver resets, WHEA or other stability errors, or unusually rapid temperature
rises.

Abort and restore the saved curve when the display resets, artifacts appear,
the driver crashes, the system restarts, clocks collapse unexpectedly, or the
temperature/power behavior leaves the prepared envelope.

## Validation layers

Use separate evidence layers:

1. A repeatable synthetic benchmark or stress tool for quick screening.
2. The actual target game or production workload for practical success.
3. Idle, light load, reboot, sleep/wake, and normal-use checks for persistence.

A high synthetic pass percentage only describes that test's frame-time
consistency. It does not prove all games, all workloads, or daily stability.
The target workload and boundary checks decide whether a candidate is retained.

## Recovery sequence

The user-facing recovery sequence is: close the tuning tool; restore the saved
default or known-good profile; disable automatic profile application; reboot
and recheck the curve, power limit, and fan mode; if the driver state is
abnormal, follow the vendor's official reinstall or rollback procedure; observe
stability before resuming any experiment.

## Plain-language explanation

The recommendation must include action, analogy, and consequence when the user
is a beginner or the curve change is persistent or difficult to recover from.
For an experienced user making a low-risk reversible change, a compact
explanation may combine the analogy with the tradeoff but must still name the
changed control, stop signal, and recovery.

> Use the localized safety notice defined in SKILL.md; do not mix languages.
