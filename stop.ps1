param(
    [string]$RuntimeDirectory = "runtime"
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
$Runtime = if ([IO.Path]::IsPathRooted($RuntimeDirectory)) {
    [IO.Path]::GetFullPath($RuntimeDirectory)
} else {
    Join-Path $Root $RuntimeDirectory
}
$InfoPath = Join-Path $Runtime "server-info.json"
$TokenPath = Join-Path $Runtime "capability-token"

if (-not (Test-Path -LiteralPath $InfoPath)) {
    Write-Output "SkillDock is not running."
    exit 0
}

$Info = Get-Content -LiteralPath $InfoPath -Raw | ConvertFrom-Json
$Token = (Get-Content -LiteralPath $TokenPath -Raw).Trim()
$ShutdownUrl = "http://127.0.0.1:$($Info.port)/api/shutdown"

try {
    Invoke-RestMethod `
        -Uri $ShutdownUrl `
        -Method Post `
        -ContentType "application/json" `
        -Headers @{ Authorization = "Bearer $Token" } `
        -Body "{}" `
        -TimeoutSec 3 | Out-Null
}
catch {
    $Process = Get-Process -Id $Info.pid -ErrorAction SilentlyContinue
    if (-not $Process) {
        Write-Output "SkillDock is already stopped."
        exit 0
    }
    $Details = Get-CimInstance Win32_Process -Filter "ProcessId = $($Info.pid)"
    if (-not $Details.CommandLine -or $Details.CommandLine -notmatch "server\.mjs") {
        throw "PID $($Info.pid) is not verified as the SkillDock server."
    }
    Stop-Process -Id $Info.pid
}

$Stopped = $false
for ($Attempt = 0; $Attempt -lt 20; $Attempt++) {
    if (-not (Get-Process -Id $Info.pid -ErrorAction SilentlyContinue)) {
        $Stopped = $true
        break
    }
    Start-Sleep -Milliseconds 250
}

if ($Stopped) {
    Write-Output "SkillDock stopped."
} else {
    Write-Warning "Shutdown was requested, but PID $($Info.pid) is still present."
}
