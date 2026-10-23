# Windows 侧下载器行为自检：实跑仓库里那份 通过HTTP断点续传下载（按 AST 取函数体，不是副本），对着必连不上的地址制造
# 「等间隔失败风暴」约 60 秒，核对四条性质：
#   ① 下载链接只在首次起始行公布一次；
#   ② 无按轮回显的「（第 N 次尝试）」起始行——那正是一次中断产出两条消息的多余汇报点；
#   ③ 一次中断恒为一条消息，且每条都带端标注（[远程自下载-产物名] 或 [本地供给-产物名]）、续传点与「下个汇报周期（N 秒后）重试」；
#   ④ 重试真的对齐汇报周期：相邻两条中断行的实测间隔 == 上一条声明的等待秒数（容差 0.6~2.5 秒），
#      且声明的等待随轮次递增（不是写死的固定值，也没有 30 秒封顶）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\download-log-selftest.ps1
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$源文件 = Join-Path $repo 'module\private\remote-install-common.ps1'
$本地供给文件 = Join-Path $repo 'module\private\local-supply.ps1'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库（此前每个自检各拄一份计数与打印，同一条纪律改一次要改九处）；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

foreach ($f in @($源文件, $本地供给文件)) {
	$tokens = $null; $errors = $null
	[void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors)
	$name = Split-Path -Leaf $f
	断言 ($errors.Count -eq 0) ("语法解析: $name" + $(if ($errors.Count) { ' -> ' + (($errors | ForEach-Object { $_.Message }) -join '; ') } else { '' }))
}

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($源文件, [ref]$tokens, [ref]$errors)
$func = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like '*HTTP*' }, $true) | Select-Object -First 1
if (-not $func) { Write-Output 'FAIL: 找不到断点续传下载函数'; exit 1 }
Write-Output ("被测函数: " + $func.Name + "（" + $func.Extent.Text.Length + " 字，取自仓库文件本身）")

$url = 'https://127.0.0.1:9/nope.zip'
$target = Join-Path $env:TEMP 'dl-log-selftest.zip'
Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
# 预置半成品：首轮就走断点续传分支（与真实截断风暴现场一致，也是最容易冒出回显行的分支）
Set-Content -LiteralPath $target -Value 'partial' -Encoding Ascii

$runner = $func.Extent.Text + "`n" + '&' + ' ' + $func.Name + ' ' + "'$url' '$target'"
$runnerPath = Join-Path $env:TEMP 'dl-log-selftest-runner.ps1'
# UTF-8 BOM 是硬要求：PS 5.1 读无 BOM 的 .ps1 按 ANSI 解，中文标识符会被读坏
Set-Content -LiteralPath $runnerPath -Value $runner -Encoding UTF8
$outPath = Join-Path $env:TEMP 'dl-log-selftest-out.txt'
Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue
# 子进程 stderr 也必须落盘：catch 里抛出的异常会走到 stderr，不捕获就看不到（实测 MinValue 溢出缺陷当初就是这样漏网的）
$errPath = Join-Path $env:TEMP 'dl-log-selftest-err.txt'
Remove-Item -LiteralPath $errPath -Force -ErrorAction SilentlyContinue

$观测秒数 = 60
Write-Output ''
Write-Output "===== 实跑下载器约 $观测秒数 秒（对着 $url 反复失败重试） ====="
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath) -RedirectStandardOutput $outPath -RedirectStandardError $errPath -NoNewWindow -PassThru
Start-Sleep -Seconds $观测秒数
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 700

$lines = @(Get-Content -LiteralPath $outPath)
$错误文本 = if (Test-Path -LiteralPath $errPath) { (Get-Content -LiteralPath $errPath -Raw) } else { '' }
Write-Output '----- 捕获到的完整输出 -----'
$lines | ForEach-Object { Write-Output $_ }
Write-Output '----- 断言 -----'

# ① 不得有异常从 catch 逸出（逸出即穿透重试循环，整条下载当场中止）
$异常特征 = @('RuntimeException', 'CategoryInfo', 'InvalidCastIConvertible', 'Cannot convert value', 'FullyQualifiedErrorId', '异常终止')
$逸出 = @($异常特征 | Where-Object { $错误文本 -like "*$_*" -or (($lines -join "`n") -like "*$_*") })
断言 ($逸出.Count -eq 0) ("catch 里无异常逸出（命中特征 " + $逸出.Count + ' 个' + $(if ($逸出.Count) { '：' + ($逸出 -join ',') } else { '' }) + '）')
if ($逸出.Count -gt 0 -and $错误文本) { Write-Output ('    stderr 前 600 字: ' + $错误文本.Substring(0, [Math]::Min(600, $错误文本.Length))) }

# ② 下载链接只公布一次
$urlLines = @($lines | Where-Object { $_ -like "*$url*" })
断言 ($urlLines.Count -eq 1) ("下载链接只公布一次（实测 " + $urlLines.Count + ' 行含 URL，期望 1）')
if ($urlLines.Count -ge 1) { Write-Output ('    起始行: ' + $urlLines[0]) }

# ② 无按轮回显的起始行
$旧回显 = @($lines | Where-Object { $_ -match '断点续传（第|开始下载（第' })
断言 ($旧回显.Count -eq 0) ("按轮回显起始行已消失（实测 " + $旧回显.Count + ' 行，期望 0）')

# ③ 一次中断一条消息 + 信息不缩水 + 逐条带端标注
# 端标注是必需项（缺陷E）：两端的下载行交织在同一份 preconnect 日志里，不带标注就只能靠续传点字节数猜是哪一端。
# 正则兼容「有/无端标注」两种形态，再由下面的专项断言卡「必须有」（否则改回去也能蒙混过关）
$中断行 = @($lines | Where-Object { $_ -like '*下载中断*' })
$解析 = @()
foreach ($l in $中断行) {
	$m = [regex]::Match($l, '^(?<标签>\[[^\]]+\] )?\[(?<t>[\d\-: ]+)\] 第 (?<n>\d+) 次下载中断（续传点 (?<b>\d+) 字节）: (?<r>.*?)，下个汇报周期（(?<w>\d+) 秒后）重试$')
	if ($m.Success) {
		$解析 += [pscustomobject]@{
			时刻   = [datetime]::ParseExact($m.Groups['t'].Value, 'yyyy-MM-dd HH:mm:ss', $null)
			轮次   = [int]$m.Groups['n'].Value
			续传点  = [int]$m.Groups['b'].Value
			原因   = $m.Groups['r'].Value
			等待秒数 = [int]$m.Groups['w'].Value
			端标注  = $m.Groups['标签'].Value.Trim()
		}
	}
}
断言 ($中断行.Count -ge 8) ("中断行条数足够做时序核对（实测 " + $中断行.Count + '）')
断言 ($解析.Count -eq $中断行.Count) ("每条中断行都带续传点与「下个汇报周期（N 秒后）重试」（不合规 " + ($中断行.Count - $解析.Count) + ' 条）')
$缺标注行 = @($解析 | Where-Object { $_.端标注 -notmatch '^\[(远程自下载|本地供给)-' })
断言 ($解析.Count -gt 0 -and $缺标注行.Count -eq 0) ("每条中断行都带端标注（缺标注 " + $缺标注行.Count + ' 条' + $(if ($缺标注行.Count) { '：' + (($缺标注行 | ForEach-Object { $_.端标注 }) -join ',') } elseif ($解析.Count) { '；实测前缀 ' + $解析[0].端标注 } else { '' }) + '）')
$max轮 = if ($解析.Count) { ($解析 | Measure-Object -Property 轮次 -Maximum).Maximum } else { 0 }
断言 ($中断行.Count -eq $max轮) ("一次中断一条消息：中断行 " + $中断行.Count + " == 已推进轮数 $max轮")

# ④ 重试对齐汇报周期：实测间隔 = 声明等待 + 本轮连接尝试耗时（后者约 2~3 秒，是真实网络开销不是额外退避）。
# 故真正要卡的两件事：①绝不得早于声明的周期重试；②「间隔 − 声明」必须集中在一个常数附近（那就是连接耗时），
# 若它随轮次越来越大，就说明在周期之上又叠了别的退避。
$尝试耗时 = @()
$提前重试 = @()
for ($i = 1; $i -lt $解析.Count; $i++) {
	$间隔 = ($解析[$i].时刻 - $解析[$i - 1].时刻).TotalSeconds
	$声明 = $解析[$i - 1].等待秒数
	if ($间隔 -lt ($声明 - 0.6)) { $提前重试 += ('第' + $解析[$i - 1].轮次 + '轮声明 ' + $声明 + 's 但实测只隔 ' + [Math]::Round($间隔, 1) + 's') }
	$尝试耗时 += [Math]::Round($间隔 - $声明, 1)
}
断言 ($提前重试.Count -eq 0) ("重试绝不早于声明的汇报周期（提前 " + $提前重试.Count + ' 条' + $(if ($提前重试.Count) { '：' + ($提前重试 -join '；') } else { '' }) + '）')
if ($尝试耗时.Count -ge 3) {
	$排序 = $尝试耗时 | Sort-Object
	$中位数 = $排序[[int][Math]::Floor($排序.Count / 2)]
	$波动 = @($尝试耗时 | Where-Object { [Math]::Abs($_ - $中位数) -gt 3 }).Count
	Write-Output ('    间隔−声明（= 本轮连接耗时）序列: ' + ($尝试耗时 -join ', ') + "s，中位数 $中位数 s")
	断言 ($波动 -le 1) ("额外耗时集中在连接尝试本身（中位数 $中位数 s，偏离超 3s 的条数 $波动），周期之上没再叠退避")
	断言 ($尝试耗时[-1] -lt ($尝试耗时[0] + 8)) ("额外耗时不随轮次增长（首轮 " + $尝试耗时[0] + 's → 末轮 ' + $尝试耗时[-1] + 's）')
}
$等待序列 = ($解析 | ForEach-Object { $_.等待秒数 }) -join ' → '
if ($解析.Count -ge 2) {
	断言 ((($解析 | Select-Object -Last 1).等待秒数) -ge (($解析 | Select-Object -First 1).等待秒数 + 3)) ("等待秒数随轮次递增而非固定值（序列: $等待序列）")
	# 计时抖动（GetResponse 失败耗时亚秒级）可能让单步回落 1 秒，故只卡「回落超过 1 秒」：真回到固定值会连续大面积回落
	$回落 = 0
	for ($i = 1; $i -lt $解析.Count; $i++) { if ($解析[$i].等待秒数 -lt ($解析[$i - 1].等待秒数 - 1)) { $回落++ } }
	断言 ($回落 -eq 0) ("等待秒数无大幅回落（回落超过 1 秒的处数 $回落）= 周期只放宽不重置")
	断言 (@($解析 | Where-Object { $_.等待秒数 -eq 30 }).Count -lt $解析.Count) ("没有「每轮都写死 30 秒」的形态（实测 30s 条数 " + (@($解析 | Where-Object { $_.等待秒数 -eq 30 }).Count) + ' / ' + $解析.Count + '）')
	Write-Output ('    等待序列: ' + $等待序列)
	Write-Output ('    续传点全程: ' + (($解析 | ForEach-Object { $_.续传点 } | Select-Object -Unique) -join ',') + ' 字节（预置的半成品未被误改写）')
	Write-Output ('    首条中断原因: ' + $解析[0].原因)
} else {
	断言 $false '中断行不足 2 条，无法做时序核对'
}

Remove-Item -LiteralPath $target, $runnerPath -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output ("断言失败数: " + (取-断言计数).失败)
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
