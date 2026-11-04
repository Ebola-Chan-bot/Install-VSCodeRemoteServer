# Remote-SSH 管道执行守卫 v5：本文件整段追加到远端用户 profile（Documents\WindowsPowerShell\profile.ps1）末尾，幂等部署由 remote-install-common.ps1 完成。
# 触发条件：stdin 是管道且进程无命令行参数 = Remote-SSH 把连接脚本经 stdin 喂给裸 powershell REPL 执行；带参数/命令的会话与交互登录不受影响。
# v5：在当前进程内执行脚本，先把 stdout 替换为 AutoFlush 的 StreamWriter——每次写出立即刷到管道，不再有块缓冲滞留。v4 的 powershell -File 子进程默认块缓冲（printResult 的 listeningOn 握手标记不够触发 4KB 刷新，Remote-SSH 本地 17 秒超时）。
# 注意：守卫标记行尾注释的 v5 是幂等版本号，改动逻辑必须同步升号。

$守卫标记 = 'Remote-SSH 管道执行守卫 v5' # 幂等标记与版本号（勿删本行）：标记必须留在代码行尾注释里（整行注释会被载荷的去注释步骤剥掉，标记丢失会导致每连一次就重贴一份守卫）
if ([Console]::IsInputRedirected -and ([Environment]::GetCommandLineArgs().Count -eq 1)) {
	# stdout 换为 AutoFlush 的 StreamWriter：PowerShell 默认 stdout 在非交互模式下是块缓冲（4KB），
	# Remote-SSH 安装脚本的握手标记（listeningOn 等）不足触发刷新，必须逐行即刷。
	$原始输出 = [Console]::OpenStandardOutput()
	$自动刷写器 = New-Object System.IO.StreamWriter($原始输出, [System.Text.Encoding]::UTF8)
	$自动刷写器.AutoFlush = $true
	[Console]::SetOut($自动刷写器)
	$临时脚本 = Join-Path $env:TEMP ('vscode-guard-' + [guid]::NewGuid().ToString('N').Substring(0,8) + '.ps1')
	$读取 = New-Object System.Text.StringBuilder
	while ($true) {
		$行文本 = [Console]::In.ReadLine()
		if ($null -eq $行文本) { break }
		[void]$读取.AppendLine($行文本)
	}
	# EOF 到达才落盘执行：Remote-SSH 的 type 管道会关闭 stdin，EOF 确定到来
	[System.IO.File]::WriteAllText($临时脚本, $读取.ToString(), [System.Text.Encoding]::UTF8)
	try {
		. $临时脚本
	} catch {
		[Console]::Out.WriteLine('脚本异常: ' + $_.Exception.Message)
	}
	$退出码 = $LASTEXITCODE
	if ($null -eq $退出码) { $退出码 = 0 }
	Remove-Item -LiteralPath $临时脚本 -Force -ErrorAction SilentlyContinue
	exit $退出码
}
$守卫结束 = 1 # 守卫块结束标记（勿删本行）
