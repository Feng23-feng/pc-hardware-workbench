# RTX 50 series public overclock reference

Retrieved: 2026-10-30.

Source class: controlled-media cross-board prior from TechPowerUp and KitGuru
reviews. This is stronger than an unattributed screenshot but remains less
specific than the user's own repeated baseline and does not establish a
universal stable limit.

## What the public data shows

- Blackwell memory requests above about `+375 MHz` (`+6000 MT/s` in the source
  wording) are commonly clamped; a larger requested value is not evidence that
  a larger applied value exists.
- Core results are reported as achieved average GPU clock, not software offset.
  Never convert an observed 3.1-3.3 GHz average clock into a `+MHz` slider value.
- The default-fan/default-voltage tables include many board designs. Board
  power limits, cooler design, and sample variance materially affect results.
- Raising the power ceiling often produces only a small additional FPS gain.
  Some boards already ship at their maximum ceiling.
- Blackwell reviews commonly lack a GPU Hot Spot sensor. GPU and memory
  temperatures do not establish connector or power-path safety.

## Second-source cross-check

KitGuru's tested maximum manual settings show that 5070-class boards can take a
larger experiment, while still being sample- and board-specific maxima:

| Sample | Core offset | Memory setting | Power setting | Observed game gain |
| --- | ---: | --- | --- | --- |
| RTX 5070 FE | +380 MHz | slider maximum +2000 MHz | up to about +10% | about +10% to +11% |
| RTX 5070 Ti MSI Ventus 3X | +420 MHz | slider maximum | power limit not adjustable | about +7% to +12% |

Do not reconcile those memory numbers with TechPowerUp's roughly +375 MHz
request clamp without a same-tool conversion. Slider units and what the driver
actually applies can differ. The more aggressive 5070/5070 Ti observations
remain evidence for the internal boundary, not permission to skip the one-step
protocol or jump both core and memory together.

## Controlled observations

| Tier | Reviewed boards | Maximum average core-clock range | Memory request | Power ceiling range |
| --- | ---: | ---: | --- | --- |
| RTX 5060 | 2 | 2915-3202 MHz | mostly +375 MHz | 145-170 W |
| RTX 5060 Ti | 7 | 3132-3227 MHz | +360 to +375 MHz | 180-234 W |
| RTX 5070 | 5 | 3146-3204 MHz | mostly +375 MHz | 250-300 W |
| RTX 5070 Ti | 9 | 3139-3286 MHz | mostly +375 MHz | 300-350 W |
| RTX 5080 | 9 | 3154-3312 MHz | mostly +375 MHz | 360-450 W |
| RTX 5090 | 5 | 2938-3086 MHz | mostly +375 MHz | 575-600 W |

These ranges are outcomes under review conditions, not transferable offsets.

## Candidate authority

Automatic candidate values and evidence labels are maintained only in
[gpu-auto-oc-tier-authority.json](gpu-auto-oc-tier-authority.json). The RTX 5080
entry is explicitly single-source and has no matched normalized core-offset
maximum; it must not be described as second-source cross-checked.

Memory remains a separate round. Start with no memory change, then use the
tool's displayed unit and a small step. Do not request values beyond the
Blackwell clamp merely to test whether another tool accepts a larger number.

## Evidence limits

- The retained evidence is a multi-board controlled-media set plus a
  sample-specific second source, not an independent-lab reproduction or broad
  community consensus.
- No matching second-source settings table was retained for 5060 Ti, 5080, or
  5090; do not invent a cross-check value for those tiers.
- The 5060 Ti 8 GB and 16 GB are separate capacity variants; capacity does not
  establish core or memory overclock headroom.
- Desktop and laptop Blackwell profiles must never be transferred.
- RTX 5090 power-path checks and the existing reduced-power/curve reference
  remain controlling.

## Primary pages

- RTX 5060 MSI review, overclocking page:
  https://www.techpowerup.com/review/msi-geforce-rtx-5060-gaming-oc/41.html
- RTX 5060 Ti 8 GB Gainward review, overclocking page:
  https://www.techpowerup.com/review/gainward-geforce-rtx-5060-ti-8-gb/43.html
- RTX 5060 Ti 16 GB ASUS TUF review, overclocking page:
  https://www.techpowerup.com/review/asus-geforce-rtx-5060-ti-tuf-16-gb/44.html
- RTX 5070 FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-5070-founders-edition/45.html
- RTX 5070 Ti Ventus review, overclocking page:
  https://www.techpowerup.com/review/msi-geforce-rtx-5070-ti-ventus-3x-pz/40.html
- RTX 5080 FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-5080-founders-edition/45.html
- RTX 5090 FE review, overclocking page:
  https://www.techpowerup.com/review/nvidia-geforce-rtx-5090-founders-edition/45.html
- RTX 5070 KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/nvidia-rtx-5070-review/39/
- RTX 5070 Ti MSI Ventus 3X KitGuru review:
  https://www.kitguru.net/components/graphic-cards/dominic-moass/msi-rtx-5070-ti-ventus-3x-oc-review/39/
