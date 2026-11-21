[CmdletBinding()]
param(
    [switch]$ReplaceStage,

    [switch]$UpgradeExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")

$evidence = Get-EvidenceRoot
$logPath = Join-Path $evidence "01-install.log"
Write-Utf8Text `
    -Path $logPath `
    -Text ("SkillDock RC installation`nStarted: " + [DateTimeOffset]::Now.ToString("o") + "`n")

$preflightArguments = @()
if ($UpgradeExisting) {
    $preflightArguments += "-AllowExistingInstall"
}
& (Join-Path $PSScriptRoot "00-Preflight.ps1") @preflightArguments | Out-Host

$archive = Assert-ArchiveIdentity
$stageRoot = Assert-UnderBundle -Path (Get-BundlePath "stage")
if (Test-Path -LiteralPath $stageRoot) {
    if (-not $ReplaceStage) {
        throw (
            "Stage directory already exists. Re-run only after reviewing it, " +
            "or use -ReplaceStage to recreate the staged RC: $stageRoot"
        )
    }
    $stageItem = Get-Item -LiteralPath $stageRoot -Force
    if (($stageItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Stage path cannot be a reparse point."
    }
    Remove-Item -LiteralPath $stageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot | Out-Null
Expand-Archive `
    -LiteralPath $archive.archive `
    -DestinationPath $stageRoot `
    -Force

$packageRoot = Join-Path $stageRoot $script:PackageBaseName
if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
    throw "The extracted RC package root is missing."
}

$manifestPath = Join-Path $packageRoot "RC-MANIFEST.json"
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ([string]$manifest.release_id -ne $script:ReleaseVersion) {
    throw "The extracted RC release ID is unexpected."
}
if ([string]$manifest.gates.commit -notin @("local-only", "local-uncommitted")) {
    throw "The extracted RC does not record an accepted local source state."
}
if ([string]$manifest.release_state -ne "local-candidate-clean-ui-pending") {
    throw "This acceptance bundle requires the P1 local candidate release state."
}

$skillsRoot = Join-Path $env:USERPROFILE ".codex\skills"
$skillInstallerArguments = @("-SkillsRoot", $skillsRoot)
if ($UpgradeExisting) {
    $skillInstallerArguments += "-ReplaceExisting"
}
$installSkill = Invoke-PowerShellScript `
    -ScriptPath (Join-Path $packageRoot "Install PCHW Skill.ps1") `
    -Arguments $skillInstallerArguments `
    -LogPath $logPath
$skillInstallResult = $installSkill.text.Trim() | ConvertFrom-Json

$installRuntime = Invoke-PowerShellScript `
    -ScriptPath (Join-Path $packageRoot "Install SkillDock Runtime.ps1") `
    -Arguments @() `
    -LogPath $logPath

$pointerPath = Join-Path $env:LOCALAPPDATA "SkillDock\runtime-location.json"
if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
    throw "Runtime installation did not create runtime-location.json."
}
$pointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json
if ([string]$pointer.version -ne $script:ReleaseVersion) {
    throw "Installed Runtime version does not match the RC."
}
if (-not (Test-Path -LiteralPath ([string]$pointer.runtime_path) -PathType Leaf)) {
    throw "The installed Runtime launcher is missing."
}

$result = [ordered]@{
    schema_version = "1.0"
    status = "passed"
    installed_at = [DateTimeOffset]::Now.ToString("o")
    user_profile = $env:USERPROFILE
    archive_sha256 = $archive.sha256
    package_root = $packageRoot
    skills_root = $skillsRoot
    installed_skill = Join-Path $skillsRoot "pc-hardware-workbench"
    skill_changed = [bool]$skillInstallResult.changed
    skill_backup_path = [string]$skillInstallResult.backup_path
    skill_tree_sha256 = [string]$skillInstallResult.tree_sha256
    runtime_pointer = $pointerPath
    runtime_path = [string]$pointer.runtime_path
    pchw_version = [string]$manifest.pchw_skill.version
    runtime_version = [string]$pointer.version
}
Write-Utf8Text `
    -Path (Join-Path $evidence "01-install-result.json") `
    -Text (($result | ConvertTo-Json -Depth 6) + "`n")
Append-Utf8Text -Path $logPath -Text "INSTALL PASSED`n"

Write-Host ""
Write-Host "Installation completed." -ForegroundColor Green
Write-Host "Next: open Codex and ask a hardware question in the current conversation."
Write-Host "Do not start SkillDock.exe manually for the primary acceptance path."
