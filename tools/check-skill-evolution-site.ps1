[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$errors = New-Object System.Collections.Generic.List[string]
$siteRoot = Join-Path $RepositoryRoot "docs\skill-evolution"
$indexPath = Join-Path $siteRoot "index.html"
$interactivePath = Join-Path $siteRoot "interactive\index.html"
$orreryPath = Join-Path $siteRoot "orrery\index.html"
$frozenPath = Join-Path $siteRoot "orrery\FROZEN.json"

foreach ($path in @($indexPath, $interactivePath, $orreryPath, $frozenPath)) {
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
        if ($entry.Html -notmatch '\u5DE5\u4F5C\u53F0 2\.4\.0 \u00B7 \u672C\u5730\u6D4B\u8BD5\u5019\u9009') {
            $errors.Add("$($entry.Name) does not label 2.4.0 as the local candidate.") | Out-Null
        }
        if ($entry.Html -match '\u5DE5\u4F5C\u53F0 1\.5\.2') {
            $errors.Add("$($entry.Name) still presents 1.5.2 as the current chip.") | Out-Null
        }
        if ($entry.Html -match '\u7A33\u5B9A 2\.4\.0|STABLE 2\.4\.0') {
            $errors.Add("$($entry.Name) still presents 2.4.0 as stable.") | Out-Null
        }
        if ($entry.Html -notmatch 'PENDING') {
            $errors.Add("$($entry.Name) does not preserve pending validation status.") | Out-Null
        }
        if ($entry.Html -notmatch 'currentSeriesByTrack\s*=\s*\{[\s\S]*?core:\s*"wb-2-2"') {
            $errors.Add("$($entry.Name) current core series is not wb-2-2.") | Out-Null
        }
        if ($entry.Html -notmatch 'selectVersion\("wb-2-4-0"') {
            $errors.Add("$($entry.Name) does not initialize the archive on 2.4.0.") | Out-Null
        }
        if ($entry.Html -notmatch '\u5DE5\u4F5C\u53F0 / 1\.6 \u2192 2\.4') {
            $errors.Add("$($entry.Name) version-series label does not cover 1.6 through 2.4.") | Out-Null
        }
        if ($entry.Html -notmatch 'id="dse-root"' -or $entry.Html -notmatch '<main id="dse-root"') {
            $errors.Add("$($entry.Name) does not use a main landmark for the site root.") | Out-Null
        }
        if ($entry.Html -match '\u5DE5\u4F5C\u53F0 2\.4\.0[^\r\n]*GitHub \u5C1A\u672A\u63A8\u9001') {
            $errors.Add("$($entry.Name) still says the 2.4.0 candidate is not on GitHub.") | Out-Null
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
            if ($segment -notmatch '\["2\.0\.0"[^\r\n]*WMI') {
                $errors.Add("$($entry.Name) no longer preserves the historical 2.0.0 WMI record.") | Out-Null
            }
            if ($segment -notmatch '\["2\.4\.0"[^\r\n]*CURRENT CANDIDATE[^\r\n]*loopback Web') {
                $errors.Add("$($entry.Name) current 2.4.0 record is not consistent with the local candidate.") | Out-Null
            }
        }
    }
    if ($indexHtml -notmatch '\u5F53\u524D 86 \u4E2A Skill \u6587\u4EF6') {
        $errors.Add("Index does not point to the current 86-file orrery.") | Out-Null
    }
    if ($indexHtml -notmatch '\u5F53\u524D\u6587\u4EF6\u661F\u7CFB \u00B7 2\.4\.0') {
        $errors.Add("Index does not label the current file galaxy as 2.4.0.") | Out-Null
    }
    foreach ($marker in @(
        'dse-skill-kicker',
        '$pc-hardware-workbench',
        'class="dse-hero-actions"',
        'class="dse-hero-status"',
        'id="dse-overview-title"',
        'class="dse-about-grid"',
        'class="dse-preview-card"',
        'class="dse-section-continue"',
        'id="dse-how-title"',
        'id="dse-candidate-title"',
        'class="dse-candidate-columns"',
        'class="dse-candidate-details"',
        'class="dse-explore"'
    )) {
        if ($indexHtml -notmatch [regex]::Escape($marker)) {
            $errors.Add("Index homepage hierarchy is missing $marker.") | Out-Null
        }
    }
    if ($indexHtml -notmatch '\u4EBA\u5DE5\u7B7E\u7F72\uFF1APENDING') {
        $errors.Add("Index technical details do not preserve the human-acceptance gate.") | Out-Null
    }
    if ([regex]::Matches($indexHtml, '<a class="dse-hero-action\b').Count -ne 1) {
        $errors.Add("Index must expose exactly one primary hero action.") | Out-Null
    }
    if ($indexHtml -match 'dse-page-enter' -or $indexHtml -notmatch 'dse-home-hero-enter') {
        $errors.Add("Index first-load motion is not using the dedicated hero entrance.") | Out-Null
    }
    if ($indexHtml -notmatch 'sessionStorage' -or $indexHtml -notmatch 'dse-hero-enter') {
        $errors.Add("Index first-load motion is not session-gated.") | Out-Null
    }
    if ($interactiveHtml -notmatch 'data-demo-mode="evidence"') {
        $errors.Add("Interactive page has no evidence-system mode.") | Out-Null
    }
    if ($interactiveHtml -notmatch '\u540C\u4E00\u6761\u8BC1\u636E\u94FE\uFF0C\u63A5\u4F4F\u4E0D\u540C\u6765\u6E90') {
        $errors.Add("Interactive evidence-system panel copy is missing.") | Out-Null
    }
    foreach ($marker in @(
        'class="dse-hero-status"',
        'class="dse-guided"',
        'class="dse-guided-path"',
        'id="dse-guided-outcome"',
        'id="dse-guided-evidence-choices"',
        'id="dse-guided-evidence-options"',
        'id="dse-guided-result-actions"',
        'id="dse-guided-recommendation"',
        'class="dse-guided-action-note"',
        'id="dse-guided-scenario"',
        'id="dse-guided-next"',
        'id="dse-guided-prev"',
        'id="dse-guided-reset"',
        'id="dse-guided-show-reason"',
        'id="dse-guided-switch"',
        'id="dse-guided-open-advanced"',
        'class="dse-advanced-shell" id="dse-advanced-shell"',
        'class="dse-advanced-status"',
        'id="dse-advanced-prev"',
        'id="dse-advanced-reset"',
        'id="dse-advanced-next"'
    )) {
        if ($interactiveHtml -notmatch [regex]::Escape($marker)) {
            $errors.Add("Interactive progressive-disclosure hierarchy is missing $marker.") | Out-Null
        }
    }
    if ([regex]::Matches($interactiveHtml, '<a class="dse-hero-action\b').Count -ne 1) {
        $errors.Add("Interactive lab must expose exactly one hero action.") | Out-Null
    }
    if ($interactiveHtml -notmatch '<nav class="dse-global-nav"[^>]*>\s*<a href="\.\./">\u2190 \u8FD4\u56DE\u9879\u76EE\u5730\u56FE</a>') {
        $errors.Add("Interactive lab has no persistent global return to the project map.") | Out-Null
    }
    if ($interactiveHtml -notmatch '\u2191 \u6536\u8D77\u9AD8\u7EA7\u6A21\u5F0F') {
        $errors.Add("Advanced mode does not expose its local close action.") | Out-Null
    }
    if ($interactiveHtml -match '<details class="dse-advanced-shell" id="dse-advanced-shell" open') {
        $errors.Add("Interactive advanced content must be collapsed by default.") | Out-Null
    }
    if ($interactiveHtml -match 'href="interactive/"') {
        $errors.Add("Interactive page contains a self-referential nested link.") | Out-Null
    }
    if ($interactiveHtml -match '\u5408\u6210(?:\u57FA\u51C6|\u57FA\u7EBF)') {
        $errors.Add("Interactive page still uses the ambiguous synthetic-baseline label.") | Out-Null
    }
    if ($interactiveHtml -notmatch '\u53EF\u91CD\u590D\u57FA\u51C6\u6D4B\u8BD5') {
        $errors.Add("Interactive workload selector does not use the plain-language benchmark label.") | Out-Null
    }
    if ($interactiveHtml -notmatch 'applyFilter\(button\.dataset\.filter, false\)') {
        $errors.Add("Interactive filter controls must preserve their current scroll position.") | Out-Null
    }
    if ($interactiveHtml -match '\u91CD\u65B0\u6F14\u793A\u672C\u573A\u666F') {
        $errors.Add("Interactive completion prompt still uses the old replay-only action.") | Out-Null
    }
    if ($interactiveHtml -notmatch 'navigator\.clipboard\.writeText') {
        $errors.Add("Interactive guided result has no copy-to-Codex continuation.") | Out-Null
    }

    foreach ($entry in @(
        @{ Name = "Index"; Path = $indexPath; Html = $indexHtml },
        @{ Name = "Interactive"; Path = $interactivePath; Html = $interactiveHtml }
    )) {
        $ids = [regex]::Matches($entry.Html, '(?i)\sid="([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }
        $duplicateIds = $ids | Group-Object | Where-Object { $_.Count -gt 1 }
        foreach ($duplicate in $duplicateIds) {
            $errors.Add("$($entry.Name) contains duplicate id '$($duplicate.Name)'.") | Out-Null
        }

        $baseDirectory = Split-Path -Parent $entry.Path
        foreach ($match in [regex]::Matches($entry.Html, '(?i)\shref="([^"]+)"')) {
            $href = $match.Groups[1].Value
            if ($href.StartsWith("#")) {
                $fragment = $href.Substring(1)
                if ($fragment -and $ids -notcontains $fragment) {
                    $errors.Add("$($entry.Name) has missing fragment target $href.") | Out-Null
                }
                continue
            }
            if ($href -match '^(?:https?:|mailto:|data:|javascript:)') {
                continue
            }
            $pathOnly = ($href -split '[?#]', 2)[0]
            if ([string]::IsNullOrWhiteSpace($pathOnly)) {
                continue
            }
            $target = [IO.Path]::GetFullPath((Join-Path $baseDirectory $pathOnly))
            if (Test-Path -LiteralPath $target -PathType Container) {
                $target = Join-Path $target "index.html"
            }
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
                $errors.Add("$($entry.Name) has missing local link target $href.") | Out-Null
            }
        }
    }

    if ($errors.Count -eq 0) {
        $orreryHtml = Get-Content -Raw -LiteralPath $orreryPath -Encoding UTF8
        if ($orreryHtml -notmatch '<nav class="global-nav"[^>]*>\s*<a href="\.\./">\u2190 \u8FD4\u56DE\u9879\u76EE\u5730\u56FE</a>') {
            $errors.Add("Orrery has no persistent global return to the project map.") | Out-Null
        }
        if ($orreryHtml -notmatch '\u5F53\u524D\u6587\u4EF6\u661F\u7CFB|\u5F53\u524D\u5FEB\u7167') {
            $errors.Add("Orrery does not clearly identify its current 2.4.0 snapshot status.") | Out-Null
        }
        if ($orreryHtml -notmatch '86 \u4E2A\u6587\u4EF6|\u5F53\u524D\u5019\u9009 \u00B7 Skill 2\.4\.0') {
            $errors.Add("Orrery does not expose the current 2.4.0 file count and candidate status.") | Out-Null
        }
        if ($orreryHtml -match 'archive/1\.5\.2/') {
            $errors.Add("Orrery still exposes the local-only 1.5.2 archive.") | Out-Null
        }
        if ($orreryHtml -notmatch 'const CAMERA_PITCH_LIMIT = 1\.55;' -or
            $orreryHtml -notmatch '-CAMERA_PITCH_LIMIT,\s*CAMERA_PITCH_LIMIT') {
            $errors.Add("Orrery camera pitch does not use the intended symmetric free-orbit limit.") | Out-Null
        }
        if ($orreryHtml -notmatch 'rel="icon"') {
            $errors.Add("Orrery has no favicon declaration.") | Out-Null
        }

        $frozen = Get-Content -Raw -LiteralPath $frozenPath -Encoding UTF8 | ConvertFrom-Json
        $orreryText = [IO.File]::ReadAllText($orreryPath, [Text.UTF8Encoding]::new($false, $true))
        $orreryText = $orreryText.Replace("`r`n", "`n").Replace("`r", "`n")
        $orreryBytes = [Text.UTF8Encoding]::new($false).GetBytes($orreryText)
        $sha256 = [Security.Cryptography.SHA256]::Create()
        $orreryHash = -join (
            $sha256.ComputeHash($orreryBytes) |
                ForEach-Object { $_.ToString("X2") }
        )
        if ($frozen.version -ne "2.4.0" -or $frozen.status -ne "frozen" -or [int]$frozen.fileCount -ne 86) {
            $errors.Add("Orrery FROZEN.json version/status/file count is unexpected.") | Out-Null
        }
        if ($frozen.frozenAt -ne "2026-11-04" -or [string]::IsNullOrWhiteSpace($frozen.changes)) {
            $errors.Add("Orrery FROZEN.json is missing its freeze date or change summary.") | Out-Null
        }
        if ([int]$frozen.bytes -ne $orreryBytes.Length) {
            $errors.Add("Orrery FROZEN.json byte count is stale.") | Out-Null
        }
        if ($frozen.sha256 -ne $orreryHash) {
            $errors.Add("Orrery FROZEN.json SHA-256 is stale.") | Out-Null
        }
        $sha256.Dispose()
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

Write-Host "Skill evolution site check: PASS (candidate status, homepage hierarchy, 106 versions, current 86-file orrery, JavaScript syntax)" -ForegroundColor Green
