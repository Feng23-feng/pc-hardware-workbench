[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChannelId,

    [Parameter(Mandatory = $true)]
    [string]$SourceSessionRef,

    [Parameter(Mandatory = $true)]
    [string]$PanelFile,

    [Parameter(Mandatory = $true)]
    [string]$MessageText,

    [string]$Objective = "",

    [string]$Summary = "",

    [string]$RuntimeDirectory = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom

try {
    if ([string]::IsNullOrWhiteSpace($RuntimeDirectory)) {
        $localRoot = if ([string]::IsNullOrWhiteSpace($env:SKILLDOCK_LOCAL_ROOT)) {
            Join-Path $env:LOCALAPPDATA "SkillDock"
        }
        else {
            [IO.Path]::GetFullPath($env:SKILLDOCK_LOCAL_ROOT)
        }
        $RuntimeDirectory = Join-Path $localRoot "runtime-dsh-web"
    }
    $infoPath = Join-Path $RuntimeDirectory "server-info.json"
    $tokenPath = Join-Path $RuntimeDirectory "source-capability-token"
    if (
        -not (Test-Path -LiteralPath $infoPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $tokenPath -PathType Leaf)
    ) {
        throw "SkillDock source-hosted runtime is not running."
    }
    $resolvedPanel = (Resolve-Path -LiteralPath $PanelFile -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedPanel -PathType Leaf)) {
        throw "Panel result file is missing."
    }
    if ((Get-Item -LiteralPath $resolvedPanel).Length -gt 200000) {
        throw "Panel result exceeds 200 KB."
    }
    $panel = Get-Content -LiteralPath $resolvedPanel -Raw -Encoding UTF8 |
        ConvertFrom-Json
    if ($null -eq $panel -or $panel -is [array]) {
        throw "Panel result must be one JSON object."
    }

    $info = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    $sourceToken = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    $health = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$($info.port)/api/health" `
        -TimeoutSec 5
    if (-not $health.ok) {
        throw "SkillDock health check failed."
    }

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $panelText = $panel | ConvertTo-Json -Depth 20 -Compress
        $messageBytes = [Text.Encoding]::UTF8.GetBytes(
            "$ChannelId`n$MessageText`n$panelText"
        )
        $hash = $sha.ComputeHash($messageBytes)
        $messageId = "pchw-panel-" + (
            (($hash | Select-Object -First 16) | ForEach-Object {
                $_.ToString("x2")
            }) -join ""
        )
    }
    finally {
        $sha.Dispose()
    }

    $body = [pscustomobject]@{
        schema_version = "1.0"
        channel_id = $ChannelId
        source_session_ref = $SourceSessionRef
        objective = $Objective
        summary = $Summary
        messages = @(
            [pscustomobject]@{
                id = $messageId
                role = "agent"
                text = $MessageText
                created_at = [DateTimeOffset]::UtcNow.ToString("o")
            }
        )
        panel = $panel
    }
    $bodyBytes = [Text.Encoding]::UTF8.GetBytes(
        ($body | ConvertTo-Json -Depth 24 -Compress)
    )
    $result = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$($info.port)/api/task/sync/import" `
        -Method Post `
        -Headers @{
            Authorization = "Bearer $sourceToken"
            "X-Source-Session-Ref" = $SourceSessionRef
        } `
        -ContentType "application/json; charset=utf-8" `
        -Body $bodyBytes `
        -TimeoutSec 20
    [pscustomobject]@{
        ok = $true
        task_ref = [string]$result.task_ref
        phase = [string]$result.shared_task_phase
        imported_count = [int]$result.imported_count
        skipped_count = [int]$result.skipped_count
    } | ConvertTo-Json -Compress
}
catch {
    [pscustomobject]@{
        ok = $false
        error_code = "panel_result_write_failed"
        error = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
