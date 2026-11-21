[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [string]$VerificationPath = "",

    [switch]$AllowDirtyLocalCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "skill-tree-identity.ps1")

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Sha256HexFromFile -Path $Path
}

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString(
            $sha256.ComputeHash($utf8.GetBytes($Text))
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Write-NormalizedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    $json = $json.Replace("`r`n", "`n") + "`n"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $json, $utf8)
}

function Get-PackageRelativePath {
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
        throw "Package path escaped its root: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

function Get-SortedOrdinal {
    param([object[]]$Values)

    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

$resolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $resolvedArchive -PathType Leaf)) {
    throw "RC archive is missing: $resolvedArchive"
}
$sidecarPath = "$resolvedArchive.sha256"
if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
    throw "RC SHA-256 sidecar is missing: $sidecarPath"
}
$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $sidecarPath).Trim() -split "\s+"
)
if ($sidecarFields.Count -lt 1 -or $sidecarFields[0] -notmatch "^[a-f0-9]{64}$") {
    throw "RC SHA-256 sidecar is malformed."
}
$expectedArchiveSha256 = $sidecarFields[0].ToLowerInvariant()
$actualArchiveSha256 = Get-FileSha256 -Path $resolvedArchive
if ($actualArchiveSha256 -ne $expectedArchiveSha256) {
    throw "RC archive SHA-256 does not match its sidecar."
}

$tempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("skilldock-rc-verify-" + [guid]::NewGuid().ToString("N"))
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
    if ($topLevelDirectories.Count -ne 1 -or $topLevelFiles.Count -ne 0) {
        throw "RC archive must contain exactly one top-level package directory."
    }
    $packageRoot = $topLevelDirectories[0].FullName
    $manifestPath = Join-Path $packageRoot "RC-MANIFEST.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "RC-MANIFEST.json is missing."
    }
    $manifestText = Get-Content -Raw -LiteralPath $manifestPath
    $manifest = $manifestText | ConvertFrom-Json
    $sourceStatePath = Join-Path $packageRoot "SOURCE-STATE.json"
    if (-not (Test-Path -LiteralPath $sourceStatePath -PathType Leaf)) {
        throw "SOURCE-STATE.json is missing."
    }
    $sourceState = Get-Content -Raw -LiteralPath $sourceStatePath |
        ConvertFrom-Json
    foreach ($entry in @(
        [pscustomobject]@{
            name = "release_id"
            expected = [string]$manifest.release_id
        },
        [pscustomobject]@{
            name = "head"
            expected = [string]$manifest.build_provenance.head
        },
        [pscustomobject]@{
            name = "branch"
            expected = [string]$manifest.build_provenance.branch
        },
        [pscustomobject]@{
            name = "dirty_entry_count"
            expected = [int]$manifest.build_provenance.dirty_entry_count
        },
        [pscustomobject]@{
            name = "git_status_sha256"
            expected =
                [string]$manifest.build_provenance.git_status_sha256
        },
        [pscustomobject]@{
            name = "pchw_repository_head"
            expected = [string]$manifest.build_provenance.pchw_repository_head
        },
        [pscustomobject]@{
            name = "pchw_repository_branch"
            expected =
                [string]$manifest.build_provenance.pchw_repository_branch
        },
        [pscustomobject]@{
            name = "pchw_repository_dirty_entry_count"
            expected =
                [int]$manifest.build_provenance.pchw_repository_dirty_entry_count
        },
        [pscustomobject]@{
            name = "pchw_repository_status_sha256"
            expected =
                [string]$manifest.build_provenance.pchw_repository_status_sha256
        },
        [pscustomobject]@{
            name = "source_pchw_tree_sha256"
            expected = [string]$manifest.pchw_skill.source_tree_sha256
        },
        [pscustomobject]@{
            name = "packaged_pchw_tree_sha256"
            expected = [string]$manifest.pchw_skill.tree_sha256
        },
        [pscustomobject]@{
            name = "builder_sha256"
            expected = [string]$manifest.build_provenance.builder_sha256
        }
    )) {
        $sourceValue = $sourceState.($entry.name)
        if ([string]$sourceValue -ne [string]$entry.expected) {
            throw (
                "SOURCE-STATE.json differs from RC-MANIFEST.json: " +
                $entry.name
            )
        }
    }
    if ([string]$manifest.build_provenance.head -notmatch "^[0-9a-f]{40}$") {
        throw "RC manifest does not record a full SkillDock commit SHA."
    }
    if (
        [string]$manifest.build_provenance.pchw_repository_head -notmatch
            "^[0-9a-f]{40}$"
    ) {
        throw "RC manifest does not record a full PCHW commit SHA."
    }
    if (
        -not $AllowDirtyLocalCandidate -and
        [int]$manifest.build_provenance.dirty_entry_count -ne 0 -or
        -not $AllowDirtyLocalCandidate -and
        [int]$manifest.build_provenance.pchw_repository_dirty_entry_count -ne 0
    ) {
        throw "RC provenance is dirty; only clean source checkouts may be packaged."
    }
    if ($topLevelDirectories[0].Name -ne [string]$manifest.package_basename) {
        if (
            $topLevelDirectories[0].Name -ne
            "SkillDock-PCHW-$([string]$manifest.release_id)-win-x64"
        ) {
            throw "Archive top-level directory does not match the release ID."
        }
    }
    $allowedReleaseStates = if ($AllowDirtyLocalCandidate) {
        @(
            "release-candidate-not-released",
            "local-candidate-clean-ui-pending",
            "release-candidate-prerelease"
        )
    }
    else {
        @(
            "release-candidate-not-released",
            "release-candidate-prerelease"
        )
    }
    if ([string]$manifest.release_state -notin $allowedReleaseStates) {
        throw "RC manifest has an unexpected release state."
    }
    if ([string]$manifest.gates.formal_release -ne "not-performed") {
        throw "RC manifest must not claim a formal release."
    }
    $allowedCommitStates = if ($AllowDirtyLocalCandidate) {
        @("local-only", "local-uncommitted")
    }
    else {
        @("local-only")
    }
    if ([string]$manifest.gates.commit -notin $allowedCommitStates) {
        throw "RC manifest has an unexpected local commit state."
    }
    foreach ($gateName in @("tag", "upload", "formal_release")) {
        if ([string]$manifest.gates.$gateName -ne "not-performed") {
            throw "RC manifest contains an unexpected completed gate: $gateName"
        }
    }
    if ([string]$manifest.boundaries.formal_default_entry -ne "closed") {
        throw "RC package must keep the formal default entry closed."
    }
    if ([string]$manifest.boundaries.default_traffic -ne "off") {
        throw "RC package must keep default traffic off."
    }
    foreach ($name in @(
        "dsh_observer_in_package",
        "fake_data_entry_in_package",
        "test_runner_in_package",
        "write_profile_in_package"
    )) {
        if ([bool]$manifest.boundaries.$name) {
            throw "RC boundary must remain false: $name"
        }
    }
    if (
        [string]$manifest.support.skilldock_panel_host -ne "codex" -or
        -not [bool]$manifest.support.panel_requires_codex_thread_id
    ) {
        throw "RC manifest does not declare the Codex-only panel host boundary."
    }
    $supportMatrixPath = Join-Path `
        $packageRoot `
        "docs\release\SUPPORT-MATRIX.md"
    if (-not (Test-Path -LiteralPath $supportMatrixPath -PathType Leaf)) {
        throw "Packaged support matrix is missing."
    }
    $supportMatrix = Get-Content `
        -Raw `
        -LiteralPath $supportMatrixPath `
        -Encoding UTF8
    if (
        $supportMatrix -notmatch "Codex" -or
        $supportMatrix -notmatch "thread_binding_missing" -or
        $supportMatrix -notmatch "DSH"
    ) {
        throw "Support matrix does not state the Codex-only panel boundary."
    }
    $componentMatrixPath = Join-Path `
        $packageRoot `
        "docs\COMPONENT-MATRIX.md"
    if (-not (Test-Path -LiteralPath $componentMatrixPath -PathType Leaf)) {
        throw "Packaged component and evidence matrix is missing."
    }
    $componentMatrix = Get-Content `
        -Raw `
        -LiteralPath $componentMatrixPath `
        -Encoding UTF8
    if (
        $componentMatrix -notmatch "2\.8\.0" -or
        $componentMatrix -notmatch "24\.22\.1" -or
        $componentMatrix -notmatch "Runtime-only"
    ) {
        throw "Component matrix is missing version or Runtime-only details."
    }

    $applicationPackage = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "app\package.json"
    ) | ConvertFrom-Json
    if (
        [string]$applicationPackage.version -ne
        [string]$manifest.application_version
    ) {
        throw "Packaged application version does not match RC-MANIFEST.json."
    }
    if (
        $null -ne $applicationPackage.PSObject.Properties["scripts"] -or
        $null -ne $applicationPackage.PSObject.Properties["devDependencies"]
    ) {
        throw "Packaged application metadata exposes test or development scripts."
    }

    $skillRoot = Join-Path $packageRoot "skills\pc-hardware-workbench"
    $skillIdentity = Get-SkillTreeIdentity -Root $skillRoot
    if (
        $skillIdentity.tree_sha256 -ne
            [string]$manifest.pchw_skill.tree_sha256 -or
        $skillIdentity.tree_file_count -ne
            [int]$manifest.pchw_skill.tree_file_count
    ) {
        throw "Packaged PCHW Skill identity does not match RC-MANIFEST.json."
    }
    $packagedSkillMarkdown = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $skillRoot "SKILL.md") `
        -Encoding UTF8
    if (
        $packagedSkillMarkdown -notmatch
            "version:\s*`"([^`"]+)`""
    ) {
        throw "Packaged PCHW SKILL.md has no metadata version."
    }
    $packagedSkillVersion = $Matches[1]
    $packagedWorkbenchManifest = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $skillRoot "workbench.manifest.json") `
        -Encoding UTF8 | ConvertFrom-Json
    if (
        $packagedSkillVersion -ne
            [string]$manifest.pchw_skill.version -or
        [string]$packagedWorkbenchManifest.skill.version -ne
            [string]$manifest.pchw_skill.version
    ) {
        throw "Packaged PCHW version metadata is inconsistent."
    }

    $nodeExecutable = Join-Path $packageRoot "node\node.exe"
    $nodeVersion = (
        & $nodeExecutable --version
    ).Trim()
    if ($nodeVersion -ne "v$([string]$manifest.bundled_node_version)") {
        throw "Bundled Node.js version does not match RC-MANIFEST.json."
    }

    $topLevelForbidden = @(
        ".git",
        "dist",
        "work",
        "node_modules",
        "runtime",
        "runtime-dsh-web",
        "tests",
        "agent-diagnostics"
    )
    $forbiddenAnywhere = @(
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
        "INSTALL-INFO.json",
        "agent-bridge-driver.mjs",
        "agent-bridge-host.mjs",
        "codex-agent-driver.mjs",
        "dsh-agent-driver.mjs",
        "dsh-web-agent-driver.mjs",
        "dsh-web-rpc-client.mjs",
        "mock-agent-driver.mjs",
        "open-workbench.mjs",
        "source-hosted-shadow.mjs",
        '$null',
        '$null)'
    )
    $forbidden = New-Object System.Collections.Generic.List[string]
    $relativeFiles = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $packageRoot -File -Recurse -Force
    )) {
        $relativePath = Get-PackageRelativePath `
            -Root $packageRoot `
            -FullName $file.FullName
        $relativeFiles.Add($relativePath)
        $segments = $relativePath.Split("/")
        $basename = $segments[$segments.Count - 1]
        if (
            $topLevelForbidden -contains $segments[0] -or
            @($segments | Where-Object { $forbiddenAnywhere -contains $_ }).Count -gt 0 -or
            $forbiddenBasenames -contains $basename
        ) {
            $forbidden.Add($relativePath)
        }
    }
    if ($forbidden.Count -gt 0) {
        throw "Forbidden package entries: $($forbidden -join ', ')"
    }
    foreach ($relativePath in @(
        "Start-DSH-SkillDock.ps1",
        "Start-DSH-SkillDock-Dev.ps1",
        "app\README.md",
        "integrations\skilldock\README.md"
    )) {
        if (Test-Path -LiteralPath (Join-Path $packageRoot $relativePath)) {
            throw "Development entry remains in RC: $relativePath"
        }
    }

    $releaseServerText = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "app\server.mjs"
    )
    if (
        $releaseServerText -match "sourceHostedShadow" -or
        $releaseServerText -match [regex]::Escape("/api/task/recover")
    ) {
        throw "Packaged server contains a shadow observer or recovery route."
    }
    $releaseAgentsText = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "app\lib\agents\index.mjs"
    )
    if (
        $releaseAgentsText -match "MockAgentDriver|DSHAgentDriver|AgentBridgeDriver|CodexAgentDriver"
    ) {
        throw "Packaged agent index references a development adapter."
    }
    $releasePermissionsText = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "app\lib\agent-permissions.mjs"
    )
    if (
        $releasePermissionsText -match
            "workspace-write|danger-full-access|interactive|developer"
    ) {
        throw "Packaged permission profile exposes write or developer modes."
    }
    $releaseSurfaceFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $packageRoot "app") `
            -File `
            -Recurse `
            -Include "*.mjs", "*.js", "*.json"
        Get-ChildItem -LiteralPath (
            Join-Path $packageRoot "integrations\skilldock"
        ) -File -Filter "*.ps1"
        Get-ChildItem -LiteralPath $packageRoot -File -Filter "*.ps1"
    )
    foreach ($surfaceFile in $releaseSurfaceFiles) {
        $surfaceText = Get-Content `
            -Raw `
            -LiteralPath $surfaceFile.FullName `
            -Encoding UTF8
        if (
            $surfaceText -cmatch
                "SKILLDOCK_INTERNAL_PREVIEW|SkillDock-DSH|DSH_HOME|DSH|DeepSeek|\.dsh|mock-agent-driver|dsh-agent-driver|agent-bridge-driver|open-workbench"
        ) {
            throw "Development entry token remains in package surface: $($surfaceFile.FullName)"
        }
    }

    $runtimePathHelpers = @(
        (Join-Path $packageRoot "runtime-paths.ps1"),
        (Join-Path $packageRoot "integrations\skilldock\runtime-paths.ps1"),
        (Join-Path `
            $packageRoot `
            "skills\pc-hardware-workbench\scripts\skilldock\runtime-paths.ps1")
    )
    foreach ($helperPath in $runtimePathHelpers) {
        if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
            throw "Packaged runtime path helper is missing: $helperPath"
        }
    }
    $helperHashes = @(
        $runtimePathHelpers |
            ForEach-Object {
                Get-TextSha256 -Text (
                    (Get-Content -Raw -LiteralPath $_ -Encoding UTF8).
                        Replace("`r`n", "`n").
                        Replace("`r", "`n")
                )
            } |
            Sort-Object -Unique
    )
    if ($helperHashes.Count -ne 1) {
        throw "Packaged runtime path helpers do not have matching content."
    }
    foreach ($requiredPath in @(
        "runtime-data-migration.ps1",
        "integrations\skilldock\launch-panel.ps1",
        "integrations\skilldock\sync-panel.ps1",
        "integrations\skilldock\wait-panel.ps1",
        "integrations\skilldock\submit-panel-result.ps1",
        "skills\pc-hardware-workbench\scripts\skilldock\launch-panel.ps1",
        "skills\pc-hardware-workbench\scripts\skilldock\sync-panel.ps1",
        "skills\pc-hardware-workbench\scripts\skilldock\wait-panel.ps1",
        "skills\pc-hardware-workbench\scripts\skilldock\submit-panel-result.ps1"
    )) {
        if (-not (Test-Path -LiteralPath (
            Join-Path $packageRoot $requiredPath
        ) -PathType Leaf)) {
            throw "Required runtime integration file is missing: $requiredPath"
        }
    }
    foreach ($scriptDirectory in @(
        (Join-Path $packageRoot "integrations\skilldock"),
        (Join-Path `
            $packageRoot `
            "skills\pc-hardware-workbench\scripts\skilldock")
    )) {
        foreach ($scriptName in @(
            "launch-panel.ps1",
            "sync-panel.ps1",
            "wait-panel.ps1",
            "submit-panel-result.ps1"
        )) {
            $scriptPath = Join-Path $scriptDirectory $scriptName
            $scriptText = Get-Content -Raw -LiteralPath $scriptPath
            if ($scriptText -match "runtime-dsh-web|runtime-pchw") {
                throw (
                    "SkillDock data-root name is hard-coded outside the " +
                    "shared resolver: $scriptPath"
                )
            }
            if ($scriptText -notmatch 'runtime-paths\.ps1') {
                throw "SkillDock script does not load runtime-paths.ps1: $scriptPath"
            }
            if ($scriptText -match "server-info\.json") {
                throw (
                    "SkillDock script directly trusts server-info.json: " +
                    $scriptPath
                )
            }
        }
    }

    $launcherFiles = @(
        $relativeFiles | Where-Object {
            [IO.Path]::GetFileName($_) -eq "SkillDock.exe"
        }
    )
    if (
        $launcherFiles.Count -ne 1 -or
        $launcherFiles[0] -ne "SkillDock.exe"
    ) {
        throw "RC package must contain exactly one top-level SkillDock.exe."
    }

    $packageManifest = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "PACKAGE-MANIFEST.json"
    ) | ConvertFrom-Json
    if ([int]$packageManifest.file_count -ne @($packageManifest.entries).Count) {
        throw "Package manifest file count is inconsistent."
    }
    foreach ($entry in @($packageManifest.entries)) {
        $relativePath = [string]$entry.path
        if (
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Split("/") -contains ".."
        ) {
            throw "Unsafe package manifest path: $relativePath"
        }
        $absolutePath = Join-Path $packageRoot ($relativePath.Replace("/", "\"))
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "Package manifest entry is missing: $relativePath"
        }
        if ((Get-Item -LiteralPath $absolutePath).Length -ne [int64]$entry.bytes) {
            throw "Package manifest byte count differs: $relativePath"
        }
        if ((Get-FileSha256 -Path $absolutePath) -ne [string]$entry.sha256) {
            throw "Package manifest SHA-256 differs: $relativePath"
        }
    }

    $manifestLines = @(
        Get-Content -LiteralPath (Join-Path $packageRoot "MANIFEST.sha256")
    )
    $describedFiles = New-Object System.Collections.Generic.List[string]
    foreach ($line in $manifestLines) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            throw "Malformed MANIFEST.sha256 line: $line"
        }
        $expectedSha256 = $Matches[1]
        $relativePath = $Matches[2]
        if (([string]$relativePath).Split("/") -contains "..") {
            throw "Unsafe MANIFEST.sha256 path: $relativePath"
        }
        $absolutePath = Join-Path $packageRoot ($relativePath.Replace("/", "\"))
        if (-not (Test-Path -LiteralPath $absolutePath -PathType Leaf)) {
            throw "MANIFEST.sha256 entry is missing: $relativePath"
        }
        if ((Get-FileSha256 -Path $absolutePath) -ne $expectedSha256) {
            throw "MANIFEST.sha256 digest differs: $relativePath"
        }
        $describedFiles.Add($relativePath)
    }
    $expectedDescribedFiles = @(
        $relativeFiles | Where-Object { $_ -ne "MANIFEST.sha256" }
    )
    $expectedDescribedSorted = Get-SortedOrdinal `
        -Values $expectedDescribedFiles
    $describedSorted = Get-SortedOrdinal -Values $describedFiles.ToArray()
    if (@(Compare-Object `
            -ReferenceObject $expectedDescribedSorted `
            -DifferenceObject $describedSorted `
            -CaseSensitive).Count -ne 0) {
        throw "MANIFEST.sha256 does not describe the complete package inventory."
    }

    $manifestTextLf = $manifestText.Replace("`r`n", "`n")
    $verification = [ordered]@{
        schema_version = "1.0"
        status = "passed"
        release_id = [string]$manifest.release_id
        package_basename = $topLevelDirectories[0].Name
        archive = [ordered]@{
            path = $resolvedArchive
            bytes = (Get-Item -LiteralPath $resolvedArchive).Length
            sha256 = $actualArchiveSha256
            sidecar_sha256 = $expectedArchiveSha256
        }
        package = [ordered]@{
            file_count = $relativeFiles.Count
            manifest_entry_count = @($packageManifest.entries).Count
            checksum_entry_count = $describedFiles.Count
            rc_manifest_sha256 = Get-TextSha256 -Text $manifestTextLf
        }
        versions = [ordered]@{
            application = [string]$applicationPackage.version
            pchw_skill = [string]$manifest.pchw_skill.version
            pchw_r7_source = [string]$manifest.pchw_skill.r7_source_version
            node = $nodeVersion
        }
        identities = [ordered]@{
            source_pchw_tree_sha256 =
                [string]$manifest.pchw_skill.source_tree_sha256
            source_pchw_tree_file_count =
                [int]$manifest.pchw_skill.source_tree_file_count
            r7_source_pchw_tree_sha256 =
                [string]$manifest.pchw_skill.r7_source_tree_sha256
            r7_source_pchw_tree_file_count =
                [int]$manifest.pchw_skill.r7_source_tree_file_count
            pchw_skill_tree_sha256 = $skillIdentity.tree_sha256
            pchw_skill_tree_file_count = $skillIdentity.tree_file_count
            skilldock_exe_sha256 = Get-FileSha256 -Path (
                Join-Path $packageRoot "SkillDock.exe"
            )
            server_mjs_sha256 = Get-FileSha256 -Path (
                Join-Path $packageRoot "app\server.mjs"
            )
            node_exe_sha256 = Get-FileSha256 -Path $nodeExecutable
        }
        source_provenance = [ordered]@{
            pchw_branch = [string]$manifest.build_provenance.pchw_repository_branch
            pchw_head = [string]$manifest.build_provenance.pchw_repository_head
            pchw_dirty_entry_count =
                [int]$manifest.build_provenance.pchw_repository_dirty_entry_count
            pchw_status_sha256 =
                [string]$manifest.build_provenance.pchw_repository_status_sha256
            skilldock_dirty_entry_count =
                [int]$manifest.build_provenance.dirty_entry_count
            skilldock_status_sha256 =
                [string]$manifest.build_provenance.git_status_sha256
        }
        gates = [ordered]@{
            inventory_and_hashes = "passed"
            clean_windows_install_uninstall = "pending"
            clean_ui_user_acceptance = "pending"
            user_release_signoff = "pending"
            source_commit = [string]$manifest.gates.commit
            formal_release = "not-performed"
        }
        boundaries = [ordered]@{
            default_traffic = "off"
            formal_default_entry = "closed"
            real_thread_created_by_verifier = $false
            release_uploaded = $false
            dsh_observer_in_package = $false
            test_runner_in_package = $false
            fake_data_entry_in_package = $false
            write_profile_in_package = $false
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
        release_id = $verification.release_id
        archive_path = $verification.archive.path
        archive_bytes = $verification.archive.bytes
        archive_sha256 = $verification.archive.sha256
        sidecar_sha256 = $verification.archive.sidecar_sha256
        package_file_count = $verification.package.file_count
        pchw_skill_tree_sha256 = $verification.identities.pchw_skill_tree_sha256
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
    } | ConvertTo-Json -Depth 4
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
