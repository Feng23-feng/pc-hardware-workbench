# Guided experiment loop

Use this loop for each candidate change.

## 1. Preflight

Give the component-specific risk notice first. Record the exact device, form factor, selected starting route, firmware/driver, current daily profile, evidence source, baseline measurement, ambient conditions, workload, and rollback method. Record any reference profile and why it is comparable. If telemetry is live, agree on sampling duration and an end condition. Confirm the user is at the machine, can restore the known-good profile, and understands the specific risk.

If a prior card clearly belongs to the same device and workload, offer its fixed conditions as defaults for route, objective, recovery, workload, primary metric, and abort signals. Show that reuse explicitly and let the user confirm or replace each changed condition instead of asking from blank again.

## 2. State the hypothesis

Use one sentence:

> Changing [one setting] from [baseline] to [candidate] should improve [one target] while remaining within [thermal/power/stability limit].

State what result would reject the hypothesis and name the reference evidence that made this candidate reasonable.

Record whether that evidence came from the user's own device, an official document, a matched community report, or an unverified online claim. A web profile is only a hypothesis until the user's own test supports it.

## 3. Choose the candidate increment

Use the smallest meaningful increment supported by the tool. For a discrete control, usually one UI step or one multiplier step. For a continuous control, choose a change large enough to measure but small enough to leave a clear margin; state the step instead of presenting it as a universal safe value.

Do not compound changes to compensate for noise. Repeat the baseline if measurement noise is comparable to the expected gain.

## 4. User application

The user applies the change. Confirm:

- the setting actually applied;
- the tool or firmware did not reject it silently;
- the machine remained bootable;
- the expected voltage/clock/power value is visible in monitoring data.

Treat any uncertainty about whether the control exists or was accepted as a reason to stop this round. Do not invent a substitute setting from another firmware, board, laptop, or tuning utility.

## 5. Verification sequence

Choose tests proportional to the change:

1. short smoke test;
2. repeatable target workload or benchmark;
3. a stability or integrity test appropriate to CPU, GPU, memory, or storage involvement;
4. cold boot, warm reboot, sleep/wake, and recovery-path check when relevant;
5. normal-use period after synthetic testing.

Record frame times or throughput, minimum/percentile performance when relevant, temperatures, power, clocks, fan behavior, errors, and subjective artifacts.

## 6. Classification

- **Pass for this round:** improvement is repeatable and no correctness, thermal, power, or stability failure occurred.
- **Fail:** any artifact, WHEA, reset, corruption, crash, thermal runaway, connector hot spot, or unexplained clock collapse.
- **Inconclusive:** noise or missing evidence prevents a decision. Do not escalate until it is resolved.

## 7. Stop and rollback

Stop immediately for:

- failed POST or repeated display/device resets;
- visual corruption, driver resets, filesystem errors, or data-integrity warnings;
- burning smell, arcing, damaged connector, or unusually rapid connector/hotspot heating;
- repeated thermal or power throttling outside the expected envelope;
- anti-cheat rejection or security-policy conflict.

Restore the saved profile or documented default. Do not hide the failure by changing several compensations at once.

## 8. Decision and optional learning review

End with one:

- **Keep:** record the tested profile and its evidence.
- **Continue:** propose exactly one next increment and repeat.
- **Revert:** restore the prior stable baseline.
- **Stop:** hardware, cooling, power, or recovery evidence makes further tuning unjustified.

First summarize the evidence and recommended decision directly:

> The primary variable was [x]. The useful evidence was [baseline vs candidate], while [guard signal] limits the conclusion. I recommend [keep/continue/revert/stop] because [reason]. Recovery is [action].

Then offer, but do not require, a one-line learning review:

> 如果愿意，可以用一句话确认：你是否同意这个判断？下次你最需要自己记住的是哪一点？

The user may accept, correct, or decline. Do not withhold the decision or experiment card pending a written answer. If the user's reasoning would be unsafe, correct that specific point directly. End with the next independently executable step or the condition that means tuning should not start. This is a takeaway offered to the user, not a passing criterion.

Update the same experiment record with:

- status: reviewed;
- result: pass, fail, or inconclusive;
- evidence: linked telemetry summary or manual observations;
- decision: keep, continue, revert, or stop;
- reason and the next single experiment.

Reuse that reviewed card as context for the next round when the device and workload remain the same.
