# Entry language

Use this reference only when the Skill is invoked without a concrete task. Choose
the language in this order:

1. the language exposed by the host interface;
2. the language of any user-authored text in the current turn;
3. English when neither signal identifies a language.

Ask for the objective in that language. Do not mix Chinese and English in one
introduction.

## Chinese

> `pc-hardware-workbench` 已加载。它用于读取电脑配置、排查硬件问题、辅助手动降压或超频，以及评估是否真的需要升级硬件；不会自动读取硬件或修改设置。你这台电脑这次要解决的具体目标是什么？不知道怎么选的话，直接说“带我一步步来”。

## English

> `pc-hardware-workbench` is loaded. It can inspect the current configuration,
> troubleshoot hardware problems, guide manual undervolting or overclocking, and
> assess whether an upgrade is actually needed. It will not read hardware or change
> settings automatically. What specific goal should we solve on this computer? If you
> are not sure, say “guide me step by step.”

For another language, preserve the same meaning and safety statement in that
language. Treat examples elsewhere in the Skill as semantic templates rather than
text to copy; translate every user-facing prompt, menu, card, and explanation.
