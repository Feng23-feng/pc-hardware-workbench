[CmdletBinding()]
param(
    [string]$SkillRoot,

    [string]$VenvPath,

    [string]$PythonExe,

    [string]$IndexUrl = "https://pypi.tuna.tsinghua.edu.cn/simple",

    [string]$OfficialValidatorPath,

    [switch]$Bootstrap,

    [switch]$SkipOfficial
)

$ErrorActionPreference = "Stop"
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

if ([string]::IsNullOrWhiteSpace($SkillRoot)) {
    $SkillRoot = Join-Path (Split-Path -Parent $scriptRoot) "skill\pc-hardware-workbench"
}

function Resolve-BasePython {
    param([string]$RequestedPython)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPython)) {
        return (Resolve-Path -LiteralPath $RequestedPython).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_VALIDATION_PYTHON)) {
        return (Resolve-Path -LiteralPath $env:CODEX_VALIDATION_PYTHON).Path
    }

    $userProfile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($userProfile)) {
        $userProfile = [Environment]::GetFolderPath("UserProfile")
    }
    $bundledPython = Join-Path $userProfile ".cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe"
    if (Test-Path -LiteralPath $bundledPython -PathType Leaf) {
        return (Resolve-Path -LiteralPath $bundledPython).Path
    }

    foreach ($name in @("python.exe", "python3.exe", "python")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return $command.Source
        }
    }
    throw "No Python interpreter found. Pass -PythonExe or set CODEX_VALIDATION_PYTHON."
}

function Remove-Utf8Bom {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if (
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF
    ) {
        [IO.File]::WriteAllBytes($Path, $bytes[3..($bytes.Length - 1)])
    }
}

$repoRoot = Split-Path -Parent $scriptRoot
$resolvedSkill = (Resolve-Path -LiteralPath $SkillRoot).Path
$skillName = Split-Path -Leaf $resolvedSkill

if ([string]::IsNullOrWhiteSpace($VenvPath)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_VALIDATION_VENV)) {
        $VenvPath = $env:CODEX_VALIDATION_VENV
    }
    else {
        $localAppData = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $env:LOCALAPPDATA
        }
        else {
            [Environment]::GetFolderPath("LocalApplicationData")
        }
        if ([string]::IsNullOrWhiteSpace($localAppData)) {
            throw "Cannot resolve the user's LocalAppData directory. Set CODEX_VALIDATION_VENV or pass -VenvPath."
        }
        $VenvPath = Join-Path $localAppData "pc-hardware-workbench\.validation-venv"
    }
}
$VenvPath = [IO.Path]::GetFullPath($VenvPath)
$venvPython = Join-Path $VenvPath "Scripts\python.exe"

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    if (-not $Bootstrap) {
        throw "Validation venv not found: $VenvPath. Re-run with -Bootstrap once to create it."
    }

    $basePython = Resolve-BasePython -RequestedPython $PythonExe
    New-Item -ItemType Directory -Path (Split-Path -Parent $VenvPath) -Force | Out-Null
    & $basePython -m venv $VenvPath
    if ($LASTEXITCODE -ne 0) {
        throw "Python venv creation failed with exit code $LASTEXITCODE."
    }
}

$pythonPathBefore = $env:PYTHONPATH
$pythonUtf8Before = $env:PYTHONUTF8
try {
    $env:PYTHONPATH = $null
    $env:PYTHONUTF8 = "1"

    $yamlProbe = & $venvPython -c "import importlib.util; print('1' if importlib.util.find_spec('yaml') else '0')"
    if ($LASTEXITCODE -ne 0 -or [string]$yamlProbe -ne "1") {
        if (-not $Bootstrap) {
            throw "PyYAML is missing from $VenvPath. Re-run with -Bootstrap once."
        }
        & $venvPython -m pip install `
            --disable-pip-version-check `
            --no-input `
            --index-url $IndexUrl `
            "PyYAML>=6.0,<7"
        if ($LASTEXITCODE -ne 0) {
            throw "PyYAML installation failed with exit code $LASTEXITCODE."
        }
    }

    Write-Host "Repository validator:"
    & $venvPython (Join-Path $scriptRoot "validate-skill.py") $resolvedSkill
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if ($SkipOfficial) {
        Write-Host "Official validator: SKIP"
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($OfficialValidatorPath)) {
        $userProfile = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            $userProfile = [Environment]::GetFolderPath("UserProfile")
        }
        $OfficialValidatorPath = Join-Path $userProfile ".codex\skills\.system\skill-creator\scripts\quick_validate.py"
    }
    $OfficialValidatorPath = (Resolve-Path -LiteralPath $OfficialValidatorPath).Path

    # quick_validate.py reads with locale defaults and cannot consume a BOM.
    # Validate a full structural copy with UTF-8 BOMs removed.
    $validationRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-skill-validate-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null
    try {
        $copiedSkill = Join-Path $validationRoot $skillName
        Copy-Item -LiteralPath $resolvedSkill -Destination $copiedSkill -Recurse
        Get-ChildItem -LiteralPath $copiedSkill -Recurse -File |
            Where-Object { $_.Extension -in @(".md", ".txt") } |
            ForEach-Object { Remove-Utf8Bom -Path $_.FullName }

        Write-Host "Official validator:"
        & $venvPython $OfficialValidatorPath $copiedSkill
        exit $LASTEXITCODE
    }
    finally {
        $resolvedValidationRoot = [IO.Path]::GetFullPath($validationRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (
            (Test-Path -LiteralPath $resolvedValidationRoot) -and
            $resolvedValidationRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedValidationRoot).StartsWith("codex-skill-validate-")
        ) {
            Remove-Item -LiteralPath $resolvedValidationRoot -Recurse -Force
        }
    }
}
finally {
    $env:PYTHONPATH = $pythonPathBefore
    $env:PYTHONUTF8 = $pythonUtf8Before
}
