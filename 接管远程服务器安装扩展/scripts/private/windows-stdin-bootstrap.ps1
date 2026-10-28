# Windows 单会话 stdin 引导（固定极小，永远只占 argv 里的几百字符）
#
# 为什么改成 stdin：安装脚本正文（去注释去空行）gzip+base64 得 $载荷，内嵌进 Windows单会话引导.ps1 得 $引导脚本，再整体按 UTF-16 base64 得 $引导码 —— 双重 base64 让命令行膨胀约 2.67 倍。实测本仓库当前模板下argv= 37,950 字符 > Windows CreateProcess 上限 32,767 → 本地 ssh.exe 根本起不来："Program 'ssh.exe' failed to run: The filename or extension is too long"（psm1:621），preconnect退出码 1 → Remote-SSH 判 PreconnectScriptFailure（Session Summary: 预连接脚本已失败），整条连接夭折，窗口再也重连不上（2026-10-22 真机复现，耗时 1.98 秒即失败）。
# 旧结论“不走 stdin（远端 shell 对 stdin 收尾不可靠，挂死+僵尸进程）”被本轮实测推翻：
#   ① 远端 sshd DefaultShell = powershell.exe（不是 cmd.exe，故无 8191 字符命令行上限）；
#   ② 本引导读**全量** stdin → 去掉一切空白 → 再 base64 解码，2KB / 40KB / 120KB / 400KB 四档长度与 SHA256 双判据全部一致、退出码 0、单程约 1 秒；管道结束时本地 PowerShell 会正常关闭 ssh 的标准输入（EOF 确定送达，不靠猜）。
# 载荷走 stdin、argv 只装本引导 → argv 长度与安装脚本大小彻底解耦，模板再长大也撞不到上限。
#
# ===== 有界读取（2026-10-23 上科大B服务器死亡螺旋事故后加固）=====
# 绝不能无期限地阻塞等 EOF（旧写法直接同步读全量输入）：本地看门狗 taskkill 杀掉的是**本地** ssh.exe，Windows 不向远端传播信号，于是远端这个引导进程会永远卡在 ReadToEnd 里成为孤儿。每失败一次尝试就多留一个，实测 B 上堆到 8 个卡死引导 + 52 条 sshd 会话，会话饱和后新连接的首字节延迟被拖过看门狗（240 秒）→ 看门狗又杀（安装脚本首个输出在僵尸清理之后才打，冷启动/饱和时首字节更晚）→又留一个孤儿 → 彻底瘫痪。改为有界异步读：90 秒拿不到 EOF 就自己退出，绝不留孤儿、绝不放大饱和。
# 读取器必须是 OpenStandardInput 上的 StreamReader：B 服务器实测旧的 Console.In 异步全量读取在大载荷时连 Task 都不返回，下面的 Wait(90000) 根本没机会执行；改用原始标准输入后，同一 154KB 载荷可完整读完并回执（2026-10-24 实测）。
$读器 = New-Object System.IO.StreamReader -ArgumentList ([Console]::OpenStandardInput())
$读任务 = $读器.ReadToEndAsync()
if (-not $读任务.Wait(90000)) {
	Write-Host '[stdin引导] 等待标准输入 90 秒仍无 EOF，远端主动退出（不再无期限挂起，避免留下孤儿会话拖垮后续连接）。'
	exit 1
}
$全量 = $读任务.Result
$净 = ($全量 -replace '\s', '')
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
