[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseScriptPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$resolvedScript = (Resolve-Path -LiteralPath $CaseScriptPath).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-case-$([guid]::NewGuid().ToString('N'))"

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

function Invoke-CaseProcess {
    param([string[]]$Arguments)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = (
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedScript) + $Arguments |
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

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $resolvedScript,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null
    Assert-True ($parseErrors.Count -eq 0) "Hardware case syntax errors: $($parseErrors -join '; ')"

    $caseDirectory = Join-Path $tempRoot "case"
    $caseFile = & $resolvedScript -Action New `
        -CasePath $caseDirectory `
        -DeviceAlias "test-device" `
        -Platform "test-platform" `
        -Goal "diagnose intermittent stutter" `
        -IdentityQuality "user-reported"
    Assert-True ($caseFile -eq (Join-Path $caseDirectory "case.json")) "New did not report the case.json path."
    Assert-True (Test-Path -LiteralPath $caseFile -PathType Leaf) "New did not create case.json."

    $caseBytes = [IO.File]::ReadAllBytes($caseFile)
    Assert-True (
        $caseBytes.Length -lt 3 -or
        $caseBytes[0] -ne 0xEF -or
        $caseBytes[1] -ne 0xBB -or
        $caseBytes[2] -ne 0xBF
    ) "case.json must not contain a UTF-8 BOM."

    $evidenceFile = Join-Path $tempRoot "sample telemetry.csv"
    [IO.File]::WriteAllText($evidenceFile, "Time,FPS`r`n0,60`r`n1,61`r`n", $utf8)
    $evidenceHash = (Get-FileHash -LiteralPath $evidenceFile -Algorithm SHA256).Hash
    $evidenceId = & $resolvedScript -Action AddEvidence `
        -CasePath $caseDirectory `
        -EvidenceType telemetry `
        -EvidencePath $evidenceFile `
        -EvidenceCapturedAt "2026-11-03T14:00:00+08:00" `
        -Summary "Baseline telemetry" `
        -ImportArtifact
    Assert-True ($evidenceId -eq "E-001") "Unexpected first evidence ID: $evidenceId"

    $hypothesisId = & $resolvedScript -Action AddHypothesis `
        -CasePath $caseDirectory `
        -Hypothesis "The new driver causes the stutter" `
        -NextTest "Compare the previous driver with the same workload"
    Assert-True ($hypothesisId -eq "H-001") "Unexpected first hypothesis ID: $hypothesisId"

    & $resolvedScript -Action UpdateHypothesis `
        -CasePath $caseDirectory `
        -HypothesisId $hypothesisId `
        -Status supported `
        -Supporting "Symptoms began after the update" | Out-Null
    & $resolvedScript -Action UpdateHypothesis `
        -CasePath $caseDirectory `
        -HypothesisId $hypothesisId `
        -NextTest "Rollback and repeat the fixed workload" | Out-Null

    $timelineId = & $resolvedScript -Action AddTimeline `
        -CasePath $caseDirectory `
        -OccurredAt "2026-11-02T20:00:00+08:00" `
        -EventType driver `
        -Summary "Graphics driver updated"
    Assert-True ($timelineId -eq "T-001") "Unexpected first timeline ID: $timelineId"

    $baselineId = & $resolvedScript -Action AddBaseline `
        -CasePath $caseDirectory `
        -BaselineStatus valid `
        -Workload "fixed game benchmark" `
        -Conditions "AC power; stock profile" `
        -EvidenceId $evidenceId `
        -Summary "Stable baseline summary"
    Assert-True ($baselineId -eq "B-001") "Unexpected first baseline ID: $baselineId"
    $noBaselineId = & $resolvedScript -Action AddBaseline `
        -CasePath $caseDirectory `
        -BaselineStatus none `
        -Summary "Mixed phases cannot establish a comparable baseline"
    Assert-True ($noBaselineId -eq "B-002") "Unexpected no-baseline record ID: $noBaselineId"

    $experimentId = & $resolvedScript -Action AddExperiment `
        -CasePath $caseDirectory `
        -HypothesisId $hypothesisId `
        -Change "Driver rollback" `
        -Expected "Stutter disappears" `
        -Result "pending" `
        -Decision "continue"
    Assert-True ($experimentId -eq "X-001") "Unexpected first experiment ID: $experimentId"

    & $resolvedScript -Action SetNextAction `
        -CasePath $caseDirectory `
        -NextAction "Repeat the fixed workload after rollback" | Out-Null

    $validation = Invoke-CaseProcess -Arguments @(
        "-Action", "Validate",
        "-CasePath", $caseDirectory
    )
    Assert-True ($validation.ExitCode -eq 0) "Valid case failed validation."
    Assert-True ($validation.Stdout -match "Hardware case is valid") "Valid case did not print a validation result."

    $case = & $resolvedScript -Action Show -CasePath $caseDirectory -AsJson | ConvertFrom-Json
    Assert-True (@($case.evidence).Count -eq 1) "Evidence was not persisted."
    Assert-True (@($case.hypotheses).Count -eq 1) "Hypothesis was not persisted."
    Assert-True (@($case.timeline).Count -eq 1) "Timeline event was not persisted."
    Assert-True (@($case.baselines).Count -eq 2) "Baseline records were not persisted."
    Assert-True (@($case.experiments).Count -eq 1) "Experiment was not persisted."
    Assert-True ($case.hypotheses[0].Status -eq "supported") "A later hypothesis update reset the existing status."
    Assert-True ($case.hypotheses[0].Supporting.Count -eq 1) "Supporting evidence was not appended."
    Assert-True ($case.evidence[0].Sha256 -eq $evidenceHash) "Imported evidence hash changed."
    Assert-True ($case.evidence[0].ImportedPath -match '^artifacts/.+sample_telemetry\.csv$') "Imported evidence path is not relative."
    Assert-True ($null -eq $case.evidence[0].SourcePath) "Imported evidence retained its private source path."
    Assert-True ($case.evidence[0].OriginalFileName -eq "sample telemetry.csv") "Imported evidence lost its original filename."
    Assert-True ($case.evidence[0].CapturedAt -eq "2026-11-03T14:00:00.0000000+08:00") "Evidence capture time was replaced by import time."
    Assert-True ($case.baselines[0].EvidenceId -eq $evidenceId) "Baseline did not retain its evidence ID."
    Assert-True ($case.baselines[0].Status -eq "valid") "Valid baseline status was not stored."
    Assert-True ($case.baselines[1].Status -eq "none") "No-baseline status was not stored."
    Assert-True ($case.nextAction -eq "Repeat the fixed workload after rollback") "Next action was not saved."

    $notEmptyDirectory = Join-Path $tempRoot "not-empty"
    New-Item -ItemType Directory -Path $notEmptyDirectory | Out-Null
    [IO.File]::WriteAllText((Join-Path $notEmptyDirectory "existing.txt"), "x", $utf8)
    $nonEmptyCapture = Invoke-CaseProcess -Arguments @(
        "-Action", "New",
        "-CasePath", $notEmptyDirectory,
        "-DeviceAlias", "x",
        "-Goal", "x"
    )
    Assert-True ($nonEmptyCapture.ExitCode -eq 2) "New reused a non-empty directory."
    Assert-True ($nonEmptyCapture.Stderr -match "not empty") "Non-empty directory rejection was not explained."

    $missingHypothesisCapture = Invoke-CaseProcess -Arguments @(
        "-Action", "UpdateHypothesis",
        "-CasePath", $caseDirectory,
        "-HypothesisId", "H-999",
        "-Status", "verified"
    )
    Assert-True ($missingHypothesisCapture.ExitCode -eq 2) "Missing hypothesis did not return exit code 2."
    Assert-True ($missingHypothesisCapture.Stderr -match "Hypothesis not found") "Missing hypothesis error is unclear."

    $badEvidenceCapture = Invoke-CaseProcess -Arguments @(
        "-Action", "AddBaseline",
        "-CasePath", $caseDirectory,
        "-Workload", "test",
        "-EvidenceId", "E-999"
    )
    Assert-True ($badEvidenceCapture.ExitCode -eq 2) "Baseline accepted a missing evidence ID."
    Assert-True ($badEvidenceCapture.Stderr -match "Evidence not found") "Missing baseline evidence error is unclear."

    $missingCaseDirectory = Join-Path $tempRoot "case-missing-evidence"
    Copy-Item -LiteralPath $caseDirectory -Destination $missingCaseDirectory -Recurse
    $missingCaseFile = Join-Path $missingCaseDirectory "case.json"
    $missingCase = Get-Content -Raw -LiteralPath $missingCaseFile -Encoding UTF8 | ConvertFrom-Json
    $missingArtifact = Join-Path $missingCaseDirectory ([string]$missingCase.evidence[0].ImportedPath)
    Remove-Item -LiteralPath $missingArtifact -Force
    $missingEvidenceValidation = Invoke-CaseProcess -Arguments @(
        "-Action", "Validate",
        "-CasePath", $missingCaseFile
    )
    Assert-True ($missingEvidenceValidation.ExitCode -ne 0) "Validate accepted a case with a missing evidence file."
    Assert-True ($missingEvidenceValidation.Stderr -match "file is missing") "Missing evidence validation was not explained."

    $hashCaseDirectory = Join-Path $tempRoot "case-bad-hash"
    Copy-Item -LiteralPath $caseDirectory -Destination $hashCaseDirectory -Recurse
    $hashCaseFile = Join-Path $hashCaseDirectory "case.json"
    $hashCase = Get-Content -Raw -LiteralPath $hashCaseFile -Encoding UTF8 | ConvertFrom-Json
    $hashArtifact = Join-Path $hashCaseDirectory ([string]$hashCase.evidence[0].ImportedPath)
    [IO.File]::AppendAllText($hashArtifact, "tampered", $utf8)
    $hashValidation = Invoke-CaseProcess -Arguments @(
        "-Action", "Validate",
        "-CasePath", $hashCaseFile
    )
    Assert-True ($hashValidation.ExitCode -ne 0) "Validate accepted a case with a mismatched evidence hash."
    Assert-True ($hashValidation.Stderr -match "SHA-256 does not match") "Hash mismatch validation was not explained."

    $statusCaseDirectory = Join-Path $tempRoot "case-bad-status"
    Copy-Item -LiteralPath $caseDirectory -Destination $statusCaseDirectory -Recurse
    $statusCaseFile = Join-Path $statusCaseDirectory "case.json"
    $statusCase = Get-Content -Raw -LiteralPath $statusCaseFile -Encoding UTF8 | ConvertFrom-Json
    $statusCase.baselines[0].Status = "invalid"
    [IO.File]::WriteAllText(
        $statusCaseFile,
        ($statusCase | ConvertTo-Json -Depth 20) + "`r`n",
        $utf8
    )
    $statusValidation = Invoke-CaseProcess -Arguments @(
        "-Action", "Validate",
        "-CasePath", $statusCaseFile
    )
    Assert-True ($statusValidation.ExitCode -ne 0) "Validate accepted an unknown baseline status."
    Assert-True ($statusValidation.Stderr -match "invalid status") "Unknown baseline status validation was not explained."

    if ($failures.Count -gt 0) {
        Write-Host "Hardware case regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Hardware case regression: PASS" -ForegroundColor Green
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
