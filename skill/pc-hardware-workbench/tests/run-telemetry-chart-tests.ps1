[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AnalyzerPath,

    [Parameter(Mandatory = $true)]
    [string]$RendererPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
    }
}

$resolvedAnalyzer = (Resolve-Path -LiteralPath $AnalyzerPath).Path
$resolvedRenderer = (Resolve-Path -LiteralPath $RendererPath).Path
$resolvedGanttRenderer = (
    Resolve-Path -LiteralPath (
        Join-Path (Split-Path -Parent $resolvedRenderer) "render-gantt-chart.ps1"
    )
).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-chart-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $resolvedRenderer,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "Chart renderer syntax errors: $($parseErrors -join '; ')"
    $ganttTokens = $null
    $ganttParseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $resolvedGanttRenderer,
        [ref]$ganttTokens,
        [ref]$ganttParseErrors
    ) | Out-Null
    Assert-True ($ganttParseErrors.Count -eq 0) "Gantt renderer syntax errors: $($ganttParseErrors -join '; ')"

    $telemetryPath = Join-Path $tempRoot "telemetry.csv"
    $telemetryContent = @'
"Date","Time","GPU Temperature [C]","GPU Power [W]","FPS"
"2026-11-03","12:00:00","55","120","70"
"2026-11-03","12:00:01","58","140","72"
"2026-11-03","12:00:02","61","155","71"
"2026-11-03","12:00:03","66","170","68"
"2026-11-03","12:00:04","63","160","69"
'@
    [IO.File]::WriteAllText($telemetryPath, $telemetryContent, $utf8)

    $chartData = & $resolvedAnalyzer -Path $telemetryPath -Format ChartData -MaxChartPoints 100 | ConvertFrom-Json
    Assert-True ($chartData.ChartDataVersion -eq "1.0") "Chart data version is missing."
    Assert-True ($chartData.AnalyzerVersion -eq "1.2.3") "Analyzer version was not updated for chart data."
    Assert-True ($chartData.TimeBased -eq $true) "Timestamped input was not exposed as a time-based chart."
    Assert-True ($chartData.XAxisLabel -eq "seconds") "Timestamped chart x-axis label is wrong."
    Assert-True ($chartData.Sampling.Consistency -eq "stable") "Stable chart sampling was not reported as stable."
    Assert-True ($chartData.Sampling.IntervalSecondsMedian -eq 1) "Chart sampling median is wrong."
    Assert-True (@($chartData.Series).Count -ge 3) "Expected at least three chartable series."

    $temperatureSeries = @($chartData.Series | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    $powerSeries = @($chartData.Series | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    $fpsSeries = @($chartData.Series | Where-Object { $_.Metric -eq "FPS" }) | Select-Object -First 1
    Assert-True ($null -ne $temperatureSeries -and $temperatureSeries.Unit -eq "C") "Temperature chart unit is missing."
    Assert-True ($null -ne $powerSeries -and $powerSeries.Unit -eq "W") "Power chart unit is missing."
    Assert-True ($null -ne $fpsSeries -and $fpsSeries.Unit -eq "FPS") "FPS chart unit is missing."
    Assert-True (@($temperatureSeries.Points).Count -eq 5) "Temperature chart should contain five points."

    $svgPath = Join-Path $tempRoot "overview.svg"
    $renderedPath = (& $resolvedRenderer -Path $telemetryPath -OutputPath $svgPath | Select-Object -Last 1)
    $svg = Get-Content -Raw -LiteralPath $svgPath
    Assert-True ($renderedPath -eq $svgPath) "Renderer did not report the created SVG path."
    Assert-True ($svg.StartsWith('<?xml version="1.0" encoding="UTF-8"?>')) "SVG XML declaration is missing."
    Assert-True ($svg.Contains("<svg ")) "SVG root element is missing."
    Assert-True ($svg.Contains("Telemetry overview")) "Default chart title is missing."
    Assert-True ($svg.Contains("GPU temperature (C)")) "Temperature panel is missing."
    Assert-True ($svg.Contains("GPU power (W)")) "Power panel is missing."
    Assert-True ($svg.Contains(">FPS<")) "FPS panel is missing."
    Assert-True ($svg.Contains("<polyline")) "Rendered chart contains no line series."
    Assert-True (-not ($svg -match "NaN|Infinity")) "Rendered SVG contains a non-finite value."
    Assert-True (-not ($svg -match ">\-\d+(?:\.\d+)?</text>")) "A non-negative telemetry series received a negative axis label."

    $existingHash = (Get-FileHash -LiteralPath $svgPath -Algorithm SHA256).Hash
    $previousErrorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $existingMessage = (
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedRenderer `
                -Path $telemetryPath -OutputPath $svgPath 2>&1 | Out-String
        )
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    $existingExitCode = $LASTEXITCODE
    $existingBlocked = (
        $existingExitCode -eq 2 -and
        $existingMessage -match "already exists" -and
        (Get-FileHash -LiteralPath $svgPath -Algorithm SHA256).Hash -eq $existingHash
    )
    Assert-True $existingBlocked "Renderer overwrote or did not reject an existing output file."

    $rowBasedPath = Join-Path $tempRoot "row-based.csv"
    [IO.File]::WriteAllText($rowBasedPath, @'
"GPU Temperature [C]","GPU Power [W]"
"50","100"
"51","110"
"52","120"
'@, $utf8)
    $rowBasedData = & $resolvedAnalyzer -Path $rowBasedPath -Format ChartData | ConvertFrom-Json
    Assert-True ($rowBasedData.TimeBased -eq $false) "CSV without timestamps should use a row-based x-axis."
    Assert-True ($rowBasedData.XAxisLabel -eq "samples") "Row-based chart x-axis label is wrong."
    $rowTemperature = @($rowBasedData.Series | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    Assert-True (
        $null -ne $rowTemperature -and
        @($rowTemperature.Points)[0].T -eq 1 -and
        @($rowTemperature.Points)[2].T -eq 3
    ) "Row-based points do not use one-based sample positions."

    $downsamplePath = Join-Path $tempRoot "downsample.csv"
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('"GPU Temperature [C]","GPU Power [W]"')
    for ($index = 0; $index -lt 300; $index++) {
        $temperature = 50 + (($index * 7) % 25)
        $power = 100 + (($index * 11) % 80)
        [void]$builder.AppendLine("`"$temperature`",`"$power`"")
    }
    [IO.File]::WriteAllText($downsamplePath, $builder.ToString(), $utf8)
    $downsampled = & $resolvedAnalyzer -Path $downsamplePath -Format ChartData -MaxChartPoints 31 | ConvertFrom-Json
    $downsampledSeries = @($downsampled.Series)
    Assert-True (
        @($downsampledSeries | Where-Object { $_.Downsampled -eq $true }).Count -ge 1
    ) "Large chart data was not downsampled."
    Assert-True (
        @($downsampledSeries | Where-Object { @($_.Points).Count -gt 31 }).Count -eq 0
    ) "Downsampled series exceeded MaxChartPoints."

    $stableLargePath = Join-Path $tempRoot "stable-large.csv"
    $stableBuilder = New-Object System.Text.StringBuilder
    [void]$stableBuilder.AppendLine('"Date","Time","GPU Temperature [C]"')
    $startTime = [datetime]::ParseExact(
        "2026-11-03 12:00:00",
        "yyyy-MM-dd HH:mm:ss",
        [System.Globalization.CultureInfo]::InvariantCulture
    )
    for ($index = 0; $index -lt 120; $index++) {
        $sampleTime = $startTime.AddSeconds($index)
        [void]$stableBuilder.AppendLine(
            '"' + $sampleTime.ToString("yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture) +
            '","' + $sampleTime.ToString("HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture) +
            '","' + (55 + ($index % 5)) + '"'
        )
    }
    [IO.File]::WriteAllText($stableLargePath, $stableBuilder.ToString(), $utf8)
    $stableLarge = & $resolvedAnalyzer -Path $stableLargePath -Format ChartData -MaxChartPoints 31 | ConvertFrom-Json
    $stableLargeSeries = @($stableLarge.Series | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    Assert-True ($stableLargeSeries.Downsampled -eq $true) "Stable sampling fixture was not downsampled."
    Assert-True ($stableLarge.Sampling.Consistency -eq "stable") "Downsampling falsely changed a stable sampling interval."
    Assert-True ($stableLarge.Sampling.IntervalSecondsMedian -eq 1) "Downsampled chart lost the original sampling median."

    $gapPath = Join-Path $tempRoot "downsample-gap.csv"
    $gapBuilder = New-Object System.Text.StringBuilder
    [void]$gapBuilder.AppendLine('"GPU Temperature [C]","GPU Power [W]"')
    for ($index = 0; $index -lt 300; $index++) {
        $temperature = if ($index -ge 140 -and $index -le 160) { "" } else { 55 + ($index % 5) }
        $power = 100 + ($index % 20)
        [void]$gapBuilder.AppendLine("`"$temperature`",`"$power`"")
    }
    [IO.File]::WriteAllText($gapPath, $gapBuilder.ToString(), $utf8)
    $gapData = & $resolvedAnalyzer -Path $gapPath -Format ChartData -MaxChartPoints 31 | ConvertFrom-Json
    $gapTemperature = @($gapData.Series | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    $gapPoints = @($gapTemperature.Points)
    Assert-True ($gapPoints.Count -le 31) "Gap-preserving downsample exceeded MaxChartPoints."
    Assert-True (
        @($gapPoints | Where-Object { $null -eq $_.V }).Count -ge 1
    ) "Downsampling removed the missing-value gap."
    $gapSvgPath = Join-Path $tempRoot "downsample-gap.svg"
    & $resolvedRenderer -Path $gapPath -OutputPath $gapSvgPath -MaxSeries 1 -MaxPoints 31 -IncludeColumn "GPU Temperature" | Out-Null
    $gapSvg = Get-Content -Raw -LiteralPath $gapSvgPath
    Assert-True (
        ([regex]::Matches($gapSvg, "<polyline")).Count -ge 2
    ) "Rendered chart connected across the missing-value gap."

    $explicitPath = Join-Path $tempRoot "explicit.csv"
    [IO.File]::WriteAllText($explicitPath, @'
"GPU Temperature [C]","GPU Power [W]","FPS","VRM Hotspot [C]"
"60","120","70","64"
"61","125","71","65"
"62","130","69","66"
'@, $utf8)
    $explicitSvgPath = Join-Path $tempRoot "explicit.svg"
    & $resolvedRenderer -Path $explicitPath -OutputPath $explicitSvgPath -MaxSeries 3 -IncludeColumn "VRM" | Out-Null
    $explicitSvg = Get-Content -Raw -LiteralPath $explicitSvgPath
    Assert-True ($explicitSvg.Contains("VRM Hotspot [C]")) "Explicit IncludeColumn series was pushed out by default series."

    $warningPath = Join-Path $tempRoot "warning.csv"
    [IO.File]::WriteAllText($warningPath, @'
"GPU Temperature [C]","Mystery"
"60","1"
"61","2"
"62","3"
'@, $utf8)
    $warningSvgPath = Join-Path $tempRoot "warning.svg"
    & $resolvedRenderer -Path $warningPath -OutputPath $warningSvgPath -MaxSeries 1 | Out-Null
    $warningSvg = Get-Content -Raw -LiteralPath $warningSvgPath
    Assert-True ($warningSvg.Contains("First warning:")) "Rendered chart omitted the first analyzer warning."

    $maliciousPath = Join-Path $tempRoot "malicious.csv"
    [IO.File]::WriteAllText($maliciousPath, @'
"GPU Temperature [C] <script>alert(1)</script>","GPU Power [W]"
"60","120"
"61","125"
'@, $utf8)
    $maliciousSvgPath = Join-Path $tempRoot "malicious.svg"
    & $resolvedRenderer -Path $maliciousPath -OutputPath $maliciousSvgPath -MaxSeries 1 | Out-Null
    $maliciousSvg = Get-Content -Raw -LiteralPath $maliciousSvgPath
    Assert-True (-not ($maliciousSvg -match "<script>alert\(1\)</script>")) "Source column markup was not escaped in SVG output."
    Assert-True ($maliciousSvg.Contains("&lt;script&gt;alert(1)&lt;/script&gt;")) "Escaped source column text is missing from SVG output."

    $ganttPlanPath = Join-Path $tempRoot "gantt-plan.json"
    @{
        title = "GPU stability validation"
        timeUnit = "min"
        tasks = @(
            @{
                label = "Known-good baseline"
                start = 0
                duration = 20
                track = "Baseline"
                status = "planned"
            },
            @{
                label = "Candidate +50 MHz"
                start = 20
                duration = 30
                track = "Candidate"
                status = "active"
                note = "Fixed workload"
            },
            @{
                label = "Reboot and soak"
                start = 50
                duration = 120
                track = "Validation"
                status = "planned"
            }
        )
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ganttPlanPath -Encoding UTF8
    $ganttSvgPath = Join-Path $tempRoot "gantt.svg"
    $renderedGanttPath = (& $resolvedGanttRenderer -InputPath $ganttPlanPath -OutputPath $ganttSvgPath | Select-Object -Last 1)
    $ganttSvg = Get-Content -Raw -LiteralPath $ganttSvgPath -Encoding UTF8
    Assert-True ($renderedGanttPath -eq $ganttSvgPath) "Gantt renderer did not report the created SVG path."
    Assert-True ($ganttSvg.StartsWith('<?xml version="1.0" encoding="UTF-8"?>')) "Gantt SVG XML declaration is missing."
    Assert-True ($ganttSvg.Contains("<svg ")) "Gantt SVG root element is missing."
    Assert-True ($ganttSvg.Contains("Known-good baseline")) "Gantt baseline task is missing."
    Assert-True ($ganttSvg.Contains("Candidate +50 MHz")) "Gantt candidate task is missing."
    Assert-True ($ganttSvg.Contains("Planning view")) "Gantt planning label is missing."
    Assert-True ($ganttSvg.Contains("not a hardware measurement")) "Gantt evidence boundary is missing."
    Assert-True ($ganttSvg.Contains("Durations remain assumptions")) "Gantt execution limitation is missing."
    Assert-True (-not ($ganttSvg -match "NaN|Infinity")) "Gantt SVG contains a non-finite value."

    $ganttHash = (Get-FileHash -LiteralPath $ganttSvgPath -Algorithm SHA256).Hash
    try {
        $ErrorActionPreference = "Continue"
        $ganttExistingMessage = (
            & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedGanttRenderer `
                -InputPath $ganttPlanPath -OutputPath $ganttSvgPath 2>&1 | Out-String
        )
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    $ganttExistingExitCode = $LASTEXITCODE
    Assert-True (
        $ganttExistingExitCode -eq 2 -and
        $ganttExistingMessage -match "already exists" -and
        (Get-FileHash -LiteralPath $ganttSvgPath -Algorithm SHA256).Hash -eq $ganttHash
    ) "Gantt renderer overwrote or did not reject an existing output file."

    $invalidGanttPath = Join-Path $tempRoot "invalid-gantt.json"
    @{ title = "Invalid plan"; tasks = @() } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $invalidGanttPath -Encoding UTF8
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedGanttRenderer `
            -InputPath $invalidGanttPath `
            -OutputPath (Join-Path $tempRoot "invalid-gantt.svg") *> $null
        $invalidGanttExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    Assert-True ($invalidGanttExitCode -eq 2) "Gantt renderer accepted a plan with no tasks."

    $missingStartPath = Join-Path $tempRoot "missing-gantt-start.json"
    @{
        title = "Invalid plan"
        tasks = @(@{
            label = "Missing start"
            duration = 10
        })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $missingStartPath -Encoding UTF8
    try {
        $ErrorActionPreference = "Continue"
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $resolvedGanttRenderer `
            -InputPath $missingStartPath `
            -OutputPath (Join-Path $tempRoot "missing-gantt-start.svg") *> $null
        $missingStartExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorPreference
    }
    Assert-True ($missingStartExitCode -eq 2) "Gantt renderer accepted a task without a start value."

    $maliciousGanttPath = Join-Path $tempRoot "malicious-gantt.json"
    @{
        title = "Plan <script>alert(1)</script>"
        tasks = @(@{
            label = "Baseline <script>alert(2)</script>"
            start = 0
            duration = 20
        })
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $maliciousGanttPath -Encoding UTF8
    $maliciousGanttSvgPath = Join-Path $tempRoot "malicious-gantt.svg"
    & $resolvedGanttRenderer -InputPath $maliciousGanttPath -OutputPath $maliciousGanttSvgPath | Out-Null
    $maliciousGanttSvg = Get-Content -Raw -LiteralPath $maliciousGanttSvgPath -Encoding UTF8
    Assert-True (-not ($maliciousGanttSvg -match "<script>alert\(")) "Gantt task text was not escaped in SVG output."
    Assert-True ($maliciousGanttSvg.Contains("&lt;script&gt;alert(1)&lt;/script&gt;")) "Escaped Gantt title is missing from SVG output."
    Assert-True ($maliciousGanttSvg.Contains("&lt;script&gt;alert(2)&lt;/script&gt;")) "Escaped Gantt task label is missing from SVG output."

    if ($failures.Count -gt 0) {
        Write-Host "Telemetry chart regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Telemetry chart regression: PASS" -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
