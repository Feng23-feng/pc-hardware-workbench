param(
    [string]$HomeSource,

    [string]$InteractiveSource,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($HomeSource)) {
    $HomeSource = Join-Path $PSScriptRoot "templates\skill-evolution-home.html"
}
if ([string]::IsNullOrWhiteSpace($InteractiveSource)) {
    $InteractiveSource = Join-Path $PSScriptRoot "templates\skill-evolution-interactive.html"
}
foreach ($sourcePath in @($HomeSource, $InteractiveSource)) {
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Missing Skill evolution source template: $sourcePath"
    }
}

$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$skillPath = Join-Path $repositoryRoot "skill\pc-hardware-workbench\SKILL.md"
$skillText = [System.IO.File]::ReadAllText($skillPath, $utf8Strict)
$versionMatch = [regex]::Match($skillText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
if (-not $versionMatch.Success) {
    throw "Skill metadata.version is missing."
}
$skillVersion = $versionMatch.Groups[1].Value

function Write-SitePage {
    param(
        [string]$Path,
        [string]$SiteView,
        [string]$Title,
        [string]$Description,
        [string]$Source,
        [string]$BaseHref = "",
        [string]$AssetPrefix = "."
    )

    $fragment = [System.IO.File]::ReadAllText($Source, $utf8Strict)
    $baseTag = if ([string]::IsNullOrWhiteSpace($BaseHref)) {
        ""
    }
    else {
        "  <base href=`"$BaseHref`">"
    }
    $styleHref = "$AssetPrefix/crt-backdrop.css"
    $scriptSrc = "$AssetPrefix/crt-backdrop.js"
    $html = @"
<!doctype html>
<html lang="zh-CN" data-site-view="$SiteView">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <meta name="description" content="$Description">
  <link rel="icon" href="data:,">
  <link rel="stylesheet" href="$styleHref">
$baseTag
  <title>$Title</title>
</head>
<body>
$fragment
<script src="$scriptSrc" defer></script>
<noscript>This page requires JavaScript to show the interactive content.</noscript>
</body>
</html>
"@

    [System.IO.File]::WriteAllText($Path, $html, $utf8NoBom)
    if (-not [System.IO.File]::Exists($Path)) {
        throw "Failed to write $Path"
    }
    Write-Host "Wrote $Path"
}

$interactiveRoot = Join-Path $OutputRoot "interactive"
[System.IO.Directory]::CreateDirectory($OutputRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($interactiveRoot) | Out-Null

Write-SitePage `
    -Path (Join-Path $OutputRoot "index.html") `
    -SiteView "index" `
    -Title "pc-hardware-workbench &#183; &#30005;&#33041;&#30828;&#20214;&#24037;&#20316;&#21488;" `
    -Description "PC Hardware Workbench ${skillVersion}: read-only hardware evidence and practical next-step guidance." `
    -Source $HomeSource `
    -AssetPrefix "."

Write-SitePage `
    -Path (Join-Path $interactiveRoot "index.html") `
    -SiteView "interactive" `
    -Title "&#39640;&#32423;&#27169;&#24335; &#183; pc-hardware-workbench" `
    -Description "PC Hardware Workbench ${skillVersion} advanced tools: terminology, tuning, triage, baseline identity and evidence." `
    -Source $InteractiveSource `
    -AssetPrefix ".."

Write-Host "Built index.html and interactive/index.html under $OutputRoot"
