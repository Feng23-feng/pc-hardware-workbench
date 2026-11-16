[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChannelId,

    [ValidateRange(0, 1000000000)]
    [int]$AfterSequence = 0,

    [string]$RuntimeDirectory = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

try {
    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $RuntimeDirectory = Join-Path $env:LOCALAPPDATA "SkillDock\runtime-dsh-web"
    }
    $infoPath = Join-Path $RuntimeDirectory "server-info.json"
    $tokenPath = Join-Path $RuntimeDirectory "capability-token"
    if (
        -not (Test-Path -LiteralPath $infoPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $tokenPath -PathType Leaf)
    ) {
        throw "SkillDock runtime is not running."
    }
    $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    $runtimeToken = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    $health = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$($info.port)/api/health" `
        -TimeoutSec 5
    if (-not $health.ok) {
        throw "SkillDock health check failed."
    }
    $encodedChannel = [Uri]::EscapeDataString($ChannelId)
    $result = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$($info.port)/api/task/sync/export?channel_id=$encodedChannel&after_seq=$AfterSequence" `
        -Headers @{ Authorization = "Bearer $runtimeToken" } `
        -TimeoutSec 10
    $result | ConvertTo-Json -Depth 20 -Compress
}
catch {
    [pscustomobject]@{
        ok = $false
        error = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
