import { spawn } from "node:child_process";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  writeFileSync,
} from "node:fs";
import { createHash, randomUUID } from "node:crypto";
import { resolve } from "node:path";
import readline from "node:readline";
import { AgentDriver, AgentDriverError } from "./agent-driver.mjs";

const DEFAULT_EXECUTABLE = "C:\\dsh\\DeepSeek Harness.exe";
const DEFAULT_CLI_PATH =
  "C:\\dsh\\resources\\app.asar\\dsh\\node_modules\\@deepseek-ai\\dsh-desktop-host\\lib\\cli.js";

function sanitizeDiagnostic(value) {
  return String(value ?? "")
    .replace(/sk-[A-Za-z0-9_-]{16,}/gu, "[redacted-key]")
    .replace(/Bearer\s+[^\s"']+/giu, "Bearer [redacted]")
    .replace(
      /(?:DEEPSEEK_API_KEY|DSH_PLATFORM_COOKIE|panel_token|handoff-secret)\s*[=:]\s*\S+/giu,
      "[redacted-credential]",
    );
}

function buildPrompt(packet, schema) {
  return [
    "You are the structured backend for a local Agent Workbench.",
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

export class DSHAgentDriver extends AgentDriver {
  constructor({
    cwd,
    protocolLogPath = null,
    timeoutMs = 300_000,
    executable = DEFAULT_EXECUTABLE,
    cliPath = DEFAULT_CLI_PATH,
    agentDataDir = cwd,
    dshHome = process.env.PANEL_DSH_HOME
      ? resolve(process.env.PANEL_DSH_HOME)
      : resolve(agentDataDir, "dsh-home"),
    fixture = process.env.PANEL_DSH_FIXTURE === "1",
  }) {
    const fixturePath = resolve(cwd, "fixtures", "dsh-headless-fixture.mjs");
    super({
      name: "dsh",
      displayName: "DSH",
      capabilities: {
        supportsStreaming: true,
        streamingMode: "committed-text-events",
        supportsThreadResume: true,
        supportsActiveThreadAttach: false,
        activeThreadAttachReason:
          "DSH headless creates new isolated sessions and cannot attach to the active Desktop conversation.",
        supportsStructuredOutput: false,
        structuredOutputCompatibility: "prompt-parse-schema-validation",
        supportsApprovals: false,
        supportsThreadNaming: false,
        supportsCancellation: true,
        cancellationMode: "process-termination",
        adapterStatus: fixture ? "fixture" : "experimental",
        sessionCreation: "first-turn",
      },
    });
    this.cwd = cwd;
    this.protocolLogPath = protocolLogPath;
    this.timeoutMs = timeoutMs;
    this.fixture = fixture;
    this.executable = fixture ? process.execPath : executable;
    this.cliArgsPrefix = fixture
      ? [fixturePath]
      : ["--expose-internals", cliPath];
    this.dshHome = dshHome;
    this.userProfile = resolve(dshHome, "userprofile");
    this.tempDir = resolve(dshHome, "temp");
    this.sessionCwd = resolve(cwd, "work", "p5-dsh", "session-cwd");
    this.diagnosticDir = resolve(agentDataDir, "agent-diagnostics");
    this.activeChild = null;
    this.activeTurnId = null;
    this.cancelledTurnIds = new Set();
  }

  async initialize() {
    if (!this.fixture && !existsSync(this.executable)) {
      throw new AgentDriverError(
        "unavailable",
        "dsh_executable_missing",
        `DSH executable was not found at ${this.executable}`,
      );
    }
    mkdirSync(this.dshHome, { recursive: true });
    mkdirSync(this.userProfile, { recursive: true });
    mkdirSync(this.tempDir, { recursive: true });
    mkdirSync(this.sessionCwd, { recursive: true });
    mkdirSync(this.diagnosticDir, { recursive: true });
    return { connected: true };
  }

  async startThread() {
    this.activeThreadReference = `dsh-pending-${randomUUID()}`;
    this.activeThreadName = null;
    return { threadReference: this.activeThreadReference, resumed: false };
  }

  async resumeThread(threadReference) {
    if (!/^session-[A-Za-z0-9-]{8,}$/u.test(String(threadReference))) {
      throw new AgentDriverError(
        "blocked",
        "dsh_session_reference_invalid",
        "DSH resume requires a persisted session ID",
      );
    }
    this.activeThreadReference = threadReference;
    return { threadReference, resumed: true };
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
        "dsh_session_not_active",
        "The requested DSH session is not active",
      );
    }
    if (this.activeChild) {
      throw new AgentDriverError(
        "blocked",
        "dsh_turn_already_running",
        "A DSH turn is already running",
      );
    }
    const resumeSession = /^session-/u.test(threadReference);
    const turnId = `dsh-turn-${randomUUID()}`;
    const prompt = buildPrompt(packet, structuredOutputSchema);
    const args = [
      ...this.cliArgsPrefix,
      "headless",
      "--json",
      ...(resumeSession ? ["--session-id", threadReference] : []),
      "-",
    ];
    const diagnosticPath = resolve(
      this.diagnosticDir,
      `${turnId}.jsonl`,
    );
    writeFileSync(
      diagnosticPath,
      `${JSON.stringify({
        type: "meta",
        turnId,
        eventId,
        driver: "dsh",
        fixture: this.fixture,
        resumed: resumeSession,
        prompt_sha256: createHash("sha256").update(prompt).digest("hex"),
        created_at: new Date().toISOString(),
      })}\n`,
      { encoding: "utf8", mode: 0o600 },
    );
    this.emit(onEvent, { type: "turn_started", turnId });
    const result = await this.runHeadless({
      args,
      prompt,
      turnId,
      diagnosticPath,
      onEvent,
      resumeRequested: resumeSession,
    });
    return {
      ...result,
      turnId,
      diagnosticPath,
    };
  }

  runHeadless({
    args,
    prompt,
    turnId,
    diagnosticPath,
    onEvent,
    resumeRequested,
  }) {
    return new Promise((resolvePromise, reject) => {
      const env = {
        PATH: process.env.PATH ?? "",
        SystemRoot: process.env.SystemRoot ?? "C:\\Windows",
        WINDIR: process.env.WINDIR ?? "C:\\Windows",
        TEMP: this.tempDir,
        TMP: this.tempDir,
        USERPROFILE: this.userProfile,
        HOME: this.userProfile,
        DSH_HOME: this.dshHome,
        DSH_TELEMETRY_DISABLED: "1",
        DSH_PERMISSION_MODE: "read-only",
        ELECTRON_RUN_AS_NODE: "1",
      };
      if (process.env.DEEPSEEK_API_KEY) {
        env.DEEPSEEK_API_KEY = process.env.DEEPSEEK_API_KEY;
      }
      if (this.fixture && process.env.DSH_FIXTURE_LOG_PATH) {
        env.DSH_FIXTURE_LOG_PATH = process.env.DSH_FIXTURE_LOG_PATH;
      }
      const child = spawn(this.executable, args, {
        cwd: this.sessionCwd,
        windowsHide: true,
        stdio: ["pipe", "pipe", "pipe"],
        env,
      });
      this.activeChild = child;
      this.activeTurnId = turnId;
      let stderr = "";
      let finalText = "";
      let sessionId = null;
      let streamedText = "";
      let settled = false;
      const timeout = setTimeout(() => {
        child.kill();
        fail(
          new AgentDriverError(
            "unavailable",
            "dsh_turn_timeout",
            "DSH headless turn timed out",
          ),
        );
      }, this.timeoutMs);

      const log = (event) => {
        appendFileSync(
          diagnosticPath,
          `${JSON.stringify(event)}\n`,
          { encoding: "utf8", mode: 0o600 },
        );
        if (this.protocolLogPath) {
          appendFileSync(
            this.protocolLogPath,
            `${JSON.stringify({ driver: "dsh", ...event })}\n`,
            { encoding: "utf8", mode: 0o600 },
          );
        }
      };
      const fail = (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        this.activeChild = null;
        this.activeTurnId = null;
        const classified = this.classifyError(error);
        classified.diagnosticPath = diagnosticPath;
        reject(classified);
      };
      const finish = () => {
        if (settled) return;
        if (!finalText.trim()) {
          fail(
            new Error(
              `DSH completed without a final message${stderr ? `: ${stderr}` : ""}`,
            ),
          );
          return;
        }
        settled = true;
        clearTimeout(timeout);
        this.activeChild = null;
        this.activeTurnId = null;
        if (sessionId) {
          this.activeThreadReference = sessionId;
          this.emit(onEvent, {
            type: "session",
            threadReference: sessionId,
            resumed: resumeRequested,
          });
        }
        this.emit(onEvent, {
          type: "turn_completed",
          turnId,
          status: "completed",
        });
        resolvePromise({
          sessionId,
          finalText,
          streamedText,
          structuredOutput: null,
        });
      };

      const lines = readline.createInterface({ input: child.stdout });
      lines.on("line", (line) => {
        let event;
        try {
          event = JSON.parse(line);
        } catch {
          const diagnostic = {
            type: "invalid_ndjson",
            line: sanitizeDiagnostic(line).slice(0, 16_384),
          };
          log(diagnostic);
          return;
        }
        const safeEvent =
          event.type === "final"
            ? { ...event, text: sanitizeDiagnostic(event.text) }
            : JSON.parse(sanitizeDiagnostic(JSON.stringify(event)));
        log(safeEvent);
        if (event.type === "session" && typeof event.sessionId === "string") {
          sessionId = event.sessionId;
          this.activeThreadReference = sessionId;
          this.emit(onEvent, {
            type: "session_started",
            threadReference: sessionId,
            resumed: resumeRequested,
          });
        } else if (event.type === "text" && typeof event.text === "string") {
          streamedText += event.text;
          this.emit(onEvent, {
            type: "text_delta",
            turnId,
            delta: event.text,
          });
        } else if (event.type === "thinking" && typeof event.text === "string") {
          this.emit(onEvent, {
            type: "reasoning_delta",
            turnId,
            delta: event.text,
          });
        } else if (event.type === "status") {
          this.emit(onEvent, {
            type: "status",
            turnId,
            phase: event.phase,
          });
        } else if (event.type === "final" && typeof event.text === "string") {
          finalText = event.text;
        }
      });
      child.stderr.on("data", (chunk) => {
        stderr = `${stderr}${chunk.toString()}`.slice(-32_768);
      });
      child.once("error", (error) => {
        fail(
          new AgentDriverError(
            "unavailable",
            "dsh_spawn_failed",
            `DSH process could not start: ${error.message}`,
            { cause: error },
          ),
        );
      });
      child.once("close", (code, signal) => {
        log({
          type: "process_exit",
          code,
          signal,
          stderr: sanitizeDiagnostic(stderr),
        });
        if (this.cancelledTurnIds.has(turnId)) {
          this.cancelledTurnIds.delete(turnId);
          fail(
            new AgentDriverError(
              "blocked",
              "dsh_turn_cancelled",
              "DSH turn was cancelled",
            ),
          );
          return;
        }
        if (code === 0) {
          finish();
          return;
        }
        fail(
          new AgentDriverError(
            /MISSING_CREDENTIAL|API key|unauthorized|401/iu.test(stderr)
              ? "auth"
              : /permission|denied/iu.test(stderr)
                ? "permission"
                : /unknown.*session|session.*not found/iu.test(stderr)
                  ? "blocked"
                  : "protocol",
            /MISSING_CREDENTIAL|API key/iu.test(stderr)
              ? "dsh_authentication_required"
              : "dsh_turn_failed",
            `DSH exited with code ${code}${stderr ? `: ${stderr.slice(0, 1000)}` : ""}`,
          ),
        );
      });
      child.stdin.end(prompt);
    });
  }

  async cancel(turnId) {
    if (!this.activeChild || this.activeTurnId !== turnId) {
      throw new AgentDriverError(
        "unavailable",
        "dsh_turn_not_running",
        "The DSH turn is not running",
      );
    }
    this.cancelledTurnIds.add(turnId);
    this.activeChild.kill();
    return { turnId, cancelled: true };
  }

  classifyError(error) {
    if (error instanceof AgentDriverError) {
      return error;
    }
    const text = String(error?.message ?? error);
    if (/MISSING_CREDENTIAL|API key|unauthorized|401/iu.test(text)) {
      return new AgentDriverError(
        "auth",
        "dsh_authentication_required",
        "DSH requires a configured DEEPSEEK_API_KEY.",
        { cause: error },
      );
    }
    if (/permission|denied|approval/iu.test(text)) {
      return new AgentDriverError(
        "permission",
        "dsh_permission_denied",
        "DSH rejected the action by permission policy.",
        { cause: error },
      );
    }
    if (/unknown.*session|session.*not found|invalid session/iu.test(text)) {
      return new AgentDriverError(
        "blocked",
        "dsh_session_unavailable",
        "The saved DSH session cannot be resumed.",
        { cause: error },
      );
    }
    if (/ENOENT|spawn|not found|timed out/iu.test(text)) {
      return new AgentDriverError(
        "unavailable",
        "dsh_unavailable",
        "DSH headless is unavailable.",
        { cause: error },
      );
    }
    return new AgentDriverError(
      "protocol",
      "dsh_protocol_error",
      text,
      { cause: error },
    );
  }

  async close() {
    if (this.activeChild) {
      this.activeChild.kill();
      this.activeChild = null;
    }
    this.activeThreadReference = null;
  }
}
