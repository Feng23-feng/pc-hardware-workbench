import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import readline from "node:readline";
import { AgentDriver, AgentDriverError } from "./agent-driver.mjs";
import { PANEL_DEVELOPER_INSTRUCTIONS } from "../panel-response.mjs";
import {
  AGENT_SANDBOX_MODES,
  normalizeAgentPermissionProfile,
} from "../agent-permissions.mjs";

export class CodexAgentDriver extends AgentDriver {
  constructor({
    cwd,
    timeoutMs = 300_000,
    protocolLogPath = null,
    executable = "codex",
    args = ["app-server"],
    permissionProfile = {},
  }) {
    const normalizedPermissionProfile =
      normalizeAgentPermissionProfile(permissionProfile);
    super({
      name: "codex",
      displayName: "Codex",
      capabilities: {
        supportsStreaming: true,
        supportsThreadResume: true,
        supportsActiveThreadAttach: false,
        activeThreadAttachReason:
          "The source conversation is owned by another active agent client.",
        supportsStructuredOutput: true,
        supportsApprovals: false,
        supportsApprovalDecision: false,
        sandboxModes: AGENT_SANDBOX_MODES,
        approvalModes: ["never"],
        supportsCancellation: true,
        supportsThreadNaming: true,
        adapterStatus: "experimental",
      },
      permissionProfile: normalizedPermissionProfile,
    });
    this.cwd = cwd;
    this.timeoutMs = timeoutMs;
    this.protocolLogPath = protocolLogPath;
    this.executable = executable;
    this.args = args;
    this.nextId = 1;
    this.pending = new Map();
    this.turnWaiters = new Map();
    this.agentMessages = new Map();
    this.agentDeltas = new Map();
    this.turnEventHandlers = new Map();
    this.turnEventBuffers = new Map();
    this.completedTurns = new Map();
    this.stderrTail = "";
    this.sentTurn = false;
  }

  async initialize() {
    this.child = spawn(this.executable, this.args, {
      cwd: this.cwd,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
    this.child.stderr.on("data", (chunk) => {
      this.stderrTail = `${this.stderrTail}${chunk.toString()}`.slice(-16_384);
    });
    this.child.once("error", (error) => {
      this.failPending(
        new AgentDriverError(
          "unavailable",
          "driver_spawn_failed",
          `Codex driver could not start: ${error.message}`,
          { cause: error },
        ),
      );
    });
    this.child.once("exit", (code, signal) => {
      this.failPending(
        new AgentDriverError(
          "unavailable",
          "driver_exited",
          `Codex driver exited before the panel stopped (code=${code}, signal=${signal})`,
        ),
      );
    });
    const input = readline.createInterface({ input: this.child.stdout });
    input.on("line", (line) => this.handleLine(line));
    this.input = input;

    await this.request("initialize", {
      clientInfo: {
        name: "agent_workbench",
        title: "SkillDock",
        version: "0.1.0",
      },
      capabilities: {
        experimentalApi: true,
        requestAttestation: false,
      },
    });
    this.notify("initialized");
    return this.publicStatus();
  }

  failPending(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timeout);
      pending.reject(error);
    }
    this.pending.clear();
    for (const waiter of this.turnWaiters.values()) {
      waiter.reject(error);
    }
    this.turnWaiters.clear();
  }

  async startThread() {
    const created = await this.request("thread/start", {
      cwd: this.cwd,
      approvalPolicy: this.permissionProfile.approvalPolicy,
      sandbox: this.permissionProfile.sandbox,
      ephemeral: false,
      developerInstructions: PANEL_DEVELOPER_INSTRUCTIONS,
    });
    this.activeThreadReference = created.thread.id;
    this.sentTurn = false;
    return { threadReference: this.activeThreadReference, resumed: false };
  }

  async resumeThread(threadReference) {
    try {
      const resumed = await this.request("thread/resume", {
        threadId: threadReference,
        cwd: this.cwd,
        approvalPolicy: this.permissionProfile.approvalPolicy,
        sandbox: this.permissionProfile.sandbox,
        developerInstructions: PANEL_DEVELOPER_INSTRUCTIONS,
        excludeTurns: true,
      });
      this.activeThreadReference = resumed.thread.id;
      this.sentTurn = true;
      return { threadReference: this.activeThreadReference, resumed: true };
    } catch (error) {
      throw this.classifyError(error);
    }
  }

  async setThreadName(name) {
    if (!this.capabilities.supportsThreadNaming) {
      throw this.unsupported("setThreadName");
    }
    if (!this.activeThreadReference) {
      throw new AgentDriverError(
        "unavailable",
        "no_active_thread",
        "No agent thread is active",
      );
    }
    const normalized = String(name).trim().slice(0, 80);
    if (!normalized) {
      throw new AgentDriverError(
        "protocol",
        "invalid_thread_name",
        "Thread name cannot be empty",
      );
    }
    await this.request("thread/name/set", {
      threadId: this.activeThreadReference,
      name: normalized,
    });
    this.activeThreadName = normalized;
    return normalized;
  }

  request(method, params, timeoutMs = 30_000) {
    if (!this.child?.stdin.writable) {
      return Promise.reject(
        new AgentDriverError(
          "unavailable",
          "driver_not_running",
          "Codex driver is not running",
        ),
      );
    }
    const id = this.nextId++;
    this.writeMessage({ id, method, params });
    return new Promise((resolvePromise, reject) => {
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(
          new AgentDriverError(
            "unavailable",
            "driver_request_timeout",
            `${method} timed out`,
          ),
        );
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timeout);
          resolvePromise(value);
        },
        reject: (error) => {
          clearTimeout(timeout);
          reject(this.classifyError(error));
        },
      });
    });
  }

  notify(method) {
    this.writeMessage({ method });
  }

  writeMessage(message) {
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
    if (this.protocolLogPath) {
      appendFileSync(
        this.protocolLogPath,
        `${JSON.stringify({ direction: "out", ...message })}\n`,
        "utf8",
      );
    }
  }

  handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      return;
    }
    if (this.protocolLogPath) {
      appendFileSync(
        this.protocolLogPath,
        `${JSON.stringify({ direction: "in", ...message })}\n`,
        "utf8",
      );
    }
    if (message.id && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) {
        pending.reject(new Error(JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
      return;
    }
    const params = message.params;
    if (message.method === "item/agentMessage/delta" && params?.turnId) {
      const previous = this.agentDeltas.get(params.turnId) ?? "";
      this.agentDeltas.set(params.turnId, `${previous}${params.delta ?? ""}`);
      this.deliverTurnEvent(params.turnId, {
        type: "text_delta",
        turnId: params.turnId,
        delta: params.delta ?? "",
      });
    }
    if (
      message.method === "item/completed" &&
      params?.item?.type === "agentMessage"
    ) {
      this.agentMessages.set(params.turnId, params.item.text ?? "");
      this.deliverTurnEvent(params.turnId, {
        type: "message_completed",
        turnId: params.turnId,
      });
    }
    if (message.method === "turn/started" && params?.turn?.id) {
      this.deliverTurnEvent(params.turn.id, {
        type: "turn_started",
        turnId: params.turn.id,
      });
    }
    if (message.method === "turn/completed" && params?.turn?.id) {
      this.completedTurns.set(params.turn.id, params.turn);
      this.deliverTurnEvent(params.turn.id, {
        type: "turn_completed",
        turnId: params.turn.id,
        status: params.turn.status,
      });
      const waiter = this.turnWaiters.get(params.turn.id);
      if (waiter) {
        this.turnWaiters.delete(params.turn.id);
        this.completedTurns.delete(params.turn.id);
        waiter.resolve(params.turn);
      }
    }
  }

  deliverTurnEvent(turnId, event) {
    const handler = this.turnEventHandlers.get(turnId);
    if (handler) {
      this.emit(handler, event);
      return;
    }
    const buffered = this.turnEventBuffers.get(turnId) ?? [];
    buffered.push(event);
    this.turnEventBuffers.set(turnId, buffered);
  }

  async sendTurn({
    threadReference,
    eventId,
    packet,
    structuredOutputSchema,
    onEvent = null,
  }) {
    if (
      !this.activeThreadReference ||
      threadReference !== this.activeThreadReference
    ) {
      throw new AgentDriverError(
        "unavailable",
        "thread_not_active",
        "The requested agent thread is not active",
      );
    }
    const input = [];
    input.push({
      type: "text",
      text: [
        "PANEL RESPONSE CONTRACT v1.2:",
        "Use schema_version 1.2. Include judgement, evidence with supports/conflicts/context, uncertainty, 2-3 low-risk evidence-collection recommendations, priorityAction, and copy-only actions.",
        "Set blocks and artifact_refs to empty arrays unless the supplied skill instructions explicitly allow verified local artifact references. Never invent artifact paths, metric values, HTML, or JavaScript.",
        "Follow packet.skill_context.instructions. Use the supplied Task and Skill context; do not infer a different domain.",
        JSON.stringify(packet),
      ].join("\n"),
      text_elements: [],
    });
    const started = await this.request(
      "turn/start",
      {
        threadId: this.activeThreadReference,
        clientUserMessageId: eventId,
        input,
        outputSchema: structuredOutputSchema ?? null,
      },
      30_000,
    );
    this.sentTurn = true;
    const turnId = started.turn.id;
    if (typeof onEvent === "function") {
      this.turnEventHandlers.set(turnId, onEvent);
      for (const buffered of this.turnEventBuffers.get(turnId) ?? []) {
        this.emit(onEvent, buffered);
      }
      this.turnEventBuffers.delete(turnId);
    }
    let completed = this.completedTurns.get(turnId);
    if (completed) {
      this.completedTurns.delete(turnId);
    } else {
      completed = await new Promise((resolvePromise, reject) => {
          const timeout = setTimeout(() => {
            this.turnWaiters.delete(turnId);
            reject(
              new AgentDriverError(
                "unavailable",
                "agent_turn_timeout",
                "Agent turn timed out",
              ),
            );
          }, this.timeoutMs);
          this.turnWaiters.set(turnId, {
            resolve: (turn) => {
              clearTimeout(timeout);
              resolvePromise(turn);
            },
            reject: (error) => {
              clearTimeout(timeout);
              reject(this.classifyError(error));
            },
          });
        });
    }
    this.turnEventHandlers.delete(turnId);

    if (completed.status !== "completed") {
      const detail = completed.error?.message
        ? `: ${completed.error.message.slice(0, 500)}`
        : "";
      throw new AgentDriverError(
        completed.status === "interrupted" ? "blocked" : "protocol",
        "agent_turn_not_completed",
        `Agent turn ended with status ${completed.status}${detail}`,
      );
    }
    const finalText =
      this.agentMessages.get(turnId) ??
      this.agentDeltas.get(turnId) ??
      "";
    this.agentMessages.delete(turnId);
    this.agentDeltas.delete(turnId);
    if (!finalText.trim()) {
      throw new AgentDriverError(
        "protocol",
        "empty_agent_message",
        "Agent turn completed without a final message",
      );
    }
    return {
      turnId,
      finalText,
      structuredOutput: null,
    };
  }

  async cancel(turnId) {
    if (!this.activeThreadReference) {
      throw new AgentDriverError(
        "unavailable",
        "no_active_thread",
        "No active agent thread to cancel",
      );
    }
    await this.request("turn/interrupt", {
      threadId: this.activeThreadReference,
      turnId,
    });
    return { turnId, cancelled: true };
  }

  classifyError(error) {
    if (error instanceof AgentDriverError) {
      return error;
    }
    const text = String(error?.message ?? error);
    if (/active writer|already has an active writer/iu.test(text)) {
      return new AgentDriverError(
        "blocked",
        "active_thread_owned",
        "The requested conversation is owned by another active agent client.",
        { cause: error },
      );
    }
    if (/timed out|exited|not running|spawn|ENOENT|unavailable/iu.test(text)) {
      return new AgentDriverError(
        "unavailable",
        "driver_unavailable",
        "The Codex driver is unavailable.",
        { cause: error },
      );
    }
    if (/permission|approval/iu.test(text)) {
      return new AgentDriverError(
        "permission",
        "driver_permission_denied",
        "The Codex driver rejected the action by permission policy.",
        { cause: error },
      );
    }
    return new AgentDriverError(
      "protocol",
      "driver_protocol_error",
      text,
      { cause: error },
    );
  }

  publicStatus() {
    return {
      connected: Boolean(this.child && this.child.exitCode === null),
      thread_id: this.activeThreadReference,
      thread_name: this.activeThreadName,
      capabilities: this.capabilities,
    };
  }

  async close() {
    this.input?.close();
    if (this.child && this.child.exitCode === null) {
      this.child.stdin.end();
      this.child.kill();
    }
    this.activeThreadReference = null;
  }
}
