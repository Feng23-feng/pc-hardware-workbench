# DeepSeek Harness entry

If DeepSeek Harness does not automatically load `AGENTS.md`, use this file as
the project instruction or explicitly ask the model:

```text
先阅读 AGENTS.md，再按其中的电脑硬件工作台适配规则回答。
```

`AGENTS.md` is the adapter entry. `skill/pc-hardware-workbench/` contains the
complete routed workflow, references, scripts, and tests.

Do not claim local hardware was read without a working local filesystem and
PowerShell toolchain.
