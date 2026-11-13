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
        "UpdateExperiment",
        "SetNextAction",
        "Show",
        "Resume",
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

    [datetimeoffset]$EvidenceCapturedAt = [datetimeoffset]::Now,

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

    [string[]]$EvidenceIds = @(),

    [ValidateSet("valid", "provisional", "none")]
    [string]$BaselineStatus = "provisional",

    [string]$BaselineId,

    [string]$ExperimentId,

    [string]$Change,

    [string]$Expected,

    [string]$Result,

    [ValidateSet("pending", "pass", "fail", "inconclusive")]
    [string]$Outcome = "pending",

    [string]$Decision,

    [string]$PassCriteria,

    [string]$AbortCriteria,

    [string]$Recovery,

    [ValidateSet(
        "unknown",
        "not-checked",
        "verified-active",
        "verified-after-reboot",
        "not-active",
        "not-applicable"
    )]
    [string]$PersistenceStatus = "unknown",

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

function Test-DateTimeOffsetValue {
    param([string]$Value)
    try {
        [datetimeoffset]::Parse(
            $Value,
            $invariant,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ) | Out-Null
        return $true
    }
    catch {
        return $false
    }
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

function ConvertTo-CompactText {
    param(
        [AllowNull()][object]$Value,
        [int]$MaximumLength = 260
    )
    $text = ConvertTo-SingleLineText $Value
    if ($text.Length -le $MaximumLength) {
        return $text
    }
    return $text.Substring(0, $MaximumLength - 3).TrimEnd() + "..."
}

function Merge-NormalizedIds {
    param(
        [AllowNull()][object[]]$Existing,
        [AllowNull()][object[]]$Added
    )
    return @(
        @($Existing) + @($Added) |
            ForEach-Object { ConvertTo-SingleLineText $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Select-Object -Unique
    )
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
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

function Assert-CaseIntegrity {
    param(
        [Parameter(Mandatory = $true)][object]$Case,
        [Parameter(Mandatory = $true)][string]$CaseFile
    )

    $caseRoot = [IO.Path]::GetFullPath((Split-Path -Parent $CaseFile))
    $caseRootPrefix = $caseRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $evidenceIds = New-Object System.Collections.Generic.HashSet[string]
    $hypothesisIds = New-Object System.Collections.Generic.HashSet[string]
    $baselineIds = New-Object System.Collections.Generic.HashSet[string]
    foreach ($fieldName in @("createdAt", "updatedAt")) {
        if (-not (Test-DateTimeOffsetValue ([string]$Case.$fieldName))) {
            throw "Hardware case field '$fieldName' has an invalid timestamp."
        }
    }
    foreach ($item in @($Case.hypotheses)) {
        $hypothesisIds.Add([string]$item.Id) | Out-Null
        if (([string]$item.Status) -notin @("verified", "supported", "pending", "contradicted", "unknown")) {
            throw "Hypothesis '$($item.Id)' has an invalid status '$($item.Status)'."
        }
        if ($null -eq $item.PSObject.Properties["CreatedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$item.CreatedAt)) -or
            $null -eq $item.PSObject.Properties["UpdatedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$item.UpdatedAt))) {
            throw "Hypothesis '$($item.Id)' has an invalid timestamp."
        }
    }

    foreach ($evidence in @($Case.evidence)) {
        $evidenceIds.Add([string]$evidence.Id) | Out-Null
        if (([string]$evidence.Type) -notin @("telemetry", "screenshot", "report", "log", "manual", "web", "other")) {
            throw "Evidence '$($evidence.Id)' has an invalid type '$($evidence.Type)'."
        }
        if ($null -eq $evidence.PSObject.Properties["CapturedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$evidence.CapturedAt))) {
            throw "Evidence '$($evidence.Id)' has an invalid CapturedAt timestamp."
        }

        $recordedHash = if ($null -ne $evidence.PSObject.Properties["Sha256"]) {
            [string]$evidence.Sha256
        }
        else {
            ""
        }
        $importedPath = if ($null -ne $evidence.PSObject.Properties["ImportedPath"]) {
            [string]$evidence.ImportedPath
        }
        else {
            ""
        }
        $sourcePath = if ($null -ne $evidence.PSObject.Properties["SourcePath"]) {
            [string]$evidence.SourcePath
        }
        else {
            ""
        }

        if (-not [string]::IsNullOrWhiteSpace($importedPath)) {
            if ([IO.Path]::IsPathRooted($importedPath)) {
                throw "Evidence '$($evidence.Id)' ImportedPath must be relative."
            }
            $storedPath = [IO.Path]::GetFullPath((Join-Path $caseRoot $importedPath))
            if (-not $storedPath.StartsWith($caseRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Evidence '$($evidence.Id)' ImportedPath escapes the case directory."
            }
            if (-not (Test-Path -LiteralPath $storedPath -PathType Leaf)) {
                throw "Evidence '$($evidence.Id)' file is missing: $importedPath"
            }
            if (Test-PathChainHasReparsePoint -Path $storedPath) {
                throw "Evidence '$($evidence.Id)' resolves through a reparse point."
            }
            $actualHash = (Get-FileHash -LiteralPath $storedPath -Algorithm SHA256).Hash
            if ([string]::IsNullOrWhiteSpace($recordedHash) -or $actualHash -ne $recordedHash) {
                throw "Evidence '$($evidence.Id)' SHA-256 does not match the stored file."
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($sourcePath)) {
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "Evidence '$($evidence.Id)' source file is missing: $sourcePath"
            }
            $actualHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
            if ([string]::IsNullOrWhiteSpace($recordedHash) -or $actualHash -ne $recordedHash) {
                throw "Evidence '$($evidence.Id)' SHA-256 does not match its source file."
            }
        }
        elseif ($evidence.Type -notin @("manual", "web", "other")) {
            throw "Evidence '$($evidence.Id)' of type '$($evidence.Type)' has no stored file."
        }
    }

    foreach ($baseline in @($Case.baselines)) {
        $baselineIds.Add([string]$baseline.Id) | Out-Null
        $baselineStatus = if ($null -ne $baseline.PSObject.Properties["Status"]) {
            [string]$baseline.Status
        }
        else {
            "unknown"
        }
        if ($baselineStatus -notin @("valid", "provisional", "none")) {
            throw "Baseline '$($baseline.Id)' has an invalid status '$baselineStatus'."
        }
        if ($null -eq $baseline.PSObject.Properties["RecordedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$baseline.RecordedAt))) {
            throw "Baseline '$($baseline.Id)' has an invalid RecordedAt timestamp."
        }
        if ([string]::IsNullOrWhiteSpace([string]$baseline.EvidenceId)) {
            if ($baselineStatus -eq "valid") {
                throw "Valid baseline '$($baseline.Id)' requires an EvidenceId."
            }
        }
        elseif (-not $evidenceIds.Contains([string]$baseline.EvidenceId)) {
            throw "Baseline '$($baseline.Id)' references missing evidence '$($baseline.EvidenceId)'."
        }
    }

    foreach ($event in @($Case.timeline)) {
        if (([string]$event.Type) -notin @("system-update", "driver", "bios", "hardware", "symptom", "change", "recovery", "note")) {
            throw "Timeline event '$($event.Id)' has an invalid type '$($event.Type)'."
        }
        if ($null -eq $event.PSObject.Properties["OccurredAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$event.OccurredAt)) -or
            $null -eq $event.PSObject.Properties["RecordedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$event.RecordedAt))) {
            throw "Timeline event '$($event.Id)' has an invalid timestamp."
        }
    }

    foreach ($experiment in @($Case.experiments)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$experiment.HypothesisId) -and
            -not $hypothesisIds.Contains([string]$experiment.HypothesisId)) {
            throw "Experiment '$($experiment.Id)' references missing hypothesis '$($experiment.HypothesisId)'."
        }
        $experimentBaselineId = [string](Get-OptionalPropertyValue $experiment "BaselineId")
        if (-not [string]::IsNullOrWhiteSpace($experimentBaselineId) -and
            -not $baselineIds.Contains($experimentBaselineId)) {
            throw "Experiment '$($experiment.Id)' references missing baseline '$experimentBaselineId'."
        }
        $experimentEvidenceIds = @(Get-OptionalPropertyValue $experiment "EvidenceIds" @())
        foreach ($experimentEvidenceIdValue in $experimentEvidenceIds) {
            $experimentEvidenceId = [string]$experimentEvidenceIdValue
            if (-not [string]::IsNullOrWhiteSpace($experimentEvidenceId) -and
                -not $evidenceIds.Contains($experimentEvidenceId)) {
                throw "Experiment '$($experiment.Id)' references missing evidence '$experimentEvidenceId'."
            }
        }
        $experimentOutcome = [string](Get-OptionalPropertyValue $experiment "Outcome" "")
        if (-not [string]::IsNullOrWhiteSpace($experimentOutcome) -and
            $experimentOutcome -notin @("pending", "pass", "fail", "inconclusive")) {
            throw "Experiment '$($experiment.Id)' has an invalid outcome '$experimentOutcome'."
        }
        if ($experimentOutcome -ne "pending" -and
            [string]::IsNullOrWhiteSpace([string]$experiment.Result)) {
            throw "Experiment '$($experiment.Id)' has a completed outcome but no result."
        }
        $experimentPersistence = [string](Get-OptionalPropertyValue $experiment "PersistenceStatus" "")
        if (-not [string]::IsNullOrWhiteSpace($experimentPersistence) -and
            $experimentPersistence -notin @(
                "unknown",
                "not-checked",
                "verified-active",
                "verified-after-reboot",
                "not-active",
                "not-applicable"
            )) {
            throw "Experiment '$($experiment.Id)' has an invalid persistence status '$experimentPersistence'."
        }
        if ($null -eq $experiment.PSObject.Properties["RecordedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$experiment.RecordedAt)) -or
            $null -eq $experiment.PSObject.Properties["UpdatedAt"] -or
            -not (Test-DateTimeOffsetValue ([string]$experiment.UpdatedAt))) {
            throw "Experiment '$($experiment.Id)' has an invalid timestamp."
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
        $sourceFileName = $null
        $storedPath = $null
        $hash = $null
        if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
            try {
                $sourcePath = Assert-LocalReadFilePath -Path $EvidencePath
            }
            catch {
                Stop-WithCaseInputError $_.Exception.Message
            }
            $sourceFileName = [IO.Path]::GetFileName($sourcePath)
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
            OriginalFileName = $sourceFileName
            Sha256 = $hash
            CapturedAt = ConvertTo-CaseTimestamp $EvidenceCapturedAt
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
        if ($BaselineStatus -ne "none" -and [string]::IsNullOrWhiteSpace($Workload)) {
            Stop-WithCaseInputError "AddBaseline requires -Workload unless -BaselineStatus is none."
        }
        if ($BaselineStatus -eq "none" -and [string]::IsNullOrWhiteSpace($Summary)) {
            Stop-WithCaseInputError "A none baseline requires -Summary explaining why no valid baseline exists."
        }
        if (-not [string]::IsNullOrWhiteSpace($EvidenceId) -and
            -not (@($case.evidence | Where-Object { $_.Id -eq $EvidenceId }))) {
            Stop-WithCaseInputError "Evidence not found: $EvidenceId"
        }
        if ($BaselineStatus -eq "valid" -and [string]::IsNullOrWhiteSpace($EvidenceId)) {
            Stop-WithCaseInputError "A valid baseline requires -EvidenceId."
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.baselines) -Prefix "B"
            Status = $BaselineStatus
            Workload = if ([string]::IsNullOrWhiteSpace($Workload)) { $null } else { $Workload }
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
        if (-not [string]::IsNullOrWhiteSpace($BaselineId) -and
            -not (@($case.baselines | Where-Object { $_.Id -eq $BaselineId }))) {
            Stop-WithCaseInputError "Baseline not found: $BaselineId"
        }
        if ($Outcome -ne "pending" -and [string]::IsNullOrWhiteSpace($Result)) {
            Stop-WithCaseInputError "A completed experiment outcome requires -Result."
        }
        $normalizedEvidenceIds = @(Get-NormalizedList $EvidenceIds | Select-Object -Unique)
        foreach ($referencedEvidenceId in $normalizedEvidenceIds) {
            if (-not (@($case.evidence | Where-Object { $_.Id -eq $referencedEvidenceId }))) {
                Stop-WithCaseInputError "Evidence not found: $referencedEvidenceId"
            }
        }
        $item = [pscustomobject]@{
            Id = Get-NextEntityId -Items @($case.experiments) -Prefix "X"
            HypothesisId = if ([string]::IsNullOrWhiteSpace($HypothesisId)) { $null } else { $HypothesisId }
            BaselineId = if ([string]::IsNullOrWhiteSpace($BaselineId)) { $null } else { $BaselineId }
            Change = $Change
            Expected = $Expected
            Result = $Result
            Outcome = $Outcome
            Decision = $Decision
            PassCriteria = $PassCriteria
            AbortCriteria = $AbortCriteria
            Recovery = $Recovery
            PersistenceStatus = $PersistenceStatus
            EvidenceIds = @($normalizedEvidenceIds)
            RecordedAt = $now
            UpdatedAt = $now
        }
        $case.experiments = @(@($case.experiments) + @($item))
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $item.Id
        break
    }
    "UpdateExperiment" {
        if ([string]::IsNullOrWhiteSpace($ExperimentId)) {
            Stop-WithCaseInputError "UpdateExperiment requires -ExperimentId."
        }
        $target = @($case.experiments | Where-Object { $_.Id -eq $ExperimentId }) | Select-Object -First 1
        if ($null -eq $target) {
            Stop-WithCaseInputError "Experiment not found: $ExperimentId"
        }
        if ($PSBoundParameters.ContainsKey("HypothesisId")) {
            if (-not [string]::IsNullOrWhiteSpace($HypothesisId) -and
                -not (@($case.hypotheses | Where-Object { $_.Id -eq $HypothesisId }))) {
                Stop-WithCaseInputError "Hypothesis not found: $HypothesisId"
            }
            $target.HypothesisId = if ([string]::IsNullOrWhiteSpace($HypothesisId)) { $null } else { $HypothesisId }
        }
        if ($PSBoundParameters.ContainsKey("BaselineId")) {
            if (-not [string]::IsNullOrWhiteSpace($BaselineId) -and
                -not (@($case.baselines | Where-Object { $_.Id -eq $BaselineId }))) {
                Stop-WithCaseInputError "Baseline not found: $BaselineId"
            }
            $target.BaselineId = if ([string]::IsNullOrWhiteSpace($BaselineId)) { $null } else { $BaselineId }
        }
        if ($PSBoundParameters.ContainsKey("EvidenceIds")) {
            $normalizedEvidenceIds = @(Get-NormalizedList $EvidenceIds | Select-Object -Unique)
            foreach ($referencedEvidenceId in $normalizedEvidenceIds) {
                if (-not (@($case.evidence | Where-Object { $_.Id -eq $referencedEvidenceId }))) {
                    Stop-WithCaseInputError "Evidence not found: $referencedEvidenceId"
                }
            }
            $target.EvidenceIds = @(
                Merge-NormalizedIds `
                    -Existing @(Get-OptionalPropertyValue $target "EvidenceIds" @()) `
                    -Added $normalizedEvidenceIds
            )
        }
        foreach ($fieldName in @(
            "Change",
            "Expected",
            "Result",
            "Outcome",
            "Decision",
            "PassCriteria",
            "AbortCriteria",
            "Recovery",
            "PersistenceStatus"
        )) {
            if ($PSBoundParameters.ContainsKey($fieldName)) {
                $target.$fieldName = [string](Get-Variable -Name $fieldName -ValueOnly)
            }
        }
        $updatedOutcome = [string](Get-OptionalPropertyValue $target "Outcome" "pending")
        if ($updatedOutcome -ne "pending" -and
            [string]::IsNullOrWhiteSpace([string]$target.Result)) {
            Stop-WithCaseInputError "A completed experiment outcome requires a result."
        }
        $target.UpdatedAt = $now
        Write-Case -FilePath $caseFile -Case $case
        Write-Output $target.Id
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
    "Resume" {
        Assert-CaseIntegrity -Case $case -CaseFile $caseFile
        $nextActionText = if ([string]::IsNullOrWhiteSpace([string]$case.nextAction)) {
            "not set"
        }
        else {
            ConvertTo-CompactText $case.nextAction
        }
        Write-Output "# Hardware case resume"
        Write-Output ""
        Write-Output "- Device: $(ConvertTo-CompactText $case.device.alias) / $(ConvertTo-CompactText $case.device.platform)"
        Write-Output "- Identity: $(ConvertTo-CompactText $case.device.identityQuality)"
        Write-Output "- Goal: $(ConvertTo-CompactText $case.goal)"
        Write-Output "- Status: $(ConvertTo-SingleLineText $case.status)"
        Write-Output "- Updated: $(ConvertTo-SingleLineText $case.updatedAt)"
        Write-Output "- Next action: $nextActionText"

        Write-Output ""
        Write-Output "## Latest evidence"
        $recentEvidence = @($case.evidence | Select-Object -Last 3)
        if ($recentEvidence.Count -eq 0) {
            Write-Output "- None recorded"
        }
        else {
            foreach ($evidence in $recentEvidence) {
                $fileName = [string](Get-OptionalPropertyValue $evidence "OriginalFileName" "")
                $fileSuffix = if ([string]::IsNullOrWhiteSpace($fileName)) { "" } else { " / $(ConvertTo-CompactText $fileName 100)" }
                Write-Output "- $($evidence.Id) [$($evidence.Type)] $(ConvertTo-CompactText $evidence.Summary)$fileSuffix"
            }
        }

        Write-Output ""
        Write-Output "## Open or supported hypotheses"
        $openHypotheses = @(
            $case.hypotheses |
                Where-Object { $_.Status -notin @("verified", "contradicted") } |
                Select-Object -Last 3
        )
        if ($openHypotheses.Count -eq 0) {
            Write-Output "- None recorded"
        }
        else {
            foreach ($hypothesis in $openHypotheses) {
                $nextTest = ConvertTo-CompactText (Get-OptionalPropertyValue $hypothesis "NextTest" "")
                $testSuffix = if ([string]::IsNullOrWhiteSpace($nextTest)) { "" } else { " / Next test: $nextTest" }
                Write-Output "- $($hypothesis.Id) [$($hypothesis.Status)] $(ConvertTo-CompactText $hypothesis.Text)$testSuffix"
            }
        }

        Write-Output ""
        Write-Output "## Recent baselines"
        $recentBaselines = @($case.baselines | Select-Object -Last 3)
        if ($recentBaselines.Count -eq 0) {
            Write-Output "- None recorded"
        }
        else {
            foreach ($baseline in $recentBaselines) {
                Write-Output "- $($baseline.Id) [$($baseline.Status)] workload: $(ConvertTo-CompactText $baseline.Workload) / evidence: $((Get-OptionalPropertyValue $baseline 'EvidenceId' 'none'))"
            }
        }

        Write-Output ""
        Write-Output "## Recent experiments"
        $recentExperiments = @($case.experiments | Select-Object -Last 3)
        if ($recentExperiments.Count -eq 0) {
            Write-Output "- None recorded"
        }
        else {
            foreach ($experiment in $recentExperiments) {
                $experimentOutcome = ConvertTo-CompactText (Get-OptionalPropertyValue $experiment "Outcome" "not recorded")
                $experimentDecision = ConvertTo-CompactText (Get-OptionalPropertyValue $experiment "Decision" "not recorded")
                $experimentPersistence = ConvertTo-CompactText (Get-OptionalPropertyValue $experiment "PersistenceStatus" "not recorded")
                Write-Output "- $($experiment.Id) [$experimentOutcome] $(ConvertTo-CompactText $experiment.Change) / decision: $experimentDecision / persistence: $experimentPersistence"
                $experimentPass = ConvertTo-CompactText (Get-OptionalPropertyValue $experiment "PassCriteria" "")
                $experimentAbort = ConvertTo-CompactText (Get-OptionalPropertyValue $experiment "AbortCriteria" "")
                if (-not [string]::IsNullOrWhiteSpace($experimentPass) -or
                    -not [string]::IsNullOrWhiteSpace($experimentAbort)) {
                    Write-Output "  Criteria: pass: $experimentPass / abort: $experimentAbort"
                }
                $experimentRecovery = ConvertTo-CompactText (Get-OptionalPropertyValue $experiment "Recovery" "")
                if (-not [string]::IsNullOrWhiteSpace($experimentRecovery)) {
                    Write-Output "  Recovery: $experimentRecovery"
                }
            }
        }

        Write-Output ""
        Write-Output "## Resume rule"
        Write-Output "- Revalidate historical settings and current state before any new state-changing action."
        Write-Output "- This packet records state; it does not prove diagnosis, stability, or persistence."
        break
    }
    "Validate" {
        Assert-CaseShape -Case $case
        Assert-CaseIntegrity -Case $case -CaseFile $caseFile
        Write-Output "Hardware case is valid: $caseFile"
        break
    }
}
