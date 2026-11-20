param(
    [string]$SourceDirectory = "",
    [string]$TargetDirectory = "",
    [string]$LocalRoot = "",
    [string]$BackupRoot = "",
    [string]$DataBackupRoot = "",
    [ValidateSet("Auto", "PreferLegacy", "KeepCurrent")]
    [string]$LegacyDataPolicy = "Auto",
    [ValidateRange(1, 20)]
    [int]$RetainRuntimeBackups = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "runtime-paths.ps1")
. (Join-Path $PSScriptRoot "runtime-data-migration.ps1")

function Get-AvailableBackupPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$PreferredName
    )

    $candidate = Join-Path $Root $PreferredName
    if (-not (Test-Path -LiteralPath $candidate)) {
        return $candidate
    }
    $index = 2
    do {
        $candidate = Join-Path $Root "$PreferredName-$index"
        $index++
    } while (Test-Path -LiteralPath $candidate)
    return $candidate
}

function Assert-NoReparsePointInPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    foreach ($segment in ($fullPath.Substring($root.Length) -split '[\\/]')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Backup path cannot traverse a reparse point: $current"
        }
    }
}

function Write-Utf8Json {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 8) + "`n"),
        $encoding
    )
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($stream)
        return (
            [BitConverter]::ToString($digest) -replace '-', ''
        ).ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Test-SkillDockEngineDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$EngineDirectory,
        [Parameter(Mandatory = $true)][string]$EngineId,
        [Parameter(Mandatory = $true)][string]$NodeVersion,
        [Parameter(Mandatory = $true)][string]$NodeSha256
    )

    $resolvedEngine = [IO.Path]::GetFullPath(
        $EngineDirectory
    ).TrimEnd('\')
    if (
        -not (Test-Path -LiteralPath $resolvedEngine -PathType Container) -or
        (
            (Get-Item -LiteralPath $resolvedEngine -Force).Attributes -band
                [IO.FileAttributes]::ReparsePoint
        ) -ne 0
    ) {
        throw "Shared Node engine directory is missing or unsafe: $resolvedEngine"
    }
    $metadataPath = Join-Path $resolvedEngine "ENGINE.json"
    $nodePath = Join-Path $resolvedEngine "node.exe"
    if (
        -not (Test-Path -LiteralPath $metadataPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $nodePath -PathType Leaf)
    ) {
        throw "Shared Node engine files are incomplete: $resolvedEngine"
    }
    $metadata = Get-Content -Raw -LiteralPath $metadataPath | ConvertFrom-Json
    if (
        [string]$metadata.schema_version -ne "1.0" -or
        [string]$metadata.engine_id -ne $EngineId -or
        [string]$metadata.node_version -ne $NodeVersion -or
        [string]$metadata.node_sha256 -ne $NodeSha256 -or
        [string]$metadata.node_path -ne $nodePath
    ) {
        throw "Shared Node engine metadata does not match its identity: $resolvedEngine"
    }
    $actualSha256 = Get-FileSha256 -Path $nodePath
    if ($actualSha256 -ne $NodeSha256) {
        throw "Shared Node engine digest does not match its metadata: $nodePath"
    }
    return [pscustomobject][ordered]@{
        schema_version = "1.0"
        engine_id = $EngineId
        engine_path = $resolvedEngine
        node_path = $nodePath
        node_version = $NodeVersion
        node_sha256 = $NodeSha256
        reused = $true
    }
}

function Install-SkillDockNodeEngine {
    param(
        [Parameter(Mandatory = $true)][string]$SourceNodePath,
        [Parameter(Mandatory = $true)][string]$SourceLicensePath,
        [Parameter(Mandatory = $true)][string]$LocalRoot
    )

    if (-not (Test-Path -LiteralPath $SourceNodePath -PathType Leaf)) {
        throw "Source package does not contain node\node.exe."
    }
    $nodeSha256 = Get-FileSha256 -Path $SourceNodePath
    $nodeVersion = [string](& $SourceNodePath --version 2>$null)
    if ($LASTEXITCODE -ne 0 -or $nodeVersion.Trim() -notmatch '^v\d+\.\d+\.\d+$') {
        throw "Source Node engine did not return a valid version."
    }
    $nodeVersion = $nodeVersion.Trim()
    $safeVersion = $nodeVersion.TrimStart('v')
    $engineId = "node-$safeVersion-$($nodeSha256.Substring(0, 16))"
    $engineRoot = Get-SkillDockEngineRoot -LocalRoot $LocalRoot
    Assert-NoReparsePointInPath -Path $engineRoot
    New-Item -ItemType Directory -Path $engineRoot -Force | Out-Null
    $engineDirectory = Join-Path $engineRoot $engineId
    if (Test-Path -LiteralPath $engineDirectory) {
        return Test-SkillDockEngineDirectory `
            -EngineDirectory $engineDirectory `
            -EngineId $engineId `
            -NodeVersion $nodeVersion `
            -NodeSha256 $nodeSha256
    }

    $stagingDirectory = Join-Path `
        $engineRoot `
        (".node-engine-" + [guid]::NewGuid().ToString("N") + ".tmp")
    try {
        New-Item -ItemType Directory -Path $stagingDirectory | Out-Null
        $stagedNodePath = Join-Path $stagingDirectory "node.exe"
        Copy-Item `
            -LiteralPath $SourceNodePath `
            -Destination $stagedNodePath `
            -Force
        if (Test-Path -LiteralPath $SourceLicensePath -PathType Leaf) {
            Copy-Item `
                -LiteralPath $SourceLicensePath `
                -Destination (Join-Path $stagingDirectory "LICENSE") `
                -Force
        }
        Write-Utf8Json `
            -Path (Join-Path $stagingDirectory "ENGINE.json") `
            -Value ([ordered]@{
                schema_version = "1.0"
                engine_id = $engineId
                node_version = $nodeVersion
                node_sha256 = $nodeSha256
                node_path = (Join-Path $engineDirectory "node.exe")
                installed_at = [DateTimeOffset]::Now.ToString("o")
            })
        $stagedSha256 = Get-FileSha256 -Path $stagedNodePath
        if ($stagedSha256 -ne $nodeSha256) {
            throw "Staged shared Node engine digest changed during copy."
        }
        try {
            Move-Item `
                -LiteralPath $stagingDirectory `
                -Destination $engineDirectory
        }
        catch {
            if (-not (Test-Path -LiteralPath $engineDirectory)) {
                throw
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $stagingDirectory) {
            Remove-Item -LiteralPath $stagingDirectory -Recurse -Force
        }
    }

    $installed = Test-SkillDockEngineDirectory `
        -EngineDirectory $engineDirectory `
        -EngineId $engineId `
        -NodeVersion $nodeVersion `
        -NodeSha256 $nodeSha256
    return [pscustomobject][ordered]@{
        schema_version = $installed.schema_version
        engine_id = $installed.engine_id
        engine_path = $installed.engine_path
        node_path = $installed.node_path
        node_version = $installed.node_version
        node_sha256 = $installed.node_sha256
        reused = $false
    }
}

function Get-ReferencedSkillDockEngineIds {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $ids = New-Object 'System.Collections.Generic.HashSet[string]'
    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($root in @($LocalRoot, $BackupRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($runtimeDirectory in @(
            Get-ChildItem -LiteralPath $root -Directory -Force |
                Where-Object { $_.Name -cmatch '^Runtime(?:-|$)' }
        )) {
            $referencePath = Join-Path `
                $runtimeDirectory.FullName `
                "engine-location.json"
            if (-not (Test-Path -LiteralPath $referencePath -PathType Leaf)) {
                continue
            }
            try {
                $reference = Get-Content `
                    -Raw `
                    -LiteralPath $referencePath | ConvertFrom-Json
                $engineId = [string]$reference.engine_id
                if (
                    [string]$reference.schema_version -ne "1.0" -or
                    [string]::IsNullOrWhiteSpace($engineId)
                ) {
                    throw "Malformed shared Node engine reference."
                }
                [void]$ids.Add($engineId)
            }
            catch {
                $failures.Add([pscustomobject]@{
                    path = $referencePath
                    error = [string]$_.Exception.Message
                }) | Out-Null
            }
        }
    }
    return [pscustomobject]@{
        complete = $failures.Count -eq 0
        ids = @($ids)
        failures = @($failures.ToArray())
    }
}

function Invoke-SkillDockEngineRetention {
    param(
        [Parameter(Mandatory = $true)][string]$LocalRoot,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )

    $references = Get-ReferencedSkillDockEngineIds `
        -LocalRoot $LocalRoot `
        -BackupRoot $BackupRoot
    $removed = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[object]
    if (-not $references.complete) {
        return [pscustomobject]@{
            retained = @($references.ids)
            removed = @()
            failures = @($references.failures)
        }
    }
    $engineRoot = Get-SkillDockEngineRoot -LocalRoot $LocalRoot
    if (-not (Test-Path -LiteralPath $engineRoot -PathType Container)) {
        return [pscustomobject]@{
            retained = @($references.ids)
            removed = @()
            failures = @()
        }
    }
    $referenced = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($engineId in @($references.ids)) {
        [void]$referenced.Add([string]$engineId)
    }
    foreach ($engineDirectory in @(
        Get-ChildItem -LiteralPath $engineRoot -Directory -Force |
            Where-Object {
                $_.Name -cmatch
                    '^node-\d+\.\d+\.\d+-[0-9a-f]{16}$'
            }
    )) {
        if (
            (($engineDirectory.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            $referenced.Contains($engineDirectory.Name)
        ) {
            continue
        }
        try {
            $fullPath = [IO.Path]::GetFullPath(
                $engineDirectory.FullName
            ).TrimEnd('\')
            if (
                [IO.Path]::GetDirectoryName($fullPath).TrimEnd('\') -ne
                    $engineRoot
            ) {
                throw "Refusing to remove an unsafe engine path: $fullPath"
            }
            Remove-Item -LiteralPath $fullPath -Recurse -Force
            $removed.Add($fullPath) | Out-Null
        }
        catch {
            $failures.Add([pscustomobject]@{
                path = $engineDirectory.FullName
                error = [string]$_.Exception.Message
            }) | Out-Null
        }
    }
    return [pscustomobject]@{
        retained = @($references.ids)
        removed = @($removed.ToArray())
        failures = @($failures.ToArray())
    }
}

function Invoke-RuntimeBackupRetention {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$RetainCount,
        [string]$ProtectedPath = ""
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return [pscustomobject]@{
            retain_count = $RetainCount
            retained = @()
            removed = @()
            failures = @()
        }
    }

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $resolvedProtectedPath = if ([string]::IsNullOrWhiteSpace($ProtectedPath)) {
        ""
    }
    else {
        [IO.Path]::GetFullPath($ProtectedPath).TrimEnd('\')
    }
    $backupDirectories = New-Object System.Collections.Generic.List[object]
    foreach ($directory in @(
        Get-ChildItem -LiteralPath $Root -Directory -Force
    )) {
        if (
            (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or
            [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\') -eq
                $resolvedRoot -or
            [IO.Path]::GetDirectoryName($directory.FullName).TrimEnd('\') -ne
                $resolvedRoot -or
            $directory.Name -cnotmatch '^Runtime(?:-|$)'
        ) {
            continue
        }
        if (
            $directory.Name -cmatch
                '-backup-(?<stamp>\d{8}-\d{6})(?:-(?<duplicate>\d+))?$'
        ) {
            $backupDirectories.Add([pscustomobject]@{
                Directory = $directory
                BackupStamp = $Matches["stamp"]
                Duplicate = if ([string]::IsNullOrWhiteSpace($Matches["duplicate"])) {
                    0
                }
                else {
                    [int]$Matches["duplicate"]
                }
                Protected = (
                    -not [string]::IsNullOrWhiteSpace($resolvedProtectedPath) -and
                    [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\') -eq
                        $resolvedProtectedPath
                )
            }) | Out-Null
        }
    }
    $protectedBackups = @(
        $backupDirectories |
            Where-Object Protected |
            Select-Object -First 1
    )
    $ordered = @(
        $backupDirectories |
            Where-Object { -not $_.Protected } |
            Sort-Object BackupStamp, Duplicate, @{ Expression = {
                $_.Directory.Name
            }; Descending = $true } -Descending
    )
    $remainingSlots = [Math]::Max(0, $RetainCount - $protectedBackups.Count)
    $retained = @(
        $protectedBackups
        $ordered | Select-Object -First $remainingSlots
    )
    $obsolete = @($ordered | Select-Object -Skip $remainingSlots)
    $removed = New-Object System.Collections.Generic.List[string]
    $failures = New-Object System.Collections.Generic.List[object]

    foreach ($backupRecord in $obsolete) {
        $backup = $backupRecord.Directory
        try {
            $fullPath = [IO.Path]::GetFullPath($backup.FullName).TrimEnd('\')
            $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
            if (
                [IO.Path]::GetDirectoryName($fullPath).TrimEnd('\') -ne
                    $resolvedRoot -or
                $backup.Name -cnotmatch '^Runtime(?:-|$)' -or
                (($backup.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
            ) {
                throw "Refusing to remove an unsafe Runtime backup path: $fullPath"
            }
            Remove-Item -LiteralPath $fullPath -Recurse -Force
            $removed.Add($fullPath) | Out-Null
        }
        catch {
            $failures.Add([pscustomobject]@{
                path = $backup.FullName
                error = [string]$_.Exception.Message
            }) | Out-Null
        }
    }

    return [pscustomobject]@{
        retain_count = $RetainCount
        retained = @($retained | ForEach-Object { $_.Directory.FullName })
        removed = @($removed.ToArray())
        failures = @($failures.ToArray())
    }
}

function Stop-PointedRuntime {
    param(
        [string]$RuntimePath,
        [string]$LocalRoot
    )

    if (
        [string]::IsNullOrWhiteSpace($RuntimePath) -or
        -not (Test-Path -LiteralPath $RuntimePath -PathType Leaf)
    ) {
        return
    }
    try {
        $context = Get-SkillDockRuntimeContext -LocalRoot $LocalRoot
        if ($null -eq $context) {
            return
        }
    }
    catch {
        return
    }
    $previousLocalRoot = $env:SKILLDOCK_LOCAL_ROOT
    try {
        $env:SKILLDOCK_LOCAL_ROOT = $LocalRoot
        $process = Start-Process `
            -FilePath $RuntimePath `
            -ArgumentList @("--stop", "--silent") `
            -WindowStyle Hidden `
            -Wait `
            -PassThru
    }
    finally {
        $env:SKILLDOCK_LOCAL_ROOT = $previousLocalRoot
    }
    if ($process.ExitCode -ne 0) {
        throw "The previous SkillDock Runtime could not be stopped: $RuntimePath"
    }
    Start-Sleep -Milliseconds 500
    if ($null -ne (Get-SkillDockRuntimeContext -LocalRoot $LocalRoot)) {
        throw "The previous SkillDock Runtime is still healthy after stop."
    }
}

if ([string]::IsNullOrWhiteSpace($SourceDirectory)) {
    if (
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot "SkillDock.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot "app\package.json") -PathType Leaf)
    ) {
        $SourceDirectory = $PSScriptRoot
    }
    else {
        $SourceDirectory = Join-Path $RepositoryRoot "dist\SkillDock-DSH"
    }
}
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
$PackageJsonPath = Join-Path $SourceDirectory "app\package.json"
if (-not (Test-Path -LiteralPath (Join-Path $SourceDirectory "SkillDock.exe") -PathType Leaf)) {
    throw "Source package does not contain SkillDock.exe: $SourceDirectory"
}
if (-not (Test-Path -LiteralPath $PackageJsonPath -PathType Leaf)) {
    throw "Source package does not contain app/package.json: $SourceDirectory"
}
$PackageJson = Get-Content -Raw -LiteralPath $PackageJsonPath | ConvertFrom-Json
$PackageVersion = [string]$PackageJson.version

if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    $LocalRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
}
$LocalRoot = [IO.Path]::GetFullPath($LocalRoot).TrimEnd('\')

if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
    $SafeVersion = $PackageVersion -replace '[^A-Za-z0-9._-]', '-'
    $TargetDirectory = Join-Path $LocalRoot (
        "Runtime-$SafeVersion-" + (Get-Date -Format "yyyyMMddHHmmss")
    )
}
$TargetDirectory = [IO.Path]::GetFullPath($TargetDirectory).TrimEnd('\')
if (
    -not $TargetDirectory.StartsWith(
        $LocalRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "TargetDirectory must stay inside LocalRoot"
}
if (Test-Path -LiteralPath $TargetDirectory) {
    throw "TargetDirectory already exists: $TargetDirectory"
}

if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\runtime"
}
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($DataBackupRoot)) {
    $DataBackupRoot = Join-Path (Split-Path -Parent $BackupRoot) "data"
}
$DataBackupRoot = [IO.Path]::GetFullPath(
    $DataBackupRoot
).TrimEnd('\')
if (
    $BackupRoot.Equals($LocalRoot, [StringComparison]::OrdinalIgnoreCase) -or
    $BackupRoot.StartsWith(
        $LocalRoot + '\',
        [StringComparison]::OrdinalIgnoreCase
    )
) {
    throw "BackupRoot must stay outside the active LocalRoot"
}
Assert-NoReparsePointInPath -Path $BackupRoot
Assert-NoReparsePointInPath -Path $DataBackupRoot

$PointerPath = Join-Path $LocalRoot "runtime-location.json"
$PreviousRuntimePath = ""
if (Test-Path -LiteralPath $PointerPath -PathType Leaf) {
    try {
        $PreviousPointer = Get-Content -Raw -LiteralPath $PointerPath | ConvertFrom-Json
        $PreviousRuntimePath = [string]$PreviousPointer.runtime_path
    }
    catch {
        throw "Existing runtime-location.json cannot be read: $PointerPath"
    }
}
$PreviousRuntimeDirectory = if ([string]::IsNullOrWhiteSpace($PreviousRuntimePath)) {
    ""
}
else {
    [IO.Path]::GetFullPath((Split-Path -Parent $PreviousRuntimePath)).TrimEnd('\')
}

Stop-PointedRuntime `
    -RuntimePath $PreviousRuntimePath `
    -LocalRoot $LocalRoot

$DataMigration = Invoke-SkillDockRuntimeDataMigration `
    -LocalRoot $LocalRoot `
    -DataBackupRoot $DataBackupRoot `
    -Policy $LegacyDataPolicy

$SharedEngine = Install-SkillDockNodeEngine `
    -SourceNodePath (Join-Path $SourceDirectory "node\node.exe") `
    -SourceLicensePath (Join-Path $SourceDirectory "node\LICENSE") `
    -LocalRoot $LocalRoot

New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null
$RuntimeEntries = @(
    "SkillDock.exe",
    "app",
    "Stop SkillDock.cmd",
    "Uninstall SkillDock.ps1",
    "Uninstall PCHW Skill.ps1",
    "runtime-paths.ps1",
    "skill-tree-identity.ps1",
    "RC-MANIFEST.json"
)
$CopiedRuntimeEntry = $false
foreach ($entry in $RuntimeEntries) {
    $sourceEntry = Join-Path $SourceDirectory $entry
    if (-not (Test-Path -LiteralPath $sourceEntry)) {
        continue
    }
    Copy-Item `
        -LiteralPath $sourceEntry `
        -Destination $TargetDirectory `
        -Recurse `
        -Force
    $CopiedRuntimeEntry = $true
}
if (-not $CopiedRuntimeEntry) {
    throw "Source package has no supported Runtime entries: $SourceDirectory"
}
Write-Utf8Json `
    -Path (Join-Path $TargetDirectory "engine-location.json") `
    -Value ([ordered]@{
        schema_version = "1.0"
        engine_id = [string]$SharedEngine.engine_id
        engine_path = [string]$SharedEngine.engine_path
        node_path = [string]$SharedEngine.node_path
        node_version = [string]$SharedEngine.node_version
        node_sha256 = [string]$SharedEngine.node_sha256
    })
$LauncherPath = Join-Path $TargetDirectory "SkillDock.exe"
if (-not (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
    throw "Runtime installation did not produce SkillDock.exe: $TargetDirectory"
}

$ActiveRuntimes = New-Object System.Collections.Generic.List[System.IO.DirectoryInfo]
foreach ($child in @(Get-ChildItem -LiteralPath $LocalRoot -Directory -Force)) {
    if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        continue
    }
    if ($child.FullName.Equals($TargetDirectory, [StringComparison]::OrdinalIgnoreCase)) {
        continue
    }
    if ($child.Name -cmatch '^Runtime(?:-|$)') {
        $ActiveRuntimes.Add($child) | Out-Null
    }
}

New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$MovedBackups = New-Object System.Collections.Generic.List[string]
$PreviousRuntimeBackupPath = ""
foreach ($activeRuntime in $ActiveRuntimes) {
    $backupPath = Get-AvailableBackupPath `
        -Root $BackupRoot `
        -PreferredName "$($activeRuntime.Name)-backup-$Stamp"
    Move-Item -LiteralPath $activeRuntime.FullName -Destination $backupPath
    $MovedBackups.Add($backupPath) | Out-Null
    if (
        -not [string]::IsNullOrWhiteSpace($PreviousRuntimeDirectory) -and
        [IO.Path]::GetFullPath($activeRuntime.FullName).TrimEnd('\') -eq
            $PreviousRuntimeDirectory
    ) {
        $PreviousRuntimeBackupPath = $backupPath
    }
    Write-Host "Previous active Runtime moved to backup:"
    Write-Host "  $backupPath"
}

$remainingRuntimes = @(
    Get-ChildItem -LiteralPath $LocalRoot -Directory -Force |
        Where-Object {
            $_.Name -cmatch '^Runtime(?:-|$)' -and
            $_.FullName -ne $TargetDirectory
        }
)
if ($remainingRuntimes.Count -gt 0) {
    throw "Old active Runtime directories remain: $($remainingRuntimes.FullName -join ', ')"
}

[pscustomobject]@{
    runtime_path = $LauncherPath
    version = $PackageVersion
    installed_at = [DateTimeOffset]::Now.ToString("o")
    previous_runtime_path = $PreviousRuntimePath
    previous_runtime_backup_path = $PreviousRuntimeBackupPath
    backup_root = $BackupRoot
    data_backup_root = $DataBackupRoot
    legacy_data_migration = $DataMigration
    node_engine = [ordered]@{
        engine_id = [string]$SharedEngine.engine_id
        engine_path = [string]$SharedEngine.engine_path
        node_path = [string]$SharedEngine.node_path
        node_version = [string]$SharedEngine.node_version
        node_sha256 = [string]$SharedEngine.node_sha256
    }
} | ConvertTo-Json | Set-Content -LiteralPath $PointerPath -Encoding UTF8

$BackupRetention = try {
    Invoke-RuntimeBackupRetention `
        -Root $BackupRoot `
        -RetainCount $RetainRuntimeBackups `
        -ProtectedPath $PreviousRuntimeBackupPath
}
catch {
    [pscustomobject]@{
        retain_count = $RetainRuntimeBackups
        retained = @()
        removed = @()
        failures = @(
            [pscustomobject]@{
                path = $BackupRoot
                error = [string]$_.Exception.Message
            }
        )
    }
}
foreach ($removedBackup in @($BackupRetention.removed)) {
    Write-Host "Removed obsolete Runtime backup:"
    Write-Host "  $removedBackup"
}
foreach ($retentionFailure in @($BackupRetention.failures)) {
    Write-Warning (
        "Could not remove obsolete Runtime backup '{0}': {1}" -f
        $retentionFailure.path,
        $retentionFailure.error
    )
}

$EngineRetention = try {
    Invoke-SkillDockEngineRetention `
        -LocalRoot $LocalRoot `
        -BackupRoot $BackupRoot
}
catch {
    [pscustomobject]@{
        retained = @()
        removed = @()
        failures = @(
            [pscustomobject]@{
                path = (Get-SkillDockEngineRoot -LocalRoot $LocalRoot)
                error = [string]$_.Exception.Message
            }
        )
    }
}
foreach ($removedEngine in @($EngineRetention.removed)) {
    Write-Host "Removed unreferenced shared Node engine:"
    Write-Host "  $removedEngine"
}
foreach ($engineFailure in @($EngineRetention.failures)) {
    Write-Warning (
        "Could not clean shared Node engine '{0}': {1}" -f
        $engineFailure.path,
        $engineFailure.error
    )
}

[pscustomobject]@{
    runtime = $LauncherPath
    pointer = $PointerPath
    version = $PackageVersion
    installed_at = [DateTimeOffset]::Now.ToString("o")
    backup_root = $BackupRoot
    data_backup_root = $DataBackupRoot
    legacy_data_migration = $DataMigration
    backups = @($MovedBackups)
    previous_runtime_backup_path = $PreviousRuntimeBackupPath
    backup_retention = $BackupRetention
    shared_engine = [ordered]@{
        engine_id = [string]$SharedEngine.engine_id
        engine_path = [string]$SharedEngine.engine_path
        node_path = [string]$SharedEngine.node_path
        node_version = [string]$SharedEngine.node_version
        node_sha256 = [string]$SharedEngine.node_sha256
        reused = [bool]$SharedEngine.reused
    }
    engine_retention = $EngineRetention
} | ConvertTo-Json -Depth 4 -Compress
