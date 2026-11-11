[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent $PSScriptRoot
}
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath

$skillRelativeRoot = "skill/pc-hardware-workbench"
$skillRoot = Join-Path $RepositoryRoot $skillRelativeRoot
$orreryRoot = Join-Path $RepositoryRoot "docs\skill-evolution\orrery"
$curationPath = Join-Path $orreryRoot "data\curation.json"
$uiPath = Join-Path $orreryRoot "data\current-ui.json"
$rendererTemplatePath = Join-Path $RepositoryRoot "tools\templates\orrery-renderer.html"
$manifestPath = Join-Path $orreryRoot "data\manifest.json"
$indexPath = Join-Path $orreryRoot "index.html"
$frozenPath = Join-Path $orreryRoot "FROZEN.json"
$skillPath = Join-Path $skillRoot "SKILL.md"

foreach ($required in @($curationPath, $uiPath, $rendererTemplatePath, $skillPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing orrery build input: $required"
    }
}

$utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

function Get-Sha256Hex {
    param([byte[]]$Bytes)

    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        return -join (
            $algorithm.ComputeHash($Bytes) |
                ForEach-Object { $_.ToString("X2", $invariant) }
        )
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-LfText {
    param([string]$Text)
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-CanonicalText {
    param([string]$Path)
    return ConvertTo-LfText ([System.IO.File]::ReadAllText($Path, $utf8Strict))
}

function Get-Sha256ForFile {
    param([string]$Path)
    return Get-Sha256Hex -Bytes ([System.IO.File]::ReadAllBytes($Path))
}

function Round-Metric {
    param([double]$Value)
    return [Math]::Round($Value, 2, [MidpointRounding]::AwayFromZero)
}

function Get-SectorId {
    param([string]$RelativePath)

    if ($RelativePath -eq "SKILL.md") { return "core" }
    if ($RelativePath.StartsWith("agents/", [StringComparison]::Ordinal)) { return "core" }
    if ($RelativePath.StartsWith("assets/", [StringComparison]::Ordinal)) { return "integration" }
    if ($RelativePath.StartsWith("references/integration/", [StringComparison]::Ordinal)) { return "integration" }
    if ($RelativePath.StartsWith("references/triage/", [StringComparison]::Ordinal)) { return "triage" }
    if ($RelativePath.StartsWith("references/tuning/", [StringComparison]::Ordinal)) { return "tuning" }
    if ($RelativePath.StartsWith("references/upgrade/", [StringComparison]::Ordinal)) { return "upgrade" }
    if ($RelativePath.StartsWith("scripts/", [StringComparison]::Ordinal)) { return "scripts" }
    if ($RelativePath.StartsWith("tests/", [StringComparison]::Ordinal)) { return "tests" }
    throw "No orrery sector mapping for $RelativePath"
}

function Get-CategoryId {
    param([string]$RelativePath)

    if ($RelativePath -eq "SKILL.md") { return "SKILL.md" }
    return ($RelativePath -split "/")[0]
}

function Get-BaseWeight {
    param(
        [string]$RelativePath,
        [string]$SectorId
    )

    if ($SectorId -eq "core") { return 1.55 }
    if ($SectorId -eq "tests" -and $RelativePath -match "results-") { return 0.68 }
    if ($SectorId -eq "tests") { return 0.82 }
    if ($SectorId -eq "scripts") { return 1.00 }
    return 0.92
}

$curation = [System.IO.File]::ReadAllText($curationPath, $utf8Strict) | ConvertFrom-Json
$ui = [System.IO.File]::ReadAllText($uiPath, $utf8Strict) | ConvertFrom-Json
$snapshotFrozenAt = [string]$curation.snapshot.frozenAt
$snapshotChanges = [string]$curation.snapshot.changes
if ([string]::IsNullOrWhiteSpace($snapshotFrozenAt) -or [string]::IsNullOrWhiteSpace($snapshotChanges)) {
    throw "Curation snapshot metadata is incomplete."
}
$rendererTemplate = [System.IO.File]::ReadAllText($rendererTemplatePath, $utf8Strict)
$skillText = [System.IO.File]::ReadAllText($skillPath, $utf8Strict)

$versionMatch = [regex]::Match($skillText, '(?m)^\s*version:\s*"([^"]+)"\s*$')
if (-not $versionMatch.Success) {
    throw "SKILL.md metadata.version is missing."
}
$skillVersion = $versionMatch.Groups[1].Value
$nameMatch = [regex]::Match($skillText, '(?m)^name:\s*([^\r\n]+)\s*$')
$skillName = if ($nameMatch.Success) { $nameMatch.Groups[1].Value.Trim() } else { "pc-hardware-workbench" }

$gitOutput = & git -C $RepositoryRoot ls-files -- $skillRelativeRoot
if ($LASTEXITCODE -ne 0) {
    throw "git ls-files failed for $skillRelativeRoot"
}
$tracked = @(
    $gitOutput |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        Sort-Object -Culture "en-US" -CaseSensitive
)
if ($tracked.Count -eq 0) {
    throw "No Git-tracked Skill files were found."
}

$relativeFiles = @(
    $tracked |
        ForEach-Object {
            $_.Substring($skillRelativeRoot.Length + 1).Replace("\", "/")
        }
)
$curatedFiles = @($curation.files.PSObject.Properties.Name)
$missingCuration = @($relativeFiles | Where-Object { $curatedFiles -notcontains $_ })
$extraCuration = @($curatedFiles | Where-Object { $relativeFiles -notcontains $_ })
if ($missingCuration.Count -gt 0 -or $extraCuration.Count -gt 0) {
    throw "Curation and Git-tracked file sets differ. Missing curation: $($missingCuration -join ', '); extra curation: $($extraCuration -join ', ')"
}

$pathByBasename = @{}
foreach ($relativePath in $relativeFiles) {
    $basename = Split-Path -Leaf $relativePath
    if (-not $pathByBasename.ContainsKey($basename)) {
        $pathByBasename[$basename] = New-Object System.Collections.Generic.List[string]
    }
    $pathByBasename[$basename].Add($relativePath)
}

$outbound = @{}
$inbound = @{}
foreach ($relativePath in $relativeFiles) {
    $outbound[$relativePath] = New-Object System.Collections.Generic.HashSet[string]
    $inbound[$relativePath] = New-Object System.Collections.Generic.HashSet[string]
}

foreach ($sourceRelative in $relativeFiles) {
    $sourcePath = Join-Path $skillRoot $sourceRelative
    $sourceText = [System.IO.File]::ReadAllText($sourcePath, $utf8Strict)
    $sourceDirectory = Split-Path -Parent $sourcePath

    foreach ($linkMatch in [regex]::Matches($sourceText, '\[[^\]]+\]\(([^)\s]+)(?:\s+[^)]*)?\)')) {
        $targetToken = $linkMatch.Groups[1].Value.Trim("<", ">")
        $targetToken = ($targetToken -split "[?#]", 2)[0]
        if (-not $targetToken -or $targetToken -match "^(?:https?:|mailto:|data:)") {
            continue
        }
        try {
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $sourceDirectory $targetToken))
        }
        catch {
            continue
        }
        if (-not $candidate.StartsWith($skillRoot, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }
        $targetRelative = $candidate.Substring($skillRoot.Length).
            TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).
            Replace("\", "/")
        if ($targetRelative -ne $sourceRelative -and $relativeFiles -contains $targetRelative) {
            [void]$outbound[$sourceRelative].Add($targetRelative)
            [void]$inbound[$targetRelative].Add($sourceRelative)
        }
    }

    foreach ($targetRelative in $relativeFiles) {
        if ($targetRelative -eq $sourceRelative) { continue }
        $basename = Split-Path -Leaf $targetRelative
        if ($pathByBasename[$basename].Count -ne 1) { continue }
        $escapedRelative = [regex]::Escape($targetRelative)
        $escapedBasename = [regex]::Escape($basename)
        $tokenPattern = "(?<![A-Za-z0-9._/-])(?:$escapedRelative|$escapedBasename)(?![A-Za-z0-9._/-])"
        if ([regex]::IsMatch($sourceText, $tokenPattern)) {
            [void]$outbound[$sourceRelative].Add($targetRelative)
            [void]$inbound[$targetRelative].Add($sourceRelative)
        }
    }
}

$fileRecords = New-Object System.Collections.Generic.List[object]
foreach ($relativePath in $relativeFiles) {
    $curated = $curation.files.PSObject.Properties[$relativePath].Value
    if (-not $curation.clusters.PSObject.Properties[$curated.cluster]) {
        throw "Unknown cluster '$($curated.cluster)' for $relativePath"
    }
    $sectorId = Get-SectorId $relativePath
    $categoryId = Get-CategoryId $relativePath
    $filePath = Join-Path $skillRoot $relativePath
    $bytes = $utf8NoBom.GetBytes((Get-CanonicalText $filePath))
    $inboundCount = $inbound[$relativePath].Count
    $outboundCount = $outbound[$relativePath].Count
    $baseWeight = Get-BaseWeight -RelativePath $relativePath -SectorId $sectorId
    $inboundBoost = [Math]::Min(0.34, [Math]::Log([double](1 + $inboundCount), 2.0) * 0.105)
    $outboundBoost = [Math]::Min(0.12, [Math]::Log([double](1 + $outboundCount), 2.0) * 0.035)
    $weight = Round-Metric ($baseWeight + $inboundBoost + $outboundBoost)
    $sector = $curation.sectors.PSObject.Properties[$sectorId].Value
    $cluster = $curation.clusters.PSObject.Properties[$curated.cluster].Value

    $fileRecords.Add([pscustomobject][ordered]@{
        path = $relativePath
        name = Split-Path -Leaf $relativePath
        category = $categoryId
        sector = $sectorId
        sectorName = [string]$sector.name
        sectorColor = [string]$sector.color
        cluster = [string]$curated.cluster
        clusterName = [string]$cluster.name
        role = [string]$curated.role
        summary = [string]$curated.summary
        when = [string]$cluster.when
        boundaries = @($sector.boundaries)
        anchor = if ($curated.PSObject.Properties["anchor"]) {
            [bool]$curated.PSObject.Properties["anchor"].Value
        }
        else {
            $false
        }
        bytes = $bytes.Length
        sha256 = Get-Sha256Hex -Bytes $bytes
        inboundCount = $inboundCount
        outboundCount = $outboundCount
        baseWeight = Round-Metric $baseWeight
        weight = $weight
        related = @()
    }) | Out-Null
}

$recordByPath = @{}
foreach ($record in $fileRecords) {
    $recordByPath[$record.path] = $record
}

foreach ($record in $fileRecords) {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($path in $outbound[$record.path]) {
        if (-not $candidates.Contains($path)) { $candidates.Add($path) }
    }
    $curated = $curation.files.PSObject.Properties[$record.path].Value
    if ($curated.PSObject.Properties["related"]) {
        foreach ($path in @($curated.related)) {
            if (-not $candidates.Contains([string]$path)) { $candidates.Add([string]$path) }
        }
    }
    foreach ($path in ($inbound[$record.path] | Sort-Object -Culture "en-US" -CaseSensitive)) {
        if (-not $candidates.Contains($path)) { $candidates.Add($path) }
    }
    $related = @(
        $candidates |
            Where-Object { $_ -ne $record.path -and $recordByPath.ContainsKey($_) } |
            Select-Object -First 4
    )
    $record.related = $related
}

$sortedRecords = @(
    $fileRecords |
        Sort-Object @{ Expression = { [int]$curation.sectors.PSObject.Properties[$_.sector].Value.ring } },
                      @{ Expression = { [string]$_.sector } },
                      @{ Expression = { [string]$_.cluster } },
                      @{ Expression = { [string]$_.path } } -Culture "en-US" -CaseSensitive
)
$weights = @($sortedRecords | ForEach-Object { [double]$_.weight })
$weightMin = ($weights | Measure-Object -Minimum).Minimum
$weightMax = ($weights | Measure-Object -Maximum).Maximum

$sectorRecords = New-Object System.Collections.Generic.List[object]
foreach ($sectorProperty in $curation.sectors.PSObject.Properties) {
    $sectorId = $sectorProperty.Name
    $sectorConfig = $sectorProperty.Value
    $sectorFiles = @($sortedRecords | Where-Object { $_.sector -eq $sectorId })
    $sectorWeight = 0.0
    foreach ($record in $sectorFiles) { $sectorWeight += [double]$record.weight }
    $sectorRecords.Add([pscustomobject][ordered]@{
        id = $sectorId
        name = [string]$sectorConfig.name
        folder = [string]$sectorConfig.folder
        root = switch ($sectorId) {
            "core" { "" }
            "integration" { "references/integration/" }
            "triage" { "references/triage/" }
            "tuning" { "references/tuning/" }
            "upgrade" { "references/upgrade/" }
            "scripts" { "scripts/" }
            "tests" { "tests/" }
            default { throw "No root mapping for sector $sectorId" }
        }
        summary = [string]$sectorConfig.summary
        boundaries = @($sectorConfig.boundaries)
        ring = [int]$sectorConfig.ring
        orbitScale = [double]$sectorConfig.orbitScale
        flatten = [double]$sectorConfig.flatten
        tilt = [double]$sectorConfig.tilt
        inclination = [double]$sectorConfig.inclination
        angle = [double]$sectorConfig.angle
        speed = [double]$sectorConfig.speed
        color = [string]$sectorConfig.color
        fileCount = $sectorFiles.Count
        weight = Round-Metric $sectorWeight
    }) | Out-Null
}
$sortedSectors = @($sectorRecords | Sort-Object ring, name -Culture "en-US" -CaseSensitive)
$sectorWeights = @($sortedSectors | Where-Object { $_.id -ne "core" } | ForEach-Object { [double]$_.weight })
$sectorWeightMin = ($sectorWeights | Measure-Object -Minimum).Minimum
$sectorWeightMax = ($sectorWeights | Measure-Object -Maximum).Maximum

$categoryCounts = [ordered]@{}
foreach ($group in @($sortedRecords | Group-Object category | Sort-Object Name -Culture "en-US" -CaseSensitive)) {
    $categoryCounts[$group.Name] = $group.Count
}
$sectorCounts = [ordered]@{}
foreach ($sector in $sortedSectors) {
    $sectorCounts[$sector.id] = $sector.fileCount
}

$aggregateLines = @(
    $sortedRecords |
        ForEach-Object { "$($_.path)`0$($_.sha256)`0$($_.bytes)" }
) -join "`n"
$aggregateSha256 = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($aggregateLines)

$manifest = [pscustomobject][ordered]@{
    schemaVersion = 1
    sourceKind = "git-tracked"
    sourceCommand = "git ls-files -- skill/pc-hardware-workbench"
    skillRoot = $skillRelativeRoot
    skillName = $skillName
    skillVersion = $skillVersion
    fileCount = $sortedRecords.Count
    categoryCounts = [pscustomobject]$categoryCounts
    sectorCounts = [pscustomobject]$sectorCounts
    aggregateSha256 = $aggregateSha256
    weightModel = [pscustomobject][ordered]@{
        purpose = "structural importance, not bytes or real hardware telemetry"
        formula = "role base + min(0.34, log2(1 + inbound) * 0.105) + min(0.12, log2(1 + outbound) * 0.035)"
        fileDiameter = "area-proportional between 7px and 15px"
        sectorDiameter = "area-proportional between 28px and 50px"
        fileWeightMin = $weightMin
        fileWeightMax = $weightMax
        sectorWeightMin = $sectorWeightMin
        sectorWeightMax = $sectorWeightMax
        orbitSpeedMultiplier = 1.0
    }
    sectors = $sortedSectors
    files = $sortedRecords
}

$manifestJson = $manifest | ConvertTo-Json -Depth 20 -Compress
$manifestJson = $manifestJson.Replace("`r`n", "`n") + "`n"

$orbitSpeedMultiplier = 1.0
$groupsObject = [ordered]@{}
foreach ($sector in $sortedSectors) {
    $groupsObject[$sector.id] = [pscustomobject][ordered]@{
        name = $sector.name
        folder = $sector.folder
        root = $sector.root
        ring = $sector.ring
        orbitScale = $sector.orbitScale
        flatten = $sector.flatten
        focusSide = 0
        tilt = $sector.tilt
        inclination = $sector.inclination
        color = $sector.color
        summary = $sector.summary
        angle = $sector.angle
        speed = Round-Metric ($sector.speed * $orbitSpeedMultiplier)
    }
}

$fileObjectList = New-Object System.Collections.Generic.List[object]
foreach ($record in $sortedRecords) {
    $sector = $sortedSectors | Where-Object { $_.id -eq $record.sector } | Select-Object -First 1
    $root = [string]$sector.root
    $rawPath = if ($root -and $record.path.StartsWith($root, [StringComparison]::Ordinal)) {
        $record.path.Substring($root.Length)
    }
    else {
        $record.path
    }
    $relatedNames = @(
        @($record.related) |
            ForEach-Object { ($_ -split "/")[-1] } |
            Where-Object { $_ } |
            Select-Object -Unique
    )
    $fileObjectList.Add([pscustomobject][ordered]@{
        group = $record.sector
        path = $record.name
        location = "$root$rawPath"
        name = $record.name
        role = $record.role
        what = $record.summary
        when = $record.when
        boundaries = @($sector.boundaries)
        related = $relatedNames
        weight = $record.weight
        color = $sector.color
    }) | Out-Null
}

$groupsJson = $groupsObject | ConvertTo-Json -Depth 20 -Compress
$filesJson = ConvertTo-Json -InputObject @($fileObjectList.ToArray()) -Depth 20 -Compress
$groupsJson = $groupsJson.Replace("`r`n", "`n")
$filesJson = $filesJson.Replace("`r`n", "`n")

$dataStart = $rendererTemplate.IndexOf("    const GROUPS = {", [StringComparison]::Ordinal)
$dataEnd = $rendererTemplate.IndexOf("    const FILES_BY_PATH =", [StringComparison]::Ordinal)
if ($dataStart -lt 0 -or $dataEnd -le $dataStart) {
    throw "The orrery renderer template does not expose the expected data blocks."
}

$generatedData = @"
    const GROUPS = $groupsJson;

    const FILES = $filesJson;

"@
$generatedHtml = $rendererTemplate.Substring(0, $dataStart) + $generatedData + $rendererTemplate.Substring($dataEnd)

function Expand-UiTemplate {
    param([Parameter(Mandatory = $true)][string]$Value)
    return $Value.
        Replace("{{version}}", $skillVersion).
        Replace("{{fileCount}}", [string]$sortedRecords.Count).
        Replace("{{sectorCount}}", [string]$sortedSectors.Count).
        Replace("{{shortSha}}", $aggregateSha256.Substring(0, 12))
}

$uiTitle = Expand-UiTemplate $ui.title
$uiDescription = Expand-UiTemplate $ui.description
$uiMetadataName = Expand-UiTemplate $ui.metadataName
$uiNavCurrent = Expand-UiTemplate $ui.navCurrent
$uiNavArchive = if ([string]::IsNullOrWhiteSpace($ui.navArchive)) {
    ""
}
else {
    Expand-UiTemplate $ui.navArchive
}
$uiBackLabel = Expand-UiTemplate $ui.backLabel
$uiHeaderSubtitle = Expand-UiTemplate $ui.headerSubtitle
$uiStatFiles = Expand-UiTemplate $ui.statFiles
$uiStatSectors = Expand-UiTemplate $ui.statSectors
$uiStatStatus = Expand-UiTemplate $ui.statStatus
$uiBannerHtml = Expand-UiTemplate $ui.bannerHtml
$uiDossierKicker = Expand-UiTemplate $ui.dossierKicker
$uiDossierHeading = Expand-UiTemplate $ui.dossierHeading
$uiDossierLead = Expand-UiTemplate $ui.dossierLead
$uiOverviewNote = Expand-UiTemplate $ui.overviewNote
$uiStageAria = Expand-UiTemplate $ui.stageAria
$uiArchiveNav = if ([string]::IsNullOrWhiteSpace($uiNavArchive)) {
    ""
}
else {
    "`n      <a href=""archive/1.5.2/"">$uiNavArchive</a>"
}

$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)<meta name="description" content="[^"]*">',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        '<meta name="description" content="' + $uiDescription + '">'
    },
    1
)
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)<title>.*?</title>',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        "<title>$uiTitle</title>"
    },
    1
)
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)<nav class="global-nav"[^>]*>.*?</nav>',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        @"
<nav class="global-nav" aria-label="$($ui.navAria)">
      <a href="../">$uiBackLabel</a>
      <span aria-current="page">$uiNavCurrent</span>$uiArchiveNav
    </nav>
"@
    },
    1
)
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)<header class="app-header"[^>]*>.*?</header>',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        @"
<header class="app-header">
      <div class="brand">
        <div class="brand-mark" aria-hidden="true"></div>
        <div>
          <h1>$($ui.headerTitle)</h1>
          <p>$uiHeaderSubtitle</p>
        </div>
      </div>
      <div class="header-stats" aria-label="$($ui.statsAria)">
        <span>$uiStatFiles</span>
        <span>$uiStatSectors</span>
        <span>$uiStatStatus</span>
      </div>
    </header>
"@
    },
    1
)
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)<div class="snapshot-banner"[^>]*>.*?</div>',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        '<div class="snapshot-banner" role="note">' + $uiBannerHtml + '</div>'
    },
    1
)
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '<section class="stage-shell"[^>]*>',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        '<section class="stage-shell" aria-label="' + $uiStageAria + '">'
    },
    1
)
$renderOverviewReplacement = @'
    function renderOverview() {
      dossier.style.setProperty("--panel-accent", GROUPS.core.color);
      dossier.innerHTML = `
        <div class="dossier-inner">
          <div class="dossier-kicker">__DSE_DOSSIER_KICKER__</div>
          <h2>__DSE_DOSSIER_HEADING__</h2>
          <p class="dossier-lead">__DSE_DOSSIER_LEAD__</p>
          <div class="overview-list">
            ${Object.entries(GROUPS).sort((a, b) => a[1].ring - b[1].ring).map(([id, group]) => `
              <div class="overview-row" style="--row-color:${group.color}">
                <em>R${group.ring}</em>
                <span><b>${escapeHtml(group.name)}</b><br>${escapeHtml(group.summary)}</span>
                <em>${FILES_BY_GROUP[id].length}</em>
              </div>
            `).join("")}
          </div>
          <p class="overview-note">__DSE_OVERVIEW_NOTE__</p>
        </div>
      `;
    }

    function renderGroupOverview
'@
$renderOverviewReplacement = $renderOverviewReplacement.
    Replace("__DSE_DOSSIER_KICKER__", $uiDossierKicker).
    Replace("__DSE_DOSSIER_HEADING__", $uiDossierHeading).
    Replace("__DSE_DOSSIER_LEAD__", $uiDossierLead).
    Replace("__DSE_OVERVIEW_NOTE__", $uiOverviewNote)
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)    function renderOverview\(\) \{.*?\n    \}\r?\n\r?\n    function renderGroupOverview',
    [System.Text.RegularExpressions.MatchEvaluator]{
        param($match)
        $renderOverviewReplacement
    },
    1
)

$currentStyle = @'
<style id="dse-current-orrery-adjustments">
  .file-name {
    max-width: 160px;
    font-size: 11px;
  }

  .stage.compact-labels .file-name {
    max-width: 132px;
    font-size: 10px;
  }

  .stage.compact-labels .file-node:not(.is-anchor) .file-name {
    opacity: .56;
  }

  .stage.compact-labels .file-node.is-anchor .file-name {
    opacity: .78;
  }

  .stage.compact-labels .file-node.is-related:not(.is-active) .file-name {
    opacity: 1;
    color: #dcecf5;
    background: rgba(6, 10, 14, .76);
  }

  .stage.has-file-selection .file-node:not(.is-active):not(.is-related):not(:hover):not(:focus-visible) .file-name {
    opacity: .3;
    color: #74808a;
    background: rgba(4, 8, 11, .28);
  }

  .stage.compact-labels .file-node:hover .file-name,
  .stage.compact-labels .file-node:focus-visible .file-name,
  .stage.compact-labels .file-node.is-active .file-name,
  .stage.compact-labels .file-node.is-related:not(.is-active) .file-name {
    opacity: 1;
  }

  @media (min-width: 621px) and (max-width: 1120px) {
    .workspace {
      grid-template-columns: minmax(0, 1fr);
      height: auto;
    }

    .stage-shell {
      height: min(680px, 74svh);
      min-height: 560px;
    }

    .dossier {
      min-height: 420px;
      max-height: none;
    }
  }

  @media (max-width: 620px) {
    .global-nav {
      min-height: 48px;
      gap: 8px;
    }

    .global-nav a {
      min-height: 40px;
      font-size: 12px;
    }

    .global-nav > span {
      display: none;
    }

    .category-node:not(.is-core) .category-label {
      display: none;
    }
  }
</style>
'@
$generatedHtml = [regex]::Replace(
    $generatedHtml,
    '(?s)\s*<style id="dse-current-orrery-adjustments">.*?</style>',
    ''
)
$generatedHtml = $generatedHtml.Replace("</head>", $currentStyle + "`n</head>")

$generatedHtml = ConvertTo-LfText $generatedHtml
$pageBytes = $utf8NoBom.GetBytes($generatedHtml)
$pageSha256 = Get-Sha256Hex -Bytes $pageBytes
$frozenObject = [pscustomobject][ordered]@{
    name = $uiMetadataName
    version = $skillVersion
    status = "frozen"
    frozenAt = $snapshotFrozenAt
    generatedFrom = "git ls-files -- skill/pc-hardware-workbench"
    source = "docs/skill-evolution/orrery/index.html"
    manifest = "docs/skill-evolution/orrery/data/manifest.json"
    changes = $snapshotChanges
    fileCount = $sortedRecords.Count
    aggregateSha256 = $aggregateSha256
    sha256 = $pageSha256
    bytes = $pageBytes.Length
}
$frozenJson = $frozenObject | ConvertTo-Json -Depth 10 -Compress
$frozenJson = $frozenJson.Replace("`r`n", "`n") + "`n"

if ($Check) {
    $stale = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $stale.Add("Missing generated manifest: $manifestPath") | Out-Null
    }
    else {
        $actualManifest = Get-CanonicalText $manifestPath
        if ($actualManifest -cne $manifestJson) {
            $actualManifestHash = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($actualManifest)
            $expectedManifestHash = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($manifestJson)
            $stale.Add("Generated manifest is stale (actual $actualManifestHash, expected $expectedManifestHash, aggregate $aggregateSha256). Run tools/build-skill-orrery.ps1.") | Out-Null
        }
    }
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        $stale.Add("Missing generated current orrery: $indexPath") | Out-Null
    }
    else {
        $actualIndex = Get-CanonicalText $indexPath
        if ($actualIndex -cne $generatedHtml) {
            $actualIndexHash = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($actualIndex)
            $expectedIndexHash = Get-Sha256Hex -Bytes $pageBytes
            $stale.Add("Generated current orrery is stale (actual $actualIndexHash, expected $expectedIndexHash, aggregate $aggregateSha256). Run tools/build-skill-orrery.ps1.") | Out-Null
        }
    }
    if (-not (Test-Path -LiteralPath $frozenPath -PathType Leaf)) {
        $stale.Add("Missing generated current metadata: $frozenPath") | Out-Null
    }
    else {
        $actualFrozen = Get-CanonicalText $frozenPath
        if ($actualFrozen -cne $frozenJson) {
            $actualFrozenHash = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($actualFrozen)
            $expectedFrozenHash = Get-Sha256Hex -Bytes $utf8NoBom.GetBytes($frozenJson)
            $stale.Add("Generated current metadata is stale (actual $actualFrozenHash, expected $expectedFrozenHash, aggregate $aggregateSha256). Run tools/build-skill-orrery.ps1.") | Out-Null
        }
    }
    if ($stale.Count -gt 0) {
        $stale | ForEach-Object { Write-Host "- $_" -ForegroundColor Red }
        throw "Skill orrery generated artifacts are stale."
    }
    Write-Host "Skill orrery build check: PASS ($skillVersion, $($sortedRecords.Count) files, $aggregateSha256)" -ForegroundColor Green
    exit 0
}

$manifestDirectory = Split-Path -Parent $manifestPath
[System.IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
[System.IO.File]::WriteAllText($manifestPath, $manifestJson, $utf8NoBom)
[System.IO.File]::WriteAllText($indexPath, $generatedHtml, $utf8NoBom)
[System.IO.File]::WriteAllText($frozenPath, $frozenJson, $utf8NoBom)

Write-Host "Built Skill orrery: $skillVersion / $($sortedRecords.Count) files" -ForegroundColor Green
Write-Host "Manifest: $manifestPath"
Write-Host "Page: $indexPath"
Write-Host "Metadata: $frozenPath"
