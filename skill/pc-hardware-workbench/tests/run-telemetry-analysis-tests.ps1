[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AnalyzerPath
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
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-telemetry-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $resolvedAnalyzer,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "Analyzer syntax errors: $($parseErrors -join '; ')"

    $hwinfoPath = Join-Path $tempRoot "hwinfo.csv"
    $hwinfoChineseFooterPath = Join-Path $tempRoot "hwinfo-chinese-footer.csv"
    $amdHwinfoPath = Join-Path $tempRoot "hwinfo-amd.csv"
    $amdOffsetOnlyPath = Join-Path $tempRoot "hwinfo-amd-offset-only.csv"
    $amdDieAveragePath = Join-Path $tempRoot "hwinfo-amd-die-average.csv"
    $presentmonPath = Join-Path $tempRoot "presentmon.csv"
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    [IO.File]::WriteAllText($hwinfoPath, @'
"HWiNFO64 v8.54"
"Exported sensor data"
"Date","Time","GPU Core Clock [MHz]","GPU Effective Clock [MHz]","GPU Core Voltage [V]","GPU Temperature [C]","GPU Hot Spot Temperature [C]","GPU Memory Junction Temperature [C]","GPU Power [W]","CPU Core Max [C]","FPS","Frame Time [ms]","GPU Fan [RPM]"
"2026-10-25","12:00:00.000","2400","2350","0.950","60","70","72","300","69","99","10.1","1800"
"2026-10-25","12:00:01.000","2410","2360","0.955","61","71","73","305","70","100","10.0","1810"
"2026-10-25","12:00:02.000","2420","2370","0.960","62","72","74","310","71","101","9.9","1820"
"2026-10-25","12:00:03.000","2430","2380","0.965","63","73","75","315","72","102","9.8","1830"
"2026-10-25","12:00:04.000","2440","2390","0.970","64","74","76","320","73","103","9.7","1840"
"2026-10-25","12:00:05.000","2450","2400","0.975","65","75","77","325","74","104","9.6","1850"
'@, $utf8)

    [IO.File]::WriteAllText($hwinfoChineseFooterPath, @'
"Date","Time","GPU 温度 [℃]","GPU 温度 [℃]","GPU 功率 [W]","GPU 有效频率 [MHz]","显存结温 [℃]","CPU 封装 [℃]","CPU 封装功率 [W]","帧率 [FPS]","帧率 Presented (avg) [FPS]","呈现帧率 (avg) [FPS]","1% 低帧率 [FPS]","0.1% 低帧率 [FPS]","呈现帧率 (1% low) [FPS]","呈现帧率 (0.1% low) [FPS]","显示帧率 (1% low) [FPS]","显示帧率 (0.1% low) [FPS]","Frame Time Presented (avg) [ms]","Frame Time Presented (99%) [ms]","Frame Time Presented (1%) [ms]","Frame Time Presented (0.1%) [ms]","Frame Time Displayed (1% high) [ms]","Frame Time Displayed (0.1% high) [ms]"
"25.10.2026","18:15:6.118","40","41","20","1500","44","45","15","1","120","130","0","0","60","40","80","70","7.69","100","20","30","40","50"
"25.10.2026","18:15:7.118","41","42","22","1510","45","46","16","2","122","132","0","0","62","42","82","72","7.58","101","21","31","41","51"
"25.10.2026","18:15:8.118","42","43","24","1520","46","47","17","3","124","134","0","0","64","44","84","74","7.46","102","22","32","42","52"
"25.10.2026","18:15:9.118","43","44","26","1530","47","48","18","4","126","136","0","0","66","46","86","76","7.35","103","23","33","43","53"
"Date","Time","Metadata","Value"
"25.10.2026","18:16:00.000","Device","This appended row must be ignored"
'@, $utf8)

    [IO.File]::WriteAllText($presentmonPath, @'
Application,ProcessID,SwapChainAddress,PresentFlags,AllowsTearing,PresentMode,SyncInterval,TimeInSeconds,msInPresentAPI,msBetweenPresents,msUntilDisplayed
game.exe,42,0,0,0,Hardware: Independent Flip,1,0.000,1.0,10.0,12.0
game.exe,42,0,0,0,Hardware: Independent Flip,1,0.010,1.0,20.0,22.0
game.exe,42,0,0,0,Hardware: Independent Flip,1,0.030,1.0,25.0,27.0
'@, $utf8)

    [IO.File]::WriteAllText($amdHwinfoPath, @'
"Date","Time","CPU Tdie Offset [°C]","CPU (Tctl/Tdie) [°C]","CPU (Tctl) [°C]","CPU (Tdie) [°C]","CPU PPT Limit [W]","CPU PPT [W]","GPU Core Clock [MHz]"
"2026-10-26","21:00:00","0.0","48.0","45.0","44.0","142","35","2500"
"2026-10-26","21:00:01","0.0","82.5","80.0","79.0","142","120","2520"
"2026-10-26","21:00:02","0.0","91.2","89.0","88.0","142","145","2540"
'@, $utf8)

    [IO.File]::WriteAllText($amdOffsetOnlyPath, @'
"Date","Time","CPU Tdie Offset [°C]","CPU PPT [W]"
"2026-10-26","21:00:00","0.0","35"
"2026-10-26","21:00:01","0.0","120"
"2026-10-26","21:00:02","0.0","145"
'@, $utf8)

    [IO.File]::WriteAllText($amdDieAveragePath, @'
"Date","Time","CPU Die (average) [°C]","CPU PPT [W]"
"2026-10-26","21:00:00","43.5","35"
"2026-10-26","21:00:01","78.0","120"
"2026-10-26","21:00:02","87.0","145"
'@, $utf8)

    $hwinfoJson = & $resolvedAnalyzer -Path $hwinfoPath -Format Json -WarmupSeconds 2 -DurationSeconds 2 | ConvertFrom-Json
    Assert-True ($hwinfoJson.HeaderLine -eq 3) "HWiNFO header should be detected on line 3."
    Assert-True ($hwinfoJson.TotalRows -eq 6) "HWiNFO should read six data rows."
    Assert-True ($hwinfoJson.AnalyzedRows -eq 3) "Time-windowed HWiNFO analysis should select three rows."

    $power = @($hwinfoJson.Metrics | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    $hotspot = @($hwinfoJson.Metrics | Where-Object { $_.Metric -eq "GPU hotspot (C)" }) | Select-Object -First 1
    $junction = @($hwinfoJson.Metrics | Where-Object { $_.Metric -eq "GPU memory junction (C)" }) | Select-Object -First 1
    $gpuVoltage = @($hwinfoJson.Metrics | Where-Object { $_.Metric -eq "GPU core voltage (V)" }) | Select-Object -First 1
    $cpuCoreMax = @($hwinfoJson.Metrics | Where-Object { $_.Metric -eq "CPU core maximum temperature (C)" }) | Select-Object -First 1
    $fps = @($hwinfoJson.Metrics | Where-Object { $_.Metric -eq "FPS" }) | Select-Object -First 1

    Assert-True ($null -ne $power -and [Math]::Abs($power.Mean - 315) -lt 0.001) "HWiNFO GPU power mean should be 315 W."
    Assert-True ($null -ne $hotspot -and $hotspot.Max -eq 74) "HWiNFO hotspot max should be 74 C."
    Assert-True ($null -ne $junction -and $junction.Max -eq 76) "HWiNFO memory-junction max should be 76 C."
    Assert-True ($null -ne $gpuVoltage -and [Math]::Abs($gpuVoltage.Mean - 0.965) -lt 0.0001) "HWiNFO GPU core voltage mean is incorrect."
    Assert-True ($null -ne $cpuCoreMax -and $cpuCoreMax.Max -eq 73) "HWiNFO CPU core maximum temperature is incorrect."
    Assert-True ($null -ne $fps -and [Math]::Abs($fps.Mean - 102) -lt 0.001) "HWiNFO FPS mean should be 102."

    $chineseJson = & $resolvedAnalyzer -Path $hwinfoChineseFooterPath -Format Json -WarmupSeconds 1 -DurationSeconds 2 | ConvertFrom-Json
    Assert-True ($chineseJson.TotalRows -eq 4) "Appended HWiNFO metadata should not be counted as telemetry rows."
    Assert-True ($chineseJson.AnalyzedRows -eq 3) "Flexible Date+Time parsing should select three rows in the requested window."
    Assert-True ($chineseJson.Window -match "^time 1s to 3s$") "Flexible Date+Time parsing should produce a real time window."
    Assert-True (@($chineseJson.Warnings | Where-Object { $_ -match "appended metadata was ignored" }).Count -eq 1) "The appended HWiNFO metadata warning is missing."

    $chineseFps = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "FPS" }) | Select-Object -First 1
    $chinesePower = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    $chineseJunction = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "GPU memory junction (C)" }) | Select-Object -First 1
    $presentedFpsLow = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Presented FPS 1% low (FPS)" }) | Select-Object -First 1
    $presentedFpsLow01 = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Presented FPS 0.1% low (FPS)" }) | Select-Object -First 1
    $displayedFpsLow = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Displayed FPS 1% low (FPS)" }) | Select-Object -First 1
    $displayedFpsLow01 = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Displayed FPS 0.1% low (FPS)" }) | Select-Object -First 1
    $presentedFrameHigh = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Presented frame time 99% high (ms)" }) | Select-Object -First 1
    $presentedFrameFastest1 = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Presented frame time fastest 1% (ms)" }) | Select-Object -First 1
    $presentedFrameFastest01 = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Presented frame time fastest 0.1% (ms)" }) | Select-Object -First 1
    $displayedFrameHigh = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Displayed frame time 1% high (ms)" }) | Select-Object -First 1
    $displayedFrameHigh01 = @($chineseJson.Metrics | Where-Object { $_.Metric -eq "Displayed frame time 0.1% high (ms)" }) | Select-Object -First 1
    Assert-True (
        $null -ne $chineseFps -and
        $chineseFps.SourceColumn -eq "呈现帧率 (avg) [FPS]" -and
        [Math]::Abs($chineseFps.Mean - 134) -lt 0.001
    ) "Localized presented-average FPS was not preferred."
    Assert-True ($null -ne $chinesePower -and [Math]::Abs($chinesePower.Mean - 24) -lt 0.001) "Chinese GPU power header was not recognized."
    Assert-True ($null -ne $chineseJunction -and [Math]::Abs($chineseJunction.Mean - 46) -lt 0.001) "Chinese memory-junction header was not recognized."
    Assert-True (
        $null -ne $presentedFpsLow -and
        $presentedFpsLow.SourceColumn -eq "呈现帧率 (1% low) [FPS]" -and
        [Math]::Abs($presentedFpsLow.Mean - 64) -lt 0.001
    ) "Presented 1% low FPS was not recognized."
    Assert-True (
        $null -ne $presentedFpsLow01 -and
        $presentedFpsLow01.SourceColumn -eq "呈现帧率 (0.1% low) [FPS]" -and
        [Math]::Abs($presentedFpsLow01.Mean - 44) -lt 0.001
    ) "Presented 0.1% low FPS was not recognized."
    Assert-True (
        $null -ne $displayedFpsLow -and
        $displayedFpsLow.SourceColumn -eq "显示帧率 (1% low) [FPS]" -and
        [Math]::Abs($displayedFpsLow.Mean - 84) -lt 0.001
    ) "Displayed 1% low FPS was not recognized."
    Assert-True (
        $null -ne $displayedFpsLow01 -and
        $displayedFpsLow01.SourceColumn -eq "显示帧率 (0.1% low) [FPS]" -and
        [Math]::Abs($displayedFpsLow01.Mean - 74) -lt 0.001
    ) "Displayed 0.1% low FPS was not recognized."
    Assert-True ($null -ne $presentedFrameHigh -and [Math]::Abs($presentedFrameHigh.Mean - 102) -lt 0.001) "Presented 99% high frame time was not recognized."
    Assert-True ($null -ne $presentedFrameFastest1 -and [Math]::Abs($presentedFrameFastest1.Mean - 22) -lt 0.001) "Presented fastest 1% frame time was not recognized."
    Assert-True ($null -ne $presentedFrameFastest01 -and [Math]::Abs($presentedFrameFastest01.Mean - 32) -lt 0.001) "Presented fastest 0.1% frame time was not recognized."
    Assert-True ($null -ne $displayedFrameHigh -and [Math]::Abs($displayedFrameHigh.Mean - 42) -lt 0.001) "Displayed 1% high frame time was not recognized."
    Assert-True ($null -ne $displayedFrameHigh01 -and [Math]::Abs($displayedFrameHigh01.Mean - 52) -lt 0.001) "Displayed 0.1% high frame time was not recognized."
    Assert-True (
        @($chineseJson.Warnings | Where-Object {
            $_ -match "Low-FPS sensor column '1% 低帧率 \[FPS\]'" -and
            $_ -match "only zero values"
        }).Count -eq 1
    ) "The all-zero generic 1% low FPS sensor did not produce a warning."
    Assert-True (
        @($chineseJson.Warnings | Where-Object {
            $_ -match "Low-FPS sensor column '0\.1% 低帧率 \[FPS\]'" -and
            $_ -match "only zero values"
        }).Count -eq 1
    ) "The all-zero generic 0.1% low FPS sensor did not produce a warning."

    $amdJson = & $resolvedAnalyzer -Path $amdHwinfoPath -Format Json | ConvertFrom-Json
    $amdTemp = @($amdJson.Metrics | Where-Object { $_.Metric -eq "CPU Tctl/Tdie temperature (C)" }) | Select-Object -First 1
    $amdPower = @($amdJson.Metrics | Where-Object { $_.Metric -eq "CPU package power (W)" }) | Select-Object -First 1
    Assert-True (
        $null -ne $amdTemp -and
        $amdTemp.SourceColumn -eq "CPU (Tctl/Tdie) [°C]" -and
        [Math]::Abs($amdTemp.Mean - 73.9) -lt 0.001
    ) "AMD Tctl/Tdie temperature selected the wrong source column or value."
    Assert-True (
        $null -ne $amdPower -and
        $amdPower.SourceColumn -eq "CPU PPT [W]" -and
        [Math]::Abs($amdPower.Mean - 100) -lt 0.001
    ) "AMD CPU PPT power selected the wrong source column or value."

    $offsetOnlyJson = & $resolvedAnalyzer -Path $amdOffsetOnlyPath -Format Json | ConvertFrom-Json
    $offsetOnlyTemp = @($offsetOnlyJson.Metrics | Where-Object { $_.Metric -eq "CPU Tctl/Tdie temperature (C)" }) | Select-Object -First 1
    $offsetWarning = @($offsetOnlyJson.Warnings | Where-Object {
        $_ -match "No column was selected for 'CPU Tctl/Tdie temperature" -and
        $_ -match "CPU Tdie Offset"
    }) | Select-Object -First 1
    Assert-True ($null -eq $offsetOnlyTemp) "An offset-only temperature column was accepted as a measured CPU temperature."
    Assert-True ($null -ne $offsetWarning) "An offset-only CPU temperature was rejected without a warning."

    $dieAverageJson = & $resolvedAnalyzer -Path $amdDieAveragePath -Format Json | ConvertFrom-Json
    $dieAverage = @($dieAverageJson.Metrics | Where-Object { $_.Metric -eq "CPU die average temperature (C)" }) | Select-Object -First 1
    Assert-True (
        $null -ne $dieAverage -and
        $dieAverage.SourceColumn -eq "CPU Die (average) [°C]" -and
        [Math]::Abs($dieAverage.Mean - 69.5) -lt 0.001
    ) "CPU Die (average) fallback was not recognized with its distinct label."

    $presentmonJson = & $resolvedAnalyzer -Path $presentmonPath -Format Json | ConvertFrom-Json
    $derivedFps = @($presentmonJson.Metrics | Where-Object { $_.Metric -eq "FPS derived from frame time" }) | Select-Object -First 1
    $frameTime = @($presentmonJson.Metrics | Where-Object { $_.Metric -eq "Frame time (ms)" }) | Select-Object -First 1
    Assert-True ($null -ne $derivedFps) "PresentMon frame time should derive an FPS series."
    Assert-True ($null -ne $frameTime -and [Math]::Abs($frameTime.Mean - (55.0 / 3.0)) -lt 0.001) "PresentMon frame-time mean is incorrect."

    $markdown = & $resolvedAnalyzer -Path $hwinfoPath -Format Markdown | Out-String
    Assert-True ($markdown.Contains("# Telemetry summary")) "Markdown output heading is missing."
    Assert-True ($markdown.Contains("GPU hotspot (C)")) "Markdown output is missing the isolated hotspot metric."
    Assert-True ($markdown.Contains("does not prove stability")) "Markdown output is missing the stability limitation."

    if ($failures.Count -gt 0) {
        Write-Host "Telemetry analyzer regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Telemetry analyzer regression: PASS" -ForegroundColor Green
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
