[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$errors = New-Object System.Collections.Generic.List[string]
$skillFile = Join-Path $RepositoryRoot "skill\pc-hardware-workbench\SKILL.md"
$readmeFile = Join-Path $RepositoryRoot "README.md"
$changelogFile = Join-Path $RepositoryRoot "CHANGELOG.md"
$portableGuideName = (-join @(
    [char]0x4F7F,
    [char]0x7528,
    [char]0x8BF4,
    [char]0x660E
)) + ".txt"
$portableGuide = Join-Path (Join-Path $RepositoryRoot "portable") $portableGuideName
$portableStart = Join-Path $RepositoryRoot "portable\start.ps1"
$indexFile = Join-Path $RepositoryRoot "docs\skill-evolution\index.html"
$interactiveFile = Join-Path $RepositoryRoot "docs\skill-evolution\interactive\index.html"

foreach ($path in @($skillFile, $readmeFile, $changelogFile, $portableGuide, $portableStart, $indexFile, $interactiveFile)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing version source: $path") | Out-Null
    }
}

if ($errors.Count -eq 0) {
    $skillText = Get-Content -Raw -LiteralPath $skillFile -Encoding UTF8
    $match = [regex]::Match($skillText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
    if (-not $match.Success) {
        $errors.Add("SKILL.md version is missing.") | Out-Null
        $version = "unknown"
    }
    else {
        $version = $match.Groups[1].Value
    }

    $readmeText = Get-Content -Raw -LiteralPath $readmeFile -Encoding UTF8
    if ($readmeText -notmatch [regex]::Escape("Current public status: **$version test release**")) {
        $errors.Add("README current version does not match $version.") | Out-Null
    }

    $changelogText = Get-Content -Raw -LiteralPath $changelogFile -Encoding UTF8
    if ($changelogText -notmatch [regex]::Escape("## $version ")) {
        $errors.Add("CHANGELOG top version does not match $version.") | Out-Null
    }

    $portableGuideText = Get-Content -Raw -LiteralPath $portableGuide -Encoding UTF8
    $portableTitlePattern = "\u7535\u8111\u786C\u4EF6\u4FBF\u643A\u5DE5\u5177\u5305 " + [regex]::Escape($version)
    if ($portableGuideText -notmatch $portableTitlePattern) {
        $errors.Add("Portable guide version does not match $version.") | Out-Null
    }

    $portableStartText = Get-Content -Raw -LiteralPath $portableStart -Encoding UTF8
    if ($portableStartText -notmatch $portableTitlePattern) {
        $errors.Add("Portable start title does not match $version.") | Out-Null
    }

    $siteVersionRecordPattern = '\["' + [regex]::Escape($version) + '"[^\r\n]*CURRENT CANDIDATE'
    foreach ($path in @($indexFile, $interactiveFile)) {
        $html = Get-Content -Raw -LiteralPath $path -Encoding UTF8
        if ($html -notmatch $siteVersionRecordPattern) {
            $errors.Add("Site version archive does not contain current record $version : $path") | Out-Null
        }
    }

    if ($errors.Count -eq 0) {
        Write-Host "Version consistency: PASS ($version)" -ForegroundColor Green
        exit 0
    }
}

Write-Host "Version consistency: FAIL" -ForegroundColor Red
foreach ($errorMessage in $errors) {
    Write-Host "- $errorMessage" -ForegroundColor Red
}
exit 1
