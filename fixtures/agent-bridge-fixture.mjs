import { createServer } from "node:http";
import { randomUUID } from "node:crypto";

const PROTOCOL_VERSION = "0.1-draft";
const DEFAULT_TOKEN = "fixture-agent-bridge-token-0123456789";

function sendJson(response, status, value) {
  const body = `${JSON.stringify(value)}\n`;
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  response.end(body);
}

async function readJson(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 4 * 1024 * 1024) {
      const error = new Error("fixture request too large");
      error.statusCode = 413;
      throw error;
    }
    chunks.push(chunk);
  }
  if (chunks.length === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function fixturePanel(text) {
  const summary = String(text || "Agent Bridge fixture turn").slice(0, 120);
  return {
    schema_version: "1.2",
    turn_summary: summary,
    current_goal: "验证 Agent Bridge 本地契约",
    status: "ready",
    judgement:
      "本轮由确定性 Agent Bridge fixture 完成，只验证协议、Session 和结构化输出，不形成领域判断。",
    question: null,
    recommendation: {
      summary: "契约已通过，可继续验证恢复和取消。",
      option_id: null,
    },
    evidence: [
      {
        id: "bridge-turn-input",
        label: "Bridge turn input",
        detail: summary,
        source: "observed_current",
        relation: "context",
      },
    ],
    uncertainty: ["Fixture 不代表真实 Agent 的回答质量。"],
    recommendations: [
      {
        id: "bridge-verify-resume",
        title: "验证 Session 恢复",
        detail: "使用相同 Session ID 再次提交一个 turn。",
        risk: "low",
        evidence_goal: "确认 bridge Session 可以恢复。",
      },
      {
        id: "bridge-verify-cancel",
        title: "验证取消操作",
        detail: "在慢 turn 执行期间调用取消接口。",
        risk: "low",
        evidence_goal: "确认取消映射不会产生假成功。",
      },
    ],
    priorityAction: {
      title: "继续契约测试",
      detail: "保持确定性 fixture，不调用真实模型。",
    },
    actions: [
      {
        id: "bridge-copy",
        label: "复制协议版本",
        kind: "copy",
        content: "agent-bridge/0.1-draft",
      },
    ],
    artifact_refs: [],
    blocks: [],
  };
}

function wait(ms, signal) {
  return new Promise((resolvePromise, rejectPromise) => {
    const timer = setTimeout(resolvePromise, ms);
    if (signal) {
      signal.addEventListener(
        "abort",
        () => {
          clearTimeout(timer);
          rejectPromise(new Error("fixture turn cancelled"));
        },
        { once: true },
      );
    }
  });
}

export async function startAgentBridgeFixture({
  token = DEFAULT_TOKEN,
  host = "127.0.0.1",
} = {}) {
  const sessions = new Map();
  const cancellationControllers = new Map();
  let requests = 0;

  const server = createServer(async (request, response) => {
    requests += 1;
    if (request.headers.authorization !== `Bearer ${token}`) {
      sendJson(response, 401, {
        error: {
          classification: "auth",
          code: "fixture_auth_required",
          message: "A bearer token is required.",
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
        sendJson(response, 200, {
          protocol_version: PROTOCOL_VERSION,
          implementation: {
            name: "deterministic-agent-bridge-fixture",
            version: "1.0.0",
          },
          capabilities: {
            text_input: true,
            session_create: true,
            session_scope: "workspace",
            session_resume: true,
            session_naming: true,
            structured_output: true,
            streaming: false,
            cancellation: true,
            approvals: false,
            active_attach: false,
          },
          limitations: [],
        });
        return;
      }
      if (request.method === "POST" && url.pathname === "/v1/sessions") {
        const body = await readJson(request);
        const createdAt = new Date().toISOString();
        const session = {
          id: `session-${randomUUID()}`,
          name: null,
          created_at: createdAt,
          workspace: String(body.workspace ?? process.cwd()),
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
            code: "fixture_endpoint_not_found",
            message: "Unknown Agent Bridge endpoint.",
          },
        });
        return;
      }
      const sessionId = decodeURIComponent(match[1]);
      const action = match[2] ?? null;
      const session = sessions.get(sessionId);
      if (!session) {
        sendJson(response, 404, {
          error: {
            classification: "blocked",
            code: "fixture_session_not_found",
            message: "The Agent Bridge Session was not found.",
          },
        });
        return;
      }
      if (request.method === "GET" && action === null) {
        sendJson(response, 200, { session });
        return;
      }
      if (request.method === "POST" && action === "name") {
        const body = await readJson(request);
        session.name = String(body.name ?? "").slice(0, 120) || null;
        sendJson(response, 200, { session });
        return;
      }
      if (request.method === "POST" && action === "cancel") {
        const body = await readJson(request);
        const controller = cancellationControllers.get(String(body.turn_id));
        if (controller) controller.abort();
        sendJson(response, 200, { cancelled: true });
        return;
      }
      if (request.method === "POST" && action === "turns") {
        const body = await readJson(request);
        const turnId = String(body.turn_id ?? "");
        if (!turnId) {
          sendJson(response, 400, {
            error: {
              classification: "protocol",
              code: "fixture_turn_id_missing",
              message: "turn_id is required.",
            },
          });
          return;
        }
        const packetText = String(body.packet?.text ?? "");
        if (packetText.includes("[BRIDGE_ERROR_AUTH]")) {
          sendJson(response, 401, {
            error: {
              classification: "auth",
              code: "fixture_model_auth_required",
              message: "Fixture requested an authentication error.",
            },
          });
          return;
        }
        const controller = new AbortController();
        cancellationControllers.set(turnId, controller);
        if (packetText.includes("[BRIDGE_SLOW]")) {
          await wait(2_000, controller.signal);
        }
        cancellationControllers.delete(turnId);
        const panel = fixturePanel(packetText);
        sendJson(response, 200, {
          turn_id: turnId,
          status: "completed",
          output: {
            text: JSON.stringify(panel),
            structured: panel,
          },
        });
        return;
      }
      sendJson(response, 405, {
        error: {
          classification: "protocol",
          code: "fixture_method_not_allowed",
          message: "Method is not allowed for this endpoint.",
        },
      });
    } catch (error) {
      if (error?.name === "AbortError" || /cancelled/u.test(error?.message)) {
        return;
      }
      sendJson(response, Number(error?.statusCode ?? 400), {
        error: {
          classification: "protocol",
          code: "fixture_request_invalid",
          message: String(error?.message ?? "Fixture request failed").slice(
            0,
            500,
          ),
        },
      });
    }
  });

  await new Promise((resolvePromise, rejectPromise) => {
    server.once("error", rejectPromise);
    server.listen(0, host, resolvePromise);
  });
  const address = server.address();
  if (!address || typeof address !== "object") {
    throw new Error("Agent Bridge fixture did not bind a TCP port.");
  }
  return {
    baseUrl: `http://${host}:${address.port}`,
    token,
    get requestCount() {
      return requests;
    },
    async close() {
      for (const controller of cancellationControllers.values()) {
        controller.abort();
      }
      cancellationControllers.clear();
      await new Promise((resolvePromise) => server.close(resolvePromise));
    },
  };
}

export { DEFAULT_TOKEN as AGENT_BRIDGE_FIXTURE_TOKEN };
