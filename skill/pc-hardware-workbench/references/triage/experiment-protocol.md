# Controlled tuning experiment

Use this before applying a tuning change. Skip the formal experiment only for read-only inspection or a clearly reversible bug fix that the user requested.

## Preflight

Record:

- device and firmware/BIOS version;
- current stable profile name;
- exact baseline values;
- workload used for comparison;
- ambient conditions and power plan;
- how to restore defaults or the saved profile;
- an alternate access route if a display or boot setting fails.

## Hypothesis

State one relationship, for example:

- lowering a specified voltage may improve temperature without reducing performance;
- changing one timing may improve a benchmark but risks data integrity;
- a driver rollback may restore stability.

Do not combine several independent goals in one test.

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

## Abort

Stop when any of these appears:

- boot failure or repeated device resets;
- visual corruption, application crashes, or filesystem errors;
- thermal runaway or connector/hotspot temperature rising unusually fast;
- repeated throttling or a sudden clock collapse;
- behavior that differs from the test plan.

## Record

Finish with:

- hypothesis;
- baseline;
- changed value;
- test result;
- pass/fail/inconclusive;
- restored profile or retained setting;
- date and device.
