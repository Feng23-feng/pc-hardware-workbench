[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputDirectory,

    [ValidateSet("FirstPass", "GpuTuning", "CpuTuning")]
    [string]$Preset = "FirstPass",

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$WarmupSeconds = 0,

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$DurationSeconds = 0,

    [string]$ManifestPath = ""
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
$analyzerPath = Join-Path $PSScriptRoot "analyze-telemetry.ps1"
$rendererPath = Join-Path $PSScriptRoot "render-telemetry-chart.ps1"
foreach ($requiredPath in @($pathSafetyHelper, $analyzerPath, $rendererPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required telemetry dependency is missing: $requiredPath"
    }
}
. $pathSafetyHelper

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$FilePath)

    $stream = [IO.File]::OpenRead($FilePath)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash($stream)
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-ExactMetricPattern {
    param([Parameter(Mandatory = $true)][string]$Metric)
    return "^" + [regex]::Escape($Metric) + "$"
}

function Get-AvailablePatterns {
    param(
        [Parameter(Mandatory = $true)][string[]]$AvailableMetrics,
        [Parameter(Mandatory = $true)][string[]]$RequestedMetrics
    )

    $patterns = New-Object System.Collections.Generic.List[string]
    foreach ($metric in $RequestedMetrics) {
        if ($AvailableMetrics -contains $metric) {
            $patterns.Add((Get-ExactMetricPattern -Metric $metric)) | Out-Null
        }
    }
    return [string[]]$patterns.ToArray()
}

function Add-ChartSpec {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Specs,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$IncludeColumn = @(),
        [switch]$ClockVoltageTimeline,
        [switch]$Required
    )

    $Specs.Add([pscustomobject]@{
        Id = $Id
        Title = $Title
        FileName = $FileName
        IncludeColumn = $IncludeColumn
        ClockVoltageTimeline = [bool]$ClockVoltageTimeline
        Required = [bool]$Required
    }) | Out-Null
}

try {
    $resolvedInput = Assert-LocalReadFilePath -Path $Path
    $outputRoot = ConvertTo-LocalFilesystemPath -Path $OutputDirectory
    if (Test-PathChainHasReparsePoint -Path $outputRoot) {
        throw "OutputDirectory resolves through a reparse point."
    }
    if (Test-Path -LiteralPath $outputRoot -PathType Leaf) {
        throw "OutputDirectory must be a directory: $outputRoot"
    }
    if (Test-Path -LiteralPath $outputRoot -PathType Container) {
        $existing = @(Get-ChildItem -LiteralPath $outputRoot -Force)
        if ($existing.Count -gt 0) {
            throw "OutputDirectory must be empty: $outputRoot"
        }
    }
    else {
        New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Join-Path $outputRoot "telemetry-pack-manifest.json"
    }
    $resolvedManifest = Resolve-LocalOutputFilePath -Path $ManifestPath
    $manifestParent = Split-Path -Parent $resolvedManifest
    if (
        -not $manifestParent.Equals(
            $outputRoot.TrimEnd("\"),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "ManifestPath must be directly inside OutputDirectory."
    }

    $analyzerParameters = @{
        Path = $resolvedInput
        Format = "ChartData"
    }
    if ($WarmupSeconds -gt 0) {
        $analyzerParameters.WarmupSeconds = $WarmupSeconds
    }
    if ($DurationSeconds -gt 0) {
        $analyzerParameters.DurationSeconds = $DurationSeconds
    }
    $chartData = & $analyzerPath @analyzerParameters | Out-String | ConvertFrom-Json
    $availableMetrics = @(
        @($chartData.Series) |
            ForEach-Object { [string]$_.Metric } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    if ($availableMetrics.Count -eq 0) {
        throw "No recognized numeric telemetry series can form a chart pack."
    }

    $specs = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    $preferredClock = if ($availableMetrics -contains "GPU effective clock (MHz)") {
        "GPU effective clock (MHz)"
    }
    elseif ($availableMetrics -contains "GPU core clock (MHz)") {
        "GPU core clock (MHz)"
    }
    else {
        $null
    }
    $overviewCandidates = @(
        "FPS",
        "Frame time (ms)",
        "GPU power (W)",
        "GPU temperature (C)",
        $preferredClock,
        "GPU memory clock (MHz)",
        "CPU package power (W)",
        "CPU package temperature (C)"
    )
    if ($Preset -eq "CpuTuning") {
        $overviewCandidates = @(
            "FPS",
            "Frame time (ms)",
            "CPU package power (W)",
            "CPU package temperature (C)"
        )
    }
    $overviewPatterns = @(
        Get-AvailablePatterns `
            -AvailableMetrics $availableMetrics `
            -RequestedMetrics $overviewCandidates
    )
    if ($overviewPatterns.Count -eq 0) {
        throw "The selected preset requires at least one recognized overview series."
    }
    Add-ChartSpec `
        -Specs $specs `
        -Id "telemetry-overview" `
        -Title "Telemetry overview" `
        -FileName "01-telemetry-overview.svg" `
        -IncludeColumn $overviewPatterns `
        -Required

    $clockMetric = if ($availableMetrics -contains "GPU effective clock (MHz)") {
        "GPU effective clock (MHz)"
    }
    elseif ($availableMetrics -contains "GPU core clock (MHz)") {
        "GPU core clock (MHz)"
    }
    else {
        $null
    }
    $hasVf = (
        $Preset -ne "CpuTuning" -and
        $chartData.TimeBased -eq $true -and
        $null -ne $clockMetric -and
        $availableMetrics -contains "GPU core voltage (V)"
    )
    if ($hasVf) {
        Add-ChartSpec `
            -Specs $specs `
            -Id "gpu-vf-timeline" `
            -Title "GPU frequency and voltage timeline" `
            -FileName "02-gpu-vf-timeline.svg" `
            -ClockVoltageTimeline
    }
    else {
        $skipped.Add([pscustomobject]@{
            Id = "gpu-vf-timeline"
            Reason = "Timestamped GPU clock and core voltage are not both available."
        }) | Out-Null
    }

    if ($Preset -eq "CpuTuning") {
        $cpuThermalPatterns = @(
            Get-AvailablePatterns `
                -AvailableMetrics $availableMetrics `
                -RequestedMetrics @(
                    "CPU package power (W)",
                    "CPU package temperature (C)",
                    "CPU Tctl/Tdie temperature (C)",
                    "CPU die average temperature (C)"
                )
        )
        if ($cpuThermalPatterns.Count -gt 0) {
            Add-ChartSpec `
                -Specs $specs `
                -Id "cpu-core-power-thermal" `
                -Title "CPU package power and thermal evidence" `
                -FileName "02-cpu-core-power-thermal.svg" `
                -IncludeColumn $cpuThermalPatterns
        }
        else {
            $skipped.Add([pscustomobject]@{
                Id = "cpu-core-power-thermal"
                Reason = "No recognized CPU package power or temperature series."
            }) | Out-Null
        }
    }
    else {
        $gpuThermalPatterns = @(
            Get-AvailablePatterns `
                -AvailableMetrics $availableMetrics `
                -RequestedMetrics @(
                    "GPU power (W)",
                    "GPU temperature (C)",
                    "GPU hotspot (C)",
                    "GPU memory junction (C)"
                )
        )
        if ($gpuThermalPatterns.Count -gt 0) {
            Add-ChartSpec `
                -Specs $specs `
                -Id "gpu-power-thermal" `
                -Title "GPU power and thermal evidence" `
                -FileName "03-gpu-power-thermal.svg" `
                -IncludeColumn $gpuThermalPatterns
        }
        else {
            $skipped.Add([pscustomobject]@{
                Id = "gpu-power-thermal"
                Reason = "No recognized GPU power or temperature series."
            }) | Out-Null
        }
    }

    $gpuSharedPatterns = @(
        Get-AvailablePatterns `
            -AvailableMetrics $availableMetrics `
            -RequestedMetrics @(
                "GPU power (W)",
                "GPU hotspot (C)"
            )
    )
    $cpuSharedPatterns = @(
        Get-AvailablePatterns `
            -AvailableMetrics $availableMetrics `
            -RequestedMetrics @(
                "CPU package power (W)",
                "CPU package temperature (C)"
            )
    )
    $sharedPatterns = @($gpuSharedPatterns + $cpuSharedPatterns)
    if ($gpuSharedPatterns.Count -ge 1 -and $cpuSharedPatterns.Count -ge 1) {
        Add-ChartSpec `
            -Specs $specs `
            -Id "laptop-shared-budget" `
            -Title "CPU and GPU shared budget" `
            -FileName "04-laptop-shared-budget.svg" `
            -IncludeColumn $sharedPatterns
    }
    else {
        $skipped.Add([pscustomobject]@{
            Id = "laptop-shared-budget"
            Reason = "Insufficient CPU/GPU power or temperature evidence."
        }) | Out-Null
    }

    $performancePatterns = @(
        Get-AvailablePatterns `
            -AvailableMetrics $availableMetrics `
            -RequestedMetrics @(
                "FPS",
                "Frame time (ms)",
                "Presented frame time 99% high (ms)",
                "Presented FPS 1% low (FPS)",
                "Presented FPS 0.1% low (FPS)"
            )
    )
    if ($Preset -eq "GpuTuning") {
        if ($performancePatterns.Count -gt 0) {
            Add-ChartSpec `
                -Specs $specs `
                -Id "gpu-frame-delivery" `
                -Title "GPU frame delivery evidence" `
                -FileName "05-gpu-frame-delivery.svg" `
                -IncludeColumn $performancePatterns
        }
        else {
            $skipped.Add([pscustomobject]@{
                Id = "gpu-frame-delivery"
                Reason = "No recognized FPS or frame-time series."
            }) | Out-Null
        }
    }
    elseif ($Preset -eq "CpuTuning") {
        if ($performancePatterns.Count -gt 0) {
            Add-ChartSpec `
                -Specs $specs `
                -Id "cpu-gaming-latency" `
                -Title "CPU gaming latency evidence" `
                -FileName "03-cpu-gaming-latency.svg" `
                -IncludeColumn $performancePatterns
        }
        else {
            $skipped.Add([pscustomobject]@{
                Id = "cpu-gaming-latency"
                Reason = "No recognized FPS or frame-time series."
            }) | Out-Null
        }
    }

    $charts = New-Object System.Collections.Generic.List[object]
    $createdPaths = New-Object System.Collections.Generic.List[string]
    foreach ($spec in $specs) {
        $chartPath = Join-Path $outputRoot $spec.FileName
        $renderArgs = @{
            Path = $resolvedInput
            OutputPath = $chartPath
            Title = $spec.Title
        }
        if ($WarmupSeconds -gt 0) {
            $renderArgs.WarmupSeconds = $WarmupSeconds
        }
        if ($DurationSeconds -gt 0) {
            $renderArgs.DurationSeconds = $DurationSeconds
        }
        if ($spec.ClockVoltageTimeline) {
            $renderArgs.ClockVoltageTimeline = $true
        }
        if (@($spec.IncludeColumn).Count -gt 0) {
            $renderArgs.IncludeColumn = [string[]]$spec.IncludeColumn
            $renderArgs.MaxSeries = [Math]::Min(32, @($spec.IncludeColumn).Count)
        }
        try {
            & $rendererPath @renderArgs | Out-Null
            if (-not (Test-Path -LiteralPath $chartPath -PathType Leaf)) {
                throw "Renderer did not create the expected chart."
            }
            $createdPaths.Add($chartPath) | Out-Null
            $charts.Add([pscustomobject]@{
                Id = $spec.Id
                Title = $spec.Title
                Kind = "chart"
                Mime = "image/svg+xml"
                FileName = $spec.FileName
                RelativePath = $spec.FileName
                Sha256 = Get-Sha256Hex -FilePath $chartPath
            }) | Out-Null
        }
        catch {
            if ($spec.Required) {
                throw "Required chart '$($spec.Id)' failed: $($_.Exception.Message)"
            }
            $skipped.Add([pscustomobject]@{
                Id = $spec.Id
                Reason = (([string]$_.Exception.Message) -replace "\s+", " ").Trim()
            }) | Out-Null
        }
    }

    if ($charts.Count -eq 0) {
        throw "No chart pack figure could be generated."
    }
    $status = if ($skipped.Count -eq 0) { "complete" } else { "partial" }
    $manifest = [pscustomobject]@{
        SchemaVersion = "1.0"
        Preset = $Preset
        Status = $status
        SourceFileName = [IO.Path]::GetFileName($resolvedInput)
        SourceSha256 = Get-Sha256Hex -FilePath $resolvedInput
        Window = [string]$chartData.Window
        AnalyzedRows = [int]$chartData.AnalyzedRows
        CreatedAt = [DateTimeOffset]::Now.ToString("o")
        Charts = [object[]]$charts.ToArray()
        Warnings = @($chartData.Warnings)
        Skipped = [object[]]$skipped.ToArray()
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 10
    $writtenManifest = Write-LocalOutputFile `
        -Path $resolvedManifest `
        -Content ($manifestJson + [Environment]::NewLine)
    Write-Output $writtenManifest
}
catch {
    [Console]::Error.WriteLine(
        (([string]$_.Exception.Message) -replace "\s+", " ").Trim()
    )
    exit 1
}
