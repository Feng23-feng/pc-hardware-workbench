[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Add", "List", "Check", "Find")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$CachePath,

    [string]$Url,

    [string]$Title,

    [string]$Publisher,

    [ValidateSet("", "A", "B", "C")]
    [string]$SourceTier = "",

    [datetimeoffset]$FetchedAt = [datetimeoffset]::Now,

    [string]$PublishedAt,

    [ValidateRange(0, 3650)]
    [int]$FreshnessDays = 0,

    [string[]]$AppliesTo = @(),

    [string]$Claim,

    [string]$EvidenceQuote,

    [string[]]$ConflictsWith = @(),

    [string]$SourceContentSha256,

    [switch]$AllowCommunitySource,

    [string]$Query,

    [switch]$FailOnExpired,

    [switch]$AsJson
)

$ErrorActionPreference = "Stop"
$invariant = [System.Globalization.CultureInfo]::InvariantCulture
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$pathSafetyHelper = Join-Path $PSScriptRoot "..\local-path-safety.ps1"
if (-not (Test-Path -LiteralPath $pathSafetyHelper -PathType Leaf)) {
    throw "Local path safety helper is missing: $pathSafetyHelper"
}
. $pathSafetyHelper

function Stop-WithInputError {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine($Message)
    exit 2
}

function ConvertTo-CleanText {
    param(
        [AllowNull()][object]$Value,
        [string]$FieldName = "value",
        [int]$MaximumLength = 4000
    )
    if ($null -eq $Value) {
        return ""
    }
    $text = ([string]$Value) -replace "[\p{Cc}\p{Cf}]", " "
    $text = ($text -replace "[\u2028\u2029]", " ").Trim()
    if ($text.Length -gt $MaximumLength) {
        throw "$FieldName exceeds the $MaximumLength character limit."
    }
    return $text
}

function ConvertTo-IsoTimestamp {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$FieldName
    )
    try {
        if ($Value -is [datetimeoffset]) {
            $parsed = [datetimeoffset]$Value
        }
        elseif ($Value -is [datetime]) {
            $parsed = [datetimeoffset]$Value
        }
        else {
            $parsed = [datetimeoffset]::Parse(
                [string]$Value,
                $invariant,
                [System.Globalization.DateTimeStyles]::RoundtripKind
            )
        }
        return $parsed.ToString("o", $invariant)
    }
    catch {
        throw "$FieldName is not a valid timestamp."
    }
}

function Get-Sha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $utf8NoBom.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "")
    }
    finally {
        $sha.Dispose()
    }
}

function Get-EvidenceRecordHash {
    param([Parameter(Mandatory = $true)][object]$Card)
    $separator = [char]0x1F
    $publishedAtHashValue = if ($null -eq $Card.PublishedAt) {
        "<null>"
    }
    else {
        ConvertTo-IsoTimestamp -Value $Card.PublishedAt -FieldName "PublishedAt"
    }
    $fetchedAtHashValue = ConvertTo-IsoTimestamp -Value $Card.FetchedAt -FieldName "FetchedAt"
    $expiresAtHashValue = ConvertTo-IsoTimestamp -Value $Card.ExpiresAt -FieldName "ExpiresAt"
    $material = @(
        "Id=$($Card.Id)"
        "Publisher=$($Card.Publisher)"
        "Title=$($Card.Title)"
        "Url=$($Card.Url)"
        "Host=$($Card.Host)"
        "SourceTier=$($Card.SourceTier)"
        "Use=$($Card.Use)"
        "PublishedAt=$publishedAtHashValue"
        "FetchedAt=$fetchedAtHashValue"
        "ExpiresAt=$expiresAtHashValue"
        "FreshnessDays=$($Card.FreshnessDays)"
        "AppliesTo=$((@($Card.AppliesTo)) -join $separator)"
        "Claim=$($Card.Claim)"
        "EvidenceQuote=$($Card.EvidenceQuote)"
        "EvidenceQuoteSha256=$($Card.EvidenceQuoteSha256)"
        "SourceContentSha256=$(if ($null -eq $Card.SourceContentSha256) { '<null>' } else { $Card.SourceContentSha256 })"
        "ConflictsWith=$((@($Card.ConflictsWith)) -join $separator)"
    ) -join "`n"
    return Get-Sha256Text $material
}

function Resolve-CachePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $candidate = ConvertTo-LocalFilesystemPath -Path $Path
    if ([IO.Path]::GetExtension($candidate) -ine ".json") {
        throw "CachePath must use the .json extension."
    }
    if (Test-PathChainHasReparsePoint -Path $candidate) {
        throw "CachePath resolves through a symbolic link, junction, or reparse point."
    }
    $parent = Split-Path -Parent $candidate
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "CachePath parent directory does not exist: $parent"
    }
    if (Test-Path -LiteralPath $candidate -PathType Container) {
        throw "CachePath must be a file path."
    }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        $item = Get-Item -LiteralPath $candidate
        if (($item.Attributes -band [System.IO.FileAttributes]::Offline) -ne 0) {
            throw "CachePath is an offline or cloud-placeholder file."
        }
        if ($item.Length -gt 16MB) {
            throw "CachePath exceeds the 16 MB evidence-cache limit."
        }
    }
    return $candidate
}

function Read-Registry {
    $registryPath = Join-Path $PSScriptRoot "source-registry.json"
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        throw "RAG source registry is missing: $registryPath"
    }
    try {
        $registry = Get-Content -Raw -LiteralPath $registryPath -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "RAG source registry JSON is invalid: $($_.Exception.Message)"
    }
    if ([string]$registry.schemaVersion -ne "1.0" -or @($registry.sources).Count -eq 0) {
        throw "RAG source registry is missing a supported schema or sources."
    }
    return $registry
}

function Read-Cache {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Registry
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-WithInputError "RAG evidence cache not found: $Path"
    }
    try {
        $cache = Get-Content -Raw -LiteralPath $Path -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Stop-WithInputError "RAG evidence cache JSON is invalid: $($_.Exception.Message)"
    }
    if ([string]$cache.schemaVersion -ne "1.0" -or
        $null -eq $cache.PSObject.Properties["cards"] -or
        $cache.cards -isnot [System.Array]) {
        Stop-WithInputError "RAG evidence cache must contain schemaVersion 1.0 and a cards array."
    }
    $seenIds = New-Object System.Collections.Generic.HashSet[string]
    $maximumCardNumber = 0
    foreach ($card in @($cache.cards)) {
        foreach ($requiredName in @(
            "Id", "Publisher", "Title", "Url", "Host", "SourceTier", "Use",
            "PublishedAt", "FetchedAt", "ExpiresAt", "FreshnessDays",
            "AppliesTo", "Claim", "EvidenceQuote", "EvidenceQuoteSha256",
            "EvidenceRecordSha256", "SourceContentSha256", "ConflictsWith"
        )) {
            if ($null -eq $card.PSObject.Properties[$requiredName]) {
                Stop-WithInputError "RAG evidence card is missing '$requiredName'."
            }
        }
        $idMatch = [regex]::Match([string]$card.Id, '^R-(\d{3,})$')
        if (-not $idMatch.Success -or -not $seenIds.Add([string]$card.Id)) {
            Stop-WithInputError "RAG evidence cache contains an invalid or duplicate card ID."
        }
        $maximumCardNumber = [Math]::Max($maximumCardNumber, [int]$idMatch.Groups[1].Value)
        $source = Resolve-Source -Url ([string]$card.Url) -Registry $Registry
        if ([string]$card.Host -ine $source.Uri.Host) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' host does not match its URL."
        }
        if ([string]$card.SourceTier -notin @("A", "B", "C")) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has an invalid source tier."
        }
        if ([string]$card.Use -notin @("primary", "supporting", "lead-only")) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has an invalid use."
        }
        if ($card.AppliesTo -isnot [System.Array] -or $card.ConflictsWith -isnot [System.Array]) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has invalid array fields."
        }
        if (@($card.AppliesTo).Count -eq 0) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has no applicable scope."
        }
        foreach ($textField in @("Publisher", "Title", "Claim", "EvidenceQuote")) {
            if ([string]::IsNullOrWhiteSpace([string]$card.$textField)) {
                Stop-WithInputError "RAG evidence card '$($card.Id)' has an empty $textField."
            }
        }
        if ($source.Registered) {
            if ([string]$card.Publisher -ine $source.Publisher) {
                Stop-WithInputError "RAG evidence card '$($card.Id)' publisher does not match the registry."
            }
            if ((Get-TierRank ([string]$card.SourceTier)) -lt (Get-TierRank $source.Tier)) {
                Stop-WithInputError "RAG evidence card '$($card.Id)' elevates its registered source tier."
            }
        }
        else {
            if ([string]$card.SourceTier -ne "C" -or [string]$card.Use -ne "lead-only") {
                Stop-WithInputError "RAG evidence card '$($card.Id)' elevates an unregistered community source."
            }
        }
        $expectedUse = if ([string]$card.SourceTier -eq "A") {
            "primary"
        }
        elseif ([string]$card.SourceTier -eq "B") {
            "supporting"
        }
        else {
            "lead-only"
        }
        if ([string]$card.Use -ne $expectedUse) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has an inconsistent source use."
        }
        if ([int]$card.FreshnessDays -le 0 -or [int]$card.FreshnessDays -gt 3650) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has an invalid freshness interval."
        }
        foreach ($timestampField in @("FetchedAt", "ExpiresAt")) {
            try {
                ConvertTo-IsoTimestamp -Value $card.$timestampField -FieldName $timestampField | Out-Null
            }
            catch {
                Stop-WithInputError "RAG evidence card '$($card.Id)' has an invalid $timestampField."
            }
        }
        if ($null -ne $card.PublishedAt) {
            try {
                ConvertTo-IsoTimestamp -Value $card.PublishedAt -FieldName "PublishedAt" | Out-Null
            }
            catch {
                Stop-WithInputError "RAG evidence card '$($card.Id)' has an invalid PublishedAt."
            }
        }
        $fetchedAtValue = [datetimeoffset]::Parse([string]$card.FetchedAt, $invariant)
        $expiresAtValue = [datetimeoffset]::Parse([string]$card.ExpiresAt, $invariant)
        if ($fetchedAtValue -gt [datetimeoffset]::Now.AddMinutes(5)) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' FetchedAt is unreasonably in the future."
        }
        $expectedExpiry = $fetchedAtValue.AddDays([int]$card.FreshnessDays)
        if ([Math]::Abs(($expiresAtValue - $expectedExpiry).TotalSeconds) -gt 1) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' expiry does not match its freshness interval."
        }
        if ($null -ne $card.PublishedAt -and
            [datetimeoffset]::Parse([string]$card.PublishedAt, $invariant) -gt $fetchedAtValue) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has PublishedAt after FetchedAt."
        }
        if ([string]$card.EvidenceQuoteSha256 -ne (Get-Sha256Text ([string]$card.EvidenceQuote))) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' evidence quote hash does not match."
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$card.SourceContentSha256) -and
            [string]$card.SourceContentSha256 -notmatch '^[0-9A-Fa-f]{64}$') {
            Stop-WithInputError "RAG evidence card '$($card.Id)' has an invalid source content hash."
        }
        if ([string]$card.EvidenceRecordSha256 -ne (Get-EvidenceRecordHash -Card $card)) {
            Stop-WithInputError "RAG evidence card '$($card.Id)' record hash does not match."
        }
    }
    if ($null -eq $cache.PSObject.Properties["lastCardNumber"]) {
        $cache | Add-Member -NotePropertyName "lastCardNumber" -NotePropertyValue $maximumCardNumber
    }
    elseif ([int]$cache.lastCardNumber -lt $maximumCardNumber -or [int]$cache.lastCardNumber -lt 0) {
        Stop-WithInputError "RAG evidence cache lastCardNumber is lower than an existing card ID."
    }
    foreach ($card in @($cache.cards)) {
        foreach ($conflictId in @($card.ConflictsWith)) {
            if (-not $seenIds.Contains([string]$conflictId)) {
                Stop-WithInputError "RAG evidence card '$($card.Id)' references missing conflict '$conflictId'."
            }
        }
    }
    return $cache
}

function New-Cache {
    $now = [datetimeoffset]::Now.ToString("o", $invariant)
    return [pscustomobject]@{
        schemaVersion = "1.0"
        createdAt = $now
        updatedAt = $now
        lastCardNumber = 0
        cards = @()
    }
}

function Write-Cache {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Cache
    )
    $Cache.updatedAt = [datetimeoffset]::Now.ToString("o", $invariant)
    $json = $Cache | ConvertTo-Json -Depth 20
    $temporary = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        [IO.File]::WriteAllText($temporary, $json + "`r`n", $utf8NoBom)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $backup = "$Path.bak-$([guid]::NewGuid().ToString('N'))"
            try {
                [IO.File]::Replace($temporary, $Path, $backup)
            }
            finally {
                if (Test-Path -LiteralPath $backup) {
                    Remove-Item -LiteralPath $backup -Force
                }
            }
        }
        else {
            Move-Item -LiteralPath $temporary -Destination $Path
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-NextCardId {
    param(
        [object[]]$Cards,
        [int]$LastCardNumber = 0
    )
    $maximum = [Math]::Max(0, $LastCardNumber)
    foreach ($card in @($Cards)) {
        $match = [regex]::Match([string]$card.Id, '^R-(\d+)$')
        if ($match.Success) {
            $number = [int]$match.Groups[1].Value
            if ($number -gt $maximum) {
                $maximum = $number
            }
        }
    }
    return "R-{0:D3}" -f ($maximum + 1)
}

function Test-DomainMatch {
    param(
        [Parameter(Mandatory = $true)][string]$HostName,
        [Parameter(Mandatory = $true)][string]$Domain
    )
    $normalizedHost = $HostName.ToLowerInvariant().TrimEnd('.')
    $normalizedDomain = $Domain.ToLowerInvariant().TrimEnd('.')
    return (
        $normalizedHost -eq $normalizedDomain -or
        $normalizedHost.EndsWith(".$normalizedDomain", [StringComparison]::Ordinal)
    )
}

function Resolve-Source {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][object]$Registry
    )
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ine "https") {
        Stop-WithInputError "Source URL must be an absolute HTTPS URL."
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        Stop-WithInputError "Source URL must not contain credentials or user information."
    }
    if ($uri.Query -match '(?i)(?:token|key|auth|session|email|user|cookie)=') {
        Stop-WithInputError "Source URL contains a potentially sensitive query parameter."
    }
    $decodedQuery = try {
        [Uri]::UnescapeDataString($uri.Query)
    }
    catch {
        $uri.Query
    }
    if ($decodedQuery -match '(?i)[?&](?:token|key|api_?key|auth|authorization|session|email|user|username|cookie|password|passwd|pwd|secret|credential)=+') {
        Stop-WithInputError "Source URL contains a potentially sensitive query parameter."
    }

    foreach ($registrySource in @($Registry.sources)) {
        foreach ($domain in @($registrySource.domains)) {
            if (Test-DomainMatch -HostName $uri.Host -Domain ([string]$domain)) {
                return [pscustomobject]@{
                    Uri = $uri
                    Publisher = [string]$registrySource.publisher
                    Tier = [string]$registrySource.tier
                    Use = "primary"
                    Registered = $true
                }
            }
        }
    }
    return [pscustomobject]@{
        Uri = $uri
        Publisher = ""
        Tier = "C"
        Use = "lead-only"
        Registered = $false
    }
}

function Get-TierRank {
    param([string]$Tier)
    switch ($Tier) {
        "A" { return 0 }
        "B" { return 1 }
        default { return 2 }
    }
}

function Get-CardView {
    param(
        [Parameter(Mandatory = $true)][object]$Card,
        [Parameter(Mandatory = $true)][datetimeoffset]$Now
    )
    $expiresAt = [datetimeoffset]::Parse(
        [string]$Card.ExpiresAt,
        $invariant,
        [System.Globalization.DateTimeStyles]::RoundtripKind
    )
    $daysRemaining = [Math]::Floor(($expiresAt - $Now).TotalDays)
    return [pscustomobject]@{
        Id = [string]$Card.Id
        Publisher = ConvertTo-CleanText $Card.Publisher -FieldName "Publisher" -MaximumLength 200
        Title = ConvertTo-CleanText $Card.Title -FieldName "Title" -MaximumLength 300
        SourceTier = [string]$Card.SourceTier
        Use = [string]$Card.Use
        PublishedAt = $Card.PublishedAt
        FetchedAt = $Card.FetchedAt
        ExpiresAt = $Card.ExpiresAt
        Fresh = ($Now -le $expiresAt)
        DaysRemaining = $daysRemaining
        AppliesTo = @($Card.AppliesTo | ForEach-Object {
            ConvertTo-CleanText $_ -FieldName "AppliesTo" -MaximumLength 200
        })
        Claim = ConvertTo-CleanText $Card.Claim -FieldName "Claim" -MaximumLength 4000
        Url = ConvertTo-CleanText $Card.Url -FieldName "Url" -MaximumLength 2048
        ConflictsWith = @($Card.ConflictsWith | ForEach-Object {
            ConvertTo-CleanText $_ -FieldName "ConflictsWith" -MaximumLength 40
        })
    }
}

function Write-CardLines {
    param([object[]]$Cards)
    if (@($Cards).Count -eq 0) {
        Write-Output "No matching RAG evidence cards."
        return
    }
    foreach ($card in @($Cards)) {
        $freshText = if ($card.Fresh) { "fresh" } else { "expired" }
        Write-Output "[$($card.Id)] $freshText / tier $($card.SourceTier) / $($card.Use)"
        Write-Output "  $($card.Publisher): $($card.Title)"
        Write-Output "  Applies to: $($card.AppliesTo -join ', ')"
        Write-Output "  Claim: $($card.Claim)"
        Write-Output "  URL: $($card.Url)"
        Write-Output "  Expires: $($card.ExpiresAt)"
    }
}

try {
    $resolvedCachePath = Resolve-CachePath -Path $CachePath
    $registry = Read-Registry
}
catch {
    Stop-WithInputError $_.Exception.Message
}

if ($Action -eq "Add") {
    try {
        $titleText = ConvertTo-CleanText $Title -FieldName "Title" -MaximumLength 300
        $claimText = ConvertTo-CleanText $Claim -FieldName "Claim" -MaximumLength 4000
        $quoteText = ConvertTo-CleanText $EvidenceQuote -FieldName "EvidenceQuote" -MaximumLength 8000
        $appliesList = @($AppliesTo | ForEach-Object {
            ConvertTo-CleanText $_ -FieldName "AppliesTo" -MaximumLength 200
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if (
            [string]::IsNullOrWhiteSpace($Url) -or
            [string]::IsNullOrWhiteSpace($titleText) -or
            [string]::IsNullOrWhiteSpace($claimText) -or
            [string]::IsNullOrWhiteSpace($quoteText) -or
            $appliesList.Count -eq 0
        ) {
            Stop-WithInputError "Add requires -Url, -Title, -AppliesTo, -Claim, and -EvidenceQuote."
        }

        $source = Resolve-Source -Url $Url -Registry $registry
        if (-not $source.Registered) {
            if (-not $AllowCommunitySource -or $SourceTier -ne "C") {
                Stop-WithInputError "Unregistered domains require -AllowCommunitySource and -SourceTier C."
            }
            $publisherText = ConvertTo-CleanText $Publisher -FieldName "Publisher" -MaximumLength 200
            if ([string]::IsNullOrWhiteSpace($publisherText)) {
                Stop-WithInputError "Community sources require an explicit -Publisher label."
            }
            $effectiveTier = "C"
            $use = "lead-only"
        }
        else {
            $publisherText = $source.Publisher
            $effectiveTier = $source.Tier
            if (-not [string]::IsNullOrWhiteSpace($SourceTier)) {
                if ((Get-TierRank $SourceTier) -gt (Get-TierRank $effectiveTier)) {
                    $effectiveTier = $SourceTier
                }
            }
            $use = if ($effectiveTier -eq "A") { "primary" } elseif ($effectiveTier -eq "B") { "supporting" } else { "lead-only" }
        }

        $fetchedAtIso = ConvertTo-IsoTimestamp -Value $FetchedAt -FieldName "FetchedAt"
        if ([datetimeoffset]::Parse($fetchedAtIso, $invariant) -gt [datetimeoffset]::Now.AddMinutes(5)) {
            Stop-WithInputError "FetchedAt cannot be more than five minutes in the future."
        }
        $publishedAtIso = if ([string]::IsNullOrWhiteSpace($PublishedAt)) {
            $null
        }
        else {
            ConvertTo-IsoTimestamp -Value $PublishedAt -FieldName "PublishedAt"
        }
        if ($null -ne $publishedAtIso -and
            [datetimeoffset]::Parse($publishedAtIso, $invariant) -gt [datetimeoffset]::Parse($fetchedAtIso, $invariant)) {
            Stop-WithInputError "PublishedAt cannot be later than FetchedAt."
        }

        $freshness = if ($FreshnessDays -gt 0) {
            $FreshnessDays
        }
        else {
            [int]$registry.defaultFreshnessDays.$effectiveTier
        }
        if ($freshness -le 0) {
            $freshness = 14
        }
        $expiresAtIso = ([datetimeoffset]::Parse($fetchedAtIso, $invariant)).AddDays($freshness).ToString("o", $invariant)
        if (-not [string]::IsNullOrWhiteSpace($SourceContentSha256) -and
            $SourceContentSha256 -notmatch '^[0-9a-fA-F]{64}$') {
            Stop-WithInputError "SourceContentSha256 must be a SHA-256 hash."
        }

        if (Test-Path -LiteralPath $resolvedCachePath -PathType Leaf) {
            $cache = Read-Cache -Path $resolvedCachePath -Registry $registry
        }
        else {
            $cache = New-Cache
        }
        $existingIds = @($cache.cards | ForEach-Object { [string]$_.Id })
        foreach ($conflictId in @($ConflictsWith)) {
            if ($existingIds -notcontains [string]$conflictId) {
                Stop-WithInputError "ConflictsWith references missing evidence card '$conflictId'."
            }
        }

        $lastCardNumber = if ($null -eq $cache.PSObject.Properties["lastCardNumber"]) {
            0
        }
        else {
            [int]$cache.lastCardNumber
        }
        $id = Get-NextCardId -Cards @($cache.cards) -LastCardNumber $lastCardNumber
        $card = [pscustomobject]@{
            Id = $id
            Publisher = $publisherText
            Title = $titleText
            Url = $source.Uri.AbsoluteUri
            Host = $source.Uri.Host.ToLowerInvariant()
            SourceTier = $effectiveTier
            Use = $use
            PublishedAt = $publishedAtIso
            FetchedAt = $fetchedAtIso
            ExpiresAt = $expiresAtIso
            FreshnessDays = $freshness
            AppliesTo = @($appliesList)
            Claim = $claimText
            EvidenceQuote = $quoteText
            EvidenceQuoteSha256 = Get-Sha256Text $quoteText
            SourceContentSha256 = if ([string]::IsNullOrWhiteSpace($SourceContentSha256)) { $null } else { $SourceContentSha256.ToUpperInvariant() }
            EvidenceRecordSha256 = $null
            ConflictsWith = @($ConflictsWith | ForEach-Object { [string]$_ })
        }
        $card.EvidenceRecordSha256 = Get-EvidenceRecordHash -Card $card
        $cache.cards = @(@($cache.cards) + @($card))
        $cache | Add-Member -NotePropertyName "lastCardNumber" -NotePropertyValue ([int]($id.Substring(2))) -Force
        Write-Cache -Path $resolvedCachePath -Cache $cache
        Write-Output $id
        return
    }
    catch {
        Stop-WithInputError $_.Exception.Message
    }
}

$cache = Read-Cache -Path $resolvedCachePath -Registry $registry
$now = [datetimeoffset]::Now
$cardViews = @(@($cache.cards) | ForEach-Object { Get-CardView -Card $_ -Now $now })

if ($Action -eq "List") {
    if ($AsJson) {
        [pscustomobject]@{
            Total = $cardViews.Count
            Cards = $cardViews
        } | ConvertTo-Json -Depth 12
    }
    else {
        Write-CardLines -Cards $cardViews
    }
    return
}

if ($Action -eq "Find") {
    $queryText = ConvertTo-CleanText $Query -FieldName "Query" -MaximumLength 300
    if ([string]::IsNullOrWhiteSpace($queryText)) {
        Stop-WithInputError "Find requires -Query."
    }
    $matches = @($cardViews | Where-Object {
        $searchFields = New-Object System.Collections.Generic.List[string]
        $searchFields.Add([string]$_.Publisher) | Out-Null
        $searchFields.Add([string]$_.Title) | Out-Null
        $searchFields.Add([string]$_.Claim) | Out-Null
        $searchFields.Add([string]$_.Url) | Out-Null
        foreach ($scope in @($_.AppliesTo)) {
            $searchFields.Add([string]$scope) | Out-Null
        }
        $searchText = $searchFields -join " "
        $searchText -match [regex]::Escape($queryText)
    })
    if ($AsJson) {
        [pscustomobject]@{
            Query = $queryText
            Total = $matches.Count
            Cards = $matches
        } | ConvertTo-Json -Depth 12
    }
    else {
        Write-CardLines -Cards $matches
    }
    return
}

if ($Action -eq "Check") {
    $expired = @($cardViews | Where-Object { -not $_.Fresh })
    $summary = [pscustomobject]@{
        CheckedAt = $now.ToString("o", $invariant)
        Total = $cardViews.Count
        Fresh = $cardViews.Count - $expired.Count
        Expired = $expired.Count
        ExpiredCards = $expired
    }
    if ($AsJson) {
        $summary | ConvertTo-Json -Depth 12
    }
    else {
        Write-Output "RAG evidence check: total=$($summary.Total), fresh=$($summary.Fresh), expired=$($summary.Expired)"
        if ($expired.Count -gt 0) {
            Write-CardLines -Cards $expired
        }
    }
    if ($FailOnExpired -and $expired.Count -gt 0) {
        exit 1
    }
    return
}
