[CmdletBinding()]
param(
    [ValidateSet("start", "stop")]
    [string]$Action = "start",

    [string]$LauncherPath = "",

    [string]$LocalRoot = (
        Join-Path $env:LOCALAPPDATA "SkillDock\dev-visual-interface"
    ),

    [string]$DshExecutable = "C:\dsh\DeepSeek Harness.exe",

    [string]$DshWorkspace = (
        Join-Path $env:USERPROFILE "Documents\deepseek-harness\default-workspace"
    )
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
    $LauncherPath = Join-Path $PSScriptRoot "SkillDock.exe"
}
$resolvedLauncher = [IO.Path]::GetFullPath($LauncherPath)
$resolvedLocalRoot = [IO.Path]::GetFullPath($LocalRoot)

if (-not (Test-Path -LiteralPath $resolvedLauncher -PathType Leaf)) {
    throw "SkillDock development executable is missing: $resolvedLauncher"
}

$env:SKILLDOCK_LOCAL_ROOT = $resolvedLocalRoot
$env:SKILLDOCK_LAUNCHER = $resolvedLauncher
$env:PANEL_SURFACE_MODE = "read-only"
Remove-Item Env:SKILLDOCK_AGENT_DRIVER -ErrorAction SilentlyContinue

function Test-SkillDockRuntimeHealthy {
    param([string]$Root)

    $infoPath = Join-Path $Root "runtime-dsh-web\server-info.json"
    if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) {
        return $false
    }
    try {
        $info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
        $port = [int]$info.port
        if ($port -le 0) {
            return $false
        }
        $health = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$port/api/health" `
            -TimeoutSec 5
        return [bool]$health.ok
    }
    catch {
        return $false
    }
}

if ($Action -eq "stop") {
    if (-not (Test-SkillDockRuntimeHealthy -Root $resolvedLocalRoot)) {
        Write-Host "SkillDock development Runtime is already stopped."
        Write-Host "Local root: $resolvedLocalRoot"
        exit 0
    }
    $process = Start-Process `
        -FilePath $resolvedLauncher `
        -ArgumentList @("--stop", "--silent") `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    if ($process.ExitCode -ne 0) {
        throw "SkillDock development Runtime did not stop cleanly."
    }
    Write-Host "SkillDock development Runtime stopped."
    Write-Host "Local root: $resolvedLocalRoot"
    exit 0
}

$runningDsh = Get-Process -Name "DeepSeek Harness" -ErrorAction SilentlyContinue
if ($runningDsh) {
    throw "Close DeepSeek Harness completely before starting this isolated test."
}
if (-not (Test-Path -LiteralPath $DshExecutable -PathType Leaf)) {
    throw "DeepSeek Harness executable is missing: $DshExecutable"
}
$resolvedWorkspace = [IO.Path]::GetFullPath($DshWorkspace)
if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
    throw "DSH workspace is missing: $resolvedWorkspace"
}

New-Item -ItemType Directory -Path $resolvedLocalRoot -Force | Out-Null
$quotedWorkspace = '"' + $resolvedWorkspace.Replace('"', '\"') + '"'
$ensureArguments = @(
    "--ensure",
    "--workspace",
    $quotedWorkspace,
    "--silent",
    "--no-browser"
)
$ensureProcess = Start-Process `
    -FilePath $resolvedLauncher `
    -ArgumentList $ensureArguments `
    -WindowStyle Hidden `
    -Wait `
    -PassThru
if ($ensureProcess.ExitCode -ne 0) {
    throw "SkillDock development Runtime failed to start."
}
$launchResultPath = Join-Path $resolvedLocalRoot "launch-result.json"
if (-not (Test-Path -LiteralPath $launchResultPath -PathType Leaf)) {
    throw "SkillDock development Runtime did not write launch-result.json."
}
$launchResult = Get-Content -LiteralPath $launchResultPath -Raw | ConvertFrom-Json
if (
    -not $launchResult.ok -or
    -not $launchResult.url -or
    -not ([string]$launchResult.workspace).Equals(
        $resolvedWorkspace,
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "SkillDock development Runtime returned an invalid launch result."
}

Start-Process `
    -FilePath $DshExecutable `
    -WorkingDirectory (Split-Path -Parent $DshExecutable)

Write-Host "Started DSH with the isolated SkillDock development Runtime."
Write-Host "Launcher: $resolvedLauncher"
Write-Host "Local root: $resolvedLocalRoot"
Write-Host "Workspace: $resolvedWorkspace"
Write-Host "Panel URL: $launchResult.url"
Write-Host ""
Write-Host "In DSH, open a task and say: 打开 SkillDock"
