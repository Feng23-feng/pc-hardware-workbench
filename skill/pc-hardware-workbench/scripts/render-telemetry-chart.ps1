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

    [ValidateSet("Auto", "Csv", "NormalizedJson", "ChartData")]
    [string]$InputFormat = "Auto",

    [switch]$HideFileName,

    [ValidateRange(1, 4096)]
    [int]$MaxInputMegabytes = 512,

    [ValidateRange(1, 32)]
    [int]$MaxSeries = 3,

    [switch]$ClockVoltageTimeline,

    [ValidateRange(20, 5000)]
    [int]$MaxPoints = 480,

    [string]$Title = "Telemetry overview"
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$chartTitle = if (
    $ClockVoltageTimeline -and
    -not $PSBoundParameters.ContainsKey("Title")
) {
    "GPU frequency and voltage timeline"
}
else {
    $Title
}
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

function Get-PropertyValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        return $Default
    }
    return $Object.$Name
}

function Stop-WithNormalizedInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

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

function Format-SvgFixedNumber {
    param(
        [double]$Value,
        [ValidateRange(0, 6)][int]$Decimals
    )
    return $Value.ToString("F$Decimals", $invariant)
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
    if ($Metric -match "(?i)voltage|电压") {
        return "#e39468"
    }
    if ($Metric -match "(?i)memory clock|显存频率") {
        return "#d9a0c0"
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
        [int]$Maximum,
        [string[]]$ExplicitPatterns = @()
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
    foreach ($pattern in $ExplicitPatterns) {
        if ($selected.Count -ge $Maximum) {
            break
        }
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }
        foreach ($candidate in @($Series | Where-Object {
            $_.SourceColumn -match $pattern -or $_.Metric -match $pattern
        })) {
            if ($selected.Count -ge $Maximum) {
                break
            }
            $key = ([string]$candidate.Metric) + [char]0x1F + ([string]$candidate.SourceColumn)
            if ($seen.Add($key)) {
                $selected.Add($candidate) | Out-Null
            }
        }
    }
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

function Find-FirstChartSeries {
    param(
        [object[]]$Series,
        [string[]]$MetricNames
    )
    foreach ($metricName in $MetricNames) {
        $candidate = @($Series | Where-Object {
            $_.Metric -eq $metricName -and
            @($_.Points | Where-Object {
                $null -ne $_.T -and $null -ne $_.V
            }).Count -gt 0
        }) | Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-PaddedValueDomain {
    param([double[]]$Values)
    $minimum = ($Values | Measure-Object -Minimum).Minimum
    $maximum = ($Values | Measure-Object -Maximum).Maximum
    if ($maximum -le $minimum) {
        $padding = [Math]::Max(1, [Math]::Abs($maximum) * 0.03)
    }
    else {
        $padding = ($maximum - $minimum) * 0.08
    }
    $paddedMinimum = $minimum - $padding
    if ($minimum -ge 0 -and $paddedMinimum -lt 0) {
        $paddedMinimum = 0
    }
    return [pscustomobject]@{
        Minimum = [double]$paddedMinimum
        Maximum = [double]($maximum + $padding)
    }
}

function Get-PlotSegments {
    param(
        [object[]]$Points,
        [double]$XMinimum,
        [double]$XMaximum,
        [double]$YMinimum,
        [double]$YMaximum,
        [double]$PlotLeft,
        [double]$PlotTop,
        [double]$PlotWidth,
        [double]$PlotHeight
    )
    $xRange = $XMaximum - $XMinimum
    $yRange = $YMaximum - $YMinimum
    $segments = New-Object System.Collections.Generic.List[object]
    $currentSegment = New-Object System.Collections.Generic.List[object]
    foreach ($point in $Points) {
        if ($null -eq $point.T -or $null -eq $point.V) {
            if ($currentSegment.Count -gt 0) {
                $segments.Add([pscustomobject]@{
                    Coordinates = [object[]]$currentSegment.ToArray()
                }) | Out-Null
                $currentSegment.Clear()
            }
            continue
        }
        $x = $PlotLeft + (([double]$point.T - $XMinimum) / $xRange) * $PlotWidth
        $y = $PlotTop + $PlotHeight -
            (([double]$point.V - $YMinimum) / $yRange) * $PlotHeight
        $currentSegment.Add([pscustomobject]@{ X = $x; Y = $y }) | Out-Null
    }
    if ($currentSegment.Count -gt 0) {
        $segments.Add([pscustomobject]@{
            Coordinates = [object[]]$currentSegment.ToArray()
        }) | Out-Null
    }
    return [object[]]$segments.ToArray()
}

function New-ClockVoltageTimelineSvg {
    param(
        [Parameter(Mandatory = $true)][object]$ChartData,
        [Parameter(Mandatory = $true)][object]$ClockSeries,
        [Parameter(Mandatory = $true)][object]$VoltageSeries,
        [Parameter(Mandatory = $true)][string]$TitleText
    )

    $width = 1200
    $height = 900
    $left = 112
    $right = 72
    $contentInset = 22
    $plotWidth = $width - $left - $right
    $panelTop = 164
    $panelHeight = 650
    $clockPlotTop = 224
    $clockPlotHeight = 205
    $voltagePlotTop = 500
    $voltagePlotHeight = 205
    $plotBottom = $voltagePlotTop + $voltagePlotHeight

    $clockPoints = @($ClockSeries.Points)
    $voltagePoints = @($VoltageSeries.Points)
    $validClockPoints = @($clockPoints | Where-Object {
        $null -ne $_.T -and $null -ne $_.V
    })
    $validVoltagePoints = @($voltagePoints | Where-Object {
        $null -ne $_.T -and $null -ne $_.V
    })
    if ($validClockPoints.Count -eq 0 -or $validVoltagePoints.Count -eq 0) {
        throw "Clock and voltage timeline requires usable points for both series."
    }
    $powerSeries = Find-FirstChartSeries `
        -Series @($ChartData.Series) `
        -MetricNames @("GPU power (W)")
    $activeTimes = New-Object System.Collections.Generic.HashSet[double]
    if ($null -ne $powerSeries) {
        foreach ($powerPoint in @($powerSeries.Points)) {
            if ($null -ne $powerPoint.T -and
                $null -ne $powerPoint.V -and
                [double]$powerPoint.V -gt 80) {
                $activeTimes.Add([double]$powerPoint.T) | Out-Null
            }
        }
    }
    else {
        foreach ($clockPoint in $validClockPoints) {
            if ([double]$clockPoint.V -gt 2000) {
                $activeTimes.Add([double]$clockPoint.T) | Out-Null
            }
        }
    }
    $activeClockPoints = @($validClockPoints | Where-Object {
        $activeTimes.Contains([double]$_.T) -and [double]$_.V -gt 2000
    })
    $activeVoltagePoints = @($validVoltagePoints | Where-Object {
        $activeTimes.Contains([double]$_.T)
    })
    if ($activeClockPoints.Count -eq 0) {
        $activeClockPoints = $validClockPoints
    }
    if ($activeVoltagePoints.Count -eq 0) {
        $activeVoltagePoints = $validVoltagePoints
    }

    $allTimes = @(
        $validClockPoints | ForEach-Object { [double]$_.T }
        $validVoltagePoints | ForEach-Object { [double]$_.T }
    )
    $xMinimum = ($allTimes | Measure-Object -Minimum).Minimum
    $xMaximum = ($allTimes | Measure-Object -Maximum).Maximum
    if ($xMaximum -le $xMinimum) {
        $xMaximum = $xMinimum + 1
    }

    $clockDomain = Get-PaddedValueDomain -Values @(
        $validClockPoints | ForEach-Object { [double]$_.V }
    )
    $voltageDomain = Get-PaddedValueDomain -Values @(
        $validVoltagePoints | ForEach-Object { [double]$_.V }
    )
    if ($clockDomain.Maximum -le $clockDomain.Minimum) {
        $clockDomain.Maximum = $clockDomain.Minimum + 1
    }
    if ($voltageDomain.Maximum -le $voltageDomain.Minimum) {
        $voltageDomain.Maximum = $voltageDomain.Minimum + 0.001
    }

    $clockColor = Get-SeriesColor -Metric ([string]$ClockSeries.Metric)
    $voltageColor = Get-SeriesColor -Metric ([string]$VoltageSeries.Metric)
    $xAxisLabel = [string](Get-PropertyValue `
        -Object $ChartData `
        -Name "XAxisLabel" `
        -Default "seconds")
    $clockSegments = Get-PlotSegments `
        -Points $clockPoints `
        -XMinimum $xMinimum `
        -XMaximum $xMaximum `
        -YMinimum $clockDomain.Minimum `
        -YMaximum $clockDomain.Maximum `
        -PlotLeft $left `
        -PlotTop $clockPlotTop `
        -PlotWidth $plotWidth `
        -PlotHeight $clockPlotHeight
    $voltageSegments = Get-PlotSegments `
        -Points $voltagePoints `
        -XMinimum $xMinimum `
        -XMaximum $xMaximum `
        -YMinimum $voltageDomain.Minimum `
        -YMaximum $voltageDomain.Maximum `
        -PlotLeft $left `
        -PlotTop $voltagePlotTop `
        -PlotWidth $plotWidth `
        -PlotHeight $voltagePlotHeight

    $svg = New-Object System.Text.StringBuilder
    [void]$svg.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$svg.AppendLine(
        "<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"chart-title chart-desc`" data-chart-mode=`"clock-voltage-time`">"
    )
    [void]$svg.AppendLine("  <title id=`"chart-title`">$(ConvertTo-SvgText $TitleText)</title>")
    [void]$svg.AppendLine(
        '  <desc id="chart-desc">Two aligned time-series lanes share one time axis: GPU effective or core frequency above and GPU core voltage below. This is runtime telemetry, not the configured voltage-point table, and it does not prove hardware stability.</desc>'
    )
    [void]$svg.AppendLine('  <defs>')
    [void]$svg.AppendLine(
        '    <linearGradient id="page" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#080b10"/><stop offset="1" stop-color="#0d1319"/></linearGradient>'
    )
    [void]$svg.AppendLine(
        '    <linearGradient id="panel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#111820"/><stop offset="1" stop-color="#0b1016"/></linearGradient>'
    )
    [void]$svg.AppendLine(
        '    <filter id="glow" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.2" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
    )
    [void]$svg.AppendLine('  </defs>')
    [void]$svg.AppendLine("  <rect width=`"$width`" height=`"$height`" fill=`"url(#page)`"/>")
    [void]$svg.AppendLine('  <g font-family="Segoe UI, Microsoft YaHei, sans-serif" fill="#edf3f6">')
    [void]$svg.AppendLine(
        "    <text x=`"$left`" y=`"58`" font-size=`"28`" font-weight=`"600`" letter-spacing=`"-0.5`">$(ConvertTo-SvgText $TitleText)</text>"
    )
    [void]$svg.AppendLine(
        "    <text x=`"$left`" y=`"86`" font-size=`"13`" fill=`"#8b98a4`">$(ConvertTo-SvgText $ChartData.FileName)  /  $(ConvertTo-SvgText $ChartData.Window)</text>"
    )
    [void]$svg.AppendLine(
        "    <text x=`"$left`" y=`"108`" font-size=`"11`" fill=`"#64727f`">$(ConvertTo-SvgText $ChartData.AnalyzedRows) analyzed rows  /  x-axis: time ($(ConvertTo-SvgText $xAxisLabel))</text>"
    )
    [void]$svg.AppendLine(
        "    <rect x=`"$left`" y=`"$panelTop`" width=`"$plotWidth`" height=`"$panelHeight`" rx=`"10`" fill=`"url(#panel)`" stroke=`"#26313b`"/>"
    )

    [void]$svg.AppendLine(
        "    <line x1=`"$($left + 22)`" y1=`"$($panelTop + 27)`" x2=`"$($left + 52)`" y2=`"$($panelTop + 27)`" stroke=`"$clockColor`" stroke-width=`"2.4`" stroke-linecap=`"round`"/>"
    )
    [void]$svg.AppendLine(
        "    <circle cx=`"$($left + 37)`" cy=`"$($panelTop + 27)`" r=`"3.2`" fill=`"$clockColor`"/>"
    )
    [void]$svg.AppendLine(
        "    <text x=`"$($left + 62)`" y=`"$($panelTop + 31)`" font-size=`"12`" font-weight=`"600`">$(ConvertTo-SvgText $ClockSeries.Metric)</text>"
    )
    [void]$svg.AppendLine(
        "    <line x1=`"$($left + 350)`" y1=`"$($panelTop + 27)`" x2=`"$($left + 380)`" y2=`"$($panelTop + 27)`" stroke=`"$voltageColor`" stroke-width=`"2.4`" stroke-linecap=`"round`"/>"
    )
    [void]$svg.AppendLine(
        "    <circle cx=`"$($left + 365)`" cy=`"$($panelTop + 27)`" r=`"3.2`" fill=`"$voltageColor`"/>"
    )
    [void]$svg.AppendLine(
        "    <text x=`"$($left + 390)`" y=`"$($panelTop + 31)`" font-size=`"12`" font-weight=`"600`">$(ConvertTo-SvgText $VoltageSeries.Metric)</text>"
    )
    [void]$svg.AppendLine(
        "    <text x=`"$($left + $contentInset)`" y=`"$(($clockPlotTop - 14).ToString('0.###', $invariant))`" font-size=`"11`" font-weight=`"600`" fill=`"$clockColor`">Frequency (MHz)</text>"
    )
    [void]$svg.AppendLine(
        "    <text x=`"$($left + $contentInset)`" y=`"$(($voltagePlotTop - 14).ToString('0.###', $invariant))`" font-size=`"11`" font-weight=`"600`" fill=`"$voltageColor`">Core voltage (V)</text>"
    )

    for ($gridIndex = 0; $gridIndex -le 4; $gridIndex++) {
        $ratio = $gridIndex / 4
        $gridY = $clockPlotTop + ($clockPlotHeight * $ratio)
        $gridOpacity = if ($gridIndex -eq 4) { "0.7" } else { "0.36" }
        [void]$svg.AppendLine(
            "    <line x1=`"$left`" y1=`"$($gridY.ToString('0.###', $invariant))`" x2=`"$($width - $right)`" y2=`"$($gridY.ToString('0.###', $invariant))`" stroke=`"#26313b`" stroke-width=`"1`" opacity=`"$gridOpacity`"/>"
        )
        $clockValue = $clockDomain.Maximum -
            (($clockDomain.Maximum - $clockDomain.Minimum) * $ratio)
        $clockTick = ConvertTo-SvgText (
            Format-SvgFixedNumber -Value $clockValue -Decimals 0
        )
        [void]$svg.AppendLine(
            "    <text x=`"$($left - 12)`" y=`"$(($gridY + 4).ToString('0.###', $invariant))`" text-anchor=`"end`" font-size=`"10`" fill=`"$clockColor`">$clockTick</text>"
        )
    }
    for ($gridIndex = 0; $gridIndex -le 4; $gridIndex++) {
        $ratio = $gridIndex / 4
        $gridY = $voltagePlotTop + ($voltagePlotHeight * $ratio)
        $gridOpacity = if ($gridIndex -eq 4) { "0.7" } else { "0.36" }
        [void]$svg.AppendLine(
            "    <line x1=`"$left`" y1=`"$($gridY.ToString('0.###', $invariant))`" x2=`"$($width - $right)`" y2=`"$($gridY.ToString('0.###', $invariant))`" stroke=`"#26313b`" stroke-width=`"1`" opacity=`"$gridOpacity`"/>"
        )
        $voltageValue = $voltageDomain.Maximum -
            (($voltageDomain.Maximum - $voltageDomain.Minimum) * $ratio)
        $voltageTick = ConvertTo-SvgText (
            Format-SvgFixedNumber -Value $voltageValue -Decimals 3
        )
        [void]$svg.AppendLine(
            "    <text x=`"$($left - 12)`" y=`"$(($gridY + 4).ToString('0.###', $invariant))`" text-anchor=`"end`" font-size=`"10`" fill=`"$voltageColor`">$voltageTick</text>"
        )
    }

    for ($tickIndex = 0; $tickIndex -le 4; $tickIndex++) {
        $ratio = $tickIndex / 4
        $tickX = $left + ($plotWidth * $ratio)
        $tickValue = $xMinimum + (($xMaximum - $xMinimum) * $ratio)
        $tickText = ConvertTo-SvgText (
            Format-SvgFixedNumber -Value $tickValue -Decimals 1
        )
        [void]$svg.AppendLine(
            "    <line x1=`"$($tickX.ToString('0.###', $invariant))`" y1=`"$clockPlotTop`" x2=`"$($tickX.ToString('0.###', $invariant))`" y2=`"$plotBottom`" stroke=`"#26313b`" stroke-width=`"1`" opacity=`"0.16`"/>"
        )
        [void]$svg.AppendLine(
            "    <text x=`"$($tickX.ToString('0.###', $invariant))`" y=`"$($plotBottom + 20)`" text-anchor=`"middle`" font-size=`"10`" fill=`"#64727f`">$tickText s</text>"
        )
    }

    foreach ($segment in $clockSegments) {
        $coordinates = @($segment.Coordinates)
        if ($coordinates.Count -eq 0) {
            continue
        }
        if ($coordinates.Count -eq 1) {
            [void]$svg.AppendLine(
                "    <circle cx=`"$($coordinates[0].X.ToString('0.###', $invariant))`" cy=`"$($coordinates[0].Y.ToString('0.###', $invariant))`" r=`"2.5`" fill=`"$clockColor`"/>"
            )
            continue
        }
        $pointsText = New-PolylinePoints -Coordinates $coordinates
        [void]$svg.AppendLine(
            "    <polyline data-series=`"gpu-clock`" data-plot-lane=`"clock`" points=`"$pointsText`" fill=`"none`" stroke=`"$clockColor`" stroke-width=`"2.4`" stroke-linecap=`"round`" stroke-linejoin=`"round`" filter=`"url(#glow)`"/>"
        )
    }
    foreach ($segment in $voltageSegments) {
        $coordinates = @($segment.Coordinates)
        if ($coordinates.Count -eq 0) {
            continue
        }
        if ($coordinates.Count -eq 1) {
            [void]$svg.AppendLine(
                "    <circle cx=`"$($coordinates[0].X.ToString('0.###', $invariant))`" cy=`"$($coordinates[0].Y.ToString('0.###', $invariant))`" r=`"2.5`" fill=`"$voltageColor`"/>"
            )
            continue
        }
        $pointsText = New-PolylinePoints -Coordinates $coordinates
        [void]$svg.AppendLine(
            "    <polyline data-series=`"gpu-voltage`" data-plot-lane=`"voltage`" points=`"$pointsText`" fill=`"none`" stroke=`"$voltageColor`" stroke-width=`"2.4`" stroke-linecap=`"round`" stroke-linejoin=`"round`" filter=`"url(#glow)`"/>"
        )
    }

    $extremeAnnotations = @(
        [pscustomobject]@{
            Key = "gpu-clock-max"
            Label = "有效段最高"
            Mode = "max"
            Lane = "clock"
            Unit = "MHz"
            Decimals = 1
            Color = $clockColor
            Points = $activeClockPoints
        },
        [pscustomobject]@{
            Key = "gpu-clock-min"
            Label = "有效段最低"
            Mode = "min"
            Lane = "clock"
            Unit = "MHz"
            Decimals = 1
            Color = $clockColor
            Points = $activeClockPoints
        },
        [pscustomobject]@{
            Key = "gpu-voltage-max"
            Label = "有效段最高"
            Mode = "max"
            Lane = "voltage"
            Unit = "V"
            Decimals = 3
            Color = $voltageColor
            Points = $activeVoltagePoints
        },
        [pscustomobject]@{
            Key = "gpu-voltage-min"
            Label = "有效段最低"
            Mode = "min"
            Lane = "voltage"
            Unit = "V"
            Decimals = 3
            Color = $voltageColor
            Points = $activeVoltagePoints
        }
    )
    $extremeReadouts = New-Object System.Collections.Generic.List[object]
    foreach ($annotation in $extremeAnnotations) {
        $targetPoint = if ($annotation.Mode -eq "max") {
            @($annotation.Points | Sort-Object { [double]$_.V } -Descending) |
                Select-Object -First 1
        }
        else {
            @($annotation.Points | Sort-Object { [double]$_.V }) |
                Select-Object -First 1
        }
        if ($null -eq $targetPoint) {
            continue
        }
        $pointX = $left +
            (([double]$targetPoint.T - $xMinimum) / ($xMaximum - $xMinimum)) *
            $plotWidth
        if ($annotation.Lane -eq "clock") {
            $pointY = $clockPlotTop + $clockPlotHeight -
                (([double]$targetPoint.V - $clockDomain.Minimum) /
                    ($clockDomain.Maximum - $clockDomain.Minimum)) *
                $clockPlotHeight
            $laneTop = $clockPlotTop
            $laneBottom = $clockPlotTop + $clockPlotHeight
        }
        else {
            $pointY = $voltagePlotTop + $voltagePlotHeight -
                (([double]$targetPoint.V - $voltageDomain.Minimum) /
                    ($voltageDomain.Maximum - $voltageDomain.Minimum)) *
                $voltagePlotHeight
            $laneTop = $voltagePlotTop
            $laneBottom = $voltagePlotTop + $voltagePlotHeight
        }
        $valueText = Format-SvgFixedNumber `
            -Value ([double]$targetPoint.V) `
            -Decimals $annotation.Decimals
        $timeText = Format-SvgFixedNumber `
            -Value ([double]$targetPoint.T) `
            -Decimals 1
        $extremeReadouts.Add([pscustomobject]@{
            Key = $annotation.Key
            Lane = $annotation.Lane
            Label = $annotation.Label
            ValueText = $valueText
            Unit = $annotation.Unit
            TimeText = $timeText
            Color = $annotation.Color
        }) | Out-Null
        [void]$svg.AppendLine(
            "    <circle data-extreme=`"$($annotation.Key)`" cx=`"$($pointX.ToString('0.###', $invariant))`" cy=`"$($pointY.ToString('0.###', $invariant))`" r=`"4`" fill=`"$($annotation.Color)`" stroke=`"#0b1016`" stroke-width=`"2`"/>"
        )
    }

    $clockReadouts = @($extremeReadouts | Where-Object { $_.Lane -eq "clock" })
    $voltageReadouts = @($extremeReadouts | Where-Object { $_.Lane -eq "voltage" })
    function Format-ExtremeReadout {
        param([object[]]$Readouts)
        return ($Readouts | ForEach-Object {
            "$($_.Label) $($_.ValueText) $($_.Unit) @ $($_.TimeText) s"
        }) -join "  ·  "
    }
    $clockReadoutText = Format-ExtremeReadout -Readouts $clockReadouts
    $voltageReadoutText = Format-ExtremeReadout -Readouts $voltageReadouts
    [void]$svg.AppendLine(
        "    <circle cx=`"$($left + 22)`" cy=`"738`" r=`"3`" fill=`"$clockColor`"/>"
    )
    [void]$svg.AppendLine(
        "    <text data-extreme-label=`"gpu-clock-readout`" x=`"$($left + 34)`" y=`"742`" font-size=`"10`" fill=`"#8b98a4`">$(ConvertTo-SvgText $clockReadoutText)</text>"
    )
    [void]$svg.AppendLine(
        "    <circle cx=`"$($left + 22)`" cy=`"760`" r=`"3`" fill=`"$voltageColor`"/>"
    )
    [void]$svg.AppendLine(
        "    <text data-extreme-label=`"gpu-voltage-readout`" x=`"$($left + 34)`" y=`"764`" font-size=`"10`" fill=`"#8b98a4`">$(ConvertTo-SvgText $voltageReadoutText)</text>"
    )

    $clockSource = ConvertTo-SvgText $ClockSeries.SourceColumn
    $voltageSource = ConvertTo-SvgText $VoltageSeries.SourceColumn
    [void]$svg.AppendLine(
        "    <text x=`"$($left + $contentInset)`" y=`"790`" font-size=`"10`" fill=`"#73818d`">Clock source: $clockSource  /  Voltage source: $voltageSource</text>"
    )
    $warningCount = @($ChartData.Warnings).Count
    $firstWarning = if ($warningCount -gt 0) {
        (([string]$ChartData.Warnings[0]) -replace "\s+", " ").Trim()
    }
    else {
        ""
    }
    if ($firstWarning.Length -gt 150) {
        $firstWarning = $firstWarning.Substring(0, 147) + "..."
    }
    $warningSummary = if ([string]::IsNullOrWhiteSpace($firstWarning)) {
        ""
    }
    else {
        "  First warning: $firstWarning"
    }
    $footerText = "Runtime telemetry only; it cannot reconstruct the configured voltage-point table.  Warnings: $warningCount$warningSummary"
    [void]$svg.AppendLine(
        "    <text x=`"$left`" y=`"$($height - 38)`" font-size=`"10`" fill=`"#64727f`">$(ConvertTo-SvgText $footerText)</text>"
    )
    [void]$svg.AppendLine('  </g>')
    [void]$svg.AppendLine('</svg>')
    return $svg.ToString()
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

$resolvedInputFormat = if ($InputFormat -eq "Auto") {
    if ([System.IO.Path]::GetExtension($resolvedInput) -ieq ".json") {
        "NormalizedJson"
    }
    else {
        "Csv"
    }
}
else {
    $InputFormat
}

if ($resolvedInputFormat -eq "Csv") {
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
}
elseif ($resolvedInputFormat -eq "ChartData") {
    foreach ($name in @(
        "WarmupSeconds", "DurationSeconds", "WarmupRows", "MaxRows",
        "Delimiter", "MaxInputMegabytes", "MaxPoints"
    )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            [Console]::Error.WriteLine(
                "ChartData is already windowed and downsampled; do not combine it with -$name."
            )
            exit 2
        }
    }
    try {
        $chartData = Get-Content -Raw -LiteralPath $resolvedInput -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        Stop-WithNormalizedInputError "ChartData JSON is invalid: $($_.Exception.Message)"
    }
    if ([string]$chartData.ChartDataVersion -ne "1.0") {
        Stop-WithNormalizedInputError "ChartDataVersion must be '1.0'."
    }
    if (
        $null -eq $chartData.PSObject.Properties["Series"] -or
        $chartData.Series -isnot [System.Array] -or
        @($chartData.Series).Count -eq 0
    ) {
        Stop-WithNormalizedInputError "ChartData.Series must be a non-empty array."
    }
    if (
        $null -eq $chartData.PSObject.Properties["Warnings"] -or
        $chartData.Warnings -isnot [System.Array]
    ) {
        Stop-WithNormalizedInputError "ChartData.Warnings must be an array."
    }
    if ($HideFileName) {
        $chartData.FileName = "[hidden]"
    }
}
else {
    foreach ($name in @(
        "WarmupSeconds", "DurationSeconds", "WarmupRows", "MaxRows",
        "Delimiter", "MaxInputMegabytes", "MaxPoints"
    )) {
        if ($PSBoundParameters.ContainsKey($name)) {
            [Console]::Error.WriteLine(
                "Normalized JSON is already windowed and downsampled; do not combine it with -$name."
            )
            exit 2
        }
    }

    try {
        $normalized = Get-Content -Raw -LiteralPath $resolvedInput -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Stop-WithNormalizedInputError "Normalized telemetry JSON is invalid: $($_.Exception.Message)"
    }
    foreach ($requiredName in @(
        "NormalizedTelemetryVersion", "AdapterVersion", "Source", "Sampling",
        "DataQuality", "Sensors", "ChartData", "Warnings"
    )) {
        if ($null -eq $normalized.PSObject.Properties[$requiredName]) {
            Stop-WithNormalizedInputError "Normalized telemetry document is missing required section '$requiredName'."
        }
    }
    if ([string]$normalized.NormalizedTelemetryVersion -ne "1.0") {
        Stop-WithNormalizedInputError "NormalizedTelemetryVersion must be '1.0'."
    }
    if ([string]$normalized.AdapterVersion -ne "1.0.0") {
        Stop-WithNormalizedInputError "AdapterVersion must be '1.0.0'."
    }

    $source = $normalized.PSObject.Properties["Source"].Value
    if ($null -eq $source -or $source -is [string] -or $source -is [System.Array]) {
        Stop-WithNormalizedInputError "Normalized telemetry Source must be an object."
    }
    foreach ($sourceName in @("Tool", "Version", "InputKind", "InputFileName", "InputSha256", "MixedSources")) {
        if ($null -eq $source.PSObject.Properties[$sourceName]) {
            Stop-WithNormalizedInputError "Normalized telemetry Source is missing '$sourceName'."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$source.Tool) -or
        [string]::IsNullOrWhiteSpace([string]$source.Version)) {
        Stop-WithNormalizedInputError "Normalized telemetry Source.Tool and Source.Version are required."
    }
    if ([string]$source.InputKind -notin @("csv", "sensor-snapshot")) {
        Stop-WithNormalizedInputError "Normalized telemetry Source.InputKind is invalid."
    }
    if ([string]$source.InputSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        Stop-WithNormalizedInputError "Normalized telemetry Source.InputSha256 must be a SHA-256 hash."
    }

    $sampling = $normalized.PSObject.Properties["Sampling"].Value
    if ($null -eq $sampling -or $sampling -is [string] -or $sampling -is [System.Array]) {
        Stop-WithNormalizedInputError "Normalized telemetry Sampling must be an object."
    }
    if ([string]$sampling.Consistency -notin @("stable", "variable", "unknown")) {
        Stop-WithNormalizedInputError "Normalized telemetry Sampling.Consistency is invalid."
    }

    $sensorsProperty = $normalized.PSObject.Properties["Sensors"]
    if ($sensorsProperty.Value -isnot [System.Array] -or @($sensorsProperty.Value).Count -eq 0) {
        Stop-WithNormalizedInputError "Normalized telemetry Sensors must be a non-empty array."
    }
    foreach ($sensor in @($sensorsProperty.Value)) {
        foreach ($sensorName in @("Name", "Category", "Unit", "Header")) {
            if ($null -eq $sensor.PSObject.Properties[$sensorName] -or
                [string]::IsNullOrWhiteSpace([string]$sensor.$sensorName)) {
                Stop-WithNormalizedInputError "Normalized telemetry sensor is missing '$sensorName'."
            }
        }
    }

    $quality = $normalized.PSObject.Properties["DataQuality"].Value
    if ($null -eq $quality -or $quality -is [string] -or $quality -is [System.Array]) {
        Stop-WithNormalizedInputError "Normalized telemetry DataQuality must be an object."
    }
    if ([string]$quality.Status -notin @("complete", "partial", "warnings")) {
        Stop-WithNormalizedInputError "Normalized telemetry DataQuality.Status is invalid."
    }
    foreach ($qualityName in @("SeriesCount", "MissingValueCount", "Window")) {
        if ($null -eq $quality.PSObject.Properties[$qualityName]) {
            Stop-WithNormalizedInputError "Normalized telemetry DataQuality is missing '$qualityName'."
        }
    }

    $warningsProperty = $normalized.PSObject.Properties["Warnings"]
    if ($warningsProperty.Value -isnot [System.Array]) {
        Stop-WithNormalizedInputError "Normalized telemetry Warnings must be an array."
    }

    $chartData = $normalized.PSObject.Properties["ChartData"].Value
    if ($null -eq $chartData -or $chartData -is [string] -or $chartData -is [System.Array]) {
        Stop-WithNormalizedInputError "Normalized telemetry ChartData must be an object."
    }
    if ([string]$chartData.ChartDataVersion -ne "1.0") {
        Stop-WithNormalizedInputError "Normalized telemetry ChartDataVersion must be '1.0'."
    }
    $chartSeriesProperty = $chartData.PSObject.Properties["Series"]
    if ($null -eq $chartSeriesProperty -or
        $chartSeriesProperty.Value -isnot [System.Array] -or
        @($chartSeriesProperty.Value).Count -eq 0) {
        Stop-WithNormalizedInputError "Normalized telemetry ChartData.Series must be a non-empty array."
    }
    if ($null -eq $chartData.PSObject.Properties["Warnings"] -or
        $chartData.Warnings -isnot [System.Array]) {
        Stop-WithNormalizedInputError "Normalized telemetry ChartData.Warnings must be an array."
    }
    $mergedWarnings = New-Object System.Collections.Generic.List[string]
    $warningSeen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($warningValue in @(@($chartData.Warnings) + @($warningsProperty.Value))) {
        $warningText = ([string]$warningValue) -replace "[\p{Cc}\p{Cf}]", " "
        $warningText = $warningText.Trim()
        if (-not [string]::IsNullOrWhiteSpace($warningText) -and $warningSeen.Add($warningText)) {
            $mergedWarnings.Add($warningText) | Out-Null
        }
    }
    $chartData.Warnings = @($mergedWarnings.ToArray())
    if ($HideFileName) {
        $chartData.FileName = "[hidden]"
    }
}

$availableSeries = @($chartData.Series)
if ($availableSeries.Count -eq 0) {
    throw "No recognized numeric telemetry series can be charted. Use -IncludeColumn when the column role is clear."
}

if ($ClockVoltageTimeline) {
    if ([bool](Get-PropertyValue -Object $chartData -Name "TimeBased" -Default $false) -ne $true) {
        [Console]::Error.WriteLine(
            "-ClockVoltageTimeline requires timestamped telemetry so the x-axis is time."
        )
        exit 2
    }
    $clockSeries = Find-FirstChartSeries `
        -Series $availableSeries `
        -MetricNames @(
            "GPU effective clock (MHz)",
            "GPU core clock (MHz)"
        )
    $voltageSeries = Find-FirstChartSeries `
        -Series $availableSeries `
        -MetricNames @("GPU core voltage (V)")
    if ($null -eq $clockSeries -or $null -eq $voltageSeries) {
        [Console]::Error.WriteLine(
            "-ClockVoltageTimeline requires both a GPU effective/core clock series and a GPU core voltage series."
        )
        exit 2
    }

    $timelineSvg = New-ClockVoltageTimelineSvg `
        -ChartData $chartData `
        -ClockSeries $clockSeries `
        -VoltageSeries $voltageSeries `
        -TitleText $chartTitle
    $writtenPath = Write-LocalOutputFile `
        -Path $resolvedOutput `
        -Content $timelineSvg
    Write-Output $writtenPath
    exit 0
}

$selectedSeries = @(Select-ChartSeries -Series $availableSeries -Maximum $MaxSeries -ExplicitPatterns $IncludeColumn)
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
[void]$svg.AppendLine("  <title id=`"chart-title`">$(ConvertTo-SvgText $chartTitle)</title>")
[void]$svg.AppendLine("  <desc id=`"chart-desc`">Telemetry time-series chart. Evidence view only; it does not prove hardware stability.</desc>")
[void]$svg.AppendLine('  <defs>')
[void]$svg.AppendLine('    <linearGradient id="page" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#080b10"/><stop offset="1" stop-color="#0d1319"/></linearGradient>')
[void]$svg.AppendLine('    <linearGradient id="panel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#111820"/><stop offset="1" stop-color="#0b1016"/></linearGradient>')
    [void]$svg.AppendLine("    <filter id=`"glow`" filterUnits=`"userSpaceOnUse`" x=`"0`" y=`"0`" width=`"$width`" height=`"$height`"><feGaussianBlur stdDeviation=`"2.5`" result=`"blur`"/><feMerge><feMergeNode in=`"blur`"/><feMergeNode in=`"SourceGraphic`"/></feMerge></filter>")
[void]$svg.AppendLine('  </defs>')
[void]$svg.AppendLine("  <rect width=`"$width`" height=`"$height`" fill=`"url(#page)`"/>")
[void]$svg.AppendLine('  <g font-family="Segoe UI, Microsoft YaHei, sans-serif" fill="#edf3f6">')
[void]$svg.AppendLine("    <text x=`"$left`" y=`"60`" font-size=`"28`" font-weight=`"600`" letter-spacing=`"-0.5`">$(ConvertTo-SvgText $chartTitle)</text>")
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
    $isMemoryClock = [string]$seriesItem.Metric -eq "GPU memory clock (MHz)"
    $seriesStrokeWidth = if ($isMemoryClock) { "3.2" } else { "2" }
    $areaOpacity = if ($isMemoryClock) { "0.035" } else { "0.08" }
    $unit = ConvertTo-SvgText $seriesItem.Unit
    $metricText = ConvertTo-SvgText $seriesItem.Metric
    $sourceText = ConvertTo-SvgText $seriesItem.SourceColumn
    $minimumText = Format-SvgNumber ([double]$seriesItem.Min)
    $meanText = Format-SvgNumber ([double]$seriesItem.Mean)
    $maximumText = Format-SvgNumber ([double]$seriesItem.Max)

    [void]$svg.AppendLine("    <rect x=`"$left`" y=`"$panelTop`" width=`"$plotWidth`" height=`"$($panelHeight - 18)`" rx=`"10`" fill=`"url(#panel)`" stroke=`"#26313b`"/>")
    [void]$svg.AppendLine("    <text x=`"$($left + 22)`" y=`"$($panelTop + 28)`" font-size=`"15`" font-weight=`"600`">$metricText</text>")
    [void]$svg.AppendLine("    <text x=`"$($left + 22)`" y=`"$($panelTop + 44)`" font-size=`"10`" fill=`"#73818d`">$sourceText</text>")
    [void]$svg.AppendLine("    <text data-panel-stat=`"summary`" x=`"$($width - $right - 18)`" y=`"$($panelTop + 27)`" text-anchor=`"end`" font-size=`"10`" fill=`"#8c9aa6`">min $minimumText  ·  mean $meanText  ·  max $maximumText  $unit</text>")

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
        [void]$svg.AppendLine("    <polygon points=`"$areaPoints`" fill=`"$color`" opacity=`"$areaOpacity`"/>")
        $seriesKind = if ($isMemoryClock) { " data-series-kind=`"memory-clock`"" } else { "" }
        if ($isMemoryClock) {
            [void]$svg.AppendLine("    <polyline data-series-halo=`"memory-clock`" points=`"$polylinePoints`" fill=`"none`" stroke=`"$color`" stroke-width=`"7`" stroke-linecap=`"round`" stroke-linejoin=`"round`" opacity=`"0.12`" filter=`"url(#glow)`"/>")
        }
        [void]$svg.AppendLine("    <polyline$seriesKind points=`"$polylinePoints`" fill=`"none`" stroke=`"$color`" stroke-width=`"$seriesStrokeWidth`" stroke-linecap=`"round`" stroke-linejoin=`"round`" filter=`"url(#glow)`"/>")
        if ($isMemoryClock) {
            $markerStep = [Math]::Max(1, [Math]::Floor($segment.Count / 7))
            for ($markerIndex = 0; $markerIndex -lt $segment.Count; $markerIndex += $markerStep) {
                $marker = $segment[$markerIndex]
                [void]$svg.AppendLine("    <circle data-series-marker=`"memory-clock`" cx=`"$($marker.X.ToString('0.###', $invariant))`" cy=`"$($marker.Y.ToString('0.###', $invariant))`" r=`"3`" fill=`"$color`" stroke=`"#0b1016`" stroke-width=`"1.2`"/>")
            }
            $lastMarker = $segment[$segment.Count - 1]
            [void]$svg.AppendLine("    <circle data-series-marker=`"memory-clock`" cx=`"$($lastMarker.X.ToString('0.###', $invariant))`" cy=`"$($lastMarker.Y.ToString('0.###', $invariant))`" r=`"3`" fill=`"$color`" stroke=`"#0b1016`" stroke-width=`"1.2`"/>")
        }
    }

    $lastValid = $validPoints[$validPoints.Count - 1]
    $lastX = $left + (([double]$lastValid.T - $xMinimum) / ($xMaximum - $xMinimum)) * $plotWidth
    $lastY = $plotBottom - (([double]$lastValid.V - $plotYMinimum) / $plotYRange) * $plotHeight
    [void]$svg.AppendLine("    <circle cx=`"$($lastX.ToString('0.###', $invariant))`" cy=`"$($lastY.ToString('0.###', $invariant))`" r=`"3.2`" fill=`"$color`"/>")

    $xStartText = ConvertTo-SvgText (Format-SvgNumber $xMinimum)
    $xEndText = ConvertTo-SvgText (Format-SvgNumber $xMaximum)
    [void]$svg.AppendLine("    <text x=`"$left`" y=`"$($plotBottom + 18)`" font-size=`"9`" fill=`"#64727f`">$xStartText</text>")
    [void]$svg.AppendLine("    <text x=`"$($width - $right)`" y=`"$($plotBottom + 18)`" text-anchor=`"end`" font-size=`"9`" fill=`"#64727f`">$xEndText</text>")
    [void]$svg.AppendLine("    <text data-panel-stat=`"samples`" x=`"$($width - $right - 18)`" y=`"$($panelTop + 43)`" text-anchor=`"end`" font-size=`"9`" fill=`"#64727f`">$($seriesItem.Samples) samples$(if ($seriesItem.Downsampled) { ' · downsampled' } else { '' })</text>")
    $panelIndex++
}

$footerY = $height - 36
$warningCount = @($chartData.Warnings).Count
$firstWarning = if ($warningCount -gt 0) {
    $warningText = ([string]$chartData.Warnings[0]) -replace "\s+", " "
    $warningText.Trim()
}
else {
    ""
}
if ($firstWarning.Length -gt 150) {
    $firstWarning = $firstWarning.Substring(0, 147) + "..."
}
$warningSummary = if ([string]::IsNullOrWhiteSpace($firstWarning)) {
    ""
}
else {
    "  First warning: $firstWarning"
}
$footerText = "Evidence view only - it does not prove stability.  Warnings: $warningCount$warningSummary"
[void]$svg.AppendLine("    <text x=`"$left`" y=`"$footerY`" font-size=`"10`" fill=`"#64727f`">$(ConvertTo-SvgText $footerText)</text>")
[void]$svg.AppendLine('  </g>')
[void]$svg.AppendLine('</svg>')

$writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content $svg.ToString()
Write-Output $writtenPath
