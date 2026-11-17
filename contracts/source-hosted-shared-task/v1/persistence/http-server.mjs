import { createServer } from "node:http";
import { ERROR_CATALOG, errorResult } from "../reference/error-codes.mjs";
import {
  openSqliteConformanceCoordinator,
} from "./sqlite-coordinator.mjs";

class HttpTransportError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = "HttpTransportError";
    this.status = status;
    this.code = code;
  }
}

const SAFE_TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/u;
const UNSCOPED_TASK_ID = "task-http-unscoped";

function writeJson(request, response, status, value) {
  const body = `${JSON.stringify(value)}\n`;
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
  });
  response.end(body);
}

function transportError(requestId, taskId, status, code, message) {
  const base = errorResult({
    requestId: requestId || "request-http-error",
    taskId: taskId || UNSCOPED_TASK_ID,
    code,
    message,
  });
  return { status, body: base };
}

function statusForError(code) {
  return ERROR_CATALOG[code]?.http_status ?? 500;
}

function parseBearer(value) {
  if (typeof value !== "string") return null;
  const match = value.match(/^Bearer ([^\s]+)$/u);
  return match?.[1] ?? null;
}

function readBody(request, maxBytes, timeoutMs) {
  return new Promise((resolve, reject) => {
    const declared = Number(request.headers["content-length"]);
    if (Number.isFinite(declared) && declared > maxBytes) {
      reject(new HttpTransportError(
        413,
        "payload_too_large",
        "The HTTP request body exceeds its limit.",
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
      reject(new HttpTransportError(
        408,
        "invalid_request",
        "The HTTP request body timed out.",
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
          reject,
          new HttpTransportError(
            413,
            "payload_too_large",
            "The HTTP request body exceeds its limit.",
          ),
        );
        request.resume();
        return;
      }
      chunks.push(chunk);
    });
    request.once("end", () => {
      finish(resolve, Buffer.concat(chunks).toString("utf8"));
    });
    request.once("aborted", () => {
      finish(
        reject,
        new HttpTransportError(
          400,
          "invalid_request",
          "The HTTP client disconnected before the request completed.",
        ),
      );
    });
    request.once("error", (error) => {
      finish(
        reject,
        new HttpTransportError(
          400,
          "invalid_request",
          `The HTTP request body failed: ${error.message}`,
        ),
      );
    });
  });
}

function routeFor(pathname) {
  const match = pathname.match(
    /^\/v1\/tasks\/([^/]+)\/(mailbox\/(snapshot|pull|publish|ack)|lease\/(claim|release))$/u,
  );
  if (!match) return null;
  let taskId;
  try {
    taskId = decodeURIComponent(match[1]);
  } catch {
    return null;
  }
  if (!SAFE_TASK_ID.test(taskId)) return null;
  if (match[3]) {
    return {
      taskId,
      group: "mailbox",
      action: match[3],
    };
  }
  return {
    taskId,
    group: "lease",
    action: match[4] === "claim" ? "claim_lease" : "release_lease",
  };
}

export async function startIsolatedHttpServer({
  dbPath,
  port = 0,
  host = "127.0.0.1",
  bodyTimeoutMs = 5_000,
  responseFault = null,
} = {}) {
  if (host !== "127.0.0.1") {
    throw new Error("Isolated HTTP profile must bind 127.0.0.1");
  }
  const coordinator = openSqliteConformanceCoordinator({ dbPath });

  const server = createServer(async (request, response) => {
    let requestId = "request-http-error";
    let taskId = UNSCOPED_TASK_ID;
    try {
      const address = server.address();
      const actualPort =
        address && typeof address === "object" ? address.port : null;
      const expectedHost = actualPort
        ? `127.0.0.1:${actualPort}`
        : null;
      if (!expectedHost || request.headers.host !== expectedHost) {
        const item = transportError(
          requestId,
          taskId,
          403,
          "invalid_host",
          "The HTTP Host header is invalid.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      if (request.headers.origin !== undefined) {
        const item = transportError(
          requestId,
          taskId,
          403,
          "invalid_request",
          "Direct browser-origin access is not supported.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      const url = new URL(request.url, `http://${expectedHost}`);
      const route = routeFor(url.pathname);
      if (!route) {
        const item = transportError(
          requestId,
          taskId,
          404,
          "invalid_request",
          "Unknown conformance endpoint.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      taskId = route.taskId;
      if (request.method !== "POST") {
        response.setHeader("Allow", "POST");
        const item = transportError(
          requestId,
          taskId,
          405,
          "invalid_request",
          "Only POST is allowed for this endpoint.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      if (!coordinator.hasTask(taskId)) {
        const item = transportError(
          requestId,
          taskId,
          404,
          "task_not_found",
          "The requested Task is unavailable.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      const token = parseBearer(request.headers.authorization);
      if (!token) {
        const item = transportError(
          requestId,
          taskId,
          401,
          "capability_missing",
          "A bearer capability is required.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      const auth = coordinator.authorize(token, route.action, { taskId });
      if (!auth.ok) {
        writeJson(
          request,
          response,
          statusForError(auth.error.code),
          { ...auth, request_id: requestId, task_id: taskId },
        );
        return;
      }
      if (url.search !== "") {
        const item = transportError(
          requestId,
          taskId,
          400,
          "invalid_request",
          "Query parameters are not supported.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      const contentType = String(request.headers["content-type"] ?? "");
      if (
        !/^application\/json(?:\s*;\s*charset=utf-8)?$/iu.test(contentType)
      ) {
        const item = transportError(
          requestId,
          taskId,
          415,
          "invalid_request",
          "Content-Type must be application/json.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      const maxBytes = route.action === "publish"
        ? 256 * 1024
        : 64 * 1024;
      const raw = await readBody(request, maxBytes, bodyTimeoutMs);
      let body;
      try {
        body = JSON.parse(raw);
      } catch {
        const item = transportError(
          requestId,
          taskId,
          400,
          "schema_invalid",
          "The HTTP request body is not valid JSON.",
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      requestId =
        typeof body?.request_id === "string"
          ? body.request_id
          : requestId;
      let result;
      if (route.action === "snapshot") {
        result = coordinator.snapshot(token, body, { taskId });
      } else if (route.action === "pull") {
        result = coordinator.pull(token, body, { taskId });
      } else if (route.action === "publish") {
        result = coordinator.publish(token, body, { taskId });
      } else if (route.action === "ack") {
        result = coordinator.ack(token, body, { taskId });
      } else if (route.action === "claim_lease") {
        result = coordinator.claimLease(token, body, { taskId });
      } else if (route.action === "release_lease") {
        result = coordinator.releaseLease(token, body, { taskId });
      } else {
        throw new Error("Unsupported route action");
      }
      if (result.ok && typeof responseFault === "function") {
        const fault = responseFault({
          action: route.action,
          request,
          response,
          result,
        });
        if (fault === "drop") {
          request.socket.destroy();
          return;
        }
      }
      const status = result.ok ? 200 : statusForError(result.error.code);
      writeJson(
        request,
        response,
        status,
        {
          ...result,
          request_id: result.ok ? result.request_id : requestId,
          task_id: taskId,
        },
      );
    } catch (error) {
      if (error instanceof HttpTransportError) {
        const item = transportError(
          requestId,
          taskId,
          error.status,
          error.code,
          error.message,
        );
        writeJson(request, response, item.status, item.body);
        return;
      }
      const busy = /database is locked|SQLITE_BUSY/iu.test(
        String(error?.message ?? error),
      );
      const item = transportError(
        requestId,
        taskId,
        busy ? 429 : 500,
        busy ? "rate_limited" : "internal_error",
        busy
          ? "The SQLite writer is temporarily busy."
          : "The isolated coordinator failed.",
      );
      writeJson(request, response, item.status, item.body);
    }
  });

  await new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(port, host, resolvePromise);
  });
  const address = server.address();
  if (!address || typeof address !== "object") {
    coordinator.close();
    server.close();
    throw new Error("Isolated HTTP server did not bind a port");
  }
  return {
    host,
    port: address.port,
    baseUrl: `http://${host}:${address.port}`,
    coordinator,
    async close() {
      const closed = new Promise((resolvePromise) => {
        server.close(resolvePromise);
      });
      server.closeIdleConnections?.();
      server.closeAllConnections?.();
      await closed;
      coordinator.close();
    },
  };
}
