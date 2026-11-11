# Privacy and Safety Boundaries

[中文](../privacy-and-safety.md) | [English](privacy-and-safety.md)

## Actions the Skill does not perform automatically

- It does not modify BIOS/UEFI.
- It does not modify clocks, voltage, power limits, fan curves, memory timings, or
  firmware.
- It does not elevate privileges, install drivers, or start monitoring software.
- It does not bypass permissions, anti-cheat controls, vendor locks, or other safety
  restrictions.
- It does not connect to a monitoring endpoint that is not hosted on loopback.

Hardware-tuning advice is limited to a proposed test plan. Every persistent change
must be applied manually by the user.

## Physical safety comes first

Stop stress testing and tuning if there is a burning smell, spark, liquid, melted
connector, swollen battery, or visible damage. These conditions take priority over
performance, temperature, and purchase recommendations.

## Unexplained instability

An unexplained blue screen, restart, WHEA event, driver reset, or repeated game crash
blocks tuning until a stable baseline is recovered. A user's verbal acceptance of risk
does not replace a recovery path.

## Data collection

- Collection does not elevate privileges by default.
- Serial numbers are omitted by default.
- Redacted mode masks device, motherboard, BIOS, memory part number, storage, volume
  label, display, and battery identifiers.
- The Skill reads only currently visible information and does not guess missing models.
- A monitoring screenshot represents one point in time, not a time series.
- CSV data is the primary evidence for statistical analysis and time-window comparison.

The collector does not upload hardware reports. Telemetry analysis rejects UNC paths,
mapped network drives, cloud placeholder files, symbolic links, directory junctions,
and other reparse points.

## Read-only LibreHardwareMonitor integration

The LibreHardwareMonitor adapter reads only an already-running local loopback web
endpoint and requires explicit consent. It does not install, start, or elevate LHM, run
without a time limit, or modify hardware settings.

## Hardware cases

Local case files do not retain raw evidence content by default. Optional previews have
size limits and reject active or externally linked SVG content. Before publishing or
sharing an exported HTML report, manually inspect it for local paths, device names,
and screenshots.

## Before sharing a report

Review and remove:

- real serial numbers;
- usernames, computer names, and exact local paths;
- screenshots that have not been redacted;
- accounts, network addresses, and other personal information.

Report security issues privately according to [SECURITY.md](../../SECURITY.md). Do not
upload hardware logs, screenshots, or local paths to a public issue.
