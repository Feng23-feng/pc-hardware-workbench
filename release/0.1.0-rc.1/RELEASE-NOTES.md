# Release notes: 0.1.0-rc.1

Date: 2026-11-17 (+08:00)

Status: **release candidate; not released**

## Identity

| Layer | Version |
| --- | --- |
| SkillDock application | `0.1.0-rc.1` |
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
installation subset hash separately in `RC-MANIFEST.json`.

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

For reference only: parameters related to hardware controls must put safety
first, and all hardware changes remain manual user actions outside this release.

## Release conditions still open

1. Install, use, restart, and uninstall from a clean Windows profile or VM.
2. Verify no leftover Runtime process, installed Skill, pointer, or test
   fixture remains after acceptance cleanup.
3. Review the final ZIP inventory and hashes.
4. Obtain explicit user approval before any commit, tag, push, upload, or
   public release.
