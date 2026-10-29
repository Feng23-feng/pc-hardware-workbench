[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SkillRoot,

    [switch]$AllowLiveCollector,

    [ValidateSet("Redacted", "Standard", "Both")]
    [string]$PrivacyMode = "Redacted"
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$resolvedRoot = (Resolve-Path -LiteralPath $SkillRoot).Path
$collectorPath = Join-Path $resolvedRoot "scripts\collect-windows.ps1"
$pathSafetyHelper = Join-Path $resolvedRoot "scripts\local-path-safety.ps1"
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
. $pathSafetyHelper

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message) | Out-Null
    }
}

function Get-ShapeSignature {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Path = '$'
    )

    $lines = New-Object System.Collections.Generic.List[string]
    function Add-ShapeNode {
        param(
            [AllowNull()]
            [object]$NodeValue,
            [string]$NodePath,
            [System.Collections.Generic.List[string]]$Lines
        )

        if ($null -eq $NodeValue) {
            $Lines.Add("$NodePath|<leaf>") | Out-Null
            return
        }
        if ($NodeValue -is [string] -or $NodeValue -is [System.ValueType]) {
            $Lines.Add("$NodePath|<leaf>") | Out-Null
            return
        }
        if ($NodeValue -is [System.Collections.IEnumerable]) {
            $items = @($NodeValue)
            $Lines.Add("$NodePath|<array:$($items.Count)>") | Out-Null
            for ($index = 0; $index -lt $items.Count; $index++) {
                Add-ShapeNode `
                    -NodeValue $items[$index] `
                    -NodePath "$NodePath[$index]" `
                    -Lines $Lines
            }
            return
        }

        $properties = @(
            $NodeValue.PSObject.Properties |
                Where-Object {
                    $_.MemberType -in @("Property", "NoteProperty", "AliasProperty")
                } |
                Sort-Object Name
        )
        $Lines.Add("$NodePath|<object>") | Out-Null
        foreach ($property in $properties) {
            Add-ShapeNode `
                -NodeValue $property.Value `
                -NodePath "$NodePath.$($property.Name)" `
                -Lines $Lines
        }
    }

    Add-ShapeNode -NodeValue $Value -NodePath $Path -Lines $lines
    return [string[]]$lines
}

function Invoke-Collector {
    param([string[]]$CollectorArguments)

    $output = & $powershell -NoProfile -ExecutionPolicy Bypass -File $collectorPath @CollectorArguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Collector failed with exit code $LASTEXITCODE. $($output -join [Environment]::NewLine)"
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
}

function Test-CollectorOutputPathGuards {
    $pathGuardRoot = Join-Path ([IO.Path]::GetTempPath()) ("pcwb-output-guard-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $pathGuardRoot -Force | Out-Null
    try {
        $existingOutput = Join-Path $pathGuardRoot "existing.md"
        [IO.File]::WriteAllText($existingOutput, "keep", (New-Object System.Text.UTF8Encoding($false)))
        try {
            Resolve-LocalOutputFilePath -Path $existingOutput | Out-Null
            $overwriteRejected = $false
        }
        catch {
            $overwriteRejected = $_.Exception.Message -match "will not be overwritten"
        }
        Assert-True $overwriteRejected "Collector output helper accepted an existing output file."

        try {
            Resolve-LocalOutputFilePath -Path '\\server\share\hardware.json' | Out-Null
            $uncRejected = $false
        }
        catch {
            $uncRejected = $_.Exception.Message -match "UNC and network paths are rejected"
        }
        Assert-True $uncRejected "Collector output helper accepted a UNC output path."

        $newOutput = Join-Path $pathGuardRoot "new.md"
        $writtenPath = Write-LocalOutputFile -Path $newOutput -Content "snapshot"
        Assert-True ((Test-Path -LiteralPath $writtenPath -PathType Leaf) -and (Get-Content -Raw -LiteralPath $writtenPath) -eq "snapshot") "Collector output helper did not create a readable local report."
        $writtenBytes = [IO.File]::ReadAllBytes($writtenPath)
        Assert-True (
            $writtenBytes.Length -lt 3 -or
            $writtenBytes[0] -ne 0xEF -or
            $writtenBytes[1] -ne 0xBB -or
            $writtenBytes[2] -ne 0xBF
        ) "BOM-less output mode unexpectedly wrote a UTF-8 BOM."
        $bomOutput = Join-Path $pathGuardRoot "new-bom.md"
        $bomContent = [string]([char]0x4E2D) + [string]([char]0x6587) +
            [string]([char]0x62A5) + [string]([char]0x544A)
        $bomPath = Write-LocalOutputFile -Path $bomOutput -Content $bomContent -IncludeUtf8Bom
        $bomBytes = [IO.File]::ReadAllBytes($bomPath)
        Assert-True (
            $bomBytes.Length -ge 3 -and
            $bomBytes[0] -eq 0xEF -and
            $bomBytes[1] -eq 0xBB -and
            $bomBytes[2] -eq 0xBF
        ) "Text output mode did not write a UTF-8 BOM."
        try {
            Write-LocalOutputFile -Path $newOutput -Content "replacement" | Out-Null
            $secondWriteRejected = $false
        }
        catch {
            $secondWriteRejected = $_.Exception.Message -match "will not be overwritten"
        }
        Assert-True $secondWriteRejected "Collector output helper allowed a second write to the same path."

        $junctionTarget = Join-Path $pathGuardRoot "junction-target"
        $junctionPath = Join-Path $pathGuardRoot "junction-link"
        New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
        New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null
        $junctionInput = Join-Path $junctionPath "telemetry.csv"
        [IO.File]::WriteAllText($junctionInput, "header", (New-Object System.Text.UTF8Encoding($false)))
        try {
            Assert-LocalReadFilePath -Path $junctionInput | Out-Null
            $junctionReadRejected = $false
        }
        catch {
            $junctionReadRejected = $_.Exception.Message -match "symbolic link, junction, or reparse point"
        }
        Assert-True $junctionReadRejected "Telemetry input helper followed a directory junction."

        $junctionOutput = Join-Path $junctionPath "report.md"
        try {
            Resolve-LocalOutputFilePath -Path $junctionOutput | Out-Null
            $junctionOutputRejected = $false
        }
        catch {
            $junctionOutputRejected = $_.Exception.Message -match "symbolic link, junction, or reparse point"
        }
        Assert-True $junctionOutputRejected "Collector output helper followed a directory junction."
    }
    finally {
        if (Test-Path -LiteralPath $pathGuardRoot) {
            Remove-Item -LiteralPath $pathGuardRoot -Recurse -Force
        }
    }
}

foreach ($relative in @(
    "scripts/collect-windows.ps1",
    "scripts/device-identity.ps1",
    "scripts/inventory-context.ps1",
    "scripts/local-path-safety.ps1",
    "scripts/system-native.cs",
    "scripts/storage-native.cs",
    "scripts/display-native.cs"
)) {
    Assert-True (Test-Path -LiteralPath (Join-Path $resolvedRoot $relative) -PathType Leaf) "Collector dependency is missing: $relative"
}
if ($failures.Count -gt 0) {
    Write-Host "Collector static/path tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Test-CollectorOutputPathGuards
if ($failures.Count -gt 0) {
    Write-Host "Collector output-path guards: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}
Write-Host "Collector static/path tests: PASS" -ForegroundColor Green

if (-not $AllowLiveCollector) {
    Write-Host "Collector live smoke: SKIP (pass -AllowLiveCollector and choose -PrivacyMode Redacted|Standard|Both)" -ForegroundColor Yellow
    exit 0
}

try {
    $allowedIdentityStatuses = @("readable", "suspicious", "partial", "unreadable", "unknown", "redacted")
    $runStandard = $PrivacyMode -in @("Standard", "Both")
    $runRedacted = $PrivacyMode -in @("Redacted", "Both")

    if ($runStandard) {
        $standardJsonText = Invoke-Collector -CollectorArguments @("-Format", "Json")
        $standard = $standardJsonText | ConvertFrom-Json
        Assert-True ($standard.SchemaVersion -eq 3) "The standard JSON snapshot has an unexpected schema version."
        Assert-True ($standard.CollectorVersion -eq "1.0.1-r18") "The standard JSON snapshot reports an unexpected collector version."
        Assert-True ($standard.PrivacyMode -eq "Standard") "Standard collection did not report Standard privacy mode."
        Assert-True ($null -ne $standard.IdentityQuality) "The standard JSON snapshot omits IdentityQuality."
        Assert-True ($null -ne $standard.CollectionContext) "The standard JSON snapshot omits CollectionContext."
        Assert-True ($standard.CollectionContext.ProcessClass -in @("standard-user", "restricted-agent", "elevated-user")) "The standard JSON snapshot has an invalid process class."
        Assert-True ($standard.CollectionStatus.Battery -in @("available", "not-present", "unavailable-permission", "unavailable")) "The standard JSON snapshot has an invalid battery collection status."
        Assert-True (-not [string]::IsNullOrWhiteSpace($standard.CollectionStatus.BatteryStatusReason)) "The standard JSON snapshot omits the battery status reason."
        Assert-True ($standard.CollectionStatus.BatteryCimStatus -in @("available", "unavailable-permission", "unavailable")) "The standard JSON snapshot has an invalid CIM battery status."
        Assert-True ($standard.IdentityQuality.Status -in $allowedIdentityStatuses) "The standard JSON snapshot returned an unknown IdentityQuality status."
        Assert-True ($null -ne $standard.Computer) "The standard JSON snapshot omits computer identity."
        Assert-True ($null -ne $standard.OperatingSystem) "The standard JSON snapshot omits operating-system data."
        Assert-True ($standard.OperatingSystem.Caption -match "Windows 1[01]") "The standard JSON snapshot has no credible Windows caption."
        Assert-True ($null -ne $standard.PSObject.Properties["CPU"]) "The standard JSON snapshot omits the CPU field."
        Assert-True ($null -ne $standard.PSObject.Properties["GPU"]) "The standard JSON snapshot omits the GPU field."
        Assert-True ($null -ne $standard.PSObject.Properties["PhysicalDisks"]) "The standard JSON snapshot omits physical disks."
        Assert-True ($null -ne $standard.PSObject.Properties["Volumes"]) "The standard JSON snapshot omits volumes."

        $markdown = Invoke-Collector -CollectorArguments @("-Format", "Markdown")
        Assert-True ($markdown -match "(?m)^# Hardware snapshot\r?$") "Markdown output has no snapshot heading."
        Assert-True ($markdown -match "(?m)^- Identity quality: ") "Markdown output omits identity quality."
        Assert-True ($markdown -match "(?m)^## CPU\r?$") "Markdown output omits the CPU section."
        Assert-True ($markdown -match "(?m)^## Reported GPUs\r?$") "Markdown output omits the reported-GPU section."
        Assert-True ($markdown -match "(?m)^## Memory modules\r?$") "Markdown output omits the memory section."
        Assert-True ($markdown -match "(?m)^## Reported physical disks\r?$") "Markdown output omits the disk section."
        $identityMarkdownLines = @($markdown -split "\r?\n" | Where-Object { $_ -match "^- (Manufacturer|Model|System family): " })
        Assert-True ($identityMarkdownLines.Count -gt 0) "Markdown output omits all identity display lines."
        foreach ($identityLine in $identityMarkdownLines) {
            Assert-True ($identityLine.Contains(": " + [string][char]0x60)) "A Markdown identity line is not isolated in inline code."
        }
    }

    if ($runRedacted) {
        $redactedJsonText = Invoke-Collector -CollectorArguments @("-Format", "Json", "-RedactIdentifiers")
        $redacted = $redactedJsonText | ConvertFrom-Json
        Assert-True ($redacted.SchemaVersion -eq 3) "The redacted JSON snapshot has an unexpected schema version."
        Assert-True ($redacted.CollectorVersion -eq "1.0.1-r18") "The redacted JSON snapshot reports an unexpected collector version."
        Assert-True ($redacted.PrivacyMode -eq "Redacted identifiers") "Redacted collection did not report Redacted identifiers."
        Assert-True ($redacted.IdentityQuality.Status -eq "redacted") "Redacted collection did not mark IdentityQuality as redacted."
        Assert-True ($null -ne $redacted.CollectionContext) "The redacted JSON snapshot omits CollectionContext."
        Assert-True (-not [string]::IsNullOrWhiteSpace($redacted.CollectionStatus.BatteryStatusReason)) "The redacted JSON snapshot omits the battery status reason."
        Assert-True ($redacted.Computer.Manufacturer -eq "[redacted]") "Redacted collection retained the computer manufacturer."
        Assert-True ($redacted.Computer.Model -eq "[redacted]") "Redacted collection retained the computer model."
        Assert-True ($redacted.Motherboard.Manufacturer -eq "[redacted]") "Redacted collection retained the motherboard manufacturer."
        Assert-True ($redacted.Motherboard.Product -eq "[redacted]") "Redacted collection retained the motherboard product."
        Assert-True ($redacted.Firmware.Manufacturer -eq "[redacted]") "Redacted collection retained the BIOS manufacturer."
        Assert-True ($redacted.Firmware.Version -eq "[redacted]") "Redacted collection retained the BIOS version."

        if ($runStandard) {
            $standardKeys = @($standard.PSObject.Properties.Name | Sort-Object)
            $redactedKeys = @($redacted.PSObject.Properties.Name | Sort-Object)
            $keyDifferences = @(Compare-Object -ReferenceObject $standardKeys -DifferenceObject $redactedKeys)
            Assert-True ($keyDifferences.Count -eq 0) "Standard and redacted snapshots expose different top-level keys."

            $shapeRoots = @(
                "Computer",
                "OperatingSystem",
                "Firmware",
                "Motherboard",
                "Battery",
                "CPU",
                "GPU",
                "MemoryModules",
                "PhysicalDisks",
                "Volumes",
                "Monitors",
                "CollectionContext",
                "CollectionStatus"
            )
            foreach ($rootName in $shapeRoots) {
                $standardRoot = $standard.PSObject.Properties[$rootName].Value
                $redactedRoot = $redacted.PSObject.Properties[$rootName].Value
                $standardShape = Get-ShapeSignature -Value $standardRoot -Path ('$.' + $rootName)
                $redactedShape = Get-ShapeSignature -Value $redactedRoot -Path ('$.' + $rootName)
                $shapeDifferences = @(Compare-Object -ReferenceObject $standardShape -DifferenceObject $redactedShape)
                Assert-True ($shapeDifferences.Count -eq 0) "Redaction changed keys, field types, or array lengths under $rootName."
            }

            $redactionChecks = @(
                @{ Name = "Computer.Manufacturer"; Value = $redacted.Computer.Manufacturer },
                @{ Name = "Computer.ManufacturerDisplay"; Value = $redacted.Computer.ManufacturerDisplay },
                @{ Name = "Computer.Model"; Value = $redacted.Computer.Model },
                @{ Name = "Computer.ModelDisplay"; Value = $redacted.Computer.ModelDisplay },
                @{ Name = "Computer.SystemFamily"; Value = $redacted.Computer.SystemFamily },
                @{ Name = "Computer.SystemFamilyDisplay"; Value = $redacted.Computer.SystemFamilyDisplay },
                @{ Name = "Computer.ProductVendor"; Value = $redacted.Computer.ProductVendor },
                @{ Name = "Computer.ProductName"; Value = $redacted.Computer.ProductName },
                @{ Name = "Computer.ProductVersion"; Value = $redacted.Computer.ProductVersion },
                @{ Name = "Motherboard.Manufacturer"; Value = $redacted.Motherboard.Manufacturer },
                @{ Name = "Motherboard.ManufacturerDisplay"; Value = $redacted.Motherboard.ManufacturerDisplay },
                @{ Name = "Motherboard.Product"; Value = $redacted.Motherboard.Product },
                @{ Name = "Motherboard.ProductDisplay"; Value = $redacted.Motherboard.ProductDisplay },
                @{ Name = "Motherboard.Version"; Value = $redacted.Motherboard.Version },
                @{ Name = "Firmware.Manufacturer"; Value = $redacted.Firmware.Manufacturer },
                @{ Name = "Firmware.Version"; Value = $redacted.Firmware.Version },
                @{ Name = "Firmware.ReleaseDate"; Value = $redacted.Firmware.ReleaseDate }
            )
            foreach ($check in $redactionChecks) {
                Assert-True ([string]$check.Value -ceq "[redacted]") "Redaction did not replace $($check.Name) exactly."
            }

            $redactedMemory = @($redacted.MemoryModules)
            for ($index = 0; $index -lt $redactedMemory.Count; $index++) {
                $module = $redactedMemory[$index]
                $standardModule = $standard.MemoryModules[$index]
                $expectedManufacturer = if ([string]::IsNullOrWhiteSpace([string]$standardModule.Manufacturer)) { $standardModule.Manufacturer } else { "[redacted]" }
                $expectedPartNumber = if ([string]::IsNullOrWhiteSpace([string]$standardModule.PartNumber)) { $standardModule.PartNumber } else { "[redacted]" }
                Assert-True ($module.Manufacturer -ceq $expectedManufacturer) "Redacted memory module $index did not preserve emptiness or hide its manufacturer."
                Assert-True ($module.PartNumber -ceq $expectedPartNumber) "Redacted memory module $index did not preserve emptiness or hide its part number."
                Assert-True ($module.Slot -eq $standardModule.Slot) "Redaction changed memory channel/slot evidence at module $index."
                Assert-True ($module.Bank -eq $standardModule.Bank) "Redaction changed memory bank/channel evidence at module $index."
                Assert-True ($module.CapacityBytes -eq $standardModule.CapacityBytes) "Redaction changed memory capacity at module $index."
            }

            $redactedDisks = @($redacted.PhysicalDisks)
            for ($index = 0; $index -lt $redactedDisks.Count; $index++) {
                $disk = $redactedDisks[$index]
                $standardDisk = $standard.PhysicalDisks[$index]
                $expectedDiskNumber = if ($null -ne $disk.DeviceNumber) { $disk.DeviceNumber } else { $index }
                $expectedDiskModel = if ([string]::IsNullOrWhiteSpace([string]$standardDisk.Model)) { $standardDisk.Model } else { "Physical disk $expectedDiskNumber (redacted model)" }
                $expectedRevision = if ([string]::IsNullOrWhiteSpace([string]$standardDisk.ProductRevision)) { $standardDisk.ProductRevision } else { "[redacted]" }
                Assert-True ($disk.Model -eq $expectedDiskModel) "Redacted disk $index did not preserve emptiness or use its DeviceNumber placeholder."
                Assert-True ($disk.ProductRevision -ceq $expectedRevision) "Redacted disk $index did not preserve emptiness or hide its firmware revision."
                Assert-True ($disk.DeviceNumber -eq $standardDisk.DeviceNumber) "Redaction changed disk DeviceNumber at index $index."
                Assert-True ($disk.Interface -eq $standardDisk.Interface) "Redaction changed disk interface at index $index."
            }

            $redactedVolumes = @($redacted.Volumes)
            for ($index = 0; $index -lt $redactedVolumes.Count; $index++) {
                $volume = $redactedVolumes[$index]
                $standardVolume = $standard.Volumes[$index]
                $standardLabel = ([string]$standardVolume.Label).Trim()
                $isGenericLabel = $standardLabel -match '^(?i:Windows|Local Disk|System Reserved|New Volume|\u672C\u5730\u78C1\u76D8|\u65B0\u52A0\u5377|\u7CFB\u7EDF\u4FDD\u7559)$'
                $expectedLabel = if ([string]::IsNullOrWhiteSpace($standardLabel) -or $isGenericLabel) { $standardVolume.Label } else { "[redacted]" }
                $expectedPhysicalDisk = if ([string]::IsNullOrWhiteSpace([string]$standardVolume.PhysicalDisk)) {
                    $standardVolume.PhysicalDisk
                }
                elseif ($null -ne $standardVolume.DiskNumber) {
                    "Physical disk $($standardVolume.DiskNumber) (redacted model)"
                }
                else {
                    "[redacted]"
                }
                Assert-True ($volume.Label -ceq $expectedLabel) "Redacted volume $index did not preserve emptiness or hide its label."
                Assert-True ($volume.PhysicalDisk -ceq $expectedPhysicalDisk) "Redacted volume $index did not preserve its disk correlation."
                Assert-True ($volume.DriveLetter -eq $standardVolume.DriveLetter) "Redaction changed volume drive letter at index $index."
                Assert-True ($volume.DiskNumber -eq $standardVolume.DiskNumber) "Redaction changed volume disk mapping at index $index."
                Assert-True ($volume.PartitionNumber -eq $standardVolume.PartitionNumber) "Redaction changed volume partition mapping at index $index."
            }

            $redactedMonitors = @($redacted.Monitors)
            $redactedGpuNames = @($redacted.GPU | ForEach-Object { [string]$_.Name })
            for ($index = 0; $index -lt $redactedMonitors.Count; $index++) {
                $monitor = $redactedMonitors[$index]
                $standardMonitor = $standard.Monitors[$index]
                $expectedManufacturer = if ([string]::IsNullOrWhiteSpace([string]$standardMonitor.Manufacturer)) { $standardMonitor.Manufacturer } else { "[redacted]" }
                $expectedProductCode = if ([string]::IsNullOrWhiteSpace([string]$standardMonitor.ProductCode)) { $standardMonitor.ProductCode } else { "[redacted]" }
                $standardModel = ([string]$standardMonitor.Model).Trim()
                $isGenericModel = $standardModel -match '^(?i:Generic PnP Monitor|Generic Monitor|Default Monitor|\u901A\u7528\u5373\u63D2\u5373\u7528\u76D1\u89C6\u5668|\u9ED8\u8BA4\u76D1\u89C6\u5668)$'
                $expectedModel = if ([string]::IsNullOrWhiteSpace($standardModel) -or $isGenericModel) { $standardMonitor.Model } else { "Display $($index + 1) (redacted model)" }
                Assert-True ($monitor.Manufacturer -ceq $expectedManufacturer) "Redacted monitor $index did not preserve emptiness or hide its manufacturer."
                Assert-True ($monitor.ProductCode -ceq $expectedProductCode) "Redacted monitor $index did not preserve emptiness or hide its PnP identifier."
                Assert-True ($monitor.Model -eq $expectedModel) "Redacted monitor $index did not preserve emptiness or use its stable placeholder."
                Assert-True (-not [string]::IsNullOrWhiteSpace([string]$monitor.AdapterName)) "Redacted monitor $index lost its adapter identity."
                Assert-True ($monitor.AdapterName -cne "[redacted]") "Redacted monitor $index hid the adapter name that GPU identity preserves."
                Assert-True ($redactedGpuNames -contains [string]$monitor.AdapterName) "Redacted monitor $index adapter name no longer matches a declared GPU."
                Assert-True ($monitor.AdapterName -eq $standardMonitor.AdapterName) "Redaction changed monitor adapter name at index $index."
                Assert-True ($monitor.CurrentWidth -eq $standardMonitor.CurrentWidth) "Redaction changed current display width at index $index."
                Assert-True ($monitor.HdrEnabled -eq $standardMonitor.HdrEnabled) "Redaction changed HDR state at index $index."
            }

            if ($null -ne $redacted.Battery) {
                if ($null -ne $standard.Battery) {
                    $expectedBatteryManufacturer = if ([string]::IsNullOrWhiteSpace([string]$standard.Battery.Manufacturer)) { $standard.Battery.Manufacturer } else { "[redacted]" }
                    Assert-True ($redacted.Battery.Manufacturer -ceq $expectedBatteryManufacturer) "Redacted battery did not preserve emptiness or hide its manufacturer."
                    Assert-True ($redacted.Battery.HealthPercent -eq $standard.Battery.HealthPercent) "Redaction changed battery health."
                    Assert-True ($redacted.Battery.DesignCapacityMWh -eq $standard.Battery.DesignCapacityMWh) "Redaction changed battery design capacity."
                }
            }

            Assert-True ($redacted.IdentityQuality.Status -eq "redacted") "Redacted identity quality is not the intentional redacted state."
            Assert-True ($redacted.IdentityQuality.Fields -is [System.Collections.IEnumerable]) "Redacted identity quality lost its field shape."
            $identityIssues = @(
                $redacted.IdentityQuality.Fields |
                    ForEach-Object { @($_.Issues).Count } |
                    Measure-Object -Sum
            )
            Assert-True ($identityIssues[0].Sum -eq 0) "Redacted identity quality did not intentionally suppress identity issues."
            Assert-True (-not (@($redacted.CollectionWarningCodes) -contains "identity-quality-unconfirmed")) "Redacted collection emitted the suppressed identity-quality warning."
        }

        $redactedMarkdown = Invoke-Collector -CollectorArguments @("-Format", "Markdown", "-RedactIdentifiers")
        Assert-True ($redactedMarkdown -match "(?m)^- Identity quality: redacted\r?$") "Redacted Markdown did not report redacted identity quality."
        Assert-True ($redactedMarkdown -match '(?m)^- Model: `[^`]*\[redacted\][^`]*`\r?$') "Redacted Markdown did not isolate the withheld model in inline code."
        Assert-True ($redactedMarkdown -match '(?m)^- Motherboard: `[^`]*\[redacted\][^`]*` `[^`]*\[redacted\][^`]*`\r?$') "Redacted Markdown did not isolate withheld motherboard fields in inline code."
    }
}
catch {
    $failures.Add($_.Exception.Message) | Out-Null
}

if ($failures.Count -gt 0) {
    Write-Host "Collector smoke tests: FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "- $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Collector live smoke tests: PASS" -ForegroundColor Green
