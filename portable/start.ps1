[CmdletBinding()]
param(
    [switch]$SelfTest,

    [switch]$AllowLiveCollector,

    [ValidateSet("Redacted", "Standard", "Both")]
    [string]$CollectorPrivacyMode = "Redacted"
)

$ErrorActionPreference = "Stop"
$utf8 = New-Object System.Text.UTF8Encoding($false)
$appRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptsRoot = Join-Path $appRoot "scripts"
$outputRoot = Join-Path $appRoot "输出结果"
$configOutputRoot = Join-Path $outputRoot "配置报告"
$telemetryOutputRoot = Join-Path $outputRoot "遥测分析"
$experimentOutputRoot = Join-Path $outputRoot "调校实验卡"
$upgradeOutputRoot = Join-Path $outputRoot "升级准备"
$script:SessionState = @{
    ActiveConfigPath = $null
    ActiveHardwareContext = $null
    ActiveCoolingContext = $null
    ActiveExperimentPath = $null
    HardwareFreshnessConfirmed = $false
    ExplanationMode = "detailed"
}

try {
    [Console]::OutputEncoding = $utf8
} catch {
}

function Write-Title {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "       电脑硬件便携工具包 1.4.3" -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "本地、只读、无网络；不会修改 BIOS、频率、电压、功耗或风扇。" -ForegroundColor DarkGray
    Write-Host "目标：教你识别、验证和恢复，让下次可以自己完成调校闭环。" -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace([string]$script:SessionState.ActiveHardwareContext.Platform)) {
        Write-Host "当前设备：$($script:SessionState.ActiveHardwareContext.Platform)" -ForegroundColor DarkGray
        if ($script:SessionState.ActiveHardwareContext.IdentityQuality -ne "readable") {
            $identitySummary = Get-HardwareIdentitySummary -HardwareContext $script:SessionState.ActiveHardwareContext
            Write-Host "设备身份：$identitySummary" -ForegroundColor DarkYellow
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$script:SessionState.ActiveExperimentPath) -and
        (Test-Path -LiteralPath $script:SessionState.ActiveExperimentPath -PathType Leaf)) {
        $stateLine = Select-String -LiteralPath $script:SessionState.ActiveExperimentPath -Pattern '^状态：' -ErrorAction SilentlyContinue |
            Select-Object -Last 1
        $cardState = if ($null -ne $stateLine) { $stateLine.Line.Trim() } else { "状态：未记录" }
        Write-Host "当前实验：$cardState｜$(Split-Path -Leaf $script:SessionState.ActiveExperimentPath)" -ForegroundColor DarkYellow
    }
    $modeText = if ($script:SessionState.ExplanationMode -eq "concise") { "简洁" } else { "详细" }
    Write-Host "讲解模式：$modeText" -ForegroundColor DarkGray
    Write-Host ""
}

function Toggle-ExplanationMode {
    if ($script:SessionState.ExplanationMode -eq "concise") {
        $script:SessionState.ExplanationMode = "detailed"
    }
    else {
        $script:SessionState.ExplanationMode = "concise"
    }
    $modeText = if ($script:SessionState.ExplanationMode -eq "concise") { "简洁" } else { "详细" }
    Write-Host "讲解模式已切换为：$modeText" -ForegroundColor Green
}

function Pause-Menu {
    Write-Host ""
    [void](Read-Host "按回车继续")
}

function Ensure-OutputDirectory {
    foreach ($directory in @($outputRoot, $configOutputRoot, $telemetryOutputRoot, $experimentOutputRoot, $upgradeOutputRoot)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
    }

    $legacyGroups = @(
        [pscustomobject]@{ Destination = $configOutputRoot; Patterns = @("hardware-*.md") },
        [pscustomobject]@{ Destination = $telemetryOutputRoot; Patterns = @("telemetry-summary-*.md") },
        [pscustomobject]@{ Destination = $experimentOutputRoot; Patterns = @("experiment-quick-*.md", "experiment-deep-*.md") },
        [pscustomobject]@{ Destination = $upgradeOutputRoot; Patterns = @("upgrade-preparation-*.md") }
    )
    foreach ($group in $legacyGroups) {
        foreach ($pattern in $group.Patterns) {
            $legacyFiles = @(Get-ChildItem -LiteralPath $outputRoot -File -Filter $pattern -ErrorAction SilentlyContinue)
            foreach ($file in $legacyFiles) {
                $destination = Join-Path $group.Destination $file.Name
                if (Test-Path -LiteralPath $destination) {
                    Write-Host "旧报告未移动，因为目标位置已有同名文件：$($file.Name)" -ForegroundColor Yellow
                    continue
                }
                try {
                    Move-Item -LiteralPath $file.FullName -Destination $destination
                }
                catch {
                    Write-Host "旧报告未移动，可能正被其他程序打开：$($file.Name)" -ForegroundColor Yellow
                }
            }
        }
    }
}

function New-OutputPath {
    param(
        [string]$Prefix,
        [string]$Extension = "md",
        [Parameter(Mandatory = $true)]
        [ValidateSet("配置报告", "遥测分析", "调校实验卡", "升级准备")]
        [string]$Category
    )

    Ensure-OutputDirectory
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $categoryRoot = switch ($Category) {
        "配置报告" { $configOutputRoot }
        "遥测分析" { $telemetryOutputRoot }
        "调校实验卡" { $experimentOutputRoot }
        "升级准备" { $upgradeOutputRoot }
    }
    $candidate = Join-Path $categoryRoot ("{0}-{1}.{2}" -f $Prefix, $stamp, $Extension)
    $sequence = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $categoryRoot ("{0}-{1}-{2}.{3}" -f $Prefix, $stamp, $sequence, $Extension)
        $sequence++
    }
    return $candidate
}

function Get-LatestHardwareReport {
    Ensure-OutputDirectory
    return Get-ChildItem -LiteralPath $configOutputRoot -File -Filter "hardware-*.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Confirm-HardwareReportReuse {
    param([string]$Path)

    Write-Host ""
    Write-Host "复用前确认：如果近期更换过 CPU、GPU、内存、硬盘、主板/笔记本、显示器或电源适配器，" -ForegroundColor Yellow
    Write-Host "旧配置单可能已经过期，应重新采集。" -ForegroundColor Yellow
    $answer = Read-Host "近期更换过硬件吗？输入 y 重新采集；直接回车继续使用现有报告"
    if ($answer -match "^(y|yes|是)$") {
        return "__REFRESH__"
    }
    return $Path
}

function Select-HardwareReportForReuse {
    Ensure-OutputDirectory
    $activePath = Get-ActiveHardwareReportPath
    if (-not [string]::IsNullOrWhiteSpace($activePath)) {
        return $activePath
    }
    $reports = @(
        Get-ChildItem -LiteralPath $configOutputRoot -File -Filter "hardware-*.md" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    )
    if ($reports.Count -eq 0) {
        return $null
    }
    if ($reports.Count -eq 1) {
        Write-Host "找到配置单：$($reports[0].Name)" -ForegroundColor Green
        Write-Host "生成时间：$($reports[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        $selected = Confirm-HardwareReportReuse -Path $reports[0].FullName
        if ($selected -ne "__REFRESH__") {
            Set-ActiveHardwareReport -Path $selected | Out-Null
        }
        return $selected
    }

    Clear-Host
    Write-Host "找到多份配置单，请选择本次要使用的电脑：" -ForegroundColor Cyan
    Write-Host "近期更换过 CPU、GPU、内存、硬盘、主板/笔记本、显示器或电源适配器时，请选择重新采集。" -ForegroundColor Yellow
    for ($index = 0; $index -lt $reports.Count; $index++) {
        $report = $reports[$index]
        $context = Get-HardwareReportContext -Path $report.FullName
        $platform = if ($null -ne $context -and -not [string]::IsNullOrWhiteSpace($context.Platform)) {
            $context.Platform
        }
        else {
            "平台摘要不可读取"
        }
        Write-Host ("  {0}. {1}  [{2}]" -f ($index + 1), $report.Name, $report.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
        Write-Host ("     {0}" -f $platform)
        if ($null -ne $context -and $context.IdentityQuality -ne "readable") {
            Write-Host ("     设备身份：{0}" -f (Get-HardwareIdentitySummary -HardwareContext $context)) -ForegroundColor DarkYellow
        }
        Write-Host "     路径：$($report.FullName)"
    }
    Write-Host "  R. 重新采集一份配置"
    Write-Host "  0. 跳过配置，手动填写平台"
    Write-Host ""
    $choice = Read-Host "输入序号；直接回车使用最新一份"
    if ($null -eq $choice -or [string]::IsNullOrWhiteSpace($choice)) {
        Set-ActiveHardwareReport -Path $reports[0].FullName | Out-Null
        return $reports[0].FullName
    }
    $choice = $choice.Trim()
    if ($choice -match '^(r|refresh|更新|重新)$') {
        return "__REFRESH__"
    }
    if ($choice -eq "0") {
        return $null
    }
    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $reports.Count) {
        Set-ActiveHardwareReport -Path $reports[$index - 1].FullName | Out-Null
        return $reports[$index - 1].FullName
    }
    Write-Host "没有识别这个序号，将使用最新一份。" -ForegroundColor Yellow
    Set-ActiveHardwareReport -Path $reports[0].FullName | Out-Null
    return $reports[0].FullName
}

function Get-MarkdownSectionLines {
    param(
        [string[]]$Lines,
        [string]$Heading,
        [string[]]$Aliases = @()
    )

    $inside = $false
    $result = New-Object System.Collections.Generic.List[string]
    $headingNames = @($Heading) + @($Aliases) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($line in $Lines) {
        if ($line -match '^##\s+') {
            if ($inside) {
                break
            }
            $currentHeading = ($line -replace '^##\s+', '').Trim()
            if ($headingNames -contains $currentHeading) {
                $inside = $true
            }
            continue
        }
        if ($inside) {
            $result.Add($line) | Out-Null
        }
    }
    return @($result.ToArray())
}

function ConvertFrom-MarkdownIdentityValue {
    param([object]$Value)

    if ($null -eq $Value) {
        return $null
    }
    $text = ([string]$Value).Trim()
    $tick = [char]0x60
    if ($text.Length -lt 2 -or $text[0] -ne $tick -or $text[$text.Length - 1] -ne $tick) {
        return $text
    }

    $leadingTicks = 0
    while ($leadingTicks -lt $text.Length -and $text[$leadingTicks] -eq $tick) {
        $leadingTicks++
    }
    $trailingTicks = 0
    while (
        $trailingTicks -lt ($text.Length - $leadingTicks) -and
        $text[$text.Length - 1 - $trailingTicks] -eq $tick
    ) {
        $trailingTicks++
    }
    if ($leadingTicks -gt 0 -and $leadingTicks -eq $trailingTicks -and
        ($leadingTicks + $trailingTicks) -le $text.Length) {
        $innerLength = $text.Length - $leadingTicks - $trailingTicks
        if ($innerLength -gt 0) {
            return $text.Substring($leadingTicks, $innerLength).Trim()
        }
    }
    return $text
}

function ConvertTo-SessionIdentityStatus {
    param([string]$IdentityQuality)

    switch (([string]$IdentityQuality).ToLowerInvariant()) {
        "readable" { return "confirmed" }
        "partial" { return "unknown" }
        "suspicious" { return "unreadable" }
        "unreadable" { return "unreadable" }
        "redacted" { return "unknown" }
        default { return "unknown" }
    }
}

function Get-HardwareIdentitySummary {
    param([object]$HardwareContext)

    if ($null -eq $HardwareContext) {
        return "未提供设备身份状态"
    }
    switch (([string]$HardwareContext.IdentityQuality).ToLowerInvariant()) {
        "readable" { return "已确认" }
        "partial" { return "仅部分字段可读；型号级兼容判断精度受限" }
        "suspicious" { return "文本可疑，不按已确认型号使用" }
        "unreadable" { return "不可可靠读取；不按已确认型号使用" }
        "redacted" { return "已隐私脱敏；保留容量和部件级分析" }
        default { return "旧报告或当前采集未提供身份质量" }
    }
}

function Get-HardwareReportContextFromLines {
    param([string[]]$Lines)

    $systemLines = @(Get-MarkdownSectionLines -Lines $lines -Heading "System" -Aliases @("系统"))
    $cpuLines = @(Get-MarkdownSectionLines -Lines $lines -Heading "CPU" -Aliases @("处理器"))
    $gpuLines = @(Get-MarkdownSectionLines -Lines $lines -Heading "GPU" -Aliases @("显卡"))

    $manufacturer = $null
    $model = $null
    $identityQuality = $null
    $identityWarnings = New-Object System.Collections.Generic.List[string]
    foreach ($line in $systemLines) {
        if ($line -match '^-\s+Identity quality[:：]\s*(\S+)\s*$') {
            $identityQuality = $Matches[1].Trim().ToLowerInvariant()
        }
        elseif ($line -match '^\s+-\s+Identity warning[:：]\s*(.+)$') {
            $identityWarnings.Add($Matches[1].Trim()) | Out-Null
        }
        elseif ($line -match '^-\s+(?:Manufacturer|制造商)[:：]\s*(.+)$') {
            $manufacturer = ConvertFrom-MarkdownIdentityValue -Value $Matches[1]
        }
        elseif ($line -match '^-\s+(?:Model|型号)[:：]\s*(.+)$') {
            $model = ConvertFrom-MarkdownIdentityValue -Value $Matches[1]
        }
    }
    $cpu = $cpuLines | Where-Object { $_ -match '^-\s+' } | Select-Object -First 1
    if ($cpu) { $cpu = ($cpu -replace '^-\s+', '').Trim() }
    $gpus = @(
        $gpuLines |
            Where-Object { $_ -match '^-\s+' } |
            ForEach-Object { ($_ -replace '^-\s+', '').Trim() } |
            Where-Object { $_ -notmatch 'Virtual|GameViewer|Remote' }
    )

    $parts = New-Object System.Collections.Generic.List[string]
    $machineCandidates = switch ($identityQuality) {
        "partial" { @($manufacturer) }
        "suspicious" { @() }
        "unreadable" { @() }
        "redacted" { @() }
        default { @($manufacturer, $model) }
    }
    $machineParts = @(
        $machineCandidates |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notmatch '^\[(?:redacted|unreadable)\]$' }
    )
    $machine = $machineParts -join " "
    if (-not [string]::IsNullOrWhiteSpace($machine)) { $parts.Add($machine) | Out-Null }
    switch ($identityQuality) {
        "redacted" { $parts.Add("设备身份已隐私脱敏") | Out-Null }
        "unreadable" { $parts.Add("系统型号不可可靠读取") | Out-Null }
        "suspicious" { $parts.Add("系统型号文本可疑") | Out-Null }
        "partial" { $parts.Add("系统型号仅部分可读") | Out-Null }
    }
    if (-not [string]::IsNullOrWhiteSpace($cpu)) { $parts.Add("CPU: $cpu") | Out-Null }
    if ($gpus.Count -gt 0) { $parts.Add("GPU: $($gpus -join ' / ')") | Out-Null }

    return [pscustomobject]@{
        Platform = ($parts -join "; ")
        CPU = $cpu
        GPUs = $gpus
        IsLaptop = [bool](@($lines | Where-Object { $_ -match '^##\s+(?:Battery|电池)$|^-\s+(?:Battery|电池)[:：]' }).Count -gt 0)
        IdentityQuality = $identityQuality
        IdentityStatus = (ConvertTo-SessionIdentityStatus -IdentityQuality $identityQuality)
        IdentityWarnings = @($identityWarnings.ToArray())
    }
}

function Get-HardwareReportContext {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-HardwareReportContextFromLines -Lines @(Get-Content -LiteralPath $Path)
}

function Set-ActiveHardwareReport {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $context = Get-HardwareReportContext -Path $Path
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $previousPath = [string]$script:SessionState.ActiveConfigPath
    if (-not [string]::Equals($previousPath, $resolvedPath, [StringComparison]::OrdinalIgnoreCase)) {
        $script:SessionState.ActiveCoolingContext = $null
    }
    $script:SessionState.ActiveConfigPath = $resolvedPath
    $script:SessionState.ActiveHardwareContext = $context
    $script:SessionState.HardwareFreshnessConfirmed = $true
    return $context
}

function Read-CoolingChoice {
    param(
        [Parameter(Mandatory = $true)][string]$Prompt,
        [Parameter(Mandatory = $true)][string[]]$Options
    )

    for ($index = 0; $index -lt $Options.Count; $index++) {
        $number = $index + 1
        Write-Host "  $number. $($Options[$index])"
    }
    Write-Host "  0. 不知道"
    while ($true) {
        $answer = Read-Host $Prompt
        if ($null -eq $answer -or [string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -eq "0") {
            return "不知道"
        }
        $value = 0
        if ([int]::TryParse($answer.Trim(), [ref]$value) -and $value -ge 1 -and $value -le $Options.Count) {
            return $Options[$value - 1]
        }
        Write-Host "请输入对应数字；不知道可直接回车或输入 0。" -ForegroundColor Yellow
    }
}

function Get-CoolingContext {
    param(
        [string]$ConfigPath,
        [object]$HardwareContext,
        [string]$TargetPart
    )

    $existing = $script:SessionState.ActiveCoolingContext
    if ($null -ne $HardwareContext -and $HardwareContext.IsLaptop) {
        $result = [pscustomobject]@{
            ConfigPath = [string]$script:SessionState.ActiveConfigPath
            Kind = "Laptop"
            Summary = "笔记本内置散热；先按具体型号、CPU/GPU 等级、当前厂商性能模式和官方平台功耗范围建立临时上限。"
            PowerEnvelope = "官方数值待核实；采集器不能证明实际散热能力。后续用 PL1/PL2、TGP、温度、有效频率、降频和风扇行为校正。"
        }
        $script:SessionState.ActiveCoolingContext = $result
        Write-Host ""
        Write-Host "已识别为笔记本：不要求你回答台式机式散热器规格。" -ForegroundColor Green
        Write-Host "先采用型号与官方平台功耗范围作临时上限，再用实测温度、功耗和降频校验。" -ForegroundColor DarkGray
        return $result
    }

    if ($null -eq $HardwareContext) {
        return $null
    }

    $sameDevice = $null -ne $existing -and
        [string]::Equals([string]$existing.ConfigPath, [string]$script:SessionState.ActiveConfigPath, [StringComparison]::OrdinalIgnoreCase)
    $cpuCooling = if ($sameDevice) { [string]$existing.CpuCooling } else { $null }
    $gpuCooling = if ($sameDevice) { [string]$existing.GpuCooling } else { $null }
    $airflow = if ($sameDevice) { [string]$existing.Airflow } else { $null }
    $targetText = ([string]$TargetPart).ToLowerInvariant()
    $needsCpu = $targetText -match "cpu|处理器"
    $needsGpu = $targetText -match "gpu|显卡|图形"
    $needsAirflow = $targetText -match "cpu|处理器|gpu|显卡|图形|内存|memory|ram|温度|噪音"

    Write-Host ""
    Write-Host "配置和目标已经明确，只补本次目标真正需要的散热条件。" -ForegroundColor Cyan
    Write-Host "不需要背型号，只选最接近的情况：" -ForegroundColor Yellow
    if ($needsCpu -and [string]::IsNullOrWhiteSpace($cpuCooling)) {
        $cpuCooling = Read-CoolingChoice -Prompt "CPU 散热" -Options @("风冷", "一体水冷", "其他或改装散热")
    }
    if ($needsGpu -and [string]::IsNullOrWhiteSpace($gpuCooling)) {
        $gpuCooling = Read-CoolingChoice -Prompt "GPU 散热" -Options @(
            "单风扇或涡轮原装风冷",
            "双风扇原装风冷",
            "三风扇原装风冷",
            "四风扇及以上原装风冷",
            "改装风冷",
            "改装水冷"
        )
    }
    if ($needsAirflow -and [string]::IsNullOrWhiteSpace($airflow)) {
        $airflow = Read-CoolingChoice -Prompt "机箱风道" -Options @("正常进排风", "明显受阻、贴墙或积热", "开放测试平台")
    }

    $knownCooling = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($cpuCooling)) { $knownCooling.Add("CPU 散热：$cpuCooling") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($gpuCooling)) { $knownCooling.Add("GPU 散热：$gpuCooling") | Out-Null }
    if (-not [string]::IsNullOrWhiteSpace($airflow)) { $knownCooling.Add("机箱风道：$airflow") | Out-Null }
    if ($knownCooling.Count -eq 0) {
        $knownCooling.Add("未收集与本轮目标相关的散热信息") | Out-Null
    }
    $summary = "台式机；" + ($knownCooling -join "；")
    $result = [pscustomobject]@{
        ConfigPath = [string]$script:SessionState.ActiveConfigPath
        Kind = "Desktop"
        Summary = $summary
        PowerEnvelope = "由当前硬件和散热条件建立实测基线；不套用其他机器功耗。"
        CpuCooling = $cpuCooling
        GpuCooling = $gpuCooling
        Airflow = $airflow
        TargetPart = $TargetPart
    }
    $script:SessionState.ActiveCoolingContext = $result
    return $result
}

function Get-ActiveHardwareReportPath {
    $activePath = [string]$script:SessionState.ActiveConfigPath
    if (
        $script:SessionState.HardwareFreshnessConfirmed -and
        -not [string]::IsNullOrWhiteSpace($activePath) -and
        (Test-Path -LiteralPath $activePath -PathType Leaf)
    ) {
        return $activePath
    }
    return $null
}

function Get-LatestExperimentCard {
    Ensure-OutputDirectory
    return Get-ChildItem -LiteralPath $experimentOutputRoot -File -Filter "experiment-*.md" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Get-ExperimentCardContext {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    $lines = @(Get-Content -LiteralPath $Path)
    $result = @{}
    foreach ($line in $lines) {
        if ($line -match '^路线[:：]\s*(.+)$') { $result.Route = $Matches[1].Trim() }
        elseif ($line -match '^目标[:：]\s*(.+)$') { $result.Objective = $Matches[1].Trim() }
        elseif ($line -match '^状态[:：]\s*(.+)$') { $result.Status = $Matches[1].Trim() }
        elseif ($line -match '^唯一主要变量[:：]\s*(.+)$') { $result.PrimaryVariable = $Matches[1].Trim() }
        elseif ($line -match '^工作负载[:：]\s*(.+)$') { $result.Workload = $Matches[1].Trim() }
        elseif ($line -match '^通过标准[:：]\s*(.+)$') { $result.PrimaryMetric = $Matches[1].Trim() }
        elseif ($line -match '^中止信号[:：]\s*(.+)$') { $result.AbortSignals = $Matches[1].Trim() }
        elseif ($line -match '^回滚方式[:：]\s*(.+)$') { $result.Recovery = $Matches[1].Trim() }
    }

    $targetPart = $null
    if ($result.Route -match '目标部件[:：]\s*(.+)$') {
        $targetPart = $Matches[1].Trim()
    }
    return [pscustomobject]@{
        Route = $result.Route
        TargetPart = $targetPart
        Objective = $result.Objective
        Status = $result.Status
        PrimaryVariable = $result.PrimaryVariable
        Workload = $result.Workload
        PrimaryMetric = $result.PrimaryMetric
        AbortSignals = $result.AbortSignals
        Recovery = $result.Recovery
    }
}

function Get-TuningExpectationDirection {
    param(
        [Parameter(Mandatory = $true)][object]$Gate,
        [object]$HardwareContext,
        [object]$PreviousContext
    )

    $routeText = ([string]$Gate.Route).ToLowerInvariant()
    $goalText = ([string]$Gate.Objective).ToLowerInvariant()
    $laptopNote = if ($null -ne $HardwareContext -and $HardwareContext.IsLaptop) {
        "这是笔记本，CPU/GPU 共享功耗和散热预算；只改善其中一个部件的设置可能让另一个部件降频。"
    }
    else {
        "台式机仍需用本机原厂基线验证；硬件型号只能确定方向，不能推出安全数值。"
    }
    $coolingNote = if ($null -ne $Gate.CoolingContext) {
        "散热依据：$($Gate.CoolingContext.Summary) 功耗参考：$($Gate.CoolingContext.PowerEnvelope)"
    }
    else {
        "散热条件尚未确认，不承诺温度、噪音或持续性能余量。"
    }
    $platformNote = "$laptopNote $coolingNote"

    if ($routeText -match "gpu|显卡|图形") {
        if ($goalText -match "温|噪|功耗|能效|安静") {
            return [pscustomobject]@{
                Direction = "优先验证 GPU 核心电压/频率曲线的小步降压；目标是相近帧时间下降低功耗和温度。"
                FirstVariable = "仅一个 GPU 核心曲线或电压/频率控制点"
                Tradeoff = "若帧时间、1% low 或稳定性明显变差，即使温度更低也不算通过。"
                FollowUp = "下一轮至少回传同一固定负载的原厂/候选帧时间、功耗、核心温度、显存结温、有效频率和异常。"
                PlatformNote = $platformNote
                PriorNote = if ($PreviousContext -and $PreviousContext.PrimaryVariable) { "上一轮变量：$($PreviousContext.PrimaryVariable)。先确认上一轮结论，再决定是否沿同一方向继续。" } else { "" }
            }
        }
        return [pscustomobject]@{
            Direction = "先验证 GPU 核心频率/电压曲线的小步改善；核心方向稳定后，再单独测试显存频率。"
            FirstVariable = "仅一个 GPU 核心曲线偏移或单一核心控制点"
            Tradeoff = "性能提升必须是可重复的帧时间/吞吐改善，不能以伪影、驱动重置或更高噪声换取跑分。"
            FollowUp = "下一轮回传固定负载的帧时间、P1/P5、功耗、温度、显存结温和异常日志。"
            PlatformNote = $platformNote
            PriorNote = if ($PreviousContext -and $PreviousContext.PrimaryVariable) { "上一轮变量：$($PreviousContext.PrimaryVariable)。不要同时叠加显存和核心变量。" } else { "" }
        }
    }
    if ($routeText -match "cpu|处理器") {
        if ($goalText -match "温|噪|功耗|能效|安静") {
            return [pscustomobject]@{
                Direction = "优先验证 CPU 降压/负载线或厂商工具中的单项能效控制；目标是相近性能下降低封装温度和功耗。"
                FirstVariable = "仅一个 CPU 电压偏移、负载线或能效控制项"
                Tradeoff = "CPU 降压不应被描述为自动性能提升；性能明显下降或低负载不稳定就应回退。"
                FollowUp = "下一轮回传封装温度、封装功耗、有效频率、固定负载结果、WHEA/重启和低负载稳定性。"
                PlatformNote = $platformNote
                PriorNote = if ($PreviousContext -and $PreviousContext.PrimaryVariable) { "上一轮变量：$($PreviousContext.PrimaryVariable)。先确认上一轮结论再继续。" } else { "" }
            }
        }
        return [pscustomobject]@{
            Direction = "先确认原厂功耗墙和温度余量，再只调整一个 CPU 倍频、功耗限制或受支持的单核心控制项。"
            FirstVariable = "仅一个 CPU 倍频、功耗限制或单核心控制项"
            Tradeoff = "CPU 性能方向必须对应固定吞吐/跑分和稳定性；更高瞬时频率不等于更长持续性能。"
            FollowUp = "下一轮回传固定负载得分/耗时、有效频率、封装功耗、温度、限流原因和稳定性异常。"
            PlatformNote = $platformNote
            PriorNote = if ($PreviousContext -and $PreviousContext.PrimaryVariable) { "上一轮变量：$($PreviousContext.PrimaryVariable)。沿用同一固定负载再比较。" } else { "" }
        }
    }
    if ($routeText -match "内存|memory|ram") {
        return [pscustomobject]@{
            Direction = "若当前仍低于内存额定配置，先验证 XMP/EXPO 整套配置；之后再只改一个时序或相关时序组。"
            FirstVariable = "XMP/EXPO 整套配置，或一个明确的内存时序项"
            Tradeoff = "频率和时序不能跨颗粒、容量、rank 或笔记本/台式机照搬；训练失败、冷启动或数据异常都应回退。"
            FollowUp = "下一轮回传实际频率/时序、训练与重启行为、固定负载结果、内存温度和任何数据/稳定性异常。"
            PlatformNote = $platformNote
            PriorNote = if ($PreviousContext -and $PreviousContext.PrimaryVariable) { "上一轮变量：$($PreviousContext.PrimaryVariable)。不要同时改变频率和多个时序。" } else { "" }
        }
    }

    return [pscustomobject]@{
        Direction = "先明确一个目标部件和原厂基线，再选择一个可恢复的最小控制项验证。"
        FirstVariable = "本轮唯一控制项"
        Tradeoff = "没有配置和目标对应关系时，不应提供任何通用超频数值。"
        FollowUp = "补充平台、目标、固定负载和上一轮结果后再确定方向。"
        PlatformNote = $platformNote
        PriorNote = ""
    }
}

function Open-TextFile {
    param([string]$Path)

    $answer = Read-Host "现在用记事本打开结果吗？输入 y 打开，直接回车跳过"
    if ($answer -match "^(y|yes|是)$") {
        Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $Path) | Out-Null
    }
}

function Show-CollectionModes {
    Write-Host "读取配置有两种模式：" -ForegroundColor Yellow
    Write-Host "  标准模式：保留精确电脑、主板/笔记本、BIOS、内存料号、硬盘型号和显示器 ID。"
    Write-Host "            适合自己的电脑或可信排障，分析最准确；分享给他人要谨慎。"
    Write-Host "  隐私脱敏：隐藏型号级标识，保留容量、速度、核心/线程、接口、映射和显示能力。"
    Write-Host "            适合公开发送；型号级兼容、保修和残值判断精度会下降。"
    Write-Host "  两种模式都只读、本地运行、不联网、不修改设置，默认不输出序列号。"
    Write-Host ""
}

function Select-HardwareCollectionModeAndRun {
    Clear-Host
    Write-Host "读取电脑配置" -ForegroundColor Cyan
    Write-Host "请选择报告模式：" -ForegroundColor Yellow
    Write-Host "  1. 标准模式"
    Write-Host "     保留精确电脑、主板/笔记本、BIOS、内存料号、硬盘型号和显示器 ID。"
    Write-Host "     适合自己查看或可信排障；分享前需要检查隐私。"
    Write-Host "  2. 隐私脱敏"
    Write-Host "     隐藏型号级标识，保留容量、速度、核心/线程、接口和显示能力。"
    Write-Host "     适合发给别人；型号兼容、保修和残值判断会更不精确。"
    Write-Host "  0. 返回主菜单"
    Write-Host ""

    $choice = Read-Host "输入 1、2 或 0"
    if ($null -eq $choice) {
        return
    }
    switch ($choice.Trim()) {
        "1" {
            Invoke-HardwareCollection -BeginnerFriendly
        }
        "2" {
            Invoke-HardwareCollection -Redacted -BeginnerFriendly
        }
        "0" {
            Write-Host "已取消，没有读取配置。" -ForegroundColor Yellow
        }
        default {
            Write-Host "请输入 1、2 或 0。" -ForegroundColor Red
        }
    }
}

function Invoke-HardwareCollection {
    param(
        [switch]$Redacted,
        [switch]$BeginnerFriendly,
        [switch]$ReturnPath
    )

    if (-not $BeginnerFriendly) {
        Show-CollectionModes
    }
    else {
        Write-Host "这一步只读取配置，不会修改任何设置。" -ForegroundColor Yellow
        if ($Redacted) {
            Write-Host "结果会隐藏具体型号，适合发给别人。"
        }
        else {
            Write-Host "结果保留完整型号，适合自己查看或交给可信的技术人员。"
        }
    }
    $modeName = if ($Redacted) { "隐私脱敏" } else { "标准" }
    $confirmPrompt = if ($BeginnerFriendly) {
        "确认现在只读读取配置吗？输入 y 继续"
    }
    else {
        "确认运行$modeName模式只读采集吗？输入 y 继续"
    }
    $confirm = Read-Host $confirmPrompt
    if ($confirm -notmatch "^(y|yes|是)$") {
        Write-Host "已取消，本次没有生成配置单。" -ForegroundColor Yellow
        return $null
    }

    $collectorPath = Join-Path $scriptsRoot "collect-windows.ps1"
    if (-not (Test-Path -LiteralPath $collectorPath -PathType Leaf)) {
        throw "缺少采集器：$collectorPath"
    }
    $identityHelperPath = Join-Path $scriptsRoot "device-identity.ps1"
    if (-not (Test-Path -LiteralPath $identityHelperPath -PathType Leaf)) {
        throw "缺少设备身份辅助文件：$identityHelperPath"
    }

    $outputPath = New-OutputPath -Prefix ("hardware-" + $(if ($Redacted) { "redacted" } else { "standard" })) -Category "配置报告"
    $arguments = @{
        Format = "Markdown"
        OutputPath = $outputPath
    }
    if ($Redacted) {
        $arguments.RedactIdentifiers = $true
    }

    Write-Host ""
    Write-Host "正在读取本机配置，请稍候……" -ForegroundColor Cyan
    & $collectorPath @arguments | Out-Null

    if (-not (Test-Path -LiteralPath $outputPath -PathType Leaf)) {
        throw "采集器没有生成结果文件。"
    }

    Write-Host ""
    Write-Host "采集完成：$outputPath" -ForegroundColor Green
    $hardwareContext = Set-ActiveHardwareReport -Path $outputPath
    if ($null -ne $hardwareContext) {
        $identityColor = if ($hardwareContext.IdentityQuality -eq "readable") { "Green" } elseif ($hardwareContext.IdentityQuality -eq "redacted") { "DarkGray" } else { "Yellow" }
        Write-Host "设备身份：$(Get-HardwareIdentitySummary -HardwareContext $hardwareContext)" -ForegroundColor $identityColor
        foreach ($warning in @($hardwareContext.IdentityWarnings | Select-Object -First 3)) {
            Write-Host "身份警告：$warning" -ForegroundColor Yellow
        }
    }
    Write-Host "下一步：核对报告中的平台和部件；配置单不代表稳定状态，也不代表调校已生效。" -ForegroundColor Cyan
    Open-TextFile -Path $outputPath
    if ($ReturnPath) {
        return $outputPath
    }
}

function Select-TelemetryFile {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Title = "选择监控软件保存的记录（通常是 .csv）"
        $dialog.Filter = "监控记录或 CSV 文件 (*.csv)|*.csv|所有文件 (*.*)|*.*"
        $dialog.CheckFileExists = $true
        $dialog.Multiselect = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.FileName
        }
        return $null
    }
    catch {
        $manual = Read-Host "请输入监控记录文件的完整路径（通常是 .csv）"
        if ([string]::IsNullOrWhiteSpace($manual)) {
            return $null
        }
        return $manual.Trim('"')
    }
}

function Read-NonNegativeNumber {
    param(
        [string]$Prompt,
        [double]$Default = 0
    )

    while ($true) {
        $raw = Read-Host ("{0}（默认 {1}）" -f $Prompt, $Default)
        if ($null -eq $raw) {
            throw "输入已取消。"
        }
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Default
        }

        $value = 0.0
        if ([double]::TryParse($raw, [ref]$value) -and $value -ge 0) {
            return $value
        }
        Write-Host "请输入不小于 0 的数字，例如 0、60 或 300。" -ForegroundColor Yellow
    }
}

function Show-HwinfoDownloadGuidance {
    param([switch]$RecordingOnly)

    Clear-Host
    if ($RecordingOnly) {
        Write-Host "HWiNFO 记录生成说明" -ForegroundColor Cyan
    }
    else {
        Write-Host "HWiNFO 下载与记录说明" -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host "HWiNFO 在当前流程中只观察数据，不会修改频率、电压、功耗或 BIOS。"
    if (-not $RecordingOnly) {
        Write-Host "  官方下载页：https://www.hwinfo.com/download/"
        Write-Host ""
        Write-Host "新手默认选择 Installer；只有明确需要免安装时才选 Portable。" -ForegroundColor Yellow
        Write-Host "在 Free Download 下按以下顺序选择：" -ForegroundColor Yellow
        Write-Host "  1. Local (U.S.)：官方 hwinfo.com 直链，首选。U.S. 只是服务器位置，不是地区限制。"
        Write-Host "  2. SAC ftp (SK)：官方页面链接的备用镜像。"
        Write-Host "  3. dAppCDN (Fast CDN)：最后备用。部分网络实测会超时，不要反复等待。"
        Write-Host ""
        Write-Host "DWG FastView、LanSweeper、OPEN、Try Now 等都是广告，不是 HWiNFO 下载按钮。" -ForegroundColor Red
        Write-Host "不要把 HWiNFO 安装包直接放进本工具分享包；请从官方页面下载。" -ForegroundColor DarkYellow
        Write-Host ""
    }
    if ($RecordingOnly) {
        Write-Host "接下来："
    }
    else {
        Write-Host "下载安装后："
    }
    Write-Host "  1. 打开 HWiNFO 时选 Sensors-only；"
    Write-Host "  2. 开始记录并保存为 CSV；"
    Write-Host "  3. 运行你要测试的游戏或软件；"
    Write-Host "  4. 测试结束后停止记录。"
    Write-Host ""
    Write-Host "原始 CSV 可能附有设备信息，发给别人时优先只发分析摘要。" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "生成记录后，再选择“我有一份监控软件导出的记录，想分析结果”。" -ForegroundColor Green
}

function Show-BeginnerMonitoringGuidance {
    Show-HwinfoDownloadGuidance
}

function Invoke-MonitoringAnalysisEntry {
    param([switch]$BeginnerFriendly)

    while ($true) {
        Clear-Host
        Write-Host "分析监控记录前的确认" -ForegroundColor Cyan
        Write-Host "分析文件需要先有监测软件导出的记录，通常是以 .csv 结尾的表格。"
        Write-Host ""
        Write-Host "  1. 已安装监测软件，并且已经有一份记录"
        Write-Host "  2. 已安装监测软件，但还没有生成记录"
        Write-Host "  3. 还没有安装监测软件"
        Write-Host "  0. 返回"
        Write-Host ""
        $choice = Read-Host "输入 1、2、3 或 0"
        if ($null -eq $choice) {
            return
        }
        switch ($choice.Trim()) {
            "1" {
                Invoke-TelemetryAnalysis -BeginnerFriendly:$BeginnerFriendly -SkipRecordPrompt
                return
            }
            "2" {
                Show-HwinfoDownloadGuidance -RecordingOnly
                Pause-Menu
            }
            "3" {
                Show-HwinfoDownloadGuidance
                Pause-Menu
            }
            "0" {
                Write-Host "已取消，没有分析监控记录。" -ForegroundColor Yellow
                return
            }
            default {
                Write-Host "请输入 1、2、3 或 0。" -ForegroundColor Red
                Pause-Menu
            }
        }
    }
}

function Invoke-TelemetryAnalysis {
    param(
        [switch]$BeginnerFriendly,
        [switch]$SkipRecordPrompt,
        [switch]$ReturnPath
    )

    if ($BeginnerFriendly -and -not $SkipRecordPrompt) {
        Write-Host ""
        Write-Host "监控软件可以把温度、频率、功耗和帧率保存成一份记录。"
        Write-Host "这类文件通常叫 CSV，也就是监控软件保存成表格的文件，文件名一般以 .csv 结尾。"
        Write-Host ""

        $ready = Read-Host "确认已有监控记录文件吗？输入 y 选择文件；直接回车返回"
        if ($ready -notmatch "^(y|yes|是)$") {
            return
        }
    }

    while ($true) {
        $sourcePath = Select-TelemetryFile
        if (-not $sourcePath) {
            Write-Host "没有选择监控记录，本次分析已取消。" -ForegroundColor Yellow
            return
        }
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            break
        }
        Write-Host "文件不存在：$sourcePath。请重新选择。" -ForegroundColor Yellow
    }

    if ($BeginnerFriendly) {
        $warmup = 0
        $duration = 0
        Write-Host "先统计整个文件，不需要你计算时间。"
        Write-Host "如果文件里混有待机、加载或刚关闭软件的画面，结果只算初步参考。" -ForegroundColor Yellow
    }
    else {
        $warmup = Read-NonNegativeNumber -Prompt "前面多少秒不计入统计？0 表示从文件开头统计" -Default 0
        $duration = Read-NonNegativeNumber -Prompt "统计多久？0 表示统计到文件结尾" -Default 0
    }

    $analyzerPath = Join-Path $scriptsRoot "analyze-telemetry.ps1"
    if (-not (Test-Path -LiteralPath $analyzerPath -PathType Leaf)) {
        throw "缺少遥测分析脚本：$analyzerPath"
    }

    $arguments = @{
        Path = $sourcePath
        Format = "Markdown"
        WarmupSeconds = $warmup
        DurationSeconds = $duration
    }

    Write-Host ""
    Write-Host "正在分析监控记录……" -ForegroundColor Cyan
    $analysis = @(& $analyzerPath @arguments 2>&1 | ForEach-Object { $_.ToString() })
    if ($BeginnerFriendly) {
        $analysis = @(
            "> 新手模式：已自动统计整个文件。",
            "> 如果记录包含待机、加载、正式负载或恢复阶段，这份摘要只能作初步参考，不能单独证明硬件稳定。",
            ""
        ) + $analysis
    }
    $outputPath = New-OutputPath -Prefix "telemetry-summary" -Category "遥测分析"
    [IO.File]::WriteAllText($outputPath, ($analysis -join "`r`n"), $utf8)

    Write-Host "分析完成：$outputPath" -ForegroundColor Green
    Write-Host "下一步：结合固定负载判断结果；单个摘要不能单独证明硬件稳定。" -ForegroundColor Cyan
    Open-TextFile -Path $outputPath
    if ($ReturnPath) {
        return $outputPath
    }
}

function Read-CardValue {
    param(
        [string]$Prompt,
        [string]$Default = "待填写"
    )

    $value = Read-Host ("{0}（直接回车使用 [{1}]）" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}

function Read-RequiredTuningValue {
    param(
        [string]$Prompt,
        [string]$MissingLabel,
        [string]$Example,
        [string]$Default
    )

    while ($true) {
        if (-not [string]::IsNullOrWhiteSpace($Default)) {
            $value = Read-Host ("{0}（回车沿用上次 [{1}]；输入 ? 获取帮助）" -f $Prompt, $Default)
        }
        else {
            $value = Read-Host ("{0}（输入 ? 获取帮助）" -f $Prompt)
        }
        if ($null -eq $value) {
            return $null
        }
        $value = $value.Trim()
        if ($value -match '^(b|back|返回)$') {
            return "__BACK__"
        }
        if ($value -match '^(q|quit|退出)$') {
            return "__CANCEL__"
        }
        if ($value -match '^(\?|？|不知道|不确定)$') {
            Show-TuningGatePreparationHelp $MissingLabel
            continue
        }
        if ([string]::IsNullOrWhiteSpace($value) -and -not [string]::IsNullOrWhiteSpace($Default)) {
            return $Default
        }
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
        Write-Host "这一项不能留空。例如：$Example" -ForegroundColor Yellow
    }
}

function Show-TuningGatePreparationHelp {
    param([string]$Missing)

    Clear-Host
    Write-Host "还不能生成调校实验卡：$Missing" -ForegroundColor Yellow
    Write-Host "这不是让你自己摸索后回来，下面直接告诉你怎样补齐。" -ForegroundColor Cyan
    Write-Host ""
    $showAll = [string]::IsNullOrWhiteSpace($Missing)
    if ($showAll -or $Missing -match "稳定") {
        Write-Host "稳定基线" -ForegroundColor Yellow
        Write-Host "  先保存或截图当前设置，恢复原厂/已知稳定配置，重启后正常使用一段时间。"
        Write-Host "  如果仍有黑屏、重启、驱动重置、文件异常、过热或供电损坏，先排障，不调校。"
        Write-Host ""
    }
    if ($showAll -or $Missing -match "控制项") {
        Write-Host "找到控制项" -ForegroundColor Yellow
        Write-Host "  打开对应 BIOS、官方厂商工具或调校软件，确认里面确实有准备修改的选项。"
        Write-Host "  GPU 先看官方显卡软件；CPU 先看受支持的官方工具或 BIOS；内存先看主板 XMP/EXPO 或时序控制。"
        Write-Host "  找不到就不要猜，也不要解锁或刷改固件。"
        Write-Host ""
    }
    if ($showAll -or $Missing -match "平台|目标部件") {
        Write-Host "确认平台和部件" -ForegroundColor Yellow
        Write-Host "  从配置报告中确认电脑型号、CPU 和 GPU；本轮还要明确准备调 GPU、CPU 还是内存。"
        Write-Host "  如果报告属于另一台电脑，应重新选择配置单或重新采集。"
        Write-Host ""
    }
    if ($showAll -or $Missing -match "目标") {
        Write-Host "确认调校目标" -ForegroundColor Yellow
        Write-Host "  可选降温、降噪、提高持续性能、跑分或日常平衡；一次只选一个主要目标。"
        Write-Host ""
    }
    if ($showAll -or $Missing -match "恢复") {
        Write-Host "恢复方式" -ForegroundColor Yellow
        Write-Host "  改动前记录每个原值；找到软件里的重置默认、厂商默认配置，或 BIOS 的载入默认设置。"
        Write-Host "  确认屏幕或网络失效时自己仍能操作这台机器。风险自担不能代替恢复能力。"
        Write-Host ""
    }
    if ($showAll -or $Missing -match "负载|结果|指标") {
        Write-Host "固定负载与结果" -ForegroundColor Yellow
        Write-Host "  使用现有游戏的同一存档、内置基准、可重复渲染或合成测试，不要每次换场景。"
        Write-Host "  固定分辨率、画质、帧率上限、电源模式和采样时间；第一次先测原厂基线。"
        Write-Host "  主要看帧时间/帧数、功耗、温度、跑分或渲染时间。"
        Write-Host "  黑屏、重启、驱动重置、画面异常、异常高温或软件报错时必须停止。" -ForegroundColor Red
        Write-Host ""
    }
    Write-Host "返回后会继续同一项检查，已经回答的内容不会丢失。" -ForegroundColor Green
}

function Test-TuningSafetyPreflight {
    Clear-Host
    Write-Host "调校前的物理安全检查" -ForegroundColor Cyan
    Write-Host "如果出现下面任意情况，调校必须立即停止：" -ForegroundColor Red
    Write-Host "  烧焦味、冒烟、打火、液体进入通电设备、电源接头熔化或变色、" -ForegroundColor Red
    Write-Host "  电池鼓包、裸露损坏线材或可见电气损坏。" -ForegroundColor Red
    Write-Host ""

    while ($true) {
        $answer = Read-Host "当前是否存在上述危险现象？y=存在 / n=全部没有"
        if ($null -eq $answer) {
            return $false
        }
        switch ($answer.Trim().ToLowerInvariant()) {
            "y" {
                Write-Host ""
                Write-Host "已停止调校。请不要再跑压力测试或反复开机。" -ForegroundColor Red
                Write-Host "在安全时断电并停止使用，联系售后或有资质的维修人员。" -ForegroundColor Red
                return $false
            }
            "n" {
                return $true
            }
            default {
                Write-Host "请明确输入 y 或 n；这里不用默认值代替安全确认。" -ForegroundColor Yellow
            }
        }
    }
}

function Read-GpuBaselineReport {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [object]$HardwareContext
    )

    $subject = "$($State.Route) $($State.TargetPart)".ToLowerInvariant()
    if ($subject -notmatch "gpu|显卡|图形") {
        return $null
    }

    Clear-Host
    Write-Host "GPU 调校前的当前运行基线" -ForegroundColor Cyan
    Write-Host "先记录当前参数在固定游戏中的实际表现，再讨论曲线或频率。"
    Write-Host "参数仅供参考，请以安全为第一要务。" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "提供当前参数下的运行报告（填 CSV 路径、摘要文字或截图位置均可）。"
    Write-Host "应来自已经选定的固定游戏和固定场景，不能只填待机或瞬时峰值。" -ForegroundColor Yellow
    $source = Read-RequiredTuningValue `
        -Prompt "当前运行报告来源" `
        -MissingLabel "GPU 基线报告来源" `
        -Example "HWiNFO CSV 路径，或稳定运行 60 秒后的手动摘要"
    if ($source -eq "__BACK__" -or $source -eq "__CANCEL__") {
        return "__CANCEL__"
    }

    $performance = Read-RequiredTuningValue `
        -Prompt "同一窗口的平均/最低 FPS 或帧时间" `
        -MissingLabel "GPU 基线性能结果" `
        -Example "平均 120 FPS，1% low 95 FPS"
    if ($performance -eq "__BACK__" -or $performance -eq "__CANCEL__") {
        return "__CANCEL__"
    }

    $power = Read-RequiredTuningValue `
        -Prompt "同一窗口的显卡功耗" `
        -MissingLabel "GPU 基线功耗" `
        -Example "约 220 W"
    if ($power -eq "__BACK__" -or $power -eq "__CANCEL__") {
        return "__CANCEL__"
    }

    $temperature = Read-RequiredTuningValue `
        -Prompt "同一窗口的核心/热点温度" `
        -MissingLabel "GPU 基线温度" `
        -Example "核心 72°C；热点 88°C；未知项写“传感器未提供”"
    if ($temperature -eq "__BACK__" -or $temperature -eq "__CANCEL__") {
        return "__CANCEL__"
    }

    $limitReason = Read-RequiredTuningValue `
        -Prompt "同一窗口的主要性能限制原因（PerfCap/限流原因）" `
        -MissingLabel "GPU 基线限制原因" `
        -Example "Pwr、Thrm、VRel、VOp 或工具显示的对应原因；未知可写“工具未提供”"
    if ($limitReason -eq "__BACK__" -or $limitReason -eq "__CANCEL__") {
        return "__CANCEL__"
    }

    $powerPath = "笔记本内置供电；不支持第三方工具解锁功耗墙"
    if ($null -ne $HardwareContext -and -not [bool]$HardwareContext.IsLaptop) {
        $powerPath = Read-RequiredTuningValue `
            -Prompt "桌面电源型号、额定功率、使用年限和显卡供电接头状态" `
            -MissingLabel "GPU 供电路径未确认" `
            -Example "如：某型号 850W，使用 2 年，原生 12VHPWR/多 8pin 接头无变色和松动"
        if ($powerPath -eq "__BACK__" -or $powerPath -eq "__CANCEL__") {
            return "__CANCEL__"
        }
    }

    $voltage = Read-CardValue "固定游戏中代表性稳定核心电压（mV；传感器未提供可写未知）" -Default "未知"
    $coreClock = Read-CardValue "该稳定电压点对应的核心/有效频率（MHz；未记录可写未知）" -Default "未知"

    return [pscustomobject]@{
        Route = "待选择"
        Source = $source
        Performance = $performance
        Power = $power
        Temperature = $temperature
        LimitReason = $limitReason
        PowerPath = $powerPath
        Voltage = $voltage
        CoreClock = $coreClock
        Method = "等待在实验卡中填写当前默认参数后再选择路线"
    }
}

function Get-AvailableGpuRouteKeys {
    param([object]$HardwareContext)

    $keys = New-Object System.Collections.Generic.List[string]
    $keys.Add("Pure") | Out-Null
    $keys.Add("Curve") | Out-Null
    if ($null -eq $HardwareContext -or [bool]$HardwareContext.IsLaptop) {
        return @($keys.ToArray())
    }

    $keys.Add("DesktopSegment") | Out-Null
    $gpuText = (@($HardwareContext.GPUs) -join " ")
    $isFlagship = $gpuText -match "RTX\s*(4090|5090)" -and $gpuText -notmatch "Laptop"
    if (-not $isFlagship) {
        $keys.Add("DesktopPowerCeiling") | Out-Null
    }
    if ($gpuText -match "RTX\s*5090" -and $gpuText -notmatch "Laptop") {
        $keys.Add("RTX5090PowerCurve") | Out-Null
    }
    return @($keys.ToArray())
}

function Get-GpuRouteDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("Pure", "Curve", "DesktopSegment", "DesktopPowerCeiling", "RTX5090PowerCurve")]
        [string]$RouteKey
    )

    switch ($RouteKey) {
        "Pure" {
            return [pscustomobject]@{
                Key = "Pure"
                Route = "纯频率超频"
                Description = "不主动降压，不重画曲线形状；只修改一个核心频率或核心偏移步骤。"
                Method = "保持曲线形状不变，只做一个核心频率或核心偏移步骤；显存偏移和功耗墙本轮不动。"
                CandidatePrompt = "准备手动尝试的 GPU 核心频率或核心偏移候选值（显存与功耗墙本轮不动）"
            }
        }
        "Curve" {
            return [pscustomobject]@{
                Key = "Curve"
                Route = "曲线降压超频"
                Description = "根据游戏实际稳定电压点，抬高目标点、拉平右侧，必要时处理左侧低电压点。"
                Method = "抬高目标电压点，拉平其右侧所有点；左侧低电压点如一并抬高，必须额外验证待机和轻载。显存偏移与功耗墙本轮不动。"
                CandidatePrompt = "准备手动尝试的曲线形状（写明目标电压点、右侧拉平方式和左侧处理；显存与功耗墙本轮不动）"
            }
        }
        "DesktopSegment" {
            return [pscustomobject]@{
                Key = "DesktopSegment"
                Route = "桌面分段曲线降压超频"
                Description = "仅桌面 GPU：拉平高电压段，低电压保护段不动，只抬升中间电压段。"
                Method = "先记录曲线区间；将目标上限电压以上全部拉平，低电压保护区间保持不动，只抬升中间区间。RTX 5090 可参考 1.025V 以上拉平、0.8V 以下不动、先 +150 MHz，再以 ±15 或 ±50 MHz 微调；其他桌面 GPU 必须按自己的基线和曲线范围调整。显存与无关控制本轮不动。"
                CandidatePrompt = "准备手动尝试的分段曲线（写明低电压保护边界、中段范围、高电压拉平位置和候选频率）"
            }
        }
        "DesktopPowerCeiling" {
            return [pscustomobject]@{
                Key = "DesktopPowerCeiling"
                Route = "桌面功耗墙上限测试"
                Description = "仅非 4090/5090 且供电、散热和电源条件已确认的桌面 GPU；把厂商允许上限作为单独候选。"
                Method = "先确认显卡不是缩减供电/散热的低端设计，PSU 型号、功率、年限和显卡供电接头状态可靠，且基线主要表现为功耗限制。其他控制不动，只把功耗墙调到厂商工具允许的最高值；111% 或滑块上限只是参考，不是固定安全目标。"
                CandidatePrompt = "本轮厂商工具允许的最高功耗墙上限，以及调前百分比（核心曲线和显存本轮不动）"
            }
        }
        "RTX5090PowerCurve" {
            return [pscustomobject]@{
                Key = "RTX5090PowerCurve"
                Route = "桌面 RTX 5090 功耗墙加整段曲线"
                Description = "仅桌面 RTX 5090：降低功耗墙并整体抬升核心曲线。"
                Method = "将功耗墙设为 93% 作为参考起点，整段核心曲线先 +150 MHz，随后以 ±15 或 ±50 MHz 微调。功耗墙和曲线作为一个协调候选，不叠加显存修改。"
                CandidatePrompt = "准备手动尝试的整套 5090 功耗墙与曲线候选（功耗墙 93% 为参考，核心曲线 +150 MHz 起步，再记录微调值）"
            }
        }
    }
}

function Select-GpuTuningRoute {
    param(
        [Parameter(Mandatory = $true)][object]$Baseline,
        [object]$HardwareContext
    )

    $availableKeys = @(Get-AvailableGpuRouteKeys -HardwareContext $HardwareContext)
    $definitions = @($availableKeys | ForEach-Object { Get-GpuRouteDefinition -RouteKey $_ })
    $isLaptop = $null -ne $HardwareContext -and [bool]$HardwareContext.IsLaptop

    while ($true) {
        Clear-Host
        Write-Host "GPU 当前参数已记录，选择本轮路线" -ForegroundColor Cyan
        Write-Host "参数仅供参考，请以安全为第一要务。" -ForegroundColor Yellow
        Write-Host "当前基线：性能 $($Baseline.Performance)；功耗 $($Baseline.Power)；温度 $($Baseline.Temperature)"
        Write-Host "主要限流原因：$($Baseline.LimitReason)"
        Write-Host "供电路径：$($Baseline.PowerPath)"
        Write-Host "代表性电压：$($Baseline.Voltage)；对应核心/有效频率：$($Baseline.CoreClock)"
        Write-Host "若基线显示明显热压力或频率大幅波动，可把适度降低功耗墙作为下一轮单独候选；不是固定规律。" -ForegroundColor DarkGray
        if ($isLaptop) {
            Write-Host "笔记本提示：不提供桌面分段或功耗墙上限路线，也不推荐大幅超频显存；不要用第三方工具解锁隐藏功耗墙。" -ForegroundColor Yellow
        }
        Write-Host ""
        for ($index = 0; $index -lt $definitions.Count; $index++) {
            Write-Host ("  {0}. {1}" -f ($index + 1), $definitions[$index].Route)
            Write-Host ("     {0}" -f $definitions[$index].Description)
        }
        Write-Host "  0. 取消"
        $choice = Read-Host ("输入 1-{0} 或 0" -f $definitions.Count)
        if ($null -eq $choice -or $choice.Trim() -eq "0") {
            return "__CANCEL__"
        }
        $index = 0
        if (-not [int]::TryParse($choice.Trim(), [ref]$index) -or $index -lt 1 -or $index -gt $definitions.Count) {
            Write-Host "没有识别这个序号。" -ForegroundColor Red
            continue
        }

        $selected = $definitions[$index - 1]
        if ($selected.Key -in @("Curve", "DesktopSegment")) {
            $voltageUnknown = [string]::IsNullOrWhiteSpace([string]$Baseline.Voltage) -or $Baseline.Voltage -match "未知|未提供|无法读取"
            $clockUnknown = [string]::IsNullOrWhiteSpace([string]$Baseline.CoreClock) -or $Baseline.CoreClock -match "未知|未提供|无法读取"
            if ($voltageUnknown -or $clockUnknown) {
                Write-Host "这条路线需要可用的代表性电压和核心频率；当前基线不足。" -ForegroundColor Yellow
                Write-Host "可以返回补测后重来，或改选其他路线。" -ForegroundColor Yellow
                Pause-Menu
                continue
            }
        }
        if ($selected.Key -eq "DesktopPowerCeiling") {
            if ([string]::IsNullOrWhiteSpace([string]$Baseline.PowerPath) -or
                $Baseline.PowerPath -match "未知|未提供|无法确认") {
                Write-Host "功耗墙上限测试需要明确 PSU、供电路径和接头状态；当前基线不足。" -ForegroundColor Yellow
                continue
            }
            if ($Baseline.LimitReason -match "Thrm|温度|热") {
                Write-Host "基线主要是温度限制，优先考虑降低功耗墙或改善散热，不应先拉高功耗墙。" -ForegroundColor Yellow
                Pause-Menu
                continue
            }
        }
        return $selected
    }
}

function Get-Intel13Or14CpuRisk {
    param([object]$HardwareContext)

    if ($null -eq $HardwareContext -or [string]::IsNullOrWhiteSpace([string]$HardwareContext.CPU)) {
        return $null
    }
    $cpu = [string]$HardwareContext.CPU
    if ($cpu -notmatch "Intel" -or $cpu -notmatch "i[3579][ -]?1[34][0-9]{3}") {
        return $null
    }
    return [pscustomobject]@{
        Cpu = $cpu
        IsLaptop = [bool]$HardwareContext.IsLaptop
    }
}

function Read-Intel13Or14CpuRiskNotice {
    param([object]$Risk)

    Clear-Host
    Write-Host "Intel 13/14 代 CPU 附加风险检查" -ForegroundColor Yellow
    Write-Host "检测到：$($Risk.Cpu)" -ForegroundColor Cyan
    Write-Host "桌面高功耗 13/14 代型号存在已知稳定性/退化风险；这不代表当前 CPU 一定已损坏，也不能把笔记本直接套成同一故障模式。" -ForegroundColor Red
    Write-Host "若在默认/原厂设置下已有蓝屏、WHEA、编译失败或游戏崩溃，先排障和走保固，不用降压、定压定频或超频掩盖问题。" -ForegroundColor Yellow
    Write-Host "先确认当前主板/笔记本厂商的官方 BIOS、微码和推荐默认配置。" -ForegroundColor Yellow
    Write-Host "参数仅供参考，请以安全为第一要务。" -ForegroundColor Yellow
    $source = Read-CardValue "CPU 来源（原盒 / 散片OEM / 不清楚）" -Default "不清楚"
    $warranty = Read-CardValue "购买凭证和保修状态（有 / 无 / 不确定）" -Default "不确定"
    return [pscustomobject]@{
        Cpu = $Risk.Cpu
        FormFactor = $(if ($Risk.IsLaptop) { "笔记本" } else { "桌面或平台形态待确认" })
        Source = $source
        Warranty = $warranty
        Guidance = "先以官方微码和默认配置确认稳定；稳定后才考虑平台支持的降压或定压定频单变量实验，不暴露隐藏固件控制。"
    }
}

function Invoke-TuningEntryGate {
    param([string]$ConfigPath)

    if (-not (Test-TuningSafetyPreflight)) {
        return $null
    }

    $hardwareContext = if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        Get-HardwareReportContext -Path $ConfigPath
    }
    else {
        $null
    }
    $intelRisk = Get-Intel13Or14CpuRisk -HardwareContext $hardwareContext
    $intelRiskNotice = if ($null -ne $intelRisk) {
        Read-Intel13Or14CpuRiskNotice -Risk $intelRisk
    }
    else {
        $null
    }
    $coolingContext = $null
    $previousCard = Get-LatestExperimentCard
    $previousContext = if ($null -ne $previousCard) {
        Get-ExperimentCardContext -Path $previousCard.FullName
    }
    else {
        $null
    }
    $state = [pscustomobject]@{
        Stable = $false
        ControlExists = $false
        TargetPart = $null
        Route = $null
        Objective = $null
        Recovery = $null
        Workload = $null
        PrimaryMetric = $null
        AbortSignals = $null
    }
    $step = 1

    do {
        while ($step -le 7) {
            Clear-Host
            Write-Host "硬件调校入口检查" -ForegroundColor Cyan
            if ($null -ne $hardwareContext -and -not [string]::IsNullOrWhiteSpace($hardwareContext.Platform)) {
                Write-Host "当前平台：$($hardwareContext.Platform)" -ForegroundColor DarkGray
                if ($hardwareContext.IdentityQuality -ne "readable") {
                    Write-Host "设备身份：$(Get-HardwareIdentitySummary -HardwareContext $hardwareContext)" -ForegroundColor DarkYellow
                }
            }
            if ($null -ne $previousContext) {
                Write-Host "上一轮参考：$($previousCard.Name)" -ForegroundColor DarkGray
            }
            Write-Host "操作：回车确认默认值 / ? 获取帮助 / B 返回上一项 / Q 取消" -ForegroundColor DarkGray
            Write-Host ""

            switch ($step) {
                1 {
                    $value = Read-Host "检查 1/7：当前未应用本轮改动的配置能稳定使用吗？y=能 / n=不能 / B / Q"
                    if ($null -eq $value -or $value.Trim() -match '^(q|quit|退出)$') { return $null }
                    if ($value.Trim() -match '^(b|back|返回)$') { return $null }
                    if ($value.Trim() -match '^(y|yes|是)$') {
                        $state.Stable = $true
                        $step = 2
                    }
                    else {
                        Show-TuningGatePreparationHelp "稳定基线未确认"
                        $retry = Read-Host "处理完成后按回车重新检查；B 返回，Q 取消"
                        if ($null -eq $retry -or $retry.Trim() -match '^(q|quit|退出)$') { return $null }
                        if ($retry.Trim() -match '^(b|back|返回)$') { return $null }
                    }
                }
                2 {
                    $value = Read-Host "检查 2/7：已在 BIOS/厂商工具/调校软件中找到准备修改的控制项吗？y=是 / n=否 / B / Q"
                    if ($null -eq $value -or $value.Trim() -match '^(q|quit|退出)$') { return $null }
                    if ($value.Trim() -match '^(b|back|返回)$') { $step = 1; break }
                    if ($value.Trim() -match '^(y|yes|是)$') {
                        $state.ControlExists = $true
                        $step = 3
                    }
                    else {
                        Show-TuningGatePreparationHelp "暂时找不到要修改的控制项"
                        $retry = Read-Host "确认控制项后按回车重新检查；B 返回，Q 取消"
                        if ($null -eq $retry -or $retry.Trim() -match '^(q|quit|退出)$') { return $null }
                        if ($retry.Trim() -match '^(b|back|返回)$') { $step = 1; break }
                    }
                }
                3 {
                    if ($null -ne $hardwareContext -and -not [string]::IsNullOrWhiteSpace($hardwareContext.Platform)) {
                        $default = if ($state.TargetPart) { $state.TargetPart } elseif ($previousContext) { $previousContext.TargetPart } else { $null }
                        $targetPart = Read-RequiredTuningValue `
                            -Prompt "检查 3/7：本轮要调哪个部件（GPU、CPU、内存或其他）？" `
                            -MissingLabel "目标部件未确认" `
                            -Example "GPU 核心曲线" `
                            -Default $default
                        if ($targetPart -eq "__BACK__") { $step = 2; break }
                        if ($targetPart -eq "__CANCEL__" -or $null -eq $targetPart) { return $null }
                        $state.TargetPart = $targetPart
                        $state.Route = "$($hardwareContext.Platform)；目标部件: $targetPart"
                    }
                    else {
                        $default = if ($state.Route) { $state.Route } elseif ($previousContext) { $previousContext.Route } else { $null }
                        $route = Read-RequiredTuningValue `
                            -Prompt "检查 3/7：要调哪台电脑的哪个部件？" `
                            -MissingLabel "具体平台或目标部件未确认" `
                            -Example "某型号笔记本，RTX 5070 Ti 显卡核心曲线" `
                            -Default $default
                        if ($route -eq "__BACK__") { $step = 2; break }
                        if ($route -eq "__CANCEL__" -or $null -eq $route) { return $null }
                        $state.Route = $route
                    }
                    if ($null -ne $hardwareContext) {
                        $coolingContext = Get-CoolingContext `
                            -ConfigPath $ConfigPath `
                            -HardwareContext $hardwareContext `
                            -TargetPart $state.TargetPart
                    }
                    $step = 4
                }
                4 {
                    $default = if ($state.Objective) { $state.Objective } elseif ($previousContext) { $previousContext.Objective } else { $null }
                    $objective = Read-RequiredTuningValue `
                        -Prompt "检查 4/7：本轮想改善什么？" `
                        -MissingLabel "调校目标未确认" `
                        -Example "降低游戏温度，同时保持帧时间不明显变差" `
                        -Default $default
                    if ($objective -eq "__BACK__") { $step = 3; break }
                    if ($objective -eq "__CANCEL__" -or $null -eq $objective) { return $null }
                    $state.Objective = $objective
                    $step = 5
                }
                5 {
                    $default = if ($state.Recovery) { $state.Recovery } elseif ($previousContext) { $previousContext.Recovery } else { $null }
                    $recovery = Read-RequiredTuningValue `
                        -Prompt "检查 5/7：出问题时怎样恢复原厂或已知稳定配置？" `
                        -MissingLabel "恢复方式未确认" `
                        -Example "在厂商工具中恢复默认配置，必要时重启后重新选择原厂模式" `
                        -Default $default
                    if ($recovery -eq "__BACK__") { $step = 4; break }
                    if ($recovery -eq "__CANCEL__" -or $null -eq $recovery) { return $null }
                    $state.Recovery = $recovery
                    $step = 6
                }
                6 {
                    $default = if ($state.Workload) { $state.Workload } elseif ($previousContext) { $previousContext.Workload } else { $null }
                    $workload = Read-RequiredTuningValue `
                        -Prompt "检查 6/7：用哪个固定游戏、渲染或测试项目进行比较？" `
                        -MissingLabel "固定工作负载未确认" `
                        -Example "某游戏同一存档路线，固定画质和分辨率" `
                        -Default $default
                    if ($workload -eq "__BACK__") { $step = 5; break }
                    if ($workload -eq "__CANCEL__" -or $null -eq $workload) { return $null }
                    $state.Workload = $workload
                    $step = 7
                }
                7 {
                    $default = if ($state.PrimaryMetric) { $state.PrimaryMetric } elseif ($previousContext) { $previousContext.PrimaryMetric } else { $null }
                    $metric = Read-RequiredTuningValue `
                        -Prompt "检查 7/7：主要看什么结果？" `
                        -MissingLabel "主要结果和保护指标未确认" `
                        -Example "比较平均帧时间和功耗，同时记录最高显存温度" `
                        -Default $default
                    if ($metric -eq "__BACK__") { $step = 6; break }
                    if ($metric -eq "__CANCEL__" -or $null -eq $metric) { return $null }
                    $state.PrimaryMetric = $metric
                    if ($null -ne $previousContext -and -not [string]::IsNullOrWhiteSpace($previousContext.AbortSignals)) {
                        $defaultAbort = $previousContext.AbortSignals
                    }
                    else {
                        $defaultAbort = "黑屏、重启、驱动重置、画面异常、异常高温或软件报错"
                    }
                    $abort = Read-Host "中止条件：哪些异常必须立即停止？直接回车使用 [$defaultAbort]"
                    if ($null -eq $abort) { return $null }
                    if ($abort.Trim() -match '^(q|quit|退出)$') { return $null }
                    if ($abort.Trim() -match '^(b|back|返回)$') { $step = 6; break }
                    $state.AbortSignals = if ([string]::IsNullOrWhiteSpace($abort)) { $defaultAbort } else { $abort.Trim() }
                    $step = 8
                }
            }
        }

        Write-Host ""
        Write-Host "入口检查结果：" -ForegroundColor Green
        Write-Host "  平台/部件：$($state.Route.Trim())"
        Write-Host "  目标：$($state.Objective.Trim())"
        Write-Host "  固定负载：$($state.Workload.Trim())"
        Write-Host "  主要结果：$($state.PrimaryMetric.Trim())"
        Write-Host "  恢复方式：$($state.Recovery.Trim())"
        Write-Host "  中止信号：$($state.AbortSignals.Trim())"
        if ($null -ne $coolingContext) {
            Write-Host "  散热依据：$($coolingContext.Summary)"
        }
        Write-Host "  当前配置：已确认可稳定使用"
        Write-Host "  控制项：已确认在工具或 BIOS 中存在"
        Write-Host "本轮重点是理解证据和判断；参数只是这次记录，不是要背下来的固定答案。" -ForegroundColor Cyan

        do {
            $confirm = Read-Host "以上信息正确吗？y 继续 / B 返回逐项检查 / Q 取消"
            if ($null -eq $confirm) {
                return $null
            }
            if ($confirm.Trim() -notmatch '^(y|yes|是|b|back|返回|q|quit|退出)$') {
                Write-Host "请输入 y、B 或 Q。" -ForegroundColor Yellow
            }
        } while ($confirm.Trim() -notmatch '^(y|yes|是|b|back|返回|q|quit|退出)$')

        if ($confirm.Trim() -match '^(q|quit|退出)$') {
            Write-Host "已取消，本次入口检查未生成实验卡。" -ForegroundColor Yellow
            return $null
        }
        if ($confirm.Trim() -match '^(b|back|返回)$') {
            $step = 1
            continue
        }
        if ($confirm.Trim() -match '^(y|yes|是)$') {
            $gpuBaseline = Read-GpuBaselineReport -State $state -HardwareContext $hardwareContext
            if ($gpuBaseline -eq "__CANCEL__") {
                Write-Host "GPU 当前运行基线未完成，本次没有生成调校实验卡。" -ForegroundColor Yellow
                return $null
            }
            return [pscustomobject]@{
                Route = $state.Route.Trim()
                Objective = $state.Objective.Trim()
                Recovery = $state.Recovery.Trim()
                Workload = $state.Workload.Trim()
                PrimaryMetric = $state.PrimaryMetric.Trim()
                AbortSignals = $state.AbortSignals.Trim()
                HardwareContext = $hardwareContext
                CoolingContext = $coolingContext
                PreviousContext = $previousContext
                GpuBaseline = $gpuBaseline
                IntelRiskNotice = $intelRiskNotice
            }
        }
    } while ($step -eq 1)

    return $null
}

function Get-PlainLanguageExplanation {
    param(
        [Parameter(Mandatory = $true)][string]$Variable,
        [Parameter(Mandatory = $true)][string]$Goal,
        [Parameter(Mandatory = $true)][string]$AbortSignals,
        [Parameter(Mandatory = $true)][string]$Rollback
    )

    $subject = "$Variable $Goal"
    if ($subject -match "电压|降压|Vcore|MSVDD|电压曲线") {
        $analogy = "像把发动机供油稍微调低，希望用更少消耗完成同样工作；但留量太少就可能熄火。这只是帮助理解的类比，不代表两者在技术上等价。"
        $risk = "稳定性或性能余量变小"
    }
    elseif ($subject -match "时序|tREFI|tRFC|tFAW|CL\d|内存") {
        $analogy = "像把传送带的检查间隔或节拍卡得更紧，配合得好会更快，但余量不足就容易出错。这只是帮助理解的类比，不代表内存机制完全相同。"
        $risk = "锁频、启动失败或数据完整性问题"
    }
    elseif ($subject -match "功耗|功率|PL1|PL2|TGP|TDP") {
        $analogy = "像给整台电脑设一个用电预算：预算低一些通常更凉、更安静，但重任务可能跑得更慢。"
        $risk = "性能不足、异常限流或体验下降"
    }
    elseif ($subject -match "频率|倍频|核心曲线|Crossbar|显存偏移") {
        $analogy = "像提高发动机转速：产出可能更高，但发热、功耗和稳定性压力也会上升。"
        $risk = "发热、功耗和不稳定风险增加"
    }
    elseif ($subject -match "风扇|转速|曲线") {
        $analogy = "像给风扇设定更积极或更保守的加速规则：转得快更凉但更吵，转得慢更安静但更容易升温。"
        $risk = "噪音、降频或温度波动"
    }
    else {
        $analogy = "像只拧一颗螺丝并保持其他零件不动，方便判断变化究竟来自哪里；但这个类比不代表参数本身的技术原理。"
        $risk = "稳定性、温度、功耗或实际效果出现意外变化"
    }

    return [pscustomobject]@{
        SafetyNotice = "参数仅供参考，请以安全为第一要务。"
        Action = "本轮只在对应 BIOS/UEFI、厂商工具或调校软件中修改「${Variable}」；其他设置保持不动。"
        Analogy = $analogy
        Consequence = "可能让「${Goal}」向预期方向改善，但会增加${risk}。若出现「${AbortSignals}」，立即停止并执行：${Rollback}"
    }
}

function Format-PlainLanguageExplanation {
    param(
        [Parameter(Mandatory = $true)][object]$Explanation,
        [Parameter(Mandatory = $true)][bool]$Detailed
    )

    if ($Detailed) {
        return @"
动作：$($Explanation.Action)

类比：$($Explanation.Analogy)

后果：$($Explanation.Consequence)
"@
    }

    return @"
简明说明：
- 修改内容：$($Explanation.Action)
- 取舍、停止与恢复：$($Explanation.Consequence)
"@
}

function New-ExperimentCard {
    param(
        [switch]$Deep,
        [Parameter(Mandatory = $true)]
        [object]$Gate
    )

    $mode = if ($Deep) { "深入模式" } else { "快速模式" }
    $expectation = Get-TuningExpectationDirection `
        -Gate $Gate `
        -HardwareContext $Gate.HardwareContext `
        -PreviousContext $Gate.PreviousContext
    Write-Host ""
    Write-Host "生成$mode实验卡。这不是硬件写入，只是本地 Markdown 记录。" -ForegroundColor Yellow
    Write-Host "路线、目标、通过/中止条件和恢复方式直接沿用已完成的入口检查。" -ForegroundColor DarkGray

    $route = $Gate.Route
    $goal = $Gate.Objective
    $baseline = "已确认当前配置可稳定使用"
    $isGpu = $null -ne $Gate.GpuBaseline
    $variablePrompt = if ($isGpu) {
        "本轮唯一主要变量（GPU 示例：核心偏移；曲线路线将在填写当前默认参数后选择）"
    }
    else {
        "本轮唯一主要变量（例如 GPU 核心曲线、一个 CPU 核心倍频或一个内存时序）"
    }
    while ($true) {
        $variable = Read-Host $variablePrompt
        if ($null -eq $variable) {
            throw "输入已取消。"
        }
        $variable = $variable.Trim()
        if (-not [string]::IsNullOrWhiteSpace($variable)) {
            break
        }
        Write-Host "唯一主要变量不能留空，这是单变量调校的安全条件。" -ForegroundColor Yellow
    }
    $beforePrompt = if ($isGpu) {
        "当前默认/已知稳定 GPU 参数（曲线截图、核心偏移、功耗墙等原值）"
    }
    else {
        "修改前的值"
    }
    $before = Read-CardValue $beforePrompt

    $gpuRouteSelection = $null
    $isGpuCurve = $false
    if ($isGpu) {
        $gpuRouteSelection = Select-GpuTuningRoute `
            -Baseline $Gate.GpuBaseline `
            -HardwareContext $Gate.HardwareContext
        if ($gpuRouteSelection -eq "__CANCEL__") {
            throw "输入已取消。"
        }
        $isGpuCurve = $gpuRouteSelection.Key -ne "Pure"
    }

    $candidatePrompt = if ($isGpu) {
        $gpuRouteSelection.CandidatePrompt
    }
    else {
        "准备手动尝试的候选值"
    }
    $candidate = Read-CardValue $candidatePrompt
    $externalReference = Read-CardValue "外部参考来源（URL、标题或日期；没有可留空）" -Default "未提供"
    $externalChange = if ($externalReference -eq "未提供") {
        "未采用外部参考"
    }
    else {
        Read-CardValue "该参考改变了哪些路线、警告、参数方向或验证步骤；没有改变就写“未改变”" -Default "未改变"
    }
    $expected = $expectation.Direction
    $pass = $Gate.PrimaryMetric
    $abort = $Gate.AbortSignals
    $rollback = $Gate.Recovery
    $plainLanguage = Get-PlainLanguageExplanation `
        -Variable $variable `
        -Goal $goal `
        -AbortSignals $abort `
        -Rollback $rollback
    $persistence = "仅当前会话"
    $sensorLimits = "未检查；快速模式不把未证实的传感器作为通过条件"

    $workload = $Gate.Workload
    $driver = "待填写"
    $currentProfile = "待填写"
    if ($Deep) {
        $persistence = Read-CardValue "要求的持久性（仅会话 / 重启已验证 / 日常已验证）"
        $sensorLimits = Read-CardValue "传感器限制或未知项"
        $driver = Read-CardValue "驱动和调校工具版本"
        $currentProfile = Read-CardValue "当前配置名称"
    }

    $requiresFullExplanation = $script:SessionState.ExplanationMode -eq "detailed" -or
        $variable -match "BIOS|UEFI|固件|持久|启动|电压|时序|功耗"
    $explanationSection = Format-PlainLanguageExplanation `
        -Explanation $plainLanguage `
        -Detailed $requiresFullExplanation
    $gpuVramNote = if ($null -ne $Gate.HardwareContext -and [bool]$Gate.HardwareContext.IsLaptop) {
        "笔记本不推荐大幅超频显存；先分别验证核心路线，显存只能在需要时做单独的小步测试。"
    }
    else {
        "显存必须另起一轮；请求频率更高不等于带宽或性能更高，出现错误、纠错开销或帧率下降时回退。"
    }
    $gpuBaselineSection = if ($null -eq $Gate.GpuBaseline) {
        "本次不是 GPU 曲线流程。"
    }
    else {
@"
路线：$($gpuRouteSelection.Route)
当前运行报告：$($Gate.GpuBaseline.Source)
性能结果：$($Gate.GpuBaseline.Performance)
显卡功耗：$($Gate.GpuBaseline.Power)
温度：$($Gate.GpuBaseline.Temperature)
主要限流原因：$($Gate.GpuBaseline.LimitReason)
供电路径：$($Gate.GpuBaseline.PowerPath)
代表性电压：$($Gate.GpuBaseline.Voltage)
对应核心/有效频率：$($Gate.GpuBaseline.CoreClock)
当前默认参数：$before
本轮方法：$($gpuRouteSelection.Method)
显存限制：$gpuVramNote
"@
    }
    $intelRiskSection = if ($null -eq $Gate.IntelRiskNotice) {
        "不适用"
    }
    else {
@"
CPU：$($Gate.IntelRiskNotice.Cpu)
平台形态：$($Gate.IntelRiskNotice.FormFactor)
来源与保修：$($Gate.IntelRiskNotice.Source)；$($Gate.IntelRiskNotice.Warranty)
处理原则：$($Gate.IntelRiskNotice.Guidance)
"@
    }
    $curveApplicationCheck = if ($isGpuCurve) {
        "Apply 后重新打开曲线编辑器，记录工具是否钳制、平滑或调整相邻点；不要只记录拖动目标值。"
    }
    else {
        "不适用"
    }

    $content = @"
# 硬件调校实验卡

日期：$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
状态：待测试
模式：$mode
路线：$route
目标：$goal

## 参数安全提示与解释

安全提示：$($plainLanguage.SafetyNotice)

$explanationSection

## 基于配置的预期方向

- 预期方向：$($expectation.Direction)
- 首先只验证：$($expectation.FirstVariable)
- 主要取舍：$($expectation.Tradeoff)
- 配置影响：$($expectation.PlatformNote)
- 上一轮参考：$($expectation.PriorNote)
- 后续跟进所需：$($expectation.FollowUp)

## GPU 当前参数基线

$gpuBaselineSection

曲线应用复核：$curveApplicationCheck

## Intel 13/14 代风险记录

$intelRiskSection

## 外部参考与变更披露

参考来源：$externalReference
改变了什么：$externalChange

若外部参考改变路线、参数方向、警告或验证步骤，必须明确说明变化、原因、未改变的部分和仍需本地验证的部分；外部数值仅供参考。

## 固定条件

驱动/工具：$driver
当前配置：$currentProfile
工作负载：$workload
散热依据：$(if ($null -ne $Gate.CoolingContext) { $Gate.CoolingContext.Summary } else { "未确认" })
功耗参考：$(if ($null -ne $Gate.CoolingContext) { $Gate.CoolingContext.PowerEnvelope } else { "未确认" })

## 本轮实验

稳定基线：$baseline
唯一主要变量：$variable
修改前：$before
候选值：$candidate
预期改善：$expected

## 学习提示（选填）

- 本轮唯一变量：$variable
- 原厂基线：$baseline
- 通过标准：$pass
- 中止信号：$abort
- 恢复方式：$rollback

> 测试后只需补充最有价值的证据和最终决定，不必写完整复盘作业。

## 判定

通过标准：$pass
中止信号：$abort
回滚方式：$rollback
要求的持久性：$persistence
传感器限制：$sensorLimits

## 验证层级

1. 合成测试或压力测试：只用于快速筛选。
2. 目标游戏或生产负载：判断是否值得保留。
3. 待机、轻载、重启、睡眠唤醒和驱动重载：判断能否作为日常配置。

任何跑分通过率只代表该测试窗口的一致性，不证明所有游戏或日常使用稳定。

## 恢复顺序

关闭调校工具 → 恢复原厂/已知稳定配置 → 禁用自动应用 → 重启并检查曲线、功耗墙和风扇模式 → 驱动异常时按官方流程重装或回滚 → 先观察稳定，再继续实验。

## 测试后填写

结果：通过 / 失败 / 无结论
决定：保留 / 继续 / 回退 / 停止
实际温度、功耗、频率和帧时间：
异常或伪影：
是否重启验证：

## 学习复盘（选填）

- 最有价值的证据：
- 最终决定和一小句理由：
- 下次想记住的一点：
- 仍希望获得帮助的地方：

> 本卡只用于记录和指导。所有 BIOS、XTU、Afterburner 或其他硬件设置必须由用户手动应用。
"@

    $outputPath = New-OutputPath -Prefix $(if ($Deep) { "experiment-deep" } else { "experiment-quick" }) -Category "调校实验卡"
    [IO.File]::WriteAllText($outputPath, $content, $utf8)
    Write-Host ""
    Write-Host "实验卡已生成：$outputPath" -ForegroundColor Green
    Write-Host "下一步：按卡片手动做一轮测试，记录结果和异常，再决定保留、继续、回退或停止。" -ForegroundColor Cyan
    $script:SessionState.ActiveExperimentPath = $outputPath
    Open-TextFile -Path $outputPath
}

function Invoke-ExperimentReview {
    $cardPath = [string]$script:SessionState.ActiveExperimentPath
    if ([string]::IsNullOrWhiteSpace($cardPath) -or -not (Test-Path -LiteralPath $cardPath -PathType Leaf)) {
        $latestCard = Get-LatestExperimentCard
        if ($null -ne $latestCard) {
            $cardPath = $latestCard.FullName
        }
    }
    if ([string]::IsNullOrWhiteSpace($cardPath) -or -not (Test-Path -LiteralPath $cardPath -PathType Leaf)) {
        Write-Host "没有找到调校实验卡。请先生成并完成一轮调校实验。" -ForegroundColor Yellow
        return
    }

    $context = Get-ExperimentCardContext -Path $cardPath
    Clear-Host
    Write-Host "复盘上一轮调校" -ForegroundColor Cyan
    Write-Host "实验卡：$cardPath"
    Write-Host "状态：$(if ($context.Status) { $context.Status } else { '未记录' })"
    Write-Host "路线：$(if ($context.Route) { $context.Route } else { '未记录' })"
    Write-Host "目标：$(if ($context.Objective) { $context.Objective } else { '未记录' })"
    Write-Host "唯一变量：$(if ($context.PrimaryVariable) { $context.PrimaryVariable } else { '未记录' })"
    Write-Host "固定负载：$(if ($context.Workload) { $context.Workload } else { '未记录' })"
    Write-Host ""
    Write-Host "  1. 分析本轮测试 CSV 后复盘"
    Write-Host "  2. 没有 CSV，手动填写复盘"
    Write-Host "  0. 返回主菜单"
    $choice = Read-Host "输入 1、2 或 0"
    if ($null -eq $choice) {
        return
    }

    $telemetryPath = $null
    switch ($choice.Trim()) {
        "1" {
            $telemetryPath = Invoke-TelemetryAnalysis -BeginnerFriendly -SkipRecordPrompt -ReturnPath
            if ([string]::IsNullOrWhiteSpace($telemetryPath)) {
                Write-Host "没有完成遥测分析，复盘已取消。" -ForegroundColor Yellow
                return
            }
        }
        "2" { }
        "0" {
            Write-Host "已取消复盘，没有修改实验卡。" -ForegroundColor Yellow
            return
        }
        default {
            Write-Host "请输入 1、2 或 0。" -ForegroundColor Red
            return
        }
    }

    Write-Host ""
    Write-Host "本轮结果：" -ForegroundColor Yellow
    Write-Host "  1. 通过：重复测试有改善，且没有稳定性异常"
    Write-Host "  2. 失败：出现崩溃、伪影、异常温度或其他问题"
    Write-Host "  3. 无结论：测量噪声或证据不足"
    $resultChoice = Read-Host "输入 1、2 或 3"
    if ($null -eq $resultChoice) {
        return
    }
    $result = switch ($resultChoice.Trim()) {
        "1" { "通过" }
        "2" { "失败" }
        "3" { "无结论" }
        default { $null }
    }
    if ($null -eq $result) {
        Write-Host "没有识别本轮结果，未修改实验卡。" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "下一步决定：" -ForegroundColor Yellow
    Write-Host "  1. 保留"
    Write-Host "  2. 继续下一小步"
    Write-Host "  3. 回退"
    Write-Host "  4. 停止调校"
    $decisionChoice = Read-Host "输入 1、2、3 或 4"
    if ($null -eq $decisionChoice) {
        return
    }
    $decision = switch ($decisionChoice.Trim()) {
        "1" { "保留" }
        "2" { "继续" }
        "3" { "回退" }
        "4" { "停止" }
        default { $null }
    }
    if ($null -eq $decision) {
        Write-Host "没有识别下一步决定，未修改实验卡。" -ForegroundColor Yellow
        return
    }

    $reason = Read-Host "用一句话记录判断理由（可直接回车跳过）"
    if ([string]::IsNullOrWhiteSpace($reason)) {
        $reason = "未填写"
    }
    $nextAction = switch ($decision) {
        "保留" { "保留本轮配置，继续正常使用并观察重启、睡眠唤醒和长时间稳定性。" }
        "继续" { "只设计下一项单变量实验，不叠加其他控制项。" }
        "回退" { "恢复原厂或上一轮稳定配置，并记录恢复后的状态。" }
        "停止" { "停止调校，转向硬件、散热、供电或故障排查。" }
    }
    $evidence = if (-not [string]::IsNullOrWhiteSpace($telemetryPath)) {
        "遥测分析：$telemetryPath"
    }
    else {
        "手动复盘，未提供 CSV"
    }

    $reviewText = @"

## 工具复盘记录

复盘时间：$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
状态：已复盘
结果：$result
决定：$decision
证据：$evidence
理由：$reason
下一步：$nextAction
"@
    [IO.File]::AppendAllText($cardPath, $reviewText, $utf8)
    $script:SessionState.ActiveExperimentPath = $cardPath
    Write-Host ""
    Write-Host "复盘已写入实验卡：$cardPath" -ForegroundColor Green
    Write-Host "下一步：$nextAction" -ForegroundColor Cyan
}

function Show-Usage {
    $usagePath = Join-Path $appRoot "使用说明.txt"
    if (Test-Path -LiteralPath $usagePath -PathType Leaf) {
        Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $usagePath) | Out-Null
    }
    else {
        Write-Host "未找到使用说明文件。" -ForegroundColor Red
    }
}

function Select-BeginnerCollection {
    Write-Host ""
    Write-Host "读取配置前只需要决定一件事：结果要给谁看？" -ForegroundColor Yellow
    Write-Host "  直接回车：只给自己或可信的技术人员看，保留完整型号。"
    Write-Host "  输入 y：要发给群里或陌生人，隐藏具体型号。"
    $share = Read-Host "这份配置结果要发给别人看吗"
    return Invoke-HardwareCollection -Redacted:($share -match "^(y|yes|是)$") -BeginnerFriendly -ReturnPath
}

function Offer-BeginnerCollection {
    param([string]$Reason)

    Write-Host ""
    Write-Host $Reason
    $answer = Read-Host "现在读取一份只读配置记录吗？输入 y 继续，直接回车跳过"
    if ($answer -match "^(y|yes|是)$") {
        return Select-BeginnerCollection
    }
    return $null
}

function Get-OrOfferBeginnerCollection {
    param([string]$Reason)

    $selectedReport = Select-HardwareReportForReuse
    if ($selectedReport -eq "__REFRESH__") {
        return Select-BeginnerCollection
    }
    if (-not [string]::IsNullOrWhiteSpace($selectedReport)) {
        return $selectedReport
    }

    return Offer-BeginnerCollection $Reason
}

function Show-BeginnerTroubleshooting {
    while ($true) {
    Clear-Host
    Write-Host "电脑故障 - 先不修改任何设置" -ForegroundColor Cyan
    Write-Host "先选最接近的情况：" -ForegroundColor Yellow
    Write-Host "  1. 完全不通电，按开机键没反应"
    Write-Host "  2. 机器亮灯或风扇转，但屏幕没有画面"
    Write-Host "  3. 能进 Windows，但会死机、重启、蓝屏或游戏闪退"
    Write-Host "  4. 很热、很吵，或者明显卡顿"
    Write-Host "  0. 返回新手入口"
    Write-Host ""

    $choice = Read-Host "输入序号"
    if ($null -eq $choice) {
        return
    }
    switch ($choice.Trim()) {
        "1" {
            Write-Host ""
            Write-Host "先检查墙插、电源开关、电源线和插排；台式机确认显示器接的是显卡。" -ForegroundColor Yellow
            Write-Host "如果有烧焦味、液体、打火、线材融化或可见损坏，请断电并停止反复开机。" -ForegroundColor Red
            Write-Host "没有这些危险现象，再尝试一次开机；仍无反应时，不建议连续反复按电源键。"
            Write-Host "下一步：按上面的顺序检查；若没有任何灯、风扇或提示，准备送修或找可信技术人员。" -ForegroundColor Cyan
        }
        "2" {
            Write-Host ""
            Write-Host "先检查显示器是否通电、输入源是否选对，并重新插紧显示线。笔记本可先看自带屏幕。"
            Write-Host "如果能看到 Windows 桌面，可以继续读取配置；如果完全无画面，不要盲目改 BIOS 或超频设置。"
            $visible = Read-Host "现在能通过自带屏幕、另一块屏幕或远程看到 Windows 吗？输入 y 表示能"
            if ($visible -match "^(y|yes|是)$") {
                $configPath = Get-OrOfferBeginnerCollection "配置记录可以帮助技术人员判断平台，但不会解释当前黑屏。"
                if (-not [string]::IsNullOrWhiteSpace($configPath)) {
                    Write-Host "下一步：记录黑屏出现时机、指示灯/风扇状态和错误提示，再与配置单一起交给技术人员。" -ForegroundColor Cyan
                }
            }
            else {
                Write-Host "下一步：尝试另一块屏幕或远程查看；如果完全无画面，不要盲改 BIOS，准备送修或找可信技术人员。" -ForegroundColor Yellow
            }
        }
        "3" {
            Write-Host ""
            Write-Host "记住三件事：发生时在做什么、屏幕上有没有错误提示、最近装过什么或改过什么。"
            Write-Host "先不要换驱动、改 BIOS、超频或降压。当前不稳定原因还没确认。"
            $configPath = Get-OrOfferBeginnerCollection "配置记录可以连同故障现象一起交给可信的技术人员。"
            if (-not [string]::IsNullOrWhiteSpace($configPath)) {
                Write-Host "下一步：把故障出现时间、当时负载、最近改动和配置单放在一起，再进行排障。" -ForegroundColor Cyan
            }
        }
        "4" {
            Write-Host ""
            Write-Host "先暂停大型游戏、渲染或压力测试。笔记本不要为了散热随意拆开。"
            Write-Host "如果温度异常高、塑料变味、风扇异响或电池鼓包，请停止使用并检修。"
            $configPath = Get-OrOfferBeginnerCollection "如果系统还能正常操作，可以先保存一份配置记录。"
            if (-not [string]::IsNullOrWhiteSpace($configPath)) {
                Write-Host "下一步：先停止高负载；若异常温度、异味、风扇异响或电池鼓包持续，停止使用并检修。" -ForegroundColor Cyan
            }
        }
        "0" {
            return
        }
        default {
            Write-Host "没有识别这个序号。" -ForegroundColor Red
        }
    }
    Pause-Menu
    }
}

function Show-BeginnerTuningGuidance {
    Clear-Host
    Write-Host "关于超频和降压" -ForegroundColor Cyan
    Write-Host "便携版不会替你修改 BIOS、频率、电压、功耗或风扇。"
    Write-Host ""
    if ($script:SessionState.ExplanationMode -eq "concise") {
        Write-Host "接下来检查：平台与控制项、稳定基线、目标、恢复方式、固定负载和停止条件。" -ForegroundColor Yellow
    }
    else {
        Write-Host "所有调校用户都必须先确认五件事：" -ForegroundColor Yellow
        Write-Host "  1. 具体平台、目标部件，以及 BIOS/工具是否真的提供该控制项；"
        Write-Host "  2. 现在没改本轮设置时能不能稳定使用；"
        Write-Host "  3. 本轮要改善什么；"
        Write-Host "  4. 改坏后怎样恢复原厂或已知稳定设置；"
        Write-Host "  5. 用哪个固定负载、看什么结果、什么异常必须停止。"
        Write-Host ""
    }
    Write-Host "任一项不清楚时，主菜单的快速/深入实验卡入口也会拒绝生成调校卡。" -ForegroundColor Red
    $configPath = Get-OrOfferBeginnerCollection "未找到现有配置单；读取配置后才能按正确平台准备调校。"
    Show-BeginnerTuningNextSteps -ConfigPath $configPath
}

function Select-ExperimentDepthAndCard {
    param([Parameter(Mandatory = $true)][object]$Gate)

    $expectation = Get-TuningExpectationDirection `
        -Gate $Gate `
        -HardwareContext $Gate.HardwareContext `
        -PreviousContext $Gate.PreviousContext
    Clear-Host
    Write-Host "基于当前配置的调校预期方向" -ForegroundColor Cyan
    Write-Host "  $($expectation.Direction)"
    Write-Host "  首先只验证：$($expectation.FirstVariable)"
    Write-Host "  取舍：$($expectation.Tradeoff)"
    Write-Host "  配置影响：$($expectation.PlatformNote)"
    if (-not [string]::IsNullOrWhiteSpace($expectation.PriorNote)) {
        Write-Host "  $($expectation.PriorNote)" -ForegroundColor DarkYellow
    }
    Write-Host "  后续跟进：$($expectation.FollowUp)"

    while ($true) {
        Write-Host ""
        Write-Host "选择调校实验卡深度：" -ForegroundColor Yellow
        Write-Host "  1. 快速：做一轮简单尝试，记录较少；安全要求不变。"
        Write-Host "  2. 深入：额外记录驱动、当前配置和固定工作负载，便于长期比较。"
        Write-Host "  0. 取消实验卡，返回上一步"
        $depth = Read-Host "输入 1、2 或 0"
        if ($null -eq $depth) {
            return "cancel"
        }
        switch ($depth.Trim()) {
            "1" {
                New-ExperimentCard -Gate $Gate
                return "quick"
            }
            "2" {
                New-ExperimentCard -Deep -Gate $Gate
                return "deep"
            }
            "0" {
                Write-Host "已取消实验卡；入口检查结果不再保留。" -ForegroundColor Yellow
                return "cancel"
            }
            default {
                Write-Host "请输入 1、2 或 0。" -ForegroundColor Red
            }
        }
    }
}

function Show-BeginnerTuningNextSteps {
    param([string]$ConfigPath)

    while ($true) {
        Clear-Host
        Write-Host "调校准备 - 下一步" -ForegroundColor Cyan
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
            Write-Host "配置单已保存：$ConfigPath" -ForegroundColor Green
            Write-Host "它只记录当前硬件，不能证明控制项、稳定基线或恢复方式。"
        }
        else {
            Write-Host "你跳过了配置单。只要自己已经知道具体平台和部件，仍可以继续。"
        }
        Write-Host ""
        Write-Host "继续调校前仍必须确认：稳定现状、控制项、目标、恢复方式、固定负载与中止条件。"
        Write-Host ""
        Write-Host "  1. 继续入口检查并准备实验卡"
        Write-Host "  2. 重新查看缺少条件时怎样补齐"
        Write-Host "  3. 重新生成/更新配置单"
        Write-Host "  0. 返回新手菜单"
        Write-Host ""

        $choice = Read-Host "输入序号"
        if ($null -eq $choice) {
            return
        }
        switch ($choice.Trim()) {
            "1" {
                $gate = Invoke-TuningEntryGate -ConfigPath $ConfigPath
                if ($null -eq $gate) {
                    Pause-Menu
                    break
                }

                $depthResult = Select-ExperimentDepthAndCard -Gate $gate
                if ($depthResult -ne "cancel") {
                    return
                }
            }
            "2" {
                Show-TuningGatePreparationHelp "继续准备调校条件"
                Pause-Menu
            }
            "3" {
                $newReport = Select-BeginnerCollection
                if (-not [string]::IsNullOrWhiteSpace($newReport)) {
                    $ConfigPath = $newReport
                    Write-Host "配置单已更新：$ConfigPath" -ForegroundColor Green
                }
                else {
                    Write-Host "没有生成新配置单，继续保留原来的状态。" -ForegroundColor Yellow
                }
                Pause-Menu
            }
            "0" {
                return
            }
            default {
                Write-Host "请输入 1、2、3 或 0。" -ForegroundColor Red
                Pause-Menu
            }
        }
    }
}

function Show-BeginnerUpgradeGuidance {
    while ($true) {
    Clear-Host
    Write-Host "升级判断前置整理" -ForegroundColor Cyan
    Write-Host "便携版不会直接推荐购买哪款硬件；先整理真实痛点和当前配置。"
    Write-Host "选择最接近的主要问题："
    Write-Host "  1. 游戏帧数不够或画面卡顿"
    Write-Host "  2. 显存或内存容量不够"
    Write-Host "  3. 渲染、剪辑或编译太慢"
    Write-Host "  4. 温度高、噪音大或便携性不足"
    Write-Host "  5. 还不确定具体瓶颈"
    Write-Host "  0. 返回新手菜单"
    Write-Host ""
    $choice = Read-Host "输入 1、2、3、4、5 或 0"
    if ($null -eq $choice) {
        return
    }
    $pain = switch ($choice.Trim()) {
        "1" { "游戏帧数或帧时间不足" }
        "2" { "显存或内存容量不足" }
        "3" { "渲染、剪辑或编译性能不足" }
        "4" { "温度、噪音或便携性不足" }
        "5" { "瓶颈尚未确认" }
        "0" { return }
        default { $null }
    }
    if ($null -eq $pain) {
        Write-Host "请输入 1、2、3、4、5 或 0。" -ForegroundColor Red
        Pause-Menu
        continue
    }
    $configPath = Get-OrOfferBeginnerCollection "先保存当前配置，再决定是否值得升级。"
    $task = Read-CardValue "最影响使用的软件或任务" -Default "待填写"
    $settings = Read-CardValue "当前分辨率、画质或运行设置" -Default "待填写"
    $observed = Read-CardValue "目前表现或可测量结果" -Default "待填写"
    $target = Read-CardValue "希望达到的结果" -Default "待填写"
    $budget = Read-CardValue "预算范围（选填）" -Default "未提供"
    $platform = [string]$script:SessionState.ActiveHardwareContext.Platform
    if ([string]::IsNullOrWhiteSpace($platform) -and -not [string]::IsNullOrWhiteSpace($configPath)) {
        $context = Get-HardwareReportContext -Path $configPath
        if ($null -ne $context) { $platform = $context.Platform }
    }
    if ([string]::IsNullOrWhiteSpace($platform)) { $platform = "未确认" }

    $reportPath = New-OutputPath -Prefix "upgrade-preparation" -Category "升级准备"
    $content = @"
# 升级判断准备

日期：$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
主要痛点：$pain
当前设备：$platform
配置报告：$(if ($configPath) { $configPath } else { "本次未保存" })

## 当前使用场景

主要任务：$task
当前设置：$settings
目前表现：$observed
希望达到：$target
预算范围：$budget

## 判断前仍需补齐

- 同一固定负载下的 CPU/GPU 使用率、显存/内存占用、帧时间或耗时；
- 温度、功耗、限流原因和稳定性异常；
- 调低画质、关闭特效、更新驱动等非购买方案的结果；
- 候选硬件的接口、尺寸、供电、散热和系统兼容性；
- 现行硬件的残值、维修成本和升级后的净支出。

> 本报告只整理升级判断证据，不直接推荐购买具体硬件。
"@
    [IO.File]::WriteAllText($reportPath, $content, $utf8)
    Write-Host ""
    Write-Host "当前升级准备摘要：" -ForegroundColor Green
    Write-Host "  主要痛点：$pain"
    if (-not [string]::IsNullOrWhiteSpace($configPath)) {
        Write-Host "  配置单：$configPath"
    }
    else {
        Write-Host "  配置单：本次未保存"
    }
    Write-Host "  升级准备报告：$reportPath" -ForegroundColor Green
    Write-Host "下一步：用同一固定负载补齐使用率、温度、功耗和帧时间证据，再判断是调设置、维修还是升级。" -ForegroundColor Cyan
    Write-Host "不要只凭电脑型号直接决定换硬件。" -ForegroundColor Yellow
    Open-TextFile -Path $reportPath
    Pause-Menu
    }
}

function Invoke-SafeBeginnerStart {
    Clear-Host
    Write-Host "你不知道也很好，先做最安全的一步：读取现状，不修改设置。" -ForegroundColor Cyan
    Write-Host ""
    $usable = Read-Host "现在能看到 Windows 桌面并正常点鼠标吗？输入 y 表示能，直接回车表示不能"
    if ($usable -match "^(y|yes|是)$") {
        Select-BeginnerCollection
        return
    }

    Write-Host ""
    Write-Host "先检查电源线、墙插和显示器输入。若有烧焦味、液体、打火或线材发热融化，请立即断电并停止开机。" -ForegroundColor Red
    Write-Host "不要反复改 BIOS、超频或拆机；能正常开机后再回来读取配置。"
}

function Show-BeginnerGuide {
    while ($true) {
        Write-Title
        Write-Host "新手模式：不需要懂术语，只回答你想做什么。" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  1. 我只想知道这台电脑是什么配置"
        Write-Host "  2. 电脑有故障，比如没画面、重启、卡顿或过热"
        Write-Host "  3. 我想查看温度、频率、功耗等数据，但还没有监控记录"
        Write-Host "  4. 我有一份监控软件导出的记录，想分析结果"
        Write-Host "  5. 我想超频或降压"
        Write-Host "  6. 我想准备判断该不该升级"
        Write-Host "  0. 我还是不知道，帮我选最安全的第一步"
        Write-Host "  B. 返回主菜单"
        Write-Host ""

        $choice = Read-Host "输入序号"
        if ($null -eq $choice) {
            return
        }
        try {
            switch ($choice.Trim().ToUpperInvariant()) {
                "1" { Select-BeginnerCollection; Pause-Menu }
                "2" { Show-BeginnerTroubleshooting }
                "3" { Show-BeginnerMonitoringGuidance; Pause-Menu }
                "4" { Invoke-MonitoringAnalysisEntry -BeginnerFriendly; Pause-Menu }
                "5" { Show-BeginnerTuningGuidance; Pause-Menu }
                "6" { Show-BeginnerUpgradeGuidance }
                "0" { Invoke-SafeBeginnerStart; Pause-Menu }
                "B" { return }
                default {
                    Write-Host "请输入 1–6、0 或 B。" -ForegroundColor Red
                    Pause-Menu
                }
            }
        }
        catch {
            Write-Host ""
            Write-Host ("操作失败：" + $_.Exception.Message) -ForegroundColor Red
            Pause-Menu
        }
    }
}

function Invoke-PortableCollectorSmokeTest {
    param([string]$PrivacyMode)

    $collectorPath = Join-Path $scriptsRoot "collect-windows.ps1"
    $smokeRoot = Join-Path ([IO.Path]::GetTempPath()) ("pc-hardware-portable-smoke-" + [guid]::NewGuid().ToString("N"))
    $allowedIdentityStatuses = @("readable", "suspicious", "partial", "unreadable", "unknown", "redacted")
    New-Item -ItemType Directory -Path $smokeRoot -Force | Out-Null
    try {
        $modes = switch ($PrivacyMode) {
            "Redacted" { @("Redacted") }
            "Standard" { @("Standard") }
            "Both" { @("Redacted", "Standard") }
        }
        foreach ($mode in $modes) {
            $jsonPath = Join-Path $smokeRoot ("hardware-{0}.json" -f $mode.ToLowerInvariant())
            $arguments = @{
                Format = "Json"
                OutputPath = $jsonPath
            }
            if ($mode -eq "Redacted") {
                $arguments.RedactIdentifiers = $true
            }
            & $collectorPath @arguments | Out-Null
            if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
                throw "实机采集没有生成 $mode 格式的 JSON。"
            }
            $snapshot = Get-Content -Raw -LiteralPath $jsonPath | ConvertFrom-Json
            if ($snapshot.SchemaVersion -lt 2 -or $snapshot.CollectorVersion -ne "1.0.1-r10") {
                throw "$mode 实机采集返回了不兼容的版本。"
            }
            if ($mode -eq "Redacted") {
                if ($snapshot.PrivacyMode -ne "Redacted identifiers" -or
                    $snapshot.IdentityQuality.Status -ne "redacted" -or
                    $snapshot.Computer.Manufacturer -ne "[redacted]" -or
                    $snapshot.Computer.Model -ne "[redacted]") {
                    throw "隐私脱敏实机采集没有正确隐藏设备身份。"
                }
            }
            elseif ($snapshot.PrivacyMode -ne "Standard") {
                throw "标准实机采集没有返回 Standard 隐私模式。"
            }

            $markdownPath = Join-Path $smokeRoot ("hardware-{0}.md" -f $mode.ToLowerInvariant())
            $markdownArguments = @{
                Format = "Markdown"
                OutputPath = $markdownPath
            }
            if ($mode -eq "Redacted") {
                $markdownArguments.RedactIdentifiers = $true
            }
            & $collectorPath @markdownArguments | Out-Null
            $reportContext = Get-HardwareReportContext -Path $markdownPath
            if ($null -eq $reportContext) {
                throw "$mode 实机采集没有生成可解析的 Markdown 报告。"
            }
            if ($reportContext.Platform -match '`') {
                throw "$mode Markdown 身份围栏没有正确移除。"
            }
            if ($mode -eq "Redacted") {
                if ($reportContext.IdentityQuality -ne "redacted" -or $reportContext.Platform -notmatch "隐私脱敏") {
                    throw "隐私脱敏 Markdown 报告没有保持身份隐藏状态。"
                }
            }
            elseif ([string]::IsNullOrWhiteSpace($reportContext.IdentityQuality) -or
                $reportContext.IdentityQuality -notin @($allowedIdentityStatuses)) {
                throw "标准 Markdown 报告没有返回有效的设备身份质量。"
            }
        }
    }
    finally {
        try {
            if (Test-Path -LiteralPath $smokeRoot) {
                Remove-Item -LiteralPath $smokeRoot -Recurse -Force -ErrorAction Stop
            }
        }
        catch {
            Write-Host "实机自检临时目录未自动清理：$smokeRoot" -ForegroundColor Yellow
        }
    }
}

function Test-PortableKit {
    $required = @(
        (Join-Path $scriptsRoot "collect-windows.ps1"),
        (Join-Path $scriptsRoot "device-identity.ps1"),
        (Join-Path $scriptsRoot "local-path-safety.ps1"),
        (Join-Path $scriptsRoot "system-native.cs"),
        (Join-Path $scriptsRoot "storage-native.cs"),
        (Join-Path $scriptsRoot "display-native.cs"),
        (Join-Path $scriptsRoot "analyze-telemetry.ps1")
    )

    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) })
    if ($missing.Count -gt 0) {
        throw ("缺少文件：`r`n" + ($missing -join "`r`n"))
    }

    if ($null -eq (Get-Command Invoke-TuningEntryGate -ErrorAction SilentlyContinue)) {
        throw "缺少统一调校入口检查函数。"
    }
    if ($null -eq (Get-Command Get-PlainLanguageExplanation -ErrorAction SilentlyContinue)) {
        throw "缺少参数修改的大白话解释生成逻辑。"
    }
    $testExplanation = Get-PlainLanguageExplanation `
        -Variable "BIOS/UEFI 内存配置" `
        -Goal "验证稳定性" `
        -AbortSignals "启动失败" `
        -Rollback "恢复默认设置"
    if ($testExplanation.SafetyNotice -ne "参数仅供参考，请以安全为第一要务。" -or
        $testExplanation.Action -notmatch "BIOS/UEFI") {
        throw "参数安全提示或 BIOS/UEFI 解释范围缺失。"
    }
    $fullExplanation = Format-PlainLanguageExplanation -Explanation $testExplanation -Detailed $true
    $compactExplanation = Format-PlainLanguageExplanation -Explanation $testExplanation -Detailed $false
    if ($fullExplanation -notmatch "动作：" -or
        $fullExplanation -notmatch "类比：" -or
        $fullExplanation -notmatch "后果：") {
        throw "详细参数解释没有包含动作、类比和后果。"
    }
    if ($compactExplanation -notmatch "修改内容" -or
        $compactExplanation -notmatch "取舍、停止与恢复" -or
        $compactExplanation -match "类比：") {
        throw "简明参数解释没有按低风险场景压缩。"
    }
    if ($null -eq (Get-Command Test-TuningSafetyPreflight -ErrorAction SilentlyContinue)) {
        throw "缺少物理安全预检。"
    }
    if ($null -eq (Get-Command Get-CoolingContext -ErrorAction SilentlyContinue)) {
        throw "缺少采集后的散热条件分流。"
    }
    if ($null -eq (Get-Command Read-GpuBaselineReport -ErrorAction SilentlyContinue)) {
        throw "缺少 GPU 曲线前的当前运行基线检查。"
    }
    if ($null -eq (Get-Command Select-GpuTuningRoute -ErrorAction SilentlyContinue)) {
        throw "缺少 GPU 纯超频/降压超频路线选择。"
    }
    if ($null -eq (Get-Command Get-AvailableGpuRouteKeys -ErrorAction SilentlyContinue)) {
        throw "缺少按设备形态筛选 GPU 路线。"
    }
    if ($null -eq (Get-Command Get-GpuRouteDefinition -ErrorAction SilentlyContinue)) {
        throw "缺少 GPU 路线定义。"
    }
    if ($null -eq (Get-Command Get-Intel13Or14CpuRisk -ErrorAction SilentlyContinue)) {
        throw "缺少 Intel 13/14 代 CPU 风险识别。"
    }
    if ($null -eq (Get-Command Read-Intel13Or14CpuRiskNotice -ErrorAction SilentlyContinue)) {
        throw "缺少 Intel 13/14 代保修与稳定性检查。"
    }
    $affectedIntel = [pscustomobject]@{ CPU = "Intel(R) Core(TM) i7-14700K"; IsLaptop = $false }
    $unaffectedCpu = [pscustomobject]@{ CPU = "AMD Ryzen 7 7800X3D"; IsLaptop = $false }
    if ($null -eq (Get-Intel13Or14CpuRisk -HardwareContext $affectedIntel) -or
        $null -ne (Get-Intel13Or14CpuRisk -HardwareContext $unaffectedCpu)) {
        throw "Intel 13/14 代 CPU 检测错误。"
    }
    $desktop5090 = [pscustomobject]@{ IsLaptop = $false; GPUs = @("NVIDIA GeForce RTX 5090") }
    $desktop4090 = [pscustomobject]@{ IsLaptop = $false; GPUs = @("NVIDIA GeForce RTX 4090") }
    $desktopOther = [pscustomobject]@{ IsLaptop = $false; GPUs = @("NVIDIA GeForce RTX 4080") }
    $laptopGpu = [pscustomobject]@{ IsLaptop = $true; GPUs = @("NVIDIA GeForce RTX 5090 Laptop GPU") }
    $desktop5090Keys = @(Get-AvailableGpuRouteKeys -HardwareContext $desktop5090)
    $desktop4090Keys = @(Get-AvailableGpuRouteKeys -HardwareContext $desktop4090)
    $desktopOtherKeys = @(Get-AvailableGpuRouteKeys -HardwareContext $desktopOther)
    $laptopKeys = @(Get-AvailableGpuRouteKeys -HardwareContext $laptopGpu)
    if ($desktop5090Keys -notcontains "RTX5090PowerCurve" -or
        $desktop5090Keys -notcontains "DesktopSegment" -or
        $desktop5090Keys -contains "DesktopPowerCeiling") {
        throw "桌面 RTX 5090 没有获得专属或分段路线。"
    }
    if ($desktop4090Keys -contains "DesktopPowerCeiling" -or $desktop4090Keys -contains "RTX5090PowerCurve") {
        throw "RTX 4090 错误获得了普通功耗墙上限路线。"
    }
    if ($desktopOtherKeys -contains "RTX5090PowerCurve" -or
        $desktopOtherKeys -notcontains "DesktopSegment" -or
        $desktopOtherKeys -notcontains "DesktopPowerCeiling") {
        throw "非 5090 桌面 GPU 的路线筛选错误。"
    }
    if ($laptopKeys -contains "DesktopSegment" -or
        $laptopKeys -contains "DesktopPowerCeiling" -or
        $laptopKeys -contains "RTX5090PowerCurve") {
        throw "笔记本错误获得了桌面专属路线。"
    }
    $segmentDefinition = Get-GpuRouteDefinition -RouteKey "DesktopSegment"
    $ceilingDefinition = Get-GpuRouteDefinition -RouteKey "DesktopPowerCeiling"
    $powerCurveDefinition = Get-GpuRouteDefinition -RouteKey "RTX5090PowerCurve"
    if ($segmentDefinition.Method -notmatch "1\.025V" -or
        $segmentDefinition.Method -notmatch "0\.8V" -or
        $segmentDefinition.Method -notmatch "\+150") {
        throw "桌面分段路线缺少 5090 参考边界。"
    }
    if ($powerCurveDefinition.Method -notmatch "93%" -or
        $powerCurveDefinition.Method -notmatch "\+150") {
        throw "桌面 RTX 5090 功耗墙路线缺少参考步骤。"
    }
    if ($ceilingDefinition.Method -notmatch "PSU" -or
        $ceilingDefinition.Method -notmatch "111%" -or
        $ceilingDefinition.Method -notmatch "不是固定安全目标") {
        throw "桌面普通功耗墙上限路线缺少电源或参考值边界。"
    }
    if ($null -eq (Get-Command Show-TuningGatePreparationHelp -ErrorAction SilentlyContinue)) {
        throw "缺少调校条件教学方法。"
    }
    if ($null -eq (Get-Command Show-HwinfoDownloadGuidance -ErrorAction SilentlyContinue)) {
        throw "缺少 HWiNFO 下载说明。"
    }
    if ($null -eq (Get-Command Show-BeginnerTuningNextSteps -ErrorAction SilentlyContinue)) {
        throw "缺少调校准备后续流程。"
    }
    if ($null -eq (Get-Command Read-RequiredTuningValue -ErrorAction SilentlyContinue)) {
        throw "缺少调校必填项重试逻辑。"
    }
    if ($null -eq (Get-Command Get-LatestHardwareReport -ErrorAction SilentlyContinue)) {
        throw "缺少配置报告自动检索。"
    }
    if ($null -eq (Get-Command Get-HardwareReportContext -ErrorAction SilentlyContinue)) {
        throw "缺少配置报告摘要解析。"
    }
    if ($null -eq (Get-Command Get-HardwareReportContextFromLines -ErrorAction SilentlyContinue)) {
        throw "缺少可测试的配置报告上下文解析。"
    }
    if ($null -eq (Get-Command ConvertFrom-MarkdownIdentityValue -ErrorAction SilentlyContinue)) {
        throw "缺少 Markdown 设备身份清理。"
    }
    if ($null -eq (Get-Command ConvertTo-SessionIdentityStatus -ErrorAction SilentlyContinue)) {
        throw "缺少采集身份质量映射。"
    }
    if ($null -eq (Get-Command Select-HardwareReportForReuse -ErrorAction SilentlyContinue)) {
        throw "缺少多配置报告选择。"
    }
    if ($null -eq (Get-Command Confirm-HardwareReportReuse -ErrorAction SilentlyContinue)) {
        throw "缺少配置报告时效提醒。"
    }
    if ($null -eq (Get-Command Get-ExperimentCardContext -ErrorAction SilentlyContinue)) {
        throw "缺少上一轮实验条件解析。"
    }
    if ($null -eq (Get-Command Get-TuningExpectationDirection -ErrorAction SilentlyContinue)) {
        throw "缺少基于配置的调校预期方向。"
    }
    if ($null -eq (Get-Command Invoke-ExperimentReview -ErrorAction SilentlyContinue)) {
        throw "缺少调校实验复盘流程。"
    }
    if ($null -eq (Get-Command Select-ExperimentDepthAndCard -ErrorAction SilentlyContinue)) {
        throw "缺少快速/深入实验卡选择。"
    }
    if ($null -eq (Get-Command Select-HardwareCollectionModeAndRun -ErrorAction SilentlyContinue)) {
        throw "缺少配置报告模式选择。"
    }
    if ($null -eq (Get-Command Invoke-MonitoringAnalysisEntry -ErrorAction SilentlyContinue)) {
        throw "缺少监控记录分析前检查。"
    }
    $gateParameter = (Get-Command New-ExperimentCard -ErrorAction SilentlyContinue).Parameters["Gate"]
    $gateIsMandatory = $false
    if ($null -ne $gateParameter) {
        $gateIsMandatory = @(
            $gateParameter.Attributes |
                Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }
        ).Count -gt 0
    }
    if (-not $gateIsMandatory) {
        throw "调校实验卡没有强制绑定入口检查结果。"
    }

    $selfText = Get-Content -Raw -LiteralPath $PSCommandPath -Encoding UTF8
    $beforePosition = $selfText.IndexOf('$before = Read-CardValue $beforePrompt')
    $routePosition = $selfText.IndexOf('$gpuRouteSelection = Select-GpuTuningRoute')
    $candidatePosition = $selfText.IndexOf('$candidate = Read-CardValue $candidatePrompt')
    if ($beforePosition -lt 0 -or $routePosition -lt 0 -or $candidatePosition -lt 0 -or
        -not ($beforePosition -lt $routePosition -and $routePosition -lt $candidatePosition)) {
        throw "GPU 实验卡顺序必须是：当前默认参数 → 路线选择 → 候选值。"
    }
    foreach ($requiredGpuText in @("PerfCap", "曲线应用复核", "验证层级", "恢复顺序", "显存必须另起一轮", "不要用第三方工具解锁隐藏功耗墙", "DesktopPowerCeiling", "Intel 13/14 代风险记录", "外部参考与变更披露")) {
        if (-not $selfText.Contains($requiredGpuText)) {
            throw "GPU 通用验证字段缺失：$requiredGpuText"
        }
    }

    $collectorText = Get-Content -Raw -LiteralPath (Join-Path $scriptsRoot "collect-windows.ps1")
    if ($collectorText -notmatch 'CollectorVersion\s*=\s*"1\.0\.1-r[0-9]+"') {
        throw "采集器缺少有效版本标识。"
    }
    if ($collectorText -notmatch 'IdentityQuality\s*=\s*\$identityAssessment') {
        throw "采集器没有输出 IdentityQuality。"
    }
    if ($collectorText -notmatch 'ConvertTo-DeviceIdentityMarkdown') {
        throw "采集器没有使用安全 Markdown 身份格式。"
    }
    $analyzerText = Get-Content -Raw -LiteralPath (Join-Path $scriptsRoot "analyze-telemetry.ps1")
    if ($analyzerText -notmatch 'AnalyzerVersion\s*=\s*"[0-9]+\.[0-9]+\.[0-9]+"') {
        throw "遥测分析器缺少有效版本标识。"
    }

    $skillScriptsRoot = Join-Path (Split-Path -Parent $appRoot) "skill\pc-hardware-workbench\scripts"
    if (Test-Path -LiteralPath $skillScriptsRoot -PathType Container) {
        $portableScripts = @(
            Get-ChildItem -LiteralPath $scriptsRoot -File |
                Where-Object { $_.Extension -in @(".ps1", ".cs") }
        )
        $skillScripts = @(
            Get-ChildItem -LiteralPath $skillScriptsRoot -File |
                Where-Object { $_.Extension -in @(".ps1", ".cs") }
        )
        $allSharedScriptNames = @(
            @($portableScripts | ForEach-Object Name) +
            @($skillScripts | ForEach-Object Name) |
                Sort-Object -Unique
        )
        foreach ($sharedScript in $allSharedScriptNames) {
            $portablePath = Join-Path $scriptsRoot $sharedScript
            $skillPath = Join-Path $skillScriptsRoot $sharedScript
            if (-not (Test-Path -LiteralPath $skillPath -PathType Leaf)) {
                throw "便携目录存在仅有的脚本：$sharedScript"
            }
            if (-not (Test-Path -LiteralPath $portablePath -PathType Leaf)) {
                throw "便携工具缺少 Skill 共享脚本：$sharedScript"
            }
            if ((Get-FileHash -Algorithm SHA256 -LiteralPath $portablePath).Hash -ne
                (Get-FileHash -Algorithm SHA256 -LiteralPath $skillPath).Hash) {
                throw "便携工具的共享脚本与 Skill 不一致：$sharedScript"
            }
        }
    }

    $syntheticReadable = Get-HardwareReportContextFromLines -Lines @(
        "# Hardware snapshot",
        "## System",
        "- Identity quality: readable",
        '- Manufacturer: ` Example Corp `',
        '- Model: ` ExampleBook 16X `',
        "## CPU",
        "- Example CPU, 8 cores, 16 threads",
        "## GPU",
        "- Example GPU"
    )
    if ($syntheticReadable.IdentityQuality -ne "readable" -or $syntheticReadable.IdentityStatus -ne "confirmed") {
        throw "可读身份没有映射为 confirmed。"
    }
    if ($syntheticReadable.Platform -match '`' -or $syntheticReadable.Platform -notmatch 'ExampleBook 16X') {
        throw "安全 Markdown 身份没有正确还原为平台文本。"
    }

    $syntheticRedacted = Get-HardwareReportContextFromLines -Lines @(
        "## System",
        "- Identity quality: redacted",
        '- Manufacturer: ` [redacted] `',
        '- Model: ` [redacted] `'
    )
    if ($syntheticRedacted.IdentityQuality -ne "redacted" -or $syntheticRedacted.Platform -notmatch '隐私脱敏') {
        throw "隐私脱敏身份没有保持明确状态。"
    }

    $syntheticUnreadable = Get-HardwareReportContextFromLines -Lines @(
        "## System",
        "- Identity quality: unreadable",
        '- Model: ` [unreadable] `',
        "  - Identity warning: Model: replacement characters"
    )
    if ($syntheticUnreadable.IdentityStatus -ne "unreadable" -or
        $syntheticUnreadable.Platform -notmatch '不可可靠读取' -or
        $syntheticUnreadable.IdentityWarnings.Count -ne 1) {
        throw "不可读身份没有阻止型号级确认或丢失警告。"
    }

    $syntheticSuspicious = Get-HardwareReportContextFromLines -Lines @(
        "## System",
        "- Identity quality: suspicious",
        '- Model: ` ExampleBook 16X `',
        "## CPU",
        "- Example CPU"
    )
    if ($syntheticSuspicious.IdentityStatus -ne "unreadable" -or
        $syntheticSuspicious.Platform -match 'ExampleBook 16X' -or
        $syntheticSuspicious.Platform -notmatch '文本可疑') {
        throw "可疑身份被错误用于平台文本。"
    }

    foreach ($scriptPath in @(
        (Join-Path $appRoot "start.ps1"),
        (Join-Path $scriptsRoot "collect-windows.ps1"),
        (Join-Path $scriptsRoot "device-identity.ps1"),
        (Join-Path $scriptsRoot "analyze-telemetry.ps1")
    )) {
        $tokens = $null
        $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            $scriptPath,
            [ref]$tokens,
            [ref]$parseErrors
        ) | Out-Null
        if ($parseErrors.Count -gt 0) {
            throw ("PowerShell 语法错误：{0}`r`n{1}" -f $scriptPath, ($parseErrors -join "; "))
        }
    }

    Ensure-OutputDirectory
    foreach ($directory in @($configOutputRoot, $telemetryOutputRoot, $experimentOutputRoot, $upgradeOutputRoot)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "输出分类目录缺失：$directory"
        }
    }
    Write-Host "便携工具非实机自检通过。" -ForegroundColor Green
    if ($AllowLiveCollector) {
        Write-Host "正在执行实机采集自检（$CollectorPrivacyMode）……" -ForegroundColor Cyan
        Invoke-PortableCollectorSmokeTest -PrivacyMode $CollectorPrivacyMode
        Write-Host "实机采集自检通过（$CollectorPrivacyMode）。" -ForegroundColor Green
    }
    else {
        Write-Host "实机采集自检：SKIP（使用 -AllowLiveCollector 并选择 -CollectorPrivacyMode Redacted|Standard|Both）" -ForegroundColor Yellow
    }
}

if ($SelfTest) {
    Test-PortableKit
    exit 0
}

Ensure-OutputDirectory

while ($true) {
    Write-Title
    Write-Host "请选择操作：" -ForegroundColor Yellow
    Write-Host "  0. 我不知道选什么，带我一步步来" -ForegroundColor Cyan
    Write-Host "  1. 读取电脑配置（进入后选择标准或隐私脱敏）"
    Write-Host "  2. 分析已有的监控记录（通常是 .csv 文件）"
    Write-Host "  3. 超频/降压调校（先检查，再选择快速或深入）"
    Write-Host "  4. 复盘上一轮调校"
    Write-Host "  5. 打开使用说明"
    Write-Host "  6. 查看 HWiNFO 下载说明（监测软件）"
    Write-Host "  M. 切换详细/简洁说明"
    Write-Host "  Q. 退出"
    Write-Host ""

    $choice = Read-Host "输入序号；不会选就输 0"
    if ($null -eq $choice) {
        return
    }
    try {
        switch ($choice.Trim().ToUpperInvariant()) {
            "0" { Show-BeginnerGuide }
            "1" { Select-HardwareCollectionModeAndRun; Pause-Menu }
            "2" { Invoke-MonitoringAnalysisEntry; Pause-Menu }
            "3" {
                $selectedReport = Select-HardwareReportForReuse
                if ($selectedReport -eq "__REFRESH__") {
                    $selectedReport = Select-BeginnerCollection
                }
                $gate = Invoke-TuningEntryGate -ConfigPath $selectedReport
                if ($null -ne $gate) {
                    Select-ExperimentDepthAndCard -Gate $gate | Out-Null
                }
                Pause-Menu
            }
            "4" { Invoke-ExperimentReview; Pause-Menu }
            "5" { Show-Usage; Pause-Menu }
            "6" { Show-HwinfoDownloadGuidance; Pause-Menu }
            "M" { Toggle-ExplanationMode; Pause-Menu }
            "Q" { return }
            default {
                Write-Host "请输入 0–6、M 或 Q。" -ForegroundColor Red
                Pause-Menu
            }
        }
    }
    catch {
        Write-Host ""
        Write-Host ("操作失败：" + $_.Exception.Message) -ForegroundColor Red
        Pause-Menu
    }
}
