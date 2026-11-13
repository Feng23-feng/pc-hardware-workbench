[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("NVIDIA", "AMD", "Intel")]
    [string]$Vendor,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Desktop", "Laptop", "MoDT", "Other")]
    [string]$FormFactor,

    [string]$GpuModel = "",
    [string]$BoardModel = "",
    [ValidateSet("Auto", "assumed-stock", "declared-stock", "declared-unlocked", "detected-mismatch")]
    [string]$PowerLimitModificationState = "Auto",
    [ValidateSet("unknown", "user-declared", "vendor-tool", "monitoring-log", "vbios-string")]
    [string]$PowerLimitEvidenceSource = "unknown",
    [double]$StockPowerLimitWatts = 0,
    [double]$CurrentPowerLimitWatts = 0,
    [double]$DynamicBoostWatts = 0,
    [double]$MeasuredPowerWatts = 0,

    [ValidateSet(
        "Auto",
        "NVIDIA-Ampere",
        "NVIDIA-Ampere-Entry",
        "NVIDIA-Ampere-Mainstream",
        "NVIDIA-Ampere-High",
        "NVIDIA-Ampere-UpperHigh",
        "NVIDIA-Ampere-Flagship",
        "NVIDIA-Ampere-FlagshipTi",
        "NVIDIA-Ada",
        "NVIDIA-Ada-Entry",
        "NVIDIA-Ada-Mainstream",
        "NVIDIA-Ada-UpperMid",
        "NVIDIA-Ada-High",
        "NVIDIA-Ada-Flagship",
        "NVIDIA-Blackwell",
        "NVIDIA-Blackwell-Entry",
        "NVIDIA-Blackwell-Mainstream",
        "NVIDIA-Blackwell-High",
        "NVIDIA-Blackwell-Flagship",
        "NVIDIA-Turing",
        "NVIDIA-Pascal",
        "NVIDIA-Generic",
        "AMD-RDNA1",
        "AMD-RDNA2",
        "AMD-RDNA3",
        "AMD-RDNA4",
        "AMD-Generic",
        "Intel-Alchemist",
        "Intel-Battlemage",
        "Intel-Generic"
    )]
    [string]$GpuFamily = "Auto",

    [ValidateSet("Balanced", "Performance", "Efficiency", "Benchmark")]
    [string]$Goal = "Balanced",

    [ValidateSet("usable-start", "explore-limit")]
    [string]$TuningIntent = "usable-start",

    [ValidateSet("None", "Power", "Thermal", "Voltage", "Reliability", "Utilization", "Unknown")]
    [string]$DominantLimit = "Unknown",

    [ValidateSet("Good", "Tight", "Unknown")]
    [string]$ThermalHeadroom = "Unknown",

    [string]$TargetComponent = "",
    [string]$FixedWorkload = "",
    [string]$PassCriteria = "",
    [string[]]$AbortSignals = @(),
    [switch]$ConsumerGpuConfirmed,

    [ValidateSet("None", "pass", "fail", "inconclusive")]
    [string]$ResultVerdict = "None",
    [ValidateSet("Unknown", "Yes", "No")]
    [string]$MaterialBenefit = "Unknown",
    [ValidateSet("Unknown", "Yes", "No")]
    [string]$NoiseExceeded = "Unknown",
    [ValidateSet("Unknown", "Yes", "No")]
    [string]$EffectiveClockImproved = "Unknown",
    [ValidateSet("Unknown", "Yes", "No")]
    [string]$ThermalAcceptable = "Unknown",
    [ValidateSet("Unknown", "Yes", "No")]
    [string]$PowerAcceptable = "Unknown",
    [ValidateSet("Unknown", "None", "Observed")]
    [string]$Artifacts = "Unknown",

    [string]$ExperimentId = "",
    [string]$BaselineId = "",
    [string]$ParentCandidateId = "",
    [string]$ParentCandidateValue = "",
    [ValidateSet("Unknown", "Core", "Memory", "Power", "Curve")]
    [string]$ParentControlKind = "Unknown",
    [string]$ParentExperimentId = "",
    [string]$LastPassingCandidateValue = "",
    [ValidateSet("Unknown", "Core", "Memory", "Power", "Curve")]
    [string]$LastPassingControlKind = "Unknown",
    [double]$LastPassingVoltageMv = 0,
    [double]$LastPassingFrequencyMhz = 0,
    [double]$LastPassingPowerLimitPct = 0,
    [string]$DeviceFingerprint = "",
    [string]$DriverVersion = "",
    [string]$TuningToolVersion = "",
    [string]$VBiosVersion = "",
    [string]$CoolingSummary = "",
    [ValidateSet("Fresh", "Stale", "Unknown")]
    [string]$ReportFreshness = "Unknown",

    [ValidateSet("Auto", "Core", "Memory", "Power")]
    [string]$Variable = "Auto",

    [ValidateSet("Offset", "ClockTarget", "Curve", "Unsupported")]
    [string]$CoreControlKind = "Offset",

    [ValidateSet("Offset", "ClockTarget", "Mode", "Unsupported")]
    [string]$MemoryControlKind = "Offset",

    [Alias("CurrentCoreValueMhz")]
    [Nullable[double]]$CurrentCoreOffsetMhz,

    [Alias("CurrentMemoryValueMhz")]
    [Nullable[double]]$CurrentMemoryOffsetMhz,

    [Alias("BaselineCoreValueMhz")]
    [double]$BaselineCoreOffsetMhz = 0,

    [Alias("BaselineMemoryValueMhz")]
    [double]$BaselineMemoryOffsetMhz = 0,

    [double]$CurrentCoreVoltageMv = 0,
    [double]$CurrentCoreFrequencyMhz = 0,

    [Nullable[double]]$CurrentPowerLimitPct,

    [switch]$BaselineRecorded,
    [switch]$StableStartingState,
    [switch]$RecoverySaved,
    [switch]$ExposedCoreOffset,
    [switch]$ExposedMemoryOffset,
    [switch]$ExposedPowerLimit,
    [switch]$CoreValidated,
    [switch]$MemoryValidated
)

$ErrorActionPreference = "Stop"

if ($null -ne $CurrentPowerLimitPct -and
    ($CurrentPowerLimitPct -le 0 -or $CurrentPowerLimitPct -gt 200)) {
    throw "CurrentPowerLimitPct must be greater than 0 and no more than 200."
}

$authorityPath = Join-Path (Split-Path -Parent $PSScriptRoot) "references/tuning/gpu-auto-oc-tier-authority.json"
if (-not (Test-Path -LiteralPath $authorityPath -PathType Leaf)) {
    $authorityPath = Join-Path (Split-Path -Parent $PSScriptRoot) "docs/gpu-auto-oc-tier-authority.json"
}
if (-not (Test-Path -LiteralPath $authorityPath -PathType Leaf)) {
    throw "The GPU tier authority file is missing: $authorityPath"
}
$tierAuthority = Get-Content -LiteralPath $authorityPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $tierAuthority.Profiles) {
    throw "The GPU tier authority file has no Profiles object: $authorityPath"
}

$familyProfiles = @{}
foreach ($profileEntry in $tierAuthority.Profiles.PSObject.Properties) {
    $profileValue = $profileEntry.Value
    $familyProfiles[$profileEntry.Name] = [pscustomobject]@{
        Label = [string]$profileValue.Label
        Vendor = [string]$profileValue.Vendor
        CoreStartDesktop = [int]$profileValue.CoreStartDesktop
        CoreStep = [int]$profileValue.CoreStep
        CoreBoundaryDesktop = [int]$profileValue.CoreBoundaryDesktop
        CoreBoundaryLaptop = [int]$profileValue.CoreBoundaryLaptop
        MemoryStartDesktop = [int]$profileValue.MemoryStartDesktop
        MemoryStep = [int]$profileValue.MemoryStep
        MemoryBoundaryDesktop = [int]$profileValue.MemoryBoundaryDesktop
        MemoryBoundaryLaptop = [int]$profileValue.MemoryBoundaryLaptop
        Strategy = [string]$profileValue.Strategy
        Caveats = @($profileValue.Caveats)
        StartEvidence = $profileValue.StartEvidence
        ModelStartEvidence = @($profileValue.ModelStartEvidence)
        PriorSourceClass = [string]$tierAuthority.PriorSourceClass
        PriorReviewedAt = [string]$tierAuthority.PriorReviewedAt
        PriorRuleVersion = [string]$tierAuthority.PriorRuleVersion
        PriorUnitAssumption = [string]$tierAuthority.PriorUnitAssumption
    }
}

function Get-NormalizedGpuText {
    param([string]$Model)

    return (($Model.ToUpperInvariant() -replace '\(R\)', ' ' -replace '\(TM\)', ' ' -replace '[()]', ' ' -replace '\s+', ' ').Trim())
}

function Get-StableId {
    param([string]$Prefix, [string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $hash = $sha.ComputeHash($bytes)
        return "$Prefix" + (($hash | ForEach-Object { $_.ToString("x2") }) -join "").Substring(0, 16)
    }
    finally {
        $sha.Dispose()
    }
}

function Split-GpuAdapterText {
    param([string]$Model)

    $normalized = Get-NormalizedGpuText -Model $Model
    $normalized = $normalized -replace '\s*[;,/\\&]\s*', ';'
    $fullWidthSeparators = '[' + [char]0xFF1B + [char]0xFF0C + [char]0x3001 + ']'
    $normalized = $normalized -replace ('\s*' + $fullWidthSeparators + '\s*'), ';'
    $normalized = $normalized -replace '\s+\bAND\b\s+', ';'
    $normalized = $normalized -replace '\s*\((INTEL|AMD|NVIDIA)\b', '; $1'
    $normalized = $normalized -replace '\s+\+\s+', ';'
    return @($normalized -split '[;|\r\n]+' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ModelFamilyKey {
    param([string]$VendorName, [string]$Model)

    $normalized = Get-NormalizedGpuText -Model $Model
    if ($VendorName -eq "NVIDIA") {
        if ($normalized -match '\bRTX\s*5090\b') { return "NVIDIA-Blackwell-Flagship" }
        if ($normalized -match '\bRTX\s*5080\b') { return "NVIDIA-Blackwell-High" }
        if ($normalized -match '\bRTX\s*5070\b') { return "NVIDIA-Blackwell-Mainstream" }
        if ($normalized -match '\bRTX\s*5060\b') { return "NVIDIA-Blackwell-Entry" }
        if ($normalized -match '\bRTX\s*50\d{2}\b') { return "NVIDIA-Blackwell" }
        if ($normalized -match '\bRTX\s*4090\b') { return "NVIDIA-Ada-Flagship" }
        if ($normalized -match '\bRTX\s*4080\b') { return "NVIDIA-Ada-High" }
        if ($normalized -match '\bRTX\s*4070\s*Ti\b') { return "NVIDIA-Ada-UpperMid" }
        if ($normalized -match '\bRTX\s*4070\b') { return "NVIDIA-Ada-Mainstream" }
        if ($normalized -match '\bRTX\s*4060\b') { return "NVIDIA-Ada-Entry" }
        if ($normalized -match '\bRTX\s*40\d{2}\b') { return "NVIDIA-Ada" }
        if ($normalized -match '\bRTX\s*3090\s*Ti\b') { return "NVIDIA-Ampere-FlagshipTi" }
        if ($normalized -match '\bRTX\s*3090\b') { return "NVIDIA-Ampere-Flagship" }
        if ($normalized -match '\bRTX\s*3080\s*Ti\b') { return "NVIDIA-Ampere-UpperHigh" }
        if ($normalized -match '\bRTX\s*3080\b') { return "NVIDIA-Ampere-High" }
        if ($normalized -match '\bRTX\s*3070\s*Ti\b') { return "NVIDIA-Ampere-Mainstream" }
        if ($normalized -match '\bRTX\s*3070\b') { return "NVIDIA-Ampere-Mainstream" }
        if ($normalized -match '\bRTX\s*3060\s*Ti\b') { return "NVIDIA-Ampere-Entry" }
        if ($normalized -match '\bRTX\s*3060\b') { return "NVIDIA-Ampere-Entry" }
        if ($normalized -match '\bRTX\s*30\d{2}\b') { return "NVIDIA-Ampere" }
        if ($normalized -match '\b(?:RTX\s*20\d{2}|GTX\s*16\d{2})\b') { return "NVIDIA-Turing" }
        if ($normalized -match '\bGTX\s*10\d{2}\b') { return "NVIDIA-Pascal" }
        return "NVIDIA-Generic"
    }
    if ($VendorName -eq "AMD") {
        if ($normalized -match '\bRX\s*9\d{3}M?\b') { return "AMD-RDNA4" }
        if ($normalized -match '\bRX\s*7\d{3}M?\b') { return "AMD-RDNA3" }
        if ($normalized -match '\bRX\s*6\d{3}M?\b') { return "AMD-RDNA2" }
        if ($normalized -match '\bRX\s*5\d{3}M?\b') { return "AMD-RDNA1" }
        return "AMD-Generic"
    }
    if ($VendorName -eq "Intel") {
        if ($normalized -match '\bARC\s*B\d{3}\b') { return "Intel-Battlemage" }
        if ($normalized -match '\bARC\s*A\d{3}\b') { return "Intel-Alchemist" }
        return "Intel-Generic"
    }
    return "$VendorName-Generic"
}

function Resolve-StartEvidence {
    param(
        [object]$Profile,
        [string]$NormalizedModel,
        [object]$DefaultEvidence
    )

    $values = [ordered]@{
        StartEvidenceClass = [string]$DefaultEvidence.StartEvidenceClass
        StartConfidence = [string]$DefaultEvidence.StartConfidence
        PublicSourceCount = [int]$DefaultEvidence.PublicSourceCount
        ObservedMaxCoreOffsetMhz = $DefaultEvidence.ObservedMaxCoreOffsetMhz
        StartToObservedMaxPercent = $DefaultEvidence.StartToObservedMaxPercent
        StartEvidenceNote = [string]$DefaultEvidence.StartEvidenceNote
    }
    if ($Profile.StartEvidence) {
        foreach ($property in $Profile.StartEvidence.PSObject.Properties) {
            $values[$property.Name] = $property.Value
        }
    }
    foreach ($modelEvidence in @($Profile.ModelStartEvidence)) {
        if ($modelEvidence -and $NormalizedModel -match [string]$modelEvidence.Pattern) {
            foreach ($property in $modelEvidence.PSObject.Properties) {
                if ($property.Name -ne "Pattern") {
                    $values[$property.Name] = $property.Value
                }
            }
            break
        }
    }
    return [pscustomobject]$values
}

function Get-GpuModelTokenCount {
    param([string]$Model)

    $normalized = Get-NormalizedGpuText -Model $Model
    $explicitPattern = '\b(?:RTX\s*(?:PRO\s*\d{4}|A\d{4}|[2-6]\d{3})|GTX\s*\d{3,4}|(?:A2|A10G?|A16|A30|A40|A100|A800|H100|H200|H800|L2|L4|L20|L40S?|P4|P6|P40|P100|V100|T4|B100|B200|GB200|GH200)|RX\s*[5-9]\d{3}M?|RADEON\s+(?:PRO\s+)?(?:W|MI)?\d{3,4}M?|ARC\s*[AB]\d{3})\b'
    $genericGraphicsPattern = '\b(?:INTEL\s+)?(?:(?:UHD|HD|IRIS|XE)\s+)?GRAPHICS(?:\s+\d+)?\b'
    $segments = Split-GpuAdapterText -Model $Model
    $count = 0
    foreach ($segment in $segments) {
        $explicitCount = [regex]::Matches($segment, $explicitPattern).Count
        $count += $explicitCount
        $looksIntegrated = $segment -match '\b(?:INTEL|UHD|IRIS|XE)\b|\bHD\s+GRAPHICS\b|\bRADEON\s+GRAPHICS\b'
        if ($segment -match $genericGraphicsPattern -and
            $segment -notmatch '\bARC\s*[AB]\d{3}\b' -and
            ($explicitCount -eq 0 -or $looksIntegrated)) {
            $count += 1
        }
    }
    return $count
}

function Test-NonConsumerGpuClass {
    param([string]$VendorName, [string]$Model)

    $normalized = Get-NormalizedGpuText -Model $Model
    if ($VendorName -eq "NVIDIA") {
        return ($normalized -match '\b(?:QUADRO|TESLA|WORKSTATION|RTX\s+(?:A\d{4}|PRO\b)|RTX\s+(?:2000|4000|4500|5000|5880|6000|8000)(?=\s|$)|A2|A10G?|A16|A30|A40|A100|A800|H100|H200|H800|L2|L4|L20|L40S?|P4|P6|P40|P100|V100|T4|B100|B200|GB200|GH200)\b')
    }
    if ($VendorName -eq "AMD") {
        if ($normalized -match '\b(?:RADEON\s+PRO|FIREPRO|INSTINCT|RADEON\s+W\d{4}|MI\d{3}[A-Z]?)\b') {
            return $true
        }
        if ($normalized -match '\bRADEON\b' -and $normalized -notmatch '\bRX\s*[5-9]\d{3}M?\b') {
            return $true
        }
        return $false
    }
    if ($VendorName -eq "Intel") {
        if ($normalized -match '\b(?:DATA\s+CENTER|FLEX\s+\d+|UHD\s+GRAPHICS|IRIS|HD\s+GRAPHICS|XE\s+GRAPHICS|INTEGRATED|MICROSOFT\s+BASIC)\b') {
            return $true
        }
        if ($normalized -match '\bARC\b' -and $normalized -notmatch '\bARC\s*[AB]\d{3}\b') {
            return $true
        }
        if ($normalized -match '\bINTEL\s+GRAPHICS(?:\s+\d+)?\b') {
            return $true
        }
    }
    return $false
}

function Test-ConsumerGpuClass {
    param([string]$VendorName, [string]$Model)

    $normalized = Get-NormalizedGpuText -Model $Model
    if (Test-NonConsumerGpuClass -VendorName $VendorName -Model $Model) {
        return $false
    }
    if ($VendorName -eq "NVIDIA") {
        return ($normalized -match '\b(?:RTX\s*(?:20|30|40|50)\d{2}|GTX\s*(?:10|16)\d{2})\b')
    }
    if ($VendorName -eq "AMD") {
        return ($normalized -match '\bRX\s*[5-9]\d{3}M?\b')
    }
    if ($VendorName -eq "Intel") {
        return ($normalized -match '\bARC\s*[AB]\d{3}\b')
    }
    return $false
}

function Test-GpuTargetComponent {
    param([string]$Target, [string]$Model)

    if ([string]::IsNullOrWhiteSpace($Target)) {
        return "missing"
    }
    $normalizedTarget = $Target.Trim().ToUpperInvariant()
    if ($normalizedTarget -match '\b(?:CPU|PROCESSOR|MEMORY|RAM|MOTHERBOARD|STORAGE|DISK|NETWORK|SYSTEM|PACKAGE)\b') {
        return "non-gpu"
    }
    if ($normalizedTarget -match '\b(?:GPU|GRAPHICS\s+ADAPTER|DISPLAY\s+ADAPTER|VIDEO\s+CARD)\b') {
        return "gpu"
    }
    if (-not [string]::IsNullOrWhiteSpace($Model) -and
        $normalizedTarget -eq $Model.Trim().ToUpperInvariant()) {
        return "gpu-model"
    }
    return "unconfirmed"
}

$normalizedModel = Get-NormalizedGpuText -Model $GpuModel
$modelFamilyKey = Get-ModelFamilyKey -VendorName $Vendor -Model $GpuModel
$modelRecognized = $modelFamilyKey -notmatch '-Generic$'
$classificationIssues = New-Object System.Collections.Generic.List[string]
$modelTokenCount = Get-GpuModelTokenCount -Model $GpuModel
$consumerModelRecognized = Test-ConsumerGpuClass -VendorName $Vendor -Model $GpuModel
$targetValidation = Test-GpuTargetComponent -Target $TargetComponent -Model $GpuModel

if ($FormFactor -in @("Desktop", "MoDT")) {
    $resolvedPowerLimitState = "not-applicable"
    $powerLimitMode = if ($FormFactor -eq "MoDT") { "desktop-like-modt" } else { "desktop" }
    $powerLimitAssumptionNote = if ($FormFactor -eq "MoDT") {
        "MoDT is treated as a desktop-like control path only for bounded candidate generation; verify the board, cooling, and exposed power path first."
    }
    else {
        "Desktop power-path behavior is handled separately from laptop power-limit assumptions."
    }
}
elseif ($FormFactor -eq "Other") {
    $resolvedPowerLimitState = "blocked"
    $powerLimitMode = "blocked"
    $powerLimitAssumptionNote = "A generic Other form factor has no reliable desktop/laptop control model."
    $classificationIssues.Add("Other form factor blocks numeric candidate generation; identify Desktop, Laptop, or MoDT and its exposed controls")
}
else {
    if ([string]::IsNullOrWhiteSpace($BoardModel)) {
        $classificationIssues.Add("laptop candidate requires a brand and board model")
    }
    $resolvedPowerLimitState = if ($PowerLimitModificationState -eq "Auto") {
        if ($StockPowerLimitWatts -gt 0 -and
            $CurrentPowerLimitWatts -gt 0 -and
            $CurrentPowerLimitWatts -gt ($StockPowerLimitWatts + 1)) {
            "detected-mismatch"
        }
        else {
            "assumed-stock"
        }
    }
    else {
        $PowerLimitModificationState
    }
    if ($resolvedPowerLimitState -eq "detected-mismatch") {
        $classificationIssues.Add("laptop power-limit evidence conflicts and must be confirmed before generating a candidate")
    }
    if ($resolvedPowerLimitState -in @("assumed-stock", "declared-stock") -and
        $StockPowerLimitWatts -gt 0 -and
        $CurrentPowerLimitWatts -gt ($StockPowerLimitWatts + 1)) {
        $resolvedPowerLimitState = "detected-mismatch"
        $classificationIssues.Add("current laptop power-limit exceeds the declared stock limit")
    }
    if ($resolvedPowerLimitState -eq "declared-unlocked") {
        if ($StockPowerLimitWatts -le 0 -or $CurrentPowerLimitWatts -le 0) {
            $classificationIssues.Add("declared-unlocked laptop power state needs stock and current watt limits")
        }
        elseif ($CurrentPowerLimitWatts -le ($StockPowerLimitWatts + 1)) {
            $resolvedPowerLimitState = "detected-mismatch"
            $classificationIssues.Add("declared-unlocked laptop power state does not show a higher current limit")
        }
        if ($PowerLimitEvidenceSource -eq "unknown") {
            $PowerLimitEvidenceSource = "user-declared"
        }
    }
    $powerLimitMode = switch ($resolvedPowerLimitState) {
        "assumed-stock" { "stock-assumed" }
        "declared-stock" { "stock-declared" }
        "declared-unlocked" { "modified-declared" }
        default { "blocked" }
    }
    $powerLimitAssumptionNote = if ($resolvedPowerLimitState -eq "assumed-stock") {
        "No power-limit modification was declared; calculate against the stock laptop strategy. This assumption is correctable if the machine was unlocked."
    }
    elseif ($resolvedPowerLimitState -eq "declared-stock") {
        "The user declared the stock laptop power state; this does not prove measured cooling capacity."
    }
    elseif ($resolvedPowerLimitState -eq "declared-unlocked") {
        "The user declared a modified power path; use the current watt limit as the baseline without increasing frequency steps automatically."
    }
    else {
        "Power-limit state is conflicting or incomplete; no numeric candidate is available."
    }
}

if ($modelTokenCount -gt 1) {
    $classificationIssues.Add("model text contains multiple GPU model tokens; the active target adapter is ambiguous")
}
if ($normalizedModel -match '(?:;|\||\r?\n|\s+\+\s+)' -and $modelTokenCount -gt 1) {
    $classificationIssues.Add("model text appears to concatenate multiple adapter records")
}

$mobileModelPattern = '\b(?:LAPTOP|MOBILE)\b|\bRX\s*\d{4}M\b'
if ($FormFactor -eq "Desktop" -and $normalizedModel -match $mobileModelPattern) {
    $classificationIssues.Add("model identifies a mobile GPU, but FormFactor is Desktop")
}
if ($FormFactor -eq "Laptop" -and $normalizedModel -match '\bDESKTOP(?:\s+GPU)?\b') {
    $classificationIssues.Add("model identifies a desktop GPU, but FormFactor is Laptop")
}

if ($normalizedModel -match '\b(?:VIRTUAL|MICROSOFT\s+BASIC)\b' -or
    (Test-NonConsumerGpuClass -VendorName $Vendor -Model $GpuModel)) {
    $classificationIssues.Add("model indicates a virtual, integrated, professional, or otherwise unconfirmed consumer GPU class")
}
elseif (-not $consumerModelRecognized -and
    -not [string]::IsNullOrWhiteSpace($GpuModel)) {
    $classificationIssues.Add("model is not positively identified as a supported consumer GPU; numeric tuning requires the exact model")
}
if ([string]::IsNullOrWhiteSpace($GpuModel)) {
    $classificationIssues.Add("unreadable or missing GPU model blocks numeric tuning; confirm the exact active consumer GPU model")
}
if ($Vendor -eq "NVIDIA" -and $normalizedModel -match '\b(?:AMD|RADEON|RX\s*\d{4})\b') {
    $classificationIssues.Add("model text identifies an AMD Radeon GPU, but Vendor is NVIDIA")
}
if ($Vendor -eq "AMD" -and $normalizedModel -match '\b(?:NVIDIA|GEFORCE|RTX|GTX)\b') {
    $classificationIssues.Add("model text identifies an NVIDIA GPU, but Vendor is AMD")
}
if ($Vendor -eq "Intel" -and $normalizedModel -match '\b(?:NVIDIA|GEFORCE|RTX|GTX|AMD|RADEON|RX\s*\d{4})\b') {
    $classificationIssues.Add("model text identifies a non-Intel GPU, but Vendor is Intel")
}
if ($targetValidation -eq "non-gpu") {
    $classificationIssues.Add("TargetComponent identifies a non-GPU component")
}
elseif ($targetValidation -eq "unconfirmed") {
    $classificationIssues.Add("TargetComponent is not a confirmed GPU identifier or the exact selected GPU model")
}
if ($ReportFreshness -eq "Stale") {
    $classificationIssues.Add("the supplied device, driver, tool, cooling, or baseline context is stale")
}

$familyKey = "$Vendor-Generic"
$familyConfidence = "generic"
if ($GpuFamily -ne "Auto") {
    if (-not $familyProfiles.ContainsKey($GpuFamily) -or $familyProfiles[$GpuFamily].Vendor -ne $Vendor) {
        $classificationIssues.Add("explicit GpuFamily does not match Vendor")
    }
    elseif (-not $modelRecognized) {
        $classificationIssues.Add("explicit GpuFamily is not verifiable without a recognized model")
    }
    elseif ($modelFamilyKey -ne $GpuFamily) {
        $classificationIssues.Add("explicit GpuFamily conflicts with the recognized model generation")
    }
    else {
        $familyKey = $GpuFamily
        $familyConfidence = "explicit-model-match"
    }
}
elseif ($modelRecognized) {
    $familyKey = $modelFamilyKey
    $familyConfidence = "model-pattern"
}
if ($familyKey -match '-Generic$') {
    $classificationIssues.Add("GPU generation is not positively identified; generic profiles cannot generate a numeric candidate")
}

$family = $familyProfiles[$familyKey]
$startEvidence = Resolve-StartEvidence -Profile $family -NormalizedModel $normalizedModel -DefaultEvidence $tierAuthority.DefaultStartEvidence
if ($startEvidence.PSObject.Properties.Name -contains "CoreStartDesktop" -and
    [int]$startEvidence.CoreStartDesktop -gt 0) {
    $family.CoreStartDesktop = [int]$startEvidence.CoreStartDesktop
}

$hardwareFingerprintSource = @(
    $Vendor,
    $normalizedModel,
    $BoardModel.Trim().ToUpperInvariant(),
    $FormFactor,
    $DriverVersion.Trim().ToUpperInvariant(),
    $TuningToolVersion.Trim().ToUpperInvariant(),
    $VBiosVersion.Trim().ToUpperInvariant(),
    $CoolingSummary.Trim().ToUpperInvariant()
) -join "|"
$effectiveHardwareFingerprint = Get-StableId -Prefix "hardware-" -Text $hardwareFingerprintSource
$configurationFingerprintSource = @(
    $effectiveHardwareFingerprint,
    $StockPowerLimitWatts,
    $CurrentPowerLimitWatts,
    $DynamicBoostWatts,
    $resolvedPowerLimitState
) -join "|"
$computedConfigurationFingerprint = Get-StableId -Prefix "config-" -Text $configurationFingerprintSource
$effectiveDeviceFingerprint = if ([string]::IsNullOrWhiteSpace($DeviceFingerprint)) {
    $computedConfigurationFingerprint
}
else {
    $DeviceFingerprint.Trim()
}
$experimentLineageSource = @(
    $effectiveHardwareFingerprint,
    $FixedWorkload.Trim(),
    $Goal,
    $TuningIntent
) -join "|"
$experimentLineageId = Get-StableId -Prefix "lineage-" -Text $experimentLineageSource
$baselineSource = @(
    $effectiveDeviceFingerprint,
    $FixedWorkload.Trim(),
    $BaselineCoreOffsetMhz,
    $BaselineMemoryOffsetMhz,
    $CurrentPowerLimitPct
) -join "|"
$effectiveBaselineId = if ([string]::IsNullOrWhiteSpace($BaselineId)) {
    Get-StableId -Prefix "baseline-" -Text $baselineSource
}
else {
    $BaselineId.Trim()
}
$missingGate = New-Object System.Collections.Generic.List[string]
if (-not $BaselineRecorded) { $missingGate.Add("in-workload baseline") }
if (-not $StableStartingState) { $missingGate.Add("stable stock or known-good state") }
if (-not $RecoverySaved) { $missingGate.Add("saved recovery profile") }
if ([string]::IsNullOrWhiteSpace($TargetComponent)) { $missingGate.Add("target component") }
if ([string]::IsNullOrWhiteSpace($FixedWorkload)) { $missingGate.Add("fixed workload") }
if ([string]::IsNullOrWhiteSpace($PassCriteria)) { $missingGate.Add("pass criteria") }
if ($AbortSignals.Count -eq 0 -or @($AbortSignals | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
    $missingGate.Add("abort signals")
}
if ($ReportFreshness -ne "Fresh") {
    $missingGate.Add("fresh current report or session baseline")
}

$result = [ordered]@{
    ScriptVersion = "2.0.3"
    SuiteVersion = "2.7.2"
    NoHardwareChange = $true
    HardwareWrite = "none"
    SafetyNoticeRequired = $true
    GpuFamily = $familyKey
    GpuFamilyLabel = $family.Label
    FamilyConfidence = $familyConfidence
    StartEvidenceClass = $startEvidence.StartEvidenceClass
    StartConfidence = $startEvidence.StartConfidence
    PublicSourceCount = $startEvidence.PublicSourceCount
    ObservedMaxCoreOffsetMhz = $startEvidence.ObservedMaxCoreOffsetMhz
    StartToObservedMaxPercent = $startEvidence.StartToObservedMaxPercent
    StartEvidenceNote = $startEvidence.StartEvidenceNote
    FamilyPrior = $family.Strategy
    FamilyStrategy = $family.Strategy
    FamilyCaveats = @($family.Caveats)
    PriorSourceClass = $family.PriorSourceClass
    PriorReviewedAt = $family.PriorReviewedAt
    PriorRuleVersion = $family.PriorRuleVersion
    PriorUnitAssumption = $family.PriorUnitAssumption
    GpuModel = $GpuModel
    FormFactor = $FormFactor
    BoardModel = $BoardModel
    StockPowerLimitWatts = if ($StockPowerLimitWatts -gt 0) { $StockPowerLimitWatts } else { $null }
    CurrentPowerLimitWatts = if ($CurrentPowerLimitWatts -gt 0) { $CurrentPowerLimitWatts } else { $null }
    DynamicBoostWatts = if ($DynamicBoostWatts -gt 0) { $DynamicBoostWatts } else { $null }
    PowerLimitModificationState = $resolvedPowerLimitState
    PowerLimitMode = $powerLimitMode
    PowerLimitPercentMeaning = "ceiling-not-draw"
    PowerLimitWattsMeaning = "configured-or-observed-limit-ceiling-not-draw"
    PowerLimitEvidenceSource = $PowerLimitEvidenceSource
    MeasuredPowerWatts = if ($MeasuredPowerWatts -gt 0) { $MeasuredPowerWatts } else { $null }
    PowerLimitAssumptionNote = $powerLimitAssumptionNote
    UsesCurrentPowerLimit = $null
    ResolvedGpuModel = $null
    DetectedModelTokenCount = $modelTokenCount
    AdapterIdentityStatus = $null
    ConsumerGpuConfirmed = [bool]$ConsumerGpuConfirmed
    HardwareFingerprint = $effectiveHardwareFingerprint
    ConfigurationFingerprint = $effectiveDeviceFingerprint
    DeviceFingerprint = $effectiveDeviceFingerprint
    ExperimentLineageId = $experimentLineageId
    ExperimentRevisionId = $null
    HistoryPolicy = "preserve-and-mark-stale-for-continuation"
    BaselineStatus = "pending"
    CandidateStatus = "none"
    FallbackStatus = "none"
    BaselineId = $effectiveBaselineId
    ExperimentId = $null
    CandidateId = $null
    ParentCandidateId = $ParentCandidateId
    ReportFreshness = $ReportFreshness
    ResumeState = "session-only"
    EvidenceBasis = "none"
    LocalEvidenceLevel = "none"
    LocalEvidence = "No accepted local evidence is available before classification and gate checks."
    EvidenceQuality = "family-only"
    Confidence = "none"
    ConfidenceReason = "Candidate not yet eligible for a numeric recommendation."
    PredictionBasis = "Direction only; magnitude is not calibrated by local history."
    PredictedDirection = $null
    ExpectedMagnitude = "unknown"
    ExpectedBenefitBand = "unknown"
    ExpectedPassLikelihood = "uncalibrated"
    PassLikelihoodMeaning = "Qualitative only; no calibrated probability is implied."
    TuningIntent = $TuningIntent
    CandidateType = "experiment-plan"
    CandidateRole = $null
    ReachedUsableCandidate = $false
    StopWhenGoodEnough = ($TuningIntent -eq "usable-start")
    SuggestedAction = $null
    FallbackCandidate = $null
    NotClaimed = @(
        "final stable limit",
        "calibrated FPS gain",
        "daily-verified profile"
    )
    ClassificationIssues = @($classificationIssues.ToArray())
    TargetComponent = $TargetComponent
    TargetComponentValidated = ($targetValidation -in @("gpu", "gpu-model"))
    FixedWorkload = $FixedWorkload
    PassCriteria = $PassCriteria
    Status = $null
    Reason = $null
    MissingGate = @()
    Variable = $null
    ControlKind = $null
    Unit = $null
    BaselineDisplayedValue = $null
    CurrentDisplayedValue = $null
    CandidateDisplayedValue = $null
    Candidate = $null
    CurveStart = $null
    Change = $null
    InitialStep = $null
    FollowupStep = $null
    ReferenceBoundary = $null
    ReferenceBoundaryMeaning = "Internal automatic stopping point; not a hardware-safe maximum."
    ExpectedDirection = $null
    PassEvidence = $null
    AbortSignals = @()
    Rollback = $null
    Persistence = "session-only first"
    PersistenceControl = "user-controlled"
    RequiredUserActions = @()
    EvidenceGaps = @()
    EvidenceLimit = $null
    ResultVerdict = $ResultVerdict
    MaterialBenefit = $MaterialBenefit
    NoiseExceeded = $NoiseExceeded
    EffectiveClockImproved = $EffectiveClockImproved
    ThermalAcceptable = $ThermalAcceptable
    PowerAcceptable = $PowerAcceptable
    Artifacts = $Artifacts
}

function Complete-Result {
    param([System.Collections.IDictionary]$Value)
    $Value | ConvertTo-Json -Depth 8
    exit 0
}

function Complete-BlockedResult {
    param(
        [System.Collections.IDictionary]$Value,
        [string]$Reason,
        [string[]]$MissingItems,
        [string]$UserAction,
        [string[]]$Gaps,
        [string]$Rollback
    )

    $Value.Status = "Blocked"
    $Value.Reason = $Reason
    $Value.MissingGate = @($MissingItems)
    $Value.EvidenceBasis = "none"
    $Value.LocalEvidenceLevel = "none"
    $Value.LocalEvidence = "No local evidence is accepted for a candidate while this request is blocked."
    $Value.EvidenceQuality = "none"
    $Value.Confidence = "none"
    $Value.ConfidenceReason = "The candidate was blocked before evidence could support a numeric recommendation."
    $Value.PredictedDirection = $null
    $Value.ExpectedDirection = $null
    $Value.ExpectedMagnitude = "unknown"
    $Value.ExpectedBenefitBand = "unknown"
    $Value.UsesCurrentPowerLimit = $false
    $Value.Candidate = $null
    $Value.CandidateDisplayedValue = $null
    $Value.CandidateType = "blocked"
    $Value.CandidateId = $null
    $Value.CandidateRole = $null
    $Value.FallbackCandidate = $null
    $Value.ReachedUsableCandidate = $false
    $Value.StopWhenGoodEnough = $false
    $Value.SuggestedAction = $null
    $Value.ResumeState = "blocked"
    $Value.BaselineStatus = "not-accepted"
    $Value.CandidateStatus = "none"
    $Value.FallbackStatus = "none"
    $Value.ResultVerdict = "None"
    $Value.MaterialBenefit = "Unknown"
    $Value.NoiseExceeded = "Unknown"
    $Value.EffectiveClockImproved = "Unknown"
    $Value.ThermalAcceptable = "Unknown"
    $Value.PowerAcceptable = "Unknown"
    $Value.Artifacts = "Unknown"
    $Value.ExpectedPassLikelihood = "none"
    $Value.PassLikelihoodMeaning = "No candidate exists while the request is blocked."
    $Value.Change = $null
    $Value.InitialStep = $null
    $Value.FollowupStep = $null
    $Value.ControlKind = $null
    $Value.RequiredUserActions = @($UserAction)
    $Value.EvidenceGaps = @($Gaps)
    $Value.Rollback = $Rollback
    Complete-Result $Value
}

function Get-ClassificationBlockGuidance {
    param([string]$Issue)

    if ($Issue -match 'multiple GPU model tokens|concatenate multiple adapter') {
        return [pscustomobject]@{
            Reason = "More than one GPU model is present, so the active tuning target is ambiguous."
            Missing = "one confirmed active GPU model"
            Action = "Confirm the single GPU that the current workload is using; do not choose from the combined adapter list."
        }
    }
    if ($Issue -match 'laptop candidate requires a brand and board model') {
        return [pscustomobject]@{
            Reason = "The laptop brand and board model are missing, so board-specific power and cooling limits cannot be bounded."
            Missing = "laptop brand and exact board model"
            Action = "Provide the laptop brand and exact model; keep the already confirmed GPU and form factor."
        }
    }
    if ($Issue -match 'mobile GPU.*FormFactor is Desktop|desktop GPU.*FormFactor is Laptop') {
        return [pscustomobject]@{
            Reason = "The readable GPU model conflicts with the selected desktop/laptop form factor."
            Missing = "one consistent GPU model and form factor"
            Action = "Correct whichever is wrong: the GPU model or the desktop/laptop form factor."
        }
    }
    if ($Issue -match 'Other form factor') {
        return [pscustomobject]@{
            Reason = "The Other form factor has no reliable automatic GPU constraint model."
            Missing = "a confirmed Desktop, Laptop, or MoDT form factor"
            Action = "Identify the actual form factor and its exposed power/cooling controls; Other cannot receive a numeric candidate."
        }
    }
    if ($Issue -match 'laptop power-limit|current laptop power-limit|declared-unlocked laptop') {
        return [pscustomobject]@{
            Reason = "The laptop power-limit state or watt evidence is incomplete or conflicting."
            Missing = "confirmed stock/current watt ceilings and power-path state"
            Action = "Confirm the stock and current watt ceilings and whether the power path was modified; a percentage is not a watt value."
        }
    }
    if ($Issue -match 'virtual, integrated, professional') {
        return [pscustomobject]@{
            Reason = "The target is not a supported single consumer GPU."
            Missing = "one supported consumer GPU"
            Action = "Select a supported consumer GPU; professional, integrated, virtual, and multi-adapter targets are not eligible."
        }
    }
    if ($Issue -match 'not positively identified|unreadable or missing GPU model') {
        return [pscustomobject]@{
            Reason = "The active consumer GPU cannot be confirmed from the supplied model text."
            Missing = "one exact active consumer GPU model"
            Action = "Confirm the exact active consumer GPU model and that it is the intended tuning target."
        }
    }
    if ($Issue -match 'TargetComponent') {
        return [pscustomobject]@{
            Reason = "The target component is not a confirmed GPU."
            Missing = "the exact active GPU as TargetComponent"
            Action = "Set the target component to the exact GPU model being tuned; use the CPU or memory route for other targets."
        }
    }
    if ($Issue -match 'stale') {
        return [pscustomobject]@{
            Reason = "The hardware, driver, tool, cooling, or baseline context is stale."
            Missing = "a fresh current report and baseline"
            Action = "Refresh the affected report or baseline, then retry without carrying old settings."
        }
    }
    if ($Issue -match 'identifies an .* GPU, but Vendor') {
        return [pscustomobject]@{
            Reason = "The selected vendor conflicts with the readable GPU model."
            Missing = "one consistent GPU vendor and model"
            Action = "Correct the vendor/model mismatch before generating any candidate."
        }
    }
    if ($Issue -match 'explicit GpuFamily') {
        return [pscustomobject]@{
            Reason = "The requested GPU family conflicts with or cannot be verified from the readable model."
            Missing = "an Auto or model-verified GPU family"
            Action = "Leave the family on Auto or correct it to the readable model generation."
        }
    }
    return [pscustomobject]@{
        Reason = "Candidate generation is blocked by an unresolved device-classification issue."
        Missing = $Issue
        Action = "Resolve the first listed classification issue, then retry with the same confirmed context."
    }
}

if ($modelTokenCount -eq 1) {
    $result.ResolvedGpuModel = $GpuModel.Trim()
    $result.AdapterIdentityStatus = "single-readable-model"
}
elseif ($modelTokenCount -gt 1) {
    $result.AdapterIdentityStatus = "ambiguous-multiple-models"
}
else {
    $result.AdapterIdentityStatus = "unconfirmed"
}

if ($classificationIssues.Count -gt 0) {
    $classificationGuidance = Get-ClassificationBlockGuidance -Issue ([string]$classificationIssues[0])
    Complete-BlockedResult `
        -Value $result `
        -Reason $classificationGuidance.Reason `
        -MissingItems @($classificationGuidance.Missing) `
        -UserAction $classificationGuidance.Action `
        -Gaps @($classificationIssues.ToArray()) `
        -Rollback "No candidate is available. Make no tuning change."
}

if ($missingGate.Count -gt 0) {
    Complete-BlockedResult `
        -Value $result `
        -Reason "The mandatory tuning entry gate is incomplete." `
        -MissingItems @($missingGate.ToArray()) `
        -UserAction "Complete the first missing experiment field: $($missingGate[0])." `
        -Gaps @($missingGate.ToArray()) `
        -Rollback "No candidate is available. Preserve the current state and complete the gate."
}

$hasStageEvidence = $CoreValidated -or $MemoryValidated
$result.LocalEvidenceLevel = if ($hasStageEvidence) { "stage-validated" } else { "baseline-only" }
$result.LocalEvidence = if ($hasStageEvidence) {
    "Local in-workload baseline plus at least one user-reported passed stage."
}
else {
    "Local in-workload baseline only; no repeated pass/fail history is available."
}
$result.EvidenceQuality = if ($hasStageEvidence) { "local-pass" } else { "local-baseline" }
$result.ExpectedPassLikelihood = "uncalibrated"
if ($familyKey -match '-Generic$') {
    $result.EvidenceBasis = if ($hasStageEvidence) { "LocalPass + LocalBaseline + GenericRule" } else { "LocalBaseline + GenericRule" }
    $result.Confidence = "very-low"
    $result.ConfidenceReason = "The model lacks reliable generation classification; only a reduced generic rule is available."
}
else {
    $result.EvidenceBasis = if ($hasStageEvidence) { "LocalPass + LocalBaseline + FamilyPrior" } else { "LocalBaseline + FamilyPrior" }
    $result.Confidence = if ($startEvidence.StartConfidence -eq "very-low") { "very-low" } else { "low" }
    $result.ConfidenceReason = "A recognized family prior and local baseline exist, but no repeated local calibration or matched-board evidence is recorded. Start prior evidence: $($startEvidence.StartEvidenceClass), public-source count $($startEvidence.PublicSourceCount)."
}

function New-FallbackCandidate {
    param(
        [string]$VariableName,
        [double]$Value,
        [string]$ValueUnit,
        [string]$Reason
    )

    return [ordered]@{
        CandidateType = "fallback"
        CandidateRole = "fallback"
        Variable = $VariableName
        Value = $Value
        Unit = $ValueUnit
        Reason = $Reason
        FallbackScope = "profile-only"
        FallbackValidity = "valid-recovery"
        ConfigurationFingerprint = $effectiveDeviceFingerprint
        MayRestoreExternalPowerModification = $false
        HardwareWrite = "none"
    }
}

if ($DominantLimit -eq "Reliability") {
    $result.Status = "Stop"
    $result.Reason = "A reliability limit or unexplained instability must be stabilized before any Pass result can be accepted."
    $result.SuggestedAction = "stop"
    $result.RequiredUserActions = @("Restore the known-good profile and diagnose the reliability problem before tuning.")
    $result.Rollback = "Restore the known-good profile and use triage."
    Complete-Result $result
}

if ($DominantLimit -eq "Utilization") {
    $result.Status = "DiagnoseFirst"
    $result.Reason = "The workload does not currently show representative GPU demand, so a Pass result cannot establish a usable GPU overclock."
    $result.SuggestedAction = "diagnose"
    $result.RequiredUserActions = @("Resolve CPU, frame-cap, presentation, or workload limits before accepting a GPU candidate.")
    $result.Rollback = "Do not change clocks yet."
    Complete-Result $result
}

$preliminaryRoute = if ($Variable -ne "Auto") {
    $Variable
}
elseif ($ParentControlKind -ne "Unknown") {
    $ParentControlKind
}
elseif ($Goal -eq "Efficiency" -or $DominantLimit -in @("Power", "Thermal") -or $ThermalHeadroom -eq "Tight") {
    "Power"
}
else {
    "Core"
}
$preliminaryControlKind = if ($preliminaryRoute -eq "Core" -and $CoreControlKind -eq "Curve") {
    "Curve"
}
elseif ($preliminaryRoute -eq "Memory") {
    $MemoryControlKind
}
elseif ($preliminaryRoute -eq "Power") {
    "PowerLimitPercent"
}
else {
    $CoreControlKind
}
$experimentSource = @(
    $effectiveDeviceFingerprint,
    $effectiveBaselineId,
    $Goal,
    $DominantLimit,
    $ThermalHeadroom,
    $TuningIntent,
    $preliminaryRoute,
    $preliminaryControlKind,
    $CurrentCoreVoltageMv,
    $CurrentCoreFrequencyMhz
) -join "|"
$effectiveExperimentId = if ([string]::IsNullOrWhiteSpace($ExperimentId)) {
    Get-StableId -Prefix "experiment-" -Text $experimentSource
}
else {
    $ExperimentId.Trim()
}
$result.ExperimentId = $effectiveExperimentId
$result.ExperimentRevisionId = $effectiveExperimentId

if (-not [string]::IsNullOrWhiteSpace($ParentCandidateId)) {
    if ([string]::IsNullOrWhiteSpace($ParentCandidateValue) -or
        $ParentControlKind -eq "Unknown" -or
        [string]::IsNullOrWhiteSpace($ParentExperimentId)) {
        Complete-BlockedResult `
            -Value $result `
            -Reason "ParentCandidateId was supplied without enough parent context to validate it." `
            -MissingItems @("parent candidate value, control kind, and experiment ID") `
            -UserAction "Provide the parent candidate context from the prior result, or start a new session without ParentCandidateId." `
            -Gaps @("The supplied parent candidate ID cannot be validated without its context.") `
            -Rollback "Do not apply or persist a candidate. Start from the known-good baseline."
    }
    $expectedParentId = Get-StableId -Prefix "candidate-" -Text (@(
        $effectiveDeviceFingerprint,
        $effectiveBaselineId,
        $ParentExperimentId.Trim(),
        $ParentControlKind,
        $ParentCandidateValue.Trim()
    ) -join "|")
    if ($ParentCandidateId -ne $expectedParentId) {
        Complete-BlockedResult `
            -Value $result `
            -Reason "ParentCandidateId does not match the current configuration. The historical record is preserved but is stale for continuation." `
            -MissingItems @("a valid parent candidate context") `
            -UserAction "Use the CandidateId and context from the immediately preceding result, or begin a fresh session." `
            -Gaps @("The parent candidate identity is invalid or stale.") `
            -Rollback "No candidate change. Return to the saved known-good profile."
    }
    $result.ResumeState = "session-validated"
}

$outcomeProvided = ($ResultVerdict -ne "None" -or
    $MaterialBenefit -ne "Unknown" -or
    $NoiseExceeded -ne "Unknown" -or
    $EffectiveClockImproved -ne "Unknown" -or
    $ThermalAcceptable -ne "Unknown" -or
    $PowerAcceptable -ne "Unknown" -or
    $Artifacts -ne "Unknown")

if ($outcomeProvided) {
    $testedVariable = if ($ParentControlKind -ne "Unknown") {
        $ParentControlKind
    }
    elseif ($Variable -ne "Auto") {
        $Variable
    }
    else {
        $preliminaryRoute
    }
    $result.UsesCurrentPowerLimit = ($FormFactor -eq "Laptop" -and
        ($testedVariable -eq "Power" -or $resolvedPowerLimitState -eq "declared-unlocked"))
    if ($LastPassingControlKind -ne "Unknown" -and $LastPassingControlKind -ne $testedVariable) {
        Complete-BlockedResult `
            -Value $result `
            -Reason "LastPassingControlKind does not match the tested route." `
            -MissingItems @("last-passing context for the tested route") `
            -UserAction "Use the last-passing value and control kind from the same route." `
            -Gaps @("A fallback from a different control class would be unsafe.") `
            -Rollback "No candidate change. Restore the known-good profile."
    }

    $lastPassingText = if (-not [string]::IsNullOrWhiteSpace($LastPassingCandidateValue)) {
        $LastPassingCandidateValue.Trim()
    }
    else {
        $ParentCandidateValue.Trim()
    }
    $lastPassingNumeric = 0.0
    $hasLastPassingNumeric = [double]::TryParse(
        $lastPassingText,
        [System.Globalization.NumberStyles]::Float,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref]$lastPassingNumeric
    )

    $fallback = if ($testedVariable -eq "Memory") {
        $fallbackValue = if ($hasLastPassingNumeric) { $lastPassingNumeric } else { $BaselineMemoryOffsetMhz }
        New-FallbackCandidate "Memory control" $fallbackValue "last-passing or baseline displayed memory value" "Return to the last passing or saved memory value after a failed round."
    }
    elseif ($testedVariable -eq "Power") {
        $fallbackValue = if ($LastPassingPowerLimitPct -gt 0) {
            $LastPassingPowerLimitPct
        }
        elseif ($hasLastPassingNumeric) {
            $lastPassingNumeric
        }
        else {
            $CurrentPowerLimitPct
        }
        New-FallbackCandidate "Power ceiling" $fallbackValue "last-passing or current displayed power-limit ceiling percent" "Return to the last passing power-limit ceiling after a failed efficiency round."
    }
    elseif ($testedVariable -eq "Curve") {
        $fallbackVoltage = if ($LastPassingVoltageMv -gt 0) { $LastPassingVoltageMv } else { $CurrentCoreVoltageMv }
        $fallbackFrequency = if ($LastPassingFrequencyMhz -gt 0) {
            $LastPassingFrequencyMhz
        }
        elseif ($hasLastPassingNumeric) {
            $lastPassingNumeric
        }
        else {
            $CurrentCoreFrequencyMhz
        }
        $fallbackPower = if ($LastPassingPowerLimitPct -gt 0) { $LastPassingPowerLimitPct } else { $CurrentPowerLimitPct }
        $curveFallbackResult = New-FallbackCandidate "Core curve anchor" $fallbackFrequency "MHz measured frequency at voltage anchor" "Return to the last passing measured curve anchor."
        $curveFallbackResult.VoltageAnchorMv = $fallbackVoltage
        $curveFallbackResult.FrequencyMhz = $fallbackFrequency
        $curveFallbackResult.PowerLimitPct = $fallbackPower
        $curveFallbackResult
    }
    else {
        $fallbackValue = if ($hasLastPassingNumeric) { $lastPassingNumeric } else { $BaselineCoreOffsetMhz }
        New-FallbackCandidate "Core control" $fallbackValue "last-passing or baseline displayed core value" "Return to the last passing or saved core value after a failed round."
    }

    if ($ResultVerdict -eq "fail" -or $Artifacts -eq "Observed" -or $ThermalAcceptable -eq "No" -or $PowerAcceptable -eq "No") {
        $result.Status = "Revert"
        $result.Reason = "The tested round failed or violated a stability, thermal, or power guard."
        $result.CandidateRole = "fallback"
        $result.FallbackCandidate = $fallback
        $result.SuggestedAction = "fallback"
        $result.ReachedUsableCandidate = $false
        $result.BaselineStatus = "current-or-revalidate"
        $result.CandidateStatus = "rejected"
        $result.FallbackStatus = "valid-recovery"
        $result.RequiredUserActions = @("Restore the saved known-good profile shown in FallbackCandidate; make no further increase.")
        $result.EvidenceGaps = @("A failure was recorded; a larger candidate is not justified.")
        $result.Rollback = "Restore the saved stock/known-good profile and reboot before another experiment."
        Complete-Result $result
    }

    if ($ResultVerdict -eq "inconclusive" -or
        $MaterialBenefit -eq "Unknown" -or
        $NoiseExceeded -eq "Unknown") {
        $result.Status = "DiagnoseFirst"
        $result.Reason = "The result does not establish a material benefit above workload noise."
        $result.SuggestedAction = "repeat"
        $result.CandidateStatus = "unresolved"
        $result.FallbackStatus = "valid-recovery"
        $result.RequiredUserActions = @("Repeat the same fixed workload with the current value; do not increase it.")
        $result.EvidenceGaps = @("Material benefit or noise separation is unresolved.")
        Complete-Result $result
    }

    if ($MaterialBenefit -eq "No" -or $NoiseExceeded -eq "No") {
        $result.Status = "DiagnoseFirst"
        $result.Reason = "The candidate passed without a material benefit, so it is not a usable starting point."
        $result.SuggestedAction = "diagnose"
        $result.CandidateStatus = "no-material-benefit"
        $result.FallbackStatus = "valid-recovery"
        $result.RequiredUserActions = @("Keep the last known-good profile and assess a different limiting control or workload.")
        $result.EvidenceGaps = @("The tested control did not produce a benefit beyond noise.")
        Complete-Result $result
    }

    $requiresClockGain = ($testedVariable -in @("Core", "Curve") -and $Goal -ne "Efficiency")
    $fullyAccepted = ($ResultVerdict -eq "pass" -and
        $MaterialBenefit -eq "Yes" -and
        $NoiseExceeded -eq "Yes" -and
        ((-not $requiresClockGain) -or $EffectiveClockImproved -eq "Yes") -and
        $ThermalAcceptable -eq "Yes" -and
        $PowerAcceptable -eq "Yes" -and
        $Artifacts -eq "None")
    if ($fullyAccepted) {
        if ($TuningIntent -eq "usable-start") {
            $result.Status = "Keep"
            $result.Reason = "The round produced a material, noise-separated benefit with acceptable thermal, power, and artifact evidence."
            $result.CandidateRole = "usable-start"
            $result.ReachedUsableCandidate = $true
            $result.StopWhenGoodEnough = $true
            $result.SuggestedAction = "keep"
            $result.BaselineStatus = "current"
            $result.CandidateStatus = "accepted"
            $result.FallbackStatus = "valid-recovery"
            $result.RequiredUserActions = @("Keep the tested profile and stop automatic frequency escalation.")
            $result.EvidenceGaps = @("Daily behavior after reboot and normal use still requires separate validation.")
            Complete-Result $result
        }
    }
    else {
        $result.Status = "DiagnoseFirst"
        $result.Reason = "The result remains incomplete for a usable start."
        $result.SuggestedAction = "repeat"
        $result.RequiredUserActions = @("Repeat the same fixed workload and resolve the remaining artifact, thermal, power, clock, benefit, or noise evidence.")
        $result.EvidenceGaps = @("Not all usable-start result conditions are satisfied.")
        Complete-Result $result
    }
}

if ($CoreValidated -and $TuningIntent -eq "usable-start" -and -not $outcomeProvided) {
    $result.Status = "DiagnoseFirst"
    $result.Reason = "A core round passed, but no material-benefit result is recorded."
    $result.SuggestedAction = "report-result"
    $result.RequiredUserActions = @("Report whether the core candidate produced a repeatable benefit above workload noise before testing memory.")
    $result.EvidenceGaps = @("Core pass alone does not establish a usable starting point.")
    Complete-Result $result
}

$chosenVariable = $Variable
if ($chosenVariable -eq "Auto") {
    if ($Goal -eq "Efficiency" -or $DominantLimit -in @("Power", "Thermal") -or $ThermalHeadroom -eq "Tight") {
        $chosenVariable = "Power"
    }
    elseif ($DominantLimit -eq "Voltage") {
        $result.Status = "DiagnoseFirst"
        $result.Reason = "A voltage limit needs baseline comparison before a positive clock candidate is appropriate."
        $result.Rollback = "Do not change clocks yet. Review the matched workload's clock, power, and performance evidence."
        Complete-Result $result
    }
    elseif ($CoreValidated -and
        $TuningIntent -eq "explore-limit" -and
        $ExposedCoreOffset -and
        $null -ne $CurrentCoreOffsetMhz -and
        (($CurrentCoreOffsetMhz - $BaselineCoreOffsetMhz) -lt $(if ($FormFactor -eq "Laptop") { $family.CoreBoundaryLaptop } else { $family.CoreBoundaryDesktop }))) {
        $chosenVariable = "Core"
    }
    elseif ($CoreValidated -and $ExposedMemoryOffset -and -not $MemoryValidated) {
        $chosenVariable = "Memory"
    }
    elseif ($ExposedCoreOffset) {
        $chosenVariable = "Core"
    }
    elseif ($ExposedMemoryOffset -and $CoreValidated) {
        $chosenVariable = "Memory"
    }
    else {
        Complete-BlockedResult `
            -Value $result `
            -Reason "No supported next tuning control is exposed." `
            -MissingItems @("the exact exposed control and its current displayed value") `
            -UserAction "Open the current supported vendor tuning software and confirm which one GPU control is available." `
            -Gaps @("No supported exposed control has been recorded.") `
            -Rollback "No setting changes. Do not use a hidden or modified control."
    }
}

$finalControlKind = if ($chosenVariable -eq "Core" -and $CoreControlKind -eq "Curve") {
    "Curve"
}
elseif ($chosenVariable -eq "Memory") {
    $MemoryControlKind
}
elseif ($chosenVariable -eq "Power") {
    "PowerLimitPercent"
}
else {
    $CoreControlKind
}
if ([string]::IsNullOrWhiteSpace($ExperimentId)) {
    $finalExperimentSource = @(
        $effectiveDeviceFingerprint,
        $effectiveBaselineId,
        $Goal,
        $DominantLimit,
        $ThermalHeadroom,
        $TuningIntent,
        $chosenVariable,
        $finalControlKind,
        $CurrentCoreVoltageMv,
        $CurrentCoreFrequencyMhz
    ) -join "|"
    $effectiveExperimentId = Get-StableId -Prefix "experiment-" -Text $finalExperimentSource
    $result.ExperimentId = $effectiveExperimentId
    $result.ExperimentRevisionId = $effectiveExperimentId
}

if ($DominantLimit -in @("Power", "Thermal") -or $ThermalHeadroom -eq "Tight") {
    if ($chosenVariable -in @("Core", "Memory")) {
        Complete-BlockedResult `
            -Value $result `
            -Reason "Thermal or power pressure takes precedence over a positive clock offset." `
            -MissingItems @("a supported power/efficiency experiment or thermal remediation") `
            -UserAction "Keep the current clock value and address the thermal/power limit or select a supported efficiency control." `
            -Gaps @("Positive clock headroom is not established while thermal or power pressure dominates.") `
            -Rollback "Keep the current profile. Do not raise clocks before addressing the thermal/power limit."
    }
}

$commonPass = "Use the same fixed workload twice; require a result above baseline noise plus acceptable sustained clocks, power, temperatures, and no errors."
$commonAbort = @(
    "artifact, flicker, corruption, black screen, or driver reset",
    "unexpected shutdown, WHEA/error event, or clock collapse",
    "rapid thermal rise, hot connector, fan failure, or burning smell",
    "performance below baseline or inconsistent frame pacing"
)

switch ($chosenVariable) {
    "Core" {
        if (-not $ExposedCoreOffset) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The selected core control is not exposed as a supported displayed value." `
                -MissingItems @("a supported exposed core control") `
                -UserAction "Confirm the core control in the current supported tuning software or choose an exposed GPU control." `
                -Gaps @("No supported exposed core control is recorded.") `
                -Rollback "Use no numeric candidate. Do not use a hidden or modified control."
        }
        if ($CoreControlKind -eq "Unsupported") {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The core control is unsupported by the automatic candidate workflow." `
                -MissingItems @("a direct offset, actual-clock, or measured curve control") `
                -UserAction "Confirm a supported core control in the current vendor software." `
                -Gaps @("The numeric core ladder cannot represent this control type.") `
                -Rollback "Do not convert units or invent a numeric offset."
        }
        if ($CoreControlKind -eq "Curve") {
            if ($CurrentCoreVoltageMv -le 0 -or $CurrentCoreFrequencyMhz -le 0) {
                Complete-BlockedResult `
                    -Value $result `
                    -Reason "A curve start needs the observed in-workload voltage and frequency anchor." `
                    -MissingItems @("measured core voltage and frequency at the target workload") `
                    -UserAction "Record one steady workload voltage/frequency anchor in the same monitoring data used for the baseline." `
                    -Gaps @("A curve candidate cannot be derived without a local voltage/frequency anchor.") `
                    -Rollback "No curve edit. Keep the saved default curve."
            }
            if ($null -eq $CurrentPowerLimitPct) {
                Complete-BlockedResult `
                    -Value $result `
                    -Reason "The current displayed power-limit ceiling is missing, so a fixed-curve experiment cannot be bounded." `
                    -MissingItems @("current displayed power-limit ceiling") `
                    -UserAction "Record the current displayed power-limit percentage from the supported tuning tool; do not assume 100%." `
                    -Gaps @("Curve-start output must preserve the current power ceiling.") `
                    -Rollback "No curve edit. Keep the saved default curve and power state."
            }

            $curveStep = $family.CoreStartDesktop
            $curveBoundary = $family.CoreBoundaryDesktop
            if ($FormFactor -eq "Laptop" -or $ThermalHeadroom -eq "Unknown") {
                $curveStep = [Math]::Min($curveStep, 25)
            }
            if ($FormFactor -eq "Laptop") {
                $curveBoundary = 75
            }
            $curveCandidateFrequency = $CurrentCoreFrequencyMhz + $curveStep
            $curveFallback = New-FallbackCandidate "Core curve anchor" $CurrentCoreFrequencyMhz "MHz measured frequency at the baseline voltage anchor" "Restore the measured baseline curve if the start fails."
            $result.Status = "Ready"
            $result.Reason = "A measured voltage/frequency anchor supports one bounded curve-start experiment."
            $result.CandidateType = "curve-start"
            $result.Variable = "Core curve anchor"
            $result.ControlKind = "Curve"
            $result.Unit = "MHz measured core frequency at voltage anchor"
            $result.BaselineDisplayedValue = $CurrentCoreFrequencyMhz
            $result.CurrentDisplayedValue = $CurrentCoreFrequencyMhz
            $result.CandidateDisplayedValue = $null
            $result.Candidate = [ordered]@{
                CandidateType = "curve-start"
                CandidateRole = if ($TuningIntent -eq "usable-start") { "usable-start" } else { "limit-exploration" }
                VoltageAnchorMv = $CurrentCoreVoltageMv
                CurrentFrequencyMhz = $CurrentCoreFrequencyMhz
                CandidateFrequencyMhz = $curveCandidateFrequency
                PowerLimitPct = $CurrentPowerLimitPct
                CurveAction = "Set the measured voltage anchor to the candidate frequency, then flatten points above that anchor and verify the applied curve."
            }
            $result.CurveStart = $result.Candidate
            $result.Change = $curveCandidateFrequency - $CurrentCoreFrequencyMhz
            $result.InitialStep = "+$curveStep MHz at the measured anchor"
            $result.FollowupStep = "+$($family.CoreStep) MHz at the measured anchor"
            $result.ReferenceBoundary = "$curveBoundary MHz above the measured baseline frequency"
            $result.ExpectedDirection = "Higher frequency at the measured voltage may improve performance only if the applied curve remains stable and cooling/power accept it."
            $result.PredictedDirection = $result.ExpectedDirection
            $result.CandidateRole = $result.Candidate.CandidateRole
            $result.FallbackCandidate = $curveFallback
            $result.SuggestedAction = "test-candidate"
            $result.PassEvidence = "$PassCriteria Use the same fixed workload twice and verify the applied curve did not shift after editing."
            $result.AbortSignals = @($AbortSignals) + @($commonAbort)
            $result.Rollback = "Restore the saved default/known-good curve and verify the applied values after reboot."
            $result.RequiredUserActions = @(
                "Set only the measured voltage anchor toward the candidate frequency and flatten points above it.",
                "Reopen the curve editor to verify the applied values, then run the fixed workload."
            )
            $result.EvidenceGaps = @(
                "No calibrated local pass/fail history is available, so ExpectedMagnitude remains unknown.",
                "Tool clamping and neighbor-point smoothing must be verified from the applied curve."
            )
            $result.EvidenceLimit = "A curve start is a measured local experiment, not a transferable curve or a daily-stable claim."
            $result.UsesCurrentPowerLimit = ($FormFactor -eq "Laptop" -and
                $resolvedPowerLimitState -eq "declared-unlocked")
            $result.BaselineStatus = "current"
            $result.CandidateStatus = "active"
            $result.FallbackStatus = "valid-recovery"
            $result.CandidateId = Get-StableId -Prefix "candidate-" -Text (@(
                $effectiveDeviceFingerprint,
                $effectiveBaselineId,
                $result.ExperimentId,
                "Curve",
                $result.CurveStart.CandidateFrequencyMhz
            ) -join "|")
            Complete-Result $result
        }
        if ($CoreControlKind -eq "ClockTarget" -and $BaselineCoreOffsetMhz -le 0) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "An actual-clock core control needs the stock baseline clock before a bounded change can be calculated." `
                -MissingItems @("stock/default core clock target") `
                -UserAction "Record the stock/default displayed core clock target from the current profile." `
                -Gaps @("The actual-clock delta cannot be calculated without the stock baseline clock.") `
                -Rollback "No core setting change."
        }
        if ($null -eq $CurrentCoreOffsetMhz) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The current displayed core value is missing, so the next relative step cannot be calculated safely." `
                -MissingItems @("current displayed core offset or clock target") `
                -UserAction "Record the current displayed core value in the supported tuning tool; zero is accepted only when it is actually displayed as zero." `
                -Gaps @("An omitted current value must not be treated as zero.") `
                -Rollback "No core setting change. Keep the current profile."
        }

        $coreDelta = $CurrentCoreOffsetMhz - $BaselineCoreOffsetMhz
        $step = 0
        if ($coreDelta -eq 0) {
            $step = $family.CoreStartDesktop
        }
        else {
            $step = $family.CoreStep
        }
        if ($FormFactor -eq "Laptop") { $step = [Math]::Min($step, 25) }
        if ($ThermalHeadroom -eq "Unknown") { $step = [Math]::Min($step, 25) }

        $boundary = $family.CoreBoundaryDesktop
        if ($FormFactor -eq "Laptop") { $boundary = $family.CoreBoundaryLaptop }

        if ($coreDelta -ge $boundary) {
            $result.Status = "Stop"
            $result.Reason = "The current core offset has reached the automatic internal reference boundary."
            $result.ReferenceBoundary = "$boundary MHz above the baseline displayed value"
            $result.Rollback = "Keep the last passing profile and validate daily behavior separately."
            Complete-Result $result
        }

        $step = [Math]::Min($step, $boundary - $coreDelta)
        $candidate = $CurrentCoreOffsetMhz + $step

        $result.Status = "Ready"
        $result.Reason = "$($family.Label) strategy plus the supported core-only baseline makes one bounded step the next automatic candidate."
        $result.Variable = if ($CoreControlKind -eq "ClockTarget") { "Core clock target" } else { "Core offset" }
        $result.ControlKind = $CoreControlKind
        $result.Unit = if ($CoreControlKind -eq "ClockTarget") { "MHz displayed clock target" } else { "MHz displayed offset" }
        $result.BaselineDisplayedValue = $BaselineCoreOffsetMhz
        $result.CurrentDisplayedValue = $CurrentCoreOffsetMhz
        $result.CandidateDisplayedValue = $candidate
        $result.Change = $candidate - $CurrentCoreOffsetMhz
        $result.InitialStep = if ($CoreControlKind -eq "ClockTarget") { "+$step MHz displayed clock target" } else { "+$step MHz" }
        $result.FollowupStep = "+$($family.CoreStep) MHz"
        $result.ReferenceBoundary = "$boundary MHz above the baseline displayed value"
        $result.ExpectedDirection = "Higher effective clock or throughput only if $($family.Label) behavior and another limit do not absorb the step; the gain must exceed baseline noise."
        $result.CandidateRole = if ($TuningIntent -eq "usable-start") { "usable-start" } else { "limit-exploration" }
        $result.FallbackCandidate = New-FallbackCandidate $result.Variable $BaselineCoreOffsetMhz $result.Unit "Restore the saved core baseline if the candidate fails."
        $result.SuggestedAction = "test-candidate"
    }
    "Memory" {
        if (-not $CoreValidated) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "A core candidate must pass before memory becomes the next variable." `
                -MissingItems @("a passed core-only round with measured evidence") `
                -UserAction "Keep the current memory value and complete the core-only round first." `
                -Gaps @("No passed core round is recorded for this device.") `
                -Rollback "Keep the last passing core profile."
        }
        if (-not $ExposedMemoryOffset) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The platform does not expose a supported displayed memory control." `
                -MissingItems @("a supported exposed memory control") `
                -UserAction "Confirm whether the current supported tuning software exposes a GPU memory control." `
                -Gaps @("No supported exposed memory control is recorded.") `
                -Rollback "Use no numeric memory candidate."
        }
        if ($MemoryControlKind -in @("Mode", "Unsupported")) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The memory control is a mode or unsupported control, not a direct offset or clock value." `
                -MissingItems @("a direct memory offset or actual-clock control") `
                -UserAction "Keep memory unchanged or test one supported UI mode as a separate experiment." `
                -Gaps @("The numeric memory ladder cannot represent this control type.") `
                -Rollback "Do not invent a numeric memory offset."
        }
        if ($MemoryControlKind -eq "ClockTarget" -and $BaselineMemoryOffsetMhz -le 0) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "An actual-clock memory control needs the stock baseline clock before a bounded change can be calculated." `
                -MissingItems @("stock/default memory clock") `
                -UserAction "Record the stock/default displayed memory clock from the current profile." `
                -Gaps @("The actual-clock delta cannot be calculated without the stock baseline clock.") `
                -Rollback "No memory setting change."
        }
        if ($null -eq $CurrentMemoryOffsetMhz) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The current displayed memory value is missing, so the next relative step cannot be calculated safely." `
                -MissingItems @("current displayed memory offset or clock target") `
                -UserAction "Record the current displayed memory value in the supported tuning tool; zero is accepted only when it is actually displayed as zero." `
                -Gaps @("An omitted current value must not be treated as zero.") `
                -Rollback "No memory setting change. Keep the current profile."
        }

        $memoryDelta = $CurrentMemoryOffsetMhz - $BaselineMemoryOffsetMhz
        $step = 0
        if ($memoryDelta -eq 0) {
            $step = $family.MemoryStartDesktop
        }
        else {
            $step = $family.MemoryStep
        }
        if ($FormFactor -eq "Laptop") { $step = [Math]::Min($step, 50) }
        if ($ThermalHeadroom -eq "Unknown") { $step = [Math]::Min($step, 50) }

        $boundary = $family.MemoryBoundaryDesktop
        if ($FormFactor -eq "Laptop") { $boundary = $family.MemoryBoundaryLaptop }

        if ($memoryDelta -ge $boundary) {
            $result.Status = "Stop"
            $result.Reason = "The current memory value has reached the conservative automatic reference boundary."
            $result.ReferenceBoundary = "$boundary displayed tool units above the baseline value"
            $result.Rollback = "Keep the last passing profile and validate daily behavior separately."
            Complete-Result $result
        }

        $step = [Math]::Min($step, $boundary - $memoryDelta)
        $candidate = $CurrentMemoryOffsetMhz + $step

        $result.Status = "Ready"
        $result.Reason = "$($family.Label) strategy applies after the core round passed; memory is the next separate variable."
        $result.Variable = if ($MemoryControlKind -eq "ClockTarget") { "Memory clock target" } else { "Memory offset" }
        $result.ControlKind = $MemoryControlKind
        $result.Unit = if ($MemoryControlKind -eq "ClockTarget") { "MHz displayed clock target" } else { "displayed tool unit" }
        $result.BaselineDisplayedValue = $BaselineMemoryOffsetMhz
        $result.CurrentDisplayedValue = $CurrentMemoryOffsetMhz
        $result.CandidateDisplayedValue = $candidate
        $result.Change = $candidate - $CurrentMemoryOffsetMhz
        $result.FollowupStep = if ($MemoryControlKind -eq "ClockTarget") { "$step MHz displayed clock target" } else { "$step displayed tool units" }
        $result.InitialStep = $result.FollowupStep
        $result.ReferenceBoundary = if ($MemoryControlKind -eq "ClockTarget") { "$boundary MHz above the baseline displayed clock" } else { "$boundary displayed tool units above the baseline value" }
        $result.ExpectedDirection = "Higher bandwidth only for a memory-sensitive workload; keep the core control fixed and reject artifacts or correction-driven performance loss."
        $result.CandidateRole = if ($TuningIntent -eq "usable-start") { "incremental" } else { "limit-exploration" }
        $result.FallbackCandidate = New-FallbackCandidate $result.Variable $BaselineMemoryOffsetMhz $result.Unit "Restore the saved memory baseline if the candidate fails."
        $result.SuggestedAction = "test-candidate"
    }
    "Power" {
        if (-not $ExposedPowerLimit) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "No supported power ceiling is exposed." `
                -MissingItems @("a supported exposed power control") `
                -UserAction "Confirm the supported power or performance-mode control in the current vendor software." `
                -Gaps @("No supported exposed power control is recorded.") `
                -Rollback "Keep stock power behavior. Do not use a hidden control."
        }
        if ($null -eq $CurrentPowerLimitPct) {
            Complete-BlockedResult `
                -Value $result `
                -Reason "The current displayed power-limit ceiling is missing, so an efficiency candidate cannot be calculated safely." `
                -MissingItems @("current displayed power-limit ceiling percentage") `
                -UserAction "Record the current displayed power-limit percentage from the supported tuning tool; do not assume 100%." `
                -Gaps @("An omitted current power ceiling must not be treated as 100%.") `
                -Rollback "No power setting change. Keep the current profile."
        }

        $floor = 65
        if ($CurrentPowerLimitPct -le $floor) {
            $result.Status = "Stop"
            $result.Reason = "The exposed power ceiling is already at or below the conservative automatic floor."
            $result.ReferenceBoundary = "$floor percent displayed power limit"
            $result.Rollback = "Keep the last passing profile or restore the default."
            Complete-Result $result
        }

        $candidate = [Math]::Max($floor, $CurrentPowerLimitPct - 5)

        $result.Status = "Ready"
        $result.Reason = "Thermal or power pressure makes a small exposed power reduction the next automatic candidate."
        $result.Variable = "Power ceiling"
        $result.ControlKind = "PowerLimitPercent"
        $result.Unit = "displayed power-limit ceiling percent"
        $result.CurrentDisplayedValue = $CurrentPowerLimitPct
        $result.CandidateDisplayedValue = $candidate
        $result.Change = $candidate - $CurrentPowerLimitPct
        $result.InitialStep = "-5 percentage points"
        $result.FollowupStep = "-5 percentage points"
        $result.ReferenceBoundary = "$floor percent displayed power limit"
        $result.ExpectedDirection = "Potentially steadier clocks, lower temperature, or lower noise when thermal/power pressure dominates on $($family.Label); throughput may fall."
        $result.Persistence = "session-only first"
        $result.CandidateRole = if ($TuningIntent -eq "usable-start") { "usable-start" } else { "limit-exploration" }
        $result.FallbackCandidate = New-FallbackCandidate $result.Variable $CurrentPowerLimitPct $result.Unit "Restore the current or last-passing power-limit ceiling if the efficiency candidate fails."
        $result.SuggestedAction = "test-candidate"
    }
    default {
        throw "Unsupported variable selection: $chosenVariable"
    }
}

$result.PassEvidence = $commonPass
$result.AbortSignals = $commonAbort
$result.Rollback = "Restore the saved stock/known-good profile, close conflicting tuning tools, reboot, and recheck the applied values."
$result.EvidenceLimit = "The family prior and a clean round are screening evidence for this device and workload, not proof of daily stability or transfer to another GPU."
$result.PredictedDirection = $result.ExpectedDirection
$result.Candidate = [ordered]@{
    Value = $result.CandidateDisplayedValue
    Unit = $result.Unit
    Variable = $result.Variable
}
$result.CandidateId = Get-StableId -Prefix "candidate-" -Text (@(
    $effectiveDeviceFingerprint,
    $effectiveBaselineId,
    $result.ExperimentId,
    $chosenVariable,
    $result.CandidateDisplayedValue
) -join "|")
$result.UsesCurrentPowerLimit = ($FormFactor -eq "Laptop" -and
    ($chosenVariable -eq "Power" -or $resolvedPowerLimitState -eq "declared-unlocked"))
$result.BaselineStatus = "current"
$result.CandidateStatus = "active"
$result.FallbackStatus = "valid-recovery"
$result.PassEvidence = "$PassCriteria $commonPass"
$result.AbortSignals = @($AbortSignals) + @($commonAbort)
$result.RequiredUserActions = @(
    "Apply the candidate manually in the supported tuning control.",
    "Run the recorded fixed workload and report only artifacts, errors, or a materially different result."
)
$result.EvidenceGaps = @(
    "No calibrated local pass/fail history is available, so ExpectedMagnitude remains unknown.",
    "A single baseline cannot establish a stable maximum."
)

Complete-Result $result
