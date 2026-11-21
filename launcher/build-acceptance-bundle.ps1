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
$releaseConfigPath = Join-Path `
    $repositoryRoot `
    "release\$releaseVersion\release.json"
$releaseConfig = Get-Content -Raw -LiteralPath $releaseConfigPath |
    ConvertFrom-Json
$sourceBundleRoot = Join-Path `
    $repositoryRoot `
    "release\$releaseVersion\acceptance-bundle"
$shellRoot = Join-Path $PSScriptRoot "acceptance-shell"
$distRoot = [IO.Path]::GetFullPath(
    (Join-Path $repositoryRoot "dist")
).TrimEnd("\")
$resolvedRcArchive = [IO.Path]::GetFullPath($RcArchivePath)
$rcVerificationPath = [IO.Path]::ChangeExtension(
    $resolvedRcArchive,
    ".verification.json"
)
$rcSidecarPath = "$resolvedRcArchive.sha256"

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
        throw "Path escaped its root: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

function Get-ManifestEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [string[]]$Exclude = @()
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force
    )) {
        $relativePath = Get-RelativePath `
            -Root $Root `
            -FullName $file.FullName
        if ($Exclude -contains $relativePath) {
            continue
        }
        $entries.Add([pscustomobject]@{
            path = $relativePath
            bytes = $file.Length
            sha256 = Get-FileSha256 -Path $file.FullName
        }) | Out-Null
    }
    $sorted = [object[]]$entries.ToArray()
    $paths = [string[]]@($sorted | ForEach-Object { $_.path })
    [Array]::Sort($paths, [StringComparer]::Ordinal)
    return @(
        foreach ($path in $paths) {
            $sorted | Where-Object { $_.path -ceq $path } | Select-Object -First 1
        }
    )
}

function Read-ZipText {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryPath
    )

    $normalizedEntryPath = $EntryPath.Replace("\", "/")
    $entry = @(
        $Archive.Entries |
            Where-Object {
                $_.FullName.Replace("\", "/") -eq $normalizedEntryPath
            }
    ) | Select-Object -First 1
    if ($null -eq $entry) {
        throw "Required RC entry is missing: $EntryPath"
    }
    $reader = New-Object System.IO.StreamReader(
        $entry.Open(),
        (New-Object System.Text.UTF8Encoding($false, $true))
    )
    try {
        return $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
}

foreach ($required in @(
    $resolvedRcArchive,
    $rcSidecarPath,
    $rcVerificationPath,
    $releaseConfigPath,
    (Join-Path $sourceBundleRoot "Start-Acceptance.ps1"),
    (Join-Path $sourceBundleRoot "lib\Common.ps1"),
    (Join-Path $shellRoot "README-ACCEPTANCE.txt"),
    (Join-Path $shellRoot "Start-Acceptance.cmd")
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Acceptance bundle build input is missing: $required"
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
if ([string]$rcVerification.status -ne "passed") {
    throw "The RC verification receipt is not PASS."
}
if ([int64]$rcVerification.archive.bytes -ne $archiveBytes) {
    throw "The RC byte count differs from its verification receipt."
}
if ([string]$rcVerification.archive.sha256 -ne $archiveSha256) {
    throw "The RC SHA-256 differs from its verification receipt."
}
if (
    [string]$rcVerification.gates.source_commit -ne "local-uncommitted" -and
    -not $AllowDirtyLocalCandidate
) {
    if ([string]$rcVerification.gates.source_commit -ne "local-only") {
        throw "The RC source commit state is unexpected."
    }
}
if ([string]$rcVerification.gates.formal_release -ne "not-performed") {
    throw "The RC verification receipt unexpectedly claims a formal release."
}

$shortHash = $archiveSha256.Substring(0, 8)
$bundleBaseName =
    "SkillDock-Clean-Windows-Acceptance-Bundle-20261118-safe-upgrade-$shortHash"
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $distRoot $bundleBaseName
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
    $ArchivePath = Join-Path $distRoot "$bundleBaseName.zip"
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
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Acceptance output already exists: $OutputDirectory"
}
if (Test-Path -LiteralPath $ArchivePath) {
    throw "Acceptance archive already exists: $ArchivePath"
}
if ([string]::IsNullOrWhiteSpace($BuildReportPath)) {
    $BuildReportPath = "$ArchivePath.build-report.json"
}
$BuildReportPath = [IO.Path]::GetFullPath($BuildReportPath)
if (Test-Path -LiteralPath $BuildReportPath) {
    throw "Acceptance build report already exists: $BuildReportPath"
}

$temporaryRoot = Join-Path `
    $distRoot `
    (".$bundleBaseName-build-" + [guid]::NewGuid().ToString("N"))
$temporaryArchive = Join-Path `
    $distRoot `
    (".$bundleBaseName-build-" + [guid]::NewGuid().ToString("N") + ".zip")
$bundleRoot = Join-Path $temporaryRoot "SkillDockRC"
$payloadRoot = Join-Path $bundleRoot "payload"

try {
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null

    Copy-Item `
        -LiteralPath (Join-Path $shellRoot "README-ACCEPTANCE.txt") `
        -Destination (Join-Path $bundleRoot "README-ACCEPTANCE.txt")
    Copy-Item `
        -LiteralPath (Join-Path $shellRoot "Start-Acceptance.cmd") `
        -Destination (Join-Path $bundleRoot "Start-Acceptance.cmd")

    foreach ($item in @(
        Get-ChildItem -LiteralPath $sourceBundleRoot -Force
    )) {
        if ($item.Name -eq "BUNDLE-MANIFEST.sha256") {
            continue
        }
        Copy-Item `
            -LiteralPath $item.FullName `
            -Destination $payloadRoot `
            -Recurse `
            -Force
    }

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
    $sanitizedVerificationPath = Join-Path `
        $payloadRoot `
        ([IO.Path]::GetFileName($rcVerificationPath))
    Write-NormalizedJson `
        -Path $sanitizedVerificationPath `
        -Value $sanitizedVerification

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolvedRcArchive)
    try {
        $topLevel = New-Object System.Collections.Generic.HashSet[string]
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName.Replace("\", "/")
            if (
                [IO.Path]::IsPathRooted($name) -or
                ($name.Split("/") -contains "..")
            ) {
                throw "RC archive contains an unsafe path: $name"
            }
            $segment = $name.Split("/")[0]
            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                [void]$topLevel.Add($segment)
            }
        }
        $topLevelList = @($topLevel)
        $expectedPackageRoot = [string]$releaseConfig.package_basename
        if (
            $topLevelList.Count -ne 1 -or
            $topLevelList[0] -ne $expectedPackageRoot
        ) {
            throw "RC archive does not contain the expected package root."
        }
        foreach ($manifestName in @(
            "RC-MANIFEST.json",
            "SOURCE-STATE.json"
        )) {
            $text = Read-ZipText `
                -Archive $archive `
                -EntryPath "$expectedPackageRoot/$manifestName"
            Write-Utf8Text `
                -Path (Join-Path $payloadRoot $manifestName) `
                -Text ($text.Replace("`r`n", "`n"))
        }
        $rcManifestText = Read-ZipText `
            -Archive $archive `
            -EntryPath "$expectedPackageRoot/RC-MANIFEST.json"
        $rcManifest = $rcManifestText | ConvertFrom-Json
    }
    finally {
        $archive.Dispose()
    }

    $outerInfo = [ordered]@{
        schema_version = "1.0"
        product = [string]$rcManifest.product
        release_id = [string]$rcManifest.release_id
        outer_bundle_kind = "clean-windows-acceptance"
        bundle_layout = "README-ACCEPTANCE.txt, Start-Acceptance.cmd, and payload"
        created_at = [DateTimeOffset]::UtcNow.ToString("o")
        rc_archive = [ordered]@{
            file = [IO.Path]::GetFileName($resolvedRcArchive)
            bytes = $archiveBytes
            sha256 = $archiveSha256
        }
        versions = [ordered]@{
            skilldock = [string]$rcManifest.application_version
            pchw_skill = [string]$rcManifest.pchw_skill.version
            pchw_r7_source = [string]$rcManifest.pchw_skill.r7_source_version
            node = [string]$rcManifest.bundled_node_version
        }
        gates = [ordered]@{
            rc_hash_and_inventory = "passed"
            clean_windows_install_uninstall = "pending"
            clean_ui_user_acceptance = "pending"
            user_release_signoff = "pending"
            commit = [string]$rcManifest.gates.commit
            formal_release = "not-performed"
        }
        boundaries = [ordered]@{
            user_root_entries = @(
                "README-ACCEPTANCE.txt",
                "Start-Acceptance.cmd",
                "payload"
            )
            primary_entry = "Start-Acceptance.cmd"
            diagnostic_entries_under_payload_only = $true
            real_thread_created_by_builder = $false
            release_uploaded = $false
        }
    }
    Write-NormalizedJson `
        -Path (Join-Path $payloadRoot "OUTER-BUNDLE-INFO.json") `
        -Value $outerInfo

    $manifestEntries = Get-ManifestEntries -Root $payloadRoot
    $manifest = New-Object System.Text.StringBuilder
    foreach ($entry in $manifestEntries) {
        [void]$manifest.Append(
            "$($entry.sha256)  $($entry.path)`n"
        )
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
    if (Test-Path -LiteralPath $temporaryArchive -PathType Leaf) {
        Move-Item -LiteralPath $temporaryArchive -Destination $ArchivePath
    }
    else {
        throw "Acceptance archive creation did not produce an archive."
    }
    Move-Item -LiteralPath $bundleRoot -Destination $OutputDirectory

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
        release_id = $releaseVersion
        output_directory = $OutputDirectory
        archive = $ArchivePath
        archive_bytes = (Get-Item -LiteralPath $ArchivePath).Length
        archive_sha256 = $bundleSha256
        sidecar = $sidecarPath
        build_report = $BuildReportPath
        rc_sha256 = $archiveSha256
        payload_file_count = @(
            Get-ChildItem -LiteralPath $OutputDirectory -File -Recurse -Force
        ).Count
        primary_entry = "Start-Acceptance.cmd"
        clean_windows_acceptance = "pending"
        formal_release = "not-performed"
    }
    Write-NormalizedJson `
        -Path $BuildReportPath `
        -Value $buildResult
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
