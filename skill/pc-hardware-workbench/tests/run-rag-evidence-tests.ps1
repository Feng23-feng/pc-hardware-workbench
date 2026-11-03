[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RagScriptPath
)

$ErrorActionPreference = "Stop"
$failures = New-Object System.Collections.Generic.List[string]
$powershell = (Get-Command powershell.exe -ErrorAction Stop).Source
$resolvedScript = (Resolve-Path -LiteralPath $RagScriptPath).Path
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) "pcwb-rag-$([guid]::NewGuid().ToString('N'))"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Quote-Argument {
    param([string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-Rag {
    param([string[]]$Arguments)

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $powershell
    $startInfo.Arguments = (
        @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $resolvedScript) + $Arguments |
            ForEach-Object { Quote-Argument $_ }
    ) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(30000)) {
        try {
            $process.Kill()
        }
        catch {
        }
        throw "RAG evidence process timed out."
    }
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.Result
        Stderr = $stderrTask.Result
    }
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $cachePath = Join-Path $tempRoot "rag-cache.json"

    $first = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/en-us/geforce/news/",
        "-Title", "Official GeForce notes",
        "-SourceTier", "A",
        "-FetchedAt", "2026-11-03T12:00:00+08:00",
        "-PublishedAt", "2026-10-30T09:00:00+08:00",
        "-FreshnessDays", "30",
        "-AppliesTo", "RTX 50 series",
        "-Claim", "Official material applies to the named architecture.",
        "-EvidenceQuote", "Official vendor statement for the named product family.",
        "-SourceContentSha256", ("A" * 64)
    )
    Assert-True ($first.ExitCode -eq 0) "Official evidence card add failed: $($first.Stderr)"
    Assert-True ($first.Stdout.Trim() -eq "R-001") "First evidence ID is not R-001."
    Assert-True (Test-Path -LiteralPath $cachePath -PathType Leaf) "Evidence cache was not created."

    $cache = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($cache.schemaVersion -eq "1.0") "Evidence cache schema is missing."
    Assert-True (@($cache.cards).Count -eq 1) "Evidence card was not persisted."
    $firstCard = $cache.cards[0]
    Assert-True ($firstCard.Id -eq "R-001") "First card ID changed."
    Assert-True ($firstCard.SourceTier -eq "A") "Official source tier changed."
    Assert-True ($firstCard.Use -eq "primary") "Official source use is not primary."
    Assert-True ($firstCard.Host -eq "www.nvidia.com") "Official source host was not recorded."
    Assert-True ($firstCard.ExpiresAt -eq "2026-12-03T12:00:00.0000000+08:00") "Evidence expiry is wrong."
    Assert-True ($firstCard.EvidenceQuoteSha256 -match '^[0-9A-F]{64}$') "Evidence quote hash is missing."
    Assert-True ($firstCard.EvidenceRecordSha256 -match '^[0-9A-F]{64}$') "Evidence record hash is missing."
    Assert-True ($firstCard.SourceContentSha256 -eq ("A" * 64)) "Source content hash was not preserved."

    $firstHash = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash
    $unregisteredBlocked = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://example.com/hardware-note",
        "-Title", "Community note",
        "-Publisher", "Example Community",
        "-AppliesTo", "RTX 50 series",
        "-Claim", "Community claim.",
        "-EvidenceQuote", "Community excerpt.",
        "-FetchedAt", "2026-11-03T12:01:00+08:00"
    )
    Assert-True ($unregisteredBlocked.ExitCode -eq 2) "Unregistered domain was accepted without an explicit community flag."
    Assert-True ((Get-FileHash -LiteralPath $cachePath -Algorithm SHA256).Hash -eq $firstHash) "Rejected community add changed the cache."

    $communityTierBlocked = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://example.com/hardware-note",
        "-Title", "Community note",
        "-Publisher", "Example Community",
        "-SourceTier", "A",
        "-AllowCommunitySource",
        "-AppliesTo", "RTX 50 series",
        "-Claim", "Community claim.",
        "-EvidenceQuote", "Community excerpt.",
        "-FetchedAt", "2026-11-03T12:01:00+08:00"
    )
    Assert-True ($communityTierBlocked.ExitCode -eq 2) "Unregistered community source could claim tier A."

    $second = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.amd.com/en/support",
        "-Title", "Official AMD support",
        "-FetchedAt", "2026-11-03T12:02:00+08:00",
        "-FreshnessDays", "30",
        "-AppliesTo", "Radeon RX 9000",
        "-Claim", "The support page is the primary vendor support entry.",
        "-EvidenceQuote", "Official AMD support page.",
        "-ConflictsWith", "R-001"
    )
    Assert-True ($second.ExitCode -eq 0) "Second official card failed: $($second.Stderr)"
    Assert-True ($second.Stdout.Trim() -eq "R-002") "Second evidence ID is not R-002."

    $expired = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.intel.com/content/www/us/en/support.html",
        "-Title", "Old Intel support snapshot",
        "-FetchedAt", "2025-01-01T00:00:00+08:00",
        "-FreshnessDays", "1",
        "-AppliesTo", "Intel platform",
        "-Claim", "An old claim retained as historical evidence.",
        "-EvidenceQuote", "Historical support excerpt."
    )
    Assert-True ($expired.ExitCode -eq 0) "Expired historical card could not be retained."
    Assert-True ($expired.Stdout.Trim() -eq "R-003") "Historical evidence ID is not R-003."

    $list = Invoke-Rag -Arguments @(
        "-Action", "List",
        "-CachePath", $cachePath,
        "-AsJson"
    )
    Assert-True ($list.ExitCode -eq 0) "Evidence list failed."
    $listed = $list.Stdout | ConvertFrom-Json
    Assert-True ($listed.Total -eq 3) "Evidence list count is wrong."

    $find = Invoke-Rag -Arguments @(
        "-Action", "Find",
        "-CachePath", $cachePath,
        "-Query", "RTX 50",
        "-AsJson"
    )
    Assert-True ($find.ExitCode -eq 0) "Evidence find failed."
    $found = $find.Stdout | ConvertFrom-Json
    Assert-True ($found.Total -eq 1 -and $found.Cards[0].Id -eq "R-001") "Evidence find returned the wrong card: total=$($found.Total), ids=$(@($found.Cards.Id) -join ',')"

    $check = Invoke-Rag -Arguments @(
        "-Action", "Check",
        "-CachePath", $cachePath,
        "-AsJson"
    )
    Assert-True ($check.ExitCode -eq 0) "Evidence check failed."
    $checked = $check.Stdout | ConvertFrom-Json
    Assert-True ($checked.Total -eq 3 -and $checked.Fresh -eq 2 -and $checked.Expired -eq 1) "Evidence freshness summary is wrong."
    Assert-True ($checked.ExpiredCards[0].Id -eq "R-003") "Wrong evidence card was marked expired."

    $checkFail = Invoke-Rag -Arguments @(
        "-Action", "Check",
        "-CachePath", $cachePath,
        "-FailOnExpired"
    )
    Assert-True ($checkFail.ExitCode -eq 1) "FailOnExpired did not return exit code 1."

    $community = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://community.example.net/report",
        "-Title", "Community troubleshooting lead",
        "-Publisher", "Community Author",
        "-SourceTier", "C",
        "-AllowCommunitySource",
        "-FetchedAt", "2026-11-03T12:03:00+08:00",
        "-FreshnessDays", "7",
        "-AppliesTo", "Unknown GPU firmware",
        "-Claim", "This is a lead requiring official confirmation.",
        "-EvidenceQuote", "Community report excerpt.",
        "-ConflictsWith", "R-001"
    )
    Assert-True ($community.ExitCode -eq 0) "Explicit community source was rejected: $($community.Stderr)"
    $communityCache = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    $communityCard = @($communityCache.cards | Where-Object { $_.Id -eq "R-004" }) | Select-Object -First 1
    Assert-True ($null -ne $communityCard) "Community evidence card R-004 is missing."
    Assert-True ($communityCard.SourceTier -eq "C" -and $communityCard.Use -eq "lead-only") "Community evidence was not downgraded to lead-only."

    $communityNoPublisher = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://community.example.net/no-publisher",
        "-Title", "Unattributed community lead",
        "-SourceTier", "C",
        "-AllowCommunitySource",
        "-FetchedAt", "2026-11-03T12:03:00+08:00",
        "-AppliesTo", "Unknown GPU firmware",
        "-Claim", "Unattributed lead.",
        "-EvidenceQuote", "Community excerpt."
    )
    Assert-True ($communityNoPublisher.ExitCode -eq 2) "Community source without a publisher label was accepted."
    Assert-True ($communityNoPublisher.Stderr -match "explicit -Publisher") "Community publisher requirement is unclear."

    $httpResult = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "http://www.nvidia.com/insecure",
        "-Title", "Insecure source",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($httpResult.ExitCode -eq 2) "HTTP source URL was accepted."
    Assert-True ($httpResult.Stderr -match "HTTPS") "HTTP URL rejection is unclear."

    $credentialResult = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://user:pass@www.nvidia.com/source",
        "-Title", "Credential source",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($credentialResult.ExitCode -eq 2) "URL credentials were accepted."
    Assert-True ($credentialResult.Stderr -match "credentials") "Credential URL rejection is unclear."

    $queryResult = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source?token=secret",
        "-Title", "Token source",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($queryResult.ExitCode -eq 2) "Sensitive URL query parameter was accepted."

    $encodedQueryResult = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source?%74oken=secret",
        "-Title", "Encoded token source",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($encodedQueryResult.ExitCode -eq 2) "Percent-encoded sensitive query key was accepted."
    Assert-True ($encodedQueryResult.Stderr -match "sensitive query") "Encoded query-key rejection is unclear."

    $passwordQueryResult = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source?password=secret",
        "-Title", "Password source",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($passwordQueryResult.ExitCode -eq 2) "Password query parameter was accepted."

    $missingQuote = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source",
        "-Title", "Missing quote",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($missingQuote.ExitCode -eq 2) "Evidence card without a quote was accepted."

    $missingConflict = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source",
        "-Title", "Missing conflict",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-ConflictsWith", "R-999",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($missingConflict.ExitCode -eq 2) "Evidence card accepted a missing conflict ID."
    Assert-True ($missingConflict.Stderr -match "missing evidence card") "Missing conflict error is unclear."

    $futurePublished = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source",
        "-Title", "Future publish",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-FetchedAt", "2026-11-03T12:04:00+08:00",
        "-PublishedAt", "2026-11-04T12:04:00+08:00"
    )
    Assert-True ($futurePublished.ExitCode -eq 2) "Evidence card accepted PublishedAt after FetchedAt."

    $invalidHash = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/source",
        "-Title", "Invalid content hash",
        "-AppliesTo", "GPU",
        "-Claim", "Claim.",
        "-EvidenceQuote", "Quote.",
        "-SourceContentSha256", "not-a-hash",
        "-FetchedAt", "2026-11-03T12:04:00+08:00"
    )
    Assert-True ($invalidHash.ExitCode -eq 2) "Invalid SourceContentSha256 was accepted."

    $futureFetchedAt = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $cachePath,
        "-Url", "https://www.nvidia.com/en-us/geforce/news/",
        "-Title", "Future fetched evidence",
        "-FetchedAt", "2027-11-03T12:00:00+08:00",
        "-FreshnessDays", "30",
        "-AppliesTo", "RTX 50 series",
        "-Claim", "Future-dated evidence claim.",
        "-EvidenceQuote", "Future-dated evidence quote."
    )
    Assert-True ($futureFetchedAt.ExitCode -eq 2) "Future FetchedAt was accepted."
    Assert-True ($futureFetchedAt.Stderr -match "five minutes in the future") "Future FetchedAt rejection is unclear."

    $invalidCachePath = Join-Path $tempRoot "invalid-cache.json"
    [IO.File]::WriteAllText($invalidCachePath, "{broken", (New-Object System.Text.UTF8Encoding($false)))
    $invalidCache = Invoke-Rag -Arguments @(
        "-Action", "List",
        "-CachePath", $invalidCachePath,
        "-AsJson"
    )
    Assert-True ($invalidCache.ExitCode -eq 2) "Invalid evidence cache JSON was accepted."

    $tamperedCachePath = Join-Path $tempRoot "tampered-cache.json"
    $tampered = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    $tampered.cards[0].SourceTier = "Z"
    [IO.File]::WriteAllText(
        $tamperedCachePath,
        ($tampered | ConvertTo-Json -Depth 20) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $tamperedResult = Invoke-Rag -Arguments @(
        "-Action", "List",
        "-CachePath", $tamperedCachePath,
        "-AsJson"
    )
    Assert-True ($tamperedResult.ExitCode -eq 2) "Tampered evidence tier was accepted."
    Assert-True ($tamperedResult.Stderr -match "invalid source tier") "Tampered tier error is unclear."

    $tamperedHashPath = Join-Path $tempRoot "tampered-hash-cache.json"
    $tamperedHash = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    $tamperedHash.cards[0].Claim = "Tampered claim with the original record hash."
    [IO.File]::WriteAllText(
        $tamperedHashPath,
        ($tamperedHash | ConvertTo-Json -Depth 20) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $tamperedHashResult = Invoke-Rag -Arguments @(
        "-Action", "List",
        "-CachePath", $tamperedHashPath,
        "-AsJson"
    )
    Assert-True ($tamperedHashResult.ExitCode -eq 2) "Tampered evidence claim was accepted."
    Assert-True ($tamperedHashResult.Stderr -match "record hash does not match") "Tampered record hash error is unclear."

    $credentialCachePath = Join-Path $tempRoot "credential-cache.json"
    $credentialCache = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    $credentialCache.cards[0].Url = "https://user:pass@www.nvidia.com/tampered"
    [IO.File]::WriteAllText(
        $credentialCachePath,
        ($credentialCache | ConvertTo-Json -Depth 20) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $credentialCacheResult = Invoke-Rag -Arguments @(
        "-Action", "List",
        "-CachePath", $credentialCachePath,
        "-AsJson"
    )
    Assert-True ($credentialCacheResult.ExitCode -eq 2) "Credential URL in the cache was accepted."
    Assert-True ($credentialCacheResult.Stderr -match "credentials") "Cached credential URL error is unclear."

    $promotedCommunityPath = Join-Path $tempRoot "promoted-community-cache.json"
    $promotedCommunity = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    $promotedCard = @($promotedCommunity.cards | Where-Object { $_.Id -eq "R-004" }) | Select-Object -First 1
    $promotedCard.SourceTier = "A"
    $promotedCard.Use = "primary"
    [IO.File]::WriteAllText(
        $promotedCommunityPath,
        ($promotedCommunity | ConvertTo-Json -Depth 20) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $promotedCommunityResult = Invoke-Rag -Arguments @(
        "-Action", "List",
        "-CachePath", $promotedCommunityPath,
        "-AsJson"
    )
    Assert-True ($promotedCommunityResult.ExitCode -eq 2) "Community evidence could be promoted in the cache."
    Assert-True ($promotedCommunityResult.Stderr -match "elevates an unregistered community source") "Community tier promotion error is unclear."

    $deletedHighestPath = Join-Path $tempRoot "deleted-highest-cache.json"
    $deletedHighest = Get-Content -Raw -LiteralPath $cachePath -Encoding UTF8 | ConvertFrom-Json
    $deletedHighest.cards = @($deletedHighest.cards | Where-Object { $_.Id -ne "R-004" })
    [IO.File]::WriteAllText(
        $deletedHighestPath,
        ($deletedHighest | ConvertTo-Json -Depth 20) + "`r`n",
        (New-Object System.Text.UTF8Encoding($false))
    )
    $nextAfterDelete = Invoke-Rag -Arguments @(
        "-Action", "Add",
        "-CachePath", $deletedHighestPath,
        "-Url", "https://www.nvidia.com/en-us/geforce/news/",
        "-Title", "New evidence after highest card deletion",
        "-FetchedAt", "2026-11-03T12:20:00+08:00",
        "-FreshnessDays", "30",
        "-AppliesTo", "GPU",
        "-Claim", "A newly appended card must not reuse a historical ID.",
        "-EvidenceQuote", "Official NVIDIA page."
    )
    Assert-True ($nextAfterDelete.ExitCode -eq 0) "Add after deleting the highest ID failed: $($nextAfterDelete.Stderr)"
    Assert-True ($nextAfterDelete.Stdout.Trim() -eq "R-005") "Historical highest evidence ID was reused."

    if ($failures.Count -gt 0) {
        Write-Host "RAG evidence regression: FAIL" -ForegroundColor Red
        foreach ($failure in $failures) {
            Write-Host "- $failure" -ForegroundColor Red
        }
        exit 1
    }

    Write-Host "RAG evidence regression: PASS" -ForegroundColor Green
}
finally {
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (
        (Test-Path -LiteralPath $resolvedTemp) -and
        $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)
    ) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
