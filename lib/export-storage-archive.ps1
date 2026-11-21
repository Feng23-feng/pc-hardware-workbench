[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SpecPath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
if ([string]$spec.schema_version -ne "1.0") {
    throw "Storage export spec schema is unsupported."
}
if (
    [string]::IsNullOrWhiteSpace([string]$spec.kind) -or
    [string]::IsNullOrWhiteSpace([string]$spec.title) -or
    $null -eq $spec.entries
) {
    throw "Storage export spec is incomplete."
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return (
            [BitConverter]::ToString($sha256.ComputeHash($stream)) -replace "-", ""
        ).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Add-ArchiveEntry {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.Compression.ZipArchive]$Archive,

        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ArchivePath
    )

    $normalizedArchivePath = $ArchivePath.Replace("\", "/").TrimStart("/")
    if ([string]::IsNullOrWhiteSpace($normalizedArchivePath)) {
        throw "Archive entry path is empty."
    }
    $entry = $Archive.CreateEntry(
        $normalizedArchivePath,
        [IO.Compression.CompressionLevel]::Optimal
    )
    $entry.LastWriteTime = [IO.File]::GetLastWriteTime($SourcePath)
    $input = [IO.File]::OpenRead($SourcePath)
    $output = $entry.Open()
    try {
        $input.CopyTo($output)
    }
    finally {
        $output.Dispose()
        $input.Dispose()
    }
}

$excludedPaths = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($excludePath in @($spec.excluded_paths)) {
    if ([string]::IsNullOrWhiteSpace([string]$excludePath)) {
        continue
    }
    [void]$excludedPaths.Add(
        [IO.Path]::GetFullPath([string]$excludePath).ToLowerInvariant()
    )
}

$files = New-Object System.Collections.Generic.List[object]
$archivePaths = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($entrySpec in @($spec.entries)) {
    $sourcePath = [IO.Path]::GetFullPath([string]$entrySpec.source_path)
    $archiveRoot = ([string]$entrySpec.archive_path).
        Replace("\", "/").
        Trim("/")
    if ([string]::IsNullOrWhiteSpace($archiveRoot)) {
        throw "Storage export entry archive path is empty."
    }
    if (-not (Test-Path -LiteralPath $sourcePath)) {
        throw "Storage export source is missing: $sourcePath"
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    if (
        ($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    ) {
        throw "Storage export source cannot be a reparse point: $sourcePath"
    }
    if ($sourceItem.PSIsContainer) {
        $pending = New-Object 'System.Collections.Generic.Stack[string]'
        $pending.Push($sourcePath)
        while ($pending.Count -gt 0) {
            $directory = $pending.Pop()
            foreach ($child in @(
                Get-ChildItem -LiteralPath $directory -Force
            )) {
                if (
                    ($child.Attributes -band
                        [IO.FileAttributes]::ReparsePoint) -ne 0
                ) {
                    throw (
                        "Storage export source contains a reparse point: " +
                        $child.FullName
                    )
                }
                if ($child.PSIsContainer) {
                    $pending.Push($child.FullName)
                    continue
                }
                $files.Add([pscustomobject]@{
                    SourcePath = $child.FullName
                    RelativePath =
                        $child.FullName.Substring($sourcePath.Length).
                            TrimStart("\", "/")
                    ArchiveRoot = $archiveRoot
                }) | Out-Null
            }
        }
    }
    else {
        $files.Add([pscustomobject]@{
            SourcePath = $sourcePath
            RelativePath = ""
            ArchiveRoot = $archiveRoot
        }) | Out-Null
    }
}

$manifestEntries = New-Object System.Collections.Generic.List[object]
$orderedFiles = @($files | Sort-Object {
    "$($_.ArchiveRoot)/$($_.RelativePath)"
})
$outputDirectory = Split-Path -Parent ([IO.Path]::GetFullPath($OutputPath))
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
$temporaryDirectory = Join-Path (
    [IO.Path]::GetTempPath()
) ("skilldock-export-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null
$archive = $null
try {
    foreach ($file in $orderedFiles) {
        $fullSource = [IO.Path]::GetFullPath($file.SourcePath)
        if ($excludedPaths.Contains($fullSource.ToLowerInvariant())) {
            continue
        }
        $archivePath = if ([string]::IsNullOrWhiteSpace($file.RelativePath)) {
            $file.ArchiveRoot
        }
        else {
            $file.ArchiveRoot + "/" + $file.RelativePath.Replace("\", "/")
        }
        if (-not $archivePaths.Add($archivePath)) {
            throw "Duplicate storage export archive path: $archivePath"
        }
        $fileInfo = Get-Item -LiteralPath $fullSource -Force
        $manifestEntries.Add([ordered]@{
            path = $archivePath
            bytes = [int64]$fileInfo.Length
            sha256 = Get-Sha256 -Path $fullSource
        }) | Out-Null
    }

    $manifest = [ordered]@{
        schema_version = "1.0"
        kind = [string]$spec.kind
        title = [string]$spec.title
        created_at = [DateTimeOffset]::Now.ToString("o")
        metadata = $spec.metadata
        file_count = $manifestEntries.Count
        entries = @($manifestEntries.ToArray())
    }
    $manifestPath = Join-Path $temporaryDirectory "EXPORT-MANIFEST.json"
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $manifestPath,
        (($manifest | ConvertTo-Json -Depth 10) + "`n"),
        $encoding
    )
    $readmePath = Join-Path $temporaryDirectory "README.txt"
    [IO.File]::WriteAllText(
        $readmePath,
        (
            "$($manifest.title)`n`n" +
            "This archive was created locally by SkillDock.`n" +
            "Created: $($manifest.created_at)`n" +
            "Files: $($manifest.file_count)`n`n" +
            "EXPORT-MANIFEST.json records each file size and SHA-256.`n"
        ),
        $encoding
    )

    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
    $archive = [IO.Compression.ZipFile]::Open(
        [IO.Path]::GetFullPath($OutputPath),
        [IO.Compression.ZipArchiveMode]::Create
    )
    foreach ($file in $orderedFiles) {
        $fullSource = [IO.Path]::GetFullPath($file.SourcePath)
        if ($excludedPaths.Contains($fullSource.ToLowerInvariant())) {
            continue
        }
        Add-ArchiveEntry `
            -Archive $archive `
            -SourcePath $fullSource `
            -ArchivePath $(if (
                [string]::IsNullOrWhiteSpace($file.RelativePath)
            ) {
                $file.ArchiveRoot
            }
            else {
                $file.ArchiveRoot + "/" +
                    $file.RelativePath.Replace("\", "/")
            })
    }
    Add-ArchiveEntry `
        -Archive $archive `
        -SourcePath $manifestPath `
        -ArchivePath "EXPORT-MANIFEST.json"
    Add-ArchiveEntry `
        -Archive $archive `
        -SourcePath $readmePath `
        -ArchivePath "README.txt"
    $archive.Dispose()
    $archive = $null

    [pscustomobject]@{
        ok = $true
        kind = [string]$spec.kind
        output_path = [IO.Path]::GetFullPath($OutputPath)
        bytes = (Get-Item -LiteralPath $OutputPath).Length
        file_count = $manifestEntries.Count
    } | ConvertTo-Json -Compress
}
finally {
    if ($null -ne $archive) {
        $archive.Dispose()
    }
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}
