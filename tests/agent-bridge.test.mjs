import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import {
  AGENT_BRIDGE_FIXTURE_TOKEN,
  startAgentBridgeFixture,
} from "../fixtures/agent-bridge-fixture.mjs";
import {
  AgentBridgeDriver,
  AgentDriverError,
  MockAgentDriver,
  createAgentDriver,
  resolveAgentDriverName,
} from "../lib/agents/index.mjs";
import { runPanelTurn } from "../lib/panel-response.mjs";
import { startAgentBridgeHost } from "../agent-bridge-host.mjs";

const root = import.meta.dirname.replace(/[\\/]tests$/u, "");
const schema = JSON.parse(
  await readFile(join(root, "schemas", "panel-ui-state.schema.json"), "utf8"),
);
const fixture = await startAgentBridgeFixture();
let driver;
let resumedDriver;
let host;
let hostClient;

try {
  assert.equal(
    resolveAgentDriverName({ PANEL_AGENT_DRIVER: "agent-bridge" }),
    "agent-bridge",
  );
  const factoryDriver = createAgentDriver("agent-bridge", {
    baseUrl: fixture.baseUrl,
    token: fixture.token,
  });
  assert.ok(factoryDriver instanceof AgentBridgeDriver);
  await factoryDriver.close();

  driver = new AgentBridgeDriver({
    baseUrl: fixture.baseUrl,
    token: fixture.token,
  });
  await driver.initialize();
  assert.equal(driver.capabilities.adapterStatus, "draft");
  assert.equal(driver.capabilities.bridgeProtocolVersion, "0.1-draft");
  assert.equal(driver.capabilities.supportsThreadResume, true);
  assert.equal(driver.capabilities.supportsStructuredOutput, true);
  assert.equal(driver.capabilities.supportsCancellation, true);
  assert.equal(driver.capabilities.supportsStreaming, false);

  const started = await driver.startThread();
  assert.match(started.threadReference, /^session-/u);
  assert.equal(started.resumed, false);
  await driver.setThreadName("Agent Bridge fixture Session");
  assert.equal(driver.activeThreadName, "Agent Bridge fixture Session");

  const first = await runPanelTurn({
    driver,
    threadReference: started.threadReference,
    eventId: "bridge-first-event",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "Agent Bridge first turn",
    },
    outputSchema: schema,
  });
  assert.equal(first.panel.schema_version, "1.2");
  assert.equal(first.repairAttempted, false);

  await driver.close();
  resumedDriver = new AgentBridgeDriver({
    baseUrl: fixture.baseUrl,
    token: fixture.token,
  });
  await resumedDriver.initialize();
  const resumed = await resumedDriver.resumeThread(started.threadReference);
  assert.equal(resumed.resumed, true);
  assert.equal(resumed.threadReference, started.threadReference);
  const second = await runPanelTurn({
    driver: resumedDriver,
    threadReference: resumed.threadReference,
    eventId: "bridge-second-event",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "Agent Bridge resumed turn",
    },
    outputSchema: schema,
  });
  assert.equal(second.panel.schema_version, "1.2");

  await assert.rejects(
    runPanelTurn({
      driver: resumedDriver,
      threadReference: resumed.threadReference,
      eventId: "bridge-auth-error",
      packet: {
        schema_version: "1.0",
        type: "user_message",
        text: "[BRIDGE_ERROR_AUTH]",
      },
      outputSchema: schema,
    }),
    (error) =>
      error instanceof AgentDriverError &&
      error.classification === "auth" &&
      error.code === "fixture_model_auth_required",
  );

  let slowTurnId = null;
  const slowTurn = runPanelTurn({
    driver: resumedDriver,
    threadReference: resumed.threadReference,
    eventId: "bridge-slow-event",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "[BRIDGE_SLOW]",
    },
    outputSchema: schema,
    onEvent: (event) => {
      if (event.type === "turn_started") {
        slowTurnId = event.turnId;
      }
    },
  });
  for (let index = 0; index < 40 && !slowTurnId; index += 1) {
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 25));
  }
  assert.ok(slowTurnId, "Agent Bridge did not expose the active turn ID");
  await resumedDriver.cancel(slowTurnId);
  await assert.rejects(
    slowTurn,
    (error) =>
      error instanceof AgentDriverError &&
      error.classification === "blocked" &&
      error.code === "agent_bridge_turn_cancelled",
  );

  assert.throws(
    () =>
      new AgentBridgeDriver({
        baseUrl: "http://example.com:4444",
        token: AGENT_BRIDGE_FIXTURE_TOKEN,
      }),
    (error) =>
      error instanceof AgentDriverError &&
      error.code === "agent_bridge_url_not_loopback",
  );
  assert.throws(
    () =>
      new AgentBridgeDriver({
        baseUrl: fixture.baseUrl,
        token: "",
      }),
    (error) =>
      error instanceof AgentDriverError &&
      error.code === "agent_bridge_token_missing",
  );
  assert.ok(fixture.requestCount >= 10);

  host = await startAgentBridgeHost({
    driver: new MockAgentDriver(),
    token: "reference-host-token-0123456789",
  });
  hostClient = new AgentBridgeDriver({
    baseUrl: host.baseUrl,
    token: host.token,
  });
  await hostClient.initialize();
  assert.equal(hostClient.capabilities.implementationName, "Mock");
  const hostSession = await hostClient.startThread();
  const hostTurn = await runPanelTurn({
    driver: hostClient,
    threadReference: hostSession.threadReference,
    eventId: "bridge-reference-host-turn",
    packet: {
      schema_version: "1.0",
      type: "user_message",
      text: "Reference Agent Bridge host turn",
      skill_context: {
        runtime_id: "generic-demo",
      },
    },
    outputSchema: schema,
  });
  assert.equal(hostTurn.panel.schema_version, "1.2");
  console.log("Agent Bridge 0.1 draft contract: PASS");
} finally {
  await hostClient?.close().catch(() => {});
  await host?.close().catch(() => {});
  await resumedDriver?.close().catch(() => {});
  await driver?.close().catch(() => {});
  await fixture.close();
}
