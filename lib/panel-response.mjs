import { randomUUID } from "node:crypto";
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
  const sendAndValidate = async ({
    turnEventId,
    turnPacket,
    validationPacket = packet,
  }) => {
    const result = await driver.sendTurn({
      threadReference,
      eventId: turnEventId,
      packet: turnPacket,
      structuredOutputSchema: outputSchema,
      onEvent: (event) => {
        capturedEvents.push(event);
        if (typeof onEvent === "function") {
          onEvent(event);
        }
      },
    });
    let candidate;
    let panel;
    try {
      candidate =
        result.structuredOutput ?? parseStructuredOutput(result.finalText);
      panel = validatePanelState(candidate);
    } catch (error) {
      return { ok: false, error, result, candidate };
    }
    try {
      if (typeof domainValidator === "function") {
        panel = await domainValidator(panel, {
          packet: validationPacket,
          taskContext: validationPacket.task_context,
        });
        panel = validatePanelState(panel);
      }
    } catch (error) {
      if (result.diagnosticPath && error && typeof error === "object") {
        error.diagnosticPath = result.diagnosticPath;
      }
      throw error;
    }
    return { ok: true, result, panel };
  };

  let attempt = await sendAndValidate({
    turnEventId: eventId,
    turnPacket: packet,
  });
  let repairAttempted = false;
  if (
    !attempt.ok &&
    driver.capabilities?.supportsStructuredOutput === false
  ) {
    repairAttempted = true;
    const repairEventId = randomUUID();
    const repairPacket = {
      ...packet,
      type: "schema_repair",
      event_id: repairEventId,
      created_at: new Date().toISOString(),
      repair: {
        original_event_id: eventId,
        validation_error: String(attempt.error?.message ?? attempt.error).slice(
          0,
          500,
        ),
        previous_output: String(attempt.result?.finalText ?? "").slice(0, 12_000),
        instruction:
          "Return the corrected complete JSON object only. Preserve the original intent and do not add commentary.",
      },
    };
    attempt = await sendAndValidate({
      turnEventId: repairEventId,
      turnPacket: repairPacket,
    });
  }

  if (!attempt.ok) {
    if (
      attempt.result?.diagnosticPath &&
      attempt.error &&
      typeof attempt.error === "object"
    ) {
      attempt.error.diagnosticPath = attempt.result.diagnosticPath;
    }
    throw attempt.error;
  }

  return {
    turnId: attempt.result.turnId,
    panel: attempt.panel,
    driverEvents: attempt.result.events ?? capturedEvents,
    repairAttempted,
  };
}
