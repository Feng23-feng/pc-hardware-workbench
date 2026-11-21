[CmdletBinding()]
param(
    [switch]$UpgradeExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$bundleRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\")
$evidenceRoot = Join-Path $bundleRoot "evidence"
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null

$startedAt = [DateTimeOffset]::Now
$runId = [guid]::NewGuid().ToString("N")
$runName = "acceptance-start-$($startedAt.ToString('yyyyMMdd-HHmmss'))-$($runId.Substring(0, 8))"
$runRoot = Join-Path $evidenceRoot $runName
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
$logPath = Join-Path $runRoot "acceptance-start.log"
$resultPath = Join-Path $runRoot "acceptance-start-result.json"
$latestResultPath = Join-Path $evidenceRoot "acceptance-start-result.json"
$acceptanceMode = if ($UpgradeExisting) {
    "upgrade-existing"
}
else {
    "clean-acceptance"
}

function Append-Log {
    param([AllowEmptyString()][string]$Text)

    [IO.File]::AppendAllText($logPath, $Text, $utf8)
}

function Write-Stage {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Color = "Cyan"
    )

    $line = "[$([DateTimeOffset]::Now.ToString('HH:mm:ss'))] $Message"
    Write-Host $line -ForegroundColor $Color
    Append-Log ($line + "`n")
}

function Write-Result {
    param(
        [string]$Status,
        [string]$FailedStage,
        [int]$FailedExitCode,
        [string]$ErrorMessage,
        [object[]]$Stages
    )

    $finishedAt = [DateTimeOffset]::Now
    $result = [ordered]@{
        schema_version = "1.0"
        status = $Status
        mode = $acceptanceMode
        started_at = $startedAt.ToString("o")
        finished_at = $finishedAt.ToString("o")
        failed_stage = $FailedStage
        failed_exit_code = $FailedExitCode
        error = $ErrorMessage
        log_path = $logPath
        stages = @($Stages)
    }
    $json = $result | ConvertTo-Json -Depth 8
    $json = $json.Replace("`r`n", "`n") + "`n"
    [IO.File]::WriteAllText($resultPath, $json, $utf8)
    [IO.File]::WriteAllText($latestResultPath, $json, $utf8)
}

$stages = @(
    [pscustomobject]@{
        order = 1
        name = "Validate bundle"
        script = "99-Validate-Bundle.ps1"
        arguments = @()
    },
    [pscustomobject]@{
        order = 2
        name = "Preflight"
        script = "00-Preflight.ps1"
        arguments = @()
    },
    [pscustomobject]@{
        order = 3
        name = "Install"
        script = "01-Install.ps1"
        arguments = @()
    }
)
if ($UpgradeExisting) {
    $stages[1].arguments = @("-AllowExistingInstall")
    $stages[2].arguments = @("-UpgradeExisting")
}
$stageResults = New-Object System.Collections.Generic.List[object]

try {
    Write-Stage "SkillDock acceptance startup"
    Write-Stage "Bundle: $bundleRoot"
    Write-Stage "Log: $logPath"

    foreach ($stage in $stages) {
        $scriptPath = Join-Path $bundleRoot $stage.script
        $stageResult = [ordered]@{
            order = $stage.order
            name = $stage.name
            script = $stage.script
            arguments = @($stage.arguments)
            status = "running"
            exit_code = $null
            started_at = [DateTimeOffset]::Now.ToString("o")
            finished_at = $null
            stdout_path = $null
            stderr_path = $null
            error = ""
        }
        $stageResults.Add($stageResult) | Out-Null
        Write-Stage ("Stage {0}/{1}: {2}" -f $stage.order, $stages.Count, $stage.name)

        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            $stageResult.status = "failed"
            $stageResult.exit_code = 1
            $stageResult.error = "Stage script is missing: $scriptPath"
            $stageResult.finished_at = [DateTimeOffset]::Now.ToString("o")
            Write-Stage $stageResult.error "Red"
            Write-Result `
                -Status "failed" `
                -FailedStage $stage.name `
                -FailedExitCode 1 `
                -ErrorMessage $stageResult.error `
                -Stages $stageResults.ToArray()
            Write-Host "Acceptance startup: FAIL" -ForegroundColor Red
            Write-Host "Result: $resultPath" -ForegroundColor Yellow
            Write-Host "Log:    $logPath" -ForegroundColor Yellow
            exit 1
        }

        $stdoutPath = Join-Path $runRoot ("{0:D2}-{1}.stdout.log" -f $stage.order, ($stage.name -replace '[^A-Za-z0-9-]+', '-'))
        $stderrPath = Join-Path $runRoot ("{0:D2}-{1}.stderr.log" -f $stage.order, ($stage.name -replace '[^A-Za-z0-9-]+', '-'))
        $stageResult.stdout_path = $stdoutPath
        $stageResult.stderr_path = $stderrPath
        $arguments = (
            "-NoProfile -ExecutionPolicy Bypass -File `"" +
            $scriptPath +
            "`""
        )
        if ($stage.arguments.Count -gt 0) {
            $arguments += " " + ($stage.arguments -join " ")
        }

        try {
            $process = Start-Process `
                -FilePath "powershell.exe" `
                -ArgumentList $arguments `
                -WorkingDirectory $bundleRoot `
                -WindowStyle Hidden `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -Wait `
                -PassThru `
                -ErrorAction Stop
            $exitCode = [int]$process.ExitCode
            $stdout = if (Test-Path -LiteralPath $stdoutPath) {
                Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
            }
            else {
                ""
            }
            $stderr = if (Test-Path -LiteralPath $stderrPath) {
                Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
            }
            else {
                ""
            }
            if (-not [string]::IsNullOrEmpty($stdout)) {
                Append-Log ("`n--- stdout ---`n" + $stdout.TrimEnd() + "`n")
                Write-Host $stdout.TrimEnd()
            }
            if (-not [string]::IsNullOrEmpty($stderr)) {
                Append-Log ("`n--- stderr ---`n" + $stderr.TrimEnd() + "`n")
                Write-Host $stderr.TrimEnd() -ForegroundColor Yellow
            }
            $stageResult.exit_code = $exitCode
            $stageResult.finished_at = [DateTimeOffset]::Now.ToString("o")
            if ($exitCode -ne 0) {
                $stageResult.status = "failed"
                $stageResult.error = "Stage exited with code $exitCode."
                Write-Stage $stageResult.error "Red"
                Write-Result `
                    -Status "failed" `
                    -FailedStage $stage.name `
                    -FailedExitCode $exitCode `
                    -ErrorMessage $stageResult.error `
                    -Stages $stageResults.ToArray()
                Write-Host "Acceptance startup: FAIL" -ForegroundColor Red
                Write-Host "Failed stage: $($stage.name)" -ForegroundColor Yellow
                Write-Host "Result: $resultPath" -ForegroundColor Yellow
                Write-Host "Log:    $logPath" -ForegroundColor Yellow
                exit $exitCode
            }
            $stageResult.status = "passed"
            Write-Stage ("Stage {0}/{1}: {2} PASS" -f $stage.order, $stages.Count, $stage.name) "Green"
        }
        catch {
            $stageResult.status = "failed"
            $stageResult.exit_code = 1
            $stageResult.error = [string]$_.Exception.Message
            $stageResult.finished_at = [DateTimeOffset]::Now.ToString("o")
            Write-Stage $stageResult.error "Red"
            Write-Result `
                -Status "failed" `
                -FailedStage $stage.name `
                -FailedExitCode 1 `
                -ErrorMessage $stageResult.error `
                -Stages $stageResults.ToArray()
            Write-Host "Acceptance startup: FAIL" -ForegroundColor Red
            Write-Host "Failed stage: $($stage.name)" -ForegroundColor Yellow
            Write-Host "Result: $resultPath" -ForegroundColor Yellow
            Write-Host "Log:    $logPath" -ForegroundColor Yellow
            exit 1
        }
    }

    Write-Result `
        -Status "passed" `
        -FailedStage "" `
        -FailedExitCode 0 `
        -ErrorMessage "" `
        -Stages $stageResults.ToArray()
    Write-Stage "Acceptance startup: PASS" "Green"
    Write-Host "Result: $resultPath" -ForegroundColor Green
    Write-Host "Log:    $logPath" -ForegroundColor Green
    exit 0
}
catch {
    $message = [string]$_.Exception.Message
    Write-Stage $message "Red"
    Write-Result `
        -Status "failed" `
        -FailedStage "startup-controller" `
        -FailedExitCode 1 `
        -ErrorMessage $message `
        -Stages $stageResults.ToArray()
    Write-Host "Acceptance startup: FAIL" -ForegroundColor Red
    Write-Host "Result: $resultPath" -ForegroundColor Yellow
    Write-Host "Log:    $logPath" -ForegroundColor Yellow
    exit 1
}
