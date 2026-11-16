# Windows 单会话 stdin 引导（固定极小；加载时剔除整行注释与空行后才编码进 argv，注释写多少都不占命令行预算）
#
# ===== 帧通道（2026-11-16 全单连接改造）=====
# 本引导不再「读全量 stdin 到 EOF」，而是逐行读到 __BOOTSTRAP_END__ 标记为止：标记只划定载荷边界，stdin **不关闭**——此后同一条 SSH 连接即帧通道（__FILE__/__CMD__/__EXIT__，字节级协议与 Linux 的 会话帧循环.sh 相同），本地供给的竞速产物由主进程的帧上传器随时插帧送入，全流程（引导/安装/竞速产物上传/收尾）不再需要第二条 SSH/scp 连接。
# 裸流交接：原始字节流存 $global:VSI_帧输入流、本引导缓冲里越过标记已读出的帧首段存 $global:VSI_帧剩余字节，供内层引导的帧接收器接着消费。不得改用 StreamReader：其字符缓冲会把越过标记的帧字节一并吞掉，二进制帧体经文本解码必损坏，故全程裸字节流。
#
# 为什么改成 stdin：安装脚本正文（去注释去空行）gzip+base64 得 $载荷，内嵌进 Windows单会话引导.ps1 得 $引导脚本，再整体按 UTF-16 base64 得 $引导码 —— 双重 base64 让命令行膨胀约 2.67 倍。实测本仓库当前模板下argv= 37,950 字符 > Windows CreateProcess 上限 32,767 → 本地 ssh.exe 根本起不来："Program 'ssh.exe' failed to run: The filename or extension is too long"（psm1:621），preconnect退出码 1 → Remote-SSH 判 PreconnectScriptFailure（Session Summary: 预连接脚本已失败），整条连接夭折，窗口再也重连不上（2026-10-22 真机复现，耗时 1.98 秒即失败）。
# 旧结论“不走 stdin（远端 shell 对 stdin 收尾不可靠，挂死+僵尸进程）”被本轮实测推翻：
#   ① 远端 sshd DefaultShell = powershell.exe（不是 cmd.exe，故无 8191 字符命令行上限）；
#   ② 本引导读**全量** stdin → 去掉一切空白 → 再 base64 解码，2KB / 40KB / 120KB / 400KB 四档长度与 SHA256 双判据全部一致、退出码 0、单程约 1 秒；管道结束时本地 PowerShell 会正常关闭 ssh 的标准输入（EOF 确定送达，不靠猜）。
# 载荷走 stdin、argv 只装本引导 → argv 长度与安装脚本大小彻底解耦，模板再长大也撞不到上限。
#
# ===== 有界读取（2026-10-23 上科大B服务器死亡螺旋事故后加固）=====
# 绝不能无期限地阻塞等 EOF（旧写法直接同步读全量输入）：本地看门狗 taskkill 杀掉的是**本地** ssh.exe，Windows 不向远端传播信号，于是远端这个引导进程会永远卡在 ReadToEnd 里成为孤儿。每失败一次尝试就多留一个，实测 B 上堆到 8 个卡死引导 + 52 条 sshd 会话，会话饱和后新连接的首字节延迟被拖过看门狗（240 秒）→ 看门狗又杀（安装脚本首个输出在僵尸清理之后才打，冷启动/饱和时首字节更晚）→又留一个孤儿 → 彻底瘫痪。改为有界异步读：90 秒拿不到引导结束标记就自己退出，绝不留孤儿、绝不放大饱和。标记到达之后接收器不再设总时限（帧可能在数分钟的下载后才到），其生命周期由内层引导在安装结束时回收。
# 读取必须走 OpenStandardInput 的裸字节流：B 服务器实测旧的 Console.In 异步全量读取在大载荷时连 Task 都不返回，有界 Wait 根本没机会执行；改用原始标准输入后，同一 154KB 载荷可完整读完并回执（2026-10-24 实测）。帧通道改造后同样不得用 StreamReader（见文件头「裸流交接」）。
$流 = [Console]::OpenStandardInput()
$global:VSI_帧输入流 = $流
$global:VSI_帧剩余字节 = New-Object byte[] 0
$载荷流 = New-Object System.IO.MemoryStream
$行字节 = New-Object System.Collections.Generic.List[byte]
$读缓冲 = New-Object byte[] 65536
$截止 = (Get-Date).AddSeconds(90)
$标记已到 = $false
while (-not $标记已到) {
	$剩余毫秒 = [int](($截止 - (Get-Date)).TotalMilliseconds)
	if ($剩余毫秒 -le 0) {
		Write-Host '[stdin引导] 等待引导结束标记 90 秒仍未收到，远端主动退出（不再无期限挂起，避免留下孤儿会话拖垮后续连接）。'
		exit 1
	}
	$读任务 = $流.ReadAsync($读缓冲, 0, $读缓冲.Length)
	if (-not $读任务.Wait($剩余毫秒)) {
		Write-Host '[stdin引导] 等待引导结束标记 90 秒仍未收到，远端主动退出（不再无期限挂起，避免留下孤儿会话拖垮后续连接）。'
		exit 1
	}
	$读到 = 0
	try { $读到 = $读任务.Result } catch { $读到 = -1 }
	if ($读到 -lt 0) {
		Write-Host '[stdin引导] 标准输入读取失败（通道被截断）。'
		exit 1
	}
	if ($读到 -eq 0) {
		Write-Host '[stdin引导] 标准输入提前结束：未收到引导结束标记（载荷未送达或通道被截断）。'
		exit 1
	}
	for ($位置 = 0; $位置 -lt $读到; $位置++) {
		$字节 = $读缓冲[$位置]
		if ($字节 -ne 10) { $行字节.Add($字节); continue }
		$文本行 = [System.Text.Encoding]::ASCII.GetString($行字节.ToArray()).Trim()
		$行字节.Clear()
		if ($文本行 -ne '__BOOTSTRAP_END__') {
			$线字节 = [System.Text.Encoding]::ASCII.GetBytes($文本行)
			$载荷流.Write($线字节, 0, $线字节.Length)
			continue
		}
		# 标记已到：本块内越过标记已读出的字节就是帧流首段，交接给帧接收器接着消费（管道里未读的字节随后由接收器从同一条裸流读出，顺序不乱）
		$余量 = $读到 - $位置 - 1
		if ($余量 -gt 0) {
			$帧首段 = New-Object byte[] $余量
			[Array]::Copy($读缓冲, $位置 + 1, $帧首段, 0, $余量)
			$global:VSI_帧剩余字节 = $帧首段
		}
		$标记已到 = $true
		break
	}
}
$净 = [System.Text.Encoding]::ASCII.GetString($载荷流.ToArray()) -replace '\s', ''
if ($净.Length -eq 0) {
	Write-Host '[stdin引导] 标准输入为空：载荷未送达（本地没传 stdin，或通道被截断）'
	exit 1
}
try {
	$字节 = [Convert]::FromBase64String($净)
} catch {
	Write-Host ('[stdin引导] 载荷 base64 解码失败（清洗后长度 {0}）: {1}' -f $净.Length, $_.Exception.Message)
	exit 1
}
$文本 = [System.Text.Encoding]::Unicode.GetString($字节)
# 到达即回执：在执行安装脚本**之前**先回一行，让本地看门狗尽早拿到首字节、把「正在冷启动」与「真挂死」区分开。安装脚本开头是大段僵尸清理，其首个 Get-CimInstance / Get-NetTCPConnection 在会话饱和的主机上会显著拖慢首字节；没有这行回执时，本地会把慢启动误判成挂死而按看门狗杀掉（首行输出「准备安装」要等清理全跑完才打）。
Write-Host ('[stdin引导] 载荷已到达（{0} 字符），帧通道保持打开，开始执行安装脚本...' -f $文本.Length)
try {
	# 内层引导自己决定退出码：正常 exit 0、安装脚本终止性错误 exit 1、PS2 老主机打 __PS2__ 后 exit 0。PowerShell的 exit 终止的是整个进程会话，无需在此再转发一次退出码。
	& ([scriptblock]::Create($文本))
	exit 0
} catch {
	Write-Host ('[stdin引导] 内层引导异常终止: {0}' -f $_.Exception.Message)
	exit 1
}
