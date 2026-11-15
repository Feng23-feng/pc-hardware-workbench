# Workbench surfaces

Use this reference only when an investigation may continue across chat, a
workbench panel, or another agent surface; when choosing where to continue; or
when a complex task needs explicit task, evidence, and artifact continuity.
Do not load it for a one-turn concept answer.

## One task, several views

A **Task** is a bounded investigation goal with a device scope, evidence,
current judgement, and next action. A **Thread** is a conversation or execution
container. A **surface** is an input and presentation view over a Task. These are
not interchangeable: one Task may appear in more than one Thread or surface, and
one Thread may contain several Tasks.

When the user raises a new problem, default to a new Task inside the current
Thread. Do not create a new Codex thread merely because the Task changed. Reuse
the current Thread unless the user asks for a separate conversation or the
existing Thread cannot safely represent the work.

Device records and the Evidence Store are shared across Tasks. Reuse a current
device reference, inventory snapshot, or evidence file when the device and
context still match. A shared record does not make old settings current and does
not authorize a new collection or test. Start a distinct Task when the device,
workload, goal, or safety situation materially changes, then carry only the
references that remain relevant.

## Task state and Resume Packet

Maintain a Resume Packet only when a multi-turn or multi-evidence Task needs to
continue in another view. A simple concept answer or one-off result does not
create, display, or suggest a Resume Packet.

The abstract packet carries:

| Field | Machine-side reference | User-visible summary |
| --- | --- | --- |
| Task | Stable Task ID and goal | Task name or ID when needed to resume |
| Objective | Current bounded goal | One plain-language objective |
| Device snapshot | Device-store reference and capture date | Device label and snapshot date/reference |
| Relevant evidence | Evidence IDs, hashes, and validity context | A few completed-evidence labels; IDs only when traceability matters |
| Current judgement | Full decision record | One compact judgement |
| Uncertainty | Conflicts and unresolved items | Only the open question that can change the next step |
| Priority action | One next action | The same one next action |
| Artifact references | Private store refs and relative artifact paths | Safe relative refs or labels |
| Surface preference | `auto`, `chat-first`, or `panel-first` | Only when the user needs to choose where to continue |

Machine-side references need not be shown to the user. The visible summary is a
redacted projection, not a serialization of the packet. It must not expose
absolute private paths, local attachment paths, full transcripts, capability
tokens, handoff signing material, HMAC/TTL details, or nonces.

Use a private hardware case when the task meets the case-continuity threshold in
[hardware-case.md](hardware-case.md). The case and its `Resume` output are the
preferred durable Task packet. The internal result envelope in
[interaction-closure.md](interaction-closure.md) is the current decision view,
not another state store.

On a surface switch or resume:

1. keep the same Task and device reference;
2. reuse current evidence and prior results instead of asking again or
   re-collecting;
3. carry the current judgement, conflicts, uncertainty, and priority action;
4. read permissions from the current surface rather than from the Resume Packet;
   and
5. report only state that is actually available.

If the new surface cannot read the prior state, say which facts are missing and
re-establish the smallest missing set. Do not pretend a shared Task exists.

## Entering a surface from chat

When the host offers a stable Task handoff, carry the abstract Resume Packet into
the selected surface. Reuse the same Task, device snapshot, evidence, judgement,
and priority action. Do not repeat device intake, rerun the collector, or reanalyze
unchanged evidence merely because the view changed.

If native attachment to the active chat is unavailable, use the host's Task
Resume fallback and describe the result as an independent continuation. Say that
the source conversation was not taken over or attached. Do not claim that the
panel is “connected to the current chat”, is the same conversation, or owns the
source thread.

The destination may already use its own execution thread or process. A switch
itself does not create a new Codex thread or Task and does not replace the source
conversation. Switching surfaces never creates permission, and an unavailable
handoff is a limitation to state plainly, not something to simulate.

## Returning to chat from a workbench surface

Return by default as one compact, sanitized Resume summary that the user can copy
or send to the intended chat. It is not a native attachment unless the current
host separately proves one. Include:

- Task identity and objective;
- device label, snapshot date, and safe reference;
- only the relevant evidence IDs or labels and artifacts needed to continue;
- the current judgement and the one unresolved question or uncertainty;
- one priority action; and
- a return instruction that identifies the intended source conversation or says
  that the user must choose one.

Do not copy the full chat, attach every evidence item, repeat the judgement across
summary and action, or include secrets or private filesystem paths. If the source
conversation is unavailable, give the summary but do not claim it has returned.

## Handoff transport boundary

The Skill defines packet content and user-visible projection. It does not own or
implement capability tokens, HMAC signing, TTL and nonce handling, app-server
thread ownership, queue delivery, or browser transport. A host may provide a
signed, short-lived, one-use handoff, but that transport is not part of the
generic hardware workflow and its values must never be echoed into summaries.

Source/return-target and execution-context identifiers, when present, are
transport metadata. They may help route the summary, but they do not establish
thread ownership or make two conversations one Thread.

Queueing is not a default handoff. Do not enqueue a message merely to simulate
native chat attachment. A one-way queue with unknown reply visibility is an
explicit advanced host action; enqueue success is not delivery, a completed turn,
or proof that the source conversation received the result.

If the required transport is absent, blocked, or cannot prove ownership, state
the handoff limitation and use the copy/send Resume fallback. Task continuity can
survive without thread attachment; a claim of same-thread attachment cannot.

## Surface selection

Support `auto`, `chat-first`, and `panel-first` as presentation preferences, not
permission or safety modes. `auto` may suggest a workbench surface when a chart,
many evidence items, a long experiment, or repeated comparison would be clearer
there. Keep chat first for quick concepts, private explanations, and a single
low-risk action. If a preferred surface is unavailable, continue safely in the
available one.

The preference may be changed by the user without restarting the Task and must
never lock the investigation into one surface. Surface selection does not change
the Task, device, evidence, or permission scope. Do not depend on an experimental
panel protocol; this reference defines capabilities and state semantics only.

## Permissions and execution

Chat, panel, and other agent surfaces share the current user permission boundary.
Switching views must not elevate, broaden, or silently reacquire permission.

| Tier | Permitted by default | Boundary |
| --- | --- | --- |
| Read-only supervised | Inspect the current device, supplied logs, CSVs, images, and private case state | Default tier; respect sandbox and privacy |
| Artifact write | Create bounded local charts, reports, case files, or packages in an authorized output location | No unrelated writes or overwrite; report paths |
| Controlled execution | Run an existing local read-only helper inside the current sandbox | Wider script execution needs explicit current authorization |
| Network | Retrieve a current official source when the current tools allow network access | Minimum device data; record source and date |
| Full access | Use only permissions already granted by the host | Never inferred from a task, surface, or hardware case |

`Full access` is still not a hardware-write tier. The Skill never applies BIOS or
UEFI changes, firmware or driver installation, clocks, voltages, power limits,
fans, memory timings, or vendor profile changes. A supervised user performs any
such change manually after the relevant gate; switching surfaces never changes
that boundary.

## Attachments and artifacts

The surface owns file picking, upload, transport, and display. The Skill owns
evidence meaning and provenance. Classify an attachment by content and role:

| Class | Typical examples | Default use |
| --- | --- | --- |
| Telemetry | HWiNFO, PresentMon, or compatible CSV | Analyze with the telemetry route when needed |
| Log or export | Event export, dump metadata, text report | Bounded context; parse only with a relevant route |
| Visual evidence | Screenshot, BIOS photo, physical-damage photo | One visible observation, with the limits in [visual-evidence.md](visual-evidence.md) |
| Inventory or profile | Collector output, vendor report, saved settings | Device/config context, not proof of current state or stability |
| Derived artifact | Chart, report, package, normalized JSON | Link to its source evidence; never treat it as a new measurement |

Record the original filename or a safe label, capture time, SHA-256, source versus
derived status, related Task/device, and known workload or time window. Imported
case artifacts follow the path and privacy rules in `hardware-case.md`; do not
put private source paths in shared output.

Analyze an attachment when the user asks, the current decision needs it, and a
matching parser is available. Otherwise cite it as context without claiming more
than it can show. Do not repeat analysis of the same hash and window solely
because the surface changed. Preserve the original, label redacted or transformed
derivatives, and never upload private evidence automatically.

Link evidence to a Task by stable Evidence ID and hash. A shared Evidence Store
may serve several Tasks; each Task records a reference and its relevance rather
than copying or reinterpreting the bytes. If that store is unavailable to the
new surface, import the original again only with the user's action and record the
relation.
