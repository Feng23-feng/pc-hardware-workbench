# Tuning depth: quick and deep

Tuning has one entry. Offer the two operating depths only after the user has chosen tuning and completed the tuning entry gate. The depths change how much evidence and record-keeping is expected, not the safety floor.

## How to choose

Use **quick mode** by default when the user wants a practical daily profile, asks for a first experiment, or does not want a long measurement campaign.

Use **deep mode** when the user wants the highest repeatable profile, a benchmark-only result, a hard-to-reproduce failure, a formal comparison, or explicitly asks for extensive records.

If the choice is ambiguous, explain that quick mode reaches a useful candidate faster with less evidence, while deep mode takes longer and supports stronger stability and transferability claims. Then ask which depth the user wants. Do not use quick/deep as two separate top-level task options.

In a conversational Skill, do not ask a beginner to fill a blank experiment template. Ask natural questions, often no more than “你实际在玩什么或运行什么？” and “现在大约是什么表现？”, then turn the answers into the fixed workload and metrics. Ask only for safety facts that cannot be inferred. The Skill writes the formatted card; the user reviews one concise confirmation instead of completing a form.

Cooling context is collected only after inventory establishes the device form and target component. A desktop CPU task may ask only for CPU cooling type and relevant airflow; a desktop GPU task may ask only for the original/modified GPU cooler class and relevant airflow. Exact model names are optional. Laptop users are not asked to answer a desktop-style cooling questionnaire; use official model/power-envelope information as a provisional ceiling and verify actual cooling with telemetry.

### Vendor-profile fast path

When the request is only to enable an official one-toggle profile such as XMP, EXPO, or a vendor performance mode, use a compact setup plan instead of a full deep-tuning record. Confirm that the system currently boots reliably and that the user can restore BIOS defaults or clear CMOS if necessary. Give one toggle, its action/analogy/consequence, the expected gain, the failure signals, the recovery route, and a short reboot plus representative-workload check. Do not turn this into permission to stack manual timings, voltage offsets, or benchmark-only profiles. If the machine fails to boot, revert instead of forcing it through.

This fast path is inside the normal tuning gate, not a bypass. Its single “experiment unit” is the complete vendor profile, not each frequency, timing, and voltage it changes. Attribute a result to the profile as a whole; do not claim a specific timing or voltage caused the improvement. If the prerequisite gate facts are missing, teach the user how to obtain them before applying the profile.

## Safety floor shared by both modes

- Pass the mandatory tuning entry gate in `SKILL.md` and `intake.md` before proposing a personalized setting.
- Establish the stock or known-good profile and a recovery method.
- Change one primary variable per round.
- Use the exact control exposed by the platform.
- Apply the safety notice from SKILL.md only when the response contains a candidate setting or an actionable user-applied change; adapt explanation depth to user skill and risk.
- Never hide or invent missing safety fields simply to keep the conversation short.
- Stop for artifacts, black screens, driver resets, shutdowns, thermal abnormality, or anti-cheat conflict.
- Never silently promote a quick result to daily-validated.

Quick mode is less detailed, not less safe.
No route, wording, user experience level, or explicit request for speed may skip the entry gate.

## Quick mode

Collect only:

1. exact device and current driver/tool;
2. objective and one target workload;
3. stock or known-good profile and rollback;
4. one repeatable scene or benchmark;
5. one primary metric and one critical guard signal.

For the first round:

- establish a stock result;
- apply one smallest meaningful step;
- repeat the same workload, preferably twice when the change is small;
- check artifacts, resets, unusual temperature/power behavior, and the chosen metric;
- record whether the result is keep, continue, revert, or stop.

Quick-mode evidence label:

```text
Quick pass: useful for continuing this tuning session.
Not yet: reboot-verified, daily-validated, or a universal stable value.
```

Use [fixed-workloads.md](fixed-workloads.md) for the compact workload and one-screen card.

## Deep mode

Follow the complete experiment loop and validation guidance:

- estimate baseline noise;
- record full workload/settings and sampling window;
- capture relevant clocks, power, temperatures, limits, errors, and artifacts;
- use telemetry analysis when a CSV or log exists;
- verify persistence, reboot, sleep/wake, and combined workloads;
- keep daily and benchmark profiles separate;
- preserve dated records and a shareable, de-identified summary when requested.

Deep mode is appropriate for claims such as “daily stable”, “maximum stable”, or “safe for another similar machine”. It still does not create a universal safe value.

Use [success-and-sensor-semantics.md](success-and-sensor-semantics.md) for pass criteria and telemetry interpretation, and [persistence-and-update-gate.md](persistence-and-update-gate.md) for restart and software-update validation.

## Transition rules

- A quick pass can become a deep-validation candidate, not automatically a daily profile.
- If quick mode exposes noise, a failure, or an uncertain sensor, switch to deep mode or stop.
- Do not ask the user to complete the deep record before giving useful next steps; progressively request only evidence that can change the decision.
