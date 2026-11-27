# PCWB local evidence CLI

Use `scripts/pcwb.ps1` for routine read-only collection and analysis. It wraps
the existing collectors and analyzers so the Agent receives one deterministic
JSON result instead of parsing console prose or several unrelated child formats.
The original scripts remain available for advanced use and compatibility.

The CLI is Windows-only. It does not offer hardware writes, tuning application,
driver installation, elevation, BIOS changes, or background collectors that were
not explicitly requested through the underlying read-only command.

## Commands

| Command | Purpose |
|---|---|
| `pcwb.ps1 inventory` | Collect a current read-only hardware snapshot. |
| `pcwb.ps1 analyze telemetry -Path <csv>` | Analyze HWiNFO or compatible telemetry. |
| `pcwb.ps1 analyze presentmon -InputPath <csv>` | Analyze PresentMon frame times. |
| `pcwb.ps1 evidence package -BaselinePath <csv> -OutputDirectory <root>` | Build a normalized telemetry evidence package. |
| `pcwb.ps1 verify claim -ClaimPath <json> [-EvidencePath <json>]` | Compare user or historical claims with structured evidence. |
| `pcwb.ps1 doctor` | Check the installed Skill structure and local prerequisites. |

Examples:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\pcwb.ps1" `
  inventory -PrivacyMode Redacted

powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\pcwb.ps1" `
  inventory -PrivacyMode Redacted -Sections CPU,Memory

powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\pcwb.ps1" `
  analyze telemetry -Path "<telemetry.csv>" `
  -WarmupSeconds 60 -DurationSeconds 300

powershell -NoProfile -ExecutionPolicy Bypass -File "<skill>\scripts\pcwb.ps1" `
  evidence package -BaselinePath "<baseline.csv>" `
  -CandidatePath "<candidate.csv>" `
  -Workload "<same fixed workload>" `
  -Change "<one declared change>" `
  -OutputDirectory "<local-evidence-root>"
```

Use `-HideFileName` when a summary must not expose the source filename.
For `inventory`, `-Sections` accepts a comma-separated subset of `System`,
`CPU`, `GPU`, `Memory`, `Storage`, `Display`, and `Battery`. Omit it for the
full-inventory default. The compact evidence records `CollectionScope` and only
includes fields from the selected sections.

## Output contract

Standard output contains exactly one JSON document. Diagnostics go to standard
error. Do not merge or display either stream as the user-facing answer.

The result follows [pcwb-result.schema.json](../../schemas/pcwb-result.schema.json):

```json
{
  "SchemaVersion": "1.0",
  "Tool": "pcwb",
  "ToolVersion": "1.0.0",
  "Command": "analyze telemetry",
  "Status": "partial",
  "GeneratedAt": "2026-11-22T06:00:00.0000000+00:00",
  "DurationMilliseconds": 950,
  "ExitCode": 0,
  "Inputs": [],
  "Evidence": [],
  "Findings": [],
  "Uncertainties": [],
  "NextActions": [],
  "Artifacts": [],
  "Warnings": [],
  "Errors": [],
  "Limits": []
}
```

Every array item has a stable role:

- `Inputs`: local source path, SHA-256, and byte count.
- `Evidence`: compact normalized observations selected for the Agent.
- `Findings`: decision-changing facts such as a claim conflict.
- `Uncertainties`: known limits in interpretation.
- `NextActions`: deterministic follow-up prompts, not hardware mutations.
- `Artifacts`: local child outputs with SHA-256 and media type.
- `Warnings`: recoverable parsing, sampling, or environment warnings.
- `Errors`: the blocking failure for this invocation.
- `Limits`: boundaries that remain true even when the command succeeds.

`Evidence` is the normal Agent input. Open a referenced raw artifact only when a
decision needs detail that is not already present. Never paste the envelope or
raw child JSON into the reply.

## Status and exit codes

| Status | Exit | Meaning |
|---|---:|---|
| `ok` | 0 | Requested evidence was produced without known degradation. |
| `partial` | 0 or 4 | Evidence exists but has warnings, uncertainty, or a semantic conflict. |
| `needs-input` | 2 or 4 | Required input is missing, invalid, or insufficient. |
| `blocked` | 3 or 6 | Unsupported environment, broken prerequisite, or missing permission. |
| `failed` | 1 or 5 | Execution, child protocol, or integrity validation failed. |

Always check `Status`, `ExitCode`, `Errors`, `Warnings`, and `Limits` before
interpreting `Evidence`. A successful process exit is not a stability or safety
verdict.

## Output directories and retention

`-OutputDirectory` is an existing or creatable local directory. Each invocation
creates one `pcwb-<timestamp>-<id>` run folder beneath it and never overwrites an
existing file. Without the option, the CLI uses a unique folder under the local
temporary directory.

Artifacts remain until the user or host removes them. Do not delete, move, or
rewrite artifacts during the same Task without an explicit retention decision.
Keep the paths and hashes with any case, report, or panel result that depends on
them.

The CLI rejects UNC paths, mapped network drives, and paths that traverse a
symbolic link, junction, or other reparse point. JSON artifacts are UTF-8 without
a BOM and are published by temporary-file move.

## Agent handling

1. Run the narrowest command that answers the current question.
2. Use `Evidence`, `Findings`, and artifact hashes as the cited facts.
3. If `Status` is `partial`, separate confirmed evidence from the warning.
4. If `needs-input`, ask for the one missing input or choose a supported window.
5. If `blocked`, explain the capability boundary and preserve the original goal.
6. If `failed`, report that no valid result was produced; do not parse partial
   child output as success.
7. Keep the user-facing answer concise and omit the internal envelope.
