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
surface-contract versions, capability IDs, block types, and schema versions, but
not private filesystem paths or provider credentials.

`surface_contracts` separates product-version compatibility from host transport.
The `pchw-source-hosted` contract declares `contract_version`,
`min_skill_version`, and `required_capabilities`. Hosts must negotiate the
contract instead of requiring one exact Skill version. A product update that
does not change this contract must remain usable with an already compatible
surface host.

If a host cannot validate the manifest, import the runtime, or satisfy its
declared adapter capabilities, it must report a discovery/runtime limitation and
fall back safely. Do not substitute a different Skill or claim that the domain
runtime is active.

## Runtime boundary

`runtime.mjs` exports `createRuntime(context)` and only Skill-domain hooks:

- task context and device/evidence references;
- result validation and domain guidance;
- structured safety-state enforcement without general symptom classification or
  automatic display-evidence recommendation generation;
- capability-grant checks for one local telemetry action;
- shared device/evidence state;
- read-only telemetry analysis and safe evidence-only chart-pack generation.

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
- fixed read-only analyzer, chart, and chart-pack scripts;
- chart-pack writes under that Task's artifact directory.

The grant cannot authorize arbitrary commands, network access, system writes, or
hardware controls. Switching surfaces or loading the runtime never broadens it.

Before permission is granted, attachment inspection is limited to metadata and
real-path containment. It rejects symbolic links, junctions, other reparse
points, and paths whose resolved target leaves the controlled attachment root;
the runtime does not read or hash the full CSV until the scoped analysis grant
is present. A cache lookup may reuse an existing same-Task, same-attachment
artifact by declared SHA-256, but that cache does not authorize a new file read.
Changing the attachment ID or declared hash requires a new permission decision.
A cache hit is historical evidence from the same Task and attachment; it does
not claim the source file was revalidated just now. For a new analysis, recheck
the attachment hash after every analyzer/renderer child process finishes and
before accepting generated charts. Fail closed if the bytes changed during that
pipeline. This detects a persistent replacement, but not a rapid
replace-and-restore race; closing that last gap requires an OS-level sandbox or
a process handle passed to every reader.

Generated SVG charts are checked for safe embedded content, written under the
Task artifact root, indexed with the source evidence ID and hash, and cached by
attachment hash plus analysis window. One analysis returns an ordered pack of up
to six verified artifacts. Before display, download, panel reference, or result
sync, the runtime rechecks Task ownership, controlled real path, byte count,
SHA-256, and SVG safety. Every cached file must still match its stored hash.
The first artifact remains available as a legacy singular reference, but new
UI/event consumers use the `artifacts` array and corresponding `artifact_refs`.
`chart_preset` is optional. If omitted or explicitly `null`, the action returns
the analyzer summary without running chart-pack generation. The interactive
chart-analysis action explicitly requests `FirstPass`. Explicit `FirstPass`,
`GpuTuning`, or `CpuTuning` values retain the existing chart-pack behavior and
remain inside the same read-only CSV capability.

The analysis records `analyzer_passes` and `analyzer_pass_reason`. The normal
path reports one pass. The narrow `CandidateColumnPattern` recovery may report
two passes and must add an explicit fallback warning instead of presenting every
path as single-pass.

Runtime safety enforcement is intentionally narrow. Only a current explicit
physical-danger signal forces `blocked` and the canonical stop action. An
ordinary `blocked` state, such as missing permission, insufficient evidence, or
a tuning gate, remains Agent-authored and is not converted into an electrical
safety stop. Historical or negated text does not trigger a stop. Negating one
hazard does not suppress a different hazard in the same sentence. Once a hazard
is confirmed, conflicting Agent detail text is discarded with the replacement
action.

Safety detection evaluates the user's current task objective together with the
Agent-authored current goal. An Agent summary cannot replace or hide physical
danger retained in the original objective. Analyzer bindings must come from the
analyzer result itself; the attachment hash is not substituted when analyzer
source evidence is missing.
Technical test labels such as `smoke test`, `smoke testing`, and
`signed handoff smoke` are not physical-smoke evidence. This is a narrow
ambiguity exclusion, not a broader hazard vocabulary.

General symptom interpretation, display-retest evidence selection, and normal
recommendations belong to the Agent. Runtime must not infer black-screen or
stutter recommendations from task text, and it must not rewrite Agent-authored
advice when no safety contract applies.

A completed `ready` answer may omit `uncertainty`, `recommendations`,
`priorityAction`, and `actions`. Evidence gaps, conflicts, and uncertainty remain
visible whenever they actually exist.

Source-hosted completion follows the actual `chart_preset`: summary-only
completion requires a source-bound analysis and no artifact; an explicit chart
preset requires verified chart artifacts. The existing Task, path, hash, and SVG
checks remain mandatory for chart results.

Artifact lookup accepts `getArtifact(id, { taskId })`. Callers that omit the
current Task identity for task-owned artifacts fail closed rather than returning
an unowned chart.
Surface content routes must send `Cache-Control: private, no-store` so each
display or download re-runs Task ownership, path, size, hash, and SVG safety
checks instead of reusing a browser response.

## Change check

When the manifest, runtime, schemas, capability IDs, artifact kinds, or runtime
entry changes:

1. keep `skill.version` aligned with `SKILL.md`;
2. keep every declared path contained in the Skill root;
3. run the runtime contract tests and Workbench surface tests;
4. run the structural validator and non-live Skill suite; and
5. verify that installed discovery uses the package rather than an app-local
   fixture.
