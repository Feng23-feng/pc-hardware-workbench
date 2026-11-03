# PC Hardware Workbench / DeepSeek Harness adapter

This package provides:

- `AGENTS.md` / `DEEPSEEK.md` adapter instructions;
- the complete `skill/pc-hardware-workbench/` tree;
- test guidance and build metadata;
- no local hardware reports, telemetry, evidence caches, screenshots, or secrets.

## Use as a project adapter

1. Extract the ZIP.
2. Open the extracted outer folder.
3. Load `AGENTS.md` or `DEEPSEEK.md` according to the Harness version.
4. Ensure the Harness can read files and run authorized local PowerShell.

## Install as a Skill tree

Copy:

```text
skill/pc-hardware-workbench
```

to the Harness Skill directory:

```text
<dsh-home>/skills/pc-hardware-workbench
```

The default `dsh-home` is `%USERPROFILE%\.dsh` unless `DSH_HOME` is set.

## Boundaries

- HardwareWrite: none
- Automatic elevation: none
- Live LHM: explicit consent and already-running LHM only
- Network lookup: depends on Harness tools; RAG evidence is written locally
- Broad distribution approval: no
