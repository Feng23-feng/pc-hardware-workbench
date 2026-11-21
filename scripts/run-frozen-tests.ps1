[CmdletBinding()]
param(
    [ValidateSet("check", "test", "all")]
    [string]$Mode = "all",

    [string]$NodePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent $PSScriptRoot)
).TrimEnd("\")
$packageJson = Get-Content `
    -Raw `
    -LiteralPath (Join-Path $repositoryRoot "package.json") |
    ConvertFrom-Json
$releaseVersion = [string]$packageJson.version
$releaseConfig = Get-Content `
    -Raw `
    -LiteralPath (Join-Path `
        $repositoryRoot `
        "release\$releaseVersion\release.json") |
    ConvertFrom-Json
$profile = Get-Content `
    -Raw `
    -LiteralPath (Join-Path `
        $repositoryRoot `
        "contracts\source-hosted-shared-task\v1\persistence\production-profile.json") |
    ConvertFrom-Json
$expectedNodeVersion = [string]$releaseConfig.bundled_node_version
$expectedSqliteVersion = [string]$profile.runtime.sqlite_verified

function Resolve-NodeExecutable {
    param([string]$Candidate)

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return $null
    }
    $resolved = [IO.Path]::GetFullPath($Candidate)
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $resolved = Join-Path $resolved "node.exe"
    }
    if (Test-Path -LiteralPath $resolved -PathType Leaf) {
        return $resolved
    }
    return $null
}

function Get-NodeCandidateList {
    param([switch]$IncludeArchive)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(
        $NodePath,
        $env:SKILLDOCK_FROZEN_NODE,
        (Join-Path `
            $repositoryRoot `
            "dist\SkillDock-PCHW-$releaseVersion-win-x64\node")
    )) {
        $resolved = Resolve-NodeExecutable -Candidate $candidate
        if ($resolved -and -not $candidates.Contains($resolved)) {
            $candidates.Add($resolved) | Out-Null
        }
    }

    if ($IncludeArchive) {
        $distRoot = Join-Path $repositoryRoot "dist"
    }
    else {
        $distRoot = $null
    }
    if ($distRoot -and (Test-Path -LiteralPath $distRoot -PathType Container)) {
        foreach ($file in @(
            Get-ChildItem `
                -LiteralPath $distRoot `
                -File `
                -Filter "node.exe" `
                -Recurse `
                -ErrorAction SilentlyContinue
        )) {
            if (-not $candidates.Contains($file.FullName)) {
                $candidates.Add($file.FullName) | Out-Null
            }
        }
    }
    return @($candidates.ToArray())
}

function Get-NodeProbe {
    param([Parameter(Mandatory = $true)][string]$Executable)

    $versionOutput = @(& $Executable --version 2>&1)
    $nodeVersion = (($versionOutput | Out-String).Trim()).TrimStart("v")
    $sqliteOutput = @(& $Executable -p "process.versions.sqlite" 2>&1)
    $sqliteVersion = ($sqliteOutput | Out-String).Trim()
    return [pscustomobject]@{
        node = $nodeVersion
        sqlite = $sqliteVersion
    }
}

$selectedNode = $null
$selectedProbe = $null
$rejected = New-Object System.Collections.Generic.List[string]
$tested = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($candidate in @(Get-NodeCandidateList)) {
    if (-not $tested.Add($candidate)) {
        continue
    }
    try {
        $probe = Get-NodeProbe -Executable $candidate
    }
    catch {
        $rejected.Add(
            "$candidate (probe failed: $($_.Exception.Message))"
        ) | Out-Null
        continue
    }
    if (
        $probe.node -eq $expectedNodeVersion -and
        $probe.sqlite -eq $expectedSqliteVersion
    ) {
        $selectedNode = $candidate
        $selectedProbe = $probe
        break
    }
    $rejected.Add(
        "$candidate (node $($probe.node), sqlite $($probe.sqlite))"
    ) | Out-Null
}

if (-not $selectedNode -and -not $NodePath -and -not $env:SKILLDOCK_FROZEN_NODE) {
    foreach ($candidate in @(Get-NodeCandidateList -IncludeArchive)) {
        if (-not $tested.Add($candidate)) {
            continue
        }
        try {
            $probe = Get-NodeProbe -Executable $candidate
        }
        catch {
            $rejected.Add(
                "$candidate (probe failed: $($_.Exception.Message))"
            ) | Out-Null
            continue
        }
        if (
            $probe.node -eq $expectedNodeVersion -and
            $probe.sqlite -eq $expectedSqliteVersion
        ) {
            $selectedNode = $candidate
            $selectedProbe = $probe
            break
        }
        $rejected.Add(
            "$candidate (node $($probe.node), sqlite $($probe.sqlite))"
        ) | Out-Null
    }
}

if (-not $selectedNode) {
    $details = if ($rejected.Count -gt 0) {
        $shown = @($rejected | Select-Object -First 10)
        $remaining = $rejected.Count - $shown.Count
        $detailText = "`nCandidates checked:`n- " + ($shown -join "`n- ")
        if ($remaining -gt 0) {
            $detailText += "`n- ... and $remaining more"
        }
        $detailText
    }
    else {
        ""
    }
    throw (
        "No frozen Node executable was found. Expected Node " +
        "$expectedNodeVersion with SQLite $expectedSqliteVersion. " +
        "Set SKILLDOCK_FROZEN_NODE or pass -NodePath.$details"
    )
}

$pnpm = Get-Command pnpm.cmd -ErrorAction Stop
$previousPath = $env:PATH
try {
    $nodeDirectory = Split-Path -Parent $selectedNode
    $env:PATH = "$nodeDirectory;$env:PATH"

    Write-Host "Frozen test runtime: $selectedNode"
    Write-Host "Node: $($selectedProbe.node) / SQLite: $($selectedProbe.sqlite)"

    if ($Mode -in @("check", "all")) {
        & $pnpm.Source check
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
    if ($Mode -in @("test", "all")) {
        & $pnpm.Source test
        if ($LASTEXITCODE -ne 0) {
            exit $LASTEXITCODE
        }
    }
}
finally {
    $env:PATH = $previousPath
}

Write-Host "Frozen Node test gate: PASS" -ForegroundColor Green
