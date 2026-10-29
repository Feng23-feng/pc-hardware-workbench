[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [ValidateSet("Markdown", "Json")]
    [string]$Format = "Markdown",

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
    [int]$MaxInputMegabytes = 512
)

$ErrorActionPreference = "Stop"
function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$warnings = New-Object System.Collections.Generic.List[string]
Add-Type -AssemblyName Microsoft.VisualBasic
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

$usesTimeWindow = $WarmupSeconds -gt 0 -or $DurationSeconds -gt 0
$usesRowWindow = $WarmupRows -gt 0 -or $MaxRows -gt 0
if ($usesTimeWindow -and $usesRowWindow) {
    Stop-WithInputError "Use time-based window parameters or row-based window parameters, not both."
}

function Test-FiniteNumber {
    param([double]$Value)

    return -not ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))
}

function ConvertTo-Number {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $number = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$number)) {
        if (Test-FiniteNumber -Value $number) {
            return $number
        }
        return $null
    }

    $cultureNumber = 0.0
    if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$cultureNumber)) {
        if (Test-FiniteNumber -Value $cultureNumber) {
            return $cultureNumber
        }
        return $null
    }

    $match = [regex]::Match($text, "[-+]?\d[\d.,]*")
    if ($match.Success) {
        $normalized = $match.Value
        $commaIndex = $normalized.LastIndexOf(",")
        $dotIndex = $normalized.LastIndexOf(".")

        if ($commaIndex -ge 0 -and $dotIndex -ge 0) {
            if ($commaIndex -gt $dotIndex) {
                $normalized = $normalized.Replace(".", "").Replace(",", ".")
            }
            else {
                $normalized = $normalized.Replace(",", "")
            }
        }
        elseif ($commaIndex -ge 0) {
            if ($normalized -match "^[-+]?\d{1,3}(,\d{3})+$") {
                $normalized = $normalized.Replace(",", "")
            }
            else {
                $normalized = $normalized.Replace(",", ".")
            }
        }

        if ([double]::TryParse($normalized, [System.Globalization.NumberStyles]::Float, $invariant, [ref]$number)) {
            if (Test-FiniteNumber -Value $number) {
                return $number
            }
        }
    }

    return $null
}

function Get-ColumnUnit {
    param([string]$Column)

    $text = ([string]$Column).Trim().ToLowerInvariant()
    if ($text -match '千兆赫|吉赫') {
        return "ghz"
    }
    if ($text -match '兆赫') {
        return "mhz"
    }
    if ($text -match '千赫') {
        return "khz"
    }
    if ($text -match '(\[|\()\s*(ghz|mhz|khz|hz)\s*(\]|\))') {
        return $Matches[2]
    }
    if ($text -match '(\[|\()\s*(kw|mw|uw|w|watt)\s*(\]|\))') {
        return $(if ($Matches[2] -eq "watt") { "w" } else { $Matches[2] })
    }
    if ($text -match '(\[|\()\s*(kv|v|mv|uv)\s*(\]|\))') {
        return $Matches[2]
    }
    if ($text -match '千瓦') {
        return "kw"
    }
    if ($text -match '毫瓦') {
        return "mw"
    }
    if ($text -match '瓦') {
        return "w"
    }
    if ($text -match '(\[|\()\s*°?\s*f\s*(\]|\))' -or $text -match '华氏') {
        return "f"
    }
    if ($text -match '(\[|\()\s*°?\s*k\s*(\]|\))' -or $text -match '开尔文') {
        return "k"
    }
    if ($text -match '(\[|\()\s*(°?c|℃)\s*(\]|\))' -or $text -match '℃') {
        return "c"
    }
    if ($text -match '\brpm\b|转/分') {
        return "rpm"
    }
    if ($text -match '(\[|\()\s*%\s*(\]|\))') {
        return "percent"
    }
    if ($text -match '(\[|\()\s*ms\s*(\]|\))') {
        return "ms"
    }
    if ($text -match '(\[|\()\s*fps\s*(\]|\))') {
        return "fps"
    }
    return $null
}

function Get-TrailingQualifier {
    param([string]$Column)

    $text = ([string]$Column).Trim().ToLowerInvariant()
    $match = [regex]::Match($text, '(?:\[|\()\s*([^\[\]\(\)]{1,32})\s*(?:\]|\))\s*$')
    if (-not $match.Success) {
        return $null
    }
    return $match.Groups[1].Value.Trim()
}

function Test-QualifierLooksLikeUnit {
    param([string]$Qualifier)

    if ([string]::IsNullOrWhiteSpace($Qualifier)) {
        return $false
    }
    if ($Qualifier -match '^(avg|average|current|instant|instantaneous|min|minimum|max|maximum|peak|limit|target|requested|set|effective|core|memory|gpu|cpu|sensor|value|nvidia|amd|intel|primary|secondary|discrete|integrated)(?:\s+\d+)?$') {
        return $false
    }
    if ($Qualifier -match '^(gpu|cpu|device|sensor)\s*\d+$') {
        return $false
    }
    return $true
}

function Test-ColumnUnitCompatible {
    param(
        [string]$Column,
        [string]$ExpectedUnit
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedUnit)) {
        return $true
    }
    $actualUnit = Get-ColumnUnit -Column $Column
    if ([string]::IsNullOrWhiteSpace($actualUnit)) {
        $qualifier = Get-TrailingQualifier -Column $Column
        if (Test-QualifierLooksLikeUnit -Qualifier $qualifier) {
            return $false
        }
        return $true
    }
    switch ($ExpectedUnit.ToLowerInvariant()) {
        "mhz" { return $actualUnit -in @("mhz", "ghz", "khz", "hz") }
        "w" { return $actualUnit -in @("w", "kw", "mw", "uw") }
        "v" { return $actualUnit -in @("v", "kv", "mv", "uv") }
        "c" { return $actualUnit -in @("c", "f", "k") }
        "rpm" { return $actualUnit -eq "rpm" }
        "percent" { return $actualUnit -eq "percent" }
        "ms" { return $actualUnit -eq "ms" }
        default { return $actualUnit -eq $ExpectedUnit.ToLowerInvariant() }
    }
}

function Convert-MetricValue {
    param(
        [object]$Value,
        [string]$Column,
        [string]$ExpectedUnit
    )

    $number = ConvertTo-Number -Value $Value
    if ($null -eq $number) {
        return $null
    }
    $actualUnit = Get-ColumnUnit -Column $Column
    if ([string]::IsNullOrWhiteSpace($ExpectedUnit) -or [string]::IsNullOrWhiteSpace($actualUnit)) {
        return $number
    }
    switch ($ExpectedUnit.ToLowerInvariant()) {
        "mhz" {
            if ($actualUnit -eq "ghz") { return $number * 1000.0 }
            if ($actualUnit -eq "khz") { return $number / 1000.0 }
            if ($actualUnit -eq "hz") { return $number / 1000000.0 }
            return $number
        }
        "w" {
            if ($actualUnit -eq "kw") { return $number * 1000.0 }
            if ($actualUnit -eq "mw") { return $number / 1000.0 }
            if ($actualUnit -eq "uw") { return $number / 1000000.0 }
            return $number
        }
        "v" {
            if ($actualUnit -eq "kv") { return $number * 1000.0 }
            if ($actualUnit -eq "mv") { return $number / 1000.0 }
            if ($actualUnit -eq "uv") { return $number / 1000000.0 }
            return $number
        }
        "c" {
            if ($actualUnit -eq "f") { return ($number - 32.0) * (5.0 / 9.0) }
            if ($actualUnit -eq "k") { return $number - 273.15 }
            return $number
        }
        default { return $number }
    }
}

function Test-MetricValuePlausible {
    param(
        [string]$MetricLabel,
        [double]$Value
    )

    if (-not (Test-FiniteNumber -Value $Value)) {
        return $false
    }

    switch -Regex ($MetricLabel) {
        "^Frame time" {
            return $Value -gt 0 -and $Value -le 600000
        }
        "^FPS" {
            return $Value -ge 0 -and $Value -le 100000
        }
        "clock" {
            return $Value -ge 0 -and $Value -le 10000
        }
        "power" {
            return $Value -ge 0 -and $Value -le 5000
        }
        "temperature|hotspot|junction" {
            return $Value -ge -100 -and $Value -le 250
        }
        "^GPU core voltage \(V\)$" {
            return $Value -ge 0 -and $Value -le 5
        }
        "fan \(RPM\)" {
            return $Value -ge 0 -and $Value -le 20000
        }
        "fan \(%\)" {
            return $Value -ge 0 -and $Value -le 100
        }
        default {
            return $true
        }
    }
}

function ConvertTo-TimeSeconds {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    $clockMatch = [regex]::Match($text, "^(\d{1,3}):(\d{1,2}):(\d{1,2})(?:[\.,](\d+))?$")
    if ($clockMatch.Success) {
        $fraction = 0.0
        if ($clockMatch.Groups[4].Success) {
            $fraction = [double]::Parse("0.$($clockMatch.Groups[4].Value)", $invariant)
        }
        return ([int]$clockMatch.Groups[1].Value * 3600.0) +
            ([int]$clockMatch.Groups[2].Value * 60.0) +
            [int]$clockMatch.Groups[3].Value +
            $fraction
    }

    $timeSpan = [timespan]::Zero
    if ([timespan]::TryParse($text, [System.Globalization.CultureInfo]::CurrentCulture, [ref]$timeSpan) -or
        [timespan]::TryParse($text, $invariant, [ref]$timeSpan)) {
        return $timeSpan.TotalSeconds
    }

    return $null
}

function Get-CsvFields {
    param([string]$Line)

    $reader = $null
    $parser = $null
    try {
        $reader = New-Object System.IO.StringReader($Line)
        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($reader)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters([string[]]@($Delimiter))
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        return @($parser.ReadFields() | ForEach-Object { ([string]$_).Trim() })
    }
    catch {
        return @()
    }
    finally {
        if ($null -ne $parser) {
            $parser.Dispose()
        }
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }
}

function Test-HeaderCandidateHasData {
    param(
        [string[]]$CandidateNames,
        [string[]]$Lines,
        [int]$HeaderIndex
    )

    $timeColumns = @{}
    for ($index = 0; $index -lt $CandidateNames.Count; $index++) {
        if ($CandidateNames[$index] -match "^(Date|日期|Time|TimeInSeconds|时间)(\s|\[|$)") {
            $timeColumns[$index] = $true
        }
    }

    $lookaheadEnd = [Math]::Min($Lines.Count - 1, $HeaderIndex + 50)
    for ($lineIndex = $HeaderIndex + 1; $lineIndex -le $lookaheadEnd; $lineIndex++) {
        if ([string]::IsNullOrWhiteSpace($Lines[$lineIndex])) {
            continue
        }

        $fields = @(Get-CsvFields -Line $Lines[$lineIndex])
        if ($fields.Count -ne $CandidateNames.Count) {
            continue
        }

        for ($fieldIndex = 0; $fieldIndex -lt $fields.Count; $fieldIndex++) {
            if ($timeColumns.ContainsKey($fieldIndex)) {
                continue
            }
            if ($null -ne (ConvertTo-Number -Value $fields[$fieldIndex])) {
                return $true
            }
        }
    }

    return $false
}

function Find-FirstColumn {
    param(
        [string[]]$Columns,
        [string]$Pattern,
        [string]$ExcludePattern,
        [string]$ExpectedUnit,
        [bool]$RequireUnit = $false
    )

    foreach ($column in $Columns) {
        if ($column -match $Pattern -and
            (-not $ExcludePattern -or $column -notmatch $ExcludePattern) -and
            (Test-ColumnUnitCompatible -Column $column -ExpectedUnit $ExpectedUnit) -and
            (-not $RequireUnit -or -not [string]::IsNullOrWhiteSpace((Get-ColumnUnit -Column $column)))) {
            return $column
        }
    }

    return $null
}

function Find-FirstColumnByPriority {
    param(
        [string[]]$Columns,
        [string[]]$Patterns,
        [string]$ExcludePattern,
        [string]$ExpectedUnit
    )

    foreach ($pattern in $Patterns) {
        foreach ($column in $Columns) {
            if ($column -match $pattern -and
                (-not $ExcludePattern -or $column -notmatch $ExcludePattern) -and
                (Test-ColumnUnitCompatible -Column $column -ExpectedUnit $ExpectedUnit)) {
                return $column
            }
        }
    }

    return $null
}

function Find-FirstUnitlessColumn {
    param(
        [string[]]$Columns,
        [string]$Pattern,
        [string]$ExcludePattern
    )

    foreach ($column in $Columns) {
        if ($column -match $Pattern -and
            (-not $ExcludePattern -or $column -notmatch $ExcludePattern) -and
            [string]::IsNullOrWhiteSpace((Get-ColumnUnit -Column $column))) {
            return $column
        }
    }

    return $null
}

function Get-NumericColumnValues {
    param(
        [object[]]$Rows,
        [string]$Column,
        [string]$ExpectedUnit
    )

    $values = New-Object System.Collections.Generic.List[double]
    foreach ($row in $Rows) {
        $property = $row.PSObject.Properties[$Column]
        if ($null -eq $property) {
            continue
        }
        $number = if ([string]::IsNullOrWhiteSpace($ExpectedUnit)) {
            ConvertTo-Number -Value $property.Value
        }
        else {
            Convert-MetricValue -Value $property.Value -Column $Column -ExpectedUnit $ExpectedUnit
        }
        if ($null -ne $number) {
            $values.Add([double]$number) | Out-Null
        }
    }
    return [double[]]$values.ToArray()
}

function Get-Percentile {
    param(
        [double[]]$SortedValues,
        [double]$Percentile
    )

    if ($SortedValues.Count -eq 0) {
        return $null
    }

    $position = [Math]::Floor(($SortedValues.Count - 1) * $Percentile)
    return $SortedValues[[int]$position]
}

function Get-SeriesStatistics {
    param(
        [string]$Label,
        [string]$Column,
        [double[]]$Values
    )

    if ($Values.Count -eq 0) {
        return $null
    }

    $sorted = @($Values | Sort-Object)
    $sum = 0.0
    foreach ($value in $sorted) {
        $sum += $value
    }
    $mean = $sum / $sorted.Count
    $p1 = Get-Percentile -SortedValues $sorted -Percentile 0.01
    $p5 = Get-Percentile -SortedValues $sorted -Percentile 0.05
    $median = Get-Percentile -SortedValues $sorted -Percentile 0.50
    $p95 = Get-Percentile -SortedValues $sorted -Percentile 0.95
    foreach ($resultValue in @($sum, $mean, $p1, $p5, $median, $p95, $sorted[0], $sorted[$sorted.Count - 1])) {
        if (-not (Test-FiniteNumber -Value ([double]$resultValue))) {
            $warnings.Add("Metric '$Label' produced a non-finite statistic and was omitted.")
            return $null
        }
    }

    return [pscustomobject]@{
        Metric = $Label
        SourceColumn = $Column
        Samples = $sorted.Count
        Min = $sorted[0]
        Mean = $mean
        P1 = $p1
        P5 = $p5
        Median = $median
        P95 = $p95
        Max = $sorted[$sorted.Count - 1]
    }
}

function Format-Number {
    param([double]$Value)
    return $Value.ToString("0.###", $invariant)
}

function ConvertTo-MarkdownCell {
    param([object]$Value)

    $text = [string]$Value
    $text = $text -replace "\p{Cc}", " "
    $text = $text -replace "\p{Cf}", ""
    $text = $text -replace "[\uFE00-\uFE0F]", ""
    $text = $text -replace "\p{Zl}|\p{Zp}", " "
    $text = $text -replace "\s+", " "
    $text = $text.Trim()
    $text = $text.Replace("|", "\|")

    $backtickRuns = [regex]::Matches($text, '`+')
    $longestBacktickRun = if ($backtickRuns.Count -gt 0) {
        ($backtickRuns | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    }
    else {
        0
    }
    $fence = ([string][char]0x60) * ($longestBacktickRun + 1)
    return "$fence $text $fence"
}

function Test-MojibakeText {
    param([object]$Value)

    if ($null -eq $Value) {
        return $false
    }
    $text = [string]$Value
    return $text.IndexOf([char]0xFFFD) -ge 0 -or
        $text -match "Ã.|Â.|â€|ðŸ|锟斤拷|烫烫烫|屯屯屯|鏃ユ湡|鏃堕棿|娓╁|鍔熺"
}

function Read-TelemetryLines {
    param(
        [string]$FilePath,
        [int64]$MaximumBytes
    )

    $invalidUtf8 = $false
    $stream = [System.IO.File]::Open(
        $FilePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite
    )
    try {
        if ($stream.Length -gt $MaximumBytes) {
            Stop-WithInputError "Telemetry file grew above the $($MaximumBytes / 1MB) MB safety limit before it could be read. Provide a smaller fixed-window extract or explicitly raise -MaxInputMegabytes after reviewing memory limits."
        }
        $bytes = New-Object byte[] $stream.Length
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) {
                break
            }
            $offset += $read
        }
    }
    finally {
        $stream.Dispose()
    }

    if ($offset -lt $bytes.Length) {
        $bytes = @($bytes[0..($offset - 1)])
    }

    $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    try {
        $text = $strictUtf8.GetString([byte[]]$bytes)
    }
    catch [System.Text.DecoderFallbackException] {
        $invalidUtf8 = $true
        # A live HWiNFO log can end with a partially written UTF-8 character.
        $lastNewline = [Array]::LastIndexOf($bytes, [byte]10)
        if ($lastNewline -ge 0) {
            try {
                $text = $strictUtf8.GetString([byte[]]$bytes[0..$lastNewline])
            }
            catch {
                $text = (New-Object System.Text.UTF8Encoding($false, $false)).GetString([byte[]]$bytes)
            }
        }
        else {
            $text = (New-Object System.Text.UTF8Encoding($false, $false)).GetString([byte[]]$bytes)
        }
    }

    $text = $text.TrimStart([char]0xFEFF)
    return [pscustomobject]@{
        Lines = @($text -split "\r?\n")
        InvalidUtf8 = $invalidUtf8
    }
}

try {
    $resolvedPath = Assert-LocalReadFilePath -Path $Path
}
catch {
    Stop-WithInputError $_.Exception.Message
}
$inputItem = Get-Item -LiteralPath $resolvedPath -Force
if (($inputItem.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0) {
    Stop-WithInputError "Telemetry input is an offline or cloud-placeholder file. Open or download it locally first; the analyzer will not trigger hydration."
}
$fileBytes = $inputItem.Length
$maximumBytes = [int64]$MaxInputMegabytes * 1MB
if ($fileBytes -gt $maximumBytes) {
    Stop-WithInputError "Telemetry file is $([math]::Round($fileBytes / 1MB, 1)) MB, above the $MaxInputMegabytes MB safety limit. Provide a smaller fixed-window extract or explicitly raise -MaxInputMegabytes after reviewing memory limits."
}

$readResult = Read-TelemetryLines -FilePath $resolvedPath -MaximumBytes $maximumBytes
$lines = @($readResult.Lines)
if ($lines.Count -lt 2) {
    Stop-WithInputError "Telemetry file is empty or too short: $resolvedPath"
}
$encodingSuspicion = $false
$encodingLookahead = [Math]::Min($lines.Count, 200)
for ($encodingIndex = 0; $encodingIndex -lt $encodingLookahead; $encodingIndex++) {
    if (Test-MojibakeText -Value $lines[$encodingIndex]) {
        $encodingSuspicion = $true
        break
    }
}
if ($encodingSuspicion) {
    $warnings.Add(
        "Possible text-encoding corruption or mojibake was detected; no sensor names were automatically corrected. Re-export the log using UTF-8 with the intended locale.")
}

$headerTokens = @(
    "date", "time", "fps", "frame", "clock", "mhz", "temp", "temperature",
    "power", "watt", "fan", "load", "util", "junction", "hotspot", "voltage",
    "processid", "msbetweenpresents",
    "日期", "时间", "帧率", "帧时间", "频率", "温度", "功耗", "功率", "风扇",
    "负载", "占用", "热点", "结温", "电压", "内存"
)

$headerLineIndex = -1
$headerNames = @()
$rawHeaderNames = @()
$duplicateHeaderNames = New-Object System.Collections.Generic.List[string]
$bestScore = 0

for ($index = 0; $index -lt [Math]::Min($lines.Count, 200); $index++) {
    if ([string]::IsNullOrWhiteSpace($lines[$index])) {
        continue
    }

    $candidateNames = @(Get-CsvFields -Line $lines[$index])
    if ($candidateNames.Count -lt 2) {
        continue
    }

    $joined = $candidateNames -join " "
    $score = 0
    foreach ($token in $headerTokens) {
        if ($joined -match [regex]::Escape($token)) {
            $score++
        }
    }

    if (
        $score -ge 2 -and
        $score -gt $bestScore -and
        (Test-HeaderCandidateHasData -CandidateNames $candidateNames -Lines $lines -HeaderIndex $index)
    ) {
        $bestScore = $score
        $headerLineIndex = $index
        $rawHeaderNames = $candidateNames
    }
}

if ($headerLineIndex -lt 0 -or $rawHeaderNames.Count -lt 2) {
    $encodingHint = if ($encodingSuspicion) {
        " Possible text-encoding corruption or mojibake was detected; re-export the log using UTF-8 with the intended locale."
    }
    else {
        ""
    }
    throw "Could not identify a telemetry header row with recognizable numeric sensor columns.$encodingHint"
}

$seenHeaders = @{}
$normalizedHeaders = New-Object System.Collections.Generic.List[string]
for ($index = 0; $index -lt $rawHeaderNames.Count; $index++) {
    $baseName = ([string]$rawHeaderNames[$index]).Trim()
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = "Column$($index + 1)"
    }

    if ($seenHeaders.ContainsKey($baseName)) {
        $seenHeaders[$baseName]++
        $normalizedHeaders.Add("$baseName [#$($seenHeaders[$baseName])]") | Out-Null
        if (-not $duplicateHeaderNames.Contains($baseName)) {
            $duplicateHeaderNames.Add($baseName) | Out-Null
        }
    }
    else {
        $seenHeaders[$baseName] = 1
        $normalizedHeaders.Add($baseName) | Out-Null
    }
}

$headerNames = @($normalizedHeaders.ToArray())
if ($duplicateHeaderNames.Count -gt 0) {
    $warnings.Add("$($duplicateHeaderNames.Count) duplicate HWiNFO header names were normalized with [#N] suffixes.")
}

$dataLines = New-Object System.Collections.Generic.List[string]
$stoppedAtFooter = $false
$invalidDataRows = 0
$firstInvalidDataLine = $null
if ($headerLineIndex + 1 -lt $lines.Count) {
    for ($index = $headerLineIndex + 1; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($dataLines.Count -gt 0) {
                $hasLaterContent = $false
                for ($lookahead = $index + 1; $lookahead -lt $lines.Count; $lookahead++) {
                    if (-not [string]::IsNullOrWhiteSpace($lines[$lookahead])) {
                        $hasLaterContent = $true
                        break
                    }
                }
                if ($hasLaterContent) {
                    $stoppedAtFooter = $true
                    break
                }
            }
            continue
        }

        $fields = @(Get-CsvFields -Line $line)
        if ($fields.Count -ge 2 -and $fields[0] -match "^(Date|日期)$" -and $fields[1] -match "^(Time|时间)") {
            $stoppedAtFooter = $true
            break
        }

        if ($fields.Count -ne $headerNames.Count) {
            $invalidDataRows++
            if ($null -eq $firstInvalidDataLine) {
                $firstInvalidDataLine = $index + 1
            }
            continue
        }

        $dataLines.Add($line) | Out-Null
    }
}

if ($dataLines.Count -eq 0) {
    throw "No telemetry rows were found after the header."
}
if ($stoppedAtFooter) {
    $warnings.Add("Data extraction stopped before a repeated Date/Time header or blank separator; appended metadata was ignored.")
}
if ($invalidDataRows -gt 0) {
    $warnings.Add(
        "$invalidDataRows data row(s) were skipped because their field count did not match the header; first bad row was line $firstInvalidDataLine.")
}
if ($readResult.InvalidUtf8) {
    if ($stoppedAtFooter) {
        $warnings.Add("The CSV contains invalid UTF-8 bytes; HWiNFO footer bytes were excluded from analysis, but parsed rows with replacement characters should be treated with caution.")
    }
    else {
        $warnings.Add("The CSV contains invalid UTF-8 bytes, possibly because it is still being written. Stop logging before formal analysis.")
    }
}

$rows = @($dataLines.ToArray() | ConvertFrom-Csv -Delimiter $Delimiter -Header $headerNames)

$dateColumn = Find-FirstColumn -Columns $headerNames -Pattern "^(Date|日期)(\s|\[|$)"
$timeColumn = Find-FirstColumn -Columns $headerNames -Pattern "^(Time|TimeInSeconds|时间)(\s|\[|$)"
$dateColumnIndex = if ($dateColumn) { [Array]::IndexOf($headerNames, $dateColumn) } else { -1 }
$timeColumnIndex = if ($timeColumn) { [Array]::IndexOf($headerNames, $timeColumn) } else { -1 }
Write-Verbose "Time column '$timeColumn' at index $timeColumnIndex; date column '$dateColumn' at index $dateColumnIndex."

$timeOffsets = New-Object System.Collections.Generic.List[double]
$invalidTimeIndexes = New-Object System.Collections.Generic.List[int]
$parsedTimeCount = 0
$firstDateTime = $null
$usedTimeFallback = $false
$timeOnlyFallbackCount = 0
$dateTimeFormats = @(
    "d.M.yyyy H:m:s.fff",
    "d.M.yyyy H:m:s",
    "yyyy-M-d H:m:s.fff",
    "yyyy-M-d H:m:s",
    "yyyy/M/d H:m:s.fff",
    "yyyy/M/d H:m:s",
    "dd.MM.yyyy HH:mm:ss.fff",
    "dd.MM.yyyy HH:mm:ss",
    "yyyy-MM-dd HH:mm:ss.fff",
    "yyyy-MM-dd HH:mm:ss",
    "yyyy/MM/dd HH:mm:ss.fff",
    "yyyy/MM/dd HH:mm:ss"
)

for ($index = 0; $index -lt $rows.Count; $index++) {
    $row = $rows[$index]
    $rawFields = @(Get-CsvFields -Line $dataLines[$index])
    if ($index -eq 0) {
        Write-Verbose "First time cell: '$($rawFields[$timeColumnIndex])'."
    }
    $parsed = $null

    if ($timeColumn -and $timeColumn -match "Seconds") {
        $secondsValue = ConvertTo-Number -Value $rawFields[$timeColumnIndex]
        if ($null -ne $secondsValue) {
            $timeOffsets.Add([double]$secondsValue)
            $parsedTimeCount++
        }
        else {
            $timeOffsets.Add([double]::NaN)
        }
        continue
    }

    if ($dateColumn -and $timeColumn) {
        $combined = "$($rawFields[$dateColumnIndex]) $($rawFields[$timeColumnIndex])".Trim()
        $dateTime = [datetime]::MinValue
        foreach ($dateTimeFormat in $dateTimeFormats) {
            try {
                $dateTime = [datetime]::ParseExact(
                    $combined,
                    $dateTimeFormat,
                    $invariant,
                    [System.Globalization.DateTimeStyles]::AllowWhiteSpaces
                )
                $parsed = $dateTime
                break
            }
            catch [System.FormatException] {
            }
        }
        if ($null -eq $parsed -and (
            [datetime]::TryParse($combined, [System.Globalization.CultureInfo]::CurrentCulture, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$dateTime) -or
            [datetime]::TryParse($combined, $invariant, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$dateTime))) {
            $parsed = $dateTime
        }
    }

    if ($null -eq $parsed -and $timeColumn) {
        $secondsValue = ConvertTo-TimeSeconds -Value $rawFields[$timeColumnIndex]
        if ($null -ne $secondsValue) {
            $parsed = [datetime]::Today.AddSeconds([double]$secondsValue)
            if ($dateColumn) {
                $timeOnlyFallbackCount++
            }
        }
    }

    if ($null -eq $parsed) {
        $timeOffsets.Add([double]::NaN)
        if ($timeColumn) {
            $invalidTimeIndexes.Add($index) | Out-Null
        }
    }
    else {
        if ($null -eq $firstDateTime) {
            $firstDateTime = $parsed
        }
        $timeOffsets.Add(($parsed - $firstDateTime).TotalSeconds)
        $parsedTimeCount++
    }
}

if ($timeOnlyFallbackCount -gt 0) {
    $warnings.Add("$timeOnlyFallbackCount rows used time-only parsing because Date+Time parsing failed; verify that the run does not cross midnight.")
}
if ($invalidTimeIndexes.Count -gt 0 -and $parsedTimeCount -gt 0) {
    $invalidRowLabel = if ($invalidTimeIndexes.Count -eq 1) { "1 row has" } else { "$($invalidTimeIndexes.Count) rows have" }
    $warnings.Add(
        "$invalidRowLabel no parseable timestamp; time-window boundaries use valid timestamps only.")
}

if ($parsedTimeCount -eq 0) {
    $timeOffsets.Clear()
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $timeOffsets.Add([double]$index)
    }
    $usedTimeFallback = $true
    $timeWarning = if ($timeColumn) {
        "No parseable timestamp values were found; row-based warmup/limit fallback is used."
    }
    else {
        "No time column was found; row-based warmup/limit fallback is used."
    }
    $warnings.Add($timeWarning)
}

if ($parsedTimeCount -gt 0) {
    $previousValidTime = $null
    for ($index = 0; $index -lt $timeOffsets.Count; $index++) {
        if ([double]::IsNaN($timeOffsets[$index])) {
            continue
        }
        if ($null -ne $previousValidTime -and $timeOffsets[$index] + 0.001 -lt $previousValidTime) {
            throw ("Telemetry timestamps move backwards at row {0}: {1:0.###}s followed by {2:0.###}s." -f ($index + 2), $previousValidTime, $timeOffsets[$index])
        }
        $previousValidTime = $timeOffsets[$index]
    }
}

$startIndex = 0
$endIndex = $rows.Count - 1
$requestedWindowLabel = $null

if ($usesTimeWindow) {
    if ($parsedTimeCount -eq 0) {
        throw "WarmupSeconds/DurationSeconds require a parseable time column. Use WarmupRows/MaxRows explicitly for row-based windows."
    }
    else {
        $firstValidTime = $null
        for ($index = 0; $index -lt $timeOffsets.Count; $index++) {
            if (-not [double]::IsNaN($timeOffsets[$index])) {
                $firstValidTime = $timeOffsets[$index]
                break
            }
        }

        if ($null -ne $firstValidTime) {
            $windowStart = $firstValidTime + $WarmupSeconds
            $lastValidTime = $null
            for ($index = $timeOffsets.Count - 1; $index -ge 0; $index--) {
                if (-not [double]::IsNaN($timeOffsets[$index])) {
                    $lastValidTime = $timeOffsets[$index]
                    break
                }
            }
            if ($null -eq $lastValidTime -or $windowStart -gt $lastValidTime) {
                throw ("WarmupSeconds {0} exceeds the available telemetry duration {1:0.###}s." -f $WarmupSeconds, $lastValidTime)
            }

            $startIndex = -1
            for ($index = 0; $index -lt $timeOffsets.Count; $index++) {
                if (-not [double]::IsNaN($timeOffsets[$index]) -and $timeOffsets[$index] -ge $windowStart) {
                    $startIndex = $index
                    break
                }
            }
            if ($startIndex -lt 0) {
                throw "No telemetry row exists at or after the requested warm-up boundary."
            }

            $windowEnd = $lastValidTime
            if ($DurationSeconds -gt 0) {
                $windowEnd = $windowStart + $DurationSeconds
                $requestedWindowLabel = "time {0:0.###}s to {1:0.###}s" -f $windowStart, $windowEnd
                if ($windowEnd -lt $windowStart) {
                    throw "The requested telemetry window ends before it starts."
                }
                if ($windowEnd -gt $lastValidTime + 0.001) {
                    throw (
                        "DurationSeconds {0} exceeds the available telemetry from the requested start: requested {1:0.###}s, available {2:0.###}s." -f
                        $DurationSeconds, $windowEnd, $lastValidTime)
                }
            }
            else {
                $requestedWindowLabel = "time {0:0.###}s to end" -f $windowStart
            }

            $endIndex = $rows.Count - 1
            for ($index = $startIndex; $index -lt $timeOffsets.Count; $index++) {
                if (-not [double]::IsNaN($timeOffsets[$index]) -and $timeOffsets[$index] -gt $windowEnd + 0.001) {
                    $endIndex = $index - 1
                    break
                }
            }
        }
    }
}
else {
        if ($WarmupRows -gt 0) {
        if ($WarmupRows -ge $rows.Count) {
            throw ("WarmupRows {0} leaves no data rows in a {1}-row file." -f $WarmupRows, $rows.Count)
        }
        $startIndex = $WarmupRows
    }
    if ($MaxRows -gt 0) {
        $endIndex = [Math]::Min($startIndex + $MaxRows - 1, $rows.Count - 1)
    }
}

if ($endIndex -lt $startIndex) {
    throw "The selected telemetry window contains no rows."
}
if ($usesTimeWindow) {
    $invalidRowsInWindow = @(
        $invalidTimeIndexes |
            Where-Object { $_ -ge $startIndex -and $_ -le $endIndex }
    )
    if ($invalidRowsInWindow.Count -gt 0) {
        throw (
            "The selected telemetry window contains {0} row(s) without a parseable timestamp." -f
            $invalidRowsInWindow.Count)
    }
}

$selectedRows = @($rows[$startIndex..$endIndex])

$fpsPatterns = @(
    "^呈现帧率 \(avg\)",
    "^显示帧率 \(avg\)",
    "^帧率 Presented \(avg\)",
    "^FPS Presented \(avg\)",
    "^Frames Per Second Presented \(avg\)",
    "^(FPS|Frame Rate|Frames Per Second|帧率)(?:\s|\[|$)"
)
$fpsColumn = Find-FirstColumnByPriority `
    -Columns $headerNames `
    -Patterns $fpsPatterns `
    -ExcludePattern "Limit|Cap|Target|Maximum|Max|限制|上限|目标"
Write-Verbose "Preferred FPS column: '$fpsColumn'."

$specs = @(
    [pscustomobject]@{ Metric = "Frame time (ms)"; Pattern = "msBetweenPresents|Frame Time|Frametime"; Exclude = "Limit|Cap|Target|Maximum|Max|限制|上限|目标"; Unit = "ms" },
    [pscustomobject]@{ Metric = "GPU effective clock (MHz)"; Pattern = "GPU (Core )?Effective Clock|GPU 有效频率"; Exclude = "CPU|Requested|Limit|Target|Set|请求|限制|目标"; Unit = "MHz" },
    [pscustomobject]@{ Metric = "GPU core clock (MHz)"; Pattern = "GPU Core Clock|GPU Clock|Graphics Clock|GPU 频率"; Exclude = "Memory|Effective|Requested|Limit|Target|Maximum|Max|Set|显存|视频|Crossbar|有效|限制|目标|请求"; Unit = "MHz" },
    [pscustomobject]@{ Metric = "GPU core voltage (V)"; Pattern = "GPU (Core )?Voltage|GPU Vcore|GPU Core VID|GPU 核心电压|GPU 电压"; Exclude = "Memory|MVDD|SOC|Requested|Limit|Target|Maximum|Max|显存|限制|目标|请求"; Unit = "V"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "GPU memory clock (MHz)"; Pattern = "GPU Memory Clock|GPU 显存频率|显存频率"; Exclude = "Limit|Target|Maximum|Max|Requested|限制|目标|请求"; Unit = "MHz" },
    [pscustomobject]@{ Metric = "GPU power (W)"; Pattern = "GPU Power|Board Power|Total Board Power|GPU 功率"; Exclude = "Limit|%|限制"; Unit = "W" },
    [pscustomobject]@{ Metric = "GPU temperature (C)"; Pattern = "GPU Temperature|GPU Temp|GPU 温度"; Exclude = "Memory|Hot Spot|Junction|Limit|显存|热点|限制"; Unit = "C" },
    [pscustomobject]@{ Metric = "GPU hotspot (C)"; Pattern = "GPU Hot ?Spot|GPU 热点温度"; Exclude = "Limit|Target|Maximum|Max|限制|目标"; Unit = "C" },
    [pscustomobject]@{ Metric = "GPU memory junction (C)"; Pattern = "GPU Memory Junction|显存结温|显存温度"; Exclude = "Limit|Target|Maximum|Max|限制|目标"; Unit = "C" },
    [pscustomobject]@{ Metric = "GPU fan (RPM)"; Pattern = "GPU Fan.*RPM|GPU 风扇.*RPM|GPU Fan"; Exclude = "System|Case|Chassis|CPU|Pump|Motherboard|VRM|机箱|系统|泵"; Unit = "RPM"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "GPU fan (%)"; Pattern = "GPU Fan.*%|GPU 风扇.*%|GPU Fan"; Exclude = "System|Case|Chassis|CPU|Pump|Motherboard|VRM|机箱|系统|泵"; Unit = "percent"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "CPU core maximum temperature (C)"; Pattern = "CPU Core Max(imum)?|CPU 核心.*(最高|最大)|核心最高温度"; Exclude = "Clock|Voltage|Power|Watt|Distance|Limit|Target|频率|电压|功率|功耗|距离|限制|目标"; Unit = "C"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "CPU Tctl/Tdie temperature (C)"; Pattern = "CPU .*Tctl|CPU .*Tdie|Tctl/Tdie"; Exclude = "Clock|Voltage|Power|Watt|PPT|Offset|Limit|Target|偏移|距离|限制|目标"; Unit = "C"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "CPU die average temperature (C)"; Pattern = "CPU Die \(average\)|CPU 平均温度|CPU平均温度"; Exclude = "Offset|Limit|Target|Distance|偏移|限制|目标|距离"; Unit = "C"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "CPU package temperature (C)"; Pattern = "CPU Package|CPU Temp|CPU 封装"; Exclude = "Core|Distance|Power|Watt|Limit|Target|Maximum|Max|功率|功耗|限制|目标|\[W\]|\(W\)"; Unit = "C"; RequireUnit = $true },
    [pscustomobject]@{ Metric = "CPU package power (W)"; Pattern = "CPU Package|CPU PPT|CPU 封装"; Exclude = "Limit|%|限制|Temperature|Temp|温度|\[C\]|\(C\)|℃"; Unit = "W"; RequireUnit = $true }
)

$supplementalSpecs = @(
    [pscustomobject]@{
        Metric = "Presented FPS 1% low (FPS)"
        Patterns = @(
            "^呈现帧率 \(1% low\)",
            "^FPS Presented \(1% low\)",
            "^Frames Per Second Presented \(1% low\)"
        )
        Unit = "FPS"
    },
    [pscustomobject]@{
        Metric = "Presented FPS 0.1% low (FPS)"
        Patterns = @(
            "^呈现帧率 \(0\.1% low\)",
            "^FPS Presented \(0\.1% low\)",
            "^Frames Per Second Presented \(0\.1% low\)"
        )
        Unit = "FPS"
    },
    [pscustomobject]@{
        Metric = "Displayed FPS 1% low (FPS)"
        Patterns = @(
            "^显示帧率 \(1% low\)",
            "^FPS Displayed \(1% low\)",
            "^Frames Per Second Displayed \(1% low\)"
        )
        Unit = "FPS"
    },
    [pscustomobject]@{
        Metric = "Displayed FPS 0.1% low (FPS)"
        Patterns = @(
            "^显示帧率 \(0\.1% low\)",
            "^FPS Displayed \(0\.1% low\)",
            "^Frames Per Second Displayed \(0\.1% low\)"
        )
        Unit = "FPS"
    },
    [pscustomobject]@{
        Metric = "Presented frame time 99% high (ms)"
        Patterns = @(
            "^Frame Time Presented \(99%\)",
            "^Presented Frame Time.*\(99%\)"
        )
        Unit = "ms"
    },
    [pscustomobject]@{
        Metric = "Presented frame time fastest 1% (ms)"
        Patterns = @(
            "^Frame Time Presented \(1%\)",
            "^Presented Frame Time.*\(1%\)"
        )
        Unit = "ms"
    },
    [pscustomobject]@{
        Metric = "Presented frame time fastest 0.1% (ms)"
        Patterns = @(
            "^Frame Time Presented \(0\.1%\)",
            "^Presented Frame Time.*\(0\.1%\)"
        )
        Unit = "ms"
    },
    [pscustomobject]@{
        Metric = "Displayed frame time 1% high (ms)"
        Patterns = @(
            "^Frame Time Displayed \(1% high\)",
            "^Displayed Frame Time.*\(1% high\)"
        )
        Unit = "ms"
    },
    [pscustomobject]@{
        Metric = "Displayed frame time 0.1% high (ms)"
        Patterns = @(
            "^Frame Time Displayed \(0\.1% high\)",
            "^Displayed Frame Time.*\(0\.1% high\)"
        )
        Unit = "ms"
    }
)

$series = New-Object System.Collections.Generic.List[object]
$usedColumns = New-Object System.Collections.Generic.HashSet[string]
$invalidMetricCounts = @{}
$ambiguousUnitlessColumns = @{}

if ($fpsColumn) {
    $values = New-Object System.Collections.Generic.List[double]
    foreach ($row in $selectedRows) {
        $property = $row.PSObject.Properties[$fpsColumn]
        if ($null -ne $property) {
            $number = ConvertTo-Number -Value $property.Value
            if ($null -ne $number) {
                if (Test-MetricValuePlausible -MetricLabel "FPS" -Value ([double]$number)) {
                    $values.Add([double]$number)
                }
                else {
                    $invalidMetricCounts["FPS"] = 1 + [int]$invalidMetricCounts["FPS"]
                }
            }
        }
    }

    $statistics = Get-SeriesStatistics -Label "FPS" -Column $fpsColumn -Values @($values)
    if ($null -ne $statistics) {
        $series.Add($statistics) | Out-Null
        $usedColumns.Add($fpsColumn) | Out-Null
    }
}

foreach ($spec in $specs) {
    $requireUnit = [bool]($spec.PSObject.Properties["RequireUnit"] -and $spec.RequireUnit)
    $column = Find-FirstColumn `
        -Columns $headerNames `
        -Pattern $spec.Pattern `
        -ExcludePattern $spec.Exclude `
        -ExpectedUnit $spec.Unit `
        -RequireUnit $requireUnit
    Write-Verbose "Metric '$($spec.Metric)' selected column '$column'."
    if (-not $column -or $usedColumns.Contains($column)) {
        if (-not $column) {
            $rejectedCandidates = New-Object System.Collections.Generic.List[string]
            foreach ($candidate in $headerNames) {
                if ($usedColumns.Contains($candidate) -or $candidate -notmatch $spec.Pattern) {
                    continue
                }
                if ($spec.Exclude -and $candidate -match $spec.Exclude) {
                    $rejectedCandidates.Add("'$candidate' (offset/limit/role exclusion)") | Out-Null
                    continue
                }
                $candidateUnit = Get-ColumnUnit -Column $candidate
                if ($requireUnit -and [string]::IsNullOrWhiteSpace($candidateUnit)) {
                    $ambiguousUnitlessColumns[$candidate] = $true
                    continue
                }
                if (-not (Test-ColumnUnitCompatible -Column $candidate -ExpectedUnit $spec.Unit)) {
                    $rejectedCandidates.Add("'$candidate' (unit incompatible with $($spec.Unit))") | Out-Null
                }
            }
            if ($rejectedCandidates.Count -gt 0) {
                $warnings.Add(
                    "No column was selected for '$($spec.Metric)'; rejected matching candidates: $($rejectedCandidates -join ', '). Use -IncludeColumn only when the column role is clear.")
            }
        }
        if (-not $column -and $requireUnit) {
            $unitlessCandidate = Find-FirstUnitlessColumn `
                -Columns $headerNames `
                -Pattern $spec.Pattern `
                -ExcludePattern $spec.Exclude
            if ($unitlessCandidate) {
                $ambiguousUnitlessColumns[$unitlessCandidate] = $true
            }
        }
        continue
    }

    $values = New-Object System.Collections.Generic.List[double]
    foreach ($row in $selectedRows) {
        $property = $row.PSObject.Properties[$column]
        if ($null -ne $property) {
            $number = Convert-MetricValue -Value $property.Value -Column $column -ExpectedUnit $spec.Unit
            if ($null -ne $number) {
                if (Test-MetricValuePlausible -MetricLabel $spec.Metric -Value ([double]$number)) {
                    $values.Add([double]$number)
                }
                else {
                    $invalidMetricCounts[$spec.Metric] = 1 + [int]$invalidMetricCounts[$spec.Metric]
                }
            }
        }
    }

    $statistics = Get-SeriesStatistics -Label $spec.Metric -Column $column -Values @($values)
    if ($null -ne $statistics) {
        $series.Add($statistics) | Out-Null
        $usedColumns.Add($column) | Out-Null
    }
}

foreach ($spec in $supplementalSpecs) {
    $column = Find-FirstColumnByPriority `
        -Columns $headerNames `
        -Patterns $spec.Patterns `
        -ExcludePattern "Limit|Cap|Target|Maximum|Max|限制|上限|目标" `
        -ExpectedUnit $spec.Unit
    if (-not $column -or $usedColumns.Contains($column)) {
        continue
    }

    $values = @(Get-NumericColumnValues -Rows $selectedRows -Column $column -ExpectedUnit $spec.Unit)
    $positiveValues = @($values | Where-Object { $_ -gt 0 })
    if ($values.Count -eq 0) {
        $warnings.Add("Sensor column '$column' is present but has no usable numeric values in the selected window; it was not summarized.")
        continue
    }
    if ($positiveValues.Count -eq 0) {
        $warnings.Add("Sensor column '$column' is present but contains only zero values in the selected window; it was not summarized.")
        continue
    }

    $statistics = Get-SeriesStatistics -Label $spec.Metric -Column $column -Values $values
    if ($null -ne $statistics) {
        $series.Add($statistics) | Out-Null
        $usedColumns.Add($column) | Out-Null
    }
}

foreach ($column in $headerNames) {
    if ($column -notmatch '(?i)(?:1%|0\.1%)\s*(?:低帧率|low).*\[fps\]') {
        continue
    }
    if ($usedColumns.Contains($column)) {
        continue
    }
    $values = @(Get-NumericColumnValues -Rows $selectedRows -Column $column -ExpectedUnit "FPS")
    if ($values.Count -eq 0) {
        $warnings.Add("Low-FPS sensor column '$column' is present but has no usable numeric values in the selected window; it was not summarized.")
    }
    elseif (@($values | Where-Object { $_ -gt 0 }).Count -eq 0) {
        $warnings.Add("Low-FPS sensor column '$column' is present but contains only zero values in the selected window; it was not summarized.")
    }
}

$frameTimeColumn = Find-FirstColumn -Columns $headerNames -Pattern "msBetweenPresents|Frame Time|Frametime" -ExcludePattern "^$" -ExpectedUnit "ms"
if (-not $fpsColumn -and $frameTimeColumn) {
    $derivedFps = New-Object System.Collections.Generic.List[double]
    foreach ($row in $selectedRows) {
        $property = $row.PSObject.Properties[$frameTimeColumn]
        if ($null -ne $property) {
            $frameTime = Convert-MetricValue -Value $property.Value -Column $frameTimeColumn -ExpectedUnit "ms"
                if (
                    $null -ne $frameTime -and
                    (Test-MetricValuePlausible -MetricLabel "Frame time" -Value ([double]$frameTime))
                ) {
                $derivedFps.Add(1000.0 / $frameTime)
            }
        }
    }
    $statistics = Get-SeriesStatistics -Label "FPS derived from frame time" -Column $frameTimeColumn -Values @($derivedFps)
    if ($null -ne $statistics) {
        $series.Insert(0, $statistics)
    }
}

foreach ($pattern in $IncludeColumn) {
    if ([string]::IsNullOrWhiteSpace($pattern)) {
        continue
    }

    foreach ($column in $headerNames) {
        if ($column -notmatch $pattern -or $usedColumns.Contains($column)) {
            continue
        }

        $values = New-Object System.Collections.Generic.List[double]
        foreach ($row in $selectedRows) {
            $property = $row.PSObject.Properties[$column]
            if ($null -ne $property) {
                $number = ConvertTo-Number -Value $property.Value
                if ($null -ne $number) {
                    if (Test-MetricValuePlausible -MetricLabel $column -Value ([double]$number)) {
                        $values.Add([double]$number)
                    }
                    else {
                        $invalidMetricCounts[$column] = 1 + [int]$invalidMetricCounts[$column]
                    }
                }
            }
        }

        $statistics = Get-SeriesStatistics -Label $column -Column $column -Values @($values)
        if ($null -ne $statistics) {
            $series.Add($statistics) | Out-Null
            $usedColumns.Add($column) | Out-Null
        }
    }
}

foreach ($metricName in $invalidMetricCounts.Keys) {
    $warnings.Add(
        "$($invalidMetricCounts[$metricName]) value(s) for '$metricName' were outside the analyzer's plausible range and were ignored.")
}
if ($ambiguousUnitlessColumns.Count -gt 0) {
    $ambiguousNames = @($ambiguousUnitlessColumns.Keys | Sort-Object) -join ", "
    $warnings.Add(
        "Unitless columns with ambiguous measurement roles were ignored: $ambiguousNames. Use -IncludeColumn to analyze a specific column as a custom numeric series.")
}

if ($series.Count -eq 0) {
    $warnings.Add("No recognized numeric sensor columns could be summarized. Use -IncludeColumn with a column-name pattern.")
}

if (-not $usedTimeFallback -and $timeOffsets.Count -gt 0 -and -not [double]::IsNaN($timeOffsets[$startIndex]) -and -not [double]::IsNaN($timeOffsets[$endIndex])) {
    $windowLabel = "time {0:0.###}s to {1:0.###}s" -f $timeOffsets[$startIndex], $timeOffsets[$endIndex]
}
else {
    $windowLabel = "rows $startIndex to $endIndex (header on line $($headerLineIndex + 1))"
}

$result = [pscustomobject]@{
    AnalyzerVersion = "1.1.6"
    FileName = if ($HideFileName) { "[hidden]" } else { [System.IO.Path]::GetFileName($resolvedPath) }
    HeaderLine = $headerLineIndex + 1
    InvalidRows = $invalidDataRows
    TotalRows = $rows.Count
    AnalyzedRows = $selectedRows.Count
    RequestedWindow = $requestedWindowLabel
    Window = $windowLabel
    Columns = $headerNames
    DuplicateHeaderNames = @($duplicateHeaderNames.ToArray())
    Metrics = @($series.ToArray())
    Warnings = @($warnings.ToArray())
}

if ($Format -eq "Json") {
    $result | ConvertTo-Json -Depth 8
    return
}

Write-Output "# Telemetry summary"
Write-Output ""
Write-Output "- File: $(ConvertTo-MarkdownCell $result.FileName)"
Write-Output "- Header line: $($result.HeaderLine)"
Write-Output "- Rows: $($result.AnalyzedRows) analyzed / $($result.TotalRows) total"
Write-Output "- Window: $($result.Window)"
Write-Output ""
Write-Output "| Metric | Source column | Samples | Min | Mean | P1 | P5 | Median | P95 | Max |"
Write-Output "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |"

foreach ($metric in $series) {
    Write-Output ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} | {9} |" -f `
        (ConvertTo-MarkdownCell $metric.Metric), (ConvertTo-MarkdownCell $metric.SourceColumn), $metric.Samples,
        (Format-Number $metric.Min), (Format-Number $metric.Mean),
        (Format-Number $metric.P1), (Format-Number $metric.P5),
        (Format-Number $metric.Median), (Format-Number $metric.P95),
        (Format-Number $metric.Max))
}

if ($warnings.Count -gt 0) {
    Write-Output ""
    Write-Output "## Warnings"
    foreach ($warning in $warnings) {
        Write-Output "- $(ConvertTo-MarkdownCell $warning)"
    }
}

Write-Output ""
Write-Output "This summary is evidence for one monitoring window. It does not prove stability, daily use, or sensor accuracy."
