[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CaseScriptPath,

    [Parameter(Mandatory = $true)]
    [string]$ReportScriptPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$resolvedCaseScript = (Resolve-Path -LiteralPath $CaseScriptPath).Path
$resolvedReportScript = (Resolve-Path -LiteralPath $ReportScriptPath).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-report-$([guid]::NewGuid().ToString('N'))"

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
    $caseDirectory = Join-Path $tempRoot "case"
    $caseFile = & $resolvedCaseScript -Action New `
        -CasePath $caseDirectory `
        -DeviceAlias "Test <script>alert('device')</script>" `
        -Platform "Windows fixture" `
        -Goal "Verify <b>offline report</b> escaping" `
        -IdentityQuality "user-reported"

    $importedEvidence = Join-Path $tempRoot "telemetry.csv"
    [IO.File]::WriteAllText(
        $importedEvidence,
        "Time,FPS`r`n0,60`r`n1,<script>alert('artifact')</script>`r`n",
        $utf8
    )
    $importedHash = (Get-FileHash -LiteralPath $importedEvidence -Algorithm SHA256).Hash
    $importedId = & $resolvedCaseScript -Action AddEvidence `
        -CasePath $caseFile `
        -EvidenceType telemetry `
        -EvidencePath $importedEvidence `
        -EvidenceCapturedAt "2026-11-03T14:00:00+08:00" `
        -Summary "Telemetry <script>alert('summary')</script>" `
        -ImportArtifact

    $externalEvidence = Join-Path $tempRoot "private-source-name.txt"
    [IO.File]::WriteAllText($externalEvidence, "external evidence", $utf8)
    $externalId = & $resolvedCaseScript -Action AddEvidence `
        -CasePath $caseFile `
        -EvidenceType log `
        -EvidencePath $externalEvidence `
        -EvidenceCapturedAt "2026-11-03T14:01:00+08:00" `
        -Summary "External evidence reference"

    $safeSvg = Join-Path $tempRoot "safe-chart.svg"
    [IO.File]::WriteAllText(
        $safeSvg,
        '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="40"><rect width="120" height="40" fill="#123456"/><text x="10" y="25" fill="white">chart</text></svg>',
        $utf8
    )
    $safeSvgId = & $resolvedCaseScript -Action AddEvidence `
        -CasePath $caseFile `
        -EvidenceType screenshot `
        -EvidencePath $safeSvg `
        -EvidenceCapturedAt "2026-11-03T14:02:00+08:00" `
        -Summary "Safe SVG chart" `
        -ImportArtifact

    $unsafeSvg = Join-Path $tempRoot "unsafe-chart.svg"
    [IO.File]::WriteAllText(
        $unsafeSvg,
        '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script><rect width="10" height="10"/></svg>',
        $utf8
    )
    $unsafeSvgId = & $resolvedCaseScript -Action AddEvidence `
        -CasePath $caseFile `
        -EvidenceType screenshot `
        -EvidencePath $unsafeSvg `
        -EvidenceCapturedAt "2026-11-03T14:03:00+08:00" `
        -Summary "Unsafe SVG rejection fixture" `
        -ImportArtifact

    $hypothesisId = & $resolvedCaseScript -Action AddHypothesis `
        -CasePath $caseFile `
        -Hypothesis "Driver <em>regression</em>" `
        -NextTest "Repeat the fixed workload"
    & $resolvedCaseScript -Action UpdateHypothesis `
        -CasePath $caseFile `
        -HypothesisId $hypothesisId `
        -Status supported `
        -Supporting "Evidence $importedId" | Out-Null

    $baselineId = & $resolvedCaseScript -Action AddBaseline `
        -CasePath $caseFile `
        -BaselineStatus valid `
        -Workload "fixed workload" `
        -Conditions "AC power" `
        -EvidenceId $importedId `
        -Summary "Stable baseline"
    $noBaselineId = & $resolvedCaseScript -Action AddBaseline `
        -CasePath $caseFile `
        -BaselineStatus none `
        -Summary "No comparable baseline"
    & $resolvedCaseScript -Action AddTimeline `
        -CasePath $caseFile `
        -OccurredAt "2026-11-02T20:00:00+08:00" `
        -EventType driver `
        -Summary "Driver <system>updated</system>" | Out-Null
    & $resolvedCaseScript -Action AddExperiment `
        -CasePath $caseFile `
        -HypothesisId $hypothesisId `
        -Change "Rollback" `
        -Expected "No stutter" `
        -Result "pending" `
        -Decision "continue" | Out-Null
    & $resolvedCaseScript -Action SetNextAction `
        -CasePath $caseFile `
        -NextAction "Run <fixed> workload" | Out-Null

    $metadataReport = Join-Path $tempRoot "metadata-report.html"
    $metadataResult = Invoke-Process -ScriptPath $resolvedReportScript -Arguments @(
        "-CasePath", $caseFile,
        "-OutputPath", $metadataReport,
        "-CaseScriptPath", $resolvedCaseScript
    )
    Assert-True ($metadataResult.ExitCode -eq 0) "Metadata-only report export failed: $($metadataResult.Stderr)"
    Assert-True (Test-Path -LiteralPath $metadataReport -PathType Leaf) "Metadata-only report was not created."
    $metadataHtml = Get-Content -Raw -LiteralPath $metadataReport -Encoding UTF8
    Assert-True ($metadataHtml -match '<!doctype html>') "Report is not a complete HTML document."
    Assert-True ($metadataHtml -match 'Content-Security-Policy') "Report has no restrictive content-security policy."
    Assert-True ($metadataHtml -match 'Artifact content not embedded') "Default export did not mark artifact content as omitted."
    Assert-True (-not ($metadataHtml -match "alert\('artifact'\)")) "Default export embedded artifact content."

    $reportPath = Join-Path $tempRoot "case-report.html"
    $reportResult = Invoke-Process -ScriptPath $resolvedReportScript -Arguments @(
        "-CasePath", $caseFile,
        "-OutputPath", $reportPath,
        "-CaseScriptPath", $resolvedCaseScript,
        "-IncludeArtifacts"
    )
    Assert-True ($reportResult.ExitCode -eq 0) "Report export failed: $($reportResult.Stderr)"
    Assert-True (Test-Path -LiteralPath $reportPath -PathType Leaf) "Report was not created."
    $html = Get-Content -Raw -LiteralPath $reportPath -Encoding UTF8
    Assert-True ($html -match [regex]::Escape($case.caseId)) "Report does not contain the case ID."
    Assert-True ($html -match [regex]::Escape($importedId)) "Report does not contain imported evidence ID."
    Assert-True ($html -match [regex]::Escape($externalId)) "Report does not contain external evidence ID."
    Assert-True ($html -match [regex]::Escape($safeSvgId)) "Report does not contain safe SVG evidence ID."
    Assert-True ($html -match [regex]::Escape($unsafeSvgId)) "Report does not contain unsafe SVG evidence metadata."
    Assert-True ($html -match [regex]::Escape($importedHash)) "Report does not contain the imported evidence hash."
    Assert-True ($html.Contains("2026-11-03T14:00:00.0000000+08:00")) "Report did not preserve the invariant evidence timestamp."
    Assert-True ($html -match [regex]::Escape($baselineId)) "Report does not contain the valid baseline."
    Assert-True ($html -match [regex]::Escape($noBaselineId)) "Report does not contain the none baseline."
    Assert-True ($html -match [regex]::Escape($hypothesisId)) "Report does not contain the hypothesis."
    Assert-True ($html -match 'data:image/svg\+xml;base64,') "Safe SVG was not embedded as an image."
    Assert-True ($html -match 'SVG preview skipped') "Unsafe SVG was not rejected."
    Assert-True ($html -match '&lt;script&gt;') "Escaped script text is missing from the report."
    Assert-True (-not ($html -match '(?i)<script\b')) "Report contains an active script element."
    Assert-True (-not ($html -match '(?i)<link\b')) "Report contains an external stylesheet or link element."
    Assert-True (-not ($html -match '(?i)https?://')) "Report contains a remote URL."
    Assert-True ($html -match "default-src 'none'") "Report CSP does not block network access."
    Assert-True (-not ($html -match [regex]::Escape($externalEvidence))) "Report exposed the external evidence source path."
    Assert-True ($html -match [regex]::Escape("private-source-name.txt")) "Report omitted the external evidence filename."
    Assert-True (-not ($html -match "<b>offline report</b>")) "Report did not escape HTML from the case goal."

    $overwriteResult = Invoke-Process -ScriptPath $resolvedReportScript -Arguments @(
        "-CasePath", $caseFile,
        "-OutputPath", $reportPath,
        "-CaseScriptPath", $resolvedCaseScript
    )
    Assert-True ($overwriteResult.ExitCode -eq 2) "Report exporter overwrote an existing file."
    Assert-True ($overwriteResult.Stderr -match "already exists") "Overwrite rejection was not explained."

    $brokenCaseDirectory = Join-Path $tempRoot "broken-case"
    Copy-Item -LiteralPath $caseDirectory -Destination $brokenCaseDirectory -Recurse
    $brokenCaseFile = Join-Path $brokenCaseDirectory "case.json"
    $brokenCase = Get-Content -Raw -LiteralPath $brokenCaseFile -Encoding UTF8 | ConvertFrom-Json
    $missingArtifact = Join-Path $brokenCaseDirectory ([string]$brokenCase.evidence[0].ImportedPath)
    Remove-Item -LiteralPath $missingArtifact -Force
    $brokenResult = Invoke-Process -ScriptPath $resolvedReportScript -Arguments @(
        "-CasePath", $brokenCaseFile,
        "-OutputPath", (Join-Path $tempRoot "broken-report.html"),
        "-CaseScriptPath", $resolvedCaseScript
    )
    Assert-True ($brokenResult.ExitCode -eq 2) "Report exporter accepted a case with missing evidence."
    Assert-True ($brokenResult.Stderr -match "validation failed") "Broken-case report rejection was not explained: $($brokenResult.Stderr)"

    if ($failures.Count -gt 0) {
        Write-Host "Hardware case report regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Hardware case report regression: PASS" -ForegroundColor Green
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
