import { createHash } from "node:crypto";

const TOP_LEVEL_TRANSPORT_FIELDS = new Set([
  "request_id",
  "idempotency_key",
]);

function canonicalJsonString(value, path, ancestors) {
  if (
    value === null ||
    typeof value === "string" ||
    typeof value === "boolean"
  ) {
    return JSON.stringify(value);
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new TypeError(`${path} must be a finite JSON number`);
    }
    return JSON.stringify(Object.is(value, -0) ? 0 : value);
  }
  if (typeof value !== "object") {
    throw new TypeError(`${path} is not a JSON value`);
  }
  if (ancestors.has(value)) {
    throw new TypeError(`${path} contains a cycle`);
  }
  ancestors.add(value);
  try {
    if (Array.isArray(value)) {
      const items = [];
      for (let index = 0; index < value.length; index += 1) {
        items.push(
          canonicalJsonString(
            value[index],
            `${path}[${index}]`,
            ancestors,
          ),
        );
      }
      return `[${items.join(",")}]`;
    }
    const prototype = Object.getPrototypeOf(value);
    if (prototype !== Object.prototype && prototype !== null) {
      throw new TypeError(`${path} must be a plain object`);
    }
    const keys = Object.keys(value).sort();
    return `{${keys.map((key) =>
      `${JSON.stringify(key)}:${canonicalJsonString(
        value[key],
        `${path}.${key}`,
        ancestors,
      )}`).join(",")}}`;
  } finally {
    ancestors.delete(value);
  }
}

export function canonicalizeJson(value) {
  return JSON.parse(canonicalJson(value));
}

export function canonicalJson(value) {
  return canonicalJsonString(value, "$", new Set());
}

export function canonicalRequestPayload(operation, request) {
  if (typeof operation !== "string" || !operation) {
    throw new TypeError("operation must be a non-empty string");
  }
  if (!request || typeof request !== "object" || Array.isArray(request)) {
    throw new TypeError("request must be an object");
  }
  const payload = Object.create(null);
  for (const [key, value] of Object.entries(request)) {
    if (!TOP_LEVEL_TRANSPORT_FIELDS.has(key)) {
      payload[key] = value;
    }
  }
  return canonicalizeJson({ operation, payload });
}

export function canonicalRequestHash(operation, request) {
  return createHash("sha256")
    .update(canonicalJson(canonicalRequestPayload(operation, request)), "utf8")
    .digest("hex");
}
