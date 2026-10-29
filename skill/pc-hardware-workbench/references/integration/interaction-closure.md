# Interaction closure

Use this reference whenever a mode, submenu, file picker, collector, gate, experiment, or handoff ends.

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

## Session context

Maintain a lightweight current-session context when the task spans several modes:

- active device/report path;
- current tuning card path and status;
- component and objective;
- fixed workload and guard metrics;
- last decision and next single test.

Reuse that context without asking again unless the user changes device, hardware, workload, or goal. When multiple device reports exist, keep the selected report active for the session.

In a multi-step flow, a progress update may be given as one short natural-language sentence at a branch entry, after a gap is filled, or when resuming from a pause. A single-turn response must not show a bracketed workflow-state template. Do not display internal IDs unless the user is working with saved cards, and do not repeat the update in every response.

If a new conversation starts and prior state is unavailable, say what must be re-established rather than pretending to remember it.

## Analysis and execution

- A mixed telemetry window needs a concrete next step such as recording a fixed window or repeating the same baseline.
- A completed experiment card needs the next manual test or a keep/continue/revert/stop decision.
- After a result, link the telemetry summary to the same card, append the result/decision and next step, and mark the card reviewed.
- A cancelled file selection needs “no analysis was produced” and a route back to select a file or change task.

## Response check

Before replying, identify which end state applies. If none applies, add the missing next action or question rather than returning to a generic menu or opening prompt.
