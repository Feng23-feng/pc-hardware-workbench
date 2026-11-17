$script:SkillDockCanonicalRuntimeDataDirectoryName = "runtime-pchw"
$script:SkillDockLegacyRuntimeDataDirectoryName = "runtime-dsh-web"

function Get-SkillDockLocalRoot {
    param([string]$LocalRoot = "")

    if (-not [string]::IsNullOrWhiteSpace($LocalRoot)) {
        return [IO.Path]::GetFullPath($LocalRoot).TrimEnd("\")
    }
    if (-not [string]::IsNullOrWhiteSpace($env:SKILLDOCK_LOCAL_ROOT)) {
        return [IO.Path]::GetFullPath(
            $env:SKILLDOCK_LOCAL_ROOT
        ).TrimEnd("\")
    }
    return [IO.Path]::GetFullPath(
        (Join-Path $env:LOCALAPPDATA "SkillDock")
    ).TrimEnd("\")
}

function Get-SkillDockRuntimeDirectoryCandidates {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)

    return @(
        (Join-Path `
            $LocalRoot `
            $script:SkillDockCanonicalRuntimeDataDirectoryName),
        (Join-Path `
            $LocalRoot `
            $script:SkillDockLegacyRuntimeDataDirectoryName)
    )
}

function Get-SkillDockCanonicalRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)

    return Join-Path `
        $LocalRoot `
        $script:SkillDockCanonicalRuntimeDataDirectoryName
}

function Get-SkillDockLegacyRuntimeDirectory {
    param([Parameter(Mandatory = $true)][string]$LocalRoot)

    return Join-Path `
        $LocalRoot `
        $script:SkillDockLegacyRuntimeDataDirectoryName
}

function Read-SkillDockJsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 |
        ConvertFrom-Json
}

function Test-SkillDockRuntimeBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][object]$Reference
    )

    $bindingPid = [int]$Binding.pid
    $bindingPort = [int]$Binding.port
    $bindingLaunchId = [string]$Binding.launch_id
    $bindingOrigin = ([string]$Binding.origin).TrimEnd("/")
    $referencePid = [int]$Reference.pid
    $referencePort = [int]$Reference.port
    $referenceLaunchId = [string]$Reference.launch_id
    $referenceOrigin = ([string]$Reference.origin).TrimEnd("/")
    return (
        $bindingPid -gt 0 -and
        $bindingPort -gt 0 -and
        -not [string]::IsNullOrWhiteSpace($bindingLaunchId) -and
        -not [string]::IsNullOrWhiteSpace($bindingOrigin) -and
        $bindingPid -eq $referencePid -and
        $bindingPort -eq $referencePort -and
        $bindingLaunchId -eq $referenceLaunchId -and
        (
            [string]::IsNullOrWhiteSpace($referenceOrigin) -or
            $bindingOrigin -eq $referenceOrigin
        )
    )
}

function Get-SkillDockRuntimeContext {
    param(
        [string]$LocalRoot = "",
        [string]$RuntimeDirectory = "",
        [ValidateRange(1, 30)]
        [int]$TimeoutSeconds = 5
    )

    $resolvedLocalRoot = Get-SkillDockLocalRoot -LocalRoot $LocalRoot
    $resolvedRuntimeDirectory = if (
        [string]::IsNullOrWhiteSpace($RuntimeDirectory)
    ) {
        ""
    }
    else {
        [IO.Path]::GetFullPath($RuntimeDirectory).TrimEnd("\")
    }

    if (-not [string]::IsNullOrWhiteSpace($resolvedRuntimeDirectory)) {
        $info = Read-SkillDockJsonFile `
            -Path (Join-Path $resolvedRuntimeDirectory "server-info.json")
        if ($null -eq $info) {
            return $null
        }
        try {
            $health = Invoke-RestMethod `
                -Uri "http://127.0.0.1:$([int]$info.port)/api/health" `
                -TimeoutSec $TimeoutSeconds
            if (
                -not [bool]$health.ok -or
                -not (Test-SkillDockRuntimeBinding `
                    -Binding $health.runtime_binding `
                    -Reference $info)
            ) {
                return $null
            }
        }
        catch {
            return $null
        }
        $infoOrigin = ([string]$info.origin).TrimEnd("/")
        $infoUrl = if ($infoOrigin) {
            "$infoOrigin/"
        }
        else {
            "http://127.0.0.1:$([int]$info.port)/"
        }
        return [pscustomobject]@{
            ok = $true
            result = $info
            health = $health
            binding = $health.runtime_binding
            local_root = $resolvedLocalRoot
            runtime_directory = $resolvedRuntimeDirectory
            server_info_match = $true
            metadata_state = "explicit-runtime"
            ignored_server_info = @()
            url = $infoUrl
        }
    }

    $resultPath = Join-Path $resolvedLocalRoot "launch-result.json"
    $result = Read-SkillDockJsonFile -Path $resultPath
    if (
        $null -eq $result -or
        -not [bool]$result.ok -or
        [string]::IsNullOrWhiteSpace([string]$result.url) -or
        [int]$result.pid -le 0 -or
        [int]$result.port -le 0 -or
        [string]::IsNullOrWhiteSpace([string]$result.launch_id)
    ) {
        return $null
    }
    try {
        $health = Invoke-RestMethod `
            -Uri "$(([string]$result.url).TrimEnd('/'))/api/health" `
            -TimeoutSec $TimeoutSeconds
    }
    catch {
        return $null
    }
    $binding = $health.runtime_binding
    if (
        -not [bool]$health.ok -or
        -not (Test-SkillDockRuntimeBinding `
            -Binding $binding `
            -Reference $result)
    ) {
        return $null
    }
    $resultOrigin = ([string]$result.url).TrimEnd("/")
    $bindingOrigin = ([string]$binding.origin).TrimEnd("/")
    if ($bindingOrigin -ne $resultOrigin) {
        return $null
    }

    $ignored = New-Object System.Collections.Generic.List[string]
    $matchedDirectory = ""
    $serverInfoMatch = $false
    foreach ($candidate in Get-SkillDockRuntimeDirectoryCandidates `
        -LocalRoot $resolvedLocalRoot) {
        $infoPath = Join-Path $candidate "server-info.json"
        if (-not (Test-Path -LiteralPath $infoPath -PathType Leaf)) {
            continue
        }
        try {
            $info = Read-SkillDockJsonFile -Path $infoPath
            if (
                $null -ne $info -and
                (Test-SkillDockRuntimeBinding `
                    -Binding $binding `
                    -Reference $info)
            ) {
                $matchedDirectory = $candidate
                $serverInfoMatch = $true
                break
            }
        }
        catch {
            # Stale or malformed metadata is ignored; health remains authoritative.
        }
        $ignored.Add($infoPath) | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($matchedDirectory)) {
        $canonical = Get-SkillDockCanonicalRuntimeDirectory `
            -LocalRoot $resolvedLocalRoot
        $legacy = Get-SkillDockLegacyRuntimeDirectory `
            -LocalRoot $resolvedLocalRoot
        if (Test-Path -LiteralPath $canonical -PathType Container) {
            $matchedDirectory = $canonical
        }
        elseif (Test-Path -LiteralPath $legacy -PathType Container) {
            $matchedDirectory = $legacy
        }
    }
    if ([string]::IsNullOrWhiteSpace($matchedDirectory)) {
        return $null
    }

    $metadataState = if ($serverInfoMatch) {
        "matched"
    }
    else {
        "launch-health-authoritative"
    }
    return [pscustomobject]@{
        ok = $true
        result = $result
        health = $health
        binding = $binding
        local_root = $resolvedLocalRoot
        runtime_directory = $matchedDirectory
        server_info_match = $serverInfoMatch
        metadata_state = $metadataState
        ignored_server_info = $ignored.ToArray()
        url = ([string]$result.url).TrimEnd("/") + "/"
    }
}

function Get-SkillDockRuntimeAccessContext {
    param(
        [string]$LocalRoot = "",
        [string]$RuntimeDirectory = ""
    )

    $context = Get-SkillDockRuntimeContext `
        -LocalRoot $LocalRoot `
        -RuntimeDirectory $RuntimeDirectory
    if ($null -eq $context) {
        throw "SkillDock runtime is not running or its launch binding is stale."
    }
    return $context
}
