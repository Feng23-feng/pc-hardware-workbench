# GPU memory tuning playbook

Use this reference when the user wants to interpret a local memory reading or
tune GPU memory. Read [vram-and-memory-bus.md](vram-and-memory-bus.md) in the
background, but do not make the user read or repeat the full mechanism.

## Response contract

Default to:

1. one sentence stating what is known and what is not;
2. one next action or one smallest missing question;
3. one brief reason that changes the decision;
4. stop.

Do not dump every gate field, every memory generation, or the full bandwidth
formula unless the user asks why. Ask one question at a time. Preserve answers
and continue from the current step.

Use deeper mechanism only when:

- the user asks what a clock value means;
- two tools disagree;
- exact-model official bandwidth is requested;
- artifact or stability evidence is ambiguous;
- the user asks why a candidate is blocked.

## Distinguish four request types

- **Concept:** explain terms and formulas without requiring live machine data.
- **Official specification:** use an exact SKU and dated official sources. A
  theoretical bandwidth result does not need driver, vBIOS, or fixed-load data.
- **Local reading:** identify the exact GPU, raw sensor label, tool/version,
  unit, and reporting basis. Do not call a high or divergent value wrong merely
  because it differs from another tool.
- **Tuning or stability:** use the complete tuning gate below.

## Tuning sequence

### 1. Establish the card and control

Confirm:

- exact GPU and desktop/laptop form factor;
- VRAM type and capacity;
- supported memory control in the user's tuning tool;
- monitoring tool and raw memory field.

If the form factor or exact card is unknown, ask only the first item needed.
Do not substitute an RTX family or GDDR generation for the installed card.

### 2. Establish the current state

- Save or record the current profile and recovery route.
- Confirm the core profile is stable before changing memory.
- Keep core curve, memory, and power limit as separate experiment rounds.
- Run the stock/known-good baseline in the target workload.

### 3. Explain the control at use time

Before the user moves a memory slider or offset, explain in plain language:

- this changes the memory request, not a guaranteed effective data rate;
- the tool may display a physical, effective, or vendor-scaled number;
- bandwidth and FPS are not proven by the offset alone;
- do not stack memory and core changes in one round.

Include the localized parameter safety notice required by `SKILL.md`.

### 4. Make one bounded memory test

Use one supported memory control and one small user-applied step appropriate to
the exact tool and card. Do not provide a universal MHz offset. For a laptop,
discourage a large VRAM overclock because shared power, heat, and harder
recovery increase the cost of a bad step.

### 5. Re-run the same evidence

Use the same workload and sampling window. Compare:

- average and percentile FPS or throughput;
- frame time and any worsening pacing;
- core and memory clocks with their reported basis;
- board power, core temperature, and memory-junction temperature when exposed;
- artifacts, texture corruption, flicker, driver resets, WHEA, crashes, or
  restarts.

No artifacts alone is not a pass. A benchmark score alone is not a pass.

### 6. Decide

- **Keep:** repeatable improvement or acceptable behavior with no guard-signal
  failure.
- **Repeat:** result is within noise or evidence is incomplete.
- **Revert:** artifacts, resets, crashes, worse frame pacing, unexpected clock
  collapse, or unsafe temperature/power behavior.

Daily stability still requires idle, light load, reboot, sleep/wake, and normal
use checks. Keep benchmark-only and daily profiles separate.

## Common answer shapes

For “显存怎么调”:

> 先只调显存，不要和核心曲线一起改。先告诉我具体显卡型号，以及这是台式还是笔记本；确认后我会带你完成“保存基线 → 小步调整 → 同负载复测 → 异常恢复”。

For “14001 MHz 是不是 14GHz”:

> 不能直接这样理解。这个数字取决于监控工具的显示口径；它可能是等效时钟或厂商缩放值，不等于 14 GHz 物理显存频率。先看这个字段来自哪个工具、具体显卡是什么，才能解释它。

For an exact official specification request:

> 如果 SKU 和官方规格已确认，可以直接计算理论峰值带宽；这属于纸面规格，不是你这台机器的实测带宽或稳定性结论。

## Boundaries

- Never infer bandwidth from a clock-only sensor value.
- Never compare raw memory clocks across GDDR generations.
- Never turn an offset into a universal data-rate or bandwidth claim.
- Never claim a memory profile is daily-stable from a short artifact-free run.
- Never use a hidden or manufacturer-limited control. Follow the existing
  advice-intensity rules.
