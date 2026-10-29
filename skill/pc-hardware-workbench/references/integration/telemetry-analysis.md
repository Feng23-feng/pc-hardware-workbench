# Telemetry analysis

Use the read-only analyzer to summarize an existing HWiNFO CSV, PresentMon CSV, or compatible text CSV. It does not launch monitoring software, install drivers, request elevation, initiate network access, or change hardware settings. UNC paths, mapped network drives, and Windows offline/cloud-placeholder files are rejected so the analyzer does not initiate remote reads or cloud hydration.

## Confirm the record exists

Before asking for a path, confirm that the user has monitoring software and an exported record:

- **software and record available:** continue to file analysis;
- **software installed, no record yet:** teach Sensors-only logging and the export steps before returning to analysis;
- **no monitoring software:** provide the official HWiNFO download page, then the recording steps;
- **user cancels:** state that no file was analyzed and keep the original goal or offer another option.
- **When teaching a first capture:** Always relay the HWiNFO download-page specifics from `references/tuning/tools.md`: prefer the Installer card, order mirrors Local (U.S.) then SAC ftp then dAppCDN, describe dAppCDN as network-dependent and stop retrying after a timeout, say that "U.S." is a server location rather than a download restriction, name DWG FastView, LanSweeper, OPEN, and Try Now as advertisements, reject repacks and cloud-drive mirrors, and warn that a raw HWiNFO CSV may carry appended device metadata before external sharing.

Do not open with an unexplained file picker or assume that every user already has a monitoring tool.

## Command

From the installed Skill folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\analyze-telemetry.ps1" -Path "<telemetry.csv>" -Format Markdown
```

JSON output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\analyze-telemetry.ps1" -Path "<telemetry.csv>" -Format Json
```

Time-window selection when the file has timestamps:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\analyze-telemetry.ps1" -Path "<telemetry.csv>" -WarmupSeconds 60 -DurationSeconds 300
```

Row-window fallback when timestamps are absent:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\analyze-telemetry.ps1" -Path "<telemetry.csv>" -WarmupRows 100 -MaxRows 1000
```

Add a custom numeric column pattern:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<suite-folder>\scripts\analyze-telemetry.ps1" -Path "<telemetry.csv>" -IncludeColumn "GPU PCIe|VRM"
```

## Exit codes

- `0`: the analyzer produced a valid summary;
- `1`: the input was readable but analysis failed, for example because no
  usable header or data structure could be processed;
- `2`: the input was rejected before analysis, such as a missing file,
  oversized file, unsafe/non-local path, or incompatible window arguments.

Treat a nonzero exit as no valid analysis result. Do not reuse partial stdout as
a completed report.

The analyzer prints a summary; it does not save a report unless the caller redirects standard output.

The default maximum input size is 512 MB and can be changed with
`-MaxInputMegabytes`. When a log is larger, ask the user for a smaller fixed
window instead of reading the entire file. A higher limit is an explicit
memory-use decision, not a tuning decision.

Add `-HideFileName` when sharing a summary that must not expose a source filename. JSON reports then use `FileName: "[hidden]"` and Markdown reports print `File: [hidden]`.

Markdown reports treat filenames, source column names, and warning text as
untrusted display data and place them in dynamic inline-code spans. Control,
bidirectional, zero-width, and invisible formatting characters are removed;
pipes are escaped for tables. Bare URLs, emails, links, images, emphasis, code
markers, and HTML therefore remain text rather than active markup.

## Screenshots and one-off monitoring values

The analyzer script reads compatible CSV/text logs; a monitoring screenshot is not
parsed as a sample set. The Skill may still inspect a user-supplied screenshot from
HWiNFO, Afterburner, RTSS, or a vendor utility as limited single-point evidence.

Before interpreting it, identify:

- monitoring software and version when visible;
- the workload and game scene or application state;
- capture time or the surrounding event;
- active settings, power mode, and AC/battery state;
- whether values are current, maximum, average, or an unknown aggregation;
- polling interval or sampling window when visible.

A screenshot can show that a named temperature, clock, voltage, fan speed, or limit
reason was visible at that moment. It cannot provide P1/P95 statistics, prove a
sustained value, compare two runs fairly, or establish stability. If the screenshot
omits time, workload, or aggregation, ask for one reproducible run and record the
uncertainty. Crop serial numbers and unrelated personal information before sharing.

## Metrics it recognizes

It maps common column names for:

- FPS and frame time;
- PresentMon `msBetweenPresents` as a frame-time source;
- GPU core voltage when exposed, plus core/effective/memory clocks;
- GPU power and temperature;
- GPU hotspot and memory-junction temperature when present;
- GPU fan RPM/percentage;
- CPU package temperature, AMD Tctl/Tdie when exposed, a representative CPU core maximum when named as such, and package power including CPU PPT when present.

For HWiNFO Sensors CSV logs it also:

- reads live or closed files without requiring exclusive access;
- normalizes duplicate sensor names with `[#N]` suffixes;
- recognizes English and complete Chinese header rows, including `日期` and `时间`;
- requires a detected header row to be backed by later numeric sensor data;
- rejects data rows whose field count does not match the header and reports the first bad line;
- parses common localized Date+Time formats and flexible zero-padding, including runs crossing midnight;
- requires GPU metrics to use an explicit GPU-qualified column rather than an ambiguous CPU or system-memory column;
- separates measured values from limits, caps, targets, and other control columns;
- keeps temperature and power columns separate by name and unit hints, so `CPU 封装功耗 [W]` is not treated as a temperature;
- canonicalizes known unit aliases, converts compatible units such as GHz/kHz/Hz to MHz, kW/mW/uW to W, and Fahrenheit/Kelvin to Celsius, and rejects explicit unsupported units;
- refuses to guess between ambiguous unitless roles such as `CPU Package` as temperature/power or `GPU Fan` as RPM/percentage, and reports the ignored column names;
- rejects NaN and Infinity instead of treating them as numeric samples;
- filters implausible values by metric type before summary statistics;
- aborts a metric whose aggregate statistics overflow to a non-finite result;
- reports likely text-encoding corruption or mojibake without automatically remapping sensor names;
- ignores appended HWiNFO metadata after a repeated `Date`/`Time` header or blank separator;
- recognizes common Chinese sensor names such as `GPU 温度`, `GPU 功率`, `GPU 有效频率`, `显存结温`, `CPU 封装` and `CPU 封装功率`;
- recognizes AMD HWiNFO `CPU (Tctl/Tdie)` temperature and `CPU PPT` package power as separate, source-labelled metrics;
- rejects AMD temperature offset and PPT limit columns when selecting measured temperature or package power;
- recognizes `CPU Die (average)` as a distinctly labelled fallback CPU temperature;
- reports matching columns rejected by offset, limit, role, or unit rules when a requested metric has no selected source;
- prefers localized `呈现帧率 (avg)` and English presented-average FPS columns
  over generic FPS columns that may be zero outside a captured application;
- summarizes Presented and Displayed 1% low / 0.1% low FPS when those HWiNFO
  columns exist;
- summarizes Presented 99% high plus fastest 1% and fastest 0.1% frame time,
  and Displayed 1% high and 0.1% high frame time, without confusing low-
  percentile/high-tail directions;
- warns when a known low-FPS sensor column exists in the selected window but has
  no usable values or contains only zeroes.

It prints count, minimum, mean, median, P1, P5, P95, and maximum for each recognized series. Average FPS is not a substitute for frame-time consistency.

HWiNFO low/high percentile fields are aggregate sensor values, not raw frame
series reconstructed by this analyzer. Use their median and steady-window
distribution for context, but do not present a single minimum as a direct
per-frame result. A generic HWiNFO 1% low column that is present but all zero is
reported as unavailable rather than summarized as zero FPS.

Frame-time and FPS percentiles run in opposite directions. For example,
HWiNFO `Frame Time Presented (1%)` is the fastest 1% frame time, not a slow-frame
1% low. The analyzer labels it `fastest 1%`; slow-frame tails remain
`99% high` for Presented and `1% high` / `0.1% high` for Displayed fields.

A requested warm-up or duration window that has no valid rows is an error, not permission to fall back to the beginning of the file. A normal trailing newline is not treated as appended metadata.
Time-based and row-based window parameters cannot be combined. A partially invalid timestamp column is reported, and a fixed time window that would include a row without a parseable timestamp is rejected.

The requested duration starts at the requested warm-up boundary, not at the first sample that happens to fall after it. JSON output includes `RequestedWindow` and the actual sampled `Window`; a requested duration extending past the available telemetry is rejected.

Implausible-value filters are broad data-sanity checks, not safe hardware limits. They reject impossible frame times, negative clocks or fan speeds, unrealistic temperature ranges, and fan percentages outside 0–100.

Markdown table cells escape pipes, HTML delimiters, and line breaks from source column names. JSON preserves the original column names.

When mojibake prevents header detection or sensor recognition, tell the user to re-export the log using UTF-8 with the intended locale. Do not guess a corrupted sensor name or silently map it to a different metric.

## Interpret with the workload

Before treating a summary as a result:

1. confirm the CSV contains the intended baseline/candidate run;
2. confirm the selected time or row window is steady-state, not loading or shutdown;
3. confirm the monitoring interval is the same across rounds;
4. compare the same metric and workload;
5. do not use a sensor the device/tool did not actually expose.

An analyzer summary does not prove stability. It is supporting evidence alongside the fixed workload, artifacts, reboot behavior, and the user's normal-use observations.

If a hotspot or junction-temperature column is absent, report it as unavailable rather than estimating it from another temperature.

When the analyzed window mixes idle, loading, active load, and recovery, say that the summary is preliminary and give one concrete next step: record a fixed workload window, repeat the same window for a candidate run, or provide the missing workload context. Do not end with only a table of aggregate numbers.

When the log belongs to an active experiment, keep the experiment card path with the summary. Compare only the same workload and metric, then append the result and decision to that card instead of creating an unrelated standalone conclusion.
