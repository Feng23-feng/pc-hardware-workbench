# PC Hardware Workbench 2.9.3 Security and Release Acceptance

Date: 2026-11-27  
Host: Windows 11 Home 10.0.26200, x64  
PowerShell: 7.6.9  
Node.js: 24.22.3  
Base commit: `30de911fa3b85ef84fe1d1c48a23dbc702986f75` plus reviewed working-tree changes  
Release status: **not ready for a stable-release claim**

## Scope

This review covers the confirmed telemetry evidence, path containment, artifact
integrity, missing-value formatting, analyzed-window statistics, permission
boundaries, analysis error mapping, display-evidence enforcement, browser
artifact-cache behavior, attachment analysis-time consistency, SVG safety, and
GPU tuning evidence provenance.

It does not replace real-device behavioral acceptance or a clean Windows
installation/upgrade test.

## Confirmed Regressions and Results

| Item | Pre-fix evidence | Current result | Post-fix regression evidence |
| --- | --- | --- | --- |
| Attachment Junction/reparse escape | External review confirmed lexical containment accepted an attachment path through a Junction. Local regression then failed with “Missing expected exception”. | **PASS** | `run-telemetry-broker-tests.mjs` rejects a Junction target outside the attachment root. |
| Artifact tampering and task ownership | External review confirmed `getArtifact()` did not rehash and task ownership was not checked at use time. | **PASS** | Broker tests reject cross-Task lookup, Task-mismatched panel binding, modified SVG bytes, and unsafe externally loaded SVG. The SkillDock route test also rejects a tampered artifact. |
| Missing duration/interval shown as zero | External review confirmed `Number(null) === 0`. | **PASS** | Telemetry block tests preserve missing values as `未提供`/empty cells while retaining a real analyzer-produced zero as zero. |
| Categorical statistics crossing the analysis window | External review confirmed JavaScript treated analyzer row indices as physical CSV lines and selected `Thermal` could be shown as `Idle`. | **PASS** | PowerShell `analyze-telemetry.ps1` now derives `CategoricalColumns` directly from `$selectedRows`; the JavaScript duplicate parser is removed. Analyzer and broker regressions cover a malformed middle row plus a trimmed surplus field. |
| Attachment content read before authorization | External review identified `findCached()`/`validateAttachment()` reading the full CSV before a grant. | **PASS** | Runtime test confirms an uncached analysis requests permission with zero attachment-content reads. Pre-permission lookup uses real-path metadata and declared SHA-256 only. |
| Analysis failure mislabeled as missing sensors | External review confirmed timeout, runner, and hash failures shared the sensor-column explanation. | **PASS** | Runtime tests verify distinct timeout, runner-start, hash-mismatch, and no-series titles/recovery actions. |
| Display evidence enforcement overwriting a stop conclusion | External review reproduced a panel that required immediate power-off/no repower while the same task mentioned stutter; the runtime still appended fixed-scene retest advice. A second pass also reproduced a polite-prefixed stop such as “请立即停止使用电脑” being missed. | **PASS** | Enforcement now exits unchanged for `status: blocked`, an existing explicit stop recommendation, or a stop priority action, including common polite or mandatory prefixes. It does not infer danger by expanding a physical-danger keyword catalogue. Historical and negated display clauses are excluded, while “黑屏已经修复但仍掉帧” retains the current stutter context. |
| Unsafe SVG loading | External review requested stronger artifact loading boundaries. | **PASS** | SVG validation rejects active elements, external URLs/imports, doctype/entity stylesheets, and data/javascript/vbscript schemes; artifact lookup rechecks the hash and safety. |
| GPU declaration/measurement ambiguity | External review requested clearer evidence association. | **PASS** | GPU helper output marks identity as `user-declared-unverified`, baseline/recovery as `user-confirmed-not-measured`, and fingerprints as declaration-derived. |
| Browser reuse bypassing artifact checks | External review questioned the one-year immutable artifact response. | **PASS** | SkillDock artifact content now sends `Cache-Control: private, no-store`; each display/download request re-enters Task ownership, path, size, hash, and SVG checks. |
| Attachment replacement during analysis | External review requested evaluation of the hash-check/analyzer-reopen race, then reproduced replacement during chart-pack generation after an earlier pre-render check. | **PASS with residual risk** | A new analysis rechecks the attachment only after the complete analyzer and chart-renderer pipeline finishes and before artifacts are accepted. A persistent replacement fails closed with `attachment_hash_mismatch`. Separate tests cover mutation during the analyzer call and during chart-pack generation. A rapid replace-and-restore swap can still evade the final check; the documentation states that closing that residual gap requires OS-level sandboxing or a process handle shared with every reader, which was intentionally not added in this minimal fix. |

## Full Windows Test Matrix

| Suite | Status | Result |
| --- | --- | --- |
| Contract | PASS | All contract checks passed. |
| Encoding | PASS | 50 PowerShell files passed. |
| PowerShell 7 parse | PASS | 50 files passed. |
| Device identity | PASS | Passed. |
| Inventory context | PASS | Passed. |
| Collector static/path | PASS | Passed. |
| Collector live smoke, Redacted | PASS | Local read-only collection passed. |
| Telemetry audit | PASS | Passed. |
| VRAM knowledge | PASS | Passed. |
| Telemetry analyzer | PASS | Analyzer 1.2.7 passed, including selected-row categorical statistics. |
| Telemetry chart | PASS | Passed. |
| Telemetry pack | PASS | Passed. |
| Memory basis | PASS | Passed. |
| Tuning conclusion | PASS | Passed. |
| Evidence pipeline | PASS | Passed. |
| Telemetry normalization | PASS | Passed. |
| Hardware case and HTML report | PASS | Passed. |
| RAG evidence | PASS | Passed. |
| GPU automatic overclock | PASS | Passed, helper 2.0.4. |
| LHM adapter regression | PASS | Passed. |
| Live LHM Web/WMI read | SKIP | No already-running LHM process was available. |
| Doctor | PASS | Passed. |
| PCWB CLI | PASS | Passed. |
| Interaction contract | PASS | Passed. |
| Workbench surface contract | PASS | Passed. |
| Workbench runtime contract | PASS | Passed. |
| Telemetry broker chart-pack regression | PASS | Passed. |
| Claim verification | PASS | Passed. |
| PresentMon analysis | PASS | Passed. |
| Skill validator | PASS | `Skill is valid!` |
| SkillDock frozen suite | PASS | `pnpm verify:frozen` passed. |
| PCHW source-hosted mock external-agent E2E | PASS | Installed-Skill tree identity, source Agent result, panel rendering, artifact cache headers, and tamper rejection passed. |
| Skill installer regressions | PASS | Remote/local install, idempotency, rollback, and path-boundary cases passed. |
| Real Edge source-result auto-refresh on current bytes | PENDING | The existing `dist` package predates the current evidence-disclosure UI and failed that UI assertion. Rebuilding is intentionally blocked by the RC's reviewed PCHW tree identity until the candidate identity is updated. This is a packaging-state issue, not a source or security PASS. |

## SKIP

- Live LHM Web/WMI read: requires LHM already running and an explicitly
  available live process. No process was present.

## PENDING Manual Acceptance

- Real Codex Thread end-to-end launch, permission, recovery, panel result, and
  source-conversation sync with explicit Thread-creation authorization.
- Human review of running, upload failure, deny/re-approve, attachment change,
  Task recovery, result sync, dangerous physical symptom handling, and cleanup
  confirmation on the installed product.
- Clean Windows user-account install, upgrade, repair, and uninstall.
- Reviewed PCHW tree identity update, current RC rebuild, package verification,
  and real Edge source-result auto-refresh against those rebuilt bytes.

## Warnings

- `SKILL.md` is 10,656 bytes, below the 10,752-byte daily target and the
  11,264-byte hard maximum.
- The attachment race check is intentionally narrow: it rejects a persistent
  replacement but does not claim to defeat an adversarial rapid swap-back.
- The clean RC identity and Edge test remain pending; automated source tests do
  not substitute for packaged-byte verification.

## Verdict

All confirmed source-level security defects in this review round have post-fix
automated regression coverage, and the full automated Windows Skill suite plus
the SkillDock frozen suite pass. No post-fix source-level FAIL is open.

This report does **not** establish that 2.9.3 is a stable release. The PENDING
manual, real-Thread, reviewed-byte package rebuild, and real-Edge checks above
must be completed before a stable-release claim.
