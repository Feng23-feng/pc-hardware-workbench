[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [string]$VerificationPath = "",

    [string]$BuildReportPath = "",

    [switch]$AllowDirtyLocalCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha256.ComputeHash($stream)
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-NormalizedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    Write-Utf8Text -Path $Path -Text (
        $json.Replace("`r`n", "`n") + "`n"
    )
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullName
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    $resolvedFile = [IO.Path]::GetFullPath($FullName)
    if (
        -not $resolvedFile.StartsWith(
            $resolvedRoot + "\",
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Path escaped the extracted bundle: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

$resolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $resolvedArchive -PathType Leaf)) {
    throw "Acceptance archive is missing: $resolvedArchive"
}
$sidecarPath = "$resolvedArchive.sha256"
if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
    throw "Acceptance archive sidecar is missing: $sidecarPath"
}
$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $sidecarPath).Trim() -split "\s+"
)
if (
    $sidecarFields.Count -lt 1 -or
    $sidecarFields[0] -notmatch "^[a-f0-9]{64}$"
) {
    throw "Acceptance archive sidecar is malformed."
}
$actualArchiveSha256 = Get-FileSha256 -Path $resolvedArchive
$expectedArchiveSha256 = $sidecarFields[0].ToLowerInvariant()
if ($actualArchiveSha256 -ne $expectedArchiveSha256) {
    throw "Acceptance archive SHA-256 does not match its sidecar."
}

$tempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("skilldock-acceptance-verify-" + [guid]::NewGuid().ToString("N"))
$extractRoot = Join-Path $tempRoot "extract"
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

try {
    Expand-Archive `
        -LiteralPath $resolvedArchive `
        -DestinationPath $extractRoot `
        -Force
    $topLevelDirectories = @(
        Get-ChildItem -LiteralPath $extractRoot -Directory -Force
    )
    $topLevelFiles = @(
        Get-ChildItem -LiteralPath $extractRoot -File -Force
    )
    if (
        $topLevelDirectories.Count -ne 1 -or
        $topLevelFiles.Count -ne 0 -or
        $topLevelDirectories[0].Name -ne "SkillDockRC"
    ) {
        throw "Acceptance archive must contain exactly SkillDockRC at its root."
    }
    $bundleRoot = $topLevelDirectories[0].FullName
    $rootItems = @(Get-ChildItem -LiteralPath $bundleRoot -Force)
    $rootNames = @($rootItems | ForEach-Object Name | Sort-Object)
    $expectedRootNames = @(
        "payload",
        "README-ACCEPTANCE.txt",
        "Start-Acceptance.cmd"
    )
    if (
        @(Compare-Object `
            -ReferenceObject $expectedRootNames `
            -DifferenceObject $rootNames `
            -CaseSensitive).Count -ne 0 -or
        $rootItems.Count -ne 3
    ) {
        throw (
            "Acceptance root must contain exactly README-ACCEPTANCE.txt, " +
            "Start-Acceptance.cmd, and payload."
        )
    }
    foreach ($requiredRootFile in @(
        "README-ACCEPTANCE.txt",
        "Start-Acceptance.cmd"
    )) {
        if (-not (Test-Path -LiteralPath (
            Join-Path $bundleRoot $requiredRootFile
        ) -PathType Leaf)) {
            throw "Acceptance root file is missing: $requiredRootFile"
        }
    }
    $payloadRoot = Join-Path $bundleRoot "payload"
    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        throw "Acceptance payload directory is missing."
    }

    $rootCommand = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $bundleRoot "Start-Acceptance.cmd")
    if (
        $rootCommand -notmatch
            [regex]::Escape('payload\Start-Acceptance.ps1') -or
        $rootCommand -match 'SkillDock\.exe|SKILLDOCK_|PANEL_'
    ) {
        throw "Root Start-Acceptance.cmd does not expose the single safe entry."
    }

    $acceptanceReadme = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $bundleRoot "README-ACCEPTANCE.txt") `
        -Encoding UTF8
    if (
        $acceptanceReadme -notmatch "内部验收包" -or
        $acceptanceReadme -notmatch "不是普通用户安装包" -or
        $acceptanceReadme -notmatch "Start-Acceptance\.cmd"
    ) {
        throw "Acceptance root README does not identify the internal bundle."
    }

    $infoPath = Join-Path $payloadRoot "OUTER-BUNDLE-INFO.json"
    $info = Get-Content -Raw -LiteralPath $infoPath | ConvertFrom-Json
    if (
        [string]$info.outer_bundle_kind -ne "clean-windows-acceptance" -or
        [string]$info.boundaries.primary_entry -ne "Start-Acceptance.cmd" -or
        -not [bool]$info.boundaries.diagnostic_entries_under_payload_only -or
        [bool]$info.boundaries.real_thread_created_by_builder -or
        [bool]$info.boundaries.release_uploaded -or
        [string]$info.gates.formal_release -ne "not-performed"
    ) {
        throw "Acceptance bundle metadata violates its release boundaries."
    }
    if (
        [string]$info.gates.clean_windows_install_uninstall -ne "pending" -or
        [string]$info.gates.clean_ui_user_acceptance -ne "pending" -or
        [string]$info.gates.user_release_signoff -ne "pending"
    ) {
        throw "Acceptance bundle must not claim clean-Windows completion."
    }
    if (
        [string]$info.gates.commit -eq "local-uncommitted" -and
        -not $AllowDirtyLocalCandidate
    ) {
        throw "Dirty local acceptance candidate requires explicit allowance."
    }
    if (-not [string]::IsNullOrWhiteSpace($BuildReportPath)) {
        $resolvedBuildReport = [IO.Path]::GetFullPath($BuildReportPath)
        if (-not (Test-Path -LiteralPath $resolvedBuildReport -PathType Leaf)) {
            throw "Acceptance build report is missing."
        }
        $buildReport = Get-Content -Raw -LiteralPath $resolvedBuildReport |
            ConvertFrom-Json
        if (
            [string]$buildReport.status -ne "built-pending-verification" -or
            [string]$buildReport.archive_sha256 -ne $actualArchiveSha256
        ) {
            throw "Acceptance build report does not match the archive."
        }
    }

    $rcFile = [string]$info.rc_archive.file
    $rcSha256 = [string]$info.rc_archive.sha256
    $rcBytes = [int64]$info.rc_archive.bytes
    if (
        [string]::IsNullOrWhiteSpace($rcFile) -or
        $rcSha256 -notmatch "^[a-f0-9]{64}$"
    ) {
        throw "Acceptance bundle RC identity is incomplete."
    }
    $rcPath = Join-Path $payloadRoot $rcFile
    $rcSidecarPath = "$rcPath.sha256"
    if (
        -not (Test-Path -LiteralPath $rcPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $rcSidecarPath -PathType Leaf)
    ) {
        throw "Pinned RC archive or sidecar is missing."
    }
    if ((Get-Item -LiteralPath $rcPath).Length -ne $rcBytes) {
        throw "Pinned RC byte count differs from acceptance metadata."
    }
    if ((Get-FileSha256 -Path $rcPath) -ne $rcSha256) {
        throw "Pinned RC SHA-256 differs from acceptance metadata."
    }
    $rcSidecarFields = @(
        (Get-Content -Raw -LiteralPath $rcSidecarPath).Trim() -split "\s+"
    )
    if (
        $rcSidecarFields.Count -lt 1 -or
        $rcSidecarFields[0].ToLowerInvariant() -ne $rcSha256
    ) {
        throw "Pinned RC sidecar differs from acceptance metadata."
    }

    $forbiddenSegments = @(
        ".git",
        "node_modules",
        "tests"
    )
    $forbiddenBasenames = @(
        ".env",
        "capability-token",
        "handoff-secret",
        "launch-result.json",
        "panel-capability-token",
        "server-info.json",
        "source-capability-token",
        "Start-DSH-SkillDock.ps1",
        "Start-DSH-SkillDock-Dev.ps1",
        "agent-bridge-driver.mjs",
        "agent-bridge-host.mjs",
        "codex-agent-driver.mjs",
        "dsh-agent-driver.mjs",
        "dsh-web-agent-driver.mjs",
        "dsh-web-rpc-client.mjs",
        "mock-agent-driver.mjs",
        "open-workbench.mjs",
        "source-hosted-shadow.mjs"
    )
    $payloadFiles = @(
        Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force
    )
    $relativeFiles = New-Object System.Collections.Generic.List[string]
    foreach ($file in $payloadFiles) {
        $relativePath = Get-RelativePath `
            -Root $payloadRoot `
            -FullName $file.FullName
        $relativeFiles.Add($relativePath) | Out-Null
        $segments = $relativePath.Split("/")
        $basename = $segments[$segments.Count - 1]
        if (
            @($segments | Where-Object { $forbiddenSegments -contains $_ }).Count -gt 0 -or
            $forbiddenBasenames -contains $basename
        ) {
            throw "Forbidden acceptance payload entry: $relativePath"
        }
        if (
            $file.Extension -in @(
                ".txt",
                ".md",
                ".ps1",
                ".cmd",
                ".json",
                ".csv"
            )
        ) {
            $text = Get-Content `
                -Raw `
                -LiteralPath $file.FullName `
                -Encoding UTF8
            if ($text -match "C:\\Users\\28271") {
                throw "Personal absolute path remains in payload: $relativePath"
            }
            if (
                $text -match
                    "SKILLDOCK_INTERNAL_PREVIEW|Start-DSH-SkillDock|runtime-dsh-web"
            ) {
                throw "Development or DSH entry token remains: $relativePath"
            }
        }
    }

    $manifestPath = Join-Path $payloadRoot "BUNDLE-MANIFEST.sha256"
    $manifestLines = @(Get-Content -LiteralPath $manifestPath)
    $described = New-Object System.Collections.Generic.List[string]
    foreach ($line in $manifestLines) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            throw "Malformed acceptance manifest line: $line"
        }
        $expected = $Matches[1]
        $relativePath = $Matches[2]
        if (
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Split("/") -contains ".."
        ) {
            throw "Unsafe acceptance manifest path: $relativePath"
        }
        $path = Join-Path $payloadRoot $relativePath.Replace("/", "\")
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Acceptance manifest entry is missing: $relativePath"
        }
        if ((Get-FileSha256 -Path $path) -ne $expected) {
            throw "Acceptance manifest SHA-256 differs: $relativePath"
        }
        $described.Add($relativePath) | Out-Null
    }
    $expectedDescribed = @(
        $relativeFiles |
            Where-Object { $_ -ne "BUNDLE-MANIFEST.sha256" } |
            Sort-Object
    )
    if (
        @(Compare-Object `
            -ReferenceObject $expectedDescribed `
            -DifferenceObject @($described | Sort-Object) `
            -CaseSensitive).Count -ne 0
    ) {
        throw "Acceptance manifest does not describe the complete payload."
    }

    $validatorPath = Join-Path $payloadRoot "99-Validate-Bundle.ps1"
    $validatorOutput = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $validatorPath 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw (
            "Acceptance payload validator failed: " +
            (($validatorOutput | Out-String).Trim())
        )
    }
    if (
        (($validatorOutput | Out-String) -notmatch
            "Acceptance bundle validation: PASS")
    ) {
        throw "Acceptance payload validator did not return its PASS marker."
    }

    $verification = [ordered]@{
        schema_version = "1.0"
        status = "passed"
        release_id = [string]$info.release_id
        outer_bundle = [ordered]@{
            file = [IO.Path]::GetFileName($resolvedArchive)
            bytes = (Get-Item -LiteralPath $resolvedArchive).Length
            sha256 = $actualArchiveSha256
            sidecar_sha256 = $expectedArchiveSha256
            root_entries = $rootNames
            primary_entry = "Start-Acceptance.cmd"
        }
        payload = [ordered]@{
            file_count = $relativeFiles.Count
            manifest_entry_count = $described.Count
            diagnostics_under_payload = $true
        }
        rc = [ordered]@{
            file = $rcFile
            bytes = $rcBytes
            sha256 = $rcSha256
        }
        versions = $info.versions
        gates = [ordered]@{
            bundle_layout = "passed"
            bundle_manifest = "passed"
            rc_hash = "passed"
            forbidden_entry_scan = "passed"
            clean_windows_install_uninstall = "pending"
            clean_ui_user_acceptance = "pending"
            user_release_signoff = "pending"
            commit = [string]$info.gates.commit
            formal_release = "not-performed"
        }
        boundaries = [ordered]@{
            real_thread_created_by_verifier = $false
            release_uploaded = $false
            dsh_entry_exposed = $false
            manual_runner_entry_required = $false
        }
        build_report = if (
            [string]::IsNullOrWhiteSpace($BuildReportPath)
        ) {
            $null
        }
        else {
            [IO.Path]::GetFullPath($BuildReportPath)
        }
        verified_at = [DateTimeOffset]::UtcNow.ToString("o")
    }
    if (-not [string]::IsNullOrWhiteSpace($VerificationPath)) {
        Write-NormalizedJson `
            -Path ([IO.Path]::GetFullPath($VerificationPath)) `
            -Value $verification
    }
    [pscustomobject]@{
        ok = $true
        status = "passed"
        archive = $resolvedArchive
        archive_sha256 = $actualArchiveSha256
        rc_sha256 = $rcSha256
        payload_file_count = $relativeFiles.Count
        root_entries = $rootNames
        clean_windows_acceptance = "pending"
        formal_release = "not-performed"
        verification_path = if (
            [string]::IsNullOrWhiteSpace($VerificationPath)
        ) {
            $null
        }
        else {
            [IO.Path]::GetFullPath($VerificationPath)
        }
    } | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $resolvedTempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (
            $resolvedTemp.StartsWith(
                $resolvedTempBase,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}
