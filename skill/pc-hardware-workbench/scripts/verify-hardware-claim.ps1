[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClaimPath,

    [string]$EvidencePath,

    [ValidateSet("Json", "Markdown")]
    [string]$OutputFormat = "Json",

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Read-JsonDocument {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-WithInputError "$Label file does not exist: $Path"
    }
    try {
        return Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Stop-WithInputError "$Label is not valid JSON: $($_.Exception.Message)"
    }
}

function Resolve-JsonPath {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $current = $InputObject
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) {
            return [pscustomobject]@{ Found = $false; Value = $null }
        }
        if ($current -is [System.Array] -or $current -is [System.Collections.IList]) {
            $index = 0
            if (-not [int]::TryParse($segment, [ref]$index)) {
                return [pscustomobject]@{ Found = $false; Value = $null }
            }
            if ($index -lt 0 -or $index -ge $current.Count) {
                return [pscustomobject]@{ Found = $false; Value = $null }
            }
            $current = $current[$index]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return [pscustomobject]@{ Found = $false; Value = $null }
        }
        $current = $property.Value
    }
    return [pscustomobject]@{ Found = $true; Value = $current }
}

function Convert-ToNumber {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return $null
    }
    $number = 0.0
    if ([double]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        return $number
    }
    return $null
}

function Test-ClaimValue {
    param(
        [AllowNull()][object]$Expected,
        [AllowNull()][object]$Actual,
        [double]$Tolerance = 0
    )
    $expectedNumber = Convert-ToNumber $Expected
    $actualNumber = Convert-ToNumber $Actual
    if ($null -ne $expectedNumber -and $null -ne $actualNumber) {
        return [math]::Abs($expectedNumber - $actualNumber) -le $Tolerance
    }
    if ($Expected -is [bool] -or $Actual -is [bool]) {
        return ([bool]$Expected) -eq ([bool]$Actual)
    }
    return ([string]$Expected).Trim() -ieq ([string]$Actual).Trim()
}

$claimDocument = Read-JsonDocument -Path $ClaimPath -Label "Claim"
if (-not ($claimDocument.PSObject.Properties.Name -contains "claims")) {
    Stop-WithInputError "Claim document is missing the claims array."
}
$claims = @($claimDocument.claims)
if ($claims.Count -eq 0) {
    Stop-WithInputError "Claim document contains no claims."
}
$evidence = if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
    Read-JsonDocument -Path $EvidencePath -Label "Evidence"
}
else {
    $null
}

$results = New-Object System.Collections.Generic.List[object]
foreach ($claim in $claims) {
    $id = [string]$claim.id
    $path = [string]$claim.path
    if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($path)) {
        Stop-WithInputError "Every claim requires id and path."
    }
    if (-not ($claim.PSObject.Properties.Name -contains "expected")) {
        Stop-WithInputError "Claim '$id' is missing expected."
    }
    $sourceType = if ($claim.PSObject.Properties.Name -contains "sourceType") {
        [string]$claim.sourceType
    }
    else {
        "user-confirmed-current"
    }
    if ($sourceType -notin @("measured-current", "user-confirmed-current", "historical", "user-estimate")) {
        Stop-WithInputError "Claim '$id' has an unsupported sourceType: $sourceType"
    }
    $tolerance = 0.0
    if ($claim.PSObject.Properties.Name -contains "tolerance") {
        $parsedTolerance = Convert-ToNumber $claim.tolerance
        if ($null -ne $parsedTolerance -and $parsedTolerance -ge 0) {
            $tolerance = $parsedTolerance
        }
    }
    $observed = if ($null -ne $evidence) {
        Resolve-JsonPath -InputObject $evidence -Path $path
    }
    else {
        [pscustomobject]@{ Found = $false; Value = $null }
    }
    $status = ""
    $matched = $null
    $observedValue = $null
    if ($observed.Found) {
        $observedValue = $observed.Value
        $matched = Test-ClaimValue -Expected $claim.expected -Actual $observedValue -Tolerance $tolerance
        $status = if ($matched) { "matched-current" } else { "conflict" }
    }
    else {
        $status = $sourceType
    }
    $results.Add([pscustomobject][ordered]@{
        id = $id
        path = $path
        expected = $claim.expected
        observed = $observedValue
        unit = if ($claim.PSObject.Properties.Name -contains "unit") { [string]$claim.unit } else { $null }
        tolerance = $tolerance
        sourceType = $sourceType
        status = $status
        matched = $matched
        evidenceFound = [bool]$observed.Found
    }) | Out-Null
}

$conflictCount = @($results | Where-Object { $_.status -eq "conflict" }).Count
$matchedCount = @($results | Where-Object { $_.status -eq "matched-current" }).Count
$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    generatedAt = [datetimeoffset]::Now.ToString("o")
    claimPath = (Resolve-Path -LiteralPath $ClaimPath).Path
    evidencePath = if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $null } else { (Resolve-Path -LiteralPath $EvidencePath).Path }
    result = if ($conflictCount -gt 0) { "conflict" } else { "no-conflict" }
    matchedCount = $matchedCount
    conflictCount = $conflictCount
    userReportedCount = @($results | Where-Object { $_.status -eq "user-confirmed-current" }).Count
    historicalCount = @($results | Where-Object { $_.status -eq "historical" }).Count
    unverifiedCount = @($results | Where-Object { $_.status -eq "unverified" }).Count
    claims = $results.ToArray()
}

$output = if ($OutputFormat -eq "Markdown") {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Hardware claim verification") | Out-Null
    $lines.Add("") | Out-Null
    $lines.Add("| Claim | Expected | Observed | Status | Source |") | Out-Null
    $lines.Add("|---|---:|---:|---|---|") | Out-Null
    foreach ($item in $results) {
        $expected = [string]$item.expected
        $observed = if ($item.evidenceFound) { [string]$item.observed } else { "-" }
        $lines.Add("| $($item.id) | $expected | $observed | $($item.status) | $($item.sourceType) |") | Out-Null
    }
    $lines.Add("") | Out-Null
    if ($conflictCount -gt 0) {
        $lines.Add("Conflicts are present. Keep both the user claim and the current observation; do not silently choose one.") | Out-Null
    }
    else {
        $lines.Add("No conflict was detected. A match does not prove stability or a safe configuration.") | Out-Null
    }
    $lines -join "`r`n"
}
else {
    $report | ConvertTo-Json -Depth 10
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    [IO.File]::WriteAllText($OutputPath, $output, $utf8NoBom)
}
else {
    Write-Output $output
}

if ($conflictCount -gt 0) {
    exit 1
}
