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

function Get-LhmComponentPrefix {
    param([AllowNull()][object]$Identifier)
    $text = ConvertTo-LhmCleanText $Identifier
    if ($text -match '(?i)^/gpu') {
        return "GPU"
    }
    if ($text -match '(?i)^/cpu') {
        return "CPU"
    }
    if ($text -match '(?i)^/(memory|ram)') {
        return "Memory"
    }
    if ($text -match '(?i)^/motherboard') {
        return "Motherboard"
    }
    if ($text -match '(?i)^/(storage|hdd|nvme)') {
        return "Storage"
    }
    if ($text -match '(?i)^/nic') {
        return "Network"
    }
    if ($text -match '(?i)^/psu') {
        return "PSU"
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
        "noise" { return [pscustomobject]@{ Category = "other"; Unit = "dBA" } }
        "energy" { return [pscustomobject]@{ Category = "other"; Unit = "mWh" } }
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
        $result.Add([pscustomobject]@{
            name = $uniqueName
            category = $mapping.Category
            unit = $mapping.Unit
            value = ConvertTo-LhmFiniteNumber $sensor.Value
            identifier = ConvertTo-LhmCleanText $sensor.Identifier
        }) | Out-Null
    }
    return [object[]]$result.ToArray()
}

function New-LhmSensorSnapshot {
    param(
        [Parameter(Mandatory = $true)][object[]]$Samples,
        [string]$SourceVersion = "unknown",
        [string]$DeviceAlias,
        [string[]]$Warnings = @()
    )
    if (@($Samples).Count -eq 0) {
        throw "At least one LHM sample is required."
    }
    return [pscustomobject]@{
        schemaVersion = "1.0"
        source = [pscustomobject]@{
            tool = "LibreHardwareMonitor"
            version = if ([string]::IsNullOrWhiteSpace($SourceVersion)) { "unknown" } else { ConvertTo-LhmCleanText $SourceVersion }
            deviceId = if ([string]::IsNullOrWhiteSpace($DeviceAlias)) { $null } else { ConvertTo-LhmCleanText $DeviceAlias }
            capturedAt = [string]$Samples[0].capturedAt
        }
        warnings = @($Warnings | ForEach-Object { ConvertTo-LhmCleanText $_ } | Where-Object { $_ })
        samples = @($Samples)
    }
}
