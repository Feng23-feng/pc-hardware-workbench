# Beginner-guided GPU auto overclock

Use this route when the user says they are new to tuning, afraid of damaging
the machine, unable to find settings, or does not know what data is needed. Do
not require them to diagnose the GPU, select HWiNFO columns, interpret a CSV,
or identify the dominant hardware limit. The skill performs those steps from
read-only evidence and presents only the next user action.

This route changes explanation, intake, and pacing. It does not bypass the
baseline, recovery, one-variable, thermal, power-path, or anti-cheat rules.

## Starting promise

Explain briefly:

> 我可以替你看数据和判断下一步。你只需要配合三件关键操作：允许我读配置、确认怎么恢复原样、在同一个游戏场景里测试一次。需要安装监控或找工具时，我一次只带你做一步。第一轮只改一个变量，也不会让设置随开机自动应用。

Do not promise that the hardware cannot be damaged. State that the workflow
uses a saved restore point, one reversible variable, and a stop rule.

## Assisted sequence

### 1. Establish the device

Reuse a current inventory, screenshot, or user statement before asking again.
If the exact GPU, driver, or desktop/laptop form is unknown on an accessible
Windows machine, explain the local read-only collector and ask one consent
question before running it. Prefer standard output for the user's own machine.
If collection is declined, ask for a cropped system or GPU utility screenshot.

Do not ask the user to look up a serial number, architecture code, VRAM type,
or tuning vocabulary.

### 2. Build the safety net

Ask which supported tuning software they already use, naming common official
or vendor-supported options only far enough to recognize it. Explain that a
vendor tool is preferred and that a third-party tool is usable only if it
supports the installed GPU. If the user cannot identify the tool, ask for a
cropped screenshot of its main window.

Before a frequency or power change, help the user identify:

- the current/default profile;
- the control or preset that returns to it;
- whether the tool can apply a profile at Windows startup.

If they cannot locate a restore control, ask for a screenshot rather than
guessing a menu path. Keep changes blocked if no credible recovery exists.
For the first rounds, ask the user to keep automatic startup application off.

### 3. Pick one familiar workload

Prefer a game the user already plays with a built-in benchmark or a reliably
repeatable save point. If they do not know, offer these explained outcomes:

- a game's built-in benchmark gives the simplest repeatable comparison;
- a fixed save/route gives the most relevant real-game result but takes more
  manual repetition;
- a synthetic benchmark is only a screening layer and still needs one real
  target workload for a daily conclusion.

Help them record resolution, preset, frame cap, power mode, AC/battery state,
and the approximate test segment. Accept ordinary language and translate it
into the fixed-workload card.

### 4. Collect the stock baseline

If an eligible monitoring record already exists, reuse it. If not, guide one
record at a time:

1. use the current official stable HWiNFO from its official page;
2. open Sensors-only;
3. start logging all sensors to a `.csv`;
4. run the chosen scene after a short warm-up;
5. stop logging after a steady interval;
6. return the file to the skill.

The user does not select individual columns. Analyze the file with
`scripts/analyze-telemetry.ps1`, use a steady window, and report only the
measurements needed to choose the next variable. If timestamps and workload
boundaries are unclear, ask one question or label the result preliminary.

Do not call a single screenshot or a remembered value a complete baseline.
When a sensor is unavailable, lower test aggressiveness and state the limit.

### 5. Complete the technical gate for the user

Turn collected evidence into plain language. Infer the dominant limit, thermal
headroom, target, and variable order when the evidence supports it. Ask only
for facts that local evidence cannot establish, such as the current displayed
offset or whether the user can see and restore the default profile.

Run `scripts/suggest-gpu-overclock.ps1`. Do not expose the JSON, gate names, or
parameter names unless the user asks. Do not present several candidate
profiles at once.

### 6. Present one action

For the first round, show a compact card with no optional controls:

- what will change and what stays unchanged;
- the current and candidate value in the exact tool's displayed unit;
- one plain-language analogy;
- the expected direction and main tradeoff;
- the saved restore action;
- one test action the user can repeat in the same game scene;
- one visible warning sign and one result to compare.

Keep every control other than this round's selected variable unchanged. The
selected variable may be a core offset/clock target, a measured curve anchor, or
a supported power-limit reduction when thermal/power pressure dominates. State
exactly which one changes and explain the relevant term in plain language.
Do not apply the setting at Windows startup unless a separate persistence check
has passed.
Start a new primary variable only after the prior round is reviewed.

For a novice-facing response, this compact card takes precedence over the full
one-screen template in `fixed-workloads.md`; use the full template internally as
a data checklist, not as a form to recite to the user.

The candidate paragraph must include the localized safety notice from
`SKILL.md`.

### 7. Review without making the user analyze data

Analyze the candidate telemetry when available. Ask for visual observations
only when telemetry cannot establish them, using a short prompt such as:

> 这一轮画面正常吗？有没有花屏、闪烁、黑屏、驱动报错，或者比原来更卡？

Then state keep, continue, revert, or stop, with the reason in one or two
sentences. If continuing, present exactly one next action. If evidence is
inconclusive, repeat the same baseline or stop; do not raise the value to
“make the result clearer.”

For a request for a practical first candidate or daily-use goal, read
[usable-start-and-state.md](usable-start-and-state.md) and default to
`usable-start`. A clean pass is not enough: a material benefit above noise plus
acceptable heat, power, artifact, and actual-performance evidence means `keep`
and stop frequency escalation. Do not automatically move from core to memory
just because the core value did not crash.

## When the user cannot answer

| Missing input | Beginner response |
| --- | --- |
| GPU or laptop model | Offer read-only inventory; accept a cropped system or GPU utility screenshot if collection is declined. |
| Tuning tool or current offset | Ask for a cropped screenshot of the relevant control; do not guess from the model. |
| Recovery route | Stop tuning and guide the user to the visible default/restore control; do not accept “I accept the risk” as a substitute. |
| Repeatable workload | Choose a built-in game benchmark or a saved game route; explain the choice before asking. |
| Monitoring record | Help create one HWiNFO Sensors-only CSV rather than asking the user to interpret columns. |
| Thermal or power limit | Analyze the steady workload window; if the evidence stays ambiguous, reduce the test or stop rather than inventing a limit. |
| “Just change it for me” | Explain that this Skill does not operate the tuning UI or write hardware settings; continue by giving one click-level action for the user to apply. |
| “I am afraid to try” | Keep the first change session-only, preserve the default profile, explain the one-step rollback, and let the user stop at any point. |

## Beginner stop rules

- Any artifact, flicker, corruption, black screen, driver reset, unexpected
  restart, rapidly rising temperature, unusual connector heat, or fan failure
  ends the round and requires restoring the saved profile.
- Thermal or power pressure ends positive core or memory escalation. Use only a
  supported efficiency change, or stop.
- Never ask a novice to combine core and memory changes, raise a hidden limit,
  edit firmware/BIOS, use an unsupported power-path control, or defeat
  anti-cheat.
- Do not enable automatic startup persistence during the first validation.
- Do not call a single clean run daily-stable.

## Communication style

Use one short result sentence, then one action. Translate terms in context:

- baseline: “这台电脑目前没改设置时的正常表现”;
- offset: “现在设置值向上或向下加多少”;
- dominant limit: “现在主要卡在功耗还是温度”;
- rollback: “出问题时点哪里恢复原样”.

Do not keep calling the user a beginner, dump a questionnaire, repeat the
safety model, or require a quiz. If the user becomes more comfortable, reduce
hand-holding while preserving the evidence card and stop rules.
