[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$HelperPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Get-ShapeSignature {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Path = '$'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    function Add-ShapeNode {
        param(
            [AllowNull()]
            [object]$NodeValue,
            [string]$NodePath,
            [System.Collections.Generic.List[string]]$Lines
        )

        if ($null -eq $NodeValue) {
            $Lines.Add("$NodePath|<leaf>") | Out-Null
            return
        }
        if ($NodeValue -is [string] -or $NodeValue -is [System.ValueType]) {
            $Lines.Add("$NodePath|<leaf>") | Out-Null
            return
        }
        if ($NodeValue -is [System.Collections.IEnumerable]) {
            $items = @($NodeValue)
            $Lines.Add("$NodePath|<array:$($items.Count)>") | Out-Null
            for ($index = 0; $index -lt $items.Count; $index++) {
                Add-ShapeNode `
                    -NodeValue $items[$index] `
                    -NodePath "$NodePath[$index]" `
                    -Lines $Lines
            }
            return
        }

        $properties = @(
            $NodeValue.PSObject.Properties |
                Where-Object {
                    $_.MemberType -in @("Property", "NoteProperty", "AliasProperty")
                } |
                Sort-Object Name
        )
        $Lines.Add("$NodePath|<object>") | Out-Null
        foreach ($property in $properties) {
            Add-ShapeNode `
                -NodeValue $property.Value `
                -NodePath "$NodePath.$($property.Name)" `
                -Lines $Lines
        }
    }

    Add-ShapeNode -NodeValue $Value -NodePath $Path -Lines $lines
    return [string[]]$lines
}

$resolvedHelper = (Resolve-Path -LiteralPath $HelperPath).Path
. $resolvedHelper

$normal = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value "EX-7A00"
Assert-True ($normal.Status -eq "readable") "A normal alphanumeric model code was not readable."

$localizedValue = [string]([char]0x8054) + [string]([char]0x60F3)
$localized = Get-DeviceIdentityTextAssessment -FieldName "Manufacturer" -Value $localizedValue
Assert-True ($localized.Status -eq "readable") "A normal localized manufacturer name was rejected."

$redacted = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value "[redacted]"
Assert-True ($redacted.Status -eq "redacted") "Redacted identity was not marked redacted."

$placeholder = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value "To be filled by O.E.M."
Assert-True ($placeholder.Status -eq "unknown") "A placeholder OEM model was not marked unknown."

$replacement = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value ("MS-" + [char]0xFFFD + [char]0xFFFD)
Assert-True ($replacement.Status -eq "unreadable") "Replacement characters were not marked unreadable."

$control = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value ("EX-7A00" + [char]0x1B + "[31m")
Assert-True ($control.Status -eq "unreadable") "Control characters were not marked unreadable."

$invisible = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value ("MS-" + [char]0x200B + "7D25")
Assert-True ($invisible.Status -eq "unreadable") "Invisible formatting characters were not marked unreadable."

$mojibakeValue = "MS-" + [string]([char]0x00C3) + [string]([char]0x0192) + [string]([char]0x00C2) + [string]([char]0x00A9)
$mojibake = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value $mojibakeValue
Assert-True ($mojibake.Status -eq "unreadable") "A common mojibake sequence was not marked unreadable."

$chineseMojibakeValue = "MS-" + [string]([char]0x93C3) + [string]([char]0x30E6) + [string]([char]0x6E61)
$chineseMojibake = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value $chineseMojibakeValue
Assert-True ($chineseMojibake.Status -eq "unreadable") "A common Chinese mojibake sequence was treated as readable."

$replacementMojibakeValue = "MS-" + [string]([char]0x951F) + [string]([char]0x65A4) + [string]([char]0x62F7)
$replacementMojibake = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value $replacementMojibakeValue
Assert-True ($replacementMojibake.Status -eq "unreadable") "The common Chinese replacement-mojibake sequence was treated as readable."

$longValue = "A" * 300
$longAssessment = Get-DeviceIdentityTextAssessment -FieldName "Model" -Value $longValue
Assert-True ($longAssessment.Status -eq "suspicious") "An unusually long identity was not marked suspicious."

$safeDisplay = ConvertTo-DeviceIdentityDisplay -Value ("<script>" + [char]0x1B + ("A" + [char]0xFFFD))
Assert-True ($safeDisplay.Contains("&lt;script&gt;")) "Identity display did not escape HTML delimiters."
Assert-True ($safeDisplay.Contains("[unreadable]")) "Identity display did not replace replacement characters."
Assert-True (-not ($safeDisplay -match "[\x00-\x1F\x7F]")) "Identity display retained control characters."

$markdownIdentity = '[MSI](https://example.invalid) ![x](https://example.invalid/a.png) **bold** `<tag>`'
$safeMarkdown = ConvertTo-DeviceIdentityMarkdown -Value $markdownIdentity
Assert-True ($safeMarkdown.StartsWith('`` ') -and $safeMarkdown.EndsWith(' ``')) "Identity Markdown was not wrapped in a fence longer than its backtick run."
Assert-True ($safeMarkdown.Contains($markdownIdentity)) "Identity Markdown changed the readable identity instead of isolating it."

$noBacktickMarkdown = ConvertTo-DeviceIdentityMarkdown -Value "EX-7A00"
$oneBacktick = [string][char]0x60
Assert-True ($noBacktickMarkdown -eq "$oneBacktick EX-7A00 $oneBacktick") "A normal identity did not use a one-backtick Markdown code span."

$trickyMarkdown = ConvertTo-DeviceIdentityMarkdown -Value ("A" + $oneBacktick + "B" + ($oneBacktick * 2) + "C" + ($oneBacktick * 3) + "D")
$fourBackticks = $oneBacktick * 4
Assert-True ($trickyMarkdown.StartsWith("$fourBackticks ") -and $trickyMarkdown.EndsWith(" $fourBackticks")) "Embedded backtick runs can escape the identity code span."

$unsafeExternalText = "[click](x)" + [char]0x009B + [char]0x061C + [char]0xFE0F
$safeExternalText = ConvertTo-SafeMarkdownText -Value $unsafeExternalText
Assert-True ($safeExternalText.StartsWith("$oneBacktick ") -and $safeExternalText.EndsWith(" $oneBacktick")) "Hardware-derived Markdown text was not isolated."
Assert-True (-not ($safeExternalText -match "[\u009B\u061C\uFE0F]")) "Hardware-derived Markdown text retained unsafe invisible characters."
Assert-True ($safeExternalText.Contains("[click](x)")) "Safe Markdown changed the readable external text."

$memoryFixture = @(
    [pscustomobject]@{
        Manufacturer = "Micron"
        PartNumber = "MTC-EXAMPLE"
        Slot = "DIMM_A1"
        Bank = "BANK 0"
        Capacity = "16 GB"
    }
    [pscustomobject]@{
        Manufacturer = "Samsung"
        PartNumber = "SEC-EXAMPLE"
        Slot = "DIMM_B1"
        Bank = "BANK 1"
        Capacity = "16 GB"
    }
)
$diskFixture = @(
    [pscustomobject]@{
        Model = "Example NVMe"
        ProductRevision = "FW-123"
        DeviceNumber = 2
        Size = "1 TB"
    }
)
$volumeFixture = @(
    [pscustomobject]@{
        DriveLetter = "D:"
        Label = "Private Project"
        PhysicalDisk = "Example NVMe"
        DiskNumber = 2
        Size = "1 TB"
    }
    [pscustomobject]@{
        DriveLetter = "E:"
        Label = ""
        PhysicalDisk = ""
        DiskNumber = $null
        Size = "500 GB"
    }
    [pscustomobject]@{
        DriveLetter = "C:"
        Label = "Windows"
        PhysicalDisk = "Example NVMe"
        DiskNumber = 2
        Size = "1 TB"
    }
)
$monitorFixture = @(
    [pscustomobject]@{
        Manufacturer = "Example Display Co"
        Model = "Monitor X"
        ProductCode = "ABC123"
        AdapterName = "NVIDIA GeForce RTX 5070 Ti Laptop GPU"
        CurrentWidth = 1920
    }
    [pscustomobject]@{
        Manufacturer = ""
        Model = ""
        ProductCode = ""
        AdapterName = "NVIDIA GeForce RTX 5070 Ti Laptop GPU"
        CurrentWidth = 1280
    }
    [pscustomobject]@{
        Manufacturer = ""
        Model = "Generic PnP Monitor"
        ProductCode = ""
        AdapterName = "NVIDIA GeForce RTX 5070 Ti Laptop GPU"
        CurrentWidth = 1920
    }
)
$batteryFixture = [pscustomobject]@{
    Manufacturer = "Example Battery Co"
    HealthPercent = 91
}
$standardInventory = [pscustomobject]@{
    MemoryModules = @($memoryFixture)
    PhysicalDisks = @($diskFixture)
    Volumes = @($volumeFixture)
    Monitors = @($monitorFixture)
    Battery = $batteryFixture
}
$redactedInventory = Get-RedactedInventoryData `
    -MemoryModules $memoryFixture `
    -PhysicalDisks $diskFixture `
    -Volumes $volumeFixture `
    -Monitors $monitorFixture `
    -Battery $batteryFixture
$standardShape = Get-ShapeSignature -Value $standardInventory
$redactedShape = Get-ShapeSignature -Value $redactedInventory
$shapeDifferences = @(Compare-Object -ReferenceObject $standardShape -DifferenceObject $redactedShape)
Assert-True ($shapeDifferences.Count -eq 0) "Redaction changed object keys or array lengths."

# Deliberately mutate in-memory fixtures to prove the shape assertions detect
# missing keys and shortened arrays. This does not mutate the tested Skill.
$missingKeyFixture = $standardInventory | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$missingKeyFixture.PSObject.Properties.Remove("Volumes")
$missingKeyDifferences = @(
    Compare-Object `
        -ReferenceObject $standardShape `
        -DifferenceObject (Get-ShapeSignature -Value $missingKeyFixture)
)
Assert-True ($missingKeyDifferences.Count -gt 0) "Shape verification did not detect a missing object key."

$shortArrayFixture = $standardInventory | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$shortArrayFixture.MemoryModules = @($shortArrayFixture.MemoryModules[0])
$shortArrayDifferences = @(
    Compare-Object `
        -ReferenceObject $standardShape `
        -DifferenceObject (Get-ShapeSignature -Value $shortArrayFixture)
)
Assert-True ($shortArrayDifferences.Count -gt 0) "Shape verification did not detect a shortened component array."

Assert-True ($redactedInventory.MemoryModules[0].Manufacturer -eq "[redacted]") "Redacted memory retained the manufacturer."
Assert-True ($redactedInventory.MemoryModules[0].PartNumber -eq "[redacted]") "Redacted memory retained the part number."
Assert-True ($redactedInventory.MemoryModules[0].Capacity -eq "16 GB") "Redaction removed a non-identifying memory capacity."
Assert-True ($redactedInventory.MemoryModules[0].Bank -eq "BANK 0") "Redaction removed the memory bank/channel evidence."
Assert-True ($redactedInventory.MemoryModules[1].Bank -eq "BANK 1") "Redaction removed the second memory bank/channel evidence."
Assert-True ($redactedInventory.MemoryModules[0].Slot -eq "DIMM_A1") "Redaction removed the first memory channel/slot locator."
Assert-True ($redactedInventory.MemoryModules[1].Slot -eq "DIMM_B1") "Redaction removed the second memory channel/slot locator."
Assert-True ($redactedInventory.PhysicalDisks[0].Model -match "Physical disk 2") "Redacted physical disk retained its model."
Assert-True ($redactedInventory.PhysicalDisks[0].ProductRevision -eq "[redacted]") "Redacted physical disk retained its firmware revision."
Assert-True ($redactedInventory.Volumes[0].Label -eq "[redacted]") "Redacted volume retained its label."
Assert-True ($redactedInventory.Volumes[1].Label -eq "") "Redaction invented a hidden label for an empty volume label."
Assert-True ($redactedInventory.Volumes[2].Label -eq "Windows") "Redaction hid the generic Windows volume label."
Assert-True ($redactedInventory.Volumes[0].PhysicalDisk -match "redacted model") "Redacted volume retained its physical-disk model."
Assert-True ($redactedInventory.Volumes[1].PhysicalDisk -eq "") "Redaction invented a hidden disk model for an empty volume mapping."
Assert-True ($redactedInventory.Monitors[0].ProductCode -eq "[redacted]") "Redacted monitor retained its product code."
Assert-True ($redactedInventory.Monitors[1].Manufacturer -eq "") "Redaction invented a hidden manufacturer for an unknown display."
Assert-True ($redactedInventory.Monitors[1].Model -eq "") "Redaction invented a hidden model for an unknown display."
Assert-True ($redactedInventory.Monitors[1].ProductCode -eq "") "Redaction invented a hidden product code for an unknown display."
Assert-True ($redactedInventory.Monitors[2].Model -eq "Generic PnP Monitor") "Redaction hid the generic PnP monitor model."
Assert-True ($redactedInventory.Monitors[0].AdapterName -eq $monitorFixture[0].AdapterName) "Redaction changed the monitor adapter name instead of preserving the declared GPU identity."
Assert-True ($redactedInventory.Monitors[0].CurrentWidth -eq 1920) "Redaction removed a non-identifying display capability."
Assert-True ($redactedInventory.Battery.Manufacturer -eq "[redacted]") "Redacted battery retained its manufacturer."
Assert-True ($redactedInventory.Battery.HealthPercent -eq 91) "Redaction removed non-identifying battery health."

$statusMappings = @{
    "readable" = "confirmed"
    "partial" = "unknown"
    "suspicious" = "unreadable"
    "unreadable" = "unreadable"
    "unknown" = "unknown"
    "redacted" = "unknown"
}
foreach ($entry in $statusMappings.GetEnumerator()) {
    $mapped = ConvertTo-DeviceIdentitySessionStatus -CollectorStatus $entry.Key
    Assert-True ($mapped -eq $entry.Value) "Collector status $($entry.Key) mapped to $mapped instead of $($entry.Value)."
}

$aggregateUnreadable = Get-DeviceIdentityAssessment `
    -Manufacturer "Example" `
    -Model ("Bad-" + [char]0xFFFD) `
    -SystemFamily "Example" `
    -MotherboardManufacturer "Example" `
    -MotherboardProduct "BOARD"
Assert-True ($aggregateUnreadable.Status -eq "unreadable") "An unreadable field did not make the aggregate identity unreadable."

$aggregatePartial = Get-DeviceIdentityAssessment `
    -Manufacturer "Example" `
    -Model "Default string" `
    -SystemFamily "Example" `
    -MotherboardManufacturer "Example" `
    -MotherboardProduct "BOARD"
Assert-True ($aggregatePartial.Status -eq "partial") "A readable-but-incomplete identity was not marked partial."

$aggregateNormalDesktop = Get-DeviceIdentityAssessment `
    -Manufacturer "Example" `
    -Model "EX-7A00" `
    -SystemFamily "" `
    -MotherboardManufacturer "Example" `
    -MotherboardProduct "BOARD"
Assert-True ($aggregateNormalDesktop.Status -eq "readable") "A readable model with an optional blank system family was incorrectly marked partial."

$aggregateOptionalFamilyUnreadable = Get-DeviceIdentityAssessment `
    -Manufacturer "Example" `
    -Model "EX-7A00" `
    -SystemFamily ("Bad-" + [char]0xFFFD) `
    -MotherboardManufacturer "Example" `
    -MotherboardProduct "BOARD"
Assert-True ($aggregateOptionalFamilyUnreadable.Status -eq "readable") "An optional field failure incorrectly downgraded a readable system model."
Assert-True (
    @($aggregateOptionalFamilyUnreadable.Warnings | Where-Object { $_ -match "SystemFamily" }).Count -eq 1
) "The optional field failure was not retained as a warning."

$aggregateOptionalBoardUnreadable = Get-DeviceIdentityAssessment `
    -Manufacturer "Example" `
    -Model "EX-7A00" `
    -SystemFamily "Example" `
    -MotherboardManufacturer "Example" `
    -MotherboardProduct ("Bad-" + [char]0xFFFD)
Assert-True ($aggregateOptionalBoardUnreadable.Status -eq "readable") "A board-field failure incorrectly downgraded a readable system model."

$aggregateRedacted = Get-DeviceIdentityAssessment `
    -Manufacturer "[redacted]" `
    -Model "[redacted]" `
    -SystemFamily "[redacted]" `
    -MotherboardManufacturer "[redacted]" `
    -MotherboardProduct "[redacted]"
Assert-True ($aggregateRedacted.Status -eq "redacted") "A fully redacted identity was not marked redacted."

if ($failures.Count -gt 0) {
    Write-Host "Device identity tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Device identity tests: PASS" -ForegroundColor Green
