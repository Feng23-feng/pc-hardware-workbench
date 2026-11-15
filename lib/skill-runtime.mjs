import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const SKILL_RUNTIME_API_VERSION = "1.0";

export class SkillRuntimeError extends Error {
  constructor(code, message, { cause = null } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = "SkillRuntimeError";
    this.code = code;
  }
}

function assertFunction(value, name) {
  if (typeof value !== "function") {
    throw new SkillRuntimeError(
      "runtime_interface_invalid",
      `Skill runtime is missing ${name}()`,
    );
  }
}

function defaultCapabilityState(manifest) {
  const required = new Set(
    manifest.permissions.required.map((item) => item.capability),
  );
  return Object.fromEntries(
    manifest.domain.capabilities.map((capability) => [
      capability.id,
      required.has(capability.id) ? "approval-required" : "available",
    ]),
  );
}

export class SkillRuntime {
  constructor({ manifest, projectRoot }) {
    this.manifest = manifest;
    this.projectRoot = resolve(projectRoot);
    this.identity = Object.freeze({
      api_version: SKILL_RUNTIME_API_VERSION,
      skill_id: manifest.skill.id,
      skill_version: manifest.skill.version,
      manifest_hash: manifest.resolved?.manifest_hash ?? null,
      runtime_id: manifest.runtime.id,
    });
    this.active = false;
  }

  async initialize() {
    this.active = true;
  }

  async close() {}

  hasCapability(capabilityId) {
    return this.manifest.domain.capabilities.some(
      (capability) => capability.id === capabilityId,
    );
  }

  requireCapability(capabilityId) {
    if (!this.hasCapability(capabilityId)) {
      throw new SkillRuntimeError(
        "capability_undeclared",
        `Capability "${capabilityId}" is not declared by ${this.manifest.skill.id}.`,
      );
    }
    return this.manifest.domain.capabilities.find(
      (capability) => capability.id === capabilityId,
    );
  }

  getCapability(capabilityId) {
    return this.requireCapability(capabilityId);
  }

  createTaskState({ taskId }) {
    return {
      domain_state: {},
      domain_refs: [],
      capability_profile: {
        schema_version: "1.0",
        profile: this.manifest.permissions.default_profile.profile,
        task_id: taskId,
        network: this.manifest.permissions.default_profile.network,
        general_command:
          this.manifest.permissions.default_profile.general_command,
        system_write:
          this.manifest.permissions.default_profile.system_write,
        capabilities: defaultCapabilityState(this.manifest),
      },
      grants: [],
      permission_request: null,
    };
  }

  normalizeTaskState({ task, taskId }) {
    const defaults = this.createTaskState({ taskId });
    task.domain_state = task.domain_state ?? defaults.domain_state;
    task.domain_refs = task.domain_refs ?? defaults.domain_refs;
    task.capability_profile =
      task.capability_profile ?? defaults.capability_profile;
    task.grants = task.grants ?? [];
    task.permission_request = task.permission_request ?? null;
    task.actions = task.actions ?? [];
    return task;
  }

  publicContext() {
    return null;
  }

  buildTaskContext({ task }) {
    return {
      skill_id: this.manifest.skill.id,
      skill_version: this.manifest.skill.version,
      runtime_id: this.manifest.runtime.id,
      domain_context: task?.domain_state ?? {},
      domain_refs: task?.domain_refs ?? [],
    };
  }

  commitAttachments({ task, attachments }) {
    task.domain_refs ??= [];
    for (const attachment of attachments) {
      if (!task.domain_refs.includes(attachment.id)) {
        task.domain_refs.push(attachment.id);
      }
    }
    return task.domain_refs;
  }

  recordEvidence({ task, evidence }) {
    task.domain_refs ??= [];
    if (!task.domain_refs.includes(evidence.id)) {
      task.domain_refs.push(evidence.id);
    }
    return evidence;
  }

  applyHandoff({ task }) {
    return task;
  }

  enrichPacket(packet, { task }) {
    return {
      ...packet,
      skill_context: {
        ...this.buildTaskContext({ task }),
        instructions: this.promptInstructions(),
      },
    };
  }

  promptInstructions() {
    return [];
  }

  taskName(panel, fallback = "新任务") {
    return String(panel?.current_goal || fallback).slice(0, 80);
  }

  validatePanelResult(panel) {
    const allowedBlocks = new Set(this.manifest.components.block_types);
    for (const block of panel.blocks ?? []) {
      if (!allowedBlocks.has(block.type)) {
        throw new SkillRuntimeError(
          "panel_block_not_allowed",
          `Panel block "${block.type}" is not declared by the active Skill.`,
        );
      }
    }
    const allowedArtifactKinds = new Set(
      this.manifest.artifacts.allowed_kinds,
    );
    for (const artifact of panel.artifact_refs ?? []) {
      if (!allowedArtifactKinds.has(artifact.kind)) {
        throw new SkillRuntimeError(
          "artifact_kind_not_allowed",
          `Artifact kind "${artifact.kind}" is not declared by the active Skill.`,
        );
      }
    }
    return panel;
  }

  publicPermissions(task) {
    return task?.capability_profile ?? this.createTaskState({
      taskId: task?.task_id ?? "task-preview",
    }).capability_profile;
  }

  async expirePermissions() {
    return false;
  }

  async decidePermission() {
    throw new SkillRuntimeError(
      "permission_action_unsupported",
      "The active Skill runtime does not expose local permission decisions.",
    );
  }

  async revokePermission() {
    throw new SkillRuntimeError(
      "permission_action_unsupported",
      "The active Skill runtime does not expose revocable local actions.",
    );
  }

  getLocalAction() {
    return null;
  }

  async runLocalAction() {
    throw new SkillRuntimeError(
      "local_action_unsupported",
      "The active Skill runtime does not implement local actions.",
    );
  }

  getArtifact() {
    return null;
  }

  buildHandoffContext({ task }) {
    return {
      title: "Skill context",
      lines: [
        `- Skill：${this.manifest.skill.name} · ${this.manifest.skill.version}`,
        `- Domain refs：${(task?.domain_refs ?? []).join("、") || "无"}`,
      ],
      data: {
        skill_id: this.manifest.skill.id,
        skill_version: this.manifest.skill.version,
        domain_refs: task?.domain_refs ?? [],
      },
    };
  }
}

export class CompatChatRuntime extends SkillRuntime {
  constructor(options) {
    super(options);
    this.identity = Object.freeze({
      ...this.identity,
      runtime_id: "compat-chat",
    });
  }

  hasCapability() {
    return false;
  }

  getCapability(capabilityId) {
    throw new SkillRuntimeError(
      "capability_undeclared",
      `Compatibility chat does not provide "${capabilityId}".`,
    );
  }

  buildTaskContext({ task }) {
    return {
      skill_id: this.manifest.skill.id,
      skill_version: this.manifest.skill.version,
      domain_context: {},
      domain_refs: [],
      fallback: "chat",
      task_id: task?.task_id ?? null,
    };
  }
}

export async function loadSkillRuntime({
  manifest,
  projectRoot,
  runtimeDir,
  runtimeOptions = {},
}) {
  if (
    manifest.status !== "active" ||
    !manifest.resolved?.runtime_entry
  ) {
    const runtime = new CompatChatRuntime({ manifest, projectRoot });
    await runtime.initialize();
    return runtime;
  }
  const entry = manifest.resolved.runtime_entry;
  if (!existsSync(entry)) {
    throw new SkillRuntimeError(
      "runtime_missing",
      "Skill runtime entry does not exist.",
    );
  }
  let module;
  try {
    module = await import(
      `${pathToFileURL(entry).href}?manifest=${encodeURIComponent(
        manifest.resolved.manifest_hash,
      )}`
    );
  } catch (error) {
    throw new SkillRuntimeError(
      "runtime_import_failed",
      "Skill runtime module could not be imported.",
      { cause: error },
    );
  }
  if (typeof module.createRuntime !== "function") {
    throw new SkillRuntimeError(
      "runtime_interface_invalid",
      "Skill runtime must export createRuntime(context).",
    );
  }
  const runtime = await module.createRuntime({
    manifest,
    projectRoot,
    runtimeDir,
    manifestPath: manifest.resolved.manifest_path,
    skillRoot: manifest.resolved.skill_root,
    SkillRuntime,
    SkillRuntimeError,
    ...runtimeOptions,
  });
  if (!runtime || runtime instanceof SkillRuntime === false) {
    throw new SkillRuntimeError(
      "runtime_interface_invalid",
      "Skill runtime factory must return a SkillRuntime instance.",
    );
  }
  if (runtime.manifest.runtime.id !== manifest.runtime.id) {
    throw new SkillRuntimeError(
      "runtime_identity_mismatch",
      "Skill runtime id does not match its manifest.",
    );
  }
  for (const method of [
    "initialize",
    "close",
    "createTaskState",
    "normalizeTaskState",
    "buildTaskContext",
    "commitAttachments",
    "recordEvidence",
    "applyHandoff",
    "enrichPacket",
    "promptInstructions",
    "validatePanelResult",
    "getLocalAction",
    "getArtifact",
    "publicPermissions",
    "expirePermissions",
    "decidePermission",
    "revokePermission",
    "runLocalAction",
    "buildHandoffContext",
  ]) {
    assertFunction(runtime[method], method);
  }
  const schema = manifest.stateSchema;
  if (!schema || schema.type !== "object") {
    throw new SkillRuntimeError(
      "runtime_schema_invalid",
      "Skill UI schema is not importable as an object schema.",
    );
  }
  await runtime.initialize();
  return runtime;
}
