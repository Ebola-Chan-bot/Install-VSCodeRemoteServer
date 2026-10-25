# 一次性远端诊断（发送到 A/B 两台 Windows 主机各跑一遍）：定位 AgentHostChannel ECONNREFUSED(127.0.0.1:6156) 的根因
# 关注点：agent-host 进程是否存活、6156 谁在听、报错的 ms-dotnettools.csdevkit 扩展目录状态、近期日志与崩溃事件
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:USERPROFILE '.vscode-server-insiders'
Write-Output ('HOST=' + $env:COMPUTERNAME + '  USERPROFILE=' + $env:USERPROFILE + '  NOW=' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))

Write-Output '--- 1) server/agent/扩展宿主 进程 ---'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
	Where-Object { $_.CommandLine -match 'vscode-server-insiders|agent-host|server-main|code-insiders' } |
	Sort-Object CreationDate |
	ForEach-Object {
		$c = [string]$_.CommandLine
		if ($c.Length -gt 150) { $c = $c.Substring(0, 150) + '…' }
		Write-Output ('PID=' + $_.ProcessId + ' PPID=' + $_.ParentProcessId + ' START=' + $_.CreationDate.ToString('MM-dd HH:mm:ss') + ' ' + $_.Name + ' | ' + $c)
	}

Write-Output '--- 2) node.exe 全量（agent host 可能以 node 形态存在）---'
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
	Sort-Object CreationDate |
	ForEach-Object {
		$c = [string]$_.CommandLine
		if ($c.Length -gt 150) { $c = $c.Substring(0, 150) + '…' }
		Write-Output ('PID=' + $_.ProcessId + ' PPID=' + $_.ParentProcessId + ' START=' + $_.CreationDate.ToString('MM-dd HH:mm:ss') + ' | ' + $c)
	}

Write-Output '--- 3) 6156 端口与 loopback 监听者 ---'
$调用 = @(Get-NetTCPConnection -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -eq 6156 -or $_.RemotePort -eq 6156 })
if ($调用.Count -eq 0) { Write-Output '  （无任何 6156 连接/监听）' }
foreach ($c in $调用) {
	$拥有 = if ($c.OwningProcess) { try { (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName } catch { '?' } } else { '?' }
	Write-Output ('  ' + $c.LocalAddress + ':' + $c.LocalPort + ' -> ' + $c.RemoteAddress + ':' + $c.RemotePort + ' ' + $c.State + ' PID=' + $c.OwningProcess + '(' + $拥有 + ')')
}

Write-Output '--- 4) 报错扩展目录 ms-dotnettools.csdevkit-3.10.14-win32-x64 ---'
$ext = Join-Path $root 'extensions\ms-dotnettools.csdevkit-3.10.14-win32-x64'
Write-Output ('  目录存在=' + (Test-Path $ext) + '  package.json=' + (Test-Path (Join-Path $ext 'package.json')))
if (Test-Path $ext) {
	Get-ChildItem $ext -Force -ErrorAction SilentlyContinue | Select-Object -First 12 | ForEach-Object {
		Write-Output ('    ' + $_.Name + ' (' + $_.Length + ') ' + $_.LastWriteTime.ToString('MM-dd HH:mm:ss'))
	}
}

Write-Output '--- 5) extensions 目录里 dotnet/csdevkit 相关项 ---'
$ext根 = Join-Path $root 'extensions'
Get-ChildItem $ext根 -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'dotnet|csdevkit|cs-dev' } | ForEach-Object {
	Write-Output ('  ' + $_.Name + ' | dir=' + $_.PSIsContainer + ' | ' + $_.LastWriteTime.ToString('MM-dd HH:mm:ss'))
}
$ejson = Join-Path $ext根 'extensions.json'
if (Test-Path $ejson) {
	$命中 = Select-String -LiteralPath $ejson -Pattern 'csdevkit' -SimpleMatch -ErrorAction SilentlyContinue
	Write-Output ('  extensions.json 登记 csdevkit=' + ($null -ne $命中) + '（文件 ' + (Get-Item $ejson).Length + ' 字节）')
} else {
	Write-Output '  extensions.json 不存在'
}

Write-Output '--- 6) cli 下已有 server 版本与保活/锁文件 ---'
$cli = Join-Path $root 'cli'
Get-ChildItem $cli -Force -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object {
	Write-Output ('  ' + $_.Name + ' | dir=' + $_.PSIsContainer + ' | ' + $_.LastWriteTime.ToString('MM-dd HH:mm:ss'))
}
$srv = Join-Path $cli 'servers'
if (Test-Path $srv) {
	Get-ChildItem $srv -Directory -ErrorAction SilentlyContinue | ForEach-Object {
		$子 = @(Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ','
		Write-Output ('  servers\' + $_.Name + ' -> [' + $子 + ']')
	}
}

Write-Output '--- 7) 最近 8 个日志及尾部 ---'
Get-ChildItem $root -Recurse -Include '*.log' -File -ErrorAction SilentlyContinue |
	Sort-Object LastWriteTime -Descending | Select-Object -First 8 |
	ForEach-Object {
		Write-Output ('### ' + $_.FullName.Substring($root.Length) + ' | ' + $_.LastWriteTime.ToString('MM-dd HH:mm:ss') + ' | ' + $_.Length + 'B')
		Get-Content $_.FullName -Tail 6 -ErrorAction SilentlyContinue | ForEach-Object {
			$x = [string]$_
			if ($x.Length -gt 230) { $x = $x.Substring(0, 230) + '…' }
			Write-Output ('    ' + $x)
		}
	}

Write-Output '--- 8) 应用事件日志：18:00 后 node/code-insiders 崩溃记录 ---'
try {
	$事件 = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).Date.AddHours(17).AddMinutes(55) } -MaxEvents 400 -ErrorAction SilentlyContinue |
		Where-Object { $_.Message -match 'node|code-insiders|vscode' -and $_.LevelDisplayName -in @('错误', 'Error', '关键', 'Critical') }
	if ($事件) {
		$事件 | Select-Object -First 5 | ForEach-Object {
			$m = [string]$_.Message
			if ($m.Length -gt 200) { $m = $m.Substring(0, 200) + '…' }
			Write-Output ('  [' + $_.TimeCreated.ToString('HH:mm:ss') + '] ' + $_.ProviderName + ': ' + $m)
		}
	} else {
		Write-Output '  （无相关崩溃事件）'
	}
} catch {
	Write-Output ('  事件日志读取失败：' + $_.Exception.Message)
}
