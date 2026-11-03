[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "New",
        "AddEvidence",
        "AddHypothesis",
        "UpdateHypothesis",
        "AddTimeline",
        "AddBaseline",
        "AddExperiment",
        "SetNextAction",
        "Show",
        "Validate"
    )]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$CasePath,

    [string]$DeviceAlias,

    [string]$Platform,

    [string]$Goal,

    [ValidateSet("confirmed", "user-reported", "unknown", "unreadable", "conflict")]
    [string]$IdentityQuality = "unknown",

    [ValidateSet("telemetry", "screenshot", "report", "log", "manual", "web", "other")]
    [string]$EvidenceType = "other",

    [string]$EvidencePath,

    [string]$Summary,

    [switch]$ImportArtifact,

    [string]$Hypothesis,

    [string]$HypothesisId,

    [ValidateSet("verified", "supported", "pending", "contradicted", "unknown")]
    [string]$Status = "pending",

    [string[]]$Supporting = @(),

    [string[]]$Contradicting = @(),

    [string]$NextTest,

    [datetimeoffset]$OccurredAt = [datetimeoffset]::Now,

    [ValidateSet("system-update", "driver", "bios", "hardware", "symptom", "change", "recovery", "note")]
    [string]$EventType = "note",

    [string]$Workload,

    [string]$Conditions,

    [string]$EvidenceId,

    [string]$ExperimentId,

    [string]$Change,

    [string]$Expected,

    [string]$Result,

    [string]$Decision,

    [string]$NextAction,

    [switch]$AsJson
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

function Stop-WithCaseInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function ConvertTo-CaseTimestamp {
    param([datetimeoffset]$Value)
    return $Value.ToString("o", $invariant)
}

function Get-NormalizedList {
    param([AllowNull()][object]$Value)
    return @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
}

function ConvertTo-SingleLineText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    return (([string]$Value) -replace "[\p{Cc}\p{Cf}]", " ").Trim()
}

function Get-CaseFilePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $candidate = ConvertTo-LocalFilesystemPath -Path $Path
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        return Join-Path $candidate "case.json"
    }
    return $candidate
}

function Read-Case {
    param([Parameter(Mandatory = $true)][string]$Path)

    $caseFile = Get-CaseFilePath -Path $Path
    if (-not (Test-Path -LiteralPath $caseFile -PathType Leaf)) {
        Stop-WithCaseInputError "Hardware case file not found: $caseFile"
    }
    if (Test-PathChainHasReparsePoint -Path $caseFile) {
        Stop-WithCaseInputError "Hardware case path resolves through a symbolic link, junction, or reparse point."
    }
    try {
        return [pscustomobject]@{
            FilePath = $caseFile
            Case = (Get-Content -Raw -LiteralPath $caseFile -Encoding UTF8 | ConvertFrom-Json)
        }
    }
    catch {
        throw "Hardware case JSON is invalid: $($_.Exception.Message)"
    }
}

function Write-Case {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][object]$Case
    )

    $Case.UpdatedAt = ConvertTo-CaseTimestamp ([datetimeoffset]::Now)
    $json = $Case | ConvertTo-Json -Depth 20
    $temporary = "$FilePath.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, $json + "`r`n", $utf8NoBom)
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            $backup = "$FilePath.bak-$([guid]::NewGuid().ToString('N'))"
            try {
                [IO.File]::Replace($temporary, $FilePath, $backup)
            }
            finally {
                if (Test-Path -LiteralPath $backup) {
                    Remove-Item -LiteralPath $backup -Force
                }
            }
        }
        else {
            Move-Item -LiteralPath $temporary -Destination $FilePath
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-NextEntityId {
    param(
        [object[]]$Items,
        [string]$Prefix
    )

    $maximum = 0
    foreach ($item in @($Items)) {
        if ($null -eq $item) {
            continue
        }
        $property = $item.PSObject.Properties["Id"]
        if ($null -eq $property) {
            continue
        }
        $match = [regex]::Match([string]$property.Value, "^$([regex]::Escape($Prefix))-(\d+)$")
        if ($match.Success) {
            $value = [int]$match.Groups[1].Value
            if ($value -gt $maximum) {
                $maximum = $value
            }
        }
    }
    return "{0}-{1:D3}" -f $Prefix, ($maximum + 1)
}

function Assert-CaseShape {
    param([Parameter(Mandatory = $true)][object]$Case)

    $required = @(
        "schemaVersion", "caseId", "createdAt", "updatedAt", "device", "goal",
        "status", "privacy", "evidence", "hypotheses", "timeline",
        "baselines", "experiments", "changes", "snapshots", "nextAction", "warnings"
    )
    foreach ($name in $required) {
        if ($null -eq $Case.PSObject.Properties[$name]) {
            throw "Hardware case is missing required field '$name'."
        }
    }
    if ($Case.schemaVersion -ne "1.0") {
        throw "Unsupported hardware-case schema version: $($Case.schemaVersion)"
    }
    if ($Case.caseId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw "Hardware case has an invalid caseId."
    }

    $seen = New-Object System.Collections.Generic.HashSet[string]
    foreach ($collectionName in @("evidence", "hypotheses", "timeline", "baselines", "experiments", "changes", "snapshots")) {
        foreach ($item in @($Case.$collectionName)) {
            if ($null -eq $item -or $null -eq $item.PSObject.Properties["Id"]) {
                throw "Hardware case collection '$collectionName' contains an item without Id."
            }
            if (-not $seen.Add([string]$item.Id)) {
                throw "Hardware case contains duplicate Id '$($item.Id)'."
            }
        }
    }
}

if ($Action -eq "New") {
    if ([string]::IsNullOrWhiteSpace($DeviceAlias) -or [string]::IsNullOrWhiteSpace($Goal)) {
        Stop-WithCaseInputError "New requires -DeviceAlias and -Goal."
    }
    try {
        $directory = ConvertTo-LocalFilesystemPath -Path $CasePath
    }
    catch {
        Stop-WithCaseInputError $_.Exception.Message
    }
    if (Test-Path -LiteralPath $directory -PathType Leaf) {
        Stop-WithCaseInputError "CasePath must be a directory, not a file: $directory"
    }
    if (Test-Path -LiteralPath $directory -PathType Container) {
        $existing = @(Get-ChildItem -LiteralPath $directory -Force)
        if ($existing.Count -gt 0) {
            Stop-WithCaseInputError "CasePath directory is not empty and will not be reused: $directory"
        }
    }
    else {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $now = ConvertTo-CaseTimestamp ([datetimeoffset]::Now)
    $case = [pscustomobject]@{
        schemaVersion = "1.0"
        caseId = [guid]::NewGuid().ToString()
        createdAt = $now
        updatedAt = $now
        device = [pscustomobject]@{
            alias = $DeviceAlias
            platform = if ([string]::IsNullOrWhiteSpace($Platform)) { "unknown" } else { $Platform }
            identityQuality = $IdentityQuality
            hardwareFingerprint = $null
            configurationFingerprint = $null
        }
        goal = $Goal
        status = "open"
        privacy = [pscustomobject]@{
            classification = "local-private"
            shareable = $false
            redactBeforeExport = $true
        }
        evidence = @()
        hypotheses = @()
        timeline = @()
        baselines = @()
        experiments = @()
        changes = @()
        snapshots = @()
        nextAction = $null
        warnings = @()
    }
    $caseFile = Join-Path $directory "case.json"
    Write-Case -FilePath $caseFile -Case $case
    Write-Output $caseFile
    return
}

$loaded = Read-Case -Path $CasePath
$caseFile = $loaded.FilePath
$case = $loaded.Case
Assert-CaseShape -Case $case
$now = ConvertTo-CaseTimestamp ([datetimeoffset]::Now)

switch ($Action) {
    "AddEvidence" {
        if ([string]::IsNullOrWhiteSpace($Summary)) {
            Stop-WithCaseInputError "AddEvidence requires -Summary."
        }
        $sourcePath = $null
        $storedPath = $null
        $hash = $null
        if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
            try {
                $sourcePath = Assert-LocalReadFilePath -Path $EvidencePath
            }
            catch {
                Stop-WithCaseInputError $_.Exception.Message
            }
            $hash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
            if ($ImportArtifact) {
                $artifactDirectory = Join-Path (Split-Path -Parent $caseFile) "artifacts"
                if (-not (Test-Path -LiteralPath $artifactDirectory -PathType Container)) {
                    New-Item -ItemType Directory -Path $artifactDirectory | Out-Null
                }
                $safeName = [IO.Path]::GetFileName($sourcePath) -replace '[^\w.\-]', '_'
                $storedName = "$(Get-Date -Format 'yyyyMMdd-HHmmssfff')-$safeName"
                $destination = Join-Path $artifactDirectory $storedName
                Copy-Item -LiteralPath $sourcePath -Destination $destination
                $storedPath = "artifacts/$storedName"
                $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            }
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.evidence) -Prefix "E"
            Type = $EvidenceType
            Summary = $Summary
            ImportedPath = $storedPath
            SourcePath = if ($ImportArtifact) { $null } else { $sourcePath }
            Sha256 = $hash
            CapturedAt = $now
        }
        $case.evidence = @(@($case.evidence) + @($item))
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $item.Id
        break
    }
    "AddHypothesis" {
        if ([string]::IsNullOrWhiteSpace($Hypothesis)) {
            Stop-WithCaseInputError "AddHypothesis requires -Hypothesis."
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.hypotheses) -Prefix "H"
            Text = $Hypothesis
            Status = $Status
            Supporting = @(Get-NormalizedList $Supporting)
            Contradicting = @(Get-NormalizedList $Contradicting)
            NextTest = $NextTest
            CreatedAt = $now
            UpdatedAt = $now
        }
        $case.hypotheses = @(@($case.hypotheses) + @($item))
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $item.Id
        break
    }
    "UpdateHypothesis" {
        if ([string]::IsNullOrWhiteSpace($HypothesisId)) {
            Stop-WithCaseInputError "UpdateHypothesis requires -HypothesisId."
        }
        $target = @($case.hypotheses | Where-Object { $_.Id -eq $HypothesisId }) | Select-Object -First 1
        if ($null -eq $target) {
            Stop-WithCaseInputError "Hypothesis not found: $HypothesisId"
        }
        if ($PSBoundParameters.ContainsKey("Status")) {
            $target.Status = $Status
        }
        if ($null -ne $target.PSObject.Properties["UpdatedAt"]) {
            $target.UpdatedAt = $now
        }
        if ($PSBoundParameters.ContainsKey("Supporting") -and @($Supporting).Count -gt 0) {
            $target.Supporting = @(@($target.Supporting) + @(Get-NormalizedList $Supporting))
        }
        if ($PSBoundParameters.ContainsKey("Contradicting") -and @($Contradicting).Count -gt 0) {
            $target.Contradicting = @(@($target.Contradicting) + @(Get-NormalizedList $Contradicting))
        }
        if ($PSBoundParameters.ContainsKey("NextTest")) {
            $target.NextTest = $NextTest
        }
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $target.Id
        break
    }
    "AddTimeline" {
        if ([string]::IsNullOrWhiteSpace($Summary)) {
            Stop-WithCaseInputError "AddTimeline requires -Summary."
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.timeline) -Prefix "T"
            OccurredAt = ConvertTo-CaseTimestamp $OccurredAt
            RecordedAt = $now
            Type = $EventType
            Summary = $Summary
        }
        $case.timeline = @(@($case.timeline) + @($item))
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $item.Id
        break
    }
    "AddBaseline" {
        if ([string]::IsNullOrWhiteSpace($Workload)) {
            Stop-WithCaseInputError "AddBaseline requires -Workload."
        }
        if (-not [string]::IsNullOrWhiteSpace($EvidenceId) -and
            -not (@($case.evidence | Where-Object { $_.Id -eq $EvidenceId }))) {
            Stop-WithCaseInputError "Evidence not found: $EvidenceId"
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.baselines) -Prefix "B"
            Workload = $Workload
            Conditions = $Conditions
            EvidenceId = if ([string]::IsNullOrWhiteSpace($EvidenceId)) { $null } else { $EvidenceId }
            Summary = $Summary
            RecordedAt = $now
        }
        $case.baselines = @(@($case.baselines) + @($item))
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $item.Id
        break
    }
    "AddExperiment" {
        if ([string]::IsNullOrWhiteSpace($Change)) {
            Stop-WithCaseInputError "AddExperiment requires -Change."
        }
        if (-not [string]::IsNullOrWhiteSpace($HypothesisId) -and
            -not (@($case.hypotheses | Where-Object { $_.Id -eq $HypothesisId }))) {
            Stop-WithCaseInputError "Hypothesis not found: $HypothesisId"
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.experiments) -Prefix "X"
            HypothesisId = if ([string]::IsNullOrWhiteSpace($HypothesisId)) { $null } else { $HypothesisId }
            Change = $Change
            Expected = $Expected
            Result = $Result
            Decision = $Decision
            RecordedAt = $now
            UpdatedAt = $now
        }
        $case.experiments = @(@($case.experiments) + @($item))
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $item.Id
        break
    }
    "SetNextAction" {
        if ([string]::IsNullOrWhiteSpace($NextAction)) {
            $case.nextAction = $null
        }
        else {
            $case.nextAction = $NextAction
        }
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $caseFile
        break
    }
    "Show" {
        if ($AsJson) {
            $case | ConvertTo-Json -Depth 20
            break
        }
        $openHypothesisCount = @($case.hypotheses | Where-Object {
            $_.Status -notin @("verified", "contradicted")
        }).Count
        Write-Output "# Hardware case"
        Write-Output ""
        Write-Output "- Case: $($case.caseId)"
        Write-Output "- Device: $(ConvertTo-SingleLineText $case.device.alias) / $(ConvertTo-SingleLineText $case.device.platform)"
        Write-Output "- Identity: $(ConvertTo-SingleLineText $case.device.identityQuality)"
        Write-Output "- Goal: $(ConvertTo-SingleLineText $case.goal)"
        Write-Output "- Status: $(ConvertTo-SingleLineText $case.status)"
        Write-Output "- Updated: $(ConvertTo-SingleLineText $case.updatedAt)"
        Write-Output "- Evidence: $(@($case.evidence).Count)"
        Write-Output "- Open hypotheses: $openHypothesisCount"
        Write-Output "- Baselines: $(@($case.baselines).Count)"
        Write-Output "- Experiments: $(@($case.experiments).Count)"
        $nextActionText = if ([string]::IsNullOrWhiteSpace([string]$case.nextAction)) { "not set" } else { ConvertTo-SingleLineText $case.nextAction }
        Write-Output "- Next action: $nextActionText"
        break
    }
    "Validate" {
        Assert-CaseShape -Case $case
        Write-Output "Hardware case is valid: $caseFile"
        break
    }
}
