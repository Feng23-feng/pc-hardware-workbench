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

if ($failures.Count -gt 0) {
    Write-Host "Inventory context tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Inventory context tests: PASS" -ForegroundColor Green
