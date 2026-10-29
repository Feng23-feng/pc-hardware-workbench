[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AnalyzerPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Quote-Argument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-AnalyzerProcess {
    param([string[]]$Arguments)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe -ErrorAction Stop).Source
    $startInfo.Arguments = (
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedAnalyzer) + $Arguments |
            ForEach-Object { Quote-Argument $_ }
    ) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

$resolvedAnalyzer = (Resolve-Path -LiteralPath $AnalyzerPath).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-audit-$([guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $chinesePath = Join-Path $tempRoot "complete-chinese.csv"
    [IO.File]::WriteAllText($chinesePath, @'
"日期","时间","GPU 温度 [C]","GPU 功率 [W]","CPU 封装功耗 [W]","CPU 封装温度 [C]"
"2026-10-26","10:00:00","60","300","56","55"
"2026-10-26","10:00:01","61","305","57","56"
"2026-10-26","10:00:02","62","310","58","57"
'@, $utf8)

    $chinese = & $resolvedAnalyzer -Path $chinesePath -Format Json | ConvertFrom-Json
    Assert-True ($chinese.HeaderLine -eq 1) "Full Chinese header was not detected on line 1."
    Assert-True ($chinese.Window -match "^time 0s to 2s$") "Full Chinese Date/Time columns did not produce a time window."

    $cpuPower = @($chinese.Metrics | Where-Object { $_.Metric -eq "CPU package power (W)" }) | Select-Object -First 1
    $cpuTemp = @($chinese.Metrics | Where-Object { $_.Metric -eq "CPU package temperature (C)" }) | Select-Object -First 1
    Assert-True ($null -ne $cpuPower -and $cpuPower.SourceColumn -match "封装功耗") "Chinese CPU package power was not recognized."
    Assert-True ($null -ne $cpuTemp -and $cpuTemp.SourceColumn -match "封装温度") "Chinese CPU package temperature was not recognized."
    Assert-True ($null -eq $cpuPower -or $cpuPower.Metric -ne "CPU package temperature (C)") "CPU package power was misclassified as temperature."

    $hiddenJson = & $resolvedAnalyzer -Path $chinesePath -Format Json -HideFileName | ConvertFrom-Json
    Assert-True ($hiddenJson.FileName -eq "[hidden]") "HideFileName did not hide the JSON filename."
    $hiddenMarkdown = & $resolvedAnalyzer -Path $chinesePath -Format Markdown -HideFileName | Out-String
    $singleBacktick = [string][char]0x60
    Assert-True ($hiddenMarkdown.Contains("- File: $singleBacktick [hidden] $singleBacktick")) "HideFileName did not hide and isolate the Markdown filename."

    $shortPath = Join-Path $tempRoot "short.csv"
    [IO.File]::WriteAllText($shortPath, "Date,Time,GPU Temp [C]`r`n2026-10-26,10:00:00,60`r`n2026-10-26,10:00:01,61`r`n2026-10-26,10:00:02,62`r`n", $utf8)
    $shortJson = & $resolvedAnalyzer -Path $shortPath -Format Json | ConvertFrom-Json
    Assert-True (-not (@($shortJson.Warnings) -match "appended metadata was ignored")) "A normal trailing newline was misreported as metadata."

    $warmupFailed = $false
    try {
        & $resolvedAnalyzer -Path $shortPath -Format Json -WarmupSeconds 100 -DurationSeconds 2 | Out-Null
    }
    catch {
        $warmupFailed = $_.Exception.Message -match "exceeds the available telemetry duration"
    }
    Assert-True $warmupFailed "A warm-up window beyond the log duration was not rejected."

    $nonMonotonicPath = Join-Path $tempRoot "non-monotonic.csv"
    [IO.File]::WriteAllText($nonMonotonicPath, @'
"Date","Time","GPU Temp [C]"
"2026-10-26","10:00:00","60"
"2026-10-26","10:01:40","61"
"2026-10-26","10:00:50","62"
'@, $utf8)
    $nonMonotonicFailed = $false
    try {
        & $resolvedAnalyzer -Path $nonMonotonicPath -Format Json -WarmupSeconds 40 -DurationSeconds 20 | Out-Null
    }
    catch {
        $nonMonotonicFailed = $_.Exception.Message -match "timestamps move backwards"
    }
    Assert-True $nonMonotonicFailed "Non-monotonic timestamps were not rejected."

    $noTimePath = Join-Path $tempRoot "no-time.csv"
    [IO.File]::WriteAllText($noTimePath, @'
"GPU Temp [C]","GPU Power [W]"
"60","300"
"61","305"
"62","310"
'@, $utf8)
    $noTimeWindowFailed = $false
    try {
        & $resolvedAnalyzer -Path $noTimePath -Format Json -WarmupSeconds 100 -DurationSeconds 2 | Out-Null
    }
    catch {
        $noTimeWindowFailed = $_.Exception.Message -match "require a parseable time column"
    }
    Assert-True $noTimeWindowFailed "Seconds-based window without timestamps was not rejected."

    $rowWarmupFailed = $false
    try {
        & $resolvedAnalyzer -Path $noTimePath -Format Json -WarmupRows 100 | Out-Null
    }
    catch {
        $rowWarmupFailed = $_.Exception.Message -match "leaves no data rows"
    }
    Assert-True $rowWarmupFailed "Row warm-up beyond available rows was not rejected."

    $fanPath = Join-Path $tempRoot "fan-selection.csv"
    [IO.File]::WriteAllText($fanPath, @'
"System Fan RPM","GPU Fan RPM","GPU Temperature [C]"
"900","1800","60"
"910","1810","61"
"920","1820","62"
'@, $utf8)
    $fanJson = & $resolvedAnalyzer -Path $fanPath -Format Json | ConvertFrom-Json
    $gpuFan = @($fanJson.Metrics | Where-Object { $_.Metric -eq "GPU fan (RPM)" }) | Select-Object -First 1
    Assert-True ($null -ne $gpuFan -and $gpuFan.SourceColumn -eq "GPU Fan RPM") "The GPU fan metric selected a non-GPU fan column."

    $limitPath = Join-Path $tempRoot "clock-limit.csv"
    [IO.File]::WriteAllText($limitPath, @'
"GPU Clock Limit [MHz]","GPU Clock [MHz]","GPU Temperature [C]"
"500","2500","60"
"510","2510","61"
"520","2520","62"
'@, $utf8)
    $limitJson = & $resolvedAnalyzer -Path $limitPath -Format Json | ConvertFrom-Json
    $coreClock = @($limitJson.Metrics | Where-Object { $_.Metric -eq "GPU core clock (MHz)" }) | Select-Object -First 1
    Assert-True ($null -ne $coreClock -and $coreClock.SourceColumn -eq "GPU Clock [MHz]") "The GPU clock limit was selected instead of the measured clock."

    $unitPath = Join-Path $tempRoot "units.csv"
    [IO.File]::WriteAllText($unitPath, @'
"GPU Temp [W]","GPU Power [C]","GPU Clock [GHz]","GPU Temperature [C]"
"300","60","2.5","65"
"310","61","2.6","66"
"320","62","2.7","67"
'@, $utf8)
    $unitJson = & $resolvedAnalyzer -Path $unitPath -Format Json | ConvertFrom-Json
    $unitTemp = @($unitJson.Metrics | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    $unitPower = @($unitJson.Metrics | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    $ghzClock = @($unitJson.Metrics | Where-Object { $_.Metric -eq "GPU core clock (MHz)" }) | Select-Object -First 1
    Assert-True ($null -ne $unitTemp -and $unitTemp.SourceColumn -eq "GPU Temperature [C]") "A watt-valued column was treated as a GPU temperature."
    Assert-True ($null -eq $unitPower) "A Celsius-valued column was treated as GPU power."
    Assert-True ($null -ne $ghzClock -and [Math]::Abs($ghzClock.Mean - 2600) -lt 0.001) "GHz was not converted to MHz."

    $sourceDomainPath = Join-Path $tempRoot "source-domain.csv"
    [IO.File]::WriteAllText($sourceDomainPath, @'
"CPU Effective Clock [MHz]","Memory Clock [MHz]","FPS Limit","GPU Temperature [C]"
"5000","3200","60","70"
"5100","3300","61","71"
'@, $utf8)
    $sourceDomainJson = & $resolvedAnalyzer -Path $sourceDomainPath -Format Json | ConvertFrom-Json
    $wrongEffective = @($sourceDomainJson.Metrics | Where-Object { $_.Metric -eq "GPU effective clock (MHz)" }) | Select-Object -First 1
    $wrongMemory = @($sourceDomainJson.Metrics | Where-Object { $_.Metric -eq "GPU memory clock (MHz)" }) | Select-Object -First 1
    $wrongFps = @($sourceDomainJson.Metrics | Where-Object { $_.Metric -eq "FPS" }) | Select-Object -First 1
    Assert-True ($null -eq $wrongEffective) "CPU effective clock was treated as GPU effective clock."
    Assert-True ($null -eq $wrongMemory) "System memory clock was treated as GPU memory clock."
    Assert-True ($null -eq $wrongFps) "FPS limit was treated as measured FPS."

    $fahrenheitPath = Join-Path $tempRoot "fahrenheit.csv"
    [IO.File]::WriteAllText($fahrenheitPath, @'
"GPU Temperature [°F]","GPU Power [W]"
"158","300"
"160","310"
'@, $utf8)
    $fahrenheitJson = & $resolvedAnalyzer -Path $fahrenheitPath -Format Json | ConvertFrom-Json
    $fahrenheit = @($fahrenheitJson.Metrics | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    $fahrenheitMaxC = (160.0 - 32.0) * (5.0 / 9.0)
    Assert-True (
        $null -ne $fahrenheit -and
        [Math]::Abs($fahrenheit.Min - 70.0) -lt 0.001 -and
        [Math]::Abs($fahrenheit.Max - $fahrenheitMaxC) -lt 0.001
    ) "Fahrenheit was not converted to Celsius."

    $thousandsPath = Join-Path $tempRoot "thousands.csv"
    [IO.File]::WriteAllText($thousandsPath, @'
"GPU Power [W]","GPU Temperature [C]"
"1,250","70"
"1,300","71"
'@, $utf8)
    $thousandsJson = & $resolvedAnalyzer -Path $thousandsPath -Format Json | ConvertFrom-Json
    $thousandsPower = @($thousandsJson.Metrics | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    Assert-True (
        $null -ne $thousandsPower -and
        [Math]::Abs($thousandsPower.Mean - 1275.0) -lt 0.001
    ) "Thousands separators were interpreted as decimal separators."

    $partialTimePath = Join-Path $tempRoot "partial-invalid-time.csv"
    [IO.File]::WriteAllText($partialTimePath, @'
"Date","Time","GPU Temperature [C]"
"2026-10-26","00:00:00","70"
"2026-10-26","not-a-time","71"
"2026-10-26","00:00:02","72"
'@, $utf8)
    $partialTimeJson = & $resolvedAnalyzer -Path $partialTimePath -Format Json | ConvertFrom-Json
    Assert-True (
        @($partialTimeJson.Warnings | Where-Object { $_ -match "no parseable timestamp" }).Count -eq 1
    ) "A partially invalid timestamp column was not reported."
    $partialWindowFailed = $false
    try {
        & $resolvedAnalyzer -Path $partialTimePath -Format Json -DurationSeconds 2 | Out-Null
    }
    catch {
        $partialWindowFailed = $_.Exception.Message -match "without a parseable timestamp"
    }
    Assert-True $partialWindowFailed "A fixed time window silently included a row with an invalid timestamp."

    $conflictingWindowPath = Join-Path $tempRoot "conflicting-window.csv"
    [IO.File]::WriteAllText($conflictingWindowPath, @'
"Date","Time","GPU Temperature [C]"
"2026-10-26","00:00:00","70"
"2026-10-26","00:00:01","71"
"2026-10-26","00:00:02","72"
'@, $utf8)
    $conflictingWindowCapture = Invoke-AnalyzerProcess -Arguments @(
        "-Path", $conflictingWindowPath,
        "-Format", "Json",
        "-WarmupSeconds", "1",
        "-WarmupRows", "1"
    )
    Assert-True ($conflictingWindowCapture.ExitCode -eq 2) "Conflicting window parameters did not return input-rejection exit code 2."
    Assert-True ([string]::IsNullOrWhiteSpace($conflictingWindowCapture.Stdout)) "Conflicting window parameters wrote to stdout."
    Assert-True ($conflictingWindowCapture.Stderr -match "not both") "Conflicting window parameters did not return the input diagnostic."

    $nonFinitePath = Join-Path $tempRoot "non-finite.csv"
    [IO.File]::WriteAllText($nonFinitePath, @'
"GPU Power [W]","GPU Temperature [C]"
"NaN","70"
"Infinity","71"
"-Infinity","72"
'@, $utf8)
    $nonFiniteJson = & $resolvedAnalyzer -Path $nonFinitePath -Format Json | ConvertFrom-Json
    $nonFinitePower = @($nonFiniteJson.Metrics | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    Assert-True ($null -eq $nonFinitePower) "NaN or Infinity was accepted as a numeric sensor sample."

    $preamblePath = Join-Path $tempRoot "preamble.csv"
    [IO.File]::WriteAllText($preamblePath, @'
"Date","Time","Temp","Power","Clock","FPS","Fan","Voltage"
"Date","Time","GPU Temperature [C]","GPU Power [W]"
"2026-10-26","00:00:00","70","300"
"2026-10-26","00:00:01","71","310"
'@, $utf8)
    $preambleJson = & $resolvedAnalyzer -Path $preamblePath -Format Json | ConvertFrom-Json
    Assert-True ($preambleJson.HeaderLine -eq 2) "A metadata preamble was selected instead of the real data-backed header."
    Assert-True ($preambleJson.TotalRows -eq 2) "Rows after the real header were not analyzed."

    $mojibakePartialPath = Join-Path $tempRoot "mojibake-partial.csv"
    [IO.File]::WriteAllText($mojibakePartialPath, @'
"Date","Time","GPU 娓╁害 [C]","GPU 鍔熺巼 [W]"
"2026-10-26","00:00:00","70","300"
"2026-10-26","00:00:01","71","310"
'@, $utf8)
    $mojibakePartial = & $resolvedAnalyzer -Path $mojibakePartialPath -Format Json | ConvertFrom-Json
    Assert-True (
        @($mojibakePartial.Warnings | Where-Object { $_ -match "text-encoding corruption or mojibake" }).Count -eq 1
    ) "Partial mojibake headers did not produce an encoding-specific warning."

    $mojibakeFullPath = Join-Path $tempRoot "mojibake-full.csv"
    [IO.File]::WriteAllText($mojibakeFullPath, @'
"鏃ユ湡","鏃堕棿","GPU 娓╁害 [C]","GPU 鍔熺巼 [W]"
"2026-10-26","00:00:00","70","300"
"2026-10-26","00:00:01","71","310"
'@, $utf8)
    $mojibakeHeaderFailed = $false
    try {
        & $resolvedAnalyzer -Path $mojibakeFullPath -Format Json | Out-Null
    }
    catch {
        $mojibakeHeaderFailed = $_.Exception.Message -match "text-encoding corruption or mojibake"
    }
    Assert-True $mojibakeHeaderFailed "Full mojibake header failure lacked an encoding-specific diagnosis."

    $sparseWindowPath = Join-Path $tempRoot "sparse-window.csv"
    [IO.File]::WriteAllText($sparseWindowPath, @'
"Date","Time","GPU Temperature [C]"
"2026-10-26","00:00:00","60"
"2026-10-26","00:01:40","70"
"2026-10-26","00:01:50","71"
"2026-10-26","00:03:20","80"
'@, $utf8)
    $sparseWindow = & $resolvedAnalyzer `
        -Path $sparseWindowPath `
        -Format Json `
        -WarmupSeconds 50 `
        -DurationSeconds 100 | ConvertFrom-Json
    Assert-True ($sparseWindow.AnalyzedRows -eq 2) "The sparse time window selected rows beyond the requested end."
    Assert-True ($sparseWindow.Window -match "^time 100s to 110s$") "The sparse time window reported the wrong actual range."
    Assert-True ($sparseWindow.RequestedWindow -match "^time 50s to 150s$") "The requested time window was not recorded."

    $emptyWindowFailed = $false
    try {
        & $resolvedAnalyzer `
            -Path $sparseWindowPath `
            -Format Json `
            -WarmupSeconds 50 `
            -DurationSeconds 20 | Out-Null
    }
    catch {
        $emptyWindowFailed = $_.Exception.Message -match "contains no rows"
    }
    Assert-True $emptyWindowFailed "A requested time window with no samples was not rejected."

    $shortDurationFailed = $false
    try {
        & $resolvedAnalyzer -Path $shortPath -Format Json -DurationSeconds 100 | Out-Null
    }
    catch {
        $shortDurationFailed = $_.Exception.Message -match "exceeds the available telemetry"
    }
    Assert-True $shortDurationFailed "A requested duration longer than the available telemetry was silently truncated."

    $invalidPhysicalPath = Join-Path $tempRoot "invalid-physical.csv"
    [IO.File]::WriteAllText($invalidPhysicalPath, @'
"Frame Time [ms]","GPU Temperature [C]","GPU Fan [%]"
"-10","-273.15","-20"
"0","-300","150"
'@, $utf8)
    $invalidPhysical = & $resolvedAnalyzer -Path $invalidPhysicalPath -Format Json | ConvertFrom-Json
    Assert-True (
        @($invalidPhysical.Metrics | Where-Object { $_.Metric -eq "Frame time (ms)" }).Count -eq 0
    ) "A non-positive frame time was accepted."
    Assert-True (
        @($invalidPhysical.Metrics | Where-Object { $_.Metric -eq "GPU temperature (C)" }).Count -eq 0
    ) "A physically impossible GPU temperature was accepted."
    Assert-True (
        @($invalidPhysical.Metrics | Where-Object { $_.Metric -eq "GPU fan (%)" }).Count -eq 0
    ) "An impossible fan percentage was accepted."
    Assert-True (
        @($invalidPhysical.Warnings | Where-Object { $_ -match "outside the analyzer's plausible range" }).Count -ge 1
    ) "Rejected physical values were not reported."

    $unitAliasPath = Join-Path $tempRoot "unit-aliases.csv"
    [IO.File]::WriteAllText($unitAliasPath, @'
"GPU Temperature [°R]","GPU Temperature [C]","GPU Power [Watt]","GPU Clock [千兆赫]"
"527.67","70","300","2.5"
"530.01","71","310","2.6"
'@, $utf8)
    $unitAlias = & $resolvedAnalyzer -Path $unitAliasPath -Format Json | ConvertFrom-Json
    $unitTemp = @($unitAlias.Metrics | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    $unitPowerAlias = @($unitAlias.Metrics | Where-Object { $_.Metric -eq "GPU power (W)" }) | Select-Object -First 1
    $unitClockAlias = @($unitAlias.Metrics | Where-Object { $_.Metric -eq "GPU core clock (MHz)" }) | Select-Object -First 1
    Assert-True ($null -ne $unitTemp -and $unitTemp.SourceColumn -eq "GPU Temperature [C]") "An unknown explicit temperature unit was accepted."
    Assert-True ($null -ne $unitPowerAlias -and $unitPowerAlias.SourceColumn -eq "GPU Power [Watt]") "The Watt unit alias was not accepted."
    Assert-True (
        $null -ne $unitClockAlias -and
        [Math]::Abs($unitClockAlias.Mean - 2550.0) -lt 0.001
    ) "Chinese GHz units were not converted to MHz."

    $unitlessRolePath = Join-Path $tempRoot "unitless-roles.csv"
    [IO.File]::WriteAllText($unitlessRolePath, @'
"CPU Package","CPU Package Power [W]","GPU Fan","GPU Fan [%]","GPU Temperature [C]"
"150","140","50","40","70"
"160","150","55","45","71"
'@, $utf8)
    $unitlessRoles = & $resolvedAnalyzer -Path $unitlessRolePath -Format Json | ConvertFrom-Json
    $cpuPowerRole = @($unitlessRoles.Metrics | Where-Object { $_.Metric -eq "CPU package power (W)" }) | Select-Object -First 1
    $gpuFanRole = @($unitlessRoles.Metrics | Where-Object { $_.Metric -eq "GPU fan (%)" }) | Select-Object -First 1
    Assert-True ($null -eq (@($unitlessRoles.Metrics | Where-Object { $_.Metric -eq "CPU package temperature (C)" }) | Select-Object -First 1)) "A unitless CPU Package column was guessed to be temperature."
    Assert-True ($null -eq (@($unitlessRoles.Metrics | Where-Object { $_.Metric -eq "GPU fan (RPM)" }) | Select-Object -First 1)) "A unitless GPU Fan column was guessed to be RPM."
    Assert-True ($null -ne $cpuPowerRole -and $cpuPowerRole.SourceColumn -eq "CPU Package Power [W]") "The explicit CPU power column was not preferred."
    Assert-True ($null -ne $gpuFanRole -and $gpuFanRole.SourceColumn -eq "GPU Fan [%]") "The explicit GPU fan percentage was not preferred."
    Assert-True (
        @($unitlessRoles.Warnings | Where-Object { $_ -match "ambiguous measurement roles" }).Count -eq 1
    ) "Ambiguous unitless columns were silently ignored."

    $overflowPath = Join-Path $tempRoot "stat-overflow.csv"
    [IO.File]::WriteAllText($overflowPath, @'
"GPU Temperature [C]","GPU Power [W]","Custom Counter"
"70","300","1e308"
"71","310","1e308"
'@, $utf8)
    $overflowJson = & $resolvedAnalyzer -Path $overflowPath -Format Json -IncludeColumn "^Custom Counter$" | ConvertFrom-Json
    Assert-True (
        @($overflowJson.Metrics | Where-Object { $_.Metric -eq "Custom Counter" }).Count -eq 0
    ) "A metric whose statistics overflowed was not omitted."
    Assert-True (
        @($overflowJson.Warnings | Where-Object { $_ -match "non-finite statistic" }).Count -eq 1
    ) "A non-finite statistic was not reported."

    $rowWidthPath = Join-Path $tempRoot "row-width.csv"
    [IO.File]::WriteAllText($rowWidthPath, @'
"Date","Time","GPU Temperature [C]","GPU Power [W]"
"2026-10-26","00:00:00","70"
"2026-10-26","00:00:01","71","300","unexpected"
"2026-10-26","00:00:02","72","310"
'@, $utf8)
    $rowWidthJson = & $resolvedAnalyzer -Path $rowWidthPath -Format Json | ConvertFrom-Json
    Assert-True ($rowWidthJson.InvalidRows -eq 2) "Mismatched CSV rows were not counted as invalid."
    Assert-True ($rowWidthJson.TotalRows -eq 1) "Mismatched CSV rows were not excluded from valid telemetry rows."
    Assert-True (
        @($rowWidthJson.Warnings | Where-Object { $_ -match "field count did not match" }).Count -eq 1
    ) "Mismatched CSV rows were not reported."

    $markdownPipePath = Join-Path $tempRoot "markdown-pipe.csv"
    [IO.File]::WriteAllText($markdownPipePath, @'
"GPU Temperature [C] | FORGED","GPU Power [W]"
"70","300"
"71","310"
'@, $utf8)
    $escapedMarkdown = & $resolvedAnalyzer -Path $markdownPipePath -Format Markdown | Out-String
    Assert-True ($escapedMarkdown.Contains("GPU Temperature [C] \| FORGED")) "Markdown table syntax in source columns was not neutralized."

    $maliciousNamePath = Join-Path $tempRoot "[click](x).csv"
    [IO.File]::WriteAllText($maliciousNamePath, @'
"GPU Temperature [C] **[GPU](x)**","`GPU Power [W]`"
"70","300"
"71","310"
'@, $utf8)
    $maliciousMarkdown = & $resolvedAnalyzer -Path $maliciousNamePath -Format Markdown | Out-String
    $backtick = [string][char]0x60
    $fileLine = @($maliciousMarkdown -split "\r?\n" | Where-Object { $_ -like "- File:*" }) | Select-Object -First 1
    Assert-True ($fileLine.StartsWith("- File: $backtick ") -and $fileLine.EndsWith(" $backtick")) "A Markdown filename was not isolated in inline code."
    $wrappedLink = "$backtick GPU Temperature [C] **[GPU](x)** $backtick"
    Assert-True ($maliciousMarkdown.Contains($wrappedLink)) "A Markdown link in a source column was not isolated in inline code."
    $doubleBacktick = $backtick + $backtick
    $wrappedBacktickColumn = $doubleBacktick + " " + $backtick + "GPU Power [W]" + $backtick + " " + $doubleBacktick
    Assert-True ($maliciousMarkdown.Contains($wrappedBacktickColumn)) "Backtick markup in a source column did not receive a longer safe fence."

    $unsafeHeader = "GPU Temperature [C]" + [char]0x1B + [char]0x009B + [char]0x061C + [char]0x200B + [char]0x202E + [char]0xFE0F + " https://example.invalid/probe"
    $unsafeHeaderPath = Join-Path $tempRoot "unsafe-header.csv"
    [IO.File]::WriteAllText($unsafeHeaderPath, ('"' + $unsafeHeader + '","GPU Power [W]"' + "`r`n" + '"70","300"' + "`r`n" + '"71","310"' + "`r`n"), $utf8)
    $unsafeMarkdown = & $resolvedAnalyzer -Path $unsafeHeaderPath -Format Markdown | Out-String
    Assert-True (-not ($unsafeMarkdown -match "[\x1B\u009B\u061C\u200B\u202E\uFE0F]")) "Control, format, directional, or variation-selector characters reached Markdown output."
    Assert-True ($unsafeMarkdown -match "${backtick}[^${backtick}]*https://example\.invalid/probe[^${backtick}]*${backtick}") "A bare URL was not isolated inside an inline-code span."

    $oversizedPath = Join-Path $tempRoot "oversized.csv"
    [IO.File]::WriteAllText($oversizedPath, ("A" * 1100000), $utf8)
    $oversizedCapture = Invoke-AnalyzerProcess -Arguments @(
        "-Path", $oversizedPath,
        "-Format", "Json",
        "-MaxInputMegabytes", "1"
    )
    Assert-True ($oversizedCapture.ExitCode -eq 2) "An oversized telemetry file did not return input-rejection exit code 2."
    Assert-True ([string]::IsNullOrWhiteSpace($oversizedCapture.Stdout)) "An oversized telemetry file wrote to stdout."
    Assert-True ($oversizedCapture.Stderr -match "safety limit") "An oversized telemetry file did not report the safety limit."

    $networkCapture = Invoke-AnalyzerProcess -Arguments @(
        "-Path", "\\server\share\log.csv",
        "-Format", "Json"
    )
    Assert-True ($networkCapture.ExitCode -eq 2) "A UNC telemetry path did not return input-rejection exit code 2."
    Assert-True ([string]::IsNullOrWhiteSpace($networkCapture.Stdout)) "A UNC telemetry path wrote to stdout."
    Assert-True ($networkCapture.Stderr -match "local filesystem path") "A UNC telemetry path did not report the local-path restriction."

    $missingCapture = Invoke-AnalyzerProcess -Arguments @(
        "-Path", (Join-Path $tempRoot "missing.csv"),
        "-Format", "Json"
    )
    Assert-True ($missingCapture.ExitCode -eq 2) "A missing telemetry path did not return input-rejection exit code 2."
    Assert-True ([string]::IsNullOrWhiteSpace($missingCapture.Stdout)) "A missing telemetry path wrote to stdout."
    Assert-True ($missingCapture.Stderr -match "Telemetry file not found:") "A missing telemetry path did not return the friendly not-found error."

    $offlinePath = Join-Path $tempRoot "offline-placeholder.csv"
    [IO.File]::WriteAllText($offlinePath, @'
"GPU Temperature [C]"
"70"
"71"
'@, $utf8)
    $originalAttributes = [IO.File]::GetAttributes($offlinePath)
    try {
        [IO.File]::SetAttributes($offlinePath, ($originalAttributes -bor [IO.FileAttributes]::Offline))
        $offlineCapture = Invoke-AnalyzerProcess -Arguments @(
            "-Path", $offlinePath,
            "-Format", "Json"
        )
        Assert-True ($offlineCapture.ExitCode -eq 2) "An offline/cloud-placeholder file did not return input-rejection exit code 2."
        Assert-True ([string]::IsNullOrWhiteSpace($offlineCapture.Stdout)) "An offline/cloud-placeholder file wrote to stdout."
        Assert-True ($offlineCapture.Stderr -match "cloud-placeholder") "An offline/cloud-placeholder file did not report the rejection."
    }
    finally {
        [IO.File]::SetAttributes($offlinePath, $originalAttributes)
    }

    $midnightPath = Join-Path $tempRoot "midnight.csv"
    [IO.File]::WriteAllText($midnightPath, @'
"Date","Time","GPU Temp [C]"
"31.10.2026","23:59:59","60"
"01.11.2026","00:00:01","61"
"01.11.2026","00:00:03","62"
'@, $utf8)
    $midnight = & $resolvedAnalyzer -Path $midnightPath -Format Json | ConvertFrom-Json
    Assert-True ($midnight.Window -match "^time 0s to 4s$") "Date+Time parsing did not remain monotonic across midnight."

    if ($failures.Count -gt 0) {
        Write-Host "Telemetry audit regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Telemetry audit regression: PASS" -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
