# 远端诊断第二轮（A/B 同跑）：agent host 死因收口
# 关注：agent-host-insider.log 尾部（agent host 自己的日志）、copilot-sdk 运行时文件是否缺损、
#      各 node 进程完整命令行（识别 agent host 链）、remoteagent.log 里 AgentHost 的注册与失败行
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:USERPROFILE '.vscode-server-insiders'
Write-Output ('HOST=' + $env:COMPUTERNAME)

Write-Output '--- 1) agent-host-insider.log 尾部 30 行 ---'
$ah = Join-Path $root 'cli\agent-host-insider.log'
if (Test-Path $ah) {
	Get-Content $ah -Tail 30 -ErrorAction SilentlyContinue | ForEach-Object {
		$x = [string]$_
		if ($x.Length -gt 210) { $x = $x.Substring(0, 210) + '…' }
		Write-Output ('  ' + $x)
	}
} else {
	Write-Output '  （文件不存在）'
}

Write-Output '--- 2) copilot-sdk 运行时文件完整性 ---'
$sdk根 = Join-Path $root 'cli\servers\Insiders-7cc5e7382b284f2156375fcedc388b44a07c0487\server\node_modules\@github'
Write-Output ('  @github 目录=' + (Test-Path $sdk根))
if (Test-Path $sdk根) {
	Get-ChildItem $sdk根 -Directory -ErrorAction SilentlyContinue | ForEach-Object {
		$exe = @(Get-ChildItem $_.FullName -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue)
		Write-Output ('  ' + $_.Name + ' | exe数=' + $exe.Count)
		$exe | Select-Object -First 3 | ForEach-Object { Write-Output ('    ' + $_.FullName.Substring($sdk根.Length) + ' (' + $_.Length + ')') }
	}
}
Write-Output '--- 3) 与 agent/copilot/sdk 相关进程的完整命令行 ---'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
	Where-Object { $_.CommandLine -match 'copilot|agent-host|copilot-sdk|runtime' } |
	ForEach-Object {
		Write-Output ('  PID=' + $_.ProcessId + ' PPID=' + $_.ParentProcessId + ' ' + $_.Name)
		$c = [string]$_.CommandLine
		if ($c.Length -gt 300) { $c = $c.Substring(0, 300) + '…' }
		Write-Output ('    ' + $c)
	}

Write-Output '--- 4) code-server 两条 cmd 链的启动命令（对照 agent host 链是否存在）---'
Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
	Where-Object { $_.CommandLine -match 'code-server-insiders' } |
	ForEach-Object {
		$c = [string]$_.CommandLine
		if ($c.Length -gt 260) { $c = $c.Substring(0, 260) + '…' }
		Write-Output ('  PID=' + $_.ProcessId + ' PPID=' + $_.ParentProcessId + ' | ' + $c)
	}

Write-Output '--- 5) remoteagent.log 中 AgentHost 相关行 ---'
$ra = Get-ChildItem (Join-Path $root 'data\logs') -Recurse -Filter 'remoteagent.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($ra) {
	Write-Output ('  文件=' + $ra.FullName.Substring($root.Length) + '  mtime=' + $ra.LastWriteTime.ToString('HH:mm:ss'))
	$命中 = @(Get-Content $ra.FullName -ErrorAction SilentlyContinue | Where-Object { [string]$_ -match 'agentHost|AgentHost|6156|agent host' })
	Write-Output ('  命中行数=' + $命中.Count)
	$命中 | Select-Object -First 4 | ForEach-Object {
		$x = [string]$_
		if ($x.Length -gt 210) { $x = $x.Substring(0, 210) + '…' }
		Write-Output ('  H ' + $x)
	}
	$命中 | Select-Object -Last 6 | ForEach-Object {
		$x = [string]$_
		if ($x.Length -gt 210) { $x = $x.Substring(0, 210) + '…' }
		$out = '  T ' + $x
		Write-Output $out
	}
} else {
	Write-Output '  （无 remoteagent.log）'
}

Write-Output '--- 6) 已损坏扩展目录清单（缺 package.json 的目录）---'
$ext根 = Join-Path $root 'extensions'
Get-ChildItem $ext根 -Directory -ErrorAction SilentlyContinue | ForEach-Object {
	if (-not (Test-Path (Join-Path $_.FullName 'package.json'))) {
		Write-Output ('  损坏: ' + $_.Name + ' | mtime=' + $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') + ' | 子项=' + @(Get-ChildItem $_.FullName -Force -ErrorAction SilentlyContinue).Count)
	}
}
Write-Output '===END==='
