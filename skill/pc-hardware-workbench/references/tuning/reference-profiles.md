# Reference profiles

Use reference profiles to improve the question, the test order, and the failure checks. They are not a table of settings to transplant.

## Evidence order

Prefer references in this order:

1. the same device's own stock, known-good, and failed experiments;
2. a near-identical device with documented cooling, power, firmware, and workload;
3. the same component family with different cooling or firmware, used only to set expectations;
4. isolated screenshots or claims with unknown conditions, used only as a hypothesis to verify;
5. marketing claims or a single "stable" report, which are not sufficient evidence.

Never infer that the user can match a reference because the CPU, GPU, motherboard, memory module, or laptop model looks similar. Silicon variation, board power delivery, cooling, ambient temperature, firmware, and sensor accuracy can change the result materially.

## Reference profile record

Ask for or construct this minimum record:

```text
Device and platform:
Cooling and power constraints:
Firmware / driver / tuning tool:
Workload and settings:
Baseline profile and result:
One changed variable and candidate:
Test duration and pass criteria:
Temperatures, clocks, power, errors, artifacts:
Reboot / sleep / normal-use validation:
Decision and rollback:
Unknowns and why it may not transfer:
```

## Common reference archetypes

These archetypes help choose an experiment shape without supplying universal numeric values.

| Archetype | What it tests | Useful comparison | Main failure evidence |
| --- | --- | --- | --- |
| Stock baseline | Whether the machine is stable before tuning and how much variation the workload has | Same device, repeated on another day or after reboot | WHEA, crashes, throttle changes, inconsistent scores, rising temperatures |
| Efficiency / undervolt | Whether similar or acceptable performance can be held with lower temperature, power, or noise | Same device's stock baseline; a matched laptop with documented power and cooling | Idle instability, WHEA, artifacts, clock stretching, unexplained benchmark loss, reboot or wake failure |
| Mild daily frequency | Whether one small frequency step gives repeatable benefit while remaining usable | Same device's stable profile; a tightly matched cooling and power envelope | Temperature/power limit reached too early, performance regression, instability under sustained load |
| GPU one-axis tuning | Whether a core, memory, power, or voltage-curve change helps without artifacts | Same GPU model and workload with known temperatures and limits | Artifacts, driver timeout, black screen, hotspot or memory-junction rise, shared laptop power loss |
| Memory profile validation | Whether XMP/EXPO or one timing change remains correct and stable | Rated profile, same module rank/capacity and firmware behavior | Training failure, boot loops, sleep/wake failure, data errors, benchmark or application corruption |
| Benchmark-only profile | What the machine can complete for a short, bounded test | Separately recorded daily profile | Any crash or artifact; success does not imply suitability for daily use |

## Example of using a reference

Suppose the user's desktop has a stock baseline with a repeatable workload. A close reference shows that reducing voltage offset one UI step lowered temperature without reducing throughput, but that machine had a different cooler and motherboard.

The useful inference is:

- test one voltage-offset step while leaving ratios, limits, and fans fixed;
- use the same repeatable workload and compare performance and temperature;
- include idle, reboot, and a longer normal-use check because the reference's short test did not cover them;
- do not copy the reference's exact voltage, frequency, power limit, or "stable" conclusion.

The reference narrows the experiment; the user's own evidence decides whether the result transfers.

## Shareable experience card

When a user wants to help others, prepare a de-identified card for them to review. Include:

```text
Report confidence: single run / repeated test / daily-validated
Device class or optional exact model:
Cooling, power, firmware, driver, and ambient context:
Starting profile and repeatable baseline:
Goal and primary metric:
One-variable experiment:
Observed performance, temperature, power, and clock evidence:
Failures, symptoms, and repeatability:
Rollback and recovery result:
Remaining uncertainty and transfer limits:
```

The most useful lessons are often the failure signature, the recovery path, and the difference between a short benchmark and normal use. Remove serials, account names, precise locations, unique file paths, and unrelated personal details. Never upload, publish, or send the card without the user's explicit approval.
