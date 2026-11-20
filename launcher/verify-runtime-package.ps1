[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [string]$VerificationPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$resolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
$sidecarPath = "$resolvedArchive.sha256"
if (
    -not (Test-Path -LiteralPath $resolvedArchive -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)
) {
    throw "Runtime archive and sidecar are required."
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).
        Hash.ToLowerInvariant()
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullName
    )
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    $resolvedFile = [IO.Path]::GetFullPath($FullName)
    if (-not $resolvedFile.StartsWith(
        $resolvedRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Path escaped its root: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $sidecarPath).Trim() -split "\s+"
)
$archiveSha256 = Get-FileSha256 -Path $resolvedArchive
if (
    $sidecarFields.Count -lt 1 -or
    $sidecarFields[0].ToLowerInvariant() -ne $archiveSha256
) {
    throw "Runtime archive digest does not match its sidecar."
}

$tempRoot = Join-Path (
    [IO.Path]::GetTempPath()
) ("skilldock-runtime-verify-" + [guid]::NewGuid().ToString("N"))
$extractRoot = Join-Path $tempRoot "extract"
try {
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
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
        throw "Runtime package must contain exactly one top-level directory."
    }
    $packageRoot = $topLevelDirectories[0].FullName
    $expectedBase = [IO.Path]::GetFileNameWithoutExtension($resolvedArchive)
    if ($topLevelDirectories[0].Name -ne $expectedBase) {
        throw "Runtime package top-level directory does not match its archive name."
    }

    $required = @(
        "app\server.mjs",
        "node\node.exe",
        "Install SkillDock Runtime.ps1",
        "runtime-data-migration.ps1",
        "runtime-paths.ps1",
        "SkillDock.exe",
        "Stop SkillDock.cmd",
        "Uninstall SkillDock.ps1",
        "README.txt",
        "RC-MANIFEST.json",
        "SOURCE-STATE.json",
        "PACKAGE-MANIFEST.json",
        "MANIFEST.sha256"
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $relative))) {
            throw "Runtime package is missing required entry: $relative"
        }
    }
    foreach ($forbidden in @("skills", "docs", "integrations", "tests")) {
        if (Test-Path -LiteralPath (Join-Path $packageRoot $forbidden)) {
            throw "Runtime package contains forbidden entry: $forbidden"
        }
    }
    $installerText = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "Install SkillDock Runtime.ps1"
    )
    if (
        $installerText -notmatch '\[int\]\$RetainRuntimeBackups' -or
        $installerText -notmatch 'Invoke-RuntimeBackupRetention' -or
        $installerText -notmatch 'Install-SkillDockNodeEngine' -or
        $installerText -notmatch 'engine-location\.json'
    ) {
        throw "Runtime package installer predates shared Node or backup retention."
    }

    $rcManifest = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "RC-MANIFEST.json"
    ) | ConvertFrom-Json
    $packageManifest = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "PACKAGE-MANIFEST.json"
    ) | ConvertFrom-Json
    $sourceState = Get-Content -Raw -LiteralPath (
        Join-Path $packageRoot "SOURCE-STATE.json"
    ) | ConvertFrom-Json
    if (
        [string]$rcManifest.package_kind -ne "skilldock-runtime-only" -or
        [bool]$rcManifest.pchw_skill_included -or
        [string]$packageManifest.package_basename -ne $topLevelDirectories[0].Name
    ) {
        throw "Runtime package metadata is inconsistent."
    }

    $manifestLines = @(
        Get-Content -LiteralPath (Join-Path $packageRoot "MANIFEST.sha256")
    )
    foreach ($line in $manifestLines) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            throw "Runtime MANIFEST.sha256 is malformed."
        }
        $expected = $Matches[1]
        $relative = $Matches[2]
        $path = Join-Path $packageRoot $relative.Replace("/", "\")
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "MANIFEST entry is missing: $relative"
        }
        if ((Get-FileSha256 -Path $path) -ne $expected) {
            throw "MANIFEST digest differs: $relative"
        }
    }

    foreach ($entry in @($packageManifest.entries)) {
        $path = Join-Path (
            $packageRoot
        ) ([string]$entry.path).Replace("/", "\")
        if (
            -not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-Item -LiteralPath $path).Length -ne [int64]$entry.bytes -or
            (Get-FileSha256 -Path $path) -ne [string]$entry.sha256
        ) {
            throw "PACKAGE-MANIFEST entry differs: $($entry.path)"
        }
    }

    $verification = [ordered]@{
        schema_version = "1.0"
        status = "passed"
        package_kind = "skilldock-runtime-only"
        release_id = [string]$rcManifest.release_id
        package = [ordered]@{
            file = [IO.Path]::GetFileName($resolvedArchive)
            bytes = (Get-Item -LiteralPath $resolvedArchive).Length
            sha256 = $archiveSha256
            top_level = $topLevelDirectories[0].Name
            file_count = $packageManifest.file_count
        }
        source_integrated_rc_sha256 =
            [string]$sourceState.source_integrated_rc_sha256
        runtime_backup_retention = "current"
        clean_windows_install_uninstall = "pending"
        user_release_signoff = "pending"
        verified_at = [DateTimeOffset]::UtcNow.ToString("o")
    }
    if (-not [string]::IsNullOrWhiteSpace($VerificationPath)) {
        $resolvedVerification = [IO.Path]::GetFullPath($VerificationPath)
        $json = $verification | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText(
            $resolvedVerification,
            $json.Replace("`r`n", "`n") + "`n",
            (New-Object Text.UTF8Encoding($false))
        )
    }
    [pscustomobject]@{
        ok = $true
        status = "passed"
        release_id = $verification.release_id
        archive = $resolvedArchive
        archive_sha256 = $archiveSha256
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
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemp.StartsWith(
            $tempBase,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}
