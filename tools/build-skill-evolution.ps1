param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$fragment = [System.IO.File]::ReadAllText($Source, $utf8Strict)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Write-SitePage {
    param(
        [string]$Path,
        [string]$SiteView,
        [string]$Title,
        [string]$Description
    )

    $html = @"
<!doctype html>
<html lang="zh-CN" data-site-view="$SiteView">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="dark">
  <meta name="description" content="$Description">
  <title>$Title</title>
</head>
<body>
$fragment
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
    -Title "PC Hardware Workbench / Evolution Map" `
    -Description "Version history, capability map, and state record for the PC Hardware Workbench."

Write-SitePage `
    -Path (Join-Path $interactiveRoot "index.html") `
    -SiteView "interactive" `
    -Title "PC Hardware Workbench / Interactive Lab" `
    -Description "Interactive terminology, tuning gate, triage, and configuration-state demos."

Write-Host "Built index.html and interactive/index.html under $OutputRoot"
