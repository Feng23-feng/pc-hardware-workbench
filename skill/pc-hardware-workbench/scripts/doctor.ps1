[CmdletBinding()]
param(
    [string]$SkillRoot,

    [ValidateSet("Text", "Json")]
    [string]$Format = "Text",

    [string]$OutputDirectory,

    [switch]$ProbeLhm,

    [switch]$AllowLiveCollector,

    [string]$ValidatorPath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    $SkillRoot = Split-Path -Parent $PSScriptRoot
}
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$pathSafetyHelper = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    [Console]::Error.WriteLine("Local path safety helper is missing: $pathSafetyHelper")
    exit 2
}
. $pathSafetyHelper

function Get-CleanText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) {
        return ""
    }
    return (([string]$Value) -replace "[\p{Cc}\p{Cf}]", " ").Trim()
}

function Test-AccessDeniedMessage {
    param([AllowNull()][object]$Message)
    $text = Get-CleanText $Message
    return ($text -match '(?i)access\s+denied|permission|unauthorized|\u62D2\u7EDD\u8BBF\u95EE|\u6743\u9650')
}

function Add-DoctorCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet("AVAILABLE", "OPTIONAL_MISSING", "PERMISSION_REQUIRED", "BROKEN", "UNKNOWN", "SKIP")]
        [string]$Status,
        [AllowNull()][object]$Detail
    )
    $script:checks.Add([pscustomobject]@{
        Name = Get-CleanText $Name
        Status = $Status
        Detail = Get-CleanText $Detail
    }) | Out-Null
}

function Get-LhmWebSensorCount {
    $endpoint = [Uri]"http://127.0.0.1:8085/data.json"
    if (
        $endpoint.Scheme -ne "http" -or
        -not $endpoint.IsLoopback -or
        $endpoint.AbsolutePath -ne "/data.json"
    ) {
        throw "The LHM Web endpoint is not loopback-only."
    }
    $document = Invoke-RestMethod `
        -Uri $endpoint.AbsoluteUri `
        -Method Get `
        -TimeoutSec 5 `
        -ErrorAction Stop
    $count = 0
    $pending = New-Object System.Collections.Stack
    $pending.Push($document)
    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        if ($null -eq $node) {
            continue
        }
        if (
            $null -ne $node.PSObject.Properties["SensorId"] -and
            $null -ne $node.PSObject.Properties["Type"] -and
            -not [string]::IsNullOrWhiteSpace((Get-CleanText $node.PSObject.Properties["SensorId"].Value))
        ) {
            $count++
        }
        $children = $node.PSObject.Properties["Children"]
        if ($null -ne $children) {
            foreach ($child in @($children.Value)) {
                $pending.Push($child)
            }
        }
    }
    if ($count -eq 0) {
        throw "The LHM Web endpoint returned no supported sensors."
    }
    return $count
}

$checks = New-Object System.Collections.Generic.List[object]
$resolvedRoot = $null
try {
    $resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot -ErrorAction Stop).Path
}
catch {
    Add-DoctorCheck -Name "Skill root" -Status "BROKEN" -Detail $_.Exception.Message
}

if ($null -ne $resolvedRoot) {
    Add-DoctorCheck -Name "Skill root" -Status "AVAILABLE" -Detail $resolvedRoot

    $skillFile = Join-Path $resolvedRoot "SKILL.md"
    if (-not (Test-Path -LiteralPath $skillFile -PathType Leaf)) {
        Add-DoctorCheck -Name "SKILL.md" -Status "BROKEN" -Detail $skillFile
        $skillVersion = "unknown"
    }
    else {
        $skillText = Get-Content -Raw -LiteralPath $skillFile -Encoding UTF8
        $versionMatch = [regex]::Match($skillText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
        $skillVersion = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { "unknown" }
        Add-DoctorCheck `
            -Name "SKILL.md" `
            -Status $(if ($versionMatch.Success) { "AVAILABLE" } else { "BROKEN" }) `
            -Detail "version=$skillVersion"
    }

    $requiredFiles = @(
        "agents/openai.yaml",
        "scripts/doctor.ps1",
        "scripts/analyze-telemetry.ps1",
        "scripts/normalize-telemetry.ps1",
        "scripts/render-telemetry-chart.ps1",
        "scripts/hardware-case.ps1",
        "scripts/export-hardware-case-html.ps1",
        "scripts/rag/rag-evidence.ps1",
        "scripts/rag/source-registry.json",
        "scripts/lhm/lhm-functions.ps1",
        "scripts/lhm/read-lhm-telemetry.ps1",
        "references/integration/telemetry-analysis.md",
        "references/integration/telemetry-normalization.md",
        "references/integration/dynamic-rag.md",
        "references/integration/lhm-adapter.md",
        "references/integration/visual-evidence.md"
    )
    $missingFiles = New-Object System.Collections.Generic.List[string]
    foreach ($relativePath in $requiredFiles) {
        $candidate = Join-Path $resolvedRoot $relativePath
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $missingFiles.Add($relativePath) | Out-Null
        }
    }
    Add-DoctorCheck `
        -Name "Core files" `
        -Status $(if ($missingFiles.Count -eq 0) { "AVAILABLE" } else { "BROKEN" }) `
        -Detail $(if ($missingFiles.Count -eq 0) { "$($requiredFiles.Count) required files present" } else { "missing=" + ($missingFiles -join ", ") })

    $parseErrors = New-Object System.Collections.Generic.List[string]
    $encodingErrors = New-Object System.Collections.Generic.List[string]
    $scriptFiles = @(Get-ChildItem -LiteralPath $resolvedRoot -Recurse -File -Filter "*.ps1")
    foreach ($scriptFileItem in $scriptFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptFileItem.FullName,
            [ref]$tokens,
            [ref]$errors
        ) | Out-Null
        if ($errors.Count -gt 0) {
            $parseErrors.Add("$($scriptFileItem.FullName): $($errors[0].Message)") | Out-Null
        }
        $bytes = [IO.File]::ReadAllBytes($scriptFileItem.FullName)
        $hasNonAscii = $false
        foreach ($byte in $bytes) {
            if ($byte -gt 0x7F) {
                $hasNonAscii = $true
                break
            }
        }
        if ($hasNonAscii -and (
            $bytes.Length -lt 3 -or
            $bytes[0] -ne 0xEF -or
            $bytes[1] -ne 0xBB -or
            $bytes[2] -ne 0xBF
        )) {
            $encodingErrors.Add($scriptFileItem.FullName) | Out-Null
        }
    }
    Add-DoctorCheck `
        -Name "PowerShell syntax" `
        -Status $(if ($parseErrors.Count -eq 0) { "AVAILABLE" } else { "BROKEN" }) `
        -Detail $(if ($parseErrors.Count -eq 0) { "$($scriptFiles.Count) scripts parsed" } else { $parseErrors -join "; " })
    Add-DoctorCheck `
        -Name "PowerShell encoding" `
        -Status $(if ($encodingErrors.Count -eq 0) { "AVAILABLE" } else { "BROKEN" }) `
        -Detail $(if ($encodingErrors.Count -eq 0) { "non-ASCII scripts use UTF-8 BOM" } else { "missing BOM: " + ($encodingErrors -join ", ") })
}
else {
    $skillVersion = "unknown"
}

Add-DoctorCheck `
    -Name "PowerShell" `
    -Status "AVAILABLE" `
    -Detail "$($PSVersionTable.PSVersion) / $($PSVersionTable.PSEdition)"
$pwshCommand = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
Add-DoctorCheck `
    -Name "PowerShell 7" `
    -Status $(if ($null -eq $pwshCommand) { "OPTIONAL_MISSING" } else { "AVAILABLE" }) `
    -Detail $(if ($null -eq $pwshCommand) { "pwsh.exe not found" } else { $pwshCommand.Source })

try {
    $null = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    Add-DoctorCheck -Name "Windows CIM" -Status "AVAILABLE" -Detail "Win32_ComputerSystem query succeeded"
}
catch {
    Add-DoctorCheck `
        -Name "Windows CIM" `
        -Status $(if (Test-AccessDeniedMessage $_.Exception.Message) { "PERMISSION_REQUIRED" } else { "BROKEN" }) `
        -Detail $_.Exception.Message
}

$nvidiaSmi = Get-Command "nvidia-smi.exe" -ErrorAction SilentlyContinue
Add-DoctorCheck `
    -Name "nvidia-smi" `
    -Status $(if ($null -eq $nvidiaSmi) { "OPTIONAL_MISSING" } else { "AVAILABLE" }) `
    -Detail $(if ($null -eq $nvidiaSmi) { "command not found" } else { $nvidiaSmi.Source })

if ($ProbeLhm -and -not $AllowLiveCollector) {
    Add-DoctorCheck -Name "LibreHardwareMonitor" -Status "PERMISSION_REQUIRED" -Detail "ProbeLhm requires explicit -AllowLiveCollector"
}
elseif (-not $ProbeLhm) {
    Add-DoctorCheck -Name "LibreHardwareMonitor" -Status "SKIP" -Detail "Use -ProbeLhm -AllowLiveCollector to inspect the local Web/WMI adapter"
}
else {
    $lhmProcess = Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match '(?i)librehardwaremonitor' } |
        Select-Object -First 1
    if ($null -eq $lhmProcess) {
        Add-DoctorCheck -Name "LibreHardwareMonitor" -Status "OPTIONAL_MISSING" -Detail "Process not detected"
    }
    else {
        $webSensorCount = $null
        $webFailure = $null
        try {
            $webSensorCount = Get-LhmWebSensorCount
            Add-DoctorCheck `
                -Name "LibreHardwareMonitor" `
                -Status "AVAILABLE" `
                -Detail "process=$($lhmProcess.ProcessName); transport=web; sensors=$webSensorCount"
        }
        catch {
            $webFailure = $_.Exception.Message
        }

        if ($null -eq $webSensorCount) {
            try {
                $sensors = @(
                    Get-CimInstance `
                        -Namespace "root/LibreHardwareMonitor" `
                        -ClassName "Sensor" `
                        -ErrorAction Stop
                )
                Add-DoctorCheck `
                    -Name "LibreHardwareMonitor" `
                    -Status "AVAILABLE" `
                    -Detail "process=$($lhmProcess.ProcessName); transport=wmi; sensors=$($sensors.Count)"
            }
            catch {
                $wmiFailure = $_.Exception.Message
                $detail = "web unavailable: $webFailure; wmi unavailable: $wmiFailure"
                Add-DoctorCheck `
                    -Name "LibreHardwareMonitor" `
                    -Status $(if (Test-AccessDeniedMessage $detail) { "PERMISSION_REQUIRED" } else { "BROKEN" }) `
                    -Detail $detail
            }
        }
    }
}

if ($null -ne $resolvedRoot) {
    $probeDirectory = if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        [IO.Path]::GetTempPath()
    }
    else {
        $OutputDirectory
    }
    $probeFile = $null
    try {
        $resolvedProbeDirectory = ConvertTo-LocalFilesystemPath -Path $probeDirectory
        if (-not (Test-Path -LiteralPath $resolvedProbeDirectory -PathType Container)) {
            throw "Output directory does not exist: $resolvedProbeDirectory"
        }
        $probeFile = Join-Path $resolvedProbeDirectory "pcwb-doctor-$([guid]::NewGuid().ToString('N')).tmp"
        [IO.File]::WriteAllText($probeFile, "ok", [Text.Encoding]::ASCII)
        Add-DoctorCheck -Name "Output directory" -Status "AVAILABLE" -Detail $resolvedProbeDirectory
    }
    catch {
        Add-DoctorCheck `
            -Name "Output directory" `
            -Status $(if (Test-AccessDeniedMessage $_.Exception.Message) { "PERMISSION_REQUIRED" } else { "BROKEN" }) `
            -Detail $_.Exception.Message
    }
    finally {
        if ($null -ne $probeFile -and (Test-Path -LiteralPath $probeFile)) {
            Remove-Item -LiteralPath $probeFile -Force
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ValidatorPath)) {
    Add-DoctorCheck -Name "Skill validator" -Status "SKIP" -Detail "No -ValidatorPath supplied"
}
elseif (Test-Path -LiteralPath $ValidatorPath -PathType Leaf) {
    Add-DoctorCheck -Name "Skill validator" -Status "AVAILABLE" -Detail $ValidatorPath
}
else {
    Add-DoctorCheck -Name "Skill validator" -Status "OPTIONAL_MISSING" -Detail $ValidatorPath
}

Add-DoctorCheck -Name "Model vision" -Status "UNKNOWN" -Detail "Runtime-owned capability; the doctor cannot prove image input support"
Add-DoctorCheck -Name "OCR runtime" -Status "UNKNOWN" -Detail "Optional; Skill scripts do not bundle OCR"

$broken = @($checks | Where-Object { $_.Status -eq "BROKEN" })
$overall = if ($null -eq $resolvedRoot -or $broken.Count -gt 0) { "BROKEN" } else { "AVAILABLE" }
$result = [pscustomobject]@{
    DoctorVersion = "1.0.0"
    CheckedAt = [datetimeoffset]::Now.ToString("o", $invariant)
    SkillRoot = $resolvedRoot
    SkillVersion = $skillVersion
    Overall = $overall
    Checks = @($checks.ToArray())
}

if ($Format -eq "Json") {
    $result | ConvertTo-Json -Depth 10
}
else {
    Write-Output "PC Hardware Workbench doctor"
    Write-Output "Skill: $skillVersion"
    Write-Output "Root: $resolvedRoot"
    Write-Output "Overall: $overall"
    Write-Output ""
    foreach ($check in $checks) {
        Write-Output ("{0,-20} {1,-20} {2}" -f $check.Name, $check.Status, $check.Detail)
    }
}

if ($overall -eq "BROKEN") {
    exit 1
}
