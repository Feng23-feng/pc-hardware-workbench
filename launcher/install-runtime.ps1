param(
    [string]$SourceDirectory = "",
    [string]$TargetDirectory = "",
    [string]$LocalRoot = "",
    [string]$BackupRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot

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

function Assert-NoReparsePointInPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    foreach ($segment in ($fullPath.Substring($root.Length) -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Backup path cannot traverse a reparse point: $current"
        }
    }
}

function Stop-PointedRuntime {
    param(
        [string]$RuntimePath,
        [string]$LocalRoot
    )

    if (
        [string]::IsNullOrWhiteSpace($RuntimePath) -or
        -not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)
    ) {
        return
    }
    $infoPath = Join-Path $LocalRoot "runtime-dsh-web\server-info.json"
    if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) {
        return
    }
    try {
        $info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
        $port = [int]$info.port
        if ($port -le 0) {
            return
        }
        $health = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$port/api/health" `
            -TimeoutSec 5
        if (-not $health.ok) {
            return
        }
    }
    catch {
        return
    }
    $process = Start-Process `
        -FilePath $RuntimePath `
        -ArgumentList @("--stop", "--silent") `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "The previous SkillDock Runtime could not be stopped: $RuntimePath"
    }
}

if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    if (
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot "SkillDock.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot "app\package.json") -PathType Leaf)
    ) {
        $SourceDirectory = $PSScriptRoot
    }
    else {
        $SourceDirectory = Join-Path $RepositoryRoot "dist\SkillDock-DSH"
    }
}
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
$PackageJsonPath = Join-Path $SourceDirectory "app\package.json"
if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory "SkillDock.exe") -PathType Leaf)) {
    throw "Source package does not contain SkillDock.exe: $SourceDirectory"
}
if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
    throw "Source package does not contain app/package.json: $SourceDirectory"
}
$PackageJson = Get-Content -Raw -LiteralPath $PackageJsonPath | ConvertFrom-Json
$PackageVersion = [string]$PackageJson.version

if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    $LocalRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
}
$LocalRoot = [IO.Path]::GetFullPath($LocalRoot).TrimEnd('\')

if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
    $SafeVersion = $PackageVersion -replace '[^A-Za-z0-9._-]', '-'
    $TargetDirectory = Join-Path $LocalRoot (
        "Runtime-$SafeVersion-" + (Get-Date -Format "yyyyMMddHHmmss")
    )
}
$TargetDirectory = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
if (
    -not $TargetDirectory.StartsWith(
        $LocalRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "TargetDirectory must stay inside LocalRoot"
}
if (Test-Path -LiteralPath $TargetDirectory) {
    throw "TargetDirectory already exists: $TargetDirectory"
}

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\runtime"
}
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
if (
    $BackupRoot.Equals($LocalRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $BackupRoot.StartsWith(
        $LocalRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "BackupRoot must stay outside the active LocalRoot"
}
Assert-NoReparsePointInPath -Path $BackupRoot

$PointerPath = Join-Path $LocalRoot "runtime-location.json"
$PreviousRuntimePath = ""
if (Test-Path -LiteralPath $PointerPath -PathType Leaf) {
    try {
        $PreviousPointer = Get-Content -Raw -LiteralPath $PointerPath | ConvertFrom-Json
        $PreviousRuntimePath = [string]$PreviousPointer.runtime_path
    }
    catch {
        throw "Existing runtime-location.json cannot be read: $PointerPath"
    }
}

New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
$RuntimeEntries = @(
    "SkillDock.exe",
    "app",
    "node",
    "Stop SkillDock.cmd",
    "Uninstall SkillDock.ps1",
    "Uninstall PCHW Skill.ps1",
    "skill-tree-identity.ps1",
    "RC-MANIFEST.json"
)
$CopiedRuntimeEntry = $false
foreach ($entry in $RuntimeEntries) {
    $sourceEntry = Join-Path $SourceDirectory $entry
    if (-not (Test-Path -LiteralPath $sourceEntry)) {
        continue
    }
    Copy-Item `
        -LiteralPath $sourceEntry `
        -Destination $TargetDirectory `
        -Recurse `
        -Force
    $CopiedRuntimeEntry = $true
}
if (-not $CopiedRuntimeEntry) {
    throw "Source package has no supported Runtime entries: $SourceDirectory"
}
$LauncherPath = Join-Path $TargetDirectory "SkillDock.exe"
if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "Runtime installation did not produce SkillDock.exe: $TargetDirectory"
}

Stop-PointedRuntime `
    -RuntimePath $PreviousRuntimePath `
    -LocalRoot $LocalRoot

$ActiveRuntimes = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
foreach ($child in @(Get-ChildItem -LiteralPath $LocalRoot -Directory -Force)) {
    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        continue
    }
    if ($child.FullName.Equals($TargetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    if ($child.Name -cmatch '^Runtime(?:-|$)') {
        $ActiveRuntimes.Add($child) | Out-Null
    }
}

New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$MovedBackups = New-Object System.Collections.Generic.List[string]
foreach ($activeRuntime in $ActiveRuntimes) {
    $backupPath = Get-AvailableBackupPath `
        -Root $BackupRoot `
        -PreferredName "$($activeRuntime.Name)-backup-$Stamp"
    Move-Item -LiteralPath $activeRuntime.FullName -Destination $backupPath
    $MovedBackups.Add($backupPath) | Out-Null
    Write-Host "Previous active Runtime moved to backup:"
    Write-Host "  $backupPath"
}

$remainingRuntimes = @(
    Get-ChildItem -LiteralPath $LocalRoot -Directory -Force |
        Where-Object {
            $_.Name -cmatch '^Runtime(?:-|$)' -and
            $_.FullName -ne $TargetDirectory
        }
)
if ($remainingRuntimes.Count -gt 0) {
    throw "Old active Runtime directories remain: $($remainingRuntimes.FullName -join ', ')"
}

[pscustomobject]@{
    runtime_path = $LauncherPath
    version = $PackageVersion
    installed_at = [DateTimeOffset]::Now.ToString("o")
    previous_runtime_path = $PreviousRuntimePath
    backup_root = $BackupRoot
} | ConvertTo-Json | Set-Content -LiteralPath $PointerPath -Encoding UTF8

[pscustomobject]@{
    runtime = $LauncherPath
    pointer = $PointerPath
    version = $PackageVersion
    installed_at = [DateTimeOffset]::Now.ToString("o")
    backup_root = $BackupRoot
    backups = @($MovedBackups)
} | ConvertTo-Json -Depth 4 -Compress
