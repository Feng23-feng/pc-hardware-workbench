[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputPath,

    [Parameter(Mandatory = $true)]
    [string]$ProfileId,

    [Parameter(Mandatory = $true)]
    [string]$GpuIdentity,

    [Parameter(Mandatory = $true)]
    [string]$RawToolIdentity,

    [Parameter(Mandatory = $true)]
    [string]$DisplayToolIdentity,

    [string]$ProfilePath,

    [switch]$AllowProvisional,

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$WarmupSeconds = 0,

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$DurationSeconds = 0,

    [string]$Title = "GPU memory clock and equivalent display evidence"
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
$analyzerPath = Join-Path $PSScriptRoot "analyze-telemetry.ps1"
if ([string]::IsNullOrWhiteSpace($ProfilePath)) {
    $skillProfilePath = Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        "references/tuning/memory-clock-profiles.json"
    $portableProfilePath = Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        "docs/memory-clock-profiles.json"
    $ProfilePath = if (Test-Path -LiteralPath $skillProfilePath -PathType Leaf) {
        $skillProfilePath
    }
    else {
        $portableProfilePath
    }
}
foreach ($requiredPath in @($pathSafetyHelper, $analyzerPath, $ProfilePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required memory evidence dependency is missing: $requiredPath"
    }
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
    param(
        [double]$Value,
        [ValidateRange(0, 6)][int]$Decimals = 1
    )
    return $Value.ToString("F$Decimals", $invariant)
}

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

function Get-RequiredProfileValue {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "Memory profile is missing required field '$Path.$Name'."
    }
    $value = $Object.$Name
    if ($value -is [string] -and [string]::IsNullOrWhiteSpace($value)) {
        throw "Memory profile field '$Path.$Name' cannot be empty."
    }
    return $value
}

function ConvertTo-ProfileIdentityKey {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    $text = [string]$Value
    $text = $text.Normalize([Text.NormalizationForm]::FormC)
    $text = ($text.Trim() -replace "\s+", " ")
    return $text.ToUpperInvariant()
}

function Test-ProfileIdentityMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [AllowEmptyCollection()][string[]]$AcceptedIdentities,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if ($AcceptedIdentities.Count -eq 0) {
        throw "Memory profile identity list '$Path' is empty."
    }
    $identityKey = ConvertTo-ProfileIdentityKey $Identity
    if ([string]::IsNullOrWhiteSpace($identityKey)) {
        return $false
    }
    foreach ($acceptedIdentity in $AcceptedIdentities) {
        if (
            [string]::IsNullOrWhiteSpace($acceptedIdentity) -or
            $identityKey -ne (ConvertTo-ProfileIdentityKey $acceptedIdentity)
        ) {
            continue
        }
        return $true
    }
    return $false
}

function Get-ProfileIdentityList {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowEmpty
    )
    $values = @(Get-RequiredProfileValue `
        -Object $Object `
        -Name $Name `
        -Path $Path)
    if ($values.Count -eq 0) {
        if ($AllowEmpty) {
            return [string[]]@()
        }
        throw "Memory profile identity list '$Path.$Name' is empty."
    }
    foreach ($value in $values) {
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            throw "Memory profile identity list '$Path.$Name' contains an empty value."
        }
    }
    return [string[]]$values
}

function Get-PaddedDomain {
    param([double[]]$Values)
    $minimum = ($Values | Measure-Object -Minimum).Minimum
    $maximum = ($Values | Measure-Object -Maximum).Maximum
    if ($maximum -eq $minimum) {
        $padding = [Math]::Max(1.0, [Math]::Abs($maximum) * 0.01)
    }
    else {
        $padding = ($maximum - $minimum) * 0.08
    }
    return [pscustomobject]@{
        Minimum = [double]($minimum - $padding)
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
        [double]$PlotHeight,
        [scriptblock]$ValueSelector
    )
    $xRange = $XMaximum - $XMinimum
    $yRange = $YMaximum - $YMinimum
    $segments = New-Object System.Collections.Generic.List[object]
    $current = New-Object System.Collections.Generic.List[object]
    foreach ($point in $Points) {
        $value = & $ValueSelector $point
        if ($null -eq $point.T -or $null -eq $value) {
            if ($current.Count -gt 0) {
                $segments.Add([pscustomobject]@{
                    Coordinates = [object[]]$current.ToArray()
                }) | Out-Null
                $current.Clear()
            }
            continue
        }
        $x = $PlotLeft + (([double]$point.T - $XMinimum) / $xRange) * $PlotWidth
        $y = $PlotTop + $PlotHeight -
            (([double]$value - $YMinimum) / $yRange) * $PlotHeight
        $current.Add([pscustomobject]@{ X = $x; Y = $y }) | Out-Null
    }
    if ($current.Count -gt 0) {
        $segments.Add([pscustomobject]@{
            Coordinates = [object[]]$current.ToArray()
        }) | Out-Null
    }
    return [object[]]$segments.ToArray()
}

try {
    $resolvedInput = Assert-LocalReadFilePath -Path $Path
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
    $profileDocument = Get-Content -Raw -LiteralPath $ProfilePath -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ([IO.Path]::GetExtension($resolvedOutput) -ne ".svg") {
    [Console]::Error.WriteLine("Only SVG output is supported.")
    exit 2
}

try {
    $profileSchemaVersion = [string](Get-RequiredProfileValue `
        -Object $profileDocument `
        -Name "schema_version" `
        -Path "document")
    if ($profileSchemaVersion -ne "1.0") {
        throw "Memory profile SchemaVersion must be '1.0'."
    }
    $profiles = @(Get-RequiredProfileValue `
        -Object $profileDocument `
        -Name "profiles" `
        -Path "document")
    if ($profiles.Count -eq 0) {
        throw "Memory profile document contains no profiles."
    }
    $profile = @($profiles | Where-Object { [string]$_.id -eq $ProfileId }) |
        Select-Object -First 1
    if ($null -eq $profile) {
        throw "Memory profile not found: $ProfileId"
    }
    $profileStatus = [string](Get-RequiredProfileValue `
        -Object $profile `
        -Name "status" `
        -Path "profile")
    if ($profileStatus -eq "deprecated") {
        throw "Memory profile is deprecated: $ProfileId"
    }
    if ($profileStatus -notin @("verified-local", "provisional")) {
        throw "Memory profile status '$profileStatus' is not supported."
    }
    if ($profileStatus -eq "provisional" -and -not $AllowProvisional) {
        throw "Memory profile is provisional; pass -AllowProvisional to use it with an explicit warning."
    }

    $gpu = Get-RequiredProfileValue `
        -Object $profile `
        -Name "gpu" `
        -Path "profile"
    [void](Get-RequiredProfileValue -Object $gpu -Name "vendor" -Path "profile.gpu")
    $profileModel = [string](Get-RequiredProfileValue `
        -Object $gpu `
        -Name "model" `
        -Path "profile.gpu")
    [void](Get-RequiredProfileValue -Object $gpu -Name "form_factor" -Path "profile.gpu")
    [void](Get-RequiredProfileValue -Object $gpu -Name "memory_type" -Path "profile.gpu")
    $gpuAliases = Get-ProfileIdentityList `
        -Object $gpu `
        -Name "aliases" `
        -Path "profile.gpu" `
        -AllowEmpty
    $gpuIdentities = @($profileModel) + @($gpuAliases)
    if (-not (Test-ProfileIdentityMatch `
        -Identity $GpuIdentity `
        -AcceptedIdentities $gpuIdentities `
        -Path "profile.gpu")) {
        throw "GPU identity '$GpuIdentity' does not match profile '$ProfileId'."
    }

    $rawField = Get-RequiredProfileValue `
        -Object $profile `
        -Name "raw_field" `
        -Path "profile"
    [void](Get-RequiredProfileValue -Object $rawField -Name "metric" -Path "profile.raw_field")
    $sourceColumnPattern = [string](Get-RequiredProfileValue `
        -Object $rawField `
        -Name "source_column_pattern" `
        -Path "profile.raw_field")
    [void]([regex]::new($sourceColumnPattern))
    [void](Get-RequiredProfileValue `
        -Object $rawField `
        -Name "clock_basis" `
        -Path "profile.raw_field")

    $rawTool = Get-RequiredProfileValue `
        -Object $profile `
        -Name "raw_tool" `
        -Path "profile"
    [void](Get-RequiredProfileValue -Object $rawTool -Name "name" -Path "profile.raw_tool")
    [void](Get-RequiredProfileValue -Object $rawTool -Name "version" -Path "profile.raw_tool")
    $rawToolIdentities = Get-ProfileIdentityList `
        -Object $rawTool `
        -Name "accepted_identities" `
        -Path "profile.raw_tool"
    if (-not (Test-ProfileIdentityMatch `
        -Identity $RawToolIdentity `
        -AcceptedIdentities $rawToolIdentities `
        -Path "profile.raw_tool.accepted_identities")) {
        throw "Raw tool identity '$RawToolIdentity' does not match profile '$ProfileId'."
    }

    $displayTool = Get-RequiredProfileValue `
        -Object $profile `
        -Name "display_tool" `
        -Path "profile"
    [void](Get-RequiredProfileValue -Object $displayTool -Name "name" -Path "profile.display_tool")
    [void](Get-RequiredProfileValue -Object $displayTool -Name "version" -Path "profile.display_tool")
    [void](Get-RequiredProfileValue -Object $displayTool -Name "label" -Path "profile.display_tool")
    $displayToolIdentities = Get-ProfileIdentityList `
        -Object $displayTool `
        -Name "accepted_identities" `
        -Path "profile.display_tool"
    if (-not (Test-ProfileIdentityMatch `
        -Identity $DisplayToolIdentity `
        -AcceptedIdentities $displayToolIdentities `
        -Path "profile.display_tool.accepted_identities")) {
        throw "Display tool identity '$DisplayToolIdentity' does not match profile '$ProfileId'."
    }

    $displayMultiplier = [double](Get-RequiredProfileValue `
        -Object $profile `
        -Name "display_multiplier" `
        -Path "profile")
    $dataRateMultiplier = [double](Get-RequiredProfileValue `
        -Object $profile `
        -Name "data_rate_multiplier" `
        -Path "profile")
    $busWidthBits = [int](Get-RequiredProfileValue `
        -Object $profile `
        -Name "bus_width_bits" `
        -Path "profile")
    if (
        $displayMultiplier -le 0 -or
        $dataRateMultiplier -le 0 -or
        $busWidthBits -le 0
    ) {
        throw "Memory profile multipliers and bus width must be positive."
    }
    $constraints = Get-RequiredProfileValue `
        -Object $profile `
        -Name "constraints" `
        -Path "profile"
    if (
        (Get-RequiredProfileValue -Object $constraints -Name "exact_gpu_required" -Path "profile.constraints") -ne $true -or
        (Get-RequiredProfileValue -Object $constraints -Name "exact_raw_field_required" -Path "profile.constraints") -ne $true -or
        (Get-RequiredProfileValue -Object $constraints -Name "exact_tool_required" -Path "profile.constraints") -ne $true -or
        (Get-RequiredProfileValue -Object $constraints -Name "cross_generation_allowed" -Path "profile.constraints") -ne $false
    ) {
        throw "Memory profile constraints are not fail-closed."
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

try {
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
}
catch {
    [Console]::Error.WriteLine("Telemetry analyzer failed: $($_.Exception.Message)")
    exit 1
}

if ($chartData.TimeBased -ne $true) {
    [Console]::Error.WriteLine("Memory basis chart requires timestamped telemetry.")
    exit 2
}
$rawSeries = @($chartData.Series | Where-Object {
    $_.Metric -eq [string]$profile.raw_field.metric -and
    ([string]$_.SourceColumn -match [string]$profile.raw_field.source_column_pattern)
}) | Select-Object -First 1
if ($null -eq $rawSeries) {
    [Console]::Error.WriteLine(
        "No memory clock series matches profile raw field '$($profile.raw_field.metric)'."
    )
    exit 2
}
$temperatureSeries = @($chartData.Series | Where-Object {
    $_.Metric -eq "GPU memory junction (C)"
}) | Select-Object -First 1

$rawPoints = @($rawSeries.Points | Where-Object { $null -ne $_.T -and $null -ne $_.V })
if ($rawPoints.Count -eq 0) {
    [Console]::Error.WriteLine("Memory clock series has no usable points.")
    exit 2
}
$times = @($rawPoints | ForEach-Object { [double]$_.T })
$xMinimum = ($times | Measure-Object -Minimum).Minimum
$xMaximum = ($times | Measure-Object -Maximum).Maximum
if ($xMaximum -le $xMinimum) {
    $xMaximum = $xMinimum + 1
}
$rawValues = @($rawPoints | ForEach-Object { [double]$_.V })
$displayValues = @($rawValues | ForEach-Object { $_ * $displayMultiplier })
$dataRateValues = @($rawValues | ForEach-Object { $_ * $dataRateMultiplier / 1000 })
$rawMedian = ($rawValues | Sort-Object)[[int][Math]::Floor($rawValues.Count / 2)]
$displayMedian = $rawMedian * $displayMultiplier
$dataRateMedian = $rawMedian * $dataRateMultiplier / 1000
$bandwidthMedian = $dataRateMedian * $busWidthBits / 8

$lanes = New-Object System.Collections.Generic.List[object]
$lanes.Add([pscustomobject]@{
    Title = "HWiNFO raw memory clock (MHz)"
    Color = "#8da8ff"
    Values = $rawValues
    Selector = { param($point) if ($null -eq $point.V) { $null } else { [double]$point.V } }
}) | Out-Null
$lanes.Add([pscustomobject]@{
    Title = "$($profile.display_tool.name) equivalent memory clock (MHz)"
    Color = "#78d5a3"
    Values = $displayValues
    Selector = {
        param($point)
        if ($null -eq $point.V) { $null } else { [double]$point.V * $displayMultiplier }
    }
}) | Out-Null
if ($null -ne $temperatureSeries) {
    $temperaturePoints = @($temperatureSeries.Points | Where-Object {
        $null -ne $_.T -and $null -ne $_.V
    })
    if ($temperaturePoints.Count -gt 0) {
        $lanes.Add([pscustomobject]@{
            Title = "GPU memory junction (C)"
            Color = "#e39468"
            Values = @($temperaturePoints | ForEach-Object { [double]$_.V })
            Selector = {
                param($point)
                if ($null -eq $point.T) { $null } else { [double]$point.V }
            }
            Points = $temperatureSeries.Points
        }) | Out-Null
    }
}

$width = 1600
$laneHeight = 150
$laneGap = 32
$firstLaneTop = 300
$lastLaneTop = $firstLaneTop + ($lanes.Count - 1) * ($laneHeight + $laneGap)
$plotBottom = $lastLaneTop + $laneHeight
$height = $plotBottom + 180
$left = 100
$right = 70
$plotWidth = $width - $left - $right

function Get-X {
    param([double]$Seconds)
    return $left + (($Seconds - $xMinimum) / ($xMaximum - $xMinimum)) * $plotWidth
}

$svg = New-Object System.Text.StringBuilder
[void]$svg.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"memory-title memory-desc`" data-profile-status=`"$(ConvertTo-SvgText $profileStatus)`">")
[void]$svg.AppendLine("  <title id=`"memory-title`">$(ConvertTo-SvgText $Title)</title>")
[void]$svg.AppendLine("  <desc id=`"memory-desc`">Raw memory clock and tool-scaled equivalent. Profile: $(ConvertTo-SvgText $ProfileId); status: $(ConvertTo-SvgText $profileStatus); raw tool: $(ConvertTo-SvgText $RawToolIdentity); display tool: $(ConvertTo-SvgText $DisplayToolIdentity). The derived values are not independent hardware measurements.</desc>")
[void]$svg.AppendLine('  <defs>')
[void]$svg.AppendLine('    <linearGradient id="page" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#080b10"/><stop offset="1" stop-color="#0d1319"/></linearGradient>')
[void]$svg.AppendLine('    <linearGradient id="panel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#111820"/><stop offset="1" stop-color="#0b1016"/></linearGradient>')
[void]$svg.AppendLine('  </defs>')
[void]$svg.AppendLine("  <rect width=`"$width`" height=`"$height`" fill=`"url(#page)`"/>")
[void]$svg.AppendLine('  <g font-family="Segoe UI, Microsoft YaHei, sans-serif" fill="#edf3f6">')
[void]$svg.AppendLine("    <text x=`"70`" y=`"62`" font-size=`"30`" font-weight=`"600`">$(ConvertTo-SvgText $Title)</text>")
[void]$svg.AppendLine("    <text x=`"70`" y=`"94`" font-size=`"13`" fill=`"#8b98a4`">$(ConvertTo-SvgText $chartData.FileName)  /  $(ConvertTo-SvgText $chartData.Window)  /  $(ConvertTo-SvgText $chartData.AnalyzedRows) rows</text>")
[void]$svg.AppendLine("    <text x=`"70`" y=`"120`" font-size=`"11`" fill=`"#64727f`">Profile $(ConvertTo-SvgText $ProfileId) · status: $(ConvertTo-SvgText $profileStatus) · raw clock basis: $(ConvertTo-SvgText $profile.raw_field.clock_basis) · derived display basis: $(ConvertTo-SvgText $profile.clock_basis)</text>")
[void]$svg.AppendLine("    <text x=`"70`" y=`"140`" font-size=`"10`" fill=`"#64727f`">Raw tool: $(ConvertTo-SvgText $RawToolIdentity) · display tool: $(ConvertTo-SvgText $DisplayToolIdentity)</text>")

$cards = @(
    @{ Label = "$($profile.raw_tool.name) $($profile.raw_tool.version) raw"; Value = "$(Format-SvgNumber $rawMedian 1) MHz"; Color = "#8da8ff" },
    @{ Label = "$($profile.display_tool.name) $($profile.display_tool.version) equivalent"; Value = "$(Format-SvgNumber $displayMedian 1) MHz"; Color = "#78d5a3" },
    @{ Label = "Per-pin equivalent"; Value = "$(Format-SvgNumber $dataRateMedian 3) Gb/s"; Color = "#e39468" },
    @{ Label = "$busWidthBits-bit theoretical"; Value = "$(Format-SvgNumber $bandwidthMedian 1) GB/s"; Color = "#e8b269" }
)
for ($cardIndex = 0; $cardIndex -lt $cards.Count; $cardIndex++) {
    $card = $cards[$cardIndex]
    $cardX = 70 + ($cardIndex * 375)
    [void]$svg.AppendLine("    <rect x=`"$cardX`" y=`"154`" width=`"350`" height=`"88`" rx=`"12`" fill=`"#0d141b`" stroke=`"#26323c`"/>")
    [void]$svg.AppendLine("    <text x=`"$($cardX + 18)`" y=`"182`" font-size=`"11`" fill=`"#8b98a4`">$(ConvertTo-SvgText $card.Label)</text>")
    [void]$svg.AppendLine("    <text x=`"$($cardX + 18)`" y=`"219`" font-size=`"24`" font-weight=`"600`" fill=`"$($card.Color)`">$(ConvertTo-SvgText $card.Value)</text>")
}

[void]$svg.AppendLine("    <rect x=`"$left`" y=`"$($firstLaneTop - 32)`" width=`"$plotWidth`" height=`"$($plotBottom - $firstLaneTop + 52)`" rx=`"14`" fill=`"url(#panel)`" stroke=`"#26323c`"/>")
for ($laneIndex = 0; $laneIndex -lt $lanes.Count; $laneIndex++) {
    $lane = $lanes[$laneIndex]
    $top = $firstLaneTop + $laneIndex * ($laneHeight + $laneGap)
    $bottom = $top + $laneHeight
    $domain = Get-PaddedDomain -Values ([double[]]$lane.Values)
    $minimum = ($lane.Values | Measure-Object -Minimum).Minimum
    $maximum = ($lane.Values | Measure-Object -Maximum).Maximum
    $mean = ($lane.Values | Measure-Object -Average).Average
    [void]$svg.AppendLine("    <text x=`"122`" y=`"$($top - 10)`" font-size=`"12`" font-weight=`"600`" fill=`"$($lane.Color)`">$(ConvertTo-SvgText $lane.Title)</text>")
    [void]$svg.AppendLine("    <text x=`"$($left + $plotWidth - 18)`" y=`"$($top - 10)`" text-anchor=`"end`" font-size=`"10`" fill=`"#8b98a4`">min $(Format-SvgNumber $minimum 1) · mean $(Format-SvgNumber $mean 1) · max $(Format-SvgNumber $maximum 1)</text>")
    for ($gridIndex = 0; $gridIndex -le 4; $gridIndex++) {
        $ratio = $gridIndex / 4
        $gridY = $top + $laneHeight * $ratio
        [void]$svg.AppendLine("    <line x1=`"$left`" y1=`"$($gridY.ToString('0.###', $invariant))`" x2=`"$($left + $plotWidth)`" y2=`"$($gridY.ToString('0.###', $invariant))`" stroke=`"#26323c`" opacity=`"$(if ($gridIndex -eq 0 -or $gridIndex -eq 4) { '0.65' } else { '0.28' })`"/>")
    }
    [void]$svg.AppendLine("    <text x=`"$($left - 10)`" y=`"$($top + 4)`" text-anchor=`"end`" font-size=`"10`" fill=`"#8b98a4`">$(Format-SvgNumber $domain.Maximum 1)</text>")
    [void]$svg.AppendLine("    <text x=`"$($left - 10)`" y=`"$bottom`" text-anchor=`"end`" font-size=`"10`" fill=`"#8b98a4`">$(Format-SvgNumber $domain.Minimum 1)</text>")

    $sourcePoints = if ($lane.PSObject.Properties["Points"]) {
        @($lane.Points)
    }
    else {
        @($rawPoints)
    }
    $segments = Get-PlotSegments `
        -Points $sourcePoints `
        -XMinimum $xMinimum `
        -XMaximum $xMaximum `
        -YMinimum $domain.Minimum `
        -YMaximum $domain.Maximum `
        -PlotLeft $left `
        -PlotTop $top `
        -PlotWidth $plotWidth `
        -PlotHeight $laneHeight `
        -ValueSelector $lane.Selector
    foreach ($segment in $segments) {
        $coordinates = @($segment.Coordinates)
        if ($coordinates.Count -ge 2) {
            $pointsText = ($coordinates | ForEach-Object {
                "$($_.X.ToString('0.###', $invariant)),$($_.Y.ToString('0.###', $invariant))"
            }) -join " "
            [void]$svg.AppendLine("    <polyline points=`"$pointsText`" fill=`"none`" stroke=`"$($lane.Color)`" stroke-width=`"2.1`" stroke-linecap=`"round`" stroke-linejoin=`"round`"/>")
        }
        elseif ($coordinates.Count -eq 1) {
            [void]$svg.AppendLine("    <circle cx=`"$($coordinates[0].X.ToString('0.###', $invariant))`" cy=`"$($coordinates[0].Y.ToString('0.###', $invariant))`" r=`"2.5`" fill=`"$($lane.Color)`"/>")
        }
    }
}
for ($tickIndex = 0; $tickIndex -le 4; $tickIndex++) {
    $ratio = $tickIndex / 4
    $tickX = $left + $plotWidth * $ratio
    $tickValue = $xMinimum + ($xMaximum - $xMinimum) * $ratio
    [void]$svg.AppendLine("    <line x1=`"$($tickX.ToString('0.###', $invariant))`" y1=`"$firstLaneTop`" x2=`"$($tickX.ToString('0.###', $invariant))`" y2=`"$plotBottom`" stroke=`"#26323c`" opacity=`"0.16`"/>")
    [void]$svg.AppendLine("    <text x=`"$($tickX.ToString('0.###', $invariant))`" y=`"$($plotBottom + 20)`" text-anchor=`"middle`" font-size=`"10`" fill=`"#64727f`">$(Format-SvgNumber $tickValue 1) s</text>")
}
[void]$svg.AppendLine("    <text x=`"70`" y=`"$($height - 70)`" font-size=`"11`" fill=`"#8b98a4`">$($profile.display_tool.name) equivalent = raw value x $(Format-SvgNumber $displayMultiplier 0); per-pin equivalent = raw value x $(Format-SvgNumber $dataRateMultiplier 0).</text>")
[void]$svg.AppendLine("    <text x=`"70`" y=`"$($height - 48)`" font-size=`"11`" fill=`"#8b98a4`">Derived values preserve the raw field and are not independent measurements, achieved throughput, or stability proof.</text>")
[void]$svg.AppendLine("    <text x=`"70`" y=`"$($height - 18)`" font-size=`"12`" font-weight=`"600`" fill=`"#e8b269`">For reference only - put safety first.</text>")
[void]$svg.AppendLine('  </g>')
[void]$svg.AppendLine('</svg>')

$writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content $svg.ToString()
Write-Output $writtenPath
