. (Join-Path $PSScriptRoot "runtime-paths.ps1")

function Get-SkillDockFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return (($sha.ComputeHash($stream) | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $stream.Dispose()
        $sha.Dispose()
    }
}

function Get-SkillDockDataInventory {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject]@{
            exists = $false
            file_count = 0
            bytes = 0
            tree_sha256 = $null
            entries = @()
        }
    }
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force |
            Sort-Object FullName
    )) {
        $relative = $file.FullName.Substring($resolvedRoot.Length).
            TrimStart("\").
            Replace("\", "/")
        $hash = Get-SkillDockFileSha256 -Path $file.FullName
        $entries.Add([pscustomobject]@{
            path = $relative
            bytes = [int64]$file.Length
            sha256 = $hash
        }) | Out-Null
    }
    $text = (
        $entries |
            ForEach-Object {
                "$($_.sha256)  $($_.path)"
            }
    ) -join "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $treeHash = (($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($text + "`n")
        ) | ForEach-Object {
            $_.ToString("x2")
        }) -join "")
    }
    finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{
        exists = $true
        file_count = $entries.Count
        bytes = [int64](($entries | Measure-Object bytes -Sum).Sum)
        tree_sha256 = $treeHash
        entries = $entries.ToArray()
    }
}

function Test-SkillDockDataNonEmpty {
    param([Parameter(Mandatory = $true)][string]$Root)

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return $false
    }
    if (Test-Path -LiteralPath (Join-Path $Root "state.json") -PathType Leaf) {
        return $true
    }
    return @(
        Get-ChildItem -LiteralPath $Root -File -Recurse -Force
    ).Count -gt 0
}

function Copy-SkillDockDataDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        throw "Runtime data source is missing: $Source"
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($child in @(
        Get-ChildItem -LiteralPath $Source -Force
    )) {
        Copy-Item `
            -LiteralPath $child.FullName `
            -Destination $Destination `
            -Recurse `
            -Force
    }
}

function Assert-SkillDockDataCopy {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [string[]]$IgnoredDestinations = @()
    )

    $sourceInventory = Get-SkillDockDataInventory -Root $Source
    $destinationInventory = Get-SkillDockDataInventory -Root $Destination
    $ignored = @($IgnoredDestinations)
    foreach ($entry in $sourceInventory.entries) {
        if ($ignored -contains $entry.path) {
            continue
        }
        $match = $destinationInventory.entries |
            Where-Object { $_.path -eq $entry.path } |
            Select-Object -First 1
        if (
            $null -eq $match -or
            $match.bytes -ne $entry.bytes -or
            $match.sha256 -ne $entry.sha256
        ) {
            throw "Runtime data copy verification failed at $($entry.path)"
        }
    }
    return [pscustomobject]@{
        source = $sourceInventory
        destination = $destinationInventory
    }
}

function Get-AvailableDataPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $candidate = Join-Path $Root $Name
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }
    $index = 2
    do {
        $candidate = Join-Path $Root "$Name-$index"
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Invoke-SkillDockRuntimeDataMigration {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$DataBackupRoot,
        [ValidateSet("Auto", "PreferLegacy", "KeepCurrent")]
        [string]$Policy = "Auto",
        [string]$Timestamp = (Get-Date -Format "yyyyMMdd-HHmmss")
    )

    $resolvedLocalRoot = [IO.Path]::GetFullPath($LocalRoot).TrimEnd("\")
    $resolvedBackupRoot = [IO.Path]::GetFullPath(
        $DataBackupRoot
    ).TrimEnd("\")
    if (
        $resolvedBackupRoot.Equals(
            $resolvedLocalRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $resolvedBackupRoot.StartsWith(
            $resolvedLocalRoot + "\",
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "DataBackupRoot must stay outside LocalRoot"
    }

    $canonical = Get-SkillDockCanonicalRuntimeDirectory `
        -LocalRoot $resolvedLocalRoot
    $legacy = Get-SkillDockLegacyRuntimeDirectory `
        -LocalRoot $resolvedLocalRoot
    $markerPath = Join-Path $canonical "runtime-data-migration.json"
    if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
        return [pscustomobject]@{
            status = "already-migrated"
            canonical_root = $canonical
            legacy_root = $legacy
            marker = $markerPath
        }
    }
    if (-not (Test-Path -LiteralPath $legacy -PathType Container)) {
        return [pscustomobject]@{
            status = "no-legacy-data"
            canonical_root = $canonical
            legacy_root = $legacy
        }
    }

    $legacyNonEmpty = Test-SkillDockDataNonEmpty -Root $legacy
    $canonicalExists = Test-Path -LiteralPath $canonical -PathType Container
    $canonicalNonEmpty = if ($canonicalExists) {
        Test-SkillDockDataNonEmpty -Root $canonical
    }
    else {
        $false
    }
    if (-not $legacyNonEmpty) {
        return [pscustomobject]@{
            status = "legacy-empty"
            canonical_root = $canonical
            legacy_root = $legacy
        }
    }
    if ($Policy -eq "KeepCurrent") {
        return [pscustomobject]@{
            status = "kept-current"
            canonical_root = $canonical
            legacy_root = $legacy
            canonical_nonempty = $canonicalNonEmpty
        }
    }
    if ($canonicalNonEmpty -and $Policy -ne "PreferLegacy") {
        throw (
            "runtime_data_conflict: both runtime-pchw and runtime-dsh-web " +
            "contain data. No merge was attempted. Re-run with " +
            "-LegacyDataPolicy PreferLegacy after reviewing the backup plan."
        )
    }

    New-Item -ItemType Directory -Path $resolvedBackupRoot -Force |
        Out-Null
    $backupDirectory = Get-AvailableDataPath `
        -Root $resolvedBackupRoot `
        -Name "data-$Timestamp"
    New-Item -ItemType Directory -Path $backupDirectory | Out-Null
    $legacyBackup = Join-Path $backupDirectory "runtime-dsh-web"
    Copy-SkillDockDataDirectory -Source $legacy -Destination $legacyBackup
    $legacyComparison = Assert-SkillDockDataCopy `
        -Source $legacy `
        -Destination $legacyBackup
    $canonicalBackup = $null
    $canonicalComparison = $null
    if ($canonicalExists) {
        $canonicalBackup = Join-Path $backupDirectory "runtime-pchw"
        Copy-SkillDockDataDirectory `
            -Source $canonical `
            -Destination $canonicalBackup
        $canonicalComparison = Assert-SkillDockDataCopy `
            -Source $canonical `
            -Destination $canonicalBackup
    }
    $canonicalSourceInventory = $null
    if ($canonicalComparison) {
        $canonicalSourceInventory = $canonicalComparison.source
    }
    $backupEvidence = [pscustomobject]@{
        schema_version = "1.0"
        created_at = [DateTimeOffset]::Now.ToString("o")
        policy = $Policy
        legacy = $legacyComparison.source
        canonical = $canonicalSourceInventory
        backup_directory = $backupDirectory
    }
    $backupEvidencePath = Join-Path $backupDirectory "DATA-BACKUP.json"
    $backupEvidence | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $backupEvidencePath -Encoding UTF8

    $staging = Join-Path $resolvedLocalRoot (
        ".runtime-pchw-migrating-" + [guid]::NewGuid().ToString("N")
    )
    $rollback = Join-Path $resolvedLocalRoot (
        ".runtime-pchw-replaced-" + [guid]::NewGuid().ToString("N")
    )
    try {
        Copy-SkillDockDataDirectory -Source $legacy -Destination $staging
        [void](Assert-SkillDockDataCopy `
            -Source $legacy `
            -Destination $staging)
        $marker = [pscustomobject]@{
            schema_version = "1.0"
            status = "completed"
            migrated_at = [DateTimeOffset]::Now.ToString("o")
            policy = $Policy
            source_root = $legacy
            source_tree_sha256 = $legacyComparison.source.tree_sha256
            source_file_count = $legacyComparison.source.file_count
            backup_directory = $backupDirectory
        }
        $marker | ConvertTo-Json -Depth 6 | Set-Content `
            -LiteralPath (Join-Path $staging "runtime-data-migration.json") `
            -Encoding UTF8

        $movedCanonical = $false
        if ($canonicalExists) {
            Move-Item -LiteralPath $canonical -Destination $rollback
            $movedCanonical = $true
        }
        try {
            Move-Item -LiteralPath $staging -Destination $canonical
        }
        catch {
            if (
                $movedCanonical -and
                (Test-Path -LiteralPath $rollback) -and
                -not (Test-Path -LiteralPath $canonical)
            ) {
                Move-Item -LiteralPath $rollback -Destination $canonical
            }
            throw
        }
        if ($movedCanonical -and (Test-Path -LiteralPath $rollback)) {
            $replacedBackup = Join-Path `
                $backupDirectory `
                "runtime-pchw-active-before-migration"
            Move-Item -LiteralPath $rollback -Destination $replacedBackup
        }
    }
    finally {
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Recurse -Force
        }
    }

    $installedInventory = Get-SkillDockDataInventory -Root $canonical
    return [pscustomobject]@{
        status = "migrated"
        policy = $Policy
        canonical_root = $canonical
        legacy_root = $legacy
        backup_directory = $backupDirectory
        backup_evidence = $backupEvidencePath
        source_tree_sha256 = $legacyComparison.source.tree_sha256
        installed_tree_sha256 = $installedInventory.tree_sha256
        source_file_count = $legacyComparison.source.file_count
        installed_file_count = $installedInventory.file_count
    }
}
