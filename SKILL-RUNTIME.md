# Skill Runtime Contract

## Purpose

`SkillRuntime` is the narrow domain boundary between the Agent-neutral Workbench
host and an installed Skill.

The host owns HTTP, Agent adapters, Sessions, Tasks, permissions, artifacts,
Resume/export, and persistent state. A Skill runtime owns domain context,
domain prompt instructions, domain result checks, and any manifest-declared
local actions.

## Identity

Every runtime receives:

```json
{
  "skill_id": "example.skill",
  "skill_version": "1.0.0",
  "manifest_hash": "sha256",
  "runtime_id": "example-runtime",
  "api_version": "1.0"
}
```

The runtime id must match `manifest.runtime.id`.

## Interface

Required methods:

- `initialize()`
- `close()`
- `createTaskState({ taskId })`
- `normalizeTaskState({ task, taskId })`
- `buildTaskContext({ task, attachments })`
- `enrichPacket(packet, { task, attachments })`
- `promptInstructions()`
- `publicContext({ task })`
- `commitAttachments({ task, attachments })`
- `recordEvidence({ task, evidence })`
- `applyHandoff({ task, packet })`
- `taskName(panel, fallback)`
- `validatePanelResult(panel, { task, packet })`
- `publicPermissions(task)`
- `expirePermissions(task, host)`
- `decidePermission({ task, body, host })`
- `revokePermission({ task, body, host })`
- `getLocalAction(actionId)`
- `runLocalAction({ actionId, input, task, attachment, host })`
- `getArtifact(artifactId)`
- `buildHandoffContext({ task, panel })`

The base implementation lives in `lib/skill-runtime.mjs`. Runtimes are loaded
only from a validated `manifest.runtime.entry` under the Skill root.

## Local Actions

A local action is optional. `getLocalAction(id)` returns:

```json
{
  "id": "example.local.export",
  "capability": "example.local.export",
  "requiresPermission": true,
  "requiresAgent": false,
  "attachmentExtensions": [".txt"]
}
```

`manifest.domain.capabilities` must declare the same capability id. An
undeclared action is rejected with `capability_undeclared`.

The runtime may use the host only for neutral lifecycle operations:

- read/set panel;
- run an Agent turn;
- append events and timeline entries;
- persist/archive Task state;
- complete/fail activity.

Provider protocol methods are never available to a runtime.

## Result Validation

The host first validates the panel UI schema. The runtime then performs
domain-level checks and post-processing. The base runtime rejects:

- block types not declared by the manifest;
- artifact kinds not declared by the manifest.

The PC Hardware Workbench runtime additionally enforces its three-domain
black-screen/frame-drop evidence guidance.

## Discovery

Explicit manifests:

```powershell
$env:PANEL_SKILL_MANIFEST = "C:\skills\a\workbench.manifest.json;C:\skills\b\workbench.manifest.json"
```

`PANEL_WORKBENCH_MANIFEST` remains a compatibility alias.

Configured roots:

```powershell
$env:PANEL_SKILL_ROOTS = "C:\skills-a;C:\skills-b"
```

Default roots:

- `<app>/skills`;
- `<user-home>/.codex/skills`;
- `<user-home>/.dsh/skills`.

Discovery:

- follows no symbolic links;
- scans at most four directory levels;
- accepts only `workbench.manifest.json`;
- deduplicates by real manifest path;
- validates schema versions and every declared path;
- ignores invalid candidates without blocking the server.

Selection order:

1. `PANEL_SKILL_ID` when set;
2. exact persisted Skill id/version/runtime id/manifest hash;
3. first compatible manifest.

If a previously persisted Skill cannot be found, the panel falls back to
compatibility chat instead of silently loading another Skill.

## Failure Model

- Missing manifest: compatibility chat.
- Invalid manifest/schema/path: compatibility chat with safe diagnostic.
- Missing runtime entry or import failure: compatibility chat.
- Runtime interface mismatch: compatibility chat.
- Undeclared capability: rejected request.
- Manifest-scoped paths outside the Skill root: rejected candidate.

## Persistence

The runtime identity is stored in both:

- `state.active_skill`;
- `task.skill`.

This lets a restart select the exact Skill or degrade safely without changing
the Task to an unrelated domain.
