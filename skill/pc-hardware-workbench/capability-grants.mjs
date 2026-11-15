import { randomUUID } from "node:crypto";

export const CAPABILITY_PROFILE_READ_ONLY = "read-only-supervised";
export const PERMISSION_REQUEST_TTL_MS = 5 * 60 * 1000;
export const ONE_TIME_GRANT_TTL_MS = 10 * 60 * 1000;
export const TASK_GRANT_TTL_MS = 2 * 60 * 60 * 1000;

export function artifactRootRef(taskId) {
  if (!/^[A-Za-z0-9_-]{8,120}$/u.test(String(taskId))) {
    throw new Error("task_id is invalid");
  }
  return `runtime/artifacts/${taskId}`;
}

export function defaultCapabilityProfile(taskId, capabilityStates = {}) {
  return {
    schema_version: "1.0",
    profile: CAPABILITY_PROFILE_READ_ONLY,
    task_id: taskId,
    network: "disabled",
    general_command: "unavailable",
    system_write: "manual-only",
    capabilities: { ...capabilityStates },
  };
}

function normalizeWindow(window = {}) {
  const warmup =
    window.warmup_seconds === null || window.warmup_seconds === undefined
      ? null
      : Number(window.warmup_seconds);
  const duration =
    window.duration_seconds === null || window.duration_seconds === undefined
      ? null
      : Number(window.duration_seconds);
  return {
    warmup_seconds: Number.isInteger(warmup) ? warmup : null,
    duration_seconds: Number.isInteger(duration) ? duration : null,
  };
}

function windowSignature(window) {
  if (
    window.warmup_seconds === null &&
    window.duration_seconds === null
  ) {
    return "all";
  }
  return `warmup-${window.warmup_seconds}-duration-${window.duration_seconds}`;
}

export function createPermissionRequest({
  capability,
  presentation,
  taskId,
  attachment,
  window,
  now = Date.now(),
}) {
  if (
    !attachment?.id ||
    !attachment?.original_name ||
    !/^[a-f0-9]{64}$/u.test(attachment.sha256 ?? "")
  ) {
    throw new Error("attachment metadata is incomplete");
  }
  const normalizedWindow = normalizeWindow(window);
  return {
    schema_version: "1.0",
    request_id: `permission-request-${randomUUID()}`,
    status: "pending",
    capability,
    profile: CAPABILITY_PROFILE_READ_ONLY,
    task_id: taskId,
    attachment_id: attachment.id,
    attachment_name: attachment.original_name,
    attachment_size: attachment.size,
    attachment_sha256: attachment.sha256,
    artifact_root_ref: artifactRootRef(taskId),
    window: normalizedWindow,
    window_signature: windowSignature(normalizedWindow),
    network: "disabled",
    general_command: "unavailable",
    system_write: "unavailable",
    presentation,
    requested_at: new Date(now).toISOString(),
    expires_at: new Date(now + PERMISSION_REQUEST_TTL_MS).toISOString(),
  };
}

export function createCapabilityGrant({
  request,
  scope,
  now = Date.now(),
}) {
  if (!["one-time", "task"].includes(scope)) {
    throw new Error("grant scope must be one-time or task");
  }
  if (
    request?.status !== "pending" ||
    typeof request.capability !== "string" ||
    !request.capability
  ) {
    throw new Error("permission request is not grantable");
  }
  const ttl =
    scope === "one-time" ? ONE_TIME_GRANT_TTL_MS : TASK_GRANT_TTL_MS;
  return {
    schema_version: "1.0",
    grant_id: `grant-${randomUUID()}`,
    status: "active",
    scope,
    capability: request.capability,
    profile: CAPABILITY_PROFILE_READ_ONLY,
    task_id: request.task_id,
    attachment_id: request.attachment_id,
    attachment_sha256: request.attachment_sha256,
    artifact_root_ref: request.artifact_root_ref,
    window: request.window,
    window_signature: request.window_signature,
    network: "disabled",
    general_command: "unavailable",
    system_write: "unavailable",
    created_at: new Date(now).toISOString(),
    expires_at: new Date(now + ttl).toISOString(),
    consumed_at: null,
    revoked_at: null,
    expired_at: null,
    request_id: request.request_id,
  };
}

export function capabilityGrantMatches(
  grant,
  {
    taskId,
    attachment,
    capability,
    artifactRootRef: expectedArtifactRoot,
    window,
    now = Date.now(),
  },
) {
  if (
    !grant ||
    grant.status !== "active" ||
    grant.capability !== capability ||
    grant.task_id !== taskId ||
    grant.attachment_id !== attachment?.id ||
    grant.attachment_sha256 !== attachment?.sha256 ||
    grant.artifact_root_ref !== expectedArtifactRoot ||
    grant.network !== "disabled" ||
    grant.general_command !== "unavailable" ||
    grant.system_write !== "unavailable" ||
    Date.parse(grant.expires_at) <= now
  ) {
    return false;
  }
  if (grant.scope === "one-time") {
    return grant.window_signature === windowSignature(normalizeWindow(window));
  }
  return grant.scope === "task";
}

export function expireCapabilityState({
  permissionRequest,
  grants,
  now = Date.now(),
}) {
  const expiredGrants = [];
  for (const grant of grants ?? []) {
    if (grant.status === "active" && Date.parse(grant.expires_at) <= now) {
      grant.status = "expired";
      grant.expired_at = new Date(now).toISOString();
      expiredGrants.push(grant);
    }
  }
  let requestExpired = false;
  if (
    permissionRequest?.status === "pending" &&
    Date.parse(permissionRequest.expires_at) <= now
  ) {
    permissionRequest.status = "expired";
    permissionRequest.expired_at = new Date(now).toISOString();
    requestExpired = true;
  }
  return { expiredGrants, requestExpired };
}

export function consumeCapabilityGrant(grant, now = Date.now()) {
  if (grant.scope === "one-time") {
    grant.status = "consumed";
    grant.consumed_at = new Date(now).toISOString();
  }
  grant.last_used_at = new Date(now).toISOString();
  return grant;
}

export function revokeCapabilityGrant(grant, now = Date.now()) {
  if (grant.status !== "active") {
    return false;
  }
  grant.status = "revoked";
  grant.revoked_at = new Date(now).toISOString();
  return true;
}

export function activeCapabilityGrants(task, capability, now = Date.now()) {
  return (task?.grants ?? []).filter(
    (grant) =>
      grant.status === "active" &&
      grant.capability === capability &&
      Date.parse(grant.expires_at) > now,
  );
}

export function grantWindowSignature(window) {
  return windowSignature(normalizeWindow(window));
}
