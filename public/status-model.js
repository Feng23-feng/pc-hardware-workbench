export function deriveActivityMode({
  phase,
  panel,
  activity,
  submitPending = false,
  optimisticPhase = null,
  optimisticStartedAt = null,
  transientReplyAt = 0,
  now = Date.now(),
}) {
  if (phase === "error") {
    return "error";
  }
  if (phase === "interrupted") {
    return "interrupted";
  }
  if (submitPending || phase === "running") {
    if (
      optimisticPhase === "sent" &&
      Number.isFinite(optimisticStartedAt) &&
      now - optimisticStartedAt < 700
    ) {
      return "sent";
    }
    return "processing";
  }
  if (!panel) {
    return "waiting";
  }
  if (panel.status === "ready") {
    return "completed";
  }
  if (panel.status === "blocked") {
    return "blocked";
  }
  const completedAt = Date.parse(activity?.completed_at ?? "");
  if (
    (transientReplyAt && now - transientReplyAt < 3_500) ||
    (Number.isFinite(completedAt) && now - completedAt < 3_500)
  ) {
    return "replied";
  }
  return "waiting";
}
