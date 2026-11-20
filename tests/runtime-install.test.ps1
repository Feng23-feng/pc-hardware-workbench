[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(Mandatory = $true)]
    [string]$SourceDirectory
)

$ErrorActionPreference = "Stop"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "skilldock-runtime-install-" + [guid]::NewGuid().ToString("N")
)
$localRoot = Join-Path $tempRoot "active"
$backupRoot = Join-Path $tempRoot "backups"
$targetDirectory = Join-Path $localRoot "Runtime-new"
$oldActiveRuntime = Join-Path $localRoot "Runtime-old"
$legacyActiveRuntime = Join-Path $localRoot "Runtime"
$enginesRoot = Join-Path $localRoot "engines"
$unusedEngine = Join-Path $enginesRoot "node-24.0.0-0123456789abcdef"
$ancientBackup = Join-Path $backupRoot "Runtime-ancient-backup-20200101-000000"
$unrecognizedRuntimeBackup = Join-Path $backupRoot "Runtime-unrecognized"
$unrelatedBackup = Join-Path $backupRoot "ManualKeep"

try {
    New-Item -ItemType Directory -Path $oldActiveRuntime -Force |
        Out-Null
    New-Item -ItemType Directory -Path $legacyActiveRuntime -Force |
        Out-Null
    New-Item -ItemType Directory -Path $unusedEngine -Force |
        Out-Null
    New-Item -ItemType Directory -Path (Join-Path $localRoot "runtime-dsh-web") -Force |
        Out-Null
    New-Item -ItemType Directory -Path $ancientBackup -Force | Out-Null
    New-Item -ItemType Directory -Path $unrecognizedRuntimeBackup -Force | Out-Null
    New-Item -ItemType Directory -Path $unrelatedBackup -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $oldActiveRuntime "old.txt") `
        -Value "old"
    Set-Content `
        -LiteralPath (Join-Path $legacyActiveRuntime "legacy.txt") `
        -Value "legacy"
    Set-Content `
        -LiteralPath (Join-Path $unusedEngine "stale.txt") `
        -Value "stale-engine"
    Set-Content `
        -LiteralPath (Join-Path $ancientBackup "ancient.txt") `
        -Value "ancient"
    Set-Content `
        -LiteralPath (Join-Path $unrecognizedRuntimeBackup "keep.txt") `
        -Value "keep"
    Set-Content `
        -LiteralPath (Join-Path $unrelatedBackup "keep.txt") `
        -Value "keep"
    Set-Content `
        -LiteralPath (Join-Path $localRoot "runtime-dsh-web\capability-token") `
        -Value "test-token"
    [IO.Directory]::SetLastWriteTimeUtc(
        $ancientBackup,
        [datetime]::UtcNow.AddDays(30)
    )
    [IO.Directory]::SetLastWriteTimeUtc(
        $oldActiveRuntime,
        [datetime]::UtcNow.AddMinutes(-2)
    )
    [IO.Directory]::SetLastWriteTimeUtc(
        $legacyActiveRuntime,
        [datetime]::UtcNow.AddMinutes(-1)
    )
    [pscustomobject]@{
        runtime_path = (Join-Path $localRoot "Runtime-old\SkillDock.exe")
        version = "old"
    } | ConvertTo-Json | Set-Content `
        -LiteralPath (Join-Path $localRoot "runtime-location.json") `
        -Encoding UTF8

    $output = & $InstallerPath `
        -SourceDirectory $SourceDirectory `
        -TargetDirectory $targetDirectory `
        -LocalRoot $localRoot `
        -BackupRoot $backupRoot

    $pointer = Get-Content -Raw `
        -LiteralPath (Join-Path $localRoot "runtime-location.json") |
        ConvertFrom-Json
    if ($pointer.runtime_path -ne (Join-Path $targetDirectory "SkillDock.exe")) {
        throw "Runtime pointer does not reference the new target."
    }
    $expectedVersion = (
        Get-Content -Raw -LiteralPath (
            Join-Path $SourceDirectory "app\package.json"
        ) |
            ConvertFrom-Json
    ).version
    if ($pointer.version -ne $expectedVersion) {
        throw "Runtime pointer version is incorrect."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $targetDirectory "app\server.mjs"))) {
        throw "Installed Runtime is missing app/server.mjs."
    }
    if (Test-Path -LiteralPath (Join-Path $targetDirectory "node")) {
        throw "Installed Runtime still contains a duplicate node directory."
    }
    $engineReferencePath = Join-Path $targetDirectory "engine-location.json"
    if (-not (Test-Path -LiteralPath $engineReferencePath -PathType Leaf)) {
        throw "Installed Runtime is missing engine-location.json."
    }
    $engineReference = Get-Content -Raw `
        -LiteralPath $engineReferencePath |
        ConvertFrom-Json
    if (
        [string]$engineReference.engine_id -notmatch
            '^node-\d+\.\d+\.\d+-[0-9a-f]{16}$' -or
        -not (Test-Path -LiteralPath ([string]$engineReference.node_path) -PathType Leaf)
    ) {
        throw "Installed Runtime shared Node engine reference is invalid."
    }
    $engineDirectories = @(
        Get-ChildItem -LiteralPath $enginesRoot -Directory |
            Where-Object {
                $_.Name -cmatch '^node-\d+\.\d+\.\d+-[0-9a-f]{16}$'
            }
    )
    if (
        $engineDirectories.Count -ne 1 -or
        $engineDirectories[0].Name -ne [string]$engineReference.engine_id
    ) {
        throw "Expected exactly one referenced shared Node engine."
    }
    if (Test-Path -LiteralPath $unusedEngine) {
        throw "Unreferenced shared Node engine was not pruned."
    }
    if (
        $null -eq $pointer.PSObject.Properties["node_engine"] -or
        [string]$pointer.node_engine.engine_id -ne
            [string]$engineReference.engine_id
    ) {
        throw "Runtime pointer does not record the shared Node engine."
    }

    $active = @(
        Get-ChildItem -LiteralPath $localRoot -Directory |
            Where-Object { $_.Name -cmatch '^Runtime(?:-|$)' }
    )
    if ($active.Count -ne 1 -or $active[0].FullName -ne $targetDirectory) {
        throw "Active Runtime directory does not contain exactly the new version."
    }

    $backups = @(
        Get-ChildItem -LiteralPath $backupRoot -Directory |
            Where-Object {
                $_.Name -cmatch '^Runtime.*-backup-\d{8}-\d{6}(?:-\d+)?$'
            }
    )
    if ($backups.Count -ne 1) {
        throw "Expected one retained Runtime backup, found $($backups.Count)."
    }
    if ($backups[0].Name -notmatch '^Runtime-old-backup-') {
        throw "Runtime backup retention did not keep the Runtime referenced by the previous pointer."
    }
    if (
        [string]$pointer.previous_runtime_backup_path -ne
            [string]$backups[0].FullName
    ) {
        throw "Runtime pointer does not protect the previous rollback backup."
    }
    if (Test-Path -LiteralPath (Join-Path $backups[0].FullName "node")) {
        throw "New-format Runtime backup still contains a duplicate node directory."
    }
    if (Test-Path -LiteralPath $ancientBackup) {
        throw "Obsolete Runtime backup was not pruned."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $unrecognizedRuntimeBackup "keep.txt"))) {
        throw "Backup retention removed an unrecognized Runtime directory."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $unrelatedBackup "keep.txt"))) {
        throw "Backup retention removed an unrelated directory."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $localRoot "runtime-dsh-web\capability-token"))) {
        throw "Runtime data directory was moved with program versions."
    }

    $runtimeResult = $null
    foreach ($line in @($output)) {
        $trimmed = ([string]$line).Trim()
        if ($trimmed.StartsWith("{")) {
            $runtimeResult = $trimmed | ConvertFrom-Json
        }
    }
    if (
        $null -eq $runtimeResult -or
        [int]$runtimeResult.backup_retention.retain_count -ne 1 -or
        @($runtimeResult.backup_retention.retained).Count -ne 1 -or
        @($runtimeResult.backup_retention.removed).Count -ne 2 -or
        @($runtimeResult.backup_retention.failures).Count -ne 0
    ) {
        throw "Runtime backup retention result does not match the filesystem state."
    }

    Write-Host "Runtime install backup retention/only-new contract: PASS"
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
