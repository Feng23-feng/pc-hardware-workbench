[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot
)

$ErrorActionPreference = "Stop"
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$testPath = Join-Path $resolvedRoot "tests/run-workbench-runtime-tests.mjs"
$brokerTestPath = Join-Path $resolvedRoot "tests/run-telemetry-broker-tests.mjs"
$node = Get-Command "node.exe" -ErrorAction SilentlyContinue
if ($null -eq $node) {
    $node = Get-Command "node" -ErrorAction SilentlyContinue
}
if ($null -eq $node) {
    Write-Host "Workbench runtime contract: FAIL - Node.js was not found." -ForegroundColor Red
    exit 1
}

& $node.Source $testPath
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
& $node.Source $brokerTestPath
exit $LASTEXITCODE
