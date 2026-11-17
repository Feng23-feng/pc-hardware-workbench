[CmdletBinding()]
param(
    [string]$Destination = "",

    [string]$BackupRoot = "",

    [string]$ArchiveUrl = "https://github.com/Feng23-feng/pc-hardware-workbench/archive/refs/heads/main.zip",

    [string]$SourceDirectory = "",

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

function Get-SafeArchiveSource {
    param([Parameter(Mandatory = $true)][string]$Value)

    $uri = $null
    if ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -in @("http", "https")) {
            $builder = [UriBuilder]::new($uri)
            $builder.UserName = ""
            $builder.Password = ""
            $builder.Query = ""
            $builder.Fragment = ""
            return $builder.Uri.AbsoluteUri
        }
        if ($uri.IsFile) {
            return [IO.Path]::GetFileName($uri.LocalPath)
        }
    }
    return [IO.Path]::GetFileName($Value)
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

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = $sha.ComputeHash($stream)
        return (($bytes | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-SkillTreeIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Skill tree does not exist: $resolvedRoot"
    }
    $paths = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[System.IO.DirectoryInfo]
    $stack.Push((Get-Item -LiteralPath $resolvedRoot -Force))
    while ($stack.Count -gt 0) {
        $directory = $stack.Pop()
        foreach ($entry in @($directory.EnumerateFileSystemInfos())) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Skill tree contains a reparse point: $($entry.FullName)"
            }
            if ($entry -is [System.IO.DirectoryInfo]) {
                $stack.Push($entry)
                continue
            }
            $relativePath = $entry.FullName.Substring(
                $resolvedRoot.Length
            ).TrimStart('\').Replace('\', '/')
            if ($relativePath -ieq "INSTALL-INFO.json") {
                continue
            }
            $paths.Add($relativePath) | Out-Null
        }
    }

    $sortedPaths = $paths.ToArray()
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $manifest = New-Object System.Text.StringBuilder
    foreach ($relativePath in $sortedPaths) {
        $filePath = Join-Path $resolvedRoot $relativePath.Replace('/', '\')
        $fileHash = Get-FileSha256Hex -Path $filePath
        [void]$manifest.Append("$fileHash  $relativePath`n")
    }
    $manifestBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(
        $manifest.ToString()
    )
    $treeSha = [Security.Cryptography.SHA256]::Create()
    try {
        $treeHashBytes = $treeSha.ComputeHash($manifestBytes)
        $treeHash = (($treeHashBytes | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $treeSha.Dispose()
    }
    $runtimePath = Join-Path $resolvedRoot "runtime.mjs"
    $manifestPath = Join-Path $resolvedRoot "workbench.manifest.json"
    $runtimeHash = if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
        Get-FileSha256Hex -Path $runtimePath
    } else {
        $null
    }
    $manifestFileHash = if (
        Test-Path -LiteralPath $manifestPath -PathType Leaf
    ) {
        Get-FileSha256Hex -Path $manifestPath
    } else {
        $null
    }
    return [pscustomobject]@{
        TreeSha256 = $treeHash
        TreeFileCount = $sortedPaths.Count
        RuntimeSha256 = $runtimeHash
        ManifestSha256 = $manifestFileHash
        TreeHashAlgorithm = "sha256-manifest-v1"
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

function Write-InstallInfo {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$SourceArchive
    )

    $manifestPath = Join-Path $Destination "SKILL.md"
    $manifestText = Get-Content -Raw -LiteralPath $manifestPath -Encoding UTF8
    $versionMatch = [regex]::Match($manifestText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
    if (-not $versionMatch.Success) {
        throw "Installed Skill version metadata is missing from: $manifestPath"
    }

    $identity = Get-SkillTreeIdentity -Root $Destination
    $installInfo = [pscustomobject]@{
        Product = "PC Hardware Workbench"
        Version = $versionMatch.Groups[1].Value
        ReleaseLabel = "main"
        GitCommit = $null
        InstalledAt = [datetimeoffset]::Now.ToString("o")
        InstallSource = if ($SourceArchive -like "local-source:*") {
            "local-source"
        } else {
            "source-archive"
        }
        SourceArchive = $SourceArchive
        Installer = "tools/install-skill.ps1"
        TreeSha256 = $identity.TreeSha256
        TreeFileCount = $identity.TreeFileCount
        RuntimeSha256 = $identity.RuntimeSha256
        ManifestSha256 = $identity.ManifestSha256
        TreeHashAlgorithm = $identity.TreeHashAlgorithm
    }
    $json = $installInfo | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        (Join-Path $Destination "INSTALL-INFO.json"),
        $json,
        (New-Object Text.UTF8Encoding($false))
    )
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
$localSkillSource = $null
if (-not [string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $resolvedSourceDirectory = [IO.Path]::GetFullPath(
        $SourceDirectory
    ).TrimEnd('\')
    if (
        (Test-Path -LiteralPath $resolvedSourceDirectory -PathType Leaf) -or
        -not (Test-Path -LiteralPath $resolvedSourceDirectory -PathType Container)
    ) {
        throw "SourceDirectory must be an existing directory: $resolvedSourceDirectory"
    }
    if (Test-Path -LiteralPath (
        Join-Path $resolvedSourceDirectory "SKILL.md"
    ) -PathType Leaf) {
        $localSkillSource = $resolvedSourceDirectory
    }
    else {
        $nestedSkill = Join-Path `
            $resolvedSourceDirectory `
            "skill\pc-hardware-workbench"
        if (Test-Path -LiteralPath $nestedSkill -PathType Container) {
            $localSkillSource = $nestedSkill
        }
    }
    if ([string]::IsNullOrWhiteSpace($localSkillSource)) {
        throw "SourceDirectory does not contain the PC Hardware Workbench Skill: $resolvedSourceDirectory"
    }
    if (
        $Destination.Equals(
            $localSkillSource,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $Destination.StartsWith(
            $localSkillSource.TrimEnd('\') + '\',
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Destination cannot be inside SourceDirectory"
    }
    $safeArchiveSource = "local-source:$(Split-Path -Leaf $localSkillSource)"
}
else {
    $safeArchiveSource = Get-SafeArchiveSource -Value $ArchiveUrl
}

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

    if ($localSkillSource) {
        Write-Host "Installing PC Hardware Workbench from local source:"
        Write-Host "  $localSkillSource"
        $skillSource = $localSkillSource
    }
    else {
        Write-Host "Downloading PC Hardware Workbench from:"
        Write-Host "  $safeArchiveSource"
        Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $archivePath
        Expand-Archive `
            -LiteralPath $archivePath `
            -DestinationPath $expandedPath `
            -Force

        $directSkillSource = Join-Path `
            $expandedPath `
            "skill\pc-hardware-workbench"
        if (Test-Path -LiteralPath $directSkillSource -PathType Container) {
            $skillCandidates = @($directSkillSource)
        }
        else {
            $skillCandidates = @(
                Get-ChildItem -LiteralPath $expandedPath -Directory |
                    ForEach-Object {
                        $candidate = Join-Path `
                            $_.FullName `
                            "skill\pc-hardware-workbench"
                        if (
                            Test-Path `
                                -LiteralPath $candidate `
                                -PathType Container
                        ) {
                            $candidate
                        }
                    }
            )
        }
        if ($skillCandidates.Count -ne 1) {
            throw "Expected one Skill tree in the downloaded archive, found $($skillCandidates.Count)."
        }
        $skillSource = $skillCandidates[0]
    }

    $manifest = Join-Path $skillSource "SKILL.md"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Skill source does not contain SKILL.md: $manifest"
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
    Write-InstallInfo -Destination $Destination -SourceArchive $safeArchiveSource

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
    Write-Host "Install-source details:"
    Write-Host "  $(Join-Path $Destination 'INSTALL-INFO.json')"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
