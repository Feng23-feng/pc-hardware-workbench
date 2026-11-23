# Portable Workbench Manifest

## Purpose

A manifest lets a Skill install domain behavior plus stable presentation
contracts without teaching the panel a provider-specific feature branch.

The panel application and the Skill package remain separate deliverables.

## Discovery

```powershell
$env:PANEL_SKILL_MANIFEST = "C:\path\to\workbench.manifest.json"
$env:PANEL_MANIFEST_ALLOWED_ROOT = "C:\path\to\skill"
$env:PANEL_SKILL_ID = "example.skill"
```

If no manifest is configured, or validation fails, the runtime uses its
compatibility manifest. Pure Task/chat remains available.

`PANEL_SKILL_MANIFEST` may contain multiple paths separated by the platform
path delimiter. `PANEL_SKILL_ROOTS` can override the standard discovery roots.
`PANEL_WORKBENCH_MANIFEST` remains a compatibility alias.

Validation rejects:

- unsupported top-level fields or versions;
- missing or malformed Skill metadata;
- unsupported block types;
- missing schema files;
- mismatched schema versions;
- manifests, Skill roots, or schema paths outside the allowed root;
- files over the manifest size limit.

For the `pc-hardware-workbench` Skill, SkillDock does not infer panel
compatibility from the Skill's product version alone. Before selecting the
Skill runtime, it also requires:

- the declared `pchw-source-hosted` contract to be within the Runtime's
  supported contract range;
- `ui.state_schema_version` and `ui.event_schema_version` to be in the
  Runtime's explicit supported sets;
- every capability required by that contract to exist in the manifest.

PCHW `2.8.0` without a surface contract is the only exact-version legacy
bridge. A later PCHW `2.x` or `3.x` release is accepted only through a matching
contract and schema declaration. A mismatch leaves chat/Task fallback available
but does not load the PCHW panel runtime.

## Contract

Schema:

`schemas/workbench-manifest.schema.json`

Example:

`skills/pc-hardware-workbench/workbench.manifest.json`

Required sections:

```json
{
  "schema_version": "1.0",
  "skill": {
    "id": "example.skill",
    "name": "Example Skill",
    "version": "1.0.0",
    "root": "."
  },
  "runtime": {
    "id": "example-runtime",
    "entry": "./runtime.mjs"
  },
  "ui": {
    "state_schema_version": "1.2",
    "state_schema_path": "schemas/state.json",
    "event_schema_version": "1.0",
    "event_schema_path": "schemas/events.json"
  },
  "artifacts": {
    "namespace": "example",
    "allowed_kinds": ["chart", "table"]
  },
  "domain": {
    "capabilities": [
      {
        "id": "example.local.analyze",
        "kind": "broker",
        "implementation": "example-broker",
        "permissions": ["local_file_read"]
      }
    ]
  },
  "permissions": {
    "default_profile": {
      "profile": "read-only-supervised",
      "network": "disabled",
      "general_command": "unavailable",
      "system_write": "unavailable"
    },
    "required": []
  },
  "components": {
    "block_types": ["markdown", "table", "callout"]
  },
  "resume_handoff": {
    "required": true,
    "format": "both",
    "includes": ["task", "session_ref", "judgement", "priority_action"]
  },
  "adapter_requirements": {
    "required_capabilities": ["text_input", "session_resume"],
    "optional_capabilities": ["structured_output", "cancellation"]
  }
}
```

Adapter requirements use capability names, never provider ids.

## Runtime Entry

`runtime.entry` must:

- remain inside the validated Skill root;
- name an existing `.mjs` file;
- be no larger than 256 KiB;
- export `createRuntime(context)`;
- return a `SkillRuntime` whose id matches `runtime.id`.

See `SKILL-RUNTIME.md` for the interface.

## Public Projection

The browser receives a redacted descriptor with:

- Skill id/name/version;
- manifest status and safe error code;
- schema versions;
- artifact namespace/kinds;
- capability ids/kinds;
- block types;
- adapter capability requirements.

It does not receive the manifest path, Skill root, schema absolute paths, or
provider credentials.
