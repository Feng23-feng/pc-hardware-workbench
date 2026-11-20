[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ArchivePath,

    [string]$VerificationPath = "",

    [string]$BuildReportPath = "",

    [switch]$AllowDirtyLocalCandidate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Write-NormalizedJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    Write-Utf8Text -Path $Path -Text (
        $json.Replace("`r`n", "`n") + "`n"
    )
}

function Invoke-UserPackageRetentionGate {
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$RcArchivePath,
        [Parameter(Mandatory = $true)][string]$ExpectedPackageBase,
        [Parameter(Mandatory = $true)][string]$GateRoot
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($RcArchivePath)
    try {
        $installerEntryName = (
            $ExpectedPackageBase + "\Install SkillDock Runtime.ps1"
        )
        $installerEntry = $archive.Entries |
            Where-Object { $_.FullName -eq $installerEntryName } |
            Select-Object -First 1
        if ($null -eq $installerEntry) {
            throw "Embedded RC Runtime installer is missing: $installerEntryName"
        }
        $reader = New-Object IO.StreamReader($installerEntry.Open())
        try {
            $installerText = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
    if (
        $installerText -notmatch '\[int\]\$RetainRuntimeBackups' -or
        $installerText -notmatch 'Invoke-RuntimeBackupRetention' -or
        $installerText -notmatch 'Install-SkillDockNodeEngine' -or
        $installerText -notmatch 'engine-location\.json'
    ) {
        throw "Embedded RC Runtime installer predates shared Node or backup retention."
    }

    $skillsRoot = Join-Path $GateRoot "skills"
    $localRoot = Join-Path $GateRoot "local"
    $backupRoot = Join-Path $GateRoot "runtime-backups"
    $dataBackupRoot = Join-Path $GateRoot "data-backups"
    $enginesRoot = Join-Path $localRoot "engines"
    $staleEngine = Join-Path $enginesRoot "node-24.0.0-0123456789abcdef"
    $staleBackup = Join-Path $backupRoot "Runtime-stale-backup-20200101-000000"
    New-Item -ItemType Directory -Path $staleEngine -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $staleEngine "stale.txt") `
        -Value "stale"
    New-Item -ItemType Directory -Path $staleBackup -Force | Out-Null
    Set-Content `
        -LiteralPath (Join-Path $staleBackup "stale.txt") `
        -Value "stale"

    $installerPath = Join-Path $PayloadRoot "Install-User.ps1"
    $installerArguments = @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $installerPath,
        "-SkillsRoot",
        $skillsRoot,
        "-LocalRoot",
        $localRoot,
        "-BackupRoot",
        $backupRoot,
        "-DataBackupRoot",
        $dataBackupRoot,
        "-RetainRuntimeBackups",
        "1"
    )
    $latestResultPath = Join-Path $localRoot "install-logs\latest-install-result.json"
    $results = New-Object System.Collections.Generic.List[object]
    for ($installNumber = 1; $installNumber -le 2; $installNumber++) {
        $output = @(
            & powershell.exe @installerArguments 2>&1
        )
        if ($LASTEXITCODE -ne 0) {
            throw (
                "Temporary user-package install $installNumber failed: " +
                (($output | Out-String).Trim())
            )
        }
        if (-not (Test-Path -LiteralPath $latestResultPath -PathType Leaf)) {
            throw "Temporary user-package install did not write an install result."
        }
        $installResult = Get-Content -Raw -LiteralPath $latestResultPath |
            ConvertFrom-Json
        if ([string]$installResult.status -ne "passed") {
            throw "Temporary user-package install $installNumber did not pass."
        }
        $results.Add($installResult) | Out-Null
        if ($installNumber -eq 1) {
            $canonicalRoot = Join-Path $localRoot "runtime-pchw"
            New-Item -ItemType Directory -Path $canonicalRoot -Force |
                Out-Null
            Set-Content `
                -LiteralPath (Join-Path $canonicalRoot "retention-gate-keep.txt") `
                -Value "keep-task-data"
        }
    }

    if (
        [string]$results[0].mode -ne "clean" -or
        [string]$results[1].mode -ne "upgrade"
    ) {
        throw "Runtime retention gate did not exercise clean and upgrade installs."
    }
    $retainedBackups = @(
        Get-ChildItem -LiteralPath $backupRoot -Directory -Force |
            Where-Object {
                $_.Name -cmatch '^Runtime.*-backup-\d{8}-\d{6}(?:-\d+)?$'
            }
    )
    if ($retainedBackups.Count -ne 1) {
        throw "Runtime retention gate expected one backup, found $($retainedBackups.Count)."
    }
    if (Test-Path -LiteralPath $staleBackup) {
        throw "Runtime retention gate did not remove the stale backup."
    }
    if (Test-Path -LiteralPath $staleEngine) {
        throw "Runtime retention gate did not remove the stale shared Node engine."
    }
    $pointer = Get-Content -Raw -LiteralPath (
        Join-Path $localRoot "runtime-location.json"
    ) | ConvertFrom-Json
    $runtimeDirectory = Split-Path -Parent ([string]$pointer.runtime_path)
    if (Test-Path -LiteralPath (Join-Path $runtimeDirectory "node")) {
        throw "Active Runtime still contains a duplicate node directory."
    }
    $engineReferencePath = Join-Path `
        $runtimeDirectory `
        "engine-location.json"
    if (-not (Test-Path -LiteralPath $engineReferencePath -PathType Leaf)) {
        throw "Active Runtime is missing its shared Node engine reference."
    }
    $engineReference = Get-Content `
        -Raw `
        -LiteralPath $engineReferencePath | ConvertFrom-Json
    $engineDirectories = @(
        Get-ChildItem -LiteralPath $enginesRoot -Directory -Force |
            Where-Object {
                $_.Name -cmatch '^node-\d+\.\d+\.\d+-[0-9a-f]{16}$'
            }
    )
    if (
        $engineDirectories.Count -ne 1 -or
        $engineDirectories[0].Name -ne [string]$engineReference.engine_id -or
        [string]$pointer.node_engine.engine_id -ne
            [string]$engineReference.engine_id
    ) {
        throw "Runtime retention gate did not converge on one shared Node engine."
    }
    if (Test-Path -LiteralPath (Join-Path $retainedBackups[0].FullName "node")) {
        throw "Retained Runtime backup still contains a duplicate node directory."
    }
    $backupEngineReferencePath = Join-Path `
        $retainedBackups[0].FullName `
        "engine-location.json"
    if (-not (Test-Path -LiteralPath $backupEngineReferencePath -PathType Leaf)) {
        throw "Retained Runtime backup is missing its shared Node engine reference."
    }
    $backupEngineReference = Get-Content `
        -Raw `
        -LiteralPath $backupEngineReferencePath | ConvertFrom-Json
    if (
        [string]$backupEngineReference.engine_id -ne
            [string]$engineReference.engine_id
    ) {
        throw "Retained Runtime backup does not reference the shared engine."
    }
    if (
        -not (
            Test-Path -LiteralPath (
                Join-Path $localRoot "runtime-pchw\retention-gate-keep.txt"
            ) -PathType Leaf
        )
    ) {
        throw "Runtime retention gate removed Task data."
    }
    if (
        [int]$results[1].runtime_install_result.backup_retention.retain_count -ne 1 -or
        @($results[1].runtime_install_result.backup_retention.removed).Count -lt 1
    ) {
        throw "Runtime retention gate did not forward the retention policy."
    }
    return [pscustomobject][ordered]@{
        status = "passed"
        embedded_rc_installer = "current"
        installs = 2
        clean_then_upgrade = $true
        retained_backup_count = $retainedBackups.Count
        shared_engine_count = $engineDirectories.Count
        stale_backup_removed = $true
        stale_engine_removed = $true
        runtime_node_embedded = $false
        backup_node_embedded = $false
        task_data_preserved = $true
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$FullName
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd("\")
    $resolvedFile = [IO.Path]::GetFullPath($FullName)
    if (
        -not $resolvedFile.StartsWith(
            $resolvedRoot + "\",
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "Path escaped the user package: $resolvedFile"
    }
    return $resolvedFile.Substring($resolvedRoot.Length + 1).Replace("\", "/")
}

$resolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $resolvedArchive -PathType Leaf)) {
    throw "User package archive is missing: $resolvedArchive"
}
$sidecarPath = "$resolvedArchive.sha256"
if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) {
    throw "User package archive sidecar is missing: $sidecarPath"
}
$sidecarFields = @(
    (Get-Content -Raw -LiteralPath $sidecarPath).Trim() -split "\s+"
)
if (
    $sidecarFields.Count -lt 1 -or
    $sidecarFields[0] -notmatch "^[a-f0-9]{64}$"
) {
    throw "User package archive sidecar is malformed."
}
$actualArchiveSha256 = Get-FileSha256 -Path $resolvedArchive
$expectedArchiveSha256 = $sidecarFields[0].ToLowerInvariant()
if ($actualArchiveSha256 -ne $expectedArchiveSha256) {
    throw "User package archive SHA-256 does not match its sidecar."
}

$tempRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ("skilldock-user-package-verify-" + [guid]::NewGuid().ToString("N"))
$extractRoot = Join-Path $tempRoot "extract"
New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null

try {
    Expand-Archive `
        -LiteralPath $resolvedArchive `
        -DestinationPath $extractRoot `
        -Force
    $topLevelDirectories = @(
        Get-ChildItem -LiteralPath $extractRoot -Directory -Force
    )
    $topLevelFiles = @(
        Get-ChildItem -LiteralPath $extractRoot -File -Force
    )
    if ($topLevelDirectories.Count -ne 1 -or $topLevelFiles.Count -ne 0) {
        throw "User package must contain exactly one top-level directory."
    }
    $packageRoot = $topLevelDirectories[0].FullName
    $rootItems = @(Get-ChildItem -LiteralPath $packageRoot -Force)
    $rootNames = @($rootItems | ForEach-Object Name | Sort-Object)
    $expectedRootNames = @(
        "payload",
        "Install.cmd",
        "README.en.txt",
        "README.txt"
    )
    if (
        @(Compare-Object `
            -ReferenceObject $expectedRootNames `
            -DifferenceObject $rootNames `
            -CaseSensitive).Count -ne 0 -or
        $rootItems.Count -ne 4
    ) {
        throw (
            "User package root must contain exactly README.txt, " +
            "README.en.txt, Install.cmd, and payload."
        )
    }
    $payloadRoot = Join-Path $packageRoot "payload"
    if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
        throw "User package payload directory is missing."
    }

    $installCommand = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $packageRoot "Install.cmd")
    if (
        $installCommand -notmatch
            [regex]::Escape('payload\Install-User.ps1') -or
        $installCommand -match
            "Start-Acceptance|Start-Upgrade|99-|00-|01-|SkillDock\.exe"
    ) {
        throw "Install.cmd is not the sole ordinary-user installation entry."
    }

    $chineseReadme = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $packageRoot "README.txt") `
        -Encoding UTF8
    $englishReadme = Get-Content `
        -Raw `
        -LiteralPath (Join-Path $packageRoot "README.en.txt") `
        -Encoding UTF8
    foreach ($readme in @(
        [pscustomobject]@{ Name = "README.txt"; Text = $chineseReadme },
        [pscustomobject]@{ Name = "README.en.txt"; Text = $englishReadme }
    )) {
        if (
            $readme.Text -match (
                "payload\\|Start-Acceptance|Start-Upgrade|99-|00-|01-|" +
                "acceptance bundle|clean UI|manual-fallback|SHA-256|" +
                "candidate|not released"
            )
        ) {
            throw "User README contains internal implementation detail: $($readme.Name)"
        }
    }
    if (
        $chineseReadme -notmatch "双击 Install\.cmd" -or
        $chineseReadme -notmatch "(?s)自动.*安全升级" -or
        $chineseReadme -notmatch "仅本次允许" -or
        $chineseReadme -notmatch "手动打开面板" -or
        $chineseReadme -notmatch "不会自动修改 BIOS"
    ) {
        throw "Chinese user README is missing required user guidance."
    }
    if (
        $englishReadme -notmatch "Double-click Install\.cmd" -or
        $englishReadme -notmatch "(?s)safe\s+upgrade\s+automatically" -or
        $englishReadme -notmatch "Allow this time only" -or
        $englishReadme -notmatch "panel manually" -or
        $englishReadme -notmatch "Uninstall" -or
        $englishReadme -notmatch "Limitations"
    ) {
        throw "English user README is missing required user guidance."
    }

    $packageInfoPath = Join-Path $payloadRoot "PACKAGE-INFO.json"
    $packageInfo = Get-Content -Raw -LiteralPath $packageInfoPath |
        ConvertFrom-Json
    if (
        [string]$packageInfo.package_kind -ne
            "integrated-user-installation" -or
        [string]$packageInfo.primary_entry -ne "Install.cmd" -or
        -not [bool]$packageInfo.behavior.automatic_mode_detection -or
        -not [bool]$packageInfo.behavior.automatic_existing_skill_backup -or
        -not [bool]$packageInfo.behavior.automatic_skill_restore_on_later_failure
    ) {
        throw "User package behavior metadata is inconsistent."
    }

    $rcFile = [string]$packageInfo.rc_archive.file
    $rcSha256 = [string]$packageInfo.rc_archive.sha256
    $rcBytes = [int64]$packageInfo.rc_archive.bytes
    $rcPath = Join-Path $payloadRoot $rcFile
    $rcSidecarPath = "$rcPath.sha256"
    if (
        -not (Test-Path -LiteralPath $rcPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $rcSidecarPath -PathType Leaf)
    ) {
        throw "Embedded RC archive or sidecar is missing."
    }
    if ((Get-Item -LiteralPath $rcPath).Length -ne $rcBytes) {
        throw "Embedded RC byte count differs from package metadata."
    }
    if ((Get-FileSha256 -Path $rcPath) -ne $rcSha256) {
        throw "Embedded RC SHA-256 differs from package metadata."
    }
    $rcSidecarFields = @(
        (Get-Content -Raw -LiteralPath $rcSidecarPath).Trim() -split "\s+"
    )
    if (
        $rcSidecarFields.Count -lt 1 -or
        $rcSidecarFields[0].ToLowerInvariant() -ne $rcSha256
    ) {
        throw "Embedded RC sidecar differs from package metadata."
    }

    $actualPayloadFiles = @(
        Get-ChildItem -LiteralPath $payloadRoot -File -Recurse -Force |
            ForEach-Object {
                Get-RelativePath -Root $payloadRoot -FullName $_.FullName
            } |
            Sort-Object
    )
    $rcVerificationFile = [IO.Path]::GetFileName(
        [IO.Path]::ChangeExtension($rcPath, ".verification.json")
    )
    $rcVerificationPath = Join-Path $payloadRoot $rcVerificationFile
    if (-not (Test-Path -LiteralPath $rcVerificationPath -PathType Leaf)) {
        throw "Embedded RC verification metadata is missing."
    }
    $embeddedRcVerification = Get-Content -Raw -LiteralPath (
        $rcVerificationPath
    ) | ConvertFrom-Json
    if (
        [string]$packageInfo.package_base -ne
            [string]$embeddedRcVerification.package_basename
    ) {
        throw "User package_base does not match the embedded RC top-level directory."
    }
    $expectedPayloadFiles = @(
        "BUNDLE-MANIFEST.sha256",
        "Install-User.ps1",
        "PACKAGE-INFO.json",
        $rcFile,
        "$rcFile.sha256",
        $rcVerificationFile
    ) | Sort-Object
    if (
        @(Compare-Object `
            -ReferenceObject $expectedPayloadFiles `
            -DifferenceObject $actualPayloadFiles `
            -CaseSensitive).Count -ne 0
    ) {
        throw "User package payload contains an unexpected or missing entry."
    }

    $manifestLines = @(
        Get-Content -LiteralPath (Join-Path $payloadRoot "BUNDLE-MANIFEST.sha256")
    )
    $described = New-Object System.Collections.Generic.List[string]
    foreach ($line in $manifestLines) {
        if ($line -notmatch "^([a-f0-9]{64})  (.+)$") {
            throw "User package manifest is malformed."
        }
        $expected = $Matches[1]
        $relativePath = $Matches[2]
        if (
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.Split("/") -contains ".."
        ) {
            throw "Unsafe user package manifest path: $relativePath"
        }
        $path = Join-Path $payloadRoot $relativePath.Replace("/", "\")
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "User package manifest entry is missing: $relativePath"
        }
        if ((Get-FileSha256 -Path $path) -ne $expected) {
            throw "User package manifest digest differs: $relativePath"
        }
        $described.Add($relativePath) | Out-Null
    }
    $expectedDescribed = @(
        $actualPayloadFiles |
            Where-Object { $_ -ne "BUNDLE-MANIFEST.sha256" } |
            Sort-Object
    )
    if (
        @(Compare-Object `
            -ReferenceObject $expectedDescribed `
            -DifferenceObject @($described | Sort-Object) `
            -CaseSensitive).Count -ne 0
    ) {
        throw "User package manifest does not describe the complete payload."
    }

    $nestedVerifier = Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        "launcher\verify-rc-package.ps1"
    if (-not (Test-Path -LiteralPath $nestedVerifier -PathType Leaf)) {
        throw "The nested RC verifier is missing."
    }
    $nestedOutput = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $nestedVerifier `
            -ArchivePath $rcPath `
            -AllowDirtyLocalCandidate 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw (
            "Nested RC verification failed: " +
            (($nestedOutput | Out-String).Trim())
        )
    }

    $userPreflightOutput = @(
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File (Join-Path $payloadRoot "Install-User.ps1") `
            -PreflightOnly 2>&1
    )
    if ($LASTEXITCODE -ne 0) {
        throw (
            "User package preflight failed: " +
            (($userPreflightOutput | Out-String).Trim())
        )
    }
    $preflightText = ($userPreflightOutput | Out-String).Trim()
    $preflightJsonStart = $preflightText.IndexOf("{")
    $preflight = if ($preflightJsonStart -ge 0) {
        $preflightText.Substring($preflightJsonStart) | ConvertFrom-Json
    }
    else {
        $null
    }
    if (
        $null -eq $preflight -or
        [bool]$preflight.writes_performed -or
        [string]$preflight.mode -notin @("clean", "upgrade")
    ) {
        throw "User package automatic install-mode preflight did not pass."
    }

    $retentionGate = Invoke-UserPackageRetentionGate `
        -PayloadRoot $payloadRoot `
        -RcArchivePath $rcPath `
        -ExpectedPackageBase ([string]$embeddedRcVerification.package_basename) `
        -GateRoot (Join-Path $tempRoot "retention-gate")

    if (-not [string]::IsNullOrWhiteSpace($BuildReportPath)) {
        $resolvedBuildReport = [IO.Path]::GetFullPath($BuildReportPath)
        if (-not (Test-Path -LiteralPath $resolvedBuildReport -PathType Leaf)) {
            throw "User package build report is missing."
        }
        $buildReport = Get-Content -Raw -LiteralPath $resolvedBuildReport |
            ConvertFrom-Json
        if (
            [string]$buildReport.package_kind -ne
                "integrated-user-installation" -or
            [string]$buildReport.archive_sha256 -ne $actualArchiveSha256
        ) {
            throw "User package build report does not match the archive."
        }
    }

    $verification = [ordered]@{
        schema_version = "1.0"
        status = "passed"
        package_kind = "integrated-user-installation"
        release_id = [string]$packageInfo.versions.skilldock
        package = [ordered]@{
            file = [IO.Path]::GetFileName($resolvedArchive)
            bytes = (Get-Item -LiteralPath $resolvedArchive).Length
            sha256 = $actualArchiveSha256
            sidecar_sha256 = $expectedArchiveSha256
            root_entries = $rootNames
            primary_entry = "Install.cmd"
        }
        payload = [ordered]@{
            file_count = $actualPayloadFiles.Count
            manifest_entry_count = $described.Count
            exact_allowlist = "passed"
        }
        rc = [ordered]@{
            file = $rcFile
            bytes = $rcBytes
            sha256 = $rcSha256
        }
        versions = $packageInfo.versions
        automatic_install_preflight = [ordered]@{
            status = "passed"
            detected_mode = [string]$preflight.mode
            writes_performed = $false
        }
        runtime_backup_retention = $retentionGate
        boundaries = [ordered]@{
            user_root_exposes_acceptance_scripts = $false
            test_fixture_in_user_package = $false
            dsh_entry_in_user_package = $false
            real_thread_created_by_verifier = $false
            release_uploaded = $false
        }
        build_report = if (
            [string]::IsNullOrWhiteSpace($BuildReportPath)
        ) {
            $null
        }
        else {
            [IO.Path]::GetFullPath($BuildReportPath)
        }
        verified_at = [DateTimeOffset]::UtcNow.ToString("o")
    }
    if (-not [string]::IsNullOrWhiteSpace($VerificationPath)) {
        Write-NormalizedJson `
            -Path ([IO.Path]::GetFullPath($VerificationPath)) `
            -Value $verification
    }
    [pscustomobject]@{
        ok = $true
        status = "passed"
        package_kind = "integrated-user-installation"
        archive = $resolvedArchive
        archive_bytes = $verification.package.bytes
        archive_sha256 = $actualArchiveSha256
        rc_sha256 = $rcSha256
        root_entries = $rootNames
        automatic_mode = [string]$preflight.mode
        runtime_backup_retention = $retentionGate.status
        verification_path = if (
            [string]::IsNullOrWhiteSpace($VerificationPath)
        ) {
            $null
        }
        else {
            [IO.Path]::GetFullPath($VerificationPath)
        }
    } | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $resolvedTempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (
            $resolvedTemp.StartsWith(
                $resolvedTempBase,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
        }
    }
}
