# Panel, Agent driver, Skill manifest, and provider adapter protocol

## Agent-neutral core

The browser API, Task store, artifact canvas, permission grants, and handoff
contracts are independent of any Agent transport.

Select a driver with:

```powershell
$env:PANEL_AGENT_DRIVER = "codex"  # default
$env:PANEL_AGENT_DRIVER = "dsh"
$env:PANEL_AGENT_DRIVER = "mock"
```

An unsupported value fails before the HTTP listener starts and lists the allowed
drivers.

Stable browser/state contracts use `agent`, `session`, `task`, `surface`,
`artifact`, and `permission`. Provider transport methods are confined to
`lib/agents`.

The neutral interface supports:

- initialize and close;
- thread start/resume with an unsupported-capability result;
- turn submission with streaming lifecycle events and completion;
- cancellation;
- optional thread naming;
- a capability descriptor;
- error classification.

`GET /api/state` exposes a generic `agent` descriptor:

```json
{
  "driver": "codex",
  "displayName": "Codex",
  "connected": true,
  "supportsStreaming": true,
  "supportsThreadResume": true,
  "supportsActiveThreadAttach": false,
  "supportsStructuredOutput": true,
  "supportsApprovals": false
}
```

`driver` and `displayName` are adapter details. The primary UI uses
`Agent 已连接`; provider names appear only inside collapsed task details.

## Portable Workbench Manifest

The runtime accepts one manifest through:

```powershell
$env:PANEL_SKILL_MANIFEST = "C:\path\to\workbench.manifest.json"
$env:PANEL_MANIFEST_ALLOWED_ROOT = "C:\path\to\skill"
$env:PANEL_SKILL_ID = "example.skill"
```

Manifest and declared schema paths must resolve under the allowed root. The
manifest declares generic adapter capabilities rather than provider names.
Missing or invalid metadata falls back to the compatibility manifest and does
not block Task/chat.

`PANEL_SKILL_ROOTS` overrides the standard discovery roots. Explicit paths may
contain multiple manifests separated by the platform path delimiter.

The host dynamically imports only the validated `manifest.runtime.entry`. The
runtime capability allowlist is exactly
`manifest.domain.capabilities[]`; undeclared action ids are rejected.

The UI uses these fields only for display and capability-gated behavior. It does
not inspect Codex protocol methods or fields.

## DSH adapter

DSH uses only:

```text
DeepSeek Harness.exe --expose-internals <cli.js>
  headless --json [--session-id <id>] -
```

The prompt is written to stdin. The adapter parses NDJSON:

- `session`;
- `status`;
- `text`;
- `thinking`;
- `tool_call` / `tool_result`;
- `final`.

Observed DSH capabilities:

| Capability | Value |
| --- | --- |
| Streaming | true, committed `text` events |
| Session resume | true, `--session-id` |
| Active source-session attach | false |
| Native structured output | false |
| Structured compatibility | prompt + JSON parse + schema 1.2 validation |
| Approvals | false |
| Thread naming | false |
| Cancellation | process termination |

The first session event supplies `sessionId`; subsequent turns pass that value to
`--session-id`. The initial panel reference is pending until DSH emits the real
session.

DSH runs with an isolated `DSH_HOME`, `DSH_PERMISSION_MODE=read-only`, telemetry
disabled, and a minimal environment. Panel code does not read the existing
`.dsh` profile or credential files.

Real DSH is currently blocked from a model turn on this machine because
`DEEPSEEK_API_KEY` is absent. The emitted session is persisted and the error is
classified as `auth`. Deterministic `PANEL_DSH_FIXTURE=1` verification covers
session resume and parsing without presenting fixture output as a real model
result.

### DSH Web boundary

DSH Web `0.2.2-rc.3` is a real local API, not a scrape-only UI:

```text
POST /api/<endpoint>       unary Remote RPC
WS   /api/remote.mux       multiplexed event stream
GET  /connect?token=...    API peer and API-cookie exchange
```

Generated endpoints include `session/create`, `session/list`,
`session/prompt`, `session/wait`, `session/follow`, and `session/cancel`.
Unary requests use this envelope:

```json
{
  "type": "client-request",
  "rpcId": "client UUID",
  "method": "session/prompt",
  "payload": {
    "args": {
      "request": {
        "requestId": "client UUID",
        "sessionId": "session ID",
        "mode": "queue",
        "content": [{ "type": "text", "text": "compact panel packet" }]
      }
    }
  }
}
```

There is no Authorization-header token mode. The current page is authenticated
with a host/port-bound `HttpOnly`, `SameSite=Strict` browser cookie. External API
clients must use the separate `/connect` launch-token exchange and keep the API
socket alive.

Those are two different capabilities. The panel process cannot reuse the
browser cookie without reading it through an unsupported channel such as
DevTools or credential storage. Therefore `dsh-web` remains unimplemented and
blocked. An unauthenticated `session/list` request and `/connect` without a
valid launch token both return HTTP 401.

The remainder of this document describes the Codex adapter.

## Browser boundary

The browser and local supervisor communicate only over
`http://127.0.0.1:4319`.

`GET /` sets an HttpOnly, SameSite=Strict capability-token cookie. API requests
must carry that cookie or a bearer token. The token is generated locally under
`runtime/capability-token`; it is not a Codex credential.

Endpoints:

- `GET /api/state` returns thread identity, panel state, draft, and status.
- `POST /api/event` records one local `option_selected` or `evidence_added`
  event and starts no agent turn.
- `POST /api/attachments` copies one whitelisted local file into private runtime
  storage and returns updated draft state.
- `GET /api/attachments/:id/content` serves a local image or text preview.
- `DELETE /api/attachments/:id` removes an unsent draft attachment.
- `POST /api/skill/actions/:id` invokes a manifest-declared local action.
- `POST /api/artifacts/analyze` remains a compatibility alias for the active
  Skill's first matching attachment action.
- `GET /api/artifacts/:id/content` serves a verified text or image artifact.
  `?download=1` switches to an attachment disposition.
- `GET /handoff/open?token=<signed-handoff>` validates and consumes a compact
  current-chat Task Resume Packet, sets the panel capability cookie, and
  redirects to `/`.
- `GET /api/resume-packet` returns a compact, sanitized Resume summary for
  copying back into the source Codex conversation. It creates no turn and calls
  no queue.
- `POST /api/permissions/request` creates a pending request for the exact
  attachment/hash/window. It runs no analysis.
- `POST /api/permissions/decide` records `deny`, `allow_once`, or `allow_task`.
- `POST /api/permissions/revoke` revokes an active grant.
- `POST /api/submit` sends the current draft as one turn.
- `POST /api/task/new` clears the current task view while keeping the current
  Codex thread and shared evidence. The task is created on first submission.
- `POST /api/thread/new` is the advanced independent-dialog action and creates a
  new app-owned thread.
- `POST /api/shutdown` stops the supervisor and its active Agent driver.

## Panel UI state

The canonical schema is
[`schemas/panel-ui-state.schema.json`](schemas/panel-ui-state.schema.json).

```json
{
  "schema_version": "1.2",
  "turn_summary": "Why this question is next",
  "current_goal": "One short objective",
  "status": "needs_input",
  "judgement": "Substantive current interpretation without claiming a hardware fault",
  "question": {
    "id": "slowdown-timing",
    "prompt": "One question",
    "options": [
      {
        "id": "gaming",
        "label": "玩游戏时",
        "description": "Observable context"
      },
      {
        "id": "desktop",
        "label": "日常使用时",
        "description": "Second observable option"
      }
    ],
    "allow_free_text": true
  },
  "recommendation": {
    "summary": "How to choose",
    "option_id": null
  },
  "evidence": [
    {
      "id": "reported-slowdown",
      "label": "User reported slowdown",
      "detail": "What is actually known",
      "source": "user_reported",
      "relation": "supports"
    }
  ],
  "uncertainty": ["What remains unknown"],
  "recommendations": [
    {
      "id": "fixed-scene",
      "title": "Run a fixed-scene retest",
      "detail": "Concrete evidence-collection step",
      "risk": "low",
      "evidence_goal": "What this can distinguish"
    }
  ],
  "priorityAction": {
    "title": "The first next step",
    "detail": "Why it is first"
  },
  "actions": [
    {
      "id": "copy-checklist",
      "label": "Copy checklist",
      "kind": "copy",
      "content": "Whitelisted copy payload"
    }
  ],
  "artifact_refs": [],
  "blocks": []
}
```

The schema allows zero or one question. A question has two to four uniquely
identified options. Schema 1.2 adds typed artifact blocks while continuing to
reject arbitrary HTML, scripts, event handlers, and executable UI supplied by
the model.

Allowed block types are `markdown`, `metrics`, `chart`, `table`, `callout`, and
`artifact-download`. A chart or download block must reference an artifact in
`artifact_refs`. The browser renders every string as text, and chart SVG is
served by the artifact endpoint and displayed through `<img>`.

Artifact metadata is server controlled:

```json
{
  "id": "artifact-uuid",
  "kind": "chart",
  "mime": "image/svg+xml",
  "title": "Telemetry overview",
  "relative_path": "task-uuid/artifact-uuid.svg",
  "sha256": "hex",
  "source_evidence_ids": ["attachment-uuid"],
  "created_at": "2026-11-15T08:49:08.449Z",
  "safeToEmbed": true,
  "size": 6532
}
```

Absolute filesystem paths are server-only. The public artifact endpoint requires
the capability cookie or bearer token, accepts only a server-generated artifact
ID, rechecks file containment and SHA-256, sets `image/svg+xml` with
`X-Content-Type-Options: nosniff`, and uses `private, max-age=31536000,
immutable`.

The server state also carries a compact `activity` record for the current turn:

```json
{
  "status": "completed",
  "user_summary": "选择：玩游戏时",
  "submitted_at": "2026-11-15T07:24:10.560Z",
  "completed_at": "2026-11-15T07:24:14.170Z",
  "agent_summary": "Agent turn summary",
  "next_action": "The one action needed now",
  "elapsed_ms": 3610,
  "error": null
}
```

It is persisted before the model turn and finalized when the turn completes, so
a browser refresh can restore both the user's submitted content and the agent's
summary.

`state.handoff` separately records the most recent signed handoff:

```json
{
  "status": "task_resume_packet",
  "support_level": "task-resume-packet",
  "native_thread_attached": false,
  "queue_capability": "one-way-experimental",
  "queue_message_sent": false,
  "reply_visibility": "unavailable",
  "panel_view_mode": "independent",
  "source_thread_role": "return-target",
  "context_applied": true,
  "local_surface_handoff": true,
  "native_owner_changed": false,
  "thread_id": "01a1d07d-...",
  "environment_thread_id": "01a1dde5-...",
  "thread_id_mismatch": true,
  "task_id": "task-...",
  "device_snapshot_ref": "device-snapshot:...",
  "evidence_refs": ["evidence-..."],
  "received_at": "2026-11-15T09:08:53.197Z"
}
```

The raw handoff token is never stored or returned.

After handoff, the primary action column shows one state:
`来自对话 · 独立继续`. Ownership and thread IDs are moved into collapsed
`任务详情`. No `task.surface_changed` event is written; the local event is
`handoff.local_surface_handoff`.

The task state carries `task_id`, `objective`, `device_snapshot_ref`,
`evidence_refs`, `attachments`, `timeline`, `phase`, `summary`, and `last_turn`.
It also stores local artifact and analysis summaries for audit continuity.
Switching tasks injects this compact context instead of replaying prior task
history.

Draft state carries `events` and `attachments`. Attachments are metadata records
until Send; uploaded files do not create a model turn.

Completed and switched tasks are archived under `runtime/tasks/<task_id>.json`
with their panel, answer card, timeline, device/evidence references, and last
turn. The browser only renders the active task.

## Telemetry tool result

`POST /api/artifacts/analyze` does not submit a user message. On a valid CSV the
supervisor sends one structured `panel_tool_result` into the current app-owned
thread:

```json
{
  "type": "panel_tool_result",
  "task_id": "task-uuid",
  "thread_id": "thread-uuid",
  "attachment_id": "attachment-uuid",
  "task_context": {},
  "tool_result": {
    "tool": "pc-hardware-workbench.telemetry",
    "read_only": true,
    "cache_hit": false,
    "analysis": {
      "analyzed_rows": 3,
      "window": "rows 0 to 2 (header on line 1)",
      "warnings": []
    },
    "artifact": {}
  }
}
```

The model supplies the judgement and next step. The supervisor then overwrites
`artifact_refs` and `blocks` with verified broker output. This keeps the chart,
metrics, source evidence, and download path outside model control.

The broker uses `spawn(..., { shell: false })`, an argument array, a timeout,
output-size limits, attachment containment checks, CSV hash verification, and
an SVG active-content scan. The Agent never receives arbitrary shell access.

A missing, invalid, or non-recognized CSV returns a deterministic failure card.
No chart is indexed and no model tool-result turn is sent. Selecting a non-CSV
attachment returns HTTP 415.

Cache identity is `<CSV SHA-256>:<normalized window>`. Repeating the same CSV and
window reuses the artifact instead of rerunning analysis or rendering.

## Current-chat handoff capability

`open-workbench.mjs` constructs a compact Task Resume Packet and signs it with
the dedicated local `runtime/handoff-secret`. The signed URL contains an audience,
`issued_at`, `expires_at`, nonce, and packet. The server rejects:

- a bad HMAC signature with HTTP 401;
- an expired token with HTTP 401;
- a consumed nonce with HTTP 409.

Only loopback HTTP URLs are accepted. The default lifetime is 120 seconds and
the server retains at most 200 consumed nonces.

This endpoint does not attach to the supplied Codex thread. It records a
fallback task-resume context and leaves the panel's app-owned thread unchanged.

`带回 Codex` calls `/api/resume-packet`. The server builds only from structured
task, device, evidence, panel, and artifact metadata. It sanitizes Windows and
common Unix absolute paths, removes token-shaped values, and excludes raw
timeline messages. The response includes:

- task and panel task ID;
- source and panel execution thread IDs;
- device alias, snapshot date, and reference;
- completed evidence labels;
- current judgement and unresolved items;
- one priority next step;
- panel artifact IDs and relative references.

The browser copies this Markdown to the clipboard. Queueing remains absent from
the default action.

## Capability grants

Each Task has:

```json
{
  "capability_profile": {
    "schema_version": "1.0",
    "profile": "read-only-supervised",
    "task_id": "task-uuid",
    "network": "disabled",
    "general_command": "unavailable",
    "hardware_write": "manual-only",
    "capabilities": {
      "telemetry_csv_analyze": "approval-required"
    }
  },
  "permission_request": null,
  "grants": []
}
```

Pending request fields include:

- `request_id`, `status`, `capability`, `profile`, and `task_id`;
- attachment ID, display name, size, SHA-256;
- Task-relative `artifact_root_ref`;
- normalized analysis window and signature;
- request expiry;
- network/command/system-write limitations.

Grant fields add:

- `grant_id`, scope (`one-time` or `task`), status;
- the same Task/attachment hash/artifact root binding;
- creation, expiry, consumed, revoked, and expired timestamps.

One-time requests last five minutes; grants last ten minutes and must match the
requested analysis window. Task grants last two hours and can authorize another
window for the same attachment hash in the same Task. Neither can cross Task,
attachment ID/hash, capability, or artifact-root scope.

`POST /api/artifacts/analyze` checks the artifact cache before permission. If the
current panel already includes the cached artifact, it returns without scripts,
new audit events, or a model turn. Otherwise it requires an active matching
grant before invoking the existing broker.

Denial, invalid grant, expiry, revocation, or cache miss without authorization
must not run a script, create an artifact, or call the model.

Permission audit events contain no bearer token, handoff secret, local path, or
process arguments.

The P2A protocol experiment found:

1. `thread/resume` from a second app-server is rejected while Codex Desktop owns
   the target thread: `already has an active writer`.
2. `thread/queue/start` from that non-owner is rejected with
   `resume the thread before starting a queued message`.
3. `codex queue --thread <id> --message <event> --resume` can enqueue an event
   and return a queued ID, but warns when it cannot resume.
4. The owner can consume the queued event; a non-owner sees the shared queue
   item but receives no reply or turn-completion notification.
5. After the owner process closes, an isolated completed mock thread can be
   resumed by a fresh app-server with its completed turns intact.

Therefore native bidirectional attachment to the currently active desktop
thread is `blocked/experimental`. The stable fallback is the signed Task Resume
Packet. No `task.surface_changed` event is written unless a native surface
attachment actually succeeds.

## User event contract

The canonical schema is
[`schemas/panel-event.schema.json`](schemas/panel-event.schema.json).

Local events:

```json
{
  "schema_version": "1.0",
  "type": "option_selected",
  "event_id": "uuid",
  "created_at": "2026-11-15T06:37:18.385Z",
  "question_id": "slowdown-timing",
  "option_id": "gaming"
}
```

```json
{
  "schema_version": "1.0",
  "type": "evidence_added",
  "event_id": "uuid",
  "created_at": "2026-11-15T06:37:18.385Z",
  "label": "Short label",
  "detail": "Optional detail",
  "source": "user_reported"
}
```

On Send, pending events are wrapped in one turn input:

```json
{
  "schema_version": "1.0",
  "type": "panel_submission",
  "submission_id": "uuid",
  "created_at": "2026-11-15T06:37:23.456Z",
  "events": ["...pending events..."],
  "free_text": "",
  "task_context": {
    "task_id": "task-uuid",
    "device_snapshot_ref": "device-snapshot:...",
    "evidence_refs": ["evidence-..."]
  },
  "attachments": [
    {
      "id": "attachment-uuid",
      "original_name": "sensor.csv",
      "mime_type": "text/csv",
      "size": 193,
      "sha256": "hex",
      "local_path": "C:\\...\\runtime\\attachments\\..."
    }
  ]
}
```

The initial symptom is a direct `user_message` event.

`attachment_added` is recorded separately and never starts a turn. Only the
following `user_message` or `panel_submission` carries attachment references to
the agent. The binary content is never inserted into the prompt.

`task_submitted` separately records the task ID, thread ID, user event ID, user
summary, and attachment IDs. This keeps file ingestion, task submission, and the
agent input distinguishable in the append-only event log.

Allowed uploads are CSV, TXT, LOG, JSON, PNG, JPEG, and WEBP, up to 8 MB per
file. SVG and other types are rejected. The server ignores the submitted path,
sanitizes the display name, assigns its own ID and storage name, and records the
SHA-256 digest.

## Thread naming and history

After thread creation or resume, the supervisor calls `thread/name/set` with a
name derived from the active workbench objective, for example
`硬件调试：确认现有 CSV 是否覆盖黑屏或掉帧事件`.

Discoverability of a saved Thread through a fresh `thread/list` probe remains an
adapter-specific diagnostic outside the 0.1.0-dev product test suite. Exact-ID
resume is the supported recovery path.

## Permissions

The thread is created/resumed with `read-only` and `approvalPolicy: never`. The
UI exposes the resulting `read-only supervised` boundary and does not hide the
panel. Action-by-action permission escalation is reserved for the next phase.

## Codex adapter exchange

Messages are newline-delimited JSON. The tested sequence is:

1. Client `initialize`
2. Client notification `initialized`
3. Client `thread/start`
4. Client `turn/start` with `threadId`, one text input, and `outputSchema`
5. Server notifications `turn/started`, `item/started`, `item/completed`,
   `item/agentMessage/delta`, and `turn/completed`
6. The final `agentMessage` item is parsed and validated as panel state

On supervisor restart, the server sends `thread/resume` with the saved
app-owned `threadId`. Resume is best effort in the experimental app-server
protocol. An earlier run recovered the same thread; the P1 retry encountered
“no rollout found” and created a new app-owned thread before analysis. In both
cases the workbench task, device snapshot, shared evidence, and attachments were
preserved. Analysis itself did not change the active thread ID. The next orderly
restart resumed `01a1de6a-3433-7e50-b90a-82d31eca4b35` successfully. A separate
`thread/list` history probe still did not discover that thread, so direct resume
and new-process history discovery should be treated as separate capabilities.

## Unverified boundaries

- Bidirectional attachment to the Codex desktop app's current thread while it
  owns an active writer.
- Discovering that current thread through a stable cross-client API.
- `codex queue --thread` round trips and structured callback behavior.
- Compatibility with Codex CLI versions other than 0.169.0-alpha.11.1.
- Concurrent users, remote clients, cloud deployment, or multi-panel ownership.
