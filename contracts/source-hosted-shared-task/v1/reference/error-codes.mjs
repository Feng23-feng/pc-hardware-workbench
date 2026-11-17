import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(
  readFileSync(resolve(root, "errors.json"), "utf8"),
);

export const ERROR_CATALOG = Object.freeze(
  Object.fromEntries(
    Object.entries(catalog.codes).map(([code, value]) => [
      code,
      Object.freeze({ code, ...value }),
    ]),
  ),
);

export const ERROR_CODES = Object.freeze(Object.keys(ERROR_CATALOG));
export const ERROR_CODE_SET = new Set(ERROR_CODES);

export function errorResult({
  requestId = "request-error",
  taskId = "task-fixture",
  code,
  message,
  details = {},
}) {
  const metadata = ERROR_CATALOG[code];
  if (!metadata) {
    throw new TypeError(`Unknown contract error code: ${code}`);
  }
  return {
    ok: false,
    schema_version: "1.0",
    request_id: requestId,
    task_id: taskId,
    error: {
      code,
      classification: metadata.classification,
      message: String(message || metadata.description).slice(0, 500),
      retryable: metadata.retryable,
      details,
    },
  };
}
