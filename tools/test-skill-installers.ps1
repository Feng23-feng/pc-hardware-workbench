[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceSkill = Join-Path $repoRoot "skill\pc-hardware-workbench"
$sourceSkillText = Get-Content -Raw -LiteralPath (Join-Path $sourceSkill "SKILL.md") -Encoding UTF8
$sourceVersionMatch = [regex]::Match($sourceSkillText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
if (-not $sourceVersionMatch.Success) {
    throw "Could not read the source Skill version."
}
$sourceVersion = $sourceVersionMatch.Groups[1].Value
$remoteInstaller = Join-Path $repoRoot "tools\install-skill.ps1"
$packageInstaller = Join-Path $repoRoot "tools\release-package\Install-PC-Hardware-Workbench.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "pcwb-installer-test-" + [guid]::NewGuid().ToString("N")
)
$createdJunction = $null

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-OldSkill {
    param([Parameter(Mandatory = $true)][string]$Path)

    New-Item -ItemType Directory -Path (Join-Path $Path "scripts") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Path "references") -Force | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $Path "SKILL.md"),
        "---`nname: pc-hardware-workbench`ndescription: old test copy`n---`n",
        (New-Object Text.UTF8Encoding($false))
    )
    [IO.File]::WriteAllText(
        (Join-Path $Path "old-version-marker.txt"),
        "old version",
        (New-Object Text.UTF8Encoding($false))
    )
}

function Assert-InstalledSkill {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$OldMarkerPath
    )

    Assert-True (Test-Path -LiteralPath (Join-Path $Destination "SKILL.md") -PathType Leaf) "Installed SKILL.md is missing."
    Assert-True (Test-Path -LiteralPath (Join-Path $Destination "scripts") -PathType Container) "Installed scripts directory is missing."
    Assert-True (Test-Path -LiteralPath (Join-Path $Destination "references") -PathType Container) "Installed references directory is missing."
    Assert-True (-not (Test-Path -LiteralPath $OldMarkerPath)) "The old Skill was not replaced."

    $expectedManifest = [IO.File]::ReadAllText(
        (Join-Path $sourceSkill "SKILL.md"),
        [Text.Encoding]::UTF8
    )
    $installedManifest = [IO.File]::ReadAllText(
        (Join-Path $Destination "SKILL.md"),
        [Text.Encoding]::UTF8
    )
    Assert-True ($installedManifest -eq $expectedManifest) "Installed SKILL.md does not match the repository."
}

function Assert-OneManifestUnderScanRoot {
    param([Parameter(Mandatory = $true)][string]$ScanRoot)

    $manifests = @(Get-ChildItem -LiteralPath $ScanRoot -Recurse -File -Filter "SKILL.md")
    Assert-True ($manifests.Count -eq 1) "Expected one active SKILL.md under the scan root, found $($manifests.Count)."
}

function Invoke-Installer {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$ExpectFailure
    )

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @Arguments
    $exitCode = $LASTEXITCODE
    if ($ExpectFailure) {
        Assert-True ($exitCode -ne 0) "Installer unexpectedly succeeded: $Path"
    }
    else {
        Assert-True ($exitCode -eq 0) "Installer failed with exit code $exitCode`: $Path"
    }
}

New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
try {
    $payloadRoot = Join-Path $testRoot "payload"
    $payloadSkill = Join-Path $payloadRoot "skill\pc-hardware-workbench"
    New-Item -ItemType Directory -Path (Split-Path -Parent $payloadSkill) -Force | Out-Null
    Copy-Item -LiteralPath $sourceSkill -Destination $payloadSkill -Recurse
    $archivePath = Join-Path $testRoot "source.zip"
    Compress-Archive -LiteralPath (Join-Path $payloadRoot "skill") -DestinationPath $archivePath

    $remoteCodexRoot = Join-Path $testRoot "remote\.codex"
    $remoteScanRoot = Join-Path $remoteCodexRoot "skills"
    $remoteDestination = Join-Path $remoteScanRoot "pc-hardware-workbench"
    $remoteBackupRoot = Join-Path $remoteCodexRoot "skill-backups\pc-hardware-workbench"
    New-OldSkill -Path $remoteDestination
    $legacyBackup = Join-Path $remoteScanRoot "pc-hardware-workbench.backup-legacy"
    New-OldSkill -Path $legacyBackup
    $nestedLegacyBackup = Join-Path $remoteScanRoot "legacy-group\pc-hardware-workbench.backup-nested"
    New-OldSkill -Path $nestedLegacyBackup
    $remoteArguments = @(
        "-Destination", $remoteDestination,
        "-BackupRoot", $remoteBackupRoot,
        "-ArchiveUrl", $archivePath,
        "-Force"
    )
    Invoke-Installer -Path $remoteInstaller -Arguments @(
        "-Destination", $remoteDestination,
        "-BackupRoot", $remoteBackupRoot,
        "-ArchiveUrl", $archivePath
    ) -ExpectFailure
    Assert-True (Test-Path -LiteralPath (Join-Path $remoteDestination "old-version-marker.txt") -PathType Leaf) "An update without -Force changed the active Skill."
    Assert-True (Test-Path -LiteralPath $legacyBackup -PathType Container) "An update without -Force moved a legacy backup."
    Invoke-Installer -Path $remoteInstaller -Arguments $remoteArguments
    Assert-InstalledSkill `
        -Destination $remoteDestination `
        -OldMarkerPath (Join-Path $remoteDestination "old-version-marker.txt")
    $remoteInstallInfo = Get-Content -Raw -LiteralPath (Join-Path $remoteDestination "INSTALL-INFO.json") -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($remoteInstallInfo.Version -eq $sourceVersion) "Remote installer recorded the wrong Skill version."
    Assert-True ($remoteInstallInfo.ReleaseLabel -eq "main") "Remote installer did not record the main-branch source."
    Assert-True ($remoteInstallInfo.SourceArchive -eq "source.zip") "Remote installer did not sanitize the source archive label."
    Assert-OneManifestUnderScanRoot -ScanRoot $remoteScanRoot
    Assert-True (Test-Path -LiteralPath $remoteBackupRoot -PathType Container) "Remote installer backup root is missing."
    Assert-True (
        @(Get-ChildItem -LiteralPath $remoteBackupRoot -Directory).Count -eq 3
    ) "Remote installer did not preserve the current old version and both legacy backups."
    Assert-True (
        -not (Test-Path -LiteralPath $legacyBackup -PathType Container)
    ) "The legacy in-root backup was not moved out of the scan root."

    $packageRoot = Join-Path $testRoot "package"
    $packageDestinationRoot = Join-Path $testRoot "package-install\.codex"
    $packageScanRoot = Join-Path $packageDestinationRoot "skills"
    $packageDestination = Join-Path $packageScanRoot "pc-hardware-workbench"
    $packageBackupRoot = Join-Path $packageDestinationRoot "skill-backups\pc-hardware-workbench"
    New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
    Copy-Item -LiteralPath $packageInstaller -Destination $packageRoot
    Copy-Item -LiteralPath $sourceSkill -Destination (Join-Path $packageRoot "pc-hardware-workbench") -Recurse
    $testBuildInfo = [pscustomobject]@{
        Version = $sourceVersion
        Label = "test"
        ReleaseName = "$sourceVersion-test"
        GitCommit = "test-commit"
        BuiltAt = "2026-11-11T00:00:00+08:00"
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        (Join-Path $packageRoot "BUILD-INFO.json"),
        $testBuildInfo,
        (New-Object Text.UTF8Encoding($false))
    )
    $packagedInstaller = Join-Path $packageRoot "Install-PC-Hardware-Workbench.ps1"
    New-OldSkill -Path $packageDestination
    Invoke-Installer -Path $packagedInstaller -Arguments @(
        "-Destination", $packageDestination,
        "-BackupRoot", $packageBackupRoot
    )
    Assert-InstalledSkill `
        -Destination $packageDestination `
        -OldMarkerPath (Join-Path $packageDestination "old-version-marker.txt")
    $packageInstallInfo = Get-Content -Raw -LiteralPath (Join-Path $packageDestination "INSTALL-INFO.json") -Encoding UTF8 |
        ConvertFrom-Json
    Assert-True ($packageInstallInfo.ReleaseLabel -eq "test") "Package installer recorded the wrong release label."
    Assert-True ($packageInstallInfo.GitCommit -eq "test-commit") "Package installer recorded the wrong Git commit."
    Assert-OneManifestUnderScanRoot -ScanRoot $packageScanRoot
    Assert-True (
        @(Get-ChildItem -LiteralPath $packageBackupRoot -Directory).Count -eq 1
    ) "Package installer did not preserve the previous Skill."

    $invalidBackupRoot = Join-Path $packageScanRoot "backups"
    New-OldSkill -Path $packageDestination
    Invoke-Installer -Path $packagedInstaller -Arguments @(
        "-Destination", $packageDestination,
        "-BackupRoot", $invalidBackupRoot
    ) -ExpectFailure
    Assert-True (Test-Path -LiteralPath (Join-Path $packageDestination "SKILL.md") -PathType Leaf) "Rejected backup path changed the active Skill."

    $nestedDestination = Join-Path $packageScanRoot "nested\pc-hardware-workbench"
    $nestedInvalidBackup = Join-Path $packageScanRoot "nested-backups"
    New-OldSkill -Path $nestedDestination
    Invoke-Installer -Path $packagedInstaller -Arguments @(
        "-Destination", $nestedDestination,
        "-BackupRoot", $nestedInvalidBackup
    ) -ExpectFailure
    Assert-True (Test-Path -LiteralPath (Join-Path $nestedDestination "SKILL.md") -PathType Leaf) "A nested rejected backup path changed the active Skill."

    $junctionParent = Join-Path $testRoot "junction\.codex"
    $junctionTarget = Join-Path $packageScanRoot "hidden-backups"
    $createdJunction = Join-Path $junctionParent "skill-backups"
    New-Item -ItemType Directory -Path $junctionParent,$junctionTarget -Force | Out-Null
    New-Item -ItemType Junction -Path $createdJunction -Target $junctionTarget | Out-Null
    Invoke-Installer -Path $packagedInstaller -Arguments @(
        "-Destination", $nestedDestination,
        "-BackupRoot", (Join-Path $createdJunction "pc-hardware-workbench")
    ) -ExpectFailure
    Assert-True (Test-Path -LiteralPath (Join-Path $nestedDestination "SKILL.md") -PathType Leaf) "A reparse-point backup path changed the active Skill."

    $freshCodexRoot = Join-Path $testRoot "fresh-install\.codex"
    $freshDestination = Join-Path $freshCodexRoot "skills\pc-hardware-workbench"
    $freshBackupRoot = Join-Path $freshCodexRoot "skill-backups\pc-hardware-workbench"
    Invoke-Installer -Path $packagedInstaller -Arguments @(
        "-Destination", $freshDestination,
        "-BackupRoot", $freshBackupRoot
    )
    Assert-InstalledSkill `
        -Destination $freshDestination `
        -OldMarkerPath (Join-Path $freshDestination "old-version-marker.txt")

    Write-Host "Installer regression: PASS"
}
finally {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        -not [string]::IsNullOrWhiteSpace($createdJunction) -and
        (Test-Path -LiteralPath $createdJunction)
    ) {
        $resolvedJunction = [IO.Path]::GetFullPath($createdJunction)
        if (-not $resolvedJunction.StartsWith($resolvedTestRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a junction outside the installer test root."
        }
        Remove-Item -LiteralPath $resolvedJunction -Force
    }
    if (
        (Test-Path -LiteralPath $resolvedTestRoot) -and
        $resolvedTestRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedTestRoot).StartsWith("pcwb-installer-test-")
    ) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}
