# SkillDock Skill integration

`launch-panel.ps1` is the Skill-side entry point for the primary
Skill-triggered user experience. It ensures the local runtime is running and
returns a compact JSON result without exposing the runtime capability token.

```powershell
.\launch-panel.ps1 -Workspace "C:\Users\example\project"
```

The default runtime location is:

```text
%LOCALAPPDATA%\SkillDock\Runtime\SkillDock.exe
```

For development, set `SKILLDOCK_LAUNCHER` to the portable test EXE. The script
also writes no runtime state into the installed Skill directory.
