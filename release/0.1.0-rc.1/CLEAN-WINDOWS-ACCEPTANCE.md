# Clean-Windows acceptance for 0.1.0-rc.1

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

1. Extract the RC ZIP to a new local directory.
2. Run `Install PCHW Skill.ps1`.
3. Confirm the installed Skill subset matches the PCHW tree hash and file count
   recorded in the package's `RC-MANIFEST.json`.
4. Run the installed Skill validator from the Codex tool environment.
5. Run `Install SkillDock Runtime.ps1`.
6. Confirm exactly one active `Runtime-*` directory and a valid
   `runtime-location.json`, with version `0.1.0-rc.1`.
7. Confirm the bundled Node reports `v24.22.1`.
8. Confirm default traffic and the formal default entry are still off/closed.

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
8. Verify the answer card, verified SVG, supports/conflicts/context,
   uncertainty, low-risk actions, and both copy actions.
9. Restart the same Runtime, reopen the same Task, and compare Task count,
   phase, panel hash, artifact ID, and artifact SHA-256.

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
- No real Codex Thread is created solely for packaging or installation tests.
- No test runner, mock adapter, development route, or DSH entry is exposed.
- No BIOS, firmware, driver, clock, voltage, power, fan, memory-timing, or OS
  setting is changed.
- No secret, personal path, Task payload, or runtime token appears in the ZIP.

Until this checklist passes, the artifact remains an RC and cannot be called a
formally released Windows product.
