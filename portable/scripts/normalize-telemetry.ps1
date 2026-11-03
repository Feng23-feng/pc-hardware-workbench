[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputPath,

    [ValidateSet("Auto", "Csv", "SensorSnapshot")]
    [string]$InputFormat = "Auto",

    [string]$SourceTool,

    [string]$SourceVersion,

    [string]$DeviceId,

    [string]$CapturedAt,

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

    [ValidateRange(20, 5000)]
    [int]$MaxChartPoints = 480
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Stop-WithAnalysisError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function ConvertTo-CleanText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    $text = ([string]$Value) -replace "[\p{Cc}\p{Cf}]", " "
    return ($text -replace "[\u2028\u2029]", " ").Trim()
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

function ConvertTo-IsoTimestamp {
    param(
        [AllowNull()][object]$Value,
        [string]$FieldName = "timestamp"
    )
    if ($null -eq $Value) {
        return $null
    }
    try {
        if ($Value -is [datetimeoffset]) {
            $parsed = [datetimeoffset]$Value
        }
        elseif ($Value -is [datetime]) {
            $parsed = [datetimeoffset]$Value
        }
        else {
            $parsed = [datetimeoffset]::Parse(
                [string]$Value,
                $invariant,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
        }
        return $parsed.ToString("o", $invariant)
    }
    catch {
        throw "$FieldName is not a valid ISO 8601 timestamp: $Value"
    }
}

function ConvertTo-SnapshotTimestamp {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )
    if ($Value -is [datetimeoffset]) {
        return [datetimeoffset]$Value
    }
    if ($Value -is [datetime]) {
        return [datetimeoffset]$Value
    }
    $text = ConvertTo-CleanText $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "$FieldName is required."
    }
    if ($text -notmatch '(?:Z|[+-]\d{2}:\d{2})$') {
        throw "$FieldName must include an explicit UTC offset."
    }
    try {
        return [datetimeoffset]::Parse(
            $text,
            $invariant,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        throw "$FieldName is not a valid ISO 8601 timestamp: $text"
    }
}

function ConvertTo-FiniteNumber {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )
    if ($null -eq $Value) {
        return $null
    }
    $number = 0.0
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]) {
        $number = [double]$Value
    }
    else {
        $text = ConvertTo-CleanText $Value
        if (-not [double]::TryParse(
            $text,
            [System.Globalization.NumberStyles]::Float,
            $invariant,
            [ref]$number
        )) {
            throw "$FieldName must be a finite number or null: $Value"
        }
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "$FieldName must be a finite number or null: $Value"
    }
    return $number
}

function Quote-CsvField {
    param([AllowNull()][object]$Value)
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]) {
        return '"' + ([Convert]::ToString($Value, $invariant)) + '"'
    }
    $text = ConvertTo-CleanText $Value
    return '"' + $text.Replace('"', '""') + '"'
}

function Quote-ProcessArgument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-TelemetryAnalyzer {
    param([hashtable]$Parameters)

    $analyzerPath = Join-Path $PSScriptRoot "analyze-telemetry.ps1"
    if (-not (Test-Path -LiteralPath $analyzerPath -PathType Leaf)) {
        throw "Telemetry analyzer is missing: $analyzerPath"
    }
    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $analyzerPath)
    foreach ($name in @(
        "Path", "Format", "WarmupSeconds", "DurationSeconds", "WarmupRows",
        "MaxRows", "Delimiter", "MaxInputMegabytes", "MaxChartPoints"
    )) {
        if ($Parameters.ContainsKey($name)) {
            $arguments += @("-$name", [string]$Parameters[$name])
        }
    }
    if ($Parameters.ContainsKey("IncludeColumn")) {
        foreach ($pattern in @($Parameters.IncludeColumn)) {
            $arguments += @("-IncludeColumn", [string]$pattern)
        }
    }
    if ($Parameters.ContainsKey("HideFileName") -and $Parameters.HideFileName) {
        $arguments += "-HideFileName"
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = ($arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) {
        $message = if ([string]::IsNullOrWhiteSpace($stderr)) { $stdout } else { $stderr }
        Stop-WithAnalysisError "Telemetry analysis failed: $($message.Trim())"
    }
    if ([string]::IsNullOrWhiteSpace($stdout)) {
        Stop-WithAnalysisError "Telemetry analyzer returned no chart data."
    }
    try {
        return $stdout | ConvertFrom-Json
    }
    catch {
        Stop-WithAnalysisError "Telemetry analyzer returned invalid chart data: $($_.Exception.Message)"
    }
}

function Get-SensorHeader {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Unit
    )
    $baseName = ($Name -replace '\s*\[[^\]]+\]\s*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($baseName)) {
        $baseName = $Name
    }
    if ($baseName -ieq $Unit) {
        return $baseName
    }
    return "$baseName [$Unit]"
}

function Get-MetricCategory {
    param([AllowNull()][object]$Metric)
    $text = ConvertTo-CleanText $Metric
    if ($text -match "(?i)FPS|frame rate") {
        return "fps"
    }
    if ($text -match "(?i)frame time|latency") {
        return "frame-time"
    }
    if ($text -match "(?i)temperature|hotspot|junction") {
        return "temperature"
    }
    if ($text -match "(?i)power|watt") {
        return "power"
    }
    if ($text -match "(?i)clock|frequency") {
        return "clock"
    }
    if ($text -match "(?i)voltage") {
        return "voltage"
    }
    if ($text -match "(?i)fan") {
        return "fan"
    }
    if ($text -match "(?i)utilization|usage") {
        return "utilization"
    }
    return "other"
}

function Get-SamplingSummary {
    param(
        [Parameter(Mandatory = $true)][object]$ChartData,
        [AllowEmptyCollection()]
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[string]]$Warnings
    )
    if ($ChartData.TimeBased -ne $true) {
        $Warnings.Add("Sampling interval is unknown because the input uses row positions rather than timestamps.") | Out-Null
        return [pscustomobject]@{
            TimeBased = $false
            IntervalSecondsMedian = $null
            IntervalSecondsMinimum = $null
            IntervalSecondsMaximum = $null
            Consistency = "unknown"
        }
    }

    $series = @($ChartData.Series) | Select-Object -First 1
    $times = @(
        @($series.Points) |
            Where-Object { $null -ne $_.T } |
            ForEach-Object { [double]$_.T } |
            Sort-Object -Unique
    )
    if ($times.Count -lt 2) {
        $Warnings.Add("Sampling interval is unknown because fewer than two timestamps are available.") | Out-Null
        return [pscustomobject]@{
            TimeBased = $true
            IntervalSecondsMedian = $null
            IntervalSecondsMinimum = $null
            IntervalSecondsMaximum = $null
            Consistency = "unknown"
        }
    }

    $intervals = New-Object System.Collections.Generic.List[double]
    for ($index = 1; $index -lt $times.Count; $index++) {
        $interval = $times[$index] - $times[$index - 1]
        if ($interval -gt 0) {
            $intervals.Add($interval) | Out-Null
        }
    }
    if ($intervals.Count -eq 0) {
        $Warnings.Add("Sampling interval is unknown because all timestamp differences are zero.") | Out-Null
        return [pscustomobject]@{
            TimeBased = $true
            IntervalSecondsMedian = $null
            IntervalSecondsMinimum = $null
            IntervalSecondsMaximum = $null
            Consistency = "unknown"
        }
    }

    $sorted = @($intervals | Sort-Object)
    $minimum = $sorted[0]
    $maximum = $sorted[$sorted.Count - 1]
    $midpoint = [int][Math]::Floor($sorted.Count / 2)
    $median = if (($sorted.Count % 2) -eq 0) {
        ($sorted[$midpoint - 1] + $sorted[$midpoint]) / 2
    }
    else {
        $sorted[$midpoint]
    }
    $consistency = "stable"
    if (
        $median -gt 0 -and
        ($minimum -lt ($median * 0.75) -or $maximum -gt ($median * 1.25))
    ) {
        $consistency = "variable"
        $Warnings.Add("Sampling interval varies materially across the selected window.") | Out-Null
    }
    return [pscustomobject]@{
        TimeBased = $true
        IntervalSecondsMedian = [Math]::Round($median, 6)
        IntervalSecondsMinimum = [Math]::Round($minimum, 6)
        IntervalSecondsMaximum = [Math]::Round($maximum, 6)
        Consistency = $consistency
    }
}

function Add-UniqueWarnings {
    param(
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Target,
        [AllowNull()][object]$Values
    )
    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($existing in $Target) {
        $seen.Add($existing) | Out-Null
    }
    foreach ($value in @($Values)) {
        $text = ConvertTo-CleanText $value
        if (-not [string]::IsNullOrWhiteSpace($text) -and $seen.Add($text)) {
            $Target.Add($text) | Out-Null
        }
    }
}

try {
    $resolvedInput = Assert-LocalReadFilePath -Path $Path
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
}
catch {
    Stop-WithInputError $_.Exception.Message
}

$inputInfo = Get-Item -LiteralPath $resolvedInput
if (($inputInfo.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0) {
    Stop-WithInputError "Telemetry input is an offline or cloud-placeholder file. Materialize it locally first; normalization will not trigger hydration."
}
if ($inputInfo.Length -gt ($MaxInputMegabytes * 1MB)) {
    Stop-WithInputError "Input exceeds the configured $MaxInputMegabytes MB limit."
}
$inputHash = (Get-FileHash -LiteralPath $resolvedInput -Algorithm SHA256).Hash
$inputFileName = if ($HideFileName) { "[hidden]" } else { $inputInfo.Name }
$resolvedFormat = if ($InputFormat -eq "Auto") {
    if ($inputInfo.Extension -ieq ".json") { "SensorSnapshot" } else { "Csv" }
}
else {
    $InputFormat
}

$warnings = New-Object System.Collections.Generic.List[string]
$sourceSets = New-Object System.Collections.Generic.HashSet[string]
$sensorDefinitions = New-Object System.Collections.Generic.List[object]
$sensorDefinitionKeys = New-Object System.Collections.Generic.HashSet[string]
$mixedSources = $false
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-normalize-$([guid]::NewGuid().ToString('N'))"

try {
    if ($resolvedFormat -eq "Csv") {
        $inputKind = "csv"
        $normalizedCapturedAt = if ([string]::IsNullOrWhiteSpace($CapturedAt)) {
            $null
        }
        else {
            try {
                ConvertTo-IsoTimestamp -Value $CapturedAt -FieldName "CapturedAt"
            }
            catch {
                Stop-WithInputError $_.Exception.Message
            }
        }
        $tool = ConvertTo-CleanText $SourceTool
        $version = ConvertTo-CleanText $SourceVersion
        if ([string]::IsNullOrWhiteSpace($tool)) {
            $tool = "CSV source (tool not recorded)"
            $warnings.Add("Source tool was not recorded for this CSV input.") | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = "unknown"
            $warnings.Add("Source version was not recorded for this CSV input.") | Out-Null
        }
        if ($null -eq $normalizedCapturedAt) {
            $warnings.Add("Capture time was not recorded for this CSV input.") | Out-Null
        }
        if ([string]::IsNullOrWhiteSpace($DeviceId)) {
            $warnings.Add("Device identity was not recorded for this CSV input.") | Out-Null
        }
        $sourceSets.Add("$tool|$version|$DeviceId") | Out-Null

        $chartData = Invoke-TelemetryAnalyzer -Parameters @{
            Path = $resolvedInput
            Format = "ChartData"
            WarmupSeconds = $WarmupSeconds
            DurationSeconds = $DurationSeconds
            WarmupRows = $WarmupRows
            MaxRows = $MaxRows
            Delimiter = $Delimiter
            IncludeColumn = $IncludeColumn
            MaxInputMegabytes = $MaxInputMegabytes
            MaxChartPoints = $MaxChartPoints
            HideFileName = [bool]$HideFileName
        }
    }
    elseif ($resolvedFormat -eq "SensorSnapshot") {
        $inputKind = "sensor-snapshot"
        try {
            $snapshot = Get-Content -Raw -LiteralPath $resolvedInput -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Stop-WithInputError "Sensor snapshot JSON is invalid: $($_.Exception.Message)"
        }
        if ([string](Get-PropertyValue $snapshot "schemaVersion" "") -ne "1.0") {
            Stop-WithInputError "Sensor snapshot schemaVersion must be '1.0'."
        }
        Add-UniqueWarnings `
            -Target $warnings `
            -Values @(Get-PropertyValue $snapshot "warnings" @())
        $source = Get-PropertyValue $snapshot "source"
        if ($null -eq $source) {
            Stop-WithInputError "Sensor snapshot source metadata is required."
        }
        $tool = ConvertTo-CleanText (Get-PropertyValue $source "tool" "")
        $version = ConvertTo-CleanText (Get-PropertyValue $source "version" "")
        if ([string]::IsNullOrWhiteSpace($tool) -or [string]::IsNullOrWhiteSpace($version)) {
            Stop-WithInputError "Sensor snapshot source.tool and source.version are required."
        }
        if ([string]::IsNullOrWhiteSpace($DeviceId)) {
            $DeviceId = ConvertTo-CleanText (Get-PropertyValue $source "deviceId" "")
        }
        if (-not [string]::IsNullOrWhiteSpace($CapturedAt)) {
            try {
                $normalizedCapturedAt = ConvertTo-IsoTimestamp -Value $CapturedAt -FieldName "CapturedAt"
            }
            catch {
                Stop-WithInputError $_.Exception.Message
            }
        }
        elseif ($null -ne (Get-PropertyValue $source "capturedAt")) {
            try {
                $normalizedCapturedAt = ConvertTo-IsoTimestamp -Value (Get-PropertyValue $source "capturedAt") -FieldName "source.capturedAt"
            }
            catch {
                Stop-WithInputError $_.Exception.Message
            }
        }
        else {
            $normalizedCapturedAt = $null
        }

        $samplesProperty = $snapshot.PSObject.Properties["samples"]
        if ($null -eq $samplesProperty -or $samplesProperty.Value -isnot [System.Array]) {
            Stop-WithInputError "Sensor snapshot samples must be an array."
        }
        $samples = @($samplesProperty.Value)
        if ($samples.Count -eq 0) {
            Stop-WithInputError "Sensor snapshot samples array must not be empty."
        }
        if ([string]::IsNullOrWhiteSpace($DeviceId)) {
            $warnings.Add("Device identity was not recorded for this sensor snapshot.") | Out-Null
        }

        $allowedCategories = @(
            "fps", "frame-time", "temperature", "power", "clock", "voltage",
            "utilization", "fan", "memory", "throughput", "latency", "other"
        )
        $headers = New-Object System.Collections.Generic.List[string]
        $nameUnits = @{}
        $sourceSets.Add("$tool|$version|$DeviceId") | Out-Null
        $rows = New-Object System.Collections.Generic.List[object]
        $previousTime = $null
        $mixedUnitWarnings = New-Object System.Collections.Generic.HashSet[string]

        for ($sampleIndex = 0; $sampleIndex -lt $samples.Count; $sampleIndex++) {
            $sample = $samples[$sampleIndex]
            if ($null -eq $sample -or $null -eq $sample.PSObject.Properties["capturedAt"]) {
                Stop-WithInputError "samples[$sampleIndex] must be an object with capturedAt and sensors."
            }
            try {
                $time = ConvertTo-SnapshotTimestamp `
                    -Value (Get-PropertyValue $sample "capturedAt") `
                    -FieldName "samples[$sampleIndex].capturedAt"
            }
            catch {
                Stop-WithInputError $_.Exception.Message
            }
            if ($null -ne $previousTime -and $time.UtcDateTime -lt $previousTime.UtcDateTime) {
                Stop-WithInputError "Sensor snapshot timestamps move backwards at sample $sampleIndex."
            }
            if ($null -ne $previousTime -and $time.UtcDateTime -eq $previousTime.UtcDateTime) {
                $warnings.Add("Sensor snapshot contains duplicate timestamps.") | Out-Null
            }
            $previousTime = $time

            $row = @{}
            $sensorsProperty = $sample.PSObject.Properties["sensors"]
            if ($null -eq $sensorsProperty -or $sensorsProperty.Value -isnot [System.Array]) {
                Stop-WithInputError "samples[$sampleIndex].sensors must be an array."
            }
            $sensors = @($sensorsProperty.Value)
            if ($sensors.Count -eq 0) {
                Stop-WithInputError "samples[$sampleIndex].sensors array must not be empty."
            }
            foreach ($sensorValue in $sensors) {
                $name = ConvertTo-CleanText (Get-PropertyValue $sensorValue "name" "")
                $category = ConvertTo-CleanText (Get-PropertyValue $sensorValue "category" "")
                $unit = ConvertTo-CleanText (Get-PropertyValue $sensorValue "unit" "")
                if ([string]::IsNullOrWhiteSpace($name) -or
                    [string]::IsNullOrWhiteSpace($category) -or
                    [string]::IsNullOrWhiteSpace($unit)) {
                    Stop-WithInputError "Each sensor requires name, category, and unit at sample $sampleIndex."
                }
                if ($allowedCategories -notcontains $category) {
                    Stop-WithInputError "Unsupported sensor category '$category' at sample $sampleIndex."
                }
                $header = Get-SensorHeader -Name $name -Unit $unit
                if ($row.ContainsKey($header)) {
                    Stop-WithInputError "Duplicate sensor '$header' at sample $sampleIndex."
                }
                $valueProperty = $sensorValue.PSObject.Properties["value"]
                if ($null -eq $valueProperty) {
                    Stop-WithInputError "Sensor '$header' at sample $sampleIndex is missing the required value property."
                }
                try {
                    $row[$header] = ConvertTo-FiniteNumber `
                        -Value $valueProperty.Value `
                        -FieldName "samples[$sampleIndex].$header.value"
                }
                catch {
                    Stop-WithInputError $_.Exception.Message
                }

                $sensorTool = ConvertTo-CleanText (Get-PropertyValue $sensorValue "sourceTool" $tool)
                $sensorVersion = ConvertTo-CleanText (Get-PropertyValue $sensorValue "sourceVersion" $version)
                $sensorDevice = ConvertTo-CleanText (Get-PropertyValue $sensorValue "deviceId" $DeviceId)
                $definitionKey = "$header|$category|$sensorTool|$sensorVersion|$sensorDevice"
                if ($sensorDefinitionKeys.Add($definitionKey)) {
                    $sensorDefinitions.Add([pscustomobject]@{
                        Name = $name
                        Category = $category
                        Unit = $unit
                        Header = $header
                        SourceTool = if ([string]::IsNullOrWhiteSpace($sensorTool)) { $null } else { $sensorTool }
                        SourceVersion = if ([string]::IsNullOrWhiteSpace($sensorVersion)) { $null } else { $sensorVersion }
                        DeviceId = if ([string]::IsNullOrWhiteSpace($sensorDevice)) { $null } else { $sensorDevice }
                    }) | Out-Null
                }

                if (-not $headers.Contains($header)) {
                    $headers.Add($header) | Out-Null
                }
                if (-not $nameUnits.ContainsKey($name)) {
                    $nameUnits[$name] = New-Object System.Collections.Generic.HashSet[string]
                }
                $nameUnits[$name].Add($unit) | Out-Null
                if ($nameUnits[$name].Count -gt 1 -and $mixedUnitWarnings.Add($name)) {
                    $warnings.Add("Sensor '$name' appears with multiple units and is kept as separate series.") | Out-Null
                }

                $hasSourceOverride = (
                    -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $sensorValue "sourceTool" "")) -or
                    -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $sensorValue "sourceVersion" "")) -or
                    -not [string]::IsNullOrWhiteSpace([string](Get-PropertyValue $sensorValue "deviceId" ""))
                )
                if ($hasSourceOverride) {
                    $sourceSets.Add("$sensorTool|$sensorVersion|$sensorDevice") | Out-Null
                }
            }
            $rows.Add($row) | Out-Null
        }

        if ($sourceSets.Count -gt 1) {
            $mixedSources = $true
            $warnings.Add("Sensor snapshot mixes multiple tool, version, or device source identities.") | Out-Null
        }
        if ($null -eq $normalizedCapturedAt) {
            $normalizedCapturedAt = ConvertTo-IsoTimestamp -Value $samples[0].capturedAt -FieldName "samples[0].capturedAt"
            $warnings.Add("Source capture time was missing; the first sample timestamp was used.") | Out-Null
        }
        if ($headers.Count -eq 0) {
            Stop-WithAnalysisError "Sensor snapshot contains no usable numeric sensors."
        }

        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $tempCsv = Join-Path $tempRoot "sensor-snapshot.csv"
        $csv = New-Object System.Text.StringBuilder
        $csv.AppendLine((@("Date", "Time") + @($headers) | ForEach-Object { Quote-CsvField $_ }) -join ",") | Out-Null
        for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
            $time = ConvertTo-SnapshotTimestamp `
                -Value (Get-PropertyValue $samples[$rowIndex] "capturedAt") `
                -FieldName "samples[$rowIndex].capturedAt"
            $fields = @(
                $time.UtcDateTime.ToString("yyyy-MM-dd", $invariant),
                $time.UtcDateTime.ToString("HH:mm:ss.fff", $invariant)
            )
            foreach ($header in $headers) {
                $fields += if ($rows[$rowIndex].ContainsKey($header)) { $rows[$rowIndex][$header] } else { "" }
            }
            $csv.AppendLine(($fields | ForEach-Object { Quote-CsvField $_ }) -join ",") | Out-Null
        }
        [IO.File]::WriteAllText($tempCsv, $csv.ToString(), $utf8NoBom)

        $chartData = Invoke-TelemetryAnalyzer -Parameters @{
            Path = $tempCsv
            Format = "ChartData"
            WarmupSeconds = $WarmupSeconds
            DurationSeconds = $DurationSeconds
            WarmupRows = $WarmupRows
            MaxRows = $MaxRows
            Delimiter = ","
            IncludeColumn = $IncludeColumn
            MaxInputMegabytes = $MaxInputMegabytes
            MaxChartPoints = $MaxChartPoints
            HideFileName = $true
        }
    }
    else {
        Stop-WithInputError "Unsupported input format: $resolvedFormat"
    }

    if (@($chartData.Series).Count -eq 0) {
        Stop-WithAnalysisError "No recognized numeric telemetry series can be normalized."
    }
    foreach ($warningValue in @($chartData.Warnings)) {
        $warnings.Add((ConvertTo-CleanText $warningValue)) | Out-Null
    }
    if ($inputKind -eq "csv") {
        foreach ($metric in @($chartData.Series)) {
            $definitionKey = "$($metric.SourceColumn)|other|$tool|$version|$DeviceId"
            if ($sensorDefinitionKeys.Add($definitionKey)) {
                $sensorDefinitions.Add([pscustomobject]@{
                    Name = [string]$metric.Metric
                    Category = Get-MetricCategory $metric.Metric
                    Unit = [string]$metric.Unit
                    Header = [string]$metric.SourceColumn
                    SourceTool = $tool
                    SourceVersion = $version
                    DeviceId = if ([string]::IsNullOrWhiteSpace($DeviceId)) { $null } else { ConvertTo-CleanText $DeviceId }
                }) | Out-Null
            }
        }
    }

    $uniqueWarnings = New-Object System.Collections.Generic.List[string]
    Add-UniqueWarnings -Target $uniqueWarnings -Values $warnings
    $sampling = Get-PropertyValue $chartData "Sampling"
    if ($null -eq $sampling) {
        $sampling = Get-SamplingSummary -ChartData $chartData -Warnings $uniqueWarnings
    }
    elseif ($sampling.Consistency -eq "variable") {
        Add-UniqueWarnings `
            -Target $uniqueWarnings `
            -Values @("Sampling interval varies materially across the selected window.")
    }
    elseif ($sampling.Consistency -eq "unknown") {
        Add-UniqueWarnings `
            -Target $uniqueWarnings `
            -Values @("Sampling interval could not be established from the available timestamps.")
    }
    $chartData.FileName = $inputFileName
    $missingValues = 0
    foreach ($series in @($chartData.Series)) {
        $missingValues += @(@($series.Points) | Where-Object { $null -eq $_.V -or $null -eq $_.T }).Count
    }

    $normalized = [pscustomobject]@{
        NormalizedTelemetryVersion = "1.0"
        AdapterVersion = "1.0.0"
        Source = [pscustomobject]@{
            Tool = $tool
            Version = $version
            DeviceId = if ([string]::IsNullOrWhiteSpace($DeviceId)) { $null } else { ConvertTo-CleanText $DeviceId }
            CapturedAt = $normalizedCapturedAt
            InputKind = $inputKind
            InputFileName = $inputFileName
            InputSha256 = $inputHash
            MixedSources = $mixedSources
        }
        Sampling = $sampling
        DataQuality = [pscustomobject]@{
            Status = if ($missingValues -gt 0) { "partial" } elseif ($uniqueWarnings.Count -eq 0) { "complete" } else { "warnings" }
            SeriesCount = @($chartData.Series).Count
            MissingValueCount = $missingValues
            Window = [string]$chartData.Window
        }
        Sensors = @($sensorDefinitions.ToArray())
        ChartData = $chartData
        Warnings = @($uniqueWarnings)
    }

    $json = $normalized | ConvertTo-Json -Depth 20
    $writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content ($json + "`r`n")
    Write-Output $writtenPath
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
