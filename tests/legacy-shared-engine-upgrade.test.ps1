[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$LegacyRuntimePackage,

    [Parameter(Mandatory = $true)]
    [string]$CurrentRuntimePackage
)

$ErrorActionPreference = "Stop"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    "skilldock-legacy-shared-upgrade-" + [guid]::NewGuid().ToString("N")
)
$localRoot = Join-Path $tempRoot "SkillDock"
$backupRoot = Join-Path $tempRoot "SkillDockBackups\runtime"
$dataBackupRoot = Join-Path $tempRoot "SkillDockBackups\data"
$workspace = Join-Path $tempRoot "workspace"
$runtimeProcess = $null

function Invoke-RuntimeInstaller {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot
    )

    $installer = Join-Path $PackageRoot "Install SkillDock Runtime.ps1"
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Runtime installer is missing: $installer"
    }
    & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $installer `
        -LocalRoot $localRoot `
        -BackupRoot $backupRoot `
        -DataBackupRoot $dataBackupRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Runtime installer failed: $installer"
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    return Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json
}

function Start-SharedRuntime {
    param([Parameter(Mandatory = $true)][string]$RuntimePath)

    $env:SKILLDOCK_LOCAL_ROOT = $localRoot
    $env:SKILLDOCK_AGENT_DRIVER = "source-external"
    $env:PANEL_SOURCE_HOSTED_ENTRY = "1"
    $env:PANEL_SOURCE_HOSTED_NON_MOCK = "1"
    $process = Start-Process `
        -FilePath $RuntimePath `
        -ArgumentList @(
            "--ensure",
            "--workspace",
            ('"' + $workspace + '"'),
            "--silent",
            "--no-browser"
        ) `
        -PassThru `
        -WindowStyle Hidden
    $resultPath = Join-Path $localRoot "launch-result.json"
    for ($attempt = 0; $attempt -lt 120; $attempt++) {
        if ($process.HasExited -and -not (Test-Path -LiteralPath $resultPath)) {
            throw "Upgraded Runtime exited before launch result was written."
        }
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) {
            $result = Read-JsonFile -Path $resultPath
            if ($result.ok -and $result.url) {
                $health = Invoke-RestMethod `
                    -Uri ($result.url.TrimEnd("/") + "/api/health") `
                    -TimeoutSec 10
                if ($health.ok) {
                    return [pscustomobject]@{
                        process = $process
                        result = $result
                        health = $health
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 100
    }
    if (-not $process.HasExited) {
        $process.Kill()
    }
    throw "Upgraded Runtime did not become healthy."
}

try {
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null
    Invoke-RuntimeInstaller -PackageRoot $LegacyRuntimePackage
    $legacyPointer = Read-JsonFile -Path (
        Join-Path $localRoot "runtime-location.json"
    )
    $legacyProgram = Split-Path -Parent ([string]$legacyPointer.runtime_path)
    if (
        -not (
            Test-Path -LiteralPath (
                Join-Path $legacyProgram "node\node.exe"
            ) -PathType Leaf
        )
    ) {
        throw "Legacy active Runtime is not self-contained."
    }
    $taskMarker = Join-Path $localRoot "runtime-pchw\legacy-keep.txt"
    New-Item -ItemType Directory -Path (Split-Path -Parent $taskMarker) `
        -Force | Out-Null
    Set-Content -LiteralPath $taskMarker -Value "keep-task-data"

    Invoke-RuntimeInstaller -PackageRoot $CurrentRuntimePackage
    $pointer = Read-JsonFile -Path (
        Join-Path $localRoot "runtime-location.json"
    )
    $currentProgram = Split-Path -Parent ([string]$pointer.runtime_path)
    $engineReference = Read-JsonFile -Path (
        Join-Path $currentProgram "engine-location.json"
    )
    $backups = @(
        Get-ChildItem -LiteralPath $backupRoot -Directory -Force
    )
    if (Test-Path -LiteralPath (Join-Path $currentProgram "node")) {
        throw "Upgraded Runtime still embeds a private Node directory."
    }
    if (
        -not (
            Test-Path -LiteralPath ([string]$engineReference.node_path) `
                -PathType Leaf
        )
    ) {
        throw "Upgraded Runtime shared Node engine is missing."
    }
    if (
        [string]$engineReference.node_sha256 -notmatch
            "^[0-9a-f]{64}$"
    ) {
        throw "Upgraded Runtime shared Node digest is invalid."
    }
    if ($backups.Count -ne 1) {
        throw "Expected one legacy rollback backup, found $($backups.Count)."
    }
    if (
        -not (
            Test-Path -LiteralPath (
                Join-Path $backups[0].FullName "node\node.exe"
            ) -PathType Leaf
        )
    ) {
        throw "Legacy rollback backup lost its embedded Node."
    }
    if (
        [string]$pointer.previous_runtime_backup_path -ne
            [string]$backups[0].FullName
    ) {
        throw "Runtime pointer does not protect the legacy rollback backup."
    }
    if (-not (Test-Path -LiteralPath $taskMarker -PathType Leaf)) {
        throw "Runtime upgrade removed Task data."
    }

    $started = Start-SharedRuntime -RuntimePath ([string]$pointer.runtime_path)
    $runtimeProcess = $started.process
    $stopProcess = Start-Process `
        -FilePath ([string]$pointer.runtime_path) `
        -ArgumentList @("--stop", "--silent") `
        -PassThru `
        -Wait `
        -WindowStyle Hidden
    if ($stopProcess.ExitCode -ne 0) {
        throw "Upgraded Runtime did not stop cleanly."
    }
    try {
        Wait-Process -Id $runtimeProcess.Id -Timeout 10 -ErrorAction Stop
    }
    catch {
        if (-not $runtimeProcess.HasExited) {
            $runtimeProcess.Kill()
        }
    }

    [pscustomobject]@{
        status = "PASS"
        legacy_embedded_node = $true
        legacy_backup_embedded_node = $true
        current_embedded_node = $false
        shared_engine_id = [string]$engineReference.engine_id
        shared_engine_sha256 = [string]$engineReference.node_sha256
        previous_backup_protected = $true
        task_data_preserved = $true
        health_ok = [bool]$started.health.ok
    } | ConvertTo-Json
}
finally {
    if (
        $null -ne $runtimeProcess -and
        -not $runtimeProcess.HasExited
    ) {
        $runtimeProcess.Kill()
    }
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith(
            $tempBase,
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
