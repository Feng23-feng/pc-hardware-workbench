[CmdletBinding()]
param(
    [string]$SkillsRoot = (
        Join-Path $env:USERPROFILE ".codex\skills"
    ),

    [switch]$PurgeBackups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-tree-identity.ps1")

$resolvedSkillsRoot = [IO.Path]::GetFullPath($SkillsRoot).TrimEnd("\")
$target = Join-Path $resolvedSkillsRoot "pc-hardware-workbench"
$backupRoot = Join-Path $resolvedSkillsRoot ".skilldock-backups"
$removedBackupPath = $null

if (Test-Path -LiteralPath $target) {
    $installInfoPath = Join-Path $target "INSTALL-INFO.json"
    if (-not (Test-Path -LiteralPath $installInfoPath -PathType Leaf)) {
        throw "PCHW Skill is not marked as an RC install. Refusing to remove it."
    }
    $installInfo = Get-Content -Raw -LiteralPath $installInfoPath |
        ConvertFrom-Json
    $identity = Get-SkillTreeIdentity -Root $target
    if (
        $identity.tree_sha256 -ne [string]$installInfo.tree_sha256 -or
        $identity.tree_file_count -ne [int]$installInfo.tree_file_count
    ) {
        throw "PCHW Skill changed after installation. Refusing to remove it."
    }

    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupPath = Join-Path $backupRoot (
        "pc-hardware-workbench-uninstalled-" +
        (Get-Date -Format "yyyyMMdd-HHmmss") +
        "-" +
        [guid]::NewGuid().ToString("N").Substring(0, 8)
    )
    Move-Item -LiteralPath $target -Destination $backupPath
    $removedBackupPath = $backupPath
}

if ($PurgeBackups -and (Test-Path -LiteralPath $backupRoot)) {
    Remove-Item -LiteralPath $backupRoot -Recurse -Force
}

[pscustomobject]@{
    ok = $true
    skills_root = $resolvedSkillsRoot
    active_skill_removed = -not (Test-Path -LiteralPath $target)
    backup_root = $backupRoot
    moved_to_backup = $removedBackupPath
    purged_backups = [bool]$PurgeBackups
} | ConvertTo-Json -Compress
