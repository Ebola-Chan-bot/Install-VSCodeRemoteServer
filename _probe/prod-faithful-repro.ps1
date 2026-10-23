# 单会话 stdin 通道复现（生产同款：真 bootstrap + 真引导模板 + 真分块，安装脚本换成打标记）
#
# 用途：当线上表现为「preconnect 停在 [单会话] 引导码 … 之后再无一行」时，先用它把**通道**与**安装逻辑**分开定罪。
# 为什么必须"生产同款"而不是自己搭一个：2026-10-23 查 B 服务器卡死时，我自搭的三个复现台（argv 引号拼错、
# 用了 OpenStandardInput 而生产用 Console.In、只发单块载荷）分别得出过互相矛盾的结论，其中两个还"看起来通过了"。
# 只有把生产那四步（去注释去空行 → gzip → base64 → 塞模板 → UTF-16 再 base64 → 分块）与那套 ProcessStartInfo
# 序列原样复用，结论才可信。这两份逻辑现在固定在 lib\探针公共库.ps1，由 lib-selftest.ps1 的漂移守卫盯着。
#
# 场景开关：
#   默认        安装脚本只打 START/MID/END 三标记，秒退 → 测通道本身
#   -慢安装      标记之间睡 30s / 5s → 测「长活远端进程的输出是否被缓冲到退出才 flush」
#   -大载荷      塞高熵填充把引导码顶到生产量级（几十 KB、几十块）→ 测多块大载荷投递
#   -冷启动计时   在**进程内**测首个 CimInstance / NetTCPConnection / WMI 耗时 → 测首行输出之前的开销
#
# 判读：标记按远端声明时刻递增到达 = 无缓冲、通道健康；挤在最后一刻一起到 = 输出被憋住；
#       一行不到 = 载荷没到远端或远端引导没跑起来（先用 远端体检.ps1 看是否孤儿堆积/会话饱和）。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\prod-faithful-repro.ps1 -主机 上科大A服务器_张天夫 [-慢安装|-大载荷|-冷启动计时]

param(
	[string]$主机 = '上科大A服务器_张天夫',
	[int]$端口 = 22,
	[int]$超时秒 = 60,
	[switch]$慢安装,
	[switch]$大载荷,
	[switch]$冷启动计时
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')

# 安装脚本正文（会被库按生产算法 gzip+base64 后塞进真引导模板）
if ($大载荷) {
	# 高熵填充：GUID 串 gzip 压不小，用来把引导码顶到生产量级（几十块）。只打标记、不真装机。
	$堆 = -join ((1..2300) | ForEach-Object { [Guid]::NewGuid().ToString('N') })
	$安装正文 = (@'
Write-Host 'VSI_BIG_START'
$填充 = '__PAD__'
Write-Host ('VSI_BIG_PADLEN=' + $填充.Length)
Start-Sleep -Seconds 3
Write-Host 'VSI_BIG_MID'
Start-Sleep -Seconds 3
Write-Host 'VSI_BIG_END'
'@).Replace('__PAD__', $堆)
} elseif ($冷启动计时) {
	# 必须在**进程内**测：套 Start-Job 会在作业进程里跑，模块已被预热，测出来的冷启动耗时是假的
	#（本轮就在这上面误判过一次——作业里 1.8s，进程内也 1.2s，两处都测才敢下"冷启动无罪"的结论）
	$安装正文 = @'
$g = [System.Diagnostics.Stopwatch]::StartNew()
Write-Host ('VSI_COLD t0=' + [Math]::Round($g.Elapsed.TotalSeconds, 2))
$null = @(Get-CimInstance Win32_Process)
Write-Host ('VSI_COLD 首个CimInstance完成 t=' + [Math]::Round($g.Elapsed.TotalSeconds, 2))
try { $null = @(Get-NetTCPConnection -State Established -ErrorAction Stop); Write-Host ('VSI_COLD 首个NetTCP完成 t=' + [Math]::Round($g.Elapsed.TotalSeconds, 2)) } catch { Write-Host ('VSI_COLD NetTCP异常 t=' + [Math]::Round($g.Elapsed.TotalSeconds, 2) + ' ' + $_.Exception.Message) }
$null = @(Get-CimInstance Win32_OperatingSystem)
Write-Host ('VSI_COLD 首个WMI完成 t=' + [Math]::Round($g.Elapsed.TotalSeconds, 2))
Write-Host 'VSI_COLD_DONE'
'@
} elseif ($慢安装) {
	$安装正文 = @'
Write-Host 'VSI_INSTALL_START'
Start-Sleep -Seconds 30
Write-Host 'VSI_INSTALL_MID'
Start-Sleep -Seconds 5
Write-Host 'VSI_INSTALL_END'
'@
} else {
	$安装正文 = @'
Write-Host 'VSI_INSTALL_START'
Write-Host 'VSI_INSTALL_MID'
Write-Host 'VSI_INSTALL_END'
'@
}

$构 = 构造-单会话载荷 -安装脚本文本 $安装正文
$固定引导码 = 构造-固定引导码
$命令行 = 'powershell -NoProfile -EncodedCommand ' + $固定引导码
$场景 = $(if ($大载荷) { '大载荷' } elseif ($冷启动计时) { '冷启动计时' } elseif ($慢安装) { '慢安装' } else { '快安装' })

Write-Host ('===== 单会话通道复现 [' + $场景 + '] → ' + $主机 + ' =====')
Write-Host ('  精简正文 ' + $构.精简正文字符 + ' 字符 → gzip ' + $构.gzip字节 + ' 字节 → 载荷 ' + $构.载荷.Length + ' → 引导码 ' + $构.引导码.Length + ' 字符 → 分 ' + $构.块列表.Count + ' 块（每块最长 ' + $构.每块字符 + '）')
Write-Host ('  拼接不变式（行数×行长 == 引导码总长）= ' + $构.拼接不变式通过 + '；argv 只装固定引导 ' + $固定引导码.Length + ' 字符')
if (-not $构.拼接不变式通过) { throw '拼接不变式不成立：分块逻辑坏了，后面的结论无意义' }

$超时 = if ($慢安装) { [Math]::Max($超时秒, 50) } elseif ($大载荷 -or $冷启动计时) { [Math]::Max($超时秒, 90) } else { $超时秒 }
$r = 送-载荷经stdin -主机 $主机 -命令文本 $命令行 -标准输入文本 $构.载荷标准输入 -端口 $端口 -超时秒 $超时

Write-Host ('  本地写出 stdin ' + $r.载荷字节 + ' 字节并 Close；退出码=' + $r.退出码 + '  耗时=' + $r.耗时秒 + 's  看门狗超时=' + $r.超时)
Write-Host '  --- 逐行到达时刻（探针视角） ---'
if ($r.到达记录.Count -eq 0) {
	Write-Host '    （一行都没到）'
} else {
	foreach ($到 in $r.到达记录) {
		$t = [string]$到.行
		if ($t.Length -gt 170) { $t = $t.Substring(0, 170) + '…' }
		Write-Host ('    @' + ([string]$到.秒).PadLeft(6) + 's  ' + $t)
	}
}
if ($r.stderr.Trim()) { Write-Host ('  stderr: ' + $r.stderr.Substring(0, [Math]::Min(200, $r.stderr.Length))) }

Write-Host ''
Write-Host '===== 判读 ====='
$有效行 = @($r.行 | Where-Object { $_ -match 'VSI_|stdin引导' })
if ($有效行.Count -eq 0) {
	Write-Host '  ✗ 一行有效输出都没到。先跑 远端体检.ps1：'
	Write-Host '    · 卡死引导孤儿数 > 0 或 sshd 会话数拥挤 → 会话饱和拖慢首字节，通道无罪，先清孤儿'
	Write-Host '    · 孤儿为 0 仍无输出 → 载荷没到远端（查本地写出）或远端引导崩了（查上面 stderr）'
} else {
	$首行秒 = [double]($r.到达记录 | Select-Object -First 1).秒
	$末行秒 = [double]($r.到达记录 | Select-Object -Last 1).秒
	Write-Host ('  有效输出 ' + $有效行.Count + ' 行；首行 @' + $首行秒 + 's、末行 @' + $末行秒 + 's，跨度 ' + [Math]::Round($末行秒 - $首行秒, 1) + 's')
	if ($慢安装) {
		if (($末行秒 - $首行秒) -ge 25) { Write-Host '  ✓ 标记按远端睡眠节奏递增到达 → 长活进程输出**不**被缓冲（看门狗「有输出就顺延」的策略成立）。' }
		else { Write-Host '  ✗ 跨度远小于脚本内睡眠总时长 → 输出被憋到退出才 flush（缓冲假设成立，得换传输方式）。' }
	} elseif ($冷启动计时) {
		Write-Host '  看 VSI_COLD 各行的 t= 秒数：若首个 CimInstance/NetTCP 就要几十秒，说明安装脚本首行输出之前的冷启动足以触发 240s 看门狗。'
	} else {
		Write-Host '  ✓ 通道通：载荷经真 bootstrap 送达并执行、[stdin引导] 到达回执与标记按时回传。'
	}
}
if ($r.超时) { Write-Host ('  ⚠ 本地看门狗 ' + $超时 + 's到点已杀 ssh 树（探针自身绝不留孤儿）。') }
