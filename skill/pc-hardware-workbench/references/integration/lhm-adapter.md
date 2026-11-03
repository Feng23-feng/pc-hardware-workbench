# LibreHardwareMonitor read-only adapter

Use this adapter only when LibreHardwareMonitor is already installed and running,
the user explicitly wants a live sensor snapshot, and they provide
`-AllowLiveCollector`.

The adapter:

- reads the WMI namespace `root/LibreHardwareMonitor`;
- converts sensor objects into the structured sensor-snapshot schema;
- supports one snapshot or a bounded sampling interval;
- records the LHM product version when available;
- requires an optional user-facing device alias;
- writes only a local JSON snapshot.

It does not install, launch, elevate, configure, update, or persist
LibreHardwareMonitor. It does not write clocks, voltages, power limits, fans, or
firmware.

## Prerequisites

- LibreHardwareMonitor is already running.
- Its WMI interface is available in the current user session.
- The current process can query the LHM WMI namespace without self-elevation.
- The user understands that another monitoring application may expose different
  sensor names or readings.

If any prerequisite is missing, fall back to a CSV record or basic read-only CIM
inventory. A permission failure does not mean the sensor is absent.

## Capture one snapshot

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\lhm\read-lhm-telemetry.ps1" -AllowLiveCollector -DeviceAlias "<local-alias>" -OutputPath "<snapshot>.json"
```

## Capture a bounded series

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\lhm\read-lhm-telemetry.ps1" -AllowLiveCollector -DeviceAlias "<local-alias>" -DurationSeconds 30 -IntervalSeconds 1 -OutputPath "<snapshot>.json"
```

Limits:

- duration: `0` to `300` seconds;
- interval: `0.25` to `60` seconds;
- samples: at most `1201`;
- sensors per sample: configured with `-MaxSensors`.

The collector does not run indefinitely in the background.

## Normalize and chart

The LHM output is a standard sensor snapshot. Pass it through the same
normalization and chart pipeline as any other structured source:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\normalize-telemetry.ps1" -Path "<snapshot>.json" -OutputPath "<normalized>.json"

powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\render-telemetry-chart.ps1" -Path "<normalized>.json" -OutputPath "<chart>.svg" -InputFormat NormalizedJson
```

## Sensor mapping

Common LHM sensor types map as follows:

| LHM type | Category | Unit |
| --- | --- | --- |
| Temperature | `temperature` | `C` |
| Power | `power` | `W` |
| Clock / Frequency | `clock` | `MHz` |
| Voltage | `voltage` | `V` |
| Fan | `fan` | `RPM` |
| Control | `fan` | `%` |
| Load / Level | `utilization` | `%` |
| Throughput | `throughput` | `B/s` |
| Data / SmallData | `memory` | `MB` |
| Noise | `other` | `dBA` |
| Unknown | `other` | `unitless` |

GPU sensor names are component-qualified and common ambiguous names are
normalized, for example `GPU Core` temperature becomes
`GPU Temperature (Core)`. Duplicate canonical headers receive stable `#N`
suffixes.

Unknown or unitless sensors may remain in the snapshot but may not be selected
by the analyzer. Report them as unavailable rather than guessing a role.

## Sampling and validity

- A fast sample is an instantaneous view, not stability proof.
- A short series is not equivalent to a long fixed-workload baseline.
- Verify the selected time window excludes idle, loading, and recovery phases.
- WMI polling can conflict with other monitoring software; compare source and
  timestamp before combining data.
- Different LHM versions or hardware can expose different sensors.

The normalizer records missing values, sampling consistency, source identity, and
the snapshot SHA-256. Those fields remain supporting evidence, not a guarantee of
sensor accuracy.

## Privacy and failure handling

- Use an alias rather than a hostname, username, serial number, or device path.
- Keep snapshots local unless the user reviews and redacts them.
- Do not upload raw snapshots automatically.
- If LHM is not running, the namespace is unavailable, or WMI access is denied,
  explain the dependency and stop.
- Do not trigger UAC, install LHM, start a service, or change WMI security.

## Exit codes

- `0`: snapshot series written;
- `1`: WMI/sample collection failed;
- `2`: missing consent, unsafe output path, invalid sampling plan, or sensor-count
  limit.
