# Skill-triggered interface

Status: primary product direction.

## User experience

The user installs a domain Skill. The user does not manually start a separate
SkillDock application as the normal workflow.

When the active Task benefits from a graphical surface, the Skill integration
ensures that the local runtime is running, creates or joins the Task, opens the
loopback surface, and returns the URL to the Agent conversation.

```text
install Skill
    ↓
use the Skill in Codex/DSH/another Agent
    ↓
the Agent decides that a surface is useful
    ↓
the Skill launches or reuses the local runtime
    ↓
browser surface opens for the current Task
    ↓
chat and surface can continue the same Task
```

Simple questions and explanations stay in chat. A surface appears only when it
adds real interaction value, such as a choice tree, telemetry chart, evidence
table, artifact download, permission decision, or guided experiment.

## Runtime boundary

`SkillDock.exe` is a development name for the local runtime launcher. It is an
implementation detail, not the product's primary entry point. The final package
may install it as:

- a shared per-user runtime under `%LOCALAPPDATA%`;
- a runtime installed by the domain Skill installer;
- a portable runtime bundled with a Skill distribution.

The runtime must expose an idempotent `ensure` operation that starts one local
instance, reuses an existing healthy instance, and returns the Task URL in a
machine-readable form. A desktop shortcut is a development convenience only.

## Skill launcher

Each surface-capable Skill needs a small launcher integration. The Agent calls
it from the active Task. The launcher:

1. resolves the Agent workspace;
2. starts or reuses the runtime;
3. creates a Task handoff or panel-owned Session appropriate to the Agent;
4. returns the loopback URL and Task reference;
5. falls back to chat with a clear reason if the local surface cannot start.

The launcher may not silently repeat device collection, choose a different
Skill, broaden permissions, or claim that an independent Agent Session is the
same provider Thread.

## Natural-language trigger

Users do not need to know the launcher script, context file, channel ID, cursor,
or Agent workspace. Treat ordinary phrases as explicit surface intents:

- `打开操作面板`
- `用面板继续`
- `把这个任务放到工作台`
- `把结果放到面板里`
- `同步面板`
- `把面板里的结果拿回来`

For launch intents, the Agent generates the compact context, stable channel ID,
Task reference, and cursor internally, then returns only the useful link and
task state. For return intents, it calls the sync script with the remembered
channel and cursor and continues the same Task.

When a complex Task would clearly benefit from a surface, the Agent may ask once:
“这个任务要不要打开操作面板继续？” A negative answer keeps the work in chat.
Do not expose implementation fields unless the user is debugging the integration.

## Installation decision

The shared runtime should be installed once per user, while the domain Skill
remains independently versioned. The Skill installer is responsible for
installing or verifying the runtime when the user wants surface support.

Shipping the full runtime separately to users and asking them to double-click it
is not the primary workflow. It remains useful for deterministic development,
diagnostics, and recovery.
