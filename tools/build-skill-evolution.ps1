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
  <link rel="icon" href="data:,">
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
    -Title "电脑硬件工作台 · 2.4.0 候选 / 项目地图" `
    -Description "电脑硬件工作台 2.4.0 本地候选：只读硬件证据、故障排查、遥测分析与版本档案。"

Write-SitePage `
    -Path (Join-Path $interactiveRoot "index.html") `
    -SiteView "interactive" `
    -Title "交互实验室 · 电脑硬件工作台" `
    -Description "电脑硬件工作台 2.4.0 候选交互实验室：从单一步骤开始理解证据、排障与调校门禁。"

Write-Host "Built index.html and interactive/index.html under $OutputRoot"
