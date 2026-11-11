[CmdletBinding()]
param(
    [string]$Destination = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$packageRoot = $PSScriptRoot
$skillSource = Join-Path $packageRoot "pc-hardware-workbench"

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
}
$Destination = [System.IO.Path]::GetFullPath($Destination)

if (-not (Test-Path -LiteralPath (Join-Path $skillSource "SKILL.md") -PathType Leaf)) {
    throw "The packaged Skill tree is missing or incomplete: $skillSource"
}

$backupPath = ""
if (Test-Path -LiteralPath $Destination) {
    $destinationParent = Split-Path -Parent $Destination
    $destinationName = Split-Path -Leaf $Destination
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = Join-Path $destinationParent "$destinationName.backup-$stamp"
    Move-Item -LiteralPath $Destination -Destination $backupPath
    Write-Host "Existing installation moved to:"
    Write-Host "  $backupPath"
}

$destinationParent = Split-Path -Parent $Destination
New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
Copy-Item -LiteralPath $skillSource -Destination $Destination -Recurse

$requiredPaths = @(
    (Join-Path $Destination "SKILL.md"),
    (Join-Path $Destination "scripts"),
    (Join-Path $Destination "references")
)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Installed Skill is incomplete; missing: $requiredPath"
    }
}

Write-Host ""
Write-Host "Installed PC Hardware Workbench:"
Write-Host "  $Destination"
if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
    Write-Host "Rollback backup:"
    Write-Host "  $backupPath"
}
Write-Host ""
Write-Host "Restart Codex if the Skill does not appear, then invoke:"
Write-Host "  `$pc-hardware-workbench"
