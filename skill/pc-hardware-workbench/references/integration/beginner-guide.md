# Beginner guide

Use this route when the user says they do not know what to choose, does not understand the terms, or explicitly asks to be guided one step at a time.

## Interaction rule

Do not expose the internal mode names first. Ask what the user wants as an outcome, for example:

> 你现在最想解决哪件事？
> 1. 我只想知道这台电脑是什么配置
> 2. 电脑有故障，比如黑屏、重启、卡顿或过热
> 3. 我想用监测软件查看温度、频率、功耗等数据，但还没有记录
> 4. 我有一份监控软件导出的记录，想分析结果
> 5. 我想超频或降压
> 6. 我想判断该不该升级
> 0. 我还是不知道，帮我选

Explain only the choice needed for the next step. Ask one question at a time. If the user cannot answer an optional field, state the safe default and continue; do not make them learn jargon before receiving any help.

The goal is not to keep the user dependent on the beginner route. Before closing a hands-on task, summarize what evidence mattered, the recommended next step, and the recovery rule. The user may optionally confirm or correct this in one sentence. Do not require a teach-back, written answers, or a learning review before giving the result.

For any multi-step route, a cancelled file picker, declined collection, or missing optional input must state what did not happen and return to the relevant next choice. Do not silently fall back to the opening menu.

If a fresh hardware snapshot is already available, reuse it in later tuning or troubleshooting steps. Before reuse, remind the user that a recent CPU, GPU, memory, storage, motherboard/laptop, monitor, or power-adapter change may make the report stale; refresh in that case. Do not make the user repeat the same inventory merely because the task moved to a new submenu.

## Route the plain-language choice

- **Configuration only:** explain the privacy output choice as “只给自己看” versus “要发给别人看”; then use the inventory route after consent.
- **Fault or instability:** begin with the observable symptom and whether Windows starts. Use the triage route. Stop escalation for burning smell, liquid, arcing, damaged connectors, or visible electrical damage; do not tell the user to keep power-cycling it.
- **No monitoring record yet:** use the monitoring-software onboarding below. Do not ask the user to select a file or explain CSV columns first.
- **Monitoring analysis:** before asking for a file, confirm the user has monitoring software and an exported record. If the software is installed but no record exists, teach the HWiNFO Sensors-only logging steps. When the user does not yet have the software installed, also give the download card rules from the HWiNFO section below: mirror order, the advertisement blocks, the network-dependent CDN caveat, and the raw-CSV metadata warning. With a record available, explain that it is commonly a `.csv` file and use the telemetry route. If the user cannot specify warm-up or duration, analyze the whole file and label the result as mixing idle, loading, load, or recovery phases. Do not call a mixed window stable evidence.
- **Tuning:** explain that a beginner can still inventory and monitor, but no voltage, frequency, timing, power, fan, BIOS, or firmware setting is issued before the exact machine, known-good baseline, fixed workload, and rollback route are known. If the user does not know one of those items, teach them how to obtain it using the matching section of `references/tuning/intake.md`; do not end with only “not possible.” Prefer quick mode only after those facts exist.
- **Purchase:** first classify the goal as functional, capability, repair, preference, or future planning. For a functional need, ask what currently feels inadequate and establish the workload; for an explicit preference purchase, do not invent a performance problem or call “keep” the default.

When the user cannot explain the problem yet, keep the interaction adaptive: ask only the next question that changes the decision, use an existing report or prior card as a default, and do not repeat routine explanations the user has already understood. Safety and abort conditions remain explicit.

## HWiNFO (monitoring software) and CSV

When the user needs to create a monitoring record:

1. recommend the current stable HWiNFO release from the official page: https://www.hwinfo.com/download/;
2. state that button names and menu positions can differ between HWiNFO versions, so use the labels visible in the current version;
3. tell the user to open **Sensors-only**, not the summary/settings window;
4. start sensor logging, save a `.csv` file, run the chosen workload, then stop logging;
5. state that HWiNFO is a read-only monitor in this workflow and does not apply hardware settings;
6. do not send users to repacks, bundled installers, cloud-drive mirrors, or forum attachments.

After giving download or recording instructions, return to the monitoring-analysis preflight instead of ending at the main menu. The user can then confirm that a record exists and continue.

For the HWiNFO download card, teach this order instead of letting the user guess:

1. for a novice, choose **Installer** when available; use Portable only when the user needs no installation or the skill/tool specifically requires a portable file;
2. in **Free Download**, choose **Local (U.S.)** first because it is the direct file on the official `hwinfo.com` host; “U.S.” describes the server location, not an eligibility restriction;
3. if the official direct file is unreachable or unusually slow, choose **SAC ftp (SK)** next; it is another download source linked from the official page;
4. use **dAppCDN (Fast CDN)** only after the other two fail. Despite its “Fast CDN” label, users in some networks have observed timeouts; do not keep waiting or retrying indefinitely;
5. warn that LanSweeper, DWG FastView, `Try Now`, and `OPEN` blocks are advertisements, not HWiNFO download buttons;
6. do not claim that every mainland-China network requires a VPN. Access can vary by ISP and CDN route; try a normal browser, another download option, or another network before discussing a VPN;
7. do not bundle the third-party installer in a shareable Skill or portable package. Provide the official page, this choice order, and optional local signature verification.

The download-card labels and advertisement names above were observed on
2026-10-26 and may change. Always verify that the user is on the current
official page; keep the source/signature rules even if the layout changes.

This is a distinct beginner route from analyzing a file that already exists. Do not phrase “I have a record” as cover for users who have not started monitoring.

If the user has never seen a CSV, describe it as “monitoring software saved its table as a file whose name usually ends in `.csv`.” Do not require them to understand column formats.

When sharing outside their own machine, prefer the analyzed summary. A raw HWiNFO CSV can contain appended device metadata; redact or review it before sharing if needed. Use the analyzer's `-HideFileName` option when the source filename may contain a name, client, location, or project.

## “I still do not know”

If the user cannot choose a task:

1. ask whether the computer is currently usable enough to read its configuration;
2. if yes, offer the read-only inventory after the privacy choice;
3. if no, route to the smallest safe troubleshooting question;
4. do not ask for a technical component name, exact model, serial number, purchase price, or timing value merely to keep the conversation moving.

## Terminology

Translate terms when first needed:

- warm-up window -> “前面哪一段先不计入统计”;
- CSV -> “监控软件保存成表格的记录，文件名通常以 `.csv` 结尾”;
- privacy-redacted -> “隐藏型号，适合发给别人”;
- quick/deep tuning -> “先做一轮简单尝试” / “需要更完整的验证记录”;
- baseline -> “现在没改设置时是否稳定”;
- rollback -> “出问题时怎么恢复原来的设置”.

After routing, name the task only when the user could otherwise confuse the current and previous requests. Do not prefix the reply with a mode label, keep calling the user a beginner, or repeat the same explanation in every reply.
