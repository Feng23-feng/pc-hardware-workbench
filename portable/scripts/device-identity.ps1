function ConvertTo-DeviceIdentityPlainText {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    $text = $text.Replace([string][char]0xFFFD, " [unreadable] ")
    $text = $text -replace "\p{Cc}", " "
    $text = $text -replace "\p{Cf}", ""
    $text = $text -replace "[\uFE00-\uFE0F]", ""
    $text = $text -replace "\p{Zl}|\p{Zp}", " "
    $text = $text -replace "\s+", " "
    $text = $text.Trim()
    if ($text.Length -gt 160) {
        $text = $text.Substring(0, 160).TrimEnd() + "..."
    }
    return $text
}

function ConvertTo-SafeMarkdownText {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }

    $text = [string]$Value
    $text = $text -replace "\p{Cc}", " "
    $text = $text -replace "\p{Cf}", ""
    $text = $text -replace "[\uFE00-\uFE0F]", ""
    $text = $text -replace "\p{Zl}|\p{Zp}", " "
    $text = $text -replace "\s+", " "
    $text = $text.Trim()
    if ($text.Length -gt 512) {
        $text = $text.Substring(0, 512).TrimEnd() + "..."
    }

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

function ConvertTo-DeviceIdentityDisplay {
    param([object]$Value)

    $text = ConvertTo-DeviceIdentityPlainText -Value $Value
    if ($null -eq $text) {
        return $null
    }

    $text = $text.Replace("&", "&amp;")
    $text = $text.Replace("<", "&lt;")
    $text = $text.Replace(">", "&gt;")
    return $text
}

function ConvertTo-DeviceIdentityMarkdown {
    param([object]$Value)

    $text = ConvertTo-DeviceIdentityPlainText -Value $Value
    if ($null -eq $text) {
        return $null
    }

    # Inline code keeps embedded links, images, HTML, and emphasis inert while
    # preserving the readable identity text.
    return ConvertTo-SafeMarkdownText -Value $text
}

function Get-RedactedTextValue {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return $Value
    }
    return "[redacted]"
}

function Test-GenericVolumeLabel {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { "" } else { ([string]$Value).Trim() }
    return $text -match '^(?i:Windows|Local Disk|System Reserved|New Volume|\u672C\u5730\u78C1\u76D8|\u65B0\u52A0\u5377|\u7CFB\u7EDF\u4FDD\u7559)$'
}

function Test-GenericDisplayModel {
    param([AllowNull()][object]$Value)

    $text = if ($null -eq $Value) { "" } else { ([string]$Value).Trim() }
    return $text -match '^(?i:Generic PnP Monitor|Generic Monitor|Default Monitor|\u901A\u7528\u5373\u63D2\u5373\u7528\u76D1\u89C6\u5668|\u9ED8\u8BA4\u76D1\u89C6\u5668)$'
}

function Get-RedactedInventoryData {
    param(
        [object[]]$MemoryModules,
        [object[]]$PhysicalDisks,
        [object[]]$Volumes,
        [object[]]$Monitors,
        [object]$Battery
    )

    $redactedMemory = @(
        foreach ($module in @($MemoryModules)) {
            $copy = $module | Select-Object *
            $copy.Manufacturer = Get-RedactedTextValue -Value $copy.Manufacturer
            $copy.PartNumber = Get-RedactedTextValue -Value $copy.PartNumber
            $copy
        }
    )

    $diskIndex = 0
    $redactedDisks = @(
        foreach ($disk in @($PhysicalDisks)) {
            $diskIndex++
            $copy = $disk | Select-Object *
            $diskNumber = if (
                $copy.PSObject.Properties.Name -contains "DeviceNumber" -and
                $null -ne $copy.DeviceNumber
            ) {
                $copy.DeviceNumber
            }
            else {
                $diskIndex - 1
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$copy.Model)) {
                $copy.Model = "Physical disk $diskNumber (redacted model)"
            }
            if ($copy.PSObject.Properties.Name -contains "ProductRevision") {
                $copy.ProductRevision = Get-RedactedTextValue -Value $copy.ProductRevision
            }
            $copy
        }
    )

    $redactedVolumes = @(
        foreach ($volume in @($Volumes)) {
            $copy = $volume | Select-Object *
            if (-not (Test-GenericVolumeLabel -Value $copy.Label)) {
                $copy.Label = Get-RedactedTextValue -Value $copy.Label
            }
            if ($copy.PSObject.Properties.Name -contains "PhysicalDisk") {
                $copy.PhysicalDisk = if ([string]::IsNullOrWhiteSpace([string]$copy.PhysicalDisk)) {
                    $copy.PhysicalDisk
                }
                elseif ($null -ne $copy.DiskNumber) {
                    "Physical disk $($copy.DiskNumber) (redacted model)"
                }
                else {
                    "[redacted]"
                }
            }
            $copy
        }
    )

    $monitorIndex = 0
    $redactedMonitors = @(
        foreach ($monitor in @($Monitors)) {
            $monitorIndex++
            $copy = $monitor | Select-Object *
            $copy.Manufacturer = Get-RedactedTextValue -Value $copy.Manufacturer
            if (
                -not [string]::IsNullOrWhiteSpace([string]$copy.Model) -and
                -not (Test-GenericDisplayModel -Value $copy.Model)
            ) {
                $copy.Model = "Display $monitorIndex (redacted model)"
            }
            $copy.ProductCode = Get-RedactedTextValue -Value $copy.ProductCode
            $copy
        }
    )

    $redactedBattery = if ($null -ne $Battery) {
        $copy = $Battery | Select-Object *
        $copy.Manufacturer = Get-RedactedTextValue -Value $copy.Manufacturer
        $copy
    }
    else {
        $null
    }

    return [pscustomobject]@{
        MemoryModules = @($redactedMemory)
        PhysicalDisks = @($redactedDisks)
        Volumes = @($redactedVolumes)
        Monitors = @($redactedMonitors)
        Battery = $redactedBattery
    }
}

function ConvertTo-DeviceIdentitySessionStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("readable", "suspicious", "partial", "unreadable", "unknown", "redacted")]
        [string]$CollectorStatus
    )

    switch ($CollectorStatus) {
        "readable" { return "confirmed" }
        "partial" { return "unknown" }
        "suspicious" { return "unreadable" }
        "unreadable" { return "unreadable" }
        "unknown" { return "unknown" }
        "redacted" { return "unknown" }
    }
}

function Get-DeviceIdentityTextAssessment {
    param(
        [string]$FieldName,
        [object]$Value
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    $trimmed = $text.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return [pscustomobject]@{
            Field = $FieldName
            Status = "unknown"
            Issues = @("empty")
        }
    }
    if ($trimmed -eq "[redacted]") {
        return [pscustomobject]@{
            Field = $FieldName
            Status = "redacted"
            Issues = @()
        }
    }
    if ($trimmed -match "^(Unknown|To be filled by O\.E\.M\.|Default string|System manufacturer|System product name|O\.E\.M\.|Not Specified)$") {
        return [pscustomobject]@{
            Field = $FieldName
            Status = "unknown"
            Issues = @("placeholder value")
        }
    }

    $status = "readable"
    if ($trimmed.IndexOf([char]0xFFFD) -ge 0) {
        $status = "unreadable"
        $issues.Add("replacement characters") | Out-Null
    }
    if ($trimmed -match "[\x00-\x1F\x7F]") {
        $status = "unreadable"
        $issues.Add("control characters") | Out-Null
    }
    if ($trimmed -match "[\u200B-\u200D\u202A-\u202E\u2066-\u2069\uFEFF]") {
        $status = "unreadable"
        $issues.Add("invisible formatting characters") | Out-Null
    }
    if ($trimmed -match '[\u00C3\u00C2\u00E2][\s\S]|\u00F0\u0178|\u951F\u65A4\u62F7|\u70EB\u70EB\u70EB|\u5C6F\u5C6F\u5C6F|\u93C3\u30E6\u6E61|\u5A13\u2541\u5BB3') {
        $status = "unreadable"
        $issues.Add("possible mojibake") | Out-Null
    }
    if ($trimmed.Length -gt 256) {
        if ($status -eq "readable") {
            $status = "suspicious"
        }
        $issues.Add("unusually long identity value") | Out-Null
    }
    $readableCharacters = [regex]::Matches($trimmed, "[\p{L}\p{N}]").Count
    if ($readableCharacters -lt 2) {
        if ($status -eq "readable") {
            $status = "suspicious"
        }
        $issues.Add("too few readable letters or digits") | Out-Null
    }
    if ($trimmed -match "([^\s])\1{31,}") {
        if ($status -eq "readable") {
            $status = "suspicious"
        }
        $issues.Add("long repeated-character sequence") | Out-Null
    }

    return [pscustomobject]@{
        Field = $FieldName
        Status = $status
        Issues = @($issues | Select-Object -Unique)
    }
}

function Get-DeviceIdentityAssessment {
    param(
        [object]$Manufacturer,
        [object]$Model,
        [object]$SystemFamily,
        [object]$MotherboardManufacturer,
        [object]$MotherboardProduct
    )

    $fields = @(
        (Get-DeviceIdentityTextAssessment -FieldName "Manufacturer" -Value $Manufacturer)
        (Get-DeviceIdentityTextAssessment -FieldName "Model" -Value $Model)
        (Get-DeviceIdentityTextAssessment -FieldName "SystemFamily" -Value $SystemFamily)
        (Get-DeviceIdentityTextAssessment -FieldName "MotherboardManufacturer" -Value $MotherboardManufacturer)
        (Get-DeviceIdentityTextAssessment -FieldName "MotherboardProduct" -Value $MotherboardProduct)
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($field in $fields) {
        if ($field.Status -in @("unreadable", "suspicious") -and $field.Issues.Count -gt 0) {
            $warnings.Add("$($field.Field): $($field.Issues -join ', ')") | Out-Null
        }
    }

    $nonRedacted = @($fields | Where-Object { $_.Status -ne "redacted" })
    $modelField = @($fields | Where-Object { $_.Field -eq "Model" }) | Select-Object -First 1
    $boardProductField = @($fields | Where-Object { $_.Field -eq "MotherboardProduct" }) | Select-Object -First 1
    $overallStatus = if ($nonRedacted.Count -eq 0) {
        "redacted"
    }
    elseif ($modelField.Status -eq "unreadable") {
        "unreadable"
    }
    elseif ($modelField.Status -eq "suspicious") {
        "suspicious"
    }
    elseif ($modelField.Status -eq "readable") {
        "readable"
    }
    elseif ($boardProductField.Status -eq "readable") {
        "partial"
    }
    elseif ($boardProductField.Status -eq "unreadable") {
        "unreadable"
    }
    elseif ($boardProductField.Status -eq "suspicious") {
        "suspicious"
    }
    elseif (@($nonRedacted | Where-Object { $_.Status -eq "readable" }).Count -gt 0) {
        "partial"
    }
    else {
        "unknown"
    }

    return [pscustomobject]@{
        Status = $overallStatus
        Fields = @($fields)
        Warnings = @($warnings | Select-Object -Unique)
    }
}
