import assert from "node:assert/strict";
import { resolve } from "node:path";
import {
  AgentPermissionConfigError,
  DEFAULT_AGENT_PERMISSION_PROFILE,
  normalizeAgentPermissionProfile,
  normalizeSurfaceMode,
} from "../lib/agent-permissions.mjs";
import {
  CodexAgentDriver,
  DSHAgentDriver,
  DSHWebAgentDriver,
  MockAgentDriver,
  SourceExternalAgentDriver,
  driverPublicDescriptor,
} from "../lib/agents/index.mjs";

const root = resolve(import.meta.dirname, "..");

assert.deepEqual(
  normalizeAgentPermissionProfile(),
  DEFAULT_AGENT_PERMISSION_PROFILE,
);
assert.equal(normalizeSurfaceMode(), "read-only");
assert.equal(normalizeSurfaceMode("interactive"), "interactive");
assert.throws(
  () => normalizeSurfaceMode("full-access"),
  (error) =>
    error instanceof AgentPermissionConfigError &&
    error.code === "permission_mode_invalid",
);

const codex = new CodexAgentDriver({
  cwd: root,
  permissionProfile: {
    sandbox: "workspace-write",
    approvalPolicy: "never",
    source: "test",
  },
});
assert.deepEqual(codex.permissionProfile, {
  sandbox: "workspace-write",
  approvalPolicy: "never",
  source: "test",
});
assert.equal(codex.capabilities.supportsApprovalDecision, false);
assert.deepEqual(codex.capabilities.approvalModes, ["never"]);
assert.equal(
  driverPublicDescriptor(codex).permission_profile.sandbox,
  "workspace-write",
);

assert.throws(
  () =>
    new CodexAgentDriver({
      cwd: root,
      permissionProfile: {
        sandbox: "read-only",
        approvalPolicy: "on-request",
      },
    }),
  (error) =>
    error instanceof AgentPermissionConfigError &&
    error.code === "permission_approval_unsupported",
);

assert.throws(
  () =>
    new DSHAgentDriver({
      cwd: root,
      fixture: true,
      permissionProfile: {
        sandbox: "workspace-write",
        approvalPolicy: "never",
      },
    }),
  (error) =>
    error instanceof AgentPermissionConfigError &&
    error.code === "permission_sandbox_unsupported",
);

assert.throws(
  () =>
    new DSHAgentDriver({
      cwd: root,
      fixture: true,
      permissionProfile: {
        sandbox: "read-only",
        approvalPolicy: "on-request",
      },
    }),
  (error) =>
    error instanceof AgentPermissionConfigError &&
    error.code === "permission_approval_unsupported",
);

assert.throws(
  () =>
    new DSHWebAgentDriver({
      cwd: root,
      fixture: true,
      permissionProfile: {
        sandbox: "read-only",
        approvalPolicy: "on-request",
      },
    }),
  (error) =>
    error instanceof AgentPermissionConfigError &&
    error.code === "permission_approval_unsupported",
);

const mock = new MockAgentDriver();
assert.equal(mock.permissionProfile.sandbox, "read-only");
assert.equal(mock.permissionProfile.approvalPolicy, "never");
assert.equal(mock.capabilities.supportsApprovals, false);

const sourceExternal = new SourceExternalAgentDriver({
  permissionProfile: {
    sandbox: "read-only",
    approvalPolicy: "never",
    source: "test",
  },
});
await sourceExternal.initialize();
assert.equal(sourceExternal.permissionProfile.sandbox, "read-only");
assert.equal(sourceExternal.permissionProfile.approvalPolicy, "never");
assert.equal(sourceExternal.capabilities.supportsActiveThreadAttach, false);
assert.equal(sourceExternal.capabilities.supportsThreadResume, false);
assert.equal(sourceExternal.capabilities.sourceHostedExternal, true);
await assert.rejects(
  () => sourceExternal.startThread(),
  (error) => error.code === "external_source_thread_required",
);
await assert.rejects(
  () => sourceExternal.sendTurn(),
  (error) => error.code === "panel_turn_forbidden_in_source_hosted",
);
await sourceExternal.close();

console.log("Agent permission profile contract: PASS");
