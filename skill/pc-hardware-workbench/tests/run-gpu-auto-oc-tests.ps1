[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

$ErrorActionPreference = "Stop"
$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$skillRoot = Split-Path -Parent (Split-Path -Parent $resolvedScript)
$authorityPath = Join-Path $skillRoot "references/tuning/gpu-auto-oc-tier-authority.json"
if (-not (Test-Path -LiteralPath $authorityPath -PathType Leaf)) {
    throw "GPU tier authority file is missing: $authorityPath"
}
$tierAuthority = Get-Content -LiteralPath $authorityPath -Raw -Encoding UTF8 | ConvertFrom-Json
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Assert-BlockedContract {
    param([object]$Result, [string]$Label)

    Assert-True ($Result.Status -eq "Blocked") "$Label should be Blocked."
    Assert-True ($null -eq $Result.Candidate) "$Label must not expose a candidate object."
    Assert-True ($null -eq $Result.CandidateDisplayedValue) "$Label must not expose a numeric candidate."
    Assert-True ($Result.NoHardwareChange -eq $true) "$Label must retain the no-hardware-write invariant."
    Assert-True ($Result.EvidenceBasis -eq "none") "$Label must not claim an accepted evidence basis."
    Assert-True ($Result.LocalEvidenceLevel -eq "none") "$Label must not claim local evidence."
    Assert-True ($Result.Confidence -eq "none") "$Label must not retain candidate confidence."
    Assert-True (@($Result.RequiredUserActions).Count -gt 0) "$Label must provide one next user action."
    Assert-True (@($Result.EvidenceGaps).Count -gt 0) "$Label must report evidence gaps."
}

function Invoke-Suggestion {
    param([hashtable]$Parameters)
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedScript)
    foreach ($name in $Parameters.Keys) {
        $value = $Parameters[$name]
        if ($value -is [switch] -or $value -is [bool]) {
            if ([bool]$value) { $arguments += "-$name" }
        }
        else {
            $arguments += "-$name"
            $arguments += [string]$value
        }
    }
    $raw = & $powershell @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Suggestion script failed: $raw"
    }
    return ($raw | ConvertFrom-Json)
}

function Assert-CoreFirstRound {
    param(
        [object]$Result,
        [string]$ProfileKey,
        [string]$Label
    )

    $profile = $tierAuthority.Profiles.PSObject.Properties[$ProfileKey].Value
    Assert-True ($null -ne $profile) "$Label has no authority profile."
    if ($null -eq $profile) { return }
    Assert-True ($Result.Status -eq "Ready") "$Label should produce a first-round candidate."
    Assert-True ($Result.CandidateDisplayedValue -eq $profile.CoreStartDesktop) "$Label first step disagrees with the tier authority."
    Assert-True ($Result.InitialStep -eq "+$($profile.CoreStartDesktop) MHz") "$Label InitialStep must describe the current round."
    Assert-True ($Result.FollowupStep -eq "+$($profile.CoreStep) MHz") "$Label FollowupStep must describe the next increment."
    Assert-True ($Result.NoHardwareChange -eq $true) "$Label must retain the no-hardware-write invariant."
}

Assert-True ($tierAuthority.PriorRuleVersion -eq "2.6.0") "The tier authority prior version must be 2.6.0."
foreach ($authorityProfile in $tierAuthority.Profiles.PSObject.Properties) {
    Assert-True ($authorityProfile.Value.CoreStep -eq 25) "Every first-round core profile must use a +25 MHz follow-up step."
}

$base = @{
    Vendor = "NVIDIA"
    FormFactor = "Desktop"
    Goal = "Balanced"
    DominantLimit = "None"
    ThermalHeadroom = "Good"
    TargetComponent = "GPU"
    FixedWorkload = "Recorded game benchmark"
    PassCriteria = "Repeated result above noise with no artifact"
    AbortSignals = "Artifact, driver reset, black screen, or rapid thermal rise"
    ConsumerGpuConfirmed = $true
    CurrentCoreOffsetMhz = 0
    CurrentMemoryOffsetMhz = 0
    CurrentPowerLimitPct = 100
    BaselineRecorded = $true
    StableStartingState = $true
    RecoverySaved = $true
    ExposedCoreOffset = $true
    ExposedMemoryOffset = $true
    ExposedPowerLimit = $true
}

$core = Invoke-Suggestion $base
Assert-True ($core.Status -eq "Ready") "A complete desktop baseline should produce a core candidate."
Assert-True ($core.Variable -eq "Core offset") "The first round should be core-only."
Assert-CoreFirstRound $core "NVIDIA-Generic" "Generic NVIDIA"
Assert-True ($core.ScriptVersion -eq "2.0.3") "The candidate helper script version must be 2.0.3."
Assert-True ($core.SuiteVersion -eq "2.6.0") "The candidate helper suite version must be 2.6.0."
Assert-True ($core.PriorRuleVersion -eq "2.6.0") "The candidate helper prior version must be 2.6.0."
Assert-True ($core.NoHardwareChange -eq $true) "The suggestion script must report that it changes no hardware."
Assert-True ($core.GpuFamily -eq "NVIDIA-Generic") "A model without an NVIDIA generation should use the generic family."
Assert-True ($core.FamilyConfidence -eq "generic") "An unclassified model must report generic family confidence."
Assert-True ($core.ConsumerGpuConfirmed -eq $true) "The explicit generic consumer-GPU confirmation must be preserved."
Assert-True ($core.ExpectedMagnitude -eq "unknown") "Uncalibrated predictions must report unknown magnitude."
Assert-True ($core.Confidence -ne "high") "The helper must not claim high confidence without history."
Assert-True ($core.HardwareWrite -eq "none") "The helper must report no hardware write path."
Assert-True ($core.ReferenceBoundaryMeaning -match 'not a hardware-safe maximum') "The automatic boundary must not be described as a safe maximum."
Assert-True (@($core.RequiredUserActions).Count -gt 0) "A ready candidate must list the current user actions."

$blockedParams = $base.Clone()
$blockedParams.Remove("RecoverySaved")
$blocked = Invoke-Suggestion $blockedParams
Assert-True ($blocked.Status -eq "Blocked") "Missing recovery evidence should block candidates."
Assert-True ($null -eq $blocked.CandidateDisplayedValue) "A blocked result must not expose a numeric candidate."
Assert-BlockedContract $blocked "Missing recovery evidence"

$utilizationParams = $base.Clone()
$utilizationParams.DominantLimit = "Utilization"
$utilization = Invoke-Suggestion $utilizationParams
Assert-True ($utilization.Status -eq "DiagnoseFirst") "Utilization-limited baselines should not be overclocked."

$coreMemoryParams = $base.Clone()
$coreMemoryParams.CoreValidated = $true
$memory = Invoke-Suggestion $coreMemoryParams
Assert-True ($memory.Status -eq "DiagnoseFirst") "A bare core pass must not automatically advance to memory."
Assert-True ($null -eq $memory.CandidateDisplayedValue) "A bare core pass must not produce a memory number."

$memoryParams = $base.Clone()
$memoryParams.CoreValidated = $true
$memoryParams.Variable = "Memory"
$memoryParams.TuningIntent = "explore-limit"
$memoryParams.ResultVerdict = "pass"
$memoryParams.MaterialBenefit = "Yes"
$memoryParams.NoiseExceeded = "Yes"
$memoryParams.EffectiveClockImproved = "Yes"
$memoryParams.ThermalAcceptable = "Yes"
$memoryParams.PowerAcceptable = "Yes"
$memoryParams.Artifacts = "None"
$memory = Invoke-Suggestion $memoryParams
Assert-True ($memory.Variable -eq "Memory offset") "Memory should become next only after an accepted core result."
Assert-True ($memory.CandidateDisplayedValue -eq 50) "An unclassified NVIDIA memory control should use the reduced generic step."

$unvalidatedMemoryParams = $base.Clone()
$unvalidatedMemoryParams.Variable = "Memory"
$unvalidatedMemory = Invoke-Suggestion $unvalidatedMemoryParams
Assert-True ($unvalidatedMemory.Status -eq "Blocked") "Explicit memory selection cannot skip the core round."
Assert-BlockedContract $unvalidatedMemory "Memory before core validation"

$powerParams = $base.Clone()
$powerParams.DominantLimit = "Power"
$power = Invoke-Suggestion $powerParams
Assert-True ($power.Status -eq "Ready") "A supported power reduction should be generated under power pressure."
Assert-True ($power.Variable -eq "Power ceiling") "Power pressure should select the power/efficiency variable."
Assert-True ($power.CandidateDisplayedValue -eq 95) "The power candidate should be one five-point reduction."

$tightCoreParams = $base.Clone()
$tightCoreParams.Variable = "Core"
$tightCoreParams.ThermalHeadroom = "Tight"
$tightCore = Invoke-Suggestion $tightCoreParams
Assert-True ($tightCore.Status -eq "Blocked") "Tight thermal headroom must block a positive core offset."
Assert-BlockedContract $tightCore "Tight thermal headroom"

$unknownThermalParams = $base.Clone()
$unknownThermalParams.ThermalHeadroom = "Unknown"
$unknownThermal = Invoke-Suggestion $unknownThermalParams
Assert-True ($unknownThermal.CandidateDisplayedValue -eq 25) "Unknown thermal headroom should use the reduced first step."

$laptopParams = $base.Clone()
$laptopParams.FormFactor = "Laptop"
$laptopParams.BoardModel = "Example Laptop 16 / RTX test board"
$laptop = Invoke-Suggestion $laptopParams
Assert-True ($laptop.CandidateDisplayedValue -eq 25) "A laptop should use the reduced core step."

$ampereParams = $base.Clone()
$ampereParams.GpuModel = "NVIDIA GeForce RTX 3080"
$ampere = Invoke-Suggestion $ampereParams
Assert-True ($ampere.GpuFamily -eq "NVIDIA-Ampere-High") "RTX 3080 should map to the Ampere high tier."
Assert-CoreFirstRound $ampere "NVIDIA-Ampere-High" "RTX 3080"
Assert-True ($ampere.StartEvidenceClass -eq "active-near-cited-maximum") "RTX 3080 must be labelled as an active near-maximum start."
Assert-True ($ampere.StartConfidence -eq "very-low") "RTX 3080 evidence must have very-low start confidence."
Assert-True ($ampere.PublicSourceCount -eq 1) "RTX 3080 evidence must identify its single public source."
Assert-True ($ampere.ObservedMaxCoreOffsetMhz -eq 60) "RTX 3080 observed maximum offset must remain attached."
Assert-True ($ampere.StartToObservedMaxPercent -eq 83) "RTX 3080 start-to-sample ratio must remain explicit."

$ampere3060Params = $base.Clone()
$ampere3060Params.GpuModel = "NVIDIA GeForce RTX 3060"
$ampere3060 = Invoke-Suggestion $ampere3060Params
Assert-True ($ampere3060.GpuFamily -eq "NVIDIA-Ampere-Entry") "RTX 3060 should map to Ampere Entry."
Assert-True ($ampere3060.CandidateDisplayedValue -eq 100) "RTX 3060 should use the entry-tier start."

$ampere3060TiParams = $base.Clone()
$ampere3060TiParams.GpuModel = "NVIDIA GeForce RTX 3060 Ti"
$ampere3060Ti = Invoke-Suggestion $ampere3060TiParams
Assert-True ($ampere3060Ti.GpuFamily -eq "NVIDIA-Ampere-Entry") "RTX 3060 Ti should map to Ampere Entry."
Assert-CoreFirstRound $ampere3060Ti "NVIDIA-Ampere-Entry" "RTX 3060 Ti"
Assert-True ($ampere3060Ti.StartEvidenceClass -eq "active-above-cited-sample") "RTX 3060 Ti must be labelled as an active above-sample start."
Assert-True ($ampere3060Ti.StartConfidence -eq "very-low") "RTX 3060 Ti confidence must reflect weak exact-model coverage."
Assert-True ($ampere3060Ti.PublicSourceCount -eq 1) "RTX 3060 Ti evidence must identify one public source."
Assert-True ($ampere3060Ti.ObservedMaxCoreOffsetMhz -eq 70) "RTX 3060 Ti observed maximum offset must remain attached."
Assert-True ($ampere3060Ti.StartToObservedMaxPercent -eq 143) "RTX 3060 Ti start-to-sample ratio must remain explicit."

$ampere3070Params = $base.Clone()
$ampere3070Params.GpuModel = "NVIDIA GeForce RTX 3070"
$ampere3070 = Invoke-Suggestion $ampere3070Params
Assert-True ($ampere3070.GpuFamily -eq "NVIDIA-Ampere-Mainstream") "RTX 3070 should map to Ampere Mainstream."
Assert-True ($ampere3070.CandidateDisplayedValue -eq 100) "RTX 3070 should use the mainstream start."

$ampere3070TiParams = $base.Clone()
$ampere3070TiParams.GpuModel = "NVIDIA GeForce RTX 3070 Ti"
$ampere3070Ti = Invoke-Suggestion $ampere3070TiParams
Assert-True ($ampere3070Ti.GpuFamily -eq "NVIDIA-Ampere-Mainstream") "RTX 3070 Ti should map to Ampere Mainstream."

$ampere3080TiParams = $base.Clone()
$ampere3080TiParams.GpuModel = "NVIDIA GeForce RTX 3080 Ti"
$ampere3080Ti = Invoke-Suggestion $ampere3080TiParams
Assert-True ($ampere3080Ti.GpuFamily -eq "NVIDIA-Ampere-UpperHigh") "RTX 3080 Ti should map to Ampere UpperHigh."
Assert-True ($ampere3080Ti.CandidateDisplayedValue -eq 100) "RTX 3080 Ti should use the upper-high start."

$ampere3090Params = $base.Clone()
$ampere3090Params.GpuModel = "NVIDIA GeForce RTX 3090"
$ampere3090 = Invoke-Suggestion $ampere3090Params
Assert-True ($ampere3090.GpuFamily -eq "NVIDIA-Ampere-Flagship") "RTX 3090 should map to Ampere Flagship."
Assert-True ($ampere3090.CandidateDisplayedValue -eq 50) "RTX 3090 should use the flagship start."

$ampere3090TiParams = $base.Clone()
$ampere3090TiParams.GpuModel = "NVIDIA GeForce RTX 3090 Ti"
$ampere3090Ti = Invoke-Suggestion $ampere3090TiParams
Assert-True ($ampere3090Ti.GpuFamily -eq "NVIDIA-Ampere-FlagshipTi") "RTX 3090 Ti should map to Ampere FlagshipTi."
Assert-CoreFirstRound $ampere3090Ti "NVIDIA-Ampere-FlagshipTi" "RTX 3090 Ti"
Assert-True ($ampere3090Ti.StartEvidenceClass -eq "active-at-lower-sample-maximum") "RTX 3090 Ti must be labelled as an active sample-level start."
Assert-True ($ampere3090Ti.StartConfidence -eq "very-low") "RTX 3090 Ti evidence must have very-low start confidence."
Assert-True ($ampere3090Ti.PublicSourceCount -eq 1) "RTX 3090 Ti evidence must identify its single public review."
Assert-True ($ampere3090Ti.ObservedMaxCoreOffsetMhz -eq 110) "RTX 3090 Ti observed maximum offset must remain attached."
Assert-True ($ampere3090Ti.StartToObservedMaxPercent -eq 68) "RTX 3090 Ti start-to-sample ratio must remain explicit."

$adaParams = $base.Clone()
$adaParams.GpuModel = "NVIDIA GeForce RTX 4070 SUPER"
$ada = Invoke-Suggestion $adaParams
Assert-True ($ada.GpuFamily -eq "NVIDIA-Ada-Mainstream") "RTX 4070 should map to the Ada mainstream tier."
Assert-True ($ada.CandidateDisplayedValue -eq 125) "RTX 4070 should use its one-step usable core start."

$ada4060Params = $base.Clone()
$ada4060Params.GpuModel = "NVIDIA GeForce RTX 4060"
$ada4060 = Invoke-Suggestion $ada4060Params
Assert-True ($ada4060.GpuFamily -eq "NVIDIA-Ada-Entry") "RTX 4060 should map to Ada Entry."
Assert-True ($ada4060.CandidateDisplayedValue -eq 100) "RTX 4060 should use the entry-tier start."

$ada4060TiParams = $base.Clone()
$ada4060TiParams.GpuModel = "NVIDIA GeForce RTX 4060 Ti 16GB"
$ada4060Ti = Invoke-Suggestion $ada4060TiParams
Assert-True ($ada4060Ti.GpuFamily -eq "NVIDIA-Ada-Entry") "RTX 4060 Ti should map to Ada Entry."
Assert-True ($ada4060Ti.CandidateDisplayedValue -eq 100) "RTX 4060 Ti should use the entry-tier start."

$ada4070SuperParams = $base.Clone()
$ada4070SuperParams.GpuModel = "NVIDIA GeForce RTX 4070 Super"
$ada4070Super = Invoke-Suggestion $ada4070SuperParams
Assert-True ($ada4070Super.GpuFamily -eq "NVIDIA-Ada-Mainstream") "RTX 4070 Super should map to Ada Mainstream."
Assert-True ($ada4070Super.CandidateDisplayedValue -eq 125) "RTX 4070 Super should use the mainstream start."

$ada4070TiParams = $base.Clone()
$ada4070TiParams.GpuModel = "NVIDIA GeForce RTX 4070 Ti"
$ada4070Ti = Invoke-Suggestion $ada4070TiParams
Assert-True ($ada4070Ti.GpuFamily -eq "NVIDIA-Ada-UpperMid") "RTX 4070 Ti should map to Ada UpperMid."
Assert-True ($ada4070Ti.CandidateDisplayedValue -eq 150) "RTX 4070 Ti should use the upper-mid start."

$ada4070TiSuperParams = $base.Clone()
$ada4070TiSuperParams.GpuModel = "NVIDIA GeForce RTX 4070 Ti Super"
$ada4070TiSuper = Invoke-Suggestion $ada4070TiSuperParams
Assert-True ($ada4070TiSuper.GpuFamily -eq "NVIDIA-Ada-UpperMid") "RTX 4070 Ti Super should map to Ada UpperMid."

$ada4080Params = $base.Clone()
$ada4080Params.GpuModel = "NVIDIA GeForce RTX 4080"
$ada4080 = Invoke-Suggestion $ada4080Params
Assert-True ($ada4080.GpuFamily -eq "NVIDIA-Ada-High") "RTX 4080 should map to Ada High."
Assert-CoreFirstRound $ada4080 "NVIDIA-Ada-High" "RTX 4080"
Assert-True ($ada4080.StartEvidenceClass -eq "active-near-cited-maximum") "RTX 4080 must be labelled as an active near-maximum start."
Assert-True ($ada4080.StartConfidence -eq "very-low") "RTX 4080 evidence must have very-low start confidence."
Assert-True ($ada4080.PublicSourceCount -eq 2) "RTX 4080 evidence must report two public sources."
Assert-True ($ada4080.ObservedMaxCoreOffsetMhz -eq 205) "RTX 4080 observed maximum offset must remain attached."
Assert-True ($ada4080.StartToObservedMaxPercent -eq 85) "RTX 4080 start-to-sample ratio must remain explicit."

$ada4080SuperParams = $base.Clone()
$ada4080SuperParams.GpuModel = "NVIDIA GeForce RTX 4080 Super"
$ada4080Super = Invoke-Suggestion $ada4080SuperParams
Assert-True ($ada4080Super.GpuFamily -eq "NVIDIA-Ada-High") "RTX 4080 Super should map to Ada High."

$ada4090Params = $base.Clone()
$ada4090Params.GpuModel = "NVIDIA GeForce RTX 4090"
$ada4090 = Invoke-Suggestion $ada4090Params
Assert-True ($ada4090.GpuFamily -eq "NVIDIA-Ada-Flagship") "RTX 4090 should map to Ada Flagship."
Assert-True ($ada4090.CandidateDisplayedValue -eq 100) "RTX 4090 should use the conservative flagship start."

$adaMemoryParams = $adaParams.Clone()
$adaMemoryParams.CoreValidated = $true
$adaMemoryParams.Variable = "Memory"
$adaMemoryParams.TuningIntent = "explore-limit"
$adaMemoryParams.ResultVerdict = "pass"
$adaMemoryParams.MaterialBenefit = "Yes"
$adaMemoryParams.NoiseExceeded = "Yes"
$adaMemoryParams.EffectiveClockImproved = "Yes"
$adaMemoryParams.ThermalAcceptable = "Yes"
$adaMemoryParams.PowerAcceptable = "Yes"
$adaMemoryParams.Artifacts = "None"
$adaMemory = Invoke-Suggestion $adaMemoryParams
Assert-True ($adaMemory.CandidateDisplayedValue -eq 200) "Ada should use its larger first memory step after core validation."

$blackwellParams = $base.Clone()
$blackwellParams.GpuModel = "NVIDIA GeForce RTX 5070 Ti"
$blackwell = Invoke-Suggestion $blackwellParams
Assert-True ($blackwell.GpuFamily -eq "NVIDIA-Blackwell-Mainstream") "RTX 5070 Ti should map to the Blackwell mainstream tier."
Assert-True ($blackwell.CandidateDisplayedValue -eq 150) "RTX 5070 Ti should use its one-step usable core start."

$blackwell5060Params = $base.Clone()
$blackwell5060Params.GpuModel = "NVIDIA GeForce RTX 5060"
$blackwell5060 = Invoke-Suggestion $blackwell5060Params
Assert-True ($blackwell5060.GpuFamily -eq "NVIDIA-Blackwell-Entry") "RTX 5060 should map to the Blackwell entry tier."
Assert-True ($blackwell5060.CandidateDisplayedValue -eq 100) "RTX 5060 should use the entry-tier one-step start."

$blackwell5060TiParams = $base.Clone()
$blackwell5060TiParams.GpuModel = "NVIDIA GeForce RTX 5060 Ti 16GB"
$blackwell5060Ti = Invoke-Suggestion $blackwell5060TiParams
Assert-True ($blackwell5060Ti.GpuFamily -eq "NVIDIA-Blackwell-Entry") "RTX 5060 Ti should map to the Blackwell entry tier."
Assert-True ($blackwell5060Ti.CandidateDisplayedValue -eq 100) "RTX 5060 Ti should use the entry-tier one-step start."

$blackwell5080Params = $base.Clone()
$blackwell5080Params.GpuModel = "NVIDIA GeForce RTX 5080"
$blackwell5080 = Invoke-Suggestion $blackwell5080Params
Assert-True ($blackwell5080.GpuFamily -eq "NVIDIA-Blackwell-High") "RTX 5080 should map to the Blackwell high tier."
Assert-CoreFirstRound $blackwell5080 "NVIDIA-Blackwell-High" "RTX 5080"
Assert-True ($blackwell5080.StartEvidenceClass -eq "single-source-no-matched-offset") "RTX 5080 must disclose its unmatched single-source evidence."
Assert-True ($blackwell5080.StartConfidence -eq "very-low") "RTX 5080 must not retain ordinary start confidence."
Assert-True ($blackwell5080.Confidence -eq "very-low") "RTX 5080 candidate confidence must reflect source coverage."
Assert-True ($blackwell5080.PublicSourceCount -eq 1) "RTX 5080 must not imply second-source offset coverage."
Assert-True ($null -eq $blackwell5080.ObservedMaxCoreOffsetMhz) "RTX 5080 must not invent a normalized observed offset maximum."

$blackwell5090Params = $base.Clone()
$blackwell5090Params.GpuModel = "NVIDIA GeForce RTX 5090"
$blackwell5090 = Invoke-Suggestion $blackwell5090Params
Assert-True ($blackwell5090.GpuFamily -eq "NVIDIA-Blackwell-Flagship") "RTX 5090 should map to the Blackwell flagship tier."
Assert-True ($blackwell5090.CandidateDisplayedValue -eq 100) "RTX 5090 should use the flagship simple-offset start."

$blackwellMemoryBoundaryParams = $blackwell5060Params.Clone()
$blackwellMemoryBoundaryParams.CoreValidated = $true
$blackwellMemoryBoundaryParams.Variable = "Memory"
$blackwellMemoryBoundaryParams.TuningIntent = "explore-limit"
$blackwellMemoryBoundaryParams.ResultVerdict = "pass"
$blackwellMemoryBoundaryParams.MaterialBenefit = "Yes"
$blackwellMemoryBoundaryParams.NoiseExceeded = "Yes"
$blackwellMemoryBoundaryParams.EffectiveClockImproved = "Yes"
$blackwellMemoryBoundaryParams.ThermalAcceptable = "Yes"
$blackwellMemoryBoundaryParams.PowerAcceptable = "Yes"
$blackwellMemoryBoundaryParams.Artifacts = "None"
$blackwellMemoryBoundary = Invoke-Suggestion $blackwellMemoryBoundaryParams
Assert-True ($blackwellMemoryBoundary.ReferenceBoundary -match '^375 ') "RTX 50 memory auto boundary should reflect the Blackwell request clamp."

$amdParams = $base.Clone()
$amdParams.Vendor = "AMD"
$amdParams.GpuModel = "AMD Radeon RX 7800 XT"
$amdCore = Invoke-Suggestion $amdParams
Assert-True ($amdCore.GpuFamily -eq "AMD-RDNA3") "RX 7000 should map to AMD RDNA3."
Assert-True ($amdCore.CandidateDisplayedValue -eq 75) "RDNA3 should start with a usable core step."

$amdCoreActualParams = $amdParams.Clone()
$amdCoreActualParams.CoreControlKind = "ClockTarget"
$amdCoreActualParams.BaselineCoreValueMhz = 2400
$amdCoreActualParams.Remove("CurrentCoreOffsetMhz")
$amdCoreActualParams.CurrentCoreValueMhz = 2400
$amdCoreActual = Invoke-Suggestion $amdCoreActualParams
Assert-True ($amdCoreActual.Variable -eq "Core clock target") "An AMD actual core clock must not be called an offset."
Assert-True ($amdCoreActual.CandidateDisplayedValue -eq 2475) "RDNA3 actual core clocks should advance by the usable family step."

$amdMemoryParams = $amdParams.Clone()
$amdMemoryParams.CoreValidated = $true
$amdMemoryParams.Variable = "Memory"
$amdMemoryParams.TuningIntent = "explore-limit"
$amdMemoryParams.ResultVerdict = "pass"
$amdMemoryParams.MaterialBenefit = "Yes"
$amdMemoryParams.NoiseExceeded = "Yes"
$amdMemoryParams.EffectiveClockImproved = "Yes"
$amdMemoryParams.ThermalAcceptable = "Yes"
$amdMemoryParams.PowerAcceptable = "Yes"
$amdMemoryParams.Artifacts = "None"
$amdMemoryParams.MemoryControlKind = "ClockTarget"
$amdMemoryParams.BaselineMemoryOffsetMhz = 2400
$amdMemoryParams.CurrentMemoryOffsetMhz = 2500
$amdMemory = Invoke-Suggestion $amdMemoryParams
Assert-True ($amdMemory.Variable -eq "Memory clock target") "An AMD actual-clock control must not be called an offset."
Assert-True ($amdMemory.CandidateDisplayedValue -eq 2600) "RDNA3 memory should advance by the family step."
Assert-True ($amdMemory.Unit -eq "MHz displayed clock target") "AMD clock-target units must remain explicit."

$rdna4Params = $base.Clone()
$rdna4Params.Vendor = "AMD"
$rdna4Params.GpuModel = "AMD Radeon RX 9070 XT"
$rdna4 = Invoke-Suggestion $rdna4Params
Assert-True ($rdna4.GpuFamily -eq "AMD-RDNA4") "RX 9000 should map to AMD RDNA4."

$unknownAmdParams = $base.Clone()
$unknownAmdParams.Vendor = "AMD"
$unknownAmdParams.GpuModel = "AMD Radeon graphics"
$unknownAmd = Invoke-Suggestion $unknownAmdParams
Assert-True ($unknownAmd.GpuFamily -eq "AMD-Generic") "An unclassified AMD model must retain a generic AMD path."

foreach ($requiredField in @("TargetComponent", "FixedWorkload", "PassCriteria", "AbortSignals")) {
    $missingExperiment = $base.Clone()
    $missingExperiment.Remove($requiredField)
    $missing = Invoke-Suggestion $missingExperiment
    Assert-True ($missing.Status -eq "Blocked") "Missing $requiredField must block candidates."
    Assert-True ($null -eq $missing.CandidateDisplayedValue) "Missing $requiredField must not expose a numeric candidate."
}

$laptopConflictParams = $base.Clone()
$laptopConflictParams.GpuModel = "NVIDIA GeForce RTX 4090 Laptop GPU"
$laptopConflict = Invoke-Suggestion $laptopConflictParams
Assert-True ($laptopConflict.Status -eq "Blocked") "A mobile model with Desktop form factor must be blocked."
Assert-True ($null -eq $laptopConflict.CandidateDisplayedValue) "A form-factor conflict must not expose a candidate."
Assert-BlockedContract $laptopConflict "Laptop model with Desktop form factor"

$familyConflictParams = $base.Clone()
$familyConflictParams.GpuModel = "NVIDIA GeForce RTX 3080"
$familyConflictParams.GpuFamily = "NVIDIA-Ada"
$familyConflict = Invoke-Suggestion $familyConflictParams
Assert-True ($familyConflict.Status -eq "Blocked") "An explicit family that conflicts with the model must be blocked."
Assert-True ($null -eq $familyConflict.CandidateDisplayedValue) "A family conflict must not expose a candidate."
Assert-BlockedContract $familyConflict "Explicit family mismatch"

$explicitWithoutModelParams = $base.Clone()
$explicitWithoutModelParams.GpuFamily = "NVIDIA-Ampere"
$explicitWithoutModel = Invoke-Suggestion $explicitWithoutModelParams
Assert-True ($explicitWithoutModel.Status -eq "Blocked") "An explicit family without a recognized model cannot produce a numeric candidate."
Assert-BlockedContract $explicitWithoutModel "Explicit family without model"

$amdMobileConflictParams = $base.Clone()
$amdMobileConflictParams.Vendor = "AMD"
$amdMobileConflictParams.GpuModel = "AMD Radeon RX 7900M"
$amdMobileConflict = Invoke-Suggestion $amdMobileConflictParams
Assert-True ($amdMobileConflict.Status -eq "Blocked") "An AMD mobile model with Desktop form factor must be blocked."
Assert-BlockedContract $amdMobileConflict "AMD mobile model with Desktop form factor"

$amdLaptopParams = $base.Clone()
$amdLaptopParams.Vendor = "AMD"
$amdLaptopParams.GpuModel = "AMD Radeon RX 7900M"
$amdLaptopParams.FormFactor = "Laptop"
$amdLaptopParams.BoardModel = "Example AMD Laptop 16 / RX test board"
$amdLaptop = Invoke-Suggestion $amdLaptopParams
Assert-True ($amdLaptop.GpuFamily -eq "AMD-RDNA3") "A readable AMD mobile model should retain its generation."
Assert-True ($amdLaptop.ReferenceBoundary -match '^75 MHz') "An AMD mobile model must use the laptop boundary."

$professionalParams = $base.Clone()
$professionalParams.GpuModel = "NVIDIA RTX A5000"
$professional = Invoke-Suggestion $professionalParams
Assert-True ($professional.Status -eq "Blocked") "A professional GPU class must not receive the consumer profile."
Assert-BlockedContract $professional "Professional GPU"

$vendorConflictParams = $base.Clone()
$vendorConflictParams.Vendor = "NVIDIA"
$vendorConflictParams.GpuModel = "AMD Radeon RX 7800 XT"
$vendorConflict = Invoke-Suggestion $vendorConflictParams
Assert-True ($vendorConflict.Status -eq "Blocked") "A model from another GPU vendor must be blocked."
Assert-BlockedContract $vendorConflict "Vendor/model mismatch"

$curveParams = $base.Clone()
$curveParams.CoreControlKind = "Curve"
$curve = Invoke-Suggestion $curveParams
Assert-True ($curve.Status -eq "Blocked") "A curve control must not receive a direct offset number."
Assert-True ($null -eq $curve.CandidateDisplayedValue) "A curve control must not expose a numeric offset."
Assert-BlockedContract $curve "Curve control"

$unsupportedParams = $base.Clone()
$unsupportedParams.CoreControlKind = "Unsupported"
$unsupported = Invoke-Suggestion $unsupportedParams
Assert-True ($unsupported.Status -eq "Blocked") "An unsupported control must not receive a numeric candidate."
Assert-BlockedContract $unsupported "Unsupported core control"

$missingAmdBaselineParams = $amdParams.Clone()
$missingAmdBaselineParams.CoreControlKind = "ClockTarget"
$missingAmdBaselineParams.Remove("CurrentCoreOffsetMhz")
$missingAmdBaselineParams.CurrentCoreValueMhz = 2400
$missingAmdBaseline = Invoke-Suggestion $missingAmdBaselineParams
Assert-True ($missingAmdBaseline.Status -eq "Blocked") "AMD actual-clock control without a stock baseline must be blocked."
Assert-BlockedContract $missingAmdBaseline "AMD clock target without stock baseline"

$powerFloorParams = $base.Clone()
$powerFloorParams.DominantLimit = "Power"
$powerFloorParams.CurrentPowerLimitPct = 65
$powerFloor = Invoke-Suggestion $powerFloorParams
Assert-True ($powerFloor.Status -eq "Stop") "The power/efficiency helper must stop at the automatic floor."
Assert-True ($null -eq $powerFloor.CandidateDisplayedValue) "The power floor must not expose another downward candidate."

$repeatA = Invoke-Suggestion $adaParams
$repeatB = Invoke-Suggestion $adaParams
Assert-True ($repeatA.Status -eq $repeatB.Status) "Identical input should produce an identical status."
Assert-True ($repeatA.CandidateDisplayedValue -eq $repeatB.CandidateDisplayedValue) "Identical input should produce an identical candidate."
Assert-True ($repeatA.EvidenceBasis -eq $repeatB.EvidenceBasis) "Identical input should produce an identical evidence basis."

$workstationAdaParams = $base.Clone()
$workstationAdaParams.GpuModel = "NVIDIA RTX 6000 Ada Generation"
$workstationAda = Invoke-Suggestion $workstationAdaParams
Assert-BlockedContract $workstationAda "NVIDIA RTX 6000 Ada professional class"

$h100Params = $base.Clone()
$h100Params.GpuModel = "NVIDIA H100 PCIe"
$h100 = Invoke-Suggestion $h100Params
Assert-BlockedContract $h100 "NVIDIA H100 data-center class"

$amdApuParams = $base.Clone()
$amdApuParams.Vendor = "AMD"
$amdApuParams.GpuModel = "AMD Radeon 780M"
$amdApu = Invoke-Suggestion $amdApuParams
Assert-BlockedContract $amdApu "AMD integrated graphics class"

$intelGraphicsParams = $base.Clone()
$intelGraphicsParams.Vendor = "Intel"
$intelGraphicsParams.GpuModel = "Intel(R) Arc(TM) Graphics"
$intelGraphics = Invoke-Suggestion $intelGraphicsParams
Assert-BlockedContract $intelGraphics "Intel integrated Arc graphics class"

$cpuTargetParams = $base.Clone()
$cpuTargetParams.GpuModel = "NVIDIA GeForce RTX 4070"
$cpuTargetParams.TargetComponent = "CPU"
$cpuTarget = Invoke-Suggestion $cpuTargetParams
Assert-BlockedContract $cpuTarget "CPU target for GPU tuner"

$exactTargetParams = $base.Clone()
$exactTargetParams.GpuModel = "NVIDIA GeForce RTX 4070"
$exactTargetParams.TargetComponent = "NVIDIA GeForce RTX 4070"
$exactTarget = Invoke-Suggestion $exactTargetParams
Assert-True ($exactTarget.Status -eq "Ready") "The exact selected GPU model should be a valid target identifier."
Assert-True ($exactTarget.ResolvedGpuModel -eq "NVIDIA GeForce RTX 4070") "The candidate should preserve the resolved exact GPU model."
Assert-True ($exactTarget.AdapterIdentityStatus -eq "single-readable-model") "A single readable model should be recorded explicitly."

$multiNvidiaParams = $base.Clone()
$multiNvidiaParams.GpuModel = "NVIDIA GeForce RTX 4070; NVIDIA GeForce RTX 3080"
$multiNvidia = Invoke-Suggestion $multiNvidiaParams
Assert-BlockedContract $multiNvidia "Multiple NVIDIA models"

$multiAmdParams = $base.Clone()
$multiAmdParams.Vendor = "AMD"
$multiAmdParams.GpuModel = "AMD Radeon RX 7900 XTX; AMD Radeon RX 7800 XT"
$multiAmd = Invoke-Suggestion $multiAmdParams
Assert-BlockedContract $multiAmd "Multiple AMD models"

$mixedGpuParams = $base.Clone()
$mixedGpuParams.Vendor = "AMD"
$mixedGpuParams.GpuModel = "AMD Radeon RX 7800 XT; NVIDIA GeForce RTX 4070"
$mixedGpu = Invoke-Suggestion $mixedGpuParams
Assert-BlockedContract $mixedGpu "Mixed AMD and NVIDIA models"

$missingBaselineEvidenceParams = $base.Clone()
$missingBaselineEvidenceParams.Remove("BaselineRecorded")
$missingBaselineEvidence = Invoke-Suggestion $missingBaselineEvidenceParams
Assert-BlockedContract $missingBaselineEvidence "Missing baseline evidence semantics"

$memoryModeParams = $base.Clone()
$memoryModeParams.CoreValidated = $true
$memoryModeParams.Variable = "Memory"
$memoryModeParams.TuningIntent = "explore-limit"
$memoryModeParams.ResultVerdict = "pass"
$memoryModeParams.MaterialBenefit = "Yes"
$memoryModeParams.NoiseExceeded = "Yes"
$memoryModeParams.EffectiveClockImproved = "Yes"
$memoryModeParams.ThermalAcceptable = "Yes"
$memoryModeParams.PowerAcceptable = "Yes"
$memoryModeParams.Artifacts = "None"
$memoryModeParams.MemoryControlKind = "Mode"
$memoryMode = Invoke-Suggestion $memoryModeParams
Assert-BlockedContract $memoryMode "Memory mode control"

$memoryUnsupportedParams = $base.Clone()
$memoryUnsupportedParams.CoreValidated = $true
$memoryUnsupportedParams.Variable = "Memory"
$memoryUnsupportedParams.TuningIntent = "explore-limit"
$memoryUnsupportedParams.ResultVerdict = "pass"
$memoryUnsupportedParams.MaterialBenefit = "Yes"
$memoryUnsupportedParams.NoiseExceeded = "Yes"
$memoryUnsupportedParams.EffectiveClockImproved = "Yes"
$memoryUnsupportedParams.ThermalAcceptable = "Yes"
$memoryUnsupportedParams.PowerAcceptable = "Yes"
$memoryUnsupportedParams.Artifacts = "None"
$memoryUnsupportedParams.MemoryControlKind = "Unsupported"
$memoryUnsupported = Invoke-Suggestion $memoryUnsupportedParams
Assert-BlockedContract $memoryUnsupported "Unsupported memory control"

$nonConsumerSamples = @(
    @{ Vendor = "NVIDIA"; Model = "NVIDIA RTX 4000 SFF Ada Generation" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA RTX 5000 Ada" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA RTX 5880 Ada Generation" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA A2" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA A10" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA A10G" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA A16" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA A800" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA H800" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA L2" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA L20" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GH200" },
    @{ Vendor = "Intel"; Model = "Intel Data Center GPU Flex 140" },
    @{ Vendor = "Intel"; Model = "Intel Data Center GPU Flex 170" },
    @{ Vendor = "Intel"; Model = "Intel(R) Graphics" },
    @{ Vendor = "Intel"; Model = "Intel(R) Graphics 770" },
    @{ Vendor = "AMD"; Model = "AMD Radeon 890M" },
    @{ Vendor = "AMD"; Model = "AMD Radeon 860M" }
)
foreach ($sample in $nonConsumerSamples) {
    $sampleParams = $base.Clone()
    $sampleParams.Vendor = $sample.Vendor
    $sampleParams.GpuModel = $sample.Model
    $sampleResult = Invoke-Suggestion $sampleParams
    Assert-BlockedContract $sampleResult "Non-consumer GPU $($sample.Model)"
}

$multiAdapterSamples = @(
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070; Intel(R) UHD Graphics 770" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070; Intel(R) Graphics" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070; Intel Arc A770" },
    @{ Vendor = "AMD"; Model = "AMD Radeon RX 7800 XT; Intel(R) UHD Graphics 770" },
    @{ Vendor = "AMD"; Model = "AMD Radeon RX 7800 XT; Intel Arc A770" }
)
foreach ($sample in $multiAdapterSamples) {
    $sampleParams = $base.Clone()
    $sampleParams.Vendor = $sample.Vendor
    $sampleParams.GpuModel = $sample.Model
    $sampleResult = Invoke-Suggestion $sampleParams
    Assert-BlockedContract $sampleResult "Cross-vendor adapters $($sample.Model)"
    Assert-True ($sampleResult.DetectedModelTokenCount -gt 1) "Cross-vendor adapter text should expose more than one model token."
    Assert-True ($sampleResult.AdapterIdentityStatus -eq "ambiguous-multiple-models") "Cross-vendor adapter text should be marked ambiguous."
}

$fullWidthSemicolon = [char]0xFF1B
$fullWidthComma = [char]0xFF0C
$ideographicComma = [char]0x3001
$compositeSeparatorSamples = @(
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070, Intel UHD Graphics 770" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070 / Intel UHD Graphics 770" },
    @{ Vendor = "NVIDIA"; Model = 'NVIDIA GeForce RTX 4070 \ Intel UHD Graphics 770' },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070 (Intel UHD Graphics 770)" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070 & Intel UHD Graphics 770" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070 and Intel UHD Graphics 770" },
    @{ Vendor = "NVIDIA"; Model = ("NVIDIA GeForce RTX 4070{0}Intel UHD Graphics 770" -f $fullWidthSemicolon) },
    @{ Vendor = "NVIDIA"; Model = ("NVIDIA GeForce RTX 4070{0}Intel UHD Graphics 770" -f $fullWidthComma) },
    @{ Vendor = "NVIDIA"; Model = ("NVIDIA GeForce RTX 4070{0}Intel UHD Graphics 770" -f $ideographicComma) },
    @{ Vendor = "AMD"; Model = "AMD Radeon RX 7800 XT, Intel UHD Graphics 770" },
    @{ Vendor = "AMD"; Model = ("AMD Radeon RX 7800 XT{0}Intel UHD Graphics 770" -f $fullWidthSemicolon) },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070; AMD Radeon RX 7800 XT; Intel UHD Graphics 770" }
)
foreach ($sample in $compositeSeparatorSamples) {
    $sampleParams = $base.Clone()
    $sampleParams.Vendor = $sample.Vendor
    $sampleParams.GpuModel = $sample.Model
    $sampleResult = Invoke-Suggestion $sampleParams
    Assert-BlockedContract $sampleResult "Composite adapter separator $($sample.Model)"
    Assert-True ($sampleResult.DetectedModelTokenCount -gt 1) "Composite adapter separator should expose more than one model token."
    Assert-True ($sampleResult.AdapterIdentityStatus -eq "ambiguous-multiple-models") "Composite adapter separator should be marked ambiguous."
}

$consumerControlSamples = @(
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 4070" },
    @{ Vendor = "NVIDIA"; Model = "NVIDIA GeForce RTX 5070 Ti" },
    @{ Vendor = "AMD"; Model = "AMD Radeon RX 7800 XT" },
    @{ Vendor = "AMD"; Model = "AMD Radeon RX 9070 XT" },
    @{ Vendor = "Intel"; Model = "Intel Arc B580" }
)
foreach ($sample in $consumerControlSamples) {
    $sampleParams = $base.Clone()
    $sampleParams.Vendor = $sample.Vendor
    $sampleParams.GpuModel = $sample.Model
    $sampleResult = Invoke-Suggestion $sampleParams
    Assert-True ($sampleResult.Status -eq "Ready") "Consumer control model $($sample.Model) should remain eligible."
    Assert-True ($sampleResult.AdapterIdentityStatus -eq "single-readable-model") "Consumer control model $($sample.Model) should resolve to one adapter."
}

$unknownWithoutConfirmationParams = $base.Clone()
$unknownWithoutConfirmationParams.GpuModel = "NVIDIA GeForce RTX"
$unknownWithoutConfirmationParams.Remove("ConsumerGpuConfirmed")
$unknownWithoutConfirmation = Invoke-Suggestion $unknownWithoutConfirmationParams
Assert-BlockedContract $unknownWithoutConfirmation "Unrecognized model without consumer-GPU confirmation"

$emptyModelWithoutConfirmationParams = $base.Clone()
$emptyModelWithoutConfirmationParams.Remove("ConsumerGpuConfirmed")
$emptyModelWithoutConfirmation = Invoke-Suggestion $emptyModelWithoutConfirmationParams
Assert-BlockedContract $emptyModelWithoutConfirmation "Missing model without consumer-GPU confirmation"

$a10gConfirmedParams = $base.Clone()
$a10gConfirmedParams.GpuModel = "NVIDIA A10G"
$a10gConfirmedParams.ConsumerGpuConfirmed = $true
$a10gConfirmed = Invoke-Suggestion $a10gConfirmedParams
Assert-BlockedContract $a10gConfirmed "A10G data-center card with consumer confirmation"

Assert-True ($ada.TuningIntent -eq "usable-start") "The default tuning intent should be usable-start."
Assert-True ($ada.CandidateRole -eq "usable-start") "A first consumer candidate should be labelled usable-start."
Assert-True ($null -ne $ada.FallbackCandidate) "A ready first candidate must include a fallback."
Assert-True ($ada.StopWhenGoodEnough -eq $true) "usable-start should stop after a good-enough result."
Assert-True ($ada.ExpectedPassLikelihood -eq "medium") "A recognized family with good thermal evidence should use medium qualitative pass likelihood."
Assert-True ($ada.ExpectedMagnitude -eq "unknown") "No calibrated history may claim a numeric expected magnitude."

$keepParams = $adaParams.Clone()
$keepParams.CoreValidated = $true
$keepParams.CurrentCoreOffsetMhz = 75
$keepParams.ResultVerdict = "pass"
$keepParams.MaterialBenefit = "Yes"
$keepParams.NoiseExceeded = "Yes"
$keepParams.EffectiveClockImproved = "Yes"
$keepParams.ThermalAcceptable = "Yes"
$keepParams.PowerAcceptable = "Yes"
$keepParams.Artifacts = "None"
$keepResult = Invoke-Suggestion $keepParams
Assert-True ($keepResult.Status -eq "Keep") "A material usable core result should stop at keep."
Assert-True ($keepResult.ReachedUsableCandidate -eq $true) "A material usable result should mark the useful start reached."
Assert-True ($keepResult.SuggestedAction -eq "keep") "A material usable result should recommend keep."
Assert-True ($null -eq $keepResult.CandidateDisplayedValue) "A completed usable result should not automatically offer another numeric step."

$noBenefitParams = $adaParams.Clone()
$noBenefitParams.CoreValidated = $true
$noBenefitParams.ResultVerdict = "pass"
$noBenefitParams.MaterialBenefit = "No"
$noBenefitParams.NoiseExceeded = "No"
$noBenefitParams.EffectiveClockImproved = "Yes"
$noBenefitParams.ThermalAcceptable = "Yes"
$noBenefitParams.PowerAcceptable = "Yes"
$noBenefitParams.Artifacts = "None"
$noBenefit = Invoke-Suggestion $noBenefitParams
Assert-True ($noBenefit.Status -eq "DiagnoseFirst") "A pass without material benefit must not be treated as usable."
Assert-True ($noBenefit.SuggestedAction -eq "diagnose") "A no-benefit pass should diagnose rather than increase."
Assert-True ($null -eq $noBenefit.CandidateDisplayedValue) "A no-benefit pass must not produce another value."

$inconclusiveParams = $adaParams.Clone()
$inconclusiveParams.CoreValidated = $true
$inconclusiveParams.ResultVerdict = "inconclusive"
$inconclusiveParams.MaterialBenefit = "Unknown"
$inconclusiveParams.NoiseExceeded = "Unknown"
$inconclusive = Invoke-Suggestion $inconclusiveParams
Assert-True ($inconclusive.Status -eq "DiagnoseFirst") "An inconclusive result should request a repeat."
Assert-True ($inconclusive.SuggestedAction -eq "repeat") "An inconclusive result should not increase the value."

$failParams = $adaParams.Clone()
$failParams.CoreValidated = $true
$failParams.ResultVerdict = "fail"
$failParams.Artifacts = "Observed"
$failParams.ThermalAcceptable = "Yes"
$failParams.PowerAcceptable = "Yes"
$failResult = Invoke-Suggestion $failParams
Assert-True ($failResult.Status -eq "Revert") "A failed or artifact-bearing round should revert."
Assert-True ($failResult.SuggestedAction -eq "fallback") "A failed round should provide the fallback action."
Assert-True ($null -ne $failResult.FallbackCandidate) "A failure must expose the pre-generated fallback candidate."
Assert-True ($null -eq $failResult.CandidateDisplayedValue) "A failure must not expose another numeric candidate."

$exploreParams = $adaParams.Clone()
$exploreParams.TuningIntent = "explore-limit"
$exploreParams.CoreValidated = $true
$exploreParams.CurrentCoreOffsetMhz = 75
$exploreParams.ResultVerdict = "pass"
$exploreParams.MaterialBenefit = "Yes"
$exploreParams.NoiseExceeded = "Yes"
$exploreParams.EffectiveClockImproved = "Yes"
$exploreParams.ThermalAcceptable = "Yes"
$exploreParams.PowerAcceptable = "Yes"
$exploreParams.Artifacts = "None"
$explore = Invoke-Suggestion $exploreParams
Assert-True ($explore.Status -eq "Ready") "explore-limit should continue after a material accepted round."
Assert-True ($explore.CandidateRole -eq "limit-exploration") "explore-limit candidates should be labelled as limit exploration."
Assert-True ($explore.StopWhenGoodEnough -eq $false) "explore-limit should not stop at the first usable point."

$curveParams = $adaParams.Clone()
$curveParams.CoreControlKind = "Curve"
$curveParams.CurrentCoreVoltageMv = 950
$curveParams.CurrentCoreFrequencyMhz = 2700
$curveResult = Invoke-Suggestion $curveParams
Assert-True ($curveResult.Status -eq "Ready") "A curve control with a measured anchor should produce a curve start."
Assert-True ($curveResult.CandidateType -eq "curve-start") "The curve route should expose a curve-start candidate type."
Assert-True ($null -eq $curveResult.CandidateDisplayedValue) "A curve start must not fabricate a direct offset value."
Assert-True ($curveResult.CurveStart.CandidateFrequencyMhz -gt $curveResult.CurveStart.CurrentFrequencyMhz) "The curve start should advance the measured anchor frequency."
Assert-True ($null -ne $curveResult.FallbackCandidate) "The curve start must include a baseline fallback."

$curveMissingParams = $adaParams.Clone()
$curveMissingParams.CoreControlKind = "Curve"
$curveMissing = Invoke-Suggestion $curveMissingParams
Assert-BlockedContract $curveMissing "Curve without measured voltage/frequency anchor"

$graphicsSuffixNvidiaParams = $adaParams.Clone()
$graphicsSuffixNvidiaParams.GpuModel = "NVIDIA GeForce RTX 4070 Graphics"
$graphicsSuffixNvidia = Invoke-Suggestion $graphicsSuffixNvidiaParams
Assert-True ($graphicsSuffixNvidia.Status -eq "Ready") "A NVIDIA consumer model ending in Graphics should remain eligible."
Assert-True ($graphicsSuffixNvidia.DetectedModelTokenCount -eq 1) "A trailing Graphics word must not count as a second adapter."

$graphicsSuffixAmdParams = $amdParams.Clone()
$graphicsSuffixAmdParams.GpuModel = "AMD Radeon RX 7800 XT Graphics"
$graphicsSuffixAmd = Invoke-Suggestion $graphicsSuffixAmdParams
Assert-True ($graphicsSuffixAmd.Status -eq "Ready") "An AMD consumer model ending in Graphics should remain eligible."
Assert-True ($graphicsSuffixAmd.DetectedModelTokenCount -eq 1) "A trailing AMD Graphics word must not count as a second adapter."

$stateAParams = $adaParams.Clone()
$stateAParams.DriverVersion = "driver-a"
$stateAParams.TuningToolVersion = "tool-a"
$stateA = Invoke-Suggestion $stateAParams
$stateB = Invoke-Suggestion $stateAParams
Assert-True ($stateA.DeviceFingerprint -eq $stateB.DeviceFingerprint) "Identical device context must produce a stable fingerprint."
Assert-True ($stateA.ExperimentId -eq $stateB.ExperimentId) "Identical experiment context must produce a stable experiment ID."
Assert-True ($stateA.CandidateId -eq $stateB.CandidateId) "Identical candidate context must produce a stable candidate ID."

$stateChangedParams = $stateAParams.Clone()
$stateChangedParams.DriverVersion = "driver-b"
$stateChanged = Invoke-Suggestion $stateChangedParams
Assert-True ($stateChanged.DeviceFingerprint -ne $stateA.DeviceFingerprint) "A driver change must invalidate the device fingerprint."
Assert-True ($stateChanged.ExperimentId -ne $stateA.ExperimentId) "A driver change must produce a new experiment context."

$invalidParentParams = $adaParams.Clone()
$invalidParentParams.ParentCandidateId = "candidate-123"
$invalidParent = Invoke-Suggestion $invalidParentParams
Assert-BlockedContract $invalidParent "ParentCandidateId without parent context"

$validParentParams = $adaParams.Clone()
$validParentParams.ParentCandidateId = $ada.CandidateId
$validParentParams.ParentCandidateValue = [string]$ada.CandidateDisplayedValue
$validParentParams.ParentControlKind = "Core"
$validParentParams.ParentExperimentId = $ada.ExperimentId
$validParent = Invoke-Suggestion $validParentParams
Assert-True ($validParent.Status -eq "Ready") "A valid parent context should resume the session."
Assert-True ($validParent.ResumeState -eq "session-validated") "A validated parent context should be session-validated."

$wrongParentValueParams = $validParentParams.Clone()
$wrongParentValueParams.ParentCandidateValue = "999"
$wrongParentValue = Invoke-Suggestion $wrongParentValueParams
Assert-BlockedContract $wrongParentValue "ParentCandidateId with changed candidate value"

$staleParams = $adaParams.Clone()
$staleParams.ReportFreshness = "Stale"
$stale = Invoke-Suggestion $staleParams
Assert-BlockedContract $stale "Stale report context"

Assert-True (-not [string]::IsNullOrWhiteSpace($ada.CandidateId)) "Every Ready candidate must include a CandidateId."

$reliabilityPassParams = $adaParams.Clone()
$reliabilityPassParams.DominantLimit = "Reliability"
$reliabilityPassParams.ResultVerdict = "pass"
$reliabilityPassParams.MaterialBenefit = "Yes"
$reliabilityPassParams.NoiseExceeded = "Yes"
$reliabilityPassParams.EffectiveClockImproved = "Yes"
$reliabilityPassParams.ThermalAcceptable = "Yes"
$reliabilityPassParams.PowerAcceptable = "Yes"
$reliabilityPassParams.Artifacts = "None"
$reliabilityPass = Invoke-Suggestion $reliabilityPassParams
Assert-True ($reliabilityPass.Status -eq "Stop") "Reliability must override all-pass result evidence."
Assert-True ($reliabilityPass.ReachedUsableCandidate -eq $false) "Reliability must never produce a usable candidate."

$utilizationPassParams = $adaParams.Clone()
$utilizationPassParams.DominantLimit = "Utilization"
$utilizationPassParams.ResultVerdict = "pass"
$utilizationPassParams.MaterialBenefit = "Yes"
$utilizationPassParams.NoiseExceeded = "Yes"
$utilizationPassParams.EffectiveClockImproved = "Yes"
$utilizationPassParams.ThermalAcceptable = "Yes"
$utilizationPassParams.PowerAcceptable = "Yes"
$utilizationPassParams.Artifacts = "None"
$utilizationPass = Invoke-Suggestion $utilizationPassParams
Assert-True ($utilizationPass.Status -eq "DiagnoseFirst") "Utilization must override all-pass result evidence."
Assert-True ($reliabilityPass.SuggestedAction -ne "keep") "Reliability must not recommend keep."
Assert-True ($utilizationPass.SuggestedAction -ne "keep") "Utilization must not recommend keep."

$efficiencyPassParams = $adaParams.Clone()
$efficiencyPassParams.Goal = "Efficiency"
$efficiencyPassParams.DominantLimit = "Thermal"
$efficiencyPassParams.ThermalHeadroom = "Tight"
$efficiencyPassParams.CoreValidated = $true
$efficiencyPassParams.ResultVerdict = "pass"
$efficiencyPassParams.MaterialBenefit = "Yes"
$efficiencyPassParams.NoiseExceeded = "Yes"
$efficiencyPassParams.EffectiveClockImproved = "No"
$efficiencyPassParams.ThermalAcceptable = "Yes"
$efficiencyPassParams.PowerAcceptable = "Yes"
$efficiencyPassParams.Artifacts = "None"
$efficiencyPass = Invoke-Suggestion $efficiencyPassParams
Assert-True ($efficiencyPass.Status -eq "Keep") "Efficiency success must not require higher effective clock."

$efficiencyExploreParams = $adaParams.Clone()
$efficiencyExploreParams.Goal = "Efficiency"
$efficiencyExploreParams.DominantLimit = "Thermal"
$efficiencyExploreParams.ThermalHeadroom = "Tight"
$efficiencyExploreParams.TuningIntent = "explore-limit"
$efficiencyExplore = Invoke-Suggestion $efficiencyExploreParams
Assert-True ($efficiencyExplore.CandidateRole -eq "limit-exploration") "Explore-limit efficiency candidates must not be labelled usable-start."

$powerFailureParams = $adaParams.Clone()
$powerFailureParams.Goal = "Efficiency"
$powerFailureParams.DominantLimit = "Power"
$powerFailureParams.CurrentPowerLimitPct = 85
$powerFailureParams.ResultVerdict = "fail"
$powerFailureParams.Artifacts = "Observed"
$powerFailureParams.LastPassingPowerLimitPct = 90
$powerFailureParams.LastPassingControlKind = "Power"
$powerFailure = Invoke-Suggestion $powerFailureParams
Assert-True ($powerFailure.Status -eq "Revert") "A failed power round should revert."
Assert-True ($powerFailure.FallbackCandidate.Value -eq 90) "A power fallback should use the last passing power ceiling."

$exploreFailureParams = $exploreParams.Clone()
$exploreFailureParams.ResultVerdict = "fail"
$exploreFailureParams.Artifacts = "Observed"
$exploreFailureParams.LastPassingCandidateValue = "75"
$exploreFailureParams.LastPassingControlKind = "Core"
$exploreFailure = Invoke-Suggestion $exploreFailureParams
Assert-True ($exploreFailure.Status -eq "Revert") "A failed exploration step should revert."
Assert-True ($exploreFailure.FallbackCandidate.Value -eq 75) "An exploration failure should fall back to the last passing value."

$curveFailureParams = $adaParams.Clone()
$curveFailureParams.CoreControlKind = "Curve"
$curveFailureParams.CurrentCoreVoltageMv = 950
$curveFailureParams.CurrentCoreFrequencyMhz = 2700
$curveFailureParams.ResultVerdict = "fail"
$curveFailureParams.Artifacts = "Observed"
$curveFailureParams.ParentControlKind = "Curve"
$curveFailureParams.LastPassingControlKind = "Curve"
$curveFailureParams.LastPassingVoltageMv = 925
$curveFailureParams.LastPassingFrequencyMhz = 2650
$curveFailureParams.LastPassingPowerLimitPct = 95
$curveFailure = Invoke-Suggestion $curveFailureParams
Assert-True ($curveFailure.Status -eq "Revert") "A failed curve round should revert."
Assert-True ($curveFailure.FallbackCandidate.VoltageAnchorMv -eq 925) "A curve fallback must preserve the last passing voltage anchor."
Assert-True ($curveFailure.FallbackCandidate.FrequencyMhz -eq 2650) "A curve fallback must preserve the last passing frequency."
Assert-True ($curveFailure.FallbackCandidate.PowerLimitPct -eq 95) "A curve fallback must preserve the last passing power limit."

$laptopCurveParams = $adaParams.Clone()
$laptopCurveParams.FormFactor = "Laptop"
$laptopCurveParams.GpuModel = "NVIDIA GeForce RTX 4070 Laptop GPU"
$laptopCurveParams.BoardModel = "Example Laptop 16 / RTX 4070 board"
$laptopCurveParams.CoreControlKind = "Curve"
$laptopCurveParams.CurrentCoreVoltageMv = 900
$laptopCurveParams.CurrentCoreFrequencyMhz = 2000
$laptopCurve = Invoke-Suggestion $laptopCurveParams
Assert-True ($laptopCurve.CurveStart.CandidateFrequencyMhz -eq 2025) "A laptop curve start must be capped to +25 MHz."
Assert-True ($laptopCurve.ReferenceBoundary -match '^75 MHz') "A laptop curve boundary must be capped to +75 MHz."

$unknownCurveParams = $adaParams.Clone()
$unknownCurveParams.ThermalHeadroom = "Unknown"
$unknownCurveParams.CoreControlKind = "Curve"
$unknownCurveParams.CurrentCoreVoltageMv = 950
$unknownCurveParams.CurrentCoreFrequencyMhz = 2700
$unknownCurve = Invoke-Suggestion $unknownCurveParams
Assert-True ($unknownCurve.CurveStart.CandidateFrequencyMhz -eq 2725) "Unknown thermal headroom must cap a curve first step to +25 MHz."

$goalDifferenceParams = $adaParams.Clone()
$goalDifferenceParams.Goal = "Performance"
$goalDifference = Invoke-Suggestion $goalDifferenceParams
Assert-True ($goalDifference.ExperimentId -ne $ada.ExperimentId) "A different goal must produce a different ExperimentId."

$limitDifferenceParams = $adaParams.Clone()
$limitDifferenceParams.DominantLimit = "Voltage"
$limitDifference = Invoke-Suggestion $limitDifferenceParams
Assert-True ($limitDifference.ExperimentId -ne $ada.ExperimentId) "A different dominant limit must produce a different ExperimentId."

$controlDifferenceParams = $adaParams.Clone()
$controlDifferenceParams.CoreControlKind = "ClockTarget"
$controlDifferenceParams.BaselineCoreOffsetMhz = 2400
$controlDifferenceParams.CurrentCoreOffsetMhz = 2400
$controlDifference = Invoke-Suggestion $controlDifferenceParams
Assert-True ($controlDifference.ExperimentId -ne $ada.ExperimentId) "A different control kind must produce a different ExperimentId."

$laptopPowerBase = $base.Clone()
$laptopPowerBase.FormFactor = "Laptop"
$laptopPowerBase.GpuModel = "NVIDIA GeForce RTX 5070 Ti Laptop"
$laptopPowerBase.BoardModel = "Example 16-inch laptop / RTX 5070 Ti Laptop"
$laptopPowerBase.StockPowerLimitWatts = 130
$laptopPowerBase.CurrentPowerLimitWatts = 130

$assumedStock = Invoke-Suggestion $laptopPowerBase
Assert-True ($assumedStock.Status -eq "Ready") "A laptop with no unlock declaration should default to a usable candidate."
Assert-True ($assumedStock.PowerLimitModificationState -eq "assumed-stock") "An undeclared laptop power state should be assumed-stock."
Assert-True ($assumedStock.PowerLimitMode -eq "stock-assumed") "An assumed stock laptop should use stock-assumed mode."
Assert-True ($assumedStock.PowerLimitAssumptionNote -match 'correctable') "The stock assumption must be described as correctable."

$declaredStockParams = $laptopPowerBase.Clone()
$declaredStockParams.PowerLimitModificationState = "declared-stock"
$declaredStock = Invoke-Suggestion $declaredStockParams
Assert-True ($declaredStock.PowerLimitModificationState -eq "declared-stock") "A declared stock laptop should be recorded."
Assert-True ($declaredStock.PowerLimitMode -eq "stock-declared") "A declared stock laptop should use stock-declared mode."

$unlockedParams = $laptopPowerBase.Clone()
$unlockedParams.PowerLimitModificationState = "declared-unlocked"
$unlockedParams.CurrentPowerLimitWatts = 145
$unlocked = Invoke-Suggestion $unlockedParams
Assert-True ($unlocked.Status -eq "Ready") "A declared unlocked laptop should remain eligible with current watt evidence."
Assert-True ($unlocked.PowerLimitModificationState -eq "declared-unlocked") "The unlocked state must be preserved."
Assert-True ($unlocked.PowerLimitMode -eq "modified-declared") "An unlocked laptop should use modified-declared mode."
Assert-True ($unlocked.StockPowerLimitWatts -eq 130) "The stock watt limit must be preserved."
Assert-True ($unlocked.CurrentPowerLimitWatts -eq 145) "The current watt limit must be preserved."
Assert-True ($unlocked.PowerLimitEvidenceSource -eq "user-declared") "An explicit user unlock should be recorded as user-declared evidence."
Assert-True ($unlocked.CandidateDisplayedValue -eq $assumedStock.CandidateDisplayedValue) "Unlocking the power limit must not automatically increase the frequency step."
Assert-True ($unlocked.UsesCurrentPowerLimit -eq $true) "An unlocked laptop candidate must state that it depends on the current power limit."

$powerSemanticsParams = $laptopPowerBase.Clone()
$powerSemanticsParams.CurrentPowerLimitPct = 95
$powerSemanticsParams.MeasuredPowerWatts = 120
$powerSemanticsParams.Goal = "Efficiency"
$powerSemantics = Invoke-Suggestion $powerSemanticsParams
Assert-True ($powerSemantics.PowerLimitPercentMeaning -eq "ceiling-not-draw") "Power percentage must be labelled as a ceiling, not actual draw."
Assert-True ($powerSemantics.PowerLimitWattsMeaning -eq "configured-or-observed-limit-ceiling-not-draw") "Watt limits must be labelled as ceiling values."
Assert-True ($powerSemantics.MeasuredPowerWatts -eq 120) "Measured power draw must be preserved separately."
Assert-True ($powerSemantics.CurrentPowerLimitWatts -eq 130) "The configured watt ceiling must remain separate from measured draw."
Assert-True ($powerSemantics.CandidateDisplayedValue -eq 90) "The power candidate should adjust the ceiling percentage, not the measured draw."
Assert-True ($powerSemantics.Unit -eq "displayed power-limit ceiling percent") "Power candidate units must identify the ceiling semantics."
Assert-True ($powerSemantics.DeviceFingerprint -eq $assumedStock.DeviceFingerprint) "A measured draw change alone must not alter the static device fingerprint."

$unknownUnlockParams = $laptopPowerBase.Clone()
$unknownUnlockParams.PowerLimitModificationState = "Auto"
$unknownUnlock = Invoke-Suggestion $unknownUnlockParams
Assert-True ($unknownUnlock.PowerLimitModificationState -eq "assumed-stock") "An unknown unlock state should use assumed-stock."

$mismatchParams = $laptopPowerBase.Clone()
$mismatchParams.PowerLimitModificationState = "declared-stock"
$mismatchParams.CurrentPowerLimitWatts = 145
$mismatch = Invoke-Suggestion $mismatchParams
Assert-BlockedContract $mismatch "Declared stock laptop with current watt limit above stock"
Assert-True ($mismatch.PowerLimitModificationState -eq "detected-mismatch") "Conflicting laptop power evidence should be detected-mismatch."

Assert-True ($assumedStock.DeviceFingerprint -ne $unlocked.DeviceFingerprint) "A power-state change must invalidate the device fingerprint."
Assert-True ($assumedStock.ExperimentId -ne $unlocked.ExperimentId) "A power-state change must invalidate the ExperimentId."
Assert-True ($assumedStock.BaselineId -ne $unlocked.BaselineId) "A power-state change must invalidate the BaselineId."
Assert-True ($assumedStock.CandidateId -ne $unlocked.CandidateId) "A power-state change must invalidate the CandidateId."
Assert-True ($assumedStock.HardwareFingerprint -eq $unlocked.HardwareFingerprint) "A power-limit change must preserve the hardware fingerprint."
Assert-True ($assumedStock.ConfigurationFingerprint -ne $unlocked.ConfigurationFingerprint) "A power-limit change must create a new configuration fingerprint."
Assert-True ($assumedStock.ExperimentLineageId -eq $unlocked.ExperimentLineageId) "A power-limit revision must preserve the experiment lineage."
Assert-True ($assumedStock.HistoryPolicy -eq "preserve-and-mark-stale-for-continuation") "Historical evidence must be preserved rather than deleted."
Assert-True ($assumedStock.BaselineStatus -eq "current") "A new assumed-stock baseline should be current for that configuration."
Assert-True ($unlocked.CandidateStatus -eq "active") "A new unlocked candidate should be active for its revision."
Assert-True ($unlocked.FallbackCandidate.FallbackScope -eq "profile-only") "A fallback must state that it restores profile state only."
Assert-True ($unlocked.FallbackCandidate.MayRestoreExternalPowerModification -eq $false) "A profile fallback must not promise to undo external power modifications."

$differentBoardParams = $laptopPowerBase.Clone()
$differentBoardParams.BoardModel = "Another Brand 16 / RTX 5070 Ti Laptop"
$differentBoard = Invoke-Suggestion $differentBoardParams
Assert-True ($differentBoard.DeviceFingerprint -ne $assumedStock.DeviceFingerprint) "The same GPU on a different board must not share a fingerprint."
Assert-True ($differentBoard.HardwareFingerprint -ne $assumedStock.HardwareFingerprint) "A different board must change the hardware fingerprint."
Assert-True ($differentBoard.ExperimentLineageId -ne $assumedStock.ExperimentLineageId) "A different board must start a new experiment lineage."

$desktopPowerParams = $base.Clone()
$desktopPowerParams.GpuModel = "NVIDIA GeForce RTX 5090"
$desktopPower = Invoke-Suggestion $desktopPowerParams
Assert-True ($desktopPower.PowerLimitModificationState -eq "not-applicable") "Desktop cards must not enter the laptop power-limit state machine."
Assert-True ($desktopPower.PowerLimitMode -eq "desktop") "Desktop cards must keep the desktop power mode."
Assert-True ($null -eq $desktopPower.StockPowerLimitWatts) "A desktop request must not invent a laptop stock watt limit."

$firstRoundCoreCandidates = @(
    $core,
    $laptop,
    $unknownThermal,
    $ampere,
    $ampere3060,
    $ampere3060Ti,
    $ampere3070,
    $ampere3070Ti,
    $ampere3080Ti,
    $ampere3090,
    $ampere3090Ti,
    $ada,
    $ada4060,
    $ada4060Ti,
    $ada4070Super,
    $ada4070Ti,
    $ada4080,
    $ada4080Super,
    $ada4090,
    $blackwell,
    $blackwell5060,
    $blackwell5060Ti,
    $blackwell5080,
    $blackwell5090,
    $amdCore,
    $amdCoreActual,
    $assumedStock,
    $unlocked
)
foreach ($firstRoundCandidate in $firstRoundCoreCandidates) {
    Assert-True ($firstRoundCandidate.FollowupStep -eq "+25 MHz") "A first-round core candidate must return +25 MHz as FollowupStep, not its initial step."
}

if ($failures.Count -gt 0) {
    Write-Host "GPU automatic overclock tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "GPU automatic overclock tests: PASS" -ForegroundColor Green
