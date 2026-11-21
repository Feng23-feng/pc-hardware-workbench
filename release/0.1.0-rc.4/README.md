# SkillDock / PCHW 0.1.0-rc.4

Status: **local release candidate; not uploaded; not a stable release**.

This local candidate combines SkillDock application `0.1.0-rc.4` with the packaged
PC Hardware Workbench Skill `2.8.0`. It is not a production release and does
not switch the formal default entry or enable default traffic.

The only user path is conversation-triggered: the user asks a hardware question
in the current Codex conversation, consents to the graphical workspace, and the
installed Skill opens SkillDock with the current Task context. The package does
not expose a manual development launcher, runner script, mock data adapter, DSH
entry, or test runner as a user path.

This version promises the `pchw-source-hosted` SkillDock panel only under Codex.
DSH and other hosts may install `pc-hardware-workbench` and use its chat,
collection, and CSV-analysis capabilities, but must not be told that this
SkillDock panel is available there. `launch-panel.ps1` requires
`CODEX_THREAD_ID` and returns `thread_binding_missing` without it. See
[SUPPORT-MATRIX.md](SUPPORT-MATRIX.md).

## Candidate package

```text
dist/SkillDock-PCHW-0.1.0-rc.4-win-x64.zip
dist/SkillDock-PCHW-0.1.0-rc.4-win-x64.zip.sha256
dist/SkillDock-PCHW-0.1.0-rc.4-win-x64-user.zip
dist/SkillDock-Runtime-0.1.0-rc.4-win-x64.zip
```

The adjacent `.sha256` sidecar and verification JSON are authoritative for the
exact archive bytes and digest. The builder rejects replacement of an existing
candidate. Historical packages belong under `dist/archive/` and must not be
treated as the current candidate.

The verified package also contains `docs/COMPONENT-MATRIX.md` as the canonical
version, asset, host, and evidence matrix.

## Current gates

| Gate | State |
| --- | --- |
| PCHW R7 current-user-Thread FINAL-EFFECT | PASS |
| Automated visible-Edge P1 regression | PASS |
| Clean Windows user click / restart | PENDING |
| Default Runtime ACL approval | PENDING |
| Edge isolation matrix | PENDING |
| Source and installed PCHW identity | PASS |
| Static/full regression at R7 | PASS |
| RC package build and hash verification | Produced by this release-prep batch |
| Integrated user package two-install retention gate | PASS |
| Runtime-only package inventory and retention gate | PASS |
| Clean Windows profile/VM install and uninstall | PENDING |
| User release signoff | PENDING |
| Source state | LOCAL UNCOMMITTED CANDIDATE |
| Tag / upload / formal stable publish | NOT PERFORMED / NO STABLE RELEASE |

Read [RELEASE-NOTES.md](RELEASE-NOTES.md),
[KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md),
[INSTALL.md](INSTALL.md), and
[CLEAN-WINDOWS-ACCEPTANCE.md](CLEAN-WINDOWS-ACCEPTANCE.md) before using the
candidate.
