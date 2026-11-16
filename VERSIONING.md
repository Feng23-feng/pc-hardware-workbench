# Versioning

The application, contracts, adapters, and installed Skills use independent
version lines. A change in one line does not require synchronized version bumps
in the others.

| Layer | Current version | Compatibility rule |
|---|---:|---|
| SkillDock application | `0.1.0-dev` | product releases are independent |
| SkillSurface contract | `1.0` | additive changes stay within major version 1 |
| SkillRuntime contract | `1.0` | hosts and Skills negotiate the declared API version |
| AgentDriver contract | `1.0` | adapters declare capabilities rather than platform names |
| Agent Bridge contract | `0.1-draft` | draft schemas and local HTTP driver exist; not stable until two independent Agent implementations pass one contract suite |
| PC Hardware Workbench Skill | `2.7.4` | owned and released by the domain Skill repository |

Application prereleases use `0.x.y-dev` until the first supported release. They
must not imply that an experimental adapter or domain Skill has passed broader
release acceptance.

Domain Skill versions remain authoritative in their own `SKILL.md`. A manifest
must match the installed Skill version exactly.
