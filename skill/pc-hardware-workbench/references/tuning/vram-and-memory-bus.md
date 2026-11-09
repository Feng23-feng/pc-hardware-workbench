# VRAM clocks, data rate, and bandwidth

Use this reference whenever a task mentions GPU memory clock, VRAM frequency,
memory bandwidth, memory overclocking, GDDR/HBM type, or conflicting clock
values from monitoring tools.

Last source review: 2026-11-09.

## Separate the quantities

Do not treat every value labelled “GPU Memory Clock” as the same thing.

- **Physical storage clock** is a memory-device clock. Its relationship to
  transfers depends on the memory signalling mode.
- **Command clock** is a controller-side timing basis and is not automatically
  the data rate per pin.
- **Effective data rate** is normally expressed in transfers per second
  (`MT/s`) or gigabits per second per pin (`Gb/s/pin`).
- **Tool-scaled display value** is whatever the monitoring tool chooses to
  display after an API read, multiplication, division, or architecture-specific
  conversion.

The field label alone does not establish the basis. Preserve the raw sensor
name, monitoring tool and version, GPU identity, and unit. Use
`clockBasis: unknown | physical | effective | vendor-scaled`, defaulting to
`unknown` when the source does not document its conversion.

## Bandwidth formula

For a conventional dedicated-memory interface:

```text
theoretical peak GB/s = data rate Gb/s per pin x bus width bits / 8
```

The formula uses the per-pin data-rate basis, not an arbitrary displayed
memory MHz. It produces a theoretical peak and does not prove application
throughput.

Examples:

- 28 Gb/s per pin x 256 bit / 8 = 896 GB/s
- 20 Gb/s per pin x 256 bit / 8 = 640 GB/s
- 28 Gb/s per pin x 512 bit / 8 = 1792 GB/s

Keep three bandwidth values distinct:

1. official theoretical peak from a source-backed specification;
2. a calculation based on a known observed data-rate basis;
3. achieved application throughput.

## Memory generations

Do not apply one MHz-to-data-rate multiplier across GDDR generations.

- GDDR6 commonly uses an NRZ-style signalling basis.
- GDDR6X uses PAM4 and transfers more than one bit per symbol.
- GDDR7 uses PAM3. NVIDIA documents the resulting per-pin data-rate and
  bandwidth directly rather than exposing a universal clock multiplier.
- HBM uses wide stacked interfaces and a different topology; do not apply a
  GDDR bus-width or clock heuristic to it.

Cross-generation comparisons must use source-backed per-pin data rate and bus
width, not raw monitor MHz.

## Common GPU examples

- NVIDIA RTX 5090 Laptop: 24 GB GDDR7, 256-bit, 896 GB/s theoretical peak.
- NVIDIA RTX 5090 desktop reference design: 28 Gb/s per pin, 512-bit,
  1792 GB/s theoretical peak.
- AMD RX 9070 XT: 20 Gb/s per pin, 256-bit, 640 GB/s theoretical peak.
- AMD RX 7900 XTX: 20 Gb/s per pin, 384-bit, 960 GB/s DRAM peak. Infinity
  Cache bandwidth is a separate cache metric and must not replace the DRAM
  figure.

## Interpreting high readings

A high memory-clock reading is not automatically an error or an overclock.
GDDR7, effective-clock reporting, and vendor-specific scaling can all produce
values far above older GDDR6 displays.

For example, NVAPI through LibreHardwareMonitor may report the memory clock
domain as `GPU Memory`, while LibreHardwareMonitor converts the returned
frequency to MHz without recording its basis. Therefore a reading such as
`14001 MHz` means only that NVAPI returned the basis LHM displayed. It does not
establish 14.001 GHz physical DRAM clock or 14.001 Gb/s per pin.

Do not calculate a specific card's bandwidth directly from such a reading.
Use the exact SKU's official data rate and bus width, and label the result
theoretical. If comparing LHM and GPU-Z values, compare field names, tool
versions, units, and documented conversion before deciding whether they
conflict.

## Tool and offset rules

- A memory offset is a request in a particular tool and vendor API. Do not
  convert it to a physical clock or bandwidth without the tool's documented
  mapping.
- Different tools can display physical, effective, or scaled clocks.
- Do not compare offsets across AMD, Intel, and NVIDIA as if they use one unit.
- A valid high reading can still require context before any overclocking
  advice. Safety gating belongs to the tuning decision, not to basic concept
  explanation.

## Minimum evidence by task

- **Concept explanation:** no machine evidence required. State the formula and
  units.
- **Official theoretical bandwidth:** require an exact GPU/SKU and a dated,
  source-backed VRAM type, bus width, and per-pin data rate. Label the result
  theoretical.
- **Local sensor interpretation:** require the exact GPU, raw sensor label,
  monitoring tool/version, unit, and clock basis when known. Leave the basis
  unknown when it cannot be established.
- **Memory tuning or stability conclusion:** additionally use
  [gpu-memory-playbook.md](gpu-memory-playbook.md) and the universal tuning
  gate in [intake.md](intake.md).

## Sources reviewed

- NVIDIA RTX Blackwell GPU Architecture:
  <https://images.nvidia.com/aem-dam/Solutions/geforce/blackwell/nvidia-rtx-blackwell-gpu-architecture.pdf>
- NVIDIA RTX 50 Series Laptops:
  <https://www.nvidia.com/en-us/geforce/laptops/50-series/>
- Micron GDDR7:
  <https://www.micron.com/products/memory/graphics-memory/gddr7>
- Micron GDDR6X:
  <https://www.micron.com/products/memory/graphics-memory/gddr6x>
- AMD Radeon RX 9070 XT:
  <https://www.amd.com/en/products/graphics/desktops/radeon/9000-series/amd-radeon-rx-9070xt.html>
- AMD Radeon RX 7900 XTX:
  <https://www.amd.com/en/products/graphics/desktops/radeon/7000-series/amd-radeon-rx-7900xtx.html>
- LibreHardwareMonitor 0.9.6 NVIDIA clock source:
  <https://github.com/LibreHardwareMonitor/LibreHardwareMonitor/blob/v0.9.6/LibreHardwareMonitorLib/Hardware/Gpu/NvidiaGpu.cs>
