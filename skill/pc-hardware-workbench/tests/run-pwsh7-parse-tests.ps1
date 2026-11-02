[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $pwsh) {
    Write-Host "PowerShell 7 parse tests: SKIP (pwsh.exe not installed)" -ForegroundColor Yellow
    exit 0
}

$files = @(
    Get-ChildItem -LiteralPath (Join-Path $resolvedRoot "scripts") -File -Filter "*.ps1"
    Get-ChildItem -LiteralPath (Join-Path $resolvedRoot "tests") -File -Filter "*.ps1"
)

$parserSource = @'
param([Parameter(Mandatory = $true)][string]$Path)

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $Path,
    [ref]$tokens,
    [ref]$errors
) | Out-Null
if ($errors.Count -gt 0) {
    foreach ($errorItem in $errors) {
        [Console]::Error.WriteLine(
            ("{0}:{1}: {2}" -f $Path, $errorItem.Extent.StartLineNumber, $errorItem.Message)
        )
    }
    exit 1
}
'@

$parserPath = Join-Path ([IO.Path]::GetTempPath()) (
    "pcwb-pwsh7-parser-" + [guid]::NewGuid().ToString("N") + ".ps1")
try {
    [IO.File]::WriteAllText(
        $parserPath,
        $parserSource,
        (New-Object System.Text.UTF8Encoding($false)))
    foreach ($file in $files) {
        & $pwsh.Source `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $parserPath `
            $file.FullName
        if ($LASTEXITCODE -ne 0) {
            exit 1
        }
    }
}
finally {
    if (Test-Path -LiteralPath $parserPath -PathType Leaf) {
        Remove-Item -LiteralPath $parserPath -Force
    }
}

Write-Host "PowerShell 7 parse tests: PASS ($($files.Count) files)" -ForegroundColor Green
