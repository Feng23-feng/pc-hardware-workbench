# PC Hardware Workbench External Review R6 Safety Input Scope

Date: 2026-11-28

Scope: final current-user-input and technical-label scope fixes

Release status: source verification complete; Pre-release candidate, not a stable
release

## Findings Addressed

### Current user input sources

`currentTaskContext()` now includes:

- `packet.text`;
- `packet.free_text`;
- current `user_message` events;
- the original task objective;
- the Agent-authored current goal.

The user inputs are retained before the Agent goal. A task whose original
objective is “检查游戏掉帧” now still blocks when the current packet text, free
text, or user message says “电脑冒烟，有火花”.

### Technical smoke-label scope

The previous exclusion scanned a 32-character neighborhood, so `smoke test`
could suppress a separate nearby `sparks from PSU`.

The exclusion is now attached only to the matched smoke occurrence:

- `smoke` followed by `test` or `testing`;
- `smoke` preceded by `signed handoff`.

It does not apply to `sparks`, `smoke from PSU`, or a separate hazard elsewhere in
the sentence.

## Regression Coverage

- Hazard in `packet.text`: **blocked**.
- Hazard in `packet.free_text`: **blocked**.
- Hazard in current `user_message` event: **blocked**.
- `smoke test` alone: **ready**.
- `smoke test, sparks from PSU`: **blocked**.
- Existing mixed Chinese hazard and negation regressions: retained.

## Frozen Interfaces

- Summary-only analyzer source binding: unchanged.
- ChartData/top-level source agreement: unchanged.
- Source-hosted Summary-only and chart completion conditions: unchanged.

## Remaining Release Acceptance

- Real Codex Thread behavior.
- Permission allow/deny and recovery.
- Human interaction.
- Clean Windows install, upgrade, repair, and uninstall.
- Rebuilt package, actual Edge acceptance, and exact-byte verification.
- Live LHM Web/WMI remains SKIP unless a live authorized process is available.

These are not replaced by automated test passes.

## Verification

- Full Windows Skill suite with Redacted live collector: **PASS**
- Workbench Runtime contract: **PASS**
- Telemetry Broker chart-pack regression: **PASS**
- SkillDock smoke: **PASS**
- PCHW source-hosted mock E2E: **PASS**
- SkillDock frozen verification: **PASS**
- Skill validator: **`Skill is valid!`**
- Live LHM Web/WMI: **SKIP**

Per the adjusted release policy, missing clean-install and multi-platform
acceptance does not block a Pre-release public test build, but those items remain
visible and must not be reported as PASS.

## Verdict

The confirmed R6 interface issues are fixed and the source feature set is frozen
for Pre-release delivery. Phase 3 remains out of scope.
