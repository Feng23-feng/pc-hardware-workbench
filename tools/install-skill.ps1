[CmdletBinding()]
param(
    [string]$Destination = "",

    [string]$ArchiveUrl = "https://github.com/Feng23-feng/pc-hardware-workbench/archive/refs/heads/main.zip",

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
}

$Destination = [System.IO.Path]::GetFullPath($Destination)
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "pc-hardware-workbench-install-" + [guid]::NewGuid().ToString("N")
)
$archivePath = Join-Path $temporaryRoot "source.zip"
$expandedPath = Join-Path $temporaryRoot "expanded"

try {
    New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $expandedPath -Force | Out-Null

    Write-Host "Downloading PC Hardware Workbench from:"
    Write-Host "  $ArchiveUrl"
    Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $archivePath
    Expand-Archive -LiteralPath $archivePath -DestinationPath $expandedPath -Force

    $directSkillSource = Join-Path $expandedPath "skill\pc-hardware-workbench"
    if (Test-Path -LiteralPath $directSkillSource -PathType Container) {
        $skillCandidates = @($directSkillSource)
    }
    else {
        $skillCandidates = @(
            Get-ChildItem -LiteralPath $expandedPath -Directory |
                ForEach-Object {
                    $candidate = Join-Path $_.FullName "skill\pc-hardware-workbench"
                    if (Test-Path -LiteralPath $candidate -PathType Container) {
                        $candidate
                    }
                }
        )
    }
    if ($skillCandidates.Count -ne 1) {
        throw "Expected one Skill tree in the downloaded archive, found $($skillCandidates.Count)."
    }

    $skillSource = $skillCandidates[0]
    $manifest = Join-Path $skillSource "SKILL.md"
    if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) {
        throw "Downloaded archive does not contain skill\pc-hardware-workbench\SKILL.md."
    }

    $backupPath = ""
    if (Test-Path -LiteralPath $Destination) {
        if (-not $Force) {
            throw "Destination already exists: $Destination`nRe-run with -Force to install and keep an automatic backup."
        }

        $destinationParent = Split-Path -Parent $Destination
        $destinationName = Split-Path -Leaf $Destination
        $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        $backupPath = Join-Path $destinationParent "$destinationName.backup-$stamp"
        Move-Item -LiteralPath $Destination -Destination $backupPath
        Write-Host "Existing installation moved to:"
        Write-Host "  $backupPath"
    }

    $destinationParent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    Copy-Item -LiteralPath $skillSource -Destination $Destination -Recurse

    $requiredPaths = @(
        (Join-Path $Destination "SKILL.md"),
        (Join-Path $Destination "scripts"),
        (Join-Path $Destination "references")
    )
    foreach ($requiredPath in $requiredPaths) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Installed Skill is incomplete; missing: $requiredPath"
        }
    }

    Write-Host ""
    Write-Host "Installed PC Hardware Workbench:"
    Write-Host "  $Destination"
    if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
        Write-Host "Rollback backup:"
        Write-Host "  $backupPath"
    }
    Write-Host ""
    Write-Host "Restart Codex if the Skill does not appear, then invoke:"
    Write-Host "  `$pc-hardware-workbench"
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
