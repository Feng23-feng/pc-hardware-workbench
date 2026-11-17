# Known limitations: 0.1.0-rc.1

This is a release candidate, not a production release.

## Entry and traffic

- The formal default entry remains closed.
- Default traffic remains off.
- The RC package must not be described as publicly released.
- A clean Windows acceptance run has not yet been recorded.
- The `pchw-source-hosted` SkillDock panel is promised only for Codex.
- DSH and other hosts may use the PCHW Skill's chat, collection, and CSV
  analysis, but they do not get this SkillDock panel host support.
- The launcher requires `CODEX_THREAD_ID`; absence fails closed with
  `thread_binding_missing`.

## Interaction model

- The supported PCHW path is the current Codex user conversation and current
  Task.
- The release does not promise a universal multi-provider workspace.
- Background autonomous return and multi-Task source-hosted operation are not
  supported.
- Coordinator recovery remains closed.

## Permissions

- Local telemetry analysis uses the SkillDock permission card.
- The accepted R7 path used exactly one `one-time` grant and consumed it.
- Opening or switching the panel does not widen an existing grant.
- The Agent host may have a different sandbox or network policy from SkillDock;
  one policy does not describe the other.

## Component boundary

The DSH read-only observer is a separately frozen compatibility component and is
not included as a PCHW release entry. The PCHW archive contains only the
conversation-bound source-hosted profile. It does not authorize credential
copying and does not establish a universal multi-provider promise.

## Hardware safety

SkillDock does not modify BIOS/UEFI, firmware, drivers, clocks, voltages, power
limits, fan curves, memory timings, or operating-system settings. Hardware
writes remain manual user actions. Unstable hardware must not be tuned before a
stable baseline is restored.
