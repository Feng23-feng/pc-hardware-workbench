[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CliPath,

    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$resolvedSkillRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$resolvedCli = (Resolve-Path -LiteralPath $CliPath).Path
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "pcwb cli " + [guid]::NewGuid().ToString("N")
)
$expectedTopLevel = @(
    "SchemaVersion",
    "Tool",
    "ToolVersion",
    "Command",
    "Status",
    "GeneratedAt",
    "DurationMilliseconds",
    "ExitCode",
    "Inputs",
    "Evidence",
    "Findings",
    "Uncertainties",
    "NextActions",
    "Artifacts",
    "Warnings",
    "Errors",
    "Limits"
)

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function ConvertTo-ProcessArgument {
    param([string]$Value)

    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-CapturedCli {
    param(
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $fullArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $resolvedCli
    ) + $Arguments
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = ($fullArguments | ForEach-Object {
        ConvertTo-ProcessArgument $_
    }) -join " "
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start pcwb.ps1."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function ConvertFrom-Envelope {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Capture,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    try {
        $json = $Capture.Stdout | ConvertFrom-Json
    }
    catch {
        $failures.Add("$Label did not return valid JSON: $($_.Exception.Message)")
        return $null
    }
    $actualTopLevel = @($json.PSObject.Properties.Name)
    Assert-True (
        ($actualTopLevel -join "|") -eq ($expectedTopLevel -join "|")
    ) "$Label top-level envelope keys or order changed."
    Assert-True (
        $json.SchemaVersion -eq "1.0" -and
        $json.Tool -eq "pcwb" -and
        $json.ToolVersion -eq "1.0.0"
    ) "$Label envelope identity is invalid."
    Assert-True (
        $json.ExitCode -eq $Capture.ExitCode
    ) "$Label process exit code and envelope ExitCode disagree."
    foreach ($field in @(
        "Inputs", "Evidence", "Findings", "Uncertainties", "NextActions",
        "Artifacts", "Warnings", "Errors", "Limits"
    )) {
        Assert-True (
            $null -ne $json.PSObject.Properties[$field] -and
            $json.$field -is [System.Array]
        ) "$Label field $field must be a JSON array."
    }
    return $json
}

function Test-NoUtf8Bom {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    return -not (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    )
}

function Assert-ArtifactHashes {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Envelope,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    foreach ($artifact in @($Envelope.Artifacts)) {
        Assert-True (
            Test-Path -LiteralPath $artifact.Path -PathType Leaf
        ) "$Label artifact is missing: $($artifact.Path)"
        if (Test-Path -LiteralPath $artifact.Path -PathType Leaf) {
            $actualHash = (Get-FileHash -LiteralPath $artifact.Path -Algorithm SHA256).Hash.ToLowerInvariant()
            Assert-True (
                $actualHash -eq $artifact.Sha256
            ) "$Label artifact SHA-256 does not match: $($artifact.Name)"
            Assert-True (
                (Get-Item -LiteralPath $artifact.Path).Length -eq $artifact.Bytes
            ) "$Label artifact byte count does not match: $($artifact.Name)"
            if ($artifact.MediaType -eq "application/json") {
                Assert-True (
                    Test-NoUtf8Bom -Path $artifact.Path
                ) "$Label JSON artifact contains a UTF-8 BOM: $($artifact.Name)"
            }
        }
    }
}

function New-TelemetryFixture {
    param([string]$Path)

    $degree = [char]0x00B0
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Date,Time,CPU Package Power [W],GPU Temperature [$degree" + "C]")
    $start = [datetime]::ParseExact(
        "2026-11-22 12:00:00.000",
        "yyyy-MM-dd HH:mm:ss.fff",
        [Globalization.CultureInfo]::InvariantCulture
    )
    for ($index = 0; $index -lt 24; $index++) {
        $timestamp = $start.AddSeconds($index)
        $lines.Add(
            $timestamp.ToString("yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture) + "," +
            $timestamp.ToString("HH:mm:ss.fff", [Globalization.CultureInfo]::InvariantCulture) + "," +
            (100 + $index) + "," +
            (50 + ($index % 5))
        )
    }
    [IO.File]::WriteAllText(
        $Path,
        ($lines -join "`r`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function New-PresentMonFixture {
    param([string]$Path)

    $lines = @(
        "Application,ProcessID,PresentMode,SyncInterval,TimeInSeconds,msBetweenPresents,msUntilDisplayed,Dropped",
        "game.exe,1234,Hardware: Independent Flip,1,0.000,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.010,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.020,10.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.030,100.0,15.0,false",
        "game.exe,1234,Hardware: Independent Flip,1,0.130,10.0,15.0,false"
    )
    [IO.File]::WriteAllText(
        $Path,
        ($lines -join "`r`n"),
        (New-Object System.Text.UTF8Encoding($false))
    )
}

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

    $missingCommand = Invoke-CapturedCli -Arguments @() -WorkingDirectory $testRoot
    Assert-True ($missingCommand.ExitCode -eq 2) "Missing command should exit 2."
    $missingEnvelope = ConvertFrom-Envelope -Capture $missingCommand -Label "missing-command"
    Assert-True (
        $missingEnvelope.Status -eq "needs-input" -and
        @($missingEnvelope.Errors | Where-Object { $_.Code -eq "pcwb.command.required" }).Count -eq 1
    ) "Missing command did not return a structured needs-input result."

    $doctorCapture = Invoke-CapturedCli -Arguments @("doctor") -WorkingDirectory $testRoot
    $doctor = ConvertFrom-Envelope -Capture $doctorCapture -Label "doctor"
    Assert-True ($doctorCapture.ExitCode -in @(0, 3)) "Doctor returned an unexpected exit code."
    Assert-True ($doctor.Status -in @("ok", "partial", "blocked")) "Doctor returned an invalid status."
    Assert-True (@($doctor.Evidence).Count -eq 1) "Doctor evidence is missing."
    Assert-True (@($doctor.Artifacts).Count -eq 1) "Doctor artifact is missing."
    Assert-ArtifactHashes -Envelope $doctor -Label "doctor"

    $inventoryCapture = Invoke-CapturedCli `
        -Arguments @(
            "inventory",
            "-PrivacyMode", "Redacted",
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $inventory = ConvertFrom-Envelope -Capture $inventoryCapture -Label "inventory"
    Assert-True ($inventoryCapture.ExitCode -eq 0) "Inventory wrapper should succeed."
    Assert-True (
        $inventory.Evidence[0].Kind -eq "hardware-inventory"
    ) "Inventory evidence kind is wrong."
    Assert-True (
        $inventory.Evidence[0].PrivacyMode -eq "Redacted identifiers"
    ) "Inventory privacy mode was not preserved."
    Assert-ArtifactHashes -Envelope $inventory -Label "inventory"

    $filteredInventoryCapture = Invoke-CapturedCli `
        -Arguments @(
            "inventory",
            "-PrivacyMode", "Redacted",
            "-Sections", "CPU",
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $filteredInventory = ConvertFrom-Envelope -Capture $filteredInventoryCapture -Label "filtered-inventory"
    Assert-True ($filteredInventoryCapture.ExitCode -eq 0) "Filtered inventory wrapper should succeed."
    $filteredEvidence = $filteredInventory.Evidence[0]
    Assert-True ($filteredEvidence.CollectionScope.FullInventory -eq $false) "Filtered inventory was reported as a full run."
    Assert-True (@($filteredEvidence.CollectionScope.SelectedSections) -contains "CPU") "Filtered inventory omitted its selected CPU scope."
    Assert-True ($null -ne $filteredEvidence.PSObject.Properties["CPU"]) "Filtered inventory omitted CPU evidence."
    foreach ($excludedProperty in @("Computer", "OperatingSystem", "GPU", "MemoryModules", "PhysicalDisks", "Monitors", "Battery")) {
        Assert-True ($null -eq $filteredEvidence.PSObject.Properties[$excludedProperty]) "Filtered inventory leaked excluded evidence: $excludedProperty."
    }
    foreach ($excludedStatus in @("MemoryModules", "PhysicalDisks", "Battery", "Monitors")) {
        Assert-True ($null -eq $filteredEvidence.CollectionStatus.PSObject.Properties[$excludedStatus]) "Filtered inventory leaked excluded collection status: $excludedStatus."
    }
    Assert-True (
        @($filteredInventory.NextActions | Where-Object { $_.Code -eq "confirm-device-identity" }).Count -eq 0
    ) "CPU-only inventory incorrectly requested system identity confirmation."
    Assert-ArtifactHashes -Envelope $filteredInventory -Label "filtered-inventory"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isElevated = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    if (-not $isElevated) {
        $permissionCapture = Invoke-CapturedCli `
            -Arguments @(
                "inventory",
                "-RequireElevated",
                "-OutputDirectory", $testRoot
            ) `
            -WorkingDirectory $testRoot
        $permission = ConvertFrom-Envelope -Capture $permissionCapture -Label "permission"
        Assert-True ($permissionCapture.ExitCode -eq 6) "Elevation-only collection should exit 6."
        Assert-True ($permission.Status -eq "blocked") "Elevation-only collection should be blocked."
        Assert-True (
            @($permission.Errors | Where-Object { $_.Code -eq "pcwb.child.permission-required" }).Count -eq 1
        ) "Permission failure was not classified as blocked."
    }

    $telemetryPath = Join-Path $testRoot "my telemetry.csv"
    New-TelemetryFixture -Path $telemetryPath
    $telemetryCapture = Invoke-CapturedCli `
        -Arguments @(
            "analyze", "telemetry",
            "-Path", $telemetryPath,
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $telemetry = ConvertFrom-Envelope -Capture $telemetryCapture -Label "telemetry"
    Assert-True ($telemetryCapture.ExitCode -eq 0) "Telemetry wrapper should succeed."
    Assert-True ($telemetry.Status -in @("ok", "partial")) "Telemetry returned an invalid status."
    Assert-True (@($telemetry.Inputs).Count -eq 1) "Telemetry input record is missing."
    Assert-True (
        $telemetry.Inputs[0].Sha256 -eq
        (Get-FileHash -LiteralPath $telemetryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    ) "Telemetry input SHA-256 is wrong."
    Assert-True (@($telemetry.Evidence).Count -eq 1) "Telemetry evidence is missing."
    Assert-True (@($telemetry.Evidence[0].Metrics).Count -ge 2) "Telemetry metrics are missing."
    $gpuMetric = @($telemetry.Evidence[0].Metrics | Where-Object { $_.Metric -like "GPU temperature*" })
    Assert-True ($gpuMetric.Count -eq 1) "GPU temperature metric is missing."
    if ($gpuMetric.Count -eq 1) {
        Assert-True (
            $gpuMetric[0].SourceColumn.Contains(([char]0x00B0).ToString() + "C")
        ) "Telemetry source column lost its degree symbol during UTF-8 transfer."
    }
    Assert-ArtifactHashes -Envelope $telemetry -Label "telemetry"

    $directAnalyzer = Join-Path $resolvedSkillRoot "scripts/analyze-telemetry.ps1"
    $directInfo = New-Object System.Diagnostics.ProcessStartInfo
    $directInfo.FileName = $powershell
    $directArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $directAnalyzer,
        "-Path",
        $telemetryPath,
        "-Format",
        "Json"
    ) | ForEach-Object { ConvertTo-ProcessArgument $_ }
    $directInfo.Arguments = $directArguments -join " "
    $directInfo.WorkingDirectory = $testRoot
    $directInfo.UseShellExecute = $false
    $directInfo.CreateNoWindow = $true
    $directInfo.RedirectStandardOutput = $true
    $directInfo.RedirectStandardError = $true
    $directProcess = [System.Diagnostics.Process]::Start($directInfo)
    $directStdout = $directProcess.StandardOutput.ReadToEnd()
    $directStderr = $directProcess.StandardError.ReadToEnd()
    $directProcess.WaitForExit()
    Assert-True (
        $directProcess.ExitCode -eq 0
    ) "The existing telemetry analyzer no longer runs independently: $directStderr"
    $directProcess.Dispose()

    $presentMonPath = Join-Path $testRoot "capture.csv"
    New-PresentMonFixture -Path $presentMonPath
    $presentMonCapture = Invoke-CapturedCli `
        -Arguments @(
            "analyze", "presentmon",
            "-InputPath", $presentMonPath,
            "-ProcessName", "game.exe",
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $presentMon = ConvertFrom-Envelope -Capture $presentMonCapture -Label "presentmon"
    Assert-True ($presentMonCapture.ExitCode -eq 0) "PresentMon wrapper should succeed."
    Assert-True (
        $presentMon.Evidence[0].Source.validFrameCount -eq 5
    ) "PresentMon valid frame count is wrong."
    Assert-True (
        $presentMon.Evidence[0].Analysis.averageFrameTimeMs -eq 28
    ) "PresentMon average frame time is wrong."
    Assert-ArtifactHashes -Envelope $presentMon -Label "presentmon"

    $evidenceCapture = Invoke-CapturedCli `
        -Arguments @(
            "evidence", "package",
            "-BaselinePath", $telemetryPath,
            "-Workload", "fixed smoke workload",
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $evidence = ConvertFrom-Envelope -Capture $evidenceCapture -Label "evidence-package"
    Assert-True ($evidenceCapture.ExitCode -eq 0) "Evidence package wrapper should succeed."
    Assert-True (
        $evidence.Evidence[0].Status -eq "baseline-ready"
    ) "Evidence package status is wrong."
    Assert-True (
        @($evidence.Artifacts).Count -ge 5
    ) "Evidence package did not expose all expected artifacts."
    Assert-ArtifactHashes -Envelope $evidence -Label "evidence-package"

    $claimEvidencePath = Join-Path $testRoot "claim-evidence.json"
    $claimPath = Join-Path $testRoot "claims.json"
    [ordered]@{
        GPU = @(@{
            Name = "Synthetic GPU"
            NvidiaEffectivePowerLimitW = 480
        })
    } | ConvertTo-Json -Depth 6 | ForEach-Object {
        [IO.File]::WriteAllText(
            $claimEvidencePath,
            $_,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    [ordered]@{
        schemaVersion = 1
        claims = @(@{
            id = "power-limit"
            path = "GPU.0.NvidiaEffectivePowerLimitW"
            expected = 450
            sourceType = "user-confirmed-current"
        })
    } | ConvertTo-Json -Depth 8 | ForEach-Object {
        [IO.File]::WriteAllText(
            $claimPath,
            $_,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    $claimCapture = Invoke-CapturedCli `
        -Arguments @(
            "verify", "claim",
            "-ClaimPath", $claimPath,
            "-EvidencePath", $claimEvidencePath,
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $claim = ConvertFrom-Envelope -Capture $claimCapture -Label "claim"
    Assert-True ($claimCapture.ExitCode -eq 4) "Conflicting claim should exit 4."
    Assert-True ($claim.Status -eq "partial") "Conflicting claim should be partial."
    Assert-True ($claim.Evidence[0].ConflictCount -eq 1) "Claim conflict count is wrong."
    Assert-True (@($claim.Findings).Count -eq 1) "Claim conflict finding is missing."
    Assert-ArtifactHashes -Envelope $claim -Label "claim"

    $missingCapture = Invoke-CapturedCli `
        -Arguments @(
            "analyze", "telemetry",
            "-Path", (Join-Path $testRoot "missing.csv"),
            "-OutputDirectory", $testRoot
        ) `
        -WorkingDirectory $testRoot
    $missing = ConvertFrom-Envelope -Capture $missingCapture -Label "missing-input"
    Assert-True ($missingCapture.ExitCode -eq 2) "Missing telemetry should exit 2."
    Assert-True ($missing.Status -eq "needs-input") "Missing telemetry should be needs-input."
    Assert-True (@($missing.Errors).Count -eq 1) "Missing telemetry error is not concise."
    Assert-True (
        @($missing.Artifacts).Count -eq 0
    ) "Missing telemetry must not publish a fake artifact."
    Assert-True (
        $missing.Errors[0].Message.Length -le 2200
    ) "Missing telemetry leaked an unbounded child diagnostic."

    $invalidOutputCapture = Invoke-CapturedCli `
        -Arguments @(
            "analyze", "telemetry",
            "-Path", $telemetryPath,
            "-OutputDirectory", "\\server\share"
        ) `
        -WorkingDirectory $testRoot
    $invalidOutput = ConvertFrom-Envelope -Capture $invalidOutputCapture -Label "invalid-output"
    Assert-True ($invalidOutputCapture.ExitCode -eq 2) "Unsafe output path should exit 2."
    Assert-True ($invalidOutput.Status -eq "needs-input") "Unsafe output path should be needs-input."
    Assert-True (
        @($invalidOutput.Errors | Where-Object { $_.Code -eq "pcwb.output-directory.invalid" }).Count -eq 1
    ) "Unsafe output path was not classified as an input error."
    Assert-True (@($invalidOutput.Artifacts).Count -eq 0) "Unsafe output path must not publish artifacts."

    $newScripts = @(
        (Join-Path $resolvedSkillRoot "scripts/pcwb.ps1"),
        (Join-Path $resolvedSkillRoot "scripts/pcwb-evidence.ps1"),
        (Join-Path $resolvedSkillRoot "scripts/pcwb-child-runner.ps1")
    )
    $dangerousPattern = '(?i)\b(Start-Process|runas|Register-ScheduledTask|Set-CimInstance|Set-ItemProperty|bcdedit|msi_afterburner|nvflash|Invoke-Expression)\b'
    foreach ($scriptPath in $newScripts) {
        $text = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
        Assert-True (
            $text -notmatch $dangerousPattern
        ) "PCWB CLI contains a forbidden elevation or mutation route: $scriptPath"
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    Write-Host "PCWB CLI tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}
Write-Host "PCWB CLI tests: PASS"
