[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$failures = New-Object System.Collections.Generic.List[string]
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]

foreach ($directoryName in @("scripts", "tests")) {
    $directory = Join-Path $resolvedRoot $directoryName
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $failures.Add("Required directory is missing: $directoryName")
        continue
    }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter *.ps1 -File) {
        $files.Add($file)
    }
}

foreach ($file in $files) {
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $nonAscii = [regex]::Matches($text, '[^\x00-\x7F]').Count
    if (-not $hasBom -and $nonAscii -gt 0) {
        $failures.Add(
            "$($file.Name) contains $nonAscii non-ASCII characters but has no UTF-8 BOM; Windows PowerShell 5.1 would mis-decode it."
        )
    }
}

if ($failures.Count -gt 0) {
    Write-Host "Encoding tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Encoding tests: PASS ($($files.Count) PowerShell files)" -ForegroundColor Green
