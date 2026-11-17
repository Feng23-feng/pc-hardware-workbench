[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChannelId,

    [ValidateRange(0, 1000000000)]
    [int]$AfterSequence = 0,

    [string]$RuntimeDirectory = "",

    [ValidateSet("pchw-source-hosted", "legacy")]
    [string]$SurfaceProfile = "pchw-source-hosted",

    [string]$SourceSessionRef = "",

    [string]$ExpectedTaskId = "",

    [string]$ExpectedAttachmentId = "",

    [string]$ExpectedAttachmentSha256 = "",

    [ValidateRange(0, 1000000000)]
    [int]$ExpectedSubmissionSequence = 0,

    [string]$ExpectedIntentEventId = ""
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
. (Join-Path $PSScriptRoot "source-result-freshness.ps1")
. (Join-Path $PSScriptRoot "runtime-paths.ps1")

try {
    $runtimeContext = Get-SkillDockRuntimeAccessContext `
        -RuntimeDirectory $RuntimeDirectory
    $RuntimeDirectory = $runtimeContext.runtime_directory
    $tokenName = if ($SurfaceProfile -eq "pchw-source-hosted") {
        "source-capability-token"
    }
    else {
        "capability-token"
    }
    $tokenPath = Join-Path $RuntimeDirectory $tokenName
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw "SkillDock runtime is not running."
    }
    $info = $runtimeContext.result
    if (
        $SurfaceProfile -eq "pchw-source-hosted" -and
        [string]::IsNullOrWhiteSpace($SourceSessionRef)
    ) {
        throw "source_session_ref is required for the PCHW source-hosted profile."
    }
    if (
        $SurfaceProfile -eq "pchw-source-hosted" -and
        (
            [string]::IsNullOrWhiteSpace($ExpectedTaskId) -or
            [string]::IsNullOrWhiteSpace($ExpectedAttachmentId) -or
            [string]::IsNullOrWhiteSpace($ExpectedAttachmentSha256) -or
            (
                $ExpectedSubmissionSequence -le 0 -and
                [string]::IsNullOrWhiteSpace($ExpectedIntentEventId)
            )
        )
    ) {
        [pscustomobject]@{
            ok = $false
            error_code = "panel_sync_contract_missing"
            error =
                "ExpectedTaskId, ExpectedAttachmentId, ExpectedAttachmentSha256, and a submission sequence or intent event ID are required."
        } | ConvertTo-Json -Compress
        exit 1
    }
    $runtimeToken = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    $health = $runtimeContext.health
    if (-not $health.ok) {
        throw "SkillDock health check failed."
    }
    $encodedChannel = [Uri]::EscapeDataString($ChannelId)
    $requestHeaders = @{ Authorization = "Bearer $runtimeToken" }
    if ($SurfaceProfile -eq "pchw-source-hosted") {
        $requestHeaders["X-Source-Session-Ref"] = $SourceSessionRef
    }
    $result = Invoke-RestMethod `
        -Uri "http://127.0.0.1:$($info.port)/api/task/sync/export?channel_id=$encodedChannel&after_seq=0" `
        -Headers $requestHeaders `
        -TimeoutSec 10
    if ($SurfaceProfile -eq "pchw-source-hosted") {
        $freshness = Get-SourceResultFreshness `
            -Result $result `
            -ExpectedTaskId $ExpectedTaskId `
            -ExpectedAttachmentId $ExpectedAttachmentId `
            -ExpectedAttachmentSha256 $ExpectedAttachmentSha256 `
            -ExpectedSubmissionSequence $ExpectedSubmissionSequence `
            -ExpectedIntentEventId $ExpectedIntentEventId
        if ($freshness.state -ne "ready") {
            $errorCode = if ($freshness.code -eq "stale_source_result") {
                "panel_sync_stale_result"
            }
            elseif ($freshness.state -eq "hard_failure") {
                "panel_sync_contract_mismatch"
            }
            else {
                "panel_sync_not_ready"
            }
            [pscustomobject]@{
                ok = $false
                error_code = $errorCode
                freshness_code = [string]$freshness.code
                expected_task_id = $ExpectedTaskId
                expected_attachment_id = $ExpectedAttachmentId
                expected_sha256 = $ExpectedAttachmentSha256
                expected_submission_sequence = $ExpectedSubmissionSequence
                expected_intent_event_id = $ExpectedIntentEventId
                freshness = $freshness
                error = "The exported source result is not fresh for this submission."
            } | ConvertTo-Json -Depth 12 -Compress
            exit 1
        }
        $claim = Invoke-SourceHostedResultClaim `
            -Port ([int]$info.port) `
            -SourceToken $runtimeToken `
            -ChannelId $ChannelId `
            -SourceSessionRef $SourceSessionRef `
            -ExpectedTaskId $ExpectedTaskId `
            -ExpectedAttachmentId $ExpectedAttachmentId `
            -ExpectedAttachmentSha256 $ExpectedAttachmentSha256 `
            -ExpectedSubmissionSequence $ExpectedSubmissionSequence `
            -ExpectedIntentEventId $ExpectedIntentEventId
        if (-not $claim.ok) {
            $errorCode = if ($claim.error_code -eq "claim_result_stale") {
                "panel_sync_stale_result"
            }
            elseif (
                @(
                    "claim_anchor_mismatch",
                    "claim_contract_invalid",
                    "claim_task_mismatch",
                    "claim_channel_mismatch",
                    "claim_source_session_mismatch"
                ) -contains [string]$claim.error_code
            ) {
                "panel_sync_contract_mismatch"
            }
            else {
                "panel_sync_not_ready"
            }
            [pscustomobject]@{
                ok = $false
                error_code = $errorCode
                claim_error_code = [string]$claim.error_code
                claim_status = $claim.claim_status
                freshness_code = [string]$freshness.code
                expected_task_id = $ExpectedTaskId
                expected_attachment_id = $ExpectedAttachmentId
                expected_sha256 = $ExpectedAttachmentSha256
                expected_submission_sequence = $ExpectedSubmissionSequence
                expected_intent_event_id = $ExpectedIntentEventId
                freshness = $freshness
                claim = $claim
                error = "The source result could not be explicitly claimed."
            } | ConvertTo-Json -Depth 12 -Compress
            exit 1
        }
        $result.shared_task.phase = [string]$claim.phase
        $result | Add-Member `
            -NotePropertyName freshness `
            -NotePropertyValue $freshness `
            -Force
        $result | Add-Member `
            -NotePropertyName claim `
            -NotePropertyValue $claim `
            -Force
        $result.messages = @(
            $result.messages |
                Where-Object { [int]$_.seq -gt $AfterSequence }
        )
    }
    $displayLines = New-Object System.Collections.Generic.List[string]
    $displayLines.Add("已同步面板结果。") | Out-Null
    if ($result.panel) {
        if (-not [string]::IsNullOrWhiteSpace([string]$result.panel.turn_summary)) {
            $displayLines.Add("本轮结论：$([string]$result.panel.turn_summary)") | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$result.panel.judgement)) {
            $displayLines.Add("当前判断：$([string]$result.panel.judgement)") | Out-Null
        }
        $uncertainty = @($result.panel.uncertainty | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        foreach ($item in $uncertainty | Select-Object -First 3) {
            $displayLines.Add("未决问题：$([string]$item)") | Out-Null
        }
        $nextAction = [string]$result.panel.next_action
        if ([string]::IsNullOrWhiteSpace($nextAction)) {
            $nextAction = [string]$result.panel.priorityAction.title
        }
        if (-not [string]::IsNullOrWhiteSpace($nextAction)) {
            $displayLines.Add("下一步：$nextAction") | Out-Null
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$result.summary)) {
        $displayLines.Add("当前摘要：$([string]$result.summary)") | Out-Null
    }
    $displayLines.Add("同步消息数：$(@($result.messages).Count)") | Out-Null
    $result | Add-Member `
        -NotePropertyName surface_profile `
        -NotePropertyValue $SurfaceProfile `
        -Force
    $result | Add-Member `
        -NotePropertyName display_summary `
        -NotePropertyValue ($displayLines -join "`n") `
        -Force
    $result | ConvertTo-Json -Depth 20 -Compress
}
catch {
    [pscustomobject]@{
        ok = $false
        error = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
