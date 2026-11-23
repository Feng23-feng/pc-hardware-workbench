[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackRendererPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

$resolvedPackRenderer = (Resolve-Path -LiteralPath $PackRendererPath).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-pack-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $csvPath = Join-Path $tempRoot "full.csv"
    [IO.File]::WriteAllText($csvPath, @'
"Date","Time","FPS","Frame Time Presented (avg) [ms]","GPU Effective Clock [MHz]","GPU Core Voltage [V]","GPU Memory Clock [MHz]","GPU Power [W]","GPU Temperature [C]","GPU Hot Spot [C]","GPU Memory Junction [C]","CPU Package [C]","CPU Package Power [W]"
"2026-11-03","12:00:00","60","16.7","2200","0.780","1750","110","55","63","58","58","35"
"2026-11-03","12:00:01","72","13.9","2450","0.835","1750","145","61","69","65","65","48"
"2026-11-03","12:00:02","75","13.3","2510","0.845","1750","152","64","72","68","67","52"
"2026-11-03","12:00:03","73","13.7","2490","0.840","1750","148","63","71","67","66","50"
'@, $utf8)

    $outputRoot = Join-Path $tempRoot "first-pass"
    $manifestPath = & $resolvedPackRenderer `
        -Path $csvPath `
        -OutputDirectory $outputRoot `
        -Preset FirstPass
    Assert-True (
        -not [string]::IsNullOrWhiteSpace([string]$manifestPath) -and
        (Test-Path -LiteralPath $manifestPath -PathType Leaf)
    ) "FirstPass did not create a manifest."
    $manifest = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($manifest.SchemaVersion -eq "1.0") "Pack manifest schema version is missing."
    Assert-True ($manifest.Preset -eq "FirstPass") "Pack preset is wrong."
    Assert-True ($manifest.Status -eq "complete") "Complete fixture produced a partial pack."
    Assert-True (@($manifest.Charts).Count -eq 4) "FirstPass should produce four charts."
    $chartIds = @($manifest.Charts | ForEach-Object Id)
    foreach ($requiredId in @(
        "telemetry-overview",
        "gpu-vf-timeline",
        "gpu-power-thermal",
        "laptop-shared-budget"
    )) {
        Assert-True ($chartIds -contains $requiredId) "FirstPass omitted chart '$requiredId'."
    }
    foreach ($chart in @($manifest.Charts)) {
        $chartPath = Join-Path $outputRoot $chart.RelativePath
        Assert-True (Test-Path -LiteralPath $chartPath -PathType Leaf) "Pack chart is missing: $($chart.RelativePath)"
        if (Test-Path -LiteralPath $chartPath -PathType Leaf) {
            $svg = Get-Content -Raw -LiteralPath $chartPath -Encoding UTF8
            Assert-True ($svg.Contains("<svg ")) "Pack chart is not SVG: $($chart.RelativePath)"
            Assert-True (-not ($svg -match "NaN|Infinity")) "Pack chart contains a non-finite value: $($chart.RelativePath)"
        }
    }
    $overviewSvg = Get-Content -Raw -LiteralPath (
        Join-Path $outputRoot "01-telemetry-overview.svg"
    ) -Encoding UTF8
    $coreClockIndex = $overviewSvg.IndexOf("GPU effective clock (MHz)")
    $memoryClockIndex = $overviewSvg.IndexOf("GPU memory clock (MHz)")
    Assert-True (
        $coreClockIndex -ge 0 -and
        $memoryClockIndex -gt $coreClockIndex
    ) "Memory clock does not follow the GPU core clock in the overview."
    Assert-True (
        $overviewSvg.Contains('data-series-kind="memory-clock"')
    ) "Memory clock series is not highlighted distinctly."
    Assert-True (
        $overviewSvg.Contains('data-series-halo="memory-clock"')
    ) "Memory clock series lacks a visible emphasis halo."
    Assert-True (
        $overviewSvg.Contains('filterUnits="userSpaceOnUse"')
    ) "Flat series can be clipped by a zero-height object-bounding filter region."
    Assert-True (
        ([regex]::Matches($overviewSvg, 'data-series-marker="memory-clock"')).Count -ge 5
    ) "Flat memory clock series lacks visible highlight markers."

    $gpuOutput = Join-Path $tempRoot "gpu-tuning"
    $gpuManifestPath = & $resolvedPackRenderer `
        -Path $csvPath `
        -OutputDirectory $gpuOutput `
        -Preset GpuTuning
    $gpuManifest = Get-Content -Raw -LiteralPath $gpuManifestPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True (@($gpuManifest.Charts).Count -eq 5) "GpuTuning should keep memory in the overview and add frame-delivery evidence."
    Assert-True (
        @($gpuManifest.Charts | ForEach-Object Id) -contains "gpu-frame-delivery"
    ) "GpuTuning omitted frame-delivery evidence."
    Assert-True (
        @($gpuManifest.Charts | ForEach-Object Id) -notcontains "gpu-memory-timeline"
    ) "GpuTuning should not split memory into a separate default chart."

    $cpuOnlyPath = Join-Path $tempRoot "cpu-only.csv"
    [IO.File]::WriteAllText($cpuOnlyPath, @'
"Date","Time","CPU Package [C]","CPU Package Power [W]"
"2026-11-03","12:00:00","55","35"
"2026-11-03","12:00:01","63","48"
'@, $utf8)
    $cpuOutput = Join-Path $tempRoot "cpu-partial"
    $cpuManifestPath = & $resolvedPackRenderer `
        -Path $cpuOnlyPath `
        -OutputDirectory $cpuOutput `
        -Preset CpuTuning
    $cpuManifest = Get-Content -Raw -LiteralPath $cpuManifestPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($cpuManifest.Status -eq "partial") "Optional missing charts did not produce a partial pack."
    Assert-True (
        @($cpuManifest.Skipped | ForEach-Object Id) -contains "gpu-vf-timeline"
    ) "Missing V/F data was not recorded as a skip."
    Assert-True (
        @($cpuManifest.Skipped | ForEach-Object Id) -contains "laptop-shared-budget"
    ) "Missing shared-budget data was not recorded as a skip."
    Assert-True (
        @($cpuManifest.Skipped | ForEach-Object Id) -contains "cpu-gaming-latency"
    ) "Missing gaming data was not recorded as a skip."

    $existingOutput = Join-Path $tempRoot "existing"
    New-Item -ItemType Directory -Path $existingOutput -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $existingOutput "keep.txt"), "keep", $utf8)
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedPackRenderer `
            -Path $csvPath `
            -OutputDirectory $existingOutput `
            -Preset FirstPass 2>&1 | Out-Null
        $existingExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($existingExitCode -eq 1) "Pack renderer accepted a non-empty output directory."
    Assert-True (
        (Get-Content -Raw -LiteralPath (Join-Path $existingOutput "keep.txt")) -eq "keep"
    ) "Pack renderer modified a non-empty output directory."

    if ($failures.Count -gt 0) {
        Write-Host "Telemetry pack regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "Telemetry pack regression: PASS" -ForegroundColor Green
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
