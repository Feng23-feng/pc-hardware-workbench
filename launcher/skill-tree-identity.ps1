Set-StrictMode -Version Latest

function Get-Sha256HexFromFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

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

function Get-SkillTreeIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        throw "Skill tree root is missing: $resolvedRoot"
    }

    $items = @(Get-ChildItem `
        -LiteralPath $resolvedRoot `
        -Recurse `
        -Force `
        -ErrorAction Stop)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Skill tree contains a reparse point: $($item.FullName)"
        }
    }

    $relativePaths = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
        $relativePath = $file.FullName.Substring($resolvedRoot.Length).
            TrimStart("\").
            Replace("\", "/")
        if ($relativePath -eq "INSTALL-INFO.json") {
            continue
        }
        if ($relativePath.StartsWith(".git/", [StringComparison]::Ordinal)) {
            continue
        }
        $relativePaths.Add($relativePath)
    }

    $sortedPaths = [string[]]$relativePaths.ToArray()
    [Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
    $hashes = @{}
    foreach ($relativePath in $sortedPaths) {
        $absolutePath = Join-Path $resolvedRoot ($relativePath.Replace("/", "\"))
        $hashes[$relativePath] = Get-Sha256HexFromFile -Path $absolutePath
    }

    $manifestBuilder = New-Object System.Text.StringBuilder
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($relativePath in $sortedPaths) {
        $sha256 = $hashes[$relativePath]
        [void]$manifestBuilder.Append("$sha256  $relativePath`n")
        $files.Add([pscustomobject]@{
            path = $relativePath
            sha256 = $sha256
        })
    }

    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $manifestBytes = $utf8.GetBytes($manifestBuilder.ToString())
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $treeHash = [BitConverter]::ToString(
            $sha256.ComputeHash($manifestBytes)
        ).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    return [pscustomobject]@{
        root = $resolvedRoot
        tree_sha256 = $treeHash
        tree_file_count = $sortedPaths.Count
        files = $files.ToArray()
    }
}
