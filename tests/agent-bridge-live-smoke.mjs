import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { AgentBridgeDriver } from "../lib/agents/index.mjs";
import { runPanelTurn } from "../lib/panel-response.mjs";

const baseUrl = String(process.env.SKILLDOCK_AGENT_BRIDGE_URL ?? "").trim();
const token = String(process.env.SKILLDOCK_AGENT_BRIDGE_TOKEN ?? "").trim();
if (!baseUrl || !token) {
  throw new Error(
    "SKILLDOCK_AGENT_BRIDGE_URL and SKILLDOCK_AGENT_BRIDGE_TOKEN are required.",
  );
}

const root = import.meta.dirname.replace(/[\\/]tests$/u, "");
const schema = JSON.parse(
  await readFile(join(root, "schemas", "panel-ui-state.schema.json"), "utf8"),
);
const driver = new AgentBridgeDriver({ baseUrl, token });
try {
  await driver.initialize();
  const started = await driver.startThread();
  const begin = Date.now();
  const result = await runPanelTurn({
    driver,
    threadReference: started.threadReference,
    eventId: `agent-bridge-live-${Date.now()}`,
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text:
        "Agent Bridge contract smoke: reply briefly and do not read files or call tools.",
      skill_context: {
        skill_id: "generic-demo",
        skill_version: "1.0.0",
        runtime_id: "generic-demo",
        domain_context: {
          mode: "protocol-test",
        },
        domain_refs: [],
      },
    },
    outputSchema: schema,
  });
  process.stdout.write(
    `${JSON.stringify({
      ok: true,
      protocol_version: driver.capabilities.bridgeProtocolVersion,
      implementation: driver.capabilities.implementationName,
      session_ref: started.threadReference,
      elapsed_ms: Date.now() - begin,
      schema_version: result.panel.schema_version,
      repair_attempted: result.repairAttempted,
      turn_summary: result.panel.turn_summary,
    })}\n`,
  );
} finally {
  await driver.close().catch(() => {});
}
