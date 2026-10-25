# 远端诊断第三轮：拿 supervisor/桥接链的完整命令行 + code-insiders 命名管道清单（不截断）
$ErrorActionPreference = 'Continue'
Write-Output ('HOST=' + $env:COMPUTERNAME)

Write-Output '--- vscode-server 相关进程完整命令行 ---'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
	Where-Object { $_.Name -in @('cmd.exe', 'node.exe', 'code-insiders-7cc5e7382b284f2156375fcedc388b44a07c0487.exe') -and $_.CommandLine -match 'vscode-server-insiders' } |
	Sort-Object CreationDate |
	ForEach-Object {
		Write-Output ('PID=' + $_.ProcessId + ' PPID=' + $_.ParentProcessId + ' ' + $_.Name + ' START=' + $_.CreationDate.ToString('HH:mm:ss'))
		Write-Output ('  CMD=' + [string]$_.CommandLine)
	}

Write-Output '--- code-insiders/copilot/agent 相关命名管道 ---'
try {
	[IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'code-insiders|copilot|agent' } | ForEach-Object { Write-Output ('  ' + $_) }
} catch {
	Write-Output ('  管道枚举失败：' + $_.Exception.Message)
}
Write-Output '===END==='
