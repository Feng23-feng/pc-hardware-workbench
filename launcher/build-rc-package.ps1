[CmdletBinding()]
param(
    [string]$OutputDirectory = "",

    [string]$ArchivePath = "",

    [string]$PchwSkillDirectory = "",

    [switch]$AllowDirtySource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "skill-tree-identity.ps1")

$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PchwSkillDirectory)) {
    $siblingPchw = Join-Path `
        (Split-Path -Parent $RepositoryRoot) `
        "pc-hardware-workbench\skill\pc-hardware-workbench"
    if (-not (Test-Path -LiteralPath $siblingPchw -PathType Container)) {
        throw (
            "A clean sibling pc-hardware-workbench checkout is required: " +
            $siblingPchw
        )
    }
    $PchwSkillDirectory = $siblingPchw
}
$DistRoot = Join-Path $RepositoryRoot "dist"
$PackageJsonPath = Join-Path $RepositoryRoot "package.json"
$PackageJson = Get-Content -Raw -LiteralPath $PackageJsonPath |
    ConvertFrom-Json
$ReleaseVersion = [string]$PackageJson.version
$ReleaseConfigPath = Join-Path `
    $RepositoryRoot `
    "release\$ReleaseVersion\release.json"
$ReleaseConfig = Get-Content -Raw -LiteralPath $ReleaseConfigPath |
    ConvertFrom-Json
$PackageBaseName = [string]$ReleaseConfig.package_basename

if ($PackageBaseName -ne "SkillDock-PCHW-$ReleaseVersion-win-x64") {
    throw "Package basename does not match the application version."
}
if ([string]$ReleaseConfig.release_id -ne $ReleaseVersion) {
    throw "Release configuration and package.json versions differ."
}
if (-not [bool]$ReleaseConfig.private) {
    throw "The Windows RC must remain a private package."
}
if ([string]$ReleaseConfig.clean_windows_acceptance -ne "pending") {
    throw "This preparation builder expects clean-Windows acceptance to be pending."
}
if (
    [string]$ReleaseConfig.pchw_surface_contract_id -ne
        "pchw-source-hosted" -or
    [string]$ReleaseConfig.pchw_surface_contract_version -ne "1.0.0" -or
    [string]$ReleaseConfig.pchw_surface_min_skill_version -ne "2.8.0" -or
    [string]$ReleaseConfig.pchw_legacy_exact_skill_version -ne "2.8.0" -or
    [int]$ReleaseConfig.pchw_supported_contract_major -ne 1
) {
    throw "PCHW surface contract release configuration is invalid."
}

$distFull = [IO.Path]::GetFullPath($DistRoot).TrimEnd("\")
New-Item -ItemType Directory -Path $distFull -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $distFull $PackageBaseName
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd("\")
if (
    -not $OutputDirectory.StartsWith(
        $distFull + "\",
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "OutputDirectory must stay inside $distFull"
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $distFull "$PackageBaseName.zip"
}
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
if (
    -not $ArchivePath.StartsWith(
        $distFull + "\",
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "ArchivePath must stay inside $distFull"
}
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "RC output already exists and will not be replaced: $OutputDirectory"
}
if (Test-Path -LiteralPath $ArchivePath) {
    throw "RC archive already exists and will not be replaced: $ArchivePath"
}
$existingRootArchives = @(
    Get-ChildItem -LiteralPath $distFull -File -Force -Filter "*.zip"
)
if ($existingRootArchives.Count -gt 0) {
    throw (
        "dist must not contain a root-level ZIP before an RC build. " +
        "Move historical archives under dist\archive first: " +
        (($existingRootArchives | ForEach-Object FullName) -join ", ")
    )
}

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

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Read-Utf8Text {
    param([Parameter(Mandatory = $true)][string]$Path)

    $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
    return [IO.File]::ReadAllText($Path, $utf8)
}

function Write-Utf8BomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Write-NormalizedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    $json = $json.Replace("`r`n", "`n") + "`n"
    Write-Utf8Text -Path $Path -Text $json
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

function Get-PackageEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Exclude = @()
    )

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force)) {
        $relativePath = Get-PackageRelativePath -Root $Root -FullName $file.FullName
        if ($Exclude -contains $relativePath) {
            continue
        }
        $paths.Add($relativePath)
    }
    $sortedPaths = Get-SortedOrdinal -Values $paths.ToArray()
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in $sortedPaths) {
        $absolutePath = Join-Path $Root ($relativePath.Replace("/", "\"))
        $entries.Add([pscustomobject]@{
            path = $relativePath
            bytes = (Get-Item -LiteralPath $absolutePath).Length
            sha256 = Get-FileSha256 -Path $absolutePath
        })
    }
    return $entries.ToArray()
}

$resolvedSkill = [IO.Path]::GetFullPath($PchwSkillDirectory).TrimEnd("\")
$SourceSkillMarkdown = Read-Utf8Text -Path (Join-Path $resolvedSkill "SKILL.md")
if (
    $SourceSkillMarkdown -notmatch
        "version:\s*`"$([regex]::Escape([string]$ReleaseConfig.pchw_skill_version))`""
) {
    throw "PCHW source Skill version does not match the release configuration."
}
$SourceWorkbenchManifestPath = Join-Path $resolvedSkill "workbench.manifest.json"
$SourceWorkbenchManifest = Read-Utf8Text -Path $SourceWorkbenchManifestPath |
    ConvertFrom-Json
$SourceSurfaceContractProperty =
    $SourceWorkbenchManifest.surface_contracts.PSObject.Properties[
        [string]$ReleaseConfig.pchw_surface_contract_id
    ]
$SourceSurfaceContract = if ($null -eq $SourceSurfaceContractProperty) {
    $null
}
else {
    $SourceSurfaceContractProperty.Value
}
if (
    [string]$SourceWorkbenchManifest.schema_version -ne "1.0" -or
    [string]$SourceWorkbenchManifest.skill.id -ne
        "pc-hardware-workbench" -or
    [string]$SourceWorkbenchManifest.skill.version -ne
        [string]$ReleaseConfig.pchw_skill_version -or
    $null -eq $SourceSurfaceContract -or
    [string]$SourceSurfaceContract.contract_version -ne
        [string]$ReleaseConfig.pchw_surface_contract_version -or
    [string]$SourceSurfaceContract.min_skill_version -ne
        [string]$ReleaseConfig.pchw_surface_min_skill_version -or
    @($SourceSurfaceContract.required_capabilities) -notcontains
        "telemetry.csv.analyze"
) {
    throw "PCHW source does not declare the configured surface contract."
}
$skillIdentity = Get-SkillTreeIdentity -Root $resolvedSkill
if (
    $skillIdentity.tree_sha256 -ne
        [string]$ReleaseConfig.pchw_skill_tree_sha256 -or
    $skillIdentity.tree_file_count -ne
        [int]$ReleaseConfig.pchw_skill_tree_file_count
) {
    throw (
        "PCHW Skill identity does not match the reviewed RC: " +
        "$($skillIdentity.tree_sha256) / $($skillIdentity.tree_file_count)"
    )
}

$PchwRepositoryRoot = Split-Path -Parent (Split-Path -Parent $resolvedSkill)
$PchwGit = Get-Command git -ErrorAction SilentlyContinue
$PchwGitBranch = "unavailable"
$PchwGitHead = "unavailable"
$PchwGitDirtyEntries = -1
$PchwGitStatusSha256 = $null
$PchwGlobalDirtyEntries = -1
$PchwGlobalStatusSha256 = $null
if ($PchwGit) {
    $PchwGitPrefix = @(
        "-C",
        $PchwRepositoryRoot,
        "-c",
        "safe.directory=$PchwRepositoryRoot"
    )
    $pchwHead = @(
        & $PchwGit.Source @PchwGitPrefix rev-parse HEAD 2>$null
    )
    if ($LASTEXITCODE -eq 0 -and $pchwHead.Count -gt 0) {
        $PchwGitHead = [string]$pchwHead[0]
    }
    $pchwBranch = @(
        & $PchwGit.Source @PchwGitPrefix branch --show-current 2>$null
    )
    if ($LASTEXITCODE -eq 0 -and $pchwBranch.Count -gt 0) {
        $PchwGitBranch = [string]$pchwBranch[0]
    }
    $pchwGlobalStatusLines = @(
        & $PchwGit.Source `
            @PchwGitPrefix `
            status `
            --porcelain=v1 `
            --untracked-files=all `
            2>$null
    )
    if ($LASTEXITCODE -eq 0) {
        $PchwGlobalDirtyEntries = @(
            $pchwGlobalStatusLines |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ).Count
        $PchwGlobalStatusSha256 =
            Get-TextSha256 -Text ($pchwGlobalStatusLines -join "`n")
    }
    $resolvedPchwRoot = [IO.Path]::GetFullPath($PchwRepositoryRoot).TrimEnd("\")
    $relativePchwSkill = $resolvedSkill.Substring($resolvedPchwRoot.Length + 1)
    $pchwStatusLines = @(
        & $PchwGit.Source `
            @PchwGitPrefix `
            status `
            --porcelain=v1 `
            --untracked-files=all `
            -- `
            $relativePchwSkill `
            2>$null
    )
    if ($LASTEXITCODE -eq 0) {
        $PchwGitDirtyEntries = @(
            $pchwStatusLines |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ).Count
        $PchwGitStatusSha256 =
            Get-TextSha256 -Text ($pchwStatusLines -join "`n")
    }
}
if (-not $PchwGit) {
    throw "A Git checkout is required to prove PCHW release provenance."
}
if ($PchwGitDirtyEntries -ne 0 -and -not $AllowDirtySource) {
    throw (
        "PCHW packaged Skill source must be clean before building an " +
        "official RC; dirty entry count: $PchwGitDirtyEntries. " +
        "Use -AllowDirtySource only for a local acceptance candidate."
    )
}

$BuilderPath = Join-Path $PSScriptRoot "build-dsh-package.ps1"
$StagingArchive = Join-Path `
    $distFull `
    (".$PackageBaseName-build-" + [guid]::NewGuid().ToString("N") + ".zip")
$NodeSource = if ($env:SKILLDOCK_NODE_DIR) {
    $env:SKILLDOCK_NODE_DIR
}
elseif ($env:SKILLDOCK_FROZEN_NODE) {
    Split-Path -Parent (Resolve-Path -LiteralPath $env:SKILLDOCK_FROZEN_NODE).Path
}
else {
    Split-Path -Parent (Get-Command node -ErrorAction Stop).Source
}
$NodeSource = (Resolve-Path -LiteralPath $NodeSource).Path
$NodeExecutable = Join-Path $NodeSource "node.exe"
if (-not (Test-Path -LiteralPath $NodeExecutable -PathType Leaf)) {
    throw "The selected Node source does not contain node.exe: $NodeSource"
}
$NodeProbeVersion = ((
    & $NodeExecutable --version
).Trim() -replace '^v', '')
$NodeProbeSqlite = (
    & $NodeExecutable -p "process.versions.sqlite"
).Trim()
$ProductionProfile = Get-Content `
    -Raw `
    -LiteralPath (Join-Path `
        $RepositoryRoot `
        "contracts\source-hosted-shared-task\v1\persistence\production-profile.json") |
    ConvertFrom-Json
if ($NodeProbeVersion -ne [string]$ReleaseConfig.bundled_node_version) {
    throw (
        "The selected Node version $NodeProbeVersion does not match " +
        "$($ReleaseConfig.bundled_node_version). Set SKILLDOCK_FROZEN_NODE " +
        "or SKILLDOCK_NODE_DIR to the frozen engine."
    )
}
if ($NodeProbeSqlite -ne [string]$ProductionProfile.runtime.sqlite_verified) {
    throw (
        "The selected Node ships SQLite $NodeProbeSqlite instead of " +
        "$($ProductionProfile.runtime.sqlite_verified)."
    )
}
$NodeLicenseCandidates = @(
    $env:SKILLDOCK_NODE_LICENSE,
    (Join-Path $NodeSource "LICENSE"),
    (Join-Path `
        $RepositoryRoot `
        "release\$ReleaseVersion\licenses\Node-LICENSE.txt")
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$NodeLicense = $NodeLicenseCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
if (-not $NodeLicense) {
    throw "A bundled Node.js LICENSE file is required."
}

$TemporaryNodeBundle = $null
$PreviousNodeDirectory = $env:SKILLDOCK_NODE_DIR
try {
    $env:SKILLDOCK_NODE_DIR = $NodeSource
    if (-not (Test-Path -LiteralPath (Join-Path $NodeSource "LICENSE"))) {
        $TemporaryNodeBundle = Join-Path `
            ([IO.Path]::GetTempPath()) `
            ("skilldock-node-bundle-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $TemporaryNodeBundle -Force |
            Out-Null
        Copy-Item `
            -LiteralPath (Join-Path $NodeSource "node.exe") `
            -Destination (Join-Path $TemporaryNodeBundle "node.exe")
        Copy-Item `
            -LiteralPath $NodeLicense `
            -Destination (Join-Path $TemporaryNodeBundle "LICENSE")
        $env:SKILLDOCK_NODE_DIR = $TemporaryNodeBundle
    }
    & $BuilderPath `
        -OutputDirectory $OutputDirectory `
        -ArchivePath $StagingArchive `
        -LauncherSourcePath (Join-Path $PSScriptRoot "release\SkillDockLauncher.cs")
    if (-not $?) {
        throw "The base Windows package build failed."
    }
}
finally {
    $env:SKILLDOCK_NODE_DIR = $PreviousNodeDirectory
    if ($TemporaryNodeBundle -and (Test-Path -LiteralPath $TemporaryNodeBundle)) {
        $resolvedTemporaryNode = [IO.Path]::GetFullPath($TemporaryNodeBundle)
        $resolvedTempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (
            $resolvedTemporaryNode.StartsWith(
                $resolvedTempBase,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $resolvedTemporaryNode -Recurse -Force
        }
    }
}
if (-not (Test-Path -LiteralPath $StagingArchive -PathType Leaf)) {
    throw "The base Windows package did not produce its staging archive."
}
Remove-Item -LiteralPath $StagingArchive -Force

$DevHarness = Join-Path $OutputDirectory "Start-DSH-SkillDock-Dev.ps1"
if (Test-Path -LiteralPath $DevHarness) {
    Remove-Item -LiteralPath $DevHarness -Force
}
$InstalledDshHarness = Join-Path $OutputDirectory "Start-DSH-SkillDock.ps1"
if (Test-Path -LiteralPath $InstalledDshHarness) {
    Remove-Item -LiteralPath $InstalledDshHarness -Force
}

$ReleaseAppRoot = Join-Path $OutputDirectory "app"
$ReleaseAgentsRoot = Join-Path $ReleaseAppRoot "lib\agents"
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "release\agents-index.mjs") `
    -Destination (Join-Path $ReleaseAgentsRoot "index.mjs") `
    -Force
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "release\agent-permissions.mjs") `
    -Destination (Join-Path $ReleaseAppRoot "lib\agent-permissions.mjs") `
    -Force

foreach ($relativePath in @(
    "agent-bridge-host.mjs",
    "open-workbench.mjs",
    "lib\agents\README.md",
    "lib\agents\agent-bridge-driver.mjs",
    "lib\agents\codex-agent-driver.mjs",
    "lib\agents\dsh-agent-driver.mjs",
    "lib\agents\dsh-web-agent-driver.mjs",
    "lib\agents\dsh-web-rpc-client.mjs",
    "lib\agents\mock-agent-driver.mjs",
    "lib\source-hosted-shadow.mjs"
)) {
    $target = Join-Path $ReleaseAppRoot $relativePath
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Force
    }
}

$ReleaseAppPackage = [ordered]@{
    name = [string]$PackageJson.name
    version = [string]$PackageJson.version
    description = [string]$PackageJson.description
    private = [bool]$PackageJson.private
    type = [string]$PackageJson.type
    packageManager = [string]$PackageJson.packageManager
    engines = $PackageJson.engines
    sourceHostedProfile = [string]$PackageJson.sourceHostedProfile
}
Write-NormalizedJson `
    -Path (Join-Path $ReleaseAppRoot "package.json") `
    -Value $ReleaseAppPackage

$ReleaseServerPath = Join-Path $ReleaseAppRoot "server.mjs"
$ReleaseServer = (Read-Utf8Text -Path $ReleaseServerPath).
    Replace("`r`n", "`n")
$ReleaseServer = $ReleaseServer.Replace(
    "import {`n  createSourceHostedShadowObserver,`n} from ""./lib/source-hosted-shadow.mjs"";`n",
    ""
)
$ReleaseServer = [regex]::Replace(
    $ReleaseServer,
    "(?s)const sourceHostedShadow = createSourceHostedShadowObserver\(\{.*?\n\}\);\n",
    ""
)
$ReleaseServer = [regex]::Replace(
    $ReleaseServer,
    "(?s)    if \(sourceHostedShadow\.shouldObserve\) \{.*?\n    \}\n",
    ""
)
$ReleaseServer = $ReleaseServer.Replace(
    "  await sourceHostedShadow.close().catch(() => {});`n",
    ""
)
$RecoveryRoute = @"
  if (
    request.method === "POST" &&
    url.pathname === "/api/task/recover"
  ) {
    await recoverSourceHostedTask(request, response);
    return;
  }

"@
$ReleaseServer = $ReleaseServer.Replace($RecoveryRoute, "")
$ReleaseServer = [regex]::Replace(
    $ReleaseServer,
    "(?s)async function recoverSourceHostedTask\(request, response\) \{.*?\n\}\n\n(?=async function uploadAttachment)",
    ""
)
Write-Utf8Text -Path $ReleaseServerPath -Text $ReleaseServer

$ReleaseAppJsPath = Join-Path $ReleaseAppRoot "public\app.js"
$ReleaseAppJs = (Read-Utf8Text -Path $ReleaseAppJsPath).
    Replace("`r`n", "`n")
$ReleaseAppJs = [regex]::Replace(
    $ReleaseAppJs,
    '(?m)^\s*"workspace-write":.*\n',
    ""
)
$ReleaseAppJs = [regex]::Replace(
    $ReleaseAppJs,
    '(?m)^\s*"danger-full-access":.*\n',
    ""
)
$ReleaseAppJs = [regex]::Replace(
    $ReleaseAppJs,
    '(?m)^\s*interactive:.*\n',
    ""
)
$ReleaseAppJs = [regex]::Replace(
    $ReleaseAppJs,
    '(?m)^\s*developer:.*\n',
    ""
)
$ReleaseAppJs = $ReleaseAppJs.Replace(
    @"
function sourceHostedRecoveryAvailable() {
  const phaseState = sourceHostedPhaseState();
  return (
    state.task?.shared_task?.mode === "source_hosted" &&
    (
      state.phase === "error" ||
      state.phase === "interrupted" ||
      phaseState.recovery_available
    )
  );
}
"@,
    @"
function sourceHostedRecoveryAvailable() {
  return false;
}
"@
)
$ReleaseAppJs = [regex]::Replace(
    $ReleaseAppJs,
    "(?s)async function recoverSourceHostedTask\(\) \{.*?\n\}\n\n(?=async function sendSubmission)",
    "async function recoverSourceHostedTask() {`n  return;`n}`n`n"
)
Write-Utf8Text -Path $ReleaseAppJsPath -Text $ReleaseAppJs

$ReleaseSourcePhasePath = Join-Path `
    $ReleaseAppRoot `
    "public\source-hosted-phase.js"
$ReleaseSourcePhase = Read-Utf8Text -Path $ReleaseSourcePhasePath
$ReleaseSourcePhase = $ReleaseSourcePhase.Replace(
    '  const recoveryAvailable = normalizedPhase === "source_agent_pulled";',
    "  const recoveryAvailable = false;"
)
Write-Utf8Text -Path $ReleaseSourcePhasePath -Text $ReleaseSourcePhase

$ReleaseSourceDriverPath = Join-Path `
    $ReleaseAgentsRoot `
    "source-external-agent-driver.mjs"
$ReleaseSourceDriver = Read-Utf8Text -Path $ReleaseSourceDriverPath
$ReleaseSourceDriver = $ReleaseSourceDriver.Replace(
    "The real source Thread is owned by the controlled source runner.",
    "The real source Thread is owned by the current Codex conversation."
)
$ReleaseSourceDriver = $ReleaseSourceDriver.Replace(
    "The controlled source runner owns the only real Agent Thread.",
    "The current Codex conversation owns the only real Agent Thread."
)
$ReleaseSourceDriver = $ReleaseSourceDriver.Replace(
    "A source-external preview cannot create a panel-owned model Turn.",
    "The SkillDock panel cannot create an extra model Turn."
)
Write-Utf8Text -Path $ReleaseSourceDriverPath -Text $ReleaseSourceDriver

$ReleaseSkillDiscoveryPath = Join-Path `
    $ReleaseAppRoot `
    "lib\skill-discovery.mjs"
$ReleaseSkillDiscovery = Read-Utf8Text -Path $ReleaseSkillDiscoveryPath
$ReleaseSkillDiscovery = $ReleaseSkillDiscovery.Replace(
    '    join(homedir(), ".dsh", "skills"),' + "`n",
    ""
)
Write-Utf8Text -Path $ReleaseSkillDiscoveryPath -Text $ReleaseSkillDiscovery

Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "install-runtime.ps1") `
    -Destination (Join-Path $OutputDirectory "Install SkillDock Runtime.ps1")
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "install-pchw-skill.ps1") `
    -Destination (Join-Path $OutputDirectory "Install PCHW Skill.ps1")
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "uninstall-pchw-skill.ps1") `
    -Destination (Join-Path $OutputDirectory "Uninstall PCHW Skill.ps1")
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "runtime-paths.ps1") `
    -Destination (Join-Path $OutputDirectory "runtime-paths.ps1")
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "runtime-data-migration.ps1") `
    -Destination (Join-Path $OutputDirectory "runtime-data-migration.ps1")
Copy-Item `
    -LiteralPath (Join-Path $PSScriptRoot "skill-tree-identity.ps1") `
    -Destination (Join-Path $OutputDirectory "skill-tree-identity.ps1")

$PackageSkills = Join-Path $OutputDirectory "skills"
New-Item -ItemType Directory -Path $PackageSkills -Force | Out-Null
Copy-Item `
    -LiteralPath $resolvedSkill `
    -Destination $PackageSkills `
    -Recurse `
    -Force
Remove-Item `
    -LiteralPath (Join-Path $PackageSkills "pc-hardware-workbench\INSTALL-INFO.json") `
    -Force `
    -ErrorAction SilentlyContinue
$PackagedPchwSkill = Join-Path `
    $PackageSkills `
    "pc-hardware-workbench"
$PackagedPchwTests = Join-Path $PackagedPchwSkill "tests"
if (Test-Path -LiteralPath $PackagedPchwTests) {
    Remove-Item -LiteralPath $PackagedPchwTests -Recurse -Force
}
$PackagedSkillIdentity = Get-SkillTreeIdentity -Root $PackagedPchwSkill

$PackageIntegrations = Join-Path $OutputDirectory "integrations"
New-Item -ItemType Directory -Path $PackageIntegrations -Force | Out-Null
Copy-Item `
    -LiteralPath (Join-Path $RepositoryRoot "integrations\skilldock") `
    -Destination $PackageIntegrations `
    -Recurse `
    -Force
Remove-Item `
    -LiteralPath (Join-Path $PackageIntegrations "skilldock\README.md") `
    -Force `
    -ErrorAction SilentlyContinue
$ReleaseLaunchPanelPath = Join-Path `
    $PackageIntegrations `
    "skilldock\launch-panel.ps1"
$ReleaseLaunchPanel = (Read-Utf8Text -Path $ReleaseLaunchPanelPath).
    Replace("`r`n", "`n")
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    '[ValidateSet("pchw-source-hosted", "legacy")]',
    '[ValidateSet("pchw-source-hosted")]'
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    '[ValidateSet("read-only", "interactive", "developer")]',
    '[ValidateSet("read-only")]'
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "            ""PANEL_SURFACE_MODE"",`n",
    "            ""PANEL_SURFACE_MODE""`n"
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "            ""SKILLDOCK_AGENT_DRIVER"",`n",
    ""
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "            ""SKILLDOCK_INTERNAL_PREVIEW"",`n",
    ""
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "            ""SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK""`n",
    ""
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "                `$env:SKILLDOCK_AGENT_DRIVER = ""source-external""`n",
    ""
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "                `$env:SKILLDOCK_INTERNAL_PREVIEW = ""1""`n",
    ""
)
$ReleaseLaunchPanel = $ReleaseLaunchPanel.Replace(
    "                `$env:SKILLDOCK_INTERNAL_PREVIEW_NON_MOCK = ""1""`n",
    ""
)
Write-Utf8BomText -Path $ReleaseLaunchPanelPath -Text $ReleaseLaunchPanel

$ReleasePowerShellScripts = New-Object System.Collections.Generic.List[string]
$ReleasePowerShellScripts.Add(
    (Join-Path $OutputDirectory "Install SkillDock Runtime.ps1")
)
$ReleasePowerShellScripts.Add(
    (Join-Path $OutputDirectory "Uninstall SkillDock.ps1")
)
$ReleasePowerShellScripts.Add(
    (Join-Path $OutputDirectory "runtime-paths.ps1")
)
$ReleasePowerShellScripts.Add(
    (Join-Path $OutputDirectory "runtime-data-migration.ps1")
)
foreach ($script in @(
    Get-ChildItem `
        -LiteralPath (Join-Path $PackageIntegrations "skilldock") `
        -File `
        -Filter "*.ps1"
)) {
    $ReleasePowerShellScripts.Add($script.FullName)
}
foreach ($scriptPath in $ReleasePowerShellScripts) {
    $scriptText = Read-Utf8Text -Path $scriptPath
    $scriptText = $scriptText.Replace(
        'Join-Path $RepositoryRoot "dist\SkillDock-DSH"',
        'throw "RC installer must be run from the extracted package root."'
    )
    Write-Utf8BomText -Path $scriptPath -Text $scriptText
}
foreach ($scriptPath in $ReleasePowerShellScripts) {
    $scriptTokens = $null
    $scriptErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$scriptTokens,
        [ref]$scriptErrors
    )
    if ($scriptErrors.Count -gt 0) {
        throw (
            "Release PowerShell syntax check failed: $scriptPath - " +
            (@($scriptErrors | ForEach-Object Message) -join " | ")
        )
    }
}

$RuntimePathHelpers = @(
    (Join-Path $OutputDirectory "runtime-paths.ps1"),
    (Join-Path `
        $OutputDirectory `
        "integrations\skilldock\runtime-paths.ps1"),
    (Join-Path `
        $OutputDirectory `
        "skills\pc-hardware-workbench\scripts\skilldock\runtime-paths.ps1")
)
$StorageExportHelper = Join-Path `
    $OutputDirectory `
    "app\lib\export-storage-archive.ps1"
if (-not (Test-Path -LiteralPath $StorageExportHelper -PathType Leaf)) {
    throw "Storage export helper is missing from the RC."
}
$storageHelperTokens = $null
$storageHelperErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $StorageExportHelper,
    [ref]$storageHelperTokens,
    [ref]$storageHelperErrors
)
if ($storageHelperErrors.Count -gt 0) {
    throw "Storage export helper has a syntax error."
}
foreach ($helperPath in $RuntimePathHelpers) {
    if (-not (Test-Path -LiteralPath $helperPath -PathType Leaf)) {
        throw "Runtime path helper is missing from the RC: $helperPath"
    }
    $helperTokens = $null
    $helperErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $helperPath,
        [ref]$helperTokens,
        [ref]$helperErrors
    )
    if ($helperErrors.Count -gt 0) {
        throw (
            "Packaged runtime path helper has a syntax error: " +
            $helperPath
        )
    }
}
$RuntimePathHelperHashes = @(
    $RuntimePathHelpers |
        ForEach-Object {
            Get-TextSha256 -Text (
                (Read-Utf8Text -Path $_).
                    Replace("`r`n", "`n").
                    Replace("`r", "`n")
            )
        } |
        Sort-Object -Unique
)
if ($RuntimePathHelperHashes.Count -ne 1) {
    throw "Packaged runtime path helpers do not have the same content."
}
foreach ($scriptDirectory in @(
    (Join-Path $OutputDirectory "integrations\skilldock"),
    (Join-Path `
        $OutputDirectory `
        "skills\pc-hardware-workbench\scripts\skilldock")
)) {
    foreach ($scriptName in @(
        "launch-panel.ps1",
        "sync-panel.ps1",
        "wait-panel.ps1",
        "submit-panel-result.ps1"
    )) {
        $scriptPath = Join-Path $scriptDirectory $scriptName
        if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
            throw "Required SkillDock script is missing: $scriptPath"
        }
        $script = Get-Item -LiteralPath $scriptPath
        $scriptText = Read-Utf8Text -Path $script.FullName
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw (
                "Packaged SkillDock script has a syntax error: " +
                $scriptPath
            )
        }
        if ($scriptText -match "runtime-dsh-web|runtime-pchw") {
            throw (
                "SkillDock data-root name is hard-coded outside the shared " +
                "resolver: $($script.FullName)"
            )
        }
        if ($scriptText -notmatch 'runtime-paths\.ps1') {
            throw (
                "SkillDock script does not load the shared runtime path " +
                "resolver: $($script.FullName)"
            )
        }
    }
}

$PackageDocs = Join-Path $OutputDirectory "docs"
New-Item -ItemType Directory -Path $PackageDocs -Force | Out-Null
$ComponentMatrix = Join-Path $RepositoryRoot "COMPONENT-MATRIX.md"
if (-not (Test-Path -LiteralPath $ComponentMatrix -PathType Leaf)) {
    throw "COMPONENT-MATRIX.md is missing from the release source."
}
Copy-Item `
    -LiteralPath $ComponentMatrix `
    -Destination (Join-Path $PackageDocs "COMPONENT-MATRIX.md") `
    -Force
$PackageReleaseDocs = Join-Path $PackageDocs "release"
New-Item -ItemType Directory -Path $PackageReleaseDocs -Force | Out-Null
Copy-Item `
    -Path (Join-Path $RepositoryRoot "release\$ReleaseVersion\*") `
    -Destination $PackageReleaseDocs `
    -Recurse `
    -Force
$InnerAcceptanceHarness = Join-Path $PackageReleaseDocs "acceptance-bundle"
if (Test-Path -LiteralPath $InnerAcceptanceHarness) {
    Remove-Item -LiteralPath $InnerAcceptanceHarness -Recurse -Force
}

$PackageLicenses = Join-Path $OutputDirectory "licenses"
New-Item -ItemType Directory -Path $PackageLicenses -Force | Out-Null
$SkillDockLicense = Join-Path $RepositoryRoot "LICENSE"
$PchwLicense = Join-Path $PchwRepositoryRoot "LICENSE"
if (-not (Test-Path -LiteralPath $SkillDockLicense -PathType Leaf)) {
    throw "SkillDock LICENSE is missing from the RC source."
}
if (-not (Test-Path -LiteralPath $PchwLicense -PathType Leaf)) {
    throw "PCHW LICENSE is missing from the RC source."
}
Copy-Item `
    -LiteralPath $SkillDockLicense `
    -Destination (Join-Path $PackageLicenses "SkillDock-LICENSE.txt") `
    -Force
Copy-Item `
    -LiteralPath $PchwLicense `
    -Destination (Join-Path $PackageLicenses "PCHW-LICENSE.txt") `
    -Force
Copy-Item `
    -LiteralPath $NodeLicense `
    -Destination (Join-Path $PackageLicenses "Node-LICENSE.txt") `
    -Force

$Readme = @"
SkillDock + PC Hardware Workbench $ReleaseVersion

Status: RELEASE CANDIDATE / NOT RELEASED / DEFAULT OFF

This Windows x64 archive is a release-preparation artifact. It does not enable
default traffic, the formal default entry, background write, coordinator
recovery, or automatic hardware changes. Clean-Windows acceptance and explicit
user release approval are still required.

Primary user path:

1. Ask a hardware question in the current Codex conversation.
2. Accept the offered graphical workspace.
3. The installed PC Hardware Workbench Skill starts SkillDock and carries the
   current Task, question, and supported attachment context into the page.

Ordinary use does not require a runner script, development route, test command,
port, token, environment variable, or manual SkillDock.exe launch.

Host support in this release is Codex-only for the pchw-source-hosted SkillDock
panel. DSH and other hosts may use the PC Hardware Workbench Skill's chat,
collection, and CSV analysis, but this panel is not promised on those hosts.
Without CODEX_THREAD_ID the launcher fails safely with thread_binding_missing.

Bundled components:

    SkillDock application: $ReleaseVersion
    PC Hardware Workbench: $([string]$ReleaseConfig.pchw_skill_version)
    Node.js:               $([string]$ReleaseConfig.bundled_node_version)

Before extraction, compare the ZIP with its .sha256 sidecar. After extraction,
verify package contents with the supplied MANIFEST.sha256 and
PACKAGE-MANIFEST.json.

Read docs/release/INSTALL.md, KNOWN-LIMITATIONS.md, and
CLEAN-WINDOWS-ACCEPTANCE.md before installing. The exact host matrix is
docs/release/SUPPORT-MATRIX.md. The canonical version, asset, and evidence
matrix is docs/COMPONENT-MATRIX.md.

No administrator rights are required. Hardware configuration changes are
manual-only and outside this archive.
"@
Write-Utf8Text -Path (Join-Path $OutputDirectory "README.txt") -Text $Readme

$ReleaseChecks = @(
    (Join-Path $ReleaseAppRoot "server.mjs"),
    (Join-Path $ReleaseAppRoot "public\app.js"),
    (Join-Path $ReleaseAppRoot "lib\agent-permissions.mjs"),
    (Join-Path $ReleaseAppRoot "lib\storage-exports.mjs"),
    (Join-Path $ReleaseAppRoot "lib\storage-maintenance.mjs"),
    (Join-Path $ReleaseAppRoot "lib\agents\index.mjs"),
    (Join-Path $ReleaseAppRoot "lib\agents\source-external-agent-driver.mjs")
)
foreach ($path in $ReleaseChecks) {
    & node --check $path
    if ($LASTEXITCODE -ne 0) {
        throw "Release JavaScript syntax check failed: $path"
    }
}

foreach ($relativePath in @(
    "app\agent-bridge-host.mjs",
    "app\open-workbench.mjs",
    "app\lib\agents\README.md",
    "app\lib\agents\agent-bridge-driver.mjs",
    "app\lib\agents\codex-agent-driver.mjs",
    "app\lib\agents\dsh-agent-driver.mjs",
    "app\lib\agents\dsh-web-agent-driver.mjs",
    "app\lib\agents\dsh-web-rpc-client.mjs",
    "app\lib\agents\mock-agent-driver.mjs",
    "app\lib\source-hosted-shadow.mjs",
    "Start-DSH-SkillDock.ps1",
    "Start-DSH-SkillDock-Dev.ps1",
    "skills\pc-hardware-workbench\tests"
)) {
    $path = Join-Path $OutputDirectory $relativePath
    if (Test-Path -LiteralPath $path) {
        throw "Development entry remains in the RC package: $relativePath"
    }
}

$ReleaseServerText = Read-Utf8Text -Path $ReleaseServerPath
if (
    $ReleaseServerText -match "sourceHostedShadow" -or
    $ReleaseServerText -match [regex]::Escape("/api/task/recover")
) {
    throw "Release server still contains a shadow observer or recovery route."
}
$ReleaseAgentsText = Read-Utf8Text -Path (
    Join-Path $ReleaseAgentsRoot "index.mjs"
)
if (
    $ReleaseAgentsText -match "MockAgentDriver|DSHAgentDriver|AgentBridgeDriver|CodexAgentDriver"
) {
    throw "Release agent index still references a development adapter."
}
$ReleasePermissionText = Read-Utf8Text -Path (
    Join-Path $ReleaseAppRoot "lib\agent-permissions.mjs"
)
if (
    $ReleasePermissionText -match "workspace-write|danger-full-access|interactive|developer"
) {
    throw "Release permission file still exposes a non-read-only profile."
}
$ReleasePackageObject = Get-Content -Raw -LiteralPath (
    Join-Path $ReleaseAppRoot "package.json"
) | ConvertFrom-Json
if (
    $null -ne $ReleasePackageObject.PSObject.Properties["scripts"] -or
    $null -ne $ReleasePackageObject.PSObject.Properties["devDependencies"]
) {
    throw "Packaged application metadata still exposes test or development scripts."
}

$Git = Get-Command git -ErrorAction SilentlyContinue
$GitHead = "unavailable"
$GitBranch = "unavailable"
$GitDirtyEntries = -1
$GitStatusSha256 = $null
$GitRemoteCount = -1
if ($Git) {
    $GitPrefix = @("-c", "safe.directory=$RepositoryRoot")
    $head = @(& $Git.Source @GitPrefix rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $head.Count -gt 0) {
        $GitHead = [string]$head[0]
    }
    $branch = @(& $Git.Source @GitPrefix branch --show-current 2>$null)
    if ($LASTEXITCODE -eq 0 -and $branch.Count -gt 0) {
        $GitBranch = [string]$branch[0]
    }
    $statusLines = @(
        & $Git.Source @GitPrefix status --porcelain=v1 --untracked-files=all 2>$null
    )
    if ($LASTEXITCODE -eq 0) {
        $GitDirtyEntries = @(
            $statusLines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        ).Count
        $GitStatusSha256 = Get-TextSha256 -Text ($statusLines -join "`n")
    }
    $remoteLines = @(
        & $Git.Source @GitPrefix remote -v 2>$null |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($LASTEXITCODE -eq 0) {
        $GitRemoteCount = [int]($remoteLines.Count / 2)
    }
}
if (-not $Git) {
    throw "A Git checkout is required to prove SkillDock release provenance."
}
if ($GitDirtyEntries -ne 0 -and -not $AllowDirtySource) {
    throw (
        "SkillDock repository must be clean before building an official " +
        "RC; dirty entry count: $GitDirtyEntries. Use -AllowDirtySource " +
        "only for a local acceptance candidate."
    )
}

$BuiltAt = [DateTimeOffset]::UtcNow.ToString("o")
$LocalUncommittedCandidate = [bool]$AllowDirtySource
$CandidateReleaseState = if ($LocalUncommittedCandidate) {
    "local-candidate-clean-ui-pending"
}
else {
    [string]$ReleaseConfig.release_state
}
$CandidateCommitState = if ($LocalUncommittedCandidate) {
    "local-uncommitted"
}
else {
    "local-only"
}
$SourceState = [ordered]@{
    schema_version = "1.0"
    release_id = $ReleaseVersion
    source_state = if ($LocalUncommittedCandidate) {
        "local-uncommitted-candidate"
    }
    else {
        "clean-local-checkout"
    }
    branch = $GitBranch
    head = $GitHead
    dirty_entry_count = $GitDirtyEntries
    git_status_sha256 = $GitStatusSha256
    remote_count = $GitRemoteCount
    built_at = $BuiltAt
    source_inputs = @(
        "app",
        "node",
        "launcher",
        "integrations/skilldock",
        "skills/pc-hardware-workbench",
        "release/$ReleaseVersion"
    )
    excluded_paths = @(
        ".git",
        "dist",
        "work",
        "node_modules",
        "runtime*",
        "agent-diagnostics",
        "test artifacts",
        "skills/pc-hardware-workbench/tests",
        "mock and development agent drivers",
        "DSH launch harness and observer entry",
        "local runtime tokens and process metadata"
    )
    source_pchw_version = [string]$ReleaseConfig.pchw_skill_version
    source_pchw_tree_sha256 = $skillIdentity.tree_sha256
    source_pchw_tree_file_count = $skillIdentity.tree_file_count
    r7_source_pchw_version = [string]$ReleaseConfig.pchw_r7_source_version
    r7_source_pchw_tree_sha256 =
        [string]$ReleaseConfig.pchw_r7_source_tree_sha256
    r7_source_pchw_tree_file_count =
        [int]$ReleaseConfig.pchw_r7_source_tree_file_count
    pchw_repository_branch = $PchwGitBranch
    pchw_repository_head = $PchwGitHead
    pchw_repository_dirty_entry_count = $PchwGitDirtyEntries
    pchw_repository_status_sha256 = $PchwGitStatusSha256
    pchw_repository_dirty_scope = $relativePchwSkill.Replace("\", "/")
    pchw_repository_global_dirty_entry_count = $PchwGlobalDirtyEntries
    pchw_repository_global_status_sha256 = $PchwGlobalStatusSha256
    pchw_surface_contract_id =
        [string]$ReleaseConfig.pchw_surface_contract_id
    pchw_surface_contract_version =
        [string]$ReleaseConfig.pchw_surface_contract_version
    pchw_surface_min_skill_version =
        [string]$ReleaseConfig.pchw_surface_min_skill_version
    pchw_legacy_exact_skill_version =
        [string]$ReleaseConfig.pchw_legacy_exact_skill_version
    pchw_supported_contract_major =
        [int]$ReleaseConfig.pchw_supported_contract_major
    packaged_pchw_tree_sha256 = $PackagedSkillIdentity.tree_sha256
    packaged_pchw_tree_file_count = $PackagedSkillIdentity.tree_file_count
    builder_sha256 = Get-FileSha256 -Path $PSCommandPath
}
Write-NormalizedJson `
    -Path (Join-Path $OutputDirectory "SOURCE-STATE.json") `
    -Value $SourceState

$IntegrationFiles = @(
    "runtime-paths.ps1",
    "launch-panel.ps1",
    "sync-panel.ps1",
    "wait-panel.ps1",
    "source-result-freshness.ps1",
    "submit-panel-result.ps1"
)
$IntegrationHashes = [ordered]@{}
foreach ($name in $IntegrationFiles) {
    $path = Join-Path $OutputDirectory "integrations\skilldock\$name"
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $IntegrationHashes[$name] = Get-FileSha256 -Path $path
    }
}

$PreManifestFiles = Get-PackageEntries -Root $OutputDirectory
$RcManifest = [ordered]@{
    schema_version = "1.0"
    product = [string]$ReleaseConfig.product
    release_id = $ReleaseVersion
    package_basename = $PackageBaseName
    release_state = $CandidateReleaseState
    application_version = $ReleaseVersion
    platform = [string]$ReleaseConfig.platform
    support = [ordered]@{
        skilldock_panel_host = [string]$ReleaseConfig.skilldock_panel_host
        pchw_skill_core_hosts = @($ReleaseConfig.pchw_skill_core_hosts)
        panel_requires_codex_thread_id =
            [bool]$ReleaseConfig.panel_requires_codex_thread_id
    }
    private = [bool]$ReleaseConfig.private
    bundled_node_version = [string]$ReleaseConfig.bundled_node_version
    pchw_skill = [ordered]@{
        version = [string]$ReleaseConfig.pchw_skill_version
        r7_source_version = [string]$ReleaseConfig.pchw_r7_source_version
        source_tree_sha256 = $skillIdentity.tree_sha256
        source_tree_file_count = $skillIdentity.tree_file_count
        r7_source_tree_sha256 =
            [string]$ReleaseConfig.pchw_r7_source_tree_sha256
        r7_source_tree_file_count =
            [int]$ReleaseConfig.pchw_r7_source_tree_file_count
        tree_sha256 = $PackagedSkillIdentity.tree_sha256
        tree_file_count = $PackagedSkillIdentity.tree_file_count
        excluded_paths = @("tests")
    }
    pchw_surface_contract = [ordered]@{
        id = [string]$ReleaseConfig.pchw_surface_contract_id
        version = [string]$ReleaseConfig.pchw_surface_contract_version
        min_skill_version =
            [string]$ReleaseConfig.pchw_surface_min_skill_version
        legacy_exact_skill_version =
            [string]$ReleaseConfig.pchw_legacy_exact_skill_version
        supported_contract_major =
            [int]$ReleaseConfig.pchw_supported_contract_major
        required_capabilities = @(
            $SourceSurfaceContract.required_capabilities
        )
    }
    gates = [ordered]@{
        r7_current_user_thread_final_effect = "passed"
        real_edge_user_acceptance = "clean-ui-pending"
        same_task_restart = "clean-ui-pending"
        automated_portable_regression = "passed"
        package_hash_and_inventory = "built-pending-verification"
        clean_windows_install_uninstall = "pending"
        user_release_signoff = "pending"
        commit = $CandidateCommitState
        tag = "not-performed"
        upload = "not-performed"
        formal_release = "not-performed"
    }
    boundaries = [ordered]@{
        default_traffic = "off"
        formal_default_entry = "closed"
        background_write = "closed"
        coordinator_recovery = "closed"
        automatic_hardware_changes = "forbidden"
        dsh_observer_in_package = $false
        fake_data_entry_in_package = $false
        test_runner_in_package = $false
        write_profile_in_package = $false
    }
    key_hashes = [ordered]@{
        server_mjs = Get-FileSha256 -Path (
            Join-Path $OutputDirectory "app\server.mjs"
        )
        skilldock_exe = Get-FileSha256 -Path (
            Join-Path $OutputDirectory "SkillDock.exe"
        )
        node_exe = Get-FileSha256 -Path (
            Join-Path $OutputDirectory "node\node.exe"
        )
        pchw_skill_tree = $PackagedSkillIdentity.tree_sha256
        integrations = $IntegrationHashes
    }
    build_provenance = [ordered]@{
        built_at = $BuiltAt
        branch = $GitBranch
        head = $GitHead
        dirty_entry_count = $GitDirtyEntries
        git_status_sha256 = $GitStatusSha256
        pchw_repository_branch = $PchwGitBranch
        pchw_repository_head = $PchwGitHead
        pchw_repository_dirty_entry_count = $PchwGitDirtyEntries
        pchw_repository_status_sha256 = $PchwGitStatusSha256
        pchw_repository_dirty_scope = $relativePchwSkill.Replace("\", "/")
        pchw_repository_global_dirty_entry_count = $PchwGlobalDirtyEntries
        pchw_repository_global_status_sha256 = $PchwGlobalStatusSha256
        builder_sha256 = Get-FileSha256 -Path $PSCommandPath
        pre_manifest_file_count = $PreManifestFiles.Count
    }
}
Write-NormalizedJson `
    -Path (Join-Path $OutputDirectory "RC-MANIFEST.json") `
    -Value $RcManifest

$PackageEntries = Get-PackageEntries `
    -Root $OutputDirectory `
    -Exclude @("PACKAGE-MANIFEST.json", "MANIFEST.sha256")
$PackageManifest = [ordered]@{
    schema_version = "1.0"
    release_id = $ReleaseVersion
    package_basename = $PackageBaseName
    file_count = $PackageEntries.Count
    entries = @($PackageEntries)
}
Write-NormalizedJson `
    -Path (Join-Path $OutputDirectory "PACKAGE-MANIFEST.json") `
    -Value $PackageManifest

$ChecksumEntries = Get-PackageEntries `
    -Root $OutputDirectory `
    -Exclude @("MANIFEST.sha256")
$ChecksumText = New-Object System.Text.StringBuilder
foreach ($entry in $ChecksumEntries) {
    [void]$ChecksumText.Append("$($entry.sha256)  $($entry.path)`n")
}
Write-Utf8Text `
    -Path (Join-Path $OutputDirectory "MANIFEST.sha256") `
    -Text $ChecksumText.ToString()

Compress-Archive `
    -LiteralPath $OutputDirectory `
    -DestinationPath $ArchivePath `
    -CompressionLevel Optimal
$ArchiveSha256 = Get-FileSha256 -Path $ArchivePath
$SidecarPath = "$ArchivePath.sha256"
Write-Utf8Text `
    -Path $SidecarPath `
    -Text "$ArchiveSha256  $([IO.Path]::GetFileName($ArchivePath))`n"

[pscustomobject]@{
    ok = $true
    release_id = $ReleaseVersion
    package_directory = $OutputDirectory
    archive = $ArchivePath
    archive_sha256 = $ArchiveSha256
    sidecar = $SidecarPath
    package_file_count = @(Get-ChildItem `
        -LiteralPath $OutputDirectory `
        -File `
        -Recurse `
        -Force).Count
    pchw_skill_tree_sha256 = $PackagedSkillIdentity.tree_sha256
    pchw_skill_tree_file_count = $PackagedSkillIdentity.tree_file_count
} | ConvertTo-Json -Depth 4
