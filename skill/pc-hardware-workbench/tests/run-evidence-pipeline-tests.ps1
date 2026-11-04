[CmdletBinding()]
param(
    [string]$PipelinePath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($PipelinePath)) {
    $PipelinePath = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts/run-evidence-pipeline.ps1"
}
$resolvedPipeline = (Resolve-Path -LiteralPath $PipelinePath).Path
$powershell = (Get-Command "powershell.exe" -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pcwb-evidence-pipeline-" + [guid]::NewGuid().ToString("N"))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        $failures.Add($Message) | Out-Null
    }
}

function Invoke-Pipeline {
    param([string[]]$Arguments)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedPipeline @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = (@($output) | ForEach-Object { $_.ToString() }) -join "`n"
    }
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $baselinePath = Join-Path $tempRoot "baseline.csv"
    $candidatePath = Join-Path $tempRoot "candidate.csv"
    $differentMetricPath = Join-Path $tempRoot "different-metric.csv"
    $outputRoot = Join-Path $tempRoot "packages"

    [IO.File]::WriteAllText($baselinePath, @'
"Date","Time","GPU Temperature [C]","GPU Power [W]","FPS"
"2026-11-04","12:00:00","75","200","100"
"2026-11-04","12:00:01","76","205","101"
"2026-11-04","12:00:02","74","202","99"
'@, $utf8)

    [IO.File]::WriteAllText($candidatePath, @'
"Date","Time","GPU Temperature [C]","GPU Power [W]","FPS"
"2026-11-04","12:00:00","71","190","108"
"2026-11-04","12:00:01","72","192","109"
"2026-11-04","12:00:02","70","188","107"
'@, $utf8)

    [IO.File]::WriteAllText($differentMetricPath, @'
"Date","Time","CPU Package Power [W]"
"2026-11-04","12:00:00","95"
"2026-11-04","12:00:01","96"
"2026-11-04","12:00:02","94"
'@, $utf8)

    $comparisonRun = Invoke-Pipeline -Arguments @(
        "-BaselinePath", $baselinePath,
        "-CandidatePath", $candidatePath,
        "-OutputDirectory", $outputRoot,
        "-Workload", "fixed-game-scene",
        "-Change", "curve-undervolt",
        "-FocusMetric", "GPU temperature"
    )
    Assert-True ($comparisonRun.ExitCode -eq 0) "The comparison pipeline failed: $($comparisonRun.Output)"

    $runDirectories = @(Get-ChildItem -LiteralPath $outputRoot -Directory | Sort-Object LastWriteTime)
    Assert-True ($runDirectories.Count -eq 1) "The first pipeline run did not create exactly one package directory."
    if ($runDirectories.Count -ge 1) {
        $runDirectory = $runDirectories[0].FullName
        foreach ($name in @(
            "baseline.analysis.json",
            "baseline.normalized.json",
            "baseline.chart.svg",
            "candidate.analysis.json",
            "candidate.normalized.json",
            "candidate.chart.svg",
            "evidence-card.html",
            "summary.md",
            "evidence-package.json"
        )) {
            Assert-True (Test-Path -LiteralPath (Join-Path $runDirectory $name) -PathType Leaf) "Expected package file is missing: $name"
        }

        $package = Get-Content -Raw -LiteralPath (Join-Path $runDirectory "evidence-package.json") -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($package.EvidencePackageVersion -eq "1.0") "The evidence package schema version is missing."
        Assert-True ($package.Status -eq "ready-for-review") "The comparable baseline/candidate package should be ready for review."
        Assert-True (@($package.Comparison.Metrics).Count -ge 1) "The comparison has no selected metrics."
        $temperature = @($package.Comparison.Metrics | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
        Assert-True ($null -ne $temperature) "The focused GPU temperature comparison is missing."
        if ($null -ne $temperature) {
            Assert-True ([Math]::Abs($temperature.MeanDelta + 4) -lt 0.001) "The GPU temperature mean delta is incorrect."
            Assert-True ($null -eq $temperature.MeanDeltaPercent) "A Celsius comparison should not emit a relative percentage."
        }

        $card = Get-Content -Raw -LiteralPath (Join-Path $runDirectory "evidence-card.html") -Encoding UTF8
        Assert-True ($card.Contains("<svg")) "The result card does not embed a chart."
        Assert-True (-not $card.Contains("<script")) "The result card must not contain scripts."
        Assert-True (-not ($card -match '(?i)(?:src|href)\s*=\s*["'']https?://')) "The result card must not depend on remote resources."
        Assert-True ($card.Contains("GPU temperature (C)")) "The result card is missing the focused metric."
        Assert-True ($card.Contains("candidate.csv")) "The result card is missing the candidate filename metadata."
        Assert-True ($card.Contains((Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash)) "The result card is missing the candidate input hash."
    }

    $baselineRun = Invoke-Pipeline -Arguments @(
        "-BaselinePath", $baselinePath,
        "-OutputDirectory", $outputRoot
    )
    Assert-True ($baselineRun.ExitCode -eq 0) "The baseline-only pipeline failed: $($baselineRun.Output)"
    $updatedRuns = @(Get-ChildItem -LiteralPath $outputRoot -Directory | Sort-Object LastWriteTime)
    Assert-True ($updatedRuns.Count -eq 2) "The baseline-only run should create a separate package directory."
    if ($updatedRuns.Count -eq 2) {
        $baselinePackage = Get-Content -Raw -LiteralPath (Join-Path $updatedRuns[1].FullName "evidence-package.json") -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($baselinePackage.Status -eq "baseline-ready") "The baseline-only package status is incorrect."
        Assert-True ($null -eq $baselinePackage.Candidate) "The baseline-only package unexpectedly contains a candidate."
    }

    $missingWorkload = Invoke-Pipeline -Arguments @(
        "-BaselinePath", $baselinePath,
        "-CandidatePath", $candidatePath,
        "-OutputDirectory", (Join-Path $tempRoot "missing-workload")
    )
    Assert-True ($missingWorkload.ExitCode -eq 2) "A candidate comparison without workload context should be rejected."

    $differentMetric = Invoke-Pipeline -Arguments @(
        "-BaselinePath", $baselinePath,
        "-CandidatePath", $differentMetricPath,
        "-OutputDirectory", (Join-Path $tempRoot "different-metric"),
        "-Workload", "fixed-game-scene"
    )
    Assert-True ($differentMetric.ExitCode -eq 0) "The different-metric pipeline should still produce a diagnostic package."
    $differentRuns = @(Get-ChildItem -LiteralPath (Join-Path $tempRoot "different-metric") -Directory)
    Assert-True ($differentRuns.Count -eq 1) "The different-metric run did not create one package."
    if ($differentRuns.Count -eq 1) {
        $differentPackage = Get-Content -Raw -LiteralPath (Join-Path $differentRuns[0].FullName "evidence-package.json") -Encoding UTF8 | ConvertFrom-Json
        Assert-True ($differentPackage.Status -eq "retest") "A no-common-metric comparison must require a retest."
    }
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Evidence pipeline tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Evidence pipeline tests: PASS" -ForegroundColor Green
