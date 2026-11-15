# SkillDock-triggered surface

Read this reference only when the current host has installed SkillDock Runtime
and the Task would materially benefit from a graphical surface. Do not launch it
for a simple concept answer or a one-turn text response.

## Entry

Use the current Agent workspace, not the installed Skill directory. Resolve the
workspace to an absolute existing directory, then run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File scripts/skilldock/launch-panel.ps1 `
  -Workspace "<absolute-workspace>"
```

The script starts or reuses one loopback runtime and returns compact JSON:

```json
{
  "ok": true,
  "url": "http://127.0.0.1:12345/",
  "workspace": "C:\\path\\to\\workspace",
  "driver": "dsh-web",
  "error": ""
}
```

Give the user the returned local URL and state that the operation panel is open.
Do not expose capability tokens, cookies, handoff secrets, or provider
credentials.

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
