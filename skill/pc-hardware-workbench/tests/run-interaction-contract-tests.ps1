[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

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

Assert-Contains $skill '(?m)^  version: "1\.4\.3"\r?$' "metadata.version should be 1.4.3."
Assert-Contains $skill 'r18 collector' "The Skill maintenance summary collector revision disagrees with the collector code."
Assert-Contains $skill 'while the power-path evidence is incomplete' "The Advice intensity route does not include incomplete power-path evidence."
Assert-Contains $skill 'hidden or manufacturer-limited limit' "The Advice intensity summary is narrower than the hidden or manufacturer-limited scope."
Assert-Contains $skill 'power ceiling, voltage limit, fan policy, and firmware restriction' "The Advice intensity summary omits one or more controlled object types."
Assert-Contains $skill 'When invoked without a concrete task' "Bare-invocation introduction rule is missing."
Assert-Contains $skill 'If the first request already contains a concrete task' "Task-bearing invocation skip rule is missing."
$neutralIntroduction = [regex]::Unescape('\u0060pc-hardware-workbench\u0060 \u5DF2\u52A0\u8F7D')
$codexIntroduction = [regex]::Unescape('\u0060$pc-hardware-workbench\u0060 \u5DF2\u52A0\u8F7D')
Assert-True (-not ($skill -match ("(?m)^> " + [regex]::Escape($codexIntroduction)))) "The spoken introduction still uses the Codex-only invocation sigil."
Assert-Contains $skill ("(?m)^> " + [regex]::Escape($neutralIntroduction)) "The bare-invocation introduction lost its neutral skill name."
Assert-Contains $skill 'Explain named choices' "Choice explanation rule is missing."
Assert-Contains $skill 'Do not ask a bare' "Bare named-choice prohibition is missing."
Assert-Contains $skill 'Plain-language parameter explanations' "Plain-language parameter rule is missing."
Assert-Contains $skill 'Action:' "Plain-language action component is missing."
Assert-Contains $skill 'Analogy:' "Plain-language analogy component is missing."
Assert-Contains $skill 'Consequence:' "Plain-language consequence component is missing."
Assert-Contains $skill 'explanation-style\.md' "The detailed explanation-style reference is not linked."
Assert-Contains $skill 'Do not give a bare number, offset, timing, profile, or instruction without the safety notice and an appropriately detailed explanation' "The bare-value rule lost its safety-notice binding."
Assert-Contains $skill ([regex]::Escape($referenceOnlyNotice)) "The mandatory reference-only safety notice is missing."
Assert-Contains $skill ([regex]::Escape($englishReferenceOnlyNotice)) "The English safety notice is missing."
Assert-Contains $skill 'Never mix the Chinese and English notices in one reply' "The language-mixing prohibition is missing."
Assert-Contains $skill 'Choose explanation depth by user knowledge and risk' "Explanation detail is not context-adaptive."
Assert-Contains $skill 'BIOS/UEFI tuning setting' "BIOS/UEFI tuning settings are not covered by the parameter safety rule."
Assert-Contains $skill 'firmware, clock, voltage, power control' "Firmware and tuning controls are not covered by the parameter safety rule."
Assert-Contains $skill 'exact visible menu/control label' "BIOS/UEFI guidance can invent an unverified menu path."
Assert-Contains $skill 'Beginner route' "Beginner route is missing."
Assert-Contains $skill 'beginner-guide\.md' "Beginner guide link is missing."
Assert-Contains $skill 'Teaching objective' "Independent-reuse teaching objective is missing."
Assert-Contains $skill 'independent reuse' "The teaching objective is not tied to independent reuse."
Assert-Contains $skill 'Interaction closure' "The interaction-closure rule is missing."
Assert-Contains $skill 'resume the original flow' "Post-collection flow resumption is missing."
Assert-Contains $skill 'one short natural-language sentence' "Multi-step progress guidance is missing its natural-language form."
Assert-Contains $skill 'single-turn response must not show a bracketed workflow-state template' "Single-turn replies can still emit the workflow-state template."
Assert-True ($skill -notmatch '\[\u8BBE\u5907\uFF1A') "The workflow-state example was reintroduced into the entrypoint."
Assert-Contains $skill 'Hard-stop precedence' "Physical-danger precedence is missing."
Assert-Contains $skill 'burning smell' "Hard-stop examples are missing."
Assert-True ($skill -notmatch '3/5') "The five-item gate is still presented through a stage-line example."
Assert-Contains $skill 'de-energized' "The de-energized hardware handling rule is missing."
Assert-True ($skill -notmatch 'CPU cooling type, GPU original-cooler') "The main route still asks both CPU and GPU cooling unconditionally."
Assert-Contains $skill 'preference, aesthetic, collection' "The purchase route still treats every purchase as a performance repair."
Assert-Contains $skill 'tuning entry gate' "Mandatory tuning entry gate is missing."
Assert-Contains $skill 'does not waive the gate' "The direct-request bypass prohibition is missing."
Assert-Contains $skill 'coaching branch, not a dead end' "Missing-gate coaching behavior is missing."
Assert-Contains $skill 'collector-workflow\.md' "Collector workflow route is missing."
Assert-Contains $skill 'cross-mode-handoffs\.md' "Cross-mode handoff reference is not linked from the entrypoint."
Assert-Contains $skill '### Telemetry and logs' "Telemetry has no formal shared subflow."
Assert-Contains $skill 'does not require the tuning entry gate' "Telemetry-only analysis is still forced through tuning intake."
Assert-Contains $skill 'collector is Windows-only' "Automatic collector scope is not limited to Windows."
Assert-Contains $skill 'cooling-evidence\.md' "Cooling evidence route is missing."
Assert-Contains $skill 'tuning-modes\.md' "Quick/deep tuning route is missing."
Assert-Contains $skill 'fixed-workloads\.md' "Fixed workload route is missing."
Assert-Contains $skill 'telemetry-analysis\.md' "Telemetry analysis route is missing."
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
    "references/integration/success-and-sensor-semantics.md",
    "references/integration/persistence-and-update-gate.md",
    "references/integration/installation-coexistence.md",
    "references/integration/device-identity.md",
    "references/tuning/expectation-direction.md",
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
    "tests/manual-acceptance-template.md",
    "scripts/analyze-telemetry.ps1"
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
Assert-Contains $gpuCurve 'representative sustained core voltage' "GPU curve guidance does not require a stable voltage sample."
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
Assert-Contains $skill 'Downgrade only when all three hold:' "Advice tiering has no three-condition downgrade gate."
Assert-Contains $skill 'Never downgrade: anti-cheat evasion' "Advice tiering does not hard-stop anti-cheat or concealment cases."
Assert-Contains $skill 'no tool name,\s+no step sequence, and no target value' "Advice tiering allows instructional detail after downgrade."
$quickModePosition = $skill.IndexOf('Quick mode starts with:')
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
Assert-Contains $explanationStyle 'one everyday comparison' "Explanation reference does not define Analogy."
Assert-Contains $explanationStyle 'signals that mean\s+stop, and how to recover' "Explanation reference does not define Consequence."
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

$analyzer = Read-RequiredFile `
    -Path (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1") `
    -Label "scripts/analyze-telemetry.ps1"
Assert-Contains $analyzer 'AnalyzerVersion = "1\.1\.6"' "Analyzer behavior changed without an AnalyzerVersion bump."
Assert-Contains $analyzer 'MaxInputMegabytes' "Telemetry analyzer has no large-file safety limit."
Assert-Contains $analyzer 'ConvertTo-MarkdownCell \$result\.FileName' "Telemetry filename is not passed through Markdown sanitization."
Assert-Contains $analyzer 'ConvertTo-MarkdownCell \$warning' "Telemetry warnings are not passed through Markdown sanitization."
Assert-Contains $analyzer 'offline or cloud-placeholder file' "Telemetry analyzer may trigger cloud-file hydration."
Assert-Contains $analyzer 'local-path-safety\.ps1' "Telemetry analyzer does not use the shared local-path helper."
Assert-Contains $analyzer 'Presented FPS 1% low' "Telemetry analyzer omits Presented 1% low FPS."
Assert-Contains $analyzer 'Low-FPS sensor column' "Telemetry analyzer omits all-zero low-FPS warnings."
$pathSafety = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/local-path-safety.ps1") -Raw -Encoding UTF8
$triageChecklist = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/triage/triage-checklist.md") -Raw -Encoding UTF8
$telemetryAnalysis = $telemetry
Assert-Contains $triageChecklist 'Everyday slowdown or intermittent stutter' "Everyday performance triage is missing."
Assert-Contains $triageChecklist 'Kernel-Power 41' "Windows crash evidence guidance is missing."
Assert-Contains $triageChecklist 'Peripheral or network scope boundary' "Peripheral and network handoff guidance is missing."
Assert-Contains $triageChecklist 'Laptop battery or power-adapter issue' "Laptop battery and adapter triage is missing."
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

$identityHelper = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/device-identity.ps1") -Raw -Encoding UTF8
Assert-Contains $identityHelper 'function Get-DeviceIdentityAssessment' "The identity assessment helper is missing."
Assert-Contains $identityHelper 'function ConvertTo-DeviceIdentityDisplay' "The identity display sanitizer is missing."
Assert-Contains $identityHelper 'function ConvertTo-DeviceIdentityMarkdown' "The Markdown identity sanitizer is missing."
Assert-Contains $identityHelper 'function ConvertTo-SafeMarkdownText' "The generic hardware Markdown sanitizer is missing."
Assert-Contains $identityHelper 'function Get-RedactedInventoryData' "The synthetic-testable inventory redaction helper is missing."
Assert-Contains $identityHelper 'function Test-GenericVolumeLabel' "The generic volume-label allowlist is missing."
Assert-Contains $identityHelper 'function Test-GenericDisplayModel' "The generic display-model allowlist is missing."
Assert-True ($identityHelper -notmatch '\$copy\.Slot\s*=\s*"Memory module') "Redaction replaces structural memory slot evidence."
Assert-Contains $identityHelper 'function ConvertTo-DeviceIdentitySessionStatus' "The collector-quality to session-status mapping is missing."
Assert-Contains $identityHelper 'possible mojibake' "The identity helper does not detect probable mojibake."

$collectorScript = Get-Content -LiteralPath (Join-Path $resolvedRoot "scripts/collect-windows.ps1") -Raw -Encoding UTF8
Assert-Contains $collectorScript 'IdentityQuality = \$identityAssessment' "The collector snapshot does not expose IdentityQuality."
Assert-Contains $collectorScript 'CollectorVersion = "1\.0\.1-r18"' "The collector behavior changed without a collector version bump."
Assert-Contains $collectorScript 'ConvertTo-DeviceIdentityMarkdown' "The Markdown renderer does not isolate identity fields safely."
Assert-Contains $collectorScript 'ConvertTo-SafeMarkdownText -Value \(\$details -join' "Hardware-derived detail lines are not passed through the generic Markdown sanitizer."
Assert-Contains $collectorScript 'DriveType = 2 OR DriveType = 3' "CIM volume collection does not match the fixed/removable fallback scope."
Assert-Contains $collectorScript '## Reported physical disks' "The physical-disk heading still claims unverified active status."
Assert-Contains $collectorScript 'Get-RedactedInventoryData' "The collector does not use the tested inventory-redaction helper."
Assert-Contains $collectorScript 'inventory-context\.ps1' "The collector does not load the tested inventory-context helper."
Assert-Contains $collectorScript '\[switch\]\$RequireElevated' "The collector has no explicit user-run elevated mode."
Assert-Contains $collectorScript 'CollectionContext' "The collector does not record its privilege context."
Assert-Contains $collectorScript 'restricted-agent' "The collector does not distinguish a restricted agent process from a normal user process."
Assert-Contains $collectorScript 'nvidia-smi instantaneous sample' "The collector does not label nvidia-smi live values as instantaneous."
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
Assert-Contains $interactionClosure 'resume the original flow' "Interaction closure reference has no resumed-flow rule."
Assert-Contains $interactionClosure 'single-turn response must not show a bracketed workflow-state template' "Single-turn interaction closure still permits a workflow shell."

$crossMode = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/cross-mode-handoffs.md") -Raw -Encoding UTF8
Assert-Contains $crossMode '\| Telemetry \|' "Cross-mode matrix has no Telemetry row."
Assert-Contains $crossMode 'Anything to telemetry' "Cross-mode guidance has no entry into telemetry."
Assert-Contains $crossMode 'Telemetry to triage, tuning, or purchase' "Cross-mode guidance has no telemetry exit rules."
Assert-Contains $crossMode 'does not establish a\s+fault' "Telemetry handoff can be mistaken for diagnosis."
Assert-Contains $crossMode 'resume the same\s+experiment loop' "Telemetry cannot return to the active experiment."

$fixedWorkloads = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/fixed-workloads.md") -Raw -Encoding UTF8
Assert-Contains $fixedWorkloads 'One-screen experiment card' "One-screen experiment card is missing."
Assert-Contains $fixedWorkloads 'Template 1: game or interactive workload' "Game workload template is missing."
Assert-Contains $fixedWorkloads 'Explanation \(depth adapted to the user and risk\)' "The experiment card has no adaptive explanation section."
Assert-Contains $fixedWorkloads 'localized safety notice from SKILL\.md' "The experiment card hard-codes the safety notice language."
Assert-Contains $fixedWorkloads 'depth adapted to the user and risk' "The experiment card does not adapt explanation depth."
Assert-Contains $fixedWorkloads 'Cooling baseline' "The workload record has no cooling baseline."
Assert-Contains $fixedWorkloads 'Noise measurement' "The workload record has no noise-measurement fields."
Assert-Contains $fixedWorkloads 'compact prose by default' "The experiment card is forced even when plain prose is clearer."
Assert-Contains $fixedWorkloads 'A settings card, table, or fenced block is content' "The guidance treats all structured plans as workflow chrome."
Assert-Contains $fixedWorkloads 'Never place a mode label' "Mode labels are still allowed inside the answer or card."
Assert-Contains $fixedWorkloads 'Before -> candidate \(same paragraph\)' "The safety notice is not bound to the candidate paragraph."
Assert-True ($fixedWorkloads -notmatch 'Mode:\s*quick\s*/\s*deep') "The experiment-card template reintroduced a mode field."

$success = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/integration/success-and-sensor-semantics.md") -Raw -Encoding UTF8
Assert-Contains $success 'Goal-specific success' "Goal-specific success criteria are missing."
Assert-Contains $success 'Sensor semantics' "Sensor semantics are missing."
Assert-Contains $success 'Noise as evidence' "Noise-specific evidence rules are missing."
Assert-Contains $success '## Promoting a profile to daily use' "Profile promotion guidance is missing its section heading."

$componentPlaybooks = Get-Content -LiteralPath (Join-Path $resolvedRoot "references/tuning/component-playbooks.md") -Raw -Encoding UTF8
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
Assert-Contains $scenarioDoc 'no larger than 17 KB' "Interaction scenario budget does not match the 17 KB entrypoint budget."
Assert-Contains $scenarioDoc 'no larger than 31 KB' "Interaction scenario budget does not match the 31 KB quick-mode budget."
Assert-Contains $scenarioDoc 'Manual behavioral acceptance scenarios' "Interaction scenarios are still presented as automated behavior tests."
Assert-Contains $scenarioDoc 'do not prove that every scenario behaves' "Interaction scenarios overstate static test coverage."

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
Assert-Contains $manualAcceptance 'For the 1\.4\.3 tone layer' "Manual acceptance still points at the previous tone-layer version."

$auditTest = Join-Path $resolvedRoot "tests/run-telemetry-audit-tests.ps1"
if (-not (Test-Path -LiteralPath $auditTest -PathType Leaf)) {
    $failures.Add("The packaged telemetry audit regression is missing.")
}

$skillBytes = (Get-Item -LiteralPath $skillPath).Length
if ($skillBytes -gt 17408) {
    $failures.Add("SKILL.md exceeds the 17 KB entrypoint budget: $skillBytes bytes.")
}

$quickFiles = @(
    "SKILL.md",
    "references/integration/tuning-modes.md",
    "references/tuning/component-playbooks.md",
    "references/integration/fixed-workloads.md"
)
$quickBytes = 0
foreach ($relative in $quickFiles) {
    $quickBytes += (Get-Item -LiteralPath (Join-Path $resolvedRoot $relative)).Length
}
if ($quickBytes -gt 31744) {
    $failures.Add("Quick-mode initial load exceeds the 31 KB budget: $quickBytes bytes.")
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
