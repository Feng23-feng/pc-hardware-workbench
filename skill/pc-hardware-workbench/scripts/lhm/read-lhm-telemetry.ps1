[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [switch]$AllowLiveCollector,

    [string]$DeviceAlias,

    [ValidateRange(0, 300)]
    [int]$DurationSeconds = 0,

    [ValidateRange(0.25, 60.0)]
    [double]$IntervalSeconds = 1.0,

    [ValidateRange(1, 5000)]
    [int]$MaxSensors = 500
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$pathSafetyHelper = Join-Path $PSScriptRoot "..\local-path-safety.ps1"
$functionsPath = Join-Path $PSScriptRoot "lhm-functions.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
if (-not (Test-Path -LiteralPath $functionsPath -PathType Leaf)) {
    throw "LHM helper functions are missing: $functionsPath"
}
. $pathSafetyHelper
. $functionsPath

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Stop-WithCollectorError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

if (-not $AllowLiveCollector) {
    Stop-WithInputError "Live LHM collection requires explicit -AllowLiveCollector consent."
}

try {
    $resolvedOutput = Resolve-LocalOutputFilePath -Path $OutputPath
}
catch {
    Stop-WithInputError $_.Exception.Message
}
if ([IO.Path]::GetExtension($resolvedOutput) -ine ".json") {
    Stop-WithInputError "OutputPath must use the .json extension."
}

$sampleCount = if ($DurationSeconds -le 0) {
    1
}
else {
    [int][Math]::Floor($DurationSeconds / $IntervalSeconds) + 1
}
if ($sampleCount -gt 1201) {
    Stop-WithInputError "Sampling plan exceeds 1201 samples."
}

$version = "unknown"
$warnings = New-Object System.Collections.Generic.List[string]
$lhmProcess = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '(?i)librehardwaremonitor' } |
    Select-Object -First 1
if ($null -eq $lhmProcess) {
    $warnings.Add("LibreHardwareMonitor process was not detected; WMI may fail or be stale.") | Out-Null
}
else {
    try {
        $versionText = ConvertTo-LhmCleanText $lhmProcess.MainModule.FileVersionInfo.ProductVersion
        if (-not [string]::IsNullOrWhiteSpace($versionText)) {
            $version = $versionText
        }
    }
    catch {
        $warnings.Add("LibreHardwareMonitor version could not be read from the running process.") | Out-Null
    }
}
if ([string]::IsNullOrWhiteSpace($DeviceAlias)) {
    $warnings.Add("Device alias was not supplied; this snapshot has no user-friendly device identity.") | Out-Null
}

$samples = New-Object System.Collections.Generic.List[object]
for ($sampleIndex = 0; $sampleIndex -lt $sampleCount; $sampleIndex++) {
    $capturedAt = [datetimeoffset]::Now.ToString("o", $invariant)
    try {
        $sensorObjects = @(
            Get-CimInstance `
                -Namespace "root/LibreHardwareMonitor" `
                -ClassName "Sensor" `
                -ErrorAction Stop
        )
    }
    catch {
        if ($samples.Count -eq 0) {
            Stop-WithCollectorError "LibreHardwareMonitor WMI is unavailable. Start the already-installed LHM application and enable its WMI interface; this adapter will not install, start, or elevate it. $($_.Exception.Message)"
        }
        $warnings.Add("A later LHM sample failed; the captured series is incomplete.") | Out-Null
        break
    }

    if ($sensorObjects.Count -gt $MaxSensors) {
        Stop-WithInputError "LHM sensor count $($sensorObjects.Count) exceeds the configured $MaxSensors sensor limit."
    }
    try {
        $convertedSensors = @(
            ConvertFrom-LhmSensorObjects `
                -Sensors $sensorObjects `
                -MaxSensors $MaxSensors
        )
    }
    catch {
        Stop-WithCollectorError $_.Exception.Message
    }
    if ($convertedSensors.Count -eq 0) {
        if ($samples.Count -eq 0) {
            Stop-WithCollectorError "LibreHardwareMonitor returned no supported sensor objects."
        }
        $warnings.Add("A later LHM sample contained no supported sensors and was skipped.") | Out-Null
        break
    }

    $samples.Add([pscustomobject]@{
        capturedAt = $capturedAt
        sensors = @($convertedSensors)
    }) | Out-Null

    if ($sampleIndex -lt ($sampleCount - 1)) {
        $sleepMilliseconds = [int][Math]::Round($IntervalSeconds * 1000)
        Start-Sleep -Milliseconds $sleepMilliseconds
    }
}

if ($samples.Count -eq 0) {
    Stop-WithCollectorError "No usable LibreHardwareMonitor samples were collected."
}

$snapshot = New-LhmSensorSnapshot `
    -Samples @($samples.ToArray()) `
    -SourceVersion $version `
    -DeviceAlias $DeviceAlias `
    -Warnings @($warnings)
$json = $snapshot | ConvertTo-Json -Depth 20
$writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content ($json + "`r`n")
Write-Output $writtenPath
