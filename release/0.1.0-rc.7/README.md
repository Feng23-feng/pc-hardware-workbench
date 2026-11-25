# SkillDock / PCHW 0.1.0-rc.7

Status: **public test build; not a stable release**.

This test build combines SkillDock application `0.1.0-rc.7` with the packaged PC
Hardware Workbench Skill `2.9.3`. It supersedes `0.1.0-rc.6` as the current
public test build and does not enable the formal default entry, default traffic,
background write, coordinator recovery, or automatic hardware changes.

## What changed

- SkillDock now uses the Graphite Copper × Cobalt Archive visual system.
- The verified Runtime binding is a quiet disclosure strip; PID, port, Task, and
  launch identifiers are available on demand.
- PCHW `uncertainty[0]` is the single current unresolved subject. SkillDock
  renders that subject and removes it from the later “仍需确认” list.
- Desktop and narrow layouts include explicit 390 px and 320 px overflow gates.

## Public test package

```text
dist/SkillDock-PCHW-0.1.0-rc.7-win-x64.zip
dist/SkillDock-PCHW-0.1.0-rc.7-win-x64.zip.sha256
dist/SkillDock-PCHW-0.1.0-rc.7-win-x64-user.zip
dist/SkillDock-Runtime-0.1.0-rc.7-win-x64.zip
```

The adjacent `.sha256` sidecar and verification JSON are authoritative for the
exact archive bytes and digest.

## Current gates

| Gate | State |
| --- | --- |
| Frozen Node/SQLite check and full automated regression | Verified before release |
| PCHW Skill validator and standalone package verification | Required for this release |
| RC, integrated user, and Runtime-only package verification | Required for this release |
| Visible Edge mock regression | Required for this release |
| Clean Windows installation and uninstallation | PENDING |
| User release signoff | PENDING |
| Formal stable release | NOT PERFORMED |

Read [RELEASE-NOTES.md](RELEASE-NOTES.md),
[KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md),
[INSTALL.md](INSTALL.md),
[SUPPORT-MATRIX.md](SUPPORT-MATRIX.md), and
[CLEAN-WINDOWS-ACCEPTANCE.md](CLEAN-WINDOWS-ACCEPTANCE.md) before using this
test build.
