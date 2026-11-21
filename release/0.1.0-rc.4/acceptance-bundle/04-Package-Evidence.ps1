[CmdletBinding()]
param(
    [switch]$AllowMissingManualEvidence
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")

$evidence = Get-EvidenceRoot
$requiredStructuredFiles = @(
    "00-preflight.json",
    "01-install-result.json",
    "02-environment.json",
    "03-uninstall-result.json"
)
$missingStructured = @(
    $requiredStructuredFiles |
        Where-Object {
            -not (Test-Path -LiteralPath (
                Join-Path $evidence $_
            ) -PathType Leaf)
        }
)
if ($missingStructured.Count -gt 0) {
    throw (
        "Structured evidence is incomplete: " +
        ($missingStructured -join ", ")
    )
}

$requiredScreenshots = @(
    "10-permission-allow-once.png",
    "11-answer-card.png",
    "12-chart-evidence.png",
    "20-restart-same-task.png",
    "30-uninstall-clean.png"
)
$missingScreenshots = @(
    $requiredScreenshots |
        Where-Object {
            -not (Test-Path -LiteralPath (
                Join-Path $evidence $_
            ) -PathType Leaf)
        }
)
if ($missingScreenshots.Count -gt 0 -and -not $AllowMissingManualEvidence) {
    throw (
        "Manual screenshots are incomplete: " +
        ($missingScreenshots -join ", ")
    )
}

$install = Get-Content -Raw -LiteralPath (
    Join-Path $evidence "01-install-result.json"
) | ConvertFrom-Json
$uninstall = Get-Content -Raw -LiteralPath (
    Join-Path $evidence "03-uninstall-result.json"
) | ConvertFrom-Json
if ([string]$install.status -ne "passed") {
    throw "Install evidence does not report PASS."
}
if ([string]$uninstall.status -ne "passed") {
    throw "Uninstall evidence does not report PASS."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$archivePath = Assert-UnderBundle -Path (
    Get-BundlePath "SkillDock-RC-Evidence-$stamp.zip"
)
Compress-Archive `
    -Path (Join-Path $evidence "*") `
    -DestinationPath $archivePath `
    -CompressionLevel Optimal
$sha256 = Get-Sha256Hex -Path $archivePath
$sidecarPath = "$archivePath.sha256"
Write-Utf8Text `
    -Path $sidecarPath `
    -Text ("$sha256  " + [IO.Path]::GetFileName($archivePath) + "`n")

$summary = [ordered]@{
    schema_version = "1.0"
    status = if ($missingScreenshots.Count -eq 0) { "complete" } else {
        "incomplete"
    }
    created_at = [DateTimeOffset]::Now.ToString("o")
    evidence_archive = $archivePath
    bytes = (Get-Item -LiteralPath $archivePath).Length
    sha256 = $sha256
    sidecar = $sidecarPath
    missing_screenshots = $missingScreenshots
}
$summaryPath = Assert-UnderBundle -Path (
    Get-BundlePath "SkillDock-RC-Evidence-$stamp.json"
)
Write-Utf8Text `
    -Path $summaryPath `
    -Text (($summary | ConvertTo-Json -Depth 6) + "`n")

Write-Host "Evidence package created." -ForegroundColor Green
Write-Host "ZIP:     $archivePath"
Write-Host "SHA-256: $sha256"
Write-Host "Return the ZIP and its .sha256 file."
