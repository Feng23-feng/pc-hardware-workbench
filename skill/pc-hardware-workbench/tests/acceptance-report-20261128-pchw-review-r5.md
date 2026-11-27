# PC Hardware Workbench External Review R5 Interface Fixes

Date: 2026-11-28

Scope: final three interface fixes requested after the R4 external review

Release status: source and automated verification complete; stable release not
declared

## Findings Addressed

### 1. Original user safety context

Runtime previously preferred `panel.current_goal` over the original user
objective. An Agent summary such as “检查游戏掉帧” could therefore hide a current
user description such as “电脑冒烟，有火花”.

Runtime now evaluates the current fields together, with the user objective
retained before the Agent summary. Both are examined for safety rather than one
masking the other.

This also exposed a benign English smoke-test label during integration testing.
The fix excludes narrow technical labels such as `smoke test`, `smoke testing`,
and `signed handoff smoke`; it does not add a broader hazard vocabulary.

### 2. Summary-only analyzer binding

Broker now validates the analyzer result before `analysisSummary()`:

- top-level `SourceSha256` must be present and match the actual attachment hash;
- top-level `SourceBytes` must be present and match the actual attachment size;
- if `ChartData` exists, its source hash and byte count must equal the validated
  top-level binding;
- missing or incorrect analyzer binding is rejected and is never replaced with
  the attachment hash.

The error maps to a specific user-facing recovery path instead of a generic
analysis failure.

### 3. Source-hosted Summary-only completion

`completeSourceHostedAgentResult()` now follows the actual `chart_preset`:

- summary-only completion requires a valid, source-bound analysis and no chart
  artifact;
- an explicit chart preset still requires at least one verified chart artifact;
- chart artifacts retain the existing Task ownership, path, SHA-256, and SVG
  validation path;
- a summary completion with an analysis bound to another source is rejected.

## Regression Coverage

- User objective contains smoke/sparks while Agent current goal is benign:
  **blocked**.
- Technical `signed handoff smoke` label with an ordinary slowdown:
  **not blocked**.
- Summary-only analyzer result with wrong hash: **rejected**.
- Summary-only analyzer result missing byte binding: **rejected**.
- Top-level binding correct but nested ChartData binding incorrect: **rejected**.
- Source-hosted summary completion with no artifact: **accepted**.
- Source-hosted explicit chart completion with no artifact: **rejected**.
- Source-hosted summary completion with another source hash: **rejected**.

## Verification

- Full Windows Skill suite with Redacted live collector: **PASS**
- Workbench Runtime contract: **PASS**
- Telemetry Broker chart-pack regression: **PASS**
- SkillDock smoke: **PASS**
- SkillDock frozen verification: **PASS**
- PCHW source-hosted mock E2E: **PASS**
- Skill validator: **`Skill is valid!`**
- Live LHM Web/WMI: **SKIP**

## Remaining Release Acceptance

- Real Codex Thread launch, permission, recovery, result sync, and current-Thread
  behavior.
- Human interaction acceptance.
- Clean Windows install, upgrade, repair, and uninstall.
- Rebuilt release package verification and real Edge test on those exact bytes.

These remain PENDING. Automated PASS results are not an independent external
re-review and do not establish a stable release.

## Verdict

The three requested interface defects have failing-first regression coverage and
current Windows test passes. No Phase 3, persistence schema migration, feature
expansion, or normal UI adjustment was started.
