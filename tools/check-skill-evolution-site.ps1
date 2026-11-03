[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$errors = New-Object System.Collections.Generic.List[string]
$siteRoot = Join-Path $RepositoryRoot "docs\skill-evolution"
$indexPath = Join-Path $siteRoot "index.html"
$interactivePath = Join-Path $siteRoot "interactive\index.html"

foreach ($path in @($indexPath, $interactivePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing site page: $path") | Out-Null
    }
}

if ($errors.Count -eq 0) {
    $indexHtml = Get-Content -Raw -LiteralPath $indexPath -Encoding UTF8
    $interactiveHtml = Get-Content -Raw -LiteralPath $interactivePath -Encoding UTF8
    foreach ($entry in @(
        @{ Name = "Index"; Html = $indexHtml },
        @{ Name = "Interactive"; Html = $interactiveHtml }
    )) {
        if ($entry.Html -notmatch '\u5DE5\u4F5C\u53F0 2\.4\.0') {
            $errors.Add("$($entry.Name) does not show the 2.4.0 current chip.") | Out-Null
        }
        if ($entry.Html -match '\u5DE5\u4F5C\u53F0 1\.5\.2') {
            $errors.Add("$($entry.Name) still presents 1.5.2 as the current chip.") | Out-Null
        }
        foreach ($version in @("1.6.0", "1.7.0", "1.8.0", "1.9.0", "2.0.0", "2.1.0", "2.2.0", "2.3.0", "2.4.0")) {
            if ($entry.Html -notmatch [regex]::Escape('"' + $version + '"')) {
                $errors.Add("$($entry.Name) is missing version $version.") | Out-Null
            }
        }
        $start = $entry.Html.IndexOf('const versionSeries = [')
        $end = $entry.Html.IndexOf('const versionRecords =', $start)
        if ($start -lt 0 -or $end -le $start) {
            $errors.Add("$($entry.Name) versionSeries data is missing.") | Out-Null
        }
        else {
            $segment = $entry.Html.Substring($start, $end - $start)
            $versionCount = [regex]::Matches(
                $segment,
                '(?m)^\s*\["\d+\.\d+\.\d+(?:-r\d+)?",'
            ).Count
            if ($versionCount -ne 106) {
                $errors.Add("$($entry.Name) version count is $versionCount, expected 106.") | Out-Null
            }
        }
    }
    if ($indexHtml -notmatch '\u51BB\u7ED3 v1\.2 \u5FEB\u7167\uFF1A61 \u4E2A Skill \u6587\u4EF6') {
        $errors.Add("Index does not label the file orrery as a frozen v1.2 snapshot.") | Out-Null
    }
    if ($interactiveHtml -notmatch 'data-demo-mode="evidence"') {
        $errors.Add("Interactive page has no evidence-system mode.") | Out-Null
    }
    if ($interactiveHtml -notmatch '\u540C\u4E00\u6761\u8BC1\u636E\u94FE\uFF0C\u63A5\u4F4F\u4E0D\u540C\u6765\u6E90') {
        $errors.Add("Interactive evidence-system panel copy is missing.") | Out-Null
    }

    $node = Get-Command "node.exe" -ErrorAction SilentlyContinue
    if ($null -eq $node) {
        $errors.Add("node.exe is required for embedded site JavaScript syntax checks.") | Out-Null
    }
    else {
        foreach ($path in @($indexPath, $interactivePath)) {
            $html = Get-Content -Raw -LiteralPath $path -Encoding UTF8
            $scripts = [regex]::Matches($html, '(?is)<script(?:\s[^>]*)?>(.*?)</script>')
            $temporary = Join-Path ([IO.Path]::GetTempPath()) "pcwb-site-$([guid]::NewGuid().ToString('N')).js"
            try {
                $source = ($scripts | ForEach-Object { $_.Groups[1].Value }) -join "`r`n"
                [IO.File]::WriteAllText($temporary, $source, (New-Object System.Text.UTF8Encoding($false)))
                & $node.Source --check $temporary
                if ($LASTEXITCODE -ne 0) {
                    $errors.Add("Embedded JavaScript syntax check failed: $path") | Out-Null
                }
            }
            finally {
                if (Test-Path -LiteralPath $temporary) {
                    Remove-Item -LiteralPath $temporary -Force
                }
            }
        }
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Skill evolution site check: FAIL" -ForegroundColor Red
    foreach ($errorMessage in $errors) {
        Write-Host "- $errorMessage" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Skill evolution site check: PASS (106 versions, evidence lab, JavaScript syntax)" -ForegroundColor Green
