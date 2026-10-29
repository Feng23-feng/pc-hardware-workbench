[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    # Copy the canonical Skill scripts into portable/scripts before reporting.
    # The direction is intentionally one-way. Portable-only scripts are never
    # deleted automatically and remain a manual review item.
    [switch]$Fix
)

$ErrorActionPreference = "Stop"
if ($Fix -and ($env:CI -match '^(?i:true|1)$' -or $env:GITHUB_ACTIONS -match '^(?i:true|1)$')) {
    throw "-Fix is disabled in CI. Run the check without -Fix and commit the intended synchronization."
}
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$skillScripts = Join-Path $RepositoryRoot "skill\pc-hardware-workbench\scripts"
$portableScripts = Join-Path $RepositoryRoot "portable\scripts"

if (-not (Test-Path -LiteralPath $skillScripts -PathType Container)) {
    throw "Skill scripts directory not found: $skillScripts"
}
if (-not (Test-Path -LiteralPath $portableScripts -PathType Container)) {
    throw "Portable scripts directory not found: $portableScripts"
}

$skillFiles = @(
    Get-ChildItem -LiteralPath $skillScripts -File |
        Where-Object { $_.Extension -in @(".ps1", ".cs") } |
        Sort-Object Name
)
$portableFiles = @(
    Get-ChildItem -LiteralPath $portableScripts -File |
        Where-Object { $_.Extension -in @(".ps1", ".cs") } |
        Sort-Object Name
)

$skillNames = @($skillFiles | ForEach-Object Name)
$portableNames = @($portableFiles | ForEach-Object Name)
$allNames = @($skillNames + $portableNames | Sort-Object -Unique)
$failures = New-Object System.Collections.Generic.List[string]
$fixed = New-Object System.Collections.Generic.List[string]

foreach ($name in $allNames) {
    $skillPath = Join-Path $skillScripts $name
    $portablePath = Join-Path $portableScripts $name
    if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
        $failures.Add("Portable-only script: $name") | Out-Null
        continue
    }
    if (-not (Test-Path -LiteralPath $portablePath -PathType Leaf)) {
        if ($Fix) {
            Copy-Item -LiteralPath $skillPath -Destination $portablePath -Force
            $fixed.Add($name) | Out-Null
        }
        else {
            $failures.Add("Skill script missing from portable: $name") | Out-Null
        }
        continue
    }

    $skillHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $skillPath).Hash
    $portableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $portablePath).Hash
    if ($skillHash -ne $portableHash) {
        if ($Fix) {
            Copy-Item -LiteralPath $skillPath -Destination $portablePath -Force
            $fixed.Add($name) | Out-Null
        }
        else {
            $failures.Add("Hash mismatch: $name") | Out-Null
        }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Portable script sync: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

if ($fixed.Count -gt 0) {
    Write-Host "Portable script sync: FIXED ($($fixed.Count) files)" -ForegroundColor Yellow
    foreach ($name in $fixed) {
        Write-Host "- $name" -ForegroundColor Yellow
    }
}
Write-Host "Portable script sync: PASS ($($allNames.Count) shared files)" -ForegroundColor Green
