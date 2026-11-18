[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [string]$LauncherPath = $env:SKILLDOCK_LAUNCHER,

    [string]$ChatContextFile = "",

    [switch]$NoBrowser,

    [ValidateSet("pchw-source-hosted", "legacy")]
    [string]$SurfaceProfile = "pchw-source-hosted",

    [string]$SourceSessionRef = "",

    [ValidateSet("read-only", "interactive", "developer")]
    [string]$SurfaceMode = "read-only",

    [switch]$ReplaceWorkspace,

    [ValidateRange(5, 120)]
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $Utf8NoBom
$OutputEncoding = $Utf8NoBom
. (Join-Path $PSScriptRoot "runtime-paths.ps1")
$failureCode = "surface_unavailable"
$browserHandoff = ""
$runtimeStartedHere = $false
$localRoot = ""
$manualOpenRequired = $false
$manualOpenUrl = ""
$manualOpenFile = ""

function Write-JsonResult {
    param(
        [bool]$Ok,
        [string]$Url = "",
        [string]$ResolvedWorkspace = "",
        [string]$Driver = "",
        [string]$TaskRef = "",
        [int]$Cursor = 0,
        [string]$RuntimeState = "",
        [string]$SelectedSurfaceMode = "",
        [string]$ResolvedSourceSessionRef = "",
        [string]$ChannelId = "",
        [string]$RuntimeLaunchId = "",
        [int]$RuntimePid = 0,
        [int]$RuntimePort = 0,
        [string]$RuntimeOrigin = "",
        [string]$RuntimeDataDirectory = "",
        [string]$RuntimeMetadataState = "",
        [string[]]$IgnoredRuntimeMetadata = @(),
        [bool]$ManualOpenRequired = $false,
        [string]$ManualOpenUrl = "",
        [string]$ManualOpenFile = "",
        [object]$AgentPermission = $null,
        [object]$PermissionMatrix = $null,
        [bool]$ApprovalDecisionSupported = $false,
        [string]$BrowserHandoff = "",
        [string[]]$Limitations = @(),
        [string]$ErrorCode = "",
        [string]$FallbackReason = "",
        [string]$ErrorMessage = ""
    )

    [pscustomobject]@{
        ok = $Ok
        url = $Url
        workspace = $ResolvedWorkspace
        driver = $Driver
        task_ref = $TaskRef
        cursor = $Cursor
        runtime_state = $RuntimeState
        surface_mode = $SelectedSurfaceMode
        source_session_ref = $ResolvedSourceSessionRef
        channel_id = $ChannelId
        runtime_launch_id = $RuntimeLaunchId
        runtime_pid = $RuntimePid
        runtime_port = $RuntimePort
        runtime_origin = $RuntimeOrigin
        runtime_data_directory = $RuntimeDataDirectory
        runtime_metadata_state = $RuntimeMetadataState
        ignored_runtime_metadata = @($IgnoredRuntimeMetadata)
        manual_open_required = $ManualOpenRequired
        manual_open_url = $ManualOpenUrl
        manual_open_file = $ManualOpenFile
        agent_permission = $AgentPermission
        permission_matrix = $PermissionMatrix
        approval_decision_supported = $ApprovalDecisionSupported
        browser_handoff = $BrowserHandoff
        limitations = @($Limitations)
        error_code = $ErrorCode
        fallback_reason = $FallbackReason
        error = $ErrorMessage
    } | ConvertTo-Json -Compress -Depth 8
}

function Get-RunningSkillDockRuntime {
    param([string]$LocalRoot)

    $context = Get-SkillDockRuntimeContext -LocalRoot $LocalRoot
    if ($null -eq $context) {
        return $null
    }
    return [pscustomobject]@{
        ok = $true
        url = $context.url
        port = [int]$context.binding.port
        driver = [string]$context.health.driver
        workspace = [string]$context.health.workspace
        pid = [int]$context.binding.pid
        launch_id = [string]$context.binding.launch_id
        origin = [string]$context.binding.origin
        runtime_directory = $context.runtime_directory
        metadata_state = $context.metadata_state
        ignored_server_info = @($context.ignored_server_info)
        exact_url = "http://127.0.0.1:$([int]$context.binding.port)/?runtime_launch_id=$([Uri]::EscapeDataString([string]$context.binding.launch_id))&runtime_pid=$([int]$context.binding.pid)&runtime_port=$([int]$context.binding.port)"
    }
}

function Add-RuntimeBindingToUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][object]$Binding
    )

    $separator = if ($Url.Contains("?")) { "&" } else { "?" }
    return "$Url$separator" +
        "runtime_launch_id=$([Uri]::EscapeDataString([string]$Binding.launch_id))" +
        "&runtime_pid=$([int]$Binding.pid)" +
        "&runtime_port=$([int]$Binding.port)"
}

function Get-StableTaskId {
    param([Parameter(Mandatory = $true)][string]$SourceSessionRef)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($SourceSessionRef.ToLowerInvariant())
        $hash = $sha.ComputeHash($bytes)
        $suffix = (($hash | Select-Object -First 16) | ForEach-Object {
            $_.ToString("x2")
        }) -join ""
        return "task-pchw-$suffix"
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        $bytes = $sha.ComputeHash($stream)
        return (($bytes | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-AttachmentMimeType {
    param([Parameter(Mandatory = $true)][string]$Extension)

    switch ($Extension.ToLowerInvariant()) {
        ".csv" { return "text/csv" }
        ".txt" { return "text/plain" }
        ".log" { return "text/plain" }
        ".json" { return "application/json" }
        ".png" { return "image/png" }
        ".jpg" { return "image/jpeg" }
        ".jpeg" { return "image/jpeg" }
        ".webp" { return "image/webp" }
        default { return "" }
    }
}

function Resolve-ContextAttachment {
    param([Parameter(Mandatory = $true)][object]$Attachment)

    $path = [string]$Attachment.path
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw "A current-chat attachment path is missing."
    }
    $resolved = (Resolve-Path -LiteralPath $path -ErrorAction Stop).Path
    $item = Get-Item -LiteralPath $resolved -Force
    if ($item.PSIsContainer) {
        throw "Current-chat attachment is not a file."
    }
    if ($item.Length -le 0 -or $item.Length -gt 8MB) {
        throw "Current-chat attachment is empty or exceeds 8 MB."
    }
    $extension = $item.Extension.ToLowerInvariant()
    $mime = if (-not [string]::IsNullOrWhiteSpace(
        [string]$Attachment.mime_type
    )) {
        [string]$Attachment.mime_type
    }
    else {
        Get-AttachmentMimeType -Extension $extension
    }
    if ([string]::IsNullOrWhiteSpace($mime)) {
        throw "Current-chat attachment type is not supported."
    }
    $name = [string]$Attachment.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $item.Name
    }
    $name = [IO.Path]::GetFileName($name).Replace("`"", "_")
    $sha256 = Get-FileSha256Hex -Path $resolved
    $sourceAttachmentId = [string]$Attachment.source_attachment_id
    if ([string]::IsNullOrWhiteSpace($sourceAttachmentId)) {
        $sourceAttachmentId = "chat-file:$sha256"
    }
    return [pscustomobject]@{
        path = $resolved
        name = $name
        mime_type = $mime
        size = [long]$item.Length
        sha256 = $sha256
        source_attachment_id = $sourceAttachmentId
    }
}

function Send-SkillDockAttachment {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RuntimeToken,
        [Parameter(Mandatory = $true)][object]$Attachment
    )

    $boundary = "----SkillDock$([guid]::NewGuid().ToString('N'))"
    $prefix = (
        "--$boundary`r`n" +
        "Content-Disposition: form-data; name=`"file`"; " +
        "filename=`"$($Attachment.name)`"`r`n" +
        "Content-Type: $($Attachment.mime_type)`r`n`r`n"
    )
    $suffix = "`r`n--$boundary--`r`n"
    $prefixBytes = [Text.Encoding]::UTF8.GetBytes($prefix)
    $fileBytes = [IO.File]::ReadAllBytes([string]$Attachment.path)
    $suffixBytes = [Text.Encoding]::UTF8.GetBytes($suffix)
    $stream = New-Object IO.MemoryStream
    try {
        $stream.Write($prefixBytes, 0, $prefixBytes.Length)
        $stream.Write($fileBytes, 0, $fileBytes.Length)
        $stream.Write($suffixBytes, 0, $suffixBytes.Length)
        $result = Invoke-RestMethod `
            -Uri "$($BaseUrl.TrimEnd('/'))/api/attachments" `
            -Method Post `
            -Headers @{
                Authorization = "Bearer $RuntimeToken"
                "X-Source-Attachment-Id" = [string]$Attachment.source_attachment_id
            } `
            -ContentType "multipart/form-data; boundary=$boundary" `
            -Body $stream.ToArray() `
            -TimeoutSec 30
    }
    finally {
        $stream.Dispose()
    }
    $matchingAttachments = @()
    foreach ($candidate in (
        @($result.draft.attachments) +
        @($result.task.attachments)
    )) {
        if (
            [string]::Equals(
                [string]$candidate.sha256,
                [string]$Attachment.sha256,
                [StringComparison]::OrdinalIgnoreCase
            ) -and
            (
                [string]::IsNullOrWhiteSpace(
                    [string]$candidate.source_attachment_id
                ) -or
                [string]::Equals(
                    [string]$candidate.source_attachment_id,
                    [string]$Attachment.source_attachment_id,
                    [StringComparison]::OrdinalIgnoreCase
                )
            )
        ) {
            $matchingAttachments += $candidate
        }
    }
    if ($matchingAttachments.Count -lt 1) {
        $draftCount = if ($result.draft) {
            @($result.draft.attachments).Count
        }
        else {
            0
        }
        $taskCount = if ($result.task) {
            @($result.task.attachments).Count
        }
        else {
            0
        }
        $draftSha = if ($draftCount -gt 0) {
            [string]$result.draft.attachments[0].sha256
        }
        else {
            ""
        }
        $draftSource = if ($draftCount -gt 0) {
            [string]$result.draft.attachments[0].source_attachment_id
        }
        else {
            ""
        }
        throw (
            "SkillDock did not accept a current-chat attachment " +
            "(draft=$draftCount task=$taskCount sha=$($Attachment.sha256) " +
            "source=$($Attachment.source_attachment_id) " +
            "draftSha=$draftSha draftSource=$draftSource)."
        )
    }
}

function Open-SourceHostedBootstrap {
    param([Parameter(Mandatory = $true)][string]$Url)

    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = "GET"
    $request.AllowAutoRedirect = $false
    $request.Timeout = 10000
    $response = $null
    try {
        $response = $request.GetResponse()
    }
    catch [Net.WebException] {
        $response = $_.Exception.Response
    }
    if (-not $response) {
        throw "Source-hosted bootstrap did not return a response."
    }
    $statusCode = [int]$response.StatusCode
    $response.Close()
    if ($statusCode -ne 303) {
        throw "Source-hosted bootstrap did not bind the Task."
    }
}

function Assert-SkillDockLocalRootWritable {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)

    $probePath = Join-Path `
        $LocalRoot `
        (".skilldock-write-probe-" + [guid]::NewGuid().ToString("N"))
    try {
        [IO.Directory]::CreateDirectory($LocalRoot) | Out-Null
        $stream = [IO.File]::Open(
            $probePath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes("probe")
            $stream.Write($bytes, 0, $bytes.Length)
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        $failureCode = "runtime_access_blocked"
        throw (
            "SkillDock runtime data directory is not writable: $LocalRoot. " +
            "Continue in chat or use an explicitly approved writable portable " +
            "data root."
        )
    }
    finally {
        if ([IO.File]::Exists($probePath)) {
            [IO.File]::Delete($probePath)
        }
    }
}

function Add-UrlQueryParameter {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    $separator = if ($Url.Contains("?")) { "&" } else { "?" }
    return "$Url$separator$([Uri]::EscapeDataString($Name))=$([Uri]::EscapeDataString($Value))"
}

function New-BrowserHandoffProbe {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RuntimeToken
    )

    $probe = Invoke-RestMethod `
        -Uri "$($BaseUrl.TrimEnd('/'))/api/browser-handoff/probe" `
        -Method Post `
        -Headers @{ Authorization = "Bearer $RuntimeToken" } `
        -ContentType "application/json; charset=utf-8" `
        -Body "{}" `
        -TimeoutSec 10
    if (
        -not [bool]$probe.ok -or
        [string]::IsNullOrWhiteSpace([string]$probe.probe_id)
    ) {
        throw "SkillDock did not create a browser-handoff probe."
    }
    return [string]$probe.probe_id
}

function Wait-BrowserHandoffAcknowledgement {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$RuntimeToken,
        [Parameter(Mandatory = $true)][string]$ProbeId
    )

    $timeoutMilliseconds = 6000
    if ($env:SKILLDOCK_TEST_HANDOFF_TIMEOUT_MS -match '^\d+$') {
        $timeoutMilliseconds = [int]$env:SKILLDOCK_TEST_HANDOFF_TIMEOUT_MS
    }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMilliseconds)
    do {
        try {
            $status = Invoke-RestMethod `
                -Uri (
                    "$($BaseUrl.TrimEnd('/'))/api/browser-handoff/status" +
                    "?probe_id=$([Uri]::EscapeDataString($ProbeId))"
                ) `
                -Method Get `
                -Headers @{ Authorization = "Bearer $RuntimeToken" } `
                -TimeoutSec 5
            if ([string]$status.status -eq "acknowledged") {
                return
            }
        }
        catch {
            # The page may still be starting or the probe may have expired.
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw (
        "SkillDock browser handoff was not acknowledged by the panel page " +
        "within $timeoutMilliseconds ms."
    )
}

function New-ManualBrowserOpenFile {
    param(
        [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$ProbeId
    )

    $handoffDirectory = Join-Path $RuntimeDirectory "browser-handoff"
    [IO.Directory]::CreateDirectory($handoffDirectory) | Out-Null
    $path = Join-Path $handoffDirectory "Open-SkillDock-$ProbeId.url"
    $content = (
        "[InternetShortcut]`r`n" +
        "URL=$Url`r`n"
    )
    [IO.File]::WriteAllText(
        $path,
        $content,
        [Text.Encoding]::ASCII
    )
    return $path
}

function Open-InteractiveDesktopUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $explorerPath = Join-Path $env:WINDIR "explorer.exe"
    if (-not (Test-Path -LiteralPath $explorerPath -PathType Leaf)) {
        throw "Windows Explorer is unavailable."
    }
    $quotedUrl = '"' + $Url.Replace('"', '\"') + '"'
    $process = Start-Process `
        -FilePath $explorerPath `
        -ArgumentList $quotedUrl `
        -PassThru `
        -ErrorAction Stop
    if ($null -eq $process) {
        throw "Windows Explorer did not accept the SkillDock URL."
    }
    if ($process.HasExited -and $process.ExitCode -ne 0) {
        throw (
            "Windows Explorer rejected the SkillDock URL with exit code " +
            "$($process.ExitCode)."
        )
    }
}

function Stop-LaunchPanelRuntime {
    param(
        [string]$LocalRoot,
        [string]$LaunchPanelLauncherPath
    )

    if (
        [string]::IsNullOrWhiteSpace($LocalRoot) -or
        [string]::IsNullOrWhiteSpace($LaunchPanelLauncherPath)
    ) {
        return
    }
    $previousLocalRoot = $env:SKILLDOCK_LOCAL_ROOT
    try {
        $env:SKILLDOCK_LOCAL_ROOT = $LocalRoot
        Start-Process `
            -FilePath $LaunchPanelLauncherPath `
            -ArgumentList @("--stop", "--silent") `
            -WindowStyle Hidden `
            -Wait `
            -ErrorAction Stop | Out-Null
    }
    catch {
        # Preserve the primary browser-handoff error.
    }
    finally {
        if ($null -eq $previousLocalRoot) {
            Remove-Item Env:SKILLDOCK_LOCAL_ROOT -ErrorAction SilentlyContinue
        }
        else {
            $env:SKILLDOCK_LOCAL_ROOT = $previousLocalRoot
        }
    }
}

try {
    $resolvedWorkspace = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedWorkspace -PathType Container)) {
        throw "Workspace is not a directory: $resolvedWorkspace"
    }

    if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
        $localRoot = Get-SkillDockLocalRoot
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
        $failureCode = "runtime_missing"
        throw "SkillDock Runtime is not installed."
    }

    $localRoot = Get-SkillDockLocalRoot
    $resultPath = Join-Path $localRoot "launch-result.json"
    $result = Get-RunningSkillDockRuntime -LocalRoot $localRoot
    if ($result) {
        if (
            $SurfaceProfile -eq "pchw-source-hosted" -and
            -not ([string]$result.driver).Equals(
                "source-external",
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $failureCode = "surface_profile_unavailable"
            throw "The running SkillDock surface uses $($result.driver), not the PCHW source-hosted profile."
        }
        $runningWorkspace = (
            Resolve-Path -LiteralPath $result.workspace -ErrorAction Stop
        ).Path
        if (
            -not $runningWorkspace.Equals(
                $resolvedWorkspace,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            if (-not $ReplaceWorkspace) {
                throw "SkillDock is already running for a different workspace: $runningWorkspace"
            }
            $result = $null
        }
    }

    if (-not $result -or -not $result.ok -or -not $result.url) {
        Assert-SkillDockLocalRootWritable -LocalRoot $localRoot
        $failurePath = Join-Path $localRoot "launch-failure.json"
        if (Test-Path -LiteralPath $failurePath -PathType Leaf) {
            Remove-Item -LiteralPath $failurePath -Force
        }
        if (Test-Path -LiteralPath $resultPath) {
            Remove-Item -LiteralPath $resultPath -Force
        }

        $quotedWorkspace = '"' + $resolvedWorkspace.Replace('"', '\"') + '"'
        $arguments = "--ensure --workspace $quotedWorkspace --silent"
        if ($NoBrowser -or $SurfaceProfile -eq "pchw-source-hosted") {
            $arguments += " --no-browser"
        }
        if ($ReplaceWorkspace) {
            $arguments += " --replace-workspace"
        }
        $profileVariables = @(
            "PANEL_SURFACE_MODE",
            "SKILLDOCK_AGENT_DRIVER",
            "SKILLDOCK_INTERNAL_PREVIEW",
            "SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK"
        )
        $previousEnvironment = @{}
        foreach ($name in $profileVariables) {
            $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable(
                $name,
                "Process"
            )
        }
        try {
            $env:PANEL_SURFACE_MODE = $SurfaceMode
            if ($SurfaceProfile -eq "pchw-source-hosted") {
                $env:SKILLDOCK_AGENT_DRIVER = "source-external"
                $env:SKILLDOCK_INTERNAL_PREVIEW = "1"
                $env:SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK = "1"
            }
            $runtimeStartedHere = $true
            $launcherProcess = Start-Process `
                -FilePath $LauncherPath `
                -ArgumentList $arguments `
                -WindowStyle Hidden `
                -PassThru
        }
        finally {
            foreach ($name in $profileVariables) {
                if ($null -eq $previousEnvironment[$name]) {
                    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
                }
                else {
                    Set-Item "Env:$name" $previousEnvironment[$name]
                }
            }
        }

        $failureCode = "launch_timeout"
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
            if (Test-Path -LiteralPath $failurePath -PathType Leaf) {
                try {
                    $failure = Get-Content `
                        -LiteralPath $failurePath `
                        -Raw |
                        ConvertFrom-Json
                    if (
                        $failure -and
                        -not [bool]$failure.ok -and
                        -not [string]::IsNullOrWhiteSpace(
                            [string]$failure.error_code
                        )
                    ) {
                        $failureCode = [string]$failure.error_code
                        throw (
                            "SkillDock launch failed with " +
                            "$failureCode`: $([string]$failure.error)"
                        )
                    }
                }
                catch {
                    if ($failureCode -ne "launch_timeout") {
                        throw
                    }
                }
            }
            if (
                $launcherProcess -and
                $launcherProcess.HasExited -and
                $launcherProcess.ExitCode -ne 0
            ) {
                throw (
                    "SkillDock launcher exited before producing a launch " +
                    "result (code $($launcherProcess.ExitCode))."
                )
            }
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $result -or -not $result.ok -or -not $result.url) {
            throw "SkillDock Runtime did not return a launch result within $TimeoutSeconds seconds."
        }
        $failureCode = "surface_unavailable"
    }
    $resultWorkspace = (Resolve-Path -LiteralPath $result.workspace -ErrorAction Stop).Path
    if (-not $resultWorkspace.Equals($resolvedWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
        throw "SkillDock Runtime returned a different workspace: $resultWorkspace"
    }
    $runtimeContext = Get-SkillDockRuntimeContext -LocalRoot $localRoot
    if ($null -eq $runtimeContext) {
        $failureCode = "runtime_unhealthy"
        throw "The current launch result and health Runtime binding are unavailable or inconsistent."
    }
    $result = $runtimeContext.result
    $health = $runtimeContext.health
    $runtimeBinding = $runtimeContext.binding
    $runtimeDirectory = $runtimeContext.runtime_directory
    $runtimeState = [string]$health.surface.runtime_state
    $selectedSurfaceMode = [string]$health.surface.mode
    $approvalDecisionSupported = [bool]$health.capabilities.supportsApprovalDecision
    $limitations = @($health.limitations)
    if (
        [string]::IsNullOrWhiteSpace($selectedSurfaceMode) -or
        -not $selectedSurfaceMode.Equals($SurfaceMode, [StringComparison]::OrdinalIgnoreCase)
    ) {
        $failureCode = "surface_mode_conflict"
        throw "The running SkillDock surface is $selectedSurfaceMode, not the requested $SurfaceMode. Stop or restart the runtime before changing modes."
    }
    if (
        $SurfaceProfile -eq "pchw-source-hosted" -and
        -not ([string]$health.driver).Equals(
            "source-external",
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        $failureCode = "surface_profile_unavailable"
        throw "SkillDock is not running the PCHW source-hosted profile."
    }

    $taskRef = ""
    $cursor = 0
    $resolvedSourceSessionRef = ""
    $channelId = ""
    $finalUrl = [string]$result.url
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
        $context = $contextBody | ConvertFrom-Json
        $tokenPath = Join-Path $runtimeDirectory "capability-token"
        if (-not (Test-Path -LiteralPath $tokenPath -PathType Leaf)) {
            $failureCode = "runtime_capability_unavailable"
            throw "SkillDock runtime token is unavailable."
        }
        $runtimeToken = (Get-Content -LiteralPath $tokenPath -Raw).Trim()
        if ($SurfaceProfile -eq "pchw-source-hosted") {
            $environmentThreadRef = [string]$env:CODEX_THREAD_ID
            $contextThreadRef = [string]$context.source_session_ref
            if ([string]::IsNullOrWhiteSpace($environmentThreadRef)) {
                $failureCode = "thread_binding_missing"
                throw "The current Codex environment Thread id is required."
            }
            if (
                -not [string]::IsNullOrWhiteSpace($SourceSessionRef) -and
                -not $SourceSessionRef.Equals(
                    $environmentThreadRef,
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $failureCode = "thread_binding_mismatch"
                throw "SourceSessionRef does not match the current Codex Thread."
            }
            if (
                -not [string]::IsNullOrWhiteSpace($contextThreadRef) -and
                -not $contextThreadRef.Equals(
                    $environmentThreadRef,
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $failureCode = "thread_binding_mismatch"
                throw "Chat context source_session_ref does not match the current Codex Thread."
            }
            $resolvedSourceSessionRef = $environmentThreadRef
            if (
                $resolvedSourceSessionRef -notmatch
                '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
            ) {
                $failureCode = "source_session_missing"
                throw "A valid current source Session reference is required."
            }
            $taskRef = Get-StableTaskId -SourceSessionRef $resolvedSourceSessionRef
            $domainState = if ($null -ne $context.domain_state) {
                $context.domain_state
            }
            else {
                [pscustomobject]@{}
            }
            $domainRefs = @($context.domain_refs | Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            })
            $contextAttachments = @()
            try {
                foreach ($attachment in @($context.attachments)) {
                    if ($null -ne $attachment) {
                        $contextAttachments += Resolve-ContextAttachment `
                            -Attachment $attachment
                    }
                }
            }
            catch {
                $failureCode = "attachment_invalid"
                throw
            }
            if ($contextAttachments.Count -gt 8) {
                $failureCode = "attachment_invalid"
                throw "At most eight current-chat attachments may be bridged."
            }
            $entryBody = [pscustomobject]@{
                task_id = $taskRef
                source_session_ref = $resolvedSourceSessionRef
                environment_thread_id = $env:CODEX_THREAD_ID
                objective = [string]$context.objective
                summary = [string]$context.summary
                domain_state = $domainState
                domain_refs = $domainRefs
                ttl_seconds = 600
            }
            $entryBytes = [Text.Encoding]::UTF8.GetBytes(
                ($entryBody | ConvertTo-Json -Depth 12 -Compress)
            )
            $requestEntry = {
                Invoke-RestMethod `
                    -Uri "$($result.url.TrimEnd('/'))/api/source-hosted/entry" `
                    -Method Post `
                    -Headers @{ Authorization = "Bearer $runtimeToken" } `
                    -ContentType "application/json; charset=utf-8" `
                    -Body $entryBytes `
                    -TimeoutSec 10
            }
            $entry = & $requestEntry
            if (
                -not $entry.ok -or
                [string]::IsNullOrWhiteSpace($entry.url) -or
                [string]::IsNullOrWhiteSpace($entry.task_ref)
            ) {
                $failureCode = "source_entry_failed"
                throw "SkillDock did not create the source-hosted panel entry."
            }
            if ($contextAttachments.Count -gt 0) {
                try {
                    Open-SourceHostedBootstrap -Url ([string]$entry.url)
                    foreach ($attachment in $contextAttachments) {
                        Send-SkillDockAttachment `
                            -BaseUrl ([string]$result.url) `
                            -RuntimeToken $runtimeToken `
                            -Attachment $attachment
                    }
                }
                catch {
                    $failureCode = "attachment_upload_failed"
                    throw
                }
                $entry = & $requestEntry
                if (
                    -not $entry.ok -or
                    [string]::IsNullOrWhiteSpace($entry.url) -or
                    [string]$entry.task_ref -ne $taskRef
                ) {
                    $failureCode = "source_entry_failed"
                    throw "SkillDock could not reopen the bridged Task."
                }
            }
            $taskRef = [string]$entry.task_ref
            $channelId = [string]$entry.channel_id
            $resolvedSourceSessionRef = [string]$entry.source_session_ref
            $bindingUrl = Add-RuntimeBindingToUrl `
                -Url ([string]$entry.url) `
                -Binding $runtimeBinding
            if (-not $NoBrowser) {
                try {
                    $probeId = New-BrowserHandoffProbe `
                        -BaseUrl ([string]$result.url) `
                        -RuntimeToken $runtimeToken
                    $finalUrl = Add-UrlQueryParameter `
                        -Url $bindingUrl `
                        -Name "handoff_probe" `
                        -Value $probeId
                    $manualOpenUrl = $finalUrl
                    $manualOpenFile = New-ManualBrowserOpenFile `
                        -RuntimeDirectory $runtimeDirectory `
                        -Url $manualOpenUrl `
                        -ProbeId $probeId
                    Open-InteractiveDesktopUrl -Url $finalUrl
                    Wait-BrowserHandoffAcknowledgement `
                        -BaseUrl ([string]$result.url) `
                        -RuntimeToken $runtimeToken `
                        -ProbeId $probeId
                    $browserHandoff = "windows-shell"
                }
                catch {
                    $failureCode = "interactive_desktop_unavailable"
                    $browserHandoff = "manual-required"
                    $manualOpenRequired = $true
                    throw
                }
            }
            else {
                $finalUrl = $bindingUrl
            }
        }
        else {
            $contextBytes = [Text.Encoding]::UTF8.GetBytes($contextBody)
            $imported = Invoke-RestMethod `
                -Uri "$($result.url.TrimEnd('/'))/api/task/sync/import" `
                -Method Post `
                -Headers @{ Authorization = "Bearer $runtimeToken" } `
                -ContentType "application/json; charset=utf-8" `
                -Body $contextBytes `
                -TimeoutSec 10
            if (-not $imported.ok -or [string]::IsNullOrWhiteSpace($imported.task_ref)) {
                $failureCode = "context_handoff_failed"
                throw "SkillDock did not accept the chat context handoff."
            }
            $taskRef = [string]$imported.task_ref
            $cursor = [int]$imported.cursor
        }
    }
    if (
        $SurfaceProfile -eq "pchw-source-hosted" -and
        [string]::IsNullOrWhiteSpace($taskRef)
    ) {
        $failureCode = "context_required"
        throw "The PCHW source-hosted profile requires compact chat context."
    }

    # Deliberately do not read or emit the runtime capability token.
    Write-JsonResult `
        -Ok $true `
        -Url $finalUrl `
        -ResolvedWorkspace $resultWorkspace `
        -Driver $result.driver `
        -TaskRef $taskRef `
        -Cursor $cursor `
        -RuntimeState $runtimeState `
        -SelectedSurfaceMode $selectedSurfaceMode `
        -ResolvedSourceSessionRef $resolvedSourceSessionRef `
        -ChannelId $channelId `
        -RuntimeLaunchId ([string]$runtimeBinding.launch_id) `
        -RuntimePid ([int]$runtimeBinding.pid) `
        -RuntimePort ([int]$runtimeBinding.port) `
        -RuntimeOrigin ([string]$runtimeBinding.origin) `
        -RuntimeDataDirectory $runtimeDirectory `
        -RuntimeMetadataState ([string]$runtimeContext.metadata_state) `
        -IgnoredRuntimeMetadata @($runtimeContext.ignored_server_info) `
        -AgentPermission $health.agent_permission `
        -PermissionMatrix $health.permission_matrix `
        -ApprovalDecisionSupported $approvalDecisionSupported `
        -BrowserHandoff $browserHandoff `
        -Limitations $limitations
}
catch {
    $errorMessage = [string]$_.Exception.Message
    if (
        -not [string]::IsNullOrWhiteSpace(
            [string]$_.ErrorDetails.Message
        )
    ) {
        $errorMessage = "$errorMessage $([string]$_.ErrorDetails.Message)"
    }
    if ($failureCode -eq "surface_unavailable") {
        $message = [string]$_.Exception.Message
        if ($message -match "already running for a different workspace") {
            $failureCode = "workspace_conflict"
        }
        elseif ($message -match "not the requested|not running the PCHW") {
            $failureCode = "surface_profile_unavailable"
        }
        elseif ($message -match "Runtime binding") {
            $failureCode = "runtime_binding_mismatch"
        }
        elseif ($message -match "did not return a launch result") {
            $failureCode = "launch_timeout"
        }
        elseif ($message -match "runtime data directory is not writable") {
            $failureCode = "runtime_access_blocked"
        }
        elseif ($message -match "Windows Explorer|ShellExecute|Windows Shell|Win32") {
            $failureCode = "interactive_desktop_unavailable"
        }
    }
    $fallbackReason = if (
        $failureCode -in @(
            "thread_binding_missing",
            "thread_binding_mismatch",
            "thread_rebinding_forbidden"
        )
    ) {
        "Continue in the current Codex conversation; do not create or switch Threads."
    }
    elseif ($failureCode -eq "runtime_access_blocked") {
        "Continue in chat; the default local runtime directory was not writable."
    }
    elseif ($failureCode -eq "interactive_desktop_unavailable") {
        if ($manualOpenRequired) {
            "Open the returned manual-open URL or .url shortcut to continue."
        }
        else {
            "Continue in chat; Windows did not confirm an interactive desktop handoff."
        }
    }
    elseif ($failureCode -eq "skill_runtime_mismatch") {
        "Continue in chat; the required PC Hardware Workbench Skill was not active."
    }
    else {
        "Continue in chat; the local surface was not confirmed open."
    }
    if (
        $failureCode -eq "interactive_desktop_unavailable" -and
        -not $manualOpenRequired -and
        $runtimeStartedHere
    ) {
        Stop-LaunchPanelRuntime `
            -LocalRoot $localRoot `
            -LaunchPanelLauncherPath $LauncherPath
    }
    Write-JsonResult `
        -Ok $false `
        -SelectedSurfaceMode $SurfaceMode `
        -ErrorCode $failureCode `
        -FallbackReason $fallbackReason `
        -BrowserHandoff $browserHandoff `
        -ManualOpenRequired $manualOpenRequired `
        -ManualOpenUrl $manualOpenUrl `
        -ManualOpenFile $manualOpenFile `
        -ErrorMessage $errorMessage
    exit 1
}
