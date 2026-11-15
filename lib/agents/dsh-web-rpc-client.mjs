import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import readline from "node:readline";
import { resolve } from "node:path";
import { AgentDriverError } from "./agent-driver.mjs";

const DEFAULT_EXECUTABLE = "C:\\dsh\\DeepSeek Harness.exe";
const DEFAULT_CLI_PATH =
  "C:\\dsh\\resources\\app.asar\\dsh\\node_modules\\@deepseek-ai\\dsh-desktop-host\\lib\\cli.js";
const TOKEN_PATTERN =
  /(?:[?&]token=)[^&\s"'<>]+/giu;
const SECRET_PATTERN =
  /(?:dsh-auth-[A-Za-z0-9_-]+|Bearer\s+\S+|(?:DEEPSEEK_API_KEY|DSH_PLATFORM_COOKIE|panel_token|handoff-secret)\s*[=:]\s*\S+|sk-[A-Za-z0-9_-]{16,})/giu;

export function sanitizeDSHWebError(value, limit = 2000) {
  return String(value ?? "")
    .replace(TOKEN_PATTERN, "?token=[redacted]")
    .replace(
      /(?:^|;\s*)dsh-auth-[^=;\s]+=[^;\s]+/giu,
      "; dsh-auth-[redacted]",
    )
    .replace(SECRET_PATTERN, "[redacted-credential]")
    .slice(0, limit);
}

function errorClassificationForCode(code, fallback = "protocol") {
  const normalized = String(code ?? "").toLowerCase();
  if (
    normalized.includes("writer-held") ||
    normalized.includes("session/not-found") ||
    normalized.includes("agent-busy") ||
    normalized.includes("ownership") ||
    normalized.includes("resume")
  ) {
    return "blocked";
  }
  if (
    normalized.includes("credential") ||
    normalized.includes("authentication") ||
    normalized.includes("unauthorized") ||
    normalized.includes("api-key")
  ) {
    return "auth";
  }
  if (
    normalized.includes("permission") ||
    normalized.includes("forbidden") ||
    normalized.includes("denied")
  ) {
    return "permission";
  }
  return fallback;
}

function dshWebError({
  classification,
  code,
  message,
  cause = null,
}) {
  return new AgentDriverError(classification, code, message, { cause });
}

function responseCookies(headers) {
  if (typeof headers.getSetCookie === "function") {
    return headers.getSetCookie();
  }
  const value = headers.get("set-cookie");
  return value ? [value] : [];
}

function cookieHeader(setCookieValues) {
  return setCookieValues
    .map((value) => String(value).split(";", 1)[0].trim())
    .filter(Boolean)
    .join("; ");
}

function cleanLaunchLine(line) {
  return String(line)
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/gu, "")
    .trim();
}

export class DSHWebRpcClient {
  constructor({
    cwd,
    executable = DEFAULT_EXECUTABLE,
    cliPath = DEFAULT_CLI_PATH,
    host = "127.0.0.1",
    port = 0,
    startupTimeoutMs = 60_000,
    connectTimeoutMs = 20_000,
    rpcTimeoutMs = 45_000,
    closeTimeoutMs = 5_000,
    env = process.env,
  }) {
    this.cwd = resolve(cwd);
    this.executable = executable;
    this.cliPath = cliPath;
    this.host = host;
    this.port = port;
    this.startupTimeoutMs = startupTimeoutMs;
    this.connectTimeoutMs = connectTimeoutMs;
    this.rpcTimeoutMs = rpcTimeoutMs;
    this.closeTimeoutMs = closeTimeoutMs;
    this.env = env;
    this.child = null;
    this.baseUrl = null;
    this.launchToken = null;
    this.cookie = null;
    this.childPid = null;
    this.lastExit = null;
    this.starting = null;
    this.closing = null;
    this.processExitHandler = null;
  }

  async open() {
    if (this.cookie && this.child && this.child.exitCode === null) {
      return this.publicStatus();
    }
    if (this.starting) {
      await this.starting;
      return this.publicStatus();
    }
    if (!existsSync(this.executable)) {
      throw dshWebError({
        classification: "unavailable",
        code: "dsh_web_executable_missing",
        message: "DSH Web executable is unavailable.",
      });
    }
    this.starting = this.#startChild();
    try {
      await this.starting;
      return this.publicStatus();
    } finally {
      this.starting = null;
    }
  }

  publicStatus() {
    return {
      connected: Boolean(this.cookie && this.child && this.child.exitCode === null),
      child_pid: this.childPid,
      host: this.host,
      port: this.baseUrl ? Number(new URL(this.baseUrl).port) : null,
      transport: "loopback-http-unary",
    };
  }

  async #startChild() {
    if (this.processExitHandler) {
      process.off("exit", this.processExitHandler);
      this.processExitHandler = null;
    }
    this.#clearSecrets();
    const args = [
      "--expose-internals",
      this.cliPath,
      "--profile",
      "web",
      "--no-open",
      "--host",
      this.host,
      "--port",
      String(this.port),
    ];
    const child = spawn(this.executable, args, {
      cwd: this.cwd,
      env: {
        ...this.env,
        ELECTRON_RUN_AS_NODE: "1",
      },
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.child = child;
    this.childPid = child.pid ?? null;
    this.lastExit = null;
    let stderrTail = "";
    let settled = false;
    let startupTimer = null;

    const launch = new Promise((resolveLaunch, rejectLaunch) => {
      const fail = (error) => {
        if (settled) return;
        settled = true;
        if (startupTimer) clearTimeout(startupTimer);
        rejectLaunch(error);
      };
      const finish = () => {
        if (settled) return;
        settled = true;
        if (startupTimer) clearTimeout(startupTimer);
        resolveLaunch();
      };

      startupTimer = setTimeout(() => {
        child.kill();
        fail(
          dshWebError({
            classification: "unavailable",
            code: "dsh_web_startup_timeout",
            message: "DSH Web did not become ready before the startup timeout.",
          }),
        );
      }, this.startupTimeoutMs);
      startupTimer.unref?.();

      const stdout = readline.createInterface({ input: child.stdout });
      stdout.on("line", (line) => {
        if (this.launchToken || settled) {
          return;
        }
        const clean = cleanLaunchLine(line);
        const match = clean.match(/dsh web:\s+(https?:\/\/\S+)/iu);
        if (!match) return;
        let authenticated;
        try {
          authenticated = new URL(match[1]);
        } catch {
          fail(
            dshWebError({
              classification: "protocol",
              code: "dsh_web_invalid_launch_url",
              message: "DSH Web printed an invalid launch URL.",
            }),
          );
          return;
        }
        const token = authenticated.searchParams.get("token");
        if (!token) {
          fail(
            dshWebError({
              classification: "protocol",
              code: "dsh_web_launch_token_missing",
              message: "DSH Web launch output did not contain a capability token.",
            }),
          );
          return;
        }
        this.launchToken = token;
        authenticated.searchParams.delete("token");
        this.baseUrl = `${authenticated.origin}${authenticated.pathname}`;
        void this.#connectPeer()
          .then(finish)
          .catch((error) => {
            child.kill();
            fail(error);
          });
      });

      child.stderr.on("data", (chunk) => {
        stderrTail = `${stderrTail}${String(chunk)}`.slice(-8192);
      });
      child.once("error", (error) => {
        fail(
          dshWebError({
            classification: "unavailable",
            code: "dsh_web_spawn_failed",
            message: "DSH Web child process could not start.",
            cause: error,
          }),
        );
      });
      child.once("exit", (code, signal) => {
        this.lastExit = { code, signal };
        this.#clearSecrets();
        if (this.child === child) {
          this.child = null;
          this.childPid = null;
        }
        if (!settled) {
          const credentialFailure =
            /MISSING_CREDENTIAL|API key|unauthorized|credential/iu.test(stderrTail);
          fail(
            dshWebError({
              classification: credentialFailure ? "auth" : "unavailable",
              code: credentialFailure
                ? "dsh_web_authentication_required"
                : "dsh_web_child_exited",
              message: credentialFailure
                ? "DSH Web child has no usable provider credential."
                : `DSH Web child exited before readiness with code ${String(code)}.`,
            }),
          );
        }
      });
    });

    await launch;
    this.processExitHandler = () => {
      try {
        child.kill();
      } catch {
        // Best-effort cleanup when the parent process exits.
      }
    };
    process.once("exit", this.processExitHandler);
  }

  async #connectPeer() {
    if (!this.baseUrl || !this.launchToken) {
      throw dshWebError({
        classification: "unavailable",
        code: "dsh_web_not_ready",
        message: "DSH Web is not ready.",
      });
    }
    const connectUrl = new URL("/connect", this.baseUrl);
    connectUrl.searchParams.set("token", this.launchToken);
    connectUrl.searchParams.set("interactions", "none");
    let response;
    try {
      response = await fetch(connectUrl, {
        method: "GET",
        redirect: "manual",
        signal: AbortSignal.timeout(this.connectTimeoutMs),
      });
    } catch (error) {
      throw dshWebError({
        classification: "unavailable",
        code: "dsh_web_connect_unavailable",
        message: "DSH Web API peer connection failed.",
        cause: error,
      });
    }
    if (response.status === 401) {
      throw dshWebError({
        classification: "auth",
        code: "dsh_web_authentication_required",
        message: "DSH Web rejected the panel launch capability.",
      });
    }
    if (response.status < 200 || response.status >= 400) {
      throw dshWebError({
        classification: response.status >= 500 ? "unavailable" : "protocol",
        code: "dsh_web_connect_failed",
        message: `DSH Web API peer connection returned HTTP ${response.status}.`,
      });
    }
    const cookies = responseCookies(response.headers);
    const cookie = cookieHeader(cookies);
    if (!cookie) {
      throw dshWebError({
        classification: "protocol",
        code: "dsh_web_api_cookie_missing",
        message: "DSH Web did not issue an API cookie.",
      });
    }
    this.cookie = cookie;
    this.launchToken = null;
    await response.body?.cancel();
  }

  #clearSecrets() {
    this.launchToken = null;
    this.cookie = null;
    this.baseUrl = null;
  }

  async rpc(endpoint, args, {
    signal,
    timeoutMs = this.rpcTimeoutMs,
  } = {}) {
    if (!/^(?:[A-Za-z0-9_$.-]+)\/(?:[A-Za-z0-9_$.-]+)$/u.test(endpoint)) {
      throw dshWebError({
        classification: "protocol",
        code: "dsh_web_invalid_endpoint",
        message: "DSH Web RPC endpoint is invalid.",
      });
    }
    await this.open();
    const rpcId = randomUUID();
    const timeoutSignal = AbortSignal.timeout(timeoutMs);
    const combinedSignal = signal
      ? AbortSignal.any([signal, timeoutSignal])
      : timeoutSignal;
    let response;
    try {
      response = await fetch(new URL(`/api/${endpoint}`, this.baseUrl), {
        method: "POST",
        redirect: "manual",
        headers: {
          "content-type": "application/json",
          cookie: this.cookie,
        },
        body: JSON.stringify({
          type: "client-request",
          rpcId,
          method: endpoint,
          payload: { args },
        }),
        signal: combinedSignal,
      });
    } catch (error) {
      if (combinedSignal.aborted) {
        throw dshWebError({
          classification: "unavailable",
          code: "dsh_web_rpc_timeout",
          message: "DSH Web RPC did not finish before its timeout.",
          cause: error,
        });
      }
      throw dshWebError({
        classification: "unavailable",
        code: "dsh_web_rpc_unavailable",
        message: "DSH Web RPC transport failed.",
        cause: error,
      });
    }
    let body;
    try {
      body = await response.json();
    } catch (error) {
      if (response.status === 401) {
        throw dshWebError({
          classification: "auth",
          code: "dsh_web_authentication_required",
          message: "DSH Web RPC authentication failed.",
          cause: error,
        });
      }
      throw dshWebError({
        classification: "protocol",
        code: "dsh_web_invalid_rpc_response",
        message: `DSH Web RPC returned non-JSON content with HTTP ${response.status}.`,
        cause: error,
      });
    }
    if (response.status === 401) {
      throw dshWebError({
        classification: "auth",
        code: "dsh_web_authentication_required",
        message: "DSH Web RPC authentication failed.",
      });
    }
    if (
      !body ||
      body.type !== "server-response" ||
      body.rpcId !== rpcId ||
      !body.result ||
      typeof body.result.ok !== "boolean"
    ) {
      throw dshWebError({
        classification: "protocol",
        code: "dsh_web_invalid_rpc_envelope",
        message: "DSH Web RPC returned an invalid response envelope.",
      });
    }
    if (body.result.ok === true) {
      return body.result.value;
    }
    const remoteCode = String(body.result.error?.code ?? "");
    const classification = errorClassificationForCode(
      remoteCode,
      response.status >= 500 ? "unavailable" : "protocol",
    );
    throw dshWebError({
      classification,
      code: remoteCode || "dsh_web_rpc_failed",
      message: sanitizeDSHWebError(
        body.result.error?.message || "DSH Web RPC failed.",
      ),
    });
  }

  async close() {
    if (this.closing) return this.closing;
    this.closing = (async () => {
      if (this.processExitHandler) {
        process.off("exit", this.processExitHandler);
        this.processExitHandler = null;
      }
      const child = this.child;
      const pid = this.childPid;
      this.child = null;
      this.childPid = null;
      this.#clearSecrets();
      if (!child || child.exitCode !== null) return;
      const exited = new Promise((resolveExit) => {
        child.once("exit", resolveExit);
      });
      child.kill();
      await Promise.race([
        exited,
        new Promise((resolveTimeout) => {
          setTimeout(resolveTimeout, this.closeTimeoutMs).unref?.();
        }),
      ]);
      if (child.exitCode === null) {
        child.kill("SIGKILL");
      }
      this.lastExit = {
        ...this.lastExit,
        requested_pid: pid,
        orderly_close: true,
      };
    })();
    try {
      await this.closing;
    } finally {
      this.closing = null;
    }
  }
}
