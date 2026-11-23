[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RendererPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

$resolvedRenderer = (Resolve-Path -LiteralPath $RendererPath).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-conclusion-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $inputPath = Join-Path $tempRoot "conclusion.json"
    @{
        SchemaVersion = "1.0"
        Title = "GPU conclusion <script>alert(1)</script>"
        Subtitle = "Baseline and candidate"
        Verdict = @{ Label = "Benchmark-only"; Tone = "negative" }
        Context = @(
            @{ Label = "Device"; Value = "Fixture laptop" },
            @{ Label = "Workload"; Value = "Fixed benchmark" }
        )
        Metrics = @(
            @{
                Label = "Speed Way"
                Baseline = 100
                Candidate = 102
                DeltaPercent = 2
                Tone = "positive"
            },
            @{
                Label = "Time Spy CPU"
                Baseline = 100
                Candidate = 80
                DeltaPercent = -20
                Tone = "negative"
            }
        )
        Telemetry = @(
            @{
                Label = "Thermal-limit samples"
                Value = "0"
                Detail = "Observed in selected window"
                Tone = "positive"
            }
        )
        Decisions = @(
            @{ Title = "GPU"; Text = "Repeatable small gain"; Tone = "positive" },
            @{ Title = "System"; Text = "CPU regression prevents a clean comparison"; Tone = "negative" },
            @{ Title = "Rollback"; Text = "Return to the known-good profile"; Tone = "warning" }
        )
        Limitations = @("Short screening only", "Saved curve table unavailable")
        Sources = @("fixture.csv", "result.xml")
        SafetyNotice = "Reference only; put safety first."
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $inputPath -Encoding UTF8

    $outputPath = Join-Path $tempRoot "conclusion.svg"
    $writtenPath = & $resolvedRenderer -InputPath $inputPath -OutputPath $outputPath
    Assert-True ($writtenPath -eq $outputPath) "Conclusion renderer did not return the output path."
    Assert-True (Test-Path -LiteralPath $outputPath -PathType Leaf) "Conclusion SVG was not created."
    $svg = Get-Content -Raw -LiteralPath $outputPath -Encoding UTF8
    Assert-True ($svg.StartsWith('<?xml version="1.0" encoding="UTF-8"?>')) "SVG XML declaration is missing."
    try {
        [xml]$parsed = $svg
        $xmlValid = $true
    }
    catch {
        $xmlValid = $false
    }
    Assert-True $xmlValid "Conclusion SVG is not valid XML."
    Assert-True (-not ($svg -match "<script>alert\(1\)</script>")) "Conclusion text was not escaped."
    Assert-True ($svg.Contains("&lt;script&gt;alert(1)&lt;/script&gt;")) "Escaped conclusion title is missing."
    Assert-True ($svg.Contains("Performance evidence")) "Performance section is missing."
    Assert-True ($svg.Contains("Telemetry evidence")) "Telemetry section is missing."
    Assert-True ($svg.Contains("Rollback")) "Decision section is incomplete."
    Assert-True (
        -not ($svg -match 'y="0"[^>]*>Repeatable')
    ) "Decision text was rendered outside its card."
    Assert-True ($svg.Contains("Short screening only")) "Limitations are missing."
    Assert-True ($svg.Contains("Reference only; put safety first.")) "Safety notice is missing."
    Assert-True (-not ($svg -match "NaN|Infinity")) "Conclusion SVG contains a non-finite value."

    $existingHash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -InputPath $inputPath `
            -OutputPath $outputPath 2>&1 | Out-Null
        $existingExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($existingExitCode -eq 2) "Conclusion renderer accepted an existing output."
    Assert-True (
        (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash -eq $existingHash
    ) "Conclusion renderer modified an existing output."

    $invalidPath = Join-Path $tempRoot "invalid.json"
    @{ SchemaVersion = "2.0" } |
        ConvertTo-Json |
        Set-Content -LiteralPath $invalidPath -Encoding UTF8
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -InputPath $invalidPath `
            -OutputPath (Join-Path $tempRoot "invalid.svg") 2>&1 | Out-Null
        $invalidExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($invalidExitCode -eq 2) "Conclusion renderer accepted an invalid schema version."

    if ($failures.Count -gt 0) {
        Write-Host "Tuning conclusion regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "Tuning conclusion regression: PASS" -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
