[CmdletBinding()]
param(
    [string]$SourceDirectory = "",

    [string]$SkillsRoot = (
        Join-Path $env:USERPROFILE ".codex\skills"
    ),

    [switch]$ReplaceExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-tree-identity.ps1")

if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path `
        $PSScriptRoot `
        "skills\pc-hardware-workbench"
}
$resolvedSource = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd("\")
$resolvedSkillsRoot = [IO.Path]::GetFullPath($SkillsRoot).TrimEnd("\")
$target = Join-Path $resolvedSkillsRoot "pc-hardware-workbench"

if (-not (Test-Path -LiteralPath (Join-Path $resolvedSource "SKILL.md"))) {
    throw "PCHW Skill source is incomplete: $resolvedSource"
}
if (
    -not (Test-Path -LiteralPath $resolvedSkillsRoot -PathType Container) -and
    (Test-Path -LiteralPath $resolvedSkillsRoot)
) {
    throw "SkillsRoot is not a directory: $resolvedSkillsRoot"
}

$releaseManifestPath = Join-Path $PSScriptRoot "RC-MANIFEST.json"
if (-not (Test-Path -LiteralPath $releaseManifestPath -PathType Leaf)) {
    throw "RC-MANIFEST.json is missing beside the installer."
}
$releaseManifest = Get-Content -Raw -LiteralPath $releaseManifestPath |
    ConvertFrom-Json
$expectedHash = [string]$releaseManifest.pchw_skill.tree_sha256
$expectedCount = [int]$releaseManifest.pchw_skill.tree_file_count
$sourceIdentity = Get-SkillTreeIdentity -Root $resolvedSource
if (
    $sourceIdentity.tree_sha256 -ne $expectedHash -or
    $sourceIdentity.tree_file_count -ne $expectedCount
) {
    throw "Bundled PCHW Skill tree does not match the RC manifest."
}

New-Item -ItemType Directory -Path $resolvedSkillsRoot -Force | Out-Null
$backupRoot = Join-Path $resolvedSkillsRoot ".skilldock-backups"
$backupPath = $null
if (Test-Path -LiteralPath $target) {
    $existingIdentity = Get-SkillTreeIdentity -Root $target
    if (
        $existingIdentity.tree_sha256 -eq $expectedHash -and
        $existingIdentity.tree_file_count -eq $expectedCount
    ) {
        [pscustomobject]@{
            ok = $true
            changed = $false
            target = $target
            tree_sha256 = $expectedHash
            tree_file_count = $expectedCount
        } | ConvertTo-Json -Compress
        exit 0
    }
    if (-not $ReplaceExisting) {
        throw "PCHW Skill already exists and differs. Re-run with -ReplaceExisting after reviewing the backup behavior."
    }
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $backupPath = Join-Path $backupRoot (
        "pc-hardware-workbench-" +
        (Get-Date -Format "yyyyMMdd-HHmmss") +
        "-" +
        [guid]::NewGuid().ToString("N").Substring(0, 8)
    )
    Move-Item -LiteralPath $target -Destination $backupPath
}

$staging = Join-Path $resolvedSkillsRoot (
    ".pc-hardware-workbench-installing-" + [guid]::NewGuid().ToString("N")
)
try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    Copy-Item `
        -Path (Join-Path $resolvedSource "*") `
        -Destination $staging `
        -Recurse `
        -Force
    Remove-Item `
        -LiteralPath (Join-Path $staging "INSTALL-INFO.json") `
        -Force `
        -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $staging -Destination $target

    [pscustomobject]@{
        schema_version = "1.0"
        skill = "pc-hardware-workbench"
        version = [string]$releaseManifest.pchw_skill.version
        tree_sha256 = $expectedHash
        tree_file_count = $expectedCount
        installed_at = [DateTimeOffset]::Now.ToString("o")
    } | ConvertTo-Json | Set-Content `
        -LiteralPath (Join-Path $target "INSTALL-INFO.json") `
        -Encoding UTF8

    $installedIdentity = Get-SkillTreeIdentity -Root $target
    if (
        $installedIdentity.tree_sha256 -ne $expectedHash -or
        $installedIdentity.tree_file_count -ne $expectedCount
    ) {
        throw "Installed PCHW Skill tree does not match the RC manifest."
    }
}
catch {
    $installError = $_
    $failedTargetPath = $null
    if (Test-Path -LiteralPath $target) {
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $failedTargetPath = Join-Path $backupRoot (
            "pc-hardware-workbench-failed-install-" +
            (Get-Date -Format "yyyyMMdd-HHmmss") +
            "-" +
            [guid]::NewGuid().ToString("N").Substring(0, 8)
        )
        Move-Item -LiteralPath $target -Destination $failedTargetPath
    }
    if ($backupPath -and (Test-Path -LiteralPath $backupPath)) {
        Move-Item -LiteralPath $backupPath -Destination $target
    }
    Write-Warning (
        "PCHW Skill installation failed and was rolled back. " +
        "Failed install backup: $failedTargetPath"
    )
    throw $installError
}
finally {
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}

[pscustomobject]@{
    ok = $true
    changed = $true
    target = $target
    backup_path = $backupPath
    tree_sha256 = $expectedHash
    tree_file_count = $expectedCount
} | ConvertTo-Json -Compress
