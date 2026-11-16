import assert from "node:assert/strict";
import {
  analysisSummary,
  verifiedBlocks,
} from "../skills/pc-hardware-workbench/telemetry-broker.mjs";

const buffer = Buffer.from(
  [
    "timestamp,gpu_temp_c,gpu_power_w,effective_clock_mhz,perfcap",
    "2026-11-16T10:00:00+08:00,67,142,2415,None",
    "2026-11-16T10:00:01+08:00,68,146,2420,Power",
    "2026-11-16T10:00:02+08:00,69,153,2430,Power",
    "2026-11-16T10:00:03+08:00,70,161,2440,None",
  ].join("\n"),
  "utf8",
);
const summary = analysisSummary(
  {
    AnalyzerVersion: "test",
    HeaderLine: 1,
    AnalyzedRows: 4,
    TotalRows: 4,
    Window: "time 0s to 3s",
    SampledSpanSeconds: 3,
    Sampling: {
      TimeBased: true,
      IntervalSecondsMedian: 1,
      IntervalSecondsMinimum: 1,
      IntervalSecondsMaximum: 1,
      Consistency: "stable",
    },
    Columns: [
      "timestamp",
      "gpu_temp_c",
      "gpu_power_w",
      "effective_clock_mhz",
      "perfcap",
    ],
    Warnings: [],
    Metrics: [
      {
        Metric: "gpu_temp_c",
        SourceColumn: "gpu_temp_c",
        Samples: 4,
        Min: 67,
        Mean: 68.5,
        Median: 68.5,
        P95: 70,
        Max: 70,
        Unit: "",
      },
    ],
  },
  buffer,
);
assert.equal(summary.sampled_span_seconds, 3);
assert.deepEqual(summary.categorical_columns, [
  {
    column: "perfcap",
    values: [
      { value: "None", count: 2 },
      { value: "Power", count: 2 },
    ],
  },
]);

const artifact = {
  id: "artifact-test",
  kind: "chart",
  mime: "image/svg+xml",
  title: "Telemetry overview",
  relative_path: "task-test/artifact-test.svg",
  sha256: "a".repeat(64),
  source_evidence_ids: ["attachment-test"],
  created_at: "2026-11-16T00:00:00.000Z",
  safeToEmbed: true,
  size: 100,
};
const blocks = verifiedBlocks(summary, artifact);
assert.ok(
  blocks.some(
    (block) =>
      block.id === "telemetry-table" &&
      block.type === "table" &&
      block.columns.length === 6,
  ),
);
assert.ok(
  blocks.some(
    (block) =>
      block.id === "telemetry-categories" &&
      block.rows.some(
        (row) => row[0] === "perfcap" && row[1] === "Power" && row[2] === "2",
      ),
  ),
);
console.log("Verified telemetry blocks: PASS");
