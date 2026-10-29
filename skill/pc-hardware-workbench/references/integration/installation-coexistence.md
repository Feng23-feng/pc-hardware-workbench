# Installation coexistence

The integrated Workbench is the default entry when the user intentionally installs it alongside the original generic Skills.

## Recommended local policy

- `$pc-hardware-workbench` may use implicit invocation.
- Keep `$hardware-triage-framework`, `$upgrade-purchase-brake`, and `$guided-overclocking` available for explicit invocation as rollback or focused fallback.
- Set those three original Skills to `allow_implicit_invocation: false` on a machine that also has this Workbench.
  (On DeepSeek Harness the same intent is expressed with the
  `disable-model-invocation: true` frontmatter field, and explicit
  invocation is `/skill-name` rather than `$skill-name`.)
- Keep the personal hardware profile Skill explicit-only when it exists, so private fleet context is not pulled into generic questions.

This prevents automatic routing from selecting a legacy or personal entry when the user intended the integrated Workbench. The original Skills remain usable by explicit `$skill-name` invocation.

## Shared package

The share package contains only `pc-hardware-workbench`; it does not require or modify the original Skills. Do not include personal profiles or machine-specific records in the shared bundle.

## If the user prefers the old Skills

Reverse the policy explicitly: set the old Skill they want to implicit and set the Workbench to explicit-only. Do not leave multiple overlapping generic entries implicit unless the user accepts ambiguous routing.
