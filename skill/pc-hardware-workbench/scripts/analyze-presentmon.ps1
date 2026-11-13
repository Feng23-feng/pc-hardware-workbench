[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InputPath,

    [string]$ProcessName,

    [ValidateSet("Json", "Markdown")]
    [string]$Format = "Json",

    [double]$SpikeMultiplier = 2.0,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptRoot "local-path-safety.ps1")

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function ConvertFrom-InvariantNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return $null
    }
    $number = 0.0
    if ([double]::TryParse(
        ([string]$Value).Trim(),
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return $null
}

function Find-Column {
    param(
        [Parameter(Mandatory = $true)][string[]]$Headers,
        [Parameter(Mandatory = $true)][string[]]$Aliases
    )
    foreach ($alias in $Aliases) {
        foreach ($header in $Headers) {
            if ($header -ieq $alias) {
                return $header
            }
        }
    }
    return $null
}

function Get-RowValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [AllowNull()][string]$Column
    )
    if ([string]::IsNullOrWhiteSpace($Column)) {
        return $null
    }
    $property = $Row.PSObject.Properties[$Column]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-Percentile {
    param(
        [Parameter(Mandatory = $true)][double[]]$SortedValues,
        [Parameter(Mandatory = $true)][double]$Percentile
    )
    if ($SortedValues.Count -eq 0) {
        return $null
    }
    $index = [math]::Ceiling($SortedValues.Count * $Percentile) - 1
    $index = [math]::Max(0, [math]::Min($SortedValues.Count - 1, $index))
    return $SortedValues[$index]
}

function Get-SlowPercentLowFps {
    param(
        [Parameter(Mandatory = $true)][double[]]$FrameTimes,
        [Parameter(Mandatory = $true)][double]$Fraction
    )
    if ($FrameTimes.Count -eq 0) {
        return $null
    }
    $sorted = @($FrameTimes | Sort-Object -Descending)
    $count = [math]::Max(1, [math]::Ceiling($sorted.Count * $Fraction))
    $slow = @($sorted | Select-Object -First $count)
    $mean = ($slow | Measure-Object -Average).Average
    if ($mean -le 0) {
        return $null
    }
    return 1000.0 / $mean
}

if ($SpikeMultiplier -lt 1.1) {
    Stop-WithInputError "SpikeMultiplier must be at least 1.1."
}
try {
    $resolvedInput = Assert-LocalReadFilePath -Path $InputPath
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
    }
}
catch {
    Stop-WithInputError $_.Exception.Message
}

$lines = @([IO.File]::ReadAllLines($resolvedInput, [Text.Encoding]::UTF8))
if ($lines.Count -lt 2) {
    Stop-WithInputError "PresentMon CSV contains no data rows."
}
$headerIndex = -1
for ($index = 0; $index -lt [math]::Min(30, $lines.Count); $index++) {
    if ($lines[$index] -match '(?i)(Application|ProcessName|Process).*?(msBetweenPresents|FrameTime|msBetweenDisplayChange)') {
        $headerIndex = $index
        break
    }
}
if ($headerIndex -lt 0) {
    Stop-WithInputError "Could not identify a PresentMon header row with application and frame-time columns."
}
$csvText = ($lines[$headerIndex..($lines.Count - 1)] -join "`r`n")
try {
    $rows = @($csvText | ConvertFrom-Csv)
}
catch {
    Stop-WithInputError "PresentMon CSV parsing failed: $($_.Exception.Message)"
}
if ($rows.Count -eq 0) {
    Stop-WithInputError "PresentMon CSV contains no parsed rows."
}

$headers = @($rows[0].PSObject.Properties.Name)
$applicationColumn = Find-Column $headers @("Application", "ProcessName", "Process")
$processIdColumn = Find-Column $headers @("ProcessID", "PID")
$frameTimeColumn = Find-Column $headers @(
    "msBetweenPresents", "MsBetweenPresents", "FrameTime", "FrameTimeMs",
    "msBetweenDisplayChange", "MsBetweenDisplayChange"
)
$timeColumn = Find-Column $headers @(
    "TimeInSeconds", "TimeInMs", "CPUStartTime", "CPUStartTimeInMs"
)
$presentModeColumn = Find-Column $headers @("PresentMode", "PresentModeName")
$syncIntervalColumn = Find-Column $headers @("SyncInterval", "SyncIntervalInSeconds")
$droppedColumn = Find-Column $headers @("Dropped", "WasDropped")
$displayLatencyColumn = Find-Column $headers @("msUntilDisplayed", "MsUntilDisplayed")
if ([string]::IsNullOrWhiteSpace($frameTimeColumn)) {
    Stop-WithInputError "PresentMon CSV has no recognized frame-time column."
}

$warnings = New-Object System.Collections.Generic.List[string]
$applications = New-Object System.Collections.Generic.List[string]
$processIds = New-Object System.Collections.Generic.List[int]
$frames = New-Object System.Collections.Generic.List[object]
$invalidRows = 0
$droppedFrames = 0
$sawDroppedValue = $false
$rowIndex = 0
foreach ($row in $rows) {
    $rowIndex++
    $application = if ($applicationColumn) { ([string](Get-RowValue $row $applicationColumn)).Trim() } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($ProcessName) -and
        $application -ine $ProcessName.Trim()) {
        continue
    }
    $frameTimeMs = ConvertFrom-InvariantNumber (Get-RowValue $row $frameTimeColumn)
    if ($null -eq $frameTimeMs -or $frameTimeMs -le 0 -or $frameTimeMs -gt 600000) {
        $invalidRows++
        continue
    }
    if (-not [string]::IsNullOrWhiteSpace($application) -and -not $applications.Contains($application)) {
        $applications.Add($application) | Out-Null
    }
    if ($processIdColumn) {
        $pidValue = ConvertFrom-InvariantNumber (Get-RowValue $row $processIdColumn)
        if ($null -ne $pidValue) {
            $parsedPid = [int]$pidValue
            if (-not $processIds.Contains($parsedPid)) {
                $processIds.Add($parsedPid) | Out-Null
            }
        }
    }
    $timeMs = $null
    if ($timeColumn) {
        $timeMs = ConvertFrom-InvariantNumber (Get-RowValue $row $timeColumn)
        if ($null -ne $timeMs -and $timeColumn -ieq "TimeInSeconds") {
            $timeMs = $timeMs * 1000.0
        }
    }
    $dropped = $false
    if ($droppedColumn) {
        $droppedText = [string](Get-RowValue $row $droppedColumn)
        if (-not [string]::IsNullOrWhiteSpace($droppedText)) {
            $sawDroppedValue = $true
            $dropped = $droppedText -match '^(?i:true|1|yes)$'
        }
    }
    if ($dropped) {
        $droppedFrames++
    }
    $displayLatencyMs = ConvertFrom-InvariantNumber (Get-RowValue $row $displayLatencyColumn)
    $frames.Add([pscustomobject][ordered]@{
        Index = $rowIndex
        Application = $application
        ProcessID = if ($processIdColumn) { Get-RowValue $row $processIdColumn } else { $null }
        TimeMs = $timeMs
        FrameTimeMs = $frameTimeMs
        PresentMode = if ($presentModeColumn) { [string](Get-RowValue $row $presentModeColumn) } else { $null }
        SyncInterval = ConvertFrom-InvariantNumber (Get-RowValue $row $syncIntervalColumn)
        DisplayLatencyMs = $displayLatencyMs
        Dropped = $dropped
    }) | Out-Null
}

if ($frames.Count -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        Stop-WithInputError "No valid PresentMon frames matched process '$ProcessName'."
    }
    Stop-WithInputError "No valid frame-time rows were found."
}
if ($frames.Count -lt 2) {
    Stop-WithInputError "At least two valid frames are required for frame-time analysis."
}

$timeValues = @($frames | ForEach-Object { $_.TimeMs } | Where-Object { $null -ne $_ })
if ($timeValues.Count -ne $frames.Count) {
    $warnings.Add("Some rows are missing a usable capture timestamp; ordering uses row order and cumulative frame time where needed.") | Out-Null
}
$cursorMs = 0.0
foreach ($frame in $frames) {
    if ($null -eq $frame.TimeMs) {
        $frame.TimeMs = $cursorMs
    }
    $cursorMs = [double]$frame.TimeMs + [double]$frame.FrameTimeMs
}
$orderedFrames = @($frames | Sort-Object TimeMs, Index)
$firstTime = [double]$orderedFrames[0].TimeMs
$lastTime = [double]$orderedFrames[$orderedFrames.Count - 1].TimeMs
$elapsedMs = $lastTime - $firstTime
if ($elapsedMs -le 0) {
    $elapsedMs = ($frames | Measure-Object FrameTimeMs -Sum).Sum
    $warnings.Add("Capture timestamps do not span a positive duration; duration was reconstructed from frame intervals.") | Out-Null
}
$frameTimes = @($frames | ForEach-Object { [double]$_.FrameTimeMs })
$sortedFrameTimes = @($frameTimes | Sort-Object)
$median = Get-Percentile -SortedValues $sortedFrameTimes -Percentile 0.5
$p95 = Get-Percentile -SortedValues $sortedFrameTimes -Percentile 0.95
$p99 = Get-Percentile -SortedValues $sortedFrameTimes -Percentile 0.99
$maximum = $sortedFrameTimes[$sortedFrameTimes.Count - 1]
$averageFrameTime = ($frameTimes | Measure-Object -Average).Average
$averageFps = if ($averageFrameTime -gt 0) { 1000.0 / $averageFrameTime } else { $null }
$onePercentLowFps = Get-SlowPercentLowFps -FrameTimes $frameTimes -Fraction 0.01
$pointOnePercentLowFps = Get-SlowPercentLowFps -FrameTimes $frameTimes -Fraction 0.001
$spikeThresholdMs = [double]$median * $SpikeMultiplier

if ($applications.Count -gt 1 -and [string]::IsNullOrWhiteSpace($ProcessName)) {
    $warnings.Add("The capture contains multiple applications; compare only frames from the intended process.") | Out-Null
}
if ($invalidRows -gt 0) {
    $warnings.Add("$invalidRows row(s) were skipped because the frame-time value was missing, non-positive, or implausible.") | Out-Null
}

$spikes = New-Object System.Collections.Generic.List[object]
$spikeClusters = New-Object System.Collections.Generic.List[object]
$clusterStart = $null
$clusterFrames = 0
$clusterMaxFrameTime = 0.0
$clusterStartTime = $null
$clusterEndTime = $null
for ($index = 0; $index -lt $orderedFrames.Count; $index++) {
    $frame = $orderedFrames[$index]
    $isSpike = [double]$frame.FrameTimeMs -gt $spikeThresholdMs
    if ($isSpike) {
        $spike = [pscustomobject][ordered]@{
            index = $index + 1
            timeMs = [double]$frame.TimeMs - $firstTime
            frameTimeMs = [double]$frame.FrameTimeMs
            multipleOfMedian = [double]$frame.FrameTimeMs / [double]$median
            application = $frame.Application
            processId = $frame.ProcessID
        }
        $spikes.Add($spike) | Out-Null
        if ($null -eq $clusterStart) {
            $clusterStart = $index
            $clusterFrames = 0
            $clusterMaxFrameTime = 0.0
            $clusterStartTime = [double]$frame.TimeMs - $firstTime
        }
        $clusterFrames++
        $clusterMaxFrameTime = [math]::Max($clusterMaxFrameTime, [double]$frame.FrameTimeMs)
        $clusterEndTime = [double]$frame.TimeMs - $firstTime
    }
    elseif ($null -ne $clusterStart) {
        $spikeClusters.Add([pscustomobject][ordered]@{
            startFrame = $clusterStart + 1
            frameCount = $clusterFrames
            startMs = $clusterStartTime
            endMs = $clusterEndTime
            maxFrameTimeMs = $clusterMaxFrameTime
        }) | Out-Null
        $clusterStart = $null
    }
}
if ($null -ne $clusterStart) {
    $spikeClusters.Add([pscustomobject][ordered]@{
        startFrame = $clusterStart + 1
        frameCount = $clusterFrames
        startMs = $clusterStartTime
        endMs = $clusterEndTime
        maxFrameTimeMs = $clusterMaxFrameTime
    }) | Out-Null
}

$topSpikes = @($spikes | Sort-Object frameTimeMs -Descending | Select-Object -First 10)
$status = if ($warnings.Count -gt 0) { "review" } else { "ready-for-review" }
$sha256 = (Get-FileHash -LiteralPath $resolvedInput -Algorithm SHA256).Hash
$result = [pscustomobject][ordered]@{
    schemaVersion = 1
    source = [ordered]@{
        type = "PresentMon CSV"
        fileName = [IO.Path]::GetFileName($resolvedInput)
        sha256 = $sha256
        analyzedAt = [datetimeoffset]::Now.ToString("o")
        rowCount = $rows.Count
        validFrameCount = $frames.Count
        invalidRowCount = $invalidRows
    }
    columns = [ordered]@{
        application = $applicationColumn
        processId = $processIdColumn
        frameTime = $frameTimeColumn
        time = $timeColumn
        presentMode = $presentModeColumn
        syncInterval = $syncIntervalColumn
        dropped = $droppedColumn
        displayLatency = $displayLatencyColumn
    }
    scope = [ordered]@{
        processFilter = if ([string]::IsNullOrWhiteSpace($ProcessName)) { $null } else { $ProcessName.Trim() }
        applications = $applications.ToArray()
        processIds = $processIds.ToArray()
        durationSeconds = $elapsedMs / 1000.0
    }
    analysis = [ordered]@{
        status = $status
        averageFps = $averageFps
        averageFrameTimeMs = $averageFrameTime
        medianFrameTimeMs = $median
        p95FrameTimeMs = $p95
        p99FrameTimeMs = $p99
        maximumFrameTimeMs = $maximum
        onePercentLowFps = $onePercentLowFps
        pointOnePercentLowFps = $pointOnePercentLowFps
        spikeThresholdMs = $spikeThresholdMs
        spikeMultiplier = $SpikeMultiplier
        spikeFrameCount = $spikes.Count
        spikeClusterCount = $spikeClusters.Count
        droppedFrameCount = if ($sawDroppedValue) { $droppedFrames } else { $null }
    }
    topSpikes = $topSpikes
    spikeClusters = $spikeClusters.ToArray()
    warnings = $warnings.ToArray()
    boundaries = @(
        "PresentMon frame time is not a hardware diagnosis.",
        "A single spike does not identify a failed component or driver.",
        "Long-term stability requires repeatable workloads and comparable runs."
    )
}

$output = if ($Format -eq "Markdown") {
    $markdown = New-Object System.Collections.Generic.List[string]
    $markdown.Add("# PresentMon frame-time report") | Out-Null
    $markdown.Add("") | Out-Null
    $markdown.Add("## Scope") | Out-Null
    $markdown.Add("") | Out-Null
    $markdown.Add("- File: ``$([IO.Path]::GetFileName($resolvedInput))``") | Out-Null
    $markdown.Add("- SHA-256: ``$sha256``") | Out-Null
    $markdown.Add("- Process filter: $(if ($ProcessName) { $ProcessName } else { 'none' })") | Out-Null
    $markdown.Add("- Applications: $($applications -join ', ')") | Out-Null
    $markdown.Add("- Duration: $([math]::Round($elapsedMs / 1000.0, 3)) s") | Out-Null
    $markdown.Add("- Status: $status") | Out-Null
    $markdown.Add("") | Out-Null
    $markdown.Add("## Frame metrics") | Out-Null
    $markdown.Add("") | Out-Null
    $markdown.Add("| Metric | Value |") | Out-Null
    $markdown.Add("|---|---:|") | Out-Null
    $markdown.Add("| Frames | $($frames.Count) |") | Out-Null
    $markdown.Add("| Average FPS | $([math]::Round($averageFps, 2)) |") | Out-Null
    $markdown.Add("| Median frame time | $([math]::Round($median, 3)) ms |") | Out-Null
    $markdown.Add("| P95 frame time | $([math]::Round($p95, 3)) ms |") | Out-Null
    $markdown.Add("| P99 frame time | $([math]::Round($p99, 3)) ms |") | Out-Null
    $markdown.Add("| Maximum frame time | $([math]::Round($maximum, 3)) ms |") | Out-Null
    $markdown.Add("| 1% low | $([math]::Round($onePercentLowFps, 2)) FPS |") | Out-Null
    $markdown.Add("| 0.1% low | $([math]::Round($pointOnePercentLowFps, 2)) FPS |") | Out-Null
    $markdown.Add("| Spike threshold | $([math]::Round($spikeThresholdMs, 3)) ms |") | Out-Null
    $markdown.Add("| Spike frames | $($spikes.Count) |") | Out-Null
    $markdown.Add("| Spike clusters | $($spikeClusters.Count) |") | Out-Null
    $markdown.Add("") | Out-Null
    $markdown.Add("## Warnings") | Out-Null
    $markdown.Add("") | Out-Null
    if ($warnings.Count -eq 0) {
        $markdown.Add("No parsing or scope warning was detected. This is not a stability claim.") | Out-Null
    }
    else {
        foreach ($warning in $warnings) {
            $markdown.Add("- $warning") | Out-Null
        }
    }
    $markdown.Add("") | Out-Null
    $markdown.Add("## Boundaries") | Out-Null
    $markdown.Add("") | Out-Null
    foreach ($boundary in $result.boundaries) {
        $markdown.Add("- $boundary") | Out-Null
    }
    $markdown -join "`r`n"
}
else {
    $result | ConvertTo-Json -Depth 10
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Write-LocalOutputFile -Path $resolvedOutput -Content $output | Out-Null
}
else {
    Write-Output $output
}
