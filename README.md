# SkillDock

**SkillDock（技能坞）** is a provider-neutral local web surface backed by
installed Skill runtimes. PC Hardware Workbench is an example Skill; Codex and
DSH are adapters, not product concepts.

Version lines are independent:

- SkillDock application: `0.1.0-rc.4` (public test build; no stable release)
- SkillSurface contract: `1.0`
- SkillRuntime contract: `1.0`
- AgentDriver contract: `1.0`
- installed domain Skills: tracked by their own versions

See [VERSIONING.md](VERSIONING.md) and [NAMING.md](NAMING.md).
The canonical version, asset, host, and evidence matrix is
[COMPONENT-MATRIX.md](COMPONENT-MATRIX.md).
The long-term Agent compatibility route is described in
[AGENT-BRIDGE.md](AGENT-BRIDGE.md); its protocol remains a draft.
The primary user journey is Skill-triggered, not a manually launched desktop
application; see [SKILL-TRIGGERED-UX.md](SKILL-TRIGGERED-UX.md).

## Windows release candidate

The current Windows test candidate is SkillDock `0.1.0-rc.6` with PC Hardware
Workbench `2.9.2`. The R7 user-experience evidence remains provenance from the
`2.7.4` source tree. The integrated Windows candidate is:

```text
dist/SkillDock-PCHW-0.1.0-rc.6-win-x64.zip
```

Build and verify it without changing the formal entry:

```powershell
pnpm build:win-rc
pnpm verify:win-rc
```

The RC remains default-off. Default traffic, the formal default entry,
background write, coordinator recovery, automatic hardware changes, and formal
stable release stay closed. Clean-Windows install/uninstall acceptance and
explicit user signoff are still required. The same verified RC is also used to
derive the user-installable package and the Runtime-only package. The latest
published SkillDock test build is
<https://github.com/Feng23-feng/pc-hardware-workbench/releases/tag/v0.1.0-rc.6>.
See [`release/0.1.0-rc.6`](release/0.1.0-rc.6).

Host scope is intentionally narrow: this version promises the
`pchw-source-hosted` SkillDock panel only under Codex. DSH and other hosts may
install `pc-hardware-workbench` and use its chat, collection, and CSV-analysis
capabilities, but must not be told that the SkillDock panel is available there.
`launch-panel.ps1` requires `CODEX_THREAD_ID` and fails with
`thread_binding_missing` when that identity is absent. See
[`SUPPORT-MATRIX.md`](release/0.1.0-rc.6/SUPPORT-MATRIX.md).

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1
```

Open <http://127.0.0.1:4319/>.

Stop:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\stop.ps1
```

If a saved panel-owned Session can no longer be resumed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -ResetState
```

The normal start path binds only to `127.0.0.1`. The selected Agent adapter
receives explicit turn inputs; the panel makes no separate upload.

The current PC Hardware Workbench example manifest is selected by `start.ps1`.
Override it without changing the panel core:

```powershell
$env:PANEL_SKILL_MANIFEST = "C:\path\to\workbench.manifest.json"
$env:PANEL_MANIFEST_ALLOWED_ROOT = "C:\path\to\skill"
$env:PANEL_SKILL_ID = "example.skill"
```

Without a manifest, the panel uses its compatibility fixture and retains Task,
composer, chat, artifacts, permissions, and Resume/export where the current
domain implementation permits them.

The connection layer is Agent-neutral:

```powershell
$env:PANEL_AGENT_DRIVER = "codex"  # default
$env:PANEL_AGENT_DRIVER = "dsh"
$env:PANEL_AGENT_DRIVER = "dsh-web"  # panel-owned DSH Web child, experimental
$env:PANEL_AGENT_DRIVER = "agent-bridge"
$env:PANEL_AGENT_DRIVER = "mock"
```

Invalid driver names fail before the server listens. P4 established the
Codex/Mock boundary; P5 adds DSH headless. DSH Web uses a panel-owned child
process so the panel never reads or copies an existing browser cookie. The
adapter remains experimental.

The effective Agent permission and the SkillDock surface mode are exposed
separately:

```powershell
$env:PANEL_AGENT_SANDBOX = "read-only"       # default
$env:PANEL_AGENT_APPROVAL_POLICY = "never"   # default
$env:PANEL_SURFACE_MODE = "read-only"        # default
```

Supported Agent sandbox names are `read-only`, `workspace-write`, and
`danger-full-access`. Approval names are `on-request` and `never`. A Driver
rejects a requested combination it cannot support. The current Codex Driver
can run the listed sandboxes, but it advertises `approvalModes: ["never"]`
because it cannot yet relay approval events; it must not claim `on-request`
support.

Surface names are `chat`, `read-only`, `interactive`, and `developer`. `chat`
launches no Runtime. The `launch-panel.ps1` entry accepts only non-chat surface
modes.

For a DSH Web trial that reuses the user's existing DSH login:

```powershell
.\start.ps1 `
  -Port 4331 `
  -AgentDriver dsh-web `
  -RuntimeDirectory runtime-dsh-web `
  -DshHome "$HOME\.dsh" `
  -AgentWorkspace "$HOME\Documents\deepseek-harness\default-workspace"

.\stop.ps1 -RuntimeDirectory runtime-dsh-web
```

The installed DSH headless route remains separately available through
`-AgentDriver dsh`, but it requires `DEEPSEEK_API_KEY` in the launching process.
Desktop credentials do not automatically become a headless environment
credential.

`-AgentWorkspace` sets the working directory used by the Agent Session. For
DSH, this is the workspace where the new conversation appears in the DSH
Session list. It also defines the project instructions and relative paths seen
by Codex/DSH.

For a third-party Agent that implements the draft local bridge contract:

```powershell
$env:PANEL_AGENT_DRIVER = "agent-bridge"
$env:PANEL_AGENT_BRIDGE_URL = "http://127.0.0.1:4400"
$env:PANEL_AGENT_BRIDGE_TOKEN = "<token issued by the local bridge>"
```

See [AGENT-BRIDGE.md](AGENT-BRIDGE.md) and
[contracts/agent-bridge/0.1-draft/README.md](contracts/agent-bridge/0.1-draft/README.md).

The reference bridge host can expose a built-in Driver for contract testing:

```powershell
$env:AGENT_BRIDGE_HOST_TOKEN = "<at least 16 characters>"
node .\agent-bridge-host.mjs --driver codex --port 4400
```

## Test

Use the frozen runtime for release-equivalent checks:

```powershell
pnpm verify:frozen
```

The wrapper requires Node `24.22.1` with SQLite `3.53.4`, prepends that runtime
to `PATH`, and then runs `pnpm check` plus the full test suite. It searches the
current built package and `dist/archive`; set `SKILLDOCK_FROZEN_NODE` or pass
`-NodePath` when the frozen runtime lives elsewhere.

Individual smoke checks can still be run directly during development:

```powershell
node .\smoke-test.mjs
node .\tests\agent-bridge.test.mjs
$env:SKILLDOCK_AGENT_BRIDGE_URL = "http://127.0.0.1:4400"
$env:SKILLDOCK_AGENT_BRIDGE_TOKEN = "<bridge token>"
node .\tests\agent-bridge-live-smoke.mjs
node --check .\server.mjs
node --check .\public\app.js
node --check .\public\status-model.js
node --check .\public\draft-storage.js
```

The smoke test uses a deterministic mock agent and verifies:

- panel-owned Session creation;
- first question with the exact `玩游戏时` option;
- option selection without a model turn;
- refresh-safe draft persistence;
- one structured Send into the same Session;
- one discriminating follow-up;
- a same-Session new task stays task-less until its first submission;
- the first new-task submission creates only the Workbench Task, not a Session;
- the shared device snapshot and evidence refs survive task changes;
- CSV and image uploads persist in draft state without starting a model turn;
- schema 1.2 preserves verified metrics, chart, window, download, and collapsed
  warnings as whitelisted blocks;
- an explicit `分析这份数据` action invokes the installed Workbench analyzer and
  SVG renderer through a fixed, non-shell broker;
- CSV hash plus time-window cache reuse does not rerun the scripts;
- authenticated artifact delivery, download disposition, traversal rejection,
  and no-store/immutable cache headers;
- invalid or non-recognized CSV returns a deterministic failure card with no
  chart and no model tool-result turn;
- attachment metadata carries ID, original name, MIME, size, hash, and time;
- sent user events carry local attachment paths to the agent, never file bytes;
- deleting an unsent file removes it from the next request;
- unsupported and oversized files are rejected;
- answers expose judgement, supports/conflicts, uncertainty, 2-3 evidence
  recommendations, a priority action, and copy actions;
- the completion-only panel still has substantive actions;
- CSV/TXT/LOG/JSON/PNG/JPEG/WEBP whitelist;
- SVG and files over 8 MB are rejected;
- an explicit independent-Session action changes Session while retaining shared
  device evidence;
- a state refresh recovers the Session, Task, answer card, composer, and files;
- source-hosted waiting, Agent-pulled, and result-synced phases update the same
  page automatically;
- page focus/visibility immediately rechecks state after the browser was in the
  background;
- persisted running activity includes the submitted user content;
- completed activity includes the agent `turn_summary`;
- duplicate submission is rejected while a turn is running;
- sent, processing, replied, waiting, error, and completed status modes;
- append-only event log;
- orderly shutdown.

## Thread, task, and evidence semantics

The runtime separates three layers:

1. A durable panel-owned Agent Session contains the conversation.
2. A workbench task contains one objective, compact timeline, answer card, and
   turn state.
3. `runtime/shared-evidence.json` contains the device snapshot and shared
   evidence references across tasks.

`新建任务` keeps the current Agent Session and shared evidence. It clears the
current Task view and creates a new Workbench Task only after the first composer
submission. It does not run the device collector.

`新建独立 Agent Session` is an advanced action in `任务详情`. It creates an
independent panel-owned Session but still binds the shared device/evidence
store.

Panel-owned Sessions are durable. When the active adapter supports naming and
resume, task details expose the Session name, reference, and copy actions.
Provider-specific lookup instructions remain adapter details.

Resume by exact saved ID succeeded again after the P1 approval. The standalone
`thread/list` history probe nevertheless returned only two unrelated threads in
the latest run, so discoverability through a fresh list probe remains an
experimental limitation even though direct resume works.

## P2B current-chat handoff

The panel accepts a compact signed handoff without requiring the user to copy a
thread ID:

```powershell
node .\open-workbench.mjs `
  --packet-file .\work\p2a-handoff\current-source-packet.json
```

The command emits a one-use URL for `http://127.0.0.1:4319/handoff/open`.
`--open` launches the system browser through an argument array without a shell.
The packet contains:

- `thread_id`;
- `task_id`;
- objective and summary;
- device snapshot reference;
- evidence references;
- `read_only: true`.

The URL is HMAC signed with a dedicated local handoff secret, expires after two
minutes by default, is rejected on replay, and is never persisted in public
panel state. The bearer capability token and handoff signing secret are
separate. The handoff packet is not sent to the model.

P2A established a firm boundary: a second app-server cannot resume a thread
while Codex Desktop owns an active writer. The live attempt against
`01a1d07d-b140-7181-acb1-e71cefa14c52` returned
`thread ... already has an active writer`.

The primary action column shows one compact state:
`来自对话 · 独立继续`. Its sentence is: “已从对话继续任务。当前面板是独立执行
视图，未接管原对话。” Task, device, and evidence references are reused, but
the panel does not create a new Codex thread and cannot display the current
conversation's future replies.

Technical source, environment, and panel thread IDs live in collapsed
`任务详情`. The panel explains any different source/execution IDs in plain
language rather than exposing internal ownership terminology.

`带回 Codex` generates and copies a compact Resume summary. The summary contains
the task, device snapshot date, key completed evidence, current judgement,
unresolved questions, one priority next step, and panel task/artifact refs. It
excludes the raw transcript, capability tokens, handoff signing material, and
absolute private paths. It performs no queue call and does not mutate the source
conversation.

`codex queue --thread ... --message ... --resume` can enqueue one event with a
receipt, but remains experimental and one-way. In the isolated mock test the
owner consumed the queued event while the non-owner observed no reply.
P2A/P2B did not send a queue message to the current live conversation. Queueing
is not exposed as a default action.

## P3 capability approval

Every Task now carries a structured `capability_profile`, `grants`, and at most
one `permission_request`. The default profile is:

```json
{
  "profile": "read-only-supervised",
  "network": "disabled",
  "general_command": "unavailable",
  "hardware_write": "manual-only"
}
```

Selecting `分析这份数据` first asks the server whether the exact CSV hash and
window already have a verified cached artifact. A cache hit returns the existing
artifact immediately: no script, authorization prompt, audit event, or Agent
turn is repeated.

An uncached analysis without an active grant creates a permission request and
stops. The card names the attachment, size, full SHA-256, both allowlisted
scripts, and the Task artifact directory. It states that network, arbitrary
commands, system writes, and hardware changes are unavailable.

Grant choices:

- `仅本次允许`: one-time, 10-minute expiry, bound to one Task, attachment ID,
  SHA-256, artifact root, capability, and analysis window;
- `同一附件后续分析`: available only after the same Task, attachment ID, and
  SHA-256 have completed one successful one-time analysis; 2-hour expiry and
  reusable only for another window of that same attachment in the same Task;
- `拒绝`: no script, artifact, or Agent turn;

The permission card is not CSV-specific. It renders Skill-supplied facts and a
single allowlisted continuation through common once/conditional-repeat/deny
controls. The repeat control is omitted until the completed one-time analysis
condition is met, and the server rejects a premature direct request. Active
grants show scope, expiration, and a revoke action.
Restarting the panel preserves unexpired/revoked state and marks newly expired
grants with `permission.expired`.

Audit event types are `permission.requested`, `permission.granted`,
`permission.denied`, `permission.consumed`, `permission.revoked`, and
`permission.expired`. They contain capability metadata and hashes, never panel
tokens, handoff secrets, local paths, or command arguments.

## P4 Agent-neutral adapter boundary

The panel core now depends on `AgentDriver`, not Codex protocol methods:

```text
Browser/UI
  -> Task + device/evidence + artifact + permission + handoff
  -> AgentDriver
  -> CodexAgentDriver | MockAgentDriver
```

Interface operations:

- initialize/close;
- startThread/resumeThread;
- sendTurn with streaming events and completion;
- cancel;
- capabilities descriptor and error classification.

Capabilities:

| Capability | Codex | Mock |
| --- | --- | --- |
| Streaming | yes | yes |
| Thread resume | yes | yes |
| Active source-thread attach | no | no |
| Structured output | yes | yes |
| Approvals | no | no |

Codex is the first supported adapter and remains experimental. Mock is
deterministic. Panel-local telemetry analysis, artifacts, grants, handoff, and
device evidence do not belong to the driver.

The primary UI reads the generic `state.agent` descriptor and says
`Agent 已连接`. Provider names remain inside collapsed task details. Task,
artifact, permission, and handoff logic remains generic.

## P5 DeepSeek Harness adapter

`DSHAgentDriver` invokes only the installed headless CLI through the fixed
Electron entry, sends the task through stdin, and parses `--json` NDJSON.

Observed events:

- `session`;
- `status`;
- committed `text`;
- `thinking`;
- `tool_call` / `tool_result`;
- terminal `final`.

The first `session.sessionId` replaces the pending panel reference. Later turns
append `--session-id`.

DSH has no native JSON-schema CLI option. The adapter uses prompt + parse
compatibility: the prompt embeds panel schema 1.2, and the panel response layer
accepts only pure/fenced JSON that passes local validation. Plain text is a
`protocol` error.

For prompt-based adapters such as DSH, a parse or schema failure triggers one
repair turn in the same Session. The host supplies the validation error and
previous output, requests only corrected complete JSON, then reruns the same
local validation. A second failure is returned to the UI as a protocol error;
the contract is never relaxed.

Real DSH startup was verified with an isolated `DSH_HOME` and no existing profile
access. A real headless turn created a session but was blocked at
`MISSING_CREDENTIAL` because `DEEPSEEK_API_KEY` is not present in the launching
environment. The panel records `auth / dsh_authentication_required` and a local
diagnostic reference; it does not claim a successful turn.

Fixture mode (`PANEL_DSH_FIXTURE=1`) verified first-turn session creation,
second-turn `--session-id` resume, pure/fenced JSON parsing, invalid-JSON
protocol classification, auth classification, and process cancellation. Fixture
UI is labelled `DSH · fixture`.

Security:

- existing `.dsh` profile and credential files are not read;
- isolated `DSH_HOME`;
- `DSH_PERMISSION_MODE=read-only`;
- telemetry disabled;
- minimal child environment;
- `DEEPSEEK_API_KEY` forwarded only when already set in the parent environment;
- diagnostics redact key/token-shaped values.

The task context injected into a new turn contains the task ID, objective,
phase, summary, device snapshot reference, evidence references, and attachment
references. Previous task text is not replayed as a new task transcript.

## P6 DSH Web boundary

DSH `0.2.2-rc.3` exposes real Remote RPC over `POST /api/<endpoint>` and
streams over `/api/remote.mux`. Generated session calls include create, list,
prompt, wait, follow, and cancel.

The installed transport still does not support a panel-owned attachment to the
current browser session:

- browser authentication uses an authority-bound, `HttpOnly`,
  `SameSite=Strict` cookie;
- no Authorization-header token is accepted;
- `/connect` requires a separate process launch token;
- unauthenticated session RPC and `/connect` both return HTTP 401;
- the panel process has no supported way to import the current browser cookie.

The existing DSH Web session did run two real short turns:
`P6-OK-1` and then `P6-OK-2` in the same visible conversation. That proves the
API and session continue to work, but not that the panel can authenticate to
them. No `DshWebAgentDriver`, `PANEL_AGENT_DRIVER=dsh-web`, cookie scraping, or
credential-file access was added.

## P9 Skill runtime and installed-Skill discovery

The server now depends on `SkillRuntime`, not a domain implementation:

```text
Server / Task / Agent / Permission / Artifact
  -> SkillRuntime
  -> GenericDemoRuntime | PcHardwareWorkbenchRuntime
```

Skill runtime responsibilities:

- initial and migrated Task domain state;
- compact Agent context and instructions;
- attachment/evidence hooks;
- permission decisions and local-action dispatch;
- domain panel/result/block/artifact validation;
- artifact lookup;
- Resume/export domain context.

Installed Skills are discovered from:

- explicit `PANEL_SKILL_MANIFEST` paths;
- app-local `skills/`;
- `.codex/skills/`;
- `.dsh/skills/`;
- configured `PANEL_SKILL_ROOTS`.

Invalid, missing, unsafe, or import-failing Skills fall back to compatibility
chat. The active Skill id/version/runtime/hash is persisted on both the panel
state and Task. A missing previous Skill never silently switches to another
installed domain.

Two compatible packages prove the boundary:

- `skills/generic-demo` — provider-free decision demo with a text artifact;
- `skills/pc-hardware-workbench` — existing device/evidence, CSV analysis,
  permission, chart, and result-card behavior.

See `SKILL-RUNTIME.md` for the interface and `WORKBENCH-MANIFEST.md` for package
metadata.

## Activity states

Every submitted turn persists a compact activity record with:

- `status`: running, completed, or error;
- the submitted choice/free text in `user_summary`;
- the agent's `turn_summary` in `agent_summary`;
- the agent's next required action;
- start/completion timestamps and elapsed time.

The main action column starts with a large status block. Its visible sequence is
`已发送` → `Agent 处理中` → `Agent 已回复` → `等待你操作`. A completed turn keeps
the prominent `Agent 已回复` heading while the fourth progress step becomes
current. `任务完成`, `任务已停止`, `Agent 回复失败`, and `任务已中断` use separate
states and treatments.

## Answer card and Artifact Canvas

Panel schema version 1.2 contains whitelisted structured data only:
`judgement`, evidence with `supports` / `conflicts` / `context`, `uncertainty`,
two or three low-risk `recommendations`, one `priorityAction`, and copy-only
`actions`. It adds `artifact_refs[]` and typed `blocks[]`.

Schema 1.0 and 1.1 remain accepted for backward validation. Schema 1.2 blocks
are limited to `markdown`, `metrics`, `chart`, `table`, `callout`, and
`artifact-download`. The browser builds DOM text nodes and never inserts model
HTML or JavaScript.

For a committed CSV, `分析这份数据` invokes `lib/telemetry-broker.mjs`. The broker:

1. accepts only a server-known, task-scoped CSV attachment;
2. rechecks its location, size, and SHA-256;
3. runs the installed `analyze-telemetry.ps1` and
   `render-telemetry-chart.ps1` without a shell;
4. rejects an empty or unusable series result before rendering;
5. validates the generated SVG before serving it through an authenticated,
   server-controlled artifact endpoint;
6. caches by CSV hash plus normalized warm-up/duration window.

The verified metrics, SVG metadata, window, and warnings are injected by the
server after the model returns its explanation. The model cannot change chart
values or artifact paths. The Agent explains what the tool result supports and
does not support; warnings remain closed by default.

If analysis fails, the task keeps the original CSV and shows a deterministic
failure card. No fake chart is created, and no model tool-result turn is sent.

For single-game black-screen or frame-drop reports, the runtime requires three
evidence domains: fixed-scene retest, Event Viewer Display TDR/WHEA/Kernel-Power
checks, and HWiNFO GPU temperature/power/effective-clock/PerfCap capture. These
are evidence steps, not hardware conclusions.

The result card always keeps its recommendations and priority action visible.
`查看结果` scrolls to and focuses that card; when no follow-up choice is needed,
the card still provides copy actions and `新建任务`.

## Composer and attachments

The home and task screens both use a primary composer. It accepts arbitrary
questions, corrections, and follow-up text; option selection is optional rather
than a replacement for free input.

Accepted attachments are CSV, TXT, LOG, JSON, PNG, JPEG, and WEBP, up to 8 MB
per file. Files are copied into `runtime/attachments/`, renamed under a
server-generated ID, hashed with SHA-256, and associated with the current task.
The browser receives preview metadata; the agent receives a local path
reference, never binary content embedded in the prompt.

CSV/TXT/LOG/JSON files show a short text preview. Images show a local thumbnail.
Uploading or deleting an unsent attachment does not start an agent turn.
`attachment_added` and `task_submitted` are separate event-log records.

## Local storage

`本地存储` in the top bar opens an on-demand inventory of the current Runtime,
shared Node engines, Task records, attachments, artifacts, Runtime state,
installer logs, launcher state, and unmanaged local files. It never uploads the
inventory and does not count every Task by walking user workspaces.

The same panel can remove obsolete recognized Runtime backups after an inline
confirmation. The active Runtime, the backup recorded by the current
`runtime-location.json`, Task data, attachments, evidence, and unmanaged backup
directories are always preserved. Shared engines are removed only after every
active and retained Runtime reference has been checked.

The retained rollback backup can be exported as a local ZIP. When its
`engine-location.json` points at a shared Node engine, the archive includes that
exact engine and records both the Runtime backup and engine SHA-256 values.
Downloads are authenticated, content-verified, and expire after 24 hours.
Expired export files are pruned at Runtime startup and whenever the storage
panel refreshes.

Installer logs have a separate confirmed cleanup action. It removes only
`LocalRoot\install-logs` and does not touch Runtime, Task, attachment, artifact,
or rollback data.

Task and evidence cleanup for ordinary, non-source-hosted Tasks lives in a
separate danger zone. A source-hosted Task is blocked because its source Session
still owns the collaboration state. SkillDock first
creates a state-bound export of `state.json`, events, Agent protocol logs,
shared evidence, Task snapshots, attachments, and artifacts. The cleanup action
unlocks only after the export link is opened and the user confirms the download.
The server re-checks the archive SHA-256 and current state revision, so an old or
expired export cannot delete data that changed afterward. On success the old
Task data is moved to a quarantine directory, a fresh Task namespace is written,
and the quarantine is removed; an interrupted cleanup is restored on the next
start when the reset did not commit. A retry of an already committed cleanup
returns the same success receipt instead of reporting a false stale failure.
Capability tokens, handoff secrets, shared engines, Runtime backups, installer
logs, and the current Agent Session remain.

Generated exports are stored under `LocalRoot\storage-exports` and are preserved
by a default uninstall. Explicit `-PurgeUserData` removes them with the other
user data.

## Real acceptance path

1. Start the panel.
2. Enter `电脑最近有点卡`.
3. Confirm the first question includes `玩游戏时`.
4. Select it and confirm Send becomes available.
5. Refresh; confirm the selection remains.
6. Send; confirm the status shows sent, processing, elapsed seconds, and a
   disabled submit button.
7. Confirm the completed block shows the agent summary and
   `现在需要你`, the answer card, and the current question in view.
8. Refresh; confirm the same Session, Task, activity record, answer card,
   composer, and attachments.
9. Under `任务数据`, press `分析这份数据` for the committed CSV.
10. Confirm the metrics, chart, data window, download, one priority action, and
    closed Workbench warnings appear in the answer card.
11. Refresh; confirm the artifact and blocks remain without creating another
    model turn.

## State

- `runtime/state.json`: current panel, Session, Task, activity record, draft,
  error, and last turn.
- `runtime/shared-evidence.json`: shared device snapshot and evidence references.
- `runtime/attachments/`: private copied attachment files.
- `runtime/artifacts/`: task-scoped SVG charts and their server-side index.
- `runtime/tasks/`: complete local task snapshots retained after switching tasks.
- `runtime/events.jsonl`: local user/runtime event log.
- `runtime/capability-token`: loopback API capability token.
- `runtime/handoff-secret`: dedicated local HMAC secret for signed handoff URLs.
- `runtime/server-info.json`: PID and port for stop/recovery.

These files are private local runtime state and are gitignored.

## Permissions

The active Agent Session runs with only the capabilities advertised by its
adapter. The UI shows the resulting permission boundary and does not hide the
Task panel.

`/api/state` and `/api/health` expose three independent projections:

- `agent_permissions`: effective Agent sandbox and approval policy;
- `surface`: surface mode and current-workspace Runtime state;
- `permissions`: Task-local Skill capability grants.

They also expose `permission_matrix`, a derived status view for Runtime launch,
selected-file read, Task artifact write, Agent workspace write, Skill Runtime
external network, and manual-only hardware control. It does not grant any of
those actions. A SkillDock-disabled network does not describe the Agent host's
network policy, and an Agent `workspace-write` sandbox does not create a separate
SkillDock workspace grant.

Opening or switching the surface never broadens any of these profiles.

The local supervisor may invoke only the installed Workbench analyzer and chart
renderer with generated argument arrays. The Agent receives no arbitrary shell
access, and an uploaded file never becomes a command string.

Future `developer` profiles may expose additional actions, but permission growth
must be approved action by action. The current telemetry broker is a fixed
allowlisted local capability, not a general command runner. Hardware writes
remain manual user actions in every profile.

A different-workspace Runtime is not stopped implicitly. The launcher returns a
blocking error until the caller makes an explicit replacement decision.

## Scope

This release candidate is not a stable SDK product and is not a formal
production release. See [`ARCHITECTURE.md`](ARCHITECTURE.md) and
[`PROTOCOL.md`](PROTOCOL.md) for decisions and verified boundaries.
