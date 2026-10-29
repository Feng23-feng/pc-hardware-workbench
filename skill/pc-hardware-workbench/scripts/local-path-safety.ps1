function Test-PathChainHasReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = [System.IO.Path]::GetFullPath($Path)
    $pathRoot = [System.IO.Path]::GetPathRoot($candidate)
    if ([string]::IsNullOrWhiteSpace($pathRoot)) {
        throw "Could not determine the filesystem root for path validation."
    }

    $current = Get-Item -LiteralPath $pathRoot -Force -ErrorAction Stop
    if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return $true
    }

    $relative = $candidate.Substring($pathRoot.Length)
    foreach ($segment in @($relative -split '[\\/]+' | Where-Object { $_ })) {
        $next = Join-Path $current.FullName $segment
        $nextItem = Get-Item -LiteralPath $next -Force -ErrorAction SilentlyContinue
        if ($null -eq $nextItem) {
            break
        }
        $current = $nextItem
        if (($current.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

function ConvertTo-LocalFilesystemPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^\\\\') {
        throw "Only local filesystem paths are accepted. UNC and network paths are rejected."
    }
    $candidate = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    }
    else {
        Join-Path (Get-Location).Path $Path
    }
    $candidate = [System.IO.Path]::GetFullPath($candidate)
    $pathRoot = [System.IO.Path]::GetPathRoot($candidate)
    if (-not [string]::IsNullOrWhiteSpace($pathRoot)) {
        try {
            $driveInfo = New-Object System.IO.DriveInfo($pathRoot)
            if ($driveInfo.DriveType -eq [System.IO.DriveType]::Network) {
                throw "Mapped network drives are rejected."
            }
        }
        catch {
            if ($_.Exception.Message -match "Mapped network drives are rejected") {
                throw
            }
            throw "Could not verify that the path is local: $($_.Exception.Message)"
        }
    }
    return $candidate
}

function Assert-LocalReadFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = ConvertTo-LocalFilesystemPath -Path $Path
    if (Test-PathChainHasReparsePoint -Path $candidate) {
        throw "Telemetry input resolves through a symbolic link, junction, or reparse point. Materialize it to a regular local file first."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Telemetry file not found: $Path"
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Resolve-LocalOutputFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = ConvertTo-LocalFilesystemPath -Path $Path
    if (Test-PathChainHasReparsePoint -Path $candidate) {
        throw "OutputPath resolves through a symbolic link, junction, or reparse point. Use a regular local directory."
    }
    $parent = Split-Path -Parent $candidate
    if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Output directory does not exist: $parent"
    }
    if (Test-Path -LiteralPath $candidate) {
        throw "OutputPath already exists and will not be overwritten: $candidate"
    }
    return $candidate
}

function Write-LocalOutputFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content,
        [switch]$IncludeUtf8Bom
    )

    $resolved = Resolve-LocalOutputFilePath -Path $Path
    $encoding = New-Object System.Text.UTF8Encoding([bool]$IncludeUtf8Bom)
    $stream = [System.IO.File]::Open(
        $resolved,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None
    )
    try {
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        try {
            $writer.Write($Content)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $resolved
}
