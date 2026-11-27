import { spawn } from "node:child_process";
import {
  closeSync,
  constants,
  copyFileSync,
  existsSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import {
  extname,
  isAbsolute,
  relative,
  resolve,
} from "node:path";

const MAX_CSV_BYTES = 8 * 1024 * 1024;
const MAX_SCRIPT_OUTPUT_BYTES = 4 * 1024 * 1024;
const MAX_ARTIFACT_BYTES = 5 * 1024 * 1024;
const MAX_CHART_ARTIFACTS = 6;
const MAX_WINDOW_SECONDS = 24 * 60 * 60;
const ANALYZER_CACHE_VERSION = "1.3.2-pack1";

export class TelemetryBrokerError extends Error {
  constructor(code, message, { statusCode = 422, details = [] } = {}) {
    super(message);
    this.name = "TelemetryBrokerError";
    this.code = code;
    this.statusCode = statusCode;
    this.details = details;
  }
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function normalizeWindowValue(value, name) {
  if (value === null || value === undefined || value === "") {
    return null;
  }
  const number = Number(value);
  if (
    !Number.isInteger(number) ||
    number < 0 ||
    number > MAX_WINDOW_SECONDS ||
    (name === "duration_seconds" && number === 0)
  ) {
    throw new TelemetryBrokerError(
      "invalid_window",
      `${name} 必须是 0 到 ${MAX_WINDOW_SECONDS} 之间的整数秒`,
      { statusCode: 400 },
    );
  }
  return number;
}

function normalizeWindow(input = {}) {
  const warmup = normalizeWindowValue(input.warmup_seconds, "warmup_seconds");
  const duration = normalizeWindowValue(input.duration_seconds, "duration_seconds");
  if (duration !== null && warmup === null) {
    throw new TelemetryBrokerError(
      "invalid_window",
      "指定 duration_seconds 时还需要 warmup_seconds",
      { statusCode: 400 },
    );
  }
  return { warmup, duration };
}

function normalizeChartPreset(value) {
  const preset = String(value ?? "FirstPass");
  if (!["FirstPass", "GpuTuning", "CpuTuning"].includes(preset)) {
    throw new TelemetryBrokerError(
      "invalid_chart_preset",
      "图表包 Preset 必须是 FirstPass、GpuTuning 或 CpuTuning",
      { statusCode: 400 },
    );
  }
  return preset;
}

function windowSignature(window) {
  if (window.warmup === null && window.duration === null) {
    return "all";
  }
  return `warmup-${window.warmup}-duration-${window.duration}`;
}

function isInside(root, filePath) {
  const candidate = relative(resolve(root), resolve(filePath));
  return candidate !== "" && !candidate.startsWith("..") && !isAbsolute(candidate);
}

function resolveControlledFile(root, filePath) {
  const resolvedRoot = resolve(root);
  const resolvedPath = resolve(filePath);
  if (!isInside(resolvedRoot, resolvedPath) || !existsSync(resolvedPath)) {
    throw new TelemetryBrokerError(
      "attachment_not_found",
      "文件不在受控的本地证据目录中",
      { statusCode: 404 },
    );
  }
  const realRoot = realpathSync.native(resolvedRoot);
  const realPath = realpathSync.native(resolvedPath);
  if (!isInside(realRoot, realPath)) {
    throw new TelemetryBrokerError(
      "unsafe_attachment_path",
      "文件真实路径越过了受控目录边界",
      { statusCode: 409 },
    );
  }
  const relativePath = relative(resolvedRoot, resolvedPath);
  let cursor = resolvedRoot;
  for (const segment of relativePath.split(/[\\/]+/u).filter(Boolean)) {
    cursor = resolve(cursor, segment);
    const stat = lstatSync(cursor);
    if (stat.isSymbolicLink()) {
      throw new TelemetryBrokerError(
        "unsafe_attachment_path",
        "附件路径包含符号链接、Junction 或重解析点",
        { statusCode: 409 },
      );
    }
  }
  const finalStat = lstatSync(realPath);
  if (!finalStat.isFile()) {
    throw new TelemetryBrokerError(
      "attachment_not_found",
      "附件路径不是普通文件",
      { statusCode: 404 },
    );
  }
  return { filePath: realPath, stat: finalStat };
}

function readControlledFile(root, filePath) {
  const reference = resolveControlledFile(root, filePath);
  const noFollow = process.platform === "win32"
    ? 0
    : constants.O_NOFOLLOW ?? 0;
  const descriptor = openSync(reference.filePath, constants.O_RDONLY | noFollow);
  try {
    const openedStat = fstatSync(descriptor);
    if (!openedStat.isFile()) {
      throw new TelemetryBrokerError(
        "attachment_not_found",
        "文件路径不是普通文件",
        { statusCode: 404 },
      );
    }
    const buffer = readFileSync(descriptor);
    return {
      ...reference,
      stat: openedStat,
      buffer,
    };
  } finally {
    closeSync(descriptor);
  }
}

function formatNumber(value) {
  if (value === null || value === undefined || value === "") {
    return "";
  }
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return "";
  }
  return Number.isInteger(number)
    ? String(number)
    : number.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function formatDuration(seconds) {
  if (seconds === null || seconds === undefined || seconds === "") {
    return "";
  }
  const value = Number(seconds);
  if (!Number.isFinite(value)) {
    return "";
  }
  return value >= 60
    ? `${formatNumber(value / 60)} 分钟`
    : `${formatNumber(value)} 秒`;
}

function metricRange(metric) {
  const minimum = formatNumber(metric.Min);
  const maximum = formatNumber(metric.Max);
  return minimum === maximum ? minimum : `${minimum}–${maximum}`;
}

function metricLabel(metric) {
  const source = String(metric.SourceColumn || metric.Metric || "数值列");
  const aliases = [
    [/gpu.*temp|temperature/i, "显卡温度"],
    [/gpu.*power|power/i, "显卡功耗"],
    [/effective.*clock|effective/i, "显卡有效频率"],
    [/gpu.*clock|core clock/i, "GPU 核心频率"],
    [/fps|frame rate/i, "游戏帧率"],
    [/frame time/i, "帧时间"],
    [/gpu.*fan|fan.*rpm|rpm/i, "显卡风扇转速"],
  ];
  const alias = aliases.find(([pattern]) => pattern.test(source))?.[1];
  return alias || metric.Metric || source;
}

function metricPriority(label) {
  return (
    {
      游戏帧率: 0,
      显卡温度: 1,
      显卡有效频率: 2,
      显卡功耗: 3,
      显卡风扇转速: 4,
    }[label] ?? 10
  );
}

function metricUnit(metric) {
  const unit = String(metric.Unit || "").trim();
  if (unit) {
    return unit === "C" ? "°C" : unit;
  }
  const source = String(metric.SourceColumn || "");
  if (/_c$|temp|temperature|温度|℃/iu.test(source)) return "°C";
  if (/_w$|power|watt|功耗|功率/iu.test(source)) return "W";
  if (/_mhz$|clock|frequency|频率/iu.test(source)) return "MHz";
  if (/_v$|voltage/iu.test(source)) return "V";
  if (/rpm/iu.test(source)) return "RPM";
  if (/%|percent/iu.test(source)) return "%";
  if (/fps|frame.?rate|帧率/iu.test(source)) return "FPS";
  if (/ms|frame.?time|帧时间/iu.test(source)) return "ms";
  return "";
}

function normalizeCategoricalColumns(value) {
  if (!Array.isArray(value)) {
    return [];
  }
  return value
    .slice(0, 3)
    .map((column) => {
      if (!column || typeof column.column !== "string") {
        return null;
      }
      const values = Array.isArray(column.values)
        ? column.values
            .filter(
              (item) =>
                item &&
                typeof item.value === "string" &&
                Number.isInteger(item.count) &&
                item.count > 0,
            )
            .slice(0, 8)
            .map((item) => ({
              value: item.value.slice(0, 120),
              count: item.count,
            }))
        : [];
      return values.length > 0
        ? { column: column.column.slice(0, 120), values }
        : null;
    })
    .filter(Boolean);
}

function assertSafeSvg(buffer) {
  if (buffer.length === 0 || buffer.length > MAX_ARTIFACT_BYTES) {
    throw new TelemetryBrokerError(
      "unsafe_artifact",
      "生成图表的大小超出安全范围",
    );
  }
  const text = buffer.toString("utf8");
  const normalized = text.replace(/\s+/gu, " ");
  if (
    !/^<\?xml\s+version="1\.0"/u.test(text.trimStart()) ||
    !/<svg(?:\s|>)/iu.test(normalized)
  ) {
    throw new TelemetryBrokerError(
      "unsafe_artifact",
      "Workbench 返回的图表不是有效 SVG",
    );
  }
  if (
    /<script\b|<style\b|<link\b|<foreignObject\b|<iframe\b|<object\b|<embed\b|<image\b|\son[a-z]+\s*=/iu.test(
      normalized,
    ) ||
    /\s(?:href|xlink:href)\s*=\s*["'](?!#)/iu.test(normalized) ||
    /\burl\(\s*["']?(?!#)/iu.test(normalized) ||
    /\b(?:javascript|vbscript|data)\s*:/iu.test(normalized) ||
    /<!DOCTYPE\b|<!ENTITY\b|<\?xml-stylesheet\b/iu.test(normalized)
  ) {
    throw new TelemetryBrokerError(
      "unsafe_artifact",
      "生成的 SVG 包含不可嵌入内容",
    );
  }
  return text;
}

function publicArtifact(record) {
  return {
    id: record.id,
    kind: record.kind,
    mime: record.mime,
    title: record.title,
    relative_path: record.relative_path,
    sha256: record.sha256,
    source_evidence_ids: [...record.source_evidence_ids],
    created_at: record.created_at,
    safeToEmbed: record.safeToEmbed,
    size: record.size,
  };
}

function normalizeArtifacts(value) {
  const values = Array.isArray(value) ? value : [value];
  return values.filter(Boolean).slice(0, MAX_CHART_ARTIFACTS);
}

export function analysisSummary(analysis, buffer) {
  const analyzedRowStart = Number.isInteger(analysis.AnalyzedRowStart)
    ? analysis.AnalyzedRowStart
    : null;
  const analyzedRowEnd = Number.isInteger(analysis.AnalyzedRowEnd)
    ? analysis.AnalyzedRowEnd
    : null;
  return {
    analyzer_version: analysis.AnalyzerVersion ?? "unknown",
    header_line: analysis.HeaderLine ?? 1,
    analyzed_rows: Number.isInteger(analysis.AnalyzedRows)
      ? analysis.AnalyzedRows
      : null,
    total_rows: Number.isInteger(analysis.TotalRows)
      ? analysis.TotalRows
      : null,
    analyzed_row_start: analyzedRowStart,
    analyzed_row_end: analyzedRowEnd,
    window: analysis.Window ?? "unknown",
    requested_window: analysis.RequestedWindow ?? null,
    sampled_span_seconds: analysis.SampledSpanSeconds ?? null,
    sampling: analysis.Sampling ?? {
      TimeBased: false,
      IntervalSecondsMedian: null,
      IntervalSecondsMinimum: null,
      IntervalSecondsMaximum: null,
      Consistency: "unknown",
    },
    columns: Array.isArray(analysis.Columns) ? analysis.Columns : [],
    warnings: Array.isArray(analysis.Warnings) ? analysis.Warnings : [],
    categorical_columns: normalizeCategoricalColumns(
      analysis.CategoricalColumns,
    ),
    metrics: (analysis.Metrics ?? []).map((metric) => ({
      metric: metric.Metric,
      source_column: metric.SourceColumn,
      unit: metricUnit(metric),
      samples: metric.Samples,
      min: metric.Min,
      mean: metric.Mean,
      median: metric.Median,
      p95: metric.P95,
      max: metric.Max,
    })),
  };
}

export function verifiedBlocks(analysis, artifactOrArtifacts) {
  const artifacts = normalizeArtifacts(artifactOrArtifacts);
  const metrics = (analysis.metrics ?? []).slice(0, 6);
  if (metrics.length === 0 || artifacts.length === 0) {
    return [];
  }
  const sampling = analysis.sampling ?? {};
  const duration = formatDuration(analysis.sampled_span_seconds);
  const interval = formatNumber(sampling.IntervalSecondsMedian);
  const analyzedRows = formatNumber(analysis.analyzed_rows);
  const analyzedRowsLabel = analyzedRows || "未提供";
  const samplingCaveat =
    sampling.Consistency === "stable"
      ? "采样间隔均匀只代表记录节奏一致，不代表硬件持续稳定。"
      : "采样间隔可能不一致，比较趋势时需要谨慎。";
  const warnings = analysis.warnings ?? [];
  const categoricalColumns = analysis.categorical_columns ?? [];
  const metricItems = metrics
    .map((metric) => ({
      label: metricLabel({
        Metric: metric.metric,
        SourceColumn: metric.source_column,
      }),
      value: metricRange({
        Min: metric.min,
        Max: metric.max,
      }),
      unit: metric.unit,
      source_column: metric.source_column,
    }))
    .sort(
      (left, right) =>
        metricPriority(left.label) - metricPriority(right.label),
    );
  const metricBlock = {
      id: "telemetry-metrics",
      type: "metrics",
      title: "关键指标",
      items: metricItems,
    };
  const tableBlock = {
      id: "telemetry-table",
      type: "table",
      title: "原始指标摘要",
      columns: ["指标", "采样", "最小", "均值", "最大", "单位"],
      rows: metrics.map((metric) => [
        metricLabel({
          Metric: metric.metric,
          SourceColumn: metric.source_column,
        }),
        formatNumber(metric.samples),
        formatNumber(metric.min),
        formatNumber(metric.mean),
        formatNumber(metric.max),
        metric.unit,
      ]),
    };
  const categoryBlocks = categoricalColumns.length > 0
    ? [
        {
          id: "telemetry-categories",
          type: "table",
          title: "状态列分布",
          columns: ["列名", "取值", "样本数"],
          rows: categoricalColumns.flatMap((column) =>
            column.values.map((item) => [
              column.column,
              item.value,
              String(item.count),
            ]),
          ).slice(0, 20),
        },
      ]
    : [];
  const chartBlocks = artifacts.map((artifact, index) => ({
      id: `telemetry-chart-${index + 1}`,
      type: "chart",
      title: artifact.title || (artifacts.length === 1 ? "遥测趋势" : `遥测图 ${index + 1}`),
      artifact_ref: artifact.id,
      alt: `${artifact.title || "遥测图"}，${analyzedRowsLabel} 行，包含 ${metrics
        .map((metric) => metric.metric)
        .join("、")}。`,
    }));
  const windowBlock = {
      id: "telemetry-window",
      type: "callout",
      title: "数据记录概况",
      text: `记录时长：${duration || "未提供"}　|　记录数量：${analyzedRowsLabel} 条　|　采样间隔中位数：${interval ? formatDuration(interval) : "未提供"}\n${samplingCaveat}`,
      tone: "info",
      collapsed: false,
    };
  const warningBlocks = warnings.length
    ? [
        {
          id: "telemetry-warnings",
          type: "callout",
          title: `数据质量提示 · ${warnings.length} 项`,
          text: warnings.map((warning) => `• ${warning}`).join("\n"),
          tone: "warning",
          collapsed: true,
        },
      ]
    : [];
  const maximumDownloads = Math.min(
    artifacts.length,
    Math.max(
      0,
      12 - chartBlocks.length - 1 - warningBlocks.length,
    ),
  );
  const downloadBlocks = artifacts
    .slice(0, maximumDownloads)
    .map((artifact, index) => ({
      id: `telemetry-download-${index + 1}`,
      type: "artifact-download",
      title: artifact.title || `图表文件 ${index + 1}`,
      artifact_ref: artifact.id,
      label: "下载 SVG",
    }));
  const remaining = 12 -
    chartBlocks.length -
    downloadBlocks.length -
    1 -
    warningBlocks.length;
  const summaryBlocks = [metricBlock, tableBlock, ...categoryBlocks]
    .slice(0, Math.max(0, remaining));
  return [
    ...summaryBlocks,
    ...chartBlocks,
    windowBlock,
    ...downloadBlocks,
    ...warningBlocks,
  ];
}

function normalizePanelWindow(panel, analysis, artifactOrArtifacts) {
  const artifacts = normalizeArtifacts(artifactOrArtifacts);
  return {
    ...panel,
    schema_version: "1.2",
    artifact_refs: artifacts.map(publicArtifact),
    blocks: verifiedBlocks(analysis, artifacts),
  };
}

export class TelemetryBroker {
  constructor({
    attachmentRoot,
    artifactRoot,
    scriptsDir,
    timeoutMs = 45_000,
    spawnImpl = spawn,
  }) {
    this.attachmentRoot = resolve(attachmentRoot);
    this.artifactRoot = resolve(artifactRoot);
    this.scriptsDir = resolve(scriptsDir);
    this.analyzerPath = resolve(this.scriptsDir, "analyze-telemetry.ps1");
    this.rendererPath = resolve(this.scriptsDir, "render-telemetry-chart.ps1");
    this.packScriptPath = resolve(
      this.scriptsDir,
      "render-telemetry-pack.ps1",
    );
    this.indexPath = resolve(this.artifactRoot, "index.json");
    this.timeoutMs = timeoutMs;
    this.spawnImpl = spawnImpl;
    mkdirSync(this.artifactRoot, { recursive: true });
  }

  loadIndex() {
    if (!existsSync(this.indexPath)) {
      return { schema_version: "1.0", artifacts: [] };
    }
    const parsed = JSON.parse(readFileSync(this.indexPath, "utf8"));
    return {
      schema_version: "1.0",
      artifacts: Array.isArray(parsed.artifacts) ? parsed.artifacts : [],
    };
  }

  saveIndex(index) {
    const temporary = `${this.indexPath}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(index, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    renameSync(temporary, this.indexPath);
  }

  verifyArtifactRecord(record, {
    taskId = null,
    attachmentId = null,
    includeContent = false,
  } = {}) {
    if (
      !record ||
      (taskId !== null && record.task_id !== taskId) ||
      (attachmentId !== null &&
        record.source_attachment_id !== attachmentId) ||
      record.safeToEmbed !== true
    ) {
      return null;
    }
    try {
      const { filePath, stat, buffer } = readControlledFile(
        this.artifactRoot,
        record.absolute_path,
      );
      if (
        stat.size !== buffer.length ||
        (Number.isInteger(record.size) && record.size !== buffer.length) ||
        sha256(buffer) !== record.sha256
      ) {
        return null;
      }
      if (record.kind === "chart" || record.mime === "image/svg+xml") {
        assertSafeSvg(buffer);
      }
      return {
        record: { ...record, absolute_path: filePath },
        buffer: includeContent ? buffer : null,
      };
    } catch {
      return null;
    }
  }

  getCachedArtifactPack(index, {
    cacheKey,
    taskId = null,
    attachmentId = null,
  }) {
    const candidates = index.artifacts
      .filter((item) => item.cache_key === cacheKey)
      .map((item) =>
        this.verifyArtifactRecord(item, { taskId, attachmentId })?.record,
      )
      .filter(Boolean)
      .sort((left, right) =>
        String(left.created_at).localeCompare(String(right.created_at)),
      );
    if (candidates.length === 0) {
      return [];
    }
    const packs = new Map();
    for (const candidate of candidates) {
      const packId = candidate.pack_id ?? candidate.id;
      if (!packs.has(packId)) {
        packs.set(packId, []);
      }
      packs.get(packId).push(candidate);
    }
    for (const pack of packs.values()) {
      pack.sort(
        (left, right) =>
          (left.pack_index ?? 0) - (right.pack_index ?? 0),
      );
      const expectedSize = Number(pack[0].pack_size ?? 1);
      if (
        Number.isInteger(expectedSize) &&
        expectedSize >= 1 &&
        expectedSize <= MAX_CHART_ARTIFACTS &&
        pack.length === expectedSize
      ) {
        return pack;
      }
    }
    return [];
  }

  validateAttachmentReference(attachment) {
    if (!attachment || typeof attachment !== "object") {
      throw new TelemetryBrokerError(
        "attachment_not_found",
        "找不到要分析的附件",
        { statusCode: 404 },
      );
    }
    if (extname(attachment.original_name ?? "").toLowerCase() !== ".csv") {
      throw new TelemetryBrokerError(
        "not_csv",
        "只有 CSV 遥测文件可以进入图表分析",
        { statusCode: 415 },
      );
    }
    const { filePath, stat } = resolveControlledFile(
      this.attachmentRoot,
      String(attachment.local_path ?? ""),
    );
    if (stat.size === 0 || stat.size > MAX_CSV_BYTES) {
      throw new TelemetryBrokerError(
        "invalid_attachment_size",
        "CSV 为空或超过 8 MB 分析限制",
        { statusCode: 413 },
      );
    }
    if (!/^[a-f0-9]{64}$/u.test(String(attachment.sha256 ?? ""))) {
      throw new TelemetryBrokerError(
        "attachment_hash_invalid",
        "CSV 上传记录缺少有效的 SHA-256",
        { statusCode: 409 },
      );
    }
    return {
      filePath,
      size: stat.size,
      declaredHash: String(attachment.sha256),
    };
  }

  validateAttachment(attachment) {
    const reference = this.validateAttachmentReference(attachment);
    const { filePath, buffer } = readControlledFile(
      this.attachmentRoot,
      reference.filePath,
    );
    const actualHash = sha256(buffer);
    if (actualHash !== attachment.sha256) {
      throw new TelemetryBrokerError(
        "attachment_hash_mismatch",
        "CSV 文件哈希与上传记录不一致，已停止分析",
        { statusCode: 409 },
      );
    }
    return { filePath, buffer, actualHash };
  }

  async buildChartPack({
    taskDirectory,
    filePath,
    parsed,
    window,
    actualHash,
    preset,
  }) {
    const packDirectory = resolve(
      taskDirectory,
      `pack-${randomUUID()}`,
    );
    if (!isInside(taskDirectory, packDirectory)) {
      throw new TelemetryBrokerError(
        "unsafe_artifact_path",
        "图表包路径越界",
      );
    }
    mkdirSync(packDirectory, { recursive: true });
    const manifestPath = resolve(packDirectory, "telemetry-pack-manifest.json");
    // The pack script requires an empty output directory. Keep analyzer-owned
    // ChartData beside the pack directory and remove the transient file after
    // rendering so the source CSV is never parsed a second time.
    const chartDataPath = resolve(
      taskDirectory,
      `.${packDirectory.split(/[\\/]/u).at(-1)}-chart-data.json`,
    );
    const warnings = [];
    const skipped = [];
    const hasChartData =
      parsed.ChartData &&
      typeof parsed.ChartData === "object" &&
      Array.isArray(parsed.ChartData.Series) &&
      parsed.ChartData.Series.length > 0;
    if (hasChartData) {
      writeFileSync(
        chartDataPath,
        `${JSON.stringify(parsed.ChartData, null, 2)}\n`,
        "utf8",
      );
    }

    if (existsSync(this.packScriptPath)) {
      const packArgs = [
        "-Path",
        filePath,
        "-OutputDirectory",
        packDirectory,
        "-Preset",
        preset,
        "-ManifestPath",
        manifestPath,
      ];
      if (hasChartData) {
        packArgs.push("-ChartDataPath", chartDataPath);
      }
      if (!hasChartData && window.warmup !== null) {
        packArgs.push("-WarmupSeconds", String(window.warmup));
      }
      if (!hasChartData && window.duration !== null) {
        packArgs.push("-DurationSeconds", String(window.duration));
      }
      try {
        await this.runPowerShell(this.packScriptPath, packArgs);
        const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
        const manifestSourceHash =
          manifest.SourceSha256 ?? manifest.source_sha256 ?? "";
        if (
          manifestSourceHash &&
          String(manifestSourceHash).toLowerCase() !== actualHash.toLowerCase()
        ) {
          throw new Error("图表包源文件哈希不匹配");
        }
        const charts =
          manifest.Charts ?? manifest.charts;
        if (!Array.isArray(charts)) {
          throw new Error("图表包 manifest 缺少 Charts");
        }
        const selected = [];
        for (const chart of charts.slice(0, MAX_CHART_ARTIFACTS)) {
          const relativePath =
            chart.RelativePath ??
            chart.relative_path ??
            chart.FileName ??
            chart.file;
          if (!relativePath) continue;
          const chartPath = resolve(packDirectory, String(relativePath));
          if (!isInside(packDirectory, chartPath) || !existsSync(chartPath)) {
            throw new Error(`图表包路径无效：${relativePath}`);
          }
          const safe = assertSafeSvg(readFileSync(chartPath));
          selected.push({
            sourcePath: chartPath,
            title: String(
              chart.Title ?? chart.title ?? `遥测图 ${selected.length + 1}`,
            ).slice(0, 120),
            safe,
          });
        }
        if (selected.length === 0) {
          throw new Error("图表包没有可用图表");
        }
        for (const value of [
          ...(Array.isArray(manifest.Warnings) ? manifest.Warnings : []),
          ...(Array.isArray(manifest.warnings) ? manifest.warnings : []),
        ]) {
          const text = String(value).trim();
          if (text) warnings.push(text);
        }
        for (const value of [
          ...(Array.isArray(manifest.Skipped) ? manifest.Skipped : []),
          ...(Array.isArray(manifest.skipped) ? manifest.skipped : []),
        ]) {
          const text =
            typeof value === "string"
              ? value
              : value?.Reason ?? value?.reason ?? value?.Id ?? value?.id;
          if (text) skipped.push(String(text));
        }
        if (existsSync(chartDataPath)) {
          unlinkSync(chartDataPath);
        }
        return {
          packDirectory,
          charts: selected,
          warnings,
          skipped,
        };
      } catch (error) {
        warnings.push(`图表包降级为单图：${error.message}`);
      }
    }

    const fallbackId = `draft-${randomUUID()}`;
    const fallbackPath = resolve(packDirectory, `${fallbackId}.svg`);
    const chartArgs = hasChartData
      ? [
          "-Path",
          chartDataPath,
          "-OutputPath",
          fallbackPath,
          "-InputFormat",
          "ChartData",
        ]
      : ["-Path", filePath, "-OutputPath", fallbackPath];
    if (!hasChartData && window.warmup !== null) {
      chartArgs.push("-WarmupSeconds", String(window.warmup));
    }
    if (!hasChartData && window.duration !== null) {
      chartArgs.push("-DurationSeconds", String(window.duration));
    }
    const genericMetrics = parsed.Metrics.every(
      (metric) => !metric.Unit || metric.Unit === "",
    );
    const includeColumn = genericMetrics
      ? parsed.CandidateColumnPattern
      : null;
    if (includeColumn) {
      chartArgs.push("-IncludeColumn", includeColumn);
    }
    let safe;
    try {
      await this.runPowerShell(this.rendererPath, chartArgs);
      safe = assertSafeSvg(readFileSync(fallbackPath));
    } finally {
      if (existsSync(chartDataPath)) {
        unlinkSync(chartDataPath);
      }
    }
    return {
      packDirectory,
      charts: [
        {
          sourcePath: fallbackPath,
          title: "Telemetry overview",
          safe,
        },
      ],
      warnings,
      skipped,
    };
  }

  async runPowerShell(scriptPath, args) {
    return new Promise((resolvePromise, reject) => {
      const child = this.spawnImpl(
        "powershell.exe",
        [
          "-NoProfile",
          "-ExecutionPolicy",
          "Bypass",
          "-File",
          scriptPath,
          ...args,
        ],
        {
          cwd: this.artifactRoot,
          windowsHide: true,
          stdio: ["ignore", "pipe", "pipe"],
        },
      );
      let stdout = "";
      let stderr = "";
      let outputBytes = 0;
      const timeout = setTimeout(() => {
        child.kill();
        reject(
          new TelemetryBrokerError(
            "analysis_timeout",
            "Workbench 分析超时，未生成图表",
          ),
        );
      }, this.timeoutMs);
      child.stdout.on("data", (chunk) => {
        outputBytes += chunk.length;
        if (outputBytes <= MAX_SCRIPT_OUTPUT_BYTES) {
          stdout += chunk.toString();
        }
      });
      child.stderr.on("data", (chunk) => {
        outputBytes += chunk.length;
        if (outputBytes <= MAX_SCRIPT_OUTPUT_BYTES) {
          stderr += chunk.toString();
        }
      });
      child.once("error", (error) => {
        clearTimeout(timeout);
        reject(
          new TelemetryBrokerError(
            "analysis_runner_error",
            `无法启动 Workbench 分析：${error.message}`,
          ),
        );
      });
      child.once("close", (code) => {
        clearTimeout(timeout);
        if (outputBytes > MAX_SCRIPT_OUTPUT_BYTES) {
          reject(
            new TelemetryBrokerError(
              "analysis_output_too_large",
              "Workbench 输出超过安全大小限制",
            ),
          );
          return;
        }
        if (code !== 0) {
          const diagnostic = stderr.trim() || stdout.trim();
          const noUsableSeries =
            /could not identify a telemetry header row|no recognized numeric sensor|no usable numeric/i.test(
              diagnostic,
            );
          reject(
            new TelemetryBrokerError(
              noUsableSeries ? "no_usable_series" : "analysis_failed",
              noUsableSeries
                ? "Workbench 未在这份 CSV 中找到可绘制的数值传感器列"
                : "Workbench 未返回可用遥测分析",
              {
                details: [diagnostic].filter(Boolean),
              },
            ),
          );
          return;
        }
        resolvePromise({ stdout, stderr });
      });
    });
  }

  findCached({
    taskId,
    attachment,
    window: windowInput = {},
    preset: presetInput = "FirstPass",
  }) {
    if (!/^[A-Za-z0-9_-]{8,120}$/u.test(String(taskId))) {
      throw new TelemetryBrokerError("invalid_task", "任务 ID 无效", {
        statusCode: 400,
      });
    }
    const window = normalizeWindow(windowInput);
    const preset = normalizeChartPreset(presetInput);
    const reference = this.validateAttachmentReference(attachment);
    const cacheKey =
      `${ANALYZER_CACHE_VERSION}:${preset}:` +
      `${reference.declaredHash}:${windowSignature(window)}`;
    const records = this.getCachedArtifactPack(this.loadIndex(), {
      cacheKey,
      taskId,
      attachmentId: attachment.id,
    });
    return records.length > 0
      ? {
          ok: true,
          cache_hit: true,
          attachment: {
            id: attachment.id,
            original_name: attachment.original_name,
            sha256: reference.declaredHash,
          },
          artifact: publicArtifact(records[0]),
          artifacts: records.map(publicArtifact),
          analysis: records[0].analysis,
          chart_preset: preset,
          blocks: verifiedBlocks(records[0].analysis, records),
        }
      : null;
  }

  async analyze({
    taskId,
    attachment,
    window: windowInput = {},
    preset: presetInput = "FirstPass",
  }) {
    const cached = this.findCached({
      taskId,
      attachment,
      window: windowInput,
      preset: presetInput,
    });
    if (cached) {
      return cached;
    }
    if (!/^[A-Za-z0-9_-]{8,120}$/u.test(String(taskId))) {
      throw new TelemetryBrokerError("invalid_task", "任务 ID 无效", {
        statusCode: 400,
      });
    }
    const window = normalizeWindow(windowInput);
    const preset = normalizeChartPreset(presetInput);
    const { filePath, buffer, actualHash } = this.validateAttachment(attachment);
    const cacheKey = `${ANALYZER_CACHE_VERSION}:${preset}:${actualHash}:${windowSignature(window)}`;
    const index = this.loadIndex();
    const reusesArtifacts = this.getCachedArtifactPack(index, {
      cacheKey,
      taskId,
      attachmentId: attachment.id,
    });
    const taskDirectory = resolve(this.artifactRoot, taskId);
    if (!isInside(this.artifactRoot, taskDirectory)) {
      throw new TelemetryBrokerError("invalid_task", "任务目录越界", {
        statusCode: 400,
      });
    }
    mkdirSync(taskDirectory, { recursive: true });

    let analysis;
    let chartPack = null;
    if (reusesArtifacts.length > 0) {
      analysis = reusesArtifacts[0].analysis;
    } else {
      const baseArgs = [
        "-Path",
        filePath,
        "-Format",
        "Json",
        "-IncludeChartData",
      ];
      if (window.warmup !== null) {
        baseArgs.push("-WarmupSeconds", String(window.warmup));
      }
      if (window.duration !== null) {
        baseArgs.push("-DurationSeconds", String(window.duration));
      }
      const first = await this.runPowerShell(this.analyzerPath, baseArgs);
      let parsed;
      try {
        parsed = JSON.parse(first.stdout);
      } catch {
        throw new TelemetryBrokerError(
          "analysis_parse_failed",
          "Workbench 返回的分析不是有效 JSON",
        );
      }
      if (!Array.isArray(parsed.Metrics) || parsed.Metrics.length === 0) {
        const includeColumn = parsed.CandidateColumnPattern;
        if (includeColumn) {
          const fallback = await this.runPowerShell(this.analyzerPath, [
            ...baseArgs,
            "-IncludeColumn",
            includeColumn,
          ]);
          try {
            parsed = JSON.parse(fallback.stdout);
          } catch {
            throw new TelemetryBrokerError(
              "analysis_parse_failed",
              "Workbench 的显式列分析不是有效 JSON",
            );
          }
        }
      }
      if (!Array.isArray(parsed.Metrics) || parsed.Metrics.length === 0) {
        throw new TelemetryBrokerError(
          "no_usable_series",
          "Workbench 未在这份 CSV 中找到可绘制的数值传感器列",
          {
            details: [
              parsed.Window ? `窗口：${parsed.Window}` : "",
              ...(Array.isArray(parsed.Warnings) ? parsed.Warnings : []),
            ].filter(Boolean),
          },
        );
      }
      analysis = analysisSummary(parsed, buffer);
      try {
        chartPack = await this.buildChartPack({
          taskDirectory,
          filePath,
          parsed,
          window,
          actualHash,
          preset,
        });
        for (const warning of chartPack.warnings) {
          if (!analysis.warnings.includes(warning)) {
            analysis.warnings.push(warning);
          }
        }
        for (const skippedItem of chartPack.skipped) {
          const warning = `图表包跳过：${skippedItem}`;
          if (!analysis.warnings.includes(warning)) {
            analysis.warnings.push(warning);
          }
        }
        // Analyzer and renderer child processes reopen the path after the
        // initial hash check. Recheck only after that full pipeline finishes.
        this.validateAttachment(attachment);
      } catch (error) {
        if (chartPack?.packDirectory) {
          rmSync(chartPack.packDirectory, { recursive: true, force: true });
        }
        throw error;
      }
    }

    const artifactInputs =
      reusesArtifacts.length > 0
        ? reusesArtifacts.map((record) => ({
            sourcePath: record.absolute_path,
            title: record.title,
            safe: assertSafeSvg(readFileSync(record.absolute_path)),
          }))
        : chartPack.charts;
    const packId = `pack-${randomUUID()}`;
    const artifacts = artifactInputs.map((item, packIndex) => {
      const artifactId = `artifact-${randomUUID()}`;
      const relativePath = `${taskId}/${artifactId}.svg`.replaceAll("\\", "/");
      const outputPath = resolve(taskDirectory, `${artifactId}.svg`);
      copyFileSync(item.sourcePath, outputPath);
      const finalBuffer = readFileSync(outputPath);
      assertSafeSvg(finalBuffer);
      return {
        id: artifactId,
        kind: "chart",
        mime: "image/svg+xml",
        title: item.title,
        relative_path: relativePath,
        sha256: sha256(finalBuffer),
        source_evidence_ids: [attachment.id],
        created_at: new Date().toISOString(),
        safeToEmbed: true,
        size: finalBuffer.length,
        cache_key: cacheKey,
        task_id: taskId,
        source_attachment_id: attachment.id,
        absolute_path: outputPath,
        analysis,
        pack_id: packId,
        pack_size: artifactInputs.length,
        pack_index: packIndex,
      };
    });
    if (chartPack?.packDirectory) {
      rmSync(chartPack.packDirectory, { recursive: true, force: true });
    }
    index.artifacts.push(...artifacts);
    this.saveIndex(index);
    return {
      ok: true,
      cache_hit: reusesArtifacts.length > 0,
      attachment: {
        id: attachment.id,
        original_name: attachment.original_name,
        sha256: actualHash,
      },
      artifact: publicArtifact(artifacts[0]),
      artifacts: artifacts.map(publicArtifact),
      analysis,
      chart_preset: preset,
      blocks: verifiedBlocks(analysis, artifacts),
    };
  }

  getArtifact(id, { taskId = null } = {}) {
    const index = this.loadIndex();
    const artifact = index.artifacts.find((item) => item.id === id);
    return this.verifyArtifactRecord(artifact, { taskId })?.record ?? null;
  }

  applyVerifiedResult(panel, result, { taskId = null } = {}) {
    const requestedArtifacts = normalizeArtifacts(
      result.artifacts ?? result.artifact,
    );
    const artifacts = requestedArtifacts
      .map((artifact) => this.getArtifact(artifact.id, { taskId }))
      .filter(Boolean);
    if (
      artifacts.length === 0 ||
      artifacts.length !== requestedArtifacts.length
    ) {
      throw new TelemetryBrokerError(
        "unverified_artifact",
        "面板结果包含未通过本地索引验证的图表引用",
      );
    }
    return normalizePanelWindow(panel, result.analysis, artifacts);
  }
}
