[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RendererPath,

    [Parameter(Mandatory = $true)]
    [string]$ProfilePath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

$resolvedRenderer = (Resolve-Path -LiteralPath $RendererPath).Path
$resolvedProfile = (Resolve-Path -LiteralPath $ProfilePath).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-memory-$([guid]::NewGuid().ToString('N'))"
$profileId = "nvidia-rtx-5070-ti-laptop-gddr7-hwinfo-afterburner-v1"
    $rawToolIdentity = "HWiNFO64 8.54-6090"
    $displayToolIdentity = "MSI Afterburner 4.6.6.16757"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $profiles = Get-Content -Raw -LiteralPath $resolvedProfile -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($profiles.schema_version -eq "1.0") "Memory profile schema version is missing."
    $selectedProfile = @($profiles.profiles | Where-Object { $_.id -eq $profileId }) |
        Select-Object -First 1
    Assert-True ($null -ne $selectedProfile) "Verified memory profile is missing."
    Assert-True (
        $selectedProfile.display_multiplier -eq 8 -and
        $selectedProfile.data_rate_multiplier -eq 16 -and
        $selectedProfile.bus_width_bits -eq 192
    ) "Verified memory profile has the wrong crosswalk values."
    Assert-True (
        $selectedProfile.constraints.exact_gpu_required -eq $true -and
        $selectedProfile.constraints.cross_generation_allowed -eq $false
    ) "Memory profile is not fail-closed by exact device."

    $csvPath = Join-Path $tempRoot "memory.csv"
    [IO.File]::WriteAllText($csvPath, @'
"Date","Time","显存频率 [MHz]","显存结温 [℃]"
"2026-11-03","12:00:00","1750","46"
"2026-11-03","12:00:01","1750","56"
"2026-11-03","12:00:02","1750","68"
'@, $utf8)
    $svgPath = Join-Path $tempRoot "memory.svg"
    $writtenPath = & $resolvedRenderer `
        -Path $csvPath `
        -OutputPath $svgPath `
        -ProfilePath $resolvedProfile `
        -ProfileId $profileId `
        -GpuIdentity "RTX 5070 Ti Laptop" `
        -RawToolIdentity $rawToolIdentity `
        -DisplayToolIdentity $displayToolIdentity `
        -Title "Memory basis fixture"
    Assert-True ($writtenPath -eq $svgPath) "Memory renderer did not report the SVG path."
    Assert-True (Test-Path -LiteralPath $svgPath -PathType Leaf) "Memory renderer did not create the SVG."
    $svg = Get-Content -Raw -LiteralPath $svgPath -Encoding UTF8
    Assert-True ($svg.Contains("1750.0 MHz")) "Raw memory clock is missing."
    Assert-True ($svg.Contains("14000.0 MHz")) "Tool-equivalent memory clock is missing."
    Assert-True ($svg.Contains("28.000 Gb/s")) "Per-pin data rate is missing."
    Assert-True ($svg.Contains("672.0 GB/s")) "Theoretical bandwidth is missing."
    Assert-True ($svg.Contains($profileId)) "Profile identity is missing."
    Assert-True ($svg.Contains($rawToolIdentity)) "Raw tool identity is missing from the chart."
    Assert-True ($svg.Contains($displayToolIdentity)) "Display tool identity is missing from the chart."
    Assert-True ($svg.Contains('data-profile-status="verified-local"')) "Verified profile status is missing from the chart."
    Assert-True ($svg.Contains("raw clock basis: unknown")) "Raw clock basis is missing."
    Assert-True (-not ($svg -match "NaN|Infinity")) "Memory SVG contains a non-finite value."

    $existingHash = (Get-FileHash -LiteralPath $svgPath -Algorithm SHA256).Hash
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $csvPath `
            -OutputPath $svgPath `
            -ProfilePath $resolvedProfile `
            -ProfileId $profileId `
            -GpuIdentity "RTX 5070 Ti Laptop" `
            -RawToolIdentity $rawToolIdentity `
            -DisplayToolIdentity $displayToolIdentity 2>&1 | Out-Null
        $existingExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($existingExitCode -eq 2) "Memory renderer accepted an existing output."
    Assert-True (
        (Get-FileHash -LiteralPath $svgPath -Algorithm SHA256).Hash -eq $existingHash
    ) "Memory renderer modified an existing output."

    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $csvPath `
            -OutputPath (Join-Path $tempRoot "wrong-gpu.svg") `
            -ProfilePath $resolvedProfile `
            -ProfileId $profileId `
            -GpuIdentity "Not NVIDIA GeForce RTX 5070 Ti Laptop GPU clone" `
            -RawToolIdentity $rawToolIdentity `
            -DisplayToolIdentity $displayToolIdentity 2>&1 | Out-Null
        $wrongGpuExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($wrongGpuExitCode -eq 2) "Memory renderer accepted a mismatched GPU profile."

    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $csvPath `
            -OutputPath (Join-Path $tempRoot "wrong-raw-tool.svg") `
            -ProfilePath $resolvedProfile `
            -ProfileId $profileId `
            -GpuIdentity "RTX 5070 Ti Laptop" `
            -RawToolIdentity "HWiNFO64 8.53" `
            -DisplayToolIdentity $displayToolIdentity 2>&1 | Out-Null
        $wrongRawToolExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($wrongRawToolExitCode -eq 2) "Memory renderer accepted a mismatched raw tool identity."

    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $csvPath `
            -OutputPath (Join-Path $tempRoot "wrong-display-tool.svg") `
            -ProfilePath $resolvedProfile `
            -ProfileId $profileId `
            -GpuIdentity "RTX 5070 Ti Laptop" `
            -RawToolIdentity $rawToolIdentity `
            -DisplayToolIdentity "MSI Afterburner 4.6.5" 2>&1 | Out-Null
        $wrongDisplayToolExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($wrongDisplayToolExitCode -eq 2) "Memory renderer accepted a mismatched display tool identity."

    $provisionalProfiles = Get-Content -Raw -LiteralPath $resolvedProfile -Encoding UTF8 |
        ConvertFrom-Json
    $provisionalProfile = @($provisionalProfiles.profiles | Where-Object {
        $_.id -eq $profileId
    }) | Select-Object -First 1
    $provisionalProfile.status = "provisional"
    $provisionalPath = Join-Path $tempRoot "provisional-profile.json"
    [IO.File]::WriteAllText(
        $provisionalPath,
        ($provisionalProfiles | ConvertTo-Json -Depth 20),
        $utf8
    )
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $csvPath `
            -OutputPath (Join-Path $tempRoot "provisional-default.svg") `
            -ProfilePath $provisionalPath `
            -ProfileId $profileId `
            -GpuIdentity "RTX 5070 Ti Laptop" `
            -RawToolIdentity $rawToolIdentity `
            -DisplayToolIdentity $displayToolIdentity 2>&1 | Out-Null
        $provisionalDefaultExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True (
        $provisionalDefaultExitCode -eq 2
    ) "Memory renderer accepted a provisional profile without explicit opt-in."

    $provisionalSvgPath = Join-Path $tempRoot "provisional.svg"
    & $resolvedRenderer `
        -Path $csvPath `
        -OutputPath $provisionalSvgPath `
        -ProfilePath $provisionalPath `
        -ProfileId $profileId `
        -GpuIdentity "RTX 5070 Ti Laptop" `
        -RawToolIdentity $rawToolIdentity `
        -DisplayToolIdentity $displayToolIdentity `
        -AllowProvisional | Out-Null
    $provisionalSvg = Get-Content -Raw -LiteralPath $provisionalSvgPath -Encoding UTF8
    Assert-True (
        $provisionalSvg.Contains('data-profile-status="provisional"')
    ) "Explicitly allowed provisional output is not visibly marked as provisional."

    $missingFieldProfiles = Get-Content -Raw -LiteralPath $resolvedProfile -Encoding UTF8 |
        ConvertFrom-Json
    $missingFieldProfile = @($missingFieldProfiles.profiles | Where-Object {
        $_.id -eq $profileId
    }) | Select-Object -First 1
    $missingFieldProfile.PSObject.Properties.Remove("display_multiplier")
    $missingFieldPath = Join-Path $tempRoot "missing-field-profile.json"
    [IO.File]::WriteAllText(
        $missingFieldPath,
        ($missingFieldProfiles | ConvertTo-Json -Depth 20),
        $utf8
    )
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $csvPath `
            -OutputPath (Join-Path $tempRoot "missing-field.svg") `
            -ProfilePath $missingFieldPath `
            -ProfileId $profileId `
            -GpuIdentity "RTX 5070 Ti Laptop" `
            -RawToolIdentity $rawToolIdentity `
            -DisplayToolIdentity $displayToolIdentity 2>&1 | Out-Null
        $missingFieldExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($missingFieldExitCode -eq 2) "Memory renderer accepted a profile with a missing multiplier."

    $cpuOnly = Join-Path $tempRoot "cpu-only.csv"
    [IO.File]::WriteAllText($cpuOnly, @'
"Date","Time","CPU Package [C]"
"2026-11-03","12:00:00","55"
'@, $utf8)
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
            -Path $cpuOnly `
            -OutputPath (Join-Path $tempRoot "missing-memory.svg") `
            -ProfilePath $resolvedProfile `
            -ProfileId $profileId `
            -GpuIdentity "RTX 5070 Ti Laptop" `
            -RawToolIdentity $rawToolIdentity `
            -DisplayToolIdentity $displayToolIdentity 2>&1 | Out-Null
        $missingExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = "Stop"
    }
    Assert-True ($missingExitCode -eq 2) "Memory renderer accepted input without a memory clock."

    if ($failures.Count -gt 0) {
        Write-Host "Memory basis regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "Memory basis regression: PASS" -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
