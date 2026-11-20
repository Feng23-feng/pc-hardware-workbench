Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:BundleRoot = Split-Path -Parent $PSScriptRoot
$script:ReleaseVersion = "0.1.0-rc.2"
$script:PackageBaseName = "SkillDock-PCHW-0.1.0-rc.2-win-x64"
$script:OuterInfoPath = Join-Path $script:BundleRoot "OUTER-BUNDLE-INFO.json"
if (-not (Test-Path -LiteralPath $script:OuterInfoPath -PathType Leaf)) {
    throw "OUTER-BUNDLE-INFO.json is missing."
}
$script:OuterInfo = Get-Content -Raw -LiteralPath $script:OuterInfoPath |
    ConvertFrom-Json
$script:ArchiveFileName = [string]$script:OuterInfo.rc_archive.file
if ([string]::IsNullOrWhiteSpace($script:ArchiveFileName)) {
    throw "OUTER-BUNDLE-INFO.json does not name the RC archive."
}
$script:ArchiveBaseName = [IO.Path]::GetFileNameWithoutExtension(
    $script:ArchiveFileName
)
$script:ExpectedArchiveBytes = [int64]$script:OuterInfo.rc_archive.bytes
$script:ExpectedArchiveSha256 = [string]$script:OuterInfo.rc_archive.sha256
if (
    $script:ExpectedArchiveBytes -le 0 -or
    $script:ExpectedArchiveSha256 -notmatch "^[a-f0-9]{64}$"
) {
    throw "OUTER-BUNDLE-INFO.json has an invalid RC archive identity."
}

function Get-BundlePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    return [IO.Path]::GetFullPath((Join-Path $script:BundleRoot $RelativePath))
}

function Assert-UnderBundle {
    param([Parameter(Mandatory = $true)][string]$Path)

    $root = [IO.Path]::GetFullPath($script:BundleRoot).TrimEnd("\")
    $resolved = [IO.Path]::GetFullPath($Path)
    if (-not $resolved.StartsWith(
        $root + "\",
        [StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Path is outside the acceptance bundle: $resolved"
    }
    return $resolved
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Append-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($Path, $Text, $encoding)
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).
        Hash.ToLowerInvariant()
}

function Get-ArchivePath {
    return Get-BundlePath "$script:ArchiveBaseName.zip"
}

function Get-ArchiveSidecarPath {
    return Get-BundlePath "$script:ArchiveBaseName.zip.sha256"
}

function Assert-ArchiveIdentity {
    $archive = Get-ArchivePath
    $sidecar = Get-ArchiveSidecarPath
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
        throw "Final RC archive is missing: $archive"
    }
    if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) {
        throw "Final RC SHA-256 sidecar is missing: $sidecar"
    }
    $fields = @(
        (Get-Content -Raw -LiteralPath $sidecar).Trim() -split "\s+"
    )
    if ($fields.Count -lt 1 -or $fields[0] -notmatch "^[a-f0-9]{64}$") {
        throw "Final RC SHA-256 sidecar is malformed."
    }
    $actual = Get-Sha256Hex -Path $archive
    if ($actual -ne $fields[0].ToLowerInvariant()) {
        throw "Archive SHA-256 does not match its sidecar."
    }
    $actualBytes = (Get-Item -LiteralPath $archive).Length
    if ($actualBytes -ne $script:ExpectedArchiveBytes) {
        throw "Archive byte count does not match the pinned acceptance package."
    }
    if ($actual -ne $script:ExpectedArchiveSha256) {
        throw "Archive SHA-256 does not match the pinned acceptance package."
    }
    return [pscustomobject]@{
        archive = $archive
        sidecar = $sidecar
        bytes = $actualBytes
        sha256 = $actual
    }
}

function Get-EvidenceRoot {
    $path = Assert-UnderBundle -Path (Get-BundlePath "evidence")
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function Invoke-PowerShellScript {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "PowerShell script is missing: $ScriptPath"
    }
    $output = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScriptPath `
            @Arguments 2>&1
    )
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else {
        [int]$LASTEXITCODE
    }
    $text = ($output | Out-String)
    Append-Utf8Text `
        -Path $LogPath `
        -Text ("`n===== " + $ScriptPath + "`n" + $text)
    if ($exitCode -ne 0) {
        throw "Script failed with exit code $exitCode`: $ScriptPath"
    }
    return [pscustomobject]@{
        exit_code = $exitCode
        text = $text
    }
}
