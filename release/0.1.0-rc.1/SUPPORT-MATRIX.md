# Support matrix: 0.1.0-rc.1 / PCHW 2.8.0

This matrix is authoritative for release claims. Installation support for the
domain Skill is not the same as support for the SkillDock panel.

| Host | PCHW Skill core capabilities | `pchw-source-hosted` SkillDock panel |
| --- | --- | --- |
| Codex with the current user Thread | Supported | Supported as the only RC panel host |
| DSH | Chat, collection, and CSV-analysis capabilities may be used through that host | Not promised |
| Other Agent hosts | Chat, collection, and CSV-analysis capabilities may be used through that host | Not promised |

`launch-panel.ps1` hard-requires `CODEX_THREAD_ID`. When that identity is
missing, the source-hosted profile returns `thread_binding_missing` safely and
must remain in conversation; it must not present a development entry.

## Browser handoff fallback

Automatic browser opening is preferred but is not guaranteed from a restricted
Codex sandbox. If Explorer cannot produce a panel ACK within the short automatic
window, `launch-panel.ps1` returns `interactive_desktop_unavailable` with:

- `manual_open_required=true`
- a short one-time `manual_open_url`
- a local `.url` shortcut in `manual_open_file`

The Skill must then say “手动打开面板” and offer the local URL or shortcut. The
Runtime remains running long enough for the user to open it. It must not claim
automatic success, hide the failure, or substitute API calls for the user's
later panel actions. The same short `open_id` and handoff probe remain valid for
the fallback window.

## Existing-install upgrade

The root `Start-Acceptance.cmd` is the strict clean-profile path and fails when
a PCHW Skill already exists. Existing Codex users should run
`payload\Start-Upgrade.cmd` from the internal acceptance bundle.

- Preflight records existing paths but permits the upgrade mode.
- The old Skill is moved to `.codex\skills\.skilldock-backups`.
- The new Skill is installed from a staging directory and verified by tree
  identity.
- If installation or verification fails, the failed target is moved to a
  `failed-install` backup and the old Skill is restored.
- Runtime program directories are versioned and old active Runtime directories
  are moved to the Runtime backup root.
- Conflicting runtime data roots fail closed instead of being merged silently.

The DSH read-only observer is an independently frozen component. Its existence
does not make DSH a SkillDock panel host and does not establish a universal
multi-provider workspace promise.

No host is granted default traffic, background write, coordinator recovery,
automatic hardware changes, or test/mock entry by this matrix.
