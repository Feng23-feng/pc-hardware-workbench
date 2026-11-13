[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DoctorPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$resolvedDoctor = (Resolve-Path -LiteralPath $DoctorPath).Path
$skillRoot = Split-Path -Parent (Split-Path -Parent $resolvedDoctor)
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $skillRoot)
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-doctor-$([guid]::NewGuid().ToString('N'))"

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

function Invoke-Doctor {
    param([string[]]$Arguments)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = (
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedDoctor) + $Arguments |
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
        throw "Doctor process timed out."
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.Result
        Stderr = $stderrTask.Result
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $validatorPath = Join-Path $repositoryRoot "tools\validate-skill.ps1"

    $jsonResult = Invoke-Doctor -Arguments @(
        "-SkillRoot", $skillRoot,
        "-Format", "Json",
        "-OutputDirectory", $tempRoot,
        "-ValidatorPath", $validatorPath
    )
    Assert-True ($jsonResult.ExitCode -eq 0) "Doctor JSON check failed: $($jsonResult.Stderr)"
    $report = $jsonResult.Stdout | ConvertFrom-Json
    Assert-True ($report.DoctorVersion -eq "1.0.0") "Doctor version is missing."
    Assert-True ($report.SkillVersion -eq "2.7.0") "Doctor read the wrong Skill version."
    Assert-True ($report.Overall -eq "AVAILABLE") "Doctor marked the installed Skill as broken."
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq "Core files" -and $_.Status -eq "AVAILABLE" }).Count -eq 1) "Doctor did not validate core files."
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq "PowerShell syntax" -and $_.Status -eq "AVAILABLE" }).Count -eq 1) "Doctor did not parse PowerShell scripts."
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq "PowerShell encoding" -and $_.Status -eq "AVAILABLE" }).Count -eq 1) "Doctor detected a script encoding failure."
    Assert-True (@($report.Checks | Where-Object { $_.Name -eq "Model vision" -and $_.Status -eq "UNKNOWN" }).Count -eq 1) "Doctor falsely claims to prove model vision."

    $textResult = Invoke-Doctor -Arguments @(
        "-SkillRoot", $skillRoot,
        "-Format", "Text",
        "-OutputDirectory", $tempRoot,
        "-ValidatorPath", $validatorPath
    )
    Assert-True ($textResult.ExitCode -eq 0) "Doctor text check failed."
    Assert-True ($textResult.Stdout -match "PC Hardware Workbench doctor") "Doctor text heading is missing."
    Assert-True ($textResult.Stdout -match "Overall: AVAILABLE") "Doctor text overall status is wrong."

    $lhmPermission = Invoke-Doctor -Arguments @(
        "-SkillRoot", $skillRoot,
        "-Format", "Json",
        "-OutputDirectory", $tempRoot,
        "-ValidatorPath", $validatorPath,
        "-ProbeLhm"
    )
    Assert-True ($lhmPermission.ExitCode -eq 0) "LHM probe without consent made the doctor fail."
    $lhmReport = $lhmPermission.Stdout | ConvertFrom-Json
    Assert-True (@($lhmReport.Checks | Where-Object { $_.Name -eq "LibreHardwareMonitor" -and $_.Status -eq "PERMISSION_REQUIRED" }).Count -eq 1) "LHM probe without consent was not marked permission-required."

    $emptySkillRoot = Join-Path $tempRoot "empty-skill"
    New-Item -ItemType Directory -Path $emptySkillRoot | Out-Null
    $brokenResult = Invoke-Doctor -Arguments @(
        "-SkillRoot", $emptySkillRoot,
        "-Format", "Json",
        "-OutputDirectory", $tempRoot
    )
    Assert-True ($brokenResult.ExitCode -eq 1) "Doctor accepted an empty Skill root."
    $brokenReport = $brokenResult.Stdout | ConvertFrom-Json
    Assert-True ($brokenReport.Overall -eq "BROKEN") "Empty Skill root was not marked broken."
    Assert-True (@($brokenReport.Checks | Where-Object { $_.Name -eq "SKILL.md" -and $_.Status -eq "BROKEN" }).Count -eq 1) "Missing SKILL.md was not reported."

    $badOutput = Join-Path $tempRoot "does-not-exist"
    $badOutputResult = Invoke-Doctor -Arguments @(
        "-SkillRoot", $skillRoot,
        "-Format", "Json",
        "-OutputDirectory", $badOutput
    )
    Assert-True ($badOutputResult.ExitCode -eq 1) "Doctor accepted a nonexistent output directory."
    $badOutputReport = $badOutputResult.Stdout | ConvertFrom-Json
    Assert-True (@($badOutputReport.Checks | Where-Object { $_.Name -eq "Output directory" -and $_.Status -eq "BROKEN" }).Count -eq 1) "Missing output directory was not reported."

    $doctorText = Get-Content -Raw -LiteralPath $resolvedDoctor -Encoding UTF8
    Assert-True ($doctorText -match '127\.0\.0\.1:8085/data\.json') "Doctor is missing the local LHM Web probe."
    Assert-True ($doctorText -match 'IsLoopback') "Doctor does not restrict the LHM Web probe to loopback."
    Assert-True ($doctorText -notmatch '(?i)Start-Process|Start-Service|runas|install-module') "Doctor can start, elevate, or install software."

    if ($failures.Count -gt 0) {
        Write-Host "Doctor regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Doctor regression: PASS" -ForegroundColor Green
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
