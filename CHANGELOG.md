# Changelog

## SkillDock 0.1.0-rc.2 / PCHW 2.8.0 - 2026-11-20

- Deduplicate bundled Node engines under `LocalRoot\engines`; installed Runtime
  releases and retained backups now reference one content-addressed
  `node.exe` instead of embedding a second copy. Launches verify the exact
  engine SHA-256 and fail closed when the reference is missing, malformed, or
  changed.
- Default Runtime target names now add a numeric suffix when two installs land
  in the same second instead of failing with an existing-directory error.
- Add the top-bar local storage panel, authenticated storage inventory, and a
  confirmed cleanup action that removes only obsolete recognized Runtime
  backups while preserving the current Runtime, the recorded rollback backup,
  Task data, attachments, evidence, and unmanaged backup directories.
- Rotate Runtime program backups after a successful install, retaining one
  previous rollback copy by default while preserving the previous pointer target
  and leaving Task and migration-data backups untouched.
- Add a user-package gate that inspects the embedded RC and performs clean then
  upgrade installation in isolated roots, proving stale backups are removed and
  Task data survives.
- Fix integrated user-package `package_base` metadata and tolerate an unchanged
  Skill reinstall without a `backup_path` field.
- Add a reproducible Runtime-only package builder and verifier derived from the
  verified integrated RC.
- Explicit `-PurgeUserData` uninstall now removes launcher failure state,
  installer logs, and interrupted runtime-data migration directories, so known
  SkillDock state no longer leaves LocalRoot behind.
- Bundle the PCHW Skill entry/guardrail update from PCHW `2.8.0` test build.

## 2026-11-18 local P1 candidate

- Preserve caller-provided `PANEL_SKILL_ROOTS` and
  `PANEL_SKILL_MANIFEST` in the portable Windows launcher.
- Require the running Runtime to load `pc-hardware-workbench` `2.8.0` with
  `status=active`, at least one discovered candidate, and
  `telemetry.csv.analyze`; otherwise stop and fail closed instead of accepting
  `workbench.compat-fixture`.
- Open the panel URL through interactive `explorer.exe` rather than the Codex
  sandbox URL broker or a direct `msedge.exe` launch.
- Do not hide the Explorer handoff window; hidden shell launches can create no
  interactive Edge page.
- Require a short-lived browser page-load acknowledgement after handoff;
  otherwise return `interactive_desktop_unavailable` and stop the Runtime
  started by that failed attempt.
- Replace the long signed source-hosted token in the browser URL with a
  one-time short `open_id`; the signed packet stays server-side and the open
  ticket expires quickly.
- When automatic Explorer handoff cannot obtain a page ACK, return an explicit
  manual-open URL and local `.url` shortcut instead of stopping the Runtime or
  claiming success.
- Add a dedicated existing-install upgrade entry. It backs up an older PCHW
  Skill, installs the verified replacement, and restores the old directory if
  installation or tree validation fails.
- Add structured `skill_runtime_mismatch`, `runtime_access_blocked`, and
  `interactive_desktop_unavailable` fallback states.
- Rotate Runtime program backups after a successful install, retaining the
  newest one by default through `-RetainRuntimeBackups`; unrelated directories,
  Task data, and migration-data backups remain untouched.
- Fix integrated user-package metadata to record the embedded RC's real
  top-level directory, and reject future builds where that layout binding is
  inconsistent.
- Require user-package verification to run two isolated installs against the
  embedded RC, proving one Runtime backup remains and Task data survives.
- Allow an unchanged Skill on reinstall to omit `backup_path` without failing
  the surrounding Runtime upgrade.
- Add portable-launcher Skill-root tests and visible-Edge UI-flow regression
  assertions for `permission.requested` and verified SVG content.

This is a clean locally committed acceptance candidate. Clean Windows user
acceptance remains pending; the source has not been pushed, tagged, uploaded, or
formally released.

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
  stale.
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
