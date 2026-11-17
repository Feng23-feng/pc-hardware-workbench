# Versioning

The application, contracts, adapters, and installed Skills use independent
version lines. A change in one line does not require synchronized version bumps
in the others.

| Layer | Current version | Compatibility rule |
|---|---:|---|
| SkillDock application | `0.1.0-rc.1` | Windows release candidate `rc.1`; not formally released |
| SkillSurface contract | `1.0` | additive changes stay within major version 1 |
| SkillRuntime contract | `1.0` | hosts and Skills negotiate the declared API version |
| AgentDriver contract | `1.0` | adapters declare capabilities rather than platform names |
| Agent Bridge contract | `0.1-draft` | draft schemas and local HTTP driver exist; not stable until two independent Agent implementations pass one contract suite |
| PC Hardware Workbench Skill | `2.8.0` | release-candidate package version; R7 evidence source was `2.7.4` |

The `0.1.0-rc.1` identifier is the first Windows release candidate. It is not a
stable or formally released version. The `private` package flag remains enabled
because this project is distributed as a local Windows archive, not as an npm
package. A release candidate must not imply that an experimental adapter or
domain Skill has passed clean-machine, default-entry, or production acceptance.

Domain Skill versions remain authoritative in their own `SKILL.md`. A manifest
must match the installed Skill version exactly.
