# Install and uninstall 0.1.0-rc.7

## Requirements

- Windows 11 x64.
- Codex Desktop for the conversation-triggered panel.
- Microsoft Edge for the verified browser path.
- An installed PCHW `2.9.3` package for the integrated test build.

## Verify

```powershell
$archive = Resolve-Path .\SkillDock-PCHW-0.1.0-rc.7-win-x64.zip
$expected = ((Get-Content "$archive.sha256" -Raw).Split()[0]).ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw "SHA-256 mismatch" }
```

## Integrated user package

1. Extract the complete `SkillDock-PCHW-0.1.0-rc.7-win-x64-user.zip`.
2. Double-click `Install.cmd`.
3. Wait for installation to finish, then reopen Codex.
4. Invoke `$pc-hardware-workbench` from the current Codex conversation.

The installer backs up an existing PCHW Skill before replacement and restores it
when installation or Runtime verification fails.

## Runtime-only package

Use `SkillDock-Runtime-0.1.0-rc.7-win-x64.zip` only when a compatible PCHW Skill
is already installed. The Runtime validates the active Skill manifest, contract,
UI schema, event schema, and required capabilities before accepting the panel.

## Uninstall

Run `Uninstall.cmd` from the installed package. The default path preserves Task
data, evidence, exports, shared Node engines, and rollback backups. Explicit
full cleanup is separate and requires confirmation.
