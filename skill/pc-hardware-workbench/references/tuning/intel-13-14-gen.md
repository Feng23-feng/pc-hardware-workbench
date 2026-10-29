# Intel 13th- and 14th-generation CPU caution

Use this whenever the detected CPU is an Intel Core 13th- or 14th-generation
model. First confirm whether the system is desktop or mobile and preserve the
exact CPU model. The documented high-power desktop instability history does not
justify declaring every 13th/14th-generation CPU damaged, and it does not prove
that a mobile CPU has the same failure mode.

> Use the localized safety notice defined in SKILL.md; do not mix languages.

## Risk notice

Tell the user:

- this CPU generation includes a documented desktop high-power stability and
  degradation concern;
- a crash, POST failure, WHEA event, compile failure, or game instability at
  stock settings must be triaged as a possible CPU/platform fault first;
- do not use overclocking, undervolting, fixed voltage, or a lower power profile
  to hide an unexplained stock instability;
- maintain current motherboard or OEM firmware/microcode and use the vendor's
  recommended default profile before judging the CPU;
- confirm whether the CPU is retail boxed or tray/OEM and whether the purchase
  invoice and warranty are available. Do not require the serial number in a
  shared report.

For a desktop 65 W-or-higher 13th/14th-generation Core CPU with stock
instability, use the official Intel/motherboard support and warranty path.
Warranty policy can change, so cite the current official policy rather than
inventing a deadline.

## Tuning route

Only after stock/default stability is established may the user consider a
supported CPU undervolt or fixed-voltage/fixed-frequency experiment. Prefer the
platform's supported adaptive or curve control when it is stable; a static
daily voltage can sacrifice idle efficiency and must be recorded as its own
choice. Change one primary control, preserve a known-good firmware profile,
and validate low-load, reboot, WHEA, temperatures, power, and the target
workload.

Do not expose hidden firmware controls, bypass microcode protections, or apply
another user's voltage/frequency values. If the platform exposes no supported
control, say so and continue monitoring or stock-profile validation.
