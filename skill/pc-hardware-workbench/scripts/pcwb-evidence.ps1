$script:PcwbArrayFields = @(
    "Inputs",
    "Evidence",
    "Findings",
    "Uncertainties",
    "NextActions",
    "Artifacts",
    "Warnings",
    "Errors",
    "Limits"
)

function New-PcwbEnvelope {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    return [ordered]@{
        SchemaVersion = "1.0"
        Tool = "pcwb"
        ToolVersion = "1.0.0"
        Command = $Command
        Status = "ok"
        GeneratedAt = [datetimeoffset]::UtcNow.ToString("o")
        DurationMilliseconds = 0
        ExitCode = 0
        Inputs = New-Object System.Collections.Generic.List[object]
        Evidence = New-Object System.Collections.Generic.List[object]
        Findings = New-Object System.Collections.Generic.List[object]
        Uncertainties = New-Object System.Collections.Generic.List[object]
        NextActions = New-Object System.Collections.Generic.List[object]
        Artifacts = New-Object System.Collections.Generic.List[object]
        Warnings = New-Object System.Collections.Generic.List[object]
        Errors = New-Object System.Collections.Generic.List[object]
        Limits = New-Object System.Collections.Generic.List[object]
    }
}

function ConvertTo-PcwbResultJson {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Envelope
    )

    $normalized = [ordered]@{}
    foreach ($key in $Envelope.Keys) {
        $value = $Envelope[$key]
        if ($script:PcwbArrayFields -contains $key) {
            if ($value -is [System.Array]) {
                $normalized[$key] = $value
            }
            else {
                $normalized[$key] = $value.ToArray()
            }
        }
        else {
            $normalized[$key] = $value
        }
    }
    return ($normalized | ConvertTo-Json -Depth 20)
}

function Get-PcwbValue {
    param(
        [AllowNull()]
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowNull()]
        [object]$Default = $null
    )

    $current = $Object
    foreach ($segment in ($Name -split '\.')) {
        if ($null -eq $current) {
            return $Default
        }

        if ($current -is [System.Array] -or $current -is [System.Collections.IList]) {
            $index = 0
            if (-not [int]::TryParse($segment, [ref]$index)) {
                return $Default
            }
            if ($index -lt 0 -or $index -ge $current.Count) {
                return $Default
            }
            $current = $current[$index]
            continue
        }

        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $Default
        }
        $current = $property.Value
    }
    return $current
}

function Get-PcwbSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PcwbPermissionFailure {
    param(
        [AllowNull()]
        [object]$ErrorRecord
    )

    if ($null -eq $ErrorRecord) {
        return $false
    }
    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception
    }
    else {
        $ErrorRecord
    }
    if ($exception -is [System.UnauthorizedAccessException]) {
        return $true
    }
    $message = if ($null -eq $exception) { [string]$ErrorRecord } else { [string]$exception.Message }
    return ($message -match '(?i)access\s+denied|permission|unauthorized|elevat')
}

function New-PcwbInputRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolved = Assert-LocalReadFilePath -Path $Path
    $item = Get-Item -LiteralPath $resolved -Force
    return [ordered]@{
        Role = $Role
        Path = $resolved
        Sha256 = Get-PcwbSha256 -Path $resolved
        Bytes = $item.Length
    }
}

function New-PcwbArtifactRecord {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Role,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$MediaType
    )

    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $item = Get-Item -LiteralPath $resolved -Force
    return [ordered]@{
        Role = $Role
        Name = $item.Name
        Path = $resolved
        Sha256 = Get-PcwbSha256 -Path $resolved
        Bytes = $item.Length
        MediaType = $MediaType
    }
}

function Write-PcwbUtf8FileAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Content
    )

    $resolved = Resolve-LocalOutputFilePath -Path $Path
    $parent = Split-Path -Parent $resolved
    $temporary = Join-Path $parent (
        "." + [IO.Path]::GetFileName($resolved) + "." + [guid]::NewGuid().ToString("N") + ".tmp"
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)

    try {
        $stream = [IO.File]::Open(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        try {
            $writer = New-Object System.IO.StreamWriter($stream, $encoding)
            try {
                $writer.Write($Content)
            }
            finally {
                $writer.Dispose()
            }
        }
        finally {
            if ($null -ne $stream) {
                $stream.Dispose()
            }
        }
        [IO.File]::Move($temporary, $resolved)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            [IO.File]::Delete($temporary)
        }
    }
    return $resolved
}

function Write-PcwbTextArtifact {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunDirectory,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [string]$Role,
        [string]$MediaType = "application/json"
    )

    if ([IO.Path]::GetFileName($Name) -ne $Name) {
        throw "Artifact names must be leaf file names: $Name"
    }
    $path = Join-Path $RunDirectory $Name
    Write-PcwbUtf8FileAtomic -Path $path -Content $Content | Out-Null
    return New-PcwbArtifactRecord -Role $Role -Path $path -MediaType $MediaType
}

function New-PcwbRunDirectory {
    param(
        [AllowNull()]
        [string]$OutputDirectory
    )

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $root = Join-Path ([IO.Path]::GetTempPath()) "pc-hardware-workbench"
    }
    else {
        try {
            $root = ConvertTo-LocalFilesystemPath -Path $OutputDirectory
        }
        catch {
            throw (New-PcwbFailureException `
                -Code "pcwb.output-directory.invalid" `
                -Message ("OutputDirectory was rejected: {0}" -f (Get-PcwbDiagnosticText $_.Exception.Message)) `
                -Status "needs-input" `
                -ExitCode 2)
        }
    }

    if (Test-Path -LiteralPath $root) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            throw (New-PcwbFailureException `
                -Code "pcwb.output-directory.invalid" `
                -Message "OutputDirectory is not a directory: $root" `
                -Status "needs-input" `
                -ExitCode 2)
        }
    }
    else {
        $parent = Split-Path -Parent $root
        if ([string]::IsNullOrWhiteSpace($parent) -or
            -not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw (New-PcwbFailureException `
                -Code "pcwb.output-directory.invalid" `
                -Message "The parent directory for OutputDirectory does not exist: $root" `
                -Status "needs-input" `
                -ExitCode 2)
        }
    }

    try {
        $hasReparsePoint = Test-PathChainHasReparsePoint -Path $root
    }
    catch {
        $status = if (Test-PcwbPermissionFailure -ErrorRecord $_) { "blocked" } else { "failed" }
        $exitCode = if ($status -eq "blocked") { 6 } else { 1 }
        throw (New-PcwbFailureException `
            -Code "pcwb.output-directory.validate-failed" `
            -Message ("OutputDirectory could not be validated: {0}" -f (Get-PcwbDiagnosticText $_.Exception.Message)) `
            -Status $status `
            -ExitCode $exitCode)
    }
    if ($hasReparsePoint) {
        throw (New-PcwbFailureException `
            -Code "pcwb.output-directory.invalid" `
            -Message "OutputDirectory resolves through a symbolic link, junction, or reparse point." `
            -Status "needs-input" `
            -ExitCode 2)
    }
    try {
        [void][IO.Directory]::CreateDirectory($root)
    }
    catch {
        $status = if (Test-PcwbPermissionFailure -ErrorRecord $_) { "blocked" } else { "failed" }
        $exitCode = if ($status -eq "blocked") { 6 } else { 1 }
        $code = if ($status -eq "blocked") {
            "pcwb.output-directory.permission-required"
        }
        else {
            "pcwb.output-directory.create-failed"
        }
        throw (New-PcwbFailureException `
            -Code $code `
            -Message ("OutputDirectory could not be created: {0}" -f (Get-PcwbDiagnosticText $_.Exception.Message)) `
            -Status $status `
            -ExitCode $exitCode)
    }

    $stamp = [datetimeoffset]::UtcNow.ToString("yyyyMMddTHHmmssfffZ")
    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $runDirectory = Join-Path $root ("pcwb-" + $stamp + "-" + $suffix)
    try {
        [void][IO.Directory]::CreateDirectory($runDirectory)
    }
    catch {
        $status = if (Test-PcwbPermissionFailure -ErrorRecord $_) { "blocked" } else { "failed" }
        $exitCode = if ($status -eq "blocked") { 6 } else { 1 }
        throw (New-PcwbFailureException `
            -Code "pcwb.run-directory.create-failed" `
            -Message ("Run directory could not be created: {0}" -f (Get-PcwbDiagnosticText $_.Exception.Message)) `
            -Status $status `
            -ExitCode $exitCode)
    }
    return (Resolve-Path -LiteralPath $runDirectory).Path
}

function ConvertTo-PcwbNativeArgument {
    param(
        [AllowNull()]
        [object]$Value
    )

    $text = if ($null -eq $Value) { "" } else { [string]$Value }
    if ($text.Length -gt 0 -and $text -notmatch '[\s"]') {
        return $text
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($character in $text.ToCharArray()) {
        if ($character -eq [char]'\') {
            $backslashes++
            continue
        }
        if ($character -eq [char]'"') {
            if ($backslashes -gt 0) {
                [void]$builder.Append(('\' * (($backslashes * 2) + 1)))
            }
            else {
                [void]$builder.Append('\')
            }
            [void]$builder.Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append(('\' * $backslashes))
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append(('\' * ($backslashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-PcwbChildProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PowerShellPath,
        [Parameter(Mandatory = $true)]
        [string]$ChildScript,
        [Parameter(Mandatory = $true)]
        [string[]]$ChildArguments,
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory
    )

    $argumentPayload = [ordered]@{
        Arguments = @($ChildArguments)
    } | ConvertTo-Json -Compress -Depth 4
    $argumentBase64 = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($argumentPayload)
    )
    $arguments = @(
        "-NoLogo",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        (Join-Path $PSScriptRoot "pcwb-child-runner.ps1"),
        "-ChildScript",
        $ChildScript,
        "-ChildArgumentsBase64",
        $argumentBase64
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $PowerShellPath
    $startInfo.Arguments = ($arguments | ForEach-Object {
        ConvertTo-PcwbNativeArgument -Value $_
    }) -join " "
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "The child PowerShell process could not be started."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.Result
            Stderr = $stderrTask.Result
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-PcwbDiagnosticText {
    param(
        [AllowNull()]
        [string]$Text,
        [int]$MaximumLength = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    $clean = $Text -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", " "
    $clean = ($clean -replace "[\r\n]+", " ").Trim()
    if ($clean.Length -gt $MaximumLength) {
        return $clean.Substring(0, $MaximumLength) + "..."
    }
    return $clean
}

function New-PcwbFailureException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [Parameter(Mandatory = $true)]
        [ValidateSet("needs-input", "blocked", "failed")]
        [string]$Status,
        [Parameter(Mandatory = $true)]
        [ValidateSet(1, 2, 3, 4, 5, 6)]
        [int]$ExitCode
    )

    $exception = New-Object System.Exception($Message)
    $exception.Data["PcwbCode"] = $Code
    $exception.Data["PcwbStatus"] = $Status
    $exception.Data["PcwbExitCode"] = $ExitCode
    return $exception
}

function Read-PcwbJsonText {
    param(
        [AllowNull()]
        [string]$Text,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw (New-PcwbFailureException `
            -Code "pcwb.output.empty" `
            -Message "$Label returned no JSON output." `
            -Status "failed" `
            -ExitCode 5)
    }
    try {
        return $Text | ConvertFrom-Json
    }
    catch {
        throw (New-PcwbFailureException `
            -Code "pcwb.output.invalid-json" `
            -Message "$Label returned invalid JSON." `
            -Status "failed" `
            -ExitCode 5)
    }
}

function Add-PcwbWarning {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Envelope,
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Envelope.Warnings.Add([ordered]@{
        Code = $Code
        Message = Get-PcwbDiagnosticText -Text $Message
    })
}

function Add-PcwbLimit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Envelope,
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Envelope.Limits.Add([ordered]@{
        Code = $Code
        Message = Get-PcwbDiagnosticText -Text $Message
    })
}

function Add-PcwbNextAction {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Envelope,
        [Parameter(Mandatory = $true)]
        [string]$Code,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $Envelope.NextActions.Add([ordered]@{
        Code = $Code
        Message = Get-PcwbDiagnosticText -Text $Message
    })
}
