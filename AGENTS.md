# Repository Instructions

These instructions are mandatory for every task that modifies this repository.
They supplement the parent and global Codex instructions.

## Required Reading Before Site or Skill-Evolution Work

Before changing `docs/skill-evolution/`, the file orrery, its generator, or its
release metadata, read:

- `docs/skill-evolution/ORRERY-LESSONS.md`
- `docs/skill-evolution/GITHUB-PUBLISH-TROUBLESHOOTING.md`

Treat those documents as release constraints, not background reading.

## Non-Negotiable UI Rules

- A data-only update must reuse the accepted renderer. Do not rewrite its
  projection, camera, orbit, depth, or interaction core.
- Visually verify the actual render at desktop, intermediate, and mobile widths.
  A successful JavaScript syntax check is not visual acceptance.
- Keep file and metadata labels visible by default in a subdued style. Hover,
  focus, and selection may strengthen them.
- When selection exposes relationships, brighten related paths, bodies, and
  labels together.
- Do not increase orbital speed to hide dropped frames. Fix repeated work first.
- Display headings `<h1>` through `<h4>` must not contain Chinese sentence
  punctuation such as `，。！？；：` or `、`. Use short phrasing, spacing, or a
  controlled line break.
- Use `文件集摘要` for the generated content digest. Never imply that it is a
  device fingerprint.

## Required Verification

For changes covered by the file orrery or evolution site, run all applicable
checks before reporting completion:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\build-skill-orrery.ps1 -Check
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check-skill-evolution-site.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\check-version-consistency.ps1
git diff --check
```

For release-integrity changes, also verify:

- output is stable under `zh-CN` and `en-US`;
- a clean checkout reproduces the generated artifacts;
- remote tree SHA equals local tree SHA;
- Windows CI succeeds on the exact remote commit;
- Pages succeeds on the exact remote commit;
- live frozen metadata and the user-visible page are verified.

Do not report “published”, “frozen”, or “complete” when only Pages succeeded,
when CI is still running, or when the live page still serves an older commit.

## GitHub Transport and Tags

If ordinary GitHub HTTPS operations fail, follow
`docs/skill-evolution/GITHUB-PUBLISH-TROUBLESHOOTING.md`.

Do not force-push, reset a user branch, or move a published tag without explicit
user approval. Do not create a final release tag until the same commit passes CI
and Pages.

## Personal Skill Boundary

The `orbital-visualization` Skill under `$CODEX_HOME/skills` is private and local.
It is not part of this repository and must not be copied into the repository,
release packages, Pages output, GitHub, or any public artifact unless the user
explicitly reverses this policy.
