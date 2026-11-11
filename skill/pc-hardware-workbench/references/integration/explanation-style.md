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

## User-facing language layer

For a beginner, an uncertain user, or a simple request, lead with the result and
one next action. Add technical structure only when it changes the decision. Do
not make the user read a report-shaped “facts / measurements / history /
assumptions” breakdown before receiving help.

At the start of a substantial tuning or telemetry flow, offer the concise/detailed
choice once in the user's language:

- Chinese: “先给精简版；想看依据、术语或完整记录，就说‘展开详细’。”
- English: “Start with the concise version. To see the evidence, terminology, or a
  complete record, say ‘show details’.”
- Other language: an equivalent offer in that language.

Do not repeat this offer. If the user asks for detail, expand evidence, assumptions,
uncertainty, and terminology without asking mode again; the safety gate stays the
same.

Use the user's words when possible. The first time a necessary technical term
appears, explain it in plain language before showing the label. Do not display
internal JSON fields, gate names, or status templates unless the user is working
with a saved record or explicitly asks for them. Do not repeat the same safety
paragraph in every turn; apply the notice when a candidate value or actionable
change is actually present.

These are reference translations, not a script to dump at once:

| Label | Plain-language meaning |
| --- | --- |
| baseline | 原配置、未改设置时，在同一场景下重复测到的正常表现 |
| fixed workload | 同一个游戏场景、设置和测试步骤，重复比较前后结果 |
| offset | 在当前设置值基础上加或减多少 |
| dominant limit | 当前主要被什么拖住：功耗、温度、电压、负载还是软件限制 |
| thermal headroom | 温度和散热还剩多少余量 |
| effective clock | 实际持续跑到的频率或性能，不是软件里请求的目标值 |
| PerfCap | 监控软件显示的限流原因 |
| vBIOS | 显卡固件版本 |
| TGP/TDP | 芯片或平台的功率等级，不等于当前实测功耗 |
| WHEA | Windows 硬件错误记录 |
| PMIC | 供电控制芯片 |
| JEDEC | 内存的默认兼容规格 |
| SPL | 短时功耗上限 |
| P95 | 把结果排序后覆盖 95% 样本的分位值；用于看慢帧或尾部表现 |
| fallback | 测试失败时恢复到的上一个已知稳定值 |
| session-only | 只在本次测试中生效，不开机自动应用 |
| operating point | 当前实际出现的电压和频率组合 |
| XMP / EXPO | 主板和内存提供的一键内存预设 |
| Clear CMOS | 清除主板固件设置；具体做法必须按主板说明确认 |

When a beginner asks what a setting means, explain the outcome and tradeoff
before naming the control. When the user already uses a technical term, mirror
that term and explain only what is needed for the next decision.

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
