import { spawn } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  statSync,
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
const MAX_WINDOW_SECONDS = 24 * 60 * 60;
const ANALYZER_CACHE_VERSION = "1.2.4";
const METRIC_HINTS =
  /temp|temperature|power|watt|clock|effective|mhz|fps|frame|voltage|fan|usage|load|温度|功耗|频率|帧率|瓦/u;

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

function formatNumber(value) {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return "";
  }
  return Number.isInteger(number)
    ? String(number)
    : number.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function metricRange(metric) {
  const minimum = formatNumber(metric.Min);
  const maximum = formatNumber(metric.Max);
  return minimum === maximum ? minimum : `${minimum}–${maximum}`;
}

function metricLabel(metric) {
  const source = String(metric.SourceColumn || metric.Metric || "数值列");
  const aliases = [
    [/gpu.*temp|temperature/i, "GPU 温度"],
    [/gpu.*power|power/i, "GPU 功耗"],
    [/effective.*clock|effective/i, "有效频率"],
    [/gpu.*clock|core clock/i, "GPU 核心频率"],
    [/fps|frame rate/i, "帧率"],
    [/frame time/i, "帧时间"],
  ];
  const alias = aliases.find(([pattern]) => pattern.test(source))?.[1];
  return alias && !/^GPU (?:温度|功耗)$|有效频率|核心频率|帧率|帧时间/u.test(metric.Metric || "")
    ? `${alias} · ${source}`
    : metric.Metric || source;
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

function parseHeaderNames(buffer) {
  const text = buffer.toString("utf8").replace(/^\uFEFF/u, "");
  const firstLine = text.split(/\r?\n/u).find((line) => line.trim()) ?? "";
  return firstLine
    .split(",")
    .map((value) =>
      value
        .trim()
        .replace(/^"+|"+$/gu, "")
        .replace(/""/gu, '"'),
    )
    .filter(Boolean)
    .slice(0, 256);
}

function parseCsvLine(line) {
  const fields = [];
  let field = "";
  let quoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const character = line[index];
    if (character === '"') {
      if (quoted && line[index + 1] === '"') {
        field += '"';
        index += 1;
      } else {
        quoted = !quoted;
      }
    } else if (character === "," && !quoted) {
      fields.push(field.trim());
      field = "";
    } else {
      field += character;
    }
  }
  fields.push(field.trim());
  return fields;
}

function summarizeCategoricalColumns(buffer, headerLine) {
  const lines = buffer.toString("utf8").replace(/^\uFEFF/u, "").split(/\r?\n/u);
  const start = Math.max(0, Number(headerLine ?? 1) - 1);
  const headers = parseCsvLine(lines[start] ?? "");
  const candidateIndexes = headers
    .map((header, index) => ({ header, index }))
    .filter(({ header }) =>
      /perfcap|performance.?limit|limit.?reason|限制原因|性能限制/iu.test(header),
    )
    .slice(0, 3);
  if (candidateIndexes.length === 0) {
    return [];
  }
  const counts = new Map(
    candidateIndexes.map(({ header }) => [header, new Map()]),
  );
  for (let index = start + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!line.trim()) break;
    const fields = parseCsvLine(line);
    if (fields.length !== headers.length) continue;
    for (const { header, index: columnIndex } of candidateIndexes) {
      const value = String(fields[columnIndex] ?? "").trim().slice(0, 120);
      if (!value) continue;
      const columnCounts = counts.get(header);
      columnCounts.set(value, (columnCounts.get(value) ?? 0) + 1);
    }
  }
  return candidateIndexes
    .map(({ header }) => {
      const values = [...counts.get(header).entries()]
        .map(([value, count]) => ({ value, count }))
        .sort((left, right) => right.count - left.count)
        .slice(0, 8);
      return values.length > 0 ? { column: header, values } : null;
    })
    .filter(Boolean);
}

function genericIncludePattern(headers, existingMetrics = []) {
  if (existingMetrics.length > 0) {
    return null;
  }
  const selected = headers
    .filter((header) => METRIC_HINTS.test(header))
    .filter((header) => !/date|time|timestamp|perfcap|limit|offset|目标|上限/u.test(header))
    .filter((header) => header.length <= 120)
    .slice(0, 8);
  if (selected.length === 0) {
    return null;
  }
  return `^(?:${selected
    .map((header) => header.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&"))
    .join("|")})$`;
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
    /<script\b|<foreignObject\b|<iframe\b|<object\b|<embed\b|\son[a-z]+\s*=/iu.test(
      normalized,
    ) ||
    /\s(?:href|xlink:href)\s*=\s*["'](?!#)/iu.test(normalized) ||
    /<!ENTITY\b/iu.test(normalized)
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

export function analysisSummary(analysis, buffer) {
  return {
    analyzer_version: analysis.AnalyzerVersion ?? "unknown",
    header_line: analysis.HeaderLine ?? 1,
    analyzed_rows: analysis.AnalyzedRows ?? 0,
    total_rows: analysis.TotalRows ?? 0,
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
    categorical_columns: summarizeCategoricalColumns(
      buffer,
      analysis.HeaderLine,
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

export function verifiedBlocks(analysis, artifact) {
  const metrics = (analysis.metrics ?? []).slice(0, 6);
  if (metrics.length === 0) {
    return [];
  }
  const sampling = analysis.sampling ?? {};
  const samplingText =
    sampling.Consistency === "stable"
      ? `采样间隔中位数 ${formatNumber(sampling.IntervalSecondsMedian)} 秒，稳定性为 stable。`
      : `采样一致性为 ${sampling.Consistency || "unknown"}；间隔样本可能有限。`;
  const warnings = analysis.warnings ?? [];
  const categoricalColumns = analysis.categorical_columns ?? [];
  const spanText =
    Number.isFinite(analysis.sampled_span_seconds)
      ? `采样跨度 ${formatNumber(analysis.sampled_span_seconds)} 秒。`
      : "";
  return [
    {
      id: "telemetry-metrics",
      type: "metrics",
      title: "关键指标",
      items: metrics.map((metric) => ({
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
      })),
    },
    {
      id: "telemetry-table",
      type: "table",
      title: "遥测摘要",
      columns: ["指标", "采样", "最小", "均值", "最大", "单位"],
      rows: metrics.map((metric) => [
        metricLabel({
          Metric: metric.metric,
          SourceColumn: metric.source_column,
        }),
        String(metric.samples),
        formatNumber(metric.min),
        formatNumber(metric.mean),
        formatNumber(metric.max),
        metric.unit,
      ]),
    },
    ...(categoricalColumns.length > 0
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
      : []),
    {
      id: "telemetry-chart",
      type: "chart",
      title: "遥测概览",
      artifact_ref: artifact.id,
      alt: `遥测概览，${analysis.analyzed_rows} 行，包含 ${metrics
        .map((metric) => metric.metric)
        .join("、")}。`,
    },
    {
      id: "telemetry-window",
      type: "callout",
      title: "数据窗口",
      text: `窗口：${analysis.window}。${spanText}已分析 ${analysis.analyzed_rows} 行；${samplingText}`,
      tone: "info",
      collapsed: false,
    },
    {
      id: "telemetry-download",
      type: "artifact-download",
      title: "图表文件",
      artifact_ref: artifact.id,
      label: "下载 SVG",
    },
    ...(warnings.length
      ? [
          {
            id: "telemetry-warnings",
            type: "callout",
            title: `Workbench 警告 · ${warnings.length} 项`,
            text: warnings.map((warning) => `• ${warning}`).join("\n"),
            tone: "warning",
            collapsed: true,
          },
        ]
      : []),
  ];
}

function normalizePanelWindow(panel, analysis, artifact) {
  return {
    ...panel,
    schema_version: "1.2",
    artifact_refs: [publicArtifact(artifact)],
    blocks: verifiedBlocks(analysis, artifact),
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

  validateAttachment(attachment) {
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
    const filePath = resolve(String(attachment.local_path ?? ""));
    if (!isInside(this.attachmentRoot, filePath) || !existsSync(filePath)) {
      throw new TelemetryBrokerError(
        "attachment_not_found",
        "附件文件不在受控的本地证据目录中",
        { statusCode: 404 },
      );
    }
    const stat = statSync(filePath);
    if (!stat.isFile() || stat.size === 0 || stat.size > MAX_CSV_BYTES) {
      throw new TelemetryBrokerError(
        "invalid_attachment_size",
        "CSV 为空或超过 8 MB 分析限制",
        { statusCode: 413 },
      );
    }
    const buffer = readFileSync(filePath);
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
          reject(
            new TelemetryBrokerError(
              "analysis_failed",
              "Workbench 未返回可用遥测分析",
              {
                details: [stderr.trim() || stdout.trim()].filter(Boolean),
              },
            ),
          );
          return;
        }
        resolvePromise({ stdout, stderr });
      });
    });
  }

  findCached({ taskId, attachment, window: windowInput = {} }) {
    if (!/^[A-Za-z0-9_-]{8,120}$/u.test(String(taskId))) {
      throw new TelemetryBrokerError("invalid_task", "任务 ID 无效", {
        statusCode: 400,
      });
    }
    const window = normalizeWindow(windowInput);
    const { actualHash } = this.validateAttachment(attachment);
    const cacheKey = `${ANALYZER_CACHE_VERSION}:${actualHash}:${windowSignature(window)}`;
    const record = this.loadIndex().artifacts.find(
      (item) =>
        item.cache_key === cacheKey &&
        item.task_id === taskId &&
        existsSync(item.absolute_path) &&
        sha256(readFileSync(item.absolute_path)) === item.sha256,
    );
    return record
      ? {
          ok: true,
          cache_hit: true,
          attachment: {
            id: attachment.id,
            original_name: attachment.original_name,
            sha256: actualHash,
          },
          artifact: publicArtifact(record),
          analysis: record.analysis,
          blocks: verifiedBlocks(record.analysis, record),
        }
      : null;
  }

  async analyze({ taskId, attachment, window: windowInput = {} }) {
    const cached = this.findCached({ taskId, attachment, window: windowInput });
    if (cached) {
      return cached;
    }
    if (!/^[A-Za-z0-9_-]{8,120}$/u.test(String(taskId))) {
      throw new TelemetryBrokerError("invalid_task", "任务 ID 无效", {
        statusCode: 400,
      });
    }
    const window = normalizeWindow(windowInput);
    const { filePath, buffer, actualHash } = this.validateAttachment(attachment);
    const cacheKey = `${ANALYZER_CACHE_VERSION}:${actualHash}:${windowSignature(window)}`;
    const index = this.loadIndex();
    const reusesArtifact = index.artifacts.find(
      (record) =>
        record.cache_key === cacheKey &&
        existsSync(record.absolute_path) &&
        sha256(readFileSync(record.absolute_path)) === record.sha256,
    );
    const taskDirectory = resolve(this.artifactRoot, taskId);
    if (!isInside(this.artifactRoot, taskDirectory)) {
      throw new TelemetryBrokerError("invalid_task", "任务目录越界", {
        statusCode: 400,
      });
    }
    mkdirSync(taskDirectory, { recursive: true });

    let analysis;
    let renderedBuffer;
    let generatedPath = null;
    if (reusesArtifact) {
      analysis = reusesArtifact.analysis;
      renderedBuffer = readFileSync(reusesArtifact.absolute_path);
    } else {
      const baseArgs = ["-Path", filePath, "-Format", "Json"];
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
        const includeColumn = genericIncludePattern(
          parseHeaderNames(buffer),
          parsed.Metrics,
        );
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
      const draftArtifactId = `artifact-${randomUUID()}`;
      const outputPath = resolve(taskDirectory, `${draftArtifactId}.svg`);
      generatedPath = outputPath;
      if (!isInside(this.artifactRoot, outputPath)) {
        throw new TelemetryBrokerError("unsafe_artifact_path", "图表路径越界");
      }
      const chartArgs = ["-Path", filePath, "-OutputPath", outputPath];
      if (window.warmup !== null) {
        chartArgs.push("-WarmupSeconds", String(window.warmup));
      }
      if (window.duration !== null) {
        chartArgs.push("-DurationSeconds", String(window.duration));
      }
      const genericMetrics = parsed.Metrics.every(
        (metric) => !metric.Unit || metric.Unit === "",
      );
      const includeColumn = genericMetrics
        ? genericIncludePattern(parseHeaderNames(buffer), [])
        : null;
      if (includeColumn) {
        chartArgs.push("-IncludeColumn", includeColumn);
      }
      try {
        await this.runPowerShell(this.rendererPath, chartArgs);
        renderedBuffer = readFileSync(outputPath);
        assertSafeSvg(renderedBuffer);
      } catch (error) {
        if (existsSync(outputPath)) {
          try {
            unlinkSync(outputPath);
          } catch {
            // The rejected file remains outside the artifact index.
          }
        }
        throw error;
      }
    }

    const artifactId = `artifact-${randomUUID()}`;
    const relativePath = `${taskId}/${artifactId}.svg`.replaceAll("\\", "/");
    const outputPath = resolve(taskDirectory, `${artifactId}.svg`);
    if (reusesArtifact) {
      copyFileSync(reusesArtifact.absolute_path, outputPath);
    } else {
      assertSafeSvg(renderedBuffer);
      writeFileSync(outputPath, renderedBuffer, { mode: 0o600 });
      if (generatedPath && generatedPath !== outputPath && existsSync(generatedPath)) {
        unlinkSync(generatedPath);
      }
    }
    const finalBuffer = readFileSync(outputPath);
    assertSafeSvg(finalBuffer);
    const artifact = {
      id: artifactId,
      kind: "chart",
      mime: "image/svg+xml",
      title: "Telemetry overview",
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
    };
    index.artifacts.push(artifact);
    this.saveIndex(index);
    return {
      ok: true,
      cache_hit: Boolean(reusesArtifact),
      attachment: {
        id: attachment.id,
        original_name: attachment.original_name,
        sha256: actualHash,
      },
      artifact: publicArtifact(artifact),
      analysis,
      blocks: verifiedBlocks(analysis, artifact),
    };
  }

  getArtifact(id) {
    const index = this.loadIndex();
    const artifact = index.artifacts.find((item) => item.id === id);
    if (
      !artifact ||
      !existsSync(artifact.absolute_path) ||
      !isInside(this.artifactRoot, artifact.absolute_path)
    ) {
      return null;
    }
    return artifact;
  }

  applyVerifiedResult(panel, result) {
    return normalizePanelWindow(panel, result.analysis, {
      ...result.artifact,
      absolute_path: this.getArtifact(result.artifact.id)?.absolute_path,
    });
  }
}
