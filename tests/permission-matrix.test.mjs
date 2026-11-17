import assert from "node:assert/strict";
import { buildPermissionMatrix } from "../lib/permission-matrix.mjs";
import {
  consumeCapabilityGrant,
  createCapabilityGrant,
  createPermissionRequest,
  revokeCapabilityGrant,
} from "../skills/pc-hardware-workbench/capability-grants.mjs";

const now = Date.parse("2026-11-16T12:00:00.000Z");
const manifest = {
  domain: {
    capabilities: [
      {
        id: "telemetry.csv.analyze",
        permissions: ["local_file_read", "artifact_write"],
      },
    ],
  },
};
const agentPermission = {
  sandbox: "read-only",
  approvalPolicy: "never",
};
const surface = {
  mode: "read-only",
  runtime_state: "running-current-workspace",
};
const capabilityProfile = {
  network: "disabled",
  general_command: "unavailable",
  system_write: "manual-only",
};

function statesFor(task, agent = agentPermission) {
  return Object.fromEntries(
    buildPermissionMatrix({
      agentPermission: agent,
      surface,
      task,
      manifest,
      now,
    }).states.map((state) => [state.id, state]),
  );
}

const initial = statesFor({
  task_id: "task-test",
  grants: [],
  permission_request: null,
  capability_profile: capabilityProfile,
});
assert.equal(initial.runtime_launch.status, "active-current-workspace");
assert.equal(initial.local_file_read.status, "approval-required");
assert.equal(initial.task_artifact_write.status, "approval-required");
assert.equal(initial.workspace_write.status, "blocked");
assert.equal(initial.external_network.status, "disabled");
assert.equal(initial.external_network.agent_network, "not-inferred");
assert.equal(initial.hardware_control.status, "manual-only");

const pending = statesFor({
  task_id: "task-test",
  grants: [],
  permission_request: {
    status: "pending",
    capability: "telemetry.csv.analyze",
    expires_at: "2026-11-16T12:05:00.000Z",
  },
  capability_profile: capabilityProfile,
});
assert.equal(pending.local_file_read.status, "pending");
assert.equal(pending.task_artifact_write.status, "pending");

const granted = statesFor({
  task_id: "task-test",
  grants: [
    {
      status: "active",
      capability: "telemetry.csv.analyze",
      expires_at: "2026-11-16T12:10:00.000Z",
    },
  ],
  permission_request: null,
  capability_profile: capabilityProfile,
});
assert.equal(granted.local_file_read.status, "granted");
assert.equal(granted.task_artifact_write.status, "granted");

const denied = statesFor({
  task_id: "task-test",
  grants: [],
  permission_request: {
    status: "denied",
    capability: "telemetry.csv.analyze",
    expires_at: "2026-11-16T12:05:00.000Z",
  },
  capability_profile: capabilityProfile,
});
assert.equal(denied.local_file_read.status, "denied");
assert.equal(denied.task_artifact_write.status, "denied");

const workspaceWrite = statesFor(
  {
    task_id: "task-test",
    grants: [],
    permission_request: null,
    capability_profile: capabilityProfile,
  },
  {
    sandbox: "workspace-write",
    approvalPolicy: "never",
  },
);
assert.equal(workspaceWrite.workspace_write.status, "host-managed");
assert.equal(workspaceWrite.external_network.status, "disabled");

const developerSurfaceReadOnlyAgent = Object.fromEntries(
  buildPermissionMatrix({
    agentPermission,
    surface: {
      mode: "developer",
      runtime_state: "running-current-workspace",
    },
    task: {
      task_id: "task-test",
      grants: [],
      permission_request: null,
      capability_profile: capabilityProfile,
    },
    manifest,
    now,
  }).states.map((state) => [state.id, state]),
);
assert.equal(
  developerSurfaceReadOnlyAgent.workspace_write.status,
  "blocked",
);
assert.equal(
  developerSurfaceReadOnlyAgent.external_network.status,
  "disabled",
);

const undeclared = Object.fromEntries(
  buildPermissionMatrix({
    agentPermission,
    surface,
    task: {
      task_id: "task-test",
      grants: [],
      permission_request: null,
      capability_profile: capabilityProfile,
    },
    manifest: { domain: { capabilities: [] } },
    now,
  }).states.map((state) => [state.id, state]),
);
assert.equal(undeclared.local_file_read.status, "unavailable");
assert.equal(undeclared.task_artifact_write.status, "unavailable");

const serialized = JSON.stringify(
  buildPermissionMatrix({
    agentPermission,
    surface,
    task: {
      task_id: "task-test",
      grants: [],
      permission_request: {
        status: "denied",
        capability: "telemetry.csv.analyze",
        expires_at: "2026-11-16T12:05:00.000Z",
      },
      capability_profile: capabilityProfile,
    },
    manifest,
    now,
  }),
);
assert.doesNotMatch(serialized, /capability-token|cookie|api[_ -]?key|C:\\\\/iu);

const permissionRequest = createPermissionRequest({
  capability: "telemetry.csv.analyze",
  presentation: {
    title: "允许当前操作？",
  },
  taskId: "task-test",
  attachment: {
    id: "attachment-test",
    original_name: "sample.csv",
    size: 12,
    sha256: "a".repeat(64),
  },
  window: {
    warmup_seconds: null,
    duration_seconds: null,
  },
  continuation: {
    action_id: "telemetry.csv.analyze",
    attachment_id: "attachment-test",
  },
  now,
});
assert.deepEqual(permissionRequest.continuation, {
  action_id: "telemetry.csv.analyze",
  attachment_id: "attachment-test",
});

const oneTimeGrant = createCapabilityGrant({
  request: permissionRequest,
  scope: "one-time",
  now,
});
assert.equal(oneTimeGrant.scope, "one-time");
consumeCapabilityGrant(oneTimeGrant, now + 1);
assert.equal(oneTimeGrant.status, "consumed");

const taskRequest = createPermissionRequest({
  capability: "telemetry.csv.analyze",
  presentation: {
    title: "允许当前操作？",
  },
  taskId: "task-test",
  attachment: {
    id: "attachment-test",
    original_name: "sample.csv",
    size: 12,
    sha256: "a".repeat(64),
  },
  window: {
    warmup_seconds: null,
    duration_seconds: null,
  },
  now,
});
const taskGrant = createCapabilityGrant({
  request: taskRequest,
  scope: "task",
  now,
});
assert.equal(taskGrant.scope, "task");
consumeCapabilityGrant(taskGrant, now + 1);
assert.equal(taskGrant.status, "active");
assert.equal(taskGrant.consumed_at, null);
assert.equal(
  taskGrant.last_used_at,
  new Date(now + 1).toISOString(),
);
assert.equal(revokeCapabilityGrant(taskGrant, now + 1), true);
assert.equal(taskGrant.status, "revoked");

console.log("Permission matrix contract: PASS");
