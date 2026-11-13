[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message) | Out-Null
    }
}

function Assert-Contains {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) {
        $failures.Add($Message) | Out-Null
    }
}

$skill = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "SKILL.md") -Encoding UTF8
$mechanism = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/tuning/vram-and-memory-bus.md") -Encoding UTF8
$playbook = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/tuning/gpu-memory-playbook.md") -Encoding UTF8
$intake = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/tuning/intake.md") -Encoding UTF8
$analyzer = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/analyze-telemetry.ps1") -Encoding UTF8
$lhm = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/lhm/lhm-functions.ps1") -Encoding UTF8

Assert-Contains $skill 'vram-and-memory-bus\.md' "SKILL.md does not route VRAM mechanism questions."
Assert-Contains $skill 'gpu-memory-playbook\.md' "SKILL.md does not route VRAM tuning."
Assert-Contains $playbook 'one next action' "GPU memory playbook does not keep user-facing output concise."

Assert-Contains $intake 'Concept explanation' "Intake has no concept-only memory tier."
Assert-Contains $intake 'Official theoretical bandwidth' "Intake cannot answer source-backed theoretical bandwidth."
Assert-Contains $intake 'Local sensor interpretation' "Intake has no local memory-reading tier."
Assert-Contains $intake 'Memory tuning or stable-range claim' "Intake has no tuning/stability tier."

Assert-Contains $mechanism 'theoretical peak GB/s = data rate Gb/s per pin x bus width bits / 8' "VRAM bandwidth formula is missing."
Assert-Contains $mechanism '28 Gb/s per pin x 256 bit / 8 = 896 GB/s' "RTX 5090 Laptop bandwidth example is missing."
Assert-Contains $mechanism 'GDDR6X uses PAM4' "GDDR6X signalling boundary is missing."
Assert-Contains $mechanism 'GDDR7 uses PAM3' "GDDR7 signalling boundary is missing."
Assert-Contains $mechanism '14001 MHz' "The high LHM memory-clock example is missing."
Assert-Contains $mechanism 'does not\s+establish 14\.001 GHz physical DRAM clock or 14\.001 Gb/s per pin' "The 14001 MHz basis warning is incomplete."
Assert-Contains $mechanism 'Infinity\s+Cache bandwidth is a separate cache metric' "AMD cache and DRAM bandwidth are conflated."

Assert-Contains $playbook 'one next action or one smallest missing question' "The user-facing memory response contract is missing."
Assert-Contains $playbook 'Do not dump every gate field' "The playbook permits questionnaire dumps."
Assert-Contains $playbook 'Do not provide a universal MHz offset' "The playbook permits a universal memory offset."
Assert-Contains $playbook 'No artifacts alone is not a pass' "Artifact-free running is incorrectly treated as stability."

Assert-Contains $analyzer 'can be valid on GDDR7' "The high memory-clock warning still implies GDDR7 is invalid."
Assert-True ($analyzer -notmatch 'exceeded the common GDDR6/GDDR6X clock range') "The old anomaly-only memory-clock warning remains."
Assert-Contains $lhm '\$clockBasis = if' "LHM memory clocks have no clock-basis field."
Assert-Contains $lhm 'sourceName = \$sourceName' "LHM sensors do not retain their source name."
Assert-Contains $lhm 'clockBasis = \$clockBasis' "LHM sensors do not emit clockBasis."

$calculator = Join-Path $resolvedRoot "scripts/calculate-vram-bandwidth.ps1"
$cases = @(
    @{ Gbps = 28; Bits = 256; Expected = 896.0 },
    @{ Gbps = 20; Bits = 256; Expected = 640.0 },
    @{ Gbps = 28; Bits = 512; Expected = 1792.0 }
)
foreach ($case in $cases) {
    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $calculator `
        -DataRateGbps $case.Gbps `
        -BusWidthBits $case.Bits
    if ($LASTEXITCODE -ne 0) {
        $failures.Add("VRAM bandwidth calculator failed for $($case.Gbps) Gb/s x $($case.Bits)-bit.") | Out-Null
        continue
    }
    try {
        $result = $output | ConvertFrom-Json
    }
    catch {
        $failures.Add("VRAM bandwidth calculator did not emit JSON.") | Out-Null
        continue
    }
    Assert-True (
        [Math]::Abs([double]$result.TheoreticalPeakGBs - [double]$case.Expected) -lt 0.000001
    ) "VRAM bandwidth calculator result is wrong for $($case.Gbps) Gb/s x $($case.Bits)-bit."
    Assert-True ($result.ResultKind -eq "theoretical-source-specification") "VRAM bandwidth calculator mislabels theoretical bandwidth."
}

$invalidRejected = $false
try {
    & $powershell -NoProfile -ExecutionPolicy Bypass -File $calculator `
        -DataRateGbps 28 `
        -BusWidthBits 0 2>$null | Out-Null
    $invalidRejected = $LASTEXITCODE -ne 0
}
catch {
    $invalidRejected = $true
}
Assert-True $invalidRejected "VRAM bandwidth calculator accepted an invalid bus width."

if ($failures.Count -gt 0) {
    Write-Host "VRAM knowledge tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "VRAM knowledge tests: PASS" -ForegroundColor Green
