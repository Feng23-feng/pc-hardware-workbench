# Configuration-based tuning expectation

Use this after the tuning gate and before selecting a candidate increment. Derive an expectation direction from the user's actual platform and goal; do not turn a model name into a universal voltage, clock, timing, or power value.

## Required inputs

- exact platform and component;
- desktop, laptop, or MoDT and shared thermal/power constraints;
- cooling context: desktop cooler/airflow answer, or laptop official power-envelope reference;
- current stable profile and exposed controls;
- user's single primary objective;
- fixed workload and guard evidence;
- prior matched card and its tested variable when available.

## Direction by route

### GPU efficiency, lower temperature, or lower noise

Expected direction: a core voltage/frequency curve change should lower power and temperature while preserving frame time within the user's tolerance. First obtain the current game-load voltage/frequency point using [gpu-curve-baseline.md](gpu-curve-baseline.md).

Start with one GPU core curve or voltage/frequency control. Do not stack memory offset in the same round. Follow-up evidence must include frame time or throughput, power, core temperature, memory junction when exposed, effective clock, and artifacts.

### GPU performance

Expected direction: distinguish pure frequency overclocking from curve undervolt/overclocking. For curve work, use the measured baseline voltage point; for pure frequency work, keep the curve method unchanged. Validate core first, then memory separately.

Frame time repeatability and artifacts are stronger evidence than a one-run benchmark score. Laptop GPU changes must account for shared CPU/GPU power and thermal budgets.

### CPU efficiency, temperature, or noise

Expected direction: a supported CPU undervolt/load-line or vendor efficiency control may reduce package temperature and power at similar performance.

Do not describe CPU undervolting as an automatic performance uplift. Follow-up evidence must include package temperature/power, effective clocks, fixed workload result, low-load stability, WHEA, and reboot behavior.

### CPU performance

Expected direction: after confirming the stock power and thermal envelope, test one ratio, power limit, or supported per-core control.

Higher instantaneous frequency alone is not evidence of better sustained performance. Compare fixed throughput and stability.

### Memory

Expected direction: if below rated profile, validate XMP/EXPO as one complete profile first; after that, change one timing or one related timing group.

Never transfer timings between different die revisions, ranks, capacities, or laptop/desktop form factors. Follow-up evidence includes actual frequency/timings, training, cold boot, reboot, workload result, temperature, and data or stability anomalies.

## Required expectation card

Present:

- expected direction;
- the single first variable class;
- primary tradeoff;
- platform-specific constraint;
- previous-round reference when comparable;
- evidence required for the next follow-up.

Do not promise an expected percentage gain without a matched baseline. If the configuration or prior result is insufficient, request a read-only snapshot or the prior card instead of inventing a range.

## Cooling expectation rules

- Ask for cooling information only after the inventory identifies the form factor.
- On desktops, ask only for the target component's cooler plus relevant case airflow; accept unknown.
- On laptops, do not ask for a desktop-style cooler inventory. Use the exact model, vendor mode, and official platform power envelope as a provisional ceiling.
- State that official power limits describe the configured platform envelope, not proof that the installed cooling can sustain it.
- Actual temperature, power, effective clocks, throttling, fan behavior, and fixed-workload results must correct or reject the initial expectation.

## Optional online calibration

If the user permits current online research and local evidence is insufficient, use [online-evidence.md](online-evidence.md) to look for:

- official specifications, firmware notes, and documented control behavior;
- exact devices when available, or similar platforms/components with the same form factor class, comparable power/thermal limits, driver/firmware generation, and workload;
- repeated failure signatures, recovery problems, and later follow-up after a claimed success.

Use online material only to refine the expected direction, first variable class, guard signals, and the smallest sensible test step. Do not copy another user's voltage, clock, offset, power limit, fan curve, memory timing, or profile as the candidate value. Record source date, exact matching conditions, evidence quality, and mismatches.

Use the similarity levels in [online-evidence.md](online-evidence.md) to distinguish useful similar-platform evidence from weak analogies. If network access is unavailable, the user declines research, or only weak evidence exists, continue from the local configuration and prior card. State the uncertainty rather than inventing a community consensus.
