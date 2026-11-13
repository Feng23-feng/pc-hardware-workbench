[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [string]$ScenarioPath,

    [string]$InputRoot,

    [string]$OutputRoot,

    [switch]$Live,

    [switch]$SelfTest,

    [string]$CodexExecutable,

    [string[]]$ScenarioIds,

    [string]$SkillSourcePath,

    [int]$Runs = 1,

    [int]$MaxCases = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path
if ([string]::IsNullOrWhiteSpace($ScenarioPath)) {
    $ScenarioPath = Join-Path $PSScriptRoot "behavior-evals\scenarios.json"
}
$ScenarioPath = (Resolve-Path -LiteralPath $ScenarioPath).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot "work\behavior-evals"
}
if ($Runs -lt 1 -or $Runs -gt 3) {
    throw "Runs must be between 1 and 3."
}
if ($MaxCases -lt 1) {
    throw "MaxCases must be positive."
}
if ($Live -and -not [string]::IsNullOrWhiteSpace($InputRoot)) {
    throw "Use either -Live or -InputRoot, not both."
}
if (-not [string]::IsNullOrWhiteSpace($SkillSourcePath)) {
    $SkillSourcePath = (Resolve-Path -LiteralPath $SkillSourcePath).Path
    if (-not (Test-Path -LiteralPath (Join-Path $SkillSourcePath "SKILL.md") -PathType Leaf)) {
        throw "SkillSourcePath does not contain SKILL.md: $SkillSourcePath"
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$scenarioData = Get-Content -Raw -LiteralPath $ScenarioPath -Encoding UTF8 | ConvertFrom-Json
$scenarios = @($scenarioData.scenarios)
if ($scenarios.Count -eq 0) {
    throw "No behavior-eval scenarios were found."
}
$seenIds = @{}
foreach ($scenario in $scenarios) {
    if ([string]::IsNullOrWhiteSpace([string]$scenario.id)) {
        throw "A behavior-eval scenario is missing an id."
    }
    if ($seenIds.ContainsKey([string]$scenario.id)) {
        throw "Duplicate behavior-eval scenario id: $($scenario.id)"
    }
    $seenIds[[string]$scenario.id] = $true
    if (@($scenario.checks).Count -eq 0) {
        throw "Scenario '$($scenario.id)' has no checks."
    }
}

function Invoke-TextCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)]$Check
    )
    $id = [string]$Check.id
    $type = [string]$Check.type
    $message = [string]$Check.message
    $severity = if ($Check.PSObject.Properties.Name -contains "severity") { [string]$Check.severity } else { "error" }
    $passed = $false
    $detail = ""

    switch ($type) {
        "required_any" {
            foreach ($pattern in @($Check.patterns)) {
                if ([regex]::IsMatch($Text, [string]$pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                    $passed = $true
                    $detail = "Matched: $pattern"
                    break
                }
            }
            if (-not $passed) {
                $detail = "None of the required patterns matched."
            }
        }
        "required_all" {
            $missing = New-Object System.Collections.Generic.List[string]
            foreach ($pattern in @($Check.patterns)) {
                if (-not [regex]::IsMatch($Text, [string]$pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                    $missing.Add([string]$pattern) | Out-Null
                }
            }
            $passed = $missing.Count -eq 0
            $detail = if ($passed) { "All required patterns matched." } else { "Missing: $($missing -join ', ')" }
        }
        "forbidden_any" {
            $matched = New-Object System.Collections.Generic.List[string]
            foreach ($pattern in @($Check.patterns)) {
                if ([regex]::IsMatch($Text, [string]$pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant)) {
                    $matched.Add([string]$pattern) | Out-Null
                }
            }
            $passed = $matched.Count -eq 0
            $detail = if ($passed) { "No forbidden pattern matched." } else { "Forbidden match: $($matched -join ', ')" }
        }
        "max_questions" {
            $limit = [int]$Check.limit
            $questionPattern = [regex]::Unescape('[\?\uFF1F]')
            $count = [regex]::Matches($Text, $questionPattern).Count
            $passed = $count -le $limit
            $detail = "Questions: $count; limit: $limit"
        }
        default {
            $detail = "Unsupported check type: $type"
        }
    }

    return [pscustomobject][ordered]@{
        id = $id
        type = $type
        severity = $severity
        passed = $passed
        message = $message
        detail = $detail
    }
}

function Measure-Response {
    param(
        [Parameter(Mandatory = $true)]$Scenario,
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$Run
    )
    $checks = @(
        foreach ($check in @($Scenario.checks)) {
            Invoke-TextCheck -Text $Text -Check $check
        }
    )
    $failed = @($checks | Where-Object { -not $_.passed -and $_.severity -ne "warning" })
    $warnings = @($checks | Where-Object { -not $_.passed -and $_.severity -eq "warning" })
    return [pscustomobject][ordered]@{
        scenario_id = [string]$Scenario.id
        title = [string]$Scenario.title
        run = $Run
        passed = ($failed.Count -eq 0)
        failed_check_ids = @($failed | ForEach-Object { $_.id })
        warning_check_ids = @($warnings | ForEach-Object { $_.id })
        checks = $checks
        response_path = $Path
        response_sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }
}

function Get-FixtureResult {
    param(
        [Parameter(Mandatory = $true)]$Scenario,
        [Parameter(Mandatory = $true)][ValidateSet("valid", "invalid")][string]$Kind
    )
    $path = Join-Path $PSScriptRoot ("behavior-evals\fixtures\{0}\{1}.md" -f $Kind, $Scenario.id)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing $Kind fixture for '$($Scenario.id)': $path"
    }
    $text = Get-Content -Raw -LiteralPath $path -Encoding UTF8
    return Measure-Response -Scenario $Scenario -Text $text -Path $path -Run 1
}

function Resolve-EvaluationAnswerPath {
    param(
        [Parameter(Mandatory = $true)][string]$AnswerRoot,
        [Parameter(Mandatory = $true)][string]$ScenarioId,
        [Parameter(Mandatory = $true)][int]$Run,
        [Parameter(Mandatory = $true)][bool]$LiveMode
    )
    $singlePath = Join-Path $AnswerRoot ("{0}.md" -f $ScenarioId)
    $runPath = Join-Path $AnswerRoot ("{0}.run{1}.md" -f $ScenarioId, $Run)
    if ($LiveMode) {
        return $runPath
    }
    if (Test-Path -LiteralPath $singlePath -PathType Leaf) {
        return $singlePath
    }
    return $runPath
}

if ($SelfTest) {
    $failures = New-Object System.Collections.Generic.List[string]
    foreach ($scenario in $scenarios) {
        $valid = Get-FixtureResult -Scenario $scenario -Kind "valid"
        if (-not $valid.passed) {
            $failures.Add("Valid fixture failed for '$($scenario.id)': $($valid.failed_check_ids -join ', ')") | Out-Null
        }
        $invalid = Get-FixtureResult -Scenario $scenario -Kind "invalid"
        if ($invalid.passed) {
            $failures.Add("Invalid fixture unexpectedly passed for '$($scenario.id)'.") | Out-Null
        }
    }
    $pathTestRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-behavior-path-$([guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path $pathTestRoot -Force | Out-Null
        $liveOne = Resolve-EvaluationAnswerPath -AnswerRoot $pathTestRoot -ScenarioId "test" -Run 1 -LiveMode $true
        $liveTwo = Resolve-EvaluationAnswerPath -AnswerRoot $pathTestRoot -ScenarioId "test" -Run 2 -LiveMode $true
        if ($liveOne -eq $liveTwo -or [IO.Path]::GetFileName($liveOne) -ne "test.run1.md" -or [IO.Path]::GetFileName($liveTwo) -ne "test.run2.md") {
            $failures.Add("Live runs do not use independent answer paths.") | Out-Null
        }
        $singlePath = Join-Path $pathTestRoot "test.md"
        [IO.File]::WriteAllText($singlePath, "fixture", (New-Object Text.UTF8Encoding($false)))
        $offlinePath = Resolve-EvaluationAnswerPath -AnswerRoot $pathTestRoot -ScenarioId "test" -Run 2 -LiveMode $false
        if ($offlinePath -ne $singlePath) {
            $failures.Add("Offline scoring no longer prefers the single answer file.") | Out-Null
        }
    }
    finally {
        if (Test-Path -LiteralPath $pathTestRoot) {
            Remove-Item -LiteralPath $pathTestRoot -Recurse -Force
        }
    }
    if ($failures.Count -gt 0) {
        Write-Host "Behavior eval harness self-test: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }
    Write-Host "Behavior eval harness self-test: PASS ($($scenarios.Count) scenarios, valid and invalid fixtures)"
    exit 0
}

if ($null -ne $ScenarioIds -and $ScenarioIds.Count -gt 0) {
    $requestedIds = @(
        $ScenarioIds |
            ForEach-Object { $_ -split "," } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    foreach ($requestedId in $requestedIds) {
        if (-not $seenIds.ContainsKey($requestedId)) {
            throw "Unknown behavior-eval scenario id: $requestedId"
        }
    }
    $selected = @($scenarios | Where-Object { $requestedIds -contains [string]$_.id })
}
else {
    $selected = @($scenarios | Select-Object -First ([Math]::Min($MaxCases, $scenarios.Count)))
}
if ($selected.Count -eq 0) {
    throw "No behavior-eval scenarios were selected."
}
if (-not $Live -and [string]::IsNullOrWhiteSpace($InputRoot)) {
    Write-Host "Behavior scenarios: $($scenarios.Count)"
    Write-Host "Selected for this invocation: $($selected.Count); runs: $Runs"
    Write-Host "No model call was made. Use one of:"
    Write-Host "  -InputRoot <directory>  Score existing response files."
    Write-Host "  -Live                  Run the installed Skill through codex exec."
    Write-Host "  -SelfTest              Check the scorer with local fixtures."
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InputRoot)) {
    New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $runRoot = Join-Path $OutputRoot $stamp
    $suffix = 2
    while (Test-Path -LiteralPath $runRoot) {
        $runRoot = Join-Path $OutputRoot "$stamp-$suffix"
        $suffix++
    }
    $answerRoot = Join-Path $runRoot "answers"
    $logRoot = Join-Path $runRoot "logs"
    New-Item -ItemType Directory -Path $answerRoot,$logRoot -Force | Out-Null

    if ([string]::IsNullOrWhiteSpace($CodexExecutable)) {
        $CodexExecutable = $env:CODEX_CLI_PATH
    }
    if ([string]::IsNullOrWhiteSpace($CodexExecutable)) {
        $command = Get-Command "codex.exe" -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            $command = Get-Command "codex" -ErrorAction SilentlyContinue
        }
        if ($null -eq $command) {
            throw "Codex executable was not found. Pass -CodexExecutable."
        }
        $CodexExecutable = $command.Source
    }
    if (-not (Test-Path -LiteralPath $CodexExecutable -PathType Leaf)) {
        $resolvedCommand = Get-Command $CodexExecutable -ErrorAction SilentlyContinue
        if ($null -eq $resolvedCommand) {
            throw "Codex executable was not found: $CodexExecutable"
        }
        $CodexExecutable = $resolvedCommand.Source
    }
    if ([string]::IsNullOrWhiteSpace($env:HOME)) {
        $env:HOME = $HOME
    }
    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $env:USERPROFILE = [Environment]::GetFolderPath("UserProfile")
    }
    if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME = Join-Path $HOME ".codex"
    }
} else {
    $answerRoot = (Resolve-Path -LiteralPath $InputRoot).Path
    $runRoot = Join-Path $OutputRoot ("offline-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
    if (Test-Path -LiteralPath $runRoot) {
        $runRoot = Join-Path $OutputRoot ("offline-" + [guid]::NewGuid().ToString("N"))
    }
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
    $logRoot = Join-Path $runRoot "logs"
    New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($scenario in $selected) {
    for ($run = 1; $run -le $Runs; $run++) {
        $answerPath = Resolve-EvaluationAnswerPath `
            -AnswerRoot $answerRoot `
            -ScenarioId $scenario.id `
            -Run $run `
            -LiveMode ([bool]$Live)
        if ($Live -and -not (Test-Path -LiteralPath $answerPath -PathType Leaf)) {
            $skillInstruction = if (-not [string]::IsNullOrWhiteSpace($SkillSourcePath)) {
                @"
You are testing the PC Hardware Workbench Skill source at:
$SkillSourcePath

Read that SKILL.md first and follow its routing and safety rules. Load only the
references it directs you to for this request. Do not invoke or rely on the
installed `$pc-hardware-workbench Skill.
"@
            }
            else {
                'Invoke the installed `$pc-hardware-workbench Skill and follow it.'
            }
            $toolBoundary = if (-not [string]::IsNullOrWhiteSpace($SkillSourcePath)) {
                "Read only the Skill files under that directory. Do not modify files or hardware. Do not use web, MCP, or hardware tools."
            }
            else {
                "Do not modify files or hardware. Do not use shell, file, web, MCP, or hardware tools."
            }
            $prompt = @"
$skillInstruction

This is an isolated response-quality evaluation. $toolBoundary Answer only the user request below.

$($scenario.prompt)
"@
            $logPath = Join-Path $logRoot ("{0}.run{1}.log" -f $scenario.id, $run)
            $arguments = @(
                "exec",
                "-s", "read-only",
                "--ephemeral",
                "--disable", "hooks",
                "-C", $RepositoryRoot,
                "--output-last-message", $answerPath
            )
            $promptPath = [IO.Path]::ChangeExtension($logPath, ".prompt.txt")
            [IO.File]::WriteAllText($promptPath, $prompt, $utf8NoBom)
            $stdoutPath = [IO.Path]::ChangeExtension($logPath, ".stdout.txt")
            $stderrPath = [IO.Path]::ChangeExtension($logPath, ".stderr.txt")
            $process = Start-Process `
                -FilePath $CodexExecutable `
                -ArgumentList $arguments `
                -RedirectStandardInput $promptPath `
                -RedirectStandardOutput $stdoutPath `
                -RedirectStandardError $stderrPath `
                -WindowStyle Hidden `
                -Wait `
                -PassThru
            $exitCode = $process.ExitCode
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -Raw -LiteralPath $stdoutPath -Encoding UTF8 } else { "" }
            $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -Raw -LiteralPath $stderrPath -Encoding UTF8 } else { "" }
            [IO.File]::WriteAllText(
                $logPath,
                "STDOUT`r`n$stdout`r`nSTDERR`r`n$stderr",
                $utf8NoBom
            )
            if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $answerPath -PathType Leaf)) {
                throw "Live behavior eval failed for '$($scenario.id)' run $run. See $logPath"
            }
        }
        if (-not (Test-Path -LiteralPath $answerPath -PathType Leaf)) {
            throw "Missing response file for '$($scenario.id)' run ${run}: $answerPath"
        }
        $text = Get-Content -Raw -LiteralPath $answerPath -Encoding UTF8
        $results.Add((Measure-Response -Scenario $scenario -Text $text -Path $answerPath -Run $run)) | Out-Null
    }
}

$failedResults = @($results | Where-Object { -not $_.passed })
$passedCount = $results.Count - $failedResults.Count
$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = [datetimeoffset]::Now.ToString("o")
    mode = if ($Live) { "live" } else { "offline" }
    skillMode = if (-not [string]::IsNullOrWhiteSpace($SkillSourcePath)) { "repository-source" } else { "installed" }
    skillSourcePath = if ([string]::IsNullOrWhiteSpace($SkillSourcePath)) { $null } else { $SkillSourcePath }
    repositoryRoot = $RepositoryRoot
    scenarioPath = $ScenarioPath
    selectedScenarioCount = $selected.Count
    runCount = $Runs
    responseRoot = $answerRoot
    passed = $passedCount
    failed = $failedResults.Count
    machineResult = if ($failedResults.Count -eq 0) { "PASS" } else { "FAIL" }
    humanReview = "PENDING"
        results = $results.ToArray()
}

$jsonPath = Join-Path $runRoot "report.json"
$markdownPath = Join-Path $runRoot "report.md"
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# Behavior evaluation report") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("- Generated: ``$($report.generatedAt)``") | Out-Null
$lines.Add("- Mode: ``$($report.mode)``") | Out-Null
$lines.Add("- Machine result: **$($report.machineResult)**") | Out-Null
$lines.Add("- Passed: $passedCount / $($results.Count)") | Out-Null
$lines.Add("- Human review: **PENDING**") | Out-Null
$lines.Add("") | Out-Null
$lines.Add("| Scenario | Run | Result | Failed checks | Warnings | Response |") | Out-Null
$lines.Add("|---|---:|---|---|---|---|") | Out-Null
foreach ($result in $results) {
    $friendlyPath = $result.response_path.Replace("\", "/")
    $lines.Add("| $($result.scenario_id) | $($result.run) | $(if ($result.passed) { 'PASS' } else { 'FAIL' }) | $($result.failed_check_ids -join ', ') | $($result.warning_check_ids -join ', ') | [open](<$friendlyPath>) |") | Out-Null
}
$lines.Add("") | Out-Null
$lines.Add("Machine checks are deterministic smoke checks. They do not replace independent human review.") | Out-Null
[IO.File]::WriteAllText($markdownPath, (($lines -join "`r`n") + "`r`n"), $utf8NoBom)

Write-Host "Behavior evaluation: $($report.machineResult)"
Write-Host "  Passed: $passedCount / $($results.Count)"
Write-Host "  Human review: PENDING"
Write-Host "  Markdown: $markdownPath"
Write-Host "  JSON:     $jsonPath"
if ($failedResults.Count -gt 0) {
    exit 1
}
