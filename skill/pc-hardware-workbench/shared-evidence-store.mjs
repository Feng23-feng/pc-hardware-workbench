import {
  createHash,
  randomUUID,
} from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

function emptyStore() {
  return {
    schema_version: "1.0",
    store_id: "local-device-evidence",
    device_snapshot: {
      ref: "device-snapshot:not-collected",
      captured_date: null,
      identity_quality: "unknown",
      privacy_mode: "local-private",
      device_alias: "尚未采集设备",
      summary: "没有可复用的设备配置快照。",
    },
    evidence_refs: [],
    updated_at: new Date().toISOString(),
  };
}

export class SharedEvidenceStore {
  constructor(filePath) {
    this.filePath = filePath;
    const persisted = existsSync(filePath);
    this.data = persisted
      ? JSON.parse(readFileSync(filePath, "utf8"))
      : emptyStore();
  }

  save() {
    this.data.updated_at = new Date().toISOString();
    mkdirSync(dirname(this.filePath), { recursive: true });
    const tempPath = `${this.filePath}.tmp`;
    writeFileSync(tempPath, `${JSON.stringify(this.data, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    renameSync(tempPath, this.filePath);
  }

  deviceContext() {
    const device = this.data.device_snapshot;
    const capturedAt = device.captured_date
      ? Date.parse(`${device.captured_date}T00:00:00+08:00`)
      : null;
    const ageDays = Number.isFinite(capturedAt)
      ? Math.max(0, Math.floor((Date.now() - capturedAt) / 86_400_000))
      : null;
    return {
      device_snapshot_ref: device.ref,
      device_alias: device.device_alias,
      captured_date: device.captured_date,
      age_days: ageDays,
      identity_quality: device.identity_quality,
      privacy_mode: device.privacy_mode,
      summary: device.summary,
      collector_runs: 0,
      evidence_refs: this.data.evidence_refs.map((item) => ({
        id: item.id,
        kind: item.kind,
        label: item.label,
        captured_at: item.captured_at,
        sha256: item.sha256,
      })),
    };
  }

  evidenceIds() {
    return this.data.evidence_refs.map((item) => item.id);
  }

  addEvidence({ label, detail, source }) {
    const content = JSON.stringify({ label, detail, source });
    const evidence = {
      id: `evidence-${randomUUID()}`,
      kind: "user_report",
      label,
      detail,
      source,
      captured_at: new Date().toISOString(),
      sha256: createHash("sha256").update(content).digest("hex"),
    };
    this.data.evidence_refs.push(evidence);
    this.save();
    return evidence;
  }

  addAttachment(attachment) {
    const evidence = {
      id: attachment.id,
      kind: "attachment",
      label: attachment.original_name,
      detail: `${attachment.mime_type} · ${attachment.size} bytes`,
      source: "user_attachment",
      captured_at: attachment.added_at,
      sha256: attachment.sha256,
      local_path: attachment.local_path,
      attachment: {
        original_name: attachment.original_name,
        mime_type: attachment.mime_type,
        size: attachment.size,
      },
    };
    if (!this.data.evidence_refs.some((item) => item.id === evidence.id)) {
      this.data.evidence_refs.push(evidence);
      this.save();
    }
    return evidence;
  }
}
