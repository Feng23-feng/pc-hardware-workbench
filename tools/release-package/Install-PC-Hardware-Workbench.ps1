[CmdletBinding()]
param(
    [string]$Destination = "",

    [string]$BackupRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AvailableBackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$PreferredName
    )

    $candidate = Join-Path $Root $PreferredName
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }

    $index = 2
    do {
        $candidate = Join-Path $Root "$PreferredName-$index"
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Assert-BackupOutsideSkillScanRoot {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedBackupRoot,
        [Parameter(Mandatory = $true)][string]$SkillScanRoot
    )

    $comparison = [StringComparison]::OrdinalIgnoreCase
    $scanRoot = $SkillScanRoot.TrimEnd('\')
    $backupRoot = $ResolvedBackupRoot.TrimEnd('\')
    if (
        $backupRoot.Equals($scanRoot, $comparison) -or
        $backupRoot.StartsWith($scanRoot + '\', $comparison)
    ) {
        throw "BackupRoot must be outside the Skill scan root to prevent duplicate Skill discovery: $ResolvedBackupRoot"
    }
}

function Assert-NoReparsePointInPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $segments = $fullPath.Substring($root.Length) -split '[\\/]'
    foreach ($segment in $segments) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "BackupRoot cannot traverse a symbolic link, junction, or other reparse point: $current"
        }
    }
}

function Get-EffectiveSkillScanRoot {
    param([Parameter(Mandatory = $true)][string]$InstallParent)

    $fallback = [System.IO.Path]::GetFullPath($InstallParent).TrimEnd('\')
    $cursor = $fallback
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if ((Split-Path -Leaf $cursor) -ieq "skills") {
            return $cursor
        }
        $parent = Split-Path -Parent $cursor
        if (
            [string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($cursor, [StringComparison]::OrdinalIgnoreCase)
        ) {
            break
        }
        $cursor = $parent
    }
    return $fallback
}

function Move-LegacyInRootBackups {
    param(
        [Parameter(Mandatory = $true)][string]$SkillScanRoot,
        [Parameter(Mandatory = $true)][string]$ActiveDestination,
        [Parameter(Mandatory = $true)][string]$DestinationName,
        [Parameter(Mandatory = $true)][string]$ResolvedBackupRoot
    )

    if (-not (Test-Path -LiteralPath $SkillScanRoot -PathType Container)) {
        return
    }
    $legacyBackups = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
    $queue = New-Object System.Collections.Generic.Queue[System.IO.DirectoryInfo]
    $queue.Enqueue((Get-Item -LiteralPath $SkillScanRoot -Force))
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        try {
            $children = @($current.EnumerateDirectories())
        }
        catch {
            continue
        }
        foreach ($child in $children) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                continue
            }
            $prefix = ([System.IO.Path]::GetFullPath($ActiveDestination).TrimEnd('\')) + '\'
            if ($child.FullName.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            if (
                $child.Name -like "$DestinationName.backup-*" -and
                (Test-Path -LiteralPath (Join-Path $child.FullName "SKILL.md") -PathType Leaf)
            ) {
                $legacyBackups.Add($child) | Out-Null
            }
            else {
                $queue.Enqueue($child)
            }
        }
    }
    foreach ($legacyBackup in $legacyBackups) {
        $legacyTarget = Get-AvailableBackupPath -Root $ResolvedBackupRoot -PreferredName $legacyBackup.Name
        Move-Item -LiteralPath $legacyBackup.FullName -Destination $legacyTarget
        Write-Host "Legacy in-root backup moved outside the Skill scan path:"
        Write-Host "  $legacyTarget"
    }
}

$packageRoot = $PSScriptRoot
$skillSource = Join-Path $packageRoot "pc-hardware-workbench"

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
}
$Destination = [System.IO.Path]::GetFullPath($Destination)
$destinationParent = Split-Path -Parent $Destination
$destinationName = Split-Path -Leaf $Destination

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $HOME ".codex\skill-backups\pc-hardware-workbench"
}
$BackupRoot = [System.IO.Path]::GetFullPath($BackupRoot)
Assert-NoReparsePointInPath -Path $BackupRoot
$skillScanRoot = Get-EffectiveSkillScanRoot -InstallParent $destinationParent
Assert-BackupOutsideSkillScanRoot `
    -ResolvedBackupRoot $BackupRoot `
    -SkillScanRoot $skillScanRoot

if (-not (Test-Path -LiteralPath (Join-Path $skillSource "SKILL.md") -PathType Leaf)) {
    throw "The packaged Skill tree is missing or incomplete: $skillSource"
}

New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
Move-LegacyInRootBackups `
    -SkillScanRoot $skillScanRoot `
    -ActiveDestination $Destination `
    -DestinationName $destinationName `
    -ResolvedBackupRoot $BackupRoot

$backupPath = ""
if (Test-Path -LiteralPath $Destination) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = Get-AvailableBackupPath `
        -Root $BackupRoot `
        -PreferredName "$destinationName-$stamp"
    Move-Item -LiteralPath $Destination -Destination $backupPath
    Write-Host "Existing installation moved to:"
    Write-Host "  $backupPath"
}

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
    Write-Host "Backups are kept outside the Codex Skill scan directory."
}
Write-Host ""
Write-Host "Restart Codex if the Skill does not appear, then invoke:"
Write-Host "  `$pc-hardware-workbench"
