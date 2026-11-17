import { AgentDriver, AgentDriverError } from "./agent-driver.mjs";
import { AGENT_SANDBOX_MODES } from "../agent-permissions.mjs";

export class SourceExternalAgentDriver extends AgentDriver {
  constructor({ permissionProfile = {} } = {}) {
    super({
      name: "source-external",
      displayName: "本地分析 Agent",
      capabilities: {
        supportsStreaming: false,
        supportsThreadResume: false,
        supportsActiveThreadAttach: false,
        activeThreadAttachReason:
          "The real source Thread is owned by the controlled source runner.",
        supportsStructuredOutput: false,
        supportsApprovals: false,
        supportsApprovalDecision: false,
        sandboxModes: AGENT_SANDBOX_MODES,
        approvalModes: ["never"],
        supportsCancellation: false,
        supportsThreadNaming: false,
        sourceHostedExternal: true,
        adapterStatus: "source-hosted-read-only",
      },
      permissionProfile,
    });
  }

  async initialize() {
    return this.publicStatus();
  }

  async startThread() {
    throw new AgentDriverError(
      "blocked",
      "external_source_thread_required",
      "The controlled source runner owns the only real Agent Thread.",
    );
  }

  async sendTurn() {
    throw new AgentDriverError(
      "blocked",
      "panel_turn_forbidden_in_source_hosted",
      "A source-external preview cannot create a panel-owned model Turn.",
    );
  }

  async close() {
    this.activeThreadReference = null;
  }

  publicStatus() {
    return {
      connected: true,
      thread_id: null,
      thread_name: null,
      capabilities: this.capabilities,
    };
  }
}
