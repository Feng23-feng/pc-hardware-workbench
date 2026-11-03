[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CasePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [string]$CaseScriptPath = (Join-Path $PSScriptRoot "hardware-case.ps1"),

    [switch]$IncludeArtifacts
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

function Stop-WithReportInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Get-CaseFileFromPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = ConvertTo-LocalFilesystemPath -Path $Path
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return Join-Path $candidate "case.json"
    }
    return $candidate
}

function Get-Value {
    param(
        [AllowNull()][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$Name]) {
        return $Default
    }
    return $Object.$Name
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }
    $singleLine = ([string]$Value) -replace "[\p{Cc}\p{Cf}]", " "
    return [System.Net.WebUtility]::HtmlEncode($singleLine.Trim())
}

function ConvertTo-HtmlBlock {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }
    $text = ([string]$Value) -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", " "
    $encoded = [System.Net.WebUtility]::HtmlEncode($text.Trim())
    return ($encoded -replace "\r?\n", "<br>")
}

function ConvertTo-HtmlTimestamp {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return ""
    }
    try {
        if ($Value -is [datetimeoffset]) {
            $parsed = [datetimeoffset]$Value
        }
        elseif ($Value -is [datetime]) {
            $parsed = [datetimeoffset]$Value
        }
        else {
            $parsed = [datetimeoffset]::Parse(
                [string]$Value,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind
            )
        }
        return ConvertTo-HtmlText ($parsed.ToString("o", [Globalization.CultureInfo]::InvariantCulture))
    }
    catch {
        return ConvertTo-HtmlText $Value
    }
}

function Format-HtmlList {
    param([AllowNull()][object]$Value)

    $items = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0) {
        return '<span class="muted">None</span>'
    }
    return (@($items | ForEach-Object { "<li>$(ConvertTo-HtmlBlock $_)</li>" }) -join "")
}

function Get-EvidenceArtifactPath {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$CaseRoot
    )

    $importedPath = [string](Get-Value $Evidence "ImportedPath" "")
    if ([string]::IsNullOrWhiteSpace($importedPath) -or [IO.Path]::IsPathRooted($importedPath)) {
        return $null
    }
    $candidate = [IO.Path]::GetFullPath((Join-Path $CaseRoot $importedPath))
    $prefix = $CaseRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        return $null
    }
    if (Test-PathChainHasReparsePoint -Path $candidate) {
        return $null
    }
    return $candidate
}

function Test-SafeSvgForImageEmbedding {
    param([Parameter(Mandatory = $true)][string]$Text)

    $scanText = $Text -replace 'http://www\.w3\.org/2000/svg', ''
    $unsafe = @(
        '(?is)<!DOCTYPE\b',
        '(?is)<!ENTITY\b',
        '(?is)<script\b',
        '(?is)<foreignObject\b',
        '(?is)<iframe\b',
        '(?is)<object\b',
        '(?is)<embed\b',
        '(?is)\bon[a-z]+\s*=',
        '(?is)(?:href|src)\s*=\s*["'']\s*(?!#)',
        '(?is)url\s*\(\s*["'']?\s*(?!#)',
        '(?is)https?://'
    )
    foreach ($pattern in $unsafe) {
        if ($scanText -match $pattern) {
            return $false
        }
    }
    return $true
}

function Get-ArtifactPreview {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][ref]$EmbeddedBytes
    )

    if (-not $IncludeArtifacts) {
        return '<span class="muted">Artifact content not embedded</span>'
    }

    $artifactPath = Get-EvidenceArtifactPath -Evidence $Evidence -CaseRoot $CaseRoot
    if ($null -eq $artifactPath) {
        return '<span class="muted">External evidence has metadata only</span>'
    }

    $file = Get-Item -LiteralPath $artifactPath
    $extension = [IO.Path]::GetExtension($artifactPath).ToLowerInvariant()
    $textExtensions = @(".csv", ".txt", ".log", ".md", ".json", ".xml")
    $imageTypes = @{
        ".png" = "image/png"
        ".jpg" = "image/jpeg"
        ".jpeg" = "image/jpeg"
        ".gif" = "image/gif"
        ".webp" = "image/webp"
        ".svg" = "image/svg+xml"
    }
    $perFileLimit = 1048576
    $totalLimit = 8388608

    if ($file.Length -gt $perFileLimit -or ($EmbeddedBytes.Value + $file.Length) -gt $totalLimit) {
        return '<span class="muted">Preview skipped by the embedding size limit</span>'
    }

    if ($textExtensions -contains $extension) {
        $text = [IO.File]::ReadAllText($artifactPath, [Text.Encoding]::UTF8)
        $EmbeddedBytes.Value += $file.Length
        return "<details><summary>Text preview</summary><pre>$(ConvertTo-HtmlBlock $text)</pre></details>"
    }

    if ($imageTypes.ContainsKey($extension)) {
        if ($extension -eq ".svg") {
            $svgText = [IO.File]::ReadAllText($artifactPath, [Text.Encoding]::UTF8)
            if (-not (Test-SafeSvgForImageEmbedding -Text $svgText)) {
                return '<span class="muted">SVG preview skipped because it contains active or external content</span>'
            }
        }
        $bytes = [IO.File]::ReadAllBytes($artifactPath)
        if ($null -eq $bytes) {
            $bytes = [byte[]]@()
        }
        $EmbeddedBytes.Value += $bytes.Length
        $base64 = [Convert]::ToBase64String($bytes)
        return "<details><summary>Image preview</summary><img class=""artifact-image"" alt=""Evidence artifact preview"" src=""data:$($imageTypes[$extension]);base64,$base64""></details>"
    }

    return '<span class="muted">Metadata only for this file type</span>'
}

function Add-Card {
    param(
        [Parameter(Mandatory = $true)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Body
    )

    $Builder.AppendLine("<section class=`"card`"><h2>$Title</h2>$Body</section>") | Out-Null
}

try {
    $resolvedCaseScript = (Resolve-Path -LiteralPath $CaseScriptPath -ErrorAction Stop).Path
    $caseFile = Get-CaseFileFromPath -Path $CasePath
    if (-not (Test-Path -LiteralPath $caseFile -PathType Leaf)) {
        Stop-WithReportInputError "Hardware case file not found: $caseFile"
    }
    if (Test-PathChainHasReparsePoint -Path $caseFile) {
        Stop-WithReportInputError "Hardware case path resolves through a symbolic link, junction, or reparse point."
    }

    $powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $validationOutput = & $powershell -NoProfile -ExecutionPolicy Bypass `
            -File $resolvedCaseScript -Action Validate -CasePath $caseFile 2>&1
        $validationExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    if ($validationExitCode -ne 0) {
        $message = ($validationOutput | ForEach-Object { [string]$_ }) -join " "
        Stop-WithReportInputError "Hardware case validation failed: $message"
    }

    $case = Get-Content -Raw -LiteralPath $caseFile -Encoding UTF8 | ConvertFrom-Json
    $caseRoot = [IO.Path]::GetFullPath((Split-Path -Parent $caseFile))
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
    $embeddedBytes = 0
    $generatedAt = [datetimeoffset]::Now.ToString("o", [Globalization.CultureInfo]::InvariantCulture)

    $summaryBody = New-Object System.Text.StringBuilder
    $summaryBody.AppendLine("<div class=`"summary-grid`">") | Out-Null
    $summaryBody.AppendLine("<div><span>Device</span><strong>$(ConvertTo-HtmlText (Get-Value $case.device 'alias' 'Unknown'))</strong></div>") | Out-Null
    $summaryBody.AppendLine("<div><span>Platform</span><strong>$(ConvertTo-HtmlText (Get-Value $case.device 'platform' 'Unknown'))</strong></div>") | Out-Null
    $summaryBody.AppendLine("<div><span>Identity</span><strong>$(ConvertTo-HtmlText (Get-Value $case.device 'identityQuality' 'unknown'))</strong></div>") | Out-Null
    $summaryBody.AppendLine("<div><span>Status</span><strong>$(ConvertTo-HtmlText (Get-Value $case 'status' 'unknown'))</strong></div>") | Out-Null
    $summaryBody.AppendLine("<div><span>Created</span><strong>$(ConvertTo-HtmlTimestamp (Get-Value $case 'createdAt' ''))</strong></div>") | Out-Null
    $summaryBody.AppendLine("<div><span>Updated</span><strong>$(ConvertTo-HtmlTimestamp (Get-Value $case 'updatedAt' ''))</strong></div>") | Out-Null
    $summaryBody.AppendLine("</div>") | Out-Null
    $summaryBody.AppendLine("<div class=`"goal`"><span>Goal</span><p>$(ConvertTo-HtmlBlock (Get-Value $case 'goal' ''))</p></div>") | Out-Null
    $nextAction = [string](Get-Value $case "nextAction" "")
    $nextActionHtml = if ([string]::IsNullOrWhiteSpace($nextAction)) {
        '<span class="muted">No next action recorded</span>'
    }
    else {
        ConvertTo-HtmlBlock $nextAction
    }
    $summaryBody.AppendLine("<div class=`"next-action`"><span>Next action</span><p>$nextActionHtml</p></div>") | Out-Null

    $evidenceRows = New-Object System.Text.StringBuilder
    $artifactItems = New-Object System.Text.StringBuilder
    $evidenceRows.AppendLine("<div class=`"table-wrap`"><table><thead><tr><th>ID</th><th>Evidence</th><th>Captured</th><th>File</th><th>SHA-256</th></tr></thead><tbody>") | Out-Null
    foreach ($evidence in @($case.evidence)) {
        $originalName = [string](Get-Value $evidence "OriginalFileName" "")
        $importedPath = [string](Get-Value $evidence "ImportedPath" "")
        $fileLabel = if (-not [string]::IsNullOrWhiteSpace($originalName)) {
            $originalName
        }
        elseif (-not [string]::IsNullOrWhiteSpace($importedPath)) {
            [IO.Path]::GetFileName($importedPath)
        }
        else {
            "No file"
        }
        $evidenceRows.AppendLine("<tr><td>$(ConvertTo-HtmlText $evidence.Id)</td><td><strong>$(ConvertTo-HtmlText $evidence.Type)</strong><br>$(ConvertTo-HtmlBlock $evidence.Summary)</td><td>$(ConvertTo-HtmlTimestamp $evidence.CapturedAt)</td><td>$(ConvertTo-HtmlText $fileLabel)<br><span class=`"hash`">$(ConvertTo-HtmlText $importedPath)</span></td><td class=`"hash`">$(ConvertTo-HtmlText $evidence.Sha256)</td></tr>") | Out-Null
        if ($IncludeArtifacts -and -not [string]::IsNullOrWhiteSpace($importedPath)) {
            $preview = Get-ArtifactPreview -Evidence $evidence -CaseRoot $caseRoot -EmbeddedBytes ([ref]$embeddedBytes)
            $artifactItems.AppendLine("<article class=`"artifact-record`"><h3>$(ConvertTo-HtmlText $evidence.Id) preview</h3><p>$(ConvertTo-HtmlText $fileLabel)</p>$preview</article>") | Out-Null
        }
    }
    if (@($case.evidence).Count -eq 0) {
        $evidenceRows.AppendLine('<tr><td colspan="5" class="muted">No evidence recorded</td></tr>') | Out-Null
    }
    $evidenceRows.AppendLine("</tbody></table></div>") | Out-Null
    if ($IncludeArtifacts) {
        if ($artifactItems.Length -gt 0) {
            $evidenceRows.AppendLine($artifactItems.ToString()) | Out-Null
        }
        else {
            $evidenceRows.AppendLine('<p class="muted">No imported artifact previews are available</p>') | Out-Null
        }
    }
    else {
        $evidenceRows.AppendLine('<p class="muted">Artifact content not embedded</p>') | Out-Null
    }

    $baselineRows = New-Object System.Text.StringBuilder
    $baselineRows.AppendLine("<div class=`"table-wrap`"><table><thead><tr><th>ID</th><th>Status</th><th>Workload</th><th>Conditions</th><th>Evidence</th><th>Summary</th></tr></thead><tbody>") | Out-Null
    foreach ($baseline in @($case.baselines)) {
        $status = [string](Get-Value $baseline "Status" "unknown")
        $statusClass = switch ($status) {
            "valid" { "status-valid"; break }
            "provisional" { "status-provisional"; break }
            "none" { "status-none"; break }
            default { "status-unknown" }
        }
        $baselineRows.AppendLine("<tr><td>$(ConvertTo-HtmlText $baseline.Id)</td><td><span class=`"status $statusClass`">$(ConvertTo-HtmlText $status)</span></td><td>$(ConvertTo-HtmlBlock (Get-Value $baseline 'Workload' ''))</td><td>$(ConvertTo-HtmlBlock (Get-Value $baseline 'Conditions' ''))</td><td>$(ConvertTo-HtmlText (Get-Value $baseline 'EvidenceId' ''))</td><td>$(ConvertTo-HtmlBlock (Get-Value $baseline 'Summary' ''))</td></tr>") | Out-Null
    }
    if (@($case.baselines).Count -eq 0) {
        $baselineRows.AppendLine('<tr><td colspan="6" class="muted">No baselines recorded</td></tr>') | Out-Null
    }
    $baselineRows.AppendLine("</tbody></table></div>") | Out-Null

    $hypothesisItems = New-Object System.Text.StringBuilder
    foreach ($hypothesis in @($case.hypotheses)) {
        $hypothesisItems.AppendLine("<article class=`"record`"><div class=`"record-head`"><strong>$(ConvertTo-HtmlText $hypothesis.Id)</strong><span class=`"status`">$(ConvertTo-HtmlText $hypothesis.Status)</span></div><p>$(ConvertTo-HtmlBlock $hypothesis.Text)</p><h3>Supporting evidence</h3><ul>$(Format-HtmlList $hypothesis.Supporting)</ul><h3>Contradicting evidence</h3><ul>$(Format-HtmlList $hypothesis.Contradicting)</ul><h3>Next discriminating test</h3><p>$(ConvertTo-HtmlBlock (Get-Value $hypothesis 'NextTest' ''))</p></article>") | Out-Null
    }
    if (@($case.hypotheses).Count -eq 0) {
        $hypothesisItems.AppendLine('<p class="muted">No hypotheses recorded</p>') | Out-Null
    }

    $timelineRows = New-Object System.Text.StringBuilder
    $timelineRows.AppendLine("<div class=`"table-wrap`"><table><thead><tr><th>ID</th><th>Occurred</th><th>Type</th><th>Summary</th></tr></thead><tbody>") | Out-Null
    foreach ($event in @($case.timeline)) {
        $timelineRows.AppendLine("<tr><td>$(ConvertTo-HtmlText $event.Id)</td><td>$(ConvertTo-HtmlTimestamp $event.OccurredAt)</td><td>$(ConvertTo-HtmlText $event.Type)</td><td>$(ConvertTo-HtmlBlock $event.Summary)</td></tr>") | Out-Null
    }
    if (@($case.timeline).Count -eq 0) {
        $timelineRows.AppendLine('<tr><td colspan="4" class="muted">No timeline events recorded</td></tr>') | Out-Null
    }
    $timelineRows.AppendLine("</tbody></table></div>") | Out-Null

    $experimentRows = New-Object System.Text.StringBuilder
    $experimentRows.AppendLine("<div class=`"table-wrap`"><table><thead><tr><th>ID</th><th>Change</th><th>Expected</th><th>Result</th><th>Decision</th><th>Hypothesis</th></tr></thead><tbody>") | Out-Null
    foreach ($experiment in @($case.experiments)) {
        $experimentRows.AppendLine("<tr><td>$(ConvertTo-HtmlText $experiment.Id)</td><td>$(ConvertTo-HtmlBlock $experiment.Change)</td><td>$(ConvertTo-HtmlBlock $experiment.Expected)</td><td>$(ConvertTo-HtmlBlock $experiment.Result)</td><td>$(ConvertTo-HtmlText $experiment.Decision)</td><td>$(ConvertTo-HtmlText (Get-Value $experiment 'HypothesisId' ''))</td></tr>") | Out-Null
    }
    if (@($case.experiments).Count -eq 0) {
        $experimentRows.AppendLine('<tr><td colspan="6" class="muted">No experiments recorded</td></tr>') | Out-Null
    }
    $experimentRows.AppendLine("</tbody></table></div>") | Out-Null

    $warningItems = @($case.warnings | ForEach-Object { "<li>$(ConvertTo-HtmlBlock $_)</li>" }) -join ""
    if ([string]::IsNullOrWhiteSpace($warningItems)) {
        $warningItems = '<li class="muted">No case warnings recorded</li>'
    }

    $html = New-Object System.Text.StringBuilder
    $html.AppendLine("<!doctype html>") | Out-Null
    $html.AppendLine('<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src ''none''; img-src data:; style-src ''unsafe-inline''; base-uri ''none''; form-action ''none''">') | Out-Null
    $html.AppendLine("<title>Hardware case $(ConvertTo-HtmlText $case.caseId)</title>") | Out-Null
    $html.AppendLine(@"
<style>
:root { color-scheme: light dark; --bg:#f4f5f7; --panel:#ffffff; --text:#17181a; --muted:#686b70; --line:#d9dce1; --accent:#3157d5; --warn:#8a4b00; --warn-bg:#fff3d6; }
@media (prefers-color-scheme: dark) { :root { --bg:#101114; --panel:#181a1f; --text:#f1f2f4; --muted:#a5a8af; --line:#30333a; --accent:#91a8ff; --warn:#ffd18a; --warn-bg:#2b2112; } }
* { box-sizing: border-box; }
html,body { max-width:100%; overflow-x:hidden; }
body { margin:0; background:var(--bg); color:var(--text); font:15px/1.55 "Segoe UI", Arial, sans-serif; }
main { width:min(1180px, calc(100% - 32px)); min-width:0; margin:32px auto 64px; }
header { margin-bottom:20px; }
h1 { margin:0 0 8px; font-size:clamp(26px,4vw,42px); line-height:1.1; }
h2 { margin:0 0 16px; font-size:20px; }
h3 { margin:16px 0 6px; font-size:14px; color:var(--muted); text-transform:uppercase; letter-spacing:.04em; }
p { margin:8px 0; }
.muted { color:var(--muted); }
.notice { border:1px solid var(--line); background:var(--warn-bg); color:var(--warn); padding:12px 14px; border-radius:10px; margin:16px 0; overflow-wrap:anywhere; }
.card { min-width:0; background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:20px; margin:16px 0; }
.summary-grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:12px; }
.summary-grid div { border:1px solid var(--line); border-radius:10px; padding:12px; }
.summary-grid span,.goal > span,.next-action > span { display:block; color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.05em; }
.summary-grid strong { display:block; margin-top:4px; overflow-wrap:anywhere; }
.goal,.next-action { margin-top:16px; border-left:3px solid var(--accent); padding:4px 0 4px 14px; }
.table-wrap { max-width:100%; overflow:auto; -webkit-overflow-scrolling:touch; border:1px solid var(--line); border-radius:10px; }
table { width:100%; border-collapse:collapse; min-width:760px; }
th,td { padding:10px 12px; text-align:left; vertical-align:top; border-bottom:1px solid var(--line); }
th { color:var(--muted); font-size:12px; text-transform:uppercase; letter-spacing:.04em; background:rgba(127,127,127,.06); }
tr:last-child td { border-bottom:0; }
.hash { color:var(--muted); font:12px/1.4 Consolas, monospace; overflow-wrap:anywhere; }
.status { display:inline-block; border:1px solid var(--line); border-radius:999px; padding:2px 8px; font-size:12px; font-weight:600; }
.status-valid { color:#116329; border-color:#7ab88a; }
.status-provisional { color:#805800; border-color:#d2ae5d; }
.status-none { color:#9a2d2d; border-color:#d88d8d; }
.record { border-top:1px solid var(--line); padding:14px 0; }
.record:first-child { border-top:0; padding-top:0; }
.record-head { display:flex; justify-content:space-between; gap:12px; }
ul { margin:6px 0; padding-left:22px; }
details { margin:6px 0; }
summary { cursor:pointer; color:var(--accent); }
pre { max-height:360px; overflow:auto; white-space:pre-wrap; overflow-wrap:anywhere; background:rgba(127,127,127,.08); padding:12px; border-radius:8px; }
.artifact-image { display:block; max-width:100%; max-height:520px; margin:10px 0; border-radius:8px; }
.artifact-record { border-top:1px solid var(--line); margin-top:16px; padding-top:14px; }
.artifact-record h3 { margin-top:0; }
footer { color:var(--muted); font-size:13px; margin-top:24px; }
@media (max-width:640px) {
  main { width:calc(100% - 20px); margin:18px auto 40px; }
  .card { padding:16px; border-radius:12px; }
  .notice { font-size:14px; }
}
@media (max-width:480px) {
  .summary-grid { grid-template-columns:1fr; }
  th,td { padding:9px 10px; }
}
</style>
"@) | Out-Null
    $html.AppendLine("</head><body><main><header>") | Out-Null
    $html.AppendLine("<h1>Hardware case report</h1>") | Out-Null
    $html.AppendLine("<p class=`"muted`">Static offline report. No scripts, remote styles, fonts, trackers, or network requests are embedded.</p>") | Out-Null
    $html.AppendLine("</header>") | Out-Null
    $html.AppendLine("<div class=`"notice`"><strong>Review before sharing.</strong> This report can contain device details and sensitive evidence. Artifact content is $(if ($IncludeArtifacts) { "embedded" } else { "not embedded" }). Evidence hashes were verified when this report was generated.</div>") | Out-Null
    Add-Card -Builder $html -Title "Overview" -Body $summaryBody.ToString()
    Add-Card -Builder $html -Title "Evidence" -Body $evidenceRows.ToString()
    Add-Card -Builder $html -Title "Baselines" -Body $baselineRows.ToString()
    Add-Card -Builder $html -Title "Hypotheses" -Body $hypothesisItems.ToString()
    Add-Card -Builder $html -Title "Timeline" -Body $timelineRows.ToString()
    Add-Card -Builder $html -Title "Experiments" -Body $experimentRows.ToString()
    Add-Card -Builder $html -Title "Warnings" -Body "<ul>$warningItems</ul>"
    $html.AppendLine("<footer>Case $(ConvertTo-HtmlText $case.caseId). Generated $(ConvertTo-HtmlText $generatedAt). This report records state; it does not prove diagnosis or authorise hardware changes.</footer>") | Out-Null
    $html.AppendLine("</main></body></html>") | Out-Null

    $writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content $html.ToString()
    Write-Output $writtenPath
}
catch {
    Stop-WithReportInputError $_.Exception.Message
}
