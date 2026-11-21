[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RcArchivePath,

    [string]$OutputDirectory = "",

    [string]$ArchivePath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$distRoot = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "dist")
).TrimEnd("\")
$resolvedRcArchive = [IO.Path]::GetFullPath($RcArchivePath)
$rcSidecarPath = "$resolvedRcArchive.sha256"
$rcVerificationPath = [IO.Path]::ChangeExtension(
    $resolvedRcArchive,
    ".verification.json"
)

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
    [IO.File]::WriteAllText(
        $Path,
        $Text,
        (New-Object Text.UTF8Encoding($false))
    )
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
        throw "Path escaped its root: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

function Get-ManifestEntries {
    param([Parameter(Mandatory = $true)][string]$Root)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
            Where-Object {
                $_.Name -notin @("MANIFEST.sha256", "PACKAGE-MANIFEST.json")
            } |
            Sort-Object FullName
    )) {
        $entries.Add([ordered]@{
            path = Get-RelativePath -Root $Root -FullName $file.FullName
            bytes = [int64]$file.Length
            sha256 = Get-FileSha256 -Path $file.FullName
        }) | Out-Null
    }
    return $entries.ToArray()
}

if (
    -not (Test-Path -LiteralPath $resolvedRcArchive -PathType Leaf) -or
    -not (Test-Path -LiteralPath $rcSidecarPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $rcVerificationPath -PathType Leaf)
) {
    throw "The verified integrated RC, sidecar, and verification JSON are required."
}
$rcSha256 = Get-FileSha256 -Path $resolvedRcArchive
$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $rcSidecarPath).Trim() -split "\s+"
)
if (
    $sidecarFields.Count -lt 1 -or
    $sidecarFields[0].ToLowerInvariant() -ne $rcSha256
) {
    throw "Integrated RC sidecar does not match the archive."
}
$rcVerification = Get-Content -Raw -LiteralPath $rcVerificationPath |
    ConvertFrom-Json
if (
    [string]$rcVerification.status -ne "passed" -or
    [string]$rcVerification.archive.sha256 -ne $rcSha256
) {
    throw "Integrated RC has not passed verification."
}

$releaseVersion = [string]$rcVerification.release_id
$packageBaseName = "SkillDock-Runtime-$releaseVersion-win-x64"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $distRoot $packageBaseName
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $distRoot "$packageBaseName.zip"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd("\")
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
foreach ($path in @($OutputDirectory, $ArchivePath, "$ArchivePath.sha256")) {
    if (-not $path.StartsWith(
        $distRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Runtime package output must stay inside dist: $path"
    }
    if (Test-Path -LiteralPath $path) {
        throw "Runtime package output already exists: $path"
    }
}

$tempRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("skilldock-runtime-package-" + [guid]::NewGuid().ToString("N"))
$extractRoot = Join-Path $tempRoot "extract"
try {
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive `
        -LiteralPath $resolvedRcArchive `
        -DestinationPath $extractRoot `
        -Force
    $topLevelDirectories = @(
        Get-ChildItem -LiteralPath $extractRoot -Directory -Force
    )
    if ($topLevelDirectories.Count -ne 1) {
        throw "Integrated RC must contain exactly one top-level directory."
    }
    $sourceRoot = $topLevelDirectories[0].FullName
    $sourceRcManifest = Get-Content -Raw -LiteralPath (
        Join-Path $sourceRoot "RC-MANIFEST.json"
    ) | ConvertFrom-Json
    $sourceState = Get-Content -Raw -LiteralPath (
        Join-Path $sourceRoot "SOURCE-STATE.json"
    ) | ConvertFrom-Json
    if (
        [string]$sourceRcManifest.release_id -ne $releaseVersion -or
        [string]$sourceRcManifest.application_version -ne $releaseVersion
    ) {
        throw "Integrated RC identity is inconsistent."
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    foreach ($entry in @(
        "app",
        "node",
        "Install SkillDock Runtime.ps1",
        "runtime-data-migration.ps1",
        "runtime-paths.ps1",
        "SkillDock.exe",
        "Stop SkillDock.cmd",
        "Uninstall SkillDock.ps1"
    )) {
        $source = Join-Path $sourceRoot $entry
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Integrated RC is missing Runtime entry: $entry"
        }
        Copy-Item `
            -LiteralPath $source `
            -Destination $OutputDirectory `
            -Recurse `
            -Force
    }

    $nodeVersion = [string]$sourceRcManifest.bundled_node_version
    $readme = @"
SkillDock Runtime $releaseVersion with bundled Node.js $nodeVersion

This test build contains the SkillDock application Runtime only.
It does not contain a PCHW Skill, DSH observer, test runner, mock/dev route,
fake data, or write profile.

Install:
1. Verify the ZIP against its .sha256 sidecar.
2. Extract the ZIP.
3. In the extracted root, run:
   powershell -NoProfile -ExecutionPolicy Bypass -File ".\Install SkillDock Runtime.ps1"
4. Install a compatible PC Hardware Workbench Skill separately.
5. Use the current Codex conversation as the primary entry; do not launch SkillDock.exe manually for normal use.

Runtime program backups rotate after a successful install. The newest rollback
copy is retained by default; Task data and migration-data backups are untouched.

Default data root:
%LOCALAPPDATA%\SkillDock\runtime-pchw

Source commit:
$([string]$sourceState.head)

Status:
Test build. Clean Windows integration acceptance and final signoff remain pending.
"@
    Write-Utf8Text -Path (Join-Path $OutputDirectory "README.txt") -Text (
        $readme.Replace("`r`n", "`n")
    )

    $runtimeManifest = [ordered]@{
        schema_version = "1.0"
        product = "SkillDock Runtime"
        release_id = $releaseVersion
        package_basename = $packageBaseName
        release_state = "release-candidate-prerelease"
        application_version = $releaseVersion
        platform = "windows-x64"
        bundled_node_version = $nodeVersion
        private = $true
        package_kind = "skilldock-runtime-only"
        pchw_skill_included = $false
        dsh_observer_included = $false
        test_runner_included = $false
        mock_dev_entry_included = $false
        formal_release = "not-performed"
        gates = [ordered]@{
            package_hash_and_inventory = "built-pending-verification"
            clean_windows_install_uninstall = "pending"
            user_release_signoff = "pending"
        }
        build_provenance = [ordered]@{
            skilldock_commit = [string]$sourceState.head
            pchw_skill_commit = [string]$sourceState.pchw_repository_head
        }
    }
    Write-NormalizedJson `
        -Path (Join-Path $OutputDirectory "RC-MANIFEST.json") `
        -Value $runtimeManifest

    $sourceSnapshot = [ordered]@{
        schema_version = "1.0"
        package_kind = "skilldock-runtime-only"
        source_state = "derived-from-verified-integrated-rc"
        skilldock_commit = [string]$sourceState.head
        pchw_skill_commit = [string]$sourceState.pchw_repository_head
        source_integrated_rc_sha256 = $rcSha256
    }
    Write-NormalizedJson `
        -Path (Join-Path $OutputDirectory "SOURCE-STATE.json") `
        -Value $sourceSnapshot

    $manifestEntries = @(Get-ManifestEntries -Root $OutputDirectory)
    $packageManifest = [ordered]@{
        schema_version = "1.0"
        package_basename = $packageBaseName
        file_count = $manifestEntries.Count
        entries = $manifestEntries
    }
    Write-NormalizedJson `
        -Path (Join-Path $OutputDirectory "PACKAGE-MANIFEST.json") `
        -Value $packageManifest

    $manifestLines = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse -Force |
            Where-Object { $_.Name -ne "MANIFEST.sha256" } |
            Sort-Object FullName
    )) {
        $relative = Get-RelativePath `
            -Root $OutputDirectory `
            -FullName $file.FullName
        $manifestLines.Add(
            "$(Get-FileSha256 -Path $file.FullName)  $relative"
        ) | Out-Null
    }
    Write-Utf8Text `
        -Path (Join-Path $OutputDirectory "MANIFEST.sha256") `
        -Text (($manifestLines -join "`n") + "`n")

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $OutputDirectory,
        $ArchivePath,
        [IO.Compression.CompressionLevel]::Optimal,
        $true
    )
    $archiveSha256 = Get-FileSha256 -Path $ArchivePath
    Write-Utf8Text `
        -Path "$ArchivePath.sha256" `
        -Text (
            "$archiveSha256  $([IO.Path]::GetFileName($ArchivePath))`n"
        )

    [pscustomobject]@{
        ok = $true
        package_kind = "skilldock-runtime-only"
        release_id = $releaseVersion
        package_directory = $OutputDirectory
        archive = $ArchivePath
        archive_bytes = (Get-Item -LiteralPath $ArchivePath).Length
        archive_sha256 = $archiveSha256
        source_integrated_rc_sha256 = $rcSha256
    } | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemp.StartsWith(
            $tempBase,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}
