# SkillDock clean-Windows acceptance payload

Return to the extracted `SkillDockRC` root and double-click
`Start-Acceptance.cmd`. This payload directory is internal support material and
is not the primary entry. The controller runs, in order:

```text
99-Validate-Bundle.ps1
00-Preflight.ps1
01-Install.ps1
```

The controller stops at the first non-zero exit code, prints the failed stage,
and writes:

```text
evidence\acceptance-start-result.json
evidence\acceptance-start-<timestamp>-<id>\acceptance-start.log
```

The granular numbered scripts remain available for diagnosis and advanced use.
They are not the primary acceptance flow.

If this Windows profile already has an older PCHW Skill or SkillDock Runtime,
use `Start-Upgrade.cmd` in this payload directory instead. It runs the same
validation and install stages with existing-install policy enabled:

```text
99-Validate-Bundle.ps1
00-Preflight.ps1 -AllowExistingInstall
01-Install.ps1 -UpgradeExisting
```

The existing PCHW Skill is moved to
`.codex\skills\.skilldock-backups` before replacement. Installation validates
the new tree and restores the old Skill if installation fails.

This bundle is an RC acceptance harness, not a public release. The pinned RC
filename, byte count, and SHA-256 are recorded in `OUTER-BUNDLE-INFO.json`; the
adjacent `.sha256` sidecar and verification JSON are authoritative.
