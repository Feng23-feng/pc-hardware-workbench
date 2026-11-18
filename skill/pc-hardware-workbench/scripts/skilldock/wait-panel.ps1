[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ChannelId,

    [Parameter(Mandatory = $true)]
    [string]$SourceSessionRef,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedTaskId,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedAttachmentId,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedAttachmentSha256,

    [ValidateRange(0, 1000000000)]
    [int]$ExpectedSubmissionSequence = 0,

    [string]$ExpectedIntentEventId = "",

    [string]$RuntimeDirectory = "",

    [ValidateRange(5, 600)]
    [int]$TimeoutSeconds = 180,

    [ValidateRange(250, 5000)]
    [int]$PollMilliseconds = 1000
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
    $tokenPath = Join-Path $RuntimeDirectory "source-capability-token"
    if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
        throw "SkillDock source-hosted runtime is not running."
    }
    $info = $runtimeContext.result
    $sourceToken = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
    $encodedChannel = [Uri]::EscapeDataString($ChannelId)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = ""
    $lastFreshness = $null

    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $result = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$($info.port)/api/task/sync/export?channel_id=$encodedChannel&after_seq=0" `
                -Headers @{
                    Authorization = "Bearer $sourceToken"
                    "X-Source-Session-Ref" = $SourceSessionRef
                } `
                -TimeoutSec 10
            $lastFreshness = Get-SourceResultFreshness `
                -Result $result `
                -ExpectedTaskId $ExpectedTaskId `
                -ExpectedAttachmentId $ExpectedAttachmentId `
                -ExpectedAttachmentSha256 $ExpectedAttachmentSha256 `
                -ExpectedSubmissionSequence $ExpectedSubmissionSequence `
                -ExpectedIntentEventId $ExpectedIntentEventId
            if ($lastFreshness.state -eq "hard_failure") {
                [pscustomobject]@{
                    ok = $false
                    ready = $false
                    error_code = "panel_wait_contract_mismatch"
                    freshness_code = [string]$lastFreshness.code
                    expected_task_id = $ExpectedTaskId
                    expected_attachment_id = $ExpectedAttachmentId
                    expected_sha256 = $ExpectedAttachmentSha256
                    expected_submission_sequence = $ExpectedSubmissionSequence
                    expected_intent_event_id = $ExpectedIntentEventId
                    freshness = $lastFreshness
                } | ConvertTo-Json -Depth 12 -Compress
                exit 1
            }
            if ($lastFreshness.state -eq "ready") {
                $claim = Invoke-SourceHostedResultClaim `
                    -Port ([int]$info.port) `
                    -SourceToken $sourceToken `
                    -ChannelId $ChannelId `
                    -SourceSessionRef $SourceSessionRef `
                    -ExpectedTaskId $ExpectedTaskId `
                    -ExpectedAttachmentId $ExpectedAttachmentId `
                    -ExpectedAttachmentSha256 $ExpectedAttachmentSha256 `
                    -ExpectedSubmissionSequence $ExpectedSubmissionSequence `
                    -ExpectedIntentEventId $ExpectedIntentEventId
                if (-not $claim.ok) {
                    if (
                        -not [string]::IsNullOrWhiteSpace(
                            [string]$claim.error_code
                        ) -and
                        [string]$claim.error_code -ne "claim_request_failed"
                    ) {
                        [pscustomobject]@{
                            ok = $false
                            ready = $false
                            error_code = "panel_wait_claim_failed"
                            claim_error_code = [string]$claim.error_code
                            claim_status = $claim.claim_status
                            expected_task_id = $ExpectedTaskId
                            expected_attachment_id = $ExpectedAttachmentId
                            expected_sha256 = $ExpectedAttachmentSha256
                            expected_submission_sequence =
                                $ExpectedSubmissionSequence
                            expected_intent_event_id = $ExpectedIntentEventId
                            freshness = $lastFreshness
                            claim = $claim
                        } | ConvertTo-Json -Depth 12 -Compress
                        exit 1
                    }
                    $lastError = [string]$claim.error
                }
                else {
                    $result.shared_task.phase = [string]$claim.phase
                    $result | Add-Member `
                        -NotePropertyName claim `
                        -NotePropertyValue $claim `
                        -Force
                $displayLines = New-Object System.Collections.Generic.List[string]
                $displayLines.Add("面板已准备好当前对话 Agent 的输入。") | Out-Null
                $displayLines.Add(
                    "本地分析行数：$([int]$result.source_tool_result.result.analysis.analyzed_rows)"
                ) | Out-Null
                $displayLines.Add(
                    "本地分析指标数：$(@($result.source_tool_result.result.analysis.metrics).Count)"
                ) | Out-Null
                [pscustomobject]@{
                    ok = $true
                    ready = $true
                    surface_profile = "pchw-source-hosted"
                    task_ref = [string]$result.task_ref
                    phase = [string]$result.shared_task.phase
                    cursor = [int]$result.cursor
                    freshness = $lastFreshness
                    claim = $claim
                    source_tool_result = $result.source_tool_result
                    panel = $result.panel
                    messages = @($result.messages)
                    display_summary = ($displayLines -join "`n")
                } | ConvertTo-Json -Depth 24 -Compress
                exit 0
                }
            }
        }
        catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    [pscustomobject]@{
        ok = $false
        ready = $false
        error_code = "panel_wait_timeout"
        expected_task_id = $ExpectedTaskId
        expected_attachment_id = $ExpectedAttachmentId
        expected_sha256 = $ExpectedAttachmentSha256
        expected_submission_sequence = $ExpectedSubmissionSequence
        expected_intent_event_id = $ExpectedIntentEventId
        stale_result_observed =
            [bool]($lastFreshness -and $lastFreshness.stale_observed)
        freshness = $lastFreshness
        fallback_reason =
            "Continue in chat. If the panel later finishes, say '同步面板' to retry."
        error = $lastError
    } | ConvertTo-Json -Compress
    exit 1
}
catch {
    [pscustomobject]@{
        ok = $false
        ready = $false
        error_code = "panel_wait_unavailable"
        fallback_reason =
            "Continue in chat; the local panel is not available for automatic return."
        error = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
