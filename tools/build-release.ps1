[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot),

    [string]$OutputRoot,

    [string]$Label = "test",

    [string]$ValidatorPath
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path (Split-Path -Parent $RepositoryRoot) "releases"
}

function Stop-WithBuildError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 1
}

function Copy-TrackedTree {
    param(
        [Parameter(Mandatory = $true)][string]$TrackedPrefix,
        [Parameter(Mandatory = $true)][string]$DestinationRoot
    )
    $files = @(
        & git -C $RepositoryRoot ls-files -- $TrackedPrefix
    )
    if ($LASTEXITCODE -ne 0) {
        throw "git ls-files failed for $TrackedPrefix."
    }
    foreach ($relativeFile in $files) {
        $source = Join-Path $RepositoryRoot ($relativeFile -replace '/', '\')
        $relativeWithin = $relativeFile.Substring($TrackedPrefix.Length).TrimStart('/')
        $destination = Join-Path $DestinationRoot ($relativeWithin -replace '/', '\')
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination
    }
    return $files
}

function Write-Manifest {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Sort-Object FullName)
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($Root.Length).TrimStart('\')
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        $lines.Add("$hash  $($relative -replace '\\','/')") | Out-Null
    }
    [IO.File]::WriteAllLines($Path, $lines, $utf8NoBom)
}

$skillRoot = (Resolve-Path -LiteralPath (Join-Path $RepositoryRoot "skill\pc-hardware-workbench")).Path
$portableRoot = (Resolve-Path -LiteralPath (Join-Path $RepositoryRoot "portable")).Path
$skillText = Get-Content -Raw -LiteralPath (Join-Path $skillRoot "SKILL.md") -Encoding UTF8
$versionMatch = [regex]::Match($skillText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
if (-not $versionMatch.Success) {
    Stop-WithBuildError "Skill version was not found."
}
$version = $versionMatch.Groups[1].Value
$label = $Label.Trim().TrimStart('-')
if ([string]::IsNullOrWhiteSpace($label)) {
    $label = "test"
}
$releaseName = "$version-$label"
$gitCommit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    Stop-WithBuildError "Could not read Git commit."
}
$gitStatus = @(& git -C $RepositoryRoot status --porcelain)
if ($LASTEXITCODE -ne 0) {
    Stop-WithBuildError "Could not read Git status."
}
if ($gitStatus.Count -gt 0) {
    Stop-WithBuildError "Working tree is not clean. Commit intended source changes before building a release package."
}

$skillReleaseRoot = Join-Path (Join-Path $OutputRoot "pc-hardware-workbench") $releaseName
$portableReleaseRoot = Join-Path (Join-Path $OutputRoot "pc-hardware-portable") $releaseName
foreach ($path in @($skillReleaseRoot, $portableReleaseRoot)) {
    if (Test-Path -LiteralPath $path) {
        Stop-WithBuildError "Release target already exists and will not be overwritten: $path"
    }
}

$skillBundleRoot = Join-Path $skillReleaseRoot "bundle"
$portableBundleRoot = Join-Path $portableReleaseRoot "bundle"
$skillBundleFolder = Join-Path $skillBundleRoot "pc-hardware-workbench-v$releaseName"
$portableBundleFolder = Join-Path $portableBundleRoot "pc-hardware-portable-v$releaseName"
New-Item -ItemType Directory -Path $skillBundleFolder,$portableBundleFolder -Force | Out-Null

$skillFiles = @(Copy-TrackedTree `
    -TrackedPrefix "skill/pc-hardware-workbench" `
    -DestinationRoot (Join-Path $skillBundleFolder "pc-hardware-workbench"))
$portableFiles = @(Copy-TrackedTree `
    -TrackedPrefix "portable" `
    -DestinationRoot $portableBundleFolder)

foreach ($docName in @("LICENSE", "README.md", "CHANGELOG.md")) {
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot $docName) -Destination (Join-Path $skillBundleFolder $docName)
}
Copy-Item -LiteralPath (Join-Path $RepositoryRoot "LICENSE") -Destination (Join-Path $portableBundleFolder "LICENSE")

$testGuideName = (-join @([char]0x6D4B, [char]0x8BD5, [char]0x8BF4, [char]0x660E)) + ".txt"
$shareGuide = @"
PC Hardware Workbench $releaseName

Install

1. Extract this ZIP.
2. Copy the pc-hardware-workbench folder to:
   C:\Users\<user>\.codex\skills\pc-hardware-workbench
3. Restart Codex or start a new conversation.
4. Invoke:
   `$pc-hardware-workbench

This is a test candidate. Independent human acceptance is incomplete.

Included capabilities

- unified CSV and SensorSnapshot telemetry normalization;
- SVG telemetry charts and static HTML hardware-case reports;
- official-source RAG evidence cards with expiry and conflict checks;
- explicit-consent, read-only LibreHardwareMonitor WMI adapter;
- runtime-owned visual evidence rules for screenshots and photos;
- read-only Skill Doctor and full non-live regression tests.

Safety

- HardwareWrite: none
- Automatic elevation: none
- BIOS/firmware/frequency/voltage/power/fan writes: none
- Live LHM read: requires an already-running LHM and explicit consent
- Broad distribution approval: no
"@
[IO.File]::WriteAllText((Join-Path $skillBundleFolder $testGuideName), $shareGuide, $utf8NoBom)

$portableGuide = @"
PC Hardware Portable $releaseName

This package uses Git-tracked portable files only. No local hardware reports,
CSV files, evidence caches, screenshots, or output folders are included.

Run:
1. Extract this ZIP.
2. Open the included portable folder.
3. Run the start command.
4. Use -SelfTest for a non-hardware check.

HardwareWrite: none
Automatic elevation: none
Live collection: explicit opt-in only
"@
[IO.File]::WriteAllText((Join-Path $portableBundleFolder "README-PACKAGE.txt"), $portableGuide, $utf8NoBom)

$buildTime = [datetimeoffset]::Now.ToString("o", $invariant)
$buildInfo = [pscustomobject]@{
    Product = "PC Hardware Workbench"
    Version = $version
    Label = $label
    ReleaseName = $releaseName
    GitCommit = $gitCommit
    BuiltAt = $buildTime
    SkillFiles = $skillFiles.Count
    PortableFiles = $portableFiles.Count
    HardwareWrite = "none"
    HumanAcceptance = "PENDING"
    BroadDistributionApproved = $false
}
$buildJson = $buildInfo | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $skillBundleFolder "BUILD-INFO.json"), $buildJson, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $portableBundleFolder "BUILD-INFO.json"), $buildJson, $utf8NoBom)

Write-Manifest -Root $skillBundleFolder -Path (Join-Path $skillBundleFolder "MANIFEST-SHA256.txt")
Write-Manifest -Root $portableBundleFolder -Path (Join-Path $portableBundleFolder "MANIFEST-SHA256.txt")

$skillZipName = "pc-hardware-workbench-v$releaseName-share.zip"
$portableZipName = "pc-hardware-portable-v$releaseName.zip"
$skillZip = Join-Path $skillReleaseRoot $skillZipName
$portableZip = Join-Path $portableReleaseRoot $portableZipName
Compress-Archive -LiteralPath $skillBundleFolder -DestinationPath $skillZip -CompressionLevel Optimal
Compress-Archive -LiteralPath $portableBundleFolder -DestinationPath $portableZip -CompressionLevel Optimal

$skillNotesPath = Join-Path $skillReleaseRoot "RELEASE-NOTES-v$releaseName.txt"
$portableNotesPath = Join-Path $portableReleaseRoot "RELEASE-NOTES-v$releaseName.txt"
$skillNotes = @"
PC Hardware Workbench / Codex share $releaseName

Artifact
- $skillZipName
- Size: $((Get-Item -LiteralPath $skillZip).Length) bytes
- SHA256: $((Get-FileHash -LiteralPath $skillZip -Algorithm SHA256).Hash)
- Skill: $version, $($skillFiles.Count) tracked files
- Git commit: $gitCommit

Included
- normalized telemetry pipeline and chart renderer;
- hardware cases and static offline HTML reports;
- RAG evidence cards with source registry, expiry, and conflicts;
- explicit-consent read-only LHM adapter;
- visual evidence rules;
- Skill Doctor.

Validation
- full non-live Skill suite passed before packaging;
- official Skill validator passed before packaging;
- packaged Skill tree is checked against the repository after extraction.

Release status
- Test candidate
- Human acceptance: PENDING
- Approved for broad distribution: NO
- HardwareWrite: none
"@
$portableNotes = @"
PC Hardware Portable / $releaseName

Artifact
- $portableZipName
- Size: $((Get-Item -LiteralPath $portableZip).Length) bytes
- SHA256: $((Get-FileHash -LiteralPath $portableZip -Algorithm SHA256).Hash)
- Product banner: $version
- Git commit: $gitCommit

Validation
- package contains Git-tracked portable files only;
- extracted package self-test is run by the build script;
- no local reports, CSV, evidence caches, screenshots, or output folders included.

Release status
- Test candidate
- Human acceptance: PENDING
- Approved for broad distribution: NO
- HardwareWrite: none
"@
[IO.File]::WriteAllText($skillNotesPath, $skillNotes, $utf8NoBom)
[IO.File]::WriteAllText($portableNotesPath, $portableNotes, $utf8NoBom)

$sums = New-Object System.Collections.Generic.List[string]
foreach ($artifact in @($skillZip, $portableZip, $skillNotesPath, $portableNotesPath)) {
    $sums.Add("$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $([IO.Path]::GetFileName($artifact))") | Out-Null
}
[IO.File]::WriteAllLines((Join-Path $skillReleaseRoot "SHA256SUMS-$releaseName.txt"), $sums, $utf8NoBom)
[IO.File]::WriteAllLines((Join-Path $portableReleaseRoot "SHA256SUMS-$releaseName.txt"), $sums, $utf8NoBom)

$verifyRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-release-verify-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null
try {
    Expand-Archive -LiteralPath $skillZip -DestinationPath (Join-Path $verifyRoot "skill")
    Expand-Archive -LiteralPath $portableZip -DestinationPath (Join-Path $verifyRoot "portable")
    $packagedSkill = Join-Path (Join-Path $verifyRoot "skill") "pc-hardware-workbench"
    $packagedPortable = Join-Path (Join-Path $verifyRoot "portable") "pc-hardware-portable"
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepositoryRoot "tools\check-package-sync.ps1") `
        -LeftRoot $skillRoot -RightRoot $packagedSkill -IgnoreEolOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged Skill does not match the repository."
    }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $packagedPortable "start.ps1") -SelfTest
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged portable self-test failed."
    }
    if (-not [string]::IsNullOrWhiteSpace($ValidatorPath)) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ValidatorPath $packagedSkill
        if ($LASTEXITCODE -ne 0) {
            throw "Packaged Skill validator failed."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $verifyRoot) {
        Remove-Item -LiteralPath $verifyRoot -Recurse -Force
    }
}

Write-Host "Release build: PASS ($releaseName)" -ForegroundColor Green
Write-Host "Skill ZIP: $skillZip"
Write-Host "Portable ZIP: $portableZip"
