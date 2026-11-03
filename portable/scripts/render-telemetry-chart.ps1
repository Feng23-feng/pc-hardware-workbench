[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputPath,

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$WarmupSeconds = 0,

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$DurationSeconds = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$WarmupRows = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxRows = 0,

    [ValidateSet(",", ";", "`t")]
    [string]$Delimiter = ",",

    [string[]]$IncludeColumn = @(),

    [switch]$HideFileName,

    [ValidateRange(1, 4096)]
    [int]$MaxInputMegabytes = 512,

    [ValidateRange(1, 8)]
    [int]$MaxSeries = 3,

    [ValidateRange(20, 5000)]
    [int]$MaxPoints = 480,

    [string]$Title = "Telemetry overview"
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

function ConvertTo-SvgText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    $text = [string]$Value
    $text = $text -replace "[\p{Cc}\p{Cf}]", " "
    $text = $text -replace "[\u2028\u2029]", " "
    return [System.Security.SecurityElement]::Escape($text)
}

function Format-SvgNumber {
    param([double]$Value)
    return $Value.ToString("0.###", $invariant)
}

function Get-SeriesColor {
    param([string]$Metric)
    if ($Metric -match "(?i)FPS|frame") {
        return "#78d5a3"
    }
    if ($Metric -match "(?i)temperature|hotspot|junction|温度|热点|结温") {
        return "#e8b269"
    }
    if ($Metric -match "(?i)power|watt|功耗|功率") {
        return "#66c8d8"
    }
    if ($Metric -match "(?i)clock|frequency|频率") {
        return "#8da8ff"
    }
    if ($Metric -match "(?i)fan|风扇") {
        return "#b7c0c8"
    }
    return "#9fb5c2"
}

function Select-ChartSeries {
    param(
        [object[]]$Series,
        [int]$Maximum
    )

    $preferred = @(
        "FPS",
        "GPU temperature (C)",
        "GPU power (W)",
        "CPU package temperature (C)",
        "CPU Tctl/Tdie temperature (C)",
        "CPU die average temperature (C)",
        "CPU package power (W)",
        "GPU hotspot (C)",
        "GPU memory junction (C)",
        "Frame time (ms)",
        "GPU effective clock (MHz)",
        "GPU core clock (MHz)",
        "GPU memory clock (MHz)",
        "GPU core voltage (V)",
        "GPU fan (RPM)",
        "GPU fan (%)"
    )

    $selected = New-Object System.Collections.Generic.List[object]
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($metricName in $preferred) {
        if ($selected.Count -ge $Maximum) {
            break
        }
        $candidate = @($Series | Where-Object { $_.Metric -eq $metricName }) | Select-Object -First 1
        if ($null -eq $candidate) {
            continue
        }
        $key = ([string]$candidate.Metric) + [char]0x1F + ([string]$candidate.SourceColumn)
        if ($seen.Add($key)) {
            $selected.Add($candidate) | Out-Null
        }
    }
    foreach ($candidate in $Series) {
        if ($selected.Count -ge $Maximum) {
            break
        }
        $key = ([string]$candidate.Metric) + [char]0x1F + ([string]$candidate.SourceColumn)
        if ($seen.Add($key)) {
            $selected.Add($candidate) | Out-Null
        }
    }
    return [object[]]$selected.ToArray()
}

function New-PolylinePoints {
    param([object[]]$Coordinates)
    return ($Coordinates | ForEach-Object {
        "{0},{1}" -f (Format-SvgNumber $_.X), (Format-SvgNumber $_.Y)
    }) -join " "
}

try {
    $resolvedInput = Assert-LocalReadFilePath -Path $Path
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ([System.IO.Path]::GetExtension($resolvedOutput) -notmatch '^\.svg$') {
    [Console]::Error.WriteLine("Only SVG output is supported in this first chart renderer.")
    exit 2
}

$analyzerPath = Join-Path $PSScriptRoot "analyze-telemetry.ps1"
if (-not (Test-Path -LiteralPath $analyzerPath -PathType Leaf)) {
    throw "Telemetry analyzer is missing: $analyzerPath"
}

$analyzerParameters = @{
    Path = $resolvedInput
    Format = "ChartData"
    Delimiter = $Delimiter
    MaxInputMegabytes = $MaxInputMegabytes
    MaxChartPoints = $MaxPoints
}
if ($WarmupSeconds -gt 0) {
    $analyzerParameters.WarmupSeconds = $WarmupSeconds
}
if ($DurationSeconds -gt 0) {
    $analyzerParameters.DurationSeconds = $DurationSeconds
}
if ($WarmupRows -gt 0) {
    $analyzerParameters.WarmupRows = $WarmupRows
}
if ($MaxRows -gt 0) {
    $analyzerParameters.MaxRows = $MaxRows
}
if ($IncludeColumn.Count -gt 0) {
    $analyzerParameters.IncludeColumn = $IncludeColumn
}
if ($HideFileName) {
    $analyzerParameters.HideFileName = $true
}

$chartJson = & $analyzerPath @analyzerParameters | Out-String
if ([string]::IsNullOrWhiteSpace($chartJson)) {
    throw "Telemetry analyzer returned no chart data."
}
try {
    $chartData = $chartJson | ConvertFrom-Json
}
catch {
    throw "Telemetry analyzer returned invalid chart data: $($_.Exception.Message)"
}

$availableSeries = @($chartData.Series)
if ($availableSeries.Count -eq 0) {
    throw "No recognized numeric telemetry series can be charted. Use -IncludeColumn when the column role is clear."
}
$selectedSeries = @(Select-ChartSeries -Series $availableSeries -Maximum $MaxSeries)
if ($selectedSeries.Count -eq 0) {
    throw "No telemetry series with usable points can be charted."
}

$width = 1200
$left = 104
$right = 72
$top = 154
$panelHeight = 228
$plotHeight = 146
$plotWidth = $width - $left - $right
$height = $top + ($selectedSeries.Count * $panelHeight) + 92
$svg = New-Object System.Text.StringBuilder

[void]$svg.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"chart-title chart-desc`">")
[void]$svg.AppendLine("  <title id=`"chart-title`">$(ConvertTo-SvgText $Title)</title>")
[void]$svg.AppendLine("  <desc id=`"chart-desc`">Telemetry time-series chart. Evidence view only; it does not prove hardware stability.</desc>")
[void]$svg.AppendLine('  <defs>')
[void]$svg.AppendLine('    <linearGradient id="page" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#080b10"/><stop offset="1" stop-color="#0d1319"/></linearGradient>')
[void]$svg.AppendLine('    <linearGradient id="panel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#111820"/><stop offset="1" stop-color="#0b1016"/></linearGradient>')
[void]$svg.AppendLine('    <filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.5" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>')
[void]$svg.AppendLine('  </defs>')
[void]$svg.AppendLine("  <rect width=`"$width`" height=`"$height`" fill=`"url(#page)`"/>")
[void]$svg.AppendLine('  <g font-family="Segoe UI, Microsoft YaHei, sans-serif" fill="#edf3f6">')
[void]$svg.AppendLine("    <text x=`"$left`" y=`"60`" font-size=`"28`" font-weight=`"600`" letter-spacing=`"-0.5`">$(ConvertTo-SvgText $Title)</text>")
[void]$svg.AppendLine("    <text x=`"$left`" y=`"88`" font-size=`"13`" fill=`"#8b98a4`">$(ConvertTo-SvgText $chartData.FileName)  /  $(ConvertTo-SvgText $chartData.Window)</text>")
[void]$svg.AppendLine("    <text x=`"$left`" y=`"110`" font-size=`"11`" fill=`"#64727f`">$(ConvertTo-SvgText $chartData.AnalyzedRows) analyzed rows  /  x-axis: $(ConvertTo-SvgText $chartData.XAxisLabel)</text>")

$panelIndex = 0
foreach ($seriesItem in $selectedSeries) {
    $panelTop = $top + ($panelIndex * $panelHeight)
    $plotTop = $panelTop + 52
    $plotBottom = $plotTop + $plotHeight
    $points = @($seriesItem.Points)
    $validPoints = @($points | Where-Object { $null -ne $_.V -and $null -ne $_.T })
    if ($validPoints.Count -eq 0) {
        $panelIndex++
        continue
    }

    $xValues = @($validPoints | ForEach-Object { [double]$_.T })
    $yValues = @($validPoints | ForEach-Object { [double]$_.V })
    $xMinimum = ($xValues | Measure-Object -Minimum).Minimum
    $xMaximum = ($xValues | Measure-Object -Maximum).Maximum
    $yMinimum = ($yValues | Measure-Object -Minimum).Minimum
    $yMaximum = ($yValues | Measure-Object -Maximum).Maximum
    if ($xMaximum -le $xMinimum) {
        $xMaximum = $xMinimum + 1
    }
    $rawYRange = $yMaximum - $yMinimum
    $yPad = if ($rawYRange -gt 0) { $rawYRange * .08 } else { [Math]::Max(1, [Math]::Abs($yMaximum) * .05) }
    $plotYMinimum = $yMinimum - $yPad
    if ($yMinimum -ge 0 -and $plotYMinimum -lt 0) {
        $plotYMinimum = 0
    }
    $plotYMaximum = $yMaximum + $yPad
    $plotYRange = $plotYMaximum - $plotYMinimum
    if ($plotYRange -le 0) {
        $plotYRange = 1
    }
    $color = Get-SeriesColor -Metric ([string]$seriesItem.Metric)
    $unit = ConvertTo-SvgText $seriesItem.Unit
    $metricText = ConvertTo-SvgText $seriesItem.Metric
    $sourceText = ConvertTo-SvgText $seriesItem.SourceColumn
    $minimumText = Format-SvgNumber ([double]$seriesItem.Min)
    $meanText = Format-SvgNumber ([double]$seriesItem.Mean)
    $maximumText = Format-SvgNumber ([double]$seriesItem.Max)

    [void]$svg.AppendLine("    <rect x=`"$left`" y=`"$panelTop`" width=`"$plotWidth`" height=`"$($panelHeight - 18)`" rx=`"10`" fill=`"url(#panel)`" stroke=`"#26313b`"/>")
    [void]$svg.AppendLine("    <text x=`"$($left + 22)`" y=`"$($panelTop + 28)`" font-size=`"15`" font-weight=`"600`">$metricText</text>")
    [void]$svg.AppendLine("    <text x=`"$($left + 22)`" y=`"$($panelTop + 44)`" font-size=`"10`" fill=`"#73818d`">$sourceText</text>")
    [void]$svg.AppendLine("    <text x=`"$($width - $right)`" y=`"$($panelTop + 27)`" text-anchor=`"end`" font-size=`"10`" fill=`"#8c9aa6`">min $minimumText  ·  mean $meanText  ·  max $maximumText  $unit</text>")

    for ($gridIndex = 0; $gridIndex -le 4; $gridIndex++) {
        $gridY = $plotTop + ($plotHeight * $gridIndex / 4)
        $gridOpacity = if ($gridIndex -eq 0) { "0.7" } else { "0.36" }
        [void]$svg.AppendLine("    <line x1=`"$left`" y1=`"$($gridY.ToString('0.###', $invariant))`" x2=`"$($width - $right)`" y2=`"$($gridY.ToString('0.###', $invariant))`" stroke=`"#26313b`" stroke-width=`"1`" opacity=`"$gridOpacity`"/>")
    }
    $minimumYText = ConvertTo-SvgText (Format-SvgNumber $plotYMinimum)
    $maximumYText = ConvertTo-SvgText (Format-SvgNumber $plotYMaximum)
    [void]$svg.AppendLine("    <text x=`"$($left - 10)`" y=`"$($plotTop + 4)`" text-anchor=`"end`" font-size=`"9`" fill=`"#64727f`">$maximumYText</text>")
    [void]$svg.AppendLine("    <text x=`"$($left - 10)`" y=`"$plotBottom`" text-anchor=`"end`" font-size=`"9`" fill=`"#64727f`">$minimumYText</text>")

    $segments = New-Object System.Collections.Generic.List[object]
    $currentSegment = New-Object System.Collections.Generic.List[object]
    foreach ($point in $points) {
        if ($null -eq $point.V -or $null -eq $point.T) {
            if ($currentSegment.Count -gt 0) {
                $segments.Add([object[]]$currentSegment.ToArray()) | Out-Null
                $currentSegment.Clear()
            }
            continue
        }

        $x = $left + (([double]$point.T - $xMinimum) / ($xMaximum - $xMinimum)) * $plotWidth
        $y = $plotBottom - (([double]$point.V - $plotYMinimum) / $plotYRange) * $plotHeight
        $currentSegment.Add([pscustomobject]@{ X = $x; Y = $y }) | Out-Null
    }
    if ($currentSegment.Count -gt 0) {
        $segments.Add([object[]]$currentSegment.ToArray()) | Out-Null
    }

    foreach ($segment in $segments) {
        if ($segment.Count -lt 2) {
            [void]$svg.AppendLine("    <circle cx=`"$($segment[0].X.ToString('0.###', $invariant))`" cy=`"$($segment[0].Y.ToString('0.###', $invariant))`" r=`"2.5`" fill=`"$color`"/>")
            continue
        }
        $polylinePoints = New-PolylinePoints -Coordinates $segment
        $areaPoints = "$($segment[0].X.ToString('0.###', $invariant)),$($plotBottom.ToString('0.###', $invariant)) $polylinePoints $($segment[$segment.Count - 1].X.ToString('0.###', $invariant)),$($plotBottom.ToString('0.###', $invariant))"
        [void]$svg.AppendLine("    <polygon points=`"$areaPoints`" fill=`"$color`" opacity=`"0.08`"/>")
        [void]$svg.AppendLine("    <polyline points=`"$polylinePoints`" fill=`"none`" stroke=`"$color`" stroke-width=`"2`" stroke-linecap=`"round`" stroke-linejoin=`"round`" filter=`"url(#glow)`"/>")
    }

    $lastValid = $validPoints[$validPoints.Count - 1]
    $lastX = $left + (([double]$lastValid.T - $xMinimum) / ($xMaximum - $xMinimum)) * $plotWidth
    $lastY = $plotBottom - (([double]$lastValid.V - $plotYMinimum) / $plotYRange) * $plotHeight
    [void]$svg.AppendLine("    <circle cx=`"$($lastX.ToString('0.###', $invariant))`" cy=`"$($lastY.ToString('0.###', $invariant))`" r=`"3.2`" fill=`"$color`"/>")

    $xStartText = ConvertTo-SvgText (Format-SvgNumber $xMinimum)
    $xEndText = ConvertTo-SvgText (Format-SvgNumber $xMaximum)
    [void]$svg.AppendLine("    <text x=`"$left`" y=`"$($plotBottom + 18)`" font-size=`"9`" fill=`"#64727f`">$xStartText</text>")
    [void]$svg.AppendLine("    <text x=`"$($width - $right)`" y=`"$($plotBottom + 18)`" text-anchor=`"end`" font-size=`"9`" fill=`"#64727f`">$xEndText</text>")
    [void]$svg.AppendLine("    <text x=`"$($width - $right)`" y=`"$($panelTop + 43)`" text-anchor=`"end`" font-size=`"9`" fill=`"#64727f`">$($seriesItem.Samples) samples$(if ($seriesItem.Downsampled) { ' · downsampled' } else { '' })</text>")
    $panelIndex++
}

$footerY = $height - 36
$warningCount = @($chartData.Warnings).Count
$footerText = "Evidence view only - it does not prove stability.  Warnings: $warningCount"
[void]$svg.AppendLine("    <text x=`"$left`" y=`"$footerY`" font-size=`"10`" fill=`"#64727f`">$(ConvertTo-SvgText $footerText)</text>")
[void]$svg.AppendLine('  </g>')
[void]$svg.AppendLine('</svg>')

$writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content $svg.ToString()
Write-Output $writtenPath
