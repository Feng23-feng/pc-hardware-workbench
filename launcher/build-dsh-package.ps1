param(
    [string]$OutputDirectory = ""
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

$Csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$NodeSource = if ($env:SKILLDOCK_NODE_DIR) {
    $env:SKILLDOCK_NODE_DIR
} else {
    Join-Path $HOME "Documents\Codex\pc-hardware-workbench\work\node22\node-v22.23.4-win-x64"
}
$NodeExecutable = Join-Path $NodeSource "node.exe"
$NodeLicense = Join-Path $NodeSource "LICENSE"
$SourceFile = Join-Path $LauncherRoot "SkillDockLauncher.cs"

foreach ($required in @($Csc, $NodeExecutable, $NodeLicense, $SourceFile)) {
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

$StopScript = @"
@echo off
"%~dp0SkillDock.exe" --stop
"@
Set-Content `
    -LiteralPath (Join-Path $OutputDirectory "Stop SkillDock.cmd") `
    -Value $StopScript `
    -Encoding ASCII

$Readme = @"
SkillDock DSH portable test

1. Start DeepSeek Harness once and sign in.
2. Double-click SkillDock.exe.
3. SkillDock opens a local browser page.
4. Use "Stop SkillDock.cmd" when finished.

No administrator rights are required by this test package.
SkillDock connects to the local DSH installation through its panel-owned Web
child process. It does not copy the DSH browser cookie or API key.
"@
Set-Content `
    -LiteralPath (Join-Path $OutputDirectory "README.txt") `
    -Value $Readme `
    -Encoding UTF8

$Package = Join-Path $DistRoot "SkillDock-DSH-win-x64.zip"
if (Test-Path -LiteralPath $Package) {
    Remove-Item -LiteralPath $Package -Force
}
Compress-Archive -LiteralPath $OutputDirectory -DestinationPath $Package

Write-Output "Package: $OutputDirectory"
Write-Output "ZIP: $Package"
