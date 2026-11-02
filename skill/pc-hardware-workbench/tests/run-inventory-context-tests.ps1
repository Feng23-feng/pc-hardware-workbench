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

$resolvedHelper = (Resolve-Path -LiteralPath $HelperPath).Path
. $resolvedHelper

$chineseDenied = ([char]0x62D2).ToString() + ([char]0x7EDD).ToString() +
    ([char]0x8BBF).ToString() + ([char]0x95EE).ToString()
Assert-True (Test-CollectionWarningIsAccessDenied -Warning "CIM: $chineseDenied") "Localized access denial was not recognized."
$windowsPermissionDenied = ([string][char]0x4F60) + ([char]0x6CA1) + ([char]0x6709) +
    ([char]0x6267) + ([char]0x884C) + ([char]0x6B64) + ([char]0x64CD) +
    ([char]0x4F5C) + ([char]0x6240) + ([char]0x9700) + ([char]0x7684) +
    ([char]0x6743) + ([char]0x9650)
Assert-True (
    Test-CollectionWarningIsAccessDenied -Warning "powercfg.exe: $windowsPermissionDenied"
) "Windows localized permission denial was not recognized."
Assert-True (Test-CollectionWarningIsAccessDenied -Warning "Access is denied.") "English access denial was not recognized."
Assert-True (Test-CollectionWarningIsAccessDenied -Warning "Access denied") "Short English access denial was not recognized."
Assert-True (Test-CollectionWarningIsAccessDenied -Warning "permission denied") "Generic permission denial was not recognized."
Assert-True (-not (Test-CollectionWarningIsAccessDenied -Warning "provider unavailable")) "Unrelated warning was misclassified as access denial."

$standard = Get-CollectionProcessClassification -IsElevated $false -RestrictedEnvironmentHint $false -AccessDeniedWarningCount 4
Assert-True ($standard.ProcessClass -eq "standard-user") "Four denied classes were enough to classify a restricted process."
$restrictedByEvidence = Get-CollectionProcessClassification -IsElevated $false -RestrictedEnvironmentHint $false -AccessDeniedWarningCount 5
Assert-True (
    $restrictedByEvidence.ProcessClass -eq "restricted-agent" -and
    $restrictedByEvidence.Reason -eq "broad-cim-denial"
) "Broad CIM denial did not classify a restricted process."
$restrictedByHint = Get-CollectionProcessClassification -IsElevated $false -RestrictedEnvironmentHint $true -AccessDeniedWarningCount 0
Assert-True ($restrictedByHint.ProcessClass -eq "restricted-agent") "A restricted environment hint was ignored."
$elevated = Get-CollectionProcessClassification -IsElevated $true -RestrictedEnvironmentHint $true -AccessDeniedWarningCount 20
Assert-True ($elevated.ProcessClass -eq "elevated-user") "Elevated context was not preferred over hints."

Assert-True ((Get-BatteryCollectionStatus -Battery ([pscustomobject]@{}) -BatteryState "unavailable-permission") -eq "available") "Present battery data was not classified as available."
Assert-True ((Get-BatteryCollectionStatus -Battery $null -BatteryState "not-present") -eq "not-present") "Missing battery data was not classified as not-present."
Assert-True ((Get-BatteryCollectionStatus -Battery $null -BatteryState "unavailable-permission") -eq "unavailable-permission") "Permission-limited battery data was not preserved."
Assert-True ((Get-BatteryCollectionStatus -Battery $null -BatteryState "unavailable") -eq "unavailable") "Other unavailable battery data was not preserved."

Assert-True ((Format-Capacity 17179869184) -eq "16.00 GiB") "Binary memory capacity was not formatted as GiB."
Assert-True ((Format-Capacity 1099511627776) -eq "1.00 TiB") "Binary disk capacity was not formatted as TiB."

$powerLimits = Get-NvidiaPowerLimitFields `
    -Requested "N/A" `
    -Effective "150" `
    -Default "65" `
    -Minimum "5" `
    -Maximum "160"
Assert-True ($null -eq $powerLimits.RequestedLimitW) "N/A requested power limit was converted to a number."
Assert-True ($powerLimits.EffectiveLimitW -eq 150) "Effective power limit was not parsed."
Assert-True ($powerLimits.CurrentLimitW -eq 150) "Current limit did not prefer the effective power limit."
Assert-True ($powerLimits.DefaultLimitW -eq 65) "Default power limit was not parsed."
Assert-True ($powerLimits.MinLimitW -eq 5) "Minimum power limit was not parsed."
Assert-True ($powerLimits.MaxLimitW -eq 160) "Maximum power limit was not parsed."

$requestedOnlyPowerLimit = Get-NvidiaPowerLimitFields `
    -Requested "140" `
    -Effective "N/A" `
    -Default "65" `
    -Minimum "5" `
    -Maximum "160"
Assert-True ($requestedOnlyPowerLimit.RequestedLimitW -eq 140) "Requested power limit was not parsed."
Assert-True ($null -eq $requestedOnlyPowerLimit.EffectiveLimitW) "N/A effective power limit was converted to a number."
Assert-True ($requestedOnlyPowerLimit.CurrentLimitW -eq 140) "Current limit did not fall back to the requested value."

Assert-True ((Get-GpuAdapterKind -PnpDeviceId "PCI\VEN_10DE&DEV_2C59") -eq "physical") "A PCI display adapter was not classified as physical."
Assert-True ((Get-GpuAdapterKind -PnpDeviceId "USB\VID_1234") -eq "physical") "A USB display adapter was not classified as physical."
Assert-True ((Get-GpuAdapterKind -PnpDeviceId "ROOT\DISPLAY\0000") -eq "virtual") "A root display device was not classified as virtual."
Assert-True ((Get-GpuAdapterKind -PnpDeviceId "SWD\TEST\0000") -eq "virtual") "A software device was not classified as virtual."
Assert-True ((Get-GpuAdapterKind -PnpDeviceId "ACPI\TEST") -eq "unknown") "An unclassified display bus was not kept unknown."

$reportedSlots = Get-MemorySlotSummary `
    -ReportedTotalSlots 2 `
    -PopulatedSlots 2 `
    -SlotSource "SMBIOS type 16" `
    -ModuleSource "SMBIOS fallback"
Assert-True ($reportedSlots.TotalSlots -eq 2) "Reported memory slot count was not preserved."
Assert-True ($reportedSlots.PopulatedSlots -eq 2) "Populated memory slot count was not preserved."
Assert-True ($reportedSlots.EmptySlots -eq 0) "Confirmed empty memory slot count was not calculated."
Assert-True ($reportedSlots.DataQuality -eq "reported") "Complete memory slot evidence was not marked reported."

$partialSlots = Get-MemorySlotSummary `
    -ReportedTotalSlots $null `
    -PopulatedSlots 2 `
    -SlotSource $null `
    -ModuleSource "CIM/WMI"
Assert-True ($null -eq $partialSlots.TotalSlots) "Missing total slots were invented."
Assert-True ($null -eq $partialSlots.EmptySlots) "Empty slots were inferred without a reported total."
Assert-True ($partialSlots.DataQuality -eq "partial") "Partial memory slot evidence was not marked partial."

$unreliableSlots = Get-MemorySlotSummary `
    -ReportedTotalSlots 1 `
    -PopulatedSlots 2 `
    -SlotSource "CIM/WMI" `
    -ModuleSource "CIM/WMI"
Assert-True ($null -eq $unreliableSlots.EmptySlots) "Conflicting slot counts produced an empty-slot value."
Assert-True ($unreliableSlots.DataQuality -eq "unreliable") "Conflicting slot counts were not marked unreliable."

$implausibleSlots = Get-MemorySlotSummary `
    -ReportedTotalSlots 65028 `
    -PopulatedSlots 2 `
    -SlotSource "SMBIOS type 16" `
    -ModuleSource "SMBIOS fallback"
Assert-True ($null -eq $implausibleSlots.TotalSlots) "An implausible total-slot count was accepted."
Assert-True ($null -eq $implausibleSlots.EmptySlots) "An implausible total-slot count produced empty slots."
Assert-True ($implausibleSlots.DataQuality -eq "partial") "An implausible total-slot count was not downgraded to partial."

$identityMonitors = @(
    [pscustomobject]@{
        Manufacturer = "AUO"
        Model = "B160QAN02.3"
        ProductCode = "7DB2"
        Active = $true
    },
    [pscustomobject]@{
        Manufacturer = "HWV"
        Model = "QSN-CAB"
        ProductCode = "6346"
        Active = $true
    }
)
$activeDisplays = @(
    [pscustomobject]@{
        Manufacturer = $null
        Model = "Generic PnP Monitor"
        ProductCode = "7DB2"
        Active = $true
        AdapterName = "NVIDIA GeForce RTX 5070 Ti Laptop GPU"
        CurrentWidth = 2560
        CurrentHeight = 1600
        CurrentRefreshHz = 240
        HdrStatus = "On"
        DisplayColorSpace = "RGB_FULL_G10_NONE_P709"
        Source = "EnumDisplayDevices active-display fallback"
    },
    [pscustomobject]@{
        Manufacturer = $null
        Model = "QSN-CAB"
        ProductCode = "6346"
        Active = $true
        AdapterName = "NVIDIA GeForce RTX 5070 Ti Laptop GPU"
        CurrentWidth = 1920
        CurrentHeight = 1080
        CurrentRefreshHz = 319
        HdrStatus = "Not supported"
        DisplayColorSpace = "RGB_FULL_G22_NONE_P709"
        Source = "EnumDisplayDevices active-display fallback"
    },
    [pscustomobject]@{
        Manufacturer = $null
        Model = "Fallback Only"
        ProductCode = "FFFF"
        Active = $true
        AdapterName = "Test Adapter"
        CurrentWidth = 1280
        CurrentHeight = 720
        CurrentRefreshHz = 60
        HdrStatus = "Unavailable"
        Source = "EnumDisplayDevices active-display fallback"
    }
)
$mergedMonitors = @(Merge-MonitorInventory `
    -IdentityMonitors $identityMonitors `
    -ActiveDisplays $activeDisplays)
Assert-True ($mergedMonitors.Count -eq 3) "Monitor merge lost or duplicated an identity/fallback record."
Assert-True ($mergedMonitors[0].Manufacturer -eq "AUO") "Monitor merge did not preserve EDID identity."
Assert-True ($mergedMonitors[0].Model -eq "B160QAN02.3") "Monitor merge replaced the EDID model with fallback text."
Assert-True ($mergedMonitors[0].CurrentWidth -eq 2560) "Monitor merge did not attach the active current width."
Assert-True ($mergedMonitors[0].HdrStatus -eq "On") "Monitor merge did not attach the HDR state."
Assert-True ($mergedMonitors[0].AdapterName -eq "NVIDIA GeForce RTX 5070 Ti Laptop GPU") "Monitor merge did not attach the adapter."
Assert-True ($mergedMonitors[2].Model -eq "Fallback Only") "Monitor merge did not preserve an unmatched active-display fallback."

if ($failures.Count -gt 0) {
    Write-Host "Inventory context tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Inventory context tests: PASS" -ForegroundColor Green
