[CmdletBinding()]
param(
    [string]$Destination = "",

    [string]$BackupRoot = "",

    [string]$ArchiveUrl = "https://github.com/Feng23-feng/pc-hardware-workbench/archive/refs/heads/main.zip",

    [switch]$Force
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

$destinationExists = Test-Path -LiteralPath $Destination
if ($destinationExists -and -not $Force) {
    throw "Destination already exists: $Destination`nRe-run with -Force to install and keep an automatic backup."
}

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "pc-hardware-workbench-install-" + [guid]::NewGuid().ToString("N")
)
$archivePath = Join-Path $temporaryRoot "source.zip"
$expandedPath = Join-Path $temporaryRoot "expanded"

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $expandedPath -Force | Out-Null

    Write-Host "Downloading PC Hardware Workbench from:"
    Write-Host "  $ArchiveUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedPath -Force

    $directSkillSource = Join-Path $expandedPath "skill\pc-hardware-workbench"
    if (Test-Path -LiteralPath $directSkillSource -PathType Container) {
        $skillCandidates = @($directSkillSource)
    }
    else {
        $skillCandidates = @(
            Get-ChildItem -LiteralPath $expandedPath -Directory |
                ForEach-Object {
                    $candidate = Join-Path $_.FullName "skill\pc-hardware-workbench"
                    if (Test-Path -LiteralPath $candidate -PathType Container) {
                        $candidate
                    }
                }
        )
    }
    if ($skillCandidates.Count -ne 1) {
        throw "Expected one Skill tree in the downloaded archive, found $($skillCandidates.Count)."
    }

    $skillSource = $skillCandidates[0]
    $manifest = Join-Path $skillSource "SKILL.md"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Downloaded archive does not contain skill\pc-hardware-workbench\SKILL.md."
    }

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    Move-LegacyInRootBackups `
        -SkillScanRoot $skillScanRoot `
        -ActiveDestination $Destination `
        -DestinationName $destinationName `
        -ResolvedBackupRoot $BackupRoot

    $backupPath = ""
    if ($destinationExists) {
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
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
