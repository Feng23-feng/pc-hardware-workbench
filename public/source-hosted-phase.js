export const SOURCE_HOSTED_SUBMITTABLE_PHASES = Object.freeze([
  "source_owned",
  "waiting_for_source_pull",
  "source_result_synced",
]);

const PHASE_COPY = {
  source_owned: "当前 Task 可以由面板开始新的分析周期。",
  waiting_for_source_pull: "当前提交正在等待来源 Agent 拉取本地分析结果。",
  source_result_synced: "上一轮结果已同步，可以开始新的分析周期。",
  source_agent_pulled: "当前对话 Agent 已领取一个尚未完成的周期；恢复当前 Task 后才能继续提交。",
};

export function evaluateSourceHostedPhase({ mode, phase }) {
  if (String(mode ?? "") !== "source_hosted") {
    return {
      source_hosted: false,
      submittable: true,
      recovery_available: false,
      can_upload: true,
      can_submit: true,
      can_analyze: true,
      can_decide_permission: true,
      phase: String(phase ?? ""),
      label: "",
      reason: "",
      recovery_label: "",
    };
  }
  const normalizedPhase = String(phase ?? "");
  const submittable = SOURCE_HOSTED_SUBMITTABLE_PHASES.includes(
    normalizedPhase,
  );
  const recoveryAvailable = normalizedPhase === "source_agent_pulled";
  return {
    source_hosted: true,
    submittable,
    recovery_available: recoveryAvailable,
    can_upload: submittable,
    can_submit: submittable,
    can_analyze: submittable,
    can_decide_permission: submittable,
    phase: normalizedPhase,
    label: submittable
      ? "当前 phase 可提交"
      : recoveryAvailable
        ? "当前 cycle 已卡住"
        : "当前 phase 不可提交",
    reason:
      PHASE_COPY[normalizedPhase] ??
      "当前 Task 的 phase 不允许新的面板操作，请回到当前 Agent 对话处理。",
    recovery_label: recoveryAvailable ? "恢复当前 Task" : "",
  };
}
