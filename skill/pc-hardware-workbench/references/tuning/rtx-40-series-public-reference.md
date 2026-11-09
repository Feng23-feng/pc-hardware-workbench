# RTX 40 series public overclock reference

Retrieved: 2026-10-30.

Source class: controlled-media cross-board prior from TechPowerUp and KitGuru
reviews. It is stronger than an unattributed screenshot, but weaker than
repeated local tests or a matched-brand record.

## What the public data shows

- RTX 40 pages report achieved average GPU clocks, not slider offsets.
- Memory units differ: some pages show a `+MHz` request; others show actual
  memory clock. Never convert between them.
- Marginal core-clock gains do not map one-to-one to FPS gains.
- The 4060 Ti 8 GB and 16 GB differ by capacity; capacity does not establish
  overclock headroom.
- RTX 4070 Ti, 4070 Ti Super, 4080, 4080 Super, and 4090 are separate tiers.
- RTX 4090 remains power-path and 16-pin sensitive.

## Second-source cross-check

KitGuru reports maximum manual settings on review samples, not first-step
recommendations:

| Sample | Core offset | Memory offset | Power setting | Observed game gain |
| --- | ---: | ---: | --- | --- |
| RTX 4070 Super FE | +210 MHz | +1280 MHz | 240 W, about +9% | about +5% to +9% |
| RTX 4070 Ti Super MSI | +190 MHz | +1600 MHz | locked at 285 W | about +5% to +7% |
| RTX 4080 FE | +205 MHz | +1620 MHz | maximum 355 W | about +8% to +9% |
| RTX 4080 Super FE | +185 MHz | +1200 MHz | maximum 355 W | about +3% to +8% |
| RTX 4090 FE | +260 MHz | not normalized by page | not normalized by page | about +5% to +10% |

These maxima inform evidence labels and internal bounds. They do not replace
the authority's first-step values. Board, VBIOS, temperature, and software
units still matter.

## Controlled observations

| Tier | Boards | Maximum average core clock | Memory evidence |
| --- | ---: | ---: | --- |
| RTX 4060 | 10 | 2645-3006 MHz | actual 2585-2745 MHz |
| RTX 4060 Ti 8/16 GB | 9 | 2780-2988 MHz | request +360 to +470 MHz |
| RTX 4070 | 5 | 2811-2911 MHz | actual 1453-1623 MHz |
| RTX 4070 Super | 5 | 2739-2875 MHz | actual 1483-1643 MHz |
| RTX 4070 Ti | 6 | 2989-3091 MHz | actual 1440-1500 MHz |
| RTX 4070 Ti Super | 10 | 2845-2971 MHz | actual 1533-1613 MHz |
| RTX 4080 | 8 | 2938-3079 MHz | actual 1580-1650 MHz |
| RTX 4080 Super | 9 | 2892-2991 MHz | actual 1608-1658 MHz |
| RTX 4090 | 8 | 2974-3018 MHz | actual 1470-1600 MHz |

## Candidate authority

Automatic candidate values and their confidence are maintained only in
[gpu-auto-oc-tier-authority.json](gpu-auto-oc-tier-authority.json). This file
records public samples and should not duplicate the candidate table.

The current RTX 4080 and RTX 4080 Super starts are active values close to
cited maximum offsets. Their authority entries carry very low start confidence
and must not be described as conservative.

Memory stays a separate round. Use the current tool's displayed unit and keep
the stock power ceiling as the first experiment except for a separate,
evidence-backed power route.

## Evidence limits

- The range data are one controlled-media source across many boards; the
  second source is sample-specific and does not cover every tier.
- A tested maximum average clock is not a daily stable value.
- Board cooling, VBIOS, power-limit exposure, and sample variance remain
  material.
- The 4090's dedicated connector and power-path checks still take precedence.

## Primary pages

- RTX 4060 MSI review, overclocking page:
  https://www.techpowerup.com/review/msi-geforce-rtx-4060-gaming-x/41.html
- RTX 4060 Ti FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4060-ti-founders-edition/41.html
- RTX 4060 Ti 16 GB review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4060-ti-16-gb/39.html
- RTX 4070 FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4070-founders-edition/41.html
- RTX 4070 Super FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4070-super-founders-edition/43.html
- RTX 4070 Ti TUF review, overclocking page:
  https://www.techpowerup.com/review/asus-geforce-rtx-4070-ti-tuf/41.html
- RTX 4070 Ti Super Strix review, overclocking page:
  https://www.techpowerup.com/review/asus-geforce-rtx-4070-ti-super-strix-oc/43.html
- RTX 4080 FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4080-founders-edition/41.html
- RTX 4080 Super FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4080-super-founders-edition/43.html
- RTX 4090 FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-4090-founders-edition/41.html
- RTX 4070 Super KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-4070-super-review/41/
- RTX 4070 Ti Super KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-4070-ti-super-review-ft-msi/41/
- RTX 4080 KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-4080-founders-edition-review/35/
- RTX 4080 Super KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-4080-super-review/43/
- RTX 4090 KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-4090-founders-edition-review/35/
