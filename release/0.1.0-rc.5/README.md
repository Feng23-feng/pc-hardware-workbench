# SkillDock / PCHW 0.1.0-rc.5

Status: **local release candidate; not released**.

This candidate combines SkillDock application `0.1.0-rc.5` with the packaged
PC Hardware Workbench Skill `2.9.0`. It is not a production release, has not
replaced the public `0.1.0-rc.4` test build, and does not switch the formal
default entry or enable default traffic.

The only user path is conversation-triggered: the user asks a hardware question
in the current Codex conversation, consents to the graphical workspace, and the
installed Skill opens SkillDock with the current Task context. The package does
not expose a manual development launcher, runner script, mock data adapter, DSH
entry, or test runner as a user path.

The `pchw-source-hosted` SkillDock panel remains Codex-only. DSH and other
hosts may install `pc-hardware-workbench` and use its chat, collection, and
CSV-analysis capabilities, but this panel is not promised there.
`launch-panel.ps1` requires `CODEX_THREAD_ID` and returns
`thread_binding_missing` without it. See [SUPPORT-MATRIX.md](SUPPORT-MATRIX.md).

SkillDock no longer hard-codes PCHW `2.8.0` as the only accepted version.
The current compatibility policy is:

- PCHW `2.8.0` without a surface contract is accepted through the exact legacy
  compatibility bridge.
- Every PCHW version after `2.8.0` must declare
  `surface_contracts["pchw-source-hosted"]`.
- Contract `1.x` must be at least `1.0.0`, satisfy its
  `min_skill_version`, and provide every
  `required_capabilities` entry.
- Contract major `2` and later is rejected until SkillDock adds an explicit
  compatibility adapter.
- If no active compatible manifest is loaded, SkillDock fails closed instead
  of falling back to the compatibility chat fixture.

## Candidate package

```text
dist/SkillDock-PCHW-0.1.0-rc.5-win-x64.zip
dist/SkillDock-PCHW-0.1.0-rc.5-win-x64.zip.sha256
dist/SkillDock-PCHW-0.1.0-rc.5-win-x64-user.zip
dist/SkillDock-Runtime-0.1.0-rc.5-win-x64.zip
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
| RC package build and hash verification | PASS |
| Integrated user package two-install retention gate | PASS |
| Runtime-only package inventory and retention gate | PASS |
| Clean Windows profile/VM install and uninstall | PENDING |
| User release signoff | PENDING |
| Source state | LOCAL RC PREPARATION |
| Tag / upload / formal stable publish | NOT PERFORMED |

Read [RELEASE-NOTES.md](RELEASE-NOTES.md),
[KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md),
[INSTALL.md](INSTALL.md), and
[CLEAN-WINDOWS-ACCEPTANCE.md](CLEAN-WINDOWS-ACCEPTANCE.md) before using the
candidate.
