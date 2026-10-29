$script:RestrictedContextAccessDeniedThreshold = 5

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
