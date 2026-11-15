import { randomUUID } from "node:crypto";
import { AgentDriver, AgentDriverError } from "./agent-driver.mjs";

export const AGENT_BRIDGE_PROTOCOL_VERSION = "0.1-draft";
const MAX_RESPONSE_BYTES = 2 * 1024 * 1024;

const ERROR_CLASSES = new Set([
  "unavailable",
  "blocked",
  "auth",
  "permission",
  "protocol",
]);

function normalizeBaseUrl(value) {
  let url;
  try {
    url = new URL(String(value ?? ""));
  } catch {
    throw new AgentDriverError(
      "unavailable",
      "agent_bridge_url_invalid",
      "Agent Bridge URL is invalid.",
    );
  }
  const loopbackHosts = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
  if (
    !["http:", "https:"].includes(url.protocol) ||
    !loopbackHosts.has(url.hostname.toLowerCase()) ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new AgentDriverError(
      "protocol",
      "agent_bridge_url_not_loopback",
      "Agent Bridge must be a credential-free loopback HTTP URL.",
    );
  }
  url.pathname = url.pathname.replace(/\/+$/u, "");
  return url.toString().replace(/\/$/u, "");
}

function classifyHttpStatus(status) {
  if (status === 401) return "auth";
  if (status === 403) return "permission";
  if (status === 409 || status === 423) return "blocked";
  if (status >= 500) return "unavailable";
  return "protocol";
}

function bridgeError(status, payload) {
  const supplied = payload?.error;
  const classification = ERROR_CLASSES.has(supplied?.classification)
    ? supplied.classification
    : classifyHttpStatus(status);
  return new AgentDriverError(
    classification,
    String(supplied?.code ?? "agent_bridge_http_error").slice(0, 120),
    String(supplied?.message ?? `Agent Bridge returned HTTP ${status}`).slice(
      0,
      500,
    ),
  );
}

function requireSessionId(value) {
  const sessionId = String(value ?? "");
  if (!/^[A-Za-z0-9][A-Za-z0-9._:-]{7,255}$/u.test(sessionId)) {
    throw new AgentDriverError(
      "protocol",
      "agent_bridge_session_invalid",
      "Agent Bridge returned an invalid Session identifier.",
    );
  }
  return sessionId;
}

function capabilityFlags(capabilities) {
  return {
    supportsStreaming: false,
    supportsThreadResume: capabilities?.session_resume === true,
    supportsActiveThreadAttach: false,
    activeThreadAttachReason:
      "Agent Bridge 0.1-draft exposes panel-owned Sessions only.",
    supportsStructuredOutput: capabilities?.structured_output === true,
    structuredOutputCompatibility:
      capabilities?.structured_output === true
        ? "native"
        : "prompt-parse-schema-validation",
    supportsApprovals: false,
    supportsThreadNaming: capabilities?.session_naming === true,
    supportsCancellation: capabilities?.cancellation === true,
    adapterStatus: "draft",
    bridgeProtocolVersion: AGENT_BRIDGE_PROTOCOL_VERSION,
  };
}

export class AgentBridgeDriver extends AgentDriver {
  constructor({
    baseUrl = process.env.PANEL_AGENT_BRIDGE_URL,
    token = process.env.PANEL_AGENT_BRIDGE_TOKEN,
    fetchImpl = globalThis.fetch,
    requestTimeoutMs = 30_000,
    turnTimeoutMs = 300_000,
  } = {}) {
    super({
      name: "agent-bridge",
      displayName: "Agent Bridge",
      capabilities: {
        adapterStatus: "draft",
        bridgeProtocolVersion: AGENT_BRIDGE_PROTOCOL_VERSION,
      },
    });
    if (!String(token ?? "").trim()) {
      throw new AgentDriverError(
        "auth",
        "agent_bridge_token_missing",
        "Agent Bridge requires PANEL_AGENT_BRIDGE_TOKEN.",
      );
    }
    if (String(token).length > 4096) {
      throw new AgentDriverError(
        "protocol",
        "agent_bridge_token_invalid",
        "Agent Bridge token is too long.",
      );
    }
    if (typeof fetchImpl !== "function") {
      throw new AgentDriverError(
        "unavailable",
        "agent_bridge_fetch_unavailable",
        "This runtime does not provide fetch.",
      );
    }
    this.baseUrl = normalizeBaseUrl(baseUrl);
    this.token = String(token).trim();
    this.fetchImpl = fetchImpl;
    this.requestTimeoutMs = requestTimeoutMs;
    this.turnTimeoutMs = turnTimeoutMs;
    this.activeTurn = null;
    this.cancelledTurns = new Set();
  }

  async initialize() {
    const health = await this.request("/v1/health", {
      timeoutMs: this.requestTimeoutMs,
    });
    if (
      health?.ok !== true ||
      health?.protocol_version !== AGENT_BRIDGE_PROTOCOL_VERSION
    ) {
      throw new AgentDriverError(
        "protocol",
        "agent_bridge_protocol_mismatch",
        `Agent Bridge must expose ${AGENT_BRIDGE_PROTOCOL_VERSION}.`,
      );
    }
    const descriptor = await this.request("/v1/capabilities", {
      timeoutMs: this.requestTimeoutMs,
    });
    if (
      descriptor?.protocol_version !== AGENT_BRIDGE_PROTOCOL_VERSION ||
      descriptor?.capabilities?.text_input !== true ||
      descriptor?.capabilities?.session_create !== true
    ) {
      throw new AgentDriverError(
        "protocol",
        "agent_bridge_capabilities_invalid",
        "Agent Bridge does not declare the required text/session capabilities.",
      );
    }
    this.capabilities = Object.freeze({
      ...this.capabilities,
      ...capabilityFlags(descriptor.capabilities),
      implementationName: String(
        descriptor.implementation?.name ?? "unknown",
      ).slice(0, 120),
      implementationVersion: String(
        descriptor.implementation?.version ?? "unknown",
      ).slice(0, 80),
    });
    return { connected: true };
  }

  async close() {
    if (this.activeTurn) {
      this.activeTurn.controller.abort(
        new Error("Agent Bridge closed during an active turn"),
      );
      this.activeTurn = null;
    }
  }

  async startThread() {
    const value = await this.request("/v1/sessions", {
      method: "POST",
      body: {
        client_request_id: randomUUID(),
      },
      timeoutMs: this.requestTimeoutMs,
    });
    const sessionId = requireSessionId(value?.session?.id);
    this.activeThreadReference = sessionId;
    this.activeThreadName = value.session.name ?? null;
    return { threadReference: sessionId, resumed: false };
  }

  async resumeThread(threadReference) {
    if (this.capabilities.supportsThreadResume !== true) {
      throw this.unsupported(
        "resumeThread",
        "Agent Bridge does not declare Session resume support.",
      );
    }
    const sessionId = requireSessionId(threadReference);
    try {
      const value = await this.request(
        `/v1/sessions/${encodeURIComponent(sessionId)}`,
        { timeoutMs: this.requestTimeoutMs },
      );
      this.activeThreadReference = requireSessionId(value?.session?.id);
      this.activeThreadName = value.session.name ?? null;
      return {
        threadReference: this.activeThreadReference,
        resumed: true,
      };
    } catch (error) {
      const classified = this.classifyError(error);
      if (classified.code === "agent_bridge_http_error") {
        throw new AgentDriverError(
          "blocked",
          "agent_bridge_session_unavailable",
          "The saved Agent Bridge Session is unavailable.",
          { cause: error },
        );
      }
      throw classified;
    }
  }

  async setThreadName(name) {
    if (this.capabilities.supportsThreadNaming !== true) {
      throw this.unsupported("setThreadName");
    }
    if (!this.activeThreadReference) {
      throw new AgentDriverError(
        "unavailable",
        "no_active_thread",
        "No Agent Bridge Session is active.",
      );
    }
    const normalized = String(name ?? "").trim().slice(0, 120);
    if (!normalized) {
      throw new AgentDriverError(
        "protocol",
        "agent_bridge_name_invalid",
        "A non-empty Session name is required.",
      );
    }
    const value = await this.request(
      `/v1/sessions/${encodeURIComponent(this.activeThreadReference)}/name`,
      {
        method: "POST",
        body: { name: normalized },
        timeoutMs: this.requestTimeoutMs,
      },
    );
    this.activeThreadName = String(value?.session?.name ?? normalized);
    return this.activeThreadName;
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
        "agent_bridge_session_not_active",
        "The requested Agent Bridge Session is not active.",
      );
    }
    if (this.activeTurn) {
      throw new AgentDriverError(
        "blocked",
        "agent_bridge_turn_already_running",
        "An Agent Bridge turn is already running.",
      );
    }
    const turnId = `bridge-turn-${randomUUID()}`;
    const controller = new AbortController();
    this.activeTurn = { turnId, controller };
    this.cancelledTurns.delete(turnId);
    this.emit(onEvent, { type: "turn_started", turnId });
    try {
      const signal = AbortSignal.any([
        controller.signal,
        AbortSignal.timeout(this.turnTimeoutMs),
      ]);
      const value = await this.request(
        `/v1/sessions/${encodeURIComponent(threadReference)}/turns`,
        {
          method: "POST",
          body: {
            request_id: eventId,
            turn_id: turnId,
            packet,
            output_schema: structuredOutputSchema ?? null,
          },
          signal,
          timeoutMs: this.turnTimeoutMs + 5_000,
        },
      );
      if (value?.turn_id !== turnId || value?.status !== "completed") {
        throw new AgentDriverError(
          "protocol",
          "agent_bridge_turn_invalid",
          "Agent Bridge returned an invalid completed turn.",
        );
      }
      const finalText =
        typeof value?.output?.text === "string" ? value.output.text : "";
      const structuredOutput =
        value?.output?.structured &&
        typeof value.output.structured === "object"
          ? value.output.structured
          : null;
      if (!finalText.trim() && !structuredOutput) {
        throw new AgentDriverError(
          "protocol",
          "agent_bridge_turn_empty",
          "Agent Bridge completed without text or structured output.",
        );
      }
      if (finalText) {
        this.emit(onEvent, {
          type: "text_delta",
          turnId,
          delta: finalText,
        });
      }
      this.emit(onEvent, { type: "message_completed", turnId });
      this.emit(onEvent, {
        type: "turn_completed",
        turnId,
        status: "completed",
      });
      return {
        turnId,
        finalText:
          finalText ||
          JSON.stringify(structuredOutput),
        structuredOutput,
      };
    } catch (error) {
      if (this.cancelledTurns.has(turnId)) {
        throw new AgentDriverError(
          "blocked",
          "agent_bridge_turn_cancelled",
          "Agent Bridge turn was cancelled.",
        );
      }
      throw this.classifyError(error);
    } finally {
      this.cancelledTurns.delete(turnId);
      if (this.activeTurn?.turnId === turnId) {
        this.activeTurn = null;
      }
    }
  }

  async cancel(turnId) {
    if (this.capabilities.supportsCancellation !== true) {
      throw this.unsupported("cancel");
    }
    if (!this.activeTurn || this.activeTurn.turnId !== turnId) {
      throw new AgentDriverError(
        "unavailable",
        "agent_bridge_turn_not_running",
        "The Agent Bridge turn is not running.",
      );
    }
    this.cancelledTurns.add(turnId);
    try {
      await this.request(
        `/v1/sessions/${encodeURIComponent(this.activeThreadReference)}/cancel`,
        {
          method: "POST",
          body: { turn_id: turnId },
          timeoutMs: this.requestTimeoutMs,
        },
      );
    } finally {
      this.activeTurn.controller.abort(
        new Error("Agent Bridge turn cancelled"),
      );
    }
    return { turnId, cancelled: true };
  }

  async request(
    path,
    {
      method = "GET",
      body = null,
      signal = null,
      timeoutMs = this.requestTimeoutMs,
    } = {},
  ) {
    let response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method,
        redirect: "error",
        headers: {
          Authorization: `Bearer ${this.token}`,
          Accept: "application/json",
          ...(body === null ? {} : { "Content-Type": "application/json" }),
        },
        body: body === null ? undefined : JSON.stringify(body),
        signal: signal ?? AbortSignal.timeout(timeoutMs),
      });
    } catch (error) {
      throw new AgentDriverError(
        "unavailable",
        "agent_bridge_unavailable",
        "Agent Bridge request failed.",
        { cause: error },
      );
    }
    let payload = {};
    const contentLength = Number(response.headers.get("content-length"));
    if (Number.isFinite(contentLength) && contentLength > MAX_RESPONSE_BYTES) {
      throw new AgentDriverError(
        "protocol",
        "agent_bridge_response_too_large",
        "Agent Bridge response exceeds the size limit.",
      );
    }
    const text = await response.text();
    if (Buffer.byteLength(text, "utf8") > MAX_RESPONSE_BYTES) {
      throw new AgentDriverError(
        "protocol",
        "agent_bridge_response_too_large",
        "Agent Bridge response exceeds the size limit.",
      );
    }
    if (text.trim()) {
      try {
        payload = JSON.parse(text);
      } catch {
        throw new AgentDriverError(
          "protocol",
          "agent_bridge_invalid_json",
          "Agent Bridge returned non-JSON content.",
        );
      }
    }
    if (!response.ok) {
      throw bridgeError(response.status, payload);
    }
    return payload;
  }
}
