[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AdapterPath,

    [Parameter(Mandatory = $true)]
    [string]$RendererPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$resolvedAdapter = (Resolve-Path -LiteralPath $AdapterPath).Path
$resolvedRenderer = (Resolve-Path -LiteralPath $RendererPath).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-normalize-test-$([guid]::NewGuid().ToString('N'))"

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

function Invoke-Process {
    param(
        [string]$ScriptPath,
        [string[]]$Arguments
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = (
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments |
            ForEach-Object { Quote-Argument $_ }
    ) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        try {
            $process.Kill()
        }
        catch {
        }
        throw "Process timed out: $ScriptPath"
    }
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Write-SnapshotFixture {
    param(
        [string]$Path,
        [object]$Snapshot
    )
    [IO.File]::WriteAllText(
        $Path,
        ($Snapshot | ConvertTo-Json -Depth 12) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $csvPath = Join-Path $tempRoot "telemetry.csv"
    [IO.File]::WriteAllText($csvPath, @'
"Date","Time","GPU Temperature [C]","GPU Power [W]","FPS"
"2026-11-03","12:00:00","55","120","60"
"2026-11-03","12:00:01","56","125","61"
"2026-11-03","12:00:02","57","130","62"
"2026-11-03","12:00:03","","131","63"
"2026-11-03","12:00:04","59","132","64"
'@, $utf8)
    $csvOutput = Join-Path $tempRoot "csv-normalized.json"
    $csvResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $csvPath,
        "-OutputPath", $csvOutput,
        "-SourceTool", "HWiNFO64",
        "-SourceVersion", "8.30",
        "-DeviceId", "fixture-desktop",
        "-CapturedAt", "2026-11-03T12:00:00+08:00"
    )
    Assert-True ($csvResult.ExitCode -eq 0) "CSV normalization failed: $($csvResult.Stderr)"
    if (-not (Test-Path -LiteralPath $csvOutput -PathType Leaf)) {
        throw "CSV normalization did not create output. stderr=$($csvResult.Stderr) stdout=$($csvResult.Stdout)"
    }
    Assert-True (Test-Path -LiteralPath $csvOutput -PathType Leaf) "CSV normalization did not create output."
    $csvNormalized = Get-Content -Raw -LiteralPath $csvOutput -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($csvNormalized.NormalizedTelemetryVersion -eq "1.0") "Normalized telemetry version is missing."
    Assert-True ($csvNormalized.AdapterVersion -eq "1.0.0") "Adapter version is missing."
    Assert-True ($csvNormalized.Source.InputKind -eq "csv") "CSV input kind was not recorded."
    Assert-True ($csvNormalized.Source.Tool -eq "HWiNFO64") "CSV source tool was not preserved."
    Assert-True ($csvNormalized.Source.Version -eq "8.30") "CSV source version was not preserved."
    Assert-True ($csvNormalized.Source.DeviceId -eq "fixture-desktop") "CSV device identity was not preserved."
    Assert-True ($csvNormalized.Source.CapturedAt -eq "2026-11-03T12:00:00.0000000+08:00") "CSV capture time was not preserved."
    Assert-True ($csvNormalized.Source.InputSha256 -eq (Get-FileHash -LiteralPath $csvPath -Algorithm SHA256).Hash) "CSV input hash is wrong."
    Assert-True ($csvNormalized.Sampling.IntervalSecondsMedian -eq 1) "CSV sampling interval was not detected."
    Assert-True ($csvNormalized.ChartData.ChartDataVersion -eq "1.0") "Normalized chart data is missing."
    Assert-True (@($csvNormalized.Sensors).Count -ge 3) "Normalized sensor metadata is incomplete."
    Assert-True (@($csvNormalized.Sensors.Category) -contains "temperature") "CSV temperature category was not inferred."
    Assert-True (@($csvNormalized.Sensors.Category) -contains "power") "CSV power category was not inferred."
    Assert-True (@($csvNormalized.Sensors.Category) -contains "fps") "CSV FPS category was not inferred."

    $csvSvg = Join-Path $tempRoot "csv-normalized.svg"
    $csvRender = Invoke-Process -ScriptPath $resolvedRenderer -Arguments @(
        "-Path", $csvOutput,
        "-OutputPath", $csvSvg
    )
    Assert-True ($csvRender.ExitCode -eq 0) "Renderer rejected normalized CSV output: $($csvRender.Stderr)"
    Assert-True (Test-Path -LiteralPath $csvSvg -PathType Leaf) "Renderer did not create normalized CSV chart."

    $unattributedOutput = Join-Path $tempRoot "csv-unattributed.json"
    $unattributedResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $csvPath,
        "-OutputPath", $unattributedOutput,
        "-HideFileName"
    )
    Assert-True ($unattributedResult.ExitCode -eq 0) "CSV compatibility normalization failed without source metadata."
    $unattributed = Get-Content -Raw -LiteralPath $unattributedOutput -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($unattributed.Source.InputFileName -eq "[hidden]") "HideFileName did not hide the normalized input filename."
    Assert-True ($unattributed.ChartData.FileName -eq "[hidden]") "HideFileName did not hide the chart filename."
    $unattributedWarnings = $unattributed.Warnings -join " "
    Assert-True ($unattributedWarnings -match "Source tool") "Missing CSV source tool was not warned."
    Assert-True ($unattributedWarnings -match "Source version") "Missing CSV source version was not warned."
    Assert-True ($unattributedWarnings -match "Capture time") "Missing CSV capture time was not warned."
    Assert-True ($unattributedWarnings -match "Device identity") "Missing CSV device identity was not warned."

    $rowBasedPath = Join-Path $tempRoot "row-based.csv"
    [IO.File]::WriteAllText($rowBasedPath, @'
"GPU Temperature [C]","GPU Power [W]"
"55","100"
"56","105"
"57","110"
'@, $utf8)
    $rowBasedOutput = Join-Path $tempRoot "row-based-normalized.json"
    $rowBasedResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $rowBasedPath,
        "-OutputPath", $rowBasedOutput
    )
    Assert-True ($rowBasedResult.ExitCode -eq 0) "Row-based normalization failed."
    if (-not (Test-Path -LiteralPath $rowBasedOutput -PathType Leaf)) {
        throw "Row-based normalization did not create output. stderr=$($rowBasedResult.Stderr) stdout=$($rowBasedResult.Stdout)"
    }
    $rowBasedNormalized = Get-Content -Raw -LiteralPath $rowBasedOutput -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($rowBasedNormalized.Sampling.TimeBased -eq $false) "Row-based input was treated as time-based."
    Assert-True ($rowBasedNormalized.Sampling.Consistency -eq "unknown") "Row-based sampling consistency is not unknown."
    Assert-True (($rowBasedNormalized.Warnings -join " ") -match "could not be established") "Unknown sampling interval was not warned."

    $snapshotPath = Join-Path $tempRoot "snapshot.json"
    $snapshot = [pscustomobject]@{
        schemaVersion = "1.0"
        source = [pscustomobject]@{
            tool = "Fixture Monitor"
            version = "1.2"
            deviceId = "gpu-fixture"
            capturedAt = "2026-11-03T12:30:00+08:00"
        }
        samples = @(
            [pscustomobject]@{
                capturedAt = "2026-11-03T12:30:00+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 60 },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 100 },
                    [pscustomobject]@{ name = "FPS"; category = "fps"; unit = "FPS"; value = 60 }
                )
            },
            [pscustomobject]@{
                capturedAt = "2026-11-03T12:30:01+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 61 },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 105 },
                    [pscustomobject]@{ name = "FPS"; category = "fps"; unit = "FPS"; value = 61 }
                )
            },
            [pscustomobject]@{
                capturedAt = "2026-11-03T12:30:02+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = $null },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 110 },
                    [pscustomobject]@{ name = "FPS"; category = "fps"; unit = "FPS"; value = 62 }
                )
            },
            [pscustomobject]@{
                capturedAt = "2026-11-03T12:30:03+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 63 },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 115 },
                    [pscustomobject]@{ name = "FPS"; category = "fps"; unit = "FPS"; value = 63 }
                )
            }
        )
    }
    Write-SnapshotFixture -Path $snapshotPath -Snapshot $snapshot
    $snapshotOutput = Join-Path $tempRoot "snapshot-normalized.json"
    $snapshotResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $snapshotPath,
        "-OutputPath", $snapshotOutput
    )
    Assert-True ($snapshotResult.ExitCode -eq 0) "Snapshot normalization failed: $($snapshotResult.Stderr)"
    $snapshotNormalized = Get-Content -Raw -LiteralPath $snapshotOutput -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($snapshotNormalized.Source.InputKind -eq "sensor-snapshot") "Snapshot input kind was not recorded."
    Assert-True ($snapshotNormalized.Source.MixedSources -eq $false) "Single-source snapshot was marked as mixed."
    Assert-True ($snapshotNormalized.Source.InputSha256 -eq (Get-FileHash -LiteralPath $snapshotPath -Algorithm SHA256).Hash) "Snapshot input hash is wrong."
    Assert-True ($snapshotNormalized.Sampling.IntervalSecondsMedian -eq 1) "Snapshot sampling interval was not detected."
    Assert-True ($snapshotNormalized.DataQuality.MissingValueCount -ge 1) "Snapshot missing-value count was not recorded."
    Assert-True ($snapshotNormalized.DataQuality.Status -eq "partial") "Snapshot with missing values was marked complete."
    $temperatureSeries = @($snapshotNormalized.ChartData.Series | Where-Object { $_.Metric -eq "GPU temperature (C)" }) | Select-Object -First 1
    Assert-True ($null -ne $temperatureSeries) "Snapshot temperature series was not recognized."
    Assert-True (
        @(@($temperatureSeries.Points) | Where-Object { $null -eq $_.V }).Count -ge 1
    ) "Snapshot missing value was not preserved."
    $snapshotSvg = Join-Path $tempRoot "snapshot-normalized.svg"
    $snapshotRender = Invoke-Process -ScriptPath $resolvedRenderer -Arguments @(
        "-Path", $snapshotOutput,
        "-OutputPath", $snapshotSvg,
        "-InputFormat", "NormalizedJson",
        "-MaxSeries", "3"
    )
    Assert-True ($snapshotRender.ExitCode -eq 0) "Renderer rejected snapshot-normalized telemetry: $($snapshotRender.Stderr)"
    $snapshotSvgText = Get-Content -Raw -LiteralPath $snapshotSvg
    Assert-True ($snapshotSvgText.Contains("GPU temperature (C)")) "Snapshot chart omitted the temperature series."
    Assert-True (([regex]::Matches($snapshotSvgText, "<polyline")).Count -ge 2) "Snapshot chart bridged the missing-value gap."

    $mixedPath = Join-Path $tempRoot "mixed.json"
    $mixedSnapshot = [pscustomobject]@{
        schemaVersion = "1.0"
        source = [pscustomobject]@{
            tool = "Primary Monitor"
            version = "2.0"
            deviceId = "mixed-device"
            capturedAt = "2026-11-03T13:00:00+08:00"
        }
        samples = @(
            [pscustomobject]@{
                capturedAt = "2026-11-03T13:00:00+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 60 },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 100 }
                )
            },
            [pscustomobject]@{
                capturedAt = "2026-11-03T13:00:01+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "F"; value = 140; sourceTool = "Secondary Monitor"; sourceVersion = "1.0"; deviceId = "mixed-device" },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 105 }
                )
            },
            [pscustomobject]@{
                capturedAt = "2026-11-03T13:00:03+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 62 },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 110 }
                )
            },
            [pscustomobject]@{
                capturedAt = "2026-11-03T13:00:06+08:00"
                sensors = @(
                    [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "F"; value = 143 },
                    [pscustomobject]@{ name = "GPU Power"; category = "power"; unit = "W"; value = 115 }
                )
            }
        )
    }
    Write-SnapshotFixture -Path $mixedPath -Snapshot $mixedSnapshot
    $mixedOutput = Join-Path $tempRoot "mixed-normalized.json"
    $mixedResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $mixedPath,
        "-OutputPath", $mixedOutput
    )
    Assert-True ($mixedResult.ExitCode -eq 0) "Mixed-source normalization failed: $($mixedResult.Stderr)"
    $mixedNormalized = Get-Content -Raw -LiteralPath $mixedOutput -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($mixedNormalized.Source.MixedSources -eq $true) "Mixed sources were not detected."
    Assert-True ($mixedNormalized.Sampling.Consistency -eq "variable") "Irregular sampling was not detected."
    Assert-True (($mixedNormalized.Warnings -join " ") -match "multiple units") "Mixed units were not warned."
    Assert-True (($mixedNormalized.Warnings -join " ") -match "varies materially") "Irregular sampling was not warned."
    Assert-True (($mixedNormalized.Warnings -join " ") -match "mixes multiple") "Mixed source identities were not warned."

    $missingVersionPath = Join-Path $tempRoot "missing-version.json"
    $missingVersion = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $missingVersion.source.PSObject.Properties.Remove("version")
    Write-SnapshotFixture -Path $missingVersionPath -Snapshot $missingVersion
    $missingVersionResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $missingVersionPath,
        "-OutputPath", (Join-Path $tempRoot "missing-version-output.json")
    )
    Assert-True ($missingVersionResult.ExitCode -eq 2) "Snapshot without source.version was accepted."
    Assert-True ($missingVersionResult.Stderr -match "source.tool and source.version") "Missing source version error is unclear."

    $samplesObjectPath = Join-Path $tempRoot "samples-object.json"
    $samplesObject = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $samplesObject.samples = $samplesObject.samples[0]
    Write-SnapshotFixture -Path $samplesObjectPath -Snapshot $samplesObject
    $samplesObjectResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $samplesObjectPath,
        "-OutputPath", (Join-Path $tempRoot "samples-object-output.json")
    )
    Assert-True ($samplesObjectResult.ExitCode -eq 2) "Object-valued samples property was accepted."
    Assert-True ($samplesObjectResult.Stderr -match "samples must be an array") "Object-valued samples error is unclear."

    $sensorsObjectPath = Join-Path $tempRoot "sensors-object.json"
    $sensorsObject = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $sensorsObject.samples[0].sensors = $sensorsObject.samples[0].sensors[0]
    Write-SnapshotFixture -Path $sensorsObjectPath -Snapshot $sensorsObject
    $sensorsObjectResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $sensorsObjectPath,
        "-OutputPath", (Join-Path $tempRoot "sensors-object-output.json")
    )
    Assert-True ($sensorsObjectResult.ExitCode -eq 2) "Object-valued sensors property was accepted."
    Assert-True ($sensorsObjectResult.Stderr -match "sensors must be an array") "Object-valued sensors error is unclear."

    $emptySensorsPath = Join-Path $tempRoot "empty-sensors.json"
    $emptySensors = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $emptySensors.samples[0].sensors = @()
    Write-SnapshotFixture -Path $emptySensorsPath -Snapshot $emptySensors
    $emptySensorsResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $emptySensorsPath,
        "-OutputPath", (Join-Path $tempRoot "empty-sensors-output.json")
    )
    Assert-True ($emptySensorsResult.ExitCode -eq 2) "Empty sensors array was accepted."
    Assert-True ($emptySensorsResult.Stderr -match "sensors array must not be empty") "Empty sensors error is unclear."

    $missingValuePath = Join-Path $tempRoot "missing-value-property.json"
    $missingValue = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $missingValue.samples[0].sensors[0].PSObject.Properties.Remove("value")
    Write-SnapshotFixture -Path $missingValuePath -Snapshot $missingValue
    $missingValueResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $missingValuePath,
        "-OutputPath", (Join-Path $tempRoot "missing-value-output.json")
    )
    Assert-True ($missingValueResult.ExitCode -eq 2) "Sensor with omitted value property was accepted."
    Assert-True ($missingValueResult.Stderr -match "missing the required value") "Omitted value error is unclear."

    $nonnumericPath = Join-Path $tempRoot "nonnumeric-value.json"
    $nonnumeric = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $nonnumeric.samples[0].sensors[0].value = "hot"
    Write-SnapshotFixture -Path $nonnumericPath -Snapshot $nonnumeric
    $nonnumericResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $nonnumericPath,
        "-OutputPath", (Join-Path $tempRoot "nonnumeric-output.json")
    )
    Assert-True ($nonnumericResult.ExitCode -eq 2) "Nonnumeric sensor value did not return schema exit code 2."
    Assert-True ($nonnumericResult.Stderr -match "finite number or null") "Nonnumeric value error is unclear."

    $backwardsPath = Join-Path $tempRoot "backwards.json"
    $backwards = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $backwards.samples[2].capturedAt = "2026-11-03T12:29:59+08:00"
    Write-SnapshotFixture -Path $backwardsPath -Snapshot $backwards
    $backwardsResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $backwardsPath,
        "-OutputPath", (Join-Path $tempRoot "backwards-output.json")
    )
    Assert-True ($backwardsResult.ExitCode -eq 2) "Backwards snapshot timestamps were accepted."
    Assert-True ($backwardsResult.Stderr -match "move backwards") "Backwards timestamp error is unclear."

    $duplicatePath = Join-Path $tempRoot "duplicate.json"
    $duplicate = $snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $duplicate.samples[0].sensors = @(
        [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 60 },
        [pscustomobject]@{ name = "GPU Temperature"; category = "temperature"; unit = "C"; value = 61 }
    )
    Write-SnapshotFixture -Path $duplicatePath -Snapshot $duplicate
    $duplicateResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $duplicatePath,
        "-OutputPath", (Join-Path $tempRoot "duplicate-output.json")
    )
    Assert-True ($duplicateResult.ExitCode -eq 2) "Duplicate sensor was accepted."
    Assert-True ($duplicateResult.Stderr -match "Duplicate sensor") "Duplicate sensor error is unclear."

    $offlinePath = Join-Path $tempRoot "offline-snapshot.json"
    Copy-Item -LiteralPath $snapshotPath -Destination $offlinePath
    $originalAttributes = [IO.File]::GetAttributes($offlinePath)
    try {
        [IO.File]::SetAttributes(
            $offlinePath,
            $originalAttributes -bor [IO.FileAttributes]::Offline
        )
        $offlineResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
            "-Path", $offlinePath,
            "-OutputPath", (Join-Path $tempRoot "offline-output.json")
        )
        Assert-True ($offlineResult.ExitCode -eq 2) "Offline snapshot was accepted."
        Assert-True ($offlineResult.Stderr -match "offline or cloud-placeholder") "Offline-file rejection is unclear."
    }
    finally {
        [IO.File]::SetAttributes($offlinePath, $originalAttributes)
    }

    $overwriteResult = Invoke-Process -ScriptPath $resolvedAdapter -Arguments @(
        "-Path", $csvPath,
        "-OutputPath", $csvOutput
    )
    Assert-True ($overwriteResult.ExitCode -eq 2) "Adapter overwrote an existing normalized output."
    Assert-True ($overwriteResult.Stderr -match "already exists") "Adapter overwrite rejection is unclear."

    $invalidRender = Invoke-Process -ScriptPath $resolvedRenderer -Arguments @(
        "-Path", $snapshotOutput,
        "-OutputPath", (Join-Path $tempRoot "invalid-normalized.svg"),
        "-MaxPoints", "100"
    )
    Assert-True ($invalidRender.ExitCode -eq 2) "Renderer accepted CSV-only options for normalized JSON."
    Assert-True ($invalidRender.Stderr -match "already windowed") "Normalized-input option rejection is unclear."

    $incompleteNormalizedPath = Join-Path $tempRoot "incomplete-normalized.json"
    $incompleteNormalized = Get-Content -Raw -LiteralPath $snapshotOutput -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @("Source", "Sampling", "Sensors", "DataQuality", "Warnings")) {
        $incompleteNormalized.PSObject.Properties.Remove($name)
    }
    [IO.File]::WriteAllText(
        $incompleteNormalizedPath,
        ($incompleteNormalized | ConvertTo-Json -Depth 20) + "`r`n",
        $utf8
    )
    $incompleteRender = Invoke-Process -ScriptPath $resolvedRenderer -Arguments @(
        "-Path", $incompleteNormalizedPath,
        "-OutputPath", (Join-Path $tempRoot "incomplete-normalized.svg"),
        "-InputFormat", "NormalizedJson"
    )
    Assert-True ($incompleteRender.ExitCode -eq 2) "Renderer accepted a normalized document with missing provenance sections."
    Assert-True ($incompleteRender.Stderr -match "missing required section") "Missing normalized-section error is unclear."

    if ($failures.Count -gt 0) {
        Write-Host "Telemetry normalization regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Telemetry normalization regression: PASS" -ForegroundColor Green
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
