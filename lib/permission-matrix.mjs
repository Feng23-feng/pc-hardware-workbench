export const PERMISSION_MATRIX_SCHEMA_VERSION = "1.0";

const LOCAL_PERMISSION_IDS = Object.freeze([
  "local_file_read",
  "task_artifact_write",
]);

function normalizedManifestPermission(permission) {
  return permission === "artifact_write"
    ? "task_artifact_write"
    : permission;
}

function capabilitiesForPermission(manifest, permission) {
  return (manifest?.domain?.capabilities ?? [])
    .filter((capability) =>
      (capability.permissions ?? []).some(
        (item) => normalizedManifestPermission(item) === permission,
      ),
    )
    .map((capability) => capability.id)
    .filter(Boolean);
}

function activeGrant(task, capabilityIds, now) {
  return (task?.grants ?? []).find(
    (grant) =>
      grant.status === "active" &&
      capabilityIds.includes(grant.capability) &&
      Date.parse(grant.expires_at) > now,
  );
}

function pendingRequest(task, capabilityIds, now) {
  const request = task?.permission_request;
  return request?.status === "pending" &&
    capabilityIds.includes(request.capability) &&
    Date.parse(request.expires_at) > now
    ? request
    : null;
}

function recentRequestStatus(task, capabilityIds) {
  const request = task?.permission_request;
  if (
    !request ||
    !capabilityIds.includes(request.capability) ||
    !["denied", "expired"].includes(request.status)
  ) {
    return null;
  }
  return request.status;
}

function localPermissionState({
  id,
  label,
  manifest,
  task,
  detail,
  now,
}) {
  const capabilityIds = capabilitiesForPermission(manifest, id);
  const grant = activeGrant(task, capabilityIds, now);
  const request = pendingRequest(task, capabilityIds, now);
  const recentStatus = recentRequestStatus(task, capabilityIds);
  let status = "unavailable";
  if (grant) {
    status = "granted";
  } else if (request) {
    status = "pending";
  } else if (recentStatus) {
    status = recentStatus;
  } else if (capabilityIds.length) {
    status = "approval-required";
  }
  return {
    id,
    label,
    owner: "skill-runtime",
    status,
    scope: "current-task",
    detail,
    capabilities: capabilityIds,
    requestable: capabilityIds.length > 0,
  };
}

function workspaceWriteState(agentPermission) {
  const sandbox = agentPermission?.sandbox ?? "unknown";
  if (sandbox === "read-only") {
    return {
      id: "workspace_write",
      label: "写入用户工作区",
      owner: "agent-host",
      status: "blocked",
      scope: "agent-workspace",
      detail:
        "当前 Agent 沙箱为只读。SkillDock 不提供绕过 Agent 沙箱的工作区写入授权。",
      requestable: false,
    };
  }
  if (["workspace-write", "danger-full-access"].includes(sandbox)) {
    return {
      id: "workspace_write",
      label: "写入用户工作区",
      owner: "agent-host",
      status: "host-managed",
      scope: "agent-workspace",
      detail:
        "工作区写入由 Agent 宿主控制；SkillDock 只展示该边界，不另行授权。",
      requestable: false,
    };
  }
  return {
    id: "workspace_write",
    label: "写入用户工作区",
    owner: "agent-host",
    status: "unknown",
    scope: "agent-workspace",
    detail: "当前 Driver 未声明可推断的 Agent 工作区写入边界。",
    requestable: false,
  };
}

function externalNetworkState(task) {
  const network = task?.capability_profile?.network ?? "unknown";
  const status =
    network === "disabled" ? "disabled" : network === "unknown" ? "unknown" : network;
  return {
    id: "external_network",
    label: "外部网络",
    owner: "skill-runtime",
    status,
    scope: "external-network",
    detail:
      "SkillDock Runtime 的外部网络按 Task 声明显示；loopback 不属于外部网络。Agent 的网络能力仍由宿主控制，不能从该状态推断为已关闭。",
    agent_network: "not-inferred",
    requestable: false,
  };
}

function runtimeLaunchState(surface) {
  const runtimeState = surface?.runtime_state ?? "unknown";
  const mode = surface?.mode ?? "unknown";
  let status = runtimeState;
  if (mode === "chat") {
    status = "chat-only";
  } else if (runtimeState === "running-current-workspace") {
    status = "active-current-workspace";
  }
  return {
    id: "runtime_launch",
    label: "启动 Runtime",
    owner: "skilldock",
    status,
    scope: "current-workspace-loopback",
    detail: "Runtime 只由用户显式打开；启动面板不会提升 Agent 或 Task 权限。",
    explicit_user_action: true,
    requestable: false,
  };
}

export function buildPermissionMatrix({
  agentPermission = null,
  surface = null,
  task = null,
  manifest = null,
  now = Date.now(),
} = {}) {
  const states = [
    runtimeLaunchState(surface),
    localPermissionState({
      id: "local_file_read",
      label: "读取用户选择的文件",
      manifest,
      task,
      now,
      detail:
        "只读取用户显式提交到当前 Task 的文件；不扫描目录，也不扩大授权到其他文件。",
    }),
    localPermissionState({
      id: "task_artifact_write",
      label: "写入 Task artifact",
      manifest,
      task,
      now,
      detail: "只写当前 Task 的 Runtime artifact 目录，不写用户工作区或系统位置。",
    }),
    workspaceWriteState(agentPermission),
    externalNetworkState(task),
    {
      id: "hardware_control",
      label: "硬件设置",
      owner: "skill",
      status: "manual-only",
      scope: "hardware-settings",
      detail:
        "BIOS、固件、驱动、频率、电压、功耗、风扇和内存时序始终由用户手工处理。",
      requestable: false,
    },
  ];
  return {
    schema_version: PERMISSION_MATRIX_SCHEMA_VERSION,
    states,
  };
}
