# Agent Bridge 0.1 draft

Status: draft. Do not claim stable interoperability until the contract suite is
passed by two independent Agent implementations and the built-in Codex adapter.

The bridge is a loopback HTTP service owned by the Agent integration. Every
request uses a bearer capability token held only in the SkillDock process and
the bridge process. Query credentials, public listeners, wildcard addresses,
cookies scraped from another process, and SkillDock handoff secrets are outside
the contract.

## Endpoints

```text
GET  /v1/health
GET  /v1/capabilities
POST /v1/sessions
GET  /v1/sessions/{id}
POST /v1/sessions/{id}/name
POST /v1/sessions/{id}/turns
POST /v1/sessions/{id}/cancel
```

`/v1/health` and `/v1/capabilities` return the declared protocol version.
`text_input` and `session_create` are mandatory. Resume, naming, structured
output, cancellation, and approvals are capability-negotiated.

The draft is synchronous at the turn boundary: `POST /turns` returns one
completed response. Streaming is explicitly `false` in this draft. A later
contract revision may add a durable event stream without changing the Session
and Task semantics.

## Session creation

Request:

```json
{
  "client_request_id": "uuid",
  "workspace": "C:\\Users\\example\\Documents\\project"
}
```

Response:

```json
{
  "session": {
    "id": "session-example",
    "name": null,
    "created_at": "2026-11-15T15:00:00.000Z",
    "workspace": "C:\\Users\\example\\Documents\\project"
  }
}
```

`workspace` is the Agent's Session scope, not the SkillDock installation
directory. Workspace-aware Agents must create or resume the Session there.

## Turn submission

Request:

```json
{
  "request_id": "event-id",
  "turn_id": "turn-id",
  "packet": {},
  "output_schema": {}
}
```

Response:

```json
{
  "turn_id": "turn-id",
  "status": "completed",
  "output": {
    "text": "",
    "structured": {}
  }
}
```

At least one of `text` or `structured` must be non-empty. SkillDock parses and
validates the output against the active Skill Surface schema. A bridge cannot
inject HTML or arbitrary browser behavior.

## Errors

HTTP status and an error envelope are both required:

```json
{
  "error": {
    "classification": "blocked",
    "code": "session_writer_busy",
    "message": "The Session is currently owned by another writer."
  }
}
```

The normative response shapes are in
[agent-bridge.schema.json](agent-bridge.schema.json).
