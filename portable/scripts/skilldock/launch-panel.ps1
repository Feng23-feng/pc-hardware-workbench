[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [string]$LauncherPath = $env:SKILLDOCK_LAUNCHER,

    [string]$ChatContextFile = "",

    [switch]$NoBrowser,

    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

function Write-JsonResult {
    param(
        [bool]$Ok,
        [string]$Url = "",
        [string]$ResolvedWorkspace = "",
        [string]$Driver = "",
        [string]$TaskRef = "",
        [int]$Cursor = 0,
        [string]$ErrorMessage = ""
    )

    [pscustomobject]@{
        ok = $Ok
        url = $Url
        workspace = $ResolvedWorkspace
        driver = $Driver
        task_ref = $TaskRef
        cursor = $Cursor
        error = $ErrorMessage
    } | ConvertTo-Json -Compress
}

try {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
        throw "Workspace is not a directory: $resolvedWorkspace"
    }

    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $localRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
        $pointerPath = Join-Path $localRoot "runtime-location.json"
        $installedRuntime = Join-Path $localRoot "Runtime\SkillDock.exe"
        if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
            try {
                $pointer = Get-Content -LiteralPath $pointerPath -Raw | ConvertFrom-Json
                if ($pointer.runtime_path) {
                    $installedRuntime = [string]$pointer.runtime_path
                }
            }
            catch {
                # Fall back to the legacy fixed runtime path.
            }
        }
        if (Test-Path -LiteralPath $installedRuntime -PathType Leaf) {
            $LauncherPath = $installedRuntime
        }
    }
    if (
        [string]::IsNullOrWhiteSpace($LauncherPath) -or
        -not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)
    ) {
        throw "SkillDock Runtime is not installed. Set SKILLDOCK_LAUNCHER or install the runtime first."
    }

    $localRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
    $resultPath = Join-Path $localRoot "launch-result.json"
    if (Test-Path -LiteralPath $resultPath) {
        Remove-Item -LiteralPath $resultPath -Force
    }

    $quotedWorkspace = '"' + $resolvedWorkspace.Replace('"', '\"') + '"'
    $arguments = "--ensure --workspace $quotedWorkspace --silent"
    if ($NoBrowser) {
        $arguments += " --no-browser"
    }
    Start-Process `
        -FilePath $LauncherPath `
        -ArgumentList $arguments `
        -WindowStyle Hidden | Out-Null

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 200
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
            try {
                $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            }
            catch {
                $result = $null
            }
            if ($result -and $result.ok -and $result.url) {
                break
            }
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    if (-not $result -or -not $result.ok -or -not $result.url) {
        throw "SkillDock Runtime did not return a launch result within $TimeoutSeconds seconds."
    }
    $resultWorkspace = (Resolve-Path -LiteralPath $result.workspace -ErrorAction Stop).Path
    if (-not $resultWorkspace.Equals($resolvedWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SkillDock Runtime returned a different workspace: $resultWorkspace"
    }
    $health = Invoke-RestMethod -Uri "$($result.url.TrimEnd('/'))/api/health" -TimeoutSec 5
    if (-not $health.ok) {
        throw "SkillDock health check failed."
    }

    $taskRef = ""
    $cursor = 0
    if (-not [string]::IsNullOrWhiteSpace($ChatContextFile)) {
        $resolvedContext = (
            Resolve-Path -LiteralPath $ChatContextFile -ErrorAction Stop
        ).Path
        if (-not (Test-Path -LiteralPath $resolvedContext -PathType Leaf)) {
            throw "Chat context file is missing: $resolvedContext"
        }
        if ((Get-Item -LiteralPath $resolvedContext).Length -gt 262144) {
            throw "Chat context file exceeds 256 KiB."
        }
        $contextBody = Get-Content -LiteralPath $resolvedContext -Raw -Encoding UTF8
        $null = ($contextBody | ConvertFrom-Json)
        $tokenPath = Join-Path $localRoot "runtime-dsh-web\capability-token"
        if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
            throw "SkillDock runtime token is unavailable."
        }
        $runtimeToken = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        $contextBytes = [Text.Encoding]::UTF8.GetBytes($contextBody)
        $imported = Invoke-RestMethod `
            -Uri "$($result.url.TrimEnd('/'))/api/task/sync/import" `
            -Method Post `
            -Headers @{ Authorization = "Bearer $runtimeToken" } `
            -ContentType "application/json; charset=utf-8" `
            -Body $contextBytes `
            -TimeoutSec 10
        if (-not $imported.ok -or [string]::IsNullOrWhiteSpace($imported.task_ref)) {
            throw "SkillDock did not accept the chat context handoff."
        }
        $taskRef = [string]$imported.task_ref
        $cursor = [int]$imported.cursor
    }

    # Deliberately do not read or emit the runtime capability token.
    Write-JsonResult `
        -Ok $true `
        -Url $result.url `
        -ResolvedWorkspace $resultWorkspace `
        -Driver $result.driver `
        -TaskRef $taskRef `
        -Cursor $cursor
}
catch {
    Write-JsonResult -Ok $false -ErrorMessage $_.Exception.Message
    exit 1
}
