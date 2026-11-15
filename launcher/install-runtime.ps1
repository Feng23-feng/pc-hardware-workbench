param(
    [string]$SourceDirectory = "",
    [string]$TargetDirectory = ""
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $RepositoryRoot "dist\SkillDock-DSH"
}
if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
    $TargetDirectory = Join-Path $env:LOCALAPPDATA "SkillDock\Runtime"
}
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
$TargetDirectory = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
$LocalRoot = [IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA "SkillDock")
).TrimEnd('\')

if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory "SkillDock.exe") -PathType Leaf)) {
    throw "Source package does not contain SkillDock.exe: $SourceDirectory"
}
if (
    -not $TargetDirectory.StartsWith(
        $LocalRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "TargetDirectory must stay inside $LocalRoot"
}

$TargetExe = Join-Path $TargetDirectory "SkillDock.exe"
if (Test-Path -LiteralPath $TargetExe -PathType Leaf) {
    & $TargetExe --stop --silent
    Start-Sleep -Milliseconds 500
}
if (Test-Path -LiteralPath $TargetDirectory) {
    Remove-Item -LiteralPath $TargetDirectory -Recurse -Force
}
New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
Copy-Item -Path (Join-Path $SourceDirectory "*") -Destination $TargetDirectory -Recurse -Force

[pscustomobject]@{
    runtime = Join-Path $TargetDirectory "SkillDock.exe"
    installed_at = [DateTimeOffset]::Now.ToString("o")
} | ConvertTo-Json -Compress
