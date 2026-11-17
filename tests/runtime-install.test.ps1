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

try {
    New-Item -ItemType Directory -Path (Join-Path $localRoot "Runtime-old") -Force |
        Out-Null
    New-Item -ItemType Directory -Path (Join-Path $localRoot "Runtime") -Force |
        Out-Null
    New-Item -ItemType Directory -Path (Join-Path $localRoot "runtime-dsh-web") -Force |
        Out-Null
    Set-Content `
        -LiteralPath (Join-Path $localRoot "Runtime-old\old.txt") `
        -Value "old"
    Set-Content `
        -LiteralPath (Join-Path $localRoot "Runtime\legacy.txt") `
        -Value "legacy"
    Set-Content `
        -LiteralPath (Join-Path $localRoot "runtime-dsh-web\capability-token") `
        -Value "test-token"
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
    if (-not (Test-Path -LiteralPath (Join-Path $targetDirectory "node\node.exe"))) {
        throw "Installed Runtime is missing node.exe."
    }

    $active = @(
        Get-ChildItem -LiteralPath $localRoot -Directory |
            Where-Object { $_.Name -cmatch '^Runtime(?:-|$)' }
    )
    if ($active.Count -ne 1 -or $active[0].FullName -ne $targetDirectory) {
        throw "Active Runtime directory does not contain exactly the new version."
    }

    $backups = @(Get-ChildItem -LiteralPath $backupRoot -Directory)
    if ($backups.Count -ne 2) {
        throw "Expected two Runtime backups, found $($backups.Count)."
    }
    if (-not ($backups.Name -match '^Runtime-old-backup-')) {
        throw "Versioned Runtime backup was not created."
    }
    if (-not ($backups.Name -match '^Runtime-backup-')) {
        throw "Legacy Runtime backup was not created."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $localRoot "runtime-dsh-web\capability-token"))) {
        throw "Runtime data directory was moved with program versions."
    }

    Write-Host "Runtime install backup/only-new contract: PASS"
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
