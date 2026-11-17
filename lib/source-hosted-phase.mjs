export const SOURCE_HOSTED_SUBMITTABLE_PHASES = Object.freeze([
  "source_owned",
  "waiting_for_source_pull",
  "source_result_synced",
]);

export const SOURCE_HOSTED_STUCK_PHASES = Object.freeze([
  "source_agent_pulled",
]);

export function isSourceHostedSubmittablePhase(phase) {
  return SOURCE_HOSTED_SUBMITTABLE_PHASES.includes(String(phase ?? ""));
}

export function isSourceHostedStuckPhase(phase) {
  return SOURCE_HOSTED_STUCK_PHASES.includes(String(phase ?? ""));
}

export function evaluateSourceHostedPhaseContract({
  mode,
  phase,
}) {
  if (String(mode ?? "") !== "source_hosted") {
    return {
      source_hosted: false,
      submittable: true,
      recovery_available: false,
      phase: String(phase ?? ""),
      code: "not_source_hosted",
    };
  }
  const normalizedPhase = String(phase ?? "");
  return {
    source_hosted: true,
    submittable: isSourceHostedSubmittablePhase(normalizedPhase),
    recovery_available: isSourceHostedStuckPhase(normalizedPhase),
    phase: normalizedPhase,
    code: isSourceHostedSubmittablePhase(normalizedPhase)
      ? "phase_submittable"
      : isSourceHostedStuckPhase(normalizedPhase)
        ? "phase_not_submittable"
        : "phase_unsupported",
  };
}
