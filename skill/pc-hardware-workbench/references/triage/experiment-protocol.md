# Controlled diagnostic or tuning experiment

Use this before a diagnostic action that changes state or a tuning change.
Read-only inspection usually needs no formal experiment, but still needs a
symptom window, a decision it can change, and a stop condition.

Keep these levels separate:

- read-only inspection: Event Viewer, an existing log, dump, trace, inventory, or
  sensor export;
- reversible diagnostic action: one service restart, one output-device switch,
  one driver rollback, or one Safe Mode boot with a tested way back;
- tuning or persistent change: clocks, voltages, power, fans, BIOS, or firmware.

The first useful experiment is the least risky action that can separate two live
hypotheses. Do not reinstall multiple drivers, run cleanup tools, or change several
settings because one screenshot is ambiguous.

## Evidence and tool handoff

Identify the file or source before choosing a tool:

| Evidence | Read-only first step | Limit |
| --- | --- | --- |
| Event Viewer or `.evtx` | filter the symptom time/source and preserve a focused view | correlation, not cause |
| `.etl` trace | inspect with Windows Performance Analyzer when a matching Windows Performance Recorder capture exists | requires a valid capture profile and context |
| `.dmp` dump | inspect with WinDbg for bug-check code, modules, and stack | module presence alone does not identify the failed part |
| telemetry CSV/JSON | use the bundled analyzer | trends, not diagnosis or stability proof |

Use official Microsoft sources for optional Microsoft tools. Obtain agreement
before downloading, installing, elevating, or starting a capture. Logs, traces,
and dumps can contain usernames, paths, process names, or device identifiers;
keep them local and redact before sharing.

Tracing is not passive: WPR writes files and can perturb timing and disk activity.
Capture only a bounded symptom window after agreeing on scope, storage location,
and how the trace will be removed.

For an intermittent audio dropout, crash, or driver reset, correlate the same
workload and time window across system events, display/audio events, and the
observed symptom. Later analysis may implicate a driver; that is a lead for one
controlled rollback or configuration test, not permission to replace hardware.

For USB audio, a topology comparison is one experiment variable. Record the
physical port, hub, root controller when known, power source, and co-active
devices, then move only the audio endpoint or safely remove one nonessential
device. Port count does not measure traffic, and a USB controller timeout or
DPC/ISR sample does not prove that the same mechanism explains a GPU-driver
event.

## Preflight

Record:

- device and firmware/BIOS version;
- current stable profile name;
- exact baseline values;
- workload used for comparison;
- ambient conditions and power plan;
- how to restore defaults or the saved profile;
- an alternate access route if a display or boot setting fails.

For a reversible diagnostic action, also record:

- the exact hypothesis and the two possible results;
- current driver/application version and how to restore it;
- whether the machine can still boot to a usable recovery environment;
- who performs the restart, rollback, or physical action.

## Hypothesis

State one relationship, for example:

- lowering a specified voltage may improve temperature without reducing performance;
- changing one timing may improve a benchmark but risks data integrity;
- a driver rollback may restore stability.

Do not combine several independent goals in one test.

State what the next result would confirm, rule out, or leave inconclusive. If no
observable result could change the route, do not ask the user to perform the step.

## Change

- Change only one primary variable.
- Keep power limits, clocks, fan curves, and software settings fixed unless they are the variable under test.
- Use a bounded test duration.
- Separate maximum-performance settings from daily-use settings.

## Verification

Use repeatable evidence:

- identical workload, resolution, and duration;
- at least one stability or integrity test appropriate to the setting;
- error logs, throttling, temperatures, clocks, and observed performance;
- a normal-use period after synthetic tests.

Do not treat "it booted" or "the score improved" as proof of stability.
For a diagnostic comparison, repeat the same workload and time window; keep
unrelated driver, BIOS, application, and hardware changes out of the same round.

## Abort

Stop when any of these appears:

- boot failure or repeated device resets;
- visual corruption, application crashes, or filesystem errors;
- thermal runaway or connector/hotspot temperature rising unusually fast;
- repeated throttling or a sudden clock collapse;
- behavior that differs from the test plan.

For storage or data-integrity evidence, stop performance testing immediately and
preserve the device before another write-heavy action.

## Record

Finish with:

- hypothesis;
- baseline;
- changed value;
- test result;
- pass/fail/inconclusive;
- restored profile or retained setting;
- date and device.
