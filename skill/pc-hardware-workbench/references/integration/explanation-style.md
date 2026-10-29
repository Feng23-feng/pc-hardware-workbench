# Parameter explanation style

Use this reference only for tuning-sensitive BIOS/UEFI settings, firmware
updates or flashes, clocks, voltages, power controls, fan policy, memory
timings, or hardware curves. Do not use it for ordinary operating-system or
software navigation.

## Trigger

Only when the same paragraph contains a candidate value for one of those
controls or an explicit instruction to change one of them, include the safety
notice in the user's current language:

- Chinese: `参数仅供参考，请以安全为第一要务。`
- English: `For reference only - put safety first.`
- Other language: an equivalent warning in that language.

Never mix the Chinese and English notices in one reply.

Do not add this notice to location-only explanations, concept-only
explanations, refusals without a candidate value, physical-safety stops, or
ordinary UI instructions. Merely opening a page or viewer, exporting telemetry,
identifying a model, toggling an ordinary display feature such as HDR, or
offering to continue checking later is not a parameter-change trigger.
A BIOS/UEFI change, firmware update or flash, or explicit instruction to change
a tuning-sensitive setting is actionable even when no numeric value appears.

When triggered, include the applicable Action/Analogy/Consequence explanation.

## Action

State what changes, where it changes, and what remains unchanged. For BIOS/UEFI,
use the exact visible menu or control label after verifying that layout. If a
label differs or one function is split among controls, describe the verified
function and ask which label the user sees; never invent a menu path.

## Analogy

Use one everyday comparison to make the effect intuitive. Label it as an analogy
when it could be mistaken for technical equivalence.

## Consequence

State the likely improvement, main downside or failure risk, signals that mean
stop, and how to recover.

## Depth

For beginners, persistent or BIOS/UEFI changes, firmware work, unclear recovery,
or difficult rollback, explain Action, Analogy, and Consequence in full.

For experienced users and low-risk reversible changes, use a compact explanation
that still states what changes, the main tradeoff, what means stop, and how to
recover. Omit the analogy when it adds no decision value.

Never present a bare number, offset, timing, profile, or actionable instruction
without the safety notice and an appropriately detailed explanation. A new
primary variable needs a new explanation even when an earlier round was
explained.
