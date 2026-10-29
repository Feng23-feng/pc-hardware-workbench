[CmdletBinding()]
param(
    [ValidateSet("Markdown", "Json")]
    [string]$Format = "Markdown",

    [string]$OutputPath,

    [switch]$RedactIdentifiers,

    # The caller must start PowerShell elevated. This switch never triggers UAC
    # or attempts to elevate the current process.
    [switch]$RequireElevated
)

$ErrorActionPreference = "Stop"
function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function Add-CollectionWarning {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Text
    )
    if ($Code -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "Invalid internal collection warning code: $Code"
    }
    $script:CollectionWarnings.Add($Text)
    $script:CollectionWarningCodes.Add($Code)
}

$script:CollectionWarnings = New-Object System.Collections.Generic.List[string]
$script:CollectionWarningCodes = New-Object System.Collections.Generic.List[string]
$script:BatteryCollectionState = "unavailable"
$script:BatteryCollectionReason = "not-collected"
$isElevated = $false
try {
    $windowsIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $windowsPrincipal = New-Object Security.Principal.WindowsPrincipal($windowsIdentity)
    $isElevated = $windowsPrincipal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch {
    $isElevated = $false
}
if ($RequireElevated -and -not $isElevated) {
    Stop-WithInputError "This collection requires a PowerShell process started by the user with elevated administrator rights. The collector does not self-elevate or request UAC."
}
$restrictedAgentEnvironmentHint = (
    -not $isElevated -and (
        $env:CODEX_SHELL -eq "1" -or
        -not [string]::IsNullOrWhiteSpace($env:CODEX_PERMISSION_PROFILE) -or
        $env:DSH_SHELL -eq "1" -or
        -not [string]::IsNullOrWhiteSpace($env:DSH_SESSION_ID) -or
        $windowsIdentity.Name -match '(?i)\\CodexSandbox'
    )
)
$isRestrictedAgentProcess = $false
$identityHelperPath = Join-Path $PSScriptRoot "device-identity.ps1"
if (-not (Test-Path -LiteralPath $identityHelperPath -PathType Leaf)) {
    throw "Device identity helper is missing: $identityHelperPath"
}
. $identityHelperPath
$pathSafetyHelperPath = Join-Path $PSScriptRoot "local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelperPath -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelperPath"
}
. $pathSafetyHelperPath
$inventoryContextHelperPath = Join-Path $PSScriptRoot "inventory-context.ps1"
if (-not (Test-Path -LiteralPath $inventoryContextHelperPath -PathType Leaf)) {
    throw "Inventory context helper is missing: $inventoryContextHelperPath"
}
. $inventoryContextHelperPath

$nativeProbeSources = @(
    Join-Path $PSScriptRoot "system-native.cs"
    Join-Path $PSScriptRoot "storage-native.cs"
    Join-Path $PSScriptRoot "display-native.cs"
)

if (-not ("CodexActiveDisplayReader" -as [type])) {
    try {
        $missingSources = @(
            $nativeProbeSources |
                Where-Object {
                    -not (Test-Path -LiteralPath $_ -PathType Leaf)
                }
        )
        if ($missingSources.Count -gt 0) {
            throw "Native probe sources are missing: $($missingSources -join ', ')"
        }
        Add-Type -Path $nativeProbeSources -ErrorAction Stop
    }
    catch {
        Add-CollectionWarning `
            -Code "native-probe-load-failed" `
            -Text "Native Windows probe source failed to load: $($_.Exception.Message)"
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    try {
        $OutputPath = Resolve-LocalOutputFilePath -Path $OutputPath
    }
    catch {
        Stop-WithInputError $_.Exception.Message
    }
}

function Get-CimData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ClassName,

        [string]$Namespace = "root/cimv2",

        [string]$Filter
    )

    try {
        if ([string]::IsNullOrWhiteSpace($Filter)) {
            @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -ErrorAction Stop)
        }
        else {
            @(Get-CimInstance -Namespace $Namespace -ClassName $ClassName -Filter $Filter -ErrorAction Stop)
        }
    }
    catch {
        Add-CollectionWarning `
            -Code "cim-class-unavailable" `
            -Text "$ClassName unavailable through CIM: $($_.Exception.Message)"
        @()
    }
}

function Get-RegistryData {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string[]]$Names
    )

    try {
        Get-ItemProperty -LiteralPath $Path -Name $Names -ErrorAction Stop
    }
    catch {
        Add-CollectionWarning `
            -Code "registry-fallback-unavailable" `
            -Text "Registry fallback unavailable at ${Path}: $($_.Exception.Message)"
        $null
    }
}

function Format-Capacity {
    param([Nullable[double]]$Bytes)

    if ($null -eq $Bytes -or $Bytes -le 0) {
        return $null
    }

    $units = @("B", "KB", "MB", "GB", "TB")
    $value = [double]$Bytes
    $index = 0

    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) {
        $value /= 1024
        $index++
    }

    return "{0:N2} {1}" -f $value, $units[$index]
}

function Resolve-WindowsOperatingSystemCaption {
    param(
        [string]$Caption,
        [string]$ProductName,
        [string]$EditionId,
        [string]$BuildNumber
    )

    $name = if (-not [string]::IsNullOrWhiteSpace($Caption)) {
        $Caption.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ProductName)) {
        $ProductName.Trim()
    }
    else {
        $null
    }

    $build = 0
    $hasBuild = [int]::TryParse($BuildNumber, [ref]$build)
    $family = if ($hasBuild -and $build -ge 22000) { "Windows 11" } else { "Windows 10" }

    if ([string]::IsNullOrWhiteSpace($name)) {
        $edition = switch -Regex ($EditionId) {
            "^Professional" { "Pro" }
            "^Enterprise" { "Enterprise" }
            "^Education" { "Education" }
            "^Server" { "Server" }
            "^CoreCountrySpecific$" { "Home China" }
            "^CoreSingleLanguage$" { "Home Single Language" }
            "^Core$" { "Home" }
            default { $null }
        }
        return if ($edition) { "$family $edition" } else { $family }
    }

    if ($hasBuild -and $build -ge 22000) {
        $name = $name -replace "(?i)\bWindows 10\b", "Windows 11"
    }

    $name
}

function Get-ProcessorTopologyFallback {
    try {

        $physicalCores = [CodexProcessorTopologyReader]::GetPhysicalCoreCount()
        if ($physicalCores -le 0) {
            throw "No physical processors were returned."
        }

        [pscustomobject]@{
            PhysicalCoreCount = $physicalCores
            LogicalProcessorCount = [Environment]::ProcessorCount
            Source = "Windows processor topology"
        }
    }
    catch {
        Add-CollectionWarning `
            -Code "processor-topology-fallback-failed" `
            -Text "Processor topology fallback failed: $($_.Exception.Message)"
        $null
    }
}

function Get-MemoryStatusFallback {
    try {

        $status = New-Object CodexMemoryStatus+MEMORYSTATUSEX
        $status.dwLength = [Runtime.InteropServices.Marshal]::SizeOf($status)
        if (-not [CodexMemoryStatus]::GlobalMemoryStatusEx($status)) {
            throw "GlobalMemoryStatusEx returned false"
        }

        [pscustomobject]@{
            TotalBytes = [double]$status.ullTotalPhys
            AvailableBytes = [double]$status.ullAvailPhys
            MemoryLoadPercent = $status.dwMemoryLoad
            Source = "GlobalMemoryStatusEx fallback"
        }
    }
    catch {
        Add-CollectionWarning `
            -Code "memory-status-fallback-failed" `
            -Text "OS memory-status fallback failed: $($_.Exception.Message)"
        $null
    }
}

function Get-SmbiosMemoryFallback {
    try {

        $modules = @(
            [CodexSmbiosMemoryReader]::Read() | ForEach-Object {
                [pscustomobject]@{
                    CapacityBytes = [double]$_.SizeBytes
                    Capacity = Format-Capacity ([double]$_.SizeBytes)
                    SpeedMTs = if ($_.SpeedMTs -gt 0) { $_.SpeedMTs } else { $null }
                    ConfiguredSpeedMTs = if ($_.ConfiguredSpeedMTs -gt 0) { $_.ConfiguredSpeedMTs } else { $null }
                    Manufacturer = $_.Manufacturer
                    PartNumber = $_.PartNumber
                    FormFactor = $null
                    Slot = $_.Slot
                    Bank = $_.Bank
                    Source = "SMBIOS fallback"
                }
            }
        )

        if ($modules.Count -eq 0) {
            Add-CollectionWarning `
                -Code "smbios-memory-empty" `
                -Text "SMBIOS memory fallback found no populated memory devices."
        }

        $modules
    }
    catch {
        Add-CollectionWarning `
            -Code "smbios-memory-failed" `
            -Text "SMBIOS memory fallback failed: $($_.Exception.Message)"
        @()
    }
}

function Get-ActiveDiskFallback {
    try {

        $disks = @(
            [CodexActiveDiskReader]::Read() | ForEach-Object {
                [pscustomobject]@{
                    Model = $_.Model
                    Interface = if ($_.Model -match "(?i)^NVMe(?:\s|_)") { "NVMe" } else { $null }
                    MediaType = $null
                    SizeBytes = $null
                    Size = $null
                    Status = "Present"
                    HealthStatus = "Unavailable in current environment"
                    Source = "SetupAPI active-device fallback"
                }
            }
        )

        if ($disks.Count -eq 0) {
            Add-CollectionWarning `
                -Code "setupapi-disk-empty" `
                -Text "SetupAPI active-disk fallback found no present disk devices."
        }

        $disks
    }
    catch {
        Add-CollectionWarning `
            -Code "setupapi-disk-failed" `
            -Text "SetupAPI active-disk fallback failed: $($_.Exception.Message)"
        @()
    }
}

function Get-PhysicalDiskDescriptorFallback {
    try {

        @(
            [CodexPhysicalDiskDescriptorReader]::Read() |
                ForEach-Object {
                    [pscustomobject]@{
                        DeviceNumber = [int]$_.DeviceNumber
                        VendorId = $_.VendorId
                        ProductId = $_.ProductId
                        ProductRevision = $_.ProductRevision
                        BusType = [int]$_.BusType
                    }
                }
        )
    }
    catch {
        Add-CollectionWarning `
            -Code "disk-descriptor-failed" `
            -Text "Physical-disk descriptor fallback failed: $($_.Exception.Message)"
        @()
    }
}

function Get-VolumeDiskMapping {
    try {

        @(
            [CodexVolumeDiskMapper]::Read() |
                ForEach-Object {
                    [pscustomobject]@{
                        DriveLetter = $_.DriveLetter
                        DeviceNumber = if ($_.Success) { [int]$_.DeviceNumber } else { $null }
                        PartitionNumber = if ($_.Success) { [int]$_.PartitionNumber } else { $null }
                        Success = $_.Success
                        Error = $_.Error
                    }
                }
        )
    }
    catch {
        Add-CollectionWarning `
            -Code "volume-disk-mapping-failed" `
            -Text "Volume-to-disk mapping fallback failed: $($_.Exception.Message)"
        @()
    }
}

function Get-BatteryStatusFallback {
    try {

        $script:BatteryCollectionReason = "querying SystemPowerStatus"
        $status = New-Object CodexSystemPowerStatus
        if (-not [CodexSystemPowerStatusReader]::GetSystemPowerStatus([ref]$status)) {
            throw "GetSystemPowerStatus returned false"
        }

        $hasNoSystemBattery = ($status.BatteryFlag -band 128) -ne 0
        if ($hasNoSystemBattery) {
            $script:BatteryCollectionState = "not-present"
            $script:BatteryCollectionReason = "SystemPowerStatus reports no system battery"
            return $null
        }

        $reportPath = Join-Path ([IO.Path]::GetTempPath()) (
            "codex-battery-" + [guid]::NewGuid().ToString("N") + ".xml")

        try {
            $script:BatteryCollectionReason = "querying powercfg battery report"
            $previousErrorActionPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = "Continue"
                $powerCfgOutput = & powercfg.exe /batteryreport /output $reportPath /xml 2>&1 |
                    Out-String
                $powerCfgExitCode = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $previousErrorActionPreference
            }

            if ($powerCfgExitCode -ne 0 -or
                -not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
                if (Test-CollectionWarningIsAccessDenied -Warning $powerCfgOutput) {
                    $script:BatteryCollectionState = "unavailable-permission"
                    $script:BatteryCollectionReason = "powercfg battery report permission denied (exit $powerCfgExitCode)"
                }
                else {
                    $script:BatteryCollectionState = "unavailable"
                    $script:BatteryCollectionReason = "powercfg battery report unavailable (exit $powerCfgExitCode)"
                }
                Add-CollectionWarning `
                    -Code "battery-capacity-unavailable" `
                    -Text "Battery capacity report is unavailable in the current environment."
                return $null
            }

            [xml]$report = Get-Content -Raw -LiteralPath $reportPath
            $batteryNode = $report.SelectSingleNode(
                "//*[local-name()='Battery']")

            if ($null -eq $batteryNode) {
                $script:BatteryCollectionState = "unavailable"
                $script:BatteryCollectionReason = "powercfg report contains no battery node"
                return $null
            }

            $designCapacity = 0
            $fullChargeCapacity = 0
            $cycleCount = $null

            if ($batteryNode.DesignCapacity -and
                [double]::TryParse(
                    [string]$batteryNode.DesignCapacity,
                    [ref]$designCapacity) -eq $false) {
                $designCapacity = 0
            }

            if ($batteryNode.FullChargeCapacity -and
                [double]::TryParse(
                    [string]$batteryNode.FullChargeCapacity,
                    [ref]$fullChargeCapacity) -eq $false) {
                $fullChargeCapacity = 0
            }

            if ($batteryNode.CycleCount -and
                [int]::TryParse(
                    [string]$batteryNode.CycleCount,
                    [ref]$cycleCount) -and
                $cycleCount -gt 0) {
                $cycleCount = [int]$cycleCount
            }
            else {
                $cycleCount = $null
            }

            $healthPercent = if ($designCapacity -gt 0 -and
                $fullChargeCapacity -gt 0) {
                [math]::Round(
                    ($fullChargeCapacity / $designCapacity) * 100,
                    1)
            }
            else {
                $null
            }

            $currentChargePercent = if ($status.BatteryLifePercent -le 100) {
                [int]$status.BatteryLifePercent
            }
            else {
                $null
            }

            $powerState = switch ($status.ACLineStatus) {
                0 { "On battery" }
                1 { "Connected to AC power" }
                default { $null }
            }

            $script:BatteryCollectionState = "available"
            $script:BatteryCollectionReason = "powercfg battery report"
            [pscustomobject]@{
                Manufacturer = if ($batteryNode.Manufacturer) {
                    [string]$batteryNode.Manufacturer
                }
                else {
                    $null
                }
                Chemistry = if ($batteryNode.Chemistry) {
                    [string]$batteryNode.Chemistry
                }
                else {
                    $null
                }
                DesignCapacityMWh = if ($designCapacity -gt 0) { [int]$designCapacity } else { $null }
                FullChargeCapacityMWh = if ($fullChargeCapacity -gt 0) { [int]$fullChargeCapacity } else { $null }
                HealthPercent = $healthPercent
                CycleCount = $cycleCount
                CurrentChargePercent = $currentChargePercent
                PowerState = $powerState
                Source = "GetSystemPowerStatus + powercfg battery report"
            }
        }
        finally {
            if (Test-Path -LiteralPath $reportPath -PathType Leaf) {
                Remove-Item -LiteralPath $reportPath -Force
            }
        }
    }
    catch {
        $script:BatteryCollectionState = if (
            Test-CollectionWarningIsAccessDenied -Warning $_.Exception.Message
        ) {
            "unavailable-permission"
        }
        else {
            "unavailable"
        }
        $script:BatteryCollectionReason = if ($script:BatteryCollectionState -eq "unavailable-permission") {
            "battery collection permission denied during $($script:BatteryCollectionReason)"
        }
        else {
            "battery collection failed during $($script:BatteryCollectionReason)"
        }
        Add-CollectionWarning `
            -Code "battery-status-fallback-failed" `
            -Text "Battery-status fallback failed: $($_.Exception.Message)"
        $null
    }
}

function Get-ActiveMonitorFallback {
    try {

        $monitors = @(
            [CodexActiveDisplayReader]::Read() |
                ForEach-Object {
                    $hdrStatus = if ($_.HdrQueryResult -ne 0) {
                        "Unavailable"
                    }
                    elseif ($_.HdrSupported -ne $true) {
                        "Not supported"
                    }
                    elseif ($null -eq $_.HdrEnabled) {
                        "Unavailable"
                    }
                    elseif ($_.HdrEnabled -eq $true) {
                        "On"
                    }
                    else {
                        "Supported, currently off"
                    }

                    $advancedColorEncoding = switch ($_.AdvancedColorEncoding) {
                        0 { "RGB" }
                        1 { "YCbCr444" }
                        2 { "YCbCr422" }
                        3 { "YCbCr420" }
                        4 { "Intensity" }
                        default { $null }
                    }

                    $displayColorSpace = switch ($_.DxgiColorSpace) {
                        0 { "RGB_FULL_G22_NONE_P709" }
                        1 { "RGB_FULL_G10_NONE_P709" }
                        2 { "RGB_STUDIO_G22_NONE_P709" }
                        3 { "RGB_STUDIO_G22_NONE_P2020" }
                        5 { "YCBCR_FULL_G22_NONE_P709_X601" }
                        6 { "YCBCR_STUDIO_G22_LEFT_P601" }
                        7 { "YCBCR_FULL_G22_LEFT_P601" }
                        8 { "YCBCR_STUDIO_G22_LEFT_P709" }
                        9 { "YCBCR_FULL_G22_LEFT_P709" }
                        10 { "YCBCR_STUDIO_G22_LEFT_P2020" }
                        11 { "YCBCR_FULL_G22_LEFT_P2020" }
                        12 { "RGB_FULL_G2084_NONE_P2020" }
                        13 { "YCBCR_STUDIO_G2084_LEFT_P2020" }
                        14 { "RGB_STUDIO_G2084_NONE_P2020" }
                        15 { "YCBCR_STUDIO_G22_TOPLEFT_P2020" }
                        16 { "YCBCR_STUDIO_G2084_TOPLEFT_P2020" }
                        17 { "RGB_FULL_G22_NONE_P2020" }
                        18 { "YCBCR_STUDIO_GHLG_TOPLEFT_P2020" }
                        19 { "YCBCR_FULL_GHLG_TOPLEFT_P2020" }
                        20 { "RGB_STUDIO_G24_NONE_P709" }
                        21 { "RGB_STUDIO_G24_NONE_P2020" }
                        22 { "YCBCR_STUDIO_G24_LEFT_P709" }
                        23 { "YCBCR_STUDIO_G24_LEFT_P2020" }
                        24 { "YCBCR_STUDIO_G24_TOPLEFT_P2020" }
                        25 { "RGB_FULL_G10_NONE_P2020" }
                        default { $null }
                    }

                    [pscustomobject]@{
                        Manufacturer = $null
                        Model = $_.Model
                        ProductCode = $_.ProductCode
                        Active = $true
                        AdapterName = $_.AdapterName
                        CurrentWidth = if ($_.CurrentWidth -gt 0) { [int]$_.CurrentWidth } else { $null }
                        CurrentHeight = if ($_.CurrentHeight -gt 0) { [int]$_.CurrentHeight } else { $null }
                        CurrentRefreshHz = if ($_.CurrentRefreshHz -gt 0) { [int]$_.CurrentRefreshHz } else { $null }
                        BitsPerPixel = if ($_.BitsPerPixel -gt 0) { [int]$_.BitsPerPixel } else { $null }
                        DisplayModeSource = "Windows current mode; not a native maximum"
                        HdrSupported = $_.HdrSupported
                        HdrEnabled = $_.HdrEnabled
                        HdrStatus = $hdrStatus
                        AdvancedColorEnabled = $_.AdvancedColorEnabled
                        WideColorEnforced = $_.WideColorEnforced
                        AdvancedColorForceDisabled = $_.AdvancedColorForceDisabled
                        AdvancedColorBitsPerColorChannel = if ($_.AdvancedColorBitsPerColorChannel -gt 0) { [int]$_.AdvancedColorBitsPerColorChannel } else { $null }
                        AdvancedColorEncoding = $advancedColorEncoding
                        HdrQueryResult = $_.HdrQueryResult
                        HdrSource = "DisplayConfig support state + DXGI current output color space"
                        DisplayColorSpace = $displayColorSpace
                        DxgiColorSpace = if ($_.DxgiColorSpace -ge 0) { [int]$_.DxgiColorSpace } else { $null }
                        DxgiBitsPerColor = if ($_.DxgiBitsPerColor -gt 0) { [int]$_.DxgiBitsPerColor } else { $null }
                        MaxLuminance = if ($_.MaxLuminance -gt 0) { [math]::Round($_.MaxLuminance, 1) } else { $null }
                        MaxFullFrameLuminance = if ($_.MaxFullFrameLuminance -gt 0) { [math]::Round($_.MaxFullFrameLuminance, 1) } else { $null }
                        Source = "EnumDisplayDevices active-display fallback"
                    }
                }
        )

        if ($monitors.Count -eq 0) {
            Add-CollectionWarning `
                -Code "display-fallback-empty" `
                -Text "Active-display fallback found no active monitor devices."
        }

        $monitors
    }
    catch {
        Add-CollectionWarning `
            -Code "display-fallback-failed" `
            -Text "Active-display fallback failed: $($_.Exception.Message)"
        @()
    }
}

function Convert-EdidText {
    param($Values)

    if ($null -eq $Values) {
        return $null
    }

    $characters = foreach ($value in $Values) {
        if ($value -ne 0) {
            [char]$value
        }
    }

    $text = (-join $characters).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    return $text
}

$computer = Get-CimData -ClassName Win32_ComputerSystem | Select-Object -First 1
$product = Get-CimData -ClassName Win32_ComputerSystemProduct | Select-Object -First 1
$bios = Get-CimData -ClassName Win32_BIOS | Select-Object -First 1
$board = Get-CimData -ClassName Win32_BaseBoard | Select-Object -First 1
$operatingSystem = Get-CimData -ClassName Win32_OperatingSystem | Select-Object -First 1
$wmiBattery = Get-CimData -ClassName Win32_Battery | Select-Object -First 1
$battery = Get-BatteryStatusFallback

if ($null -eq $battery -and $null -ne $wmiBattery) {
    $script:BatteryCollectionState = "available"
    $script:BatteryCollectionReason = "CIM/WMI battery fallback"
    $battery = [pscustomobject]@{
        Manufacturer = $null
        Chemistry = $null
        DesignCapacityMWh = $null
        FullChargeCapacityMWh = $null
        HealthPercent = $null
        CycleCount = $null
        CurrentChargePercent = $wmiBattery.EstimatedChargeRemaining
        PowerState = if ($wmiBattery.BatteryStatus -eq 2) { "Connected to AC power" } else { $null }
        Source = "CIM/WMI battery fallback"
    }
}

$batteryCimAccessDenied = @(
    $script:CollectionWarnings |
        Where-Object {
            $_ -match '(?i)^Win32_Battery unavailable through CIM:' -and
            (Test-CollectionWarningIsAccessDenied -Warning $_)
        }
).Count -gt 0
$batteryCimStatus = if ($null -ne $wmiBattery) {
    "available"
}
elseif ($batteryCimAccessDenied) {
    "unavailable-permission"
}
else {
    "unavailable"
}

$memoryStatusFallback = Get-MemoryStatusFallback

$registryBios = Get-RegistryData -Path "HKLM:\HARDWARE\DESCRIPTION\System\BIOS" -Names @(
    "SystemManufacturer",
    "SystemProductName",
    "BaseBoardManufacturer",
    "BaseBoardProduct",
    "BIOSVendor",
    "BIOSVersion",
    "BIOSReleaseDate"
)
$registryCpu = Get-RegistryData -Path "HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0" -Names @(
    "ProcessorNameString",
    "~MHz",
    "Identifier"
)
$registryOs = Get-RegistryData -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Names @(
    "ProductName",
    "EditionID",
    "DisplayVersion",
    "CurrentBuild",
    "CurrentBuildNumber",
    "UBR",
    "CurrentMajorVersionNumber",
    "CurrentMinorVersionNumber"
)

$processorTopology = Get-ProcessorTopologyFallback

$cpu = @(
    Get-CimData -ClassName Win32_Processor | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            Cores = if ($_.NumberOfCores) {
                $_.NumberOfCores
            }
            elseif ($processorTopology) {
                $processorTopology.PhysicalCoreCount
            }
            else {
                $null
            }
            LogicalProcessors = if ($_.NumberOfLogicalProcessors) {
                $_.NumberOfLogicalProcessors
            }
            elseif ($processorTopology) {
                $processorTopology.LogicalProcessorCount
            }
            else {
                $null
            }
            ReportedClockMHz = $_.MaxClockSpeed
            Socket = $_.SocketDesignation
            Source = if ($_.NumberOfCores -and $_.NumberOfLogicalProcessors) {
                "CIM/WMI"
            }
            else {
                "CIM/WMI + processor topology fallback"
            }
        }
    }
)

if ($cpu.Count -eq 0 -and $null -ne $registryCpu) {
    $cpu = @(
        [pscustomobject]@{
            Name = $registryCpu.ProcessorNameString
            Cores = if ($processorTopology) { $processorTopology.PhysicalCoreCount } else { $null }
            LogicalProcessors = if ($processorTopology) {
                $processorTopology.LogicalProcessorCount
            }
            elseif ($env:NUMBER_OF_PROCESSORS) {
                [int]$env:NUMBER_OF_PROCESSORS
            }
            else {
                $null
            }
            ReportedClockMHz = $registryCpu."~MHz"
            Socket = $null
            Source = "Registry + processor topology fallback"
        }
    )
}

$gpu = @(
    Get-CimData -ClassName Win32_VideoController | ForEach-Object {
        [pscustomobject]@{
            Name = $_.Name
            DriverVersion = $_.DriverVersion
            NvidiaDriverVersion = $null
            ReportedMemory = $null
            ReportedMemorySource = $null
            CimAdapterRAMBytes = $_.AdapterRAM
            CimAdapterRAMReliable = $false
            CurrentHorizontalResolution = $_.CurrentHorizontalResolution
            CurrentVerticalResolution = $_.CurrentVerticalResolution
            CurrentRefreshRate = $_.CurrentRefreshRate
            Source = "CIM/WMI"
        }
    }
)

$hasNvidiaGpu = @($gpu | Where-Object { $_.Name -match "NVIDIA" }).Count -gt 0
if (($gpu.Count -eq 0 -or $hasNvidiaGpu) -and (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) {
    try {
        $nvidiaRows = & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>$null
        $nvidiaGpuInfo = @(
            foreach ($row in @($nvidiaRows)) {
                if (-not [string]::IsNullOrWhiteSpace($row)) {
                    $parts = $row -split "\s*,\s*", 3
                    [pscustomobject]@{
                        Name = $parts[0]
                        NvidiaDriverVersion = if ($parts.Count -gt 1) { $parts[1] } else { $null }
                        ReportedMemory = if ($parts.Count -gt 2) { $parts[2] } else { $null }
                    }
                }
            }
        )

        if ($gpu.Count -eq 0) {
            $gpu = @(
                foreach ($item in $nvidiaGpuInfo) {
                    [pscustomobject]@{
                        Name = $item.Name
                        DriverVersion = $null
                        NvidiaDriverVersion = $item.NvidiaDriverVersion
                        ReportedMemory = $item.ReportedMemory
                        ReportedMemorySource = "nvidia-smi"
                        CimAdapterRAMBytes = $null
                        CimAdapterRAMReliable = $null
                        CurrentHorizontalResolution = $null
                        CurrentVerticalResolution = $null
                        CurrentRefreshRate = $null
                        Source = "nvidia-smi fallback"
                    }
                }
            )
        }
        else {
            foreach ($item in $gpu) {
                if ($item.Name -notmatch "NVIDIA") { continue }
                $matchingNvidiaInfo = $nvidiaGpuInfo |
                    Where-Object { $_.Name.Trim() -eq $item.Name.Trim() } |
                    Select-Object -First 1
                if ($matchingNvidiaInfo) {
                    $item.NvidiaDriverVersion = $matchingNvidiaInfo.NvidiaDriverVersion
                    $item.ReportedMemory = $matchingNvidiaInfo.ReportedMemory
                    $item.ReportedMemorySource = "nvidia-smi"
                }
            }
        }

        try {
            $telemetryRows = & nvidia-smi --query-gpu=name,temperature.gpu,power.draw,clocks.gr,utilization.gpu,fan.speed,power.limit --format=csv,noheader,nounits 2>$null
            $sampledAt = (Get-Date).ToString("o")
            $convertNvidiaNumber = {
                param([string]$Value)
                if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '(?i)N/?A') {
                    return $null
                }
                $normalized = $Value.Trim() -replace ',', '.'
                $number = 0.0
                if ([double]::TryParse(
                    $normalized,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [ref]$number)) {
                    return $number
                }
                return $null
            }
            $nvidiaTelemetry = @(
                foreach ($row in @($telemetryRows)) {
                    if ([string]::IsNullOrWhiteSpace($row)) { continue }
                    $parts = @($row -split "\s*,\s*")
                    if ($parts.Count -lt 7) { continue }
                    [pscustomobject]@{
                        Name = $parts[0]
                        TemperatureC = & $convertNvidiaNumber $parts[1]
                        PowerW = & $convertNvidiaNumber $parts[2]
                        CoreClockMHz = & $convertNvidiaNumber $parts[3]
                        UtilizationPercent = & $convertNvidiaNumber $parts[4]
                        FanPercent = & $convertNvidiaNumber $parts[5]
                        PowerLimitW = & $convertNvidiaNumber $parts[6]
                        SampledAt = $sampledAt
                    }
                }
            )
            foreach ($item in @($gpu | Where-Object { $_.Name -match "NVIDIA" })) {
                $matchingTelemetry = $nvidiaTelemetry |
                    Where-Object { $_.Name.Trim() -eq $item.Name.Trim() } |
                    Select-Object -First 1
                if ($null -eq $matchingTelemetry) { continue }
                $item | Add-Member -NotePropertyName NvidiaTemperatureC -NotePropertyValue $matchingTelemetry.TemperatureC -Force
                $item | Add-Member -NotePropertyName NvidiaPowerW -NotePropertyValue $matchingTelemetry.PowerW -Force
                $item | Add-Member -NotePropertyName NvidiaCoreClockMHz -NotePropertyValue $matchingTelemetry.CoreClockMHz -Force
                $item | Add-Member -NotePropertyName NvidiaUtilizationPercent -NotePropertyValue $matchingTelemetry.UtilizationPercent -Force
                $item | Add-Member -NotePropertyName NvidiaFanPercent -NotePropertyValue $matchingTelemetry.FanPercent -Force
                $item | Add-Member -NotePropertyName NvidiaPowerLimitW -NotePropertyValue $matchingTelemetry.PowerLimitW -Force
                $item | Add-Member -NotePropertyName NvidiaTelemetrySampledAt -NotePropertyValue $matchingTelemetry.SampledAt -Force
                $item | Add-Member -NotePropertyName NvidiaTelemetrySource -NotePropertyValue "nvidia-smi instantaneous sample" -Force
            }
        }
        catch {
            Add-CollectionWarning `
                -Code "nvidia-smi-telemetry-failed" `
                -Text "nvidia-smi telemetry sample failed: $($_.Exception.Message)"
        }
    }
    catch {
        Add-CollectionWarning `
            -Code "nvidia-smi-identity-failed" `
            -Text "nvidia-smi GPU identity lookup failed: $($_.Exception.Message)"
    }
}

$memory = @(
    Get-CimData -ClassName Win32_PhysicalMemory | ForEach-Object {
        [pscustomobject]@{
            CapacityBytes = $_.Capacity
            Capacity = Format-Capacity $_.Capacity
            SpeedMTs = $_.Speed
            ConfiguredSpeedMTs = $_.ConfiguredClockSpeed
            Manufacturer = $_.Manufacturer
            PartNumber = $_.PartNumber
            FormFactor = $_.FormFactor
            Slot = $_.DeviceLocator
        }
    }
)

$memorySource = if ($memory.Count -gt 0) { "CIM/WMI" } else { $null }
if ($memory.Count -eq 0) {
    $memory = @(Get-SmbiosMemoryFallback)
    if ($memory.Count -gt 0) {
        $memorySource = "SMBIOS fallback"
    }
}

$physicalDisks = @(
    Get-CimData -ClassName Win32_DiskDrive | ForEach-Object {
        [pscustomobject]@{
            Model = $_.Model
            DeviceNumber = [int]$_.Index
            Interface = $_.InterfaceType
            MediaType = $_.MediaType
            SizeBytes = $_.Size
            Size = Format-Capacity $_.Size
            Status = $_.Status
        }
    }
)

$physicalDiskSource = if ($physicalDisks.Count -gt 0) { "CIM/WMI" } else { $null }
if ($physicalDisks.Count -eq 0) {
    $physicalDisks = @(Get-ActiveDiskFallback)
    if ($physicalDisks.Count -gt 0) {
        $physicalDiskSource = "SetupAPI active-device fallback"
    }
}

$physicalDiskDescriptors = @(Get-PhysicalDiskDescriptorFallback)

if ($physicalDisks.Count -eq 0 -and $physicalDiskDescriptors.Count -gt 0) {
    $physicalDisks = @(
        foreach ($descriptor in $physicalDiskDescriptors) {
            $interface = switch ($descriptor.BusType) {
                7 { "USB" }
                8 { "RAID" }
                11 { "SATA" }
                17 { "NVMe" }
                default { $null }
            }
            [pscustomobject]@{
                Model = $descriptor.ProductId
                DeviceNumber = $descriptor.DeviceNumber
                Interface = $interface
                MediaType = $null
                SizeBytes = $null
                Size = $null
                Status = "Present"
                HealthStatus = "Unavailable in current environment"
                Source = "Storage descriptor fallback"
            }
        }
    )
    if ($physicalDisks.Count -gt 0) {
        $physicalDiskSource = "Storage descriptor fallback"
    }
}

foreach ($disk in $physicalDisks) {
    $deviceNumber = if ($disk.PSObject.Properties.Name -contains "DeviceNumber") {
        $disk.DeviceNumber
    }
    else {
        $null
    }

    $descriptor = if ($null -ne $deviceNumber) {
        $physicalDiskDescriptors |
            Where-Object { $_.DeviceNumber -eq $deviceNumber } |
            Select-Object -First 1
    }
    else {
        $physicalDiskDescriptors |
            Where-Object {
                $disk.Model -and
                $_.ProductId -and
                $disk.Model.IndexOf(
                    $_.ProductId,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0
            } |
            Select-Object -First 1
    }

    if ($descriptor) {
        if ($null -eq $deviceNumber) {
            $disk | Add-Member -NotePropertyName DeviceNumber -NotePropertyValue $descriptor.DeviceNumber
        }
        $disk | Add-Member -NotePropertyName ProductRevision -NotePropertyValue $descriptor.ProductRevision -Force
    }
}

$storageHealth = @{}
try {
    Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
        $storageHealth[$_.FriendlyName] = [pscustomobject]@{
            MediaType = $_.MediaType.ToString()
            BusType = $_.BusType.ToString()
            HealthStatus = $_.HealthStatus.ToString()
            OperationalStatus = ($_.OperationalStatus | ForEach-Object { $_.ToString() }) -join ", "
        }
    }
}
catch {
    Add-CollectionWarning `
        -Code "storage-health-unavailable" `
        -Text "Physical disk health is unavailable through Storage cmdlets: $($_.Exception.Message)"
}

foreach ($disk in $physicalDisks) {
    if ($storageHealth.ContainsKey($disk.Model)) {
        $health = $storageHealth[$disk.Model]
        $disk | Add-Member -NotePropertyName StorageBusType -NotePropertyValue $health.BusType
        $disk | Add-Member -NotePropertyName HealthStatus -NotePropertyValue $health.HealthStatus
        $disk | Add-Member -NotePropertyName OperationalStatus -NotePropertyValue $health.OperationalStatus
    }
}

$volumes = @(
    Get-CimData -ClassName Win32_LogicalDisk -Filter "DriveType = 2 OR DriveType = 3" | ForEach-Object {
        [pscustomobject]@{
            DriveLetter = $_.DeviceID
            Label = $_.VolumeName
            FileSystem = $_.FileSystem
            SizeBytes = $_.Size
            Size = Format-Capacity $_.Size
            FreeBytes = $_.FreeSpace
            Free = Format-Capacity $_.FreeSpace
        }
    }
)

if ($volumes.Count -eq 0) {
    $volumes = @(
        [System.IO.DriveInfo]::GetDrives() |
            Where-Object {
                $_.IsReady -and $_.DriveType -in @([System.IO.DriveType]::Fixed, [System.IO.DriveType]::Removable)
            } |
            ForEach-Object {
            [pscustomobject]@{
                DriveLetter = $_.Name.TrimEnd("\")
                Label = $_.VolumeLabel
                FileSystem = $_.DriveFormat
                SizeBytes = [double]$_.TotalSize
                Size = Format-Capacity $_.TotalSize
                FreeBytes = [double]$_.AvailableFreeSpace
                Free = Format-Capacity $_.AvailableFreeSpace
                Source = "DriveInfo fallback"
            }
        }
    )

    if ($volumes.Count -gt 0) {
        Add-CollectionWarning `
            -Code "storage-health-no-access" `
            -Text "Storage health is unavailable without Storage cmdlet access; active disk models are reported through SetupAPI when possible."
    }
}

$volumeDiskMappings = @(Get-VolumeDiskMapping)
$diskByNumber = @{}

foreach ($disk in $physicalDisks) {
    $disk | Add-Member -NotePropertyName VolumeLetters -NotePropertyValue @() -Force
    if ($disk.PSObject.Properties.Name -contains "DeviceNumber" -and
        $null -ne $disk.DeviceNumber) {
        $diskByNumber[[int]$disk.DeviceNumber] = $disk
    }
}

$unmappedVolumes = New-Object System.Collections.Generic.List[string]
foreach ($volume in $volumes) {
    $mapping = $volumeDiskMappings |
        Where-Object { $_.DriveLetter -eq $volume.DriveLetter } |
        Select-Object -First 1

    if ($mapping -and $mapping.Success) {
        $volume | Add-Member -NotePropertyName DiskNumber -NotePropertyValue $mapping.DeviceNumber
        $volume | Add-Member -NotePropertyName PartitionNumber -NotePropertyValue $mapping.PartitionNumber
        $volume | Add-Member -NotePropertyName MappingSource -NotePropertyValue "IOCTL_STORAGE_GET_DEVICE_NUMBER"

        if ($diskByNumber.ContainsKey([int]$mapping.DeviceNumber)) {
            $mappedDisk = $diskByNumber[[int]$mapping.DeviceNumber]
            $volume | Add-Member -NotePropertyName PhysicalDisk -NotePropertyValue $mappedDisk.Model
            $mappedDisk.VolumeLetters = @(
                @($mappedDisk.VolumeLetters) + @($volume.DriveLetter) |
                    Sort-Object -Unique
            )
        }
    }
    else {
        $unmappedVolumes.Add($volume.DriveLetter)
    }
}

if ($unmappedVolumes.Count -gt 0) {
    Add-CollectionWarning `
        -Code "volume-mapping-partial" `
        -Text "Volume-to-disk mapping unavailable for: $($unmappedVolumes -join ', ')"
}

$monitors = @(
    Get-CimData -Namespace "root/wmi" -ClassName WmiMonitorID | ForEach-Object {
        [pscustomobject]@{
            Manufacturer = Convert-EdidText $_.ManufacturerName
            Model = Convert-EdidText $_.UserFriendlyName
            ProductCode = Convert-EdidText $_.ProductCodeID
            Active = $_.Active
        }
    }
)

$monitorSource = if ($monitors.Count -gt 0) { "CIM/WMI" } else { $null }
if ($monitors.Count -eq 0) {
    $monitors = @(Get-ActiveMonitorFallback)
    if ($monitors.Count -gt 0) {
        $monitorSource = "EnumDisplayDevices active-display fallback"
    }
}

$osBuildNumber = if ($operatingSystem.BuildNumber) {
    [string]$operatingSystem.BuildNumber
}
elseif ($registryOs.CurrentBuildNumber) {
    [string]$registryOs.CurrentBuildNumber
}
elseif ($registryOs.CurrentBuild) {
    [string]$registryOs.CurrentBuild
}
else {
    $null
}

$osCaption = Resolve-WindowsOperatingSystemCaption `
    -Caption $(if ($operatingSystem.Caption) { [string]$operatingSystem.Caption } else { $null }) `
    -ProductName $(if ($registryOs.ProductName) { [string]$registryOs.ProductName } else { $null }) `
    -EditionId $(if ($registryOs.EditionID) { [string]$registryOs.EditionID } else { $null }) `
    -BuildNumber $osBuildNumber

$osDisplayVersion = if ($registryOs.DisplayVersion) {
    [string]$registryOs.DisplayVersion
}
else {
    $null
}

$osKernelVersion = if ($operatingSystem.Version) {
    [string]$operatingSystem.Version
}
elseif (($null -ne $registryOs.CurrentMajorVersionNumber) -and
        ($null -ne $registryOs.CurrentMinorVersionNumber) -and
        $osBuildNumber) {
    "$($registryOs.CurrentMajorVersionNumber).$($registryOs.CurrentMinorVersionNumber).$osBuildNumber"
}
else {
    $null
}

$firmwareTypeCode = $null
try {
    $firmwareTypeCode = [int][CodexFirmwareTypeReader]::Read()
}
catch {
    Add-CollectionWarning `
        -Code "firmware-type-fallback-failed" `
        -Text "Firmware-type fallback failed: $($_.Exception.Message)"
}

$firmwareMode = switch ($firmwareTypeCode) {
    1 { "Legacy BIOS" }
    2 { "UEFI" }
    3 { "Unknown" }
    default { $null }
}

$secureBootStatus = if ($firmwareTypeCode -eq 1) {
    "Not applicable (Legacy BIOS)"
}
elseif ($firmwareTypeCode -eq 2) {
    try {
        $secureBootState = Get-ItemProperty `
            -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State" `
            -Name "UEFISecureBootEnabled" `
            -ErrorAction Stop
        if ($secureBootState.UEFISecureBootEnabled -eq 1) {
            "On"
        }
        elseif ($secureBootState.UEFISecureBootEnabled -eq 0) {
            "Off"
        }
        else {
            "Unavailable"
        }
    }
    catch {
        "Unavailable"
    }
}
else {
    "Unknown"
}

if ($RedactIdentifiers) {
    $redactedInventory = Get-RedactedInventoryData `
        -MemoryModules $memory `
        -PhysicalDisks $physicalDisks `
        -Volumes $volumes `
        -Monitors $monitors `
        -Battery $battery
    $memory = $redactedInventory.MemoryModules
    $physicalDisks = $redactedInventory.PhysicalDisks
    $volumes = $redactedInventory.Volumes
    $monitors = $redactedInventory.Monitors
    $battery = $redactedInventory.Battery
}

$identityManufacturer = if ($RedactIdentifiers) { "[redacted]" } elseif ($computer.Manufacturer) { $computer.Manufacturer } else { $registryBios.SystemManufacturer }
$identityModel = if ($RedactIdentifiers) { "[redacted]" } elseif ($computer.Model) { $computer.Model } else { $registryBios.SystemProductName }
$identityFamily = if ($RedactIdentifiers) { "[redacted]" } else { $computer.SystemFamily }
$identityBoardManufacturer = if ($RedactIdentifiers) { "[redacted]" } elseif ($board.Manufacturer) { $board.Manufacturer } else { $registryBios.BaseBoardManufacturer }
$identityBoardProduct = if ($RedactIdentifiers) { "[redacted]" } elseif ($board.Product) { $board.Product } else { $registryBios.BaseBoardProduct }
$identityAssessment = Get-DeviceIdentityAssessment `
    -Manufacturer $identityManufacturer `
    -Model $identityModel `
    -SystemFamily $identityFamily `
    -MotherboardManufacturer $identityBoardManufacturer `
    -MotherboardProduct $identityBoardProduct
if ($identityAssessment.Status -in @("unreadable", "suspicious", "partial", "unknown")) {
    Add-CollectionWarning `
        -Code "identity-quality-unconfirmed" `
        -Text "Device identity quality is $($identityAssessment.Status); do not treat unreadable or unconfirmed model text as a confirmed device identity."
}

$accessDeniedWarningCount = @(
    $script:CollectionWarnings |
        Where-Object {
            Test-CollectionWarningIsAccessDenied -Warning $_
        }
).Count
$processClassification = Get-CollectionProcessClassification `
    -IsElevated $isElevated `
    -RestrictedEnvironmentHint $restrictedAgentEnvironmentHint `
    -AccessDeniedWarningCount $accessDeniedWarningCount
$isRestrictedAgentProcess = (
    $processClassification.ProcessClass -eq "restricted-agent"
)
if ($accessDeniedWarningCount -gt 0 -and -not $isElevated) {
    if ($isRestrictedAgentProcess) {
        Add-CollectionWarning `
            -Code "access-denied-restricted-agent" `
            -Text "Broad inventory access was denied inside a restricted agent process. Run the collector from a normal non-elevated PowerShell outside the agent sandbox first; that normally restores CIM, disk, battery, and monitor inventory. If a decision still needs Storage Reliability counters, then use a user-started elevated PowerShell. Elevation is not the first remedy for sandbox denial."
    }
    else {
        Add-CollectionWarning `
            -Code "access-denied-elevation-advice" `
            -Text "Some inventory queries were denied in the current non-elevated process. A user-started elevated collection may recover missing system inventory or storage reliability fields. Event-log inspection is separate, and elevation cannot reveal firmware-hidden temperatures, clocks, voltages, or fan sensors."
    }
}

$uniqueWarningTexts = New-Object System.Collections.Generic.List[string]
$uniqueWarningCodes = New-Object System.Collections.Generic.List[string]
$seenWarningPairs = New-Object System.Collections.Generic.HashSet[string]
for ($warningIndex = 0; $warningIndex -lt $script:CollectionWarnings.Count; $warningIndex++) {
    $warningText = $script:CollectionWarnings[$warningIndex]
    $warningCode = $script:CollectionWarningCodes[$warningIndex]
    $warningPairKey = "$warningCode`u0000$warningText"
    if ($seenWarningPairs.Add($warningPairKey)) {
        $uniqueWarningTexts.Add($warningText) | Out-Null
        $uniqueWarningCodes.Add($warningCode) | Out-Null
    }
}

$memoryModulesStatus = if ($memory.Count -gt 0) { "available" } else { "unavailable in current environment" }
$physicalDisksStatus = if ($physicalDisks.Count -gt 0) { "available" } else { "unavailable in current environment" }
$volumesStatus = if ($volumes.Count -gt 0) { "available" } else { "unavailable in current environment" }
$volumeDiskMappingStatus = if ($volumes.Count -eq 0) {
    "unavailable in current environment"
}
elseif ($unmappedVolumes.Count -eq 0) {
    "available"
}
else {
    "partial"
}
$batteryStatus = Get-BatteryCollectionStatus `
    -Battery $battery `
    -BatteryState $script:BatteryCollectionState
$monitorsStatus = if ($monitors.Count -gt 0) { "available" } else { "unavailable in current environment" }
$memoryModulesSource = if ($memoryModulesStatus -in @("available", "partial") -and [string]::IsNullOrWhiteSpace($memorySource)) {
    "unspecified available source"
}
else {
    $memorySource
}
$physicalDisksSource = if ($physicalDisksStatus -in @("available", "partial") -and [string]::IsNullOrWhiteSpace($physicalDiskSource)) {
    "unspecified available source"
}
else {
    $physicalDiskSource
}
$batterySource = if ($batteryStatus -eq "available") {
    if ($battery -and -not [string]::IsNullOrWhiteSpace($battery.Source)) {
        $battery.Source
    }
    else {
        "unspecified available source"
    }
}
else {
    $null
}
$monitorsSource = if ($monitorsStatus -in @("available", "partial") -and [string]::IsNullOrWhiteSpace($monitorSource)) {
    "unspecified available source"
}
else {
    $monitorSource
}

$snapshot = [ordered]@{
    SchemaVersion = 3
    CollectorVersion = "1.0.1-r18"
    GeneratedAt = (Get-Date).ToString("o")
    PrivacyMode = if ($RedactIdentifiers) {
        "Redacted identifiers"
    }
    else {
        "Standard"
    }
    CollectionMode = if ($RedactIdentifiers) {
        "Read-only local Windows inventory; serial numbers omitted; identifying device and component codes redacted"
    }
    else {
        "Read-only local Windows inventory; serial numbers are intentionally omitted"
    }
    CollectionContext = [pscustomobject]@{
        IsElevated = $isElevated
        RequireElevated = [bool]$RequireElevated
        IsRestrictedAgentProcess = [bool]$isRestrictedAgentProcess
        AccessDeniedWarningCount = $accessDeniedWarningCount
        ProcessClass = $processClassification.ProcessClass
        ProcessClassReason = $processClassification.Reason
        AccessDeniedThreshold = $processClassification.AccessDeniedThreshold
        Privilege = if ($isElevated) {
            "Elevated user process"
        }
        elseif ($isRestrictedAgentProcess) {
            "Restricted agent process"
        }
        else {
            "Standard user process"
        }
    }
    IdentityQuality = $identityAssessment
    Computer = [pscustomobject]@{
        Manufacturer = $identityManufacturer
        ManufacturerDisplay = ConvertTo-DeviceIdentityDisplay -Value $identityManufacturer
        Model = $identityModel
        ModelDisplay = ConvertTo-DeviceIdentityDisplay -Value $identityModel
        SystemFamily = $identityFamily
        SystemFamilyDisplay = ConvertTo-DeviceIdentityDisplay -Value $identityFamily
        TotalPhysicalMemoryBytes = if ($computer.TotalPhysicalMemory) { [double]$computer.TotalPhysicalMemory } elseif ($memoryStatusFallback) { $memoryStatusFallback.TotalBytes } else { $null }
        TotalPhysicalMemory = Format-Capacity $(if ($computer.TotalPhysicalMemory) { [double]$computer.TotalPhysicalMemory } elseif ($memoryStatusFallback) { $memoryStatusFallback.TotalBytes } else { $null })
        AvailablePhysicalMemoryBytes = if ($memoryStatusFallback) { $memoryStatusFallback.AvailableBytes } else { $null }
        AvailablePhysicalMemory = if ($memoryStatusFallback) { Format-Capacity $memoryStatusFallback.AvailableBytes } else { $null }
        MemoryLoadPercent = if ($memoryStatusFallback) { $memoryStatusFallback.MemoryLoadPercent } else { $null }
        ProductVendor = if ($RedactIdentifiers) { "[redacted]" } else { $product.Vendor }
        ProductName = if ($RedactIdentifiers) { "[redacted]" } else { $product.Name }
        ProductVersion = if ($RedactIdentifiers) { "[redacted]" } else { $product.Version }
    }
    OperatingSystem = [pscustomobject]@{
        Caption = $osCaption
        DisplayVersion = $osDisplayVersion
        Version = $osKernelVersion
        BuildNumber = $osBuildNumber
        UpdateBuildRevision = $registryOs.UBR
        Architecture = if ($operatingSystem.OSArchitecture) { $operatingSystem.OSArchitecture } else { $env:PROCESSOR_ARCHITECTURE }
    }
    Firmware = [pscustomobject]@{
        Manufacturer = if ($RedactIdentifiers) { "[redacted]" } elseif ($bios.Manufacturer) { $bios.Manufacturer } else { $registryBios.BIOSVendor }
        Version = if ($RedactIdentifiers) { "[redacted]" } elseif ($bios.SMBIOSBIOSVersion) { $bios.SMBIOSBIOSVersion } else { $registryBios.BIOSVersion }
        ReleaseDate = if ($RedactIdentifiers) { "[redacted]" } elseif ($bios.ReleaseDate) { $bios.ReleaseDate } else { $registryBios.BIOSReleaseDate }
        Mode = $firmwareMode
        SecureBoot = $secureBootStatus
    }
    Motherboard = [pscustomobject]@{
        Manufacturer = $identityBoardManufacturer
        ManufacturerDisplay = ConvertTo-DeviceIdentityDisplay -Value $identityBoardManufacturer
        Product = $identityBoardProduct
        ProductDisplay = ConvertTo-DeviceIdentityDisplay -Value $identityBoardProduct
        Version = if ($RedactIdentifiers) { "[redacted]" } else { $board.Version }
    }
    Battery = $battery
    CPU = $cpu
    GPU = $gpu
    MemoryModules = $memory
    PhysicalDisks = $physicalDisks
    Volumes = $volumes
    Monitors = $monitors
    CollectionStatus = [pscustomobject]@{
        MemoryModules = $memoryModulesStatus
        MemoryModulesSource = $memoryModulesSource
        PhysicalDisks = $physicalDisksStatus
        PhysicalDisksSource = $physicalDisksSource
        PhysicalDisksScope = if ($physicalDisks.Count -gt 0) { "Windows-reported present devices; active/offline state is not inferred" } else { $null }
        Volumes = $volumesStatus
        VolumesScope = if ($volumes.Count -gt 0) { "fixed and removable local drives; network drives excluded" } else { $null }
        VolumeDiskMapping = $volumeDiskMappingStatus
        VolumeDiskMappingSource = if ($volumeDiskMappingStatus -in @("available", "partial")) { "IOCTL_STORAGE_GET_DEVICE_NUMBER" } else { $null }
        Battery = $batteryStatus
        BatterySource = $batterySource
        BatteryStatusReason = $script:BatteryCollectionReason
        BatteryCimStatus = $batteryCimStatus
        Monitors = $monitorsStatus
        MonitorsSource = $monitorsSource
        MonitorsScope = if (
            $monitorSource -eq "EnumDisplayDevices active-display fallback" -and
            $monitors.Count -gt 0
        ) {
            "active monitors only"
        }
        else {
            $null
        }
    }
    CollectionWarnings = @($uniqueWarningTexts)
    CollectionWarningCodes = @($uniqueWarningCodes)
    NotReliablyDetectable = @(
        "Exact PSU model, age, cable setup, and connectors",
        "Case, cooler, fan layout, and physical clearance",
        "Monitor cable type, DSC, VRR, and full chroma negotiation",
        "Purchase price, warranty, and resale value",
        "Actual workload bottleneck without monitoring data",
        "User satisfaction, priorities, and budget"
    )
}

if ($Format -eq "Json") {
    $rendered = $snapshot | ConvertTo-Json -Depth 8
}
else {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Hardware snapshot")
    $lines.Add("")
    $lines.Add("Generated: $($snapshot.GeneratedAt)")
    $lines.Add("Collector: $($snapshot.CollectorVersion), schema $($snapshot.SchemaVersion)")
    $lines.Add("")
    $lines.Add("Read-only local inventory. Serial numbers are intentionally omitted.")
    $lines.Add(
        "- Collection context: $($snapshot.CollectionContext.ProcessClass) ($($snapshot.CollectionContext.Privilege))")
    if ($snapshot.PrivacyMode -eq "Redacted identifiers") {
        $lines.Add("")
        $lines.Add(
            "Privacy mode: identifying device and component codes are redacted; CPU/GPU model names and capability data remain.")
    }
    $lines.Add("")
    $lines.Add("## System")
    $lines.Add("")
    $lines.Add("- Identity quality: $($snapshot.IdentityQuality.Status)")
    foreach ($identityWarning in $snapshot.IdentityQuality.Warnings) {
        $lines.Add("  - Identity warning: $(ConvertTo-SafeMarkdownText -Value $identityWarning)")
    }
    if ($snapshot.Computer.ManufacturerDisplay) {
        $lines.Add("- Manufacturer: $(ConvertTo-DeviceIdentityMarkdown -Value $snapshot.Computer.ManufacturerDisplay)")
    }
    if ($snapshot.Computer.ModelDisplay) {
        $lines.Add("- Model: $(ConvertTo-DeviceIdentityMarkdown -Value $snapshot.Computer.ModelDisplay)")
    }
    if ($snapshot.Computer.SystemFamilyDisplay) {
        $lines.Add("- System family: $(ConvertTo-DeviceIdentityMarkdown -Value $snapshot.Computer.SystemFamilyDisplay)")
    }
    if ($snapshot.Computer.TotalPhysicalMemory) {
        $memoryText = "Memory total: $($snapshot.Computer.TotalPhysicalMemory)"
        if ($snapshot.Computer.AvailablePhysicalMemory) { $memoryText += "; available: $($snapshot.Computer.AvailablePhysicalMemory)" }
        if ($null -ne $snapshot.Computer.MemoryLoadPercent) { $memoryText += "; load: $($snapshot.Computer.MemoryLoadPercent)%" }
        $lines.Add("- $memoryText")
    }
    $osText = $snapshot.OperatingSystem.Caption
    if ($snapshot.OperatingSystem.DisplayVersion) { $osText += " $($snapshot.OperatingSystem.DisplayVersion)" }
    if ($snapshot.OperatingSystem.BuildNumber) {
        $buildText = "build $($snapshot.OperatingSystem.BuildNumber)"
        if ($null -ne $snapshot.OperatingSystem.UpdateBuildRevision) {
            $buildText += ".$($snapshot.OperatingSystem.UpdateBuildRevision)"
        }
        $osText += ", $buildText"
    }
    $lines.Add("- OS: $(ConvertTo-SafeMarkdownText -Value $osText)")
    if ($snapshot.OperatingSystem.Architecture) {
        $lines.Add("- System architecture: $($snapshot.OperatingSystem.Architecture)")
    }
    $biosText = "$($snapshot.Firmware.Manufacturer) $($snapshot.Firmware.Version)"
    if ($snapshot.Firmware.ReleaseDate) {
        $biosText += ", released $($snapshot.Firmware.ReleaseDate)"
    }
    $lines.Add("- BIOS: $(ConvertTo-SafeMarkdownText -Value $biosText)")
    if ($snapshot.Firmware.Mode) {
        $firmwareText = $snapshot.Firmware.Mode
        if ($snapshot.Firmware.SecureBoot) {
            $firmwareText += "; Secure Boot: $($snapshot.Firmware.SecureBoot)"
        }
        $lines.Add("- Firmware: $firmwareText")
    }
    $motherboardManufacturer = ConvertTo-DeviceIdentityMarkdown -Value $snapshot.Motherboard.ManufacturerDisplay
    $motherboardProduct = ConvertTo-DeviceIdentityMarkdown -Value $snapshot.Motherboard.ProductDisplay
    $lines.Add("- Motherboard: $motherboardManufacturer $motherboardProduct")
    $lines.Add("")
    $lines.Add("## CPU")
    $lines.Add("")
    if ($snapshot.CPU.Count -eq 0) { $lines.Add("- CPU inventory unavailable in this environment.") }
    foreach ($item in $snapshot.CPU) {
        $details = @($item.Name)
        if ($item.Cores) { $details += "$($item.Cores) cores" }
        if ($item.LogicalProcessors) { $details += "$($item.LogicalProcessors) threads" }
        $lines.Add("- $(ConvertTo-SafeMarkdownText -Value ($details -join ', '))")
    }
    $lines.Add("")
    $lines.Add("## Reported GPUs")
    $lines.Add("")
    if ($snapshot.GPU.Count -eq 0) { $lines.Add("- GPU inventory unavailable in this environment.") }
    foreach ($item in $snapshot.GPU) {
        $details = @($item.Name)
        if ($item.DriverVersion -and $item.NvidiaDriverVersion) {
            $details += "driver $($item.DriverVersion) (NVIDIA $($item.NvidiaDriverVersion))"
        }
        elseif ($item.DriverVersion) {
            $details += "driver $($item.DriverVersion)"
        }
        elseif ($item.NvidiaDriverVersion) {
            $details += "driver NVIDIA $($item.NvidiaDriverVersion)"
        }
        if ($item.PSObject.Properties.Name -contains "ReportedMemory" -and $item.ReportedMemory) {
            $memoryText = "reported memory $($item.ReportedMemory)"
            if ($item.ReportedMemorySource) { $memoryText += " ($($item.ReportedMemorySource))" }
            $details += $memoryText
        }
        if ($item.CurrentHorizontalResolution -and $item.CurrentVerticalResolution) { $details += "current $($item.CurrentHorizontalResolution)x$($item.CurrentVerticalResolution)" }
        if ($item.CurrentRefreshRate) { $details += "$($item.CurrentRefreshRate) Hz" }
        $lines.Add("- $(ConvertTo-SafeMarkdownText -Value ($details -join ', '))")
        if ($item.PSObject.Properties.Name -contains "NvidiaTelemetrySampledAt" -and $item.NvidiaTelemetrySampledAt) {
            $telemetryDetails = New-Object System.Collections.Generic.List[string]
            if ($null -ne $item.NvidiaTemperatureC) { $telemetryDetails.Add("temperature $($item.NvidiaTemperatureC) C") | Out-Null }
            if ($null -ne $item.NvidiaPowerW) { $telemetryDetails.Add("power $($item.NvidiaPowerW) W") | Out-Null }
            if ($null -ne $item.NvidiaCoreClockMHz) { $telemetryDetails.Add("core clock $($item.NvidiaCoreClockMHz) MHz") | Out-Null }
            if ($null -ne $item.NvidiaUtilizationPercent) { $telemetryDetails.Add("utilization $($item.NvidiaUtilizationPercent)%") | Out-Null }
            if ($null -ne $item.NvidiaFanPercent) { $telemetryDetails.Add("fan $($item.NvidiaFanPercent)%") | Out-Null }
            if ($null -ne $item.NvidiaPowerLimitW) { $telemetryDetails.Add("power limit $($item.NvidiaPowerLimitW) W") | Out-Null }
            if ($telemetryDetails.Count -gt 0) {
                $lines.Add("  - nvidia-smi instantaneous sample at $($item.NvidiaTelemetrySampledAt): $($telemetryDetails -join '; '); not a stability measurement")
            }
            $unavailableTelemetry = New-Object System.Collections.Generic.List[string]
            if ($null -eq $item.NvidiaFanPercent) { $unavailableTelemetry.Add("fan") | Out-Null }
            if ($null -eq $item.NvidiaPowerLimitW) { $unavailableTelemetry.Add("power limit") | Out-Null }
            if ($unavailableTelemetry.Count -gt 0) {
                $lines.Add("  - nvidia-smi unavailable in this sample: $($unavailableTelemetry -join ', ')")
            }
        }
    }
    if ($null -ne $snapshot.Battery) {
        $lines.Add("")
        $lines.Add("## Battery")
        $lines.Add("")
        $batteryDetails = @()
        if ($snapshot.Battery.Manufacturer) { $batteryDetails += $snapshot.Battery.Manufacturer }
        if ($snapshot.Battery.Chemistry) { $batteryDetails += $snapshot.Battery.Chemistry }
        if ($batteryDetails.Count -gt 0) {
            $lines.Add("- Battery: $(ConvertTo-SafeMarkdownText -Value ($batteryDetails -join ', '))")
        }
        if ($snapshot.Battery.DesignCapacityMWh -and
            $snapshot.Battery.FullChargeCapacityMWh) {
            $lines.Add(
                "- Capacity: design $($snapshot.Battery.DesignCapacityMWh) mWh; current full charge $($snapshot.Battery.FullChargeCapacityMWh) mWh")
        }
        if ($null -ne $snapshot.Battery.HealthPercent) {
            $lines.Add("- Health: $($snapshot.Battery.HealthPercent)%")
        }
        if ($null -ne $snapshot.Battery.CycleCount) {
            $lines.Add("- Cycle count: $($snapshot.Battery.CycleCount)")
        }
        if ($null -ne $snapshot.Battery.CurrentChargePercent) {
            $lines.Add("- Current charge: $($snapshot.Battery.CurrentChargePercent)%")
        }
        if ($snapshot.Battery.PowerState) {
            $lines.Add("- Power state: $(ConvertTo-SafeMarkdownText -Value $snapshot.Battery.PowerState)")
        }
    }
    elseif ($snapshot.CollectionStatus.Battery -ne "not-present") {
        $lines.Add("")
        $lines.Add("## Battery")
        $lines.Add("")
        $batteryUnavailableText = switch ($snapshot.CollectionStatus.Battery) {
            "unavailable-permission" { "Battery details are unavailable because the current process cannot read the battery report." }
            default { "Battery details are unavailable in the current environment." }
        }
        $batteryReasonText = if ($snapshot.CollectionStatus.BatteryStatusReason) {
            " Reason: $($snapshot.CollectionStatus.BatteryStatusReason)."
        }
        else {
            ""
        }
        $cimBatteryText = if ($snapshot.CollectionStatus.BatteryCimStatus) {
            " CIM battery status: $($snapshot.CollectionStatus.BatteryCimStatus)."
        }
        else {
            ""
        }
        $lines.Add("- $batteryUnavailableText$batteryReasonText$cimBatteryText")
    }
    $lines.Add("")
    $lines.Add("## Memory modules")
    $lines.Add("")
    if ($snapshot.MemoryModules.Count -eq 0) {
        $lines.Add("- Module-level memory inventory unavailable in this environment.")
        if ($snapshot.Computer.TotalPhysicalMemory) {
            $lines.Add("- Total physical memory is available through the OS fallback: $($snapshot.Computer.TotalPhysicalMemory).")
        }
        $lines.Add("- Enter module count, size, speed, and model manually if they affect compatibility or resale.")
    }
    foreach ($item in $snapshot.MemoryModules) {
        $details = @()
        if ($item.Capacity) { $details += $item.Capacity }
        if ($item.ConfiguredSpeedMTs) { $details += "$($item.ConfiguredSpeedMTs) MT/s configured" }
        if ($item.Manufacturer) { $details += $item.Manufacturer }
        if ($item.PartNumber) { $details += $item.PartNumber.Trim() }
        if ($item.Slot) { $details += $item.Slot }
        $lines.Add("- $(ConvertTo-SafeMarkdownText -Value ($details -join ', '))")
    }
    $lines.Add("")
    $lines.Add("## Reported physical disks")
    $lines.Add("")
    if ($snapshot.PhysicalDisks.Count -eq 0) {
        $lines.Add("- Physical disk model, interface, and health inventory unavailable in this environment.")
        $lines.Add("- Logical volume capacity and free space are listed separately below.")
    }
    foreach ($item in $snapshot.PhysicalDisks) {
        $details = @()
        if ($item.Model) { $details += $item.Model }
        if ($item.PSObject.Properties.Name -contains "DeviceNumber" -and $null -ne $item.DeviceNumber) {
            $details += "disk $($item.DeviceNumber)"
        }
        if ($item.Size) { $details += $item.Size }
        $displayInterface = if (
            $item.PSObject.Properties.Name -contains "StorageBusType" -and
            $item.StorageBusType
        ) {
            $item.StorageBusType
        }
        elseif ($item.Interface) {
            "$($item.Interface) (Windows-reported)"
        }
        else {
            $null
        }
        if ($displayInterface) { $details += "interface $displayInterface" }
        if ($item.PSObject.Properties.Name -contains "VolumeLetters" -and $item.VolumeLetters.Count -gt 0) {
            $details += "volumes $($item.VolumeLetters -join ', ')"
        }
        if ($item.Status) { $details += "status $($item.Status)" }
        if ($item.HealthStatus) { $details += "health $($item.HealthStatus)" }
        $lines.Add("- $(ConvertTo-SafeMarkdownText -Value ($details -join ', '))")
    }
    $lines.Add("")
    $lines.Add("## Volumes")
    $lines.Add("")
    if ($snapshot.Volumes.Count -eq 0) { $lines.Add("- Logical volume inventory unavailable in this environment.") }
    foreach ($item in $snapshot.Volumes) {
        $details = @("$($item.DriveLetter)")
        if ($item.Label) { $details += $item.Label }
        if ($item.Free -and $item.Size) { $details += "$($item.Free) free of $($item.Size)" }
        if ($item.FileSystem) { $details += $item.FileSystem }
        if ($item.PSObject.Properties.Name -contains "DiskNumber" -and $null -ne $item.DiskNumber) {
            $details += "disk $($item.DiskNumber), partition $($item.PartitionNumber)"
        }
        $lines.Add("- $(ConvertTo-SafeMarkdownText -Value ($details -join ', '))")
    }
    $lines.Add("")
    $lines.Add("## Monitors")
    $lines.Add("")
    if ($snapshot.Monitors.Count -eq 0) { $lines.Add("- Monitor EDID inventory unavailable in this environment.") }
    foreach ($item in $snapshot.Monitors) {
        $details = @()
        if ($item.Manufacturer) { $details += $item.Manufacturer }
        if ($item.Model) { $details += $item.Model }
        if ($item.ProductCode) { $details += "PnP ID $($item.ProductCode)" }
        if ($item.PSObject.Properties.Name -contains "AdapterName" -and $item.AdapterName) {
            $details += "adapter $($item.AdapterName)"
        }
        $details += "active: $($item.Active)"
        $lines.Add("- $(ConvertTo-SafeMarkdownText -Value ($details -join ', '))")

        if ($item.PSObject.Properties.Name -contains "CurrentWidth" -and
            $item.CurrentWidth -and
            $item.CurrentHeight) {
            $modeText = "$($item.CurrentWidth)x$($item.CurrentHeight)"
            if ($item.CurrentRefreshHz) {
                $modeText += " at $($item.CurrentRefreshHz) Hz"
            }
            $lines.Add("  - Current Windows mode: $modeText")
        }
        if ($item.PSObject.Properties.Name -contains "BitsPerPixel" -and
            $item.BitsPerPixel) {
            $lines.Add(
                "  - Framebuffer color depth: $($item.BitsPerPixel) bits per pixel; not GPU rendering precision or Windows architecture")
        }
        if ($item.PSObject.Properties.Name -contains "HdrStatus" -and
            $item.HdrStatus) {
            $lines.Add("  - HDR: $($item.HdrStatus)")
        }
        if ($item.PSObject.Properties.Name -contains "DisplayColorSpace" -and
            $item.DisplayColorSpace) {
            $lines.Add(
                "  - Display color space: $(ConvertTo-SafeMarkdownText -Value $item.DisplayColorSpace)")
        }
        if ($item.PSObject.Properties.Name -contains "AdvancedColorEnabled" -and
            $null -ne $item.AdvancedColorEnabled) {
            $advancedText = if ($item.AdvancedColorEnabled -eq $true) {
                "Enabled"
            }
            else {
                "Disabled"
            }
            $advancedDetails = @()
            if ($item.AdvancedColorBitsPerColorChannel) {
                $advancedDetails += "$($item.AdvancedColorBitsPerColorChannel) bits/color channel"
            }
            if ($item.AdvancedColorEncoding) {
                $advancedDetails += $item.AdvancedColorEncoding
            }
            if ($item.WideColorEnforced -eq $true) {
                $advancedDetails += "wide color enforced"
            }
            if ($advancedDetails.Count -gt 0) {
                $advancedText += " ($($advancedDetails -join ', '))"
            }
            $lines.Add("  - Advanced color pipeline: $(ConvertTo-SafeMarkdownText -Value $advancedText)")
        }
    }
    $lines.Add("")
    $lines.Add("## Not reliably detectable")
    $lines.Add("")
    foreach ($item in $snapshot.NotReliablyDetectable) {
        $lines.Add("- $item")
    }
    if ($snapshot.CollectionWarnings.Count -gt 0) {
        $lines.Add("")
        $lines.Add("## Collection warnings")
        $lines.Add("")

        $cimWarnings = @(
            $snapshot.CollectionWarnings |
                Where-Object { $_ -match "unavailable through CIM:" }
        )
        if ($cimWarnings.Count -gt 0) {
            $lines.Add("- CIM/WMI access was denied for $($cimWarnings.Count) class queries. Readable fallbacks were used where available; per-class details remain in JSON output.")
        }

        $storageWarnings = @(
            $snapshot.CollectionWarnings |
                Where-Object {
                    $_ -notmatch "unavailable through CIM:" -and
                    $_ -match "(?i)(Physical disk health|Storage health|SMART)"
                }
        )
        if ($storageWarnings.Count -gt 0) {
            $lines.Add("- Storage health and SMART detail are unavailable in the current environment; disk models and volume mapping remain available when readable.")
        }

        $otherWarnings = @(
            $snapshot.CollectionWarnings |
                Where-Object {
                    $_ -notmatch "unavailable through CIM:" -and
                    $_ -notmatch "(?i)(Physical disk health|Storage health|SMART)"
                }
        )
        foreach ($item in $otherWarnings) {
            $lines.Add("- $(ConvertTo-SafeMarkdownText -Value $item)")
        }
    }

    $rendered = $lines -join [Environment]::NewLine
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $rendered
}
else {
    Write-LocalOutputFile `
        -Path $OutputPath `
        -Content $rendered `
        -IncludeUtf8Bom:($Format -eq "Markdown") | Out-Null
    Write-Output "Hardware snapshot written to: $OutputPath"
}
