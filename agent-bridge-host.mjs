import { createHash, randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdirSync } from "node:fs";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  AgentDriverError,
  createAgentDriver,
} from "./lib/agents/index.mjs";

const PROTOCOL_VERSION = "0.1-draft";
const MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const root = resolve(import.meta.dirname);

function sendJson(response, status, value) {
  const body = `${JSON.stringify(value)}\n`;
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
  });
  response.end(body);
}

function tokenMatches(candidate, expected) {
  const left = createHash("sha256").update(String(candidate ?? "")).digest();
  const right = createHash("sha256").update(String(expected ?? "")).digest();
  return timingSafeEqual(left, right);
}

function authorize(request, token) {
  const bearer = String(request.headers.authorization ?? "").replace(
    /^Bearer\s+/iu,
    "",
  );
  return tokenMatches(bearer, token);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > MAX_REQUEST_BYTES) {
      const error = new Error("Agent Bridge request exceeds the size limit.");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    const error = new Error("Agent Bridge request is not valid JSON.");
    error.statusCode = 400;
    throw error;
  }
}

function sanitizeMessage(value) {
  return String(value ?? "Agent Bridge request failed")
    .replace(/sk-[A-Za-z0-9_-]{16,}/gu, "[redacted-key]")
    .replace(/Bearer\s+\S+/giu, "Bearer [redacted]")
    .replace(
      /(?:DEEPSEEK_API_KEY|DSH_PLATFORM_COOKIE|panel_token|handoff-secret)\s*[=:]\s*\S+/giu,
      "[redacted-credential]",
    )
    .slice(0, 500);
}

function errorStatus(classification) {
  if (classification === "auth") return 401;
  if (classification === "permission") return 403;
  if (classification === "blocked") return 409;
  if (classification === "unavailable") return 503;
  return 500;
}

function capabilityDescriptor(driver) {
  return {
    protocol_version: PROTOCOL_VERSION,
    implementation: {
      name: String(driver.capabilities.displayName ?? driver.name),
      version: "0.1.0-dev",
    },
    capabilities: {
      text_input: true,
      session_create: true,
      session_resume: driver.capabilities.supportsThreadResume === true,
      session_naming: driver.capabilities.supportsThreadNaming === true,
      structured_output:
        driver.capabilities.supportsStructuredOutput === true,
      streaming: false,
      cancellation: driver.capabilities.supportsCancellation === true,
      approvals: false,
      active_attach: false,
    },
    limitations: [
      "Agent Bridge 0.1-draft is synchronous and does not stream.",
      "The reference host exposes one active panel-owned Session at a time.",
    ],
  };
}

export async function startAgentBridgeHost({
  driver,
  token,
  host = "127.0.0.1",
  port = 0,
} = {}) {
  if (!driver || typeof driver.initialize !== "function") {
    throw new TypeError("An AgentDriver instance is required.");
  }
  if (host !== "127.0.0.1" && host !== "localhost" && host !== "::1") {
    throw new Error("Agent Bridge Host must bind a loopback address.");
  }
  const resolvedToken = String(token ?? "").trim();
  if (resolvedToken.length < 16 || resolvedToken.length > 4096) {
    throw new Error("Agent Bridge Host token must be 16 to 4096 characters.");
  }
  await driver.initialize();

  const sessions = new Map();
  let activeSessionId = null;

  const ensureSession = async (sessionId) => {
    if (activeSessionId !== sessionId) {
      const resumed = await driver.resumeThread(sessionId);
      activeSessionId = resumed.threadReference;
    }
    if (!sessions.has(sessionId)) {
      sessions.set(sessionId, {
        id: sessionId,
        name: driver.activeThreadName ?? null,
        created_at: new Date().toISOString(),
      });
    }
    return sessions.get(sessionId);
  };

  const server = createServer(async (request, response) => {
    if (!authorize(request, resolvedToken)) {
      sendJson(response, 401, {
        error: {
          classification: "auth",
          code: "agent_bridge_auth_required",
          message: "A valid Agent Bridge bearer token is required.",
        },
      });
      return;
    }
    const url = new URL(request.url, `http://${host}`);
    try {
      if (request.method === "GET" && url.pathname === "/v1/health") {
        sendJson(response, 200, {
          ok: true,
          protocol_version: PROTOCOL_VERSION,
        });
        return;
      }
      if (request.method === "GET" && url.pathname === "/v1/capabilities") {
        sendJson(response, 200, capabilityDescriptor(driver));
        return;
      }
      if (request.method === "POST" && url.pathname === "/v1/sessions") {
        await readJson(request);
        const started = await driver.startThread();
        activeSessionId = started.threadReference;
        const session = {
          id: activeSessionId,
          name: driver.activeThreadName ?? null,
          created_at: new Date().toISOString(),
        };
        sessions.set(session.id, session);
        sendJson(response, 201, { session });
        return;
      }

      const match = url.pathname.match(
        /^\/v1\/sessions\/([^/]+)(?:\/(name|turns|cancel))?$/u,
      );
      if (!match) {
        sendJson(response, 404, {
          error: {
            classification: "protocol",
            code: "agent_bridge_endpoint_not_found",
            message: "Unknown Agent Bridge endpoint.",
          },
        });
        return;
      }
      const sessionId = decodeURIComponent(match[1]);
      const action = match[2] ?? null;
      const session = await ensureSession(sessionId);

      if (request.method === "GET" && action === null) {
        sendJson(response, 200, { session });
        return;
      }
      if (request.method === "POST" && action === "name") {
        const body = await readJson(request);
        session.name = await driver.setThreadName(body.name);
        sendJson(response, 200, { session });
        return;
      }
      if (request.method === "POST" && action === "turns") {
        const body = await readJson(request);
        const result = await driver.sendTurn({
          threadReference: sessionId,
          eventId: body.request_id,
          packet: body.packet,
          structuredOutputSchema: body.output_schema,
        });
        sendJson(response, 200, {
          turn_id: body.turn_id,
          status: "completed",
          output: {
            text: result.finalText ?? "",
            structured: result.structuredOutput ?? null,
          },
        });
        return;
      }
      if (request.method === "POST" && action === "cancel") {
        const body = await readJson(request);
        await driver.cancel(body.turn_id);
        sendJson(response, 200, { cancelled: true });
        return;
      }
      sendJson(response, 405, {
        error: {
          classification: "protocol",
          code: "agent_bridge_method_not_allowed",
          message: "Method is not allowed for this endpoint.",
        },
      });
    } catch (error) {
      const classified =
        error instanceof AgentDriverError
          ? error
          : driver.classifyError(error);
      sendJson(response, errorStatus(classified.classification), {
        error: {
          classification: classified.classification,
          code: String(classified.code ?? "agent_bridge_error").slice(0, 120),
          message: sanitizeMessage(classified.message),
        },
      });
    }
  });

  await new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(port, host, resolvePromise);
  });
  const address = server.address();
  if (!address || typeof address !== "object") {
    throw new Error("Agent Bridge Host did not bind a TCP port.");
  }
  return {
    baseUrl: `http://${host}:${address.port}`,
    token: resolvedToken,
    async close() {
      await new Promise((resolvePromise) => server.close(resolvePromise));
      await driver.close();
    },
  };
}

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

async function main() {
  const driverName = argumentValue("--driver") ?? "codex";
  if (driverName === "agent-bridge") {
    throw new Error("The bridge host cannot wrap itself.");
  }
  const port = Number(argumentValue("--port") ?? 0);
  const dataDirectory = resolve(
    process.env.AGENT_BRIDGE_HOST_DATA_DIR ??
      resolve(root, "work", "agent-bridge-host"),
  );
  mkdirSync(dataDirectory, { recursive: true });
  const token =
    String(process.env.AGENT_BRIDGE_HOST_TOKEN ?? "").trim() ||
    randomBytes(32).toString("base64url");
  const driver = createAgentDriver(driverName, {
    cwd: root,
    agentDataDir: dataDirectory,
  });
  const bridge = await startAgentBridgeHost({ driver, token, port });
  process.stdout.write(`Agent Bridge ${driverName} listening at ${bridge.baseUrl}\n`);
  process.stdout.write(`Agent Bridge token: ${bridge.token}\n`);

  const shutdown = async () => {
    await bridge.close().catch(() => {});
    process.exit(0);
  };
  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(resolve(process.argv[1])).href
) {
  main().catch((error) => {
    process.stderr.write(`${sanitizeMessage(error?.message ?? error)}\n`);
    process.exit(1);
  });
}
