import {
  appendFileSync,
  mkdirSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { resolve } from "node:path";
import { AgentDriver, AgentDriverError } from "./agent-driver.mjs";
import {
  DSHWebRpcClient,
  sanitizeDSHWebError,
} from "./dsh-web-rpc-client.mjs";

function buildPrompt(packet, schema) {
  return [
    "You are the structured backend for a local SkillDock.",
    "Do not use tools, read local files, or modify files.",
    "Return exactly one JSON object and no prose, Markdown fence, or surrounding text.",
    "The JSON must validate against the supplied panel UI schema 1.2.",
    "Follow packet.skill_context.instructions for the active Skill.",
    "Set blocks and artifact_refs to empty arrays unless the supplied Skill instructions explicitly permit verified local artifact references.",
    "Use the supplied Task and Skill context; do not infer a different domain.",
    "PANEL UI SCHEMA 1.2:",
    JSON.stringify(schema),
    "EVENT PACKET:",
    JSON.stringify(packet),
  ].join("\n");
}

function textFromAssistantRecord(record) {
  if (
    record?.type !== "event" ||
    record.event?.type !== "assistant/message"
  ) {
    return null;
  }
  const content = record.event.data?.message?.content;
  if (!Array.isArray(content)) return null;
  const text = content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("");
  return text.trim() ? text : null;
}

export function latestAssistantText(records) {
  const ordered = [...(records ?? [])].sort(
    (left, right) =>
      Number(left?.event?.seq ?? 0) - Number(right?.event?.seq ?? 0),
  );
  for (let index = ordered.length - 1; index >= 0; index -= 1) {
    const text = textFromAssistantRecord(ordered[index]);
    if (text) return text;
  }
  return null;
}

function writeDiagnostic(path, event) {
  appendFileSync(path, `${JSON.stringify(event)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
}

export class DSHWebAgentDriver extends AgentDriver {
  constructor({
    cwd,
    transport = null,
    fixture = process.env.PANEL_DSH_WEB_FIXTURE === "1",
    executable,
    cliPath,
    dshHome = process.env.DSH_HOME || null,
    host = "127.0.0.1",
    port = 0,
    turnTimeoutMs = 300_000,
    initializeTimeoutMs = 60_000,
  }) {
    super({
      name: "dsh-web",
      displayName: "DSH Web",
      capabilities: {
        supportsStreaming: false,
        streamingMode: "final-only-session-wait",
        supportsThreadResume: true,
        resumeScope: "panel-created-session",
        supportsActiveThreadAttach: false,
        activeThreadAttachReason:
          "A panel-owned DSH Web child cannot attach to another browser or Desktop session.",
        supportsStructuredOutput: false,
        structuredOutputCompatibility: "prompt-parse-schema-validation",
        supportsApprovals: false,
        supportsThreadNaming: true,
        supportsCancellation: true,
        cancellationMode: "session-cancel-rpc",
        adapterStatus: fixture ? "fixture" : "experimental",
        sessionCreation: "panel-child",
        childProcessOwned: true,
        launchCredentialStorage: "memory-only",
      },
    });
    this.cwd = resolve(cwd);
    this.fixture = fixture;
    this.turnTimeoutMs = turnTimeoutMs;
    this.initializeTimeoutMs = initializeTimeoutMs;
    this.transport =
      transport ??
      new DSHWebRpcClient({
        cwd: this.cwd,
        executable,
        cliPath,
        host,
        port,
        startupTimeoutMs: initializeTimeoutMs,
        rpcTimeoutMs: turnTimeoutMs,
        env: dshHome
          ? { ...process.env, DSH_HOME: dshHome }
          : process.env,
      });
    this.diagnosticDir = resolve(this.cwd, "agent-diagnostics");
    this.activeTurn = null;
  }

  async initialize() {
    mkdirSync(this.diagnosticDir, { recursive: true, mode: 0o700 });
    await this.transport.open();
    return { connected: true };
  }

  async startThread() {
    await this.transport.open();
    const value = await this.transport.rpc("session/create", {
      request: { cwd: this.cwd },
    });
    if (!value || typeof value.sessionId !== "string" || !value.sessionId) {
      throw new AgentDriverError(
        "protocol",
        "dsh_web_invalid_session_create",
        "DSH Web did not return a Session identifier.",
      );
    }
    this.activeThreadReference = value.sessionId;
    this.activeThreadName = null;
    return {
      threadReference: value.sessionId,
      resumed: false,
      agentPreset: value.agentPreset ?? null,
    };
  }

  async resumeThread(threadReference) {
    const sessionId = String(threadReference ?? "");
    if (!sessionId || sessionId.length > 256) {
      throw new AgentDriverError(
        "blocked",
        "dsh_web_session_reference_invalid",
        "DSH Web resume requires a panel-created Session identifier.",
      );
    }
    await this.transport.open();
    try {
      await this.transport.rpc("session/events", {
        request: {
          address: { kind: "session", sessionId },
          maxMessages: 1,
        },
      });
    } catch (error) {
      const classified = this.classifyError(error);
      if (classified.classification === "auth") throw classified;
      throw new AgentDriverError(
        "blocked",
        "dsh_web_session_unavailable",
        "The saved DSH Web Session is not available to this panel.",
        { cause: error },
      );
    }
    this.activeThreadReference = sessionId;
    return {
      threadReference: sessionId,
      resumed: true,
      resumeScope: "panel-created-session",
    };
  }

  async sendTurn({
    threadReference,
    eventId,
    packet,
    structuredOutputSchema,
    onEvent = null,
  }) {
    if (threadReference !== this.activeThreadReference) {
      throw new AgentDriverError(
        "unavailable",
        "dsh_web_session_not_active",
        "The requested DSH Web Session is not active.",
      );
    }
    if (this.activeTurn) {
      throw new AgentDriverError(
        "blocked",
        "dsh_web_turn_already_running",
        "A DSH Web turn is already running.",
      );
    }
    await this.transport.open();
    const turnId = `dsh-web-turn-${randomUUID()}`;
    const requestId = randomUUID();
    const prompt = buildPrompt(packet, structuredOutputSchema);
    const diagnosticPath = resolve(
      this.diagnosticDir,
      `${turnId}.jsonl`,
    );
    writeFileSync(
      diagnosticPath,
      `${JSON.stringify({
        type: "meta",
        turn_id: turnId,
        event_id: eventId,
        session_id: threadReference,
        driver: "dsh-web",
        prompt_sha256: createHash("sha256").update(prompt).digest("hex"),
        created_at: new Date().toISOString(),
      })}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    const controller = new AbortController();
    this.activeTurn = { turnId, threadReference, controller };
    this.emit(onEvent, { type: "turn_started", turnId });
    try {
      const state = await this.transport.rpc(
        "session/state",
        { request: { sessionId: threadReference } },
        { signal: controller.signal },
      );
      const afterSeq =
        Number.isSafeInteger(state?.cursor) ? state.cursor : undefined;
      writeDiagnostic(diagnosticPath, {
        type: "rpc_ok",
        endpoint: "session/state",
        cursor: afterSeq ?? null,
      });
      writeDiagnostic(diagnosticPath, {
        type: "rpc_request",
        endpoint: "session/prompt",
      });
      await this.transport.rpc(
        "session/prompt",
        {
          request: {
            requestId,
            sessionId: threadReference,
            mode: "queue",
            content: [{ type: "text", text: prompt }],
          },
        },
        { signal: controller.signal, timeoutMs: 60_000 },
      );
      writeDiagnostic(diagnosticPath, {
        type: "rpc_ok",
        endpoint: "session/prompt",
        accepted: true,
      });
      this.emit(onEvent, {
        type: "status",
        turnId,
        phase: "turn_start",
      });
      writeDiagnostic(diagnosticPath, {
        type: "rpc_request",
        endpoint: "session/wait",
      });
      const waited = await this.transport.rpc(
        "session/wait",
        {
          request: {
            sessionId: threadReference,
            timeoutMs: this.turnTimeoutMs,
            afterSeq,
            maxMessages: 128,
          },
        },
        {
          signal: controller.signal,
          timeoutMs: this.turnTimeoutMs + 15_000,
        },
      );
      if (!waited || !Array.isArray(waited.output?.records)) {
        throw new AgentDriverError(
          "protocol",
          "dsh_web_wait_invalid",
          "DSH Web returned invalid Session wait output.",
        );
      }
      if (waited.reason === "timeout" && waited.output.records.length === 0) {
        throw new AgentDriverError(
          "unavailable",
          "dsh_web_turn_timeout",
          "DSH Web did not finish before the turn timeout.",
        );
      }
      const finalText = latestAssistantText(waited.output.records);
      if (!finalText) {
        throw new AgentDriverError(
          "protocol",
          "dsh_web_final_message_missing",
          "DSH Web completed without a final assistant message.",
        );
      }
      this.emit(onEvent, {
        type: "text_delta",
        turnId,
        delta: finalText,
      });
      this.emit(onEvent, {
        type: "message_completed",
        turnId,
      });
      this.emit(onEvent, {
        type: "turn_completed",
        turnId,
        status: "completed",
      });
      writeDiagnostic(diagnosticPath, {
        type: "turn_completed",
        endpoint: "session/wait",
        reason: waited.reason,
        records: waited.output.records.length,
        truncated: Boolean(waited.output.truncated),
      });
      return {
        turnId,
        sessionId: threadReference,
        finalText,
        structuredOutput: null,
        diagnosticPath,
      };
    } catch (error) {
      const classified = this.classifyError(error);
      classified.diagnosticPath = diagnosticPath;
      writeDiagnostic(diagnosticPath, {
        type: "turn_error",
        classification: classified.classification,
        code: classified.code,
        message: sanitizeDSHWebError(classified.message),
      });
      throw classified;
    } finally {
      if (this.activeTurn?.turnId === turnId) {
        this.activeTurn = null;
      }
    }
  }

  async cancel(turnId) {
    if (!this.activeTurn || this.activeTurn.turnId !== turnId) {
      throw new AgentDriverError(
        "unavailable",
        "dsh_web_turn_not_running",
        "The DSH Web turn is not running.",
      );
    }
    const { threadReference, controller } = this.activeTurn;
    try {
      await this.transport.rpc("session/cancel", {
        request: { sessionId: threadReference },
      });
    } finally {
      controller.abort(new Error("DSH Web turn cancelled"));
    }
    return { turnId, cancelled: true };
  }

  async setThreadName(name) {
    if (!this.activeThreadReference) {
      throw new AgentDriverError(
        "unavailable",
        "dsh_web_session_not_active",
        "The DSH Web Session is not active.",
      );
    }
    const normalized = String(name ?? "").trim().slice(0, 120);
    if (!normalized) {
      throw new AgentDriverError(
        "protocol",
        "dsh_web_thread_name_invalid",
        "A non-empty Session name is required.",
      );
    }
    const value = await this.transport.rpc("session/rename", {
      request: {
        sessionId: this.activeThreadReference,
        title: normalized,
      },
    });
    this.activeThreadName =
      typeof value?.title === "string" ? value.title : normalized;
    return this.activeThreadName;
  }

  classifyError(error) {
    if (error instanceof AgentDriverError) {
      return error;
    }
    const text = sanitizeDSHWebError(error?.message ?? error);
    if (/401|authentication|credential|API key/iu.test(text)) {
      return new AgentDriverError(
        "auth",
        "dsh_web_authentication_required",
        "DSH Web authentication is unavailable.",
        { cause: error },
      );
    }
    if (/session\/not-found|writer-held|already.*owner/iu.test(text)) {
      return new AgentDriverError(
        "blocked",
        "dsh_web_session_unavailable",
        "The saved DSH Web Session cannot be resumed.",
        { cause: error },
      );
    }
    if (/ENOENT|spawn|exited before readiness|timed out|timeout/iu.test(text)) {
      return new AgentDriverError(
        "unavailable",
        "dsh_web_unavailable",
        "DSH Web is unavailable.",
        { cause: error },
      );
    }
    return new AgentDriverError(
      "protocol",
      "dsh_web_protocol_error",
      text || "DSH Web returned an invalid response.",
      { cause: error },
    );
  }

  async close() {
    if (this.activeTurn) {
      this.activeTurn.controller.abort(new Error("DSH Web driver closed"));
      this.activeTurn = null;
    }
    await this.transport.close();
    this.activeThreadReference = null;
    this.activeThreadName = null;
  }
}
