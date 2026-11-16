import assert from "node:assert/strict";
import { mergePersistentPanelState } from "../lib/panel-state-merge.mjs";

const artifact = {
  id: "artifact-telemetry",
  kind: "chart",
  mime: "image/svg+xml",
  title: "Telemetry",
  relative_path: "task-one/artifact-telemetry.svg",
  sha256: "a".repeat(64),
  source_evidence_ids: ["attachment-one"],
  created_at: "2026-11-16T00:00:00.000Z",
  safeToEmbed: true,
  size: 100,
};
const previous = {
  schema_version: "1.2",
  turn_summary: "Telemetry analyzed.",
  artifact_refs: [artifact],
  blocks: [
    {
      id: "telemetry-metrics",
      type: "metrics",
      title: "Metrics",
      items: [],
    },
    {
      id: "telemetry-table",
      type: "table",
      title: "Table",
      columns: ["A"],
      rows: [["1"]],
    },
    {
      id: "telemetry-chart",
      type: "chart",
      title: "Chart",
      artifact_ref: artifact.id,
      alt: "Telemetry chart",
    },
    {
      id: "telemetry-download",
      type: "artifact-download",
      title: "Download",
      artifact_ref: artifact.id,
      label: "Download SVG",
    },
  ],
};
const current = {
  schema_version: "1.2",
  turn_summary: "Continue from telemetry.",
  artifact_refs: [],
  blocks: [],
};

const merged = mergePersistentPanelState(previous, current);
assert.equal(merged.turn_summary, current.turn_summary);
assert.deepEqual(merged.artifact_refs, [artifact]);
assert.deepEqual(
  merged.blocks.map((block) => block.id),
  [
    "telemetry-metrics",
    "telemetry-table",
    "telemetry-chart",
    "telemetry-download",
  ],
);
assert.equal(mergePersistentPanelState(null, current), current);
console.log("Persistent panel artifact merge: PASS");
