# 清理远端陈旧的单会话引导树（破坏性：会 taskkill 远端进程，故默认只清点）
#
# 为什么需要它：本地看门狗 taskkill 杀的是**本地** ssh.exe，Windows 不向远端传播信号，
# 于是远端那个引导 powershell 会卡在读 stdin 里成为孤儿。孤儿堆积 → sshd 会话饱和 →
# 新连接首字节延迟被拖过看门狗 → 再杀再留孤儿 → 死亡螺旋（2026-10-23 上科大B服务器实测：8 个卡死引导 + 52 条 sshd 会话）。
# 引导侧已改成有界读取（等不到 EOF 自行退出）杜绝新增孤儿；本工具负责收拾**历史上**留下的。
#
# 判据（二者取其一，也可叠加）：
#   -连接起点 "<yyyy-MM-dd HH:mm:ss>"：只杀**启动时刻早于它**的。注意这是本地生成的时间戳，却拿去与远端进程启动时刻比，
#     实测本地与远端时钟可差约 4 分钟（远端慢）——偏得够多时会把正在用的会话当成陈旧。拿不准就用下面那个。
#   -龄下限秒 N：只杀龄 ≥ N 秒的。**龄由远端自己的时钟算**（远端 now 减 CreationDate），不受两边时钟偏差影响，更安全。
# 目标集合还额外限定为“带生产固定引导码特征的引导进程”与“它起的 Start-Job 工作进程”；
# 其它 EncodedCommand（探针/别人的自动化）只报告不动手。
#
# 用法：
#   只看不动（默认）：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\remote-stale-tree-clean.ps1 -主机 <ssh别名> -龄下限秒 300
#   按时钟分界　　：… -连接起点 "2026-10-23 12:40:00"
#   确认后再清理：同上并加 -清理

param(
	[string]$主机 = '上科大A服务器_张天夫',
	[string]$提交号 = '58173d0ebc1838579e3c331e0a47e365904a6456',
	[string]$连接起点 = '',
	[int]$龄下限秒 = 0,
	[switch]$清理
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')

if ($连接起点 -eq '' -and $龄下限秒 -le 0) {
	throw '至少要给一个判据：-龄下限秒 <秒>（推荐，用远端时钟算龄、不受时钟偏差影响）或 -连接起点 "<yyyy-MM-dd HH:mm:ss>"。没判据就全杀，风险太大。'
}

# 破坏性动作要显式开启：清点的输出会先给你看清杀谁，确认了再跑一次带 -清理
if ($清理) { Write-Host ('⚠ 清理模式：会 taskkill /T /F 掉满足判据' + $(if ($连接起点 -ne '') { '（早于 ' + $连接起点 + '）' } else { '' }) + $(if ($龄下限秒 -gt 0) { '（龄 ≥ ' + $龄下限秒 + 's）' } else { '' }) + ' 且带生产固定引导码特征的引导进程与其 Start-Job 工作进程；其它 EncodedCommand 只报告不动手。') }
else { Write-Host '清点模式（默认不动手）：确认清单无误后加 -清理 再跑一次。' }

$远端 = @'
function T([string]$s){ Write-Output ('__T__' + $s) }
$界 = if ('__连接起点__' -ne '') { Get-Date '__连接起点__' } else { $null }
$龄下限 = __龄下限__
$引导特征 = '__引导特征__'
T ('远端时刻=' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  判据=' + $(if ($null -ne $界) { '启动早于 ' + $界.ToString('yyyy-MM-dd HH:mm:ss') + $(if ($龄下限 -gt 0) { ' 且 ' } else { '' }) } else { '' }) + $(if ($龄下限 -gt 0) { '龄≥' + $龄下限 + 's' } else { '龄不限' }) + $(if ($引导特征 -eq '') { '；无引导码特征（无法区分生产引导与别的 EncodedCommand）' } else { '；只认带生产固定引导码特征者' }))
$杀 = New-Object System.Collections.Generic.List[int]
$不动 = 0
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
	$cl = [string]$p.CommandLine
	$is引导 = (($引导特征 -ne '') -and $cl.Contains($引导特征))
	$is作业 = ($cl -match '-s -NoLogo')
	$is其它编码 = ($cl -match 'EncodedCommand')
	if (-not ($is引导 -or $is作业 -or $is其它编码)) { continue }
	$始 = $p.CreationDate
	$龄 = 0
	$cpu = -1
	$u = $p.UserModeTime
	$kc = $p.KernelModeTime
	if (($null -ne $u) -and ($null -ne $kc)) { $cpu = [Math]::Round(([uint64]$u + [uint64]$kc) / 10000000, 1) }
	if ($null -ne $始) { $龄 = [int]((Get-Date) - $始).TotalSeconds }
	$够龄 = ($龄 -ge $龄下限)
	$早于界 = $(if ($null -ne $界) { ($null -ne $始 -and $始 -lt $界) } else { $true })
	$陈旧 = ($够龄 -and $早于界)
	# 只杀两类：带生产固定引导码的引导进程，与它起的 Start-Job 工作进程。
	# 其它 EncodedCommand 只报告不动手：那可能是别人的自动化/探针，与死亡螺旋无关，误杀代价大。
	$可杀 = ($is引导 -or $is作业)
	$类别 = if ($is引导) { '生产引导' } elseif ($is作业) { 'Start-Job工作进程' } else { '其它EncodedCommand(不动)' }
	T ('  ' + $类别 + ' PID=' + $p.ProcessId + ' PPID=' + $p.ParentProcessId + ' 起=' + $(if($始){$始.ToString('MM-dd HH:mm:ss')}else{'?'}) + ' 龄=' + $龄 + 's CPU=' + $cpu + 's 陈旧=' + $陈旧 + ' 可杀=' + $可杀 + ' 命令长=' + $cl.Length)
	if ($陈旧 -and $可杀) { $杀.Add([int]$p.ProcessId) } elseif (-not $可杀) { $不动++ }
}
T ('拟清根进程数=' + $杀.Count + ' 另有不动手的其它编码进程=' + $不动)
__清理段__
Start-Sleep -Milliseconds 500
$剩 = 0
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)) {
	$cl = [string]$p.CommandLine
	$可杀 = ((($引导特征 -ne '') -and $cl.Contains($引导特征)) -or ($cl -match '-s -NoLogo'))
	if ($可杀) {
		$剩++
		T ('  仍在 PID=' + $p.ProcessId + ' 起=' + $(if($p.CreationDate){$p.CreationDate.ToString('MM-dd HH:mm:ss')}else{'?'}) + ' 命令长=' + $cl.Length)
	}
}
T ('清理后仍有引导特征进程数=' + $剩)
T ('sshd会话数=' + @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue).Count)
$d = Join-Path $env:USERPROFILE ('.vscode-server-insiders\race-__提交号__')
if (Test-Path $d) {
	foreach ($f in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
		T ('竞速文件 ' + $f.Name + ' ' + $f.Length + ' 字节 ' + $f.LastWriteTime.ToString('MM-dd HH:mm:ss'))
	}
} else { T '竞速目录不存在' }
$sv = Join-Path $env:USERPROFILE ('.vscode-server-insiders\cli\servers\Insiders-__提交号__\server')
T ('服务端已装=' + (Test-Path $sv))
T 'END'
'@

$清理段 = if ($清理) {
	@'
T ('拟清 PID: ' + ($杀 -join ','))
foreach ($r in $杀) {
	$out = taskkill /PID $r /T /F 2>&1
	$out | ForEach-Object { T ('  KILL ' + $r + ': ' + $_) }
}
'@
} else {
	"T '（清点模式：未执行任何 taskkill）'"
}
$引导码特征 = 取-引导码特征
$远端 = $远端.Replace('__清理段__', $清理段).Replace('__连接起点__', $连接起点).Replace('__龄下限__', [string]$龄下限秒).Replace('__提交号__', $提交号).Replace('__引导特征__', $引导码特征)

$r = 送-远端脚本 -主机 $主机 -脚本文本 $远端 -连接超时秒 15
Write-Host ('  ssh 退出码=' + $r.退出码 + '  耗时=' + $r.耗时秒 + 's  argv ' + $r.编码长度 + ' 字符')
if ($r.行.Count -eq 0) {
	Write-Host '  取不到远端结论行，原始输出：'
	$r.全部行 | Select-Object -First 10 | ForEach-Object { Write-Host ('    ' + $_) }
	exit 1
}
$r.行 | ForEach-Object { Write-Host ('  ' + $_) }
Write-Host ''
$文本 = ($r.行 -join ' ')
if ($文本 -match '拟清根进程数=(\d+)') {
	$n = [int]$Matches[1]
	if ($清理) { Write-Host ('已清理 ' + $n + ' 棵陈旧引导树。') }
	elseif ($n -gt 0) { Write-Host ('发现 ' + $n + ' 棵陈旧引导树待清；确认上面清单都属于已死会话后，加 -清理 重跑。') }
	else { Write-Host '没有陈旧引导树：远端侧干净。' }
}
if (-not ($文本 -match 'END')) { Write-Host '⚠ 远端脚本未跑到收尾（可能被截断），结论仅供参考。' }
