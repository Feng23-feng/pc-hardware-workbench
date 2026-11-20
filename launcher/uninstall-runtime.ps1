[CmdletBinding()]
param(
    [string]$LocalRoot = "",
    [string]$BackupRoot = "",
    [switch]$PurgeUserData,
    [switch]$PurgeBackups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "runtime-paths.ps1")

function Assert-SafeCleanupRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetPathRoot($resolved).TrimEnd('\')
    $userProfile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')
    $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\')
    if (
        $resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.Equals($userProfile, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.Equals($localAppData, [StringComparison]::OrdinalIgnoreCase)
    ) {
        throw "$Name is too broad for cleanup: $resolved"
    }
    return $resolved
}

function Test-ReparsePath {
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
        if (
            ((Get-Item -LiteralPath $current -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0
        ) {
            return $true
        }
    }
    return $false
}

function Remove-UnreferencedSharedNodeEngines {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $engineRoot = Get-SkillDockEngineRoot -LocalRoot $LocalRoot
    if (-not (Test-Path -LiteralPath $engineRoot -PathType Container)) {
        return [pscustomobject]@{
            removed = @()
            failures = @()
        }
    }
    $referenced = New-Object 'System.Collections.Generic.HashSet[string]'
    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($runtimeRoot in @($LocalRoot, $BackupRoot)) {
        if (-not (Test-Path -LiteralPath $runtimeRoot -PathType Container)) {
            continue
        }
        foreach ($runtimeDirectory in @(
            Get-ChildItem -LiteralPath $runtimeRoot -Directory -Force |
                Where-Object { $_.Name -cmatch '^Runtime(?:-|$)' }
        )) {
            $referencePath = Join-Path `
                $runtimeDirectory.FullName `
                "engine-location.json"
            if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
                continue
            }
            try {
                $reference = Get-Content `
                    -Raw `
                    -LiteralPath $referencePath | ConvertFrom-Json
                $engineId = [string]$reference.engine_id
                if (
                    [string]$reference.schema_version -ne "1.0" -or
                    [string]::IsNullOrWhiteSpace($engineId)
                ) {
                    throw "Malformed shared Node engine reference."
                }
                [void]$referenced.Add($engineId)
            }
            catch {
                $failures.Add([pscustomobject]@{
                    path = $referencePath
                    error = [string]$_.Exception.Message
                }) | Out-Null
            }
        }
    }
    if ($failures.Count -gt 0) {
        return [pscustomobject]@{
            removed = @()
            failures = @($failures.ToArray())
        }
    }

    $removed = New-Object System.Collections.Generic.List[string]
    foreach ($engineDirectory in @(
        Get-ChildItem -LiteralPath $engineRoot -Directory -Force |
            Where-Object {
                $_.Name -cmatch
                    '^node-\d+\.\d+\.\d+-[0-9a-f]{16}$'
            }
    )) {
        if (
            (($engineDirectory.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $referenced.Contains($engineDirectory.Name)
        ) {
            continue
        }
        try {
            $fullPath = [IO.Path]::GetFullPath(
                $engineDirectory.FullName
            ).TrimEnd('\')
            if (
                [IO.Path]::GetDirectoryName($fullPath).TrimEnd('\') -ne
                    $engineRoot
            ) {
                throw "Refusing to remove an unsafe engine path: $fullPath"
            }
            Remove-Item -LiteralPath $fullPath -Recurse -Force
            $removed.Add($fullPath) | Out-Null
        }
        catch {
            $failures.Add([pscustomobject]@{
                path = $engineDirectory.FullName
                error = [string]$_.Exception.Message
            }) | Out-Null
        }
    }
    if (
        (Test-Path -LiteralPath $engineRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $engineRoot -Force).Count -eq 0
    ) {
        Remove-Item -LiteralPath $engineRoot -Force
    }
    return [pscustomobject]@{
        removed = @($removed.ToArray())
        failures = @($failures.ToArray())
    }
}

if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    $LocalRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\runtime"
}
$LocalRoot = Assert-SafeCleanupRoot -Path $LocalRoot -Name "LocalRoot"
$BackupRoot = Assert-SafeCleanupRoot -Path $BackupRoot -Name "BackupRoot"
if ($BackupRoot.Equals($LocalRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "BackupRoot and LocalRoot must be different."
}
if (Test-ReparsePath -Path $LocalRoot) {
    throw "LocalRoot cannot traverse a reparse point."
}
if ($PurgeBackups -and (Test-ReparsePath -Path $BackupRoot)) {
    throw "BackupRoot cannot traverse a reparse point."
}

$PointerPath = Join-Path $LocalRoot "runtime-location.json"
$StoppedRuntime = ""
if (Test-Path -LiteralPath $PointerPath -PathType Leaf) {
    try {
        $pointer = Get-Content -Raw -LiteralPath $PointerPath | ConvertFrom-Json
        $runtimePath = [string]$pointer.runtime_path
        if (Test-Path -LiteralPath $runtimePath -PathType Leaf) {
            $previousLocalRoot = $env:SKILLDOCK_LOCAL_ROOT
            try {
                $env:SKILLDOCK_LOCAL_ROOT = $LocalRoot
                $process = Start-Process `
                    -FilePath $runtimePath `
                    -ArgumentList @("--stop", "--silent") `
                    -WindowStyle Hidden `
                    -Wait `
                    -PassThru
            }
            finally {
                $env:SKILLDOCK_LOCAL_ROOT = $previousLocalRoot
            }
            if ($process.ExitCode -ne 0) {
                throw "Pointed Runtime did not stop cleanly: $runtimePath"
            }
            $StoppedRuntime = $runtimePath
        }
    }
    catch {
        throw "Cannot stop the pointed Runtime: $($_.Exception.Message)"
    }
}

$RemovedRuntimeDirectories = 0
if (Test-Path -LiteralPath $LocalRoot -PathType Container) {
    foreach ($child in @(Get-ChildItem -LiteralPath $LocalRoot -Directory -Force)) {
        if (
            $child.Name -cmatch '^Runtime(?:-|$)' -and
            (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)
        ) {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force
            $RemovedRuntimeDirectories += 1
        }
    }
}
if (Test-Path -LiteralPath $PointerPath) {
    Remove-Item -LiteralPath $PointerPath -Force
}

if ($PurgeUserData) {
    foreach ($runtimeDataRoot in @(
        Get-SkillDockRuntimeDirectoryCandidates -LocalRoot $LocalRoot
    )) {
        if (Test-Path -LiteralPath $runtimeDataRoot) {
            Remove-Item -LiteralPath $runtimeDataRoot -Recurse -Force
        }
    }
    foreach ($name in @(
        "launcher.log",
        "launch-failure.json",
        "launch-result.json"
    )) {
        $target = Join-Path $LocalRoot $name
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
    $installLogs = Join-Path $LocalRoot "install-logs"
    if (Test-Path -LiteralPath $installLogs) {
        Remove-Item -LiteralPath $installLogs -Recurse -Force
    }
    if (Test-Path -LiteralPath $LocalRoot -PathType Container) {
        foreach ($migrationDirectory in @(
            Get-ChildItem -LiteralPath $LocalRoot -Directory -Force |
                Where-Object {
                    $_.Name -match
                        '^\.runtime-pchw-(?:migrating|replaced)-[0-9a-f]{32}$'
                }
        )) {
            Remove-Item -LiteralPath $migrationDirectory.FullName `
                -Recurse -Force
        }
    }
}

if ($PurgeBackups -and (Test-Path -LiteralPath $BackupRoot)) {
    Remove-Item -LiteralPath $BackupRoot -Recurse -Force
}

$EngineCleanup = [pscustomobject]@{
    removed = @()
    failures = @()
}
if ($PurgeUserData -or $PurgeBackups) {
    $EngineCleanup = Remove-UnreferencedSharedNodeEngines `
        -LocalRoot $LocalRoot `
        -BackupRoot $BackupRoot
}

if (
    $PurgeUserData -and
    (Test-Path -LiteralPath $LocalRoot -PathType Container) -and
    @(Get-ChildItem -LiteralPath $LocalRoot -Force).Count -eq 0
) {
    Remove-Item -LiteralPath $LocalRoot -Force
}

[pscustomobject]@{
    ok = $true
    local_root = $LocalRoot
    backup_root = $BackupRoot
    stopped_runtime = $StoppedRuntime
    removed_runtime_directories = $RemovedRuntimeDirectories
    removed_shared_engines = @($EngineCleanup.removed)
    shared_engine_cleanup_failures = @($EngineCleanup.failures)
    purged_user_data = [bool]$PurgeUserData
    purged_backups = [bool]$PurgeBackups
} | ConvertTo-Json -Compress
