# RTX 30 series public overclock reference

Retrieved: 2026-10-30.

Source class: two-outlet controlled-media cross-board prior. It is stronger than
an unattributed screenshot, but weaker than repeated local tests.

## What the public data shows

- Ampere core headroom varies more than a generation label suggests.
- GDDR6 cards (3060/3060 Ti/3070/3070 Ti) and GDDR6X cards (3080/3080 Ti/3090/
  3090 Ti) need different guard signals.
- GDDR6X can degrade in performance before visible artifacts when error replay
  activates. Falling throughput is a failure signal, not room to push higher.
- Memory clock and GPGPU/transfer-rate units are not interchangeable with
  software offsets.
- RTX 3080/3090-class power limits and transient behavior warrant connector and
  PSU evidence before power experiments.

## Reported manual settings and outcomes

| Sample | Core offset | Memory result | Power target | Result |
| --- | ---: | --- | --- | --- |
| RTX 3060 EVGA Black | +150 MHz | +500 MHz | 112% | about +5.8% Time Spy |
| RTX 3060 Ti FE | +70 MHz | +1300 MHz | not standardized | about +6-7% target games |
| RTX 3070 FE | +115 MHz | 14 to 16.2 Gbps | not standardized | about +9-11% target games |
| RTX 3070 Ti FE | +105 MHz | +1050 MHz | 110% | about +5-7% target games |
| RTX 3070 Ti Inno3D | +100 MHz | +1100 MHz | 100% | about +5-7% target games |
| RTX 3070 Ti Suprim X | +140 MHz | +1025 MHz | 106% | about +5-7% target games |
| RTX 3080 FE | +60 MHz | +800 MHz retained | not standardized | about +7-8%; performance drops above about +900 MHz memory |
| RTX 3080 Ti FE | +210 MHz | +810 MHz | 114% | about +4-9% target games |
| RTX 3080 Ti Gigabyte | +135 MHz | +1300 MHz | 100% | about +4-9% target games |
| RTX 3080 Ti Palit | +220 MHz | +0 MHz in screenshot | 110% | about +4-9% target games |
| RTX 3090 MSI | +70 MHz | +950 MHz, about 21.4 Gbps | not standardized | about +2-5% target games |
| RTX 3090 Ti Suprim X | +110 MHz | +1270 MHz | not adjustable | average about 2155 MHz; +4-7% |
| RTX 3090 Ti GameRock | +75 MHz | +1110 MHz | not adjustable | average about 2086 MHz; +4-7% |

## Candidate authority

Automatic candidate values, evidence classes, source counts, observed-maximum
ratios, and confidence are maintained only in
[gpu-auto-oc-tier-authority.json](gpu-auto-oc-tier-authority.json). This file
records the public observations used to judge them.

The RTX 3060 Ti sample is lower than its current tier start. The RTX 3080 and
RTX 3090 Ti starts are active values near or at cited sample offsets. Those
statuses are encoded in the authority and must not be described as
conservative.

Memory remains a separate round. Begin with core only and stock power. On GDDR6X,
require memory-junction temperature evidence when exposed. Never copy a sheet's
maximum memory offset to another board.

## Evidence limits

- The retained data are media samples, not a broad statistical consensus.
- The RTX 3060 Ti and RTX 3080 observations each come from a single cited
  sample. The 3090 Ti has two samples from one review.
- Tier starts are bounded experiments, not optima or safety guarantees.
- A clean short benchmark does not establish daily stability.

## Primary pages

- RTX 3060 Legit Reviews:
  https://www.legitreviews.com/evga-geforce-rtx-3060-black-video-card-review_225910/16
- RTX 3060 Ti KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-3060-ti-founders-edition-review/34/
- RTX 3070 KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-3070-founders-edition-review/30/
- RTX 3070 Ti KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-3070-ti-review-ft-inno3d-msi/38/
- RTX 3080 KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-3080-founders-edition-review/30/
- RTX 3080 Ti KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-3080-ti-review-ft-gigabyte-inno3d-palit/39/
- RTX 3090 KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/msi-rtx-3090-gaming-x-trio-review/30/
- RTX 3090 Ti KitGuru:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-3090-ti-review-ft-msi-palit/36/
