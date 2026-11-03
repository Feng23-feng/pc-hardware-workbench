[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputPath,

    [switch]$AllowLiveCollector,

    [string]$DeviceAlias,

    [ValidateSet("Auto", "Web", "Wmi")]
    [string]$Transport = "Auto",

    [string]$WebEndpoint = "http://127.0.0.1:8085/data.json",

    [string]$SourceVersion,

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

function Resolve-LhmWebEndpoint {
    param([Parameter(Mandatory = $true)][string]$Value)
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
        throw "WebEndpoint must be an absolute URI."
    }
    if ($uri.Scheme -ne "http" -or
        -not $uri.IsLoopback -or
        $uri.AbsolutePath -ne "/data.json" -or
        -not [string]::IsNullOrWhiteSpace($uri.UserInfo) -or
        -not [string]::IsNullOrWhiteSpace($uri.Query) -or
        -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw "WebEndpoint must be a local http:// loopback URI ending in /data.json."
    }
    return $uri.AbsoluteUri
}

function Get-LhmWebSensors {
    param([Parameter(Mandatory = $true)][string]$Endpoint)
    $document = Invoke-RestMethod `
        -Uri $Endpoint `
        -Method Get `
        -TimeoutSec 5 `
        -ErrorAction Stop
    $sensorObjects = @(
        ConvertFrom-LhmWebSensorTree `
            -Document $document `
            -MaxSensors $MaxSensors
    )
    $converted = @(
        ConvertFrom-LhmSensorObjects `
            -Sensors $sensorObjects `
            -MaxSensors $MaxSensors
    )
    if ($converted.Count -eq 0) {
        throw "LibreHardwareMonitor Web returned no supported sensor objects."
    }
    return $converted
}

function Get-LhmWmiSensors {
    $sensorObjects = @(
        Get-CimInstance `
            -Namespace "root/LibreHardwareMonitor" `
            -ClassName "Sensor" `
            -ErrorAction Stop
    )
    if ($sensorObjects.Count -gt $MaxSensors) {
        throw "LHM sensor count $($sensorObjects.Count) exceeds the configured $MaxSensors sensor limit."
    }
    $converted = @(
        ConvertFrom-LhmSensorObjects `
            -Sensors $sensorObjects `
            -MaxSensors $MaxSensors
    )
    if ($converted.Count -eq 0) {
        throw "LibreHardwareMonitor WMI returned no supported sensor objects."
    }
    return $converted
}

$resolvedWebEndpoint = $null
if ($Transport -in @("Auto", "Web")) {
    try {
        $resolvedWebEndpoint = Resolve-LhmWebEndpoint $WebEndpoint
    }
    catch {
        Stop-WithInputError $_.Exception.Message
    }
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

$version = if ([string]::IsNullOrWhiteSpace($SourceVersion)) {
    "unknown"
}
else {
    ConvertTo-LhmCleanText $SourceVersion
}
$warnings = New-Object System.Collections.Generic.List[string]
$lhmProcess = Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match '(?i)librehardwaremonitor' } |
    Select-Object -First 1
if ($null -eq $lhmProcess) {
    $warnings.Add("LibreHardwareMonitor process was not detected; live reads may fail or be stale.") | Out-Null
}
elseif ($version -eq "unknown") {
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
$activeTransport = if ($Transport -eq "Auto") { $null } else { $Transport }
for ($sampleIndex = 0; $sampleIndex -lt $sampleCount; $sampleIndex++) {
    $capturedAt = [datetimeoffset]::Now.ToString("o", $invariant)
    try {
        if ($null -eq $activeTransport) {
            $webFailure = $null
            try {
                $convertedSensors = @(Get-LhmWebSensors -Endpoint $resolvedWebEndpoint)
                $activeTransport = "Web"
            }
            catch {
                $webFailure = $_.Exception.Message
                if ($webFailure -match '(?i)sensor limit') {
                    Stop-WithInputError $webFailure
                }
            }

            if ($null -eq $activeTransport) {
                try {
                    $convertedSensors = @(Get-LhmWmiSensors)
                    $activeTransport = "Wmi"
                    $warnings.Add("LibreHardwareMonitor local Web endpoint was unavailable; WMI transport was used.") | Out-Null
                }
                catch {
                    $wmiFailure = $_.Exception.Message
                    if ($wmiFailure -match '(?i)sensor limit') {
                        Stop-WithInputError $wmiFailure
                    }
                    throw "Neither the local LibreHardwareMonitor Web endpoint nor WMI is available. Web: $webFailure WMI: $wmiFailure"
                }
            }
        }
        elseif ($activeTransport -eq "Web") {
            $convertedSensors = @(Get-LhmWebSensors -Endpoint $resolvedWebEndpoint)
        }
        else {
            $convertedSensors = @(Get-LhmWmiSensors)
        }
    }
    catch {
        $failureMessage = $_.Exception.Message
        if ($failureMessage -match '(?i)sensor limit') {
            Stop-WithInputError $failureMessage
        }
        if ($samples.Count -eq 0) {
            Stop-WithCollectorError "LibreHardwareMonitor live read failed. Start the already-installed LHM application and enable Remote Web Server or WMI; this adapter will not install, start, or elevate it. $failureMessage"
        }
        $warnings.Add("A later LHM sample failed; the captured series is incomplete.") | Out-Null
        break
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
    -Transport $activeTransport `
    -Warnings @($warnings)
$json = $snapshot | ConvertTo-Json -Depth 20
$writtenPath = Write-LocalOutputFile -Path $resolvedOutput -Content ($json + "`r`n")
Write-Output $writtenPath
