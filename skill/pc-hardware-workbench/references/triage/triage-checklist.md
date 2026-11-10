# Triage checklist

Use this checklist to localize a problem without changing settings prematurely.
Triage does not prove a failed component. Its job is to protect safety and data,
identify the most likely fault layer, and choose one next check whose result can
change the route.

## First-contact state machine

Apply these levels in order. A lower level never overrides an unresolved higher
one:

1. **Physical safety:** burning smell, smoke, sparks, liquid, damaged connectors,
   exposed wiring, a swollen battery, or visible electrical damage.
2. **Access and boot:** no power, no POST, no display, boot loop, or Windows
   cannot be reached.
3. **Stability and data risk:** unexpected reboot, shutdown, blue screen, WHEA,
   driver reset, corruption warning, or a failing storage device.
4. **Functional loss:** one display path, USB device, network, audio, sleep/wake,
   battery path, or application fails.
5. **Performance or acoustics:** slowdown, stutter, throttling, temperature, or
   noise while the machine otherwise remains usable.

When the user gives several symptoms, acknowledge them but handle only the
highest unresolved level first. Do not jump to performance tuning while a boot,
data-integrity, or physical-safety issue remains unresolved.

Establish only the minimum needed to choose the next branch:

- Is the device currently safe to operate?
- Can it power on and reach firmware?
- Is Windows or another usable environment reachable?
- Is the primary symptom a loss of function, instability, data risk, or degraded
  performance?
- What happened immediately before the first occurrence?

## Intake

Ask only for what is missing. Start with the one answer that separates the most
likely branches; do not dump this list as a questionnaire.

- Device type, model, and whether it is physically accessible.
- Operating system and recent updates.
- Exact symptom and error text.
- When it started and whether it is reproducible.
- What changed immediately before it started.
- Whether it happens at idle, low load, gaming, rendering, sleep/wake, or shutdown.
- Whether external display, safe mode, another account, or another drive changes the result.
- Whether the machine is usable enough that read-only data can be recovered
  before any risky diagnostic step.

If Windows is accessible and the user consents, this Skill's embedded collector may fill the current hardware baseline after the privacy-mode choice. Follow [collector-handoff.md](collector-handoff.md); a hardware snapshot does not replace symptom, log, temperature, power, or workload evidence.

## Evidence states

Keep these states separate in the working note even when the final answer is
concise:

- **observed-current:** directly visible in a current log, screenshot, sensor
  value, or successful reproduction;
- **user-reported:** supplied by the user but not independently verified;
- **inferred:** a hypothesis derived from one or more observations;
- **unknown:** not collected, not exposed, or not remembered;
- **conflicting:** two sources disagree or the same event has incompatible
  descriptions;
- **historical or stale:** real evidence from an earlier hardware, firmware,
  driver, workload, or configuration.

A reported cause is not evidence. “It must be the PSU” remains the user's
hypothesis until electrical, event, or substitution evidence supports it.

## Question selection

Ask one question per turn when possible. A question is useful only if at least
two plausible branches would produce different next actions.

Use this order:

1. a physical-safety question if any warning sign is present;
2. a question that separates no-power, no-POST, no-Windows, and usable-Windows;
3. a question separating reboot, shutdown, driver-only display loss, and a
   stable machine with one broken function;
4. a question identifying when the symptom occurs and what changed;
5. only then a component-specific check.

Prefer the user's observable language over component names. “The fans spin but
the screen stays black” separates more than asking the user to diagnose the GPU.
If the answer does not change the route, do not ask it.

## De-energized handling rule

Before reseating memory, a GPU, a fan/pump connector, or any power cable:

1. shut down the operating system fully;
2. disconnect the wall power or power adapter;
3. allow residual power to discharge according to the vendor's documented procedure;
4. for a laptop, disconnect the internal battery if the procedure requires it;
5. verify the relevant parts are not energized before touching them.

If the user cannot confirm these conditions, stop at inspection and use a qualified technician. Do not guide energized reseating or “test while wiggling.”

## Symptom routing

### No power or no POST

First separate **no electrical activity** from **fan or light activity without
POST**. Ask for one observable: any fan spin, LED, keyboard light, or display
reaction when power is pressed. Do not ask for PSU, RAM, or GPU conclusions first.

Then check:

- wall power and PSU switch;
- diagnostic LEDs or beep codes;
- display cable and monitor input;
- memory seating;
- whether a known-good PSU or minimal hardware configuration is available.

Avoid repeatedly power-cycling a device that shows burning smell, arcing, liquid, damaged connectors, or visible electrical damage.

### Random shutdown, reboot, or black screen

First ask what actually happened to the machine: power stayed on with display
loss, Windows restarted, or the whole system lost power. Then separate:

- power loss versus reboot versus display loss;
- idle versus load;
- CPU-only versus GPU-only versus combined load;
- event logs, WHEA, thermal warnings, and power-limit throttling;
- recent driver, BIOS, firmware, or hardware changes.

Useful read-only Windows evidence includes:

- `WHEA-Logger` entries for corrected or uncorrected hardware errors;
- `Kernel-Power 41`, which establishes an unclean shutdown but not its cause;
- `BugCheck 1001` for a recorded bug-check code when present;
- minidumps under `%SystemRoot%\Minidump` or `%SystemRoot%\MEMORY.DMP`;
- storage, filesystem, display-driver, and thermal-warning events in the System log.

Missing evidence is not proof that the event did not occur: logging can be disabled,
the dump can fail to write, or the device can lose power before recording. Do not
infer PSU, RAM, or GPU failure from `Kernel-Power 41` alone. If a dump or log is
available, keep it local unless the user deliberately sanitizes and shares it.

### Everyday slowdown or intermittent stutter

Ask when the slowdown is visible and choose one short branch:

- **Startup or login:** distinguish startup applications, disk activity, driver
  initialization, network waits, and thermal throttling before blaming hardware.
- **General desktop use:** check memory pressure, active storage load, temperatures,
  power mode, recent updates, and background processes before recommending upgrades.
- **Game stutter:** record the same repeatable route and compare average FPS with
  minimum/percentile FPS or frame time; a high average does not exclude stutter.
- **Nearly full volume:** report free space, volume mapping, and storage health, but
  do not delete or move user files automatically.

The next result must change the diagnosis. Do not treat one Task Manager screenshot
as proof of a CPU, GPU, RAM, or storage bottleneck.

### Thermal or noise issue

First identify the component and the trigger: idle, startup, one game, sustained
render, or all loads. Separate temperature from noise and sustained performance.
Record:

- idle and load temperatures;
- package and hotspot temperatures;
- fan or pump RPM;
- whether noise changes with load or orientation;
- throttling indicators and ambient temperature.

### Storage or data-integrity issue

First establish immediate data risk. If the drive is disappearing, reporting
corruption, making abnormal noises, or preventing a backup, preserve access and
stop write-heavy or formatting steps before deeper diagnosis. Then check:

- SMART health and error counters;
- drive model, capacity, slot, and current role;
- serial number only when needed for local physical identification; it is optional and must not be required in a shared report;
- event logs and filesystem errors;
- whether the issue follows the drive, cable, slot, or motherboard.

Before removing or formatting any drive, identify the physical device locally by model, capacity, slot, and serial number when accessible, rather than by drive letter alone. Use the serial locally only; crop, omit, or redact it before sharing.

### Laptop battery or power-adapter issue

For an unexpected runtime, shutdown, throttling, or battery-drain complaint, collect:

- design capacity, full-charge capacity, cycle count when available, and battery
  health from the read-only battery report;
- AC versus battery state, active Windows or vendor power mode, brightness,
  refresh rate, and the same representative workload;
- package/GPU power and clocks on AC versus battery;
- adapter model and rated wattage, whether the battery drains under load, and any
  connector overheating or damage;
- sleep/wake failures, background processes, and recent driver or firmware changes.

Deteriorated capacity supports battery aging but does not explain every runtime
drop. If the battery drains while connected or a connector is hot, damaged, or
discolored, stop high-load testing and follow the physical-safety route.

### Peripheral or network scope boundary

USB, audio, Wi-Fi, Bluetooth, display-cable, and local-network complaints receive a
short hardware sanity check: another port, cable, device, driver-free environment,
or another machine where practical. Confirm whether the symptom follows the device,
the host, the driver stack, or only one application or network.

If the evidence points to a general Windows, router, ISP, account, or application
problem, hand off to that support path. Do not recommend a motherboard, Wi-Fi card,
or whole-system upgrade merely to continue a troubleshooting flow.

### Audio stutter, crackle, or dropout

First separate one game or application from all system audio, then identify the
output path: GPU HDMI/DisplayPort audio, motherboard analog output, USB headset,
external DAC, or Bluetooth. A desktop game-only symptom does not prove the same
component as system-wide audio.

Record the game and fixed scene, the audio drop timeline, output device, audio
driver, GPU driver, recent changes, and frame-time or input stalls in the same
window. If available, correlate System/Application events with display-driver and
audio events; a matching timestamp is a lead, not proof. For a deeper latency
question, an optional Event Tracing for Windows trace can be captured with
Windows Performance Recorder and inspected with Windows Performance Analyzer
when the user agrees.

Test one reversible change at a time: switch the output path, disable only the
unused GPU display-audio endpoint, or roll back one recently changed official
driver with a saved recovery path. Do not automatically reinstall every driver,
run registry cleaners, or replace the GPU or PSU. If the change removes the
symptom, repeat the same scene and output path before retaining it.

#### USB audio path and overload hypothesis

When the output is USB, map the physical path before naming bus congestion:
direct rear I/O, front-panel header, monitor or dock hub, external powered or
unpowered hub, and any continuously active, high-bandwidth, high-report-rate, or
bus-powered devices that may share the same root controller. Do not assume
adjacent ports share a controller, and do not treat “all ports occupied” as a
universal overload threshold. Port count is not a measurement of traffic.
Device count, bandwidth or polling pressure, power delivery, enumeration or
reset, driver behavior, and DPC/ISR scheduling are separate hypotheses.

Treat “too many requests caused a driver timeout” as a user-reported hypothesis
until evidence separates the layers. A USB host-controller or device timeout and
an NVIDIA display-driver timeout/TDR are not the same mechanism merely because
both can appear as driver errors.

For the first comparison, keep the same game scene and audio output and change
one path variable: move only the audio endpoint to a directly attached port,
preferably a different verified controller/root hub, or safely remove one
nonessential high-bandwidth or bus-powered device. Do not hot-unplug a storage
device that may be writing, and do not combine the move with a GPU-driver
rollback, registry edit, BIOS change, or reinstall. If the symptom improves,
repeat the same scene before retaining the change. If it persists, correlate the
symptoms with USB/controller reset events and use a bounded WPR/WPA trace for
DPC/ISR evidence only when appropriate; a high latency sample is not a root-cause
verdict. Stop software testing if a hub, connector, or cable becomes hot,
discolored, or emits a smell.

### Memory instability

First ask whether Windows boots at the firmware default memory profile and
whether the symptom follows one module, one slot, or every configuration. Then
check:

- whether the system boots at default JEDEC settings;
- one DIMM versus two;
- slot population;
- memory training behavior;
- temperature and error logs;
- whether the problem follows a specific module.

### GPU instability

First ask whether the machine itself restarts or only the display/driver
disconnects, and whether corruption is visible only in one workload or appears in
desktop capture, BIOS/UEFI, or another display path. Then check:

- stock clocks and stock power limits;
- driver clean-install behavior;
- electrical connector seating and cable condition;
- GPU, memory-junction, and hotspot temperatures;
- whether artifacts occur only in a specific workload, API, codec, or display path.

### Software or generated-media issue

First determine whether a minimal, repeatable example exists and whether the same
input fails on another application or machine. Preserve:

- application version;
- workflow or project file;
- prompt or input;
- seed;
- logs and exact output;
- whether a minimal example reproduces the issue.

Do not blame hardware until the failure follows hardware across multiple software paths.

## Premature-conclusion guards

- Do not repeat the user's suspected cause as the diagnosis.
- Do not infer a component failure from one event code, one sensor value, one
  screenshot, or one application crash.
- Do not change firmware, drivers, hardware, and workload in the same round.
- Do not recommend reinstall, reset, Clear CMOS, drive removal, or part
  replacement before confirming the required recovery route and preserving
  important evidence.
- Do not ignore a lower-severity symptom that conflicts with the working
  hypothesis.
- Do not use a stale or different machine's baseline as the current state.
- Do not hand a stability problem to tuning merely because a tuning action is
  available.

## Decision output

Lead with the current result, not with the complete evidence inventory. Report:

1. current status: safe, unsafe, usable, limited, or unable to boot;
2. most likely layer: hardware, firmware, driver, configuration, software,
   external device/network, or user input, plus confidence (`low`, `medium`, or
   `high`);
3. the decisive evidence supporting and contradicting that layer;
4. important unknowns, conflicts, or stale evidence;
5. one smallest next diagnostic and how to perform it safely;
6. the expected alternative results and which route each would select;
7. an immediate stop condition and the recovery or support handoff.

For a beginner, collapse this into two short paragraphs and one next question.
Never show internal confidence labels or the full decision schema unless the
user asks for a detailed record.
