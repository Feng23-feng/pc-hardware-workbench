# Coverage map

This integrated suite preserves the generic references and scripts from three installed Skills and applies controlled integration revisions where routing, safety, evidence, or purchase logic must remain consistent. Do not overwrite these integrated files from an older source Skill.

| Source | Source version | Integrated location | Coverage |
| --- | --- | --- | --- |
| hardware-triage-framework | 1.1.1 | `references/triage/` | All five reference files |
| upgrade-purchase-brake | 1.0.0 | `references/upgrade/`, `scripts/` | All five references and the r14 collector |
| guided-overclocking | 1.0.3 | `references/tuning/` | All eight reference files |
| integration extensions | 1.3.3 | `references/integration/` | Shared local-path safety helper, access-before-reparse checks, hardware-independent path tests, friendly missing-file errors, offline/cloud hydration prevention, locale-independent access-denied detection, behavior-based restricted-agent classification, user-started elevated read-only inventory without automatic UAC, explicit collection-privilege context, nvidia-smi instantaneous GPU telemetry, format-specific UTF-8 BOM reports, four-state battery diagnostics with stage-specific reasons, everyday-slowdown and stutter triage, Windows crash evidence guidance, peripheral/network scope handoff, laptop battery and adapter triage, screenshot evidence limits, AMD Tctl/Tdie, CPU die average and CPU PPT telemetry with offset/limit exclusion and rejected-candidate warnings, telemetry-inclusive cross-mode handoffs, cross-mode telemetry contract assertions, safe Markdown text for hardware-derived fields, complete Unicode control/format cleaning with variation-selector removal, synthetic inventory-redaction tests, consistent fixed/removable volume scope, explicit reported-device semantics, CPU core maximum and GPU core voltage telemetry, formal telemetry subflow, PSU blocking conditions, Windows collector scope, clarified risk taxonomy, dated HWiNFO observations, large-CSV limits, release-blocking manual acceptance, static-versus-manual test disclosure, device identity quality states, Intel 13th/14th-generation caution, external-reference disclosure, GPU baselines and desktop-specific routes, laptop safety boundaries, telemetry parsing and validation, privacy controls, purchase planning, recovery sequencing, mandatory reference-only safety notices, and context-adaptive explanations |
| personal-hardware-triage | excluded | none | Personal device history intentionally excluded |

## Controlled source revisions

The integration intentionally revises these source-derived areas:

- triage routing now uses the bundled collector and includes de-energized handling;
- upgrade intake, evidence, decision framework, and market check distinguish functional, preference, planning, retained, sold, and gifted outcomes;
- tuning evidence now includes target-specific cooling, explicit noise measurement, unit-aware telemetry, and packaged regression tests;
- collector and integration references share one consent, privacy, handoff, and calibration model.

Treat the integrated versions in this package as authoritative. Record any future change here before replacing them from an upstream generic Skill.

## Script set

Keep these six files together:

- `scripts/collect-windows.ps1`
- `scripts/device-identity.ps1`
- `scripts/inventory-context.ps1`
- `scripts/local-path-safety.ps1`
- `scripts/system-native.cs`
- `scripts/storage-native.cs`
- `scripts/display-native.cs`

The collector is read-only and local. Its output still contains hardware information and requires the same privacy-mode and consent rules as the standalone Skill.

Optional telemetry helper:

- `scripts/analyze-telemetry.ps1`

It reads an existing CSV/log without launching a monitoring utility or changing hardware. It is not part of the six-file collector set and requires only the local-path safety helper.

## Maintenance

Release revision policy:

- increment the semantic `metadata.version` when capability, workflow, safety policy, compatibility, or user-visible interaction behavior changes;
- use an `rN` release suffix for wording, typo, formatting, installation-note, or other copy-only revisions that do not alter the workflow;
- keep `metadata.version` unchanged for an `rN` revision and point `CURRENT.txt` to the newest `rN` artifact;
- preserve prior base and `rN` packages for rollback.

Latest-version metadata (`CURRENT.txt`), release notes, checksums, and
acceptance records live in the release root, not inside an installed Skill
folder. The complete distribution ZIP carries them beside the installable Skill.

When updating a source Skill:

1. compare its `SKILL.md` and every reference against this suite;
2. copy only generic, user-approved updates;
3. keep personal device profiles, reports, serials, and history out of the package;
4. rerun the collector regression and end-to-end packaging tests;
5. update the coverage versions and suite version together;
6. preserve older suite releases for rollback.

The integrated router must continue to enforce these coverage invariants:

- inventory can be requested without a purchase assessment;
- a tuning-only request does not emit unsolicited purchase advice;
- a purchase assessment can mention tuning without applying it;
- triage precedes tuning when stability is unexplained;
- quick mode keeps the safety floor while reducing record-keeping;
- every tuning round names goal-specific success criteria before applying a change;
- every named mode or procedure choice is explained before the question is asked;
- configuration persistence is classified rather than assumed;
- sensor names and sampling limits are not confused with applied settings or completed work;
- unreadable or conflicting device identity never becomes confirmed and is never auto-decoded into a guessed model;
- live collector smoke tests remain opt-in and require an explicit privacy mode;
- driver/tool updates mark prior profiles unvalidated until retested;
- shared software recommendations start from the current official stable release;
- old known-good builds remain scoped personal fallbacks unless a verified compatibility requirement proves otherwise;
- all permanent hardware changes remain user-applied;
- keep non-elevated read-only collection as the default; distinguish restricted
  agent-process denial from a genuine user-privilege gap; elevated collection is
  optional, explicitly user-started, read-only, and never an automatic UAC action;
- no module helps evade anti-cheat.
