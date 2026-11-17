# Changelog

## SkillDock 0.1.0-rc.1 / PCHW 2.8.0 - 2026-11-17

Release candidate preparation only. Local preparation commits exist, but the
candidate has not been pushed, tagged, uploaded, or formally released.

### Added

- Windows x64 RC build and reverse-verification scripts.
- One immutable candidate archive with an internal package manifest and an
  external SHA-256 sidecar.
- A bundled PCHW `2.8.0` Skill snapshot with tree-identity verification.
- RC installation, uninstall, permissions, support-boundary, and
  clean-Windows acceptance documents.
- Explicit default-off and manual-only hardware boundaries in the RC package.
- Shared runtime path resolution for launch, sync, wait, submit, installer, and
  uninstaller scripts.
- Verified legacy Runtime data migration with mandatory pre-write backup and
  fail-closed dual-root conflict handling.
- Upgrade regression covering stale `server-info.json`, old Task recovery,
  current PID/port launch binding, and retained Task/attachment/artifact data.
- Same-page automatic refresh from local analysis through source-Agent writeback;
  the waiting state is explicit and no longer requires manual reload or a
  “sync panel” action.

### Verified before RC packaging

- PCHW current-user-Thread FINAL-EFFECT R7 passed with real Microsoft Edge.
- A consumed one-time permission grant completed the local CSV analysis path.
- Fresh source-result claim and exactly one panel writeback passed.
- Answer card, verified SVG, evidence, uncertainty, low-risk actions, and copy
  actions passed.
- Same-Task restart preserved the panel and artifact identity.
- Stale legacy Runtime metadata no longer makes a healthy canonical Runtime fail
  with `runtime_binding_mismatch`.
- Page focus/visibility and all source-hosted result phases now trigger bounded
  state refreshes, preventing a background-throttled poll from leaving the page
  stale until F5.
- Static checks, full tests, installed-root mock/Edge, install identity, Skill
  validation, and worktree whitespace checks passed in the R7 receipt.

### Still closed

- Formal default entry.
- Default traffic.
- Background write.
- Coordinator recovery.
- Automatic BIOS, firmware, driver, clock, voltage, power, fan, memory-timing,
  or operating-system changes.
- Tag, push, upload, public release, and release signoff.
