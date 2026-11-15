param(
    [int]$Port = 4319,
    [string]$RuntimeDirectory = "runtime",
    [ValidateSet("codex", "dsh", "dsh-web", "agent-bridge", "mock")]
    [string]$AgentDriver = "codex",
    [string]$DshHome = "",
    [string]$AgentWorkspace = "",
    [switch]$ResetState
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Runtime = if ([IO.Path]::IsPathRooted($RuntimeDirectory)) {
    [IO.Path]::GetFullPath($RuntimeDirectory)
} else {
    Join-Path $Root $RuntimeDirectory
}
$InfoPath = Join-Path $Runtime "server-info.json"
$StdoutPath = Join-Path $Runtime "server.stdout.log"
$StderrPath = Join-Path $Runtime "server.stderr.log"
$Url = "http://127.0.0.1:$Port/"
$HealthUrl = "http://127.0.0.1:$Port/api/health"
$Node = (Get-Command node -ErrorAction Stop).Source

New-Item -ItemType Directory -Path $Runtime -Force | Out-Null

try {
    $Health = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 1
    if ($Health.ok) {
        if ($ResetState) {
            throw "Agent Panel is already running. Run stop.ps1 before resetting the session."
        }
        Write-Output "Agent Panel is already running."
        Write-Output $Url
        exit 0
    }
}
catch {
    # A failed health probe is expected when the local server is stopped.
}

$env:PANEL_AGENT_DRIVER = $AgentDriver
if (-not [string]::IsNullOrWhiteSpace($DshHome)) {
    $env:DSH_HOME = [IO.Path]::GetFullPath($DshHome)
}
if (-not [string]::IsNullOrWhiteSpace($AgentWorkspace)) {
    $env:PANEL_AGENT_WORKSPACE = [IO.Path]::GetFullPath($AgentWorkspace)
}
$env:PANEL_PORT = [string]$Port
$env:PANEL_RUNTIME_DIR = $Runtime
$ServerArguments = if ($ResetState) { @("server.mjs", "--reset-state") } else { @("server.mjs") }
$Process = Start-Process `
    -FilePath $Node `
    -ArgumentList $ServerArguments `
    -WorkingDirectory $Root `
    -WindowStyle Hidden `
    -RedirectStandardOutput $StdoutPath `
    -RedirectStandardError $StderrPath `
    -PassThru

$Ready = $false
for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
    Start-Sleep -Milliseconds 400
    if ($Process.HasExited) {
        break
    }
    try {
        $Health = Invoke-RestMethod -Uri $HealthUrl -TimeoutSec 1
        if ($Health.ok) {
            $Ready = $true
            break
        }
    }
    catch {
        # Keep waiting for the local listener.
    }
}

if (-not $Ready) {
    Write-Error "Agent Panel did not become ready. Check $StderrPath"
    if (-not $Process.HasExited) {
        Stop-Process -Id $Process.Id
    }
    exit 1
}

Write-Output "Agent Panel started."
Write-Output $Url
Write-Output "Runtime PID: $($Process.Id)"
