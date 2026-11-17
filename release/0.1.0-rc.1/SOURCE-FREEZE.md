# Source freeze for 0.1.0-rc.1

The RC builder records the branch, HEAD, dirty-entry count, Git status SHA-256,
and build timestamp in `SOURCE-STATE.json`. It refuses to build unless both the
SkillDock checkout and its sibling PCHW checkout are clean Git repositories. It
also refuses to build when `dist` still contains a root-level ZIP. The builder
never creates a commit, tag, or remote change.

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
canonical clean source tree SHA-256:  ceb800d596a68ea5630607ed5371a52816f2eebc1c9993af43330355c4c76f8c
current source file count:            135
R7 evidence source version:           2.7.4
R7 source tree SHA-256:               f6eab543414ef6b208706b4367b7adb152db3bd5c5288390a0f30a5189a95eb1
R7 source file count:                 134
```

The current source hash is the canonical clean checkout produced from the PCHW
commit and its `.gitattributes`. An older working tree could hash differently
because unconverted CRLF files were still present even when Git reported the
same content blob. The R7 hash is retained only as provenance for the accepted
user-experience receipt. The final candidate build records the exact PCHW
branch, commit, clean/dirty count, and Git status SHA-256 in `SOURCE-STATE.json`.
The package verifier rejects missing or mismatched provenance and requires zero
dirty entries in both repositories before the package can pass inventory
verification.
