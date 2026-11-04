[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$BaselinePath,

    [string]$CandidatePath,

    [Parameter(Mandatory = $true, Position = 1)]
    [string]$OutputDirectory,

    [string]$BaselineLabel = "Baseline",

    [string]$CandidateLabel = "Candidate",

    [string]$Workload,

    [string]$Change,

    [string[]]$FocusMetric = @(),

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$WarmupSeconds = 0,

    [ValidateRange(0.0, [double]::MaxValue)]
    [double]$DurationSeconds = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$WarmupRows = 0,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$MaxRows = 0,

    [ValidateSet(",", ";", "`t")]
    [string]$Delimiter = ",",

    [string[]]$IncludeColumn = @(),

    [switch]$HideFileName,

    [ValidateRange(1, 4096)]
    [int]$MaxInputMegabytes = 512,

    [ValidateRange(20, 5000)]
    [int]$MaxChartPoints = 480,

    [ValidateRange(1, 8)]
    [int]$MaxSeries = 3,

    [ValidateRange(1, 20)]
    [int]$MaxComparisonMetrics = 8
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$powershellExe = (Get-Command "powershell.exe" -ErrorAction Stop).Source
$pathHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
$analyzerPath = Join-Path $PSScriptRoot "analyze-telemetry.ps1"
$normalizerPath = Join-Path $PSScriptRoot "normalize-telemetry.ps1"
$rendererPath = Join-Path $PSScriptRoot "render-telemetry-chart.ps1"
$templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) "assets/evidence-card-template.html"

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Stop-WithPipelineError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

foreach ($required in @($pathHelper, $analyzerPath, $normalizerPath, $rendererPath, $templatePath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Stop-WithPipelineError "Required evidence-pipeline file is missing: $required"
    }
}
. $pathHelper

$usesTimeWindow = $WarmupSeconds -gt 0 -or $DurationSeconds -gt 0
$usesRowWindow = $WarmupRows -gt 0 -or $MaxRows -gt 0
if ($usesTimeWindow -and $usesRowWindow) {
    Stop-WithInputError "Use time-based window parameters or row-based window parameters, not both."
}
if (-not [string]::IsNullOrWhiteSpace($CandidatePath) -and [string]::IsNullOrWhiteSpace($Workload)) {
    Stop-WithInputError "A baseline/candidate comparison requires -Workload so both runs share a declared workload context."
}

try {
    $baselineResolved = Assert-LocalReadFilePath -Path $BaselinePath
    $candidateResolved = if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        $null
    }
    else {
        Assert-LocalReadFilePath -Path $CandidatePath
    }
    if ($candidateResolved -and $candidateResolved -eq $baselineResolved) {
        Stop-WithInputError "BaselinePath and CandidatePath must refer to different files."
    }

    $outputRoot = ConvertTo-LocalFilesystemPath -Path $OutputDirectory
    if (Test-PathChainHasReparsePoint -Path $outputRoot) {
        Stop-WithInputError "OutputDirectory resolves through a symbolic link, junction, or reparse point."
    }
    if (-not (Test-Path -LiteralPath $outputRoot -PathType Container)) {
        [IO.Directory]::CreateDirectory($outputRoot) | Out-Null
    }

    $timestamp = [DateTimeOffset]::Now.ToString("yyyyMMdd-HHmmss", $invariant)
    $runId = "evidence-$timestamp-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
    $runDirectory = Join-Path $outputRoot $runId
    [IO.Directory]::CreateDirectory($runDirectory) | Out-Null
    $generatedAt = [DateTimeOffset]::Now.ToString("o", $invariant)
}
catch {
    Stop-WithInputError $_.Exception.Message
}

function Invoke-PipelineChild {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $output = & $powershellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = (@($output) | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0) {
        throw "$Description failed with exit code $exitCode.`n$text"
    }
    return $text
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Format-Number {
    param(
        [AllowNull()][object]$Value,
        [string]$Suffix = ""
    )
    if ($null -eq $Value) {
        return "n/a"
    }
    return ([double]$Value).ToString("0.###", $invariant) + $Suffix
}

function Format-SignedNumber {
    param(
        [AllowNull()][object]$Value,
        [string]$Suffix = ""
    )
    if ($null -eq $Value) {
        return "n/a"
    }
    $number = [double]$Value
    $prefix = if ($number -gt 0) { "+" } else { "" }
    return $prefix + $number.ToString("0.###", $invariant) + $Suffix
}

function ConvertTo-HtmlText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

function Get-AnalysisArguments {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ExtraArguments
    )
    $arguments = @(
        "-Path", $Path,
        "-Delimiter", $Delimiter,
        "-MaxInputMegabytes", [string]$MaxInputMegabytes,
        "-MaxChartPoints", [string]$MaxChartPoints
    ) + $ExtraArguments
    if ($WarmupSeconds -gt 0) { $arguments += @("-WarmupSeconds", [string]$WarmupSeconds) }
    if ($DurationSeconds -gt 0) { $arguments += @("-DurationSeconds", [string]$DurationSeconds) }
    if ($WarmupRows -gt 0) { $arguments += @("-WarmupRows", [string]$WarmupRows) }
    if ($MaxRows -gt 0) { $arguments += @("-MaxRows", [string]$MaxRows) }
    if ($IncludeColumn.Count -gt 0) {
        $arguments += @("-IncludeColumn") + $IncludeColumn
    }
    if ($HideFileName) {
        $arguments += "-HideFileName"
    }
    return $arguments
}

function Get-EvidenceInput {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $analysisPath = Join-Path $runDirectory "$Name.analysis.json"
    $normalizedPath = Join-Path $runDirectory "$Name.normalized.json"
    $chartPath = Join-Path $runDirectory "$Name.chart.svg"

    try {
        $analysisText = Invoke-PipelineChild `
            -ScriptPath $analyzerPath `
            -Arguments (Get-AnalysisArguments -Path $Path -ExtraArguments @("-Format", "Json")) `
            -Description "$Label analysis"
        $analysis = $analysisText | ConvertFrom-Json
        [IO.File]::WriteAllText($analysisPath, ($analysisText.TrimEnd() + "`n"), $utf8NoBom)

        $normalizerText = Invoke-PipelineChild `
            -ScriptPath $normalizerPath `
            -Arguments (Get-AnalysisArguments -Path $Path -ExtraArguments @("-OutputPath", $normalizedPath, "-InputFormat", "Csv")) `
            -Description "$Label normalization"
        if (-not (Test-Path -LiteralPath $normalizedPath -PathType Leaf)) {
            throw "$Label normalization did not create $normalizedPath. $normalizerText"
        }
        $normalized = [IO.File]::ReadAllText($normalizedPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

        $chartText = Invoke-PipelineChild `
            -ScriptPath $rendererPath `
            -Arguments @(
                "-Path", $normalizedPath,
                "-OutputPath", $chartPath,
                "-InputFormat", "NormalizedJson",
                "-MaxSeries", [string]$MaxSeries,
                "-Title", "$Label telemetry"
            ) `
            -Description "$Label chart"
        if (-not (Test-Path -LiteralPath $chartPath -PathType Leaf)) {
            throw "$Label chart renderer did not create $chartPath. $chartText"
        }
    }
    catch {
        throw $_.Exception.Message
    }

    $fileName = if ($HideFileName) { "[hidden]" } else { [IO.Path]::GetFileName($Path) }
    return [pscustomobject]@{
        Name = $Name
        Label = $Label
        InputFileName = $fileName
        InputSha256 = Get-Sha256Hex -Path $Path
        InputBytes = (Get-Item -LiteralPath $Path).Length
        AnalysisPath = $analysisPath
        NormalizedPath = $normalizedPath
        ChartPath = $chartPath
        Analysis = $analysis
        Normalized = $normalized
        Hashes = [ordered]@{
            analysis = Get-Sha256Hex -Path $analysisPath
            normalized = Get-Sha256Hex -Path $normalizedPath
            chart = Get-Sha256Hex -Path $chartPath
        }
    }
}

function Get-MetricKey {
    param([Parameter(Mandatory = $true)][object]$Metric)
    return (([string]$Metric.Metric).ToLowerInvariant() + "|" + ([string]$Metric.Unit).ToLowerInvariant())
}

function Get-Comparison {
    param(
        [Parameter(Mandatory = $true)][object]$Baseline,
        [AllowNull()][object]$Candidate
    )

    if ($null -eq $Candidate) {
        return [pscustomobject]@{
            Status = "baseline-ready"
            Workload = $Workload
            CommonMetricCount = 0
            Metrics = @()
            Warnings = @("No candidate run was supplied. Run the same fixed workload after the change.")
            NextAction = "Record a candidate run under the same workload and comparable conditions."
        }
    }

    $candidateByKey = @{}
    foreach ($metric in @($Candidate.Analysis.Metrics)) {
        $candidateByKey[(Get-MetricKey $metric)] = $metric
    }
    $baselineKeys = @{}
    $comparisonRows = New-Object System.Collections.Generic.List[object]
    foreach ($baseMetric in @($Baseline.Analysis.Metrics)) {
        $key = Get-MetricKey $baseMetric
        $baselineKeys[$key] = $true
        if (-not $candidateByKey.ContainsKey($key)) {
            continue
        }
        $candidateMetric = $candidateByKey[$key]
        $meanDelta = [double]$candidateMetric.Mean - [double]$baseMetric.Mean
        $p95Delta = [double]$candidateMetric.P95 - [double]$baseMetric.P95
        $maxDelta = [double]$candidateMetric.Max - [double]$baseMetric.Max
        $percent = $null
        if (
            [Math]::Abs([double]$baseMetric.Mean) -gt 0.000001 -and
            [string]$baseMetric.Unit -notin @("C", "°C", "%")
        ) {
            $percent = $meanDelta / [Math]::Abs([double]$baseMetric.Mean) * 100
        }
        $direction = if ($meanDelta -gt 0.000001) {
            "higher"
        }
        elseif ($meanDelta -lt -0.000001) {
            "lower"
        }
        else {
            "same"
        }
        $comparisonRows.Add([pscustomobject]@{
            Metric = [string]$baseMetric.Metric
            Unit = [string]$baseMetric.Unit
            Direction = $direction
            BaselineMean = [double]$baseMetric.Mean
            CandidateMean = [double]$candidateMetric.Mean
            MeanDelta = $meanDelta
            MeanDeltaPercent = $percent
            BaselineP95 = [double]$baseMetric.P95
            CandidateP95 = [double]$candidateMetric.P95
            P95Delta = $p95Delta
            BaselineMax = [double]$baseMetric.Max
            CandidateMax = [double]$candidateMetric.Max
            MaxDelta = $maxDelta
        }) | Out-Null
    }

    $missingInCandidate = @(
        @($Baseline.Analysis.Metrics) |
            Where-Object { -not $candidateByKey.ContainsKey((Get-MetricKey $_)) } |
            ForEach-Object { [string]$_.Metric }
    )
    $extraInCandidate = @(
        @($Candidate.Analysis.Metrics) |
            Where-Object { -not $baselineKeys.ContainsKey((Get-MetricKey $_)) } |
            ForEach-Object { [string]$_.Metric }
    )

    $warnings = New-Object System.Collections.Generic.List[string]
    if ($comparisonRows.Count -eq 0) {
        $warnings.Add("No common metric name and unit pair was found. The runs cannot be compared directly.") | Out-Null
    }
    if ($missingInCandidate.Count -gt 0) {
        $warnings.Add("Metrics missing from the candidate: $($missingInCandidate -join ', ')") | Out-Null
    }
    if ($extraInCandidate.Count -gt 0) {
        $warnings.Add("Metrics present only in the candidate: $($extraInCandidate -join ', ')") | Out-Null
    }
    if ([string]$Baseline.Analysis.Window -ne [string]$Candidate.Analysis.Window) {
        $warnings.Add("The analyzed windows differ. Confirm that both runs use the same warm-up and fixed workload window.") | Out-Null
    }
    $baseInterval = [double]$Baseline.Analysis.Sampling.IntervalSecondsMedian
    $candidateInterval = [double]$Candidate.Analysis.Sampling.IntervalSecondsMedian
    if (
        [double]::IsNaN($baseInterval) -or
        [double]::IsNaN($candidateInterval) -or
        [Math]::Abs($baseInterval - $candidateInterval) -gt [Math]::Max(0.1, $baseInterval * 0.2)
    ) {
        $warnings.Add("Sampling intervals differ or are unknown. Confirm the same monitoring interval before comparing results.") | Out-Null
    }
    if ([string]$Baseline.Analysis.Sampling.Consistency -ne "stable" -or [string]$Candidate.Analysis.Sampling.Consistency -ne "stable") {
        $warnings.Add("One or both runs have non-stable or unknown sampling. Treat the comparison as preliminary.") | Out-Null
    }

    $selectedRows = New-Object System.Collections.Generic.List[object]
    if ($FocusMetric.Count -gt 0) {
        foreach ($focus in $FocusMetric) {
            $matched = @($comparisonRows | Where-Object { $_.Metric -like "*$focus*" })
            if ($matched.Count -eq 0) {
                $warnings.Add("Requested focus metric was not found in both runs: $focus") | Out-Null
            }
            foreach ($row in $matched) {
                if (-not @($selectedRows | Where-Object { $_.Metric -eq $row.Metric -and $_.Unit -eq $row.Unit }).Count) {
                    $selectedRows.Add($row) | Out-Null
                }
            }
        }
    }
    if ($selectedRows.Count -eq 0) {
        foreach ($row in @($comparisonRows | Select-Object -First $MaxComparisonMetrics)) {
            $selectedRows.Add($row) | Out-Null
        }
    }
    $finalSelectedRows = @($selectedRows | Select-Object -First $MaxComparisonMetrics)

    $status = if ($comparisonRows.Count -eq 0) {
        "retest"
    }
    elseif ($warnings.Count -gt 0) {
        "review"
    }
    else {
        "ready-for-review"
    }
    $nextAction = if ($status -eq "retest") {
        "Repeat both runs with the same sensor set, workload, and analysis window."
    }
    elseif ($status -eq "review") {
        "Review the warnings and deltas before keeping, reverting, or repeating the change."
    }
    else {
        "Apply the user's pass and abort criteria, then choose keep, continue, revert, or stop."
    }

    return [pscustomobject]@{
        Status = $status
        Workload = $Workload
        CommonMetricCount = $comparisonRows.Count
        Metrics = @($finalSelectedRows)
        AllMetrics = @($comparisonRows.ToArray())
        MissingInCandidate = $missingInCandidate
        ExtraInCandidate = $extraInCandidate
        Warnings = @($warnings.ToArray())
        NextAction = $nextAction
    }
}

function ConvertTo-WarningList {
    param([AllowNull()][object[]]$Warnings)
    $items = @($Warnings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0) {
        return "<p class=`"empty`">No analysis warnings</p>"
    }
    return "<ul>" + (($items | ForEach-Object { "<li>$(ConvertTo-HtmlText $_)</li>" }) -join "") + "</ul>"
}

function Build-ComparisonRows {
    param([AllowNull()][object[]]$Rows)
    if ($null -eq $Rows -or @($Rows).Count -eq 0) {
        return "<p class=`"empty`">No comparable metrics</p>"
    }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append("<table><thead><tr><th>指标</th><th>基线均值</th><th>候选均值</th><th>均值变化</th><th>P95 变化</th></tr></thead><tbody>")
    foreach ($row in @($Rows)) {
        $unit = [string]$row.Unit
        $suffix = if ([string]::IsNullOrWhiteSpace($unit)) { "" } else { " $unit" }
        $percentText = if ($null -eq $row.MeanDeltaPercent) {
            "n/a"
        }
        else {
            Format-SignedNumber -Value $row.MeanDeltaPercent -Suffix "%"
        }
        $directionClass = "delta-$(ConvertTo-HtmlText $row.Direction)"
        [void]$builder.Append("<tr><td>$(ConvertTo-HtmlText $row.Metric)</td>")
        [void]$builder.Append("<td>$(Format-Number -Value $row.BaselineMean -Suffix $suffix)</td>")
        [void]$builder.Append("<td>$(Format-Number -Value $row.CandidateMean -Suffix $suffix)</td>")
        [void]$builder.Append("<td class=`"$directionClass`">$(Format-SignedNumber -Value $row.MeanDelta -Suffix $suffix)<small>$percentText</small></td>")
        [void]$builder.Append("<td class=`"$directionClass`">$(Format-SignedNumber -Value $row.P95Delta -Suffix $suffix)</td></tr>")
    }
    [void]$builder.Append("</tbody></table>")
    return $builder.ToString()
}

function Get-InputMetaHtml {
    param([Parameter(Mandatory = $true)][object]$EvidenceInput)
    return @"
<div class="meta-grid">
  <span>文件</span><strong>$(ConvertTo-HtmlText $EvidenceInput.InputFileName)</strong>
  <span>SHA-256</span><code>$(ConvertTo-HtmlText $EvidenceInput.InputSha256)</code>
  <span>分析窗口</span><strong>$(ConvertTo-HtmlText $EvidenceInput.Analysis.Window)</strong>
  <span>采样一致性</span><strong>$(ConvertTo-HtmlText $EvidenceInput.Analysis.Sampling.Consistency)</strong>
</div>
"@
}

$baseline = $null
$candidate = $null
try {
    $baseline = Get-EvidenceInput -Path $baselineResolved -Name "baseline" -Label $BaselineLabel
    if ($candidateResolved) {
        $candidate = Get-EvidenceInput -Path $candidateResolved -Name "candidate" -Label $CandidateLabel
    }
    $comparison = Get-Comparison -Baseline $baseline -Candidate $candidate
}
catch {
    Stop-WithPipelineError $_.Exception.Message
}

$allWarnings = New-Object System.Collections.Generic.List[string]
foreach ($warning in @($baseline.Analysis.Warnings) + @($baseline.Normalized.Warnings)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
        $allWarnings.Add("$($baseline.Label): $warning") | Out-Null
    }
}
if ($candidate) {
    foreach ($warning in @($candidate.Analysis.Warnings) + @($candidate.Normalized.Warnings)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
            $allWarnings.Add("$($candidate.Label): $warning") | Out-Null
        }
    }
}
foreach ($warning in @($comparison.Warnings)) {
    $allWarnings.Add([string]$warning) | Out-Null
}

$baselineSvg = [IO.File]::ReadAllText($baseline.ChartPath, [Text.Encoding]::UTF8)
$candidateSection = ""
if ($candidate) {
    $candidateSvg = [IO.File]::ReadAllText($candidate.ChartPath, [Text.Encoding]::UTF8)
    $candidateSection = @"
<section class="evidence-block">
  <div class="section-head"><span>候选</span><h2>$(ConvertTo-HtmlText $candidate.Label)</h2></div>
  $(Get-InputMetaHtml -EvidenceInput $candidate)
  <div class="chart">$candidateSvg</div>
</section>
"@
}

$template = [IO.File]::ReadAllText($templatePath, [Text.Encoding]::UTF8)
$statusText = switch ($comparison.Status) {
    "baseline-ready" { "基线已就绪" }
    "ready-for-review" { "可以评审" }
    "retest" { "需要重测" }
    default { "需要复核" }
}
$statusClass = switch ($comparison.Status) {
    "baseline-ready" { "neutral" }
    "ready-for-review" { "good" }
    "retest" { "bad" }
    default { "warn" }
}
$changeText = if ([string]::IsNullOrWhiteSpace($Change)) { "未声明" } else { $Change }
$comparisonHtml = Build-ComparisonRows -Rows $comparison.Metrics
$cardHtml = $template
$cardHtml = $cardHtml.Replace("{{STATUS}}", (ConvertTo-HtmlText $statusText))
$cardHtml = $cardHtml.Replace("{{STATUS_CLASS}}", $statusClass)
$cardHtml = $cardHtml.Replace("{{GENERATED_AT}}", (ConvertTo-HtmlText $generatedAt))
$cardHtml = $cardHtml.Replace("{{WORKLOAD}}", (ConvertTo-HtmlText $Workload))
$cardHtml = $cardHtml.Replace("{{CHANGE}}", (ConvertTo-HtmlText $changeText))
$cardHtml = $cardHtml.Replace("{{BASELINE_LABEL}}", (ConvertTo-HtmlText $baseline.Label))
$cardHtml = $cardHtml.Replace("{{BASELINE_META}}", (Get-InputMetaHtml -EvidenceInput $baseline))
$cardHtml = $cardHtml.Replace("{{BASELINE_CHART}}", $baselineSvg)
$cardHtml = $cardHtml.Replace("{{CANDIDATE_SECTION}}", $candidateSection)
$cardHtml = $cardHtml.Replace("{{COMPARISON_ROWS}}", $comparisonHtml)
$cardHtml = $cardHtml.Replace("{{WARNINGS}}", (ConvertTo-WarningList -Warnings @($allWarnings.ToArray())))
$cardHtml = $cardHtml.Replace("{{NEXT_ACTION}}", (ConvertTo-HtmlText $comparison.NextAction))
$cardHtml = $cardHtml.Replace("{{RUN_ID}}", (ConvertTo-HtmlText $runId))

$cardPath = Join-Path $runDirectory "evidence-card.html"
$summaryPath = Join-Path $runDirectory "summary.md"
$packagePath = Join-Path $runDirectory "evidence-package.json"
[IO.File]::WriteAllText($cardPath, $cardHtml, $utf8NoBom)

$summary = New-Object System.Text.StringBuilder
[void]$summary.AppendLine("# Telemetry evidence package")
[void]$summary.AppendLine("")
[void]$summary.AppendLine("- Status: $($comparison.Status)")
[void]$summary.AppendLine("- Workload: $(if ([string]::IsNullOrWhiteSpace($Workload)) { 'not declared' } else { $Workload })")
[void]$summary.AppendLine("- Baseline: $($baseline.InputFileName) / $($baseline.Analysis.Window)")
[void]$summary.AppendLine("- Baseline SHA-256: $($baseline.InputSha256)")
if ($candidate) {
    [void]$summary.AppendLine("- Candidate: $($candidate.InputFileName) / $($candidate.Analysis.Window)")
    [void]$summary.AppendLine("- Candidate SHA-256: $($candidate.InputSha256)")
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("## Metric changes")
    [void]$summary.AppendLine("")
    foreach ($row in @($comparison.Metrics)) {
        $unit = if ([string]::IsNullOrWhiteSpace([string]$row.Unit)) { "" } else { " $($row.Unit)" }
        [void]$summary.AppendLine("- $($row.Metric): $((Format-Number $row.BaselineMean $unit)) -> $((Format-Number $row.CandidateMean $unit)); mean $((Format-SignedNumber $row.MeanDelta $unit)), P95 $((Format-SignedNumber $row.P95Delta $unit))")
    }
}
if ($allWarnings.Count -gt 0) {
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("## Warnings")
    [void]$summary.AppendLine("")
    foreach ($warning in $allWarnings) {
        [void]$summary.AppendLine("- $warning")
    }
}
[void]$summary.AppendLine("")
[void]$summary.AppendLine("## Next action")
[void]$summary.AppendLine("")
[void]$summary.AppendLine($comparison.NextAction)
[void]$summary.AppendLine("")
[void]$summary.AppendLine("The result is evidence, not a stability or safety guarantee.")
[IO.File]::WriteAllText($summaryPath, $summary.ToString(), $utf8NoBom)

$package = [pscustomobject][ordered]@{
    EvidencePackageVersion = "1.0"
    PipelineVersion = "1.0.0"
    GeneratedAt = $generatedAt
    RunId = $runId
    Workload = $Workload
    Change = $changeText
    Status = $comparison.Status
    NextAction = $comparison.NextAction
    Baseline = $baseline
    Candidate = $candidate
    Comparison = $comparison
    Warnings = @($allWarnings.ToArray())
    Files = [ordered]@{
        card = [ordered]@{ name = "evidence-card.html"; sha256 = Get-Sha256Hex -Path $cardPath }
        summary = [ordered]@{ name = "summary.md"; sha256 = Get-Sha256Hex -Path $summaryPath }
        baselineAnalysis = [ordered]@{ name = "baseline.analysis.json"; sha256 = Get-Sha256Hex -Path $baseline.AnalysisPath }
        baselineNormalized = [ordered]@{ name = "baseline.normalized.json"; sha256 = Get-Sha256Hex -Path $baseline.NormalizedPath }
        baselineChart = [ordered]@{ name = "baseline.chart.svg"; sha256 = Get-Sha256Hex -Path $baseline.ChartPath }
    }
}
if ($candidate) {
    $package.Files["candidateAnalysis"] = [ordered]@{ name = "candidate.analysis.json"; sha256 = Get-Sha256Hex -Path $candidate.AnalysisPath }
    $package.Files["candidateNormalized"] = [ordered]@{ name = "candidate.normalized.json"; sha256 = Get-Sha256Hex -Path $candidate.NormalizedPath }
    $package.Files["candidateChart"] = [ordered]@{ name = "candidate.chart.svg"; sha256 = Get-Sha256Hex -Path $candidate.ChartPath }
}
[IO.File]::WriteAllText(
    $packagePath,
    (($package | ConvertTo-Json -Depth 20) + "`n"),
    $utf8NoBom
)

Write-Output "Evidence package: $runDirectory"
Write-Output "Result card: $cardPath"
Write-Output "Summary: $summaryPath"
Write-Output "Comparison: $($comparison.Status)"
