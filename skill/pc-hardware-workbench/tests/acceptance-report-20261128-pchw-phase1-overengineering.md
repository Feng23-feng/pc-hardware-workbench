# PC Hardware Workbench Phase 1 Anti-Overengineering Acceptance

Date: 2026-11-28  
Scope: instruction and documentation simplification only  
Security baseline: `813b8f0` (`fix: harden telemetry evidence and safety boundaries`)  
Release status: Phase 1 complete; Phase 2 and Phase 3 not started

## Objective

Reduce repeated instruction authority, unnecessary follow-up questions, and
unconditional persistence or SkillDock triggers without changing Runtime,
schema, collection, telemetry parsing, permissions, or hardware behavior.

The five product principles used for review were:

- The product should feel simple without becoming functionally simple.
- The Agent should have freedom inside explicit safety and evidence boundaries.
- Runtime should own structure, permissions, and integrity, not every decision.
- Safety mechanisms should be strict where risk requires it, not equally strict
  across every workflow.
- The project should remain releasable instead of chasing a perfect architecture.

## Confirmed Behavior Changes

| Area | Before | After |
| --- | --- | --- |
| Parameter safety notice | Entrypoint could be read as requiring the notice whenever a hardware parameter was explained. | `explanation-style.md` is the canonical trigger. It applies to actionable candidate values, explicit changes, or BIOS/firmware operations; concept, location, refusal, and safety-stop answers do not trigger it. |
| Question cadence | Multiple references used “one question per turn” as the general tempo. | The default is one decision per turn. Novices, safety-critical branches, and dependent follow-ups remain single-question; independent facts for the same decision may be requested together, capped at three in tuning intake. |
| Historical values | All historical values could be blocked by another confirmation question. | Confirmation is required only when the value can change safety, tuning, purchase, or baseline conclusions. Other uses remain explicitly user-reported/historical and can continue. |
| Completed answers | Every branch was expected to end with an action or question. | Ordinary chat may end with a completed answer when no decision-changing question remains. Evidence gaps and uncertainty must remain visible. Panel schema migration remains a Phase 2 task. |
| Hardware case | Multiple turns alone could trigger durable case creation. | A case requires durable continuity: reuse across sessions, baseline/change/test, large evidence, or chat-loss risk. |
| Dynamic RAG | A durable evidence card could be read as mandatory before every current-fact conclusion. | Simple current facts use official URL, date, and scope inline. A persistent card is required only for reuse, audit, conflict comparison, or a safety, compatibility, purchase, or recovery decision. |
| SkillDock trigger | Long surface guidance contained unimplemented presentation-preference modes. | Multiple turns alone do not justify SkillDock. The unimplemented `auto`, `chat-first`, and `panel-first` preferences were removed from executable guidance; the dashboard remains optional and chat-first. |
| Coverage map routing | The entrypoint linked the maintainer coverage map during maintenance use. | The installed file remains for repository compatibility, but the entrypoint now routes redistribution users to project release documentation and coexistence guidance. |
| Collector privacy wording | Older-report reuse implied a fixed hardware-change checklist. | The check is scoped to a change that could affect the current decision. The documentation now explicitly states that local collection entering Agent context remains sensitive and that the current collector does not yet provide section filtering. |

## Files Changed

- `SKILL.md`
- `references/integration/explanation-style.md`
- `references/integration/interaction-closure.md`
- `references/integration/hardware-case.md`
- `references/integration/dynamic-rag.md`
- `references/integration/claim-verification.md`
- `references/integration/collector-workflow.md`
- `references/integration/skilldock-surface.md`
- `references/integration/workbench-surface.md`
- `references/triage/triage-checklist.md`
- `references/tuning/intake.md`
- `tests/run-interaction-contract-tests.ps1`
- `tests/run-workbench-surface-tests.ps1`

## Test-First Adjustment

Phase 1 policy checks were added before documentation edits. They failed against
the old documents and passed after the canonical behavior was implemented.

The old exact-string assertions were then adjusted only where the old wording
encoded the superseded unconditional behavior. No failing test was deleted.
Existing assertions covering physical safety, permissions, error codes, artifact
integrity, path safety, schema, and launcher behavior remain in place.

## Measurements

| Metric | Before | After |
| --- | ---: | ---: |
| `SKILL.md` UTF-8 size | 10,656 bytes | 10,626 bytes |
| Quick path UTF-8 size | 19,665 bytes | 19,635 bytes |

Only directly related Phase 1 metrics are reported. No new telemetry or metrics
collection system was added.

## Test Results

| Check | Status | Result |
| --- | --- | --- |
| Skill validator | PASS | `Skill is valid!` |
| Interaction contract | PASS | Canonical safety trigger, question cadence, completion state, case/RAG thresholds, and test-first policy checks passed. |
| Workbench surface contract | PASS | SkillDock remains optional; current Thread, helper, permission, and binding rules remain enforced. |
| Full Windows Skill suite | PASS | All automated Skill tests passed. |
| Live collector smoke, Redacted | PASS | Read-only local collection passed. |
| Live LHM Web/WMI | SKIP | Requires an already-running LHM process. |
| Workbench Runtime contract | PASS | Preserved from the security baseline. |
| Telemetry broker regression | PASS | Preserved from the security baseline. |
| Telemetry analyzer regression | PASS | Preserved from the security baseline. |
| PCHW source-hosted mock E2E | PASS | Confirmed before Phase 1 edits. |

## Remaining Risks and Deferred Work

- Runtime still contains general symptom recognition and automatic recommendation
  generation until Phase 2.
- `status=ready` has not been changed to mean task completion. Runtime and schema
  alignment remain Phase 2 work.
- Actual collector section minimization has not been implemented. Phase 1 only
  stops the documentation from claiming that a full collection is minimal.
- Shared Evidence Store lazy initialization and case/RAG implementation changes
  remain deferred.
- Duplicate CSV analysis and default chart-pack size remain Phase 2 work.
- Schema and compatibility-state migration remains Phase 3 work.
- The detailed SkillDock protocol still exists in the installed reference. Phase
  1 removes unimplemented model-facing preferences and tightens trigger rules,
  but does not yet move all mechanical protocol detail into implementer tooling.
- HWiNFO page-specific download details and the installed coverage map file were
  not removed in Phase 1 because unrelated site and packaging checks still
  reference them.
- Manual behavioral acceptance and real Codex Thread validation remain outside
  this Phase 1 automated result.

## Verdict

Phase 1 is complete within its approved scope. Existing safety, permission,
evidence-integrity, and deterministic-analysis behavior remains intact. No new
mode, abstraction layer, configuration system, or metrics framework was added.
Phase 2 and Phase 3 are intentionally not started.
