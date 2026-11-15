import {
  AgentDriverError,
  driverPublicDescriptor,
} from "./agent-driver.mjs";
import { CodexAgentDriver } from "./codex-agent-driver.mjs";
import { DSHAgentDriver } from "./dsh-agent-driver.mjs";
import { DSHWebAgentDriver } from "./dsh-web-agent-driver.mjs";
import { MockAgentDriver } from "./mock-agent-driver.mjs";

export const AGENT_DRIVER_NAMES = Object.freeze([
  "codex",
  "dsh",
  "dsh-web",
  "mock",
]);

export function resolveAgentDriverName(env = process.env) {
  const configured = String(env.PANEL_AGENT_DRIVER ?? "").trim();
  const legacy =
    !configured && env.PANEL_AGENT_MODE === "mock"
      ? "mock"
      : !configured && env.PANEL_AGENT_MODE === "live"
        ? "codex"
        : null;
  const name = (configured || legacy || "codex").toLowerCase();
  if (!AGENT_DRIVER_NAMES.includes(name)) {
    throw new AgentDriverError(
      "protocol",
      "invalid_driver_configuration",
      `PANEL_AGENT_DRIVER must be one of: ${AGENT_DRIVER_NAMES.join(", ")}; received "${name}"`,
    );
  }
  return name;
}

export function createAgentDriver(name, options = {}) {
  if (name === "codex") {
    return new CodexAgentDriver(options);
  }
  if (name === "mock") {
    return new MockAgentDriver(options);
  }
  if (name === "dsh") {
    return new DSHAgentDriver(options);
  }
  if (name === "dsh-web") {
    return new DSHWebAgentDriver(options);
  }
  throw new AgentDriverError(
    "protocol",
    "unsupported_agent_driver",
    `Agent driver "${name}" is not implemented`,
  );
}

export {
  AgentDriver,
  AgentDriverError,
  driverPublicDescriptor,
} from "./agent-driver.mjs";
export { CodexAgentDriver } from "./codex-agent-driver.mjs";
export { DSHAgentDriver } from "./dsh-agent-driver.mjs";
export { DSHWebAgentDriver } from "./dsh-web-agent-driver.mjs";
export { DSHWebRpcClient } from "./dsh-web-rpc-client.mjs";
export { MockAgentDriver } from "./mock-agent-driver.mjs";
