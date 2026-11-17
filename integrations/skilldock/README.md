# SkillDock Skill integration

`launch-panel.ps1` is the Skill-side entry point for the primary
Skill-triggered user experience. It ensures the local runtime is running and
returns a compact JSON result without exposing the runtime capability token.
The default `pchw-source-hosted` profile configures the internal runtime
profile itself, creates a short-lived source-hosted entry URL, and returns the
Task and channel references. Users do not set environment variables or test
flags.

For `pchw-source-hosted`, the current `CODEX_THREAD_ID` is the canonical source
Session. The launcher fails closed with `thread_binding_missing` or
`thread_binding_mismatch` when that identity is absent or differs from the
ChatContextFile. A Task cannot be reopened from another environment Thread.

`ChatContextFile.attachments` may reference up to eight current-conversation
files. The launcher validates and uploads them into the Task draft before opening
the panel; absolute local paths are not exposed to the browser. Each upload
carries a `source_attachment_id`; the runtime deduplicates by that identity plus
SHA-256 so re-opening a Task does not append duplicate content.

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
  -AfterSequence 0 `
  -SurfaceProfile pchw-source-hosted `
  -SourceSessionRef "<source-session-ref>" `
  -ExpectedTaskId "<task-id>" `
  -ExpectedAttachmentId "<attachment-id>" `
  -ExpectedAttachmentSha256 "<64-char-sha256>" `
  -ExpectedSubmissionSequence 12 `
  -ExpectedIntentEventId "<source-submission-event-id>"
```

`wait-panel.ps1` uses the same freshness anchors. A previously completed
`source_tool_result` is ignored until its attachment, SHA-256, evidence
reference, and creation time all bind to the specified submission. Timeout and
sync paths cannot return a stale prior result. Export polling is read-only;
after freshness is verified, both scripts call the explicit idempotent
`POST /api/task/sync/claim` operation. A duplicate claim with the same anchor
tuple does not append another phase event.

When the sync result contains a verified local tool result, write the generated
panel result back through the source credential:

```powershell
.\submit-panel-result.ps1 `
  -ChannelId "chat:source-hosted:<source-session-ref>" `
  -SourceSessionRef "<source-session-ref>" `
  -PanelFile "<private-panel-result.json>" `
  -MessageText "<short user-facing conclusion>"
```

If runtime launch fails, `launch-panel.ps1` returns `ok=false`,
`error_code`, and `fallback_reason`. The Skill continues in chat instead of
asking the user to configure environment variables.

For a recoverable source-hosted error, the panel keeps the same Task and Thread,
offers “恢复当前 Task”, archives the error state, and collapses duplicate
attachment projections. Recovery never creates a replacement Thread.

The default runtime location is:

```text
%LOCALAPPDATA%\SkillDock\runtime-location.json
```

The pointer resolves to the newest versioned runtime directory. A legacy
`%LOCALAPPDATA%\SkillDock\Runtime\SkillDock.exe` is used as a fallback.

For development, set `SKILLDOCK_LAUNCHER` to the portable test EXE. The script
also writes no runtime state into the installed Skill directory.
