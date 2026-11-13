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
        Name = "PowerShell 7 parse"
        Script = Join-Path $resolvedRoot "tests/run-pwsh7-parse-tests.ps1"
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
        Name = "VRAM knowledge"
        Script = Join-Path $resolvedRoot "tests/run-vram-knowledge-tests.ps1"
        Arguments = @("-SkillRoot", $resolvedRoot)
    },
    @{
        Name = "Telemetry analyzer"
        Script = Join-Path $resolvedRoot "tests/run-telemetry-analysis-tests.ps1"
        Arguments = @("-AnalyzerPath", (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1"))
    },
    @{
        Name = "Telemetry chart"
        Script = Join-Path $resolvedRoot "tests/run-telemetry-chart-tests.ps1"
        Arguments = @(
            "-AnalyzerPath", (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1"),
            "-RendererPath", (Join-Path $resolvedRoot "scripts/render-telemetry-chart.ps1")
        )
    },
    @{
        Name = "Evidence pipeline"
        Script = Join-Path $resolvedRoot "tests/run-evidence-pipeline-tests.ps1"
        Arguments = @("-PipelinePath", (Join-Path $resolvedRoot "scripts/run-evidence-pipeline.ps1"))
    },
    @{
        Name = "Telemetry normalization"
        Script = Join-Path $resolvedRoot "tests/run-telemetry-normalization-tests.ps1"
        Arguments = @(
            "-AdapterPath", (Join-Path $resolvedRoot "scripts/normalize-telemetry.ps1"),
            "-RendererPath", (Join-Path $resolvedRoot "scripts/render-telemetry-chart.ps1")
        )
    },
    @{
        Name = "Hardware case"
        Script = Join-Path $resolvedRoot "tests/run-hardware-case-tests.ps1"
        Arguments = @("-CaseScriptPath", (Join-Path $resolvedRoot "scripts/hardware-case.ps1"))
    },
    @{
        Name = "Hardware case report"
        Script = Join-Path $resolvedRoot "tests/run-hardware-case-report-tests.ps1"
        Arguments = @(
            "-CaseScriptPath", (Join-Path $resolvedRoot "scripts/hardware-case.ps1"),
            "-ReportScriptPath", (Join-Path $resolvedRoot "scripts/export-hardware-case-html.ps1")
        )
    },
    @{
        Name = "RAG evidence"
        Script = Join-Path $resolvedRoot "tests/run-rag-evidence-tests.ps1"
        Arguments = @(
            "-RagScriptPath", (Join-Path $resolvedRoot "scripts/rag/rag-evidence.ps1")
        )
    },
    @{
        Name = "GPU automatic overclock"
        Script = Join-Path $resolvedRoot "tests/run-gpu-auto-oc-tests.ps1"
        Arguments = @(
            "-ScriptPath", (Join-Path $resolvedRoot "scripts/suggest-gpu-overclock.ps1")
        )
    },
    @{
        Name = "LHM adapter"
        Script = Join-Path $resolvedRoot "tests/run-lhm-adapter-tests.ps1"
        Arguments = @(
            "-FunctionsPath", (Join-Path $resolvedRoot "scripts/lhm/lhm-functions.ps1"),
            "-CollectorPath", (Join-Path $resolvedRoot "scripts/lhm/read-lhm-telemetry.ps1"),
            "-NormalizerPath", (Join-Path $resolvedRoot "scripts/normalize-telemetry.ps1")
        )
    },
    @{
        Name = "Doctor"
        Script = Join-Path $resolvedRoot "tests/run-doctor-tests.ps1"
        Arguments = @(
            "-DoctorPath", (Join-Path $resolvedRoot "scripts/doctor.ps1")
        )
    },
    @{
        Name = "Interaction contract (static)"
        Script = Join-Path $resolvedRoot "tests/run-interaction-contract-tests.ps1"
        Arguments = @("-SkillRoot", $resolvedRoot)
    },
    @{
        Name = "Claim verification"
        Script = Join-Path $resolvedRoot "tests/run-claim-verification-tests.ps1"
        Arguments = @(
            "-VerifierPath", (Join-Path $resolvedRoot "scripts/verify-hardware-claim.ps1")
        )
    },
    @{
        Name = "PresentMon frame-time analysis"
        Script = Join-Path $resolvedRoot "tests/run-presentmon-analysis-tests.ps1"
        Arguments = @(
            "-AnalyzerPath", (Join-Path $resolvedRoot "scripts/analyze-presentmon.ps1")
        )
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
