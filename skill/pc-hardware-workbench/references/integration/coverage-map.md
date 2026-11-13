# Coverage map

This integrated suite preserves the generic references and scripts from three installed Skills and applies controlled integration revisions where routing, safety, evidence, or purchase logic must remain consistent. Do not overwrite these integrated files from an older source Skill.

| Source | Source version | Integrated location | Coverage |
| --- | --- | --- | --- |
| hardware-triage-framework | 1.1.1 | `references/triage/` | All five reference files |
| upgrade-purchase-brake | 1.0.0 | `references/upgrade/`, `scripts/` | All five references and the r14 collector |
| guided-overclocking | 1.0.3 | `references/tuning/` | All eight reference files |
| GPU automatic candidate integration | 3.0.3 prototype | `references/tuning/`, `scripts/suggest-gpu-overclock.ps1`, `tests/run-gpu-auto-oc-tests.ps1` | Deterministic integration-only candidates, one normative tier authority, NVIDIA/AMD/Intel family priors, laptop power-limit state, usable-start lineage, fallback semantics, public-reference provenance, and no hardware writes |
| integration extensions | 1.6.0 | `references/integration/` | Shared local-path safety helper, access-before-reparse checks, hardware-independent path tests, friendly missing-file errors, offline/cloud hydration prevention, locale-independent access-denied detection, behavior-based restricted-agent classification, user-started elevated read-only inventory without automatic UAC, explicit collection-privilege context, IEC capacity formatting, merged EDID identity with active-display capabilities, independent requested-versus-effective nvidia-smi power queries, GPU PnP state and adapter-kind evidence, firmware memory-slot summary, PowerShell 5.1/7 cross-version parsing, instantaneous GPU telemetry, format-specific UTF-8 BOM reports, four-state battery diagnostics with stage-specific reasons, everyday-slowdown and stutter triage, Windows crash evidence guidance, peripheral/network scope handoff, laptop battery and adapter triage, screenshot evidence limits, AMD Tctl/Tdie, CPU die average and CPU PPT telemetry with offset/limit exclusion and rejected-candidate warnings, telemetry-inclusive cross-mode handoffs, cross-mode telemetry contract assertions, safe Markdown text for hardware-derived fields, complete Unicode control/format cleaning with variation-selector removal, synthetic inventory-redaction tests, consistent fixed/removable volume scope, explicit reported-device semantics, CPU core maximum and GPU core voltage telemetry, formal telemetry subflow, deterministic SVG telemetry charts, validated chart-data extraction and downsampling, no-overwrite chart output, local hardware-case continuity with hashed evidence, hypothesis states and change timeline, PSU blocking conditions, Windows collector scope, clarified risk taxonomy, dated HWiNFO observations, large-CSV limits, release-blocking manual acceptance, static-versus-manual test disclosure, device identity quality states, Intel 13th/14th-generation caution, external-reference disclosure, GPU baselines and desktop-specific routes, laptop safety boundaries, telemetry parsing and validation, privacy controls, purchase planning, recovery sequencing, mandatory reference-only safety notices, context-adaptive explanations, and dynamic GPU clock/VF interpretation |
| hardware-case offline reports | 1.7.0 | `scripts/export-hardware-case-html.ps1` | Static dependency-free HTML reports with prior case validation, escaped case data, no remote resources, no external evidence source paths, overwrite protection, and opt-in size-limited artifact previews with active or external SVG rejection |
| unified telemetry normalization | 1.8.0 | `scripts/normalize-telemetry.ps1`, `references/integration/telemetry-normalization.md` | CSV and structured sensor snapshots share a versioned provenance-aware JSON document; source/tool/device/capture metadata, input hash, sampling consistency, mixed-source and mixed-unit warnings, preserved missing values, and direct normalized-JSON chart rendering |
| dynamic RAG evidence | 1.9.0 | `scripts/rag/`, `references/integration/dynamic-rag.md` | Official source registry, tiered source hierarchy, minimal queries, append-only evidence cards, publication/fetch/expiry scope, conflict references, community lead downgrade, and freshness checks without script-driven network access |
| LHM live adapter | 2.4.0 | `scripts/lhm/`, `references/integration/lhm-adapter.md` | Explicit-consent, bounded read-only collection from an already-running LibreHardwareMonitor instance through its loopback Web `/data.json` interface with legacy WMI fallback; hardware-path retention, sensor-type/unit mapping, structured snapshots, provenance, duplicate handling, and no self-install, self-start, elevation, non-loopback access, persistence, or hardware writes |
| visual evidence | 2.1.0 | `references/integration/visual-evidence.md` | Runtime-owned vision capability, screenshot and photo evidence classes, visible-versus-inferred separation, OCR/crop/redaction fallback, prompt-injection isolation, case hashing, and cross-evidence limits |
| Skill Doctor | 2.2.0 | `scripts/doctor.ps1`, `references/integration/skill-doctor.md` | Read-only installation and runtime diagnostics for version, required files, PowerShell syntax/encoding, output writability, CIM, PowerShell 7, optional sensors, validator, and runtime-owned vision limits, with no install, elevation, start, repair, or network action |
| simplified cross-capability routing | 2.3.0 | `SKILL.md`, `tests/cross-capability-scenarios.md` | Entry reduced below 12.5 KB and Quick path below 23 KB; conditional telemetry, LHM, and visual guidance remains in references; six real conversation scenarios cover cross-source, unavailable-source, conflict, and bypass demands |
| compact entrypoint routing | 2.6.0 | `SKILL.md`, `tests/interaction-scenarios.md`, `tests/run-interaction-contract-tests.ps1` | Entry reduced below 11 KB and Quick path below 20 KB; task routing and safety invariants remain resident while detailed GPU, VRAM, telemetry, purchase, and evidence procedures stay in references |
| user-claim verification | 2.7.0 | `references/integration/claim-verification.md`, `scripts/verify-hardware-claim.ps1`, `tests/run-claim-verification-tests.ps1` | Separates measured current, user-confirmed current, historical, estimate, conflict, and unverifiable evidence without dismissing a truthful user report |
| PresentMon frame-time input | 2.7.0 | `references/integration/presentmon-frame-time.md`, `scripts/analyze-presentmon.ps1`, `tests/run-presentmon-analysis-tests.ps1` | Read-only CSV analysis for average FPS, tail frame time, low-FPS metrics, spikes, clusters, source hash, and capture-scope warnings; no automatic capture or hardware write |
| personal-hardware-triage | excluded | none | Personal device history intentionally excluded |

## Controlled source revisions

The integration intentionally revises these source-derived areas:

- triage routing now uses the bundled collector and includes de-energized handling;
- triage now prioritizes physical safety, data/boot risk, instability, functional
  faults, and performance in that order; it separates evidence states and routes
  `.evtx`, `.etl`, `.dmp`, and telemetry files to Event Viewer, WPR/WPA, WinDbg,
  or the bundled analyzer without automatic installation or elevation; USB audio
  triage records port/hub/controller paths and treats congestion, timeout, and
  DPC/ISR correlation as separate hypotheses before any driver or hardware
  replacement;
- upgrade intake, evidence, decision framework, and market check distinguish functional, preference, planning, retained, sold, and gifted outcomes;
- tuning evidence now includes target-specific cooling, explicit noise measurement, unit-aware telemetry, and packaged regression tests;
- GPU clock guidance now separates requested, saved, active, sampled, and
  effective values and compares dynamic operating ranges instead of requiring
  one exact voltage/frequency point;
- the GPU candidate prototype is integrated only under Tune; its older telemetry
  implementations are excluded, the current VRAM interpretation gates remain
  authoritative, and every numeric result remains a user-applied experiment;
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

Optional GPU candidate helper:

- `scripts/suggest-gpu-overclock.ps1`
- `references/tuning/gpu-auto-oc-tier-authority.json`

Keep the helper and authority together. The helper reads the JSON authority and
desktop/laptop power-state inputs, emits a session proposal, and performs no
hardware read or write. It is usable only after the normal tuning gate and may
not replace the current LHM, telemetry, or VRAM interpretation layers.

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
- GPU candidate numbers come only from the integrated authority after a verified
  baseline and saved recovery; unknown or ambiguous adapters receive no number;
- integrated GPU candidates never write, persist, or raise hidden limits and
  never treat a good first round as daily stability;
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
