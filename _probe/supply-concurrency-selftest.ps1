# 本地供给并发自检（真跑子进程）：覆盖本次线上事故的四类并发情形
#   S1 父进程死亡 → 子进程自行终止（不再有孤儿供给进程长期占着缓存与带宽）
#   S2 认领无人持有的遗留半成品（上一轮被 taskkill 留下的 .downloading-*）并续传
#   S3 他方进程持锁写同一产物 → 等待/接管，全程不得再出现 "being used by another process" 刷屏
#   S4 完整下载走通「私有在途名 → 发布稳定成品名 → Linux .job 交接」，不留私有文件残渣
# 依据：Windows 端实测 OpenSSH sshd 把非零退出码压平成 1；PS 5.1 传含双引号的命令行会被剥引号 → 子进程参数一律 Clixml 落盘
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$供给脚本 = (Resolve-Path (Join-Path $repo 'scripts\private\local-supply.ps1')).Path
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }
# 32 字节、以 gzip 魔数开头：满足 测试-本地包完整 对 .tar.gz 的最小校验（≥22 字节 + 1F 8B）
$合法包字节 = [byte[]](0x1F, 0x8B) + (New-Object byte[] 30)

# 端口探测：找一个未被占用的回环端口（HttpListener 需要 URL 保留，故用裸 TcpListener 自己发 HTTP 头）
function 取-空闲端口 {
	$侦 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
	$侦.Start(); $端 = ([System.Net.IPEndPoint]$侦.LocalEndpoint).Port; $侦.Stop(); return $端
}
# 进程存活一律独立查询：Start-Process -PassThru（带重定向）返回的对象的 HasExited 可能永远为 false，S1 就因此误判
function 测-进程仍在([int]$进程ID) { return ($null -ne (Get-Process -Id $进程ID -ErrorAction SilentlyContinue)) }

function 新建-参数文件([string]$本地文件名, [string[]]$地址列表, [int]$父进程ID) {
	$临时 = Join-Path $env:TEMP ('vsi-con-' + [Guid]::NewGuid().ToString('N'))
	$参数文件 = $临时 + '.clixml'
	# 键名必须与生产读取的完全一致（$参数.下载地址 / $参数.下载地址列表）：
	# 初版写成 下载地址组 → 子进程读到 $null → @($null) 退化为一个空 URI，四个场景全部拿不到真实下载行为
	@{
		提交号        = 'cc19dad217286193196903349966d7baf9d0111b'
		远程包名      = 'LOCAL.tar.gz'
		暂存目录      = '/remote/stage'
		完成标记名    = 'LOCAL_DONE.selftest'
		取消标记名    = 'LOCAL_CANCEL.selftest'
		本地文件名    = $本地文件名
		下载地址      = $地址列表[0]
		下载地址列表  = $地址列表
		系统类型      = 'Linux'
		父进程ID      = $父进程ID
	} | Export-Clixml -LiteralPath $参数文件 -Encoding UTF8
	return @{ 临时 = $临时; 参数文件 = $参数文件; 输出文件 = ($临时 + '.out.txt'); 作业文件 = (Join-Path $env:TEMP 'race-supply-cc19dad217286193196903349966d7baf9d0111b-LOCAL.tar.gz.job') }
}
function 跑-子进程([hashtable]$组, [int]$秒, [switch]$等待退出, [string]$工作文件) {
	$参 = '-NoProfile -ExecutionPolicy Bypass -File "' + $供给脚本 + '" -参数文件 "' + $组.参数文件 + '"'
	$p = Start-Process powershell -ArgumentList $参 -NoNewWindow -PassThru -RedirectStandardOutput $组.输出文件 -RedirectStandardError ($组.输出文件 + 'e')
	$止 = [DateTime]::Now.AddSeconds($秒)
	if ($等待退出) {
		while ((测-进程仍在 $p.Id) -and [DateTime]::Now -lt $止) { Start-Sleep -Milliseconds 200 }
	} else {
		Start-Sleep -Seconds $秒
	}
	return $p
}
function 停-子进程($p) { if ($p -and (测-进程仍在 $p.Id)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 400 } }
function 收-输出([hashtable]$组) { (Get-Content -LiteralPath $组.输出文件 -Raw -ErrorAction SilentlyContinue) }

# ---------- S1 父死自终止 ----------
try {
Write-Output '===== S1. 父进程死亡 → 本地供给自行终止 ====='
$假父 = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 300' -NoNewWindow -PassThru
$组1 = 新建-参数文件 'CONC-S1-LOCAL.tar.gz' @('http://127.0.0.1:59999/a.tar.gz', 'http://127.0.0.1:59998/b.tar.gz') $假父.Id
$p1 = 跑-子进程 $组1 3
断言 (测-进程仍在 $p1.Id) '子供给进程已在跑（父进程存活期间不会自杀）'
Stop-Process -Id $假父.Id -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
断言 (-not (测-进程仍在 $假父.Id)) '模拟的模块父进程确实已被杀（否则本场无从判定）'
$止1 = [DateTime]::Now.AddSeconds(25)
while ((测-进程仍在 $p1.Id) -and [DateTime]::Now -lt $止1) { Start-Sleep -Milliseconds 300 }
$出1 = 收-输出 $组1
断言 (-not (测-进程仍在 $p1.Id)) '父进程死亡后子供给进程自行退出（不再变成孤儿占着缓存与带宽）'
断言 ($出1 -match '父进程（模块，PID \d+）已退出，本地供给自行终止') '退出原因写明是父进程已退出（含 PID）'
停-子进程 $p1

# ---------- S2 认领遗留半成品 ----------
Write-Output ''
Write-Output '===== S2. 认领无人持有的遗留半成品（上轮被 taskkill 的残渣） ====='
$组2 = 新建-参数文件 'CONC-S2-LOCAL.tar.gz' @('http://127.0.0.1:59999/a.tar.gz') 0
$成品2 = Join-Path $env:TEMP 'CONC-S2-LOCAL.tar.gz'
Remove-Item -LiteralPath $成品2 -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:TEMP 'CONC-S2-LOCAL.tar.gz.downloading-*') -Force -ErrorAction SilentlyContinue
Set-Content -LiteralPath ($成品2 + '.downloading-9999') -Value (('9' * 100)) -Encoding Ascii -NoNewline
Set-Content -LiteralPath ($成品2 + '.downloading-8888') -Value (('8' * 50)) -Encoding Ascii -NoNewline
$p2 = 跑-子进程 $组2 8
$出2 = 收-输出 $组2
断言 ($出2 -match '认领遗留半成品续传：100 字节') ('认领最大的遗留半成品续传（实测：' + (($出2 -split "`r?`n" | Where-Object { $_ -match '认领' }) -join ' ') + '）')
断言 (-not (Test-Path ($成品2 + '.downloading-9999'))) '被认领的遗留文件已改名（不再以旧 PID 名残留）'
断言 (-not (Test-Path ($成品2 + '.downloading-8888'))) '多余的遗留副本被清掉（同一产物不留两份，防 TEMP 堆积）'
断言 (@(Get-ChildItem -LiteralPath $env:TEMP -Filter 'CONC-S2-LOCAL.tar.gz.downloading-*' -ErrorAction SilentlyContinue).Count -eq 1) '只剩本进程自己的私有在途文件'
断言 ($出2 -notmatch 'being used by another process') '无人持锁时不出现占用类报错'
停-子进程 $p2

# ---------- S2b 活属主的半成品绝不可认领（缺陷B）----------
# 线上事故（2026-10-23）：认领只按「有没有写句柄」判无人持有 —— 活着的属主在等下个汇报周期时句柄是关着的，
# 于是它已下好的 42MB（共 84MB）半成品被改名搬走，两边从残缺处续传，日志里冒出两个「另一供给进程」。
# 修法：归属判据 = 句柄被持有 **或** 文件名里的属主 PID 还活着；活属主一概跳过。
Write-Output ''
Write-Output '===== S2b. 活属主（无句柄，仅 PID 名可识别）的半成品不被认领 ====='
$假属主 = Start-Process powershell -ArgumentList '-NoProfile','-Command','Start-Sleep 240' -NoNewWindow -PassThru
$组2b = 新建-参数文件 'CONC-S2B-LOCAL.tar.gz' @('http://127.0.0.1:59999/a.tar.gz') 0
$成品2b = Join-Path $env:TEMP 'CONC-S2B-LOCAL.tar.gz'
Remove-Item -LiteralPath $成品2b -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:TEMP 'CONC-S2B-LOCAL.tar.gz.downloading-*') -Force -ErrorAction SilentlyContinue
# 关键：这个文件**没有任何句柄**（复刻“属主正在睡到下个汇报周期”的那个瞬间），只能靠 PID 名看出它还活着
$活半成品 = $成品2b + '.downloading-' + $假属主.Id
$活半成品字节 = 1048576
$活半成品内容 = New-Object byte[] $活半成品字节
$活半成品内容[0] = 0x1F; $活半成品内容[1] = 0x8B
[System.IO.File]::WriteAllBytes($活半成品, $活半成品内容)
$p2b = 跑-子进程 $组2b 12
$出2b = 收-输出 $组2b
断言 (Test-Path -LiteralPath $活半成品) '活属主的在途文件仍在原位（没被改名搬走）'
断言 ((Get-Item -LiteralPath $活半成品 -ErrorAction SilentlyContinue).Length -eq $活半成品字节) ('活属主已下的字节一个不少（实测 ' + $(if (Test-Path -LiteralPath $活半成品) { (Get-Item -LiteralPath $活半成品).Length } else { '文件已没' }) + ' 字节）')
断言 ($出2b -match ('另一供给进程正在下载同一产物（属主 PID ' + $假属主.Id + '，存活')) '按属主 PID 判出“他方还在下”并写明属主与存活判据（不再靠字节数猜）'
断言 ($出2b -notmatch '认领遗留半成品') '不把活属主的文件当无人遗留认领'
断言 (@(Get-ChildItem -LiteralPath $env:TEMP -Filter 'CONC-S2B-LOCAL.tar.gz.downloading-*' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 1 }).Count -eq 1) '没有多出一份大文件（本进程未抢先下载同一产物）'
停-子进程 $p2b
Stop-Process -Id $假属主.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $活半成品, $成品2b -Force -ErrorAction SilentlyContinue

# ---------- S3 他方持锁 → 等待/接管，不刷占用错 ----------
Write-Output ''
Write-Output '===== S3. 他方进程持锁写同一产物（复刻线上孤儿场景） ====='
$组3 = 新建-参数文件 'CONC-S3-LOCAL.tar.gz' @('http://127.0.0.1:59999/a.tar.gz') 0
$成品3 = Join-Path $env:TEMP 'CONC-S3-LOCAL.tar.gz'
Remove-Item -LiteralPath $成品3 -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:TEMP 'CONC-S3-LOCAL.tar.gz.downloading-*') -Force -ErrorAction SilentlyContinue
$持锁脚本文件 = Join-Path $env:TEMP ('vsi-lock-' + [Guid]::NewGuid().ToString('N') + '.ps1')
$持锁脚本 = @'
$p = $args[0]
$fs = [System.IO.File]::Open($p, 'OpenOrCreate', 'Write', 'Read')
$fs.SetLength(10)
$碎 = [byte[]](0x1F, 0x8B, 1, 2, 3, 4, 5, 6, 7, 8)
$fs.Write($碎, 0, 10); $fs.Flush()
Start-Sleep -Seconds 5
$fs.SetLength(0)
$fs.Seek(0, 'Begin') | Out-Null
$fs.Write([byte[]](0x1F, 0x8B) + [byte[]]::new(30), 0, 32)
$fs.Flush()
Start-Sleep -Seconds 8
$fs.Dispose()
'@
[System.IO.File]::WriteAllText($持锁脚本文件, $持锁脚本, [System.Text.UTF8Encoding]::new($true))
$持锁进程 = Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $持锁脚本文件 + '" "' + $成品3 + '"') -NoNewWindow -PassThru
Start-Sleep -Seconds 2
$p3 = 跑-子进程 $组3 18 -等待退出
$出3 = 收-输出 $组3
断言 ($出3 -match '另一供给进程正在下载同一产物') '他方持锁且未完成时，打印一行等待说明（不是每轮刷错）'
断言 ($出3 -notmatch 'being used by another process') '全程不再出现文件被占用报错（本次线上事故的主症状）'
断言 ($出3 -notmatch '下载中断') '等待期不计入网络重试，也不刷下载中断行'
断言 ($出3 -match '本地缓存已完整') '他方写完（仍持锁）后直接接管已就位的包，不重复下载'
断言 ($出3 -match '已交接主会话上传') '接管后照常交接主会话上传（日志已写明）'
断言 (Test-Path -LiteralPath $组3.作业文件) '接管后 .job 交接文件已写（Linux 分支落 TEMP 根目录）'
停-子进程 $p3
Stop-Process -Id $持锁进程.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $持锁脚本文件, $组3.作业文件 -Force -ErrorAction SilentlyContinue
$等待行数 = @($出3 -split "`r?`n" | Where-Object { $_ -match '另一供给进程' }).Count
Write-Output ('  等待行共 ' + $等待行数 + ' 行（自适应周期，不应随轮数线性增长）')
断言 ($等待行数 -le 4) ('等待说明受自适应周期约束（实测 ' + $等待行数 + ' 行）')

# ---------- S4 完整下载：私有在途名 → 发布稳定成品名 → Linux .job 交接 ----------
Write-Output ''
Write-Output '===== S4. 完整下载后发布稳定成品名并交接 ====='
$端口 = 取-空闲端口
$服务脚本 = @'
$端 = [int]$args[0]; $字节 = [byte[]]::new(32); $字节[0] = 0x1F; $字节[1] = 0x8B
$侦 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $端)
$侦.Start()
$止 = (Get-Date).AddSeconds(60)
while ((Get-Date) -lt $止) {
    if (-not $侦.Pending()) { Start-Sleep -Milliseconds 40; continue }
    $客 = $侦.AcceptTcpClient()
    try {
        $流 = $客.GetStream()
        $读 = New-Object System.IO.StreamReader($流)
        while (($行 = $读.ReadLine()) -ne $null -and $行 -ne '') { }
        $头 = "HTTP/1.1 200 OK`r`nContent-Length: 32`r`nContent-Type: application/octet-stream`r`nConnection: close`r`n`r`n"
        $头字节 = [System.Text.Encoding]::ASCII.GetBytes($头)
        $流.Write($头字节, 0, $头字节.Length); $流.Write($字节, 0, $字节.Length); $流.Flush()
    } catch { } finally { $客.Close() }
}
$侦.Stop()
'@
$服务脚本文件 = Join-Path $env:TEMP ('vsi-http-' + [Guid]::NewGuid().ToString('N') + '.ps1')
[System.IO.File]::WriteAllText($服务脚本文件, $服务脚本, [System.Text.UTF8Encoding]::new($true))
$服务进程 = Start-Process powershell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $服务脚本文件 + '" ' + $端口) -NoNewWindow -PassThru
$通 = $false
foreach ($试 in 1..40) { try { $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $端口); $c.Close(); $通 = $true; break } catch { Start-Sleep -Milliseconds 150 } }
断言 $通 ('回环 HTTP 测试服务已监听（端口 ' + $端口 + '）')
$组4 = 新建-参数文件 'CONC-S4-LOCAL.tar.gz' @(('http://127.0.0.1:' + $端口 + '/a.tar.gz')) 0
$成品4 = Join-Path $env:TEMP 'CONC-S4-LOCAL.tar.gz'
Remove-Item -LiteralPath $成品4 -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:TEMP 'CONC-S4-LOCAL.tar.gz.downloading-*') -Force -ErrorAction SilentlyContinue
$p4 = 跑-子进程 $组4 15 -等待退出
$出4 = 收-输出 $组4
断言 ($出4 -match '下载完成：共 32 字节') ('下载完成并过完整性校验（实测尾行：' + (($出4 -split "`r?`n" | Where-Object { $_ -match '下载完成' }) -join ' ') + '）')
断言 (Test-Path -LiteralPath $成品4) '已发布为稳定成品名（其它供给进程可直接复用，不必重下）'
断言 ((Test-Path -LiteralPath $成品4) -and (Get-Item -LiteralPath $成品4).Length -eq 32) '成品长度正确'
断言 (@(Get-ChildItem -LiteralPath $env:TEMP -Filter 'CONC-S4-LOCAL.tar.gz.downloading-*' -ErrorAction SilentlyContinue).Count -eq 0) '私有在途文件已随成功改名消失（不留残渣）'
断言 (Test-Path -LiteralPath $组4.作业文件) '.job 交接说明已写入（Linux 分支由接管编排接管上传）'
断言 ((Test-Path -LiteralPath $组4.作业文件) -and ((Get-Content -LiteralPath $组4.作业文件 -Raw) -match 'CONC-S4-LOCAL\.tar\.gz')) '.job 里指向的是稳定成品名（而非本进程私有在途名）'
停-子进程 $p4
Stop-Process -Id $服务进程.Id -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $服务脚本文件, $组4.作业文件 -Force -ErrorAction SilentlyContinue

}
finally {
	Write-Output ''
	Write-Output '===== 收尾：杀残留子进程 + 清临时文件 ====='
	# 无论中途断言还是异常，都不得把供给子进程/持锁助手/本地 HTTP 服务留成孤儿（自检自己就不允许重演线上孤儿场景）
	Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match 'local-supply\.ps1.*vsi-con|vsi-lock-|vsi-http-' } | ForEach-Object {
		Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
	}
}

foreach ($残 in @('CONC-S1-LOCAL.tar.gz', 'CONC-S2-LOCAL.tar.gz', 'CONC-S3-LOCAL.tar.gz', 'CONC-S4-LOCAL.tar.gz')) {
	Remove-Item -LiteralPath (Join-Path $env:TEMP $残) -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath (Join-Path $env:TEMP ($残 + '.downloading-*')) -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath (Join-Path $env:TEMP ($残 + '.solo')) -Force -ErrorAction SilentlyContinue
}
Remove-Item -LiteralPath (Join-Path $env:TEMP 'race-supply-cc19dad217286193196903349966d7baf9d0111b-LOCAL.tar.gz.job') -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath $env:TEMP -Filter 'vsi-con-*.clixml' -ErrorAction SilentlyContinue | ForEach-Object {
	Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath ($_.FullName -replace '\.clixml$', '') -Recurse -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath ($_.FullName -replace '\.clixml$', '.out.txt') -Force -ErrorAction SilentlyContinue
	Remove-Item -LiteralPath ($_.FullName -replace '\.clixml$', '.out.txte') -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("并发自检断言失败数累计: " + (取-断言计数).失败)
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
