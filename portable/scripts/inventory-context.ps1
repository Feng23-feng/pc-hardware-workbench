$script:RestrictedContextAccessDeniedThreshold = 5

function Format-Capacity {
    param([Nullable[double]]$Bytes)

    if ($null -eq $Bytes -or $Bytes -le 0) {
        return $null
    }

    $units = @("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    $value = [double]$Bytes
    $index = 0

    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value /= 1024
        $index++
    }

    return "{0:N2} {1}" -f $value, $units[$index]
}

function ConvertFrom-NvidiaNumericValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '(?i)N/?A') {
        return $null
    }

    $normalized = $Value.Trim() -replace ',', '.'
    $number = 0.0
    if ([double]::TryParse(
        $normalized,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return $null
}

function Get-NvidiaPowerLimitFields {
    param(
        [AllowNull()][string]$Requested,
        [AllowNull()][string]$Effective,
        [AllowNull()][string]$Default,
        [AllowNull()][string]$Minimum,
        [AllowNull()][string]$Maximum,
        [string]$Source = "nvidia-smi"
    )

    $requestedLimitW = ConvertFrom-NvidiaNumericValue $Requested
    $effectiveLimitW = ConvertFrom-NvidiaNumericValue $Effective
    $currentLimitW = if ($null -ne $effectiveLimitW) {
        $effectiveLimitW
    }
    elseif ($null -ne $requestedLimitW) {
        $requestedLimitW
    }
    else {
        $null
    }

    return [pscustomobject]@{
        RequestedLimitW = $requestedLimitW
        EffectiveLimitW = $effectiveLimitW
        CurrentLimitW = $currentLimitW
        DefaultLimitW = ConvertFrom-NvidiaNumericValue $Default
        MinLimitW = ConvertFrom-NvidiaNumericValue $Minimum
        MaxLimitW = ConvertFrom-NvidiaNumericValue $Maximum
        Source = $Source
    }
}

function Get-InventoryObjectValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-GpuAdapterKind {
    param([AllowNull()][string]$PnpDeviceId)

    if ([string]::IsNullOrWhiteSpace($PnpDeviceId)) {
        return "unknown"
    }

    $normalized = $PnpDeviceId.Trim().ToUpperInvariant()
    if ($normalized -match '^(PCI|USB)\\') {
        return "physical"
    }
    if ($normalized -match '^ROOT\\DISPLAY' -or $normalized -match '^SWD\\') {
        return "virtual"
    }
    return "unknown"
}

function Get-MemorySlotSummary {
    param(
        [AllowNull()][object]$ReportedTotalSlots,
        [AllowNull()][object]$PopulatedSlots,
        [AllowNull()][string]$SlotSource,
        [AllowNull()][string]$ModuleSource
    )

    $total = $null
    $populated = $null
    if ($null -ne $ReportedTotalSlots) {
        $parsedTotal = 0
        if ([int]::TryParse([string]$ReportedTotalSlots, [ref]$parsedTotal) -and
            $parsedTotal -gt 0 -and
            $parsedTotal -le 256) {
            $total = $parsedTotal
        }
    }
    if ($null -ne $PopulatedSlots) {
        $parsedPopulated = 0
        if ([int]::TryParse([string]$PopulatedSlots, [ref]$parsedPopulated) -and
            $parsedPopulated -ge 0 -and
            $parsedPopulated -lt 0xFFFF) {
            $populated = $parsedPopulated
        }
    }

    $empty = if ($null -ne $total -and $null -ne $populated -and $populated -le $total) {
        $total - $populated
    }
    else {
        $null
    }
    $dataQuality = if ($null -ne $total -and $null -ne $populated -and $populated -le $total) {
        "reported"
    }
    elseif ($null -ne $total -or $null -ne $populated) {
        if ($null -ne $total -and $null -ne $populated) {
            "unreliable"
        }
        else {
            "partial"
        }
    }
    else {
        "unavailable"
    }

    $sourceParts = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SlotSource)) {
        $sourceParts.Add($SlotSource) | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($ModuleSource)) {
        $sourceParts.Add($ModuleSource) | Out-Null
    }

    return [pscustomobject]@{
        TotalSlots = $total
        PopulatedSlots = $populated
        EmptySlots = $empty
        DataQuality = $dataQuality
        Source = if ($sourceParts.Count -gt 0) { $sourceParts -join " + " } else { $null }
    }
}

function Merge-MonitorInventory {
    param(
        [AllowNull()][object[]]$IdentityMonitors,
        [AllowNull()][object[]]$ActiveDisplays
    )

    $identities = @($IdentityMonitors | Where-Object { $null -ne $_ })
    $capabilities = @($ActiveDisplays | Where-Object { $null -ne $_ })
    $usedCapabilities = [bool[]]::new($capabilities.Count)
    $result = New-Object System.Collections.Generic.List[object]

    foreach ($identity in $identities) {
        $matchIndex = -1
        $identityProductCode = ([string](Get-InventoryObjectValue $identity "ProductCode")).Trim()
        if (-not [string]::IsNullOrWhiteSpace($identityProductCode)) {
            for ($index = 0; $index -lt $capabilities.Count; $index++) {
                if ($usedCapabilities[$index]) { continue }
                $candidateCode = ([string](Get-InventoryObjectValue $capabilities[$index] "ProductCode")).Trim()
                if ($candidateCode -ieq $identityProductCode) {
                    $matchIndex = $index
                    break
                }
            }
        }

        if ($matchIndex -lt 0) {
            $identityModel = ([string](Get-InventoryObjectValue $identity "Model")).Trim()
            if (-not [string]::IsNullOrWhiteSpace($identityModel)) {
                for ($index = 0; $index -lt $capabilities.Count; $index++) {
                    if ($usedCapabilities[$index]) { continue }
                    $candidateModel = ([string](Get-InventoryObjectValue $capabilities[$index] "Model")).Trim()
                    if ($candidateModel -ieq $identityModel) {
                        $matchIndex = $index
                        break
                    }
                }
            }
        }

        $capability = if ($matchIndex -ge 0) {
            $usedCapabilities[$matchIndex] = $true
            $capabilities[$matchIndex]
        }
        else {
            $null
        }

        $manufacturer = Get-InventoryObjectValue $identity "Manufacturer"
        if ([string]::IsNullOrWhiteSpace([string]$manufacturer)) {
            $manufacturer = Get-InventoryObjectValue $capability "Manufacturer"
        }
        $model = Get-InventoryObjectValue $identity "Model"
        if ([string]::IsNullOrWhiteSpace([string]$model)) {
            $model = Get-InventoryObjectValue $capability "Model"
        }
        $productCode = Get-InventoryObjectValue $identity "ProductCode"
        if ([string]::IsNullOrWhiteSpace([string]$productCode)) {
            $productCode = Get-InventoryObjectValue $capability "ProductCode"
        }
        $active = Get-InventoryObjectValue $capability "Active"
        if ($null -eq $active) {
            $active = Get-InventoryObjectValue $identity "Active"
        }

        $result.Add([pscustomobject]@{
            Manufacturer = $manufacturer
            Model = $model
            ProductCode = $productCode
            Active = $active
            AdapterName = Get-InventoryObjectValue $capability "AdapterName"
            CurrentWidth = Get-InventoryObjectValue $capability "CurrentWidth"
            CurrentHeight = Get-InventoryObjectValue $capability "CurrentHeight"
            CurrentRefreshHz = Get-InventoryObjectValue $capability "CurrentRefreshHz"
            BitsPerPixel = Get-InventoryObjectValue $capability "BitsPerPixel"
            DisplayModeSource = Get-InventoryObjectValue $capability "DisplayModeSource"
            HdrSupported = Get-InventoryObjectValue $capability "HdrSupported"
            HdrEnabled = Get-InventoryObjectValue $capability "HdrEnabled"
            HdrStatus = Get-InventoryObjectValue $capability "HdrStatus"
            AdvancedColorEnabled = Get-InventoryObjectValue $capability "AdvancedColorEnabled"
            WideColorEnforced = Get-InventoryObjectValue $capability "WideColorEnforced"
            AdvancedColorForceDisabled = Get-InventoryObjectValue $capability "AdvancedColorForceDisabled"
            AdvancedColorBitsPerColorChannel = Get-InventoryObjectValue $capability "AdvancedColorBitsPerColorChannel"
            AdvancedColorEncoding = Get-InventoryObjectValue $capability "AdvancedColorEncoding"
            HdrQueryResult = Get-InventoryObjectValue $capability "HdrQueryResult"
            HdrSource = Get-InventoryObjectValue $capability "HdrSource"
            DisplayColorSpace = Get-InventoryObjectValue $capability "DisplayColorSpace"
            DxgiColorSpace = Get-InventoryObjectValue $capability "DxgiColorSpace"
            DxgiBitsPerColor = Get-InventoryObjectValue $capability "DxgiBitsPerColor"
            MaxLuminance = Get-InventoryObjectValue $capability "MaxLuminance"
            MaxFullFrameLuminance = Get-InventoryObjectValue $capability "MaxFullFrameLuminance"
            Source = if ($null -ne $capability) {
                "CIM/WMI identity + active-display capabilities"
            }
            else {
                "CIM/WMI identity"
            }
        }) | Out-Null
    }

    for ($index = 0; $index -lt $capabilities.Count; $index++) {
        if ($usedCapabilities[$index]) { continue }
        $capability = $capabilities[$index]
        $result.Add([pscustomobject]@{
            Manufacturer = Get-InventoryObjectValue $capability "Manufacturer"
            Model = Get-InventoryObjectValue $capability "Model"
            ProductCode = Get-InventoryObjectValue $capability "ProductCode"
            Active = Get-InventoryObjectValue $capability "Active"
            AdapterName = Get-InventoryObjectValue $capability "AdapterName"
            CurrentWidth = Get-InventoryObjectValue $capability "CurrentWidth"
            CurrentHeight = Get-InventoryObjectValue $capability "CurrentHeight"
            CurrentRefreshHz = Get-InventoryObjectValue $capability "CurrentRefreshHz"
            BitsPerPixel = Get-InventoryObjectValue $capability "BitsPerPixel"
            DisplayModeSource = Get-InventoryObjectValue $capability "DisplayModeSource"
            HdrSupported = Get-InventoryObjectValue $capability "HdrSupported"
            HdrEnabled = Get-InventoryObjectValue $capability "HdrEnabled"
            HdrStatus = Get-InventoryObjectValue $capability "HdrStatus"
            AdvancedColorEnabled = Get-InventoryObjectValue $capability "AdvancedColorEnabled"
            WideColorEnforced = Get-InventoryObjectValue $capability "WideColorEnforced"
            AdvancedColorForceDisabled = Get-InventoryObjectValue $capability "AdvancedColorForceDisabled"
            AdvancedColorBitsPerColorChannel = Get-InventoryObjectValue $capability "AdvancedColorBitsPerColorChannel"
            AdvancedColorEncoding = Get-InventoryObjectValue $capability "AdvancedColorEncoding"
            HdrQueryResult = Get-InventoryObjectValue $capability "HdrQueryResult"
            HdrSource = Get-InventoryObjectValue $capability "HdrSource"
            DisplayColorSpace = Get-InventoryObjectValue $capability "DisplayColorSpace"
            DxgiColorSpace = Get-InventoryObjectValue $capability "DxgiColorSpace"
            DxgiBitsPerColor = Get-InventoryObjectValue $capability "DxgiBitsPerColor"
            MaxLuminance = Get-InventoryObjectValue $capability "MaxLuminance"
            MaxFullFrameLuminance = Get-InventoryObjectValue $capability "MaxFullFrameLuminance"
            Source = "active-display fallback"
        }) | Out-Null
    }

    return $result.ToArray()
}

function Test-CollectionWarningIsAccessDenied {
    param([AllowNull()][string]$Warning)

    if ([string]::IsNullOrWhiteSpace($Warning)) {
        return $false
    }
    return $Warning -match '(?i)access is denied|access denied|\u62D2\u7EDD\u8BBF\u95EE|\u6CA1\u6709\u6267\u884C\u6B64\u64CD\u4F5C\u6240\u9700\u7684\u6743\u9650|unauthorized|permission denied|do not have permission'
}

function Get-CollectionProcessClassification {
    param(
        [bool]$IsElevated,
        [bool]$RestrictedEnvironmentHint,
        [int]$AccessDeniedWarningCount
    )

    if ($IsElevated) {
        return [pscustomobject]@{
            ProcessClass = "elevated-user"
            Reason = "elevated-process"
            AccessDeniedThreshold = $script:RestrictedContextAccessDeniedThreshold
        }
    }
    if ($RestrictedEnvironmentHint) {
        return [pscustomobject]@{
            ProcessClass = "restricted-agent"
            Reason = "environment-hint"
            AccessDeniedThreshold = $script:RestrictedContextAccessDeniedThreshold
        }
    }
    # Broad denial across several core CIM classes is evidence of a restricted
    # process context. A single denied class can instead be an ordinary
    # permissions or provider limitation.
    if ($AccessDeniedWarningCount -ge $script:RestrictedContextAccessDeniedThreshold) {
        return [pscustomobject]@{
            ProcessClass = "restricted-agent"
            Reason = "broad-cim-denial"
            AccessDeniedThreshold = $script:RestrictedContextAccessDeniedThreshold
        }
    }
    return [pscustomobject]@{
        ProcessClass = "standard-user"
        Reason = "no-restricted-context-evidence"
        AccessDeniedThreshold = $script:RestrictedContextAccessDeniedThreshold
    }
}

function Get-BatteryCollectionStatus {
    param(
        [AllowNull()][object]$Battery,
        [AllowNull()][string]$BatteryState
    )

    if ($null -ne $Battery) {
        return "available"
    }
    if ($BatteryState -in @("not-present", "unavailable-permission", "unavailable")) {
        return $BatteryState
    }
    return "unavailable"
}
