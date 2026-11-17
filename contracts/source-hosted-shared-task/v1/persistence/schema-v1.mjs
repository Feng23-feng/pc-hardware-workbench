import { createHash } from "node:crypto";

export const SQLITE_SCHEMA_VERSION = 1;
export const SQLITE_APPLICATION_ID = 0x53544854; // "STHT"

export const SCHEMA_V1_SQL = `
CREATE TABLE schema_migrations (
  version INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  checksum TEXT NOT NULL,
  applied_at_ms INTEGER NOT NULL
) STRICT;

CREATE TABLE tasks (
  task_id TEXT PRIMARY KEY,
  contract_version TEXT NOT NULL,
  channel_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  objective TEXT NOT NULL,
  state_json TEXT NOT NULL CHECK (json_valid(state_json)),
  mode TEXT NOT NULL CHECK (mode IN ('source_hosted', 'panel_hosted', 'suspended')),
  owner_role TEXT NOT NULL CHECK (owner_role IN ('source', 'panel', 'none')),
  lease_id TEXT,
  fencing_epoch INTEGER NOT NULL CHECK (fencing_epoch >= 1),
  task_revision INTEGER NOT NULL CHECK (task_revision >= 0),
  stream_generation TEXT NOT NULL,
  head_seq INTEGER NOT NULL CHECK (head_seq >= 0),
  min_retained_seq INTEGER NOT NULL CHECK (min_retained_seq >= 1),
  status TEXT NOT NULL CHECK (status IN ('active', 'suspended', 'closed')),
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  closed_at_ms INTEGER,
  CHECK (
    (mode = 'source_hosted' AND owner_role = 'source' AND lease_id IS NOT NULL)
    OR
    (mode = 'panel_hosted' AND owner_role = 'panel' AND lease_id IS NOT NULL)
    OR
    (mode = 'suspended' AND owner_role = 'none' AND lease_id IS NULL)
  ),
  UNIQUE (workspace_id, channel_id),
  FOREIGN KEY (task_id, stream_generation)
    REFERENCES stream_generations(task_id, generation)
    DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE stream_generations (
  task_id TEXT NOT NULL,
  generation TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  retired_at_ms INTEGER,
  reason TEXT,
  PRIMARY KEY (task_id, generation),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id)
    DEFERRABLE INITIALLY DEFERRED
) STRICT;

CREATE TABLE mutations (
  mutation_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  operation TEXT NOT NULL CHECK (
    operation IN ('publish', 'claim_lease', 'release_lease', 'generation_reset', 'retention')
  ),
  actor_id TEXT NOT NULL,
  idempotency_key TEXT,
  committed_at_ms INTEGER NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome = 'applied'),
  CHECK (
    (operation IN ('publish', 'claim_lease', 'release_lease') AND idempotency_key IS NOT NULL)
    OR
    (operation IN ('generation_reset', 'retention') AND idempotency_key IS NULL)
  ),
  UNIQUE (task_id, mutation_id),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id)
) STRICT;

CREATE TABLE events (
  event_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  generation TEXT NOT NULL,
  stream_seq INTEGER NOT NULL CHECK (stream_seq >= 1),
  kind TEXT NOT NULL,
  authority TEXT NOT NULL,
  author_role TEXT NOT NULL CHECK (author_role IN ('source', 'panel', 'coordinator')),
  target_role TEXT NOT NULL CHECK (target_role IN ('source', 'panel', 'both')),
  execution_epoch INTEGER NOT NULL CHECK (execution_epoch >= 1),
  origin_json TEXT NOT NULL CHECK (json_valid(origin_json)),
  payload_json TEXT NOT NULL CHECK (json_valid(payload_json)),
  payload_sha256 TEXT NOT NULL,
  mutation_id TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  UNIQUE (task_id, generation, stream_seq),
  FOREIGN KEY (task_id, generation)
    REFERENCES stream_generations(task_id, generation),
  UNIQUE (task_id, event_id),
  FOREIGN KEY (task_id, mutation_id)
    REFERENCES mutations(task_id, mutation_id)
) STRICT;

CREATE INDEX events_task_generation_seq
  ON events(task_id, generation, stream_seq);

CREATE TABLE mailbox_delivery_state (
  task_id TEXT NOT NULL,
  actor_role TEXT NOT NULL CHECK (actor_role IN ('source', 'panel')),
  generation TEXT NOT NULL,
  delivered_seq_prefix INTEGER NOT NULL CHECK (delivered_seq_prefix >= 0),
  ack_coverage_prefix INTEGER NOT NULL CHECK (ack_coverage_prefix >= 0),
  updated_at_ms INTEGER NOT NULL,
  PRIMARY KEY (task_id, actor_role),
  FOREIGN KEY (task_id, generation)
    REFERENCES stream_generations(task_id, generation)
) STRICT;

CREATE TABLE event_acks (
  task_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  actor_role TEXT NOT NULL CHECK (actor_role IN ('source', 'panel')),
  acknowledged_at_ms INTEGER NOT NULL,
  PRIMARY KEY (task_id, event_id, actor_role),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  FOREIGN KEY (task_id, event_id) REFERENCES events(task_id, event_id)
) STRICT;

CREATE INDEX event_acks_task_actor
  ON event_acks(task_id, actor_role, acknowledged_at_ms);

CREATE TABLE idempotency_receipts (
  receipt_id TEXT PRIMARY KEY,
  mutation_id TEXT NOT NULL UNIQUE,
  task_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_role TEXT NOT NULL CHECK (actor_role IN ('source', 'panel', 'control')),
  operation TEXT NOT NULL CHECK (operation IN ('publish', 'claim_lease', 'release_lease')),
  idempotency_key TEXT NOT NULL,
  canonical_hash_alg TEXT NOT NULL CHECK (canonical_hash_alg = 'sha256'),
  canonical_hash TEXT NOT NULL,
  original_request_id TEXT NOT NULL,
  outcome TEXT NOT NULL CHECK (outcome = 'applied'),
  response_json TEXT NOT NULL CHECK (json_valid(response_json)),
  event_receipts_json TEXT CHECK (event_receipts_json IS NULL OR json_valid(event_receipts_json)),
  next_snapshot_json TEXT CHECK (next_snapshot_json IS NULL OR json_valid(next_snapshot_json)),
  task_revision INTEGER NOT NULL,
  stream_generation TEXT NOT NULL,
  head_seq INTEGER NOT NULL,
  committed_at_ms INTEGER NOT NULL,
  UNIQUE (task_id, actor_id, operation, idempotency_key),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  FOREIGN KEY (task_id, mutation_id)
    REFERENCES mutations(task_id, mutation_id),
  FOREIGN KEY (task_id, stream_generation)
    REFERENCES stream_generations(task_id, generation)
) STRICT;

CREATE INDEX idempotency_receipts_diagnostic
  ON idempotency_receipts(task_id, idempotency_key, canonical_hash);

CREATE TABLE mailbox_snapshots (
  snapshot_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_role TEXT NOT NULL CHECK (actor_role IN ('source', 'panel')),
  generation TEXT NOT NULL,
  snapshot_seq INTEGER NOT NULL CHECK (snapshot_seq >= 0),
  task_revision INTEGER NOT NULL CHECK (task_revision >= 0),
  fencing_epoch INTEGER NOT NULL CHECK (fencing_epoch >= 1),
  issued_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  invalidated_at_ms INTEGER,
  UNIQUE (snapshot_id, task_id, generation),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  FOREIGN KEY (task_id, generation)
    REFERENCES stream_generations(task_id, generation)
) STRICT;

CREATE INDEX mailbox_snapshots_expiry
  ON mailbox_snapshots(expires_at_ms);

CREATE TABLE mailbox_checkpoints (
  checkpoint_id TEXT PRIMARY KEY,
  snapshot_id TEXT NOT NULL,
  task_id TEXT NOT NULL,
  generation TEXT NOT NULL,
  snapshot_seq INTEGER NOT NULL CHECK (snapshot_seq >= 0),
  task_revision INTEGER NOT NULL CHECK (task_revision >= 0),
  fencing_epoch INTEGER NOT NULL CHECK (fencing_epoch >= 1),
  required_coverage_prefix INTEGER NOT NULL CHECK (required_coverage_prefix >= 0),
  issued_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  consumed_at_ms INTEGER,
  FOREIGN KEY (snapshot_id, task_id, generation)
    REFERENCES mailbox_snapshots(snapshot_id, task_id, generation),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  FOREIGN KEY (task_id, generation)
    REFERENCES stream_generations(task_id, generation)
) STRICT;

CREATE TABLE confirmations (
  confirmation_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  target_mode TEXT NOT NULL,
  issued_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  consumed_at_ms INTEGER,
  consumed_operation TEXT,
  FOREIGN KEY (task_id) REFERENCES tasks(task_id)
) STRICT;

CREATE TABLE authority_verifiers (
  verifier_sha256 TEXT PRIMARY KEY,
  handle_id TEXT NOT NULL UNIQUE,
  kind TEXT NOT NULL CHECK (kind IN ('mailbox', 'lease_control')),
  task_id TEXT NOT NULL,
  workspace_id TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_role TEXT,
  mailbox_profile TEXT,
  execution_epoch INTEGER,
  stream_generation TEXT NOT NULL,
  allowed_actions_json TEXT NOT NULL CHECK (json_valid(allowed_actions_json)),
  permitted_authority_json TEXT NOT NULL CHECK (json_valid(permitted_authority_json)),
  rotation_generation INTEGER NOT NULL,
  issued_at_ms INTEGER NOT NULL,
  expires_at_ms INTEGER NOT NULL,
  revoked_at_ms INTEGER,
  revoked_reason TEXT,
  CHECK (
    (kind = 'mailbox' AND actor_role IN ('source', 'panel')
      AND mailbox_profile IN ('standard', 'recovery', 'recovery_ack')
      AND execution_epoch IS NOT NULL)
    OR
    (kind = 'lease_control' AND actor_role IS NULL
      AND mailbox_profile IS NULL AND execution_epoch IS NULL)
  ),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  FOREIGN KEY (task_id, stream_generation)
    REFERENCES stream_generations(task_id, generation)
) STRICT;

CREATE INDEX authority_verifiers_expiry
  ON authority_verifiers(expires_at_ms);

CREATE TABLE owner_transitions (
  transition_id TEXT PRIMARY KEY,
  task_id TEXT NOT NULL,
  from_mode TEXT NOT NULL,
  from_owner TEXT NOT NULL,
  from_epoch INTEGER NOT NULL,
  to_mode TEXT NOT NULL,
  to_owner TEXT NOT NULL,
  to_epoch INTEGER NOT NULL,
  checkpoint_id TEXT,
  confirmation_id TEXT,
  checkpoint_generation TEXT,
  checkpoint_snapshot_seq INTEGER,
  confirmation_kind TEXT,
  confirmation_target_mode TEXT,
  transition_event_id TEXT NOT NULL,
  mutation_id TEXT NOT NULL,
  created_at_ms INTEGER NOT NULL,
  UNIQUE (task_id, to_epoch),
  FOREIGN KEY (task_id) REFERENCES tasks(task_id),
  FOREIGN KEY (task_id, transition_event_id)
    REFERENCES events(task_id, event_id),
  FOREIGN KEY (task_id, mutation_id)
    REFERENCES mutations(task_id, mutation_id)
) STRICT;

CREATE TRIGGER tasks_current_generation_insert
AFTER INSERT ON tasks
BEGIN
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM stream_generations
      WHERE task_id = NEW.task_id
        AND generation = NEW.stream_generation
        AND retired_at_ms IS NULL
    )
    THEN RAISE(ABORT, 'task current generation missing or retired')
  END;
END;

CREATE TRIGGER tasks_current_generation_update
AFTER UPDATE OF stream_generation ON tasks
BEGIN
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM stream_generations
      WHERE task_id = NEW.task_id
        AND generation = NEW.stream_generation
        AND retired_at_ms IS NULL
    )
    THEN RAISE(ABORT, 'task current generation missing or retired')
  END;
END;

CREATE TRIGGER stream_generations_prevent_retire_current
BEFORE UPDATE OF retired_at_ms ON stream_generations
WHEN NEW.retired_at_ms IS NOT NULL
BEGIN
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM tasks
      WHERE task_id = OLD.task_id
        AND stream_generation = OLD.generation
    )
    THEN RAISE(ABORT, 'cannot retire current task generation')
  END;
END;

CREATE TRIGGER stream_generations_prevent_delete_current
BEFORE DELETE ON stream_generations
BEGIN
  SELECT CASE
    WHEN EXISTS (
      SELECT 1 FROM tasks
      WHERE task_id = OLD.task_id
        AND stream_generation = OLD.generation
    )
    THEN RAISE(ABORT, 'cannot delete current task generation')
  END;
END;

CREATE TRIGGER authority_verifiers_require_active_generation_insert
BEFORE INSERT ON authority_verifiers
BEGIN
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM stream_generations
      WHERE task_id = NEW.task_id
        AND generation = NEW.stream_generation
        AND retired_at_ms IS NULL
    )
    THEN RAISE(ABORT, 'authority verifier generation is missing or retired')
  END;
END;

CREATE TRIGGER authority_verifiers_require_active_generation_update
BEFORE UPDATE OF task_id, stream_generation ON authority_verifiers
BEGIN
  SELECT CASE
    WHEN NOT EXISTS (
      SELECT 1 FROM stream_generations
      WHERE task_id = NEW.task_id
        AND generation = NEW.stream_generation
        AND retired_at_ms IS NULL
    )
    THEN RAISE(ABORT, 'authority verifier generation is missing or retired')
  END;
END;
`;

export const SCHEMA_V1_SHA256 = createHash("sha256")
  .update(SCHEMA_V1_SQL, "utf8")
  .digest("hex");

function userVersion(db) {
  return Number(db.prepare("PRAGMA user_version").get().user_version);
}

export function configureDatabase(db, {
  busyTimeoutMs = 5_000,
} = {}) {
  db.exec(`PRAGMA busy_timeout = ${Math.max(1, Math.floor(busyTimeoutMs))};`);
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec("PRAGMA synchronous = FULL;");
  db.exec("PRAGMA wal_autocheckpoint = 1000;");
  db.exec("PRAGMA temp_store = MEMORY;");
  db.exec("PRAGMA trusted_schema = OFF;");
  const modes = {
    journal_mode: String(db.prepare("PRAGMA journal_mode").get().journal_mode).toLowerCase(),
    synchronous: Number(db.prepare("PRAGMA synchronous").get().synchronous),
    foreign_keys: Number(db.prepare("PRAGMA foreign_keys").get().foreign_keys),
  };
  if (
    modes.journal_mode !== "wal" ||
    modes.synchronous !== 2 ||
    modes.foreign_keys !== 1
  ) {
    throw new Error(`SQLite conformance profile mismatch: ${JSON.stringify(modes)}`);
  }
  return modes;
}

export function migrateToV1(db, { now = Date.now } = {}) {
  const version = userVersion(db);
  if (version > SQLITE_SCHEMA_VERSION) {
    throw new Error(`Database schema ${version} is newer than supported v1`);
  }
  if (version === SQLITE_SCHEMA_VERSION) {
    const row = db.prepare(
      "SELECT checksum FROM schema_migrations WHERE version = 1",
    ).get();
    if (!row || row.checksum !== SCHEMA_V1_SHA256) {
      throw new Error("SQLite schema v1 checksum mismatch");
    }
    return { applied: false, version };
  }
  db.exec("BEGIN IMMEDIATE;");
  try {
    db.exec(SCHEMA_V1_SQL);
    db.prepare(
      `INSERT INTO schema_migrations(version, name, checksum, applied_at_ms)
       VALUES(1, ?, ?, ?)`,
    ).run("source_hosted_shared_task_v1", SCHEMA_V1_SHA256, now());
    db.exec(`PRAGMA application_id = ${SQLITE_APPLICATION_ID};`);
    db.exec(`PRAGMA user_version = ${SQLITE_SCHEMA_VERSION};`);
    db.exec("COMMIT;");
  } catch (error) {
    try {
      db.exec("ROLLBACK;");
    } catch {
      // Preserve the migration error.
    }
    throw error;
  }
  return { applied: true, version: SQLITE_SCHEMA_VERSION };
}
