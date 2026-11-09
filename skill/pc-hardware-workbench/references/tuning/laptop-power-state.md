# Laptop GPU power-limit state

Use this reference for every laptop GPU candidate. Laptop power limits are
board-specific even when two machines show the same GPU name.

## Default assumption

If the user did not mention a power-limit modification, use
`PowerLimitModificationState: assumed-stock`. This is a correctable calculation
assumption, not a claim that the machine was verified as stock.

Do not ask the user to prove that the machine is unlocked before giving a
conservative candidate. State:

> No power-limit modification was declared, so the first calculation uses the
> stock laptop strategy. If this machine was unlocked, a new configuration
> revision will be created; the old record remains historical evidence.

## States

| State | Meaning | Candidate behavior |
| --- | --- | --- |
| `assumed-stock` | No unlock declaration and no conflict | Use stock laptop strategy and a conservative frequency step |
| `declared-stock` | User explicitly reports stock or supplies the stock watt limit | Use stock strategy; measured cooling still decides |
| `declared-unlocked` | User explicitly reports a modified power path | Use current watt limit as baseline; do not increase frequency steps automatically |
| `detected-mismatch` | Board, tool, telemetry, or user statements conflict | Block new numeric candidates until state is confirmed |

For `declared-unlocked`, require both stock and current watt limits. A tool
percentage is not a substitute for watts. Do not provide unlock steps, tools,
menu locations, vBIOS/EC/firmware changes, or a higher-power recommendation just
because the card is unlocked.

## Required fields

Record and return:

```text
BoardModel
StockPowerLimitWatts
CurrentPowerLimitWatts
DynamicBoostWatts
PowerLimitModificationState
PowerLimitMode
PowerLimitEvidenceSource
UsesCurrentPowerLimit
```

`BoardModel` must include the brand/chassis and GPU class. Unknown watt values
remain unknown rather than being inferred from a percentage.

Evidence source values are `user-declared`, `vendor-tool`, `monitoring-log`,
`vbios-string`, or `unknown`.

### Percentage and watts are limit ceilings

`CurrentPowerLimitPct` and `CurrentPowerLimitWatts` describe the configured or
observed **power-limit ceiling**, not the GPU's instantaneous or sustained
power draw. A value such as `100%` means “whatever this profile maps to in
watts”; it does not mean 100 W and does not reveal actual consumption.

Record measured board power separately as `MeasuredPowerWatts` when available.
Do not use the measured power draw to infer the configured ceiling, and do not
use the ceiling percentage to claim the measured draw. Return both meanings
explicitly in candidate output.

## Conflict and configuration revision

Treat these as `detected-mismatch`:

- a declared stock state with a current limit above stock;
- a declared unlocked state without stock/current watt evidence;
- a declared unlocked state whose current limit is not above stock;
- inconsistent board, tool, vBIOS, or prior power-limit records.

Include board model, stock watts, current watts, dynamic boost, and power state
in `ConfigurationFingerprint`. Keep `HardwareFingerprint` separate from that
configuration revision:

- a power-limit change creates a new configuration revision and blocks direct
  continuation from the old baseline/candidate;
- the old records remain historical evidence and keep their original IDs;
- the experiment lineage remains traceable across power-state revisions;
- an old tuned fallback is not valid as current without revalidation;
- a factory/default profile fallback remains a recovery action, but it is
  profile-only and may not undo an externally modified power limit.

The same GPU model on another board must not inherit this board's power limit,
cooling assumptions, fallback, or experiment history.

## Desktop boundary

Desktop cards skip this state machine. Report
`PowerLimitModificationState: not-applicable` and
`PowerLimitMode: desktop`; do not invent a laptop stock watt value.
