# Windows 单会话 stdin 引导（固定极小；加载时剔除整行注释与空行后才编码进 argv，注释写多少都不占命令行预算）
#
# ===== 载荷专用通道（2026-11-17 第六轮重构）=====
# 逐行读到 __BOOTSTRAP_END__ 标记为止：标记划定载荷边界，本地写完载荷+标记即关 stdin（EOF）。Win32-OpenSSH exec 会话的 stdin 数据只在关流后整体送达，关流前可写上限约 2MB（实测 4MB 起 Write 永久阻塞），故 stdin 只装≤2MB 的载荷；安装包大数据改经同一条连接的 -R 远程端口转发 + 本地 HTTP 供给（direct-tcpip 通道），不再有 stdin 帧通道。
# 全程裸字节流 + 阻塞式同步 Read（理由见下方「有界读取」段）；标记后不再交接任何帧流。
#
# 为什么改成 stdin：安装脚本正文（去注释去空行）gzip+base64 得 $载荷，内嵌进 Windows单会话引导.ps1 得 $引导脚本，再整体按 UTF-16 base64 得 $引导码 —— 双重 base64 让命令行膨胀约 2.67 倍。实测本仓库当前模板下argv= 37,950 字符 > Windows CreateProcess 上限 32,767 → 本地 ssh.exe 根本起不来："Program 'ssh.exe' failed to run: The filename or extension is too long"（psm1:621），preconnect退出码 1 → Remote-SSH 判 PreconnectScriptFailure（Session Summary: 预连接脚本已失败），整条连接夭折，窗口再也重连不上（2026-10-22 真机复现，耗时 1.98 秒即失败）。
# 旧结论“不走 stdin（远端 shell 对 stdin 收尾不可靠，挂死+僵尸进程）”被本轮实测推翻：
#   ① 远端 sshd DefaultShell = powershell.exe（不是 cmd.exe，故无 8191 字符命令行上限）；
#   ② 本引导读**全量** stdin → 去掉一切空白 → 再 base64 解码，2KB / 40KB / 120KB / 400KB 四档长度与 SHA256 双判据全部一致、退出码 0、单程约 1 秒；管道结束时本地 PowerShell 会正常关闭 ssh 的标准输入（EOF 确定送达，不靠猜）。
# 载荷走 stdin、argv 只装本引导 → argv 长度与安装脚本大小彻底解耦，模板再长大也撞不到上限。
#
# ===== 有界读取（2026-10-23 上科大B服务器死亡螺旋事故后加固）=====
# 绝不能无期限地等标记：本地看门狗 taskkill 杀掉的是**本地** ssh.exe，Windows 不向远端传播信号，远端引导若永远等下去就成了孤儿。每失败一次尝试就多留一个，实测 B 上堆到 8 个卡死引导 + 52 条 sshd 会话，会话饱和后新连接的首字节延迟被拖过看门狗（240 秒）→ 看门狗又杀→又留一个孤儿 → 彻底瘫痪。90 秒拿不到引导结束标记就自己退出，绝不留孤儿。
# 读取必须走 OpenStandardInput 的裸字节流 + **阻塞式同步 Read**（2026-11-17 SSH 真机探针定论）：B 服务器 sshd 管道上 ReadAsync 的 Task 永不完成——远端进程 5 分钟零输出零退出（90 秒 Wait 界限形同虚设，ReadAsync 挂起时 Wait 也卡）。同步 Read 字节到达即返回；90 秒界限改为**每次 Read 前检查**：字节持续流动时不触发（大载荷合法慢传），字节停滞超界才退出——同步 Read 停滞时无法被打断，但本地看门狗杀 ssh 后远端管道断开、Read 返回 0/异常即退，不会成为永久孤儿。
$流 = [Console]::OpenStandardInput()
$载荷流 = New-Object System.IO.MemoryStream
$行字节 = New-Object System.Collections.Generic.List[byte]
$读缓冲 = New-Object byte[] 65536
$截止 = (Get-Date).AddSeconds(90)
$标记已到 = $false
# .NET Framework 实测（2026-11-17 B 服务器真机失败取证）：Process.StandardInput 属性被首次访问时就会把 Console.InputEncoding 的编码前导（UTF-8 BOM = EF BB BF）直接写进底层管道——发生在我们写任何字节之前，BaseStream 裸写也躲不开（本地复测：裸读 stdin 前 8 字节 = 239/187/191/65…）。旧全量读取时代 B 机从未跑过此载荷路径所以没暴露；逐行版把 BOM 当第一行内容保留，ASCII 解码成三个 '?' 混进 base64（清洗后长度恰好多 3）→ FromBase64String 失败。修复：流最开头的 EF BB BF 三字节循环剥掉（只检第一行；容忍包装层叠加的多段前导——本地复测两层 BOM 叠加场景；base64 字母表不含 '?'，绝不误伤合法载荷；宿主编码无 BOM 时条件不命中即无操作）。
$前导已检 = $false
while (-not $标记已到) {
	if ((Get-Date) -gt $截止) {
		Write-Host '[stdin引导] 等待引导结束标记 90 秒仍未收到，远端主动退出（不再无期限挂起，避免留下孤儿会话拖垮后续连接）。'
		exit 1
	}
	$读到 = 0
	try { $读到 = $流.Read($读缓冲, 0, $读缓冲.Length) } catch { $读到 = -1 }
	if ($读到 -lt 0) {
		Write-Host '[stdin引导] 标准输入读取失败（通道被截断）。'
		exit 1
	}
	if ($读到 -eq 0) {
		Write-Host '[stdin引导] 标准输入提前结束：未收到引导结束标记（载荷未送达或通道被截断）。'
		exit 1
	}
	# 有字节到达即刷新截止：90 秒界限只针对「字节停滞」，大载荷持续慢传不受影响
	$截止 = (Get-Date).AddSeconds(90)
	for ($位置 = 0; $位置 -lt $读到; $位置++) {
		$字节 = $读缓冲[$位置]
		if ($字节 -ne 10) { $行字节.Add($字节); continue }
		if (-not $前导已检) {
			$前导已检 = $true
			while ($行字节.Count -ge 3 -and $行字节[0] -eq 0xEF -and $行字节[1] -eq 0xBB -and $行字节[2] -eq 0xBF) { $行字节.RemoveRange(0, 3) }
		}
		$文本行 = [System.Text.Encoding]::ASCII.GetString($行字节.ToArray()).Trim()
		$行字节.Clear()
		if ($文本行 -ne '__BOOTSTRAP_END__') {
			$线字节 = [System.Text.Encoding]::ASCII.GetBytes($文本行)
			$载荷流.Write($线字节, 0, $线字节.Length)
			continue
		}
		# 标记已到：载荷边界划定，本地随后即关流（EOF），标记之后不会有更多数据
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
Write-Host ('[stdin引导] 载荷已到达（{0} 字符），开始执行安装脚本...' -f $文本.Length)
try {
	# 内层引导自己决定退出码：正常 exit 0、安装脚本终止性错误 exit 1、PS2 老主机打 __PS2__ 后 exit 0。PowerShell的 exit 终止的是整个进程会话，无需在此再转发一次退出码。
	& ([scriptblock]::Create($文本))
	exit 0
} catch {
	Write-Host ('[stdin引导] 内层引导异常终止: {0}' -f $_.Exception.Message)
	exit 1
}
