param(
    [string]$SourceDirectory = "",
    [string]$TargetDirectory = ""
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    $SourceDirectory = Join-Path $RepositoryRoot "dist\SkillDock-DSH"
}
$PackageJson = Get-Content -Raw -LiteralPath (Join-Path $SourceDirectory "app\package.json") | ConvertFrom-Json
$PackageVersion = [string]$PackageJson.version
if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
    $SafeVersion = $PackageVersion -replace '[^A-Za-z0-9._-]', '-'
    $TargetDirectory = Join-Path $env:LOCALAPPDATA (
        "SkillDock\Runtime-$SafeVersion-" + (Get-Date -Format "yyyyMMddHHmmss")
    )
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

if (Test-Path -LiteralPath $TargetDirectory) {
    throw "TargetDirectory already exists: $TargetDirectory"
}
New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
Copy-Item -Path (Join-Path $SourceDirectory "*") -Destination $TargetDirectory -Recurse -Force

$LauncherPath = Join-Path $TargetDirectory "SkillDock.exe"
if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "Runtime installation did not produce SkillDock.exe: $TargetDirectory"
}
$PointerPath = Join-Path $LocalRoot "runtime-location.json"
[pscustomobject]@{
    runtime_path = $LauncherPath
    version = $PackageVersion
    installed_at = [DateTimeOffset]::Now.ToString("o")
} | ConvertTo-Json | Set-Content -LiteralPath $PointerPath -Encoding UTF8

[pscustomobject]@{
    runtime = $LauncherPath
    pointer = $PointerPath
    version = $PackageVersion
    installed_at = [DateTimeOffset]::Now.ToString("o")
} | ConvertTo-Json -Compress
