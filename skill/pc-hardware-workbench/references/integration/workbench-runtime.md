# Installed workbench runtime

Read this reference when an installed host does not discover the PC Hardware
Workbench, when changing `workbench.manifest.json` or the JavaScript runtime, or
when diagnosing a capability/artifact boundary that differs between chat and a
workbench surface.

## Discovery

The Skill root is self-contained:

```text
pc-hardware-workbench/
  SKILL.md
  workbench.manifest.json
  runtime.mjs
  schemas/
```

A host that supports Portable Workbench discovers `workbench.manifest.json` from
its installed Skill roots. The Skill ID and version are `pc-hardware-workbench`
and the version in `SKILL.md`; discovery must not require a panel app-local
fixture or a particular Agent provider. Manifest scanning, precedence, and
fallback are host behavior.

When a compatible SkillDock host is installed, the Skill-side
`scripts/skilldock/launch-panel.ps1` entry starts or reuses that runtime and
returns a Task URL. It must never write runtime state into the installed Skill.

The manifest uses schema version `1.0`. Its Skill root, runtime entry, manifest
schema, UI-state schema, and event schema are relative to the Skill root and
must remain inside it. The public descriptor may expose the Skill ID, version,
capability IDs, block types, and schema versions, but not private filesystem
paths or provider credentials.

If a host cannot validate the manifest, import the runtime, or satisfy its
declared adapter capabilities, it must report a discovery/runtime limitation and
fall back safely. Do not substitute a different Skill or claim that the domain
runtime is active.

## Runtime boundary

`runtime.mjs` exports `createRuntime(context)` and only Skill-domain hooks:

- task context and device/evidence references;
- result validation and domain guidance;
- capability-grant checks for one local telemetry action;
- shared device/evidence state;
- read-only telemetry analysis and safe chart artifact generation.

The runtime does not contain Agent transport, app-server, provider, cookie,
OAuth, queue, handoff-token, or browser-session logic. The host owns those
operations. The manifest's resume fields describe content that a host may carry;
they do not implement a transport.

Runtime data belongs in the host-supplied runtime directory. Attachments,
artifacts, the shared device/evidence record, and caches must not be written into
the installed Skill. The runtime resolves its bundled PowerShell helpers from
the installed `scripts/` directory, so it does not depend on a panel working
tree.

## Permission and artifact contract

The default profile is `read-only-supervised` with network disabled, general
command unavailable, and system write manual-only. The only declared local
capability is `telemetry.csv.analyze`, scoped to:

- one submitted local CSV attachment and its SHA-256;
- one Task;
- fixed read-only analyzer/renderer scripts;
- a chart write under that Task's artifact directory.

The grant cannot authorize arbitrary commands, network access, system writes, or
hardware controls. Switching surfaces or loading the runtime never broadens it.

Generated SVG charts are checked for safe embedded content, written under the
Task artifact root, indexed with the source evidence ID and hash, and cached by
attachment hash plus analysis window. A cache hit must still verify the stored
artifact hash.

## Change check

When the manifest, runtime, schemas, capability IDs, artifact kinds, or runtime
entry changes:

1. keep `skill.version` aligned with `SKILL.md`;
2. keep every declared path contained in the Skill root;
3. run the runtime contract tests and Workbench surface tests;
4. run the structural validator and non-live Skill suite; and
5. verify that installed discovery uses the package rather than an app-local
   fixture.
