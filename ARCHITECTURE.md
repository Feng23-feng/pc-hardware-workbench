# Architecture decision record

Status: Windows release-candidate preparation in the independent SkillDock
`0.1.0-rc.2` version line, 2026-11-20. Formal stable release remains closed.

## Decision

Use a local Node supervisor with an Agent-neutral driver boundary. The core owns
Tasks, Sessions, surfaces, artifacts, handoff, permissions, and portable Skill
manifests. Provider transports are hidden inside adapters. A browser operation
only changes local draft state until the user presses Send; Send starts one
Agent turn through the selected driver.

```text
Browser / panel UI
        |
Task + device/evidence + artifact + permission + handoff
        |
     AgentDriver
     /        \
CodexAgent   MockAgent
Driver       Driver
   |
Codex app-server protocol
```

The core does not import protocol types, construct transport request fields, or
interpret transport events. It sends a neutral turn packet and receives final
text or structured output plus neutral lifecycle events.

## Portable Skill manifest

`schemas/workbench-manifest.schema.json` defines the versioned contract a Skill
uses to declare:

- Skill identity, version, and contained root;
- UI state and event schemas;
- artifact namespace and allowed kinds;
- domain capabilities and their local permission needs;
- default capability profile;
- supported panel block types;
- Resume/handoff requirements;
- required and optional Agent capability names.

The runtime loader validates exact fields, versions, file types, and real-path
containment before use. An invalid or missing manifest selects a compatibility
manifest; it does not stop the HTTP server or pure Task/chat flow.

Provider names are not manifest adapter requirements. An adapter declares
capabilities such as `text_input`, `session_resume`, `structured_output`, and
`cancellation`.

## Skill runtime

The host loads `manifest.runtime.entry` after path, file type, size, and manifest
hash validation. The module exports `createRuntime(context)` and returns a
`SkillRuntime`.

The runtime interface owns:

- initial/normalized Task domain state;
- Agent Skill context and instructions;
- attachment/evidence hooks;
- local action registration, permissions, execution, and artifact lookup;
- domain result/block/artifact validation;
- Resume/export domain context.

The host retains ownership of HTTP, Sessions, Tasks, Agent adapters, permission
envelopes, artifact delivery, event logs, and state persistence.

Discovery accepts explicit manifests and standard Skill roots. The active
Skill identity is persisted on the panel and Task. A missing prior Skill selects
compatibility chat instead of silently loading another installed domain.

## Session compatibility

`session_ref`, `session_name`, and `session_recovered` are the canonical generic
state fields. The loader and writer retain `thread_id`, `thread_name`, and
`thread_recovered` aliases for old state and events. `/api/session/new` is the
generic route; `/api/thread/new` remains a compatibility alias.

Migration order:

1. Move event names and internal helpers from `thread_*` to `session_*`.
2. Update Resume packet files and CLI flags while continuing to accept legacy
   `thread_id` input.
3. Remove public compatibility aliases only after saved-state migration is
   proven across all released snapshots.

## Connection options

| Path | Evidence | Decision |
| --- | --- | --- |
| `codex app-server` over stdio | Verified multi-turn use, same-thread task changes, structured output, and named durable history. | Primary |
| `codex app-server --listen ws://... --ws-auth capability-token` | Exposed by CLI help; not needed when the panel process can own a child process. | Possible later |
| App-server `thread/queue/*` or `codex queue --thread` | Messages can target a session UUID or exact name, but this spike has no verified callback stream into the current desktop thread. | Backup, not integrated |
| `codex exec --json` / `codex exec resume` | Event stream is useful, but process-per-turn lifecycle and current-thread attachment do not fit the desired live panel as well. | Not selected |

## Why this path

- stdio has no listening network port.
- The supervisor never reads or persists Codex credentials; app-server uses the
  user's existing Codex authentication internally.
- Thread creation, turn start, incremental text events, final message, and
  completion share one persistent connection.
- The turn's `outputSchema` constrains the final assistant message to the panel
  UI state.

## Agent adapter contract

`AgentDriver` provides:

- `initialize` / `close`;
- `startThread` / `resumeThread`;
- `sendTurn` with neutral streaming events and completion;
- `cancel`;
- optional thread naming;
- a capabilities descriptor;
- error classification.

Capability matrix:

| Capability | Codex | DSH | Mock |
| --- | --- | --- | --- |
| Streaming | yes | yes | yes |
| Thread resume | yes | yes | yes |
| Active Desktop-thread attach | no | no | no |
| Structured output | native | prompt+parse compatibility | structured object |
| Approvals | no | no | no |
| Thread naming | yes | no | yes |
| Cancellation | yes | process termination | yes |

The Codex and headless DSH adapters are experimental. Mock is deterministic.
MCP/CLI implementations do not exist. P6 verified DSH Web's underlying RPC
contracts but did not add a Web adapter because its current browser session
capability is an `HttpOnly`, authority-bound cookie with no supported handoff to
the panel process.

Driver failures are classified as:

- `unavailable`: process/connection unavailable;
- `blocked`: ownership/capability barrier;
- `auth`: provider/session authentication missing;
- `permission`: policy or approval rejection;
- `protocol`: malformed or incompatible request/response.

Panel local capabilities are outside the Agent boundary. A manifest-selected
Skill runtime owns domain context, actions, permissions, artifacts, and result
post-processing. The runtime does not import an Agent adapter.

## Known risks

- App-server is explicitly experimental in CLI 0.169.0-alpha.11.1.
- The protocol uses newline-delimited JSON-RPC-shaped messages without a
  `jsonrpc` field. A future CLI may rename or reshape experimental methods.
- Output schema compatibility varies by provider. Every node needs `type`;
  nullable unions use `anyOf`.
- A model turn needs the user's normal Codex provider connection. The panel
  itself makes no separate upload.
- Durable app-owned threads resume by ID after panel restart and receive a
  discoverable name through `thread/name/set`. Resume remains best effort: the
  P1 restart encountered “no rollout found” and created a new app-owned thread
  before analysis. The workbench task, device store, and attachments survived.
  Existing desktop-thread attachment and current-thread discovery remain
  unverified.
- The in-memory server state and `StateStore.state` must remain the same object.
  Reset mutates that object in place and clears panel/draft before assigning the
  new thread.
- DSH Web is not an AgentDriver yet. Its `/connect` API requires a process
  launch token, while the current page uses a separate `HttpOnly` browser
  cookie. Scraping that cookie from DevTools or credential storage would make
  the integration depend on an unsupported trust-boundary bypass.

## Directory plan

```text
skill-surface/
  server.mjs               local HTTP/API supervisor
  lib/
    schema-validation.mjs  trust-boundary validation
    panel-response.mjs     response parsing and UI contract enforcement
    handoff-capability.mjs signed one-use Task Resume Packets
    skill-runtime.mjs      narrow Skill runtime interface and dynamic loader
    skill-discovery.mjs    explicit/root discovery, dedupe, selection
    workbench-manifest.mjs manifest validation and public descriptor
    state-store.mjs        atomic state and append-only event log
    agents/
      agent-driver.mjs     neutral interface, capabilities, error classes
      codex-agent-driver.mjs  first Codex protocol adapter
      dsh-agent-driver.mjs    isolated DSH headless adapter
      mock-agent-driver.mjs   deterministic test adapter
      index.mjs            driver selection and factory
  skills/                  deterministic Skill fixtures for tests
    generic-demo/          provider-free demo runtime and text artifact
    pc-hardware-workbench/ PCWB runtime, evidence, grants, analyzer, renderer
  public/                  fixed shell and data-driven components
  schemas/                 panel UI state and user event contracts
  runtime/                 private token, state, and event log (gitignored)
  runtime/attachments/     private local CSV/log/image copies
  runtime/artifacts/       task-scoped verified SVGs plus server-side index
  runtime/shared-evidence.json  shared device snapshot and evidence hashes
  runtime/tasks/           archived full task/answer snapshots
  sessions/                local experiment evidence (gitignored)
```

## Success criteria

- A vague slowdown produces one workload-timing question with an option labelled
  `玩游戏时`.
- Selecting it does not create a turn.
- Send submits one compact structured event to the same thread.
- The agent asks one discriminating follow-up.
- Browser refresh and server restart preserve the thread, panel, and draft.
- New workbench tasks default to the same Codex thread and reuse the shared
  device/evidence store without running the collector.
- A separate explicit action can create a new Codex thread while preserving the
  shared store.
- CSV and image attachments survive refresh, are copied and hashed locally, and
  reach the agent only as safe local path references.
- A committed CSV can produce verified metrics, one SVG chart, a source-evidence
  link, and a cached artifact without giving the Agent arbitrary shell access.
- Mock smoke tests are deterministic; the real path is labelled experimental.

## Thread, task, and evidence

The runtime uses three layers:

1. A durable app-owned Codex thread carries the conversation.
2. A workbench task carries one objective, compact timeline, answer panel, and
   turn state.
3. A shared local device/evidence store carries the device snapshot, evidence
   references, capture date, identity quality, privacy mode, and hashes.

`新建任务` is not a thread operation. It clears the active task view while
keeping the current Codex thread and shared evidence; the actual task is created
only when the first composer submission is sent. `新建独立对话` is the separate
advanced operation that creates a new thread and still binds the shared store.

Task switching injects only a compact context: task ID, objective, phase,
summary, device snapshot reference, evidence refs, and attachment refs. Previous
task messages are not replayed into the new task prompt.

Attachments are copied into the private runtime directory before submission.
The browser receives only preview metadata; the agent receives local path,
MIME, size, and SHA-256 references. No attachment crosses a remote boundary
except as part of the user's explicit Codex turn through the configured provider.

## Telemetry broker boundary

The browser sends only a server-known attachment ID to
`POST /api/artifacts/analyze`. The supervisor owns every executable argument.
It invokes the installed `analyze-telemetry.ps1` and
`render-telemetry-chart.ps1` through `spawn` with `shell: false`, bounded
timeouts, bounded output, and no user-controlled flags.

The broker:

1. verifies that the attachment is a CSV under `runtime/attachments/`;
2. verifies size and SHA-256 against the committed attachment record;
3. normalizes optional warm-up and duration values;
4. caches by CSV hash plus window signature;
5. rejects an empty or non-recognized metric set before rendering;
6. writes task-scoped output under `runtime/artifacts/<task_id>/`;
7. validates the SVG for active or external content;
8. stores only relative paths in public artifact metadata.

The model receives one compact `panel_tool_result` packet on the same thread.
After its schema 1.2 response is validated, the supervisor injects the broker's
metrics, chart, window, download, and warning blocks. The model cannot invent or
modify artifact paths or chart values.

The artifact endpoint requires the same loopback capability as every API call,
accepts only server-generated IDs, rechecks SHA-256, and serves SVG with
`nosniff` plus an immutable private cache policy. Invalid CSV produces a
deterministic failure card; it creates no chart and sends no model turn.

## Current-chat handoff boundary

`open-workbench.mjs` accepts a compact packet containing the current Codex
thread ID, workbench task ID, device reference, and evidence references. It
signs the packet and a short-lived nonce with a dedicated local handoff secret.
The handoff endpoint accepts only loopback HTTP, consumes the nonce once, sets
the panel cookie, and redirects to the panel.

The packet is persisted as a Task Resume Packet, not as ownership of the current
thread. P2A confirmed that a second app-server receives
`already has an active writer` while Codex Desktop owns the current thread.

An experimental `codex queue` path can enqueue one compact event with a receipt,
but the queue owner sees the resulting reply and the non-owner does not. It is
therefore explicitly one-way, and P2A did not send a message to the current live
conversation.

The only supported handoff outcome in this phase is:

- preserve task/device/evidence context;
- create no new Codex thread;
- leave the panel's app-owned thread unchanged;
- show one compact `来自对话 · 独立继续` state;
- keep source, environment, and panel thread ownership in collapsed task
  details;
- generate a sanitized Resume summary through `GET /api/resume-packet`;
- copy the summary for manual return to the source conversation without a queue
  call.

`task.surface_changed` is reserved for a future successful native attachment.
The local `handoff.local_surface_handoff` event records only that the panel
switched to an independent execution view.

Resume generation uses structured fields only. It excludes full timeline text,
bearer capability material, the handoff signing secret, local attachment paths,
and absolute filesystem paths.

## Capability approval boundary

The default Task profile is `read-only-supervised`. Capability grants are local
authorization records for one exact action. They do not change the Agent's
sandbox, expose a general command runner, or enable network access.

The only implemented capability is `telemetry.csv.analyze`. A request and grant
are bound to:

- Task ID;
- attachment ID and SHA-256;
- capability name;
- Task-relative artifact root;
- analysis window or accepted task scope;
- expiry and status.

One-time grants expire after ten minutes and cannot authorize another window.
Task grants expire after two hours and can authorize another window for the same
attachment hash in the same Task. Requests expire after five minutes.

The cache is checked before grants. If the current panel already references the
requested artifact, analysis returns immediately with no new authorization,
artifact, audit event, or model turn. An uncached run requires an active grant
before the broker may start a whitelisted script.

Permission status is visible in the sidebar. Approval details are shown only in
the permission card; result judgement remains in the existing answer card.
Revocation is immediate for future uncached analysis. Restart expiry runs before
the HTTP listener starts.

The card is a generic presentation and decision surface. Skill code supplies the
request title, explanation, facts, scope, labels, and allowlisted continuation;
the host supplies the common once/conditional-repeat/deny/revoke controls. The
repeat control is unavailable until the same Task and attachment have completed
one successful one-time analysis. The card does not accept arbitrary HTML, shell
commands, paths, or network targets from the Skill.

## Permission profiles

The spike runs with a `read-only supervised` profile and explicit
`approvalPolicy: never`. Sensitive actions are therefore unavailable, but the
panel remains visible.

The Agent permission profile, surface mode, and Task capability profile are
separate contracts:

- Agent sandbox: `read-only`, `workspace-write`, `danger-full-access`;
- Agent approvals: `on-request`, `never`;
- surface: `chat`, `read-only`, `interactive`, `developer`;
- Task grants: fixed Skill-local capabilities such as CSV analysis.

`permission_matrix` is a derived status projection over those independent
contracts. It reports Runtime launch, selected-file read, Task artifact write,
Agent workspace write, Skill Runtime external network, and manual-only hardware
boundaries. It does not merge ownership or create a grant:

- file read and artifact write follow the current Task request/grant;
- Agent workspace write remains `blocked` or `host-managed` according to the
  Agent sandbox, never according to the Surface mode;
- Skill Runtime external network is reported separately from the Agent host's
  network policy; loopback is not external network;
- hardware remains `manual-only` in every profile.

Each Driver validates the requested Agent profile against modes it can actually
operate. A Driver that cannot relay an approval event and decision must reject
`on-request` instead of silently executing with `never`.

The launcher exposes the Runtime as `running-current-workspace`. A runtime that
belongs to another workspace is not stopped without an explicit replacement
decision.

Future profiles may expose additional actions, but permission growth must be
approved action by action. The current allowlisted telemetry analysis is a fixed
local broker, not a general shell or developer capability. Hardware writes such
as BIOS, firmware, driver, voltage, clock, fan, or memory-timing changes remain
manual user actions.
