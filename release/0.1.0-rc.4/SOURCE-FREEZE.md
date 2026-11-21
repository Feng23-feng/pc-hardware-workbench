# Source freeze for 0.1.0-rc.4

The RC builder records the branch, HEAD, dirty-entry count, Git status SHA-256,
packaged-PCHW dirty scope, and build timestamp in `SOURCE-STATE.json`. Official
RC builds require clean SkillDock and packaged PCHW sources.

An explicitly flagged `-AllowDirtySource` build is supported only for a local
acceptance candidate when the user prohibits commits. Such a package records
`release_state=local-candidate-clean-ui-pending` and
`gates.commit=local-uncommitted`; the verifier requires a matching explicit
flag and still keeps clean UI, install/uninstall, signoff, tag, push, upload,
and formal release pending. The builder never creates a commit, tag, or remote
change.

## Included package inputs

- `server.mjs`
- `package.json`
- `VERSIONING.md`
- `lib/`
- `public/`
- `schemas/`
- compiled `SkillDock.exe`
- bundled Node.js `24.22.1`
- launcher install and uninstall scripts
- PCHW `2.8.0` runtime/reference subset with `tests/` excluded; R7 evidence was
  produced from source version `2.7.4`
- frozen `integrations/skilldock/` scripts
- RC release and acceptance documentation

## Excluded working-tree areas

- `.git/`
- `dist/`
- `work/`
- `node_modules/`
- `runtime*/`
- `agent-diagnostics/`
- test fixtures and generated screenshots
- accidental root files named `$null` and `$null)`
- local Skill installation metadata such as `INSTALL-INFO.json`
- credentials, capability tokens, handoff secrets, launch results, and server
  process metadata
- mock adapters, test runners, fixture entries, agent bridge host, command-line
  developer entry, and DSH launch harness
- `agent-bridge-host.mjs` and `open-workbench.mjs`
- the DSH read-only observer, which remains an independent frozen component

The package manifest is the authoritative file-level allowlist for the built
candidate. The outer ZIP sidecar is the authoritative transfer hash.

## PCHW identity and provenance

```text
current authoritative source version: 2.8.0
source PCHW Skill tree SHA-256:      1cf35a8f7941bd270d92250b594d9c93638a9b3d08ebf4923057265424c5bb8b
current source file count:            135
PCHW source commit:                   417b41a6f96382f25ccbe354e784cee1378e0e99
R7 evidence source version:           2.7.4
R7 source tree SHA-256:               f6eab543414ef6b208706b4367b7adb152db3bd5c5288390a0f30a5189a95eb1
R7 source file count:                 134
```

The current source hash is frozen from the clean PCHW commit above. The R7 hash
is retained only as provenance for the accepted user-experience receipt. The
final candidate build records the exact PCHW branch, commit, packaged-Skill dirty
count, global dirty count, and status hashes in `SOURCE-STATE.json`.
