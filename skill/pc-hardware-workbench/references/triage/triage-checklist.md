# Triage checklist

Use this checklist to narrow a problem without changing settings prematurely.

## Intake

Ask only for what is missing:

- Device type, model, and whether it is physically accessible.
- Operating system and recent updates.
- Exact symptom and error text.
- When it started and whether it is reproducible.
- What changed immediately before it started.
- Whether it happens at idle, low load, gaming, rendering, sleep/wake, or shutdown.
- Whether external display, safe mode, another account, or another drive changes the result.

If Windows is accessible and the user consents, this Skill's embedded collector may fill the current hardware baseline after the privacy-mode choice. Follow [collector-handoff.md](collector-handoff.md); a hardware snapshot does not replace symptom, log, temperature, power, or workload evidence.

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

Check:

- wall power and PSU switch;
- diagnostic LEDs or beep codes;
- display cable and monitor input;
- memory seating;
- whether a known-good PSU or minimal hardware configuration is available.

Avoid repeatedly power-cycling a device that shows burning smell, arcing, liquid, damaged connectors, or visible electrical damage.

### Random shutdown, reboot, or black screen

Separate:

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

Record:

- idle and load temperatures;
- package and hotspot temperatures;
- fan or pump RPM;
- whether noise changes with load or orientation;
- throttling indicators and ambient temperature.

### Storage or data-integrity issue

Check:

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

### Memory instability

Check:

- whether the system boots at default JEDEC settings;
- one DIMM versus two;
- slot population;
- memory training behavior;
- temperature and error logs;
- whether the problem follows a specific module.

### GPU instability

Check:

- stock clocks and stock power limits;
- driver clean-install behavior;
- electrical connector seating and cable condition;
- GPU, memory-junction, and hotspot temperatures;
- whether artifacts occur only in a specific workload, API, codec, or display path.

### Software or generated-media issue

Preserve:

- application version;
- workflow or project file;
- prompt or input;
- seed;
- logs and exact output;
- whether a minimal example reproduces the issue.

Do not blame hardware until the failure follows hardware across multiple software paths.

## Decision output

Report:

1. most likely layer: hardware, firmware, driver, configuration, software, or user input;
2. evidence supporting and contradicting that layer;
3. the smallest next diagnostic;
4. what result would change the diagnosis.
