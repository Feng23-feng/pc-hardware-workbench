# Decision framework

For a functional problem, choose the least expensive option that plausibly solves it. For a preference purchase, compare the desired experience and opportunity cost rather than inventing a functional problem.

Before recommending a **functional performance upgrade**, use [upgrade-evidence.md](upgrade-evidence.md) to establish the active device, workload, measured limitation, non-purchase attempts, target, and compatibility unknowns. Classify preference, capability, repair, or future-project purchases before deciding which evidence they need.

## Classify purchase intent

Do not apply a performance-upgrade test to every purchase:

- **functional upgrade:** requires measured pain, a plausible bottleneck, compatibility, and value;
- **capability addition:** requires a concrete missing capability, such as capacity, interface, portability, or VRAM;
- **repair/replacement:** requires evidence that the old part is faulty or unreliable;
- **preference/aesthetic purchase:** does not require a fabricated performance need; assess budget, enjoyment, fit, compatibility, return policy, and opportunity cost;
- **planning/future project:** label projections as forecasts, not current bottlenecks.

“Keep” is not a moral judgment. For a preference purchase, compare “buy,” “wait,” and “don't buy” transparently instead of using performance evidence to deny a valid non-performance goal.

## Option ladder

### 1. Keep

Use when:

- the current hardware meets the target;
- the measured bottleneck is minor;
- cost, risk, or supply makes an upgrade unreasonable.

### 2. Tune or configure

Possible changes:

- graphics settings, resolution scaling, frame limits, or upscaling;
- cooling, fan curve, or dust cleanup;
- driver, BIOS, or application settings;
- storage cleanup or workload changes;
- memory profile only when compatibility and recovery are understood.

Require a baseline and one-variable testing for non-trivial tuning.

### 3. Repair

Prefer repair when:

- one known part is faulty;
- the repair is economical and safe;
- replacement would cost more without a meaningful capability gain.

Do not recommend board-level work without the skills, tools, and recovery path.

### 4. Replace one component

Use when the bottleneck is demonstrated and the replacement fixes that bottleneck.

Check:

- CPU socket and motherboard compatibility;
- GPU length, thickness, power connectors, and PSU headroom;
- RAM generation, channels, DIMM type, and supported frequency;
- storage interface and physical length;
- monitor port bandwidth and cable;
- cooler capacity and case clearance;
- driver and operating-system support;
- resale value and warranty of the current part.

### 5. Rebuild the platform

Require a material benefit across multiple target workloads. Include:

- CPU plus motherboard cost;
- possible RAM replacement;
- cooling changes;
- operating-system or software migration;
- downtime and resale risk.

### 6. Wait

Use when:

- launch pricing is inflated;
- drivers, firmware, or platform support are immature;
- availability is poor;
- a standards transition is near enough to matter;
- the current setup remains adequate.

## Bottleneck rules

- High CPU usage with low GPU usage suggests a CPU or software bottleneck.
- High GPU usage with low frame rate suggests GPU or settings limits.
- VRAM exhaustion is shown by allocation or memory errors, not just high usage.
- RAM capacity problems usually appear as paging, allocation failures, or inability to keep required applications resident.
- Storage speed affects load and transfer tasks; it rarely explains low game FPS.
- Display limits must be checked before diagnosing performance: resolution, refresh rate, cable, DSC, and port version.

Do not treat synthetic benchmark rank as proof of a real-workload bottleneck.

## Benefit thresholds

Use explicit thresholds when possible. A common default is:

- single-purpose incremental upgrade: at least about 20-30% relevant improvement;
- major GPU or platform replacement: at least about 30-35% improvement in the target workload, unless adding a missing capability;
- general responsiveness upgrade: require subjective latency improvement plus measured evidence;
- aesthetic or collection purchase: label it as preference, not performance value.
