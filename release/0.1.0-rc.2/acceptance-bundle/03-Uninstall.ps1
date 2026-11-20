[CmdletBinding()]
param(
    [switch]$AcceptDedicatedProfileCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")

if (-not $AcceptDedicatedProfileCleanup) {
    throw (
        "Uninstall with purge requires -AcceptDedicatedProfileCleanup. " +
        "Use it only in the dedicated clean acceptance profile."
    )
}

$evidence = Get-EvidenceRoot
$preflightPath = Join-Path $evidence "00-preflight.json"
if (-not (Test-Path -LiteralPath $preflightPath -PathType Leaf)) {
    throw "Preflight evidence is missing. This does not look like the installed acceptance profile."
}
$preflight = Get-Content -Raw -LiteralPath $preflightPath | ConvertFrom-Json
if (
    [IO.Path]::GetFullPath([string]$preflight.user_profile).TrimEnd("\") -ne
    [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd("\")
) {
    throw "The current Windows profile differs from the clean preflight profile."
}

$logPath = Join-Path $evidence "03-uninstall.log"
Write-Utf8Text `
    -Path $logPath `
    -Text ("SkillDock RC uninstall`nStarted: " + [DateTimeOffset]::Now.ToString("o") + "`n")

$localRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
$runtimeBackupRoot = Join-Path `
    $env:LOCALAPPDATA `
    "SkillDockBackups\runtime"
$pointerPath = Join-Path $localRoot "runtime-location.json"
$stoppedRuntime = ""
$removedRuntimeDirectories = 0

if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
    $pointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json
    $runtimePath = [IO.Path]::GetFullPath([string]$pointer.runtime_path)
    $runtimeRoot = Split-Path -Parent $runtimePath
    $resolvedLocalRoot = [IO.Path]::GetFullPath($localRoot).TrimEnd("\")
    if (-not $runtimeRoot.StartsWith(
        $resolvedLocalRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Runtime pointer escapes the SkillDock local root."
    }
    $runtimeUninstaller = Join-Path $runtimeRoot "Uninstall SkillDock.ps1"
    if (-not (Test-Path -LiteralPath $runtimeUninstaller -PathType Leaf)) {
        throw "Installed Runtime uninstaller is missing."
    }
    $runtimeResult = Invoke-PowerShellScript `
        -ScriptPath $runtimeUninstaller `
        -Arguments @(
            "-LocalRoot",
            $localRoot,
            "-BackupRoot",
            $runtimeBackupRoot,
            "-PurgeUserData",
            "-PurgeBackups"
        ) `
        -LogPath $logPath
}

$stageRoot = Assert-UnderBundle -Path (Get-BundlePath "stage")
$packageRoot = Join-Path $stageRoot $script:PackageBaseName
if (-not (Test-Path -LiteralPath (
    Join-Path $packageRoot "Uninstall PCHW Skill.ps1"
) -PathType Leaf)) {
    if (-not (Test-Path -LiteralPath $stageRoot)) {
        New-Item -ItemType Directory -Path $stageRoot | Out-Null
    }
    $archive = Assert-ArchiveIdentity
    Expand-Archive `
        -LiteralPath $archive.archive `
        -DestinationPath $stageRoot `
        -Force
}
$skillUninstaller = Join-Path $packageRoot "Uninstall PCHW Skill.ps1"
if (-not (Test-Path -LiteralPath $skillUninstaller -PathType Leaf)) {
    throw "Packaged PCHW uninstaller is missing."
}
$skillsRoot = Join-Path $env:USERPROFILE ".codex\skills"
$skillResult = Invoke-PowerShellScript `
    -ScriptPath $skillUninstaller `
    -Arguments @(
        "-SkillsRoot",
        $skillsRoot,
        "-PurgeBackups"
    ) `
    -LogPath $logPath

Start-Sleep -Milliseconds 750
$remainingPaths = @(
    (Join-Path $skillsRoot "pc-hardware-workbench"),
    $localRoot,
    (Join-Path $env:LOCALAPPDATA "SkillDockBackups")
) | Where-Object { Test-Path -LiteralPath $_ }
$processRows = @(
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -in @("node.exe", "SkillDock.exe") } |
        ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                pid = [int]$_.ProcessId
                parent_pid = [int]$_.ParentProcessId
                command_line = [string]$_.CommandLine
            }
        }
)

$result = [ordered]@{
    schema_version = "1.0"
    status = if ($remainingPaths.Count -eq 0 -and $processRows.Count -eq 0) {
        "passed"
    }
    else {
        "review"
    }
    uninstalled_at = [DateTimeOffset]::Now.ToString("o")
    user_profile = $env:USERPROFILE
    remaining_paths = @($remainingPaths)
    remaining_processes = $processRows
    purged_user_data = $true
    purged_backups = $true
}
Write-Utf8Text `
    -Path (Join-Path $evidence "03-uninstall-result.json") `
    -Text (($result | ConvertTo-Json -Depth 8) + "`n")
$processLines = $processRows | ForEach-Object {
    "$($_.pid)`t$($_.parent_pid)`t$($_.name)`t$($_.command_line)"
}
Write-Utf8Text `
    -Path (Join-Path $evidence "03-processes-after-uninstall.txt") `
    -Text (($processLines -join "`n") + "`n")
Append-Utf8Text `
    -Path $logPath `
    -Text ("UNINSTALL RESULT: " + $result.status + "`n")

if ($result.status -ne "passed") {
    throw (
        "Uninstall left paths or processes. Review 03-uninstall-result.json."
    )
}
Write-Host "Uninstall and residue check passed." -ForegroundColor Green
