# Telemetry normalization

Use the normalizer when telemetry comes from different source shapes, when a
source tool needs explicit provenance, or when a structured JSON snapshot must
feed the same analysis and chart path as a CSV record.

The normalizer does not launch monitoring software, install drivers, request
elevation, use the network, or change hardware settings.

## Normalized document

The adapter emits `NormalizedTelemetryVersion: "1.0"` with these major sections:

- `Source`: tool, version, optional device ID, capture time, original filename,
  input SHA-256, input kind, adapter version, and mixed-source state;
- `Sampling`: time-based state, median/minimum/maximum interval, and
  `stable|variable|unknown` consistency;
- `DataQuality`: warning state, series count, missing-value count, and window;
- `Sensors`: sensor name, category, unit, canonical header, and source identity;
- `ChartData`: the validated chart-data document consumed by the SVG renderer;
- `Warnings`: adapter, analyzer, and sampling warnings.

The original private source path is not stored. The original filename and content
hash are retained so a local case can trace the normalized output to its input.

## Normalize a CSV

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\normalize-telemetry.ps1" -Path "<telemetry.csv>" -OutputPath "<normalized.json>" -SourceTool "HWiNFO64" -SourceVersion "8.x" -DeviceId "<local-alias>" -CapturedAt "2026-11-03T12:30:00+08:00"
```

The CSV still passes through the existing analyzer. Existing metric recognition,
unit conversion, implausible-value filters, missing-value handling, windows, and
downsampling remain authoritative.

If source metadata is omitted, normalization continues for compatibility but
records explicit warnings instead of inventing the tool, version, device, or
capture time.

## Sensor snapshot schema

Structured sources should provide an explicit timestamp and sensor metadata for
every sample:

```json
{
  "schemaVersion": "1.0",
  "source": {
    "tool": "Fixture Monitor",
    "version": "1.2",
    "deviceId": "local-alias",
    "capturedAt": "2026-11-03T12:30:00+08:00"
  },
  "samples": [
    {
      "capturedAt": "2026-11-03T12:30:00+08:00",
      "sensors": [
        {
          "name": "GPU Temperature",
          "category": "temperature",
          "unit": "C",
          "value": 61
        },
        {
          "name": "GPU Power",
          "category": "power",
          "unit": "W",
          "value": 120
        }
      ]
    }
  ]
}
```

Allowed sensor categories are `fps`, `frame-time`, `temperature`, `power`,
`clock`, `voltage`, `utilization`, `fan`, `memory`, `throughput`, `latency`, and
`other`.

Rules:

- `source.tool` and `source.version` are required;
- `samples` must be a non-empty array, and every sample's `sensors` must also
  be a non-empty array;
- every sample timestamp must include `Z` or an explicit UTC offset;
- timestamps must not move backwards;
- a sensor requires `name`, `category`, `unit`, and a `value` property; the
  property may be a finite number or explicit `null`, but omitting it is invalid;
- duplicate canonical sensor headers within one sample are rejected;
- the same sensor name with different units is retained as separate series and
  produces a warning;
- per-sensor source overrides are allowed, but differing tool/version/device
  identities produce a mixed-source warning;
- missing sensor values are written as empty fields and remain gaps in chart
  data;
- sample timestamps are converted to UTC only for the shared chart axis; the
  original source capture timestamp remains in `Source.CapturedAt`.

Run normalization:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\normalize-telemetry.ps1" -Path "<snapshot.json>" -OutputPath "<normalized.json>"
```

`-InputFormat Auto` treats `.json` as `SensorSnapshot` and other files as CSV.
Use `-InputFormat Csv|SensorSnapshot` when the extension is ambiguous.

## Render normalized JSON

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\render-telemetry-chart.ps1" -Path "<normalized.json>" -OutputPath "<new-chart.svg>"
```

The renderer auto-detects `.json`, or accepts `-InputFormat NormalizedJson`.
Normalized JSON is already windowed and downsampled, so CSV-only options such as
`-WarmupSeconds`, `-WarmupRows`, `-MaxRows`, `-Delimiter`, and `-MaxPoints` are
rejected with exit code `2` instead of being silently ignored.

The renderer also requires the complete normalized document. A JSON object with
only version fields and `ChartData` is not sufficient: `Source`, `Sampling`,
`Sensors`, `DataQuality`, `Warnings`, valid provenance fields, and a non-empty
chart series array must all be present.

## Warnings and boundaries

- A stable sampling interval is not proof that sensors are synchronized.
- Mixed source identities are flagged; their values are never merged into one
  series when canonical headers differ.
- Row-based input has an unknown sampling interval.
- Offline/cloud-placeholder files are rejected before reading so normalization
  does not trigger cloud hydration.
- A normalized document is evidence metadata, not stability proof.
- Missing sampled values produce `DataQuality.Status: partial`; warnings without
  missing values use `warnings`, and only a complete clean document uses
  `complete`.
- Register the original input, normalized document, and rendered chart as
  separate local case evidence when traceability matters.
- Do not place private device IDs or raw telemetry in a public report without
  review and redaction.

## Exit codes

- `0`: normalization produced a valid document;
- `1`: readable input could not produce a usable analyzed series;
- `2`: invalid paths, schema, metadata, sampling order, output overwrite, or
  unsupported input shape.
