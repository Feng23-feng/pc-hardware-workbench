import { spawn } from "node:child_process";
import {
  existsSync,
  readFileSync,
  statSync,
} from "node:fs";
import { resolve } from "node:path";
import {
  HANDOFF_LIMITS,
  signHandoffToken,
} from "./lib/handoff-capability.mjs";

const root = resolve(import.meta.dirname);

function parseArgs(argv) {
  const result = {
    open: false,
    ttlSeconds: 120,
    baseUrl: "http://127.0.0.1:4319/",
    secretFile: resolve(root, "runtime", "handoff-secret"),
    packetFile: null,
    sessionId: null,
    taskId: null,
    objective: null,
    summary: "",
    domainState: {},
    domainRefs: [],
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = () => {
      const next = argv[++index];
      if (!next || next.startsWith("--")) {
        throw new Error(`${arg} requires a value`);
      }
      return next;
    };
    if (arg === "--open") {
      result.open = true;
    } else if (arg === "--packet-file") {
      result.packetFile = resolve(value());
    } else if (arg === "--secret-file" || arg === "--token-file") {
      result.secretFile = resolve(value());
    } else if (arg === "--base-url") {
      result.baseUrl = value();
    } else if (arg === "--ttl") {
      result.ttlSeconds = Number.parseInt(value(), 10);
    } else if (arg === "--session-id" || arg === "--thread-id") {
      result.sessionId = value();
    } else if (arg === "--task-id") {
      result.taskId = value();
    } else if (arg === "--objective") {
      result.objective = value();
    } else if (arg === "--summary") {
      result.summary = value();
    } else if (arg === "--domain-ref") {
      result.domainRefs.push(value());
    } else if (arg === "--evidence-ref") {
      // Compatibility alias for pre-P9 producers.
      result.domainRefs.push(value());
    } else if (arg === "--help" || arg === "-h") {
      result.help = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  return result;
}

function usage() {
  return [
    "Usage:",
    "  node open-workbench.mjs --packet-file <handoff.json> [--open]",
    "  node open-workbench.mjs --session-id <id> --task-id <task> --objective <text>",
    "       --domain-ref <ref> [--domain-ref <ref> ...]",
    "",
    "Options:",
    "  --base-url <loopback-url>  Default http://127.0.0.1:4319/",
    "  --secret-file <path>       Local handoff signing secret",
    "  --ttl <seconds>            Signed URL lifetime, 15-600 seconds",
    "  --open                     Launch the system browser without a shell",
  ].join("\n");
}

function loadPacket(args) {
  if (args.packetFile) {
    if (!existsSync(args.packetFile)) {
      throw new Error(`packet file does not exist: ${args.packetFile}`);
    }
    if (statSync(args.packetFile).size > HANDOFF_LIMITS.maxPacketBytes) {
      throw new Error("handoff packet file is too large");
    }
    return JSON.parse(readFileSync(args.packetFile, "utf8"));
  }
  return {
    thread_id:
      args.sessionId ??
      process.env.AGENT_SESSION_ID ??
      process.env.CODEX_THREAD_ID ??
      null,
    task_id: args.taskId,
    objective: args.objective,
    summary: args.summary,
    domain_state: args.domainState,
    domain_refs: args.domainRefs,
    read_only: true,
    source: "agent-skill",
  };
}

function validateBaseUrl(value) {
  const url = new URL(value);
  if (
    url.protocol !== "http:" ||
    !["127.0.0.1", "localhost", "::1"].includes(url.hostname)
  ) {
    throw new Error("base URL must use loopback HTTP");
  }
  url.pathname = "/";
  url.search = "";
  url.hash = "";
  return url;
}

function openBrowser(url) {
  const command =
    process.platform === "win32"
      ? ["rundll32.exe", ["url.dll,FileProtocolHandler", url]]
      : process.platform === "darwin"
        ? ["open", [url]]
        : ["xdg-open", [url]];
  const child = spawn(command[0], command[1], {
    detached: true,
    stdio: "ignore",
    windowsHide: true,
  });
  child.unref();
}

try {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    process.stdout.write(`${usage()}\n`);
    process.exit(0);
  }
  const secret = readFileSync(args.secretFile, "utf8").trim();
  const packet = loadPacket(args);
  if (!packet.environment_thread_id && process.env.CODEX_THREAD_ID) {
    packet.environment_thread_id = process.env.CODEX_THREAD_ID;
  }
  if (
    process.env.CODEX_THREAD_ID &&
    packet.thread_id !== process.env.CODEX_THREAD_ID
  ) {
    process.stderr.write(
      `warning: packet thread ${packet.thread_id} differs from CODEX_THREAD_ID ${process.env.CODEX_THREAD_ID}\n`,
    );
  }
  const signed = signHandoffToken(packet, secret, {
    ttlSeconds: args.ttlSeconds,
  });
  const baseUrl = validateBaseUrl(args.baseUrl);
  baseUrl.searchParams.set("token", signed.token);
  const handoffUrl = new URL("/handoff/open", baseUrl);
  handoffUrl.search = baseUrl.search;
  const output = {
    url: handoffUrl.toString(),
    thread_id: signed.packet.thread_id,
    task_id: signed.packet.task_id,
    expires_at: signed.expires_at,
    native_thread_attachment: "blocked/experimental",
    support_level: "task-resume-packet",
    environment_thread_id: process.env.CODEX_THREAD_ID ?? null,
    thread_id_source:
      process.env.CODEX_THREAD_ID === signed.packet.thread_id
        ? "environment"
        : "packet",
  };
  if (args.open) {
    openBrowser(handoffUrl.toString());
    output.opened = true;
  }
  process.stdout.write(`${JSON.stringify(output, null, 2)}\n`);
} catch (error) {
  process.stderr.write(`open-workbench failed: ${error.message}\n\n${usage()}\n`);
  process.exitCode = 1;
}
