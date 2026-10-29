[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot,

    [switch]$AllowLiveCollector,

    [ValidateSet("Redacted", "Standard", "Both")]
    [string]$CollectorPrivacyMode = "Redacted"
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$failures = New-Object System.Collections.Generic.List[string]
$collectorArguments = @(
    "-SkillRoot", $resolvedRoot,
    "-PrivacyMode", $CollectorPrivacyMode
)
if ($AllowLiveCollector) {
    $collectorArguments += "-AllowLiveCollector"
}

$testCases = @(
    @{
        Name = "Contract"
        Script = Join-Path $resolvedRoot "tests/run-contract-tests.ps1"
        Arguments = @("-SkillRoot", $resolvedRoot)
    },
    @{
        Name = "Encoding"
        Script = Join-Path $resolvedRoot "tests/run-encoding-tests.ps1"
        Arguments = @("-SkillRoot", $resolvedRoot)
    },
    @{
        Name = "Device identity"
        Script = Join-Path $resolvedRoot "tests/run-device-identity-tests.ps1"
        Arguments = @("-HelperPath", (Join-Path $resolvedRoot "scripts/device-identity.ps1"))
    },
    @{
        Name = "Inventory context"
        Script = Join-Path $resolvedRoot "tests/run-inventory-context-tests.ps1"
        Arguments = @("-HelperPath", (Join-Path $resolvedRoot "scripts/inventory-context.ps1"))
    },
    @{
        Name = "Collector smoke"
        Script = Join-Path $resolvedRoot "tests/run-collector-smoke-tests.ps1"
        Arguments = $collectorArguments
    },
    @{
        Name = "Telemetry audit"
        Script = Join-Path $resolvedRoot "tests/run-telemetry-audit-tests.ps1"
        Arguments = @("-AnalyzerPath", (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1"))
    },
    @{
        Name = "Telemetry analyzer"
        Script = Join-Path $resolvedRoot "tests/run-telemetry-analysis-tests.ps1"
        Arguments = @("-AnalyzerPath", (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1"))
    },
    @{
        Name = "Interaction contract (static)"
        Script = Join-Path $resolvedRoot "tests/run-interaction-contract-tests.ps1"
        Arguments = @("-SkillRoot", $resolvedRoot)
    }
)

foreach ($testCase in $testCases) {
    $arguments = @($testCase.Arguments)
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $testCase.Script @arguments
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("$($testCase.Name) failed with exit code $LASTEXITCODE.") | Out-Null
    }
}

if ($failures.Count -gt 0) {
    Write-Host "All Skill tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

if ($AllowLiveCollector) {
    Write-Host "All automated Skill tests, including live collector smoke ($CollectorPrivacyMode): PASS" -ForegroundColor Green
}
else {
    Write-Host "All baseline automated Skill tests: PASS (contract test used one redacted local collection)" -ForegroundColor Green
    Write-Host "Live collector smoke: SKIP (use -AllowLiveCollector and -CollectorPrivacyMode Redacted|Standard|Both)" -ForegroundColor Yellow
}
Write-Host "Manual behavioral acceptance is tracked separately in tests/manual-acceptance-template.md." -ForegroundColor Yellow
