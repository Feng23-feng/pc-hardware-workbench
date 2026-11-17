import { readFileSync } from "node:fs";
import {
  openSqliteConformanceCoordinator,
} from "./sqlite-coordinator.mjs";

const dbPath = String(process.env.SQ_DB_PATH ?? "");
const action = String(process.env.SQ_ACTION ?? "publish");
const faultPoint = String(process.env.SQ_FAULT_POINT ?? "");

if (!dbPath) {
  process.stderr.write("SQ_DB_PATH is required\n");
  process.exit(2);
}

function faultInjector(point) {
  if (faultPoint && point === faultPoint) {
    process.exit(faultPoint === "after_commit_before_response" ? 77 : 78);
  }
}

let coordinator;
try {
  const requestText = readFileSync(0, "utf8");
  const input = JSON.parse(requestText);
  const token = String(input.token ?? "");
  if (!token) {
    process.stderr.write("stdin token is required\n");
    process.exit(2);
  }
  const request = input.request;
  coordinator = openSqliteConformanceCoordinator({
    dbPath,
    faultInjector,
  });
  if (action !== "publish") {
    process.stderr.write(`Unsupported worker action: ${action}\n`);
    process.exit(2);
  }
  const response = coordinator.publish(token, request);
  process.stdout.write(`${JSON.stringify(response)}\n`);
} catch (error) {
  process.stderr.write(`${String(error?.code ?? error?.name ?? "error")}: ${String(error?.message ?? error).slice(0, 300)}\n`);
  process.exitCode = 1;
} finally {
  try {
    coordinator?.close();
  } catch {
    // Best effort for normal exits. Injected crash exits happen before finally.
  }
}
