# Release notes: 0.1.0-rc.5

Date: 2026-11-22 (+08:00)

Status: **local release candidate; not released**

## 2026-11-22 rc.5

- SkillDock now accepts PCHW through a declared surface contract instead of a
  hard-coded `2.8.0` equality check.
- Exact PCHW `2.8.0` remains supported as a legacy bridge when no contract is
  present. PCHW versions after `2.8.0` must declare
  `surface_contracts["pchw-source-hosted"]`.
- The contract must use SemVer in the supported `>=1.0.0 <2.0.0` range, satisfy
  `min_skill_version`, and declare every required capability. The current
  package requires `telemetry.csv.analyze`.
- SkillDock rejects inactive Skills, mismatched Skill ids, invalid versions,
  missing or incompatible contracts, missing capabilities, and contract major
  `2` or later.
- The Windows launcher validates the compatibility result for the exact active
  manifest loaded by the Runtime. It no longer trusts a compiled-in PCHW
  version and does not fall back to the compatibility chat fixture.
- The integrated candidate packages PCHW `2.9.0` with
  `pchw-source-hosted` contract `1.0.0`, minimum Skill version `2.8.0`, and
  `telemetry.csv.analyze`.
- New tests cover legacy `2.8.0`, product versions `2.9.0`, `2.10.0`, and
  `3.0.0`, contract `1.1.0`, rejected contract major `2`, malformed versions,
  missing contracts, missing capabilities, inactive Skills, and mismatched
  Skill ids.
- The public rc.4 tag and assets are unchanged. rc.5 remains local until package
  verification, Clean Windows acceptance, and explicit user signoff complete.

## 2026-11-21 rc.4

- The integrated user package now has one unified `Uninstall.cmd` entry for the
  PCHW Skill and SkillDock Runtime. The default path preserves Task data,
  evidence, exports, shared Node engines, and rollback backups; the explicit
  full-cleanup path removes the data-backup roots as well.
- The package ships the SkillDock, PCHW, and Node license texts. The package
  verifier checks the exact license inventory and the unified uninstall flow,
  including a default uninstall followed by an explicit purge.
- Package-root metadata now records `Uninstall.cmd`, the license directory, and
  the uninstall behavior instead of the older four-entry root.
- `docs/COMPONENT-MATRIX.md` is now the canonical component, asset, host,
  version, and evidence matrix.
- The user README no longer claims a separate DSH-only package. Runtime-only
  compatibility is defined by the PCHW manifest identity and capabilities, and
  package inventory is taken from the manifests rather than a fixed count.
- `pnpm verify:frozen` locates Node `24.22.1` with SQLite `3.53.4`, verifies the
  runtime, and runs checks and tests under that exact engine.
- Release provenance for the source PCHW tree now records commit
  `417b41a6f96382f25ccbe354e784cee1378e0e99` and tree
  `1cf35a8f7941bd270d92250b594d9c93638a9b3d08ebf4923057265424c5bb8b`;
  the `2.8.0-rc.2` Skill and Portable assets are reused and are not claimed to be
  byte-identical to the packaged Skill tree.
- Bundled Node is now installed once under `LocalRoot\engines` and referenced
  by Runtime releases and retained backups. The engine is content-addressed by
  Node version and SHA-256; launch rejects missing, malformed, or changed
  shared engines instead of falling back to another Node.
- Two default Runtime installs that land in the same second now receive
  distinct sequence suffixes instead of failing on a directory collision.
- The panel now exposes local storage categories and offers a confirmed cleanup
  for obsolete recognized Runtime backups. The active Runtime, recorded
  rollback backup, Task data, attachments, evidence, and unmanaged directories
  are preserved.
- The protected Runtime rollback backup can be exported as a verified ZIP with
  its exact shared Node engine and per-file hashes. Exports expire after 24
  hours.
- Task and evidence cleanup for ordinary, non-source-hosted Tasks now requires
  a downloaded, state-bound export. Source-hosted Tasks remain blocked because
  another source owns their collaboration state.
  Stale/expired exports fail closed, quarantine recovery protects interrupted
  cleanup, and capability tokens, Runtime backups, installer logs, and the
  Agent Session are preserved.
- Completed cleanup retries return the original success, the state-commit crash
  window is recoverable, and expired export ZIPs are pruned at startup and
  storage refresh.
- Installer logs have a separate confirmed cleanup action limited to
  `LocalRoot\install-logs`.
- Runtime program backups now rotate after a successful install. The previous
  `runtime-location.json` target is always retained; the default retain count is
  one and can be raised with `-RetainRuntimeBackups`.
- Automatic rotation only removes recognized direct `Runtime-*` backup
  directories. Task data, attachments, migration-data backups, unrelated
  directories, and unrecognized names are preserved.
- Integrated user-package verification now checks the embedded RC and performs
  clean-then-upgrade installs in isolated roots, proving one backup remains and
  Task data survives.
- The user package records the embedded RC's real top-level directory and no
  longer fails when an unchanged Skill omits `backup_path`.
- A reproducible Runtime-only builder derives the package from the same
  verified integrated RC; its exact inventory is defined by the package
  manifests, not a hard-coded file count.
- Explicit `-PurgeUserData` uninstall now removes `launch-failure.json`,
  installer logs, and interrupted runtime-data migration directories; known
  SkillDock state no longer leaves the LocalRoot directory behind.
- The bundled PCHW `2.8.0` tree includes the reduced Skill entry and the fixed
  12-scenario behavior guardrail from the PCHW test line.

## 2026-11-18 local P1 candidate

This clean locally committed candidate supersedes the prior `19b7849d...`
archive for acceptance preparation only. It has not been pushed, tagged,
uploaded, or formally released.

Current pinned RC:

The adjacent `.sha256` sidecar and verification JSON are authoritative for the
exact archive bytes and digest.

- The Portable Runtime now preserves caller-provided `PANEL_SKILL_ROOTS` and
  `PANEL_SKILL_MANIFEST`.
- Startup fails closed unless `pc-hardware-workbench` `2.8.0` is active with at
  least one discovered/compatible candidate and `telemetry.csv.analyze`.
- The Skill launcher resolves interactive `explorer.exe` and hands the final
  URL to it as one quoted argument. It does not use the sandbox URL broker or
  start `msedge.exe` directly, and it does not hide the Explorer handoff.
- Source-hosted entry URLs use a short one-time `open_id`; the signed packet is
  held server-side for the short ticket lifetime.
- Automatic browser launch is best-effort. If page ACK does not arrive, the
  launcher returns `manual_open_required=true` with `manual_open_url` and a
  local `.url` shortcut, keeps Runtime data, and never reports automatic
  success.
- Existing installations use a separate upgrade entry. The prior PCHW Skill is
  moved to `.codex\skills\.skilldock-backups`; failed new installs are moved
  aside and the old Skill is restored. An identical installed tree is
  idempotent and performs no replacement. Clean acceptance remains strict and
  refuses an existing Skill.
- Explorer handoff succeeds only after the panel page acknowledges a
  short-lived handoff probe. Silent handoff success is rejected as
  `interactive_desktop_unavailable`, and a Runtime started for that attempt is
  stopped while preserving Task data.
- `runtime_access_blocked`, `interactive_desktop_unavailable`, and
  `skill_runtime_mismatch` have structured fallback states.
- Automated portable-launcher and visible-Edge regressions pass.
- Clean Windows user click, default ACL approval, Edge crash isolation,
  restart, uninstall, and user signoff remain pending.

## Identity

| Layer | Version |
| --- | --- |
| SkillDock application | `0.1.0-rc.5` |
| PC Hardware Workbench Skill | `2.9.0` |
| PCHW surface contract | `pchw-source-hosted` `1.0.0` |
| Supported contract range | `>=1.0.0 <2.0.0` |
| Legacy bridge | exact PCHW `2.8.0` only |
| Bundled Node.js | `24.22.1` |
| Platform | Windows x64 |

The application remains `private: true`. The RC is a local Windows archive and
must not be uploaded to an npm registry.

## Supported candidate scope

- Windows local installation of the SkillDock Runtime and PCHW Skill snapshot.
- The installed PCHW Skill with the SkillDock local panel.
- The current Codex user conversation as the source identity.
- One-time local telemetry-analysis permission.
- CSV to verified local analyzer packet to verified SVG to panel answer.
- Explicit fresh source-result claim and one panel writeback.
- Same-Task Runtime restart with panel and artifact identity retained.
- Upgrade from the legacy `runtime-dsh-web` data root without silently losing
  the old Task, attachments, artifacts, or evidence.
- Stale `server-info.json` from an older data root is ignored; the current
  launch result and health Runtime binding determine the active PID/port/launch
  identity.
- After the one-time permission and local artifact completion, the page keeps a
  visible “waiting for the source Agent” state and automatically updates when
  the Agent result is synchronized.
- The primary entry is started by the installed PCHW Skill from the current
  Codex conversation; ordinary users do not launch a runner or configure
  environment variables.

This release promises the `pchw-source-hosted` SkillDock panel only under
Codex. DSH and other hosts can install `pc-hardware-workbench` and use its
chat, collection, and CSV-analysis capabilities, but they must not be claimed
as SkillDock-panel hosts. The launcher hard-requires `CODEX_THREAD_ID`; without
that identity it fails with `thread_binding_missing`.

See [SUPPORT-MATRIX.md](SUPPORT-MATRIX.md) for the exact host matrix.

## Evidence basis

PCHW current-user-Thread FINAL-EFFECT R7 passed on 2026-11-17. The accepted flow
used real Microsoft Edge, no API or headless browser substitution, zero Thread
API calls, a consumed one-time grant, one fresh source-result claim, one imported
panel result, visible answer/evidence/chart/copy actions, and a same-Task
restart. The consolidated machine evidence SHA-256 was
`57542ff58f45f8ca668b68743489d476ecb856775b33328babc5b7af98d0972e`.

The SkillDock Runtime server used by R7 has SHA-256
`60f2a0b88a662fbc416e8efece01a3ffcd22e9c819583e1f1bbfb0a6645b75af`.
The R7 source was PCHW `2.7.4`. Its installed tree identity is
`f6eab543414ef6b208706b4367b7adb152db3bd5c5288390a0f30a5189a95eb1`
with 134 files. These bytes remain provenance for the accepted user experience;
they are not a claim that the rc.5 Runtime is byte-identical to the R7 Runtime.

The rc.5 source candidate is PCHW `2.9.0`: 141 files at tree SHA-256
`a60e079471f4f0cdc91de866bf2755220b002f7575001082060ee0714fe5d45b`
from commit `b520656568d282169a8352e89f97d06a2af84a57`. The rc.5 builder
records the packaged subset separately in `RC-MANIFEST.json`.

Compatibility and package verification are automated evidence. A new real
Codex Thread or model Turn is not part of the rc.5 compatibility change, and
the rc.5 candidate must not inherit the R7 PASS as if that run had exercised
the new package bytes.

The RC package also removes non-product mock/DSH adapters, developer entry
scripts, background shadow observation, and the recovery route from its
runtime surface. Its packaged `server.mjs` and launcher therefore have their own
independently recorded hashes; the R7 hashes are provenance for the accepted
user experience, not a claim that the sanitized package bytes are identical.

## User-facing acceptance truth table

The intended end state, taken from the reviewed FINAL-EFFECT definition and the
R7 PASS receipt, is:

1. The user describes a hardware problem and supplies evidence in the current
   Codex conversation.
2. The user agrees when offered the graphical workspace.
3. The installed PCHW Skill starts SkillDock without asking the user to find a
   runner, environment variable, port, token, or test command.
4. The page carries the current Task and supported attachments and identifies
   the PC Hardware Workbench.
5. The user submits a CSV and makes one explicit `one-time` local analysis
   decision.
6. The page shows a real SVG, a concrete judgement, supports/conflicts/context,
   uncertainty, two or three low-risk actions, and copy actions.
7. Closing and restarting SkillDock restores the same Task, panel, and artifact
   without creating another Thread or model Turn.
8. Insufficient permission, a missing Runtime, or a workspace conflict returns
   to conversation safely instead of exposing a development entry.

## Explicitly not supported by this candidate

- Multi-provider universal workspace.
- Background autonomous return.
- Multi-Task source-hosted operation.
- Recovery or default traffic.
- Automatic hardware tuning.
- General shell or arbitrary command execution from the panel.
- Test runners, runtime fixtures, mock answers, development routes, and a
  manual DSH entry inside the PCHW archive.
- BIOS, firmware, driver, clock, voltage, power-limit, fan, memory-timing, or
  operating-system modification.

The separately frozen DSH read-only observer is not part of this PCHW archive
entry.

## Upgrade and data recovery

All installed SkillDock helpers use one shared runtime path resolver. The
canonical data root is `runtime-pchw`; `runtime-dsh-web` is supported only as a
legacy migration source. Before migration, the installer copies the complete
legacy data tree to `%LOCALAPPDATA%\SkillDockBackups\data` and verifies the
copy.

If both data roots contain state, the installer fails closed with
`runtime_data_conflict`. No automatic merge or overwrite is allowed.
`-LegacyDataPolicy PreferLegacy` deliberately selects the legacy Task set after
the backup has been created; the old source directory remains available for
recovery.

For reference only: parameters related to hardware controls must put safety
first, and all hardware changes remain manual user actions outside this release.

## Release conditions still open

1. Install, use, restart, and uninstall from a clean Windows profile or VM.
2. Verify no leftover Runtime process, installed Skill, pointer, or test
   fixture remains after acceptance cleanup.
3. Review the final ZIP inventory and hashes.
4. Obtain explicit user approval before any commit, tag, push, upload, or
   public release.
