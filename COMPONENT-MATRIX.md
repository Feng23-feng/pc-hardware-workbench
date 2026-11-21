# Component and evidence matrix

Snapshot: 2026-11-21 (+08:00)

This is the canonical version-and-support matrix for the SkillDock / PC
Hardware Workbench delivery. Release assets are immutable; a newer matrix does
not rewrite an older public tag.

## Products

| Surface | Local source candidate | Latest public asset | Contains | Promised scope | Evidence state |
| --- | --- | --- | --- | --- | --- |
| SkillDock Runtime | `0.1.0-rc.4` | `0.1.0-rc.3` | Runtime, embedded Node, browser surface | Codex current conversation only | R7 real-user-path evidence is from an earlier Runtime; rc.4 has automated and package gates only |
| PCHW Skill | `2.8.0` source; `2.8.0-rc.2` standalone asset reused | `2.8.0-rc.2` | Skill instructions, references, scripts | Codex supported; DSH and other hosts are structural-install candidates only; no panel promise outside Codex | Core automated suite and Skill validation; no DSH/other-host end-to-end certification |
| PCHW Portable | `2.8.0` source; `2.8.0-rc.2` asset reused | `2.8.0-rc.2` | Standalone menu and local tools | Windows without an Agent | Existing portable validation; not rebuilt for rc.4 |
| Runtime-only package | `0.1.0-rc.4` | `0.1.0-rc.3` | Runtime, embedded Node, runtime installer | An installed compatible PCHW Skill; Codex panel only | Package inventory and runtime verification; Skill-only plus Runtime-only end-to-end combo remains an open test |
| Integrated user package | `0.1.0-rc.4` | `0.1.0-rc.3` | PCHW Skill, SkillDock Runtime, installer, uninstaller, licenses | Windows 11 x64, Codex Desktop, Microsoft Edge; current conversation only | Automated clean/upgrade/install/uninstall/purge gates; Clean Windows and final user signoff pending |

## Version identities

```text
SkillDock source candidate:       0.1.0-rc.4
Latest public SkillDock release:  0.1.0-rc.3
PCHW Skill content version:       2.8.0
Standalone PCHW asset label:      2.8.0-rc.2 (reused, not rebuilt)
PCHW source tree:                 1cf35a8f7941bd270d92250b594d9c93638a9b3d08ebf4923057265424c5bb8b
PCHW source tree files:           135
PCHW packaged install subset:     73c1b69fb4bb8453ee5cfe72e0a261eba557a9811a40b04cc59c8105e46bcff5
PCHW packaged subset files:       103
PCHW source commit:               417b41a6f96382f25ccbe354e784cee1378e0e99
Bundled Node:                     24.22.1
Bundled SQLite:                   3.53.4
```

The standalone `PCHW-Skill-2.8.0-rc.2.zip` and
`pc-hardware-portable-v2.8.0-rc.2.zip` are intentional reuse of earlier test
assets. They must not be described as byte-identical to the PCHW Skill tree
inside the integrated rc.3/rc.4 package.

## Runtime-only compatibility

The Runtime-only package is for an already installed PCHW Skill that has:

- Skill id `pc-hardware-workbench`
- Skill version `2.8.0`
- Workbench Manifest schema `1.0`
- active status and a valid manifest hash
- UI state schema `1.2` and event schema `1.0`
- the `telemetry.csv.analyze` capability

The package inventory is defined by `PACKAGE-MANIFEST.json`,
`MANIFEST.sha256`, and the adjacent verification receipt. Do not use a
hard-coded file count as the compatibility contract.

## Runtime policy

The current product package uses the embedded frozen Node runtime. A separate
local-Node edition and automatic local-Node detection are deferred; they are not
part of rc.4.

Developers and CI must run release-equivalent checks through:

```powershell
pnpm verify:frozen
```

The wrapper probes the exact Node and SQLite versions before running the suite.
This prevents a host Codex or machine-wide Node update from silently changing
the source-hosted test profile.

## Evidence terminology

- `PASS`: the named gate ran on the named bytes or environment.
- `automated`: tests and package verification, not a substitute for a clean
  Windows human walkthrough.
- `PENDING`: not yet evidenced at the required level.
- `reused`: an existing immutable asset, not a claim that it was rebuilt from
  the current source tree.

The public rc.3 tag and assets remain immutable. The rc.4 candidate is local
until a separate release is explicitly authorized.
