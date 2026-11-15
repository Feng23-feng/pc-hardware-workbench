[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [string]$LauncherPath = $env:SKILLDOCK_LAUNCHER,

    [switch]$NoBrowser,

    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"

function Write-JsonResult {
    param(
        [bool]$Ok,
        [string]$Url = "",
        [string]$ResolvedWorkspace = "",
        [string]$Driver = "",
        [string]$ErrorMessage = ""
    )

    [pscustomobject]@{
        ok = $Ok
        url = $Url
        workspace = $ResolvedWorkspace
        driver = $Driver
        error = $ErrorMessage
    } | ConvertTo-Json -Compress
}

try {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
        throw "Workspace is not a directory: $resolvedWorkspace"
    }

    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $installedRuntime = Join-Path $env:LOCALAPPDATA "SkillDock\Runtime\SkillDock.exe"
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

    # Deliberately do not read or emit the runtime capability token.
    Write-JsonResult `
        -Ok $true `
        -Url $result.url `
        -ResolvedWorkspace $resultWorkspace `
        -Driver $result.driver
}
catch {
    Write-JsonResult -Ok $false -ErrorMessage $_.Exception.Message
    exit 1
}
