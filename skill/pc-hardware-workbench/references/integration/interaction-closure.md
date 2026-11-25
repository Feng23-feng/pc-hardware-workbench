# Interaction closure

Use this reference whenever a mode, submenu, file picker, collector, gate, experiment, or handoff ends.

## Result envelope

Keep one internal decision record across turns and surfaces:
`status`, `judgement`, `evidence`, `conflict`, `uncertainty`,
`recommendations`, `priority_action`, and `artifact_refs`. These fields support
continuity; they are not a response template.

Project only what the current decision needs:

- default: the current judgement, one decisive reason or decision-changing
  conflict/uncertainty, and the priority action;
- concept question: one or two paragraphs;
- ordinary troubleshooting: two concise paragraphs plus one action or question;
- complex, multi-source, or CSV result: judgement, one useful chart or compact
  evidence view, only decision-changing limitations, and at most two or three
  recommendations, including the priority action;
- explicit detail request: expand evidence, alternatives, and uncertainty
  without repeating the same conclusion as a status, summary, and next step.

### Current unresolved item

Expose at most one **current unresolved item** in a user-facing status
projection. Its subject must come from the strongest decision-changing
uncertainty that remains unresolved in the current evidence, not from a fixed
topic or a previous turn.

- When the subject is not established, use a compact localized form such as
  `<subject>待确认` or `<subject> pending confirmation`; example subjects are
  `热限制`, `功耗限制`, `采样窗口`, or `驱动证据`.
- Do not hard-code `热限制待确认`, reuse a resolved item, or use a decorative
  placeholder.
- When new evidence confirms or removes the subject, replace it with the next
  unresolved decision-changing subject. If none remains, omit the pending
  status instead of keeping “待确认” for visual consistency.
- In panel JSON, place the compact label at `uncertainty[0]`; later uncertainty
  entries may explain the evidence gap. The host may render that first item as
  a status chip; it must not choose a different subject from metric names.

Omit empty fields and internal labels unless the user asks for a record. Put a
proposition in one place: the action should state what to do, not restate the
whole diagnosis. A safety stop may lead with `unsafe` or `stop`, but no other
user-facing answer should render the envelope as a checklist.

## Resume projection

A Resume Packet or return summary is continuity state, not a routine response.
Create one only for an ongoing Task that must continue in another surface or
conversation. Do not show one for a concept answer, one-off result, ordinary
clarification, or a Task that ends in the current view.

Keep machine references and user-visible content separate. The machine packet may
carry stable Task, device, evidence, artifact, hash, and surface-preference refs.
The visible summary reports the Task/objective, device snapshot label and date,
only the relevant evidence labels or safe refs, the current judgement, one
decision-changing uncertainty or open question, one priority action, safe
artifact refs, and a return instruction.

Apply the result-envelope de-duplication rule to the summary. Do not repeat the
judgement as a status, conclusion, and action. Omit the raw transcript, exhaustive
evidence, capability tokens, handoff secrets, signing or TTL details, nonces,
local attachment paths, and absolute private paths. If native thread attachment
cannot be established, say `independent continuation`; do not call it the same
conversation.

## Teaching and review

The primary success condition is independent reuse, not producing one answer or one tuning profile. Make the decisive evidence, one-variable choice, pass/abort criteria, and rollback visible. Invite the user to perform or decide the next low-risk step and report the result. After an experiment, summarize the evidence and recommended decision, then invite one optional confirmation or correction.

End with a compact reusable rule, checklist, or next independently executable step. Do not turn teaching into a quiz, assignment, or completion gate. If the user prefers concise operation or has demonstrated understanding, reduce explanation without hiding recovery or abort criteria. A user may decline a learning review and still receive the safety-critical result.

## Required end state

Every user-visible branch must end in one of these states:

- a completed result plus the next concrete action;
- one specific question needed to continue;
- an explicit cancellation that states what was not changed or produced;
- a safety stop with the reason and the smallest safe next step;
- a mode handoff that names the remaining work.

Never return from a subflow with only an unexplained menu reset. If a request is cancelled, empty, invalid, or declined, say so and preserve the correct next choice. When a device identity is unreadable or conflicting, follow [device-identity.md](device-identity.md), do not echo unsafe raw characters, and do not treat the value as confirmed.

## Collection and handoff

When read-only inventory was requested to fill a tuning, triage, or purchase gap:

1. present or reuse the relevant snapshot instead of collecting it again;
2. state what it answered;
3. state what remains unknown;
4. resume the original flow with the next single question.

Do not silently stop at the inventory report unless the user asked for inventory only. Hardware identity does not establish stability, the active profile, the exposed controls, a recovery route, or the workload bottleneck.

## Task context

Maintain a lightweight current-Task context when the work spans several modes:

- active device/report path;
- current tuning card path and status;
- component and objective;
- fixed workload and guard metrics;
- last decision and next single test.

Reuse that context without asking again unless the user changes device, hardware, workload, or goal. When multiple device reports exist, keep the selected report active for the Task. For a durable checkpoint, use `hardware-case.md`; for a switch between chat, panel, or another agent surface, use `workbench-surface.md`.

In a multi-step flow, a progress update may be given as one short natural-language sentence at a branch entry, after a gap is filled, or when resuming from a pause. A single-turn response must not show a bracketed workflow-state template. Do not display internal IDs unless the user is working with saved cards, and do not repeat the update in every response.

If a new conversation starts and prior state is unavailable, say what must be re-established rather than pretending to remember it.

## Analysis and execution

- A mixed telemetry window needs a concrete next step such as recording a fixed window or repeating the same baseline.
- A completed experiment card needs the next manual test or a keep/continue/revert/stop decision.
- After a result, link the telemetry summary to the same card, append the result/decision and next step, and mark the card reviewed.
- A cancelled file selection needs “no analysis was produced” and a route back to select a file or change task.

## Response check

Before replying, identify which end state applies. If none applies, add the missing next action or question rather than returning to a generic menu or opening prompt.
