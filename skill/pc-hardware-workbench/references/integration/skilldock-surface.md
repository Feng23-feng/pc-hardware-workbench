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

## Entry

Use the current Agent workspace, not the installed Skill directory. Resolve the
workspace to an absolute existing directory, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/launch-panel.ps1 `
  -Workspace "<absolute-workspace>" `
  -ChatContextFile "<private-temp-chat-context.json>"
```

The script starts or reuses one loopback runtime and returns compact JSON:

```json
{
  "ok": true,
  "url": "http://127.0.0.1:12345/",
  "workspace": "C:\\path\\to\\workspace",
  "driver": "dsh-web",
  "task_ref": "task-...",
  "cursor": 2,
  "error": ""
}
```

Give the user the returned local URL and state that the operation panel is open.
Do not expose capability tokens, cookies, handoff secrets, or provider
credentials.

## Chat context handoff

Write a compact private JSON file, not a full transcript export:

```json
{
  "schema_version": "1.0",
  "channel_id": "chat:<source-thread>:<stable-task-id>",
  "source_session_ref": "<source-thread-or-session>",
  "objective": "<one bounded objective>",
  "summary": "<current decision, uncertainty, and next action>",
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

## Returning to chat

When the user returns to chat after using the surface, run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/sync-panel.ps1 `
  -ChannelId "<same-channel-id>" `
  -AfterSequence <last-seen-cursor>
```

Use the returned `messages`, `panel`, `summary`, `cursor`, unresolved question,
and safe artifact refs to continue the same Task. State that this is a Task
ledger synchronization, not native attachment to the provider Thread.
