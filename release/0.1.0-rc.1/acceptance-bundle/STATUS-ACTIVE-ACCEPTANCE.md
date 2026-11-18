# Active clean-Windows acceptance payload

Status: **ACTIVE / CLEAN-WINDOWS ACCEPTANCE PENDING**

Current RC:

```text
archive: SkillDock-PCHW-0.1.0-rc.1-win-x64-p1fix-safe-upgrade-local-candidate-20261118.zip
bytes:   36756757
SHA-256: 469a6f3e39c567d58fc78ab58ca0d8de7e9aa30231c67acaf4f02a2c8c038d3c
state:   local-candidate-clean-ui-pending
```

This package supersedes the earlier manual-fallback RC and adds safe
existing-Skill backup, replacement, idempotency, rollback, and clean bundled
upgrade controls. The local source is uncommitted; automated portable
regressions pass, while clean Windows user click, default ACL approval, Edge
isolation, restart, uninstall, and signoff remain pending.

Use this package only in a fresh Windows 11 x64 user profile or disposable VM.
Return to the extracted root and double-click `Start-Acceptance.cmd`. Open this
payload's `START-HERE.md` for the complete checklist. Do not upload the whole
directory to a Codex conversation, start SkillDock.exe manually, or create an
extra Codex Thread for the test.

Runtime access denial must return `runtime_access_blocked` or a safe chat
fallback. A writable Public portable data root is fallback evidence only.

The package has not been committed, pushed, tagged, uploaded, or formally
released.
