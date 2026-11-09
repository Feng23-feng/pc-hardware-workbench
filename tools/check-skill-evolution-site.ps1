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
$homeTemplatePath = Join-Path $RepositoryRoot "tools\templates\skill-evolution-home.html"
$interactiveTemplatePath = Join-Path $RepositoryRoot "tools\templates\skill-evolution-interactive.html"
$crtCssPath = Join-Path $siteRoot "crt-backdrop.css"
$crtJsPath = Join-Path $siteRoot "crt-backdrop.js"
$orreryPreviewPath = Join-Path $siteRoot "assets\orrery-preview.png"
$orreryPath = Join-Path $siteRoot "orrery\index.html"
$frozenPath = Join-Path $siteRoot "orrery\FROZEN.json"

foreach ($path in @(
    $indexPath,
    $interactivePath,
    $homeTemplatePath,
    $interactiveTemplatePath,
    $crtCssPath,
    $crtJsPath,
    $orreryPreviewPath,
    $orreryPath,
    $frozenPath
)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing site file: $path") | Out-Null
    }
}

if ($errors.Count -eq 0) {
    $homeTemplate = Get-Content -Raw -LiteralPath $homeTemplatePath -Encoding UTF8
    $interactiveTemplate = Get-Content -Raw -LiteralPath $interactiveTemplatePath -Encoding UTF8
    $pages = @(
        @{ Name = "Index"; Path = $indexPath; Template = $homeTemplate; SiteView = "index"; AssetPrefix = "." },
        @{ Name = "Interactive"; Path = $interactivePath; Template = $interactiveTemplate; SiteView = "interactive"; AssetPrefix = ".." }
    )

    foreach ($entry in $pages) {
        $html = Get-Content -Raw -LiteralPath $entry.Path -Encoding UTF8
        if (-not $html.Contains($entry.Template)) {
            $errors.Add("$($entry.Name) is not generated from its canonical source template.") | Out-Null
        }
        if ($html -notmatch [regex]::Escape("data-site-view=`"$($entry.SiteView)`"")) {
            $errors.Add("$($entry.Name) has the wrong data-site-view.") | Out-Null
        }
        if ($html -notmatch '<main id="dse-root"') {
            $errors.Add("$($entry.Name) does not use a main landmark for the site root.") | Out-Null
        }
        $styleHref = "$($entry.AssetPrefix)/crt-backdrop.css"
        $scriptSrc = "$($entry.AssetPrefix)/crt-backdrop.js"
        if ($html -notmatch [regex]::Escape("href=`"$styleHref`"")) {
            $errors.Add("$($entry.Name) does not load the shared CRT backdrop stylesheet.") | Out-Null
        }
        if ($html -notmatch [regex]::Escape("src=`"$scriptSrc`"")) {
            $errors.Add("$($entry.Name) does not load the shared CRT backdrop script.") | Out-Null
        }
        if ($html -notmatch '2\.5\.0' -or $html -notmatch 'PENDING') {
            $errors.Add("$($entry.Name) does not preserve version-archive metadata or pending verification status.") | Out-Null
        }
        if ($html -notmatch '\u6D4B\u8BD5\u7248') {
            $errors.Add("$($entry.Name) does not use the public test-release label.") | Out-Null
        }
        if ($html -match '\u672C\u5730\u6D4B\u8BD5\u5019\u9009|\u672C\u5730\u5019\u9009') {
            $errors.Add("$($entry.Name) still exposes the old local-candidate label.") | Out-Null
        }
        if ($html -match '\u6587\u4EF6\u661F\u7CFB|\u6D4F\u89C8\u6587\u4EF6\u661F\u7403') {
            $errors.Add("$($entry.Name) still uses an alternate name for the file planet.") | Out-Null
        }
        if ($entry.SiteView -eq "index" -and [regex]::Matches($html, 'class="dse-hero-action primary"').Count -ne 1) {
            $errors.Add("$($entry.Name) must expose exactly one primary hero action.") | Out-Null
        }
        if ($entry.SiteView -eq "interactive" -and $html -match 'class="dse-hero-action primary"') {
            $errors.Add("Interactive page still exposes a simple-mode hero action.") | Out-Null
        }
        if ($html -match '\u5B9E\u673A\u8BFB\u53D6\s*\d+\s*\u4E2A\u4F20\u611F\u5668|\u663E\u5B58\u65F6\u949F\s*\d{3,}\s*MHz|LHM Web \u5B9E\u8BFB|\u53EA\u5728\u672C\u673A\u4FDD\u7559') {
            $errors.Add("$($entry.Name) still exposes machine-specific observation copy.") | Out-Null
        }
        foreach ($headingMatch in [regex]::Matches($html, '(?is)<h[1-4][^>]*>(.*?)</h[1-4]>')) {
            $headingText = [regex]::Replace($headingMatch.Groups[1].Value, '<[^>]+>', '')
            $headingText = [Net.WebUtility]::HtmlDecode($headingText)
            if ($headingText -match '[\u3001\u3002\x21\x3F\uFF01\uFF1F\uFF0C\uFF1B\uFF1A]') {
                $errors.Add("$($entry.Name) display heading contains sentence punctuation: $headingText") | Out-Null
            }
        }
        $invalidWeights = [regex]::Matches($html, 'font-weight:\s*(\d+)', 'IgnoreCase') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notin @('400', '500', '600') } |
            Sort-Object -Unique
        if ($invalidWeights.Count -gt 0) {
            $errors.Add("$($entry.Name) uses unsupported font weights: $($invalidWeights -join ', ').") | Out-Null
        }
        foreach ($spacingMatch in [regex]::Matches($html, 'letter-spacing:\s*(-\d*\.\d+)em', 'IgnoreCase')) {
            $spacingValue = [double]::Parse($spacingMatch.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture)
            if ($spacingValue -lt -0.03) {
                $errors.Add("$($entry.Name) uses excessively tight letter spacing: $($spacingValue)em.") | Out-Null
                break
            }
        }
        if ($html -match 'text-transform:\s*uppercase') {
            $errors.Add("$($entry.Name) still contains uppercase label styling.") | Out-Null
        }
        if ($html -match 'animation:[^;]*infinite|repeatCount="indefinite"') {
            $errors.Add("$($entry.Name) still contains an infinite decorative animation.") | Out-Null
        }

        $ids = [regex]::Matches($html, '(?i)\sid="([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value }
        foreach ($duplicate in ($ids | Group-Object | Where-Object { $_.Count -gt 1 })) {
            $errors.Add("$($entry.Name) contains duplicate id '$($duplicate.Name)'.") | Out-Null
        }

        $baseDirectory = Split-Path -Parent $entry.Path
        $baseMatch = [regex]::Match($html, '(?i)<base\s+href="([^"]+)"')
        if ($baseMatch.Success) {
            $baseDirectory = [IO.Path]::GetFullPath((Join-Path $baseDirectory $baseMatch.Groups[1].Value))
        }
        foreach ($match in [regex]::Matches($html, '(?i)<a\b[^>]*\shref="([^"]+)"')) {
            $href = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
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

    $indexHtml = Get-Content -Raw -LiteralPath $indexPath -Encoding UTF8
    $crtCss = Get-Content -Raw -LiteralPath $crtCssPath -Encoding UTF8
    $crtJs = Get-Content -Raw -LiteralPath $crtJsPath -Encoding UTF8
    if ($crtCss -notmatch '@view-transition' -or $crtCss -notmatch '::view-transition-new\(root\)') {
        $errors.Add("Shared CRT stylesheet is missing the cross-document page transition.") | Out-Null
    }
    if ($crtJs -notmatch 'let hasScanned = false' -or $crtJs -match 'loopTimer = window\.setTimeout\(startScan') {
        $errors.Add("CRT backdrop must scan once per page and then remain static.") | Out-Null
    }
    if ($indexHtml -match '<section class="dse-about"') {
        $errors.Add("Index still contains the removed philosophy and three-column section.") | Out-Null
    }
    if ($indexHtml -match '\u5148\u770B\u61C2 \u518D\u52A8\u624B|\u53EA\u8BFB</strong>|\u6709\u8BC1\u636E</strong>|\u4E0D\u8D8A\u754C</strong>') {
        $errors.Add("Index still contains removed philosophy copy.") | Out-Null
    }
    if ($indexHtml -notmatch '<a class="dse-hero-action primary" href="#dse-home-flow">') {
        $errors.Add("Index primary CTA does not lead to the single-path usage section.") | Out-Null
    }
    foreach ($marker in @(
        'id="dse-how-title"',
        'class="dse-howto dse-home-flow"',
        'id="dse-home-step-1"',
        'id="dse-home-step-2"',
        'id="dse-home-step-3"',
        'id="dse-home-question-options"',
        'id="dse-home-evidence-options"',
        'id="dse-home-result"',
        'class="dse-hero-safety"',
        'class="dse-candidate"',
        'id="dse-candidate-title"',
        'class="dse-candidate-summary"',
        'class="dse-advanced-entry"',
        'class="dse-explore dse-explore-primary"',
        'class="dse-file-map"',
        'SKILL.md',
        'href="interactive/"',
        'href="orrery/"',
        'aria-controls="dse-home-technical-content"',
        'class="dse-home-technical"',
        'id="dse-home-technical-summary"'
    )) {
        if ($indexHtml -notmatch [regex]::Escape($marker)) {
            $errors.Add("Index hierarchy is missing $marker.") | Out-Null
        }
    }
    if ([regex]::Matches($indexHtml, 'class="dse-explore dse-explore-primary"[^>]*>\s*<a\b').Count -ne 1) {
        $errors.Add("Index primary-path navigation is missing.") | Out-Null
    }
    if ($indexHtml -notmatch '\u8FDB\u5165\u6587\u4EF6\u661F\u7403' -or
        $indexHtml -notmatch 'src="assets/orrery-preview\.png"') {
        $errors.Add("Index does not use the unified file planet action and preview image.") | Out-Null
    }
    $candidatePosition = $indexHtml.IndexOf('<section class="dse-candidate"')
    $technicalPosition = $indexHtml.IndexOf('<details class="dse-home-technical"')
    if ($candidatePosition -lt 0 -or $technicalPosition -lt 0 -or $candidatePosition -gt $technicalPosition) {
        $errors.Add("Index usable-state block is not visible before the technical archive.") | Out-Null
    }
    if ($indexHtml -notmatch '\u770B\u61C2\u4F60\u7684\u7535\u8111' -or
        $indexHtml -notmatch '\u67E5\u770B\u5F53\u524D\u914D\u7F6E' -or
        $indexHtml -notmatch '\u8003\u8651\u5347\u7EA7') {
        $errors.Add("Index does not state the full configuration, troubleshooting, tuning and upgrade scope.") | Out-Null
    }
    if ([regex]::Matches($indexHtml, 'class="dse-candidate-summary"').Count -ne 1 -or
        [regex]::Matches($indexHtml, '<div>\s*<dt>').Count -ne 3) {
        $errors.Add("Index usable-state summary must contain exactly three key facts.") | Out-Null
    }
    if ($indexHtml -match '\u67E5\u770B\u6280\u672F\u4E0E\u53D1\u5E03\u8BF4\u660E|\u8DEF\u5F84\uFF1A\u5B89\u5168\u8FB9\u754C|\u4EA4\u4E92\u5B9E\u9A8C\u5BA4') {
        $errors.Add("Index still exposes a duplicate technical entry or internal maintenance language.") | Out-Null
    }

    $interactiveHtml = Get-Content -Raw -LiteralPath $interactivePath -Encoding UTF8
    if ($homeTemplate -notmatch 'animateHomeEntry' -or $interactiveTemplate -notmatch 'animateAdvancedEntry') {
        $errors.Add("Motion helpers for home steps and advanced panels are missing.") | Out-Null
    }
    if ($interactiveHtml -match '<base\b') {
        $errors.Add("Interactive page must not use a base tag that changes same-page hash navigation.") | Out-Null
    }
    if ($interactiveHtml -notmatch '<nav class="dse-global-nav"[^>]*>\s*<a href="\.\./" id="dse-return-home">\u2190 \u8FD4\u56DE\u9996\u9875</a>') {
        $errors.Add("Interactive page has no clear return-home action.") | Out-Null
    }
    foreach ($marker in @(
        'class="dse-advanced-page-head"',
        'id="dse-interactive-technical"',
        'id="dse-interactive-technical-summary"',
        'aria-controls="dse-interactive-technical-content"',
        'id="dse-advanced-shell"',
        'id="dse-advanced-summary"',
        'aria-controls="dse-advanced-content"',
        'data-demo-mode="terms"',
        'data-demo-mode="tune"',
        'data-demo-mode="triage"',
        'data-demo-mode="record"',
        'class="dse-term-more"',
        'id="dse-triage-category-grid"',
        'id="dse-triage-workflow"',
        'id="dse-context-bridge"',
        'id="dse-context-title"',
        'id="dse-context-summary"',
        'id="dse-direct-feedback"',
        'id="dse-direct-feedback-title"',
        'data-gate-action="direct"',
        'class="dse-interactive-technical"'
    )) {
        if ($interactiveHtml -notmatch [regex]::Escape($marker)) {
            $errors.Add("Interactive hierarchy is missing $marker.") | Out-Null
        }
    }
    if ($interactiveHtml -match '\u4EA4\u4E92\u5B9E\u9A8C\u5BA4|\u4EA4\u4E92\u6F14\u793A|\u9AD8\u7EA7\u6A21\u5F0F\u4E0E\u6280\u672F\u6863\u6848|\u8FD4\u56DE\u4E0A\u4E00\u6B65') {
        $errors.Add("Interactive page still exposes inconsistent advanced-mode naming or return copy.") | Out-Null
    }
    if ($interactiveHtml -match 'class="dse-guided"|id="dse-guided-(?:scenario|next|prev|reset|evidence|outcome|recommendation|show-reason|open-advanced)') {
        $errors.Add("Interactive page still contains the migrated simple-mode flow.") | Out-Null
    }
    $demoModeButtons = [regex]::Matches($interactiveHtml, '<button[^>]*class="dse-filter"[^>]*data-demo-mode="([^"]+)"')
    $demoModeNames = @($demoModeButtons | ForEach-Object { $_.Groups[1].Value })
    if (
        $demoModeButtons.Count -ne 4 -or
        @($demoModeNames | Sort-Object -Unique).Count -ne 4 -or
        @($demoModeNames | Where-Object { $_ -match '^(identity|evidence)$' }).Count -gt 0
    ) {
        $errors.Add("Interactive page must expose exactly four consolidated demo themes.") | Out-Null
    }
    if ($interactiveHtml -match 'class="dse-guided-reason"[^>]*\sopen(?:\s|>)') {
        $errors.Add("Interactive evidence reasoning must be collapsed by default.") | Out-Null
    }

    $start = $homeTemplate.IndexOf('const versionSeries = [')
    $end = $homeTemplate.IndexOf('const versionRecords =', $start)
    if ($start -lt 0 -or $end -le $start) {
        $errors.Add("Home source versionSeries data is missing.") | Out-Null
    }
    else {
        $segment = $homeTemplate.Substring($start, $end - $start)
        $versionCount = [regex]::Matches($segment, '(?m)^\s*\["\d+\.\d+\.\d+(?:-r\d+)?",').Count
        if ($versionCount -ne 107) {
            $errors.Add("Home source version count is $versionCount, expected 107.") | Out-Null
        }
        if ($segment -notmatch '\["2\.5\.0"[^\r\n]*CURRENT CANDIDATE') {
            $errors.Add("Home source current 2.5.0 archive record is missing.") | Out-Null
        }
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
        & $node.Source --check $crtJsPath
        if ($LASTEXITCODE -ne 0) {
            $errors.Add("CRT backdrop JavaScript syntax check failed: $crtJsPath") | Out-Null
        }
    }

    $orreryHtml = Get-Content -Raw -LiteralPath $orreryPath -Encoding UTF8
    if ($orreryHtml -notmatch '@view-transition' -or $orreryHtml -notmatch 'orrery-view-in') {
        $errors.Add("Orrery is missing the shared cross-document page transition.") | Out-Null
    }
    $orreryIds = [regex]::Matches($orreryHtml, '(?i)\sid="([^"]+)"') |
        ForEach-Object { $_.Groups[1].Value }
    foreach ($duplicate in ($orreryIds | Group-Object | Where-Object { $_.Count -gt 1 })) {
        $errors.Add("Orrery contains duplicate id '$($duplicate.Name)'.") | Out-Null
    }
    if ($orreryHtml -notmatch '<nav class="global-nav"[^>]*>\s*<a href="\.\./">\u2190 \u8FD4\u56DE\u9879\u76EE\u5730\u56FE</a>') {
        $errors.Add("Orrery has no persistent global return to the project map.") | Out-Null
    }
    if ($orreryHtml -notmatch '\u5F53\u524D\u6587\u4EF6\u661F\u7CFB|\u5F53\u524D\u5FEB\u7167') {
        $errors.Add("Orrery does not identify its current snapshot.") | Out-Null
    }
    if ($orreryHtml -notmatch '90 \u4E2A\u6587\u4EF6|\u5F53\u524D\u5019\u9009 \u00B7 Skill 2\.5\.0') {
        $errors.Add("Orrery does not expose the current 90-file snapshot.") | Out-Null
    }
    if ($orreryHtml -match 'archive/1\.5\.2/') {
        $errors.Add("Orrery still exposes the local-only 1.5.2 archive.") | Out-Null
    }
    if ($orreryHtml -notmatch 'const CAMERA_PITCH_LIMIT = 1\.55;' -or
        $orreryHtml -notmatch '-CAMERA_PITCH_LIMIT,\s*CAMERA_PITCH_LIMIT') {
        $errors.Add("Orrery camera pitch does not use the intended symmetric free-orbit limit.") | Out-Null
    }
    if ($orreryHtml -notmatch 'id="selectionReset"[^>]*>\u91CD\u7F6E\u9009\u62E9</button>' -or
        $orreryHtml -notmatch 'function clearFileSelection\(\)' -or
        $orreryHtml -notmatch 'selectionReset\.addEventListener\("click", clearFileSelection\)') {
        $errors.Add("Orrery does not provide a visible reset-selection control.") | Out-Null
    }
    if ($orreryHtml -notmatch 'rel="icon"') {
        $errors.Add("Orrery has no favicon declaration.") | Out-Null
    }

    $frozen = Get-Content -Raw -LiteralPath $frozenPath -Encoding UTF8 | ConvertFrom-Json
    $orreryText = [IO.File]::ReadAllText($orreryPath, [Text.UTF8Encoding]::new($false, $true))
    $orreryText = $orreryText.Replace("`r`n", "`n").Replace("`r", "`n")
    $orreryBytes = [Text.UTF8Encoding]::new($false).GetBytes($orreryText)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $orreryHash = -join (
            $sha256.ComputeHash($orreryBytes) |
                ForEach-Object { $_.ToString("X2") }
        )
    }
    finally {
        $sha256.Dispose()
    }
    if ($frozen.version -ne "2.5.0" -or $frozen.status -ne "frozen" -or [int]$frozen.fileCount -ne 90) {
        $errors.Add("Orrery FROZEN.json version/status/file count is unexpected.") | Out-Null
    }
    if ([int]$frozen.bytes -ne $orreryBytes.Length -or $frozen.sha256 -ne $orreryHash) {
        $errors.Add("Orrery FROZEN.json metadata is stale.") | Out-Null
    }
}

if ($errors.Count -gt 0) {
    Write-Host "Skill evolution site check: FAIL" -ForegroundColor Red
    foreach ($errorMessage in $errors) {
        Write-Host "- $errorMessage" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Skill evolution site check: PASS (two canonical templates, single visible path, technical archives folded, 90-file orrery, JavaScript syntax)" -ForegroundColor Green
