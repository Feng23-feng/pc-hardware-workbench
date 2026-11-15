# Windows launcher

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
