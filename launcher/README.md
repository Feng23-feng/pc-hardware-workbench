# Windows development launcher

This launcher is a development and diagnostic entry. The product workflow is for
an installed Skill to start or reuse the runtime automatically; users should not
need to launch this EXE manually. See
[../SKILL-TRIGGERED-UX.md](../SKILL-TRIGGERED-UX.md).

The first Windows test package wraps the existing local Node application. The
launcher selects a free loopback port, starts `app/server.mjs` with the bundled
Node runtime, waits for health, and opens the default browser.

Build the DSH test package with Windows PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\launcher\build-dsh-package.ps1
```

The package is written under `dist/SkillDock-DSH`. It uses the existing DSH
installation at `C:\dsh` and the user's DSH home at `%USERPROFILE%\.dsh`.
It does not read or copy the DSH API key or browser cookie.

Install the built runtime once per user:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\launcher\install-runtime.ps1
```

This installs a versioned runtime and atomically updates the runtime pointer:

```text
%LOCALAPPDATA%\SkillDock\Runtime-<version>-<timestamp>\
%LOCALAPPDATA%\SkillDock\runtime-location.json
```

An update never overwrites a running EXE. The previous runtime directory remains
available for rollback until explicitly cleaned.

`SkillDock.exe --ensure --workspace <path>` is idempotent. It reuses the healthy
instance for the same workspace and writes a token-free
`%LOCALAPPDATA%\SkillDock\launch-result.json` containing the local URL. The
Skill-facing wrapper in `integrations/skilldock/launch-panel.ps1` consumes that
result.

The launcher accepts `--workspace <path>` to make the Agent Session belong to a
specific DSH workspace. Without the argument it uses
`%USERPROFILE%\Documents\deepseek-harness\default-workspace` when that directory
exists, then falls back to `%USERPROFILE%\Documents\Codex`.
