[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command,

    [Parameter(Position = 1)]
    [string]$Target,

    [string]$Path,

    [string]$InputPath,

    [string]$ProcessName,

    [double]$SpikeMultiplier = 2.0,

    [double]$WarmupSeconds = 0,

    [double]$DurationSeconds = 0,

    [int]$WarmupRows = 0,

    [int]$MaxRows = 0,

    [ValidateSet(",", ";", "`t")]
    [string]$Delimiter = ",",

    [string[]]$IncludeColumn = @(),

    [switch]$HideFileName,

    [int]$MaxInputMegabytes = 512,

    [int]$MaxChartPoints = 480,

    [string]$BaselinePath,

    [string]$CandidatePath,

    [string]$BaselineLabel = "Baseline",

    [string]$CandidateLabel = "Candidate",

    [string]$Workload,

    [string]$Change,

    [string[]]$FocusMetric = @(),

    [int]$MaxSeries = 3,

    [int]$MaxComparisonMetrics = 8,

    [string]$ClaimPath,

    [string]$EvidencePath,

    [ValidateSet("Redacted", "Standard")]
    [string]$PrivacyMode = "Redacted",

    [switch]$RequireElevated,

    [string]$SkillRoot,

    [string]$OutputDirectory
)

$ErrorActionPreference = "Stop"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$script:InvocationParameters = $PSBoundParameters
$script:SkillRootPath = Split-Path -Parent $PSScriptRoot
$pathSafetyPath = Join-Path $PSScriptRoot "local-path-safety.ps1"
$evidenceHelperPath = Join-Path $PSScriptRoot "pcwb-evidence.ps1"

if (-not (Test-Path -LiteralPath $pathSafetyPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Local path safety helper is missing: $pathSafetyPath")
    exit 2
}
if (-not (Test-Path -LiteralPath $evidenceHelperPath -PathType Leaf)) {
    [Console]::Error.WriteLine("PCWB evidence helper is missing: $evidenceHelperPath")
    exit 2
}

. $pathSafetyPath
. $evidenceHelperPath

$script:PowerShellPath = (Get-Command "powershell.exe" -ErrorAction Stop).Source
$script:Envelope = $null
$script:ResultStatus = "ok"
$script:ResultExitCode = 0
$startedAt = [datetimeoffset]::UtcNow
$commandLabel = "unknown"
$runDirectory = $null
$failureMessage = $null

function Set-PcwbOutcome {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("ok", "partial", "needs-input", "blocked", "failed")]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1, 2, 3, 4, 5, 6)]
        [int]$Code
    )

    $script:ResultStatus = $Status
    $script:ResultExitCode = $Code
}

function Assert-PcwbNoTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    if (-not [string]::IsNullOrWhiteSpace($Target)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.unexpected-target" `
            -Message "$CommandName does not accept a target after the command." `
            -Status "needs-input" `
            -ExitCode 2)
    }
}

function Assert-PcwbAllowedParameters {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Bound,
        [Parameter(Mandatory = $true)]
        [string[]]$Allowed,
        [Parameter(Mandatory = $true)]
        [string]$CommandName
    )

    $common = @(
        "Command",
        "Target",
        "OutputDirectory",
        "Verbose",
        "Debug",
        "ErrorAction",
        "WarningAction",
        "InformationAction",
        "ProgressAction",
        "ErrorVariable",
        "WarningVariable",
        "InformationVariable",
        "OutVariable",
        "OutBuffer",
        "PipelineVariable"
    )
    foreach ($name in $Bound.Keys) {
        if ($common -contains $name -or $Allowed -contains $name) {
            continue
        }
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.unsupported" `
            -Message "Parameter -$name is not supported by pcwb $CommandName." `
            -Status "needs-input" `
            -ExitCode 2)
    }
}

function Add-PcwbInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role,
        [AllowNull()]
        [string]$InputFile,
        [Parameter(Mandatory = $true)]
        [string]$ParameterName
    )

    if ([string]::IsNullOrWhiteSpace($InputFile)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.required" `
            -Message "Parameter -$ParameterName is required." `
            -Status "needs-input" `
            -ExitCode 2)
    }
    try {
        $record = New-PcwbInputRecord -Role $Role -Path $InputFile
    }
    catch {
        $status = if (Test-PcwbPermissionFailure -ErrorRecord $_) { "blocked" } else { "needs-input" }
        $exitCode = if ($status -eq "blocked") { 6 } else { 2 }
        $code = if ($status -eq "blocked") {
            "pcwb.input.permission-required"
        }
        else {
            "pcwb.input.invalid"
        }
        throw (New-PcwbFailureException `
            -Code $code `
            -Message ("Input for -{0} was rejected: {1}" -f $ParameterName, (Get-PcwbDiagnosticText $_.Exception.Message)) `
            -Status $status `
            -ExitCode $exitCode)
    }
    $script:Envelope.Inputs.Add($record)
    return $record
}

function Invoke-SkillChild {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ChildScript,
        [Parameter(Mandatory = $true)]
        [string[]]$ChildArguments
    )

    if (-not (Test-Path -LiteralPath $ChildScript -PathType Leaf)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.child.missing" `
            -Message "Required child script is missing: $ChildScript" `
            -Status "failed" `
            -ExitCode 1)
    }
    try {
        $process = Invoke-PcwbChildProcess `
            -PowerShellPath $script:PowerShellPath `
            -ChildScript $ChildScript `
            -ChildArguments $ChildArguments `
            -WorkingDirectory $script:SkillRootPath
    }
    catch {
        throw (New-PcwbFailureException `
            -Code "pcwb.child.start-failed" `
            -Message ("Child process could not be started: {0}" -f (Get-PcwbDiagnosticText $_.Exception.Message)) `
            -Status "failed" `
            -ExitCode 1)
    }
    if ($process.ExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($process.Stderr)) {
        Add-PcwbWarning `
            -Envelope $script:Envelope `
            -Code "pcwb.child.stderr" `
            -Message $process.Stderr
    }
    return $process
}

function Throw-PcwbChildFailure {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Process,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $diagnostic = Get-PcwbDiagnosticText -Text $Process.Stderr
    if ([string]::IsNullOrWhiteSpace($diagnostic)) {
        $diagnostic = "No diagnostic text was returned."
    }

    $status = "failed"
    $exitCode = 1
    $code = "pcwb.child.failed"
    if ($Process.ExitCode -eq 6 -or
        $diagnostic -match '(?i)access\s+denied|permission|unauthorized|elevat') {
        $status = "blocked"
        $exitCode = 6
        $code = "pcwb.child.permission-required"
    }
    elseif ($Process.ExitCode -eq 2) {
        $status = "needs-input"
        $exitCode = 2
        $code = "pcwb.child.input-rejected"
    }
    elseif ($Process.ExitCode -eq 3) {
        $status = "blocked"
        $exitCode = 3
        $code = "pcwb.child.unsupported"
    }

    throw (New-PcwbFailureException `
        -Code $code `
        -Message ("{0} failed with exit code {1}: {2}" -f $Label, $Process.ExitCode, $diagnostic) `
        -Status $status `
        -ExitCode $exitCode)
}

function Add-ChildWarnings {
    param(
        [AllowNull()]
        [object]$Warnings,
        [string]$CodePrefix = "pcwb.child-warning"
    )

    $index = 0
    foreach ($warning in @($Warnings)) {
        if ($null -eq $warning -or [string]::IsNullOrWhiteSpace([string]$warning)) {
            continue
        }
        $index++
        Add-PcwbWarning `
            -Envelope $script:Envelope `
            -Code ($CodePrefix + "." + $index) `
            -Message ([string]$warning)
    }
}

function Add-ChildLimits {
    param(
        [AllowNull()]
        [object]$Limits,
        [string]$CodePrefix = "pcwb.child-limit"
    )

    $index = 0
    foreach ($limit in @($Limits)) {
        if ($null -eq $limit -or [string]::IsNullOrWhiteSpace([string]$limit)) {
            continue
        }
        $index++
        Add-PcwbLimit `
            -Envelope $script:Envelope `
            -Code ($CodePrefix + "." + $index) `
            -Message ([string]$limit)
    }
}

function Add-JsonOutputArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Role
    )

    $text = $Content
    if (-not $text.EndsWith("`n")) {
        $text += "`n"
    }
    $artifact = Write-PcwbTextArtifact `
        -RunDirectory $runDirectory `
        -Name $Name `
        -Content $text `
        -Role $Role `
        -MediaType "application/json"
    $script:Envelope.Artifacts.Add($artifact)
    return $artifact
}

function Invoke-PcwbInventory {
    Assert-PcwbNoTarget -CommandName "inventory"
    Assert-PcwbAllowedParameters `
        -Bound $script:InvocationParameters `
        -Allowed @("PrivacyMode", "RequireElevated") `
        -CommandName "inventory"

    $collector = Join-Path $PSScriptRoot "collect-windows.ps1"
    $arguments = @("-Format", "Json")
    if ($PrivacyMode -eq "Redacted") {
        $arguments += "-RedactIdentifiers"
    }
    if ($RequireElevated) {
        $arguments += "-RequireElevated"
    }
    $process = Invoke-SkillChild -ChildScript $collector -ChildArguments $arguments
    if ($process.ExitCode -ne 0) {
        Throw-PcwbChildFailure -Process $process -Label "Inventory collection"
    }

    $artifact = Add-JsonOutputArtifact `
        -Name "inventory.json" `
        -Content $process.Stdout `
        -Role "inventory-snapshot"
    $snapshot = Read-PcwbJsonText -Text $process.Stdout -Label "Inventory collection"

    $collectionStatus = Get-PcwbValue -Object $snapshot -Name "CollectionStatus"
    $statusNeedsPartial = $false
    if ($null -ne $collectionStatus) {
        foreach ($property in $collectionStatus.PSObject.Properties) {
            $value = [string]$property.Value
            if ($value -match '^(partial|unavailable)') {
                $statusNeedsPartial = $true
            }
        }
    }

    $warningTexts = @(Get-PcwbValue -Object $snapshot -Name "CollectionWarnings" -Default @())
    $warningCodes = @(Get-PcwbValue -Object $snapshot -Name "CollectionWarningCodes" -Default @())
    for ($index = 0; $index -lt $warningTexts.Count; $index++) {
        $code = if ($index -lt $warningCodes.Count) {
            [string]$warningCodes[$index]
        }
        else {
            "collector-warning-" + ($index + 1)
        }
        Add-PcwbWarning -Envelope $script:Envelope -Code $code -Message ([string]$warningTexts[$index])
    }
    if ($warningTexts.Count -gt 0) {
        $statusNeedsPartial = $true
    }

    $identityQuality = Get-PcwbValue -Object $snapshot -Name "IdentityQuality"
    if ([string](Get-PcwbValue -Object $identityQuality -Name "Status") -notin @("readable", "confirmed")) {
        Add-PcwbNextAction `
            -Envelope $script:Envelope `
            -Code "confirm-device-identity" `
            -Message "Confirm the exact device or component identity before using model-specific guidance."
    }

    $script:Envelope.Evidence.Add([ordered]@{
        Kind = "hardware-inventory"
        Artifact = $artifact.Name
        SchemaVersion = Get-PcwbValue -Object $snapshot -Name "SchemaVersion"
        CollectorVersion = Get-PcwbValue -Object $snapshot -Name "CollectorVersion"
        CapturedAt = Get-PcwbValue -Object $snapshot -Name "GeneratedAt"
        PrivacyMode = Get-PcwbValue -Object $snapshot -Name "PrivacyMode"
        IdentityQuality = $identityQuality
        CollectionContext = Get-PcwbValue -Object $snapshot -Name "CollectionContext"
        Computer = Get-PcwbValue -Object $snapshot -Name "Computer"
        OperatingSystem = Get-PcwbValue -Object $snapshot -Name "OperatingSystem"
        Firmware = Get-PcwbValue -Object $snapshot -Name "Firmware"
        Motherboard = Get-PcwbValue -Object $snapshot -Name "Motherboard"
        Battery = Get-PcwbValue -Object $snapshot -Name "Battery"
        CPU = Get-PcwbValue -Object $snapshot -Name "CPU"
        GPU = @(Get-PcwbValue -Object $snapshot -Name "GPU" -Default @())
        MemoryModules = @(Get-PcwbValue -Object $snapshot -Name "MemoryModules" -Default @())
        MemorySlotSummary = Get-PcwbValue -Object $snapshot -Name "MemorySlotSummary"
        PhysicalDisks = @(Get-PcwbValue -Object $snapshot -Name "PhysicalDisks" -Default @())
        Volumes = @(Get-PcwbValue -Object $snapshot -Name "Volumes" -Default @())
        Monitors = @(Get-PcwbValue -Object $snapshot -Name "Monitors" -Default @())
        CollectionStatus = $collectionStatus
        WarningCodes = $warningCodes
    })
    Add-ChildLimits `
        -Limits (Get-PcwbValue -Object $snapshot -Name "NotReliablyDetectable" -Default @()) `
        -CodePrefix "inventory.not-reliably-detectable"

    if ($statusNeedsPartial) {
        Set-PcwbOutcome -Status "partial" -Code 0
    }
}

function Add-TelemetryAnalyzerOptions {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]]$Arguments,
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Bound
    )

    if ($Bound.ContainsKey("WarmupSeconds")) {
        $Arguments.Add("-WarmupSeconds")
        $Arguments.Add([string]$WarmupSeconds)
    }
    if ($Bound.ContainsKey("DurationSeconds")) {
        $Arguments.Add("-DurationSeconds")
        $Arguments.Add([string]$DurationSeconds)
    }
    if ($Bound.ContainsKey("WarmupRows")) {
        $Arguments.Add("-WarmupRows")
        $Arguments.Add([string]$WarmupRows)
    }
    if ($Bound.ContainsKey("MaxRows")) {
        $Arguments.Add("-MaxRows")
        $Arguments.Add([string]$MaxRows)
    }
    if ($Bound.ContainsKey("Delimiter")) {
        $Arguments.Add("-Delimiter")
        $Arguments.Add($Delimiter)
    }
    foreach ($column in @($IncludeColumn)) {
        if (-not [string]::IsNullOrWhiteSpace($column)) {
            $Arguments.Add("-IncludeColumn")
            $Arguments.Add($column)
        }
    }
    if ($HideFileName) {
        $Arguments.Add("-HideFileName")
    }
    if ($Bound.ContainsKey("MaxInputMegabytes")) {
        $Arguments.Add("-MaxInputMegabytes")
        $Arguments.Add([string]$MaxInputMegabytes)
    }
    if ($Bound.ContainsKey("MaxChartPoints")) {
        $Arguments.Add("-MaxChartPoints")
        $Arguments.Add([string]$MaxChartPoints)
    }
}

function Invoke-PcwbTelemetry {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.required" `
            -Message "Parameter -Path is required for 'analyze telemetry'." `
            -Status "needs-input" `
            -ExitCode 2)
    }
    Assert-PcwbAllowedParameters `
        -Bound $script:InvocationParameters `
        -Allowed @(
            "Path", "WarmupSeconds", "DurationSeconds", "WarmupRows", "MaxRows",
            "Delimiter", "IncludeColumn", "HideFileName", "MaxInputMegabytes", "MaxChartPoints"
        ) `
        -CommandName "analyze telemetry"
    [void](Add-PcwbInput -Role "telemetry" -InputFile $Path -ParameterName "Path")

    $analyzer = Join-Path $PSScriptRoot "analyze-telemetry.ps1"
    $arguments = New-Object "System.Collections.Generic.List[string]"
    $arguments.Add("-Path")
    $arguments.Add($Path)
    $arguments.Add("-Format")
    $arguments.Add("Json")
    Add-TelemetryAnalyzerOptions -Arguments $arguments -Bound $script:InvocationParameters

    $process = Invoke-SkillChild -ChildScript $analyzer -ChildArguments @($arguments.ToArray())
    if ($process.ExitCode -ne 0) {
        Throw-PcwbChildFailure -Process $process -Label "Telemetry analysis"
    }

    $artifact = Add-JsonOutputArtifact `
        -Name "telemetry-analysis.json" `
        -Content $process.Stdout `
        -Role "telemetry-analysis"
    $analysis = Read-PcwbJsonText -Text $process.Stdout -Label "Telemetry analysis"
    $metrics = @(Get-PcwbValue -Object $analysis -Name "Metrics" -Default @())

    $compactMetrics = New-Object System.Collections.Generic.List[object]
    foreach ($metric in $metrics) {
        $compactMetrics.Add([ordered]@{
            Metric = Get-PcwbValue -Object $metric -Name "Metric"
            SourceColumn = Get-PcwbValue -Object $metric -Name "SourceColumn"
            Unit = Get-PcwbValue -Object $metric -Name "Unit"
            Samples = Get-PcwbValue -Object $metric -Name "Samples"
            Min = Get-PcwbValue -Object $metric -Name "Min"
            Mean = Get-PcwbValue -Object $metric -Name "Mean"
            Median = Get-PcwbValue -Object $metric -Name "Median"
            P95 = Get-PcwbValue -Object $metric -Name "P95"
            Max = Get-PcwbValue -Object $metric -Name "Max"
        }) | Out-Null
    }

    $warnings = @(Get-PcwbValue -Object $analysis -Name "Warnings" -Default @())
    Add-ChildWarnings -Warnings $warnings -CodePrefix "telemetry.warning"

    $samplingConsistency = [string](Get-PcwbValue -Object $analysis -Name "Sampling.Consistency")
    if ($samplingConsistency -eq "variable") {
        $script:Envelope.Uncertainties.Add([ordered]@{
            Code = "telemetry.sampling.variable"
            Message = "Sampling intervals vary materially in the selected window."
        })
    }

    $script:Envelope.Evidence.Add([ordered]@{
        Kind = "telemetry-analysis"
        Artifact = $artifact.Name
        AnalyzerVersion = Get-PcwbValue -Object $analysis -Name "AnalyzerVersion"
        FileName = Get-PcwbValue -Object $analysis -Name "FileName"
        HeaderLine = Get-PcwbValue -Object $analysis -Name "HeaderLine"
        TotalRows = Get-PcwbValue -Object $analysis -Name "TotalRows"
        AnalyzedRows = Get-PcwbValue -Object $analysis -Name "AnalyzedRows"
        InvalidRows = Get-PcwbValue -Object $analysis -Name "InvalidRows"
        RequestedWindow = Get-PcwbValue -Object $analysis -Name "RequestedWindow"
        Window = Get-PcwbValue -Object $analysis -Name "Window"
        SampledSpanSeconds = Get-PcwbValue -Object $analysis -Name "SampledSpanSeconds"
        Sampling = Get-PcwbValue -Object $analysis -Name "Sampling"
        Metrics = @($compactMetrics.ToArray())
        Warnings = $warnings
    })
    Add-ChildLimits `
        -Limits @(
            "Aggregate telemetry does not prove stability.",
            "Compare only the same workload, window, metric, and unit."
        ) `
        -CodePrefix "telemetry.limit"

    if ($metrics.Count -eq 0) {
        Set-PcwbOutcome -Status "needs-input" -Code 4
        $script:Envelope.Errors.Add([ordered]@{
            Code = "telemetry.no-recognized-metrics"
            Message = "No supported telemetry metric was recognized in the selected window."
        })
        Add-PcwbNextAction `
            -Envelope $script:Envelope `
            -Code "record-supported-metrics" `
            -Message "Record a workload with supported sensor columns or select a valid analysis window."
    }
    elseif ($warnings.Count -gt 0) {
        Set-PcwbOutcome -Status "partial" -Code 0
    }
}

function Invoke-PcwbPresentMon {
    if ([string]::IsNullOrWhiteSpace($InputPath)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.required" `
            -Message "Parameter -InputPath is required for 'analyze presentmon'." `
            -Status "needs-input" `
            -ExitCode 2)
    }
    Assert-PcwbAllowedParameters `
        -Bound $script:InvocationParameters `
        -Allowed @("InputPath", "ProcessName", "SpikeMultiplier") `
        -CommandName "analyze presentmon"
    [void](Add-PcwbInput -Role "presentmon" -InputFile $InputPath -ParameterName "InputPath")

    $analyzer = Join-Path $PSScriptRoot "analyze-presentmon.ps1"
    $arguments = @("-InputPath", $InputPath, "-Format", "Json")
    if (-not [string]::IsNullOrWhiteSpace($ProcessName)) {
        $arguments += @("-ProcessName", $ProcessName)
    }
    if ($script:InvocationParameters.ContainsKey("SpikeMultiplier")) {
        $arguments += @("-SpikeMultiplier", [string]$SpikeMultiplier)
    }

    $process = Invoke-SkillChild -ChildScript $analyzer -ChildArguments $arguments
    if ($process.ExitCode -ne 0) {
        Throw-PcwbChildFailure -Process $process -Label "PresentMon analysis"
    }

    $artifact = Add-JsonOutputArtifact `
        -Name "presentmon-analysis.json" `
        -Content $process.Stdout `
        -Role "presentmon-analysis"
    $analysis = Read-PcwbJsonText -Text $process.Stdout -Label "PresentMon analysis"
    $warnings = @(Get-PcwbValue -Object $analysis -Name "warnings" -Default @())
    Add-ChildWarnings -Warnings $warnings -CodePrefix "presentmon.warning"

    $source = Get-PcwbValue -Object $analysis -Name "source"
    $frameAnalysis = Get-PcwbValue -Object $analysis -Name "analysis"
    $validFrames = [long](Get-PcwbValue -Object $source -Name "validFrameCount" -Default 0)
    $script:Envelope.Evidence.Add([ordered]@{
        Kind = "presentmon-frame-time"
        Artifact = $artifact.Name
        SchemaVersion = Get-PcwbValue -Object $analysis -Name "schemaVersion"
        Source = $source
        Scope = Get-PcwbValue -Object $analysis -Name "scope"
        Analysis = $frameAnalysis
        TopSpikes = @(Get-PcwbValue -Object $analysis -Name "topSpikes" -Default @())
        SpikeClusters = @(Get-PcwbValue -Object $analysis -Name "spikeClusters" -Default @())
        Warnings = $warnings
    })
    Add-ChildLimits `
        -Limits (Get-PcwbValue -Object $analysis -Name "boundaries" -Default @()) `
        -CodePrefix "presentmon.limit"

    if ($validFrames -le 0) {
        Set-PcwbOutcome -Status "needs-input" -Code 4
        $script:Envelope.Errors.Add([ordered]@{
            Code = "presentmon.no-valid-frames"
            Message = "No valid PresentMon frames were available for analysis."
        })
    }
    elseif ($warnings.Count -gt 0 -or
        [string](Get-PcwbValue -Object $frameAnalysis -Name "status") -eq "review") {
        Set-PcwbOutcome -Status "partial" -Code 0
    }
}

function Invoke-PcwbEvidencePackage {
    if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.required" `
            -Message "Parameter -BaselinePath is required for 'evidence package'." `
            -Status "needs-input" `
            -ExitCode 2)
    }
    Assert-PcwbAllowedParameters `
        -Bound $script:InvocationParameters `
        -Allowed @(
            "BaselinePath", "CandidatePath", "BaselineLabel", "CandidateLabel",
            "Workload", "Change", "FocusMetric", "WarmupSeconds", "DurationSeconds",
            "WarmupRows", "MaxRows", "Delimiter", "IncludeColumn", "HideFileName",
            "MaxInputMegabytes", "MaxChartPoints", "MaxSeries", "MaxComparisonMetrics"
        ) `
        -CommandName "evidence package"
    [void](Add-PcwbInput -Role "baseline-telemetry" -InputFile $BaselinePath -ParameterName "BaselinePath")
    if (-not [string]::IsNullOrWhiteSpace($CandidatePath)) {
        [void](Add-PcwbInput -Role "candidate-telemetry" -InputFile $CandidatePath -ParameterName "CandidatePath")
    }

    $packageRoot = Join-Path $runDirectory "package"
    [void][IO.Directory]::CreateDirectory($packageRoot)
    $arguments = New-Object "System.Collections.Generic.List[string]"
    $arguments.Add("-BaselinePath")
    $arguments.Add($BaselinePath)
    if (-not [string]::IsNullOrWhiteSpace($CandidatePath)) {
        $arguments.Add("-CandidatePath")
        $arguments.Add($CandidatePath)
    }
    $arguments.Add("-OutputDirectory")
    $arguments.Add($packageRoot)
    if ($script:InvocationParameters.ContainsKey("BaselineLabel")) {
        $arguments.Add("-BaselineLabel")
        $arguments.Add($BaselineLabel)
    }
    if ($script:InvocationParameters.ContainsKey("CandidateLabel")) {
        $arguments.Add("-CandidateLabel")
        $arguments.Add($CandidateLabel)
    }
    if ($script:InvocationParameters.ContainsKey("Workload")) {
        $arguments.Add("-Workload")
        $arguments.Add($Workload)
    }
    if ($script:InvocationParameters.ContainsKey("Change")) {
        $arguments.Add("-Change")
        $arguments.Add($Change)
    }
    foreach ($metric in @($FocusMetric)) {
        if (-not [string]::IsNullOrWhiteSpace($metric)) {
            $arguments.Add("-FocusMetric")
            $arguments.Add($metric)
        }
    }
    Add-TelemetryAnalyzerOptions -Arguments $arguments -Bound $script:InvocationParameters
    if ($script:InvocationParameters.ContainsKey("MaxSeries")) {
        $arguments.Add("-MaxSeries")
        $arguments.Add([string]$MaxSeries)
    }
    if ($script:InvocationParameters.ContainsKey("MaxComparisonMetrics")) {
        $arguments.Add("-MaxComparisonMetrics")
        $arguments.Add([string]$MaxComparisonMetrics)
    }

    $pipeline = Join-Path $PSScriptRoot "run-evidence-pipeline.ps1"
    $process = Invoke-SkillChild -ChildScript $pipeline -ChildArguments @($arguments.ToArray())
    if ($process.ExitCode -ne 0) {
        Throw-PcwbChildFailure -Process $process -Label "Evidence package pipeline"
    }

    $match = [regex]::Match(
        $process.Stdout,
        '(?im)^Evidence package:\s*(.+?)\s*$'
    )
    if (-not $match.Success) {
        throw (New-PcwbFailureException `
            -Code "pcwb.output.package-path-missing" `
            -Message "Evidence package pipeline did not report an output directory." `
            -Status "failed" `
            -ExitCode 5)
    }
    $packageDirectory = $match.Groups[1].Value.Trim()
    $packageJsonPath = Join-Path $packageDirectory "evidence-package.json"
    if (-not (Test-Path -LiteralPath $packageJsonPath -PathType Leaf)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.output.package-json-missing" `
            -Message "Evidence package JSON was not created." `
            -Status "failed" `
            -ExitCode 5)
    }

    $packageJson = [IO.File]::ReadAllText(
        $packageJsonPath,
        (New-Object System.Text.UTF8Encoding($false, $true))
    )
    $package = Read-PcwbJsonText -Text $packageJson -Label "Evidence package"

    $packageArtifact = New-PcwbArtifactRecord `
        -Role "evidence-package-json" `
        -Path $packageJsonPath `
        -MediaType "application/json"
    $script:Envelope.Artifacts.Add($packageArtifact)

    $files = Get-PcwbValue -Object $package -Name "Files"
    if ($null -ne $files) {
        foreach ($property in $files.PSObject.Properties) {
            $name = [string](Get-PcwbValue -Object $property.Value -Name "name")
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            $filePath = Join-Path $packageDirectory $name
            if (Test-Path -LiteralPath $filePath -PathType Leaf) {
                $mediaType = if ($name.EndsWith(".json", [StringComparison]::OrdinalIgnoreCase)) {
                    "application/json"
                }
                elseif ($name.EndsWith(".svg", [StringComparison]::OrdinalIgnoreCase)) {
                    "image/svg+xml"
                }
                elseif ($name.EndsWith(".html", [StringComparison]::OrdinalIgnoreCase)) {
                    "text/html"
                }
                elseif ($name.EndsWith(".md", [StringComparison]::OrdinalIgnoreCase)) {
                    "text/markdown"
                }
                else {
                    "application/octet-stream"
                }
                $script:Envelope.Artifacts.Add((New-PcwbArtifactRecord `
                    -Role ([string]$property.Name) `
                    -Path $filePath `
                    -MediaType $mediaType))
            }
        }
    }

    $warnings = @(Get-PcwbValue -Object $package -Name "Warnings" -Default @())
    Add-ChildWarnings -Warnings $warnings -CodePrefix "evidence.warning"
    $comparisonStatus = [string](Get-PcwbValue -Object $package -Name "Status")
    $script:Envelope.Evidence.Add([ordered]@{
        Kind = "telemetry-evidence-package"
        Artifact = $packageArtifact.Name
        EvidencePackageVersion = Get-PcwbValue -Object $package -Name "EvidencePackageVersion"
        PipelineVersion = Get-PcwbValue -Object $package -Name "PipelineVersion"
        Status = $comparisonStatus
        Workload = Get-PcwbValue -Object $package -Name "Workload"
        Change = Get-PcwbValue -Object $package -Name "Change"
        NextAction = Get-PcwbValue -Object $package -Name "NextAction"
        Baseline = Get-PcwbValue -Object $package -Name "Baseline"
        Candidate = Get-PcwbValue -Object $package -Name "Candidate"
        Comparison = Get-PcwbValue -Object $package -Name "Comparison"
        Warnings = $warnings
    })
    Add-ChildLimits `
        -Limits @(
            "The evidence package is not a stability or safety guarantee.",
            "A comparison is valid only for the declared fixed workload and comparable windows."
        ) `
        -CodePrefix "evidence.limit"

    if (@($warnings).Count -gt 0 -or $comparisonStatus -in @("review", "retest")) {
        Set-PcwbOutcome -Status "partial" -Code 0
    }
    if ($comparisonStatus -eq "retest") {
        Add-PcwbNextAction `
            -Envelope $script:Envelope `
            -Code "repeat-comparable-runs" `
            -Message "Repeat the same fixed workload so baseline and candidate share at least one metric and unit."
    }
}

function Invoke-PcwbClaimVerification {
    if ([string]::IsNullOrWhiteSpace($ClaimPath)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.parameter.required" `
            -Message "Parameter -ClaimPath is required for 'verify claim'." `
            -Status "needs-input" `
            -ExitCode 2)
    }
    Assert-PcwbAllowedParameters `
        -Bound $script:InvocationParameters `
        -Allowed @("ClaimPath", "EvidencePath") `
        -CommandName "verify claim"
    [void](Add-PcwbInput -Role "claim" -InputFile $ClaimPath -ParameterName "ClaimPath")
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        [void](Add-PcwbInput -Role "evidence" -InputFile $EvidencePath -ParameterName "EvidencePath")
    }

    $verifier = Join-Path $PSScriptRoot "verify-hardware-claim.ps1"
    $arguments = @("-ClaimPath", $ClaimPath, "-OutputFormat", "Json")
    if (-not [string]::IsNullOrWhiteSpace($EvidencePath)) {
        $arguments += @("-EvidencePath", $EvidencePath)
    }
    $process = Invoke-SkillChild -ChildScript $verifier -ChildArguments $arguments
    if ($process.ExitCode -notin @(0, 1)) {
        Throw-PcwbChildFailure -Process $process -Label "Claim verification"
    }

    $artifact = Add-JsonOutputArtifact `
        -Name "claim-verification.json" `
        -Content $process.Stdout `
        -Role "claim-verification"
    $report = Read-PcwbJsonText -Text $process.Stdout -Label "Claim verification"
    $conflictCount = [int](Get-PcwbValue -Object $report -Name "conflictCount" -Default 0)
    $matchedCount = [int](Get-PcwbValue -Object $report -Name "matchedCount" -Default 0)
    $userReportedCount = [int](Get-PcwbValue -Object $report -Name "userReportedCount" -Default 0)
    $historicalCount = [int](Get-PcwbValue -Object $report -Name "historicalCount" -Default 0)
    $unverifiedCount = [int](Get-PcwbValue -Object $report -Name "unverifiedCount" -Default 0)
    $claims = @(Get-PcwbValue -Object $report -Name "claims" -Default @())

    foreach ($claim in $claims) {
        $status = [string](Get-PcwbValue -Object $claim -Name "status")
        if ($status -eq "conflict") {
            $script:Envelope.Findings.Add([ordered]@{
                Code = "claim.conflict"
                Message = ("Claim {0} conflicts with current evidence." -f (Get-PcwbValue -Object $claim -Name "id"))
            })
        }
    }
    $script:Envelope.Evidence.Add([ordered]@{
        Kind = "claim-verification"
        Artifact = $artifact.Name
        SchemaVersion = Get-PcwbValue -Object $report -Name "schemaVersion"
        Result = Get-PcwbValue -Object $report -Name "result"
        MatchedCount = $matchedCount
        ConflictCount = $conflictCount
        UserReportedCount = $userReportedCount
        HistoricalCount = $historicalCount
        UnverifiedCount = $unverifiedCount
        Claims = $claims
    })
    Add-PcwbLimit `
        -Envelope $script:Envelope `
        -Code "claim.match-not-stability-proof" `
        -Message "A matching claim does not prove stability, safety, or an active configuration."

    if ($conflictCount -gt 0) {
        Set-PcwbOutcome -Status "partial" -Code 4
        Add-PcwbNextAction `
            -Envelope $script:Envelope `
            -Code "resolve-claim-conflict" `
            -Message "Keep both values visible and request a new current measurement before resolving the conflict."
    }
    elseif ($historicalCount -gt 0 -or
        $unverifiedCount -gt 0 -or
        $userReportedCount -gt 0) {
        Set-PcwbOutcome -Status "partial" -Code 0
    }
}

function Invoke-PcwbDoctor {
    Assert-PcwbNoTarget -CommandName "doctor"
    Assert-PcwbAllowedParameters `
        -Bound $script:InvocationParameters `
        -Allowed @("SkillRoot") `
        -CommandName "doctor"

    $doctor = Join-Path $PSScriptRoot "doctor.ps1"
    $arguments = @("-Format", "Json")
    if (-not [string]::IsNullOrWhiteSpace($SkillRoot)) {
        $arguments += @("-SkillRoot", $SkillRoot)
    }
    $process = Invoke-SkillChild -ChildScript $doctor -ChildArguments $arguments
    if ($process.ExitCode -notin @(0, 1)) {
        Throw-PcwbChildFailure -Process $process -Label "Doctor"
    }

    $artifact = Add-JsonOutputArtifact `
        -Name "doctor.json" `
        -Content $process.Stdout `
        -Role "doctor-report"
    $report = Read-PcwbJsonText -Text $process.Stdout -Label "Doctor"
    $checks = @(Get-PcwbValue -Object $report -Name "Checks" -Default @())
    $broken = @($checks | Where-Object {
        [string](Get-PcwbValue -Object $_ -Name "Status") -eq "BROKEN"
    })
    $permissionRequired = @($checks | Where-Object {
        [string](Get-PcwbValue -Object $_ -Name "Status") -eq "PERMISSION_REQUIRED"
    })

    $script:Envelope.Evidence.Add([ordered]@{
        Kind = "doctor"
        Artifact = $artifact.Name
        DoctorVersion = Get-PcwbValue -Object $report -Name "DoctorVersion"
        CheckedAt = Get-PcwbValue -Object $report -Name "CheckedAt"
        SkillRoot = Get-PcwbValue -Object $report -Name "SkillRoot"
        SkillVersion = Get-PcwbValue -Object $report -Name "SkillVersion"
        Overall = Get-PcwbValue -Object $report -Name "Overall"
        Checks = $checks
    })
    foreach ($check in $permissionRequired) {
        Add-PcwbWarning `
            -Envelope $script:Envelope `
            -Code "doctor.permission-required" `
            -Message ("{0}: {1}" -f (Get-PcwbValue -Object $check -Name "Name"), (Get-PcwbValue -Object $check -Name "Detail"))
    }
    if ($broken.Count -gt 0 -or [string](Get-PcwbValue -Object $report -Name "Overall") -eq "BROKEN") {
        Set-PcwbOutcome -Status "blocked" -Code 3
        foreach ($check in $broken) {
            $script:Envelope.Errors.Add([ordered]@{
                Code = "doctor.broken"
                Message = ("{0}: {1}" -f (Get-PcwbValue -Object $check -Name "Name"), (Get-PcwbValue -Object $check -Name "Detail"))
            })
        }
        Add-PcwbNextAction `
            -Envelope $script:Envelope `
            -Code "repair-doctor-findings" `
            -Message "Repair the broken Skill files or runtime prerequisites before relying on local evidence commands."
    }
    elseif ($permissionRequired.Count -gt 0) {
        Set-PcwbOutcome -Status "partial" -Code 0
    }
}

try {
    $script:Envelope = New-PcwbEnvelope -Command "unknown"
    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.command.required" `
            -Message "Choose one command: inventory, analyze, evidence, verify, or doctor." `
            -Status "needs-input" `
            -ExitCode 2)
    }

    $normalizedCommand = $Command.Trim().ToLowerInvariant()
    $normalizedTarget = if ([string]::IsNullOrWhiteSpace($Target)) {
        ""
    }
    else {
        $Target.Trim().ToLowerInvariant()
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw (New-PcwbFailureException `
            -Code "pcwb.environment.unsupported-os" `
            -Message "pcwb local evidence commands require Windows." `
            -Status "blocked" `
            -ExitCode 3)
    }

    switch ($normalizedCommand) {
        "inventory" {
            $commandLabel = "inventory"
        }
        "analyze" {
            if ($normalizedTarget -notin @("telemetry", "presentmon")) {
                throw (New-PcwbFailureException `
                    -Code "pcwb.command.invalid-target" `
                    -Message "analyze requires target 'telemetry' or 'presentmon'." `
                    -Status "needs-input" `
                    -ExitCode 2)
            }
            $commandLabel = "analyze " + $normalizedTarget
        }
        "evidence" {
            if ($normalizedTarget -ne "package") {
                throw (New-PcwbFailureException `
                    -Code "pcwb.command.invalid-target" `
                    -Message "evidence requires target 'package'." `
                    -Status "needs-input" `
                    -ExitCode 2)
            }
            $commandLabel = "evidence package"
        }
        "verify" {
            if ($normalizedTarget -ne "claim") {
                throw (New-PcwbFailureException `
                    -Code "pcwb.command.invalid-target" `
                    -Message "verify requires target 'claim'." `
                    -Status "needs-input" `
                    -ExitCode 2)
            }
            $commandLabel = "verify claim"
        }
        "doctor" {
            if (-not [string]::IsNullOrWhiteSpace($normalizedTarget)) {
                throw (New-PcwbFailureException `
                    -Code "pcwb.parameter.unexpected-target" `
                    -Message "doctor does not accept a target." `
                    -Status "needs-input" `
                    -ExitCode 2)
            }
            $commandLabel = "doctor"
        }
        default {
            throw (New-PcwbFailureException `
                -Code "pcwb.command.unknown" `
                -Message "Unknown command '$Command'." `
                -Status "needs-input" `
                -ExitCode 2)
        }
    }
    $script:Envelope.Command = $commandLabel

    $runDirectory = New-PcwbRunDirectory -OutputDirectory $OutputDirectory
    switch ($commandLabel) {
        "inventory" {
            Invoke-PcwbInventory
        }
        "analyze telemetry" {
            Invoke-PcwbTelemetry
        }
        "analyze presentmon" {
            Invoke-PcwbPresentMon
        }
        "evidence package" {
            Invoke-PcwbEvidencePackage
        }
        "verify claim" {
            Invoke-PcwbClaimVerification
        }
        "doctor" {
            Invoke-PcwbDoctor
        }
    }
}
catch {
    $exception = $_.Exception
    $code = [string]$exception.Data["PcwbCode"]
    $status = [string]$exception.Data["PcwbStatus"]
    $childExitCode = $exception.Data["PcwbExitCode"]
    if ([string]::IsNullOrWhiteSpace($code)) {
        if (Test-PcwbPermissionFailure -ErrorRecord $_) {
            $code = "pcwb.permission-required"
        }
        else {
            $code = "pcwb.unhandled"
        }
    }
    if ($status -notin @("needs-input", "blocked", "failed")) {
        $status = if (Test-PcwbPermissionFailure -ErrorRecord $_) {
            "blocked"
        }
        else {
            "failed"
        }
    }
    if ($null -eq $childExitCode) {
        $childExitCode = if ($status -eq "blocked") { 6 } else { 1 }
    }
    $script:ResultStatus = $status
    $script:ResultExitCode = [int]$childExitCode
    $failureMessage = Get-PcwbDiagnosticText -Text $exception.Message
    if ($null -ne $script:Envelope) {
        $script:Envelope.Errors.Add([ordered]@{
            Code = $code
            Message = $failureMessage
        })
    }
}
finally {
    if ($null -eq $script:Envelope) {
        $script:Envelope = New-PcwbEnvelope -Command $commandLabel
    }
    $script:Envelope.Command = $commandLabel
    $script:Envelope.Status = $script:ResultStatus
    $script:Envelope.ExitCode = $script:ResultExitCode
    $script:Envelope.DurationMilliseconds = [Math]::Max(
        0,
        [int]([datetimeoffset]::UtcNow - $startedAt).TotalMilliseconds
    )
    $json = ConvertTo-PcwbResultJson -Envelope $script:Envelope
    [Console]::Out.WriteLine($json)
    if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
        [Console]::Error.WriteLine($failureMessage)
    }
    exit $script:ResultExitCode
}
