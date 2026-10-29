# Contributing

## Before opening an issue

- Confirm the problem is reproducible.
- Remove serial numbers, usernames, private paths, account names, and unrelated
  hardware history.
- Share focused logs or synthetic examples instead of a complete raw telemetry
  dump when possible.
- State the Skill, collector, analyzer, Windows, and tool versions.

## Development setup

Requirements:

- Windows PowerShell 5.1 or PowerShell 7;
- Python 3.12 for the structural validator;
- `PyYAML==6.0.3`.

Run the default tests:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\skill\pc-hardware-workbench\tests\run-all-tests.ps1 `
  -SkillRoot .\skill\pc-hardware-workbench

python .\tools\validate-skill.py .\skill\pc-hardware-workbench

powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\portable\start.ps1 -SelfTest

powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\tools\check-portable-sync.ps1
```

Live collector tests require explicit authorization:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\skill\pc-hardware-workbench\tests\run-all-tests.ps1 `
  -SkillRoot .\skill\pc-hardware-workbench `
  -AllowLiveCollector -CollectorPrivacyMode Redacted
```

## Pull requests

- Keep one logical change per pull request.
- Add a regression test for behavior changes.
- Preserve user-controlled application of hardware settings.
- Do not add telemetry, analytics, network upload, or hidden collection.
- Do not bundle third-party installers unless redistribution rights are clear.
- By submitting a contribution, you agree that it may be distributed under the
  repository's MIT License.
- Update the changelog for user-visible behavior changes.
- Run the non-live suite and structural validator before requesting review.
- Run the portable sync check after changing any shared collector, telemetry, or
  native helper file. Use its `-Fix` switch only for an intentional one-way
  `Skill -> Portable` synchronization. `-Fix` refuses to run inside CI.

Changes that affect safety gates, privacy redaction, path handling, firmware
guidance, or hardware settings require review against the manual acceptance
scenarios.

## Commit content

Never commit:

- serial numbers or machine-specific identifiers;
- raw telemetry containing personal paths or account data;
- credentials, tokens, API keys, or local configuration;
- generated reports, ZIP archives, or private release evidence.
