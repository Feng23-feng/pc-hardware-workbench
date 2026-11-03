function ConvertTo-LhmCleanText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    $text = ([string]$Value) -replace "[\p{Cc}\p{Cf}]", " "
    return ($text -replace "[\u2028\u2029]", " ").Trim()
}

function ConvertTo-LhmFiniteNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return $null
    }
    $number = 0.0
    try {
        $number = [double]$Value
    }
    catch {
        return $null
    }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        return $null
    }
    return $number
}

function ConvertFrom-LhmDisplayValue {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$TargetUnit
    )
    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64] -or
        $Value -is [single] -or $Value -is [double] -or
        $Value -is [decimal]) {
        return ConvertTo-LhmFiniteNumber $Value
    }

    $text = ConvertTo-LhmCleanText $Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text -match '^(?i:n/?a|--?|unknown)$') {
        return $null
    }
    $match = [regex]::Match(
        $text,
        '^(?<number>[-+]?(?:\d+(?:\.\d*)?|\.\d+))\s*(?<unit>.*)$',
        [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
    if (-not $match.Success) {
        return $null
    }
    $number = 0.0
    if (-not [double]::TryParse(
        $match.Groups["number"].Value,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $null
    }

    $displayUnit = (ConvertTo-LhmCleanText $match.Groups["unit"].Value).ToLowerInvariant()
    $canonicalTarget = (ConvertTo-LhmCleanText $TargetUnit).ToLowerInvariant()
    $degreeSign = [char]0x00B0
    $degreeC = [string]$degreeSign + "c"
    $degreeF = [string]$degreeSign + "f"
    if ([string]::IsNullOrWhiteSpace($displayUnit) -or $displayUnit -eq $canonicalTarget) {
        return ConvertTo-LhmFiniteNumber $number
    }
    if ($canonicalTarget -eq "c" -and $displayUnit -in @($degreeC, "c")) {
        return ConvertTo-LhmFiniteNumber $number
    }
    if ($canonicalTarget -eq "c" -and $displayUnit -in @($degreeF, "f")) {
        return ConvertTo-LhmFiniteNumber (($number - 32.0) * (5.0 / 9.0))
    }
    if ($canonicalTarget -eq "c" -and $displayUnit -eq "k") {
        return ConvertTo-LhmFiniteNumber ($number - 273.15)
    }

    $factor = switch ("$displayUnit|$canonicalTarget") {
        "hz|mhz" { 0.000001 }
        "khz|mhz" { 0.001 }
        "ghz|mhz" { 1000.0 }
        "mw|w" { 0.001 }
        "kw|w" { 1000.0 }
        "mv|v" { 0.001 }
        "kv|v" { 1000.0 }
        "ma|a" { 0.001 }
        "ka|a" { 1000.0 }
        "b|mb" { 0.00000095367431640625 }
        "kb|mb" { 0.0009765625 }
        "kib|mb" { 0.0009765625 }
        "gb|mb" { 1024.0 }
        "gib|mb" { 1024.0 }
        "tb|mb" { 1048576.0 }
        "tib|mb" { 1048576.0 }
        "b/s|b/s" { 1.0 }
        "kb/s|b/s" { 1024.0 }
        "kib/s|b/s" { 1024.0 }
        "mb/s|b/s" { 1048576.0 }
        "mib/s|b/s" { 1048576.0 }
        "gb/s|b/s" { 1073741824.0 }
        "gib/s|b/s" { 1073741824.0 }
        "b/sec|b/s" { 1.0 }
        "kb/sec|b/s" { 1024.0 }
        "mb/sec|b/s" { 1048576.0 }
        "gb/sec|b/s" { 1073741824.0 }
        "%|%" { 1.0 }
        "rpm|rpm" { 1.0 }
        "v|v" { 1.0 }
        "w|w" { 1.0 }
        "a|a" { 1.0 }
        "dba|dba" { 1.0 }
        "mwh|mwh" { 1.0 }
        "unitless|unitless" { 1.0 }
        default { $null }
    }
    if ($null -eq $factor) {
        return $null
    }
    return ConvertTo-LhmFiniteNumber ($number * [double]$factor)
}

function Get-LhmComponentPrefix {
    param([AllowNull()][object]$Identifier)
    $text = ConvertTo-LhmCleanText $Identifier
    if ($text -match '(?i)^/[^/]*gpu(?:/|$)') {
        return "GPU"
    }
    if ($text -match '(?i)^/[^/]*(?:cpu|processor)(?:/|$)') {
        return "CPU"
    }
    if ($text -match '(?i)^/[^/]*(?:memory|ram)(?:/|$)') {
        return "Memory"
    }
    if ($text -match '(?i)^/[^/]*motherboard(?:/|$)') {
        return "Motherboard"
    }
    if ($text -match '(?i)^/[^/]*(?:storage|hdd|nvme)(?:/|$)') {
        return "Storage"
    }
    if ($text -match '(?i)^/[^/]*nic(?:/|$)') {
        return "Network"
    }
    if ($text -match '(?i)^/[^/]*psu(?:/|$)') {
        return "PSU"
    }
    if ($text -match '(?i)^/[^/]*battery(?:/|$)') {
        return "Battery"
    }
    return ""
}

function Get-LhmSensorMapping {
    param([AllowNull()][object]$SensorType)
    $type = (ConvertTo-LhmCleanText $SensorType).ToLowerInvariant()
    switch ($type) {
        "temperature" { return [pscustomobject]@{ Category = "temperature"; Unit = "C" } }
        "power" { return [pscustomobject]@{ Category = "power"; Unit = "W" } }
        "clock" { return [pscustomobject]@{ Category = "clock"; Unit = "MHz" } }
        "frequency" { return [pscustomobject]@{ Category = "clock"; Unit = "MHz" } }
        "voltage" { return [pscustomobject]@{ Category = "voltage"; Unit = "V" } }
        "fan" { return [pscustomobject]@{ Category = "fan"; Unit = "RPM" } }
        "control" { return [pscustomobject]@{ Category = "fan"; Unit = "%" } }
        "load" { return [pscustomobject]@{ Category = "utilization"; Unit = "%" } }
        "level" { return [pscustomobject]@{ Category = "utilization"; Unit = "%" } }
        "throughput" { return [pscustomobject]@{ Category = "throughput"; Unit = "B/s" } }
        "data" { return [pscustomobject]@{ Category = "memory"; Unit = "MB" } }
        "smalldata" { return [pscustomobject]@{ Category = "memory"; Unit = "MB" } }
        "current" { return [pscustomobject]@{ Category = "other"; Unit = "A" } }
        "noise" { return [pscustomobject]@{ Category = "other"; Unit = "dBA" } }
        "energy" { return [pscustomobject]@{ Category = "other"; Unit = "mWh" } }
        "humidity" { return [pscustomobject]@{ Category = "other"; Unit = "%" } }
        default { return [pscustomobject]@{ Category = "other"; Unit = "unitless" } }
    }
}

function Get-LhmCanonicalSensorName {
    param(
        [AllowNull()][object]$Name,
        [AllowNull()][object]$Identifier
    )
    $sensorName = ConvertTo-LhmCleanText $Name
    if ([string]::IsNullOrWhiteSpace($sensorName)) {
        $sensorName = "Unnamed sensor"
    }
    $prefix = Get-LhmComponentPrefix $Identifier
    if ([string]::IsNullOrWhiteSpace($prefix) -or
        $sensorName -match "^(GPU|CPU|Memory|Motherboard|Storage|Network|PSU)\b") {
        return $sensorName
    }
    return "$prefix $sensorName"
}

function Add-LhmSensorRoleLabel {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Category
    )
    switch ($Category) {
        "temperature" {
            if ($Name -notmatch '(?i)temperature|temp\b|hotspot|junction|thermal') {
                if ($Name -match '^GPU\s+(.+)$') {
                    return "GPU Temperature ($($Matches[1]))"
                }
                return "$Name Temperature"
            }
        }
        "power" {
            if ($Name -notmatch '(?i)power|watt') {
                if ($Name -match '^GPU\s+(.+)$') {
                    return "GPU Power ($($Matches[1]))"
                }
                return "$Name Power"
            }
        }
        "clock" {
            if ($Name -notmatch '(?i)clock|frequency') {
                return "$Name Clock"
            }
        }
        "voltage" {
            if ($Name -notmatch '(?i)voltage') {
                return "$Name Voltage"
            }
        }
        "fan" {
            if ($Name -notmatch '(?i)fan') {
                return "$Name Fan"
            }
        }
        "utilization" {
            if ($Name -notmatch '(?i)load|usage|utilization') {
                return "$Name Load"
            }
        }
    }
    return $Name
}

function ConvertFrom-LhmWebSensorTree {
    param(
        [AllowNull()][object]$Document,
        [ValidateRange(1, 5000)]
        [int]$MaxSensors = 500
    )
    if ($null -eq $Document) {
        throw "LibreHardwareMonitor web response is empty."
    }

    $result = New-Object System.Collections.Generic.List[object]
    function Visit-LhmWebNode {
        param(
            [AllowNull()][object]$Node,
            [string]$ParentPath = ""
        )
        if ($null -eq $Node) {
            return
        }

        $nodeText = ConvertTo-LhmCleanText $Node.PSObject.Properties["Text"].Value
        $currentPath = if ([string]::IsNullOrWhiteSpace($nodeText)) {
            $ParentPath
        }
        elseif ([string]::IsNullOrWhiteSpace($ParentPath)) {
            $nodeText
        }
        else {
            "$ParentPath / $nodeText"
        }

        $sensorIdProperty = $Node.PSObject.Properties["SensorId"]
        $sensorTypeProperty = $Node.PSObject.Properties["Type"]
        if ($null -ne $sensorIdProperty -and $null -ne $sensorTypeProperty) {
            $sensorId = ConvertTo-LhmCleanText $sensorIdProperty.Value
            $sensorType = ConvertTo-LhmCleanText $sensorTypeProperty.Value
            if (-not [string]::IsNullOrWhiteSpace($sensorId) -and
                -not [string]::IsNullOrWhiteSpace($sensorType)) {
                if ($result.Count -ge $MaxSensors) {
                    throw "Sensor count exceeds the configured $MaxSensors sensor limit."
                }
                $valueProperty = $Node.PSObject.Properties["RawValue"]
                if ($null -eq $valueProperty -or [string]::IsNullOrWhiteSpace((ConvertTo-LhmCleanText $valueProperty.Value))) {
                    $valueProperty = $Node.PSObject.Properties["Value"]
                }
                $mapping = Get-LhmSensorMapping $sensorType
                $nameProperty = $Node.PSObject.Properties["Text"]
                $name = if ($null -eq $nameProperty) { "" } else { $nameProperty.Value }
                $value = if ($null -eq $valueProperty) {
                    $null
                }
                else {
                    ConvertFrom-LhmDisplayValue -Value $valueProperty.Value -TargetUnit $mapping.Unit
                }
                $result.Add([pscustomobject]@{
                    Identifier = $sensorId
                    Name = $name
                    SensorType = $sensorType
                    Value = $value
                    HardwarePath = $ParentPath
                }) | Out-Null
            }
        }

        $childrenProperty = $Node.PSObject.Properties["Children"]
        if ($null -ne $childrenProperty) {
            foreach ($child in @($childrenProperty.Value)) {
                Visit-LhmWebNode -Node $child -ParentPath $currentPath
            }
        }
    }

    Visit-LhmWebNode $Document
    return [object[]]$result.ToArray()
}

function ConvertFrom-LhmSensorObjects {
    param(
        [AllowNull()][object[]]$Sensors,
        [ValidateRange(1, 5000)]
        [int]$MaxSensors = 500
    )
    if (@($Sensors).Count -gt $MaxSensors) {
        throw "Sensor count exceeds the configured $MaxSensors sensor limit."
    }

    $result = New-Object System.Collections.Generic.List[object]
    $headerCounts = @{}
    foreach ($sensor in @($Sensors)) {
        if ($null -eq $sensor) {
            continue
        }
        $sensorType = ConvertTo-LhmCleanText $sensor.SensorType
        if ([string]::IsNullOrWhiteSpace($sensorType)) {
            continue
        }
        $mapping = Get-LhmSensorMapping $sensorType
        $name = Get-LhmCanonicalSensorName -Name $sensor.Name -Identifier $sensor.Identifier
        $name = Add-LhmSensorRoleLabel -Name $name -Category $mapping.Category
        $baseHeader = if ($name -ieq $mapping.Unit) {
            $name
        }
        else {
            "$name [$($mapping.Unit)]"
        }
        $headerKey = $baseHeader.ToLowerInvariant()
        $occurrence = 1 + [int]$headerCounts[$headerKey]
        $headerCounts[$headerKey] = $occurrence
        $uniqueName = if ($occurrence -gt 1) { "$name #$occurrence" } else { $name }
        $hardwarePathProperty = $sensor.PSObject.Properties["HardwarePath"]
        $hardwarePath = if ($null -eq $hardwarePathProperty) {
            ""
        }
        else {
            ConvertTo-LhmCleanText $hardwarePathProperty.Value
        }
        $result.Add([pscustomobject]@{
            name = $uniqueName
            category = $mapping.Category
            unit = $mapping.Unit
            value = ConvertTo-LhmFiniteNumber $sensor.Value
            identifier = ConvertTo-LhmCleanText $sensor.Identifier
            hardwarePath = $hardwarePath
        }) | Out-Null
    }
    return [object[]]$result.ToArray()
}

function New-LhmSensorSnapshot {
    param(
        [Parameter(Mandatory = $true)][object[]]$Samples,
        [string]$SourceVersion = "unknown",
        [string]$DeviceAlias,
        [string]$Transport = "unknown",
        [string[]]$Warnings = @()
    )
    if (@($Samples).Count -eq 0) {
        throw "At least one LHM sample is required."
    }
    $observedComponents = @(
        $Samples |
            ForEach-Object { @($_.sensors) } |
            Where-Object { $_.identifier -notmatch '(?i)^/(nic|network)(?:/|$)' } |
            ForEach-Object { ConvertTo-LhmCleanText $_.hardwarePath } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    return [pscustomobject]@{
        schemaVersion = "1.0"
        source = [pscustomobject]@{
            tool = "LibreHardwareMonitor"
            version = if ([string]::IsNullOrWhiteSpace($SourceVersion)) { "unknown" } else { ConvertTo-LhmCleanText $SourceVersion }
            transport = if ([string]::IsNullOrWhiteSpace($Transport)) { "unknown" } else { ConvertTo-LhmCleanText $Transport }
            deviceId = if ([string]::IsNullOrWhiteSpace($DeviceAlias)) { $null } else { ConvertTo-LhmCleanText $DeviceAlias }
            capturedAt = [string]$Samples[0].capturedAt
            observedComponents = @($observedComponents)
        }
        warnings = @($Warnings | ForEach-Object { ConvertTo-LhmCleanText $_ } | Where-Object { $_ })
        samples = @($Samples)
    }
}
