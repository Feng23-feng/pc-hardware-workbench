import { validatePanelState } from "./schema-validation.mjs";
import { AgentDriverError } from "./agents/agent-driver.mjs";

export const PANEL_DEVELOPER_INSTRUCTIONS = [
  "You are the structured backend for a local Agent Workbench.",
  "Use the supplied event or submission, prior Session context, and the skill_context packet.",
  "Do not run shell commands from the Agent adapter.",
  "Return one compact JSON object matching the turn output schema.",
  "Ask exactly one discriminating question with 2 to 4 options, or set question to null when no input is needed.",
  "Never combine several questions.",
  "Keep option labels short, concrete, and user-observable.",
  "Follow the domain instructions supplied inside skill_context.",
  "Every result must include a substantive result card: judgement, evidence, uncertainty, two or three recommendations, a priorityAction, and safe copy-only actions.",
  "Recommendations must be concrete steps supplied by the active Skill, not disclaimers.",
  "Never use actions to inject HTML or arbitrary UI behavior.",
  "Separate user-reported evidence from inference and state uncertainty.",
].join(" ");

export function parseStructuredOutput(text) {
  const trimmed = String(text ?? "").trim();
  const unfenced = trimmed
    .replace(/^```(?:json)?\s*/iu, "")
    .replace(/\s*```$/u, "");
  try {
    return JSON.parse(unfenced);
  } catch {
    const first = unfenced.indexOf("{");
    const last = unfenced.lastIndexOf("}");
    if (first >= 0 && last > first) {
      return JSON.parse(unfenced.slice(first, last + 1));
    }
    throw new AgentDriverError(
      "protocol",
      "invalid_structured_output",
      "Agent final message was not valid JSON",
    );
  }
}

export async function runPanelTurn({
  driver,
  threadReference,
  eventId,
  packet,
  outputSchema,
  onEvent = null,
  domainValidator = null,
}) {
  const capturedEvents = [];
  const result = await driver.sendTurn({
    threadReference,
    eventId,
    packet,
    structuredOutputSchema: outputSchema,
    onEvent: (event) => {
      capturedEvents.push(event);
      if (typeof onEvent === "function") {
        onEvent(event);
      }
    },
  });
  let panel;
  try {
    const candidate =
      result.structuredOutput ?? parseStructuredOutput(result.finalText);
    panel = validatePanelState(candidate);
    if (typeof domainValidator === "function") {
      panel = await domainValidator(panel, { packet, taskContext: packet.task_context });
      panel = validatePanelState(panel);
    }
  } catch (error) {
    if (result.diagnosticPath && error && typeof error === "object") {
      error.diagnosticPath = result.diagnosticPath;
    }
    throw error;
  }
  return {
    turnId: result.turnId,
    panel,
    driverEvents: result.events ?? capturedEvents,
  };
}
