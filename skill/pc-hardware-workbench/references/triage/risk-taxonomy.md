# Risk taxonomy

Risk depends on the device, firmware, recovery path, workload, and evidence. The same setting can have different risk on different hardware.

| Level | Meaning | Required handling |
|---|---|---|
| Green | Read-only or trivially reversible | Inspect, measure, compare |
| Yellow | Persistent but easily reversible software or BIOS/UEFI parameter | Save baseline, change one variable, test |
| Orange | BIOS/firmware parameter that can affect boot, data, heat, or recovery; vendor profile; or other difficult-recovery configuration | Explicit user agreement, tested rollback, bounded experiment |
| Red | Firmware flashing or modification, hardware modification, damaged power hardware beyond safe stock operation, or no tested recovery | Stop on the working machine; use vendor service or a dedicated test platform |

An exposed BIOS/UEFI parameter is not automatically the same risk as flashing
the BIOS, modifying firmware, or changing hardware. Classify by what the
operation actually changes, whether it survives reboot, and whether a tested
recovery route exists.

## Rules

- User consent can permit a bounded Orange experiment.
- User consent cannot make a Red action recoverable or safe.
- Uncertainty is not the same as confirmed damage. For an uncertain power path, allow read-only diagnostics and low-load identification, but defer high-power and high-voltage tests.
- Reversible non-official software tuning can remain Orange if it does not permanently alter firmware or hardware and has a known rollback.
- Benchmark-only profiles must not silently become daily profiles.
- Data integrity failures outrank performance failures. A faster setting that produces corruption is a failed setting.

## Before accepting Orange risk

Require all of the following:

1. the exact setting and scope are known;
2. the user understands the possible failure modes;
3. a rollback has been prepared;
4. the test is time-bounded;
5. benchmark and daily profiles are separate;
6. the user explicitly agrees to proceed.
