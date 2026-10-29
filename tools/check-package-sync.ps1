<#
.SYNOPSIS
    比较两棵 skill 树（例如仓库工作树 vs 交付包解包目录），区分“真内容差异”与“仅换行符/BOM 差异”。

.DESCRIPTION
    逐文件读取，按以下顺序判定：
      1) 原始字节完全一致          -> SAME
      2) 去掉 BOM、CRLF 归一化后一致 -> EOL-ONLY（不影响运行，可忽略）
      3) 其余                      -> CONTENT（需要人工处理；默认导致 exit 1）

    PowerShell 5.1 友好：不使用任何 7+ 语法。

.PARAMETER LeftRoot
    左侧根目录（通常为仓库里的 skill 目录）。

.PARAMETER RightRoot
    右侧根目录（通常为交付包里展开的 skill 目录）。

.PARAMETER IgnoreEolOnly
    只报告 CONTENT 差异，EOL-ONLY 视为通过（默认关闭，便于看到全貌）。

.PARAMETER IgnoreTrailingWhitespace
    比较前去掉每行行尾空白（用于“只差行尾空格”的场景）。

.EXAMPLE
    .\check-package-sync.ps1 -LeftRoot .\skill\pc-hardware-workbench -RightRoot ..\pkg\skill\pc-hardware-workbench

.NOTES
    退出码：0 = 无 CONTENT 差异；1 = 存在 CONTENT 差异；2 = 参数或路径错误。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LeftRoot,
    [Parameter(Mandatory = $true)][string]$RightRoot,
    [switch]$IgnoreEolOnly,
    [switch]$IgnoreTrailingWhitespace
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Resolve-Root([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Write-Host ("[{0}] 目录不存在: {1}" -f $Name, $Path) -ForegroundColor Red
        exit 2
    }
    return (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
}

function Read-NormalizedText([string]$FullPath) {
    $bytes = [System.IO.File]::ReadAllBytes($FullPath)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $text = $text -replace "`r`n", "`n"
    $text = $text -replace "`r", "`n"
    if ($script:IgnoreTrailingWhitespace) {
        $text = ($text -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n"
    }
    return $text.TrimEnd("`n")
}

function Get-RelativeFiles([string]$Root) {
    $map = @{}
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\')
        $map[$rel] = $_.FullName
    }
    return $map
}

$left  = Resolve-Root $LeftRoot  'left'
$right = Resolve-Root $RightRoot 'right'

$leftFiles  = Get-RelativeFiles $left
$rightFiles = Get-RelativeFiles $right

$onlyLeft  = @($leftFiles.Keys  | Where-Object { -not $rightFiles.ContainsKey($_) } | Sort-Object)
$onlyRight = @($rightFiles.Keys | Where-Object { -not $leftFiles.ContainsKey($_) } | Sort-Object)

$eolOnly = New-Object System.Collections.ArrayList
$content = New-Object System.Collections.ArrayList
$same = 0

foreach ($rel in ($leftFiles.Keys | Sort-Object)) {
    if (-not $rightFiles.ContainsKey($rel)) { continue }
    $lf = $leftFiles[$rel]
    $rf = $rightFiles[$rel]

    $lb = [System.IO.File]::ReadAllBytes($lf)
    $rb = [System.IO.File]::ReadAllBytes($rf)
    $rawSame = ($lb.Length -eq $rb.Length)
    if ($rawSame) {
        for ($i = 0; $i -lt $lb.Length; $i++) { if ($lb[$i] -ne $rb[$i]) { $rawSame = $false; break } }
    }
    if ($rawSame) { $same++; continue }

    $lt = Read-NormalizedText $lf
    $rt = Read-NormalizedText $rf
    if ($lt -ceq $rt) { [void]$eolOnly.Add($rel); continue }

    $ll = $lt -split "`n"
    $rl = $rt -split "`n"
    $first = 0
    $min = [Math]::Min($ll.Count, $rl.Count)
    while ($first -lt $min -and $ll[$first] -ceq $rl[$first]) { $first++ }
    [void]$content.Add([pscustomobject]@{
        Path     = $rel
        Line     = $first + 1
        LeftLen  = $ll.Count
        RightLen = $rl.Count
        LeftText = if ($first -lt $ll.Count) { $ll[$first] } else { '<EOF>' }
        RightText= if ($first -lt $rl.Count) { $rl[$first] } else { '<EOF>' }
    })
}

Write-Host ''
Write-Host ('left : ' + $left)
Write-Host ('right: ' + $right)
Write-Host ('files: left={0} right={1} same={2} eol-only={3} content={4} only-left={5} only-right={6}' -f `
    $leftFiles.Count, $rightFiles.Count, $same, $eolOnly.Count, $content.Count, $onlyLeft.Count, $onlyRight.Count)
Write-Host ''

if ($onlyLeft.Count -gt 0) {
    Write-Host '[ONLY-LEFT]' -ForegroundColor Yellow
    $onlyLeft | ForEach-Object { Write-Host ('  - ' + $_) }
}
if ($onlyRight.Count -gt 0) {
    Write-Host '[ONLY-RIGHT]' -ForegroundColor Yellow
    $onlyRight | ForEach-Object { Write-Host ('  + ' + $_) }
}
if ($eolOnly.Count -gt 0) {
    Write-Host '[EOL-ONLY] 仅换行符/BOM 不同，运行时等价' -ForegroundColor DarkGray
    $eolOnly | ForEach-Object { Write-Host ('  ~ ' + $_) -ForegroundColor DarkGray }
}
if ($content.Count -gt 0) {
    Write-Host '[CONTENT] 真实内容差异' -ForegroundColor Red
    foreach ($d in $content) {
        Write-Host ('  ! {0} (line {1}, left={2} lines, right={3} lines)' -f $d.Path, $d.Line, $d.LeftLen, $d.RightLen) -ForegroundColor Red
        Write-Host ('      left : ' + $d.LeftText)
        Write-Host ('      right: ' + $d.RightText)
    }
}

$failing = ($content.Count -gt 0) -or ($onlyLeft.Count -gt 0) -or ($onlyRight.Count -gt 0) -or ((-not $IgnoreEolOnly) -and ($eolOnly.Count -gt 0))
if ($failing) {
    Write-Host ''
    Write-Host 'RESULT: FAIL' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'RESULT: PASS' -ForegroundColor Green
exit 0
