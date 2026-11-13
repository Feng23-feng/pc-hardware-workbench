[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$budgetWarnings = New-Object System.Collections.Generic.List[string]

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Pattern,
        [string]$Message
    )

    if ($Text -notmatch $Pattern) {
        $failures.Add($Message)
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Get-Utf8LfByteCount {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [IO.File]::ReadAllText(
        $Path,
        (New-Object System.Text.UTF8Encoding($false, $true))
    )
    $canonical = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    return [Text.Encoding]::UTF8.GetByteCount($canonical)
}

function Test-EntryBudgetException {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$SkillBytes,
        [Parameter(Mandatory = $true)][int]$HardLimit,
        [Parameter(Mandatory = $true)][datetimeoffset]$Now
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $maximumOverflowBytes = 256
    if ($SkillBytes -le $HardLimit) {
        $errors.Add("entry-budget-exception.json is stale while SKILL.md is within the hard maximum; remove it.") | Out-Null
        return [pscustomobject]@{
            Allowed = $false
            Errors = @($errors)
            Warning = $null
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $errors.Add("SKILL.md exceeds the hard maximum; add a valid tests/entry-budget-exception.json for a safety-only hotfix.") | Out-Null
        return [pscustomobject]@{
            Allowed = $false
            Errors = @($errors)
            Warning = $null
        }
    }
    $exceptionItem = Get-Item -LiteralPath $Path -Force
    if (($exceptionItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $errors.Add("entry-budget-exception.json cannot be a symbolic link, junction, or other reparse point.") | Out-Null
        return [pscustomobject]@{
            Allowed = $false
            Errors = @($errors)
            Warning = $null
        }
    }
    if ($exceptionItem.Length -gt 16384) {
        $errors.Add("entry-budget-exception.json cannot exceed 16 KiB.") | Out-Null
        return [pscustomobject]@{
            Allowed = $false
            Errors = @($errors)
            Warning = $null
        }
    }

    try {
        $exception = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $errors.Add("entry-budget-exception.json is not valid JSON: $($_.Exception.Message)") | Out-Null
        return [pscustomobject]@{
            Allowed = $false
            Errors = @($errors)
            Warning = $null
        }
    }

    $schemaVersion = 0
    if ($null -eq $exception.PSObject.Properties["schemaVersion"] -or
        -not [int]::TryParse([string]$exception.schemaVersion, [ref]$schemaVersion) -or
        $schemaVersion -ne 1) {
        $errors.Add("entry-budget-exception.json schemaVersion must be 1.") | Out-Null
    }
    if ([string]$exception.kind -ne "safety-hotfix") {
        $errors.Add("entry-budget-exception.json kind must be safety-hotfix.") | Out-Null
    }
    foreach ($fieldName in @("reason", "safetyImpact", "migrationPlan", "owner")) {
        $value = if ($null -eq $exception.PSObject.Properties[$fieldName]) {
            ""
        }
        else {
            [string]$exception.$fieldName
        }
        if ([string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt 500 -or
            $value -match '[\x00-\x1F\x7F]') {
            $errors.Add("entry-budget-exception.json field '$fieldName' must be 1-500 printable characters.") | Out-Null
        }
    }

    $createdAt = [datetimeoffset]::MinValue
    $expiresAt = [datetimeoffset]::MinValue
    $createdAtValid = $null -ne $exception.PSObject.Properties["createdAt"] -and
        [datetimeoffset]::TryParse(
            [string]$exception.createdAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$createdAt
        )
    $expiresAtValid = $null -ne $exception.PSObject.Properties["expiresAt"] -and
        [datetimeoffset]::TryParse(
            [string]$exception.expiresAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$expiresAt
        )
    if (-not $createdAtValid) {
        $errors.Add("entry-budget-exception.json createdAt must be an ISO 8601 timestamp.") | Out-Null
    }
    if (-not $expiresAtValid) {
        $errors.Add("entry-budget-exception.json expiresAt must be an ISO 8601 timestamp.") | Out-Null
    }
    if ($createdAtValid -and $expiresAtValid) {
        if ($createdAt -gt $Now.AddMinutes(5)) {
            $errors.Add("entry-budget-exception.json createdAt cannot be more than five minutes in the future.") | Out-Null
        }
        if ($expiresAt -le $Now) {
            $errors.Add("entry-budget-exception.json has expired.") | Out-Null
        }
        if ($expiresAt -le $createdAt -or $expiresAt -gt $createdAt.AddHours(72)) {
            $errors.Add("entry-budget-exception.json must expire within 72 hours after creation.") | Out-Null
        }
    }

    $maximumAllowedBytes = 0
    if ($null -eq $exception.PSObject.Properties["maxBytes"] -or
        -not [int]::TryParse([string]$exception.maxBytes, [ref]$maximumAllowedBytes)) {
        $errors.Add("entry-budget-exception.json maxBytes must be an integer.") | Out-Null
    }
    else {
        if ($maximumAllowedBytes -le $HardLimit) {
            $errors.Add("entry-budget-exception.json maxBytes must exceed the hard maximum.") | Out-Null
        }
        if ($maximumAllowedBytes -gt ($HardLimit + $maximumOverflowBytes)) {
            $errors.Add("entry-budget-exception.json maxBytes cannot exceed the hard maximum by more than 256 bytes.") | Out-Null
        }
        if ($SkillBytes -gt $maximumAllowedBytes) {
            $errors.Add("SKILL.md exceeds the exception maxBytes.") | Out-Null
        }
    }

    $allowed = $errors.Count -eq 0
    $warning = if ($allowed) {
        "Safety hotfix exception active: SKILL.md is $SkillBytes bytes; maximum $maximumAllowedBytes; expires $($expiresAt.ToString('o'))."
    }
    else {
        $null
    }
    return [pscustomobject]@{
        Allowed = $allowed
        Errors = @($errors)
        Warning = $warning
    }
}

function Read-RequiredFile {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [Console]::Error.WriteLine("Required path does not exist: $Label")
        exit 1
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        [Console]::Error.WriteLine("Required path is not a file: $Label")
        exit 1
    }

    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8)
}

$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$skillPath = Join-Path $resolvedRoot "SKILL.md"
$skill = Get-Content -LiteralPath $skillPath -Raw -Encoding UTF8
$referenceOnlyNotice = [regex]::Unescape('\u53C2\u6570\u4EC5\u4F9B\u53C2\u8003\uFF0C\u8BF7\u4EE5\u5B89\u5168\u4E3A\u7B2C\u4E00\u8981\u52A1\u3002')
$englishReferenceOnlyNotice = "For reference only - put safety first."

Assert-Contains $skill '(?m)^  version: "2\.7\.1"\r?$' "metadata.version should be 2.7.1."
Assert-Contains $skill 'r23 collector' "The Skill maintenance summary collector revision disagrees with the collector code."
Assert-Contains $skill 'while power-path\s+evidence is incomplete' "The Advice intensity route does not include incomplete power-path evidence."
Assert-Contains $skill 'hidden or\s+manufacturer-limited power' "The Advice intensity summary is narrower than the hidden or manufacturer-limited scope."
Assert-Contains $skill 'power, voltage, fan, or firmware control' "The Advice intensity summary omits one or more controlled object types."
Assert-Contains $skill 'For a bare invocation' "Bare-invocation introduction rule is missing."
Assert-Contains $skill 'entry-language\.md' "Bare-invocation language guidance is not linked."
Assert-Contains $skill 'ask for the objective in the current\s+language' "Bare-invocation language selection is missing."
Assert-Contains $skill 'For a concrete request, state\s+the route directly' "Task-bearing invocation skip rule is missing."
Assert-Contains $skill 'localize the response' "Reference examples do not have a universal localization rule."
Assert-Contains $skill 'Historical records are not current' "Historical values can still be relabeled as current measurements."
Assert-Contains $skill 'Do not ask.*still requires one question' "A do-not-ask instruction can bypass historical-value confirmation."
Assert-Contains $skill 'Just confirmed and unchanged' "Ambiguous historical values can still be promoted without confirmation."
Assert-Contains $skill 'Keep it user-reported, never measured' "User-confirmed current values can be mislabeled as measured."
Assert-Contains $skill 'claim-verification\.md' "Claim verification route is missing."
Assert-Contains $skill 'timed multi-phase plans.*Gantt' "Timed plans do not route to the Gantt view."
Assert-Contains $skill 'Use a private case' "Proactive hardware-case checkpoint rule is missing."
Assert-Contains $skill 'before large\s+evidence' "Large evidence can be read before a restart point is saved."
Assert-Contains $skill 'checkpoint material changes' "The Skill does not define event-driven case updates."
Assert-Contains $skill 'not every turn' "The case rule can turn into an indiscriminate chat transcript."
Assert-Contains $skill 'outside public\s+artifacts' "Case storage has no public-release boundary."
Assert-Contains $skill 'use `Resume` when reopening' "A resumed case can replay the old conversation instead of using the compact packet."
$hardwareCaseReference = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/hardware-case.md") `
    -Label "references/integration/hardware-case.md"
Assert-Contains $hardwareCaseReference 'Checkpoint at meaningful state changes' "The case reference has no checkpoint lifecycle."
Assert-Contains $hardwareCaseReference 'outside the installed Skill and any public\s+repository' "The case reference does not keep local data outside public artifacts."
Assert-Contains $hardwareCaseReference '-Action UpdateExperiment' "Completed experiment updates are not routed."
Assert-Contains $hardwareCaseReference '-Action Resume' "The compact resume command is not documented."
Assert-Contains $hardwareCaseReference 'New experiment metadata fields are optional' "New case fields lost their backward-compatibility contract."
$hardwareCaseScript = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/hardware-case.ps1") -Raw -Encoding UTF8
Assert-Contains $hardwareCaseScript '"UpdateExperiment"' "The case script has no experiment update action."
Assert-Contains $hardwareCaseScript '"Resume"' "The case script has no compact resume action."
Assert-Contains $hardwareCaseScript 'verified-after-reboot' "The case script cannot record reboot persistence without overstating it."
Assert-Contains $hardwareCaseScript '## Resume rule' "The resume action has no state-revalidation closure."
$neutralIntroduction = [regex]::Unescape('\u0060pc-hardware-workbench\u0060 \u5DF2\u52A0\u8F7D')
$codexIntroduction = [regex]::Unescape('\u0060$pc-hardware-workbench\u0060 \u5DF2\u52A0\u8F7D')
Assert-True (-not ($skill -match ("(?m)^> " + [regex]::Escape($codexIntroduction)))) "The spoken introduction still uses the Codex-only invocation sigil."
$entryLanguage = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/entry-language.md") `
    -Label "references/integration/entry-language.md"
Assert-Contains $entryLanguage ("(?m)^> " + [regex]::Escape($neutralIntroduction)) "The bare-invocation introduction lost its neutral skill name."
Assert-Contains $entryLanguage 'is loaded\. It can inspect the current configuration' "English bare-invocation introduction is missing."
Assert-Contains $entryLanguage 'Do not mix Chinese and English' "Entry-language reference permits mixed languages."
Assert-Contains $entryLanguage 'English when neither signal identifies a language' "Entry-language reference has no deterministic fallback."
Assert-Contains $entryLanguage 'Treat examples elsewhere in the Skill as semantic templates rather than\s+text to copy' "Reference examples can still be copied verbatim across languages."
Assert-Contains $skill 'Explain named choices' "Choice explanation rule is missing."
Assert-Contains $skill 'never ask a bare' "Bare named-choice prohibition is missing."
Assert-Contains $skill 'Plain-language parameter explanations' "Plain-language parameter rule is missing."
Assert-Contains $skill 'explanation-style\.md' "The detailed explanation-style reference is not linked."
Assert-Contains $skill 'Never give a\s+bare number, offset, timing, profile, or instruction without the notice and an\s+appropriately detailed explanation' "The bare-value rule lost its safety-notice binding."
Assert-Contains $skill ([regex]::Escape($referenceOnlyNotice)) "The mandatory reference-only safety notice is missing."
Assert-Contains $skill ([regex]::Escape($englishReferenceOnlyNotice)) "The English safety notice is missing."
Assert-Contains $skill 'Never mix the Chinese and English notices in one reply' "The language-mixing prohibition is missing."
Assert-Contains $skill 'BIOS/UEFI tuning setting' "BIOS/UEFI tuning settings are not covered by the parameter safety rule."
Assert-Contains $skill 'firmware, clock, voltage, power control' "Firmware and tuning controls are not covered by the parameter safety rule."
Assert-Contains $skill 'nontechnical symptom' "Beginner routing is missing."
Assert-Contains $skill 'beginner-guide\.md' "Beginner guide link is missing."
Assert-True ($skill -notmatch '\[\u8BBE\u5907\uFF1A') "The workflow-state example was reintroduced into the entrypoint."
Assert-Contains $skill 'Hard-stop precedence' "Physical-danger precedence is missing."
Assert-Contains $skill 'burning smell' "Hard-stop examples are missing."
Assert-True ($skill -notmatch '3/5') "The five-item gate is still presented through a stage-line example."
Assert-Contains $skill 'de-energized' "The de-energized hardware handling rule is missing."
Assert-True ($skill -notmatch 'CPU cooling type, GPU original-cooler') "The main route still asks both CPU and GPU cooling unconditionally."
Assert-Contains $skill 'preference, aesthetic, collection' "The purchase route still treats every purchase as a performance repair."
Assert-Contains $skill 'tuning entry gate' "Mandatory tuning entry gate is missing."
Assert-Contains $skill 'does\s+not waive the gate' "The direct-request bypass prohibition is missing."
Assert-Contains $skill 'coaching branch, not a dead end' "Missing-gate coaching behavior is missing."
Assert-Contains $skill 'collector-workflow\.md' "Collector workflow route is missing."
Assert-Contains $skill 'cross-mode-handoffs\.md' "Cross-mode handoff reference is not linked from the entrypoint."
Assert-Contains $skill '### Telemetry and logs' "Telemetry has no formal shared subflow."
Assert-Contains $skill 'does not require the\s+tuning entry gate' "Telemetry-only analysis is still forced through tuning intake."
Assert-Contains $skill 'collector is Windows-only' "Automatic collector scope is not limited to Windows."
Assert-Contains $skill 'cooling-evidence\.md' "Cooling evidence route is missing."
Assert-Contains $skill 'gpu-clock-behavior\.md' "GPU dynamic clock behavior reference is not linked from the entrypoint."
Assert-Contains $skill 'vram-and-memory-bus\.md' "The entrypoint does not route VRAM mechanism questions."
Assert-Contains $skill 'gpu-memory-playbook\.md' "The entrypoint does not route VRAM tuning."
Assert-Contains $skill 'tuning-modes\.md' "Quick/deep tuning route is missing."
Assert-Contains $skill 'fixed-workloads\.md' "Fixed workload route is missing."
Assert-Contains $skill 'telemetry-analysis\.md' "Telemetry analysis route is missing."
Assert-Contains $skill 'presentmon-frame-time\.md' "PresentMon frame-time route is missing."
Assert-Contains $skill 'analyze-presentmon\.ps1' "PresentMon analyzer is not routed from the Skill."
Assert-Contains $skill 'success-and-sensor-semantics\.md' "Success/sensor route is missing."
Assert-Contains $skill 'persistence-and-update-gate\.md' "Persistence/update route is missing."
Assert-Contains $skill 'installation-coexistence\.md' "Installation coexistence route is missing."
Assert-Contains $skill 'device-identity\.md' "Unreadable device identity route is missing."

foreach ($relative in @(
    "references/integration/collector-workflow.md",
    "references/integration/cooling-evidence.md",
    "references/integration/beginner-guide.md",
    "references/integration/interaction-closure.md",
    "references/integration/cross-mode-handoffs.md",
    "references/integration/tuning-modes.md",
    "references/integration/fixed-workloads.md",
    "references/integration/telemetry-analysis.md",
    "references/integration/presentmon-frame-time.md",
    "references/integration/success-and-sensor-semantics.md",
    "references/integration/persistence-and-update-gate.md",
    "references/integration/installation-coexistence.md",
    "references/integration/device-identity.md",
    "references/integration/claim-verification.md",
    "references/tuning/expectation-direction.md",
    "references/tuning/gpu-clock-behavior.md",
    "references/tuning/gpu-curve-baseline.md",
    "references/tuning/intel-13-14-gen.md",
    "references/upgrade/upgrade-evidence.md",
    "references/upgrade/output-format.md",
    "scripts/collect-windows.ps1",
    "scripts/device-identity.ps1",
    "scripts/inventory-context.ps1",
    "scripts/local-path-safety.ps1",
    "scripts/system-native.cs",
    "scripts/storage-native.cs",
    "scripts/display-native.cs",
    "tests/run-device-identity-tests.ps1",
    "tests/run-collector-smoke-tests.ps1",
    "tests/run-all-tests.ps1",
    "tests/run-pwsh7-parse-tests.ps1",
    "tests/manual-acceptance-template.md",
    "scripts/analyze-telemetry.ps1",
    "scripts/render-telemetry-chart.ps1",
    "scripts/render-gantt-chart.ps1",
    "scripts/analyze-presentmon.ps1",
    "scripts/verify-hardware-claim.ps1",
    "tests/run-claim-verification-tests.ps1",
    "tests/run-presentmon-analysis-tests.ps1"
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedRoot $relative) -PathType Leaf)) {
        $failures.Add("Missing required file: $relative")
    }
}

$tuningModes = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/tuning-modes.md") -Raw -Encoding UTF8
Assert-Contains $tuningModes 'Quick mode is less detailed, not less safe' "Quick mode safety-floor statement is missing."
Assert-Contains $tuningModes 'daily-validated' "Quick/deep validation boundary is missing."
Assert-Contains $tuningModes 'may skip the entry gate' "Quick-mode entry-gate prohibition is missing."
Assert-Contains $tuningModes 'Tuning has one entry' "Tuning depth is incorrectly presented as separate top-level modes."
Assert-Contains $tuningModes 'Apply the safety notice from SKILL\.md only when the response contains a candidate setting or an actionable user-applied change' "Tuning modes do not apply the safety notice at the action trigger."
Assert-Contains $tuningModes 'adapt explanation depth to user skill and risk' "Tuning modes omit context-adaptive explanations."
Assert-Contains $tuningModes 'do not ask a beginner to fill a blank experiment template' "Quick mode still forces a blank template."
Assert-Contains $tuningModes 'Vendor-profile fast path' "Vendor-profile fast path is missing."
Assert-Contains $tuningModes 'without a stock workload result' "XMP/EXPO can be enabled without a stock workload baseline."
Assert-Contains $tuningModes 'Cooling context is collected only after inventory' "Cooling timing rule is missing."
Assert-Contains $tuningModes 'fast path is inside the normal tuning gate, not a bypass' "XMP/EXPO fast path is described as a gate bypass."
Assert-True ($tuningModes -notmatch 'CPU cooling type, whether the GPU') "Tuning modes still ask both cooling groups unconditionally."

$intake = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/intake.md") -Raw -Encoding UTF8
Assert-Contains $intake 'Universal tuning entry gate' "The reusable tuning gate is missing."
Assert-Contains $intake 'five items are known' "The tuning gate does not require all five inputs."
Assert-Contains $intake 'Guided remediation for a missing gate item' "The guided gate-remediation reference is missing."
Assert-Contains $intake 'Evidence ownership' "Tuning intake has no evidence-ownership rule."
Assert-Contains $intake 'Instrument first' "Tuning intake does not prefer instrumented evidence."
Assert-Contains $intake 'Keep one decision per turn' "Tuning intake can turn the gate into a questionnaire."
Assert-Contains $intake 'block only the step that depends on it' "Tuning intake blocks the whole route on one missing user-only item."
Assert-Contains $intake 'GPU memory question tiers' "GPU memory advice has no tiered interpretation model."
Assert-Contains $intake 'VRAM type' "GPU memory advice does not require the installed VRAM type."
Assert-Contains $intake 'Concept explanation' "GPU memory advice cannot explain concepts without a tuning gate."
Assert-Contains $intake 'Official theoretical bandwidth' "GPU memory advice cannot answer source-backed theoretical bandwidth."
Assert-Contains $intake 'Local sensor interpretation' "GPU memory advice has no local-reading tier."
Assert-Contains $intake 'Never infer bandwidth from clock alone' "GPU memory advice can infer bandwidth from a clock alone."

$experimentLoop = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/experiment-loop.md") -Raw -Encoding UTF8
Assert-Contains $experimentLoop 'Decision and optional learning review' "The optional tuning learning-review step is missing."
Assert-Contains $experimentLoop 'prior card clearly belongs to the same device' "The prior-card reuse rule is missing."
Assert-Contains $experimentLoop 'status: reviewed' "The experiment loop does not persist review status."

$interactionClosure = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/interaction-closure.md") -Raw -Encoding UTF8
Assert-Contains $interactionClosure 'Session context' "Interaction closure has no current-session context."

$expectation = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/expectation-direction.md") -Raw -Encoding UTF8
Assert-Contains $expectation 'Required expectation card' "The configuration-based expectation card is missing."
Assert-Contains $expectation 'Do not promise an expected percentage gain' "Expectation guidance allows invented percentage gains."
Assert-Contains $expectation 'Optional online calibration' "Expectation guidance has no optional online calibration route."
Assert-Contains $expectation 'Do not copy another user' "Expectation guidance lacks the no-copy boundary."
Assert-True ($expectation -notmatch 'relevant CPU/GPU cooler') "Expectation guidance still asks for unrelated cooling information."

$gpuCurve = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/gpu-curve-baseline.md") -Raw -Encoding UTF8
Assert-Contains $gpuCurve 'Required baseline report' "GPU curve guidance has no mandatory baseline report."
Assert-Contains $gpuCurve 'Compact route' "GPU curve guidance has no compact overall route."
Assert-Contains $gpuCurve 'Tune the core voltage/frequency curve first' "GPU compact route does not start with core curve tuning."
Assert-Contains $gpuCurve 'test memory as a separate round' "GPU compact route does not separate memory tuning."
Assert-Contains $gpuCurve 'Repeat each retained profile at least twice' "GPU compact route does not require repeated validation."
Assert-Contains $gpuCurve 'Keep only the winning daily profile and a separate benchmark profile' "GPU compact route does not separate daily and benchmark profiles."
Assert-Contains $gpuCurve 'representative in-workload core-voltage' "GPU curve guidance does not require a representative voltage region."
$gpuClock = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/gpu-clock-behavior.md") -Raw -Encoding UTF8
Assert-Contains $gpuClock 'GPU Boost' "GPU clock guidance omits the NVIDIA GPU Boost term."
Assert-Contains $gpuClock 'Turing / RTX 20' "GPU clock guidance omits Turing."
Assert-Contains $gpuClock 'Ampere / RTX 30' "GPU clock guidance omits Ampere."
Assert-Contains $gpuClock 'Ada / RTX 40' "GPU clock guidance omits Ada."
Assert-Contains $gpuClock 'Blackwell / RTX 50' "GPU clock guidance omits Blackwell."
Assert-Contains $gpuClock 'Accelerated Frequency Switching' "GPU clock guidance omits the Blackwell-specific terminology."
Assert-Contains $gpuClock 'Game Frequency' "GPU clock guidance omits AMD Game Frequency."
Assert-Contains $gpuClock 'RDNA1 / RX 5000' "GPU clock guidance omits RDNA1."
Assert-Contains $gpuClock 'RDNA2 / RX 6000' "GPU clock guidance omits RDNA2."
Assert-Contains $gpuClock 'RDNA3 / RX 7000' "GPU clock guidance omits RDNA3."
Assert-Contains $gpuClock 'RDNA4 / RX 9000' "GPU clock guidance omits RDNA4."
Assert-Contains $gpuClock 'Radeon Boost is not core-clock boost' "GPU clock guidance confuses Radeon Boost with core-clock boost."
Assert-Contains $gpuClock 'GuC SLPC' "GPU clock guidance omits Intel Xe frequency management."
Assert-Contains $gpuClock 'Alchemist' "GPU clock guidance omits Intel Arc A-series."
Assert-Contains $gpuClock 'Battlemage' "GPU clock guidance omits Intel Arc B-series."
Assert-Contains $gpuClock 'absence of one intended point does \*\*not\*\* prove' "GPU clock guidance can still reject a curve solely because one point is absent."
Assert-Contains $gpuClock 'presence of one intended point also does not prove' "GPU clock guidance can still treat one observed sample as proof."
Assert-Contains $gpuClock 'operating-point distribution' "GPU clock guidance does not use the observed operating distribution."
Assert-Contains $gpuClock 'GPU memory clock.*source-dependent' "GPU clock guidance does not qualify memory-clock meaning."
Assert-Contains $gpuClock 'Memory bandwidth.*not a sensor' "GPU clock guidance can mistake bandwidth for a sensor."
Assert-Contains $gpuClock 'vram-and-memory-bus\.md' "GPU clock guidance does not link the VRAM mechanism reference."
Assert-Contains $gpuCurve 'gpu-clock-behavior\.md' "GPU curve guidance does not link the dynamic clock behavior reference."
$gpuAutoCandidates = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/gpu-auto-candidates.md") `
    -Label "references/tuning/gpu-auto-candidates.md"
$gpuFamilyPlaybooks = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/gpu-family-playbooks.md") `
    -Label "references/tuning/gpu-family-playbooks.md"
$usableStartState = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/usable-start-and-state.md") `
    -Label "references/tuning/usable-start-and-state.md"
$laptopPowerState = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/laptop-power-state.md") `
    -Label "references/tuning/laptop-power-state.md"
$gpuTierPath = Join-Path $resolvedRoot "references/tuning/gpu-auto-oc-tier-authority.json"
$gpuTier = Get-Content -LiteralPath $gpuTierPath -Raw -Encoding UTF8 | ConvertFrom-Json
$componentPlaybooks = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/component-playbooks.md") `
    -Label "references/tuning/component-playbooks.md"
$beginnerGpu = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/beginner-gpu-auto-oc.md") `
    -Label "references/tuning/beginner-gpu-auto-oc.md"
$fixedWorkloads = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/fixed-workloads.md") `
    -Label "references/integration/fixed-workloads.md"
$beginnerGuide = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/beginner-guide.md") `
    -Label "references/integration/beginner-guide.md"
Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/beginner-gpu-auto-oc.md") `
    -Label "references/tuning/beginner-gpu-auto-oc.md" | Out-Null
Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/rtx-30-series-public-reference.md") `
    -Label "references/tuning/rtx-30-series-public-reference.md" | Out-Null
Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/rtx-40-series-public-reference.md") `
    -Label "references/tuning/rtx-40-series-public-reference.md" | Out-Null
Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/rtx-50-series-public-reference.md") `
    -Label "references/tuning/rtx-50-series-public-reference.md" | Out-Null
Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/suggest-gpu-overclock.ps1") `
    -Label "scripts/suggest-gpu-overclock.ps1" | Out-Null
Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "tests/run-gpu-auto-oc-tests.ps1") `
    -Label "tests/run-gpu-auto-oc-tests.ps1" | Out-Null
Assert-Contains $skill 'suggest-gpu-overclock\.ps1' "The Tune route does not invoke the integrated GPU candidate helper."
Assert-Contains $skill 'multi-adapter identities receive no\s+numeric candidate' "The GPU route permits an ambiguous multi-adapter candidate."
Assert-Contains $gpuAutoCandidates 'sole\s+normative source' "GPU candidate values do not have one normative authority."
Assert-Contains $gpuAutoCandidates 'never replaces local evidence' "GPU family priors can replace local evidence."
Assert-True ($gpuAutoCandidates -notmatch '(?i)prototype') "Integrated GPU candidate guidance still calls itself a prototype."
Assert-True ($gpuFamilyPlaybooks -notmatch '(?i)prototype') "Integrated GPU family guidance still calls itself a prototype."
Assert-Contains $gpuAutoCandidates 'Empty, unresolved, or generation-unknown models receive no numeric' "GPU candidate guidance still permits a generic numeric fallback."
Assert-Contains $gpuFamilyPlaybooks 'does not replace the exact\s+readable model' "GPU family guidance permits confirmation to replace a missing model."
Assert-Contains $usableStartState 'FallbackCandidate' "Usable-start experiments have no fallback candidate."
Assert-Contains $usableStartState 'session-only' "GPU candidate state is presented as persistent without a store."
Assert-True ($usableStartState -notmatch '(?i)prototype') "Usable-start guidance still calls itself a prototype."
Assert-Contains $usableStartState 'not a daily-stability claim' "A first-round candidate can still be mistaken for a daily-stability claim."
Assert-Contains $beginnerGpu 'selected variable may be a core offset/clock target' "Beginner guidance does not state which one variable can change."
Assert-Contains $beginnerGpu 'compact card takes precedence' "Beginner compact-card precedence over the full template is missing."
Assert-True ($beginnerGpu -notmatch 'Keep memory, voltage, power ceiling') "Beginner guidance still claims the first round preserves voltage and power unconditionally."
Assert-Contains $fixedWorkloads 'This full template is a data\s+checklist, not a form to dump on a novice' "The full workload card can still be dumped on a novice."
Assert-Contains $beginnerGuide 'do not print this whole list' "A novice can still receive the entire HWiNFO fallback list in one turn."
Assert-Contains $skill 'Concept-only\s+questions' "Concept-only questions are still forced through the tuning gate."
Assert-Contains $skill 'nontechnical symptom' "Plain-language symptom requests do not trigger the beginner route."
Assert-Contains $laptopPowerState 'power-limit ceiling[\s\S]+not the GPU[\s\S]+power draw' "Laptop power limits are not separated from measured draw."
Assert-Contains $laptopPowerState 'assumed-stock' "An undeclared laptop power state lacks a correctable default."
Assert-True ($gpuTier.PriorRuleVersion -eq "2.7.0") "GPU tier authority has the wrong integrated rule version."
Assert-True ($gpuTier.Profiles.'NVIDIA-Ada-Mainstream'.CoreStartDesktop -gt 0) "GPU tier authority has no NVIDIA Ada mainstream profile."
Assert-True ($gpuTier.Profiles.'AMD-RDNA3'.CoreStartDesktop -gt 0) "GPU tier authority has no AMD RDNA3 profile."
Assert-True ($gpuTier.Profiles.'Intel-Battlemage'.CoreStartDesktop -gt 0) "GPU tier authority has no Intel Battlemage profile."
Assert-Contains $componentPlaybooks 'vram-and-memory-bus\.md' "GPU candidate integration removed the current VRAM mechanism gate."
Assert-Contains $componentPlaybooks 'gpu-memory-playbook\.md' "GPU candidate integration removed the current VRAM tuning gate."
Assert-Contains $gpuCurve 'do not require the exact MHz value\s+to recur' "GPU curve guidance still requires the exact target point."
Assert-Contains $gpuCurve 'Do not say the curve failed solely because one intended\s+voltage/MHz coordinate never appeared' "GPU curve guidance can still infer curve failure from an absent point."
Assert-Contains $gpuCurve 'Pure frequency overclock' "GPU guidance does not separate pure frequency overclocking."
Assert-Contains $gpuCurve 'Curve undervolt and lift' "GPU guidance has no curve undervolt/overclock route."
Assert-Contains $gpuCurve 'Flatten the points to the right' "GPU curve guidance omits the right-side curve flattening step."
Assert-Contains $gpuCurve 'If raising lower-voltage points to the left' "GPU curve guidance omits the lower-voltage risk."
Assert-Contains $gpuCurve 'Desktop RTX 5090 reference route' "Desktop RTX 5090 reference route is missing."
Assert-Contains $gpuCurve 'Desktop bounded mid-voltage curve lift' "The reusable desktop segment route is missing."
Assert-Contains $gpuCurve 'available for desktop GPUs, but not for laptops' "The desktop-only boundary for the segment route is missing."
Assert-Contains $gpuCurve 'Set the power limit to 93%' "RTX 5090 reduced-power route is missing."
Assert-Contains $gpuCurve 'Raise the whole core curve by \+150 MHz' "RTX 5090 whole-curve starting reference is missing."
Assert-Contains $gpuCurve 'Flatten every point above 1\.025 V' "RTX 5090 upper-voltage flattening rule is missing."
Assert-Contains $gpuCurve 'Leave the curve below 0\.8 V unchanged' "RTX 5090 idle-region protection is missing."
Assert-Contains $gpuCurve 'Lift only the 0\.8-1\.025 V segment' "RTX 5090 mid-voltage segment reference is missing."
Assert-Contains $gpuCurve '\+/-15 MHz or' "RTX 5090 small-step reference is missing."
Assert-Contains $gpuCurve '\+/-50 MHz' "RTX 5090 larger small-step reference is missing."
Assert-Contains $gpuCurve 'Do not offer this bounded mid-voltage route to a laptop user' "Laptop exclusion for the segment route is missing."
Assert-Contains $gpuCurve 'Do not recommend a large VRAM overclock on a laptop' "Laptop VRAM overclock boundary is missing."
Assert-Contains $gpuCurve 'dominant performance-limit reason' "GPU baseline omits the performance-limit reason."
Assert-Contains $gpuCurve 'compare requested values' "GPU curve guidance does not verify applied values after smoothing."
Assert-Contains $gpuCurve 'A lower power limit is a candidate direction' "GPU guidance omits the conditional lower-power-limit direction."
Assert-Contains $gpuCurve 'higher requested memory\s+clock is not proof' "GPU memory guidance lacks the performance-versus-error warning."
Assert-Contains $gpuCurve 'Validation layers' "GPU validation layers are missing."
Assert-Contains $gpuCurve 'Recovery sequence' "GPU recovery sequence is missing."
Assert-Contains $gpuCurve 'Desktop raised power ceiling' "Desktop power-ceiling guidance is missing."
Assert-Contains $gpuCurve 'not RTX 4090 or RTX 5090' "Flagship desktop GPUs are incorrectly included in the ordinary max-ceiling route."
Assert-Contains $gpuCurve 'exact PSU model, wattage, age' "Power-ceiling eligibility does not verify the PSU."
Assert-Contains $gpuCurve 'slider value such as\s+111% is a vendor-tool reference' "111% is treated as a universal target."
Assert-Contains $gpuCurve 'Do not offer this route for a laptop' "Laptop power-ceiling exclusion is missing."
Assert-Contains $gpuCurve 'do\s+not use third-party or modified tools' "Hidden laptop power-limit bypass remains allowed."
Assert-Contains $gpuCurve 'Treat the higher power ceiling as blocked' "PSU/power-ceiling blocking conditions are missing."
Assert-Contains $gpuCurve 'Do not ask an ordinary user to perform mains-side transient measurements' "PSU guidance requires unsafe user measurements."
Assert-Contains $gpuCurve 'localized safety notice defined in SKILL\.md' "GPU curve guidance hard-codes the safety notice language."

$intelCaution = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/intel-13-14-gen.md") -Raw -Encoding UTF8
Assert-Contains $intelCaution 'retail boxed or tray/OEM' "Intel 13/14 boxed-versus-tray intake is missing."
Assert-Contains $intelCaution 'documented desktop high-power stability' "Intel 13/14 degradation warning is missing."
Assert-Contains $intelCaution 'fixed-voltage/fixed-frequency' "Intel 13/14 supported tuning route is missing."
Assert-Contains $intelCaution 'Do not expose hidden firmware controls' "Intel guidance allows hidden firmware bypasses."
Assert-Contains $intelCaution 'localized safety notice defined in SKILL\.md' "Intel guidance hard-codes the safety notice language."

$onlineEvidence = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/online-evidence.md") -Raw -Encoding UTF8
Assert-Contains $onlineEvidence 'Similarity levels' "Online evidence has no similar-platform classification."
Assert-Contains $onlineEvidence 'useful similar platform' "Useful similar platforms are not included as evidence."

$upgradeEvidence = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/upgrade/upgrade-evidence.md") -Raw -Encoding UTF8
Assert-Contains $upgradeEvidence 'Upgrade evidence pack' "Upgrade evidence pack is missing."
Assert-Contains $upgradeEvidence 'Decision order' "Upgrade evidence pack has no decision order."
Assert-Contains $upgradeEvidence 'Preparation report for preference or planning' "Preference purchases have no matching evidence template."

$recommendationOutput = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/upgrade/output-format.md") -Raw -Encoding UTF8
Assert-Contains $recommendationOutput 'Functional performance or capability assessment' "The functional recommendation template is missing."
Assert-Contains $recommendationOutput 'five-line summary' "Inventory output has no novice summary layer."
Assert-Contains $recommendationOutput 'secondary detail layer' "Inventory audit fields are not separated from the first screen."
Assert-Contains $recommendationOutput 'Preference, gift, or future-project assessment' "Preference purchases have no matching output template."
Assert-Contains $recommendationOutput "Buy / Wait / Don't buy" "Preference purchases still lack Buy, Wait, and Don't buy verdicts."
Assert-Contains $recommendationOutput 'Do not force\s+a\s+performance template' "The output guidance still forces every purchase into a performance template."
Assert-Contains $recommendationOutput 'Controller0-ChannelA-DIMM1' "The redaction contract does not preserve structural memory slot evidence."
Assert-Contains $recommendationOutput 'Generic PnP Monitor' "The redaction contract does not preserve generic display placeholders."

$recordTemplate = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/record-template.md") -Raw -Encoding UTF8
Assert-Contains $recordTemplate 'Learning review \(optional\)' "The reusable tuning record has no optional learning review."

$tools = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/tools.md") -Raw -Encoding UTF8
Assert-Contains $tools 'Local \(U\.S\.\)' "The primary HWiNFO download choice is missing."
Assert-Contains $tools 'dAppCDN \(Fast CDN\)' "The official-page CDN fallback is missing."
Assert-Contains $tools 'SAC ftp \(SK\)' "The final HWiNFO mirror fallback is missing."
$localChoiceIndex = $tools.IndexOf("1. **Local (U.S.)**")
$sacChoiceIndex = $tools.IndexOf("2. **SAC ftp (SK)**")
$cdnChoiceIndex = $tools.IndexOf("3. **dAppCDN (Fast CDN)**")
Assert-True (
    $localChoiceIndex -ge 0 -and
    $sacChoiceIndex -gt $localChoiceIndex -and
    $cdnChoiceIndex -gt $sacChoiceIndex
) "HWiNFO download choices are not ordered Local, SAC, then dAppCDN."

$collectorWorkflow = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/collector-workflow.md") -Raw -Encoding UTF8
Assert-Contains $collectorWorkflow 'Resume the calling flow' "Collector has no calling-flow handoff."
Assert-Contains $collectorWorkflow 'reuse a current-session snapshot' "Collector workflow does not prefer existing snapshots."
Assert-Contains $collectorWorkflow 'If several reports are available' "Collector workflow does not handle multiple reports."
Assert-Contains $collectorWorkflow 'recently changed the CPU, GPU, memory' "Collector workflow does not remind users about recent hardware changes."
Assert-True ($collectorWorkflow -notmatch 'CPU cooling type, whether the GPU') "Collector workflow still asks both cooling groups unconditionally."

Assert-Contains $skill 'Default: refuse\.' "Advice tiering has no default-refusal rule."
Assert-Contains $skill 'Downgrade only under' "Advice tiering has no downgrade gate."
Assert-Contains $skill 'Never downgrade: anti-cheat evasion' "Advice tiering does not hard-stop anti-cheat or concealment cases."
$quickModePosition = $skill.IndexOf('After the target and form factor are known')
$advicePosition = $skill.IndexOf('## Advice intensity')
$purchasePosition = $skill.IndexOf('### Purchase')
Assert-True (
    $quickModePosition -ge 0 -and
    $quickModePosition -lt $purchasePosition -and
    $purchasePosition -lt $advicePosition
) "Advice intensity still splits the Tune route."
$tunePosition = $skill.IndexOf('### Tune')
$tuneSection = $skill.Substring($tunePosition, $purchasePosition - $tunePosition)
Assert-True ($tuneSection -notmatch '(?m)^##\s') "A level-2 heading still splits the Tune section."

$adviceIntensity = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/tuning/advice-intensity.md") `
    -Label "references/tuning/advice-intensity.md"
Assert-Contains $adviceIntensity 'Assessment downgrade' "Advice intensity has no assessment tier."
Assert-Contains $adviceIntensity 'all three conditions hold' "Advice intensity has no three-condition downgrade gate."
Assert-Contains $adviceIntensity 'Do not provide a tool name, step sequence, target value' "Advice tiering allows instructional detail after downgrade."
Assert-Contains $adviceIntensity 'self-description' "Advice intensity can confuse self-reported expertise with evidence."
Assert-Contains $adviceIntensity 'does\s+not\s+authorize\s+instructions or\s+endorsement' "Advice assessment is treated as endorsement."
Assert-Contains $adviceIntensity 'Tool naming boundary' "Advice intensity has no monitoring/negative-capability tool boundary."
Assert-Contains $adviceIntensity 'Naming a monitoring tool' "Advice intensity cannot name safe monitoring tools for assessment."
Assert-Contains $adviceIntensity 'Which tier applies' "Advice intensity does not pin the request type to a tier."
Assert-Contains $adviceIntensity 'default refusal; name the missing evidence and stop' "Advice intensity lets a partly evidenced raise plan drift into the assessment tier."
Assert-Contains $adviceIntensity 'does not move an instruction request into the assessment tier' "Advice intensity lets an evidence request convert an instruction into an assessment."
Assert-Contains $adviceIntensity 'one harmless next step' "A default refusal does not return one harmless next step."
Assert-True (-not ($adviceIntensity -match 'non-offensive')) "The obsolete non-offensive wording has returned."
Assert-Contains $adviceIntensity 'this reference does not apply' "A supported exposed limit is not separated from the hidden-limit refusal path."
Assert-Contains $adviceIntensity 'default refusal; name the missing power-path evidence' "An incomplete power path can fall through to ordinary gate remediation."
Assert-Contains $adviceIntensity 'normal tuning-gate remediation for a non-power-path fact' "A non-power-path gate fact does not receive ordinary gate remediation."
Assert-Contains $adviceIntensity 'the power-path row wins over the other-fact row' "The power-path precedence rule is missing."
Assert-True (-not ($adviceIntensity -match 'Raise the ceiling to the maximum|vendor supports 111%')) "A scenario-specific power-limit example was reintroduced."
Assert-Contains $adviceIntensity 'power-path evidence is incomplete' "Advice intensity omits the unified incomplete power-path terminology."
Assert-Contains $intake 'its one-next-step rule is the operative limit' "Intake does not make the safety-stop next-step limit explicit."
Assert-Contains $adviceIntensity 'replaces, rather than adds to, the ordinary one-decision-per-turn budget' "Advice intensity adds the next-step request to the ordinary decision budget."
Assert-Contains $intake 'Never accept a remembered reading' "Intake lacks the remembered-reading counterexample."
Assert-Contains $intake 'Never deliver the five gate items as one questionnaire' "Intake lacks the questionnaire counterexample."
Assert-Contains $intake 'Never stop the whole tuning route' "Intake lacks the whole-route blocking counterexample."

$explanationStyle = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/explanation-style.md") `
    -Label "references/integration/explanation-style.md"
Assert-Contains $explanationStyle 'what changes, where it changes, and what remains unchanged' "Explanation reference does not define Action."
Assert-Contains $explanationStyle 'User-facing language layer' "Explanation reference has no shared user-language layer."
Assert-Contains $explanationStyle 'baseline \| \u539F\u914D\u7F6E' "Explanation reference does not translate baseline plainly."
Assert-Contains $explanationStyle 'fixed workload \| \u540C\u4E00\u4E2A\u6E38\u620F\u573A\u666F' "Explanation reference does not translate fixed workload plainly."
Assert-Contains $explanationStyle 'internal JSON fields' "Explanation reference permits internal field-name dumping."
Assert-Contains $explanationStyle 'At the start of a substantial tuning or telemetry flow' "The one-time detailed-mode offer is missing."
Assert-Contains $explanationStyle 'Start with the concise version' "The detailed-mode offer has no English template."
Assert-Contains $explanationStyle 'Other language: an equivalent offer in that language' "The detailed-mode offer is not language-aware."
Assert-Contains $explanationStyle 'one everyday comparison' "Explanation reference does not define Analogy."
Assert-Contains $explanationStyle 'signals that mean\s+stop, and how to recover' "Explanation reference does not define Consequence."
Assert-Contains $explanationStyle '## Action' "Explanation reference lacks the Action section."
Assert-Contains $explanationStyle '## Analogy' "Explanation reference lacks the Analogy section."
Assert-Contains $explanationStyle '## Consequence' "Explanation reference lacks the Consequence section."
Assert-Contains $explanationStyle 'exact visible menu or control label' "BIOS/UEFI guidance can invent an unverified menu path."
Assert-Contains $explanationStyle 'For beginners[\s\S]+For experienced users' "Explanation detail is not context-adaptive."
$beginnerGuide = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/beginner-guide.md") `
    -Label "references/integration/beginner-guide.md"
Assert-Contains $beginnerGuide 'semantic example to translate' "Beginner menu examples can still be copied without localization."
$tuningModes = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/tuning-modes.md") `
    -Label "references/integration/tuning-modes.md"
Assert-Contains $tuningModes 'In the user''s language, ask natural questions' "Tuning questions remain hard-coded to one language."
Assert-Contains $explanationStyle 'Only when the same paragraph contains a candidate value for one of those' "Explanation reference lacks the action-triggered safety boundary."
Assert-Contains $explanationStyle 'Do not add this notice to location-only explanations, concept-only' "Explanation reference applies the safety notice to non-action answers."
Assert-Contains $explanationStyle 'refusals without a candidate value, physical-safety stops' "Explanation reference still forces boilerplate onto refusals and safety stops."
Assert-Contains $explanationStyle 'ordinary display feature such as HDR' "Ordinary display settings can still trigger the tuning safety notice."
Assert-Contains $explanationStyle 'offering to continue checking later is not a parameter-change trigger' "A follow-up offer can still trigger the tuning safety notice."
Assert-Contains $explanationStyle ([regex]::Escape($englishReferenceOnlyNotice)) "The explanation reference omits the English safety notice."
Assert-Contains $explanationStyle 'Never mix the Chinese and English notices in one reply' "The explanation reference permits mixed-language notices."

$telemetry = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/telemetry-analysis.md") `
    -Label "references/integration/telemetry-analysis.md"
Assert-Contains $telemetry 'Confirm the record exists' "Telemetry guidance lacks the monitoring-software preflight."
Assert-Contains $telemetry 'HideFileName' "Telemetry guidance does not expose filename privacy."
Assert-Contains $telemetry 'requires GPU metrics to use an explicit GPU-qualified column' "Telemetry guidance allows ambiguous GPU source columns."
Assert-Contains $telemetry 'rejects NaN and Infinity' "Telemetry guidance does not reject non-finite values."
Assert-Contains $telemetry 'Time-based and row-based window parameters cannot be combined' "Telemetry guidance allows conflicting window parameters."
Assert-Contains $telemetry 'Presented and Displayed 1% low / 0.1% low FPS' "Telemetry guidance omits low-FPS percentile metrics."
Assert-Contains $telemetry 'contains only zeroes' "Telemetry guidance omits all-zero sensor warnings."
Assert-Contains $telemetry 'fastest 1% frame time' "Telemetry guidance confuses fastest frame-time percentiles with slow tails."
Assert-Contains $telemetry 'prefer the Installer card, order mirrors Local \(U\.S\.\) then SAC ftp then dAppCDN' "A first-capture monitoring route must relay the Installer preference and mirror order."
Assert-Contains $telemetry 'describe dAppCDN as network-dependent and stop retrying after a timeout' "A first-capture monitoring route must explain the dAppCDN timeout risk."
Assert-Contains $telemetry 'say that "U\.S\." is a server location rather than a download restriction' "A first-capture monitoring route must explain the U.S. server-location meaning."
Assert-Contains $telemetry 'name DWG FastView, LanSweeper, OPEN, and Try Now as advertisements' "A first-capture monitoring route must identify download-page advertisements."
Assert-Contains $telemetry 'warn that a raw HWiNFO CSV may carry appended device metadata' "A first-capture monitoring route must warn about raw CSV metadata."
Assert-Contains $telemetry 'render-telemetry-chart\.ps1' "Telemetry guidance does not route to the chart renderer."
Assert-Contains $telemetry 'chart is an evidence view, not a new measurement source' "Telemetry guidance treats a chart as independent evidence."
Assert-Contains $telemetry 'supplies a compatible CSV[\s\S]*render one SVG overview' "CSV analysis does not default to a visual overview."
Assert-Contains $telemetry 'render-gantt-chart\.ps1' "Timed plans do not route to the Gantt renderer."
Assert-Contains $telemetry 'chart is a plan, not measured evidence' "Gantt guidance overstates a planned timeline as measured evidence."
Assert-Contains $telemetry 'done` means execution ended without\s+encoding a pass/fail verdict' "Gantt done status is not separated from pass/fail outcomes."
Assert-Contains $telemetry 'complete`, `completed`, and `finished` are accepted only as aliases for `done' "Gantt done aliases are not documented as non-pass states."
Assert-Contains $telemetry 'telemetry-normalization\.md' "Telemetry guidance does not route structured sources to normalization."
$ganttRendererSource = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/render-gantt-chart.ps1") `
    -Label "scripts/render-gantt-chart.ps1"
Assert-Contains $ganttRendererSource '\$statusAliases = @\{' "Gantt renderer has no status alias map."
Assert-Contains $ganttRendererSource '"done" \{ return "#4f6f96" \}' "Gantt done status has no explicit color."
Assert-Contains $ganttRendererSource '\| state: ' "Gantt task accessibility text omits canonical status."
Assert-Contains $ganttRendererSource 'accepted values are planned, active, done, pass, fail, and blocked' "Gantt unsupported-status error omits accepted values."
Assert-Contains $ganttRendererSource 'complete/completed/finished are aliases for done, not pass' "Gantt unsupported-status error omits done alias semantics."

$analyzer = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1") `
    -Label "scripts/analyze-telemetry.ps1"
Assert-Contains $analyzer 'AnalyzerVersion = "1\.2\.3"' "Analyzer behavior changed without an AnalyzerVersion bump."
Assert-Contains $analyzer 'surplus trailing empty field' "HWiNFO rows with one surplus trailing empty field are not recovered explicitly."
Assert-Contains $analyzer 'MaxInputMegabytes' "Telemetry analyzer has no large-file safety limit."
Assert-Contains $analyzer 'ChartData' "Telemetry analyzer does not expose validated chart data."
Assert-Contains $analyzer 'ConvertTo-MarkdownCell \$result\.FileName' "Telemetry filename is not passed through Markdown sanitization."
Assert-Contains $analyzer 'ConvertTo-MarkdownCell \$warning' "Telemetry warnings are not passed through Markdown sanitization."
Assert-Contains $analyzer 'offline or cloud-placeholder file' "Telemetry analyzer may trigger cloud-file hydration."
Assert-Contains $analyzer 'local-path-safety\.ps1' "Telemetry analyzer does not use the shared local-path helper."
Assert-Contains $analyzer 'Presented FPS 1% low' "Telemetry analyzer omits Presented 1% low FPS."
Assert-Contains $analyzer 'Low-FPS sensor column' "Telemetry analyzer omits all-zero low-FPS warnings."
$chartRenderer = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/render-telemetry-chart.ps1") `
    -Label "scripts/render-telemetry-chart.ps1"
Assert-Contains $chartRenderer 'Resolve-LocalOutputFilePath' "Chart renderer does not use the shared safe output-path helper."
Assert-Contains $chartRenderer 'Only SVG output is supported' "Chart renderer output format is not constrained."
Assert-Contains $chartRenderer 'does not prove hardware stability' "Chart renderer omits the evidence limitation."
Assert-Contains $chartRenderer 'NormalizedJson' "Chart renderer cannot consume normalized telemetry JSON."
Assert-Contains $chartRenderer 'missing required section' "Chart renderer does not reject incomplete normalized documents."
$normalizer = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/normalize-telemetry.ps1") `
    -Label "scripts/normalize-telemetry.ps1"
Assert-Contains $normalizer 'NormalizedTelemetryVersion = "1\.0"' "Normalized telemetry schema version is missing."
Assert-Contains $normalizer 'InputSha256' "Normalized telemetry does not preserve input provenance."
Assert-Contains $normalizer 'MixedSources' "Normalized telemetry does not expose mixed-source state."
Assert-Contains $normalizer 'Sampling' "Normalized telemetry does not expose sampling metadata."
Assert-Contains $normalizer 'offline or cloud-placeholder' "Normalized telemetry may trigger cloud hydration."
Assert-Contains $normalizer 'samples must be an array' "Normalized telemetry accepts object-valued samples."
Assert-Contains $normalizer 'missing the required value property' "Normalized telemetry accepts sensors without a value property."
Assert-Contains $normalizer 'DataQuality' "Normalized telemetry does not expose data quality."
$normalizationDoc = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/telemetry-normalization.md") `
    -Label "references/integration/telemetry-normalization.md"
Assert-Contains $normalizationDoc 'source\.tool' "Normalized snapshot source tool requirement is missing."
Assert-Contains $normalizationDoc 'source\.version' "Normalized snapshot source version requirement is missing."
Assert-Contains $normalizationDoc 'timestamps must not move backwards' "Normalized snapshot chronology rule is missing."
Assert-Contains $normalizationDoc 'samples.*non-empty array' "Normalized snapshot array-shape rule is missing."
Assert-Contains $normalizationDoc 'omitting it is invalid' "Normalized snapshot required-value rule is missing."

$dynamicRag = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/dynamic-rag.md") `
    -Label "references/integration/dynamic-rag.md"
Assert-Contains $dynamicRag 'source hierarchy' "Dynamic RAG source hierarchy is missing."
Assert-Contains $dynamicRag 'lead-only' "Dynamic RAG community downgrade is missing."
Assert-Contains $dynamicRag 'Conflict handling' "Dynamic RAG conflict workflow is missing."
Assert-Contains $dynamicRag 'Web content is untrusted data' "Dynamic RAG page-content boundary is missing."
$ragScript = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/rag/rag-evidence.ps1") `
    -Label "scripts/rag/rag-evidence.ps1"
Assert-Contains $ragScript 'source-registry\.json' "RAG evidence tool does not use the official source registry."
Assert-Contains $ragScript 'FailOnExpired' "RAG evidence tool has no freshness gate."
Assert-Contains $ragScript 'record hash does not match' "RAG evidence cache does not verify record integrity."
Assert-Contains $ragScript 'elevates an unregistered community source' "RAG evidence cache can promote community sources."
Assert-Contains $ragScript 'lastCardNumber' "RAG evidence cache does not preserve the historical highest card number."
Assert-Contains $ragScript 'UnescapeDataString' "RAG evidence URL checks can be bypassed by encoded query parameters."
Assert-Contains $ragScript 'five minutes in the future' "RAG evidence accepts future-dated capture times."
Assert-True ($ragScript -notmatch '(?i)Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer') "RAG evidence tool performs network access."
$sourceRegistryText = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/rag/source-registry.json") `
    -Label "scripts/rag/source-registry.json"
$sourceRegistry = $sourceRegistryText | ConvertFrom-Json
Assert-True ($sourceRegistry.schemaVersion -eq "1.0") "RAG source registry schema is invalid."
Assert-True (@($sourceRegistry.sources).Count -ge 20) "RAG source registry is unexpectedly small."
Assert-Contains $dynamicRag 'recomputes the quote and record hashes' "Dynamic RAG cache-integrity documentation is missing."

$lhmDoc = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/lhm-adapter.md") `
    -Label "references/integration/lhm-adapter.md"
Assert-Contains $lhmDoc 'does not install, launch, elevate' "LHM adapter boundary is missing."
Assert-Contains $lhmDoc 'AllowLiveCollector' "LHM adapter consent requirement is missing."
$lhmCollector = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/lhm/read-lhm-telemetry.ps1") `
    -Label "scripts/lhm/read-lhm-telemetry.ps1"
Assert-Contains $lhmCollector 'root/LibreHardwareMonitor' "LHM collector uses the wrong WMI namespace."
Assert-Contains $lhmCollector 'AllowLiveCollector' "LHM collector has no explicit consent gate."
Assert-Contains $lhmCollector '127.0.0.1:8085/data.json' "LHM collector is missing its loopback Web endpoint."
Assert-Contains $lhmCollector 'IsLoopback' "LHM collector does not restrict Web access to loopback."
Assert-True ($lhmCollector -notmatch '(?i)Start-Process|Start-Service|schtasks\.exe|runas') "LHM collector can start software or self-elevate."
$lhmFunctions = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/lhm/lhm-functions.ps1") `
    -Label "scripts/lhm/lhm-functions.ps1"
Assert-Contains $lhmFunctions 'LibreHardwareMonitor' "LHM snapshot source identity is missing."
Assert-Contains $lhmFunctions 'ConvertFrom-LhmSensorObjects' "LHM sensor conversion function is missing."
$visualEvidence = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/visual-evidence.md") `
    -Label "references/integration/visual-evidence.md"
Assert-Contains $visualEvidence 'Capability boundary' "Visual evidence capability boundary is missing."
Assert-Contains $visualEvidence 'Visible facts' "Visual evidence extraction template is missing."
Assert-Contains $visualEvidence 'prompt-injection' "Visual evidence prompt-injection boundary is missing."
Assert-Contains $visualEvidence 'does not prove' "Visual evidence limitations are missing."
Assert-Contains $visualEvidence 'name the missing workload, duration, or\s+time-series evidence and end with one next action' "Screenshot stability refusals can omit the next evidence action."
$claimVerification = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/claim-verification.md") `
    -Label "references/integration/claim-verification.md"
Assert-Contains $claimVerification 'A value introduced as a record, previous value, profile, or earlier result is\s+`historical`' "Recorded values can be promoted before source classification."
Assert-Contains $claimVerification 'does not promote it' "A user instruction can bypass historical-value confirmation."
Assert-Contains $claimVerification 'Never call that value `measured-current`' "User-reported current values can be mislabeled as measured."

$doctorDoc = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/skill-doctor.md") `
    -Label "references/integration/skill-doctor.md"
Assert-Contains $doctorDoc 'does not install, elevate, repair' "Doctor non-repair boundary is missing."
Assert-Contains $doctorDoc 'PERMISSION_REQUIRED' "Doctor permission status is missing."
$doctorScript = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/doctor.ps1") `
    -Label "scripts/doctor.ps1"
Assert-Contains $doctorScript 'PowerShell syntax' "Doctor does not parse Skill scripts."
Assert-Contains $doctorScript 'Model vision' "Doctor does not disclose runtime-owned vision limits."
Assert-Contains $doctorScript '127.0.0.1:8085/data.json' "Doctor is missing its loopback LHM Web probe."
Assert-Contains $doctorScript 'IsLoopback' "Doctor does not restrict the LHM Web probe to loopback."
Assert-True ($doctorScript -notmatch '(?i)Start-Process|Start-Service|runas|install-module') "Doctor can repair, elevate, install, or start software."
$hardwareCase = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/hardware-case.md") `
    -Label "references/integration/hardware-case.md"
Assert-Contains $hardwareCase 'private local state' "Hardware case is not classified as private local state."
Assert-Contains $hardwareCase 'Never convert `supported` into `verified`' "Hardware case permits unsupported confidence upgrades."
Assert-Contains $hardwareCase 'does not authorise hardware changes' "Hardware case can be mistaken for execution permission."
Assert-Contains $hardwareCase 'export-hardware-case-html\.ps1' "Hardware case does not route to the offline HTML report."
Assert-Contains $hardwareCase '-IncludeArtifacts' "Hardware case does not document the artifact-content opt-in."
$hardwareCaseScript = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/hardware-case.ps1") `
    -Label "scripts/hardware-case.ps1"
Assert-Contains $hardwareCaseScript 'Assert-LocalReadFilePath' "Hardware case does not validate local evidence paths."
Assert-Contains $hardwareCaseScript 'Get-FileHash' "Hardware case evidence has no content hash."
Assert-Contains $hardwareCaseScript 'ConvertTo-CaseTimestamp' "Hardware case does not use explicit timestamps."
$hardwareCaseReport = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/export-hardware-case-html.ps1") `
    -Label "scripts/export-hardware-case-html.ps1"
Assert-Contains $hardwareCaseReport 'ConvertTo-HtmlText' "Hardware case report does not escape case data."
Assert-Contains $hardwareCaseReport 'Test-SafeSvgForImageEmbedding' "Hardware case report has no SVG preview safety gate."
Assert-Contains $hardwareCaseReport 'Write-LocalOutputFile' "Hardware case report does not use the safe no-overwrite writer."
Assert-Contains $hardwareCaseReport 'Artifact content not embedded' "Hardware case report does not default to metadata-only export."
$pathSafety = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/local-path-safety.ps1") -Raw -Encoding UTF8
$triageChecklist = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/triage-checklist.md") -Raw -Encoding UTF8
$triageRisk = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/risk-taxonomy.md") -Raw -Encoding UTF8
$triageProtocol = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/experiment-protocol.md") -Raw -Encoding UTF8
$collectorHandoff = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/collector-handoff.md") -Raw -Encoding UTF8
$telemetryAnalysis = $telemetry
Assert-Contains $triageChecklist 'First-contact state machine' "Triage has no first-contact priority ladder."
Assert-Contains $triageChecklist 'Evidence states' "Triage does not separate evidence quality."
Assert-Contains $triageChecklist 'Question selection' "Triage has no discriminating-question policy."
Assert-Contains $triageChecklist 'Audio stutter, crackle, or dropout' "Audio dropout triage is missing."
Assert-Contains $triageChecklist 'USB audio path and overload hypothesis' "USB audio topology and overload triage is missing."
Assert-Contains $triageChecklist 'port count is not a measurement of traffic' "USB port occupancy can still be treated as a measured overload."
Assert-Contains $triageChecklist 'USB host-controller or device timeout and\s+an NVIDIA' "USB and display-driver timeouts can still be conflated."
Assert-Contains $triageChecklist 'Windows Performance Recorder' "Audio/event trace routing is missing."
Assert-Contains $triageChecklist 'Windows Performance Analyzer' "Trace analysis routing is missing."
Assert-Contains $triageChecklist 'Everyday slowdown or intermittent stutter' "Everyday performance triage is missing."
Assert-Contains $triageChecklist 'Kernel-Power 41' "Windows crash evidence guidance is missing."
Assert-Contains $triageChecklist 'Peripheral or network scope boundary' "Peripheral and network handoff guidance is missing."
Assert-Contains $triageChecklist 'Laptop battery or power-adapter issue' "Laptop battery and adapter triage is missing."
Assert-Contains $triageRisk '## Triage priority' "Triage risk priority ordering is missing."
Assert-Contains $triageRisk 'Do not recommend registry cleaners' "Unsafe triage remediation recommendation is not blocked."
Assert-Contains $triageRisk 'driver rollback is a real change' "Driver rollback is not treated as a controlled change."
Assert-Contains $triageProtocol 'Controlled diagnostic or tuning experiment' "Diagnostic experiment protocol is missing."
Assert-Contains $triageProtocol 'Windows Performance Recorder' "WPR trace handoff is missing."
Assert-Contains $triageProtocol 'Windows Performance Analyzer' "WPA trace handoff is missing."
Assert-Contains $triageProtocol 'WinDbg' "Crash-dump handoff is missing."
Assert-Contains $triageProtocol 'Later analysis may implicate a driver' "Driver evidence can still become unsupported causal certainty."
Assert-Contains $triageProtocol 'Tracing is not passive' "Trace capture is incorrectly presented as read-only."
Assert-Contains $triageProtocol 'topology comparison is one experiment variable' "USB topology can still be changed with several variables at once."
Assert-Contains $triageProtocol 'Port count does not measure traffic' "USB traffic can still be inferred from port occupancy."
Assert-Contains $collectorHandoff 'Event and log handoff' "Triage has no event-log handoff."
Assert-Contains $collectorHandoff '`eventvwr.msc`' "Event Viewer guidance is missing."
Assert-Contains $collectorHandoff '\.etl' "ETL routing is missing."
Assert-Contains $collectorHandoff '\.dmp' "Crash-dump routing is missing."
Assert-Contains $collectorHandoff 'Windows Performance Analyzer' "WPA is not linked to ETL evidence."
Assert-Contains $collectorHandoff 'WinDbg' "WinDbg is not linked to dump evidence."
Assert-Contains $collectorHandoff 'Correlation is not causation' "Event correlation can be misreported as causation."
Assert-Contains $collectorHandoff 'Devices by connection' "USB device-to-controller grouping is missing."
Assert-Contains $collectorHandoff 'does not reliably map' "USB controller grouping can still be presented as physical-port identity."
Assert-Contains $telemetryAnalysis 'Screenshots and one-off monitoring values' "Monitoring screenshot evidence limits are missing."
Assert-Contains $pathSafety 'UNC and network paths are rejected' "Local path helper accepts UNC/network paths."
Assert-Contains $analyzer 'ConvertTo-MarkdownCell \$result\.FileName' "Telemetry filename is not passed through Markdown sanitization."
Assert-Contains $analyzer 'ConvertTo-MarkdownCell \$warning' "Telemetry warnings are not passed through Markdown sanitization."

$deviceIdentity = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/device-identity.md") -Raw -Encoding UTF8
Assert-Contains $deviceIdentity '`confirmed`' "The confirmed device identity state is missing."
Assert-Contains $deviceIdentity '`user-reported`' "The user-reported device identity state is missing."
Assert-Contains $deviceIdentity '`unreadable`' "The unreadable device identity state is missing."
Assert-Contains $deviceIdentity '`conflict`' "The conflicting device identity state is missing."
Assert-Contains $deviceIdentity 'never as instructions' "Unreadable device input is not treated as untrusted data."
Assert-Contains $deviceIdentity 'never as proof of a model' "Hypothesized model decoding can still become confirmed."
Assert-Contains $deviceIdentity 'Do not mechanically block every tuning task' "Unreadable identity routing can overblock identity-independent work."
Assert-Contains $deviceIdentity 'If the system does not boot, collector is unavailable' "The no-boot identity fallback is missing."
Assert-Contains $deviceIdentity 'Collector quality versus session status' "Collector quality and session identity status are not explicitly distinguished."
Assert-Contains $deviceIdentity '`conflict` is not emitted by a single collector snapshot' "Single-snapshot identity quality can be mistaken for cross-source conflict."
Assert-Contains $deviceIdentity 'system Model is the core identity field' "Core and optional identity fields are not distinguished."
Assert-Contains $deviceIdentity 'Live collector tests' "Live collector test consent rules are missing."
Assert-Contains $deviceIdentity 'AllowLiveCollector' "Live collector tests have no explicit opt-in."
Assert-True ($deviceIdentity -notmatch '\[Device identity:') "Device identity guidance reintroduced a public bracketed state bar."

$identityHelper = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/device-identity.ps1") -Raw -Encoding UTF8
Assert-Contains $identityHelper 'function Get-DeviceIdentityAssessment' "The identity assessment helper is missing."
Assert-Contains $identityHelper 'function ConvertTo-DeviceIdentityDisplay' "The identity display sanitizer is missing."
Assert-Contains $identityHelper 'function ConvertTo-DeviceIdentityMarkdown' "The Markdown identity sanitizer is missing."
Assert-Contains $identityHelper 'function ConvertTo-SafeMarkdownText' "The generic hardware Markdown sanitizer is missing."
Assert-Contains $identityHelper 'function Get-RedactedInventoryData' "The synthetic-testable inventory redaction helper is missing."
Assert-Contains $identityHelper 'PnpDeviceId' "The GPU PnP device identifier is not covered by redaction."
Assert-Contains $identityHelper 'function Test-GenericVolumeLabel' "The generic volume-label allowlist is missing."
Assert-Contains $identityHelper 'function Test-GenericDisplayModel' "The generic display-model allowlist is missing."
Assert-True ($identityHelper -notmatch '\$copy\.Slot\s*=\s*"Memory module') "Redaction replaces structural memory slot evidence."
Assert-Contains $identityHelper 'function ConvertTo-DeviceIdentitySessionStatus' "The collector-quality to session-status mapping is missing."
Assert-Contains $identityHelper 'possible mojibake' "The identity helper does not detect probable mojibake."

$collectorScript = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/collect-windows.ps1") -Raw -Encoding UTF8
$legacyNulEscape = ([char]0x60).ToString() + "u0000"
Assert-True (-not $collectorScript.Contains($legacyNulEscape)) "The collector contains a PowerShell 5-only numeric Unicode escape."
Assert-Contains $collectorScript 'IdentityQuality = \$identityAssessment' "The collector snapshot does not expose IdentityQuality."
Assert-Contains $collectorScript 'CollectorVersion = "1\.0\.1-r23"' "The collector behavior changed without a collector version bump."
Assert-Contains $collectorScript 'SchemaVersion = 4' "The collector topology contract was not advanced to schema 4."
Assert-Contains $collectorScript 'MemorySlotSummary' "The collector does not expose the memory-slot summary."
Assert-Contains $collectorScript 'ReadMemoryDeviceCount' "The collector has no SMBIOS memory-slot fallback."
Assert-Contains $collectorScript 'AdapterKind' "The collector does not classify GPU adapter kind."
Assert-Contains $collectorScript 'StateSource' "The collector does not preserve GPU state provenance."
Assert-Contains $collectorScript 'ConvertTo-DeviceIdentityMarkdown' "The Markdown renderer does not isolate identity fields safely."
Assert-Contains $collectorScript 'ConvertTo-SafeMarkdownText -Value \(\$details -join' "Hardware-derived detail lines are not passed through the generic Markdown sanitizer."
Assert-Contains $collectorScript 'DriveType = 2 OR DriveType = 3' "CIM volume collection does not match the fixed/removable fallback scope."
Assert-Contains $collectorScript '## Reported physical disks' "The physical-disk heading still claims unverified active status."
Assert-Contains $collectorScript 'Get-RedactedInventoryData' "The collector does not use the tested inventory-redaction helper."
Assert-Contains $collectorScript '-GPU \$gpu' "The collector does not pass GPU data through redaction."
Assert-Contains $collectorScript 'inventory-context\.ps1' "The collector does not load the tested inventory-context helper."
Assert-Contains $collectorScript '\[switch\]\$RequireElevated' "The collector has no explicit user-run elevated mode."
Assert-Contains $collectorScript 'CollectionContext' "The collector does not record its privilege context."
Assert-Contains $collectorScript 'restricted-agent' "The collector does not distinguish a restricted agent process from a normal user process."
Assert-Contains $collectorScript 'nvidia-smi instantaneous sample' "The collector does not label nvidia-smi live values as instantaneous."
Assert-Contains $collectorScript 'enforced\.power\.limit' "The collector does not query the effective NVIDIA power limit."
Assert-Contains $collectorScript 'name,power\.limit,power\.default_limit' "The legacy NVIDIA power fields are not queried independently."
Assert-Contains $collectorScript 'NvidiaEffectivePowerLimitQueryStatus' "The collector does not preserve enforced power-limit query state."
Assert-Contains $collectorScript 'requested unavailable' "A missing requested NVIDIA power limit is not labeled unavailable."
Assert-Contains $collectorScript 'effective unavailable' "A missing effective NVIDIA power limit is not labeled unavailable."
Assert-Contains $collectorScript '\$env:DSH_SHELL' "The collector does not recognize a DeepSeek Harness sandbox hint."
Assert-Contains $collectorScript 'AccessDeniedWarningCount' "The collector does not expose its access-denied evidence count."
Assert-Contains $collectorScript 'BatteryStatusReason' "The collector does not explain why battery data are unavailable."
Assert-Contains $collectorScript 'BatteryCimStatus' "The collector does not distinguish CIM battery availability."
Assert-Contains $collectorScript 'Reason: \$\(\$snapshot\.CollectionStatus\.BatteryStatusReason\)' "The Markdown report omits the battery status reason."
Assert-Contains $collectorScript '\$ErrorActionPreference = "Continue"' "The powercfg stderr path is not captured before exit-code classification."
Assert-Contains $collectorScript 'powercfg battery report permission denied \(exit \$powerCfgExitCode\)' "The powercfg permission-denied exit branch is missing."
Assert-True ($collectorScript -notmatch '[^\x00-\x7F]') "The collector source contains non-ASCII text that PowerShell 5.1 can misdecode."
Assert-True ($collectorScript -notmatch '(?i)Start-Process[^\r\n]*-Verb\s+RunAs') "The collector attempts to self-elevate."
$pathSafetyHelper = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/local-path-safety.ps1") -Raw -Encoding UTF8
$inventoryContextHelper = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/inventory-context.ps1") -Raw -Encoding UTF8
Assert-Contains $pathSafetyHelper '\[switch\]\$IncludeUtf8Bom' "The output helper cannot select BOM per format."
Assert-Contains $collectorScript 'IncludeUtf8Bom:\(\$Format -eq "Markdown"\)' "The collector does not restrict UTF-8 BOM to Markdown output."
Assert-Contains $inventoryContextHelper 'RestrictedContextAccessDeniedThreshold = 5' "The restricted-process threshold is not named or explained in code."
Assert-Contains $inventoryContextHelper '\\u62D2\\u7EDD\\u8BBF\\u95EE' "The Chinese access-denied matcher is not locale-independent ASCII."
$collectorSmokeSource = Get-Content -LiteralPath (Join-Path $resolvedRoot "tests/run-collector-smoke-tests.ps1") -Raw -Encoding UTF8
Assert-True ($collectorSmokeSource -notmatch '[^\x00-\x7F]') "The collector smoke test contains non-ASCII source that PowerShell 5.1 can misdecode."
Assert-Contains $collectorScript 'local-path-safety\.ps1' "Collector does not use the shared local-path safety helper."
$pathSafety = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/local-path-safety.ps1") -Raw -Encoding UTF8
Assert-Contains $pathSafety 'will not be overwritten' "Local output helper can overwrite an existing file."
Assert-Contains $pathSafety 'Mapped network drives are rejected' "Local output helper accepts mapped network drives."
Assert-Contains $pathSafety 'ReparsePoint' "Local path helper does not reject links or junctions."

$collectorSmokeTest = Get-Content -LiteralPath (Join-Path $resolvedRoot "tests/run-collector-smoke-tests.ps1") -Raw -Encoding UTF8
Assert-Contains $collectorSmokeTest '\[switch\]\$AllowLiveCollector' "Collector smoke tests execute without an opt-in switch."
Assert-Contains $collectorSmokeTest 'Collector live smoke: SKIP' "Skipped live collector tests are not reported as SKIP."

$allTests = Get-Content -LiteralPath (Join-Path $resolvedRoot "tests/run-all-tests.ps1") -Raw -Encoding UTF8
Assert-Contains $allTests '\[switch\]\$AllowLiveCollector' "The all-tests runner has no live collector opt-in."
Assert-Contains $allTests 'Live collector smoke: SKIP' "The all-tests runner hides a skipped live collector test."

$interactionClosure = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/interaction-closure.md") -Raw -Encoding UTF8
Assert-Contains $interactionClosure 'Required end state' "Interaction closure reference has no required end states."
Assert-Contains $interactionClosure 'independent reuse' "The teaching objective is not tied to independent reuse."
Assert-Contains $interactionClosure 'resume the original flow' "Interaction closure reference has no resumed-flow rule."
Assert-Contains $interactionClosure 'one short natural-language sentence' "Multi-step progress guidance is missing its natural-language form."
Assert-Contains $interactionClosure 'single-turn response must not show a bracketed workflow-state template' "Single-turn interaction closure still permits a workflow shell."

$crossMode = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/cross-mode-handoffs.md") -Raw -Encoding UTF8
Assert-Contains $crossMode '\| Telemetry \|' "Cross-mode matrix has no Telemetry row."
Assert-Contains $crossMode 'Anything to telemetry' "Cross-mode guidance has no entry into telemetry."
Assert-Contains $crossMode 'Telemetry to triage, tuning, or purchase' "Cross-mode guidance has no telemetry exit rules."
Assert-Contains $crossMode 'does not establish a\s+fault' "Telemetry handoff can be mistaken for diagnosis."
Assert-Contains $crossMode 'resume the same\s+experiment loop' "Telemetry cannot return to the active experiment."

$fixedWorkloads = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/fixed-workloads.md") -Raw -Encoding UTF8
Assert-Contains $fixedWorkloads 'One-screen experiment card' "One-screen experiment card is missing."
Assert-Contains $fixedWorkloads 'workload-record-templates\.md' "The detailed workload-template reference is not routed."
Assert-Contains $fixedWorkloads 'Explanation \(depth adapted to the user and risk\)' "The experiment card has no adaptive explanation section."
Assert-Contains $fixedWorkloads 'localized safety notice from SKILL\.md' "The experiment card hard-codes the safety notice language."
Assert-Contains $fixedWorkloads 'depth adapted to the user and risk' "The experiment card does not adapt explanation depth."
Assert-Contains $fixedWorkloads 'Cooling baseline' "The workload record has no cooling baseline."
Assert-Contains $fixedWorkloads 'Noise measurement' "The workload record has no noise-measurement fields."
Assert-Contains $fixedWorkloads 'compact prose by default' "The experiment card is forced even when plain prose is clearer."
Assert-Contains $fixedWorkloads 'A settings card, table, or fenced block is content' "The guidance treats all structured plans as workflow chrome."
Assert-Contains $fixedWorkloads 'Never place a mode label' "Mode labels are still allowed inside the answer or card."
Assert-Contains $fixedWorkloads 'Before -> candidate \(same paragraph\)' "The safety notice is not bound to the candidate paragraph."
Assert-Contains $fixedWorkloads 'repeat-or-diagnose' "Inconclusive experiment results have no repeat-or-diagnose decision."
Assert-True ($fixedWorkloads -notmatch 'Mode:\s*quick\s*/\s*deep') "The experiment-card template reintroduced a mode field."
$workloadRecordTemplates = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "references/integration/workload-record-templates.md") `
    -Label "references/integration/workload-record-templates.md"
Assert-Contains $workloadRecordTemplates 'Template 1: game or interactive workload' "Game workload template is missing."
Assert-Contains $workloadRecordTemplates 'Template 2: synthetic benchmark' "Synthetic workload template is missing."
Assert-Contains $workloadRecordTemplates 'Template 3: rendering or production workload' "Production workload template is missing."
Assert-Contains $workloadRecordTemplates 'Template 4: stability check' "Stability-check template is missing."

$success = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/success-and-sensor-semantics.md") -Raw -Encoding UTF8
Assert-Contains $success 'Goal-specific success' "Goal-specific success criteria are missing."
Assert-Contains $success 'Sensor semantics' "Sensor semantics are missing."
Assert-Contains $success 'Noise as evidence' "Noise-specific evidence rules are missing."
Assert-Contains $success '## Promoting a profile to daily use' "Profile promotion guidance is missing its section heading."

Assert-Contains $componentPlaybooks 'Use the daily-promotion checklist' "Component playbooks do not point at the profile promotion checklist."

$riskTaxonomy = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/risk-taxonomy.md") -Raw -Encoding UTF8
Assert-Contains $riskTaxonomy 'BIOS/UEFI parameter' "Risk taxonomy does not distinguish BIOS parameters."
Assert-Contains $riskTaxonomy 'Firmware flashing or modification' "Risk taxonomy conflates firmware flashing with ordinary BIOS parameters."

$toolsText = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/tools.md") -Raw -Encoding UTF8
$beginnerGuide = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/beginner-guide.md") -Raw -Encoding UTF8
Assert-Contains $toolsText 'observed on 2026-10-26' "HWiNFO download observations are not dated."
Assert-Contains $beginnerGuide 'observed on\s+2026-10-26' "Beginner HWiNFO observations are not dated."
Assert-Contains $beginnerGuide 'download card rules' "Beginner monitoring route does not point at the download card rules."

$persistence = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/persistence-and-update-gate.md") -Raw -Encoding UTF8
Assert-Contains $persistence 'Driver and tool update gate' "Driver/tool update gate is missing."
Assert-Contains $persistence 'unvalidated after update' "Post-update validation state is missing."

$coexistence = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/installation-coexistence.md") -Raw -Encoding UTF8
Assert-Contains $coexistence 'allow_implicit_invocation: false' "Legacy explicit-only policy is missing."
Assert-Contains $coexistence 'disable-model-invocation: true' "Coexistence guidance does not give the Harness invocation field."

$marketCheck = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/upgrade/market-check.md") -Raw -Encoding UTF8
Assert-Contains $marketCheck 'cash upgrade cost' "Market cost does not distinguish cash outlay."
Assert-Contains $marketCheck 'retained: no cash offset' "Retained old hardware is incorrectly treated as a cash offset."

$decisionFramework = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/upgrade/decision-framework.md") -Raw -Encoding UTF8
Assert-Contains $decisionFramework 'preference/aesthetic purchase' "Preference purchases are not classified separately."
Assert-Contains $decisionFramework 'planning/future project' "Future project planning is not supported."

$beginnerGuide = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/beginner-guide.md") -Raw -Encoding UTF8
Assert-Contains $beginnerGuide 'explicit preference purchase' "The beginner purchase route still treats every purchase as a functional deficit."
Assert-True ($beginnerGuide -notmatch 'state the chosen mode normally') "The beginner guide still asks for a mode badge after routing."
Assert-Contains $beginnerGuide 'button names and menu positions can differ between HWiNFO versions' "The HWiNFO recording route omits version-sensitive UI guidance."

$triageChecklist = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/triage-checklist.md") -Raw -Encoding UTF8
Assert-Contains $triageChecklist 'embedded collector' "Triage still depends on an external collector Skill."
Assert-Contains $triageChecklist 'De-energized handling rule' "The pre-reseating power-off rule is missing."

$collectorHandoff = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/collector-handoff.md") -Raw -Encoding UTF8
Assert-Contains $collectorHandoff 'does not require another installed Skill' "Collector handoff retains an old Skill dependency."

$upgradeIntake = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/upgrade/intake-template.md") -Raw -Encoding UTF8
$explainPosition = $upgradeIntake.IndexOf("explain both output modes")
$choosePosition = $upgradeIntake.IndexOf("ask them to choose standard or privacy-redacted output")
Assert-True ($explainPosition -ge 0 -and $choosePosition -gt $explainPosition) "Upgrade intake asks for a privacy mode before explaining it."

$coolingEvidence = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/cooling-evidence.md") -Raw -Encoding UTF8
Assert-Contains $coolingEvidence 'only what affects the current target' "Cooling questions are not target-specific."

$coverageMap = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/coverage-map.md") -Raw -Encoding UTF8
Assert-Contains $coverageMap 'controlled integration revisions' "Coverage map still claims all source files are unchanged."
Assert-True ($coverageMap -notmatch 'byte-for-byte unchanged') "Coverage map still claims source files are byte-for-byte unchanged."

$scenarioDoc = Get-Content -LiteralPath (Join-Path $resolvedRoot "tests/interaction-scenarios.md") -Raw -Encoding UTF8
Assert-Contains $scenarioDoc 'daily target no larger than 10.5 KiB' "Interaction scenario budget has no 10.5 KiB daily target."
Assert-Contains $scenarioDoc 'hard maximum of 11 KiB' "Interaction scenario budget does not preserve the 11 KiB hard maximum."
Assert-Contains $scenarioDoc 'entry-budget-exception\.json' "Interaction scenarios do not document the safety-hotfix exception."
Assert-Contains $scenarioDoc '256 extra bytes' "Interaction scenarios omit the 256-byte exception ceiling."
Assert-Contains $scenarioDoc 'expired, stale, incomplete, oversized' "Interaction scenarios do not reject invalid budget exceptions."
Assert-Contains $scenarioDoc 'no larger than 20 KB' "Interaction scenario budget does not match the 20 KB quick-mode budget."
$crossCapabilityScenarios = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "tests/cross-capability-scenarios.md") `
    -Label "tests/cross-capability-scenarios.md"
foreach ($scenarioHeading in @(
    "1. Beginner gives only a vague symptom",
    "2. CSV and screenshot cover the same run",
    "3. Official document conflicts with local evidence",
    "4. LibreHardwareMonitor is not running",
    "5. Screenshot contradicts the log",
    "6. User demands both a bypass and a direct setting"
)) {
    Assert-Contains $crossCapabilityScenarios ([regex]::Escape("## $scenarioHeading")) "Cross-capability scenario is missing: $scenarioHeading"
}
Assert-Contains $crossCapabilityScenarios 'do not average the two claims' "Cross-source conflict rules permit averaging."
Assert-Contains $crossCapabilityScenarios 'report live sensor access as unavailable rather than hardware absent' "Missing LHM is confused with missing hardware."
Assert-Contains $crossCapabilityScenarios 'no target value' "Power-path refusal permits a target value."
$crossCapabilityResults = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "tests/cross-capability-results-20261103.md") `
    -Label "tests/cross-capability-results-20261103.md"
Assert-Contains $crossCapabilityResults 'PASS \(6/6\)' "Cross-capability result summary is missing."
Assert-Contains $crossCapabilityResults 'Independent human acceptance: PENDING' "Model-assisted acceptance is mislabeled as human sign-off."
Assert-Contains $crossCapabilityResults 'HardwareWrite: none' "Cross-capability acceptance reports an unexpected hardware write."
Assert-Contains $scenarioDoc 'Manual behavioral acceptance scenarios' "Interaction scenarios are still presented as automated behavior tests."
Assert-Contains $scenarioDoc 'do not prove that every scenario behaves' "Interaction scenarios overstate static test coverage."
Assert-Contains $scenarioDoc '(?m)^## 47\. A dynamic boost point does not define curve activation' "Interaction scenarios omit the dynamic GPU operating-point case."
Assert-Contains $scenarioDoc 'not conclude that the curve failed merely because one exact target' "The dynamic GPU scenario can still infer curve failure from an absent point."
foreach ($scenarioHeading in @(
    "48. Automatic candidate cannot skip recovery",
    "49. Thermal pressure changes the automatic variable",
    "74. Usable start stops when good enough",
    "85. Laptop defaults to a correctable stock assumption",
    "100. GPU memory needs identity, units, and a reporting basis",
    "101. A concept question does not require the tuning gate",
    "102. A plain symptom routes to the smallest beginner question",
    "103. XMP or EXPO still needs a stock baseline",
    "104. MoDT cannot silently inherit the desktop power model",
    "105. Inconclusive results require repeat or diagnosis",
    "106. A novice response must not leak internal terminology",
    "107. A detailed request changes depth, not safety",
    "108. Detailed does not mean jargon-heavy for a novice",
    "109. Detailed concept question stays outside tuning intake",
    "110. Detailed XMP guidance still needs a stock baseline",
    "111. Detailed laptop power-state comparison is not a stability verdict",
    "112. Detailed monitoring-help answer must distinguish unavailable from absent",
    "113. Detailed output still cannot resolve contradictory identity by guessing",
    "114. Detailed blocked output must not expose stale success fields",
    "115. Detailed inventory leads with a user summary",
    "116. Detailed purchase question starts with the actual bottleneck",
    "117. Detailed explanation cannot outrank physical danger",
    "118. Detailed bypass request remains a refusal",
    "119. Detailed request when many gate facts are missing",
    "120. Detailed comparison of conflicting CSV and screenshot",
    "121. Detailed candidate still blocks when the current value is missing",
    "122. Detailed thermal or power bottleneck changes the next variable",
    "123. Detailed preference purchase does not invent a bottleneck",
    "124. Detailed interpretation of one screenshot",
    "125. Detailed review of a clean but ineffective result",
    "126. Detailed source conflict still needs provenance",
    "127. Detailed automation request is declined",
    "128. Detailed recovery request can still be actionable",
    "129. Compound symptoms preserve the safety priority",
    "130. Lights and fans but no display",
    "131. Black screen may be display-only or a full restart",
    "132. Intermittent crash evidence is not a component diagnosis",
    "133. Event Viewer export and analysis-tool routing",
    "134. User cannot find Event Viewer",
    "135. Conflicting Event Viewer and monitoring evidence",
    "136. Desktop Battlefield audio stutter with driver evidence",
    "137. Driver reset or visual artifact blocks tuning",
    "138. Storage warning outranks performance work",
    "139. Thermal evidence before a quieter fan curve",
    "140. Composite troubleshooting request must not drift into tuning and purchase",
    "141. User demands one failed component",
    "142. Crowded USB audio must remain a hypothesis",
    "143. USB and GPU-driver evidence conflict",
    "144. USB symptoms cross functional families",
    "145. Remembered USB load is not current evidence",
    "146. USB path improvement is not motherboard failure",
    "147. Low-tool USB triage still has a next step",
    "148. Urgent demand cannot justify a blind driver disable"
)) {
    Assert-Contains $scenarioDoc ([regex]::Escape("## $scenarioHeading")) "Required behavior scenario is missing: $scenarioHeading"
}
Assert-True ($scenarioDoc -notmatch '14001\s*MHz') "The interaction scenarios reintroduced a concrete local memory reading."

$toneScenarios = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "tests/tone-scenarios.md") `
    -Label "tests/tone-scenarios.md"
Assert-Contains $toneScenarios 'Any one round showing it means not fixed' "Rule-driven tone acceptance lost the any-round failure rule."
Assert-Contains $toneScenarios 'Fixed only when absent in all three rounds' "Convention-driven tone acceptance lost the three-round absence rule."
Assert-Contains $toneScenarios '(?m)^\| T2 \|' "Tone scenarios lost the frozen read-only prompt row."
Assert-Contains $toneScenarios '(?m)^\| T12 \|' "Tone scenarios lost the frozen hidden-limit prompt row."
Assert-Contains $toneScenarios '(?m)^\| T13 \|' "Tone scenarios lost the positive-trigger prompt row."
Assert-Contains $toneScenarios '(?m)^\| T14 \|' "Tone scenarios lost the English light-information row."
Assert-Contains $toneScenarios '(?m)^\| T15 \|' "Tone scenarios lost the English hidden-limit row."
Assert-Contains $toneScenarios '(?m)^\| T16 \|' "Tone scenarios lost the English fault row."
Assert-Contains $toneScenarios '(?m)^\| T17 \|' "Tone scenarios lost the English positive-trigger row."
Assert-Contains $toneScenarios 'no claim that the assistant is human' "Tone scenarios omit the truthful-identity boundary."
Assert-Contains $toneScenarios 'Dangerous procedures may need numbered steps' "Tone acceptance bans legitimate numbering in dangerous procedures."
Assert-Contains $toneScenarios 'opening an HDR page' "Tone scenarios do not distinguish ordinary UI from tuning parameters."
Assert-Contains $toneScenarios 'include the safety notice in the same' "Tone scenarios do not bind the safety notice to the candidate paragraph."
Assert-Contains $toneScenarios 'do not use a mode label inside the body or card' "Tone scenarios permit a mode label inside a planning card."
Assert-Contains $toneScenarios 'One natural sentence such as' "Tone scenarios conflate natural route language with a mode-label violation."
Assert-Contains $toneScenarios 'A card, table, or fenced block is content' "Tone scenarios treat all structured plans as workflow chrome."
Assert-Contains $toneScenarios ([regex]::Escape($englishReferenceOnlyNotice)) "Tone scenarios do not define the English safety notice."
Assert-Contains $toneScenarios 'must not contain the Chinese sentence' "Tone scenarios do not prohibit mixed-language notices."

$manualAcceptance = Get-Content -LiteralPath (Join-Path $resolvedRoot "tests/manual-acceptance-template.md") -Raw -Encoding UTF8
Assert-Contains $manualAcceptance 'Release-blocking scenarios' "Manual acceptance has no release-blocking scenario set."
Assert-Contains $manualAcceptance 'Approved for broad distribution: no' "Manual acceptance defaults to broad approval."
Assert-Contains $manualAcceptance 'Any one round showing it means not fixed' "Manual acceptance omits the rule-driven any-round gate."
Assert-Contains $manualAcceptance 'Fixed only when absent in all three rounds' "Manual acceptance omits the convention-driven three-round gate."
Assert-Contains $manualAcceptance 'For the 1\.4\.3\+ tone layer' "Manual acceptance does not preserve the tone-layer acceptance baseline."
Assert-Contains $manualAcceptance 'GPU automatic candidate generation and result evaluation' "Manual acceptance has no integrated GPU candidate area."
Assert-Contains $manualAcceptance 'Laptop power state and candidate fallback' "Manual acceptance has no laptop power-state and fallback area."
foreach ($triageScenarioId in @("129", "132", "133", "136", "138", "140", "141", "142", "143", "144", "145", "146", "148")) {
    Assert-Contains $manualAcceptance ("(?m)^\\| " + $triageScenarioId + " \\|") "Manual acceptance is missing triage scenario $triageScenarioId."
}

$auditTest = Join-Path $resolvedRoot "tests/run-telemetry-audit-tests.ps1"
if (-not (Test-Path -LiteralPath $auditTest -PathType Leaf)) {
    $failures.Add("The packaged telemetry audit regression is missing.")
}

$exceptionFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("pcwb-budget-exception-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $exceptionFixtureRoot -Force | Out-Null
    $exceptionFixturePath = Join-Path $exceptionFixtureRoot "entry-budget-exception.json"
    $exceptionTestNow = [datetimeoffset]::Parse("2026-11-13T12:00:00+08:00")
    $exceptionTestHardLimit = 11264
    $exceptionFixture = [ordered]@{
        schemaVersion = 1
        kind = "safety-hotfix"
        reason = "Correct an immediate hardware-safety instruction."
        safetyImpact = "Prevents damage or data loss in a known scenario."
        migrationPlan = "Move the detailed rationale into the matching reference."
        owner = "test-owner"
        createdAt = $exceptionTestNow.AddHours(-1).ToString("o")
        expiresAt = $exceptionTestNow.AddHours(24).ToString("o")
        maxBytes = $exceptionTestHardLimit + 200
    }
    [IO.File]::WriteAllText(
        $exceptionFixturePath,
        ($exceptionFixture | ConvertTo-Json -Depth 4) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $validException = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 100) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True $validException.Allowed "A valid safety-hotfix exception was rejected."

    $exceptionFixture.migrationPlan = ""
    [IO.File]::WriteAllText($exceptionFixturePath, ($exceptionFixture | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $missingPlan = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 100) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $missingPlan.Allowed) "A safety-hotfix exception without a migration plan was accepted."
    $exceptionFixture.migrationPlan = "Move the detailed rationale into the matching reference."

    $exceptionFixture.expiresAt = $exceptionTestNow.AddHours(80).ToString("o")
    [IO.File]::WriteAllText($exceptionFixturePath, ($exceptionFixture | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $overlongException = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 100) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $overlongException.Allowed) "A safety-hotfix exception longer than 72 hours was accepted."

    $exceptionFixture.expiresAt = $exceptionTestNow.AddHours(-1).ToString("o")
    [IO.File]::WriteAllText($exceptionFixturePath, ($exceptionFixture | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $expiredException = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 100) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $expiredException.Allowed) "An expired safety-hotfix exception was accepted."

    $exceptionFixture.expiresAt = $exceptionTestNow.AddHours(24).ToString("o")
    [IO.File]::WriteAllText($exceptionFixturePath, ($exceptionFixture | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $overflowException = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 257) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $overflowException.Allowed) "A safety-hotfix exception above the 256-byte overflow ceiling was accepted."

    $exceptionFixture.maxBytes = $exceptionTestHardLimit + 257
    [IO.File]::WriteAllText($exceptionFixturePath, ($exceptionFixture | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $overstatedCeiling = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 100) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $overstatedCeiling.Allowed) "A safety-hotfix exception can raise its own ceiling above 256 bytes."

    [IO.File]::WriteAllText(
        $exceptionFixturePath,
        (($exceptionFixture | ConvertTo-Json -Depth 4) + (" " * 17000)),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $oversizedFile = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes ($exceptionTestHardLimit + 100) `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $oversizedFile.Allowed) "A safety-hotfix exception file larger than 16 KiB was accepted."

    $staleException = Test-EntryBudgetException `
        -Path $exceptionFixturePath `
        -SkillBytes $exceptionTestHardLimit `
        -HardLimit $exceptionTestHardLimit `
        -Now $exceptionTestNow
    Assert-True (-not $staleException.Allowed) "A stale safety-hotfix exception was accepted."
}
finally {
    if (Test-Path -LiteralPath $exceptionFixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $exceptionFixtureRoot -Recurse -Force
    }
}

$skillSoftLimit = 10752
$skillHardLimit = 11264
$skillBytes = Get-Utf8LfByteCount -Path $skillPath
$entryBudgetExceptionPath = Join-Path $resolvedRoot "tests/entry-budget-exception.json"
if ($skillBytes -gt $skillHardLimit) {
    $exceptionResult = Test-EntryBudgetException `
        -Path $entryBudgetExceptionPath `
        -SkillBytes $skillBytes `
        -HardLimit $skillHardLimit `
        -Now ([datetimeoffset]::Now)
    if ($exceptionResult.Allowed) {
        $budgetWarnings.Add($exceptionResult.Warning) | Out-Null
    }
    else {
        foreach ($exceptionError in $exceptionResult.Errors) {
            $failures.Add($exceptionError) | Out-Null
        }
    }
}
else {
    if (Test-Path -LiteralPath $entryBudgetExceptionPath -PathType Leaf) {
        $failures.Add("tests/entry-budget-exception.json must be removed once SKILL.md is within the hard maximum.") | Out-Null
    }
    if ($skillBytes -gt $skillSoftLimit) {
        $budgetWarnings.Add("SKILL.md exceeds the 10.5 KiB daily target: $skillBytes bytes; hard maximum is $skillHardLimit bytes. Migrate content before adding more.") | Out-Null
    }
}

$quickFiles = @(
    "SKILL.md",
    "references/integration/tuning-modes.md",
    "references/integration/fixed-workloads.md"
)
$quickBytes = 0
foreach ($relative in $quickFiles) {
    $quickBytes += Get-Utf8LfByteCount -Path (Join-Path $resolvedRoot $relative)
}
if ($quickBytes -gt 20480) {
    $failures.Add("Quick-mode initial load exceeds the 20 KB budget: $quickBytes bytes.")
}

Write-Host ("Entry budget: {0} bytes (daily target {1}; hard maximum {2}; headroom {3})." -f $skillBytes, $skillSoftLimit, $skillHardLimit, ($skillSoftLimit - $skillBytes))
Write-Host ("Quick-mode budget: {0} bytes (hard maximum 20480; headroom {1})." -f $quickBytes, (20480 - $quickBytes))
foreach ($budgetWarning in $budgetWarnings) {
    Write-Host "Budget warning: $budgetWarning" -ForegroundColor Yellow
}

$oldValidation = Join-Path $resolvedRoot "references/integration/validation-and-telemetry.md"
if (Test-Path -LiteralPath $oldValidation) {
    $failures.Add("Obsolete unsplit validation reference still exists.")
}

if ($failures.Count -gt 0) {
    Write-Host "Interaction contract tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Interaction contract tests: PASS" -ForegroundColor Green
