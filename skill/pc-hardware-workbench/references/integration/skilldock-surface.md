# SkillDock-triggered surface

Read this reference only when the current host has installed SkillDock Runtime
and the Task would materially benefit from a graphical surface. Do not launch it
for a simple concept answer or a one-turn text response.

## User-facing intent

The user should not need to mention scripts, `channel_id`, `cursor`, or a JSON
file. Recognize natural phrases such as:

- “打开 SkillDock”, “打开操作面板”, or “用 SkillDock 继续”;
- “把这个任务放到工作台”;
- “把结果放到面板里”;
- “同步面板” or “把面板里的结果拿回来”.

For an explicit launch phrase, perform the mechanical steps below yourself and
return the URL, Task identity, and current next action. For an explicit return
phrase, retrieve the incremental panel state and continue the Task. When a
complex Task would clearly benefit but the user did not ask, ask once:
“这个任务要不要打开操作面板继续？”

Do not reconstruct the Runtime launch by reading `runtime-location.json`,
starting `SkillDock.exe` directly, or creating an equivalent PowerShell command.
Resolve `scripts/skilldock/launch-panel.ps1` from this installed Skill root and
run that script. If a healthy Runtime already exists for the current workspace,
the script connects through loopback without starting or rewriting it.

The PCHW source-hosted profile is bound to the current Codex Thread. Do not
create, fork, attach, or resume another Thread for a launch or acceptance run.
The current `CODEX_THREAD_ID` is the canonical source Session reference; a
ChatContextFile that names a different source Session must fail closed with
`thread_binding_mismatch`. Reopening the same Task from another environment
Thread is also rejected.

## Entry

Use the current Agent workspace, not the installed Skill directory. Resolve the
workspace to an absolute existing directory, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/launch-panel.ps1 `
  -Workspace "<absolute-workspace>" `
  -ChatContextFile "<private-temp-chat-context.json>" `
  -SurfaceProfile pchw-source-hosted `
  -SurfaceMode read-only
```

The script starts or reuses one loopback runtime and returns compact JSON:

```json
{
  "ok": true,
  "url": "http://127.0.0.1:12345/source-hosted/open?token=<short-lived>",
  "workspace": "C:\\path\\to\\workspace",
  "driver": "source-external",
  "task_ref": "task-...",
  "channel_id": "chat:source-hosted:<source-session>",
  "source_session_ref": "<source-session>",
  "cursor": 0,
  "runtime_state": "running-current-workspace",
  "surface_mode": "read-only",
  "agent_permission": {
    "sandbox": "read-only",
    "approvalPolicy": "never",
    "source": "safe-default"
  },
  "permission_matrix": {
    "schema_version": "1.0",
    "states": [
      { "id": "runtime_launch", "status": "active-current-workspace" },
      { "id": "local_file_read", "status": "approval-required" },
      { "id": "task_artifact_write", "status": "approval-required" },
      { "id": "workspace_write", "status": "blocked" },
      { "id": "external_network", "status": "disabled" },
      { "id": "hardware_control", "status": "manual-only" }
    ]
  },
  "approval_decision_supported": false,
  "limitations": ["Host approval decisions are unavailable in this driver."],
  "error_code": "",
  "fallback_reason": "",
  "error": ""
}
```

Give the user the returned local URL and state that the operation panel is open.
Do not expose capability tokens, cookies, handoff secrets, or provider
credentials.

`SurfaceMode` accepts `read-only`, `interactive`, or `developer`. Omit the
parameter to use `read-only`. A pure chat response does not call this script.

`SurfaceProfile` defaults to `pchw-source-hosted`. Do not ask the user to set
environment variables or test flags; the script configures the intended local
runtime profile internally.

For a CSV/chart Task, stay in the same conversation Agent turn and wait for the
panel-side local analysis instead of asking the user to send “同步面板”:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/wait-panel.ps1 `
  -ChannelId "<returned-channel-id>" `
  -SourceSessionRef "<returned-source-session>" `
  -ExpectedTaskId "<returned-task-id>" `
  -ExpectedAttachmentId "<submitted-attachment-id>" `
  -ExpectedAttachmentSha256 "<submitted-csv-sha256>" `
  -ExpectedSubmissionSequence <timeline-sequence> `
  -ExpectedIntentEventId "<source-submission-event-id>" `
  -TimeoutSeconds 180
```

The script polls `/api/task/sync/export` with the source credential. Export is
strictly read-only and never advances the shared phase. After the
`source_tool_result` attachment, SHA-256, evidence and creation time bind to the
expected submission, the script calls the explicit, idempotent
`POST /api/task/sync/claim` operation once. Only that successful claim advances
`waiting_for_source_pull` to `source_agent_pulled`. Previous results, timeout,
and repeated polling remain read-only and return `ready:true` only after the
claim succeeds. Analyze that verified local result, write the panel result back,
then reply in chat. If it returns `panel_wait_timeout`, continue in chat and tell
the user they can say “同步面板” later. Never claim the panel finished when the
wait timed out.

Source-hosted submissions are allowed only in `source_owned`,
`waiting_for_source_pull`, or `source_result_synced`. For
`source_agent_pulled`, the page must lock upload/submit/analyze/permission
actions and offer an explicit same-Task recovery. Recovery archives the stuck
cycle, preserves Task attachments/artifacts/timeline/source result, clears the
active draft projection, increments `cycle_generation`, and returns to
`source_owned`. It never creates a Task or Thread.

The server and preflight reject other phases with `phase_not_submittable`
before a Runtime launch or draft upload.

If the running surface mode differs from the requested mode, stop or restart
the runtime before changing modes. Do not report the requested mode if the
health response reports a different one.

When SkillDock already belongs to another workspace, the launcher refuses to
stop it by default. Use `-ReplaceWorkspace` only after the user explicitly
accepts interrupting that runtime:

```powershell
-ReplaceWorkspace
```

## Chat context handoff

Write a compact private JSON file, not a full transcript export:

```json
{
  "schema_version": "1.0",
  "channel_id": "chat:<source-thread>:<stable-task-id>",
  "source_session_ref": "<source-thread-or-session>",
  "objective": "<one bounded objective>",
  "summary": "<current decision, uncertainty, and next action>",
  "attachments": [
    {
      "path": "<private-local-file>",
      "name": "<display-name.csv>",
      "mime_type": "text/csv",
      "source_attachment_id": "chat-file:<stable-content-id>"
    }
  ],
  "messages": [
    {
      "id": "<stable-message-id>",
      "role": "user",
      "text": "<relevant message>",
      "created_at": "<ISO-8601>"
    }
  ]
}
```

Use at most 40 relevant messages. Prefer the current judgement and the few
messages that determine it over a complete log. Keep `channel_id` stable for the
same chat Task. Duplicate message IDs are ignored by the host.

At most eight current-conversation attachments may be listed. The launcher
validates extension and size, uploads them to the Task draft, and never sends the
private absolute path to the panel surface. The user can review the prefilled
attachments before submitting.

Attachment upload is idempotent by `source_attachment_id` plus SHA-256. Omitting
`source_attachment_id` lets the launcher derive a stable identifier from the
file content. Reopening the same Task reuses the existing attachment instead of
adding a second card.

## When to launch

Use a surface when at least one of these is true:

- several evidence items or comparisons need a table;
- a verified CSV chart or artifact download is central;
- an experiment needs a multi-field card, pass/abort status, or recovery view;
- the user needs repeated structured choices that would be cumbersome in chat;
- the Task already has a Resume Packet and must continue in another view.

Keep chat when the answer is explanatory, a single action, or a small private
question. The interface is optional presentation; it never grants permission.

## Continuity and failure

Do not rerun the device collector, repeat intake, or reanalyze unchanged evidence
merely because the surface opened. Reuse the Task, device reference, evidence
hashes, current judgement, uncertainty, and priority action.

An independent panel-owned Agent Session is not the same provider Thread. State
that limitation when native attachment is unavailable. If the launcher returns
`ok: false`, continue in chat with the returned error and one recovery action.
Never claim the graph is open when no URL was returned.

Use `error_code` only to choose a safe recovery path. Do not expose environment
variable names, runner details, capability tokens, or stack traces to the user.
For `runtime_missing`, offer to continue in chat or install the SkillDock Runtime.
For `workspace_conflict` or `surface_profile_unavailable`, keep the current chat
and explain that another local workspace/profile is active. Never force a stop.
For `thread_binding_mismatch`, `thread_binding_missing`, or
`thread_rebinding_forbidden`, stop the launch and stay in the current Codex
Thread; never create or switch Threads as a workaround.

If a source-hosted Task is in a recoverable error state, the panel exposes
“恢复当前 Task”. That action keeps the same Task and Thread, archives the error
state, collapses duplicate attachment projections, and returns the Task to a
retryable phase. Use it before asking for any new acceptance run. Do not replace
the current Task or Thread solely to get past an error page.

The launcher's `agent_permission` is the effective Agent sandbox. It is not a
Task capability grant and does not authorize SkillDock-local actions. A false
`approval_decision_supported` means an `on-request` profile cannot be promised
even if the underlying CLI supports approval flags.

`permission_matrix` is a public status projection, not a grant. It reports
Runtime launch, selected-file read, Task artifact write, Agent workspace write,
external network, and manual-only hardware boundaries independently. In
particular, an Agent `workspace-write` profile does not grant SkillDock an
independent workspace-write permission, and a disabled SkillDock external
network does not prove that the Agent host has disabled its own network access.

## Returning to chat

When the user returns to chat after using the surface, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/sync-panel.ps1 `
  -ChannelId "<same-channel-id>" `
  -AfterSequence <last-seen-cursor> `
  -SurfaceProfile pchw-source-hosted `
  -SourceSessionRef "<same-source-session>" `
  -ExpectedTaskId "<same-task-id>" `
  -ExpectedAttachmentId "<same-attachment-id>" `
  -ExpectedAttachmentSha256 "<same-csv-sha256>" `
  -ExpectedSubmissionSequence <same-submission-sequence> `
  -ExpectedIntentEventId "<same-intent-event-id>"
```

`sync-panel.ps1` uses the same read-only export and freshness checks, then the
same explicit claim. It rejects a missing or stale result with
`panel_sync_not_ready`, `panel_sync_stale_result`, or
`panel_sync_contract_mismatch`. It never re-wraps an old result as fresh, and a
duplicate claim with the same Task, intent, submission sequence, attachment,
SHA-256, and result requirement returns an idempotent success without appending
another phase event.

Use the returned `messages`, `panel`, `summary`, `cursor`, unresolved question,
and safe artifact refs to continue the same Task. State that this is a Task
ledger synchronization, not native attachment to the provider Thread.

Treat `cursor`, `channel_id`, `task_ref`, `panel`, and the panel component tree
as internal synchronization data. Never paste the raw JSON or component tree
into the conversation. Prefer `display_summary`, then reply in natural language
with only:

1. “已同步面板结果”；
2. the current judgement or turn summary;
3. the unresolved question or uncertainty;
4. one concrete next action.

If no new messages were returned, say the conversation and panel are already in
sync and continue with the current next action. Do not end with a JSON code
block or resume the whole task from scratch.

When `source_tool_result` is present, treat its local analysis, warnings, window,
and public artifact metadata as verified local evidence. Produce one PCHW panel
JSON object using the active UI schema, write it to a private temp file, then
write the result back to the surface:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/submit-panel-result.ps1 `
  -ChannelId "<same-channel-id>" `
  -SourceSessionRef "<same-source-session>" `
  -PanelFile "<private-panel-result.json>" `
  -MessageText "<short user-facing conclusion>" `
  -Objective "<current objective>" `
  -Summary "<current turn summary>"
```

Do not call `submit-panel-result.ps1` with forged chart artifact references.
The SkillDock server merges the verified local chart with the Agent conclusion.
After success, tell the user the panel result is ready; do not expose the JSON or
runtime credentials.
