export const AGENT_SANDBOX_MODES = Object.freeze([
  "read-only",
  "workspace-write",
  "danger-full-access",
]);

export const AGENT_APPROVAL_MODES = Object.freeze(["on-request", "never"]);

export const SURFACE_MODES = Object.freeze([
  "chat",
  "read-only",
  "interactive",
  "developer",
]);

export const DEFAULT_AGENT_PERMISSION_PROFILE = Object.freeze({
  sandbox: "read-only",
  approvalPolicy: "never",
  source: "safe-default",
});

export const DEFAULT_SURFACE_MODE = "read-only";

export const RUNTIME_RUNNING_CURRENT_WORKSPACE =
  "running-current-workspace";

export class AgentPermissionConfigError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "AgentPermissionConfigError";
    this.code = code;
  }
}

function requireMode(value, allowed, field) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (!allowed.includes(normalized)) {
    throw new AgentPermissionConfigError(
      "permission_mode_invalid",
      `${field} must be one of: ${allowed.join(", ")}; received "${normalized}"`,
    );
  }
  return normalized;
}

function requireStringList(value, field) {
  if (!Array.isArray(value)) {
    throw new AgentPermissionConfigError(
      "permission_capability_invalid",
      `${field} must be an array`,
    );
  }
  return Object.freeze(
    value.map((item) => String(item).trim()).filter(Boolean),
  );
}

export function normalizeAgentPermissionProfile(profile = {}) {
  const sandbox =
    profile.sandbox ??
    profile.sandboxMode ??
    DEFAULT_AGENT_PERMISSION_PROFILE.sandbox;
  const approvalPolicy =
    profile.approvalPolicy ??
    profile.approval ??
    DEFAULT_AGENT_PERMISSION_PROFILE.approvalPolicy;
  return Object.freeze({
    sandbox: requireMode(sandbox, AGENT_SANDBOX_MODES, "sandbox"),
    approvalPolicy: requireMode(
      approvalPolicy,
      AGENT_APPROVAL_MODES,
      "approvalPolicy",
    ),
    source: String(
      profile.source ?? DEFAULT_AGENT_PERMISSION_PROFILE.source,
    ).slice(0, 80),
  });
}

export function normalizeSurfaceMode(value = DEFAULT_SURFACE_MODE) {
  return requireMode(value, SURFACE_MODES, "surfaceMode");
}

export function assertSupportedAgentPermissionProfile(
  profile,
  {
    driverName,
    sandboxModes,
    approvalModes,
  },
) {
  const normalized = normalizeAgentPermissionProfile(profile);
  const supportedSandboxes = requireStringList(
    sandboxModes,
    "sandboxModes",
  );
  const supportedApprovals = requireStringList(
    approvalModes,
    "approvalModes",
  );
  if (!supportedSandboxes.includes(normalized.sandbox)) {
    throw new AgentPermissionConfigError(
      "permission_sandbox_unsupported",
      `${driverName} does not support sandbox "${normalized.sandbox}"; supported: ${
        supportedSandboxes.join(", ") || "none"
      }`,
    );
  }
  if (!supportedApprovals.includes(normalized.approvalPolicy)) {
    throw new AgentPermissionConfigError(
      "permission_approval_unsupported",
      `${driverName} does not support approval policy "${
        normalized.approvalPolicy
      }"; supported: ${supportedApprovals.join(", ") || "none"}`,
    );
  }
  return normalized;
}
