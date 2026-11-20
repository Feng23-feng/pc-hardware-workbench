[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RcArchivePath,

    [string]$OutputDirectory = "",

    [string]$ArchivePath = "",

    [string]$BuildReportPath = "",

    [switch]$AllowDirtyLocalCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$releaseVersion = [string](
    Get-Content -Raw -LiteralPath (Join-Path $repositoryRoot "package.json") |
        ConvertFrom-Json
).version
$releaseConfig = Get-Content -Raw -LiteralPath (
    Join-Path $repositoryRoot "release\$releaseVersion\release.json"
) | ConvertFrom-Json
$userShellRoot = Join-Path $PSScriptRoot "user-shell"
$distRoot = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "dist")
).TrimEnd("\")
$resolvedRcArchive = [IO.Path]::GetFullPath($RcArchivePath)
$rcSidecarPath = "$resolvedRcArchive.sha256"
$rcVerificationPath = [IO.Path]::ChangeExtension(
    $resolvedRcArchive,
    ".verification.json"
)
$packageBaseName = "$([string]$releaseConfig.package_basename)-user"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $distRoot $packageBaseName
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd("\")
if (
    -not $OutputDirectory.StartsWith(
        $distRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "OutputDirectory must stay inside $distRoot"
}
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Join-Path $distRoot "$packageBaseName.zip"
}
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
if (
    -not $ArchivePath.StartsWith(
        $distRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "ArchivePath must stay inside $distRoot"
}
if ([string]::IsNullOrWhiteSpace($BuildReportPath)) {
    $BuildReportPath = "$ArchivePath.build-report.json"
}
$BuildReportPath = [IO.Path]::GetFullPath($BuildReportPath)
if (
    -not $BuildReportPath.StartsWith(
        $distRoot + "\",
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "BuildReportPath must stay inside $distRoot"
}
foreach ($path in @(
    $OutputDirectory,
    $ArchivePath,
    $BuildReportPath,
    "$ArchivePath.sha256"
)) {
    if (Test-Path -LiteralPath $path) {
        throw "User package output already exists: $path"
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).
        Hash.ToLowerInvariant()
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Write-Utf8BomText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($true)
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
        throw "Path escaped its root: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

function Get-ManifestEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force
    )) {
        $relativePath = Get-RelativePath -Root $Root -FullName $file.FullName
        if ($relativePath -ceq "BUNDLE-MANIFEST.sha256") {
            continue
        }
        $entries.Add([pscustomobject]@{
            path = $relativePath
            bytes = $file.Length
            sha256 = Get-FileSha256 -Path $file.FullName
        }) | Out-Null
    }
    $values = [object[]]$entries.ToArray()
    $paths = [string[]]@($values | ForEach-Object { $_.path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    return @(
        foreach ($path in $paths) {
            $values | Where-Object { $_.path -ceq $path } | Select-Object -First 1
        }
    )
}

foreach ($required in @(
    $resolvedRcArchive,
    $rcSidecarPath,
    $rcVerificationPath,
    (Join-Path $userShellRoot "README.txt"),
    (Join-Path $userShellRoot "README.en.txt"),
    (Join-Path $userShellRoot "Install.cmd"),
    (Join-Path $userShellRoot "Install-User.ps1")
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "User package build input is missing: $required"
    }
}

$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $rcSidecarPath).Trim() -split "\s+"
)
if (
    $sidecarFields.Count -lt 1 -or
    $sidecarFields[0] -notmatch "^[a-f0-9]{64}$"
) {
    throw "The RC sidecar is malformed."
}
$archiveBytes = (Get-Item -LiteralPath $resolvedRcArchive).Length
$archiveSha256 = Get-FileSha256 -Path $resolvedRcArchive
if ($archiveSha256 -ne $sidecarFields[0].ToLowerInvariant()) {
    throw "The RC SHA-256 does not match its sidecar."
}
$rcVerification = Get-Content -Raw -LiteralPath $rcVerificationPath |
    ConvertFrom-Json
if (
    [string]$rcVerification.status -ne "passed" -or
    [int64]$rcVerification.archive.bytes -ne $archiveBytes -or
    [string]$rcVerification.archive.sha256 -ne $archiveSha256
) {
    throw "The RC verification receipt does not match the archive."
}
if (
    [string]$rcVerification.gates.source_commit -eq "local-uncommitted" -and
    -not $AllowDirtyLocalCandidate
) {
    throw "Dirty local candidate requires explicit allowance."
}
if ([string]$rcVerification.gates.formal_release -ne "not-performed") {
    throw "The RC unexpectedly claims a formal release."
}

$temporaryRoot = Join-Path `
    $distRoot `
    (".${packageBaseName}-build-" + [guid]::NewGuid().ToString("N"))
$temporaryArchive = Join-Path `
    $distRoot `
    (".${packageBaseName}-build-" + [guid]::NewGuid().ToString("N") + ".zip")
$packageRoot = Join-Path $temporaryRoot $packageBaseName
$payloadRoot = Join-Path $packageRoot "payload"

try {
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
    foreach ($name in @("README.txt", "README.en.txt", "Install.cmd")) {
        Copy-Item `
            -LiteralPath (Join-Path $userShellRoot $name) `
            -Destination (Join-Path $packageRoot $name)
    }
    $userInstallerTarget = Join-Path $payloadRoot "Install-User.ps1"
    $userInstallerText = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $userShellRoot "Install-User.ps1") `
        -Encoding UTF8
    Write-Utf8BomText `
        -Path $userInstallerTarget `
        -Text $userInstallerText.Replace("`r`n", "`n")
    Copy-Item `
        -LiteralPath $resolvedRcArchive `
        -Destination (Join-Path $payloadRoot (
            [IO.Path]::GetFileName($resolvedRcArchive)
        ))
    Copy-Item `
        -LiteralPath $rcSidecarPath `
        -Destination (Join-Path $payloadRoot (
            [IO.Path]::GetFileName($rcSidecarPath)
        ))

    $sanitizedVerification = [ordered]@{
        schema_version = [string]$rcVerification.schema_version
        status = [string]$rcVerification.status
        release_id = [string]$rcVerification.release_id
        package_basename = [string]$rcVerification.package_basename
        archive = [ordered]@{
            file = [IO.Path]::GetFileName($resolvedRcArchive)
            bytes = [int64]$archiveBytes
            sha256 = $archiveSha256
        }
        package = $rcVerification.package
        versions = $rcVerification.versions
        identities = $rcVerification.identities
        gates = $rcVerification.gates
        boundaries = $rcVerification.boundaries
        verified_at = [string]$rcVerification.verified_at
    }
    Write-NormalizedJson `
        -Path (Join-Path $payloadRoot (
            [IO.Path]::GetFileName($rcVerificationPath)
        )) `
        -Value $sanitizedVerification

    $packageInfo = [ordered]@{
        schema_version = "1.0"
        package_kind = "integrated-user-installation"
        package_base = [string]$rcVerification.package_basename
        primary_entry = "Install.cmd"
        root_entries = @(
            "README.txt",
            "README.en.txt",
            "Install.cmd",
            "payload"
        )
        rc_archive = [ordered]@{
            file = [IO.Path]::GetFileName($resolvedRcArchive)
            bytes = $archiveBytes
            sha256 = $archiveSha256
        }
        versions = [ordered]@{
            skilldock = [string]$releaseConfig.application_version
            pchw_skill = [string]$releaseConfig.pchw_skill_version
            node = [string]$releaseConfig.bundled_node_version
        }
        behavior = [ordered]@{
            automatic_mode_detection = $true
            automatic_existing_skill_backup = $true
            automatic_skill_restore_on_later_failure = $true
            writes_outside_user_profile = $false
        }
        boundaries = [ordered]@{
            acceptance_scripts_in_user_root = $false
            test_fixture_in_user_package = $false
            dsh_entry_in_user_package = $false
            real_thread_created_by_installer = $false
        }
    }
    Write-NormalizedJson `
        -Path (Join-Path $payloadRoot "PACKAGE-INFO.json") `
        -Value $packageInfo

    $manifestEntries = Get-ManifestEntries -Root $payloadRoot
    $manifest = New-Object System.Text.StringBuilder
    foreach ($entry in $manifestEntries) {
        [void]$manifest.Append("$($entry.sha256)  $($entry.path)`n")
    }
    Write-Utf8Text `
        -Path (Join-Path $payloadRoot "BUNDLE-MANIFEST.sha256") `
        -Text $manifest.ToString()

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory(
        $temporaryRoot,
        $temporaryArchive,
        [IO.Compression.CompressionLevel]::Optimal,
        $false
    )
    if (-not (Test-Path -LiteralPath $temporaryArchive -PathType Leaf)) {
        throw "User package archive creation did not produce an archive."
    }
    Move-Item -LiteralPath $temporaryArchive -Destination $ArchivePath
    Move-Item -LiteralPath $packageRoot -Destination $OutputDirectory

    $bundleSha256 = Get-FileSha256 -Path $ArchivePath
    $sidecarPath = "$ArchivePath.sha256"
    Write-Utf8Text `
        -Path $sidecarPath `
        -Text (
            "$bundleSha256  " +
            [IO.Path]::GetFileName($ArchivePath) +
            "`n"
        )
    $buildResult = [pscustomobject]@{
        ok = $true
        status = "built-pending-verification"
        package_kind = "integrated-user-installation"
        release_id = $releaseVersion
        output_directory = $OutputDirectory
        archive = $ArchivePath
        archive_bytes = (Get-Item -LiteralPath $ArchivePath).Length
        archive_sha256 = $bundleSha256
        sidecar = $sidecarPath
        verification = "$ArchivePath.verification.json"
        build_report = $BuildReportPath
        rc_sha256 = $archiveSha256
        root_entries = @(
            "README.txt",
            "README.en.txt",
            "Install.cmd",
            "payload"
        )
        primary_entry = "Install.cmd"
    }
    Write-NormalizedJson -Path $BuildReportPath -Value $buildResult
    $buildResult | ConvertTo-Json -Depth 5
}
finally {
    foreach ($path in @($temporaryRoot, $temporaryArchive)) {
        if (Test-Path -LiteralPath $path) {
            $resolvedPath = [IO.Path]::GetFullPath($path)
            if (
                $resolvedPath.StartsWith(
                    $distRoot + "\",
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                Remove-Item -LiteralPath $resolvedPath -Recurse -Force
            }
        }
    }
}
