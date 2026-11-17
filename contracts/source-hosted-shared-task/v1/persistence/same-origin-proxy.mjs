import { createServer, request as httpRequest } from "node:http";
import { ERROR_CATALOG, errorResult } from "../reference/error-codes.mjs";

const SESSION_COOKIE = "skilldock_session";
const UNSCOPED_TASK_ID = "task-proxy-unscoped";
const SAFE_TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/u;
const PROTECTED_BODY_FIELDS = new Set([
  "action",
  "actor_id",
  "actor_role",
  "capability",
  "capability_token",
  "task_id",
  "taskId",
]);

const ROUTES = new Map([
  [
    "/api/source-hosted/mailbox/snapshot",
    { group: "mailbox", action: "snapshot" },
  ],
  [
    "/api/source-hosted/mailbox/pull",
    { group: "mailbox", action: "pull" },
  ],
  [
    "/api/source-hosted/mailbox/publish",
    { group: "mailbox", action: "publish" },
  ],
  [
    "/api/source-hosted/mailbox/ack",
    { group: "mailbox", action: "ack" },
  ],
  [
    "/api/source-hosted/lease/claim",
    { group: "lease", action: "claim_lease" },
  ],
  [
    "/api/source-hosted/lease/release",
    { group: "lease", action: "release_lease" },
  ],
]);

class ProxyTransportError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = "ProxyTransportError";
    this.status = status;
    this.code = code;
  }
}

function writeJson(response, status, value, extraHeaders = {}) {
  const body = `${JSON.stringify(value)}\n`;
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    ...extraHeaders,
  });
  response.end(body);
}

function errorBody(requestId, taskId, code, message) {
  return errorResult({
    requestId: requestId || "request-proxy-error",
    taskId: taskId || UNSCOPED_TASK_ID,
    code,
    message,
  });
}

function statusForError(code) {
  return ERROR_CATALOG[code]?.http_status ?? 500;
}

function readBody(request, maxBytes, timeoutMs) {
  return new Promise((resolvePromise, rejectPromise) => {
    const declared = Number(request.headers["content-length"]);
    if (Number.isFinite(declared) && declared > maxBytes) {
      rejectPromise(new ProxyTransportError(
        413,
        "payload_too_large",
        "The browser request body exceeds its limit.",
      ));
      request.resume();
      return;
    }
    const chunks = [];
    let size = 0;
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      rejectPromise(new ProxyTransportError(
        408,
        "invalid_request",
        "The browser request body timed out.",
      ));
    }, timeoutMs);
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      fn(value);
    };
    request.on("data", (chunk) => {
      size += chunk.length;
      if (size > maxBytes) {
        finish(
          rejectPromise,
          new ProxyTransportError(
            413,
            "payload_too_large",
            "The browser request body exceeds its limit.",
          ),
        );
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.once("end", () => {
      finish(resolvePromise, Buffer.concat(chunks).toString("utf8"));
    });
    request.once("aborted", () => {
      finish(
        rejectPromise,
        new ProxyTransportError(
          400,
          "invalid_request",
          "The browser disconnected before the request completed.",
        ),
      );
    });
    request.once("error", () => {
      finish(
        rejectPromise,
        new ProxyTransportError(
          400,
          "invalid_request",
          "The browser request body failed.",
        ),
      );
    });
  });
}

function sessionCookie(request) {
  const header = request.headers.cookie;
  if (typeof header !== "string") return null;
  const values = [];
  for (const part of header.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0) continue;
    const name = part.slice(0, separator).trim();
    if (name !== SESSION_COOKIE) continue;
    values.push(part.slice(separator + 1).trim());
  }
  return values.length === 1 && values[0] ? values[0] : null;
}

function resolveSession(sessions, sessionId) {
  if (!sessionId) return null;
  if (sessions instanceof Map) return sessions.get(sessionId) ?? null;
  if (
    sessions &&
    Object.prototype.hasOwnProperty.call(sessions, sessionId)
  ) {
    return sessions[sessionId];
  }
  return null;
}

function upstreamRequest({
  coordinatorBaseUrl,
  taskId,
  action,
  token,
  body,
  timeoutMs,
  upstreamObserver,
}) {
  const url = new URL(
    `/v1/tasks/${encodeURIComponent(taskId)}/${
      action.startsWith("claim") || action.startsWith("release")
        ? "lease"
        : "mailbox"
    }/${
      action === "claim_lease"
        ? "claim"
        : action === "release_lease"
          ? "release"
          : action
    }`,
    coordinatorBaseUrl,
  );
  const payload = Buffer.from(JSON.stringify(body), "utf8");
  const headers = {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": payload.length,
  };
  upstreamObserver?.({
    action,
    taskId,
    headers: { ...headers },
  });
  return new Promise((resolvePromise, rejectPromise) => {
    const upstream = httpRequest(url, {
      method: "POST",
      headers,
      timeout: timeoutMs,
    }, (response) => {
      const chunks = [];
      let size = 0;
      response.on("data", (chunk) => {
        size += chunk.length;
        if (size > 1024 * 1024) {
          upstream.destroy(new Error("upstream response too large"));
          return;
        }
        chunks.push(chunk);
      });
      response.once("end", () => {
        resolvePromise({
          status: response.statusCode ?? 500,
          text: Buffer.concat(chunks).toString("utf8"),
        });
      });
    });
    upstream.once("timeout", () => {
      upstream.destroy(new Error("upstream timeout"));
    });
    upstream.once("error", rejectPromise);
    upstream.end(payload);
  });
}

function tokenForAction(session, action) {
  if (action === "claim_lease" || action === "release_lease") {
    return session?.controlToken;
  }
  return session?.mailboxToken;
}

export async function startIsolatedSkillDockProxy({
  coordinatorBaseUrl,
  sessions,
  port = 0,
  host = "127.0.0.1",
  bodyTimeoutMs = 5_000,
  upstreamTimeoutMs = 5_000,
  accessLog = null,
  upstreamObserver = null,
} = {}) {
  if (host !== "127.0.0.1") {
    throw new Error("Isolated SkillDock proxy must bind 127.0.0.1");
  }
  let coordinatorUrl;
  try {
    coordinatorUrl = new URL(coordinatorBaseUrl);
  } catch {
    throw new Error("A valid coordinatorBaseUrl is required");
  }
  if (coordinatorUrl.protocol !== "http:") {
    throw new Error("The isolated proxy requires an http coordinator");
  }

  let proxyBaseUrl = "";
  const server = createServer(async (request, response) => {
    let requestId = "request-proxy-error";
    let taskId = UNSCOPED_TASK_ID;
    let action = "rejected";
    const respond = (status, body, headers = {}) => {
      writeJson(response, status, body, headers);
      accessLog?.({
        action,
        status,
        ok: body?.ok === true,
      });
    };
    try {
      const address = server.address();
      const actualPort =
        address && typeof address === "object" ? address.port : null;
      if (!actualPort || request.headers.host !== `127.0.0.1:${actualPort}`) {
        respond(
          403,
          errorBody(requestId, taskId, "invalid_host", "The Host is invalid."),
        );
        return;
      }
      proxyBaseUrl = `http://127.0.0.1:${actualPort}`;
      if (request.headers.origin !== proxyBaseUrl) {
        respond(
          403,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "A same-origin browser request is required.",
          ),
        );
        return;
      }
      if (request.headers.authorization !== undefined) {
        respond(
          400,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "Browser requests cannot provide coordinator credentials.",
          ),
        );
        return;
      }
      const url = new URL(request.url, proxyBaseUrl);
      const route = ROUTES.get(url.pathname);
      if (!route) {
        respond(
          404,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "Unknown SkillDock proxy endpoint.",
          ),
        );
        return;
      }
      action = route.action;
      if (request.method !== "POST") {
        respond(
          405,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "Only POST is allowed for this endpoint.",
          ),
          { Allow: "POST" },
        );
        return;
      }
      if (url.search !== "") {
        respond(
          400,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "Query parameters are not supported.",
          ),
        );
        return;
      }
      const sessionId = sessionCookie(request);
      if (!sessionId) {
        respond(
          401,
          errorBody(
            requestId,
            taskId,
            "capability_missing",
            "A SkillDock same-origin session is required.",
          ),
        );
        return;
      }
      const session = resolveSession(sessions, sessionId);
      if (!session) {
        respond(
          401,
          errorBody(
            requestId,
            taskId,
            "capability_invalid",
            "The SkillDock same-origin session is invalid.",
          ),
        );
        return;
      }
      if (
        typeof session.taskId === "string" &&
        SAFE_TASK_ID.test(session.taskId)
      ) {
        taskId = session.taskId;
      } else {
        throw new Error("Invalid isolated proxy session Task binding");
      }
      const coordinatorToken = tokenForAction(session, action);
      if (
        typeof coordinatorToken !== "string" ||
        coordinatorToken.length === 0
      ) {
        throw new Error("Invalid isolated proxy session capability binding");
      }
      const contentType = String(request.headers["content-type"] ?? "");
      if (
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(contentType)
      ) {
        respond(
          415,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "Content-Type must be application/json.",
          ),
        );
        return;
      }
      const maxBytes = action === "publish" ? 256 * 1024 : 64 * 1024;
      const raw = await readBody(request, maxBytes, bodyTimeoutMs);
      let body;
      try {
        body = JSON.parse(raw);
      } catch {
        respond(
          400,
          errorBody(
            requestId,
            taskId,
            "schema_invalid",
            "The browser request body is not valid JSON.",
          ),
        );
        return;
      }
      if (typeof body?.request_id === "string") {
        requestId = body.request_id;
      }
      if (
        body &&
        typeof body === "object" &&
        !Array.isArray(body) &&
        Object.keys(body).some((key) => PROTECTED_BODY_FIELDS.has(key))
      ) {
        respond(
          400,
          errorBody(
            requestId,
            taskId,
            "invalid_request",
            "Browser requests cannot override Task, action, or capability.",
          ),
        );
        return;
      }
      const upstream = await upstreamRequest({
        coordinatorBaseUrl: coordinatorUrl,
        taskId,
        action,
        token: coordinatorToken,
        body,
        timeoutMs: upstreamTimeoutMs,
        upstreamObserver,
      });
      let upstreamBody;
      try {
        upstreamBody = JSON.parse(upstream.text);
      } catch {
        throw new Error("Invalid upstream response");
      }
      if (upstream.status >= 500) {
        respond(
          500,
          errorBody(
            requestId,
            taskId,
            "internal_error",
            "The source-hosted coordinator failed.",
          ),
        );
        return;
      }
      respond(
        upstream.status,
        { ...upstreamBody, task_id: taskId },
      );
    } catch (error) {
      const transport =
        error instanceof ProxyTransportError ? error : null;
      respond(
        transport?.status ?? 500,
        errorBody(
          requestId,
          taskId,
          transport?.code ?? "internal_error",
          transport?.message ?? "The isolated SkillDock proxy failed.",
        ),
      );
    }
  });

  await new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(port, host, resolvePromise);
  });
  const address = server.address();
  if (!address || typeof address !== "object") {
    await new Promise((resolvePromise) => server.close(resolvePromise));
    throw new Error("Isolated SkillDock proxy did not bind a port");
  }
  proxyBaseUrl = `http://${host}:${address.port}`;
  return {
    host,
    port: address.port,
    baseUrl: proxyBaseUrl,
    async close() {
      await new Promise((resolvePromise) => server.close(resolvePromise));
    },
  };
}
