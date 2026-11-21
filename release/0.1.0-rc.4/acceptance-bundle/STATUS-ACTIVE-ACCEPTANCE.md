# Active clean-Windows acceptance payload

Status: **ACTIVE / CLEAN-WINDOWS ACCEPTANCE PENDING**

Current RC:

```text
identity: OUTER-BUNDLE-INFO.json + adjacent .sha256 sidecar
state:    clean-local-committed-clean-windows-pending
```

This package supersedes the earlier manual-fallback RC and adds safe
existing-Skill backup, replacement, idempotency, rollback, and clean bundled
upgrade controls. The source is frozen in a clean local commit; automated
portable regressions pass, while clean Windows user click, default ACL approval,
Edge isolation, restart, uninstall, and signoff remain pending.

Use this package only in a fresh Windows 11 x64 user profile or disposable VM.
Return to the extracted root and double-click `Start-Acceptance.cmd`. Open this
payload's `START-HERE.md` for the complete checklist. Do not upload the whole
directory to a Codex conversation, start SkillDock.exe manually, or create an
extra Codex Thread for the test.

Runtime access denial must return `runtime_access_blocked` or a safe chat
fallback. A writable Public portable data root is fallback evidence only.

The package has not been pushed, tagged, uploaded, or formally released.
