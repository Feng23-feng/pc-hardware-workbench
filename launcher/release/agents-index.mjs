import {
  AgentDriverError,
  driverPublicDescriptor,
} from "../agents/agent-driver.mjs";
import {
  SourceExternalAgentDriver,
} from "../agents/source-external-agent-driver.mjs";

export const AGENT_DRIVER_NAMES = Object.freeze(["source-external"]);

export function resolveAgentDriverName(env = process.env) {
  const configured = String(env.PANEL_AGENT_DRIVER ?? "").trim();
  const name = (configured || "source-external").toLowerCase();
  if (!AGENT_DRIVER_NAMES.includes(name)) {
    throw new AgentDriverError(
      "protocol",
      "invalid_driver_configuration",
      `PANEL_AGENT_DRIVER must be source-external; received "${name}"`,
    );
  }
  return name;
}

export function createAgentDriver(name, options = {}) {
  if (name === "source-external") {
    return new SourceExternalAgentDriver(options);
  }
  throw new AgentDriverError(
    "protocol",
    "unsupported_agent_driver",
    `Agent driver "${name}" is unavailable in the PCHW release candidate`,
  );
}

export {
  AgentDriver,
  AgentDriverError,
  driverPublicDescriptor,
} from "../agents/agent-driver.mjs";
export {
  SourceExternalAgentDriver,
} from "../agents/source-external-agent-driver.mjs";
