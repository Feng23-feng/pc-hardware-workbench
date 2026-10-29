# Cross-mode handoffs

Use this reference when a request spans inventory, diagnosis, tuning, or purchase. The suite is integrated at the entry point, but safety and cost decisions still happen in separate phases.

## Mode matrix

| Current mode | Default output | Allowed next mode | Do not do by default |
| --- | --- | --- | --- |
| Inventory | Current hardware snapshot and limitations | Telemetry, triage, tuning, or purchase after the user asks | Infer a bottleneck or recommend parts |
| Triage | Likely fault layer and smallest next diagnostic | Telemetry for evidence; tuning only after stability; purchase only after evidence and user request | Tune an unexplained fault or sell an upgrade as a diagnosis |
| Telemetry | One-window evidence summary and its limits | Triage or tuning after the user asks; purchase only when the evidence addresses the stated decision | Treat a summary as diagnosis, stability proof, or permission to change settings |
| Tune | One-variable experiment and rollback | Telemetry for the same experiment; purchase only if the user asks and the target remains unmet | Suggest a new part because a control is locked or the silicon limit is reached |
| Purchase | Keep, tune/configure, repair, replace, rebuild, or wait | Tune only if the user chooses that option | Start a tuning session automatically |

## Handoff rules

### Identify the device first

Track identity as `confirmed`, `user-reported`, `unknown`, `unreadable`, or `conflict` using [device-identity.md](device-identity.md). Never turn corrupted text or a guessed encoding into a confirmed model.

Inventory is a safe evidence step when the hardware identity is unknown and the local Windows machine is accessible. For triage or tuning, offer the embedded read-only collector after explaining the standard versus privacy-redacted output and obtaining consent.

Use the resulting hardware snapshot to:

- select the correct CPU, GPU, laptop, or desktop route;
- avoid recommending a tool that the platform does not support;
- identify the memory generation, active GPU, firmware, and display context;
- reduce redundant manual questions.

Do not use it to claim:

- the current tuning profile is active;
- the system has a stable stock baseline;
- temperatures, power, clocks, or workload behavior are healthy;
- the user has a recovery route;
- an upgrade is justified.

Even a complete inventory leaves tuning-specific facts to collect: the tool or BIOS page in use, requested and applied values, sensor behavior, the repeatable workload, pass/fail evidence, and rollback.

### Inventory to anything

A fresh inventory establishes what is present. It does not establish:

- whether the hardware is stable;
- which configuration is active;
- which component limits the workload;
- temperature or power behavior;
- the cause of a fault;
- whether an upgrade is worth its net cost.

Continue only after the user states the desired outcome.

### Anything to telemetry

Telemetry may be entered directly, from inventory, from triage, or from an
active tuning experiment. Confirm the monitoring software and record exist,
ask only for the workload and sampling window needed to interpret them, and do
not impose the tuning gate on analysis alone.

If a file picker is cancelled or the window mixes idle, loading, load, and
recovery phases, state that no conclusion was produced and return to the
telemetry choice or the original task. When telemetry belongs to an active
experiment, link the summary to that experiment card and resume the same
experiment loop instead of starting a new one.

### Telemetry to triage, tuning, or purchase

A telemetry summary can support a hypothesis, but it does not establish a
fault, a stable baseline, a bottleneck, or a purchase need. Move forward only
when the user asks and the existing summary addresses the next decision. Carry
the exact workload, sampling window, sensor limitations, and contradictory
evidence into the destination mode.

### Triage to tuning

Move to tuning only when:

1. the machine is stable enough for a controlled test;
2. there is a stock or known-good baseline;
3. the user can restore that baseline;
4. the symptom is localized enough to choose one component;
5. the user explicitly wants an experiment rather than only a repair recommendation.

A tuning experiment is not a diagnosis shortcut. Do not use overclocking to mask an unstable stock system.

### Triage to purchase

Move to purchase only when there is evidence that:

- a component is faulty and repair is not the preferred route; or
- a measured workload limit remains after safe configuration and software options; or
- the user explicitly asks for replacement planning.

A crash, high temperature, or low score alone does not prove that buying a component solves the problem.

### Tuning to purchase

Purchase is outside a tuning-only request. If the user explicitly asks whether the tuned result justifies an upgrade:

1. finish classifying the current tuning round;
2. state the measured remaining bottleneck;
3. compare the existing configuration, repair, and cheaper software settings;
4. only then enter purchase mode with current price and compatibility evidence.

Do not recommend a purchase simply because a control is locked, the cooler is already at a limit, or a benchmark score stopped improving.

### Purchase to tuning

Tuning may be the cheapest useful action in a purchase assessment. Present it as an option with its risk and evidence burden. If the user chooses it, enter tuning mode and start with baseline and recovery; do not inherit an upgrade conclusion as permission to modify settings.

## Explicit multi-mode sequence

When the user asks for a complete hardware plan, use this order unless the evidence requires an earlier stop:

1. **Inventory:** establish the current machine and limitations.
2. **Triage:** resolve any unexplained stability, thermal, power, storage, or boot problem.
3. **Measure:** identify the actual workload bottleneck and target.
4. **Tune/configure:** evaluate reversible non-purchase options.
5. **Purchase:** assess a replacement only if the target remains unmet and the user wants that analysis.

No step authorizes an automatic hardware write, automatic elevation, security
change, or anti-cheat intervention. A user-started elevated read-only inventory
may be offered for named permission-dependent fields, never as a bypass.

## Mode-switch response

When changing modes, state the reason in one sentence. For example:

> 稳定性基线还没建立，所以现在继续排障，不进入超频或购买判断。

> 这轮显卡调校已经结束；你明确问是否值得换卡后，下面才进入升级判断，当前价格会单独标注。

> 配置已经读取完成。你只要求看配置，因此不自动判断瓶颈或推荐升级。
