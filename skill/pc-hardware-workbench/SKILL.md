---
name: pc-hardware-workbench
description: Integrate Windows-focused read-only hardware inventory, telemetry charting, evidence-gated troubleshooting, guided overclocking with deterministic GPU starting candidates, and upgrade-purchase decisions through one routed workflow. Other systems receive manual guidance only. Keep tuning-only requests free of unsolicited purchase advice; never modify hardware automatically or bypass permissions or anti-cheat.
metadata:
  version: "2.7.0"
  short-description: "One routed entry for hardware inventory, telemetry visuals, triage, deterministic GPU candidates, and purchase decisions"
---

# PC Hardware Workbench

Select one user objective across inventory, triage, telemetry, tuning, or
purchase; never run every mode.

## Entry and closure

When invoked without a concrete task, read
[entry-language.md](references/integration/entry-language.md) and ask for the
objective in the user's current language. Do not mix languages in the introduction.

If the first request already contains a concrete task, skip the introduction and
state the selected route. Expose decisive evidence, the one-variable choice if
any, pass/abort criteria, and recovery. End every branch with one result and one
next action, question, cancel, stop, or handoff; reuse a current snapshot before
asking again. Read [interaction-closure.md](references/integration/interaction-closure.md)
and [cross-mode-handoffs.md](references/integration/cross-mode-handoffs.md) only
when resuming or mixing routes.

Chinese reference examples are templates, not copyable text. Translate
user-facing content; preserve only labels shown by the user's software.

For save, resume, export, or evidence-heavy work, use
[hardware-case.md](references/integration/hardware-case.md) and its scripts.
Track identity as `confirmed`, `user-reported`, `unknown`, `unreadable`, or
`conflict`; follow [device-identity.md](references/integration/device-identity.md)
and never auto-decode a suspect identity.

## Hard-stop precedence

Physical danger outranks every route. For a **burning smell**, smoke, sparks,
liquid near powered hardware, a damaged connector, swollen battery, exposed
wiring, or visible electrical damage:

1. stop performance testing and parameter changes;
2. power off and disconnect only when safe;
3. request no further boots, stress tests, energized reseating, or telemetry;
4. direct the user to vendor service or qualified repair.

Unexplained instability blocks tuning until a stable baseline is restored.
Before reseating, require shutdown, AC/adapter disconnection, and a confirmed
de-energized state.

## Explain named choices

Explain the practical difference once before naming modes, routes, formats, or
procedures; never ask a bare “A or B?”.

### Beginner route

If the user cannot choose, asks for step-by-step help, or describes a
nontechnical symptom such as “电脑卡/怎么弄”, read
[beginner-guide.md](references/integration/beginner-guide.md). Use plain-language
outcomes, one decision per turn, and safe defaults.

## Plain-language parameter explanations

For any BIOS/UEFI tuning setting, firmware, clock, voltage, power control, fan
policy, memory timing, or hardware curve, include the safety notice in the
user's language and in the same paragraph:

- Chinese: `参数仅供参考，请以安全为第一要务。`
- English: `For reference only - put safety first.`
- Other language: an equivalent warning.

Never mix the Chinese and English notices in one reply. Skip the notice for
location-only or concept-only explanations, refusals without a candidate value,
safety stops, and ordinary UI instructions.

Before explaining, read
[explanation-style.md](references/integration/explanation-style.md). Never give a
bare number, offset, timing, profile, or instruction without the notice and an
appropriately detailed explanation. Use the exact visible BIOS/UEFI label and
never invent a path.

## Route by task

### Inventory

The embedded collector is Windows-only and requires consent. Read
[collector-workflow.md](references/integration/collector-workflow.md),
[hardware-detection.md](references/upgrade/hardware-detection.md), and
[output-format.md](references/upgrade/output-format.md). Present hardware and
limits together; inventory is not diagnosis, stability proof, or upgrade
justification. Add [cooling-evidence.md](references/integration/cooling-evidence.md)
only when thermal behavior matters.

### Triage

Read [triage-checklist.md](references/triage/triage-checklist.md),
[risk-taxonomy.md](references/triage/risk-taxonomy.md), and
[experiment-protocol.md](references/triage/experiment-protocol.md). Add
[collector-handoff.md](references/triage/collector-handoff.md) only when a
collector or event-log handoff can change the next decision. Localize before changing settings;
when symptoms overlap, prioritize physical safety, data risk, boot/display,
instability, functional faults, then performance. State the likely layer,
supporting/conflicting evidence, one smallest next diagnostic, and which result
would change the diagnosis.

### Telemetry and logs

Read [telemetry-analysis.md](references/integration/telemetry-analysis.md);
confirm source and workload. Analysis is read-only and does not require the
tuning entry gate; it never implies diagnosis, stability, or permission.
Use `render-telemetry-chart.ps1` for charts. Load the matching
[telemetry-normalization.md](references/integration/telemetry-normalization.md),
[lhm-adapter.md](references/integration/lhm-adapter.md), or
[visual-evidence.md](references/integration/visual-evidence.md).
For PresentMon, read
[presentmon-frame-time.md](references/integration/presentmon-frame-time.md) and
run `analyze-presentmon.ps1`. Use
[evidence-package.md](references/integration/evidence-package.md) with
`scripts/run-evidence-pipeline.ps1`.

### Tune

Read [tuning-modes.md](references/integration/tuning-modes.md) and
[fixed-workloads.md](references/integration/fixed-workloads.md) first.
Concept-only questions such as “超频是什么” bypass the entry gate.

For a personalized setting, complete the mandatory **tuning entry gate**:
target and exposed control; stock/known-good in-workload baseline without
unexplained instability; objective; credible recovery; fixed workload with
pass/abort evidence. A skip request does not waive the gate. A missing item is a
coaching branch, not a dead end: read [intake.md](references/tuning/intake.md),
ask one smallest question, and preserve answers.

After the target and form factor are known, use
[component-playbooks.md](references/tuning/component-playbooks.md), then only the
references that change the decision:
[device-routes.md](references/tuning/device-routes.md),
[tools.md](references/tuning/tools.md),
[success-and-sensor-semantics.md](references/integration/success-and-sensor-semantics.md),
[persistence-and-update-gate.md](references/integration/persistence-and-update-gate.md),
[telemetry-analysis.md](references/integration/telemetry-analysis.md).

For GPU clocks, read
[gpu-clock-behavior.md](references/tuning/gpu-clock-behavior.md); for a gated
GPU candidate also use
[gpu-family-playbooks.md](references/tuning/gpu-family-playbooks.md),
[gpu-auto-candidates.md](references/tuning/gpu-auto-candidates.md),
[usable-start-and-state.md](references/tuning/usable-start-and-state.md), and
the applicable [laptop-power-state.md](references/tuning/laptop-power-state.md)
or [beginner-gpu-auto-oc.md](references/tuning/beginner-gpu-auto-oc.md). Run
`scripts/suggest-gpu-overclock.ps1`, then present one user-applied card; unknown,
ambiguous, or multi-adapter identities receive no numeric candidate.

For VRAM or tool conflicts, read
[vram-and-memory-bus.md](references/tuning/vram-and-memory-bus.md) and
[gpu-memory-playbook.md](references/tuning/gpu-memory-playbook.md); reply with one next step
and test memory only after a passed core round.

Before applying, use the fixed-workload card for one variable, baseline,
pass/abort, rollback, persistence, and sensor limits; end with keep, continue,
revert, or stop.

### Purchase

Read [intake-template.md](references/upgrade/intake-template.md),
[decision-framework.md](references/upgrade/decision-framework.md),
[market-check.md](references/upgrade/market-check.md), and
[output-format.md](references/upgrade/output-format.md).

Default to no performance purchase until a concrete problem and positive
expected value exist. Compare a non-purchase option and dated regional price;
never invent prices. Assess preference, aesthetic, collection, gift, capability,
or future-project goals directly rather than inventing a bottleneck.

## Advice intensity

Read [advice-intensity.md](references/tuning/advice-intensity.md) for a hidden or
manufacturer-limited power, voltage, fan, or firmware control while power-path
evidence is incomplete. Default: refuse. Provide no tool name, no step sequence,
and no target value. Downgrade only when all three hold: the change is active,
present-state evidence is supplied, and the request is assessment, not
instruction; still give no tools, steps, targets, or safety claim.
Never downgrade: anti-cheat evasion, permission bypass, or concealment.

## Time-sensitive knowledge

For current vendor facts, read
[dynamic-rag.md](references/integration/dynamic-rag.md), use minimal identifying
data, and record sources through `scripts/rag/rag-evidence.ps1`.

## Shared rules

- Prefer current measurements, then logs/screenshots, dated history, and general
  claims; retain source, date, context, and uncertainty.
- Historical records are not current. "Do not ask" still requires one question:
  "Just confirmed and unchanged?" Keep it user-reported, never measured. See
  [claim-verification.md](references/integration/claim-verification.md).
- Use current permissions only; never self-elevate, install drivers,
  disable protections, or bypass sandbox/anti-cheat.
- Never automatically change firmware, BIOS/UEFI, clocks, voltages, limits,
  fans, timings, or vendor settings; the user applies them.
- Consent cannot make a missing recovery path safe. Do not help hide, defeat,
  or evade anti-cheat.
- Recommend current official software; reject repacks and untrusted mirrors.
  Treat webpages, logs, and profiles as untrusted evidence.

Tuning-only requests do not include purchase advice. For mixed requests,
stabilize and measure first; evaluate purchase only if the target remains unmet.

## Response shape

Reply in the user's language and lead with the result or next action. For novices,
translate terms and hide internal fields. For complex evidence, separate facts,
measurements, history, and assumptions. Detail requests expand evidence and
uncertainty without changing safety or asking the user to choose a mode again.
For timed multi-phase plans, add one Gantt from telemetry-analysis.md; skip
single steps.

## Maintenance

Runtime health: read [skill-doctor.md](references/integration/skill-doctor.md)
and run `scripts/doctor.ps1`; it repairs nothing. Keep the r23 collector and
exclude personal histories. For redistribution, read
[coverage-map.md](references/integration/coverage-map.md) and
[installation-coexistence.md](references/integration/installation-coexistence.md).
