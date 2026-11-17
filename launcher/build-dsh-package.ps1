param(
    [string]$OutputDirectory = "",

    [string]$ArchivePath = "",

    [string]$LauncherSourcePath = ""
)

$ErrorActionPreference = "Stop"
$LauncherRoot = $PSScriptRoot
$RepositoryRoot = Split-Path -Parent $LauncherRoot
$DistRoot = Join-Path $RepositoryRoot "dist"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $DistRoot "SkillDock-DSH"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$ResolvedDistRoot = [IO.Path]::GetFullPath($DistRoot).TrimEnd('\')
if (
    -not $OutputDirectory.StartsWith(
        $ResolvedDistRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "OutputDirectory must stay inside $ResolvedDistRoot"
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $DistRoot "SkillDock-DSH-win-x64.zip"
}
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
if (
    -not $ArchivePath.StartsWith(
        $ResolvedDistRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "ArchivePath must stay inside $ResolvedDistRoot"
}
if ($ArchivePath.Equals($OutputDirectory, [StringComparison]::OrdinalIgnoreCase)) {
    throw "ArchivePath and OutputDirectory must be different paths"
}

$Csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$NodeSource = if ($env:SKILLDOCK_NODE_DIR) {
    $env:SKILLDOCK_NODE_DIR
} else {
    Split-Path -Parent (Get-Command node -ErrorAction Stop).Source
}
$NodeExecutable = Join-Path $NodeSource "node.exe"
$NodeLicense = Join-Path $NodeSource "LICENSE"
$SourceFile = if ([string]::IsNullOrWhiteSpace($LauncherSourcePath)) {
    Join-Path $LauncherRoot "SkillDockLauncher.cs"
}
else {
    [IO.Path]::GetFullPath($LauncherSourcePath)
}
$DshDevHarness = Join-Path $LauncherRoot "start-dsh-dev.ps1"
$DshInstalledHarness = Join-Path $LauncherRoot "start-dsh-installed.ps1"
$UninstallScript = Join-Path $LauncherRoot "uninstall-runtime.ps1"
$RuntimePathsScript = Join-Path $LauncherRoot "runtime-paths.ps1"
$PackageJsonPath = Join-Path $RepositoryRoot "package.json"
$PackageJson = Get-Content -Raw -LiteralPath $PackageJsonPath | ConvertFrom-Json
$PackageVersion = [string]$PackageJson.version

foreach ($required in @(
    $Csc,
    $NodeExecutable,
    $NodeLicense,
    $SourceFile,
    $PackageJsonPath,
    $DshDevHarness,
    $DshInstalledHarness,
    $UninstallScript,
    $RuntimePathsScript
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Build input is missing: $required"
    }
}

if (Test-Path -LiteralPath $OutputDirectory) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
}
$AppDirectory = Join-Path $OutputDirectory "app"
$NodeDirectory = Join-Path $OutputDirectory "node"
New-Item -ItemType Directory -Path $AppDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $NodeDirectory -Force | Out-Null

foreach ($file in @(
    "server.mjs",
    "agent-bridge-host.mjs",
    "open-workbench.mjs",
    "package.json",
    "VERSIONING.md"
)) {
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot $file) -Destination $AppDirectory
}
foreach ($directory in @("lib", "public", "schemas")) {
    Copy-Item `
        -LiteralPath (Join-Path $RepositoryRoot $directory) `
        -Destination (Join-Path $AppDirectory $directory) `
        -Recurse
}
Copy-Item -LiteralPath $NodeExecutable -Destination (Join-Path $NodeDirectory "node.exe")
Copy-Item -LiteralPath $NodeLicense -Destination (Join-Path $NodeDirectory "LICENSE")

$ExecutablePath = Join-Path $OutputDirectory "SkillDock.exe"
& $Csc `
    /nologo `
    /target:winexe `
    /optimize+ `
    /platform:x64 `
    "/out:$ExecutablePath" `
    /reference:System.dll `
    /reference:System.Core.dll `
    /reference:System.Web.Extensions.dll `
    /reference:System.Windows.Forms.dll `
    $SourceFile
if ($LASTEXITCODE -ne 0) {
    throw "Launcher compilation failed with exit code $LASTEXITCODE"
}
Copy-Item `
    -LiteralPath $DshDevHarness `
    -Destination (Join-Path $OutputDirectory "Start-DSH-SkillDock-Dev.ps1")
Copy-Item `
    -LiteralPath $DshInstalledHarness `
    -Destination (Join-Path $OutputDirectory "Start-DSH-SkillDock.ps1")
Copy-Item `
    -LiteralPath $UninstallScript `
    -Destination (Join-Path $OutputDirectory "Uninstall SkillDock.ps1")
Copy-Item `
    -LiteralPath $RuntimePathsScript `
    -Destination (Join-Path $OutputDirectory "runtime-paths.ps1")

$StopScript = @"
@echo off
"%~dp0SkillDock.exe" --stop
"@
Set-Content `
    -LiteralPath (Join-Path $OutputDirectory "Stop SkillDock.cmd") `
    -Value $StopScript `
    -Encoding ASCII

$Readme = @"
SkillDock Internal Preview

Version: $PackageVersion
Status: INTERNAL TEST / DEFAULT OFF / MOCK ONLY / NOT FOR RELEASE

This package exists to validate the source-hosted internal preview. It is not a
production release and it does not enable the formal user entry or default
traffic.

Start the packaged preview from PowerShell in this folder:

    `$env:SKILLDOCK_AGENT_DRIVER = "mock"
    `$env:SKILLDOCK_INTERNAL_PREVIEW = "1"
    `$env:SKILLDOCK_LOCAL_ROOT = "`$env:LOCALAPPDATA\SkillDockInternalPreview"
    .\SkillDock.exe --ensure --workspace "C:\path\to\test-workspace" --silent

The local page opens in the default browser. The preview entry is available only
when SKILLDOCK_INTERNAL_PREVIEW=1 and SKILLDOCK_AGENT_DRIVER=mock. Without both
settings it is default-off; preview with a non-mock driver is rejected. This
package must not use a real Codex Thread or recovery path.

Stop it with:

    .\SkillDock.exe --stop --silent

Use that same SKILLDOCK_LOCAL_ROOT in a new PowerShell session before stopping or
uninstalling. The recommended internal-preview root is separate from the formal
SkillDock root:

    %LOCALAPPDATA%\SkillDockInternalPreview

Uninstall behavior:

1. "Uninstall SkillDock.ps1" is for an installed Runtime-* program directory.
   It removes program files and the runtime pointer by default.
2. Default uninstall preserves user data, launch metadata and backups.
3. Add the explicit purge flags only when the tester wants Task/evidence data
   and backup copies deleted:

       .\Uninstall SkillDock.ps1 `
         -LocalRoot "`$env:LOCALAPPDATA\SkillDockInternalPreview" `
         -BackupRoot "`$env:LOCALAPPDATA\SkillDockInternalPreviewBackups" `
         -PurgeUserData -PurgeBackups

4. If this ZIP was run portably from its extracted folder, stop the Runtime and
   use the purge command above if data cleanup is required, then delete the
   extracted folder. The packaged uninstaller does not delete the arbitrary
   folder from which it was transported.

No administrator rights are required by this test package.
The mock preview does not call DSH, Codex, an external model, or a user Thread.
"@
Set-Content `
    -LiteralPath (Join-Path $OutputDirectory "README.txt") `
    -Value $Readme `
    -Encoding UTF8

if (Test-Path -LiteralPath $ArchivePath) {
    Remove-Item -LiteralPath $ArchivePath -Force
}
Compress-Archive -LiteralPath $OutputDirectory -DestinationPath $ArchivePath

Write-Output "Package: $OutputDirectory"
Write-Output "ZIP: $ArchivePath"
