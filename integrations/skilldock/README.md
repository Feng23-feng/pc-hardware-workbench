# SkillDock Skill integration

`launch-panel.ps1` is the Skill-side entry point for the primary
Skill-triggered user experience. It ensures the local runtime is running and
returns a compact JSON result without exposing the runtime capability token.

```powershell
.\launch-panel.ps1 -Workspace "C:\Users\example\project"
```

Pass a compact main-chat context at launch:

```powershell
.\launch-panel.ps1 `
  -Workspace "C:\Users\example\project" `
  -ChatContextFile "C:\Users\example\AppData\Local\Temp\skilldock-chat-context.json"
```

Pull surface-side messages and the current result back into chat:

```powershell
.\sync-panel.ps1 `
  -ChannelId "chat:thread-id:task-id" `
  -AfterSequence 0
```

The default runtime location is:

```text
%LOCALAPPDATA%\SkillDock\runtime-location.json
```

The pointer resolves to the newest versioned runtime directory. A legacy
`%LOCALAPPDATA%\SkillDock\Runtime\SkillDock.exe` is used as a fallback.

For development, set `SKILLDOCK_LAUNCHER` to the portable test EXE. The script
also writes no runtime state into the installed Skill directory.
