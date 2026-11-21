[CmdletBinding()]
param(
    [switch]$NoWrite,

    [switch]$AllowExistingInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")
$packageBaseName = $script:PackageBaseName

function Get-EdgeExecutable {
    $candidates = @(
        "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
    )
    return $candidates |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
}

$evidence = Get-EvidenceRoot
$preflightLog = Join-Path $evidence "00-preflight.log"
if (-not $NoWrite) {
    Write-Utf8Text `
        -Path $preflightLog `
        -Text "SkillDock clean-Windows preflight`n"
}

$checks = New-Object System.Collections.Generic.List[object]
function Add-Check {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $item = [pscustomobject]@{
        name = $Name
        passed = $Passed
        detail = $Detail
    }
    $checks.Add($item) | Out-Null
    $label = if ($Passed) { "PASS" } else { "FAIL" }
    $line = "[$label] $Name - $Detail"
    Write-Host $line
    if (-not $NoWrite) {
        Append-Utf8Text -Path $preflightLog -Text ($line + "`n")
    }
    if (-not $Passed) {
        throw $Detail
    }
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $computer = Get-CimInstance Win32_ComputerSystem
    $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    $isX64 = (
        [Environment]::Is64BitOperatingSystem -and
        [int]$processor.AddressWidth -eq 64 -and
        $processor.Architecture -eq 9
    )
    Add-Check `
        -Name "Windows x64" `
        -Passed $isX64 `
        -Detail (
            "$($os.Caption), build $($os.BuildNumber), " +
            "architecture $($os.OSArchitecture), " +
            "processor $($processor.Name)"
        )

    $isWindows11 = [int]$os.BuildNumber -ge 22000
    Add-Check `
        -Name "Windows 11" `
        -Passed $isWindows11 `
        -Detail "OS build $($os.BuildNumber); expected 22000 or newer."

    $archive = Assert-ArchiveIdentity
    Add-Check `
        -Name "Archive SHA-256" `
        -Passed $true `
        -Detail "$($archive.sha256), $($archive.bytes) bytes"

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive.archive)
    try {
        $topLevel = New-Object System.Collections.Generic.HashSet[string]
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName.Replace("\", "/")
            if (
                [IO.Path]::IsPathRooted($name) -or
                ($name.Split("/") -contains "..")
            ) {
                throw "Archive contains an unsafe path: $name"
            }
            $segment = $name.Split("/")[0]
            if (-not [string]::IsNullOrWhiteSpace($segment)) {
                [void]$topLevel.Add($segment)
            }
        }
        $topLevelList = @($topLevel)
        $archiveLayoutOk = (
            $topLevelList.Count -eq 1 -and
            $topLevelList[0] -eq $packageBaseName
        )
        Add-Check `
            -Name "Archive layout" `
            -Passed $archiveLayoutOk `
            -Detail ("top-level: " + ($topLevelList -join ", "))
    }
    finally {
        $zip.Dispose()
    }

    $installedSkill = Join-Path `
        $env:USERPROFILE `
        ".codex\skills\pc-hardware-workbench"
    $skilldockRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
    $skilldockBackups = Join-Path $env:LOCALAPPDATA "SkillDockBackups"
    $existing = @(
        $installedSkill,
        $skilldockRoot,
        $skilldockBackups
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $localRuntimeDirs = @(
        Get-ChildItem `
            -LiteralPath $env:LOCALAPPDATA `
            -Directory `
            -Filter "Runtime-*" `
            -ErrorAction SilentlyContinue |
            Where-Object {
                Test-Path -LiteralPath (
                    Join-Path $_.FullName "SkillDock.exe"
                ) -PathType Leaf
            }
    )
    $runtimeDirPaths = @(
        $localRuntimeDirs | ForEach-Object { $_.FullName }
    )
    $allExistingPaths = @($existing) + $runtimeDirPaths
    $cleanProfile = (
        $allExistingPaths.Count -eq 0
    )
    $cleanDetail = if ($cleanProfile) {
        "No existing PCHW Skill or SkillDock Runtime was found."
    }
    else {
        "Existing paths: " + ($allExistingPaths -join "; ")
    }
    Add-Check `
        -Name "Profile install policy" `
        -Passed ($cleanProfile -or $AllowExistingInstall) `
        -Detail $(if ($AllowExistingInstall) {
            "Existing installs allowed for upgrade. $cleanDetail"
        }
        else {
            $cleanDetail
        })

    $edge = Get-EdgeExecutable
    Add-Check `
        -Name "Microsoft Edge" `
        -Passed (-not [string]::IsNullOrWhiteSpace($edge)) `
        -Detail $(if ($edge) { $edge } else { "Edge executable not found." })

    $result = [ordered]@{
        schema_version = "1.0"
        status = "passed"
        checked_at = [DateTimeOffset]::Now.ToString("o")
        user_profile = $env:USERPROFILE
        local_app_data = $env:LOCALAPPDATA
        computer_name = $computer.Name
        os = [ordered]@{
            caption = [string]$os.Caption
            version = [string]$os.Version
            build = [int]$os.BuildNumber
            architecture = [string]$os.OSArchitecture
        }
        processor = [string]$processor.Name
        archive = $archive
        edge = $edge
        existing_paths = $allExistingPaths
        clean_profile = $cleanProfile
        existing_install_allowed = [bool]$AllowExistingInstall
        checks = $checks.ToArray()
    }
    $json = $result | ConvertTo-Json -Depth 8
    if (-not $NoWrite) {
        Write-Utf8Text `
            -Path (Join-Path $evidence "00-preflight.json") `
            -Text ($json + "`n")
        Append-Utf8Text -Path $preflightLog -Text "PREFLIGHT PASSED`n"
    }
    $json
}
catch {
    $failure = [ordered]@{
        schema_version = "1.0"
        status = "failed"
        checked_at = [DateTimeOffset]::Now.ToString("o")
        error = $_.Exception.Message
        user_profile = $env:USERPROFILE
        checks = $checks.ToArray()
    } | ConvertTo-Json -Depth 8
    if (-not $NoWrite) {
        Write-Utf8Text `
            -Path (Join-Path $evidence "00-preflight.json") `
            -Text ($failure + "`n")
        Append-Utf8Text `
            -Path $preflightLog `
            -Text ("PREFLIGHT FAILED: " + $_.Exception.Message + "`n")
    }
    throw
}
