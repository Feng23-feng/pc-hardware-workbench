[CmdletBinding()]
param(
    [string]$SkillsRoot = "",

    [string]$LocalRoot = "",

    [string]$BackupRoot = "",

    [string]$DataBackupRoot = "",

    [switch]$PurgeUserData,

    [switch]$PurgeBackups,

    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-LastJsonObject {
    param([Parameter(Mandatory = $true)][string]$Text)

    foreach ($line in @($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith("{")) {
            continue
        }
        try {
            return $trimmed | ConvertFrom-Json
        }
        catch {
            continue
        }
    }
    return $null
}

function Assert-SafePurgeRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd("\")
    $root = [IO.Path]::GetPathRoot($resolved).TrimEnd("\")
    $userProfile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd("\")
    $localAppData = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd("\")
    if (
        $resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.Equals(
            $userProfile,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $resolved.Equals(
            $localAppData,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "$Name is too broad for cleanup: $resolved"
    }
    return $resolved
}

function Test-PathNestedInAnother {
    param(
        [Parameter(Mandatory = $true)][string]$First,
        [Parameter(Mandatory = $true)][string]$Second
    )

    $firstPath = [IO.Path]::GetFullPath($First).TrimEnd("\")
    $secondPath = [IO.Path]::GetFullPath($Second).TrimEnd("\")
    return (
        $firstPath.StartsWith(
            $secondPath + "\",
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $secondPath.StartsWith(
            $firstPath + "\",
            [StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Invoke-UninstallStep {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "Required uninstall script is missing: $ScriptPath"
    }
    $output = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScriptPath `
            @Arguments 2>&1
    )
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else {
        [int]$LASTEXITCODE
    }
    $text = ($output | Out-String)
    if ($exitCode -ne 0) {
        throw "$Name failed with exit code ${exitCode}:`n$text"
    }
    return [pscustomobject]@{
        name = $Name
        script = $ScriptPath
        output = $text
        result = Get-LastJsonObject -Text $text
    }
}

if ([string]::IsNullOrWhiteSpace($SkillsRoot)) {
    $SkillsRoot = Join-Path $env:USERPROFILE ".codex\skills"
}
if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    $LocalRoot = if ([string]::IsNullOrWhiteSpace(
        $env:SKILLDOCK_LOCAL_ROOT
    )) {
        Join-Path $env:LOCALAPPDATA "SkillDock"
    }
    else {
        $env:SKILLDOCK_LOCAL_ROOT
    }
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\runtime"
}
if ([string]::IsNullOrWhiteSpace($DataBackupRoot)) {
    $DataBackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\data"
}
$SkillsRoot = [IO.Path]::GetFullPath($SkillsRoot).TrimEnd("\")
$LocalRoot = [IO.Path]::GetFullPath($LocalRoot).TrimEnd("\")
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd("\")
$DataBackupRoot = [IO.Path]::GetFullPath($DataBackupRoot).TrimEnd("\")
foreach ($cleanupRoot in @(
    [pscustomobject]@{ Name = "LocalRoot"; Path = $LocalRoot },
    [pscustomobject]@{ Name = "BackupRoot"; Path = $BackupRoot },
    [pscustomobject]@{ Name = "DataBackupRoot"; Path = $DataBackupRoot }
)) {
    Assert-SafePurgeRoot `
        -Path $cleanupRoot.Path `
        -Name $cleanupRoot.Name | Out-Null
}
if (
    $LocalRoot.Equals($BackupRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $LocalRoot.Equals(
        $DataBackupRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
    $BackupRoot.Equals(
        $DataBackupRoot,
        [StringComparison]::OrdinalIgnoreCase
    ) -or
    (Test-PathNestedInAnother -First $LocalRoot -Second $BackupRoot) -or
    (Test-PathNestedInAnother -First $LocalRoot -Second $DataBackupRoot) -or
    (Test-PathNestedInAnother -First $BackupRoot -Second $DataBackupRoot)
) {
    throw "Uninstall cleanup roots must be distinct and non-overlapping."
}

if (
    -not $NonInteractive -and
    -not $PurgeUserData -and
    -not $PurgeBackups
) {
    Write-Host ""
    Write-Host "SkillDock 卸载 / Uninstall"
    Write-Host "  1. 移除程序和 Skill，保留 Task、证据和备份（默认）"
    Write-Host "     Remove programs and Skill; keep Task, evidence, and backups"
    Write-Host "  2. 移除全部本地 SkillDock 数据、导出和备份"
    Write-Host "     Remove all local SkillDock data, exports, and backups"
    Write-Host "  0. 取消 / Cancel"
    $choice = Read-Host "请选择 / Choose [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) {
        $choice = "1"
    }
    if ($choice -eq "0") {
        [pscustomobject]@{
            ok = $false
            status = "cancelled"
            writes_performed = $false
        } | ConvertTo-Json -Compress
        exit 0
    }
    if ($choice -eq "2") {
        $PurgeUserData = $true
        $PurgeBackups = $true
    }
    elseif ($choice -ne "1") {
        throw "无效选择 / Invalid choice: $choice"
    }
}

$pointerPath = Join-Path $LocalRoot "runtime-location.json"
$runtimeRoot = ""
if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
    try {
        $pointer = Get-Content -Raw -LiteralPath $pointerPath |
            ConvertFrom-Json
        $runtimePath = [string]$pointer.runtime_path
        if (-not [string]::IsNullOrWhiteSpace($runtimePath)) {
            $candidate = [IO.Path]::GetFullPath(
                (Split-Path -Parent $runtimePath)
            ).TrimEnd("\")
            if (
                $candidate.StartsWith(
                    $LocalRoot + "\",
                    [StringComparison]::OrdinalIgnoreCase
                ) -and
                (Split-Path -Leaf $candidate) -match '^Runtime(?:-|$)'
            ) {
                $runtimeRoot = $candidate
            }
        }
    }
    catch {
        throw "Cannot read runtime-location.json: $($_.Exception.Message)"
    }
}
if (
    [string]::IsNullOrWhiteSpace($runtimeRoot) -and
    (Test-Path -LiteralPath $LocalRoot -PathType Container)
) {
    $candidate = Get-ChildItem -LiteralPath $LocalRoot -Directory -Force |
        Where-Object { $_.Name -match '^Runtime(?:-|$)' } |
        Where-Object {
            Test-Path -LiteralPath (
                Join-Path $_.FullName "Uninstall SkillDock.ps1"
            ) -PathType Leaf
        } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($candidate) {
        $runtimeRoot = $candidate.FullName
    }
}

$localHelperRoot = $PSScriptRoot
$localSkillUninstaller = Join-Path `
    $localHelperRoot `
    "Uninstall PCHW Skill.ps1"
$localRuntimeUninstaller = Join-Path `
    $localHelperRoot `
    "Uninstall SkillDock.ps1"
$skillBackupRoot = Join-Path $SkillsRoot ".skilldock-backups"

$temporaryRoot = ""
try {
    $skillUninstaller = if ($runtimeRoot) {
        Join-Path $runtimeRoot "Uninstall PCHW Skill.ps1"
    }
    else {
        ""
    }
    $runtimeUninstaller = if ($runtimeRoot) {
        Join-Path $runtimeRoot "Uninstall SkillDock.ps1"
    }
    else {
        ""
    }
    if (
        (
            [string]::IsNullOrWhiteSpace($skillUninstaller) -or
            -not (Test-Path -LiteralPath $skillUninstaller -PathType Leaf)
        ) -and
        (Test-Path -LiteralPath $localSkillUninstaller -PathType Leaf)
    ) {
        $skillUninstaller = $localSkillUninstaller
    }
    if (
        (
            [string]::IsNullOrWhiteSpace($runtimeUninstaller) -or
            -not (Test-Path -LiteralPath $runtimeUninstaller -PathType Leaf)
        ) -and
        (Test-Path -LiteralPath $localRuntimeUninstaller -PathType Leaf)
    ) {
        $runtimeUninstaller = $localRuntimeUninstaller
    }

    if (
        (Test-Path -LiteralPath (Join-Path $SkillsRoot "pc-hardware-workbench")) -and
        (
            [string]::IsNullOrWhiteSpace($skillUninstaller) -or
            -not (Test-Path -LiteralPath $skillUninstaller -PathType Leaf)
        )
    ) {
        if (Test-Path -LiteralPath $localSkillUninstaller -PathType Leaf) {
            $skillUninstaller = $localSkillUninstaller
        }
        else {
            throw (
                "The installed PCHW Skill cannot be removed because its " +
                "uninstall helper is unavailable."
            )
        }
    }

    $steps = New-Object System.Collections.Generic.List[object]
    $hasActiveSkill = Test-Path -LiteralPath (
        Join-Path $SkillsRoot "pc-hardware-workbench"
    )
    $hasSkillBackup = Test-Path -LiteralPath $skillBackupRoot
    if ($hasActiveSkill -or ($PurgeBackups -and $hasSkillBackup)) {
        $skillArguments = @("-SkillsRoot", $SkillsRoot)
        if ($PurgeBackups) {
            $skillArguments += "-PurgeBackups"
        }
        $steps.Add(
            (Invoke-UninstallStep `
                -Name "pchw-skill" `
                -ScriptPath $skillUninstaller `
                -Arguments $skillArguments)
        ) | Out-Null
    }

    if (
        (Test-Path -LiteralPath $pointerPath -PathType Leaf) -or
        ($runtimeRoot -and (
            Test-Path -LiteralPath $runtimeRoot -PathType Container
        )) -or
        ($PurgeBackups -and (Test-Path -LiteralPath $BackupRoot))
    ) {
        if (-not (Test-Path -LiteralPath $runtimeUninstaller -PathType Leaf)) {
            throw (
                "Runtime removal was requested, but the uninstall " +
                "helper is unavailable."
            )
        }
        $runtimeArguments = @(
            "-LocalRoot",
            $LocalRoot,
            "-BackupRoot",
            $BackupRoot
        )
        if ($PurgeUserData) {
            $runtimeArguments += "-PurgeUserData"
        }
        if ($PurgeBackups) {
            $runtimeArguments += "-PurgeBackups"
        }
        $steps.Add(
            (Invoke-UninstallStep `
                -Name "skilldock-runtime" `
                -ScriptPath $runtimeUninstaller `
                -Arguments $runtimeArguments)
        ) | Out-Null
    }

    $removedDataBackupRoot = $false
    if (
        $PurgeBackups -and
        (Test-Path -LiteralPath $DataBackupRoot)
    ) {
        $safeDataBackupRoot = Assert-SafePurgeRoot `
            -Path $DataBackupRoot `
            -Name "DataBackupRoot"
        Remove-Item `
            -LiteralPath $safeDataBackupRoot `
            -Recurse `
            -Force
        $removedDataBackupRoot = $true
    }

    if ($PurgeUserData -or $PurgeBackups) {
        foreach ($helperPath in @(
            (Join-Path $LocalRoot "Uninstall SkillDock.cmd"),
            (Join-Path $LocalRoot "uninstall")
        )) {
            if (Test-Path -LiteralPath $helperPath) {
                Remove-Item -LiteralPath $helperPath -Recurse -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
    if (
        $PurgeUserData -and
        (Test-Path -LiteralPath $LocalRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $LocalRoot -Force).Count -eq 0
    ) {
        Remove-Item -LiteralPath $LocalRoot -Force
    }

    $result = [pscustomobject]@{
        ok = $true
        status = "passed"
        skills_root = $SkillsRoot
        local_root = $LocalRoot
        runtime_root = $runtimeRoot
        purge_user_data = [bool]$PurgeUserData
        purge_backups = [bool]$PurgeBackups
        data_backup_root = $DataBackupRoot
        removed_data_backup_root = $removedDataBackupRoot
        steps = @($steps.ToArray())
    }
    $result | ConvertTo-Json -Depth 10 -Compress
    if (-not $NonInteractive) {
        Write-Host ""
        Write-Host "卸载完成 / Uninstall completed." -ForegroundColor Green
        if (-not $PurgeUserData) {
            Write-Host "Task、证据和备份已保留 / Task, evidence, and backups were kept."
        }
        Read-Host "按 Enter 关闭 / Press Enter to close" | Out-Null
    }
}
finally {
    if (
        -not [string]::IsNullOrWhiteSpace($temporaryRoot) -and
        (Test-Path -LiteralPath $temporaryRoot)
    ) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (
            $resolvedTemporary.StartsWith(
                $tempBase,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item `
                -LiteralPath $resolvedTemporary `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
