[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "lib\Common.ps1")

$evidence = Get-EvidenceRoot
$archive = Assert-ArchiveIdentity
$os = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem

$edgeCandidates = @(
    "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    "C:\Program Files\Microsoft\Edge\Application\msedge.exe"
)
$edgePath = $edgeCandidates |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
$edgeVersion = if ($edgePath) {
    (Get-Item -LiteralPath $edgePath).VersionInfo.ProductVersion
}
else {
    "not-found"
}

$codexProcesses = @(
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match "^Codex" } |
        ForEach-Object {
            [ordered]@{
                name = $_.ProcessName
                pid = $_.Id
                path = if ($_.Path) { [string]$_.Path } else { "" }
            }
        }
)
$codexPackages = @(
    Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "Codex|OpenAI" } |
        ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                version = [string]$_.Version
                install_location = [string]$_.InstallLocation
            }
        }
)

$runtimePointerPath = Join-Path `
    $env:LOCALAPPDATA `
    "SkillDock\runtime-location.json"
$runtimePointer = $null
$runtimeServerInfo = $null
if (Test-Path -LiteralPath $runtimePointerPath -PathType Leaf) {
    $runtimePointer = Get-Content -Raw -LiteralPath $runtimePointerPath |
        ConvertFrom-Json
    $serverInfoPath = Join-Path `
        $env:LOCALAPPDATA `
        "SkillDock\runtime-pchw\server-info.json"
    if (Test-Path -LiteralPath $serverInfoPath -PathType Leaf) {
        $runtimeServerInfo = Get-Content `
            -Raw `
            -LiteralPath $serverInfoPath |
            ConvertFrom-Json
    }
}

$installedSkillRoot = Join-Path `
    $env:USERPROFILE `
    ".codex\skills\pc-hardware-workbench"
$installInfo = $null
if (Test-Path -LiteralPath (
    Join-Path $installedSkillRoot "INSTALL-INFO.json"
) -PathType Leaf) {
    $installInfo = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $installedSkillRoot "INSTALL-INFO.json") |
        ConvertFrom-Json
}

$processRows = @(
    Get-CimInstance Win32_Process |
        Where-Object { $_.Name -in @("node.exe", "SkillDock.exe") } |
        ForEach-Object {
            [ordered]@{
                name = [string]$_.Name
                pid = [int]$_.ProcessId
                parent_pid = [int]$_.ParentProcessId
                command_line = [string]$_.CommandLine
            }
        }
)

$imageFiles = @(
    Get-ChildItem `
        -LiteralPath $evidence `
        -File `
        -Recurse |
        Where-Object { $_.Extension -match "^\.(png|jpg|jpeg|webp)$" } |
        ForEach-Object {
            [ordered]@{
                name = $_.FullName.Substring($evidence.Length + 1)
                bytes = $_.Length
                sha256 = Get-Sha256Hex -Path $_.FullName
            }
        }
)

$result = [ordered]@{
    schema_version = "1.0"
    status = "collected"
    collected_at = [DateTimeOffset]::Now.ToString("o")
    user_profile = $env:USERPROFILE
    local_app_data = $env:LOCALAPPDATA
    computer_name = [string]$computer.Name
    os = [ordered]@{
        caption = [string]$os.Caption
        version = [string]$os.Version
        build = [int]$os.BuildNumber
        architecture = [string]$os.OSArchitecture
    }
    edge = [ordered]@{
        path = $edgePath
        version = $edgeVersion
    }
    codex_processes = $codexProcesses
    codex_packages = $codexPackages
    archive = $archive
    installed_skill = [ordered]@{
        path = $installedSkillRoot
        exists = Test-Path -LiteralPath $installedSkillRoot
        install_info = $installInfo
    }
    runtime = [ordered]@{
        pointer_path = $runtimePointerPath
        pointer_exists = Test-Path -LiteralPath $runtimePointerPath
        pointer = $runtimePointer
        server_info = $runtimeServerInfo
    }
    processes = $processRows
    screenshots = $imageFiles
}

Write-Utf8Text `
    -Path (Join-Path $evidence "02-environment.json") `
    -Text (($result | ConvertTo-Json -Depth 10) + "`n")
$processLines = $processRows | ForEach-Object {
    "$($_.pid)`t$($_.parent_pid)`t$($_.name)`t$($_.command_line)"
}
Write-Utf8Text `
    -Path (Join-Path $evidence "02-processes.txt") `
    -Text (($processLines -join "`n") + "`n")

$evidenceFiles = @(
    Get-ChildItem -LiteralPath $evidence -File -Recurse |
        Where-Object { $_.Name -ne "02-FILE-INDEX.sha256" } |
        Sort-Object FullName
)
$indexLines = foreach ($file in $evidenceFiles) {
    $relative = $file.FullName.Substring($evidence.Length + 1).
        Replace("\", "/")
    "$(Get-Sha256Hex -Path $file.FullName)  $relative"
}
Write-Utf8Text `
    -Path (Join-Path $evidence "02-FILE-INDEX.sha256") `
    -Text (($indexLines -join "`n") + "`n")

Write-Host "Environment evidence collected." -ForegroundColor Green
Write-Host "Screenshot count: $($imageFiles.Count)"
Write-Host "Evidence directory: $evidence"
