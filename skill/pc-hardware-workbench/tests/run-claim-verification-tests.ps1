[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$VerifierPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message) | Out-Null
    }
}

$verifier = (Resolve-Path -LiteralPath $VerifierPath).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-claim-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $evidencePath = Join-Path $testRoot "evidence.json"
    @{
        GPU = @(@{
            Name = "Synthetic GPU"
            NvidiaEffectivePowerLimitW = 480
        })
        MemoryModules = @(@{
            ConfiguredSpeedMTs = 6000
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $evidencePath -Encoding UTF8

    $claimsPath = Join-Path $testRoot "claims.json"
    @{
        schemaVersion = 1
        claims = @(
            @{
                id = "matched-power"
                path = "GPU.0.NvidiaEffectivePowerLimitW"
                expected = 480
                tolerance = 1
                sourceType = "user-confirmed-current"
            },
            @{
                id = "conflicting-memory"
                path = "MemoryModules.0.ConfiguredSpeedMTs"
                expected = 5600
                sourceType = "user-confirmed-current"
            },
            @{
                id = "unavailable-offset"
                path = "GPU.0.CoreOffsetMHz"
                expected = 50
                sourceType = "user-confirmed-current"
            },
            @{
                id = "historical-value"
                path = "GPU.0.OldPowerLimitW"
                expected = 450
                sourceType = "historical"
            }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $claimsPath -Encoding UTF8

    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $verifier `
        -ClaimPath $claimsPath `
        -EvidencePath $evidencePath `
        -OutputFormat Json
    $exitCode = $LASTEXITCODE
    Assert-True ($exitCode -eq 1) "Conflict run should exit 1, got $exitCode."
    $report = $output | ConvertFrom-Json
    Assert-True ($report.claims[0].status -eq "matched-current") "Matching claim was not marked matched-current."
    Assert-True ($report.claims[1].status -eq "conflict") "Conflicting claim was not marked conflict."
    Assert-True ($report.claims[2].status -eq "user-confirmed-current") "Unavailable user-confirmed claim lost its source status."
    Assert-True ($report.claims[3].status -eq "historical") "Historical claim without evidence was not marked historical."
    Assert-True ($report.conflictCount -eq 1) "Conflict count is wrong."

    $matchingClaimsPath = Join-Path $testRoot "matching.json"
    @{
        schemaVersion = 1
        claims = @(@{
            id = "matched-memory"
            path = "MemoryModules.0.ConfiguredSpeedMTs"
            expected = 6000
            sourceType = "user-confirmed-current"
        })
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $matchingClaimsPath -Encoding UTF8
    $matchingOutput = & powershell -NoProfile -ExecutionPolicy Bypass -File $verifier `
        -ClaimPath $matchingClaimsPath `
        -EvidencePath $evidencePath `
        -OutputFormat Json
    $matchingExitCode = $LASTEXITCODE
    Assert-True ($matchingExitCode -eq 0) "Matching run should exit 0, got $matchingExitCode."
    $matchingReport = $matchingOutput | ConvertFrom-Json
    Assert-True ($matchingReport.claims[0].status -eq "matched-current") "Matching memory claim was not verified."

    $invalidClaimsPath = Join-Path $testRoot "invalid.json"
    @{ schemaVersion = 1 } | ConvertTo-Json | Set-Content -LiteralPath $invalidClaimsPath -Encoding UTF8
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $verifier `
            -ClaimPath $invalidClaimsPath `
            -EvidencePath $evidencePath `
            -OutputFormat Json *> $null
        $invalidExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    Assert-True ($invalidExitCode -eq 2) "Invalid claim document should exit 2."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Claim verification tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}
Write-Host "Claim verification tests: PASS"
