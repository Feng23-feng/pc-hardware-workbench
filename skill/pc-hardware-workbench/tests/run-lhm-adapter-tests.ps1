[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$FunctionsPath,

    [Parameter(Mandatory = $true)]
    [string]$CollectorPath,

    [Parameter(Mandatory = $true)]
    [string]$NormalizerPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$resolvedFunctions = (Resolve-Path -LiteralPath $FunctionsPath).Path
$resolvedCollector = (Resolve-Path -LiteralPath $CollectorPath).Path
$resolvedNormalizer = (Resolve-Path -LiteralPath $NormalizerPath).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-lhm-$([guid]::NewGuid().ToString('N'))"

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
        throw "LHM adapter process timed out."
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.Result
        Stderr = $stderrTask.Result
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    . $resolvedFunctions

    $sensorFixtures = @(
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/temperature/0"; Name = "GPU Core"; SensorType = "Temperature"; Value = 61.5 },
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/power/0"; Name = "GPU Package"; SensorType = "Power"; Value = 120.0 },
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/clock/0"; Name = "GPU Core"; SensorType = "Clock"; Value = 2400.0 },
        [pscustomobject]@{ Identifier = "/cpu/0/temperature/0"; Name = "CPU Package"; SensorType = "Temperature"; Value = 70.0 },
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/fan/0"; Name = "GPU Fan"; SensorType = "Fan"; Value = 1800.0 },
        [pscustomobject]@{ Identifier = "/motherboard/0/temperature/0"; Name = "System"; SensorType = "Temperature"; Value = 38.0 },
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/custom/0"; Name = "Vendor Metric"; SensorType = "UnknownType"; Value = 1.0 }
    )
    $converted = @(ConvertFrom-LhmSensorObjects -Sensors $sensorFixtures -MaxSensors 20)
    Assert-True ($converted.Count -eq 7) "LHM sensor conversion omitted supported fixture sensors."
    $gpuTemperature = @($converted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/temperature/0" }) | Select-Object -First 1
    $gpuPower = @($converted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/power/0" }) | Select-Object -First 1
    $gpuClock = @($converted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/clock/0" }) | Select-Object -First 1
    $unknown = @($converted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/custom/0" }) | Select-Object -First 1
    Assert-True ($gpuTemperature.category -eq "temperature" -and $gpuTemperature.unit -eq "C") "LHM temperature mapping is wrong."
    Assert-True ($gpuPower.category -eq "power" -and $gpuPower.unit -eq "W") "LHM power mapping is wrong."
    Assert-True ($gpuClock.category -eq "clock" -and $gpuClock.unit -eq "MHz") "LHM clock mapping is wrong."
    Assert-True ($unknown.category -eq "other" -and $unknown.unit -eq "unitless") "Unknown LHM sensor type was not isolated."
    Assert-True ($gpuTemperature.name -match '^GPU ') "GPU sensor name was not component-qualified."

    $duplicateFixtures = @(
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/temperature/0"; Name = "GPU Core"; SensorType = "Temperature"; Value = 60.0 },
        [pscustomobject]@{ Identifier = "/gpu-nvidia/0/temperature/0"; Name = "GPU Core"; SensorType = "Temperature"; Value = 61.0 }
    )
    $duplicates = @(ConvertFrom-LhmSensorObjects -Sensors $duplicateFixtures -MaxSensors 20)
    Assert-True ($duplicates[0].name -ne $duplicates[1].name) "Duplicate LHM sensor names were not disambiguated."
    Assert-True ($duplicates[1].name -match '#2$') "Duplicate LHM sensor did not receive a stable suffix."

    $limitRejected = $false
    try {
        ConvertFrom-LhmSensorObjects -Sensors $duplicateFixtures -MaxSensors 1 | Out-Null
    }
    catch {
        $limitRejected = $_.Exception.Message -match "sensor limit"
    }
    Assert-True $limitRejected "LHM sensor-count limit was not enforced."

    $webTree = [pscustomobject]@{
        Text = "Sensor"
        Children = @(
            [pscustomobject]@{
                Text = "NVIDIA RTX Fixture"
                Children = @(
                    [pscustomobject]@{
                        Text = "GPU Core"
                        Value = "61.5 $([char]0x00B0)C"
                        RawValue = "61.5 $([char]0x00B0)C"
                        SensorId = "/gpu-nvidia/0/temperature/0"
                        Type = "Temperature"
                        Children = @()
                    },
                    [pscustomobject]@{
                        Text = "GPU Memory"
                        Value = "14.001 GHz"
                        RawValue = "14.001 GHz"
                        SensorId = "/gpu-nvidia/0/clock/1"
                        Type = "Clock"
                        Children = @()
                    },
                    [pscustomobject]@{
                        Text = "GPU Memory Used"
                        Value = "1.5 GB"
                        RawValue = "1.5 GB"
                        SensorId = "/gpu-nvidia/0/smalldata/1"
                        Type = "SmallData"
                        Children = @()
                    }
                )
            },
            [pscustomobject]@{
                Text = "Memory"
                Children = @(
                    [pscustomobject]@{
                        Text = "Memory Used"
                        Value = "14.2 GB"
                        RawValue = "14.2 GB"
                        SensorId = "/ram/data/0"
                        Type = "Data"
                        Children = @()
                    },
                    [pscustomobject]@{
                        Text = "Heading"
                        Value = ""
                        Children = @()
                    }
                )
            }
        )
    }
    $webSensorObjects = @(ConvertFrom-LhmWebSensorTree -Document $webTree -MaxSensors 20)
    Assert-True ($webSensorObjects.Count -eq 4) "LHM Web tree flattening returned the wrong sensor count."
    $webConverted = @(ConvertFrom-LhmSensorObjects -Sensors $webSensorObjects -MaxSensors 20)
    $webTemperature = @($webConverted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/temperature/0" }) | Select-Object -First 1
    $webMemoryClock = @($webConverted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/clock/1" }) | Select-Object -First 1
    $webGpuMemory = @($webConverted | Where-Object { $_.identifier -eq "/gpu-nvidia/0/smalldata/1" }) | Select-Object -First 1
    $webSystemMemory = @($webConverted | Where-Object { $_.identifier -eq "/ram/data/0" }) | Select-Object -First 1
    Assert-True ($webTemperature.category -eq "temperature" -and $webTemperature.value -eq 61.5) "LHM Web temperature parsing is wrong."
    Assert-True ($webTemperature.hardwarePath -match "NVIDIA RTX Fixture") "LHM Web hardware context was not retained."
    Assert-True ($null -ne $webMemoryClock -and [Math]::Abs([double]$webMemoryClock.value - 14001.0) -lt 0.001) "LHM Web GHz-to-MHz conversion is wrong."
    Assert-True ($null -ne $webGpuMemory -and [Math]::Abs([double]$webGpuMemory.value - 1536.0) -lt 0.001) "LHM Web GB-to-MB conversion is wrong."
    Assert-True ($null -ne $webSystemMemory -and [Math]::Abs([double]$webSystemMemory.value - 14540.8) -lt 0.001) "LHM Web system-memory conversion is wrong."
    $fahrenheitValue = ConvertFrom-LhmDisplayValue -Value "111.2 $([char]0x00B0)F" -TargetUnit "C"
    Assert-True ([Math]::Abs([double]$fahrenheitValue - 44.0) -lt 0.001) "LHM Web Fahrenheit-to-Celsius conversion is wrong."
    $unknownUnitValue = ConvertFrom-LhmDisplayValue -Value "14.2 bananas" -TargetUnit "MB"
    Assert-True ($null -eq $unknownUnitValue) "LHM Web accepted an unsupported unit conversion."

    $webLimitRejected = $false
    try {
        ConvertFrom-LhmWebSensorTree -Document $webTree -MaxSensors 3 | Out-Null
    }
    catch {
        $webLimitRejected = $_.Exception.Message -match "sensor limit"
    }
    Assert-True $webLimitRejected "LHM Web sensor-count limit was not enforced."

    $samples = @(
        [pscustomobject]@{
            capturedAt = "2026-11-03T12:00:00+08:00"
            sensors = @($converted)
        },
        [pscustomobject]@{
            capturedAt = "2026-11-03T12:00:01+08:00"
            sensors = @($converted | ForEach-Object {
                [pscustomobject]@{
                    name = $_.name
                    category = $_.category
                    unit = $_.unit
                    value = if ($null -eq $_.value) { $null } else { [double]$_.value + 1 }
                    identifier = $_.identifier
                }
            })
        }
    )
    $snapshot = New-LhmSensorSnapshot `
        -Samples $samples `
        -SourceVersion "1.3-test" `
        -DeviceAlias "lhm-fixture" `
        -Transport "fixture" `
        -Warnings @("Synthetic LHM fixture warning.")
    Assert-True ($snapshot.schemaVersion -eq "1.0") "LHM snapshot schema is missing."
    Assert-True ($snapshot.source.tool -eq "LibreHardwareMonitor") "LHM source tool is wrong."
    Assert-True ($snapshot.source.version -eq "1.3-test") "LHM source version is wrong."
    Assert-True ($snapshot.source.transport -eq "fixture") "LHM source transport is wrong."
    Assert-True ($snapshot.source.deviceId -eq "lhm-fixture") "LHM device alias is missing."
    Assert-True (@($snapshot.warnings).Count -eq 1) "LHM snapshot warning was not retained."

    $snapshotPath = Join-Path $tempRoot "lhm-snapshot.json"
    [IO.File]::WriteAllText(
        $snapshotPath,
        ($snapshot | ConvertTo-Json -Depth 20) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $normalizedPath = Join-Path $tempRoot "lhm-normalized.json"
    $normalizeResult = Invoke-Process -ScriptPath $resolvedNormalizer -Arguments @(
        "-Path", $snapshotPath,
        "-OutputPath", $normalizedPath
    )
    Assert-True ($normalizeResult.ExitCode -eq 0) "LHM snapshot could not be normalized: $($normalizeResult.Stderr)"
    $normalized = Get-Content -Raw -LiteralPath $normalizedPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($normalized.Source.Tool -eq "LibreHardwareMonitor") "Normalized LHM provenance was lost."
    Assert-True (($normalized.Warnings -join " ") -match "Synthetic LHM fixture warning") "LHM adapter warning was not propagated."
    Assert-True (@($normalized.ChartData.Series | Where-Object { $_.Metric -eq "GPU temperature (C)" }).Count -eq 1) "LHM GPU temperature series was not normalized. metrics=$(@($normalized.ChartData.Series.Metric) -join ',')"

    $withoutConsentPath = Join-Path $tempRoot "lhm-without-consent.json"
    $withoutConsent = Invoke-Process -ScriptPath $resolvedCollector -Arguments @(
        "-OutputPath", $withoutConsentPath
    )
    Assert-True ($withoutConsent.ExitCode -eq 2) "LHM collector ran without explicit consent."
    Assert-True ($withoutConsent.Stderr -match "AllowLiveCollector") "LHM consent rejection is unclear."
    Assert-True (-not (Test-Path -LiteralPath $withoutConsentPath -PathType Leaf)) "LHM collector created output without consent."

    $harnessPath = Join-Path $tempRoot "mock-lhm-collector.ps1"
    [IO.File]::WriteAllText($harnessPath, @'
param(
    [Parameter(Mandatory = $true)][string]$CollectorPath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [Parameter(Mandatory = $true)][string]$Case,
    [ValidateSet("Auto", "Web", "Wmi")][string]$Transport = "Auto",
    [string]$WebEndpoint = "http://127.0.0.1:8085/data.json",
    [int]$MaxSensors = 500
)

function Get-Process {
    [CmdletBinding()]
    param()
}

function Get-CimInstance {
    [CmdletBinding()]
    param(
        [string]$Namespace,
        [string]$ClassName
    )
    if ($Case -eq "wmi-failure") {
        throw "Mock LHM namespace unavailable."
    }
    if ($Case -eq "empty") {
        return
    }
    if ($Case -eq "limit") {
        return @(
            [pscustomobject]@{ Identifier = "/gpu-nvidia/0/temperature/0"; Name = "GPU Core"; SensorType = "Temperature"; Value = 60.0 },
            [pscustomobject]@{ Identifier = "/gpu-nvidia/0/power/0"; Name = "GPU Package"; SensorType = "Power"; Value = 120.0 }
        )
    }
    return [pscustomobject]@{
        Identifier = "/gpu-nvidia/0/temperature/0"
        Name = "GPU Core"
        SensorType = "Temperature"
        Value = 60.0
    }
}

function Invoke-RestMethod {
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Method,
        [int]$TimeoutSec
    )
    if ($Case -eq "web-failure") {
        throw "Mock LHM web endpoint unavailable."
    }
    if ($Case -eq "web-empty") {
        return [pscustomobject]@{
            Text = "Sensor"
            Children = @()
        }
    }
    if ($Case -eq "web-limit") {
        return [pscustomobject]@{
            Text = "Sensor"
            Children = @(
                [pscustomobject]@{
                    Text = "GPU Core"
                    RawValue = "60.0 $([char]0x00B0)C"
                    SensorId = "/gpu-nvidia/0/temperature/0"
                    Type = "Temperature"
                    Children = @()
                },
                [pscustomobject]@{
                    Text = "GPU Package"
                    RawValue = "120.0 W"
                    SensorId = "/gpu-nvidia/0/power/0"
                    Type = "Power"
                    Children = @()
                }
            )
        }
    }
    return [pscustomobject]@{
        Text = "Sensor"
        Children = @(
            [pscustomobject]@{
                Text = "NVIDIA GeForce RTX Fixture"
                Children = @(
                    [pscustomobject]@{
                        Text = "GPU Core"
                        RawValue = "60.0 $([char]0x00B0)C"
                        SensorId = "/gpu-nvidia/0/temperature/0"
                        Type = "Temperature"
                        Children = @()
                    },
                    [pscustomobject]@{
                        Text = "GPU Core"
                        RawValue = "2100.0 MHz"
                        SensorId = "/gpu-nvidia/0/clock/0"
                        Type = "Clock"
                        Children = @()
                    }
                )
            }
        )
    }
}

& $CollectorPath -OutputPath $OutputPath -AllowLiveCollector -Transport $Transport -WebEndpoint $WebEndpoint -DeviceAlias "mock-lhm" -MaxSensors $MaxSensors -SourceVersion "fixture"
if ($null -ne $LASTEXITCODE) {
    exit $LASTEXITCODE
}
'@, (New-Object System.Text.UTF8Encoding($false)))

    $mockSuccessPath = Join-Path $tempRoot "mock-lhm-success.json"
    $mockSuccess = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockSuccessPath,
        "-Case", "success",
        "-Transport", "Wmi",
        "-MaxSensors", "10"
    )
    Assert-True ($mockSuccess.ExitCode -eq 0) "Mocked LHM success path failed: $($mockSuccess.Stderr)"
    Assert-True (Test-Path -LiteralPath $mockSuccessPath -PathType Leaf) "Mocked LHM success did not create output."

    $mockEmptyPath = Join-Path $tempRoot "mock-lhm-empty.json"
    $mockEmpty = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockEmptyPath,
        "-Case", "empty",
        "-Transport", "Wmi",
        "-MaxSensors", "10"
    )
    Assert-True ($mockEmpty.ExitCode -eq 1) "Empty mocked LHM sensor set did not return exit 1: exit=$($mockEmpty.ExitCode) stderr=$($mockEmpty.Stderr)"
    Assert-True (-not (Test-Path -LiteralPath $mockEmptyPath -PathType Leaf)) "Empty mocked LHM sensor set created output."

    $mockFailurePath = Join-Path $tempRoot "mock-lhm-failure.json"
    $mockFailure = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockFailurePath,
        "-Case", "wmi-failure",
        "-Transport", "Wmi",
        "-MaxSensors", "10"
    )
    Assert-True ($mockFailure.ExitCode -eq 1) "Mocked LHM WMI failure did not return exit 1: exit=$($mockFailure.ExitCode) stderr=$($mockFailure.Stderr)"
    Assert-True ($mockFailure.Stderr -match "live read failed") "Mocked WMI failure message is unclear."

    $mockLimitPath = Join-Path $tempRoot "mock-lhm-limit.json"
    $mockLimit = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockLimitPath,
        "-Case", "limit",
        "-Transport", "Wmi",
        "-MaxSensors", "1"
    )
    Assert-True ($mockLimit.ExitCode -eq 2) "Mocked LHM sensor limit did not return exit 2: exit=$($mockLimit.ExitCode) stderr=$($mockLimit.Stderr)"
    Assert-True ($mockLimit.Stderr -match "sensor limit") "Mocked LHM sensor-limit message is unclear."
    Assert-True (-not (Test-Path -LiteralPath $mockLimitPath -PathType Leaf)) "Mocked LHM sensor-limit case created output."

    $mockWebSuccessPath = Join-Path $tempRoot "mock-lhm-web-success.json"
    $mockWebSuccess = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockWebSuccessPath,
        "-Case", "web-success",
        "-Transport", "Web",
        "-MaxSensors", "10"
    )
    Assert-True ($mockWebSuccess.ExitCode -eq 0) "Mocked LHM Web success path failed: $($mockWebSuccess.Stderr)"
    $mockWebSnapshot = Get-Content -Raw -LiteralPath $mockWebSuccessPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($mockWebSnapshot.source.transport -eq "Web") "Mocked LHM Web transport was not recorded."
    Assert-True (@($mockWebSnapshot.samples[0].sensors).Count -eq 2) "Mocked LHM Web sensor tree was not flattened."
    Assert-True (($mockWebSnapshot.source.observedComponents -join " ") -match "NVIDIA GeForce RTX Fixture") "Mocked LHM Web component identity was not retained."
    $mockWebNormalizedPath = Join-Path $tempRoot "mock-lhm-web-normalized.json"
    $mockWebNormalize = Invoke-Process -ScriptPath $resolvedNormalizer -Arguments @(
        "-Path", $mockWebSuccessPath,
        "-OutputPath", $mockWebNormalizedPath
    )
    Assert-True ($mockWebNormalize.ExitCode -eq 0) "Mocked LHM Web snapshot could not be normalized: $($mockWebNormalize.Stderr)"
    $mockWebNormalized = Get-Content -Raw -LiteralPath $mockWebNormalizedPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True (($mockWebNormalized.Source.ObservedComponents -join " ") -match "NVIDIA GeForce RTX Fixture") "Normalized LHM Web component identity was lost."

    $mockWebFallbackPath = Join-Path $tempRoot "mock-lhm-web-fallback.json"
    $mockWebFallback = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockWebFallbackPath,
        "-Case", "web-failure",
        "-Transport", "Auto",
        "-MaxSensors", "10"
    )
    Assert-True ($mockWebFallback.ExitCode -eq 0) "LHM Auto transport did not fall back to WMI: $($mockWebFallback.Stderr)"
    $mockFallbackSnapshot = Get-Content -Raw -LiteralPath $mockWebFallbackPath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($mockFallbackSnapshot.source.transport -eq "Wmi") "LHM Auto fallback did not record WMI transport."

    $mockWebEmptyPath = Join-Path $tempRoot "mock-lhm-web-empty.json"
    $mockWebEmpty = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockWebEmptyPath,
        "-Case", "web-empty",
        "-Transport", "Web",
        "-MaxSensors", "10"
    )
    Assert-True ($mockWebEmpty.ExitCode -eq 1) "Empty mocked LHM Web sensor tree did not return exit 1."

    $mockWebLimitPath = Join-Path $tempRoot "mock-lhm-web-limit.json"
    $mockWebLimit = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockWebLimitPath,
        "-Case", "web-limit",
        "-Transport", "Web",
        "-MaxSensors", "1"
    )
    Assert-True ($mockWebLimit.ExitCode -eq 2) "Mocked LHM Web sensor limit did not return exit 2."

    $remoteEndpointPath = Join-Path $tempRoot "mock-lhm-remote-endpoint.json"
    $remoteEndpoint = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $remoteEndpointPath,
        "-Case", "web-success",
        "-Transport", "Web",
        "-MaxSensors", "10",
        "-WebEndpoint", "http://192.0.2.10:8085/data.json"
    )
    Assert-True ($remoteEndpoint.ExitCode -eq 2) "LHM Web accepted a non-loopback endpoint."
    Assert-True (-not (Test-Path -LiteralPath $remoteEndpointPath -PathType Leaf)) "LHM Web created output for a rejected endpoint."

    $collectorText = Get-Content -Raw -LiteralPath $resolvedCollector -Encoding UTF8
    Assert-True ($collectorText -match "root/LibreHardwareMonitor") "LHM collector does not query the documented WMI namespace."
    Assert-True ($collectorText -match '127\.0\.0\.1:8085/data\.json') "LHM collector is missing its local Web endpoint default."
    Assert-True ($collectorText -match 'IsLoopback') "LHM collector does not restrict Web access to loopback."
    Assert-True ($collectorText -notmatch '(?i)Start-Process|Start-Service|schtasks\.exe|sc\.exe') "LHM collector can start software or persist itself."
    Assert-True ($collectorText -notmatch '(?i)runas|verb\s+runas|windowsprincipal') "LHM collector can self-elevate."

    if ($failures.Count -gt 0) {
        Write-Host "LHM adapter regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "LHM adapter regression: PASS" -ForegroundColor Green
    Write-Host "Live LHM Web/WMI read: SKIP (requires an already-running LHM process and explicit -AllowLiveCollector)" -ForegroundColor Yellow
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
