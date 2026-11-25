# Support matrix: 0.1.0-rc.7 / PCHW 2.9.3

## Hosts

| Host | PCHW chat, collection, CSV analysis | SkillDock panel |
| --- | --- | --- |
| Codex Desktop | Supported | Supported only in the current conversation |
| DeepSeek Harness (DSH) | Structural-install candidate only | Not promised |
| Other compatible Agent hosts | Structural-install candidate only | Not promised |

## Panel compatibility

PCHW `2.9.3` declares:

```text
surface contract:   pchw-source-hosted 1.0.0
minimum Skill:      2.8.0
UI state schema:    1.2
event schema:       1.0
capability:         telemetry.csv.analyze
```

SkillDock accepts contract `1.x`, requires the active manifest to satisfy the
declared minimum version and capabilities, and rejects contract major `2+`,
missing contracts after `2.8.0`, missing capabilities, and unsupported schemas.

The panel requires `CODEX_THREAD_ID`; without it, launch fails closed with
`thread_binding_missing`.

## Browser

The verified test path uses Microsoft Edge. WebSocket attach is optional; the
same-origin polling fallback remains available and reports gaps explicitly.

## Status

Clean Windows installation/uninstallation and complete user signoff are
`PENDING`. This is a public test build, not a stable release.
