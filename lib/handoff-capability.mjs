import {
  createHmac,
  randomUUID,
  timingSafeEqual,
} from "node:crypto";

const MAX_PACKET_BYTES = 24 * 1024;
const MAX_TOKEN_CHARS = 40 * 1024;
const FORBIDDEN_CONTROL =
  /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f\u202a-\u202e\u2066-\u2069]/u;

function assertText(value, name, { min = 0, max = 200 } = {}) {
  if (
    typeof value !== "string" ||
    value.length < min ||
    value.length > max ||
    FORBIDDEN_CONTROL.test(value)
  ) {
    throw new Error(
      `${name} must contain ${min}-${max} safe text characters`,
    );
  }
}

function assertId(value, name, pattern) {
  if (typeof value !== "string" || !pattern.test(value)) {
    throw new Error(`${name} is invalid`);
  }
}

export function normalizeHandoffPacket(packet) {
  if (!packet || typeof packet !== "object" || Array.isArray(packet)) {
    throw new Error("handoff packet must be an object");
  }
  assertId(
    packet.thread_id,
    "thread_id",
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu,
  );
  assertId(packet.task_id, "task_id", /^task-[A-Za-z0-9_-]{8,120}$/u);
  if (
    packet.environment_thread_id !== undefined &&
    packet.environment_thread_id !== null
  ) {
    assertId(
      packet.environment_thread_id,
      "environment_thread_id",
      /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu,
    );
  }
  assertText(packet.objective, "objective", { min: 1, max: 160 });
  assertText(packet.summary ?? "", "summary", { max: 800 });
  if (
    packet.domain_state !== undefined &&
    (packet.domain_state === null ||
      typeof packet.domain_state !== "object" ||
      Array.isArray(packet.domain_state))
  ) {
    throw new Error("domain_state must be an object");
  }
  if (
    !Array.isArray(packet.domain_refs) ||
    packet.domain_refs.length > 40
  ) {
    throw new Error("domain_refs must contain at most forty references");
  }
  const domainRefs = packet.domain_refs.map((item, index) => {
    assertId(
      item,
      `domain_refs[${index}]`,
      /^[A-Za-z0-9:_-]{1,160}$/u,
    );
    return item;
  });
  if (packet.read_only !== true) {
    throw new Error("handoff packet must declare read_only true");
  }
  return {
    thread_id: packet.thread_id.toLowerCase(),
    environment_thread_id: packet.environment_thread_id
      ? packet.environment_thread_id.toLowerCase()
      : null,
    task_id: packet.task_id,
    objective: packet.objective.trim(),
    summary: (packet.summary ?? "").trim(),
    domain_state: structuredClone(packet.domain_state ?? {}),
    domain_refs: domainRefs,
    read_only: true,
    source:
      packet.source === "agent-skill" || packet.source === "codex-skill"
        ? "agent-skill"
        : "local-helper",
  };
}

export function signHandoffToken(
  packet,
  secret,
  { ttlSeconds = 120, now = Date.now() } = {},
) {
  assertText(secret, "handoff secret", { min: 24, max: 512 });
  if (
    !Number.isInteger(ttlSeconds) ||
    ttlSeconds < 15 ||
    ttlSeconds > 600
  ) {
    throw new Error("handoff TTL must be between 15 and 600 seconds");
  }
  const normalized = normalizeHandoffPacket(packet);
  const payload = {
    schema_version: "1.0",
    audience: "agent-workbench-v1",
    issued_at: Math.floor(now / 1000),
    expires_at: Math.floor(now / 1000) + ttlSeconds,
    nonce: randomUUID(),
    packet: normalized,
  };
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString(
    "base64url",
  );
  const signature = createHmac("sha256", secret)
    .update(encoded)
    .digest("base64url");
  return {
    token: `${encoded}.${signature}`,
    nonce: payload.nonce,
    expires_at: new Date(payload.expires_at * 1_000).toISOString(),
    packet: normalized,
  };
}

export function verifyHandoffToken(
  token,
  secret,
  { now = Date.now() } = {},
) {
  if (
    typeof token !== "string" ||
    token.length < 32 ||
    token.length > MAX_TOKEN_CHARS
  ) {
    throw new Error("handoff token is missing or too large");
  }
  const [encoded, signature, ...rest] = token.split(".");
  if (!encoded || !signature || rest.length > 0) {
    throw new Error("handoff token format is invalid");
  }
  const expected = createHmac("sha256", secret)
    .update(encoded)
    .digest("base64url");
  const suppliedBuffer = Buffer.from(signature);
  const expectedBuffer = Buffer.from(expected);
  if (
    suppliedBuffer.length !== expectedBuffer.length ||
    !timingSafeEqual(suppliedBuffer, expectedBuffer)
  ) {
    throw new Error("handoff token signature is invalid");
  }
  let payload;
  try {
    payload = JSON.parse(
      Buffer.from(encoded, "base64url").toString("utf8"),
    );
  } catch {
    throw new Error("handoff token payload is invalid");
  }
  if (
    payload?.schema_version !== "1.0" ||
    payload.audience !== "agent-workbench-v1" ||
    !Number.isInteger(payload.issued_at) ||
    !Number.isInteger(payload.expires_at) ||
    typeof payload.nonce !== "string"
  ) {
    throw new Error("handoff token claims are invalid");
  }
  const nowSeconds = Math.floor(now / 1_000);
  if (
    payload.expires_at <= nowSeconds ||
    payload.issued_at > nowSeconds + 60 ||
    payload.expires_at - payload.issued_at > 600
  ) {
    throw new Error("handoff token is expired or has an invalid lifetime");
  }
  assertId(
    payload.nonce,
    "handoff nonce",
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu,
  );
  return {
    nonce: payload.nonce,
    issued_at: new Date(payload.issued_at * 1_000).toISOString(),
    expires_at: new Date(payload.expires_at * 1_000).toISOString(),
    packet: normalizeHandoffPacket(payload.packet),
  };
}

export const HANDOFF_LIMITS = {
  maxPacketBytes: MAX_PACKET_BYTES,
  maxTokenChars: MAX_TOKEN_CHARS,
};
