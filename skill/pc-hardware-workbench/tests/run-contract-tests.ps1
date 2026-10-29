[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$collector = Join-Path $resolvedRoot "scripts\collect-windows.ps1"
$analyzer = Join-Path $resolvedRoot "scripts\analyze-telemetry.ps1"
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("pcwb-contract-" + [guid]::NewGuid().ToString("N"))

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

function Invoke-CapturedProcess {
    param([string[]]$Arguments)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = ($Arguments | ForEach-Object { Quote-Argument $_ }) -join " "
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

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $collectorText = Get-Content -Raw -LiteralPath $collector
    $expectedWarningCodes = @(
        "native-probe-load-failed",
        "cim-class-unavailable",
        "registry-fallback-unavailable",
        "processor-topology-fallback-failed",
        "memory-status-fallback-failed",
        "smbios-memory-empty",
        "smbios-memory-failed",
        "setupapi-disk-empty",
        "setupapi-disk-failed",
        "disk-descriptor-failed",
        "volume-disk-mapping-failed",
        "battery-capacity-unavailable",
        "battery-status-fallback-failed",
        "display-fallback-empty",
        "display-fallback-failed",
        "nvidia-smi-telemetry-failed",
        "nvidia-smi-identity-failed",
        "storage-health-unavailable",
        "storage-health-no-access",
        "volume-mapping-partial",
        "firmware-type-fallback-failed",
        "identity-quality-unconfirmed",
        "access-denied-restricted-agent",
        "access-denied-elevation-advice"
    )
    $sourceWarningCodes = @(
        [regex]::Matches($collectorText, '\-Code\s+"([a-z0-9]+(?:-[a-z0-9]+)*)"') |
            ForEach-Object { $_.Groups[1].Value } |
            Sort-Object -Unique
    )
    foreach ($expectedCode in $expectedWarningCodes) {
        Assert-True ($sourceWarningCodes -contains $expectedCode) "Collector source is missing warning code '$expectedCode'."
    }

    $snapshotPath = Join-Path $tempRoot "contract-snapshot.json"
    $capture = Invoke-CapturedProcess -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $collector,
        "-Format", "Json",
        "-OutputPath", $snapshotPath,
        "-RedactIdentifiers"
    )
    Assert-True ($capture.ExitCode -eq 0) "Successful collection returned exit code $($capture.ExitCode)."
    Assert-True (Test-Path -LiteralPath $snapshotPath -PathType Leaf) "Successful collection did not create the JSON file."
    Assert-True ([string]::IsNullOrWhiteSpace($capture.Stderr)) "Successful collection unexpectedly wrote stderr diagnostics."

    if (Test-Path -LiteralPath $snapshotPath -PathType Leaf) {
        $bytes = [IO.File]::ReadAllBytes($snapshotPath)
        Assert-True (
            $bytes.Length -lt 3 -or
            $bytes[0] -ne 0xEF -or
            $bytes[1] -ne 0xBB -or
            $bytes[2] -ne 0xBF
        ) "JSON output must not contain a UTF-8 BOM."

        $jsonText = [IO.File]::ReadAllText(
            $snapshotPath,
            (New-Object System.Text.UTF8Encoding($false, $true))
        )
        try {
            $snapshot = $jsonText | ConvertFrom-Json
        }
        catch {
            $failures.Add("JSON output could not be parsed: $($_.Exception.Message)")
            $snapshot = $null
        }

        if ($null -ne $snapshot) {
            $expectedTopLevel = @(
                "SchemaVersion", "CollectorVersion", "GeneratedAt", "PrivacyMode",
                "CollectionMode", "CollectionContext", "IdentityQuality", "Computer",
                "OperatingSystem", "Firmware", "Motherboard", "Battery", "CPU", "GPU",
                "MemoryModules", "PhysicalDisks", "Volumes", "Monitors",
                "CollectionStatus", "CollectionWarnings", "CollectionWarningCodes",
                "NotReliablyDetectable"
            )
            $actualTopLevel = @($snapshot.PSObject.Properties.Name)
            Assert-True (($actualTopLevel -join "|") -eq ($expectedTopLevel -join "|")) "Top-level JSON keys or their order changed."
            Assert-True ($snapshot.SchemaVersion -eq 3) "SchemaVersion must be 3 for this top-level contract."

            $expectedStatusKeys = @(
                "MemoryModules", "MemoryModulesSource",
                "PhysicalDisks", "PhysicalDisksSource", "PhysicalDisksScope",
                "Volumes", "VolumesScope", "VolumeDiskMapping", "VolumeDiskMappingSource",
                "Battery", "BatterySource", "BatteryStatusReason", "BatteryCimStatus",
                "Monitors", "MonitorsSource", "MonitorsScope"
            )
            $actualStatusKeys = @($snapshot.CollectionStatus.PSObject.Properties.Name)
            Assert-True (($actualStatusKeys -join "|") -eq ($expectedStatusKeys -join "|")) "CollectionStatus keys or their order changed."
            Assert-True ($actualStatusKeys.Count -eq 16) "CollectionStatus must contain exactly 16 keys."

            foreach ($property in $snapshot.CollectionStatus.PSObject.Properties) {
                Assert-True ($property.Value -ne "") "CollectionStatus.$($property.Name) is an empty string."
            }

            $allowedStatuses = @(
                "available", "partial", "unavailable",
                "unavailable in current environment",
                "unavailable-permission", "not-present"
            )
            $statusSourcePairs = @(
                @{ Status = "MemoryModules"; Source = "MemoryModulesSource"; Scope = $null },
                @{ Status = "PhysicalDisks"; Source = "PhysicalDisksSource"; Scope = "PhysicalDisksScope" },
                @{ Status = "Volumes"; Source = $null; Scope = "VolumesScope" },
                @{ Status = "VolumeDiskMapping"; Source = "VolumeDiskMappingSource"; Scope = $null },
                @{ Status = "Battery"; Source = "BatterySource"; Scope = $null },
                @{ Status = "BatteryCimStatus"; Source = $null; Scope = $null },
                @{ Status = "Monitors"; Source = "MonitorsSource"; Scope = "MonitorsScope" }
            )
            $unavailableStatuses = @(
                "unavailable", "unavailable in current environment", "unavailable-permission"
            )
            foreach ($pair in $statusSourcePairs) {
                $statusValue = [string]$snapshot.CollectionStatus.($pair.Status)
                Assert-True ($statusValue -in $allowedStatuses) "CollectionStatus.$($pair.Status) has unsupported value '$statusValue'."
                if ($pair.Source) {
                    $sourceValue = $snapshot.CollectionStatus.($pair.Source)
                    if ($statusValue -in @("available", "partial")) {
                        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$sourceValue)) "CollectionStatus.$($pair.Status) is '$statusValue' but its source is empty."
                    }
                    if ($statusValue -in $unavailableStatuses) {
                        Assert-True (
                            $null -eq $sourceValue -or
                            -not [string]::IsNullOrWhiteSpace([string]$sourceValue)
                        ) "CollectionStatus.$($pair.Status) has an empty source for an unavailable state."
                    }
                }
                if ($pair.Scope -and $statusValue -in $unavailableStatuses) {
                    Assert-True ($null -eq $snapshot.CollectionStatus.($pair.Scope)) "CollectionStatus.$($pair.Scope) must be null while the associated status is unavailable."
                }
            }

            $warningTexts = @($snapshot.CollectionWarnings)
            $warningCodes = @($snapshot.CollectionWarningCodes)
            Assert-True ($warningTexts.Count -eq $warningCodes.Count) "CollectionWarnings and CollectionWarningCodes have different lengths."
            $seenPairs = New-Object System.Collections.Generic.HashSet[string]
            for ($index = 0; $index -lt $warningCodes.Count; $index++) {
                Assert-True ([string]$warningCodes[$index] -match '^[a-z0-9]+(?:-[a-z0-9]+)*$') "Warning code at index $index is not kebab-case."
                $pairKey = [string]$warningCodes[$index] + [char]0 + [string]$warningTexts[$index]
                Assert-True ($seenPairs.Add($pairKey)) "Warning text/code pair is duplicated at index $index."
            }
        }
    }

    $stdoutLines = @($capture.Stdout -split "\r?\n" | Where-Object { $_ -ne "" })
    Assert-True ($stdoutLines.Count -eq 1) "OutputPath mode wrote more than one stdout line."
    Assert-True ($stdoutLines[0] -like "Hardware snapshot written to:*") "OutputPath status line is missing from stdout."
    Assert-True (-not $capture.Stdout.Contains("{")) "JSON leaked to stdout in OutputPath mode."

    $missingDrivePath = "\\server\share\contract.json"
    $invalidCapture = Invoke-CapturedProcess -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $collector,
        "-Format", "Json",
        "-OutputPath", $missingDrivePath,
        "-RedactIdentifiers"
    )
    Assert-True ($invalidCapture.ExitCode -eq 2) "Rejected output path did not return exit code 2."
    Assert-True ([string]::IsNullOrWhiteSpace($invalidCapture.Stdout)) "Rejected output path wrote to stdout."
    Assert-True (-not [string]::IsNullOrWhiteSpace($invalidCapture.Stderr)) "Rejected output path produced no stderr diagnostic."

    $missingCsv = Join-Path $tempRoot "missing.csv"
    $missingAnalyzerCapture = Invoke-CapturedProcess -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $analyzer,
        "-Path", $missingCsv,
        "-Format", "Json"
    )
    Assert-True ($missingAnalyzerCapture.ExitCode -eq 2) "Missing telemetry input did not return exit code 2."
    Assert-True ([string]::IsNullOrWhiteSpace($missingAnalyzerCapture.Stdout)) "Missing telemetry input wrote to stdout."

    $validCsv = Join-Path $tempRoot "valid.csv"
    [IO.File]::WriteAllText(
        $validCsv,
        "Date,Time,GPU Temperature [C],GPU Power [W]`r`n2026-10-27,00:00:00,60,100`r`n2026-10-27,00:00:01,61,101`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $validAnalyzerCapture = Invoke-CapturedProcess -Arguments @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $analyzer,
        "-Path", $validCsv,
        "-Format", "Json"
    )
    Assert-True ($validAnalyzerCapture.ExitCode -eq 0) "Valid telemetry input did not return exit code 0."
    try {
        $null = $validAnalyzerCapture.Stdout | ConvertFrom-Json
    }
    catch {
        $failures.Add("Valid telemetry output could not be parsed: $($_.Exception.Message)")
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Contract tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Contract tests: PASS" -ForegroundColor Green
