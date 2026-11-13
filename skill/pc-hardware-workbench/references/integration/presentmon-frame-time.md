# PresentMon frame-time evidence

Use this reference when the user supplies a PresentMon CSV or asks why FPS is
acceptable but gameplay still stutters.

PresentMon is an input source under the Telemetry route. It is not a new
top-level workflow, a diagnosis, or permission to change settings.

## Capture boundary

- Accept a CSV exported by the user.
- Do not download, install, start, or elevate PresentMon automatically.
- Do not attach to a game, bypass anti-cheat, or modify graphics settings.
- Analyze the file locally. Do not upload the raw trace.
- A capture can contain application names, process IDs, and paths. Treat it as
  private evidence and redact before sharing.

If the user asks for help producing a capture, explain the capture target,
workload, duration, process filter, and output location before giving steps.
The user performs the capture.

## Expected evidence

The analyzer accepts version-dependent column names. It recognizes common
columns for:

- application or process name;
- process ID;
- capture time or CPU start time;
- frame interval, usually `msBetweenPresents`;
- display-change interval or displayed latency when present;
- present mode and synchronization interval;
- dropped-frame markers when present.

The exact header remains part of the result. If a required frame-time or time
column is missing, report the limitation rather than guessing.

## Metrics

- average FPS from frames over elapsed time;
- median, P95, P99, and maximum frame time;
- 1% low and 0.1% low FPS from the mean of the slowest frames;
- spike threshold relative to the median;
- spike frame count and consecutive spike clusters;
- optional dropped-frame count;
- top spike timestamps;
- source SHA-256, row count, application names, and analysis warnings.

Do not interpret a low average or a single spike as a hardware fault.

## Decision order

When frame-time evidence shows a problem, keep these hypotheses separate:

1. workload or scene change;
2. CPU or GPU frame-generation limit;
3. driver, DPC/ISR, or operating-system scheduling;
4. background process or storage I/O;
5. display path, synchronization, or capture limitation;
6. thermal or power throttling;
7. application-level hitch or shader compilation.

Correlate the spike window with HWiNFO, WHEA, event logs, and user-visible
symptoms before selecting one next diagnostic. A correlation is not causation.

## Command

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\scripts\analyze-presentmon.ps1 `
  -InputPath .\capture.csv `
  -ProcessName "example.exe" `
  -Format Markdown `
  -OutputPath .\capture-report.md
```

Use `-Format Json` for a machine-readable result. The script refuses to
overwrite an existing output file.
