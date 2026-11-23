# Component and evidence matrix

Snapshot: 2026-11-23 (+08:00)

This is the canonical version-and-support matrix for the SkillDock / PC
Hardware Workbench delivery. Release assets are immutable; a newer matrix does
not rewrite an older public tag.

## Products

| Surface | Current test build | Latest public asset | Contains | Promised scope | Evidence state |
| --- | --- | --- | --- | --- | --- |
| SkillDock Runtime | `0.1.0-rc.6` | `0.1.0-rc.6` | Runtime, embedded Node, browser surface | Codex current conversation only | Frozen-runtime, package verification, and visible Edge regression pass; Clean Windows and stable-release signoff pending |
| PCHW Skill | `2.9.2` | `2.9.2-test.1` | Skill instructions, references, scripts | Codex supported; DSH and other hosts are structural-install candidates only; no panel promise outside Codex | Skill validator, full tests, machine-checked surface contract, and public 2.9.2 test assets pass |
| PCHW Portable | `2.9.2` | `2.9.2-test.1` | Standalone menu and local tools | Windows without an Agent | Public 2.9.2 test asset validated |
| Runtime-only package | `0.1.0-rc.6` | `0.1.0-rc.6` | Runtime, embedded Node, runtime installer | An installed compatible PCHW Skill; Codex panel only | Build and verifier pass; separate Skill-only plus Runtime-only combination remains unaccepted |
| Integrated user package | `0.1.0-rc.6` | `0.1.0-rc.6` | PCHW Skill, SkillDock Runtime, installer, uninstaller, licenses | Windows 11 x64, Codex Desktop, Microsoft Edge; current conversation only | Build, package verification, and visible Edge PASS; Clean Windows and stable user signoff pending |

## Version identities

```text
SkillDock current test build:      0.1.0-rc.6
Latest public SkillDock release:   0.1.0-rc.6
PCHW Skill content version:       2.9.2
Latest public PCHW asset:         2.9.2-test.1
PCHW source tree:                 78b51ee7b1af7b70b77e484b92b4f77ef8efe756fa8e4e0f9149dafe6e686c86
PCHW source tree files:           151
PCHW packaged install subset:     recorded by the verified rc.6 RC-MANIFEST.json
PCHW source commit:               0874d36731bf7802a5c03743489ae1cedf61ef9b
Bundled Node:                     24.22.1
Bundled SQLite:                   3.53.4
PCHW surface contract:            pchw-source-hosted 1.0.0
Supported contract range:         >=1.0.0 <2.0.0
PCHW legacy bridge:               exact 2.8.0 only
Runtime UI state schema support: exact 1.2
Runtime event schema support:    exact 1.0
```

The public `PCHW-Skill-2.9.2-test.1-*.zip` and
`pc-hardware-portable-v2.9.2-test.1.zip` assets were rebuilt for this test
release. They must not be described as byte-identical to the Skill subset
inside the integrated rc.6 package.

## Runtime-only compatibility

The Runtime-only package is for an already installed PCHW Skill that satisfies
one of these compatibility paths:

| Installed PCHW | Required identity | Result |
| --- | --- | --- |
| `2.8.0` | `pc-hardware-workbench`, active Workbench Manifest 1.0 | Accepted through exact legacy compatibility |
| Later `2.x` or `3.x` with contract | `pchw-source-hosted` `>=1.0.0 <2.0.0`, UI state schema exactly `1.2`, event schema exactly `1.0`, satisfying `min_skill_version` and capabilities | Accepted when the selected manifest is active |
| Later version without contract | None | Rejected with `surface_contract_missing` |
| Contract major `2+` | None | Rejected with `surface_contract_unsupported` |
| Missing required capability | None | Rejected with `surface_contract_capability_missing` |
| Unsupported UI state schema | None | Rejected with `ui_state_schema_unsupported` |
| Unsupported event schema | None | Rejected with `event_schema_unsupported` |

The current release machine-checks the exact UI state schema `1.2`, event schema
`1.0`, the contract range, minimum Skill version, and required capabilities.
A PCHW product major such as `3.0` is accepted only when it still declares a
compatible contract and these exact supported schemas. Conversely, a `2.x`
release that moves to UI/event schema `1.3` is rejected until a Runtime
explicitly supports it. PCHW must be the active manifest actually loaded by the
Runtime; another installed version cannot act as a fallback.

The package inventory is defined by `PACKAGE-MANIFEST.json`,
`MANIFEST.sha256`, and the adjacent verification receipt. Do not use a
hard-coded file count as the compatibility contract.

## Runtime policy

The current product package uses the embedded frozen Node runtime. A separate
local-Node edition and automatic local-Node detection are deferred; they are not
part of rc.6.

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

rc.6 is the latest public SkillDock test release. rc.5 remains the previous
PCHW 2.9.0 contract-only panel test build, and rc.4 remains the earlier PCHW
2.8.0 panel test build. Clean Windows acceptance and stable-release signoff for
rc.6 remain PENDING.
