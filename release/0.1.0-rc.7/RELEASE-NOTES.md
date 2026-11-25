# Release notes: 0.1.0-rc.7

## Components

| Component | Version |
| --- | --- |
| SkillDock application | `0.1.0-rc.7` |
| PC Hardware Workbench Skill | `2.9.3` |
| SkillSurface contract | `1.0` |
| SkillRuntime contract | `1.0` |
| AgentDriver contract | `1.0` |
| Bundled Node | `24.22.1` |
| Bundled SQLite | `3.53.4` |

## Highlights

- Apply the Graphite Copper × Cobalt Archive palette with semantic roles for
  warm canvas, copper operations, steel-blue data, amber pending states, and
  rust-red errors.
- Collapse a verified Runtime binding into a compact disclosure strip.
- Render `panel.uncertainty[0]` as the current unresolved subject and avoid
  duplicating it in the later unresolved list.
- Require resolved evidence to replace the current unresolved subject instead
  of carrying a stale fixed label.
- Add responsive browser gates for 390 px and 320 px, including opened Runtime
  details.
- Load verified evidence SVG artifacts eagerly so the unresolved-item summary
  cannot push charts outside the browser lazy-load window.

## Compatibility

- PCHW `2.8.0` remains the only exact legacy bridge without a surface contract.
- PCHW versions after `2.8.0` must declare `pchw-source-hosted` contract `1.x`
  satisfying minimum version and capability requirements.
- UI state schema must be exactly `1.2`; event schema must be exactly `1.0`.
- Contract major `2` and later fail closed until a compatible adapter exists.

## Release status

This is a public test build. Clean Windows installation/uninstallation and
complete user signoff remain `PENDING`. The formal default entry, default
traffic, background write, coordinator recovery, and automatic hardware changes
remain closed. This is not a stable release.
