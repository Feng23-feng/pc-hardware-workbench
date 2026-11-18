[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-surface-$([guid]::NewGuid().ToString('N'))"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Assert-ContainsAll {
    param(
        [string]$Text,
        [string[]]$Values,
        [string]$Label
    )
    $normalizedText = $Text -replace '\s+', ' '
    foreach ($value in $Values) {
        $normalizedValue = $value -replace '\s+', ' '
        Assert-True ($normalizedText -match [regex]::Escape($normalizedValue)) "$Label is missing '$value'."
    }
}

function Get-MarkdownSection {
    param(
        [string]$Text,
        [string]$Heading
    )
    $pattern = "(?ms)^## " + [regex]::Escape($Heading) + "\r?\n(.*?)(?=^## |\z)"
    if ($Text -match $pattern) {
        return $Matches[1]
    }
    return ""
}

try {
    $skill = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "SKILL.md") -Encoding UTF8
    $closure = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/integration/interaction-closure.md") -Encoding UTF8
    $surface = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/integration/workbench-surface.md") -Encoding UTF8
    $runtimeDoc = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/integration/workbench-runtime.md") -Encoding UTF8
    $skilldock = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/integration/skilldock-surface.md") -Encoding UTF8
    $agentInterface = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "agents/openai.yaml") -Encoding UTF8
    $skilldockLauncher = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/skilldock/launch-panel.ps1") -Encoding UTF8
    $skilldockSync = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/skilldock/sync-panel.ps1") -Encoding UTF8
    $skilldockWait = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/skilldock/wait-panel.ps1") -Encoding UTF8
    $skilldockFreshness = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/skilldock/source-result-freshness.ps1") -Encoding UTF8
    $skilldockSubmit = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/skilldock/submit-panel-result.ps1") -Encoding UTF8
    $skilldockRuntimePaths = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "scripts/skilldock/runtime-paths.ps1") -Encoding UTF8
    $triage = Get-Content -Raw -LiteralPath (Join-Path $resolvedRoot "references/triage/triage-checklist.md") -Encoding UTF8

    Assert-ContainsAll $skill @(
        "references/integration/workbench-surface.md",
        "only when a Task may continue across chat, a workbench panel, or another agent surface",
        "references/integration/skilldock-surface.md",
        "chart, evidence table, artifact", "explicit surface intents",
        "channel IDs", "context files"
    ) "SKILL.md surface routing"
    Assert-ContainsAll $skill @(
        "never synthesize a separate Runtime launch command",
        "never show raw JSON or a panel component tree",
        "Do not create, fork, attach, or resume another Thread",
        "Thread-binding mismatch must fail closed"
    ) "SKILL.md SkillDock execution boundary"
    Assert-ContainsAll $agentInterface @(
        "launch-panel.ps1"
    ) "DSH interface SkillDock boundary"
    Assert-ContainsAll $surface @(
        "[workbench-runtime.md](workbench-runtime.md)"
    ) "Installed runtime route"
    Assert-ContainsAll $runtimeDoc @(
        "workbench.manifest.json", "runtime.mjs",
        "Skill ID and version", 'schema version `1.0`',
        "must remain inside it", "read-only-supervised",
        "telemetry.csv.analyze", "does not contain Agent transport",
        "host-supplied runtime directory", 'installed `scripts/`',
        "scripts/skilldock/launch-panel.ps1"
    ) "Installed runtime documentation"
    Assert-ContainsAll $skilldock @(
        "current Agent workspace", "starts or reuses one loopback runtime",
        "User-facing intent", "channel_id", "cursor", "JSON file",
        "explicit launch phrase",
        "Do not rerun the device collector",
        "independent panel-owned Agent Session",
        "Never claim the graph is open", "Chat context handoff",
        "Returning to chat", "channel_id", "sync-panel.ps1",
        "not native attachment", "SurfaceMode", "ReplaceWorkspace",
        "runtime_state", "approval_decision_supported",
        "Do not reconstruct the Runtime launch",
        "without starting or rewriting it",
        "display_summary", "Never paste the raw JSON or component tree",
        "already in sync", "pchw-source-hosted", "submit-panel-result.ps1",
        "error_code", "environment variables or test flags",
        "attachments", "private absolute path", "prefilled",
        "wait-panel.ps1", "panel_wait_timeout", "phase_not_submittable",
        "source_agent_pulled", "cycle_generation",
        "ExpectedAttachmentSha256", "ExpectedSubmissionSequence",
        "panel_sync_stale_result", "stale",
        "thread_binding_mismatch", "thread_rebinding_forbidden",
        "source_attachment_id", "恢复当前 Task",
        "Windows ShellExecute", "runtime_access_blocked",
        "interactive_desktop_unavailable"
    ) "SkillDock-triggered surface"
    Assert-ContainsAll $skilldockLauncher @(
        "--ensure", "--workspace", "launch-result.json",
        "ChatContextFile", "task/sync/import",
        "Invoke-RestMethod", "capability token", "ReplaceWorkspace",
        "--replace-workspace", "PANEL_SURFACE_MODE", "surface_mode",
        "agent_permission", "permission_matrix", "approval_decision_supported",
        "runtime-paths.ps1", "ConvertTo-Json -Compress -Depth 8",
        "pchw-source-hosted", "source-hosted/entry", "source_session_ref",
        "channel_id", "error_code", "fallback_reason",
        "SKILLDOCK_AGENT_DRIVER", "SKILLDOCK_INTERNAL_PREVIEW",
        "Resolve-ContextAttachment", "/api/attachments",
        "CODEX_THREAD_ID", "thread_binding_mismatch",
        "X-Source-Attachment-Id", "source_attachment_id",
        "RuntimeLaunchId", "runtime_binding", "runtime_launch_id",
        "RuntimeMetadataState", "IgnoredRuntimeMetadata",
        "Assert-SkillDockLocalRootWritable",
        "Open-InteractiveDesktopUrl", 'Join-Path $env:WINDIR "explorer.exe"',
        "-FilePath $explorerPath", "-ArgumentList $quotedUrl",
        "New-BrowserHandoffProbe", "Wait-BrowserHandoffAcknowledgement",
        "New-ManualBrowserOpenFile", "Stop-LaunchPanelRuntime",
        "manual_open_required", "manual_open_url", "manual_open_file",
        "runtime_access_blocked", "interactive_desktop_unavailable"
    ) "SkillDock launcher boundary"
    Assert-True (
        $skilldockLauncher -notmatch "msedge\.exe"
    ) "SkillDock launcher must not start Edge directly from the sandbox."
    Assert-ContainsAll $skilldockSync @(
        "ChannelId", "AfterSequence", "task/sync/export",
        "Invoke-SourceHostedResultClaim",
        "source-capability-token", "X-Source-Session-Ref",
        "pchw-source-hosted", "ConvertTo-Json", "display_summary",
        "ExpectedTaskId", "ExpectedAttachmentId",
        "ExpectedAttachmentSha256", "ExpectedSubmissionSequence",
        "panel_sync_stale_result", "source-result-freshness",
        "claim_result_stale"
    ) "SkillDock return-sync boundary"
    Assert-ContainsAll $skilldockSubmit @(
        "ChannelId", "SourceSessionRef", "PanelFile", "MessageText",
        "source-capability-token", "task/sync/import",
        "X-Source-Session-Ref", "shared_task_phase"
    ) "SkillDock source-result writeback boundary"
    Assert-ContainsAll $skilldockWait @(
        "ChannelId", "SourceSessionRef", "source-capability-token",
        "X-Source-Session-Ref", "source_tool_result", "panel_wait_timeout",
        "ExpectedTaskId", "ExpectedAttachmentId",
        "ExpectedAttachmentSha256", "ExpectedSubmissionSequence",
        "stale_result_observed", "source-result-freshness", "ConvertTo-Json",
        "Invoke-SourceHostedResultClaim", "panel_wait_claim_failed"
    ) "SkillDock source-result wait boundary"
    Assert-ContainsAll $skilldockRuntimePaths @(
        "SKILLDOCK_LOCAL_ROOT", "runtime-pchw", "runtime-dsh-web",
        "Get-SkillDockRuntimeContext", "launch-result.json",
        "runtime_binding", "ignored_server_info"
    ) "SkillDock shared runtime path resolver"
    foreach ($runtimeScript in @(
        $skilldockLauncher,
        $skilldockSync,
        $skilldockWait,
        $skilldockSubmit
    )) {
        Assert-True `
            ($runtimeScript -match 'runtime-paths\.ps1') `
            "SkillDock runtime script does not load runtime-paths.ps1."
        Assert-True `
            ($runtimeScript -notmatch 'runtime-dsh-web|runtime-pchw') `
            "SkillDock runtime script hard-codes a runtime data root."
        Assert-True `
            ($runtimeScript -notmatch 'server-info\.json') `
            "SkillDock runtime script directly trusts server-info.json."
    }
    Assert-ContainsAll $skilldockFreshness @(
        "ExpectedTaskId", "ExpectedAttachmentId",
        "ExpectedAttachmentSha256", "ExpectedSubmissionSequence",
        "ExpectedIntentEventId", "stale_source_result",
        "fresh_source_result", "result_after_submission",
        "task/sync/claim", "Invoke-SourceHostedResultClaim"
    ) "SkillDock source-result freshness boundary"

    $envelope = Get-MarkdownSection $closure "Result envelope"
    Assert-True (-not [string]::IsNullOrWhiteSpace($envelope)) "The result-envelope contract is missing."
    Assert-ContainsAll $envelope @(
        "status", "judgement", "evidence", "conflict", "uncertainty",
        "recommendations", "priority_action", "artifact_refs",
        "not a response template", "concept question", "one or two paragraphs",
        "two concise paragraphs", "at most two or three", "Omit empty fields",
        "proposition in one place"
    ) "Result-envelope projection"

    $resumeProjection = Get-MarkdownSection $closure "Resume projection"
    Assert-ContainsAll $resumeProjection @(
        "continuity state, not a routine response",
        "only for an ongoing Task", "Do not show one for a concept answer",
        "machine packet", "user-visible content separate",
        "one priority action",
        "Omit the raw transcript", "capability tokens", "handoff secrets",
        "signing or TTL details", "nonces", "absolute private paths",
        "independent continuation", "same conversation"
    ) "Resume projection"

    $views = Get-MarkdownSection $surface "One task, several views"
    Assert-ContainsAll $views @(
        "Task", "Thread", "surface", "not interchangeable",
        "new problem", "new Task inside the current", "Do not create a new Codex thread",
        "Device records and the Evidence Store are shared across Tasks"
    ) "Task/Thread/surface separation"

    $resume = Get-MarkdownSection $surface "Task state and Resume Packet"
    Assert-ContainsAll $resume @(
        "simple concept answer", "does not", "Resume Packet",
        "Task ID and goal", "Objective", "Device-store reference and capture date",
        "Evidence IDs, hashes", "Current judgement", "Uncertainty",
        "Priority action", "Artifact references", "Surface preference",
        "Machine-side references need not", "redacted projection",
        "absolute private paths", "capability tokens", "handoff signing material",
        "HMAC/TTL details", "nonces"
    ) "Resume Packet"

    $entering = Get-MarkdownSection $surface "Entering a surface from chat"
    Assert-ContainsAll $entering @(
        "carry the abstract Resume Packet",
        "same Task, device snapshot, evidence",
        "Do not repeat device intake", "rerun the collector", "reanalyze",
        "Task Resume fallback", "independent continuation",
        "source conversation was not taken over or attached",
        "connected to the current chat", "same conversation",
        "destination may already use its own execution thread",
        "switch itself does not create a new Codex thread or Task",
        "never creates permission"
    ) "Chat-to-surface entry"

    $returning = Get-MarkdownSection $surface "Returning to chat from a workbench surface"
    Assert-ContainsAll $returning @(
        "compact, sanitized Resume summary", "copy", "Task identity and objective",
        "device label, snapshot date", "relevant evidence IDs or labels",
        "current judgement", "one unresolved question", "one priority action",
        "return instruction", "Do not copy the full chat",
        "secrets or private filesystem paths", "do not claim it has returned"
    ) "Return-to-chat summary"

    $transport = Get-MarkdownSection $surface "Handoff transport boundary"
    Assert-ContainsAll $transport @(
        "does not own or implement", "capability tokens", "HMAC signing",
        "TTL and nonce handling", "app-server thread ownership", "queue delivery",
        "Source/return-target and execution-context identifiers",
        "do not establish", "thread ownership",
        "Queueing is not a default handoff", "Do not enqueue",
        "one-way queue with unknown reply visibility", "enqueue success is not delivery",
        "Task continuity can survive without thread attachment"
    ) "Handoff transport boundary"

    $selection = Get-MarkdownSection $surface "Surface selection"
    Assert-ContainsAll $selection @(
        "auto", "chat-first", "panel-first",
        "presentation preferences", "never lock", "experimental", "protocol"
    ) "Surface selection"

    $permissions = Get-MarkdownSection $surface "Permissions and execution"
    Assert-ContainsAll $permissions @(
        "share the current user permission boundary",
        "Read-only supervised", "Artifact write", "Controlled execution",
        "Network", "Full access", "BIOS or",
        "firmware or driver installation", "clocks, voltages, power limits",
        "A supervised user performs any"
    ) "Permission tiers"

    $artifacts = Get-MarkdownSection $surface "Attachments and artifacts"
    Assert-ContainsAll $artifacts @(
        "surface owns file picking, upload, transport",
        "Telemetry", "Log or export", "Visual evidence",
        "Inventory or profile", "Derived artifact",
        "capture time", "SHA-256", "Evidence ID and hash",
        "never upload private evidence automatically"
    ) "Attachment semantics"

    Assert-ContainsAll $triage @(
        "Build an internal decision set",
        "Do not render that set as a mandatory multi-section answer",
        "result-envelope projection"
    ) "Triage decision projection"

    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $caseScript = Join-Path $resolvedRoot "scripts/hardware-case.ps1"
    $caseDirectory = Join-Path $tempRoot "case"
    $caseFile = & $caseScript -Action New `
        -CasePath $caseDirectory `
        -DeviceAlias "Surface test device" `
        -Platform "Windows fixture" `
        -Goal "Verify traceable evidence references"

    $evidencePath = Join-Path $tempRoot "telemetry.csv"
    [IO.File]::WriteAllText(
        $evidencePath,
        "Time,FPS`r`n0,60`r`n1,59`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $expectedHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
    $evidenceId = & $caseScript -Action AddEvidence `
        -CasePath $caseFile `
        -EvidenceType telemetry `
        -EvidencePath $evidencePath `
        -EvidenceCapturedAt "2026-11-15T12:00:00+08:00" `
        -Summary "Traceable telemetry reference" `
        -ImportArtifact

    $case = Get-Content -Raw -LiteralPath $caseFile -Encoding UTF8 | ConvertFrom-Json
    $storedEvidence = @($case.evidence)[0]
    Assert-True ($storedEvidence.Id -eq $evidenceId) "The evidence ID is not stable in the case record."
    Assert-True ($storedEvidence.Sha256 -eq $expectedHash) "The imported artifact hash does not match its source."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$storedEvidence.ImportedPath)) "The imported artifact has no relative case reference."
    Assert-True (Test-Path -LiteralPath (Join-Path $caseDirectory ([string]$storedEvidence.ImportedPath)) -PathType Leaf) "The imported artifact reference does not resolve inside the case."
    Assert-True ($null -eq $storedEvidence.SourcePath) "An imported artifact retained its private source path."
    $resumeText = (& $caseScript -Action Resume -CasePath $caseFile | Out-String)
    Assert-True ($resumeText -match [regex]::Escape($evidenceId)) "Resume omitted the traceable evidence ID."

    if ($failures.Count -gt 0) {
        Write-Host "Workbench surface contract: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "Workbench surface contract: PASS"
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
