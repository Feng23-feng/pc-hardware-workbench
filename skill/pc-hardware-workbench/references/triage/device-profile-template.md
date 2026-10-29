# Device profile template

Copy this template into the user's own notes. Keep private device data outside any shared copy of this framework.

```markdown
# Device profile

Last verified:
Access status:
Role:

## Hardware

- CPU:
- Motherboard and BIOS/firmware:
- GPU and GPU firmware:
- Memory:
- PSU or power adapter:
- Cooling:
- Case/chassis:
- Displays:

## Storage map

| Physical drive | Model | Serial (local-only, optional) | Capacity | Current host | Slot | Current role | Provenance |
|---|---|---|---|---|---|---|---|

## Current daily profile

- CPU settings:
- GPU settings:
- Memory settings:
- Power limits:
- Fan profile:
- Driver versions:

## Last-known benchmark or workload baseline

- Workload:
- Score/throughput:
- Temperature:
- Power:
- Date:

## Known failures and boundaries

| Date | Symptom | Suspected cause | Evidence | Result | Rollback | Scope |
|---|---|---|---|---|---|---|

## Pending verification

- Not yet recorded.
```

Rules:

- Use model, capacity, slot, and current role to identify storage in shared records. Keep the serial number local and optional, and redact it from shared exports.
- Put a date on every tuning snapshot.
- Keep current values separate from historical experiments.
- Mark values as confirmed, measured, last known, or unverified.
