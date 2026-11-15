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

Maintain enough internal state to resume without replaying the conversation:

- Task identity, goal, and current scope;
- device reference and identity quality;
- current judgement, decision-changing evidence, conflicts, and uncertainties;
- active baseline, experiment, recovery, and persistence state when relevant;
- artifact and evidence references with source/hash links;
- one priority action; and
- the user's surface preference.

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
