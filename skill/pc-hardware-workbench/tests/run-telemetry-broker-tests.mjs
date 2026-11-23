import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { TelemetryBroker } from "../telemetry-broker.mjs";

const skillRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const tempRoot = mkdtempSync(join(tmpdir(), "pcwb-broker-"));
const attachmentRoot = join(tempRoot, "attachments");
const artifactRoot = join(tempRoot, "artifacts");
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

  const first = await broker.analyze({
    taskId: "task-broker-pack",
    attachment,
    window: {},
  });
  assert.equal(first.artifact.kind, "chart");
  assert.equal(first.artifacts.length, 4);
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

  const second = await broker.analyze({
    taskId: "task-broker-pack",
    attachment,
    window: {},
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
  console.log("Telemetry broker chart-pack regression: PASS");
} finally {
  rmSync(tempRoot, { recursive: true, force: true });
}
