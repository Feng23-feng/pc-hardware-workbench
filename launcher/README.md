# Windows development launcher

This launcher is a development and diagnostic entry. The product workflow is for
an installed Skill to start or reuse the runtime automatically; users should not
need to launch this EXE manually. See
[../SKILL-TRIGGERED-UX.md](../SKILL-TRIGGERED-UX.md).

The first Windows test package wraps the existing local Node application. The
launcher selects a free loopback port, starts `app/server.mjs` with the bundled
Node runtime, waits for health, and opens the default browser.

Build the Windows release candidate with:

```powershell
pnpm build:win-rc
pnpm verify:win-rc
pnpm build:win-user
pnpm verify:win-user
pnpm build:runtime-only
pnpm verify:runtime-only
```

The candidate is written as
`dist/SkillDock-PCHW-0.1.0-rc.2-win-x64.zip`. The RC builder refuses to replace
an existing candidate, bundles PCHW `2.8.0`, records the exact Git worktree
state, and emits package and archive hashes. The older
`build-dsh-package.ps1` remains the isolated internal-preview fixture used by
the package usability tests.

Integrated user packages must also pass `verify-user-package.ps1`. That gate
unpacks the embedded RC, rejects a Runtime installer that predates backup
retention, and performs clean-then-upgrade installs in isolated temporary roots.
It requires exactly one retained Runtime backup while preserving a Task-data
marker.

Runtime-only assets are derived from the same verified integrated RC with
`build-runtime-package.ps1`; their verifier rejects Skill/docs/test content and
checks the exact manifest and retention-capable installer.

Build the DSH test package with Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\launcher\build-dsh-package.ps1
```

The package is written under `dist/SkillDock-DSH`. It uses the existing DSH
installation at `C:\dsh` and the user's DSH home at `%USERPROFILE%\.dsh`.
It does not read or copy the DSH API key or browser cookie.

For an isolated development build, use unique output and archive paths:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\launcher\build-dsh-package.ps1 `
  -OutputDirectory .\dist\SkillDock-Visual-Interface-0.1.0-dev-20261116 `
  -ArchivePath .\dist\SkillDock-Visual-Interface-0.1.0-dev-20261116.zip
```

The generated package is an internal-preview trial package, not a production
release. Its `README.txt` contains the default-off mock-only launch commands,
the recommended isolated `SkillDockInternalPreview` data root, and the
difference between default-uninstall retention and explicit
`-PurgeUserData -PurgeBackups` cleanup.

Run the ZIP usability gate after changing package contents:

```powershell
pnpm test:internal-preview-usability
```

This builds and extracts the ZIP in isolated temporary roots, rejects a
non-mock preview, checks the default-off entry, starts the mock preview directly
from the extracted package, stops it, and verifies the fixture has no remaining
files or processes. It also enforces an exact 45-file allowlist and writes a
sorted `{path, bytes, sha256}` manifest for every package file.

The packaged launcher can then be tested against isolated Runtime metadata:

```powershell
node .\tests\launcher-isolation.test.mjs `
  .\dist\SkillDock-Visual-Interface-0.1.0-dev-20261116\SkillDock.exe
```

To test through DSH:

```powershell
# Close DeepSeek Harness completely first.
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-DSH-SkillDock-Dev.ps1
```

This launches DSH with the development package and isolated Runtime root. Stop
only the development Runtime with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\Start-DSH-SkillDock-Dev.ps1 -Action stop
```

Install the built runtime once per user:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\launcher\install-runtime.ps1
```

This installs a versioned runtime and atomically updates the runtime pointer:

```text
%LOCALAPPDATA%\SkillDock\engines\node-<version>-<hash>\
%LOCALAPPDATA%\SkillDock\Runtime-<version>-<timestamp>\
%LOCALAPPDATA%\SkillDock\runtime-location.json
```

The Runtime directory contains the launcher and application code but no private
`node\` copy. It records an `engine-location.json` reference to the immutable
shared engine. The launcher verifies the referenced `node.exe` SHA-256 before
starting. A missing, malformed, or changed reference fails closed; it never
falls back to a different system Node.

An update never overwrites a running EXE. The previous runtime directory remains
available for rollback outside the active root:

```text
%LOCALAPPDATA%\SkillDockBackups\runtime\
```

The installer stops a healthy pointed Runtime, moves all old active
`Runtime-*`/`Runtime` program directories to that backup root, and leaves
exactly one active Runtime program directory before updating the pointer. After
the pointer update succeeds, obsolete program backups are rotated to the newest
one by default; `-RetainRuntimeBackups` accepts 1 through 20. Unrelated backup
entries, Runtime data, and data-migration backups are never removed by this
rotation. The Runtime referenced by the previous `runtime-location.json` is
always retained even when its directory timestamp is older than a stale backup.
New-format backups also reference the shared engine, so exporting a rollback
directory for use on another machine requires copying the referenced engine
directory as well. Unreferenced engines are pruned only after all active and
retained Runtime references have been checked successfully.
Cleanup failures are reported but do not turn a successful Runtime installation
into a failure. The canonical user-data root is `runtime-pchw`.

Before creating the new Runtime, the installer checks the legacy
`runtime-dsh-web` data root through `runtime-data-migration.ps1`. If legacy data
exists and the canonical root is unused, `Auto` migration copies the complete
legacy data tree into a verified backup under
`%LOCALAPPDATA%\SkillDockBackups\data`, then activates a verified copy as
`runtime-pchw`. If both data roots contain state, installation fails closed with
`runtime_data_conflict`; no merge is attempted. `-LegacyDataPolicy PreferLegacy`
is the explicit one-source replacement after reviewing the backup plan.

`SkillDock.exe --ensure --workspace <path>` is idempotent. It reuses the healthy
instance for the same workspace and writes a token-free
`%LOCALAPPDATA%\SkillDock\launch-result.json` containing the local URL. The
Skill-facing wrapper in `integrations/skilldock/launch-panel.ps1` consumes that
result. All SkillDock helpers load `runtime-paths.ps1`; current
`launch-result.json` plus `/api/health` `runtime_binding` is authoritative, and
stale `server-info.json` from another data root is ignored.

If a healthy instance belongs to a different workspace, the launcher now refuses
to stop it by default. Repeat the launch with `--replace-workspace` only after
the user explicitly accepts interrupting that runtime:

```powershell
SkillDock.exe --ensure --workspace "<path>" --replace-workspace --silent
```

The launcher accepts `--workspace <path>` to make the Agent Session belong to a
specific DSH workspace. Without the argument it uses
`%USERPROFILE%\Documents\deepseek-harness\default-workspace` when that directory
exists, then falls back to `%USERPROFILE%\Documents\Codex`.

Development-only isolation variables:

- `SKILLDOCK_LOCAL_ROOT` selects a private Runtime metadata and state root.
- `SKILLDOCK_AGENT_DRIVER` selects a Driver; normal packages default to
  `dsh-web`.
- `SKILLDOCK_INTERNAL_PREVIEW=1` enables the gated source-hosted preview
  server entry. It is off by default, requires
  `SKILLDOCK_AGENT_DRIVER=mock`, and does not change the product entry.
- `SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK=1` permits only the controlled
  `source-external` driver for the PCHW real-source acceptance path. That driver
  never owns a panel Thread; the single real Thread is created by the explicit
  source runner. The flag is off by default.
- `SKILLDOCK_DSH_HOME` overrides the DSH home for DSH Drivers.
- `SKILLDOCK_DSH_EXECUTABLE` overrides the DSH executable path.
- `SKILLDOCK_SKILL_ROOTS` overrides the semicolon-separated installed-Skill
  roots for isolated internal preview tests.

Normal users should not need these variables.

The packaged `Uninstall SkillDock.ps1` stops the pointed Runtime and removes
installed program directories and the runtime pointer. User data and backups are
preserved unless `-PurgeUserData` and `-PurgeBackups` are explicitly supplied.
