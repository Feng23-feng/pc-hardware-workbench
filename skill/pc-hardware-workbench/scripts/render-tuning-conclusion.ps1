[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputPath
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

function Get-RequiredText {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$MaximumLength = 500
    )
    $value = [string](Get-PropertyValue -Object $Object -Name $Name -Default "")
    $value = (($value -replace "[\p{Cc}\p{Cf}]", " ") -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Conclusion input is missing required text '$Name'."
    }
    if ($value.Length -gt $MaximumLength) {
        throw "Conclusion text '$Name' exceeds $MaximumLength characters."
    }
    return $value
}

function Get-Array {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Maximum = 12
    )
    $value = Get-PropertyValue -Object $Object -Name $Name -Default @()
    if ($null -eq $value) {
        return @()
    }
    return @($value | Select-Object -First $Maximum)
}

function Get-ToneColor {
    param([string]$Tone)
    switch ($Tone.ToLowerInvariant()) {
        "positive" { return "#78d5a3" }
        "negative" { return "#ef7c84" }
        "warning" { return "#e8b269" }
        "caution" { return "#e8b269" }
        "neutral" { return "#8da8ff" }
        default { return "#8da8ff" }
    }
}

function Format-NumberText {
    param(
        [double]$Value,
        [int]$Decimals = 2
    )
    return $Value.ToString("0." + ("0" * $Decimals), $invariant)
}

try {
    $resolvedInput = Assert-LocalReadFilePath -Path $InputPath
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
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
    $document = Get-Content -Raw -LiteralPath $resolvedInput -Encoding UTF8 | ConvertFrom-Json
}
catch {
    [Console]::Error.WriteLine("Conclusion JSON is invalid: $($_.Exception.Message)")
    exit 2
}

try {
    if ([string]$document.SchemaVersion -ne "1.0") {
        throw "SchemaVersion must be '1.0'."
    }
    $title = Get-RequiredText -Object $document -Name "Title" -MaximumLength 140
    $subtitle = [string](Get-PropertyValue -Object $document -Name "Subtitle" -Default "")
    $verdict = Get-PropertyValue -Object $document -Name "Verdict"
    if ($null -eq $verdict) {
        throw "Verdict is required."
    }
    $verdictLabel = Get-RequiredText -Object $verdict -Name "Label" -MaximumLength 100
    $verdictTone = [string](Get-PropertyValue -Object $verdict -Name "Tone" -Default "neutral")
    $verdictColor = Get-ToneColor -Tone $verdictTone
    $contextItems = @(Get-Array -Object $document -Name "Context" -Maximum 6)
    $metricItems = @(Get-Array -Object $document -Name "Metrics" -Maximum 8)
    $telemetryItems = @(Get-Array -Object $document -Name "Telemetry" -Maximum 6)
    $decisions = @(Get-Array -Object $document -Name "Decisions" -Maximum 3)
    $limitations = @(Get-Array -Object $document -Name "Limitations" -Maximum 6)
    $sources = @(Get-Array -Object $document -Name "Sources" -Maximum 6)
    if ($metricItems.Count -eq 0) {
        throw "At least one metric is required."
    }
    if ($decisions.Count -eq 0) {
        throw "At least one decision is required."
    }
    foreach ($metric in $metricItems) {
        [void](Get-RequiredText -Object $metric -Name "Label" -MaximumLength 100)
        foreach ($numberName in @("Baseline", "Candidate", "DeltaPercent")) {
            $numberValue = Get-PropertyValue -Object $metric -Name $numberName -Default $null
            if ($null -ne $numberValue) {
                $parsed = 0.0
                if (-not [double]::TryParse(
                    [string]$numberValue,
                    [System.Globalization.NumberStyles]::Float,
                    $invariant,
                    [ref]$parsed
                ) -or
                    [double]::IsNaN($parsed) -or
                    [double]::IsInfinity($parsed)) {
                    throw "Metric '$([string]$metric.Label)' has invalid $numberName."
                }
            }
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

$width = 1600
$height = 1200
$svg = New-Object System.Text.StringBuilder
[void]$svg.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$svg.AppendLine("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"conclusion-title conclusion-desc`">")
[void]$svg.AppendLine("  <title id=`"conclusion-title`">$(ConvertTo-SvgText $title)</title>")
[void]$svg.AppendLine('  <desc id="conclusion-desc">Hardware tuning conclusion summary with performance metrics, supporting observations, decisions, limitations, and sources.</desc>')
[void]$svg.AppendLine('  <defs>')
[void]$svg.AppendLine('    <linearGradient id="page" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#080b10"/><stop offset="1" stop-color="#0d1319"/></linearGradient>')
[void]$svg.AppendLine('    <linearGradient id="panel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#111820"/><stop offset="1" stop-color="#0b1016"/></linearGradient>')
[void]$svg.AppendLine('  </defs>')
[void]$svg.AppendLine("  <rect width=`"$width`" height=`"$height`" fill=`"url(#page)`"/>")
[void]$svg.AppendLine('  <g font-family="Segoe UI, Microsoft YaHei, sans-serif" fill="#edf3f6">')
[void]$svg.AppendLine("    <text x=`"60`" y=`"68`" font-size=`"32`" font-weight=`"600`">$(ConvertTo-SvgText $title)</text>")
if (-not [string]::IsNullOrWhiteSpace($subtitle)) {
    [void]$svg.AppendLine("    <text x=`"60`" y=`"102`" font-size=`"14`" fill=`"#8b98a4`">$(ConvertTo-SvgText $subtitle)</text>")
}
[void]$svg.AppendLine("    <rect x=`"1130`" y=`"36`" width=`"410`" height=`"96`" rx=`"12`" fill=`"$verdictColor`" opacity=`"0.10`" stroke=`"$verdictColor`" stroke-opacity=`"0.55`"/>")
[void]$svg.AppendLine("    <text x=`"1152`" y=`"66`" font-size=`"12`" fill=`"#8b98a4`">VERDICT</text>")
[void]$svg.AppendLine("    <text x=`"1152`" y=`"99`" font-size=`"23`" font-weight=`"600`" fill=`"$verdictColor`">$(ConvertTo-SvgText $verdictLabel)</text>")

$contextX = 60
$contextY = 138
$contextWidth = if ($contextItems.Count -le 3) { 460 } else { 220 }
foreach ($item in $contextItems) {
    $label = Get-RequiredText -Object $item -Name "Label" -MaximumLength 60
    $value = Get-RequiredText -Object $item -Name "Value" -MaximumLength 160
    [void]$svg.AppendLine("    <text x=`"$contextX`" y=`"$contextY`" font-size=`"10`" fill=`"#64727f`">$(ConvertTo-SvgText $label)</text>")
    [void]$svg.AppendLine("    <text x=`"$contextX`" y=`"$($contextY + 20)`" font-size=`"13`">$(ConvertTo-SvgText $value)</text>")
    $contextX += $contextWidth
}

[void]$svg.AppendLine('    <rect x="60" y="190" width="920" height="520" rx="14" fill="url(#panel)" stroke="#26323c"/>')
[void]$svg.AppendLine('    <rect x="1010" y="190" width="530" height="520" rx="14" fill="url(#panel)" stroke="#26323c"/>')
[void]$svg.AppendLine('    <text x="88" y="226" font-size="20" font-weight="600">Performance evidence</text>')
[void]$svg.AppendLine('    <text x="1038" y="226" font-size="20" font-weight="600">Telemetry evidence</text>')

$deltaValues = @($metricItems | ForEach-Object {
    $direct = Get-PropertyValue -Object $_ -Name "DeltaPercent" -Default $null
    if ($null -ne $direct) {
        [double]$direct
    }
    else {
        $baseline = Get-PropertyValue -Object $_ -Name "Baseline" -Default $null
        $candidate = Get-PropertyValue -Object $_ -Name "Candidate" -Default $null
        if ($null -ne $baseline -and $null -ne $candidate -and [double]$baseline -ne 0) {
            (([double]$candidate / [double]$baseline) - 1) * 100
        }
        else {
            $null
        }
    }
})
$numericDeltas = @($deltaValues | Where-Object { $null -ne $_ })
$maximumAbsoluteDelta = if ($numericDeltas.Count -gt 0) {
    [Math]::Max(1.0, ($numericDeltas | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum)
}
else {
    1.0
}
$zeroX = 650
$barScale = 260 / $maximumAbsoluteDelta
$rowY = 270
for ($index = 0; $index -lt $metricItems.Count; $index++) {
    $metric = $metricItems[$index]
    $label = Get-RequiredText -Object $metric -Name "Label" -MaximumLength 100
    $unit = [string](Get-PropertyValue -Object $metric -Name "Unit" -Default "")
    $tone = [string](Get-PropertyValue -Object $metric -Name "Tone" -Default "neutral")
    $color = Get-ToneColor -Tone $tone
    $valueText = [string](Get-PropertyValue -Object $metric -Name "Value" -Default "")
    $baseline = Get-PropertyValue -Object $metric -Name "Baseline" -Default $null
    $candidate = Get-PropertyValue -Object $metric -Name "Candidate" -Default $null
    $delta = $deltaValues[$index]
    [void]$svg.AppendLine("    <text x=`"88`" y=`"$rowY`" font-size=`"14`" font-weight=`"600`">$(ConvertTo-SvgText $label)</text>")
    if ($null -ne $baseline -and $null -ne $candidate) {
        $detail = "baseline {0} -> candidate {1}" -f (Format-NumberText ([double]$baseline) 2), (Format-NumberText ([double]$candidate) 2)
        [void]$svg.AppendLine("    <text x=`"88`" y=`"$($rowY + 18)`" font-size=`"10`" fill=`"#8b98a4`">$(ConvertTo-SvgText $detail)</text>")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($valueText)) {
        [void]$svg.AppendLine("    <text x=`"88`" y=`"$($rowY + 18)`" font-size=`"10`" fill=`"#8b98a4`">$(ConvertTo-SvgText ($valueText + " " + $unit))</text>")
    }
    if ($null -ne $delta) {
        $barWidth = [Math]::Abs([double]$delta) * $barScale
        $barX = if ([double]$delta -ge 0) { $zeroX } else { $zeroX - $barWidth }
        [void]$svg.AppendLine("    <rect x=`"$($barX.ToString('0.###', $invariant))`" y=`"$($rowY - 11)`" width=`"$($barWidth.ToString('0.###', $invariant))`" height=`"12`" rx=`"6`" fill=`"$color`"/>")
        $deltaText = "{0:+0.00;-0.00;0.00}%" -f [double]$delta
        [void]$svg.AppendLine("    <text x=`"930`" y=`"$rowY`" text-anchor=`"end`" font-size=`"14`" font-weight=`"600`" fill=`"$color`">$(ConvertTo-SvgText $deltaText)</text>")
    }
    elseif (-not [string]::IsNullOrWhiteSpace($valueText)) {
        [void]$svg.AppendLine("    <text x=`"930`" y=`"$rowY`" text-anchor=`"end`" font-size=`"14`" font-weight=`"600`" fill=`"$color`">$(ConvertTo-SvgText ($valueText + " " + $unit))</text>")
    }
    [void]$svg.AppendLine("    <line x1=`"88`" y1=`"$($rowY + 31)`" x2=`"950`" y2=`"$($rowY + 31)`" stroke=`"#26323c`" opacity=`"0.7`"/>")
    $rowY += 52
}

$telemetryY = 270
for ($index = 0; $index -lt $telemetryItems.Count; $index++) {
    $item = $telemetryItems[$index]
    $label = Get-RequiredText -Object $item -Name "Label" -MaximumLength 100
    $value = Get-RequiredText -Object $item -Name "Value" -MaximumLength 100
    $detail = [string](Get-PropertyValue -Object $item -Name "Detail" -Default "")
    $tone = [string](Get-PropertyValue -Object $item -Name "Tone" -Default "neutral")
    $color = Get-ToneColor -Tone $tone
    [void]$svg.AppendLine("    <rect x=`"1038`" y=`"$($telemetryY - 22)`" width=`"474`" height=`"66`" rx=`"10`" fill=`"#0d141b`" stroke=`"#26323c`"/>")
    [void]$svg.AppendLine("    <text x=`"1056`" y=`"$($telemetryY)`" font-size=`"10`" fill=`"#8b98a4`">$(ConvertTo-SvgText $label)</text>")
    [void]$svg.AppendLine("    <text x=`"1056`" y=`"$($telemetryY + 24)`" font-size=`"19`" font-weight=`"600`" fill=`"$color`">$(ConvertTo-SvgText $value)</text>")
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        [void]$svg.AppendLine("    <text x=`"1056`" y=`"$($telemetryY + 39)`" font-size=`"9`" fill=`"#64727f`">$(ConvertTo-SvgText $detail)</text>")
    }
    $telemetryY += 72
}

[void]$svg.AppendLine('    <rect x="60" y="740" width="1480" height="270" rx="14" fill="url(#panel)" stroke="#26323c"/>')
[void]$svg.AppendLine('    <text x="88" y="780" font-size="22" font-weight="600">Decision</text>')
$decisionWidth = if ($decisions.Count -eq 1) { 1420 } elseif ($decisions.Count -eq 2) { 700 } else { 460 }
for ($index = 0; $index -lt $decisions.Count; $index++) {
    $decision = $decisions[$index]
    $decisionTitle = Get-RequiredText -Object $decision -Name "Title" -MaximumLength 120
    $decisionText = Get-RequiredText -Object $decision -Name "Text" -MaximumLength 700
    $tone = [string](Get-PropertyValue -Object $decision -Name "Tone" -Default "neutral")
    $color = Get-ToneColor -Tone $tone
    $x = 88 + ($index * (470))
    [void]$svg.AppendLine("    <rect x=`"$x`" y=`"810`" width=`"$decisionWidth`" height=`"164`" rx=`"10`" fill=`"$color`" opacity=`"0.07`" stroke=`"$color`" stroke-opacity=`"0.28`"/>")
    [void]$svg.AppendLine("    <text x=`"$($x + 20)`" y=`"842`" font-size=`"16`" font-weight=`"600`" fill=`"$color`">$(ConvertTo-SvgText $decisionTitle)</text>")
    $wrapped = [System.Collections.Generic.List[string]]::new()
    $remaining = $decisionText
    while ($remaining.Length -gt 54) {
        $split = $remaining.LastIndexOf(" ", 53)
        if ($split -lt 20) { $split = 54 }
        $wrapped.Add($remaining.Substring(0, $split).Trim()) | Out-Null
        $remaining = $remaining.Substring($split).Trim()
    }
    if ($remaining.Length -gt 0) { $wrapped.Add($remaining) | Out-Null }
    for ($lineIndex = 0; $lineIndex -lt [Math]::Min(3, $wrapped.Count); $lineIndex++) {
        [void]$svg.AppendLine("    <text x=`"$($x + 20)`" y=`"$((875 + ($lineIndex * 22)).ToString('0.###', $invariant))`" font-size=`"12`" fill=`"#8b98a4`">$(ConvertTo-SvgText $wrapped[$lineIndex])</text>")
    }
}

$footerY = 1050
if ($limitations.Count -gt 0) {
    [void]$svg.AppendLine("    <text x=`"60`" y=`"$footerY`" font-size=`"12`" font-weight=`"600`" fill=`"#e8b269`">Limitations</text>")
    for ($index = 0; $index -lt $limitations.Count; $index++) {
        $text = ConvertTo-SvgText ([string]$limitations[$index])
        [void]$svg.AppendLine("    <text x=`"60`" y=`"$($footerY + 22 + ($index * 18))`" font-size=`"10`" fill=`"#8b98a4`">- $text</text>")
    }
}
if ($sources.Count -gt 0) {
    $sourceY = $footerY + 22 + ([Math]::Max(1, $limitations.Count) * 18) + 18
    [void]$svg.AppendLine("    <text x=`"60`" y=`"$sourceY`" font-size=`"10`" fill=`"#64727f`">Sources: $(ConvertTo-SvgText ($sources -join " | "))</text>")
}
$safetyNotice = [string](Get-PropertyValue -Object $document -Name "SafetyNotice" -Default "")
if (-not [string]::IsNullOrWhiteSpace($safetyNotice)) {
    [void]$svg.AppendLine("    <text x=`"60`" y=`"1160`" font-size=`"12`" font-weight=`"600`" fill=`"#e8b269`">$(ConvertTo-SvgText $safetyNotice)</text>")
}
[void]$svg.AppendLine('  </g>')
[void]$svg.AppendLine('</svg>')

$writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content $svg.ToString()
Write-Output $writtenPath
