# LibreHardwareMonitor read-only adapter

Use this adapter only when LibreHardwareMonitor is already installed and running,
the user explicitly wants a live sensor snapshot, and they provide
`-AllowLiveCollector`.

The adapter:

- reads the local Web endpoint `http://127.0.0.1:8085/data.json` used by
  current LibreHardwareMonitor releases;
- keeps read-only WMI (`root/LibreHardwareMonitor`) as a compatibility fallback;
- converts sensor objects into the structured sensor-snapshot schema;
- supports one snapshot or a bounded sampling interval;
- records the LHM product version when available;
- records whether the Web or WMI transport supplied the sample;
- records the reported hardware paths visible in the Web tree so downstream
  advice can preserve the exact card/component name instead of inferring it
  from a sensor label;
- requires an optional user-facing device alias;
- writes only a local JSON snapshot.

It does not install, launch, elevate, configure, update, or persist
LibreHardwareMonitor. It does not write clocks, voltages, power limits, fans, or
firmware. Its only network operation is a GET to an explicitly validated loopback
`/data.json` endpoint; it never connects to a remote host.

## Prerequisites

- LibreHardwareMonitor is already running.
- For current releases, **Options > Remote Web Server > Run** is started by the
  user and listens locally on port `8085`; or
- an older build exposes the read-only WMI namespace in the current user session.
- The current process can query the selected interface without self-elevation.
- The user understands that another monitoring application may expose different
  sensor names or readings.

If any prerequisite is missing, fall back to a CSV record or basic read-only CIM
inventory. A permission failure does not mean the sensor is absent.

## Capture one snapshot

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\lhm\read-lhm-telemetry.ps1" -AllowLiveCollector -DeviceAlias "<local-alias>" -OutputPath "<snapshot>.json"
```

The default `-Transport Auto` tries the loopback Web endpoint first and then the
legacy WMI namespace. A transport can be selected explicitly:

```powershell
... -Transport Web -WebEndpoint "http://127.0.0.1:8085/data.json"
... -Transport Wmi
```

`WebEndpoint` must be HTTP loopback and end in `/data.json`. Remote hosts,
credentials in the URI, queries, and fragments are rejected.

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

Common LHM Web `Type` values and WMI `SensorType` values map as follows:

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
- Web or WMI polling can conflict with other monitoring software; compare source
  and timestamp before combining data.
- Different LHM versions or hardware can expose different sensors.
- A memory-clock label may expose a physical clock, an effective data rate, or a
  vendor-scaled value. Never infer bandwidth or tuning headroom from that number
  alone, and never compare raw values across GDDR generations.

The normalizer records missing values, sampling consistency, source identity, and
the snapshot SHA-256. Those fields remain supporting evidence, not a guarantee of
sensor accuracy.

## Privacy and failure handling

- Use an alias rather than a hostname, username, serial number, or device path.
- Network-adapter labels are excluded from observed hardware components because
  they may contain user-configured names.
- Keep snapshots local unless the user reviews and redacts them.
- Do not upload raw snapshots automatically.
- Do not expose the LHM Web server to a LAN or the internet merely for this
  adapter; only its loopback response is read.
- If LHM is not running, both transports are unavailable, or WMI access is
  denied, explain the dependency and stop.
- Do not trigger UAC, install LHM, start a service, or change WMI security.

## Exit codes

- `0`: snapshot series written;
- `1`: Web/WMI sample collection failed;
- `2`: missing consent, unsafe output path, invalid sampling plan, or sensor-count
  limit.
