import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  openSqliteConformanceCoordinator,
} from "./sqlite-coordinator.mjs";

export function createTempSqliteFixture(options = {}) {
  const dir = options.directory
    ? resolve(options.directory)
    : mkdtempSync(join(tmpdir(), "skilldock-sqlite-fixture-"));
  if (options.directory) {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
  }
  const dbPath = join(dir, "mailbox.sqlite3");
  let coordinator = openSqliteConformanceCoordinator({
    ...options,
    dbPath,
  });
  const bootstrap = coordinator.bootstrapFixture(options.fixture ?? {});
  let closed = false;
  return {
    dir,
    dbPath,
    coordinator,
    bootstrap,
    reopen(reopenOptions = {}) {
      if (!closed) {
        coordinator.close();
        closed = true;
      }
      coordinator = openSqliteConformanceCoordinator({
        ...options,
        ...reopenOptions,
        dbPath,
      });
      closed = false;
      return coordinator;
    },
    close() {
      if (!closed) {
        coordinator.close();
        closed = true;
      }
    },
    cleanup() {
      if (!closed) {
        coordinator.close();
        closed = true;
      }
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
