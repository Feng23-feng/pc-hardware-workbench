[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AnalyzerPath
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

$analyzer = (Resolve-Path -LiteralPath $AnalyzerPath).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-presentmon-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $csvPath = Join-Path $testRoot "capture.csv"
    @(
        "Application,ProcessID,PresentMode,SyncInterval,TimeInSeconds,msBetweenPresents,msUntilDisplayed,Dropped",
        "game.exe,1234,Hardware: Independent Flip,1,0.000,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.010,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.020,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.030,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.040,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.050,100.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.150,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.160,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.170,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.180,10.0,15.0,false"
    ) | Set-Content -LiteralPath $csvPath -Encoding UTF8

    $jsonPath = Join-Path $testRoot "report.json"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $analyzer `
        -InputPath $csvPath `
        -ProcessName "game.exe" `
        -Format Json `
        -OutputPath $jsonPath
    Assert-True ($LASTEXITCODE -eq 0) "PresentMon JSON analysis failed."
    $report = Get-Content -Raw -LiteralPath $jsonPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($report.source.validFrameCount -eq 10) "Wrong valid frame count."
    Assert-True ($report.analysis.averageFrameTimeMs -eq 19) "Wrong average frame time."
    Assert-True ($report.analysis.medianFrameTimeMs -eq 10) "Wrong median frame time."
    Assert-True ([math]::Abs($report.analysis.onePercentLowFps - 10) -lt 0.001) "Wrong 1% low FPS."
    Assert-True ($report.analysis.spikeFrameCount -eq 1) "Wrong spike frame count."
    Assert-True ($report.analysis.spikeClusterCount -eq 1) "Wrong spike cluster count."
    Assert-True ($report.scope.applications[0] -eq "game.exe") "Process filter lost the application."
    Assert-True ($report.source.sha256.Length -eq 64) "Source hash is missing."

    $markdownPath = Join-Path $testRoot "report.md"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $analyzer `
        -InputPath $csvPath `
        -Format Markdown `
        -OutputPath $markdownPath
    Assert-True ($LASTEXITCODE -eq 0) "PresentMon Markdown analysis failed."
    $markdown = Get-Content -Raw -LiteralPath $markdownPath -Encoding UTF8
    Assert-True ($markdown -match "PresentMon frame-time report") "Markdown report heading is missing."
    Assert-True ($markdown -match "1% low") "Markdown report has no 1% low."
    Assert-True ($markdown -match "not a stability claim") "Markdown report overstates stability."

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $analyzer `
            -InputPath $csvPath `
            -Format Json `
            -OutputPath $jsonPath *> $null
        $overwriteExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    Assert-True ($overwriteExit -eq 2) "PresentMon analyzer should refuse to overwrite output."

    $badCsvPath = Join-Path $testRoot "bad.csv"
    @("Application,ProcessID,TimeInSeconds", "game.exe,1234,0.0") |
        Set-Content -LiteralPath $badCsvPath -Encoding UTF8
    try {
        $ErrorActionPreference = "Continue"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $analyzer `
            -InputPath $badCsvPath `
            -Format Json *> $null
        $badExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    Assert-True ($badExit -eq 2) "PresentMon analyzer should reject a missing frame-time column."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "PresentMon analysis tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}
Write-Host "PresentMon analysis tests: PASS"
