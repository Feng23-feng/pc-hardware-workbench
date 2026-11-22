[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChildScript,

    [Parameter(Mandatory = $true)]
    [string]$ChildArgumentsBase64
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

if (-not (Test-Path -LiteralPath $ChildScript -PathType Leaf)) {
    [Console]::Error.WriteLine("Child script does not exist: $ChildScript")
    exit 1
}

try {
    $payloadJson = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($ChildArgumentsBase64)
    )
    $payload = $payloadJson | ConvertFrom-Json
    $childArguments = @($payload.Arguments)
}
catch {
    [Console]::Error.WriteLine("Child argument payload is invalid: $($_.Exception.Message)")
    exit 1
}

$valueParameters = @(
    "Path",
    "InputPath",
    "ProcessName",
    "Format",
    "OutputFormat",
    "OutputPath",
    "OutputDirectory",
    "SkillRoot",
    "SpikeMultiplier",
    "WarmupSeconds",
    "DurationSeconds",
    "WarmupRows",
    "MaxRows",
    "Delimiter",
    "MaxInputMegabytes",
    "MaxChartPoints",
    "BaselinePath",
    "CandidatePath",
    "BaselineLabel",
    "CandidateLabel",
    "Workload",
    "Change",
    "MaxSeries",
    "MaxComparisonMetrics",
    "ClaimPath",
    "EvidencePath",
    "ValidatorPath"
)
$repeatParameters = @("IncludeColumn", "FocusMetric")
$switchParameters = @("RedactIdentifiers", "RequireElevated", "HideFileName")
$bound = @{}

for ($index = 0; $index -lt $childArguments.Count; $index++) {
    $token = [string]$childArguments[$index]
    if (-not $token.StartsWith("-")) {
        [Console]::Error.WriteLine("Unexpected positional child argument: $token")
        exit 1
    }
    $name = $token.Substring(1)
    if ($switchParameters -contains $name) {
        $bound[$name] = $true
        continue
    }
    if ($valueParameters -contains $name -or $repeatParameters -contains $name) {
        if ($index + 1 -ge $childArguments.Count) {
            [Console]::Error.WriteLine("Child parameter -$name has no value.")
            exit 1
        }
        $index++
        $value = [string]$childArguments[$index]
        if ($repeatParameters -contains $name) {
            if (-not $bound.ContainsKey($name)) {
                $bound[$name] = @()
            }
            $bound[$name] = @($bound[$name]) + $value
        }
        else {
            $bound[$name] = $value
        }
        continue
    }
    [Console]::Error.WriteLine("Unsupported child parameter: -$name")
    exit 1
}

& $ChildScript @bound
$exitCode = $LASTEXITCODE
if ($null -eq $exitCode) {
    $exitCode = 0
}
exit ([int]$exitCode)
