# Release notes: 0.1.0-rc.2

Date: 2026-11-20 (+08:00)

Status: **public test build; not a stable release**

## 2026-11-20 rc.2

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
- A reproducible Runtime-only builder derives a 40-entry package from the same
  verified integrated RC.
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
| SkillDock application | `0.1.0-rc.2` |
| PC Hardware Workbench Skill | `2.8.0` |
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
with 134 files. The distributable `2.8.0` archive applies the semantic version
bump, excludes the Skill's `tests/` directory, and records the resulting
installation subset hash separately in `RC-MANIFEST.json`. The 2.8.0 source now
contains 135 files at tree SHA-256
`57971b4e500be4a0b47ce60ca523eff2cd3905ea7483226975ee290fa31387b4`
from PCHW commit `0d7b4d9e8fe7873caabd697d1d86e909c86d0839`; the 2.7.4 R7
provenance above remains 134 files.

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
