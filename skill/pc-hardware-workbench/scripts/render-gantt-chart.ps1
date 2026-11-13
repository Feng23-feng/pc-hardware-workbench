[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$InputPath,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputPath,

    [string]$Title,

    [ValidateRange(3, 12)]
    [int]$Ticks = 6
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    [Console]::Error.WriteLine("Local path safety helper is missing: $pathSafetyHelper")
    exit 2
}
. $pathSafetyHelper

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
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

function Get-CleanText {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumLength = 160
    )
    if ($null -eq $Value) {
        return ""
    }
    $text = ([string]$Value) -replace "[\p{Cc}\p{Cf}]", " "
    $text = $text.Trim()
    if ($text.Length -gt $MaximumLength) {
        return $text.Substring(0, $MaximumLength - 3) + "..."
    }
    return $text
}

function ConvertTo-FiniteNumber {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Field,
        [Parameter(Mandatory = $true)][int]$TaskNumber
    )
    $number = 0.0
    try {
        $number = [Convert]::ToDouble($Value, $invariant)
    }
    catch {
        Stop-WithInputError "Task $TaskNumber field '$Field' must be numeric."
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        Stop-WithInputError "Task $TaskNumber field '$Field' must be finite."
    }
    return $number
}

function Format-SvgNumber {
    param([double]$Value)
    return $Value.ToString("0.###", $invariant)
}

function ConvertTo-SvgText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-StatusColor {
    param([string]$Status)
    switch ($Status) {
        "active" { return "#2f7482" }
        "pass" { return "#3f7b58" }
        "fail" { return "#a34f4f" }
        "blocked" { return "#956f2f" }
        default { return "#64717d" }
    }
}

try {
    $resolvedInput = Assert-LocalReadFilePath -Path $InputPath
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

if ([IO.Path]::GetExtension($resolvedInput) -ine ".json") {
    Stop-WithInputError "Gantt input must be a JSON plan file."
}
if ([IO.Path]::GetExtension($resolvedOutput) -ine ".svg") {
    Stop-WithInputError "Only SVG output is supported."
}

try {
    $plan = Get-Content -Raw -LiteralPath $resolvedInput -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Stop-WithInputError "Gantt input is not valid JSON: $($_.Exception.Message)"
}

$taskValues = @(Get-PropertyValue -Object $plan -Name "tasks" -Default @())
if ($taskValues.Count -eq 0) {
    Stop-WithInputError "Gantt input must contain at least one task."
}
if ($taskValues.Count -gt 40) {
    Stop-WithInputError "Gantt input contains too many tasks; the maximum is 40."
}

$planTitle = if (-not [string]::IsNullOrWhiteSpace($Title)) {
    Get-CleanText $Title 120
}
else {
    Get-CleanText (Get-PropertyValue -Object $plan -Name "title" -Default "Hardware validation plan") 120
}
if ([string]::IsNullOrWhiteSpace($planTitle)) {
    $planTitle = "Hardware validation plan"
}

$timeUnit = Get-CleanText (Get-PropertyValue -Object $plan -Name "timeUnit" -Default "min") 16
if ([string]::IsNullOrWhiteSpace($timeUnit)) {
    $timeUnit = "min"
}

$allowedStatuses = @("planned", "active", "pass", "fail", "blocked")
$tasks = New-Object System.Collections.Generic.List[object]
$trackOrder = New-Object System.Collections.Generic.List[string]
$seenTracks = New-Object System.Collections.Generic.HashSet[string]([StringComparer]::OrdinalIgnoreCase)
$minimumStart = [double]::PositiveInfinity
$maximumEnd = [double]::NegativeInfinity

for ($index = 0; $index -lt $taskValues.Count; $index++) {
    $taskNumber = $index + 1
    $task = $taskValues[$index]
    $label = Get-CleanText (Get-PropertyValue -Object $task -Name "label" -Default "") 90
    if ([string]::IsNullOrWhiteSpace($label)) {
        Stop-WithInputError "Task $taskNumber is missing a non-empty label."
    }

    $startProperty = $task.PSObject.Properties["start"]
    $durationProperty = $task.PSObject.Properties["duration"]
    if ($null -eq $startProperty -or $null -eq $startProperty.Value) {
        Stop-WithInputError "Task $taskNumber is missing the start field."
    }
    if ($null -eq $durationProperty -or $null -eq $durationProperty.Value) {
        Stop-WithInputError "Task $taskNumber is missing the duration field."
    }

    $start = ConvertTo-FiniteNumber `
        -Value $startProperty.Value `
        -Field "start" `
        -TaskNumber $taskNumber
    $duration = ConvertTo-FiniteNumber `
        -Value $durationProperty.Value `
        -Field "duration" `
        -TaskNumber $taskNumber
    if ($start -lt 0) {
        Stop-WithInputError "Task $taskNumber start must be zero or greater."
    }
    if ($duration -le 0) {
        Stop-WithInputError "Task $taskNumber duration must be greater than zero."
    }

    $track = Get-CleanText (Get-PropertyValue -Object $task -Name "track" -Default "Plan") 48
    if ([string]::IsNullOrWhiteSpace($track)) {
        $track = "Plan"
    }
    $status = (Get-CleanText (Get-PropertyValue -Object $task -Name "status" -Default "planned") 20).ToLowerInvariant()
    if ($status -notin $allowedStatuses) {
        Stop-WithInputError "Task $taskNumber has unsupported status '$status'."
    }
    $note = Get-CleanText (Get-PropertyValue -Object $task -Name "note" -Default "") 180

    if (-not $seenTracks.Add($track)) {
        $track = @($trackOrder | Where-Object { $_ -ieq $track }) | Select-Object -First 1
    }
    else {
        $trackOrder.Add($track) | Out-Null
    }

    $end = $start + $duration
    if ($start -lt $minimumStart) {
        $minimumStart = $start
    }
    if ($end -gt $maximumEnd) {
        $maximumEnd = $end
    }

    $tasks.Add([pscustomobject]@{
        Label = $label
        Start = $start
        Duration = $duration
        End = $end
        Track = $track
        Status = $status
        Note = $note
    }) | Out-Null
}

$span = [math]::Max($maximumEnd - $minimumStart, 0.001)
$canvasWidth = 1200
$canvasLeft = 270
$canvasRight = 54
$chartWidth = $canvasWidth - $canvasLeft - $canvasRight
$axisY = 126
$layoutTop = 156
$taskHeight = 28
$taskStep = 40
$trackHeaderHeight = 30
$trackGap = 18

$layouts = New-Object System.Collections.Generic.List[object]
$cursorY = $layoutTop
foreach ($trackName in $trackOrder) {
    $trackTasks = @($tasks | Where-Object { $_.Track -ieq $trackName } | Sort-Object Start, Label)
    $blockHeight = $trackHeaderHeight + ($trackTasks.Count * $taskStep) + $trackGap
    $layouts.Add([pscustomobject]@{
        Name = $trackName
        Tasks = $trackTasks
        Top = $cursorY
        Height = $blockHeight
    }) | Out-Null
    $cursorY += $blockHeight
}

$canvasHeight = [int][math]::Ceiling($cursorY + 42)
$svg = New-Object System.Text.StringBuilder
[void]$svg.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$svg.AppendLine((
    '<svg xmlns="http://www.w3.org/2000/svg" width="{0}" height="{1}" viewBox="0 0 {0} {1}" role="img" aria-labelledby="gantt-title gantt-desc">' -f
    $canvasWidth,
    $canvasHeight
))
[void]$svg.AppendLine('  <title id="gantt-title">' + (ConvertTo-SvgText $planTitle) + '</title>')
[void]$svg.AppendLine('  <desc id="gantt-desc">A planning view generated from a local JSON schedule; task durations are not measurements.</desc>')
[void]$svg.AppendLine('  <rect width="100%" height="100%" fill="#f4f2ec"/>')
[void]$svg.AppendLine('  <rect x="20" y="20" width="1160" height="' + ($canvasHeight - 40) + '" rx="14" fill="#fbfaf6" stroke="#d8d4ca"/>')
[void]$svg.AppendLine('  <text x="44" y="58" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="26" font-weight="600" fill="#20262b">' + (ConvertTo-SvgText $planTitle) + '</text>')
[void]$svg.AppendLine(
    '  <text x="44" y="84" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="13" fill="#6d7479">' +
    (ConvertTo-SvgText ("Planning view | time in {0} | not a hardware measurement" -f $timeUnit)) +
    '</text>'
)

$legendX = 44
foreach ($statusName in $allowedStatuses) {
    $color = Get-StatusColor $statusName
    $statusLabel = (Get-Culture).TextInfo.ToTitleCase($statusName)
    [void]$svg.AppendLine('  <rect x="' + $legendX + '" y="98" width="12" height="12" rx="3" fill="' + $color + '"/>')
    [void]$svg.AppendLine(
        '  <text x="' + ($legendX + 18) + '" y="109" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="11" fill="#5d656c">' +
        (ConvertTo-SvgText $statusLabel) +
        '</text>'
    )
    $legendX += 78
}

for ($tickIndex = 0; $tickIndex -le $Ticks; $tickIndex++) {
    $ratio = [double]$tickIndex / [double]$Ticks
    $tickValue = $minimumStart + ($span * $ratio)
    $tickX = $canvasLeft + ($chartWidth * $ratio)
    [void]$svg.AppendLine((
        '  <line x1="{0}" y1="{1}" x2="{0}" y2="{2}" stroke="#dedad1" stroke-width="1"/>' -f
        (Format-SvgNumber $tickX),
        $axisY,
        ($canvasHeight - 42)
    ))
    [void]$svg.AppendLine((
        '  <text x="{0}" y="148" text-anchor="middle" font-family="Cascadia Code, Consolas, monospace" font-size="11" fill="#697178">{1} {2}</text>' -f
        (Format-SvgNumber $tickX),
        (Format-SvgNumber $tickValue),
        (ConvertTo-SvgText $timeUnit)
    ))
}

foreach ($layout in $layouts) {
    [void]$svg.AppendLine((
        '  <rect x="34" y="{0}" width="1132" height="{1}" rx="9" fill="#f7f5ef" stroke="#e4e0d7"/>' -f
        $layout.Top,
        ($layout.Height - 6)
    ))
    [void]$svg.AppendLine((
        '  <text x="50" y="{0}" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="12" font-weight="600" fill="#4c565e">{1}</text>' -f
        ($layout.Top + 20),
        (ConvertTo-SvgText $layout.Name)
    ))

    $taskY = $layout.Top + $trackHeaderHeight
    foreach ($task in $layout.Tasks) {
        $barX = $canvasLeft + (($task.Start - $minimumStart) / $span * $chartWidth)
        $barWidth = [math]::Max(4.0, ($task.Duration / $span * $chartWidth))
        $barY = $taskY + 6
        $barColor = Get-StatusColor $task.Status
        $durationText = "{0:0.##} {1}" -f $task.Duration, $timeUnit
        [void]$svg.AppendLine((
            '  <text x="50" y="{0}" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="13" fill="#283038">{1}</text>' -f
            ($taskY + 24),
            (ConvertTo-SvgText $task.Label)
        ))
        [void]$svg.AppendLine((
            '  <g><title>{0}</title><rect x="{1}" y="{2}" width="{3}" height="{4}" rx="6" fill="{5}"/>' -f
            (ConvertTo-SvgText (($task.Label + " | " + $durationText + $(if ($task.Note) { " | " + $task.Note } else { "" })))),
            (Format-SvgNumber $barX),
            (Format-SvgNumber $barY),
            (Format-SvgNumber $barWidth),
            $taskHeight,
            $barColor
        ))
        if ($barWidth -ge 92) {
            [void]$svg.AppendLine((
                '    <text x="{0}" y="{1}" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="11" font-weight="600" fill="#ffffff">{2}</text>' -f
                (Format-SvgNumber ($barX + 10)),
                (Format-SvgNumber ($barY + 18)),
                (ConvertTo-SvgText $durationText)
            ))
        }
        else {
            $outsideLabelX = $barX + $barWidth + 6
            $outsideTextAnchor = "start"
            if ($outsideLabelX + 56 -gt ($canvasWidth - 24)) {
                $outsideLabelX = $barX - 6
                $outsideTextAnchor = "end"
            }
            [void]$svg.AppendLine((
                '    <text x="{0}" y="{1}" text-anchor="{2}" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="11" fill="#566069">{3}</text>' -f
                (Format-SvgNumber $outsideLabelX),
                (Format-SvgNumber ($barY + 18)),
                $outsideTextAnchor,
                (ConvertTo-SvgText $durationText)
            ))
        }
        [void]$svg.AppendLine('  </g>')
        $taskY += $taskStep
    }
}

[void]$svg.AppendLine((
    '  <text x="44" y="{0}" font-family="Segoe UI, Microsoft YaHei UI, sans-serif" font-size="11" fill="#777d81">Durations remain assumptions until the plan is executed and verified.</text>' -f
    ($canvasHeight - 22)
))
[void]$svg.AppendLine('</svg>')

try {
    $writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content $svg.ToString()
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}

Write-Output $writtenPath
