SkillDock + PC Hardware Workbench
User Guide

This is the integrated Codex + SkillDock package. It installs both the PC
Hardware Workbench Skill and the local SkillDock Runtime. The portable tools
and DSH-only package are distributed separately.

Supported environment
=====================

Requires Windows 11 64-bit, Codex Desktop, and Microsoft Edge.
The PC Hardware Workbench panel runs in the current Codex conversation.

Install
=======

1. Extract the complete package to a writable local folder.
2. Double-click Install.cmd.
3. Wait for the installer to report completion and leave the window open until
   it finishes.

If an older version of PC Hardware Workbench is already installed, do not delete
the old Skill first. Install.cmd detects the existing installation and performs
the safe upgrade automatically. The upgrade backs up the old version and
restores it if replacement fails.

Open PC Hardware Workbench
==========================

After installation, open the current Codex conversation, describe the hardware
problem, and accept the offer to open the graphical workspace. For example:

    "My games start dropping frames after about 20 minutes.
     This is the HWiNFO CSV. Can you open the PC Hardware Workbench
     for this task?"

The Skill starts the panel in the current conversation and carries the current
Task, question, and supported attachments into the page. Do not start
SkillDock.exe manually or configure ports, tokens, or environment variables.

Submit data and grant permission
================================

1. Select the CSV in the panel.
2. Enter the question and submit it.
3. When the permission card appears, choose “仅本次允许”
   (Allow this time only).

The permission applies only to that local analysis. It does not become a
long-term grant. Do not let another person or Agent click permission, submit,
or analyze actions for you.

After the same attachment has completed one successful local analysis, a repeat
analysis may show “同一附件后续分析” (repeat analysis for this attachment). It
applies only to that CSV in the current Task for two hours. A different
attachment still requires a new “仅本次允许” decision.

If the panel does not open automatically
========================================

In Codex “Ask for approval” mode, automatic browser handoff may be unavailable.
The page or Skill will then show “Open the panel manually”.

Use the short-lived link or local .url shortcut provided by the prompt to open
the same panel. Continue in that page with the CSV and the
“仅本次允许” (Allow this time only) permission.

If the runtime is unavailable, the workspace conflicts, or the panel cannot
start, continue in the current Codex conversation. Do not create a second Task
or conversation.

View results
============

When analysis finishes, the page shows a real chart, a conclusion for the
current data, supporting and conflicting evidence, uncertainty, and low-risk
recommendations. The page updates automatically when the result returns.

After closing and reopening, the same Task, attachment, chart, and conclusion
should be restored.

Safety
======

- The panel and Skill never automatically modify BIOS, firmware, drivers,
  clocks, voltage, power limits, fans, memory timings, or OS settings.
- Every hardware setting change requires your own confirmation and action.
- When evidence is insufficient, the result gives low-risk collection guidance
  instead of presenting an unknown result as a confirmed conclusion.

Uninstall
=========

Open the installed SkillDock program directory and run its SkillDock uninstall
script. The default uninstall removes the program and shortcuts while keeping
Task data and backups. Remove Task data only when the uninstall flow explicitly
offers that cleanup.

Limitations
===========

- The panel currently works only in the current Codex conversation.
- The current release provides a Windows 64-bit installation.
- Results depend on the CSV contents, time range, and sampling quality.
- Closing the panel does not continue hardware analysis in the background.
