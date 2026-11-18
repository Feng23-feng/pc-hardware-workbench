function Get-SourceResultFreshness {
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$ExpectedTaskId,
        [Parameter(Mandatory = $true)][string]$ExpectedAttachmentId,
        [Parameter(Mandatory = $true)][string]$ExpectedAttachmentSha256,
        [int]$ExpectedSubmissionSequence = 0,
        [string]$ExpectedIntentEventId = ""
    )

    if (
        $ExpectedSubmissionSequence -le 0 -and
        [string]::IsNullOrWhiteSpace($ExpectedIntentEventId)
    ) {
        return [pscustomobject]@{
            state = "hard_failure"
            code = "submission_anchor_missing"
            stale_observed = $false
            freshness_checks = @{}
        }
    }

    $actualTaskId = [string]$Result.task_ref
    if ($actualTaskId -ne $ExpectedTaskId) {
        return [pscustomobject]@{
            state = "hard_failure"
            code = "expected_task_mismatch"
            actual_task_id = $actualTaskId
            stale_observed = $false
            freshness_checks = @{
                task_matches = $false
            }
        }
    }

    $cursor = [int]$Result.cursor
    $messages = @($Result.messages)
    $submission = $null
    if (-not [string]::IsNullOrWhiteSpace($ExpectedIntentEventId)) {
        $submission = $messages |
            Where-Object {
                [string]$_.external_id -eq $ExpectedIntentEventId
            } |
            Select-Object -First 1
    }
    if ($null -eq $submission -and $ExpectedSubmissionSequence -gt 0) {
        $submission = $messages |
            Where-Object {
                [int]$_.seq -eq $ExpectedSubmissionSequence
            } |
            Select-Object -First 1
    }
    if ($null -eq $submission) {
        return [pscustomobject]@{
            state = if ($cursor -lt $ExpectedSubmissionSequence) {
                "pending"
            }
            else {
                "hard_failure"
            }
            code = if ($cursor -lt $ExpectedSubmissionSequence) {
                "submission_not_observed"
            }
            else {
                "submission_anchor_not_found"
            }
            cursor = $cursor
            stale_observed = $false
            freshness_checks = @{
                task_matches = $true
                submission_found = $false
            }
        }
    }
    if (
        [int]$submission.seq -lt $ExpectedSubmissionSequence -or
        (
            -not [string]::IsNullOrWhiteSpace($ExpectedIntentEventId) -and
            [string]$submission.external_id -ne $ExpectedIntentEventId
        )
    ) {
        return [pscustomobject]@{
            state = "hard_failure"
            code = "submission_anchor_mismatch"
            actual_submission_sequence = [int]$submission.seq
            actual_intent_event_id = [string]$submission.external_id
            stale_observed = $false
            freshness_checks = @{
                task_matches = $true
                submission_found = $true
                submission_anchor_matches = $false
            }
        }
    }

    $submissionAttachments = @($submission.attachments)
    $submissionAttachment = $submissionAttachments |
        Where-Object {
            [string]$_.id -eq $ExpectedAttachmentId
        } |
        Select-Object -First 1
    if ($null -eq $submissionAttachment) {
        return [pscustomobject]@{
            state = "hard_failure"
            code = "expected_attachment_missing_from_submission"
            submission_sequence = [int]$submission.seq
            intent_event_id = [string]$submission.external_id
            stale_observed = $false
            freshness_checks = @{
                task_matches = $true
                submission_found = $true
                submission_attachment_matches = $false
            }
        }
    }
    if (
        [string]$submissionAttachment.sha256 -ne
        $ExpectedAttachmentSha256
    ) {
        return [pscustomobject]@{
            state = "hard_failure"
            code = "expected_sha_mismatch_from_submission"
            actual_sha256 = [string]$submissionAttachment.sha256
            stale_observed = $false
            freshness_checks = @{
                task_matches = $true
                submission_found = $true
                submission_attachment_matches = $true
                submission_sha_matches = $false
            }
        }
    }

    $packet = $Result.source_tool_result.packet
    if ($null -eq $packet) {
        return [pscustomobject]@{
            state = "pending"
            code = "source_result_not_observed"
            submission_sequence = [int]$submission.seq
            intent_event_id = [string]$submission.external_id
            stale_observed = $false
            freshness_checks = @{
                task_matches = $true
                submission_found = $true
                submission_attachment_matches = $true
                submission_sha_matches = $true
                source_result_present = $false
            }
        }
    }

    $tool = $packet.tool_result
    $returnedAttachmentId = [string]$tool.attachment.id
    $returnedSha256 = [string]$tool.attachment.sha256
    $packetCreatedAt = [DateTimeOffset]::MinValue
    $packetCreatedAtValid = [DateTimeOffset]::TryParse(
        [string]$packet.created_at,
        [ref]$packetCreatedAt
    )
    $submissionCreatedAt = [DateTimeOffset]::MinValue
    $submissionCreatedAtValid = [DateTimeOffset]::TryParse(
        [string]$submission.created_at,
        [ref]$submissionCreatedAt
    )
    $sourceEvidenceIds = @($tool.artifact.source_evidence_ids)
    $matchesAttachment =
        $returnedAttachmentId -eq $ExpectedAttachmentId
    $matchesSha =
        $returnedSha256 -eq $ExpectedAttachmentSha256
    $matchesEvidence =
        $sourceEvidenceIds -contains $ExpectedAttachmentId
    $isAfterSubmission =
        $packetCreatedAtValid -and
        $submissionCreatedAtValid -and
        $packetCreatedAt -ge $submissionCreatedAt

    if (
        -not $matchesAttachment -or
        -not $matchesSha -or
        -not $matchesEvidence -or
        -not $isAfterSubmission
    ) {
        return [pscustomobject]@{
            state = "pending"
            code = "stale_source_result"
            submission_sequence = [int]$submission.seq
            intent_event_id = [string]$submission.external_id
            returned_attachment_id = $returnedAttachmentId
            returned_sha256 = $returnedSha256
            packet_created_at = [string]$packet.created_at
            submission_created_at = [string]$submission.created_at
            stale_observed = $true
            freshness_checks = @{
                task_matches = $true
                submission_found = $true
                submission_attachment_matches = $true
                submission_sha_matches = $true
                source_result_present = $true
                result_attachment_matches = $matchesAttachment
                result_sha_matches = $matchesSha
                result_evidence_matches = $matchesEvidence
                result_after_submission = $isAfterSubmission
            }
        }
    }

    return [pscustomobject]@{
        state = "ready"
        code = "fresh_source_result"
        submission_sequence = [int]$submission.seq
        intent_event_id = [string]$submission.external_id
        returned_attachment_id = $returnedAttachmentId
        returned_sha256 = $returnedSha256
        packet_created_at = [string]$packet.created_at
        submission_created_at = [string]$submission.created_at
        stale_observed = $false
        freshness_checks = @{
            task_matches = $true
            submission_found = $true
            submission_attachment_matches = $true
            submission_sha_matches = $true
            source_result_present = $true
            result_attachment_matches = $true
            result_sha_matches = $true
            result_evidence_matches = $true
            result_after_submission = $true
        }
    }
}

function Invoke-SourceHostedResultClaim {
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$SourceToken,
        [Parameter(Mandatory = $true)][string]$ChannelId,
        [Parameter(Mandatory = $true)][string]$SourceSessionRef,
        [Parameter(Mandatory = $true)][string]$ExpectedTaskId,
        [Parameter(Mandatory = $true)][string]$ExpectedAttachmentId,
        [Parameter(Mandatory = $true)][string]$ExpectedAttachmentSha256,
        [Parameter(Mandatory = $true)][int]$ExpectedSubmissionSequence,
        [Parameter(Mandatory = $true)][string]$ExpectedIntentEventId
    )

    $claimBody = [pscustomobject]@{
        schema_version = "1.0"
        task_ref = $ExpectedTaskId
        channel_id = $ChannelId
        source_session_ref = $SourceSessionRef
        intent_event_id = $ExpectedIntentEventId
        submission_sequence = $ExpectedSubmissionSequence
        attachment_id = $ExpectedAttachmentId
        attachment_sha256 = $ExpectedAttachmentSha256
        require_source_result = $true
    } | ConvertTo-Json -Depth 8 -Compress

    try {
        $claim = Invoke-RestMethod `
            -Uri "http://127.0.0.1:$Port/api/task/sync/claim" `
            -Method Post `
            -Headers @{
                Authorization = "Bearer $SourceToken"
                "X-Source-Session-Ref" = $SourceSessionRef
                "Content-Type" = "application/json"
            } `
            -Body $claimBody `
            -TimeoutSec 10
        return [pscustomobject]@{
            ok = [bool]$claim.ok
            claimed = [bool]$claim.claimed
            idempotent = [bool]$claim.idempotent
            phase = [string]$claim.phase
            claim = $claim.claim
        }
    }
    catch {
        $statusCode = $null
        $responseBody = ""
        if ($_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }
            catch {
                $statusCode = $null
            }
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    try {
                        $responseBody = $reader.ReadToEnd()
                    }
                    finally {
                        $reader.Dispose()
                    }
                }
            }
            catch {
                $responseBody = ""
            }
        }
        if ([string]::IsNullOrWhiteSpace($responseBody)) {
            try {
                $responseBody = [string]$_.ErrorDetails.Message
            }
            catch {
                $responseBody = ""
            }
        }
        $parsed = $null
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            try {
                $parsed = $responseBody | ConvertFrom-Json
            }
            catch {
                $parsed = $null
            }
        }
        return [pscustomobject]@{
            ok = $false
            claimed = $false
            idempotent = $false
            claim_status = $statusCode
            error_code =
                if ($parsed -and -not [string]::IsNullOrWhiteSpace(
                    [string]$parsed.code
                )) {
                    [string]$parsed.code
                }
                else {
                    "claim_request_failed"
                }
            error =
                if ($parsed -and -not [string]::IsNullOrWhiteSpace(
                    [string]$parsed.error
                )) {
                    [string]$parsed.error
                }
                else {
                    [string]$_.Exception.Message
                }
        }
    }
}
