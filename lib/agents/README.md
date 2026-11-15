# Agent adapter boundary

The panel core owns Tasks, surfaces, device/evidence references, artifacts,
handoff state, and local capability approvals. It talks to an Agent exclusively
through `AgentDriver`.

## Interface

```text
initialize()                         -> connected status
close()
startThread()                        -> { threadReference, resumed:false }
resumeThread(threadReference)        -> { threadReference, resumed:true }
sendTurn({
  threadReference,
  eventId,
  packet,
  structuredOutputSchema,
  onEvent
})                                   -> { turnId, finalText, structuredOutput }
cancel(turnId)
setThreadName(name)
classifyError(error)                 -> AgentDriverError
capabilities
```

`sendTurn` emits neutral streaming events through `onEvent`:

- `turn_started`;
- `text_delta`;
- `message_completed`;
- `turn_completed`.

Completion carries `turnId`, final text, and optionally already-structured
output. The panel response layer performs JSON parsing and schema validation, so
drivers do not depend on the artifact/permission UI.

## Capabilities

```json
{
  "supportsStreaming": true,
  "supportsThreadResume": true,
  "supportsActiveThreadAttach": false,
  "supportsStructuredOutput": true,
  "supportsApprovals": false,
  "supportsThreadNaming": true,
  "supportsCancellation": true,
  "adapterStatus": "experimental"
}
```

The upper layer reads capabilities instead of assuming transport behavior.
Unsupported resume or attach is a `blocked` capability boundary, not a protocol
error hidden in Task state.

## Errors

`AgentDriverError.classification` is one of:

- `unavailable`;
- `blocked`;
- `auth`;
- `permission`;
- `protocol`.

Transport-specific error text stays inside the adapter. The core records only
classification, stable code, and user-safe message.

## Drivers

| Driver | Status | Streaming | Resume | Active attach | Structured output | Approvals |
| --- | --- | --- | --- | --- | --- | --- |
| `codex` | first supported adapter, experimental protocol | yes | yes | no | yes | no |
| `dsh` | isolated headless adapter, experimental | yes | yes | no | prompt+parse compatibility | no |
| `mock` | deterministic test adapter | yes | yes | no | yes | no |
| MCP / CLI | not implemented | — | — | — | — | — |

Select with:

```powershell
$env:PANEL_AGENT_DRIVER = "codex"  # default
$env:PANEL_AGENT_DRIVER = "dsh"
$env:PANEL_AGENT_DRIVER = "mock"
```

Invalid values fail before the server starts and list allowed drivers.

## Adding another adapter

A future DSH, MCP, or CLI adapter must:

1. extend `AgentDriver`;
2. map its transport into the neutral methods/events;
3. declare truthful capabilities;
4. classify failures into the four error classes;
5. avoid importing panel artifact, permission, handoff, or UI code;
6. be registered in `lib/agents/index.mjs`.

P4 did not include DSH; P5 adds the DSH adapter below.

## DSH adapter

`DSHAgentDriver` invokes only the installed headless CLI:

```text
DeepSeek Harness.exe --expose-internals <cli.js> headless --json -
```

Prompt is sent through stdin. The adapter parses NDJSON events:

- `session`;
- `status`;
- `text`;
- `thinking`;
- `tool_call` / `tool_result`;
- final `final`.

The `session.sessionId` becomes the panel's thread reference. Subsequent turns
use `--session-id <id>`.

DSH has no native JSON-schema option. The adapter requests schema 1.2 in the
prompt and the panel response layer accepts only parseable pure/fenced JSON that
passes local validation. This is marked
`structuredOutputCompatibility: "prompt-parse-schema-validation"` and
`supportsStructuredOutput: false`.

The real CLI is launched with an isolated `DSH_HOME`, read-only permission mode,
telemetry disabled, stdin prompt transport, and a minimal environment. Existing
`.dsh` credentials/files are not read by panel code. `DEEPSEEK_API_KEY` is only
forwarded when already present in the launching environment.

`PANEL_DSH_FIXTURE=1` selects a local NDJSON fixture for deterministic adapter
tests; the UI reports `DSH · fixture`, never pretending it is a real model turn.
