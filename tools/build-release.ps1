[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [string]$OutputRoot,

    [string]$Label = "test",

    [string]$ValidatorPath
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
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
        & git -C $RepositoryRoot -c core.quotepath=false ls-files -- $TrackedPrefix
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
$gitStatus = @(& git -C $RepositoryRoot status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) {
    Stop-WithBuildError "Could not read Git status."
}
if ($gitStatus.Count -gt 0) {
    Stop-WithBuildError "Working tree is not clean. Commit intended source changes before building a release package."
}

$skillReleaseRoot = Join-Path (Join-Path $OutputRoot "pc-hardware-workbench") $releaseName
$portableReleaseRoot = Join-Path (Join-Path $OutputRoot "pc-hardware-portable") $releaseName
$dshReleaseRoot = Join-Path (Join-Path $OutputRoot "deepseek-harness-adapter") $releaseName
foreach ($path in @($skillReleaseRoot, $portableReleaseRoot, $dshReleaseRoot)) {
    if (Test-Path -LiteralPath $path) {
        Stop-WithBuildError "Release target already exists and will not be overwritten: $path"
    }
}

$skillBundleRoot = Join-Path $skillReleaseRoot "bundle"
$portableBundleRoot = Join-Path $portableReleaseRoot "bundle"
$dshBundleRoot = Join-Path $dshReleaseRoot "bundle"
$skillBundleFolder = Join-Path $skillBundleRoot "pc-hardware-workbench-v$releaseName"
$manualBundleRoot = Join-Path $skillReleaseRoot "manual-bundle"
$manualSkillFolder = Join-Path $manualBundleRoot "pc-hardware-workbench"
$portableBundleFolder = Join-Path $portableBundleRoot "pc-hardware-portable-v$releaseName"
$dshBundleFolder = Join-Path $dshBundleRoot "pc-hardware-workbench-deepseek-harness-v$releaseName"
New-Item -ItemType Directory -Path $skillBundleFolder,$manualSkillFolder,$portableBundleFolder,$dshBundleFolder -Force | Out-Null
$packageInstallerRoot = Join-Path $RepositoryRoot "tools\release-package"
if (-not (Test-Path -LiteralPath $packageInstallerRoot -PathType Container)) {
    Stop-WithBuildError "Release package installer templates are missing: $packageInstallerRoot"
}

$skillFiles = @(Copy-TrackedTree `
    -TrackedPrefix "skill/pc-hardware-workbench" `
    -DestinationRoot (Join-Path $skillBundleFolder "pc-hardware-workbench"))
$manualSkillFiles = @(Copy-TrackedTree `
    -TrackedPrefix "skill/pc-hardware-workbench" `
    -DestinationRoot $manualSkillFolder)
$portableFiles = @(Copy-TrackedTree `
    -TrackedPrefix "portable" `
    -DestinationRoot $portableBundleFolder)
$adapterFiles = @(Copy-TrackedTree `
    -TrackedPrefix "adapters/dsh" `
    -DestinationRoot $dshBundleFolder)
$dshSkillFiles = @(Copy-TrackedTree `
    -TrackedPrefix "skill/pc-hardware-workbench" `
    -DestinationRoot (Join-Path $dshBundleFolder "skill\pc-hardware-workbench"))

foreach ($docName in @("LICENSE", "README.md", "CHANGELOG.md")) {
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot $docName) -Destination (Join-Path $skillBundleFolder $docName)
}
foreach ($installerName in @(
    "Install-PC-Hardware-Workbench.ps1",
    "Install-PC-Hardware-Workbench.cmd"
)) {
    Copy-Item -LiteralPath (Join-Path $packageInstallerRoot $installerName) -Destination (Join-Path $skillBundleFolder $installerName)
}
Copy-Item -LiteralPath (Join-Path $RepositoryRoot "LICENSE") -Destination (Join-Path $portableBundleFolder "LICENSE")
Copy-Item -LiteralPath (Join-Path $RepositoryRoot "LICENSE") -Destination (Join-Path $dshBundleFolder "LICENSE")

$installGuideName = (-join @([char]0x5B89, [char]0x88C5, [char]0x8BF4, [char]0x660E)) + ".txt"
$shareGuide = @"
PC Hardware Workbench $releaseName

Install

1. Extract this ZIP.
2. Double-click Install-PC-Hardware-Workbench.cmd.
3. The installer copies the packaged Skill into:
   C:\Users\<user>\.codex\skills\pc-hardware-workbench
4. If an old installation exists, it is moved outside the Codex Skill scan
   directory to:
   C:\Users\<user>\.codex\skill-backups\pc-hardware-workbench
5. Restart Codex or start a new conversation.
6. Invoke:
   `$pc-hardware-workbench

This is a test candidate. Independent human acceptance is incomplete.

Included capabilities

- unified CSV and SensorSnapshot telemetry normalization;
- SVG telemetry charts and static HTML hardware-case reports;
- official-source RAG evidence cards with expiry and conflict checks;
- explicit-consent, read-only LibreHardwareMonitor loopback Web adapter with WMI fallback;
- runtime-owned visual evidence rules for screenshots and photos;
- read-only Skill Doctor and full non-live regression tests.

Safety

- HardwareWrite: none
- Automatic elevation: none
- BIOS/firmware/frequency/voltage/power/fan writes: none
- Live LHM read: requires an already-running LHM and explicit consent
- Broad distribution approval: no
"@
[IO.File]::WriteAllText((Join-Path $skillBundleFolder $installGuideName), $shareGuide, $utf8NoBom)

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
$dshBuildInfo = [pscustomobject]@{
    Product = "PC Hardware Workbench / DeepSeek Harness"
    Version = $version
    Label = $label
    ReleaseName = $releaseName
    GitCommit = $gitCommit
    BuiltAt = $buildTime
    AdapterFiles = $adapterFiles.Count
    SkillFiles = $dshSkillFiles.Count
    HardwareWrite = "none"
    HumanAcceptance = "PENDING"
    BroadDistributionApproved = $false
}
$dshBuildJson = $dshBuildInfo | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText((Join-Path $dshBundleFolder "BUILD-INFO.json"), $dshBuildJson, $utf8NoBom)

Write-Manifest -Root $skillBundleFolder -Path (Join-Path $skillBundleFolder "MANIFEST-SHA256.txt")
Write-Manifest -Root $portableBundleFolder -Path (Join-Path $portableBundleFolder "MANIFEST-SHA256.txt")
Write-Manifest -Root $dshBundleFolder -Path (Join-Path $dshBundleFolder "MANIFEST-SHA256.txt")

$skillZipName = "pc-hardware-workbench-v$releaseName-installer.zip"
$manualSkillZipName = "pc-hardware-workbench-v$releaseName-manual.zip"
$portableZipName = "pc-hardware-portable-v$releaseName.zip"
$dshZipName = "pc-hardware-workbench-deepseek-harness-v$releaseName.zip"
$skillZip = Join-Path $skillReleaseRoot $skillZipName
$manualSkillZip = Join-Path $skillReleaseRoot $manualSkillZipName
$portableZip = Join-Path $portableReleaseRoot $portableZipName
$dshZip = Join-Path $dshReleaseRoot $dshZipName
Compress-Archive -LiteralPath $skillBundleFolder -DestinationPath $skillZip -CompressionLevel Optimal
Compress-Archive -LiteralPath $manualSkillFolder -DestinationPath $manualSkillZip -CompressionLevel Optimal
Compress-Archive -LiteralPath $portableBundleFolder -DestinationPath $portableZip -CompressionLevel Optimal
Compress-Archive -LiteralPath $dshBundleFolder -DestinationPath $dshZip -CompressionLevel Optimal

$skillNotesPath = Join-Path $skillReleaseRoot "RELEASE-NOTES-v$releaseName.txt"
$portableNotesPath = Join-Path $portableReleaseRoot "RELEASE-NOTES-v$releaseName.txt"
$dshNotesPath = Join-Path $dshReleaseRoot "RELEASE-NOTES-v$releaseName.txt"
$skillNotes = @"
PC Hardware Workbench / Codex share $releaseName

Artifact
- $skillZipName (double-click installer package)
- $manualSkillZipName (manual extraction package)
- Size: $((Get-Item -LiteralPath $skillZip).Length) bytes
- SHA256: $((Get-FileHash -LiteralPath $skillZip -Algorithm SHA256).Hash)
- Manual ZIP SHA256: $((Get-FileHash -LiteralPath $manualSkillZip -Algorithm SHA256).Hash)
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
$dshNotes = @"
PC Hardware Workbench / DeepSeek Harness $releaseName

Artifact
- $dshZipName
- Size: $((Get-Item -LiteralPath $dshZip).Length) bytes
- SHA256: $((Get-FileHash -LiteralPath $dshZip -Algorithm SHA256).Hash)
- Skill: $version, $($dshSkillFiles.Count) tracked files
- Adapter files: $($adapterFiles.Count)
- Git commit: $gitCommit

Included
- AGENTS.md and DEEPSEEK.md adapter entries;
- complete Skill tree with telemetry, cases, RAG, LHM, visual evidence, and Doctor;
- no local hardware reports, telemetry, images, caches, or secrets.

Validation
- packaged Skill tree is checked against the repository after extraction;
- official Skill validator is run on the packaged tree.

Release status
- Test candidate
- Human acceptance: PENDING
- Approved for broad distribution: NO
- HardwareWrite: none
"@
[IO.File]::WriteAllText($skillNotesPath, $skillNotes, $utf8NoBom)
[IO.File]::WriteAllText($portableNotesPath, $portableNotes, $utf8NoBom)
[IO.File]::WriteAllText($dshNotesPath, $dshNotes, $utf8NoBom)

$skillSums = New-Object System.Collections.Generic.List[string]
foreach ($artifact in @($skillZip, $manualSkillZip, $skillNotesPath)) {
    $skillSums.Add("$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $([IO.Path]::GetFileName($artifact))") | Out-Null
}
$portableSums = New-Object System.Collections.Generic.List[string]
foreach ($artifact in @($portableZip, $portableNotesPath)) {
    $portableSums.Add("$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $([IO.Path]::GetFileName($artifact))") | Out-Null
}
$dshSums = New-Object System.Collections.Generic.List[string]
foreach ($artifact in @($dshZip, $dshNotesPath)) {
    $dshSums.Add("$((Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)  $([IO.Path]::GetFileName($artifact))") | Out-Null
}
[IO.File]::WriteAllLines((Join-Path $skillReleaseRoot "SHA256SUMS-$releaseName.txt"), $skillSums, $utf8NoBom)
[IO.File]::WriteAllLines((Join-Path $portableReleaseRoot "SHA256SUMS-$releaseName.txt"), $portableSums, $utf8NoBom)
[IO.File]::WriteAllLines((Join-Path $dshReleaseRoot "SHA256SUMS-$releaseName.txt"), $dshSums, $utf8NoBom)

$verifyRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-release-verify-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $verifyRoot -Force | Out-Null
try {
    Expand-Archive -LiteralPath $skillZip -DestinationPath (Join-Path $verifyRoot "skill-installer")
    Expand-Archive -LiteralPath $manualSkillZip -DestinationPath (Join-Path $verifyRoot "skill-manual")
    Expand-Archive -LiteralPath $portableZip -DestinationPath (Join-Path $verifyRoot "portable")
    Expand-Archive -LiteralPath $dshZip -DestinationPath (Join-Path $verifyRoot "dsh")
    $packagedSkillOuter = Join-Path (Join-Path $verifyRoot "skill-installer") "pc-hardware-workbench-v$releaseName"
    $packagedPortableOuter = Join-Path (Join-Path $verifyRoot "portable") "pc-hardware-portable-v$releaseName"
    $packagedDshOuter = Join-Path (Join-Path $verifyRoot "dsh") "pc-hardware-workbench-deepseek-harness-v$releaseName"
    $packagedSkill = Join-Path $packagedSkillOuter "pc-hardware-workbench"
    $packagedManualSkill = Join-Path (Join-Path $verifyRoot "skill-manual") "pc-hardware-workbench"
    $packagedPortable = $packagedPortableOuter
    $packagedDshSkill = Join-Path $packagedDshOuter "skill\pc-hardware-workbench"
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepositoryRoot "tools\check-package-sync.ps1") `
        -LeftRoot $skillRoot -RightRoot $packagedSkill -IgnoreEolOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged Skill does not match the repository."
    }
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepositoryRoot "tools\check-package-sync.ps1") `
        -LeftRoot $skillRoot -RightRoot $packagedManualSkill -IgnoreEolOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Manual Skill ZIP does not match the repository."
    }
    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $RepositoryRoot "tools\check-package-sync.ps1") `
        -LeftRoot $skillRoot -RightRoot $packagedDshSkill -IgnoreEolOnly
    if ($LASTEXITCODE -ne 0) {
        throw "Packaged DSH Skill does not match the repository."
    }
    foreach ($adapterFile in @("AGENTS.md", "DEEPSEEK.md", "README.md")) {
        if (-not (Test-Path -LiteralPath (Join-Path $packagedDshOuter $adapterFile) -PathType Leaf)) {
            throw "Packaged DSH adapter is missing $adapterFile."
        }
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
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ValidatorPath $packagedDshSkill
        if ($LASTEXITCODE -ne 0) {
            throw "Packaged DSH Skill validator failed."
        }
    }
}
finally {
    if (Test-Path -LiteralPath $verifyRoot) {
        Remove-Item -LiteralPath $verifyRoot -Recurse -Force
    }
}

$skillCurrent = @"
Current PC Hardware Workbench release: $releaseName

Path:
$releaseName\$skillZipName

Skill: $version
Git commit: $gitCommit
HardwareWrite: none
Live LHM: explicit consent only
Human acceptance: PENDING
Approved for broad distribution: NO
"@
$portableCurrent = @"
Current PC Hardware Portable release: $releaseName

Path:
$releaseName\$portableZipName

Product banner: $version
Git commit: $gitCommit
HardwareWrite: none
Live collection: explicit opt-in only
Human acceptance: PENDING
Approved for broad distribution: NO
"@
$dshCurrent = @"
Current DeepSeek Harness adapter release: $releaseName

Path:
$releaseName\$dshZipName

Skill: $version
Git commit: $gitCommit
HardwareWrite: none
Human acceptance: PENDING
Approved for broad distribution: NO
"@
[IO.File]::WriteAllText((Join-Path (Join-Path $OutputRoot "pc-hardware-workbench") "CURRENT.txt"), $skillCurrent, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path (Join-Path $OutputRoot "pc-hardware-portable") "CURRENT.txt"), $portableCurrent, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path (Join-Path $OutputRoot "deepseek-harness-adapter") "CURRENT.txt"), $dshCurrent, $utf8NoBom)

Write-Host "Release build: PASS ($releaseName)" -ForegroundColor Green
Write-Host "Skill ZIP: $skillZip"
Write-Host "Portable ZIP: $portableZip"
Write-Host "DSH ZIP: $dshZip"
