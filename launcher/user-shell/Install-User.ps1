[CmdletBinding()]
param(
    [switch]$PreflightOnly,

    [string]$SkillsRoot = "",

    [string]$LocalRoot = "",

    [string]$BackupRoot = "",

    [string]$DataBackupRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$payloadRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd("\")
$packageInfoPath = Join-Path $payloadRoot "PACKAGE-INFO.json"
$manifestPath = Join-Path $payloadRoot "BUNDLE-MANIFEST.sha256"

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).
        Hash.ToLowerInvariant()
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Text, $encoding)
}

function Append-Utf8Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($Path, $Text, $encoding)
}

function Assert-PayloadManifest {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Installation payload manifest is missing."
    }
    $described = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $manifestPath)) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            throw "Installation payload manifest is malformed."
        }
        $expected = $Matches[1]
        $relativePath = $Matches[2]
        if (
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Split("/") -contains ".."
        ) {
            throw "Installation payload contains an unsafe manifest path."
        }
        $path = Join-Path $payloadRoot $relativePath.Replace("/", "\")
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Installation payload file is missing: $relativePath"
        }
        if ((Get-FileSha256 -Path $path) -ne $expected) {
            throw "Installation payload file hash mismatch: $relativePath"
        }
        $described.Add($relativePath) | Out-Null
    }

    $actual = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force
    )) {
        $relativePath = $file.FullName.Substring(
            $payloadRoot.Length + 1
        ).Replace("\", "/")
        if ($relativePath -ceq "BUNDLE-MANIFEST.sha256") {
            continue
        }
        $actual.Add($relativePath) | Out-Null
    }
    $describedSorted = [string[]]$described.ToArray()
    $actualSorted = [string[]]$actual.ToArray()
    [Array]::Sort($describedSorted, [StringComparer]::Ordinal)
    [Array]::Sort($actualSorted, [StringComparer]::Ordinal)
    if (
        @(Compare-Object `
            -ReferenceObject $describedSorted `
            -DifferenceObject $actualSorted `
            -CaseSensitive).Count -ne 0
    ) {
        throw "Installation payload manifest does not describe the complete payload."
    }
}

function Assert-RcPackageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $rcManifestPath = Join-Path $PackageRoot "MANIFEST.sha256"
    if (-not (Test-Path -LiteralPath $rcManifestPath -PathType Leaf)) {
        throw "The verified package manifest is missing."
    }
    $described = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $rcManifestPath)) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            throw "The verified package manifest is malformed."
        }
        $expected = $Matches[1]
        $relativePath = $Matches[2]
        if (
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Split("/") -contains ".."
        ) {
            throw "The verified package contains an unsafe manifest path."
        }
        $path = Join-Path $PackageRoot $relativePath.Replace("/", "\")
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "A verified package file is missing: $relativePath"
        }
        if ((Get-FileSha256 -Path $path) -ne $expected) {
            throw "A verified package file hash mismatch: $relativePath"
        }
        $described.Add($relativePath) | Out-Null
    }
    $actual = New-Object System.Collections.Generic.List[string]
    foreach ($file in @(
        Get-ChildItem -LiteralPath $PackageRoot -File -Recurse -Force
    )) {
        $relativePath = $file.FullName.Substring(
            $PackageRoot.Length + 1
        ).Replace("\", "/")
        if ($relativePath -ceq "MANIFEST.sha256") {
            continue
        }
        $actual.Add($relativePath) | Out-Null
    }
    $describedSorted = [string[]]$described.ToArray()
    $actualSorted = [string[]]$actual.ToArray()
    [Array]::Sort($describedSorted, [StringComparer]::Ordinal)
    [Array]::Sort($actualSorted, [StringComparer]::Ordinal)
    if (
        @(Compare-Object `
            -ReferenceObject $describedSorted `
            -DifferenceObject $actualSorted `
            -CaseSensitive).Count -ne 0
    ) {
        throw "The verified package manifest does not describe the complete package."
    }
}

function Invoke-ChildPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "An installation script is missing: $([IO.Path]::GetFileName($ScriptPath))"
    }
    $output = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ScriptPath `
            @Arguments 2>&1
    )
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else {
        [int]$LASTEXITCODE
    }
    $text = ($output | Out-String)
    Append-Utf8Text `
        -Path $LogPath `
        -Text ("`n===== " + [IO.Path]::GetFileName($ScriptPath) + "`n" + $text)
    if ($exitCode -ne 0) {
        throw (
            "Installation step failed with exit code $exitCode`: " +
            [IO.Path]::GetFileName($ScriptPath)
        )
    }
    return $text
}

function ConvertFrom-LastJsonLine {
    param([Parameter(Mandatory = $true)][string]$Text)

    foreach ($line in @($Text -split "\r?\n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith("{")) {
            continue
        }
        try {
            return $trimmed | ConvertFrom-Json
        }
        catch {
            continue
        }
    }
    return $null
}

function Get-ExistingInstallState {
    $target = Join-Path $SkillsRoot "pc-hardware-workbench"
    $targetExists = Test-Path -LiteralPath $target
    $pointerPath = Join-Path $LocalRoot "runtime-location.json"
    $pointerExists = Test-Path -LiteralPath $pointerPath
    $runtimeDirectories = @()
    if (Test-Path -LiteralPath $LocalRoot -PathType Container) {
        $runtimeDirectories = @(
            Get-ChildItem -LiteralPath $LocalRoot -Directory -Force |
                Where-Object { $_.Name -match '^Runtime-' }
        )
    }
    return [pscustomobject]@{
        skill_target = $target
        skill_exists = $targetExists
        local_root = $LocalRoot
        runtime_pointer = $pointerPath
        runtime_pointer_exists = $pointerExists
        runtime_directories = @(
            $runtimeDirectories | ForEach-Object FullName
        )
        existing_install = (
            $targetExists -or
            $pointerExists -or
            $runtimeDirectories.Count -gt 0
        )
    }
}

function Restore-InstalledSkill {
    param(
        [Parameter(Mandatory = $true)]$InstallResult,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $changedProperty = $InstallResult.PSObject.Properties["changed"]
    if ($null -eq $changedProperty -or -not [bool]$changedProperty.Value) {
        return [pscustomobject]@{
            restored = $false
            detail = "The Skill installation did not change the installed tree."
        }
    }
    $target = [string]$InstallResult.target
    $backupPath = ""
    $backupProperty = $InstallResult.PSObject.Properties["backup_path"]
    if ($null -ne $backupProperty) {
        $backupPath = [string]$backupProperty.Value
    }
    $failedPath = ""
    if (Test-Path -LiteralPath $target) {
        $backupRoot = Join-Path $SkillsRoot ".skilldock-backups"
        New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
        $failedPath = Join-Path $backupRoot (
            "pc-hardware-workbench-failed-user-install-" +
            (Get-Date -Format "yyyyMMdd-HHmmss") +
            "-" +
            [guid]::NewGuid().ToString("N").Substring(0, 8)
        )
        Move-Item -LiteralPath $target -Destination $failedPath
    }
    if (-not [string]::IsNullOrWhiteSpace($backupPath)) {
        if (-not (Test-Path -LiteralPath $backupPath -PathType Container)) {
            throw "The previous Skill backup is missing: $backupPath"
        }
        Move-Item -LiteralPath $backupPath -Destination $target
    }
    $detail = "Previous Skill restored."
    if (-not [string]::IsNullOrWhiteSpace($failedPath)) {
        $detail += " Failed install retained at: $failedPath"
    }
    Append-Utf8Text -Path $LogPath -Text ("Skill rollback: " + $detail + "`n")
    return [pscustomobject]@{
        restored = $true
        failed_install_path = $failedPath
        restored_backup_path = $backupPath
        detail = $detail
    }
}

if ([string]::IsNullOrWhiteSpace($SkillsRoot)) {
    $SkillsRoot = Join-Path $env:USERPROFILE ".codex\skills"
}
if ([string]::IsNullOrWhiteSpace($LocalRoot)) {
    $LocalRoot = Join-Path $env:LOCALAPPDATA "SkillDock"
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\runtime"
}
if ([string]::IsNullOrWhiteSpace($DataBackupRoot)) {
    $DataBackupRoot = Join-Path $env:LOCALAPPDATA "SkillDockBackups\data"
}
$SkillsRoot = [IO.Path]::GetFullPath($SkillsRoot).TrimEnd("\")
$LocalRoot = [IO.Path]::GetFullPath($LocalRoot).TrimEnd("\")
$BackupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd("\")
$DataBackupRoot = [IO.Path]::GetFullPath($DataBackupRoot).TrimEnd("\")

Assert-PayloadManifest
if (-not (Test-Path -LiteralPath $packageInfoPath -PathType Leaf)) {
    throw "PACKAGE-INFO.json is missing."
}
$packageInfo = Get-Content -Raw -LiteralPath $packageInfoPath |
    ConvertFrom-Json
$archivePath = Join-Path $payloadRoot ([string]$packageInfo.rc_archive.file)
$sidecarPath = "$archivePath.sha256"
if (
    -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)
) {
    throw "The embedded installer payload is incomplete."
}
$archiveSha256 = Get-FileSha256 -Path $archivePath
if ($archiveSha256 -ne [string]$packageInfo.rc_archive.sha256) {
    throw "The embedded installer payload hash is invalid."
}
$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $sidecarPath).Trim() -split "\s+"
)
if (
    $sidecarFields.Count -lt 1 -or
    $sidecarFields[0].ToLowerInvariant() -ne $archiveSha256
) {
    throw "The embedded installer payload sidecar is invalid."
}

$existingState = Get-ExistingInstallState
$mode = if ($existingState.existing_install) {
    "upgrade"
}
else {
    "clean"
}
if ($PreflightOnly) {
    [pscustomobject]@{
        ok = $true
        status = "preflight_passed"
        mode = $mode
        rc_sha256 = $archiveSha256
        skills_root = $SkillsRoot
        local_root = $LocalRoot
        skill_exists = [bool]$existingState.skill_exists
        runtime_pointer_exists = [bool]$existingState.runtime_pointer_exists
        runtime_directory_count = @($existingState.runtime_directories).Count
        writes_performed = $false
    } | ConvertTo-Json -Depth 5
    exit 0
}

$startedAt = [DateTimeOffset]::Now
$runId = [guid]::NewGuid().ToString("N")
$logRoot = Join-Path $LocalRoot "install-logs"
$runName = "user-install-$($startedAt.ToString('yyyyMMdd-HHmmss'))-$($runId.Substring(0, 8))"
$runRoot = Join-Path $logRoot $runName
New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
$logPath = Join-Path $runRoot "install.log"
$resultPath = Join-Path $runRoot "install-result.json"
$latestResultPath = Join-Path $logRoot "latest-install-result.json"
Write-Utf8Text `
    -Path $logPath `
    -Text (
        "SkillDock user installation`n" +
        "Started: $($startedAt.ToString('o'))`n" +
        "Mode: $mode`n" +
        "Payload SHA-256: $archiveSha256`n"
    )

$temporaryRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("skilldock-user-install-" + [guid]::NewGuid().ToString("N"))
$extractRoot = Join-Path $temporaryRoot "extract"
$skillInstallResult = $null
$installationCommitted = $false
$rollbackResult = $null

try {
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive `
        -LiteralPath $archivePath `
        -DestinationPath $extractRoot `
        -Force
    $topLevelDirectories = @(
        Get-ChildItem -LiteralPath $extractRoot -Directory -Force
    )
    $topLevelFiles = @(
        Get-ChildItem -LiteralPath $extractRoot -File -Force
    )
    if (
        $topLevelDirectories.Count -ne 1 -or
        $topLevelFiles.Count -ne 0 -or
        $topLevelDirectories[0].Name -ne [string]$packageInfo.package_base
    ) {
        throw "The embedded installer package layout is invalid."
    }
    $rcPackageRoot = $topLevelDirectories[0].FullName
    Assert-RcPackageManifest -PackageRoot $rcPackageRoot
    $rcManifest = Get-Content -Raw -LiteralPath (
        Join-Path $rcPackageRoot "RC-MANIFEST.json"
    ) | ConvertFrom-Json
    if (
        [string]$rcManifest.release_id -ne [string]$packageInfo.versions.skilldock -or
        [string]$rcManifest.pchw_skill.version -ne
            [string]$packageInfo.versions.pchw_skill
    ) {
        throw "The embedded installer version metadata is inconsistent."
    }

    $skillArguments = @("-SkillsRoot", $SkillsRoot)
    if ($existingState.skill_exists) {
        $skillArguments += "-ReplaceExisting"
    }
    $skillOutput = Invoke-ChildPowerShell `
        -ScriptPath (Join-Path $rcPackageRoot "Install PCHW Skill.ps1") `
        -Arguments $skillArguments `
        -LogPath $logPath
    $skillInstallResult = ConvertFrom-LastJsonLine -Text $skillOutput
    if (
        $null -eq $skillInstallResult -or
        -not [bool]$skillInstallResult.ok
    ) {
        throw "The PCHW Skill installer did not return a successful result."
    }

    $runtimeOutput = Invoke-ChildPowerShell `
        -ScriptPath (Join-Path $rcPackageRoot "Install SkillDock Runtime.ps1") `
        -Arguments @(
            "-LocalRoot",
            $LocalRoot,
            "-BackupRoot",
            $BackupRoot,
            "-DataBackupRoot",
            $DataBackupRoot
        ) `
        -LogPath $logPath
    $runtimeResult = ConvertFrom-LastJsonLine -Text $runtimeOutput

    $pointerPath = Join-Path $LocalRoot "runtime-location.json"
    if (-not (Test-Path -LiteralPath $pointerPath -PathType Leaf)) {
        throw "The Runtime installer did not create runtime-location.json."
    }
    $pointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json
    if (
        [string]$pointer.version -ne [string]$packageInfo.versions.skilldock -or
        -not (Test-Path -LiteralPath ([string]$pointer.runtime_path) -PathType Leaf)
    ) {
        throw "The installed Runtime failed version or launcher validation."
    }

    $result = [ordered]@{
        schema_version = "1.0"
        status = "passed"
        mode = $mode
        started_at = $startedAt.ToString("o")
        finished_at = [DateTimeOffset]::Now.ToString("o")
        versions = $packageInfo.versions
        payload_sha256 = $archiveSha256
        skills_root = $SkillsRoot
        installed_skill = [string]$skillInstallResult.target
        skill_changed = [bool]$skillInstallResult.changed
        skill_backup_path = [string]$skillInstallResult.backup_path
        runtime_pointer = $pointerPath
        runtime_path = [string]$pointer.runtime_path
        runtime_install_result = $runtimeResult
        log_path = $logPath
    }
    $resultJson = $result | ConvertTo-Json -Depth 10
    Write-Utf8Text -Path $resultPath -Text ($resultJson + "`n")
    Write-Utf8Text -Path $latestResultPath -Text ($resultJson + "`n")
    Append-Utf8Text -Path $logPath -Text "INSTALL PASSED`n"
    $installationCommitted = $true

    Write-Host ""
    Write-Host "安装完成 / Installation completed." -ForegroundColor Green
    Write-Host "请回到当前 Codex 对话提出硬件问题并打开电脑硬件工作台。"
    Write-Host "Continue in the current Codex conversation."
    Write-Host "安装日志 / Log: $logPath"
}
catch {
    $errorMessage = [string]$_.Exception.Message
    Append-Utf8Text -Path $logPath -Text ("INSTALL FAILED: " + $errorMessage + "`n")
    if (
        $null -ne $skillInstallResult -and
        -not $installationCommitted
    ) {
        try {
            $rollbackResult = Restore-InstalledSkill `
                -InstallResult $skillInstallResult `
                -LogPath $logPath
        }
        catch {
            $rollbackError = [string]$_.Exception.Message
            Append-Utf8Text `
                -Path $logPath `
                -Text ("SKILL ROLLBACK FAILED: " + $rollbackError + "`n")
            $errorMessage += " Skill rollback also failed: $rollbackError"
        }
    }
    $failure = [ordered]@{
        schema_version = "1.0"
        status = "failed"
        mode = $mode
        started_at = $startedAt.ToString("o")
        finished_at = [DateTimeOffset]::Now.ToString("o")
        error = $errorMessage
        payload_sha256 = $archiveSha256
        rollback = $rollbackResult
        log_path = $logPath
    }
    $failureJson = $failure | ConvertTo-Json -Depth 10
    Write-Utf8Text -Path $resultPath -Text ($failureJson + "`n")
    Write-Utf8Text -Path $latestResultPath -Text ($failureJson + "`n")
    Write-Host ""
    Write-Host "安装失败 / Installation failed." -ForegroundColor Red
    Write-Host $errorMessage -ForegroundColor Yellow
    Write-Host "安装日志 / Log: $logPath" -ForegroundColor Yellow
    exit 1
}
finally {
    if (
        $env:SKILLDOCK_KEEP_INSTALL_TEMP -ne "1" -and
        (Test-Path -LiteralPath $temporaryRoot)
    ) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $resolvedTempBase = [IO.Path]::GetFullPath(
            [IO.Path]::GetTempPath()
        )
        if (
            $resolvedTemporary.StartsWith(
                $resolvedTempBase,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item `
                -LiteralPath $resolvedTemporary `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}
