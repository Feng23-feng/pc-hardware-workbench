[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")

$manifestPath = Join-Path $PSScriptRoot "BUNDLE-MANIFEST.sha256"
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "BUNDLE-MANIFEST.sha256 is missing."
}

$errors = New-Object System.Collections.Generic.List[string]
$lines = @(Get-Content -LiteralPath $manifestPath)
$describedFiles = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
        $errors.Add("Malformed manifest line: $line") | Out-Null
        continue
    }
    $expected = $Matches[1]
    $relative = $Matches[2].Replace("/", "\")
    if ($relative.Split("\") -contains "..") {
        $errors.Add("Unsafe manifest path: $relative") | Out-Null
        continue
    }
    $path = Join-Path $PSScriptRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $errors.Add("Missing file: $relative") | Out-Null
        continue
    }
    $actual = Get-Sha256Hex -Path $path
    if ($actual -ne $expected) {
        $errors.Add("SHA-256 mismatch: $relative") | Out-Null
    }
    $describedFiles.Add($relative.Replace("\", "/")) | Out-Null
}

$actualFiles = New-Object System.Collections.Generic.List[string]
foreach ($file in @(
    Get-ChildItem -LiteralPath $PSScriptRoot -File -Recurse -Force
)) {
    $relative = $file.FullName.Substring(
        ([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\")).Length + 1
    ).Replace("\", "/")
    if ($relative -ceq "BUNDLE-MANIFEST.sha256") {
        continue
    }
    if (
        $relative.StartsWith(
            "evidence/",
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $relative.StartsWith(
            "stage/",
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        $relative -match "^SkillDock-RC-Evidence-.+\.(zip|sha256|json)$"
    ) {
        continue
    }
    $actualFiles.Add($relative) | Out-Null
}
$describedSorted = [string[]]$describedFiles.ToArray()
$actualSorted = [string[]]$actualFiles.ToArray()
[Array]::Sort($describedSorted, [StringComparer]::Ordinal)
[Array]::Sort($actualSorted, [StringComparer]::Ordinal)
$inventoryDifference = @(
    Compare-Object `
        -ReferenceObject $describedSorted `
        -DifferenceObject $actualSorted `
        -CaseSensitive
)
if ($inventoryDifference.Count -gt 0) {
    foreach ($difference in $inventoryDifference) {
        $side = if ($difference.SideIndicator -eq "<=") {
            "missing from payload"
        }
        else {
            "not described by manifest"
        }
        $errors.Add(
            "$($side): $($difference.InputObject)"
        ) | Out-Null
    }
}

if ($errors.Count -gt 0) {
    $errors | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    throw "Acceptance bundle validation failed."
}

[void](Assert-ArchiveIdentity)
Write-Host (
    "Acceptance bundle validation: PASS (" +
    $lines.Count +
    " manifest entries; pinned RC hash matches)"
) -ForegroundColor Green
