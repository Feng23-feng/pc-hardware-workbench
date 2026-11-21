# Clean-Windows acceptance for 0.1.0-rc.3

Status: **PENDING**. This checklist must be executed in a clean Windows profile
or VM. The current machine is not accepted as a substitute because it already
contains SkillDock, PCHW, Task data, Edge state, and prior permissions.

## Preconditions

- Use a distinct Windows profile or disposable VM with x64 Windows.
- No SkillDock Runtime pointer, Runtime directory, PCHW Skill, or SkillDock user
  data is present.
- Record OS build, user profile type, Edge version, Codex version, and starting
  process list.
- Verify the RC ZIP against its `.sha256` sidecar.
- Keep all screenshots and logs outside the package tree.

## Install

1. Extract the outer clean-Windows acceptance ZIP to a new local directory.
2. Double-click the root `Start-Acceptance.cmd`; keep the only primary entry.
3. Confirm the window says `Acceptance startup: PASS`, then inspect
   `payload\evidence\acceptance-start-result.json`.
4. Confirm the installed Skill subset matches the PCHW tree hash and file count
   recorded in the package's `RC-MANIFEST.json`.
5. Confirm exactly one active `Runtime-*` directory and a valid
   `runtime-location.json`, with version `0.1.0-rc.3`.
6. Confirm the bundled Node reports `v24.22.1`.
7. Confirm default traffic and the formal default entry are still off/closed.

The controller invokes the packaged installers. Do not replace its validation,
preflight, or install stages with manual script execution. The numbered scripts
under `payload` remain diagnostic-only.

## Controlled PCHW flow

1. Ask a hardware question in a new Codex conversation, consent to the graphical
   workspace, and confirm the installed Skill starts SkillDock automatically.
2. Upload one new CSV that is not already cached.
3. Submit one fixed analysis intent.
4. Pause at the permission card and verify `仅本次允许` maps to `one-time`.
5. Confirm exactly one matching `permission.consumed` event.
6. Confirm a fresh source result is explicitly claimed for the same Task,
   attachment, Session, and SHA-256.
7. Confirm one panel writeback with no stale source result.
8. Confirm the page advances automatically through waiting and source-writeback
   states.
9. Verify the answer card, verified SVG, supports/conflicts/context,
   uncertainty, low-risk actions, and both copy actions.
10. Restart the same Runtime, reopen the same Task, and compare Task count,
   phase, panel hash, artifact ID, and artifact SHA-256.

## Runtime access and desktop handoff

1. First test the default `%LOCALAPPDATA%\SkillDock` data root in the actual
   Codex Ask-for-approval profile. If access is denied, record
   `runtime_access_blocked` and continue in chat; do not call it a default pass.
2. Repeat only after the user explicitly approves a writable portable data root.
   Label that run `permission_fallback`, not clean default acceptance.
3. Verify portable Runtime discovery with an explicit Skill root or manifest,
   and confirm the page will not open when the target Skill is absent.
4. Confirm the Skill obtains the URL and hands it to interactive
   `explorer.exe`. Do not use the sandbox URL broker or start `msedge.exe`
   directly as the supported path. The Explorer handoff must not be hidden.
5. Confirm the URL uses a one-time short `open_id`, then confirm the panel page
   acknowledges the handoff probe before launch success is reported.
6. If automatic ACK times out, verify `manual_open_required=true`, show
   “手动打开面板”, and confirm `manual_open_url` or `manual_open_file` produces
   the same probe ACK.

## Edge crash isolation

Preserve Application and Windows Error Reporting events without deciding the
product result from a crash page alone.

1. Open an ordinary page in the user's normal Edge profile.
2. Open the same page in a fresh Edge profile.
3. Open the SkillDock URL by pasting it manually into an already-running Edge.
4. Trigger the SkillDock URL through the Skill/Windows Shell path.
5. Record each result and every `msedge.exe` `0x80000003` or
   `RADAR_PRE_LEAK_64` event. If a browser window is absent or crashes, stop and
   leave the final product verdict pending rather than retrying APIs.

## Uninstall and residue

1. Stop the Runtime and confirm its health endpoint is unavailable.
2. Run the default Runtime uninstaller.
3. Run `Uninstall PCHW Skill.ps1` with `-PurgeBackups` only for a disposable
   acceptance profile.
4. Confirm no active Runtime directory, Runtime pointer, PCHW Skill, launcher,
   Node child, or RC test fixture remains.
5. Confirm intentional data/backup retention when purge flags are not used.
6. Record every remaining process and path, including why it is expected.

## Pass criteria

- Every step passes with recorded evidence.
- No API/headless browser substitutes for the user-facing Edge check.
- No submit, analysis, or permission-decision API substitutes for the user's
  page clicks.
- The browser path preserves ordinary-Edge, clean-Edge, manual-URL, and
  Windows-Shell evidence separately.
- No real Codex Thread is created solely for packaging or installation tests.
- No test runner, mock adapter, development route, or DSH entry is exposed.
- No BIOS, firmware, driver, clock, voltage, power, fan, memory-timing, or OS
  setting is changed.
- No secret, personal path, Task payload, or runtime token appears in the ZIP.

Until this checklist passes, the artifact remains an RC and cannot be called a
formally released Windows product.
