import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  appendFileSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  analysisSummary,
  TelemetryBroker,
  verifiedBlocks,
} from "../telemetry-broker.mjs";

const skillRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const tempRoot = mkdtempSync(join(tmpdir(), "pcwb-broker-"));
const attachmentRoot = join(tempRoot, "attachments");
const artifactRoot = join(tempRoot, "artifacts");
const isAttachmentIntegrityRejection = (error) =>
  error.code === "attachment_not_found" ||
  (
    error.code === "attachment_hash_mismatch" &&
    /哈希|完整性|停止分析/u.test(error.message ?? "")
  );
mkdirSync(attachmentRoot, { recursive: true });
mkdirSync(artifactRoot, { recursive: true });

try {
  const csv = [
    '"Date","Time","FPS","Frame Time Presented (avg) [ms]","GPU Effective Clock [MHz]","GPU Core Voltage [V]","GPU Memory Clock [MHz]","GPU Power [W]","GPU Temperature [C]","GPU Hot Spot [C]","GPU Memory Junction [C]","CPU Package [C]","CPU Package Power [W]"',
    '"2026-11-03","12:00:00","60","16.7","2200","0.780","1750","110","55","63","58","58","35"',
    '"2026-11-03","12:00:01","72","13.9","2450","0.835","1750","145","61","69","65","65","48"',
    '"2026-11-03","12:00:02","75","13.3","2510","0.845","1750","152","64","72","68","67","52"',
  ].join("\n");
  const csvPath = join(attachmentRoot, "telemetry.csv");
  writeFileSync(csvPath, csv, "utf8");
  const csvBytes = readFileSync(csvPath);
  const attachment = {
    id: "attachment-broker-pack",
    original_name: "telemetry.csv",
    sha256: createHash("sha256").update(csvBytes).digest("hex"),
    local_path: csvPath,
  };
  const broker = new TelemetryBroker({
    attachmentRoot,
    artifactRoot,
    scriptsDir: join(skillRoot, "scripts"),
    timeoutMs: 60_000,
  });

  const escapeRoot = join(tempRoot, "escape-scope");
  const escapeAttachmentRoot = join(escapeRoot, "attachments");
  const escapeArtifactRoot = join(escapeRoot, "artifacts");
  const outsideRoot = join(escapeRoot, "outside");
  mkdirSync(escapeAttachmentRoot, { recursive: true });
  mkdirSync(escapeArtifactRoot, { recursive: true });
  mkdirSync(outsideRoot, { recursive: true });
  const outsideCsvPath = join(outsideRoot, "outside.csv");
  writeFileSync(outsideCsvPath, "Time,FPS\n0,60\n", "utf8");
  const junctionPath = join(escapeAttachmentRoot, "outside-link");
  symlinkSync(
    outsideRoot,
    junctionPath,
    process.platform === "win32" ? "junction" : "dir",
  );
  const outsideBytes = readFileSync(outsideCsvPath);
  const escapeBroker = new TelemetryBroker({
    attachmentRoot: escapeAttachmentRoot,
    artifactRoot: escapeArtifactRoot,
    scriptsDir: join(skillRoot, "scripts"),
    timeoutMs: 60_000,
  });
  assert.throws(
    () =>
      escapeBroker.validateAttachment({
        id: "attachment-outside-junction",
        original_name: "outside.csv",
        sha256: createHash("sha256").update(outsideBytes).digest("hex"),
        local_path: join(junctionPath, "outside.csv"),
      }),
    (error) =>
      ["attachment_not_found", "unsafe_attachment_path"].includes(error.code),
    "attachment validation must reject links and junctions that escape the root",
  );

  assert.equal(
    broker.findCached({
      taskId: "task-broker-preauth",
      attachment: {
        ...attachment,
        id: "attachment-preauth-hash",
        sha256: "f".repeat(64),
      },
      window: {},
    }),
    null,
    "cache lookup before permission must use metadata without reading and hashing file content",
  );

  const categoricalCsv = [
    "Date,Time,FPS,Perf Cap",
    "2026-11-03,12:00:00,60,Pwr",
    "2026-11-03,12:00:01,61,Pwr",
    "2026-11-03,12:00:02,40,Therm",
    "2026-11-03,12:00:03,30,Idle",
  ].join("\n");
  const categoricalSummary = analysisSummary(
    {
      HeaderLine: 1,
      TotalRows: 4,
      AnalyzedRows: 2,
      AnalyzedRowStart: 0,
      AnalyzedRowEnd: 1,
      CategoricalColumns: [
        {
          column: "Perf Cap",
          values: [{ value: "Pwr", count: 2 }],
        },
      ],
      Window: "time 0s to 1s",
      Sampling: {
        TimeBased: true,
        IntervalSecondsMedian: 1,
        Consistency: "stable",
      },
      Metrics: [
        {
          Metric: "Frame rate (FPS)",
          SourceColumn: "FPS",
          Unit: "FPS",
          Samples: 2,
          Min: 60,
          Mean: 60.5,
          Max: 61,
        },
      ],
      Warnings: [],
    },
    Buffer.from(categoricalCsv, "utf8"),
  );
  assert.deepEqual(
    categoricalSummary.categorical_columns,
    [
      {
        column: "Perf Cap",
        values: [{ value: "Pwr", count: 2 }],
      },
    ],
    "categorical statistics must use only the analyzed row window",
  );
  const analyzerSelectedCategorical = analysisSummary(
    {
      HeaderLine: 1,
      TotalRows: 4,
      AnalyzedRows: 1,
      AnalyzedRowStart: 2,
      AnalyzedRowEnd: 2,
      CategoricalColumns: [
        {
          column: "Perf Cap",
          values: [{ value: "Thermal", count: 1 }],
        },
      ],
      Window: "time 2s to 2s",
      Sampling: {
        TimeBased: true,
        IntervalSecondsMedian: 1,
        Consistency: "stable",
      },
      Metrics: [
        {
          Metric: "Frame rate (FPS)",
          SourceColumn: "FPS",
          Unit: "FPS",
          Samples: 1,
          Min: 60,
          Mean: 60,
          Max: 60,
        },
      ],
      Warnings: [],
    },
    Buffer.from(
      [
        "Date,Time,FPS,Perf Cap",
        "2026-11-03,12:00:00,60,Idle",
        "2026-11-03,12:00:01,61,Missing timestamp",
        "2026-11-03,12:00:02,60,Idle",
      ].join("\n"),
      "utf8",
    ),
  );
  assert.deepEqual(
    analyzerSelectedCategorical.categorical_columns,
    [
      {
        column: "Perf Cap",
        values: [{ value: "Thermal", count: 1 }],
      },
    ],
    "the broker must trust the analyzer's selectedRows categorical summary",
  );

  const missingValueBlocks = verifiedBlocks(
    {
      analyzed_rows: null,
      sampled_span_seconds: null,
      sampling: {
        Consistency: "unknown",
        IntervalSecondsMedian: null,
      },
      warnings: [],
      categorical_columns: [],
      metrics: [
        {
          metric: "GPU temperature (C)",
          source_column: "GPU Temperature [C]",
          unit: "C",
          samples: null,
          min: null,
          mean: null,
          max: null,
        },
      ],
    },
    [{ id: "artifact-missing-values", title: "Missing values" }],
  );
  const missingWindow = missingValueBlocks.find(
    (block) => block.id === "telemetry-window",
  );
  const missingTable = missingValueBlocks.find(
    (block) => block.id === "telemetry-table",
  );
  assert.doesNotMatch(missingWindow.text, /0 秒|0 分钟|null/u);
  assert.match(missingWindow.text, /未提供/u);
  assert.deepEqual(missingTable.rows[0].slice(1, 5), ["", "", "", ""]);

  const changingCsv = "Time,FPS\n0,60\n1,61\n";
  const changingCsvPath = join(attachmentRoot, "changing.csv");
  writeFileSync(changingCsvPath, changingCsv, "utf8");
  const changingAttachment = {
    id: "attachment-changing-during-analysis",
    original_name: "changing.csv",
    sha256: createHash("sha256").update(changingCsv).digest("hex"),
    local_path: changingCsvPath,
  };
  const changingChartPath = join(tempRoot, "changing-chart.svg");
  writeFileSync(
    changingChartPath,
    '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"></svg>',
    "utf8",
  );
  const changingBroker = new TelemetryBroker({
    attachmentRoot,
    artifactRoot,
    scriptsDir: join(skillRoot, "scripts"),
    timeoutMs: 60_000,
  });
  changingBroker.runPowerShell = async () => {
    writeFileSync(changingCsvPath, "Time,FPS\n0,1\n1,1\n", "utf8");
    return {
      stdout: JSON.stringify({
        AnalyzerVersion: "test",
        SourceSha256: changingAttachment.sha256,
        SourceBytes: Buffer.byteLength(changingCsv),
        HeaderLine: 1,
        AnalyzedRows: 2,
        TotalRows: 2,
        AnalyzedRowStart: 0,
        AnalyzedRowEnd: 1,
        Window: "time 0s to 1s",
        Sampling: {
          TimeBased: true,
          IntervalSecondsMedian: 1,
          Consistency: "stable",
        },
        Metrics: [
          {
            Metric: "FPS",
            SourceColumn: "FPS",
            Samples: 2,
            Min: 60,
            Mean: 60.5,
            Max: 61,
            Unit: "FPS",
          },
        ],
        Warnings: [],
      }),
      stderr: "",
    };
  };
  changingBroker.buildChartPack = async () => ({
    charts: [
      {
        sourcePath: changingChartPath,
        title: "Changing source",
        safe: true,
      },
    ],
    warnings: [],
    skipped: [],
  });
  await assert.rejects(
    () =>
      changingBroker.analyze({
        taskId: "task-broker-changing",
        attachment: changingAttachment,
        window: {},
      }),
    isAttachmentIntegrityRejection,
    "analysis must reject an attachment that changes or disappears after the analyzer reopens the path",
  );

  const chartChangingCsv = "Time,FPS\n0,60\n1,61\n";
  const chartChangingCsvPath = join(
    attachmentRoot,
    "chart-changing.csv",
  );
  writeFileSync(chartChangingCsvPath, chartChangingCsv, "utf8");
  const chartChangingAttachment = {
    id: "attachment-changing-during-chart-pack",
    original_name: "chart-changing.csv",
    sha256: createHash("sha256").update(chartChangingCsv).digest("hex"),
    local_path: chartChangingCsvPath,
  };
  const chartChangingBroker = new TelemetryBroker({
    attachmentRoot,
    artifactRoot,
    scriptsDir: join(skillRoot, "scripts"),
    timeoutMs: 60_000,
  });
  chartChangingBroker.runPowerShell = async () => ({
    stdout: JSON.stringify({
      AnalyzerVersion: "test",
      SourceSha256: chartChangingAttachment.sha256,
      SourceBytes: Buffer.byteLength(chartChangingCsv),
      HeaderLine: 1,
      AnalyzedRows: 2,
      TotalRows: 2,
      AnalyzedRowStart: 0,
      AnalyzedRowEnd: 1,
      Window: "time 0s to 1s",
      Sampling: {
        TimeBased: true,
        IntervalSecondsMedian: 1,
        Consistency: "stable",
      },
      Metrics: [
        {
          Metric: "FPS",
          SourceColumn: "FPS",
          Samples: 2,
          Min: 60,
          Mean: 60.5,
          Max: 61,
          Unit: "FPS",
        },
      ],
      Warnings: [],
    }),
    stderr: "",
  });
  chartChangingBroker.buildChartPack = async () => {
    writeFileSync(chartChangingCsvPath, "Time,FPS\n0,1\n1,1\n", "utf8");
    return {
      charts: [
        {
          sourcePath: changingChartPath,
          title: "Changing chart source",
          safe: true,
        },
      ],
      warnings: [],
      skipped: [],
    };
  };
  await assert.rejects(
    () =>
      chartChangingBroker.analyze({
        taskId: "task-broker-chart-changing",
        attachment: chartChangingAttachment,
        window: {},
        preset: "FirstPass",
      }),
    isAttachmentIntegrityRejection,
    "analysis must reject an attachment that changes or disappears after chart-pack rendering",
  );

  // Keep the long-lived pipeline scenario on a fresh fixture root so earlier
  // mutation and escape-path cases cannot change its filesystem preconditions.
  {
    const attachmentRoot = join(tempRoot, "pipeline-attachments");
    const artifactRoot = join(tempRoot, "pipeline-artifacts");
    mkdirSync(attachmentRoot, { recursive: true });
    mkdirSync(artifactRoot, { recursive: true });
    const csvPath = join(attachmentRoot, "telemetry.csv");
    writeFileSync(csvPath, csv, "utf8");
    const csvBytes = readFileSync(csvPath);
    const attachment = {
      id: "attachment-broker-pack",
      original_name: "telemetry.csv",
      sha256: createHash("sha256").update(csvBytes).digest("hex"),
      local_path: csvPath,
    };
    const broker = new TelemetryBroker({
      attachmentRoot,
      artifactRoot,
      scriptsDir: join(skillRoot, "scripts"),
      timeoutMs: 60_000,
    });
  const originalRunPowerShell = broker.runPowerShell.bind(broker);
  const chartPipelineCalls = [];
  broker.runPowerShell = async (scriptPath, args) => {
    chartPipelineCalls.push({ scriptPath, args: [...args] });
    return originalRunPowerShell(scriptPath, args);
  };
  const first = await broker.analyze({
    taskId: "task-broker-pack",
    attachment,
    window: {},
    preset: "FirstPass",
  });
  broker.runPowerShell = originalRunPowerShell;
  assert.equal(
    chartPipelineCalls.filter((call) =>
      /analyze-telemetry\.ps1$/u.test(call.scriptPath)
    ).length,
    1,
    "chart analysis must invoke the authoritative analyzer exactly once",
  );
  const chartPackCall = chartPipelineCalls.find((call) =>
    /render-telemetry-pack\.ps1$/u.test(call.scriptPath),
  );
  assert.ok(chartPackCall, "chart analysis must invoke the chart pack renderer");
  assert.ok(
    chartPackCall.args.includes("-ChartDataPath"),
    "chart pack renderer must consume the analyzer-produced ChartData",
  );
  assert.equal(
    first.analysis.warnings.some((warning) =>
      warning.startsWith("图表包降级为单图：")
    ),
    false,
    "the chart pack must not downgrade after consuming analyzer ChartData",
  );
  assert.equal(first.artifact.kind, "chart");
  assert.equal(first.artifacts.length, 4);
  assert.equal(
    first.analysis.analyzer_passes,
    1,
    "the regular chart path must report one authoritative analyzer pass",
  );
  assert.equal(first.analysis.analyzer_pass_reason, "standard");
  assert.equal(first.analysis.source_sha256, attachment.sha256);
  assert.equal(first.analysis.source_bytes, csvBytes.length);
  assert.equal(new Set(first.artifacts.map((item) => item.id)).size, 4);
  assert.equal(
    first.blocks.filter((block) => block.type === "chart").length,
    4,
  );
  assert.equal(
    first.blocks.filter((block) => block.type === "artifact-download").length,
    4,
  );
  assert.ok(first.blocks.length <= 12);
  for (const artifact of first.artifacts) {
    const path = join(artifactRoot, artifact.relative_path.replaceAll("/", "\\"));
    const svg = readFileSync(path, "utf8");
    assert.match(svg, /<svg(?:\s|>)/u);
    assert.doesNotMatch(svg, /<script\b|\bhref\s*=\s*["']https?:/iu);
  }

  const bindingTaskId = "task-broker-chart-binding";
  const bindingTaskDirectory = join(artifactRoot, bindingTaskId);
  mkdirSync(bindingTaskDirectory, { recursive: true });
  await assert.rejects(
    () =>
      broker.buildChartPack({
        taskDirectory: bindingTaskDirectory,
        filePath: csvPath,
        parsed: {
          Metrics: [
            {
              Metric: "Frame rate (FPS)",
              SourceColumn: "FPS",
              Unit: "FPS",
            },
          ],
          ChartData: {
            ChartDataVersion: "1.0",
            SourceSha256: "0".repeat(64),
            SourceBytes: csvBytes.length,
            Window: "time 0s to 2s",
            Warnings: [],
            Series: [
              {
                Metric: "Frame rate (FPS)",
                SourceColumn: "FPS",
                Unit: "FPS",
                Points: [{ T: 0, V: 60 }],
              },
            ],
          },
        },
        window: { warmup: null, duration: null },
        actualHash: attachment.sha256,
        actualBytes: csvBytes.length,
        preset: "FirstPass",
      }),
    (error) => error.code === "evidence_binding_mismatch",
    "chart-pack generation must reject ChartData from another source",
  );

  const summaryCalls = [];
  broker.runPowerShell = async (scriptPath, args) => {
    summaryCalls.push({ scriptPath, args: [...args] });
    return originalRunPowerShell(scriptPath, args);
  };
  const summaryOnly = await broker.analyze({
    taskId: "task-broker-summary",
    attachment,
    window: {},
    preset: null,
  });
  broker.runPowerShell = originalRunPowerShell;
  const summaryAnalyzerCalls = summaryCalls.filter((call) =>
    /analyze-telemetry\.ps1$/u.test(call.scriptPath)
  );
  assert.equal(summaryAnalyzerCalls.length, 1);
  assert.equal(
    summaryAnalyzerCalls[0].args.includes("-IncludeChartData"),
    false,
    "summary-only analysis must not request chart generation",
  );
  assert.equal(
    summaryCalls.some((call) => /render-telemetry-pack\.ps1$/u.test(call.scriptPath)),
    false,
    "summary-only analysis must not invoke chart-pack generation",
  );
  assert.equal(summaryOnly.chart_preset, null);
  assert.equal(summaryOnly.artifact, null);
  assert.deepEqual(summaryOnly.artifacts, []);
  assert.deepEqual(summaryOnly.blocks, []);
  assert.equal(summaryOnly.analysis.analyzer_passes, 1);
  assert.equal(summaryOnly.analysis.analyzer_pass_reason, "standard");
  const summaryPanel = broker.applyVerifiedResult(
    {
      schema_version: "1.2",
      status: "ready",
      artifact_refs: [],
    },
    summaryOnly,
    { taskId: "task-broker-summary" },
  );
  assert.deepEqual(summaryPanel.artifact_refs, []);
  assert.deepEqual(summaryPanel.blocks, []);

  const bindingResponseBase = {
    AnalyzerVersion: "test-binding",
    SourceSha256: attachment.sha256,
    SourceBytes: csvBytes.length,
    HeaderLine: 1,
    AnalyzedRows: 2,
    TotalRows: 2,
    AnalyzedRowStart: 0,
    AnalyzedRowEnd: 1,
    Window: "time 0s to 1s",
    Sampling: {
      TimeBased: true,
      IntervalSecondsMedian: 1,
      Consistency: "stable",
    },
    Metrics: [
      {
        Metric: "Frame rate (FPS)",
        SourceColumn: "FPS",
        Unit: "FPS",
        Samples: 2,
        Min: 60,
        Mean: 60.5,
        Max: 61,
      },
    ],
    Warnings: [],
  };
  for (const [label, mutate] of [
    [
      "wrong hash",
      (response) => {
        response.SourceSha256 = "f".repeat(64);
      },
    ],
    [
      "missing bytes",
      (response) => {
        delete response.SourceBytes;
      },
    ],
  ]) {
    const invalidBindingBroker = new TelemetryBroker({
      attachmentRoot,
      artifactRoot,
      scriptsDir: join(skillRoot, "scripts"),
      timeoutMs: 60_000,
    });
    const response = structuredClone(bindingResponseBase);
    mutate(response);
    invalidBindingBroker.runPowerShell = async () => ({
      stdout: JSON.stringify(response),
      stderr: "",
    });
    await assert.rejects(
      () =>
        invalidBindingBroker.analyze({
          taskId: `task-broker-invalid-binding-${label.replaceAll(" ", "-")}`,
          attachment: {
            ...attachment,
            id: `attachment-invalid-binding-${label.replaceAll(" ", "-")}`,
          },
          window: {},
          preset: null,
        }),
      (error) => error.code === "analysis_source_binding_mismatch",
      `summary-only analysis must reject analyzer binding with ${label}`,
    );
  }

  const inconsistentChartBindingBroker = new TelemetryBroker({
    attachmentRoot,
    artifactRoot,
    scriptsDir: join(skillRoot, "scripts"),
    timeoutMs: 60_000,
  });
  const inconsistentChartResponse = structuredClone(bindingResponseBase);
  inconsistentChartResponse.ChartData = {
    ChartDataVersion: "1.0",
    SourceSha256: "e".repeat(64),
    SourceBytes: csvBytes.length,
    Window: "time 0s to 1s",
    Warnings: [],
    Series: [
      {
        Metric: "Frame rate (FPS)",
        SourceColumn: "FPS",
        Unit: "FPS",
        Points: [{ T: 0, V: 60 }],
      },
    ],
  };
  inconsistentChartBindingBroker.runPowerShell = async () => ({
    stdout: JSON.stringify(inconsistentChartResponse),
    stderr: "",
  });
  await assert.rejects(
    () =>
      inconsistentChartBindingBroker.analyze({
        taskId: "task-broker-inconsistent-chart-binding",
        attachment: {
          ...attachment,
          id: "attachment-inconsistent-chart-binding",
        },
        window: {},
        preset: "FirstPass",
      }),
    (error) => error.code === "analysis_source_binding_mismatch",
    "top-level and nested ChartData source bindings must agree",
  );

  const fallbackCalls = [];
  let fallbackPass = 0;
  const fallbackBroker = new TelemetryBroker({
    attachmentRoot,
    artifactRoot,
    scriptsDir: join(skillRoot, "scripts"),
    timeoutMs: 60_000,
  });
  fallbackBroker.runPowerShell = async (scriptPath, args) => {
    fallbackCalls.push({ scriptPath, args: [...args] });
    fallbackPass += 1;
    const response = {
      AnalyzerVersion: "test-fallback",
      SourceSha256: attachment.sha256,
      SourceBytes: csvBytes.length,
      HeaderLine: 1,
      AnalyzedRows: 2,
      TotalRows: 2,
      AnalyzedRowStart: 0,
      AnalyzedRowEnd: 1,
      Window: "time 0s to 1s",
      Sampling: {
        TimeBased: true,
        IntervalSecondsMedian: 1,
        Consistency: "stable",
      },
      Metrics: [],
      CandidateColumnPattern: "^(FPS)$",
      Warnings: [],
    };
    if (fallbackPass === 2) {
      response.Metrics = [
        {
          Metric: "Frame rate (FPS)",
          SourceColumn: "FPS",
          Unit: "FPS",
          Samples: 2,
          Min: 60,
          Mean: 60.5,
          Max: 61,
        },
      ];
      response.CandidateColumnPattern = null;
    }
    return { stdout: JSON.stringify(response), stderr: "" };
  };
  fallbackBroker.buildChartPack = async () => {
    throw new Error("summary-only fallback must not build a chart pack");
  };
  const fallbackSummary = await fallbackBroker.analyze({
    taskId: "task-broker-fallback",
    attachment: {
      ...attachment,
      id: "attachment-broker-fallback",
    },
    window: {},
    preset: null,
  });
  assert.equal(fallbackPass, 2);
  assert.equal(
    fallbackCalls.filter((call) => /analyze-telemetry\.ps1$/u.test(call.scriptPath))
      .length,
    2,
    "the special candidate-column fallback must report two analyzer passes",
  );
  assert.equal(fallbackSummary.analysis.analyzer_passes, 2);
  assert.equal(
    fallbackSummary.analysis.analyzer_pass_reason,
    "candidate_column_retry",
  );
  assert.equal(
    fallbackSummary.analysis.warnings.some((warning) =>
      /第二次|候选列|fallback/iu.test(warning)
    ),
    true,
    "the candidate-column fallback must be explicit in analysis warnings",
  );

  assert.equal(
    broker.getArtifact(first.artifact.id, { taskId: "task-other-owner" }),
    null,
    "artifact lookup must reject a task-owner mismatch",
  );
  assert.throws(
    () =>
      broker.applyVerifiedResult(
        {},
        {
          artifact: first.artifact,
          artifacts: first.artifacts,
          analysis: first.analysis,
        },
        { taskId: "task-other-owner" },
      ),
    (error) => error.code === "unverified_artifact",
    "panel result binding must reject artifacts from another task",
  );

  const second = await broker.analyze({
    taskId: "task-broker-pack",
    attachment,
    window: {},
    preset: "FirstPass",
  });
  assert.equal(second.cache_hit, true);
  assert.equal(second.artifacts.length, 4);
  const gpuPreset = await broker.analyze({
    taskId: "task-broker-pack",
    attachment,
    window: {},
    preset: "GpuTuning",
  });
  assert.equal(gpuPreset.cache_hit, false);
  assert.equal(gpuPreset.chart_preset, "GpuTuning");
  assert.equal(gpuPreset.artifacts.length, 5);

  const firstArtifactPath = join(
    artifactRoot,
    first.artifact.relative_path.replaceAll("/", "\\"),
  );
  appendFileSync(firstArtifactPath, "\n<!--tampered-->\n", "utf8");
  assert.equal(
    broker.getArtifact(first.artifact.id, { taskId: "task-broker-pack" }),
    null,
    "artifact lookup must revalidate content hash before use",
  );

  const unsafeArtifactId = "artifact-unsafe-svg-test";
  const unsafeArtifactPath = join(
    artifactRoot,
    "task-broker-pack",
    `${unsafeArtifactId}.svg`,
  );
  const unsafeSvg = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<svg xmlns="http://www.w3.org/2000/svg">',
    "<style>@import url(https://example.invalid/evil.css);</style>",
    "</svg>",
  ].join("\n");
  writeFileSync(unsafeArtifactPath, unsafeSvg, "utf8");
  const index = broker.loadIndex();
  const unsafeBytes = readFileSync(unsafeArtifactPath);
  index.artifacts.push({
    id: unsafeArtifactId,
    kind: "chart",
    mime: "image/svg+xml",
    title: "Unsafe SVG",
    relative_path: `task-broker-pack/${unsafeArtifactId}.svg`,
    sha256: createHash("sha256").update(unsafeBytes).digest("hex"),
    source_evidence_ids: [attachment.id],
    created_at: new Date().toISOString(),
    safeToEmbed: true,
    size: unsafeBytes.length,
    cache_key: "unsafe-test",
    task_id: "task-broker-pack",
    source_attachment_id: attachment.id,
    absolute_path: unsafeArtifactPath,
    analysis: first.analysis,
    pack_id: "pack-unsafe",
    pack_size: 1,
    pack_index: 0,
  });
  broker.saveIndex(index);
  assert.equal(
    broker.getArtifact(unsafeArtifactId, { taskId: "task-broker-pack" }),
    null,
    "artifact lookup must reject externally loaded SVG content",
  );
  console.log("Telemetry broker chart-pack regression: PASS");
  }
} finally {
  rmSync(tempRoot, { recursive: true, force: true });
}
