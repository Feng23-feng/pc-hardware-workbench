import {
  assertSupportedAgentPermissionProfile,
} from "../agent-permissions.mjs";

const ERROR_CLASSES = new Set([
  "unavailable",
  "blocked",
  "auth",
  "permission",
  "protocol",
]);

export class AgentDriverError extends Error {
  constructor(classification, code, message, { cause = null } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = "AgentDriverError";
    this.classification = ERROR_CLASSES.has(classification)
      ? classification
      : "protocol";
    this.code = code || "agent_driver_error";
  }
}

export class AgentDriver {
  constructor({
    name,
    displayName,
    capabilities = {},
    permissionProfile = null,
  }) {
    this.name = name;
    this.displayName = displayName;
    this.activeThreadReference = null;
    this.activeThreadName = null;
    this.capabilities = Object.freeze({
      name,
      displayName,
      supportsStreaming: false,
      supportsThreadResume: false,
      supportsActiveThreadAttach: false,
      supportsStructuredOutput: false,
      supportsApprovals: false,
      supportsApprovalDecision: false,
      sandboxModes: [],
      approvalModes: [],
      supportsThreadNaming: false,
      ...capabilities,
    });
    this.permissionProfile = permissionProfile
      ? assertSupportedAgentPermissionProfile(permissionProfile, {
          driverName: this.displayName,
          sandboxModes: this.capabilities.sandboxModes,
          approvalModes: this.capabilities.approvalModes,
        })
      : null;
  }

  async initialize() {
    throw this.unsupported("initialize");
  }

  async close() {
    throw this.unsupported("close");
  }

  async startThread() {
    throw this.unsupported("startThread");
  }

  async resumeThread() {
    throw this.unsupported("resumeThread");
  }

  async sendTurn() {
    throw this.unsupported("sendTurn");
  }

  async cancel() {
    throw this.unsupported("cancel");
  }

  async setThreadName() {
    throw this.unsupported("setThreadName");
  }

  classifyError(error) {
    if (error instanceof AgentDriverError) {
      return error;
    }
    return new AgentDriverError(
      "protocol",
      "unclassified_agent_error",
      error?.message || "Agent driver failed",
      { cause: error },
    );
  }

  unsupported(operation, message = `${operation} is unsupported`) {
    return new AgentDriverError(
      "blocked",
      `unsupported_${operation}`,
      message,
    );
  }

  emit(onEvent, event) {
    if (typeof onEvent === "function") {
      onEvent({
        ...event,
        driver: this.name,
        at: new Date().toISOString(),
      });
    }
  }
}

export function driverPublicDescriptor(driver) {
  return {
    driver: driver.name,
    ...driver.capabilities,
    permission_profile: driver.permissionProfile,
    connected: Boolean(driver.activeThreadReference),
    thread_id: driver.activeThreadReference,
    thread_name: driver.activeThreadName,
  };
}
