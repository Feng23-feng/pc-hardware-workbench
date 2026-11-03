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
        -Warnings @("Synthetic LHM fixture warning.")
    Assert-True ($snapshot.schemaVersion -eq "1.0") "LHM snapshot schema is missing."
    Assert-True ($snapshot.source.tool -eq "LibreHardwareMonitor") "LHM source tool is wrong."
    Assert-True ($snapshot.source.version -eq "1.3-test") "LHM source version is wrong."
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

& $CollectorPath -OutputPath $OutputPath -AllowLiveCollector -DeviceAlias "mock-lhm" -MaxSensors $MaxSensors
if ($null -ne $LASTEXITCODE) {
    exit $LASTEXITCODE
}
'@, (New-Object System.Text.UTF8Encoding($false)))

    $mockSuccessPath = Join-Path $tempRoot "mock-lhm-success.json"
    $mockSuccess = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockSuccessPath,
        "-Case", "success",
        "-MaxSensors", "10"
    )
    Assert-True ($mockSuccess.ExitCode -eq 0) "Mocked LHM success path failed: $($mockSuccess.Stderr)"
    Assert-True (Test-Path -LiteralPath $mockSuccessPath -PathType Leaf) "Mocked LHM success did not create output."

    $mockEmptyPath = Join-Path $tempRoot "mock-lhm-empty.json"
    $mockEmpty = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockEmptyPath,
        "-Case", "empty",
        "-MaxSensors", "10"
    )
    Assert-True ($mockEmpty.ExitCode -eq 1) "Empty mocked LHM sensor set did not return exit 1: exit=$($mockEmpty.ExitCode) stderr=$($mockEmpty.Stderr)"
    Assert-True (-not (Test-Path -LiteralPath $mockEmptyPath -PathType Leaf)) "Empty mocked LHM sensor set created output."

    $mockFailurePath = Join-Path $tempRoot "mock-lhm-failure.json"
    $mockFailure = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockFailurePath,
        "-Case", "wmi-failure",
        "-MaxSensors", "10"
    )
    Assert-True ($mockFailure.ExitCode -eq 1) "Mocked LHM WMI failure did not return exit 1: exit=$($mockFailure.ExitCode) stderr=$($mockFailure.Stderr)"
    Assert-True ($mockFailure.Stderr -match "WMI is unavailable") "Mocked WMI failure message is unclear."

    $mockLimitPath = Join-Path $tempRoot "mock-lhm-limit.json"
    $mockLimit = Invoke-Process -ScriptPath $harnessPath -Arguments @(
        "-CollectorPath", $resolvedCollector,
        "-OutputPath", $mockLimitPath,
        "-Case", "limit",
        "-MaxSensors", "1"
    )
    Assert-True ($mockLimit.ExitCode -eq 2) "Mocked LHM sensor limit did not return exit 2: exit=$($mockLimit.ExitCode) stderr=$($mockLimit.Stderr)"
    Assert-True ($mockLimit.Stderr -match "sensor limit") "Mocked LHM sensor-limit message is unclear."
    Assert-True (-not (Test-Path -LiteralPath $mockLimitPath -PathType Leaf)) "Mocked LHM sensor-limit case created output."

    $collectorText = Get-Content -Raw -LiteralPath $resolvedCollector -Encoding UTF8
    Assert-True ($collectorText -match "root/LibreHardwareMonitor") "LHM collector does not query the documented WMI namespace."
    Assert-True ($collectorText -notmatch '(?i)Start-Process|Start-Service|Invoke-WebRequest|Invoke-RestMethod|schtasks\.exe|sc\.exe') "LHM collector can start software, execute remote content, or persist itself."
    Assert-True ($collectorText -notmatch '(?i)runas|verb\s+runas|windowsprincipal') "LHM collector can self-elevate."

    if ($failures.Count -gt 0) {
        Write-Host "LHM adapter regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "LHM adapter regression: PASS" -ForegroundColor Green
    Write-Host "Live LHM WMI read: SKIP (requires an already-running LHM process and explicit -AllowLiveCollector)" -ForegroundColor Yellow
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
