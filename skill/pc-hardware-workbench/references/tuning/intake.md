# Tuning intake and access

Collect only what the current objective needs. A tuning decision made from a model name alone is not reliable.

## Universal tuning entry gate

This gate applies to every user and every tuning route. Do not enter the experiment loop or propose a personalized candidate setting until all five items are known:

1. **Target and platform:** component, desktop/laptop/MoDT class, readable exact or closely matched hardware identity, and the control the platform actually exposes.
2. **Stable starting state:** current stock or known-good profile, recent normal-use behavior, an in-workload baseline record for the target component, and no unexplained reboot, shutdown, POST, display, driver-reset, corruption, thermal, or power-path instability.
3. **Objective:** the component being tuned and whether the goal is lower temperature/noise, higher sustained performance, a benchmark result, or a balanced daily profile.
4. **Recovery:** the saved profile and a credible route to restore it, including whether the user can reach the machine if display, network, or boot fails.
5. **Measurement:** one repeatable workload, one primary result, guard signals, and the conditions that reject the test.

General explanation, read-only inventory, and monitoring preparation may happen before the gate is complete. Personalized values, offsets, timing changes, power limits, fan curves, BIOS changes, or firmware changes may not.

If the user says “just give the value,” return to the first missing gate item. Do not treat urgency, confidence, consent, or a promise to accept risk as evidence that the missing item exists.

Unreadable, corrupted, placeholder, or conflicting model text is not a completed platform identity. Follow [device-identity.md](../integration/device-identity.md). Block personalized tuning when the unreadable field affects firmware, power limits, exposed controls, or recovery. Do not overblock when independently readable component and platform evidence already resolves those facts.

- Evidence ownership: the user listing hardware facts, recalling settings, or
  describing what a profile contains is not the same as supplying evidence.
  "You told me X, so X is my baseline" is the failure this rule exists to stop.
  Trigger: a remembered value is offered as the baseline. Never accept a remembered reading as present-state evidence.
- Instrument first: when the user cannot supply a reading, treat the reading
  itself as the thing to establish -- ask how to obtain it, or offer the
  read-only collector. Trigger: a measurement is unavailable. Do not substitute
  the user's description for it.
- Keep one decision per turn. Ask a second user-only fact only when it is
  required to interpret or act on the first answer. Trigger: several gate facts
  are missing. Never deliver the five gate items as one questionnaire. When a
  safety stop leaves one next action, its one-next-step rule is the operative limit.
- Blocking scope: when one required fact is missing,
  block only the step that depends on it; keep unaffected work moving. Trigger:
  a missing fact has a limited dependency. Never stop the whole tuning route.

## Guided remediation for a missing gate item

When an item is missing, teach the user how to obtain it. Do not stop at “the condition is missing.” Keep personalized values blocked until the item is resolved.

| Missing item | Coach the user through |
| --- | --- |
| Stable starting state | Save the current profile, restore the vendor/stock/default profile, reboot, and use the machine normally long enough to confirm that the instability is gone. If black screens, unexplained restarts, corruption, cooling failure, or power-path damage remain, switch to triage before tuning. |
| Exposed control | Identify the exact component and open the supported BIOS, vendor utility, or tuning tool. For GPU work, verify the option in the current official vendor software; for CPU work, verify the supported vendor utility or BIOS control; for memory, verify the board's memory profile/timing controls. If the control is absent or hidden, do not guess a substitute or bypass firmware. |
| Objective | Offer a small set of outcomes such as lower temperature/noise, steadier sustained performance, higher benchmark result, or a balanced daily profile. Explain the tradeoff and ask the user to choose. |
| Recovery | Record every current profile/value before changing anything; locate the tool's reset-to-default control, the vendor default profile, BIOS load-defaults action, or the platform's documented recovery method; confirm the user can reach the machine if the display or network fails. Never treat “I accept the risk” as recovery. |
| Fixed measurement | Use software the user already owns: the same game save or built-in benchmark, a repeatable render/export, or a supported synthetic benchmark. Record resolution, presets, frame cap, power mode, and sampling period. If no baseline exists, make the first run the baseline rather than inventing a pass result. |

After coaching, return to the same missing gate item first. Preserve every answer already supplied, ask one check question, or offer read-only inventory. When the item is resolved, continue with the next missing item; do not restart the gate. Only then proceed to a candidate experiment.

For GPU curve work, the in-workload baseline must include the representative voltage/frequency point or range observed in the fixed workload. If voltage is not exposed or no stable load point can be identified, do not invent a voltage-point method; use a supported offset-only route or continue monitoring.

## Device and objective

- Exact desktop, laptop, MoDT, or other system; whether it is physically accessible.
- OS, CPU, GPU and VRAM, motherboard or laptop model, BIOS/driver versions.
- Memory generation, capacity, population, rated speed, actual speed, rank, die, and PMIC when available.
- Cooling, power supply or adapter, connector condition, ambient conditions, and physical clearance.
- Current daily profile, benchmark-only profile, last known stable values, and every relevant tool that is currently resident.
- For Intel Core 13th/14th-generation CPUs, whether the processor is retail
  boxed or tray/OEM, whether the purchase invoice and warranty are available,
  and whether stock/default instability is present; do not require a serial
  number in a shared report.
- Workload, resolution, settings, repeatable benchmark or scene, and current baseline performance.
- User priority: FPS, minimum FPS, rendering/compile throughput, temperature, noise, efficiency, benchmark score, capacity, or preference.
- Preferred starting route: GPU, CPU, or memory; efficiency-first, performance-first, or balanced daily use. Treat this as a preference, not proof that the platform exposes the desired control.
- Hard limits: thermal, acoustic, power, stability, warranty, portability, anti-cheat, or budget constraints.

Laptop and desktop are different thermal, power-sharing, firmware, and recovery environments. Do not treat a desktop as automatically safe or a laptop as incapable of useful tuning. Start where the user wants to learn if the platform supports it, then explain any missing control.

## Access permission

Ask which evidence the user permits:

- manual values or screenshots;
- read-only local hardware inventory;
- read-only monitoring exports or logs;
- user-applied settings in a specified tool or BIOS page.

For read-only collection, explain what will be read, the sampling interval and duration when relevant, and whether the result may contain device or part identifiers. Do not request credentials, full serial numbers, exact addresses, or account information. Crop or redact serials before sharing screenshots.

Prefer data the user can export without changing device state:

- CPU: requested and effective clocks, package/core temperatures, package power, voltage if exposed, throttle reasons, and WHEA/machine-check events.
- GPU: core and memory clocks, voltage if exposed, board power, limits, temperatures, hotspot or memory-junction temperature when exposed, fan behavior, driver events, and frame-time or throughput result.
- Memory: BIOS or tuning-software requested values, monitoring values where exposed, training/boot behavior, and a workload result appropriate to the change.
- System: ambient conditions, adapter or power-supply state, workload details, and the exact monitoring period.

If live telemetry is needed, state its collection window and stop condition first. Do not keep background logging running without agreement. If the only way to expose a sensor is to elevate, install a driver, disable a protection, or inject into a protected process, omit that sensor and say why.

Do not confuse these values:

- requested setting versus applied firmware value;
- applied value versus observed sensor value;
- average clock versus effective work completed;
- a clean launch versus a stable result.

## Recovery preflight

Before a setting that can affect boot or stability, establish:

- the saved stock or known-good profile;
- how to restore defaults;
- Clear CMOS, safe mode, external display, another boot device, or other applicable recovery route;
- whether the user can reach the machine if the display or network fails after reboot;
- whether the workload can be stopped without data loss;
- whether the user can recover remotely if the machine becomes unreachable.

If there is no credible recovery path, do not propose the persistent change.

## Reference evidence

Ask whether the user already has a stock or known-good record, an earlier tuning log, or a repeatable benchmark result. The user's own dated baseline is usually more useful than an unfamiliar review or screenshot.

When using an external reference profile, record:

- exact product or tightly matched platform class;
- cooling, power delivery or adapter, chassis, ambient conditions, and relevant limits;
- firmware, driver, and tuning-tool versions;
- workload, resolution, settings, and result;
- which controls were changed, in what order, and what failed;
- whether the setting was validated for sustained use or only a short benchmark;
- what remains unknown about the user's sample and configuration.

Use a reference to choose a sensible test direction, comparison range, and failure checks. Do not copy another machine's voltage offset, core ratio, power limit, GPU offset, or memory timings. Similar hardware does not prove a similar stable range because silicon, cooling, firmware, power delivery, and measurement can differ materially.

## Stop and defer

Do not start a high-load tuning experiment when any of these is present:

- no POST or repeated unexplained shutdowns;
- burning smell, arcing, liquid damage, heat-damaged connectors, or visibly damaged power delivery;
- a repaired or uncertain power path operating outside its verified envelope;
- cooling failure, disconnected fan/pump, or rapidly rising hotspot temperature;
- filesystem corruption, failing storage, or ongoing data recovery;
- encrypted storage with an unverified recovery key;
- protected software that conflicts with the tuning tool.

Read-only identification or a conservative stock profile may still be possible, but it does not authorize load testing.
