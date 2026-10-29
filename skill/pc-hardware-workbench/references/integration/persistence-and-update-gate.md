# Persistence and update gate

Use this reference when a profile may survive app close, reboot, driver reload, sleep/wake, or a software update.

## Configuration states

| State | Meaning |
| --- | --- |
| Session-only | Applied now but not guaranteed after app close, driver reload, or reboot |
| Saved, not reverified | Stored in a tool/profile but not checked after restart |
| Reboot-verified | Applied values and observed behavior survive the tested reboot route |
| Daily-verified | Reboot-verified and checked through idle, sleep/wake, combined workloads, and normal use |

## Preflight records

Record:

- the stock or known-good profile and where it is stored;
- which application, BIOS page, service, scheduled task, or vendor control applies it;
- whether the tool starts at login or boot;
- whether it is global, per-application, AC-only, battery-only, or tied to a Windows power mode;
- whether driver reset, display change, sleep/wake, or hybrid-graphics switching reloads it;
- what indicates that a value was rejected, clamped, or silently replaced.

Inspecting startup behavior is read-only. Do not create, edit, disable, or delete scheduled tasks, services, startup entries, BIOS settings, or vendor profiles automatically.

## Verify persistence

After the user applies a change:

1. Verify the setting exists and is accepted.
2. Verify the requested value in the tuning UI when exposed.
3. Verify an observed value in monitoring data when exposed.
4. Warm reboot.
5. For a daily profile, test the relevant cold start and sleep/wake path.
6. Reopen the tuning UI and monitoring source after login.
7. Confirm that the profile, limits, and workload behavior return.

For laptops, repeat the relevant check on AC and battery when profiles can differ. Do not claim persistence merely because a profile is saved.

```text
Stock profile:
Active profile:
Autostart/boot mechanism:
AC/battery scope:
Warm-reboot result:
Cold-boot result:
Sleep/wake result:
Persistence state: session-only / saved / reboot-verified / daily-verified
```

## Driver and tool update gate

- Do not update a graphics driver, BIOS/firmware, Windows, or tuning tool during an active experiment unless the user explicitly gives the update priority.
- Before updating, record the previous known-good version and how to obtain the official rollback package.
- After updating, mark the prior profile `unvalidated after update`.
- Check the new software version at stock/default settings before resuming tuning.
- If stock/default settings are unstable, triage the software/driver first instead of compensating with clocks, voltage, power, or fan settings.
- Recheck sensor names and availability after a monitoring-tool upgrade.
