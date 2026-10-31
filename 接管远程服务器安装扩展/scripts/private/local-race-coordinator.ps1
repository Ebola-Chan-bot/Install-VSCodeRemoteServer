# CLI 与服务端的本地组合竞速协调器：两个下载同时运行，进度快照统一交给 preconnect 的单一汇报器。
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, Position = 0)]
	[string]$参数文件路径
)

$ErrorActionPreference = 'Continue'
$组参数 = Import-Clixml -LiteralPath $参数文件路径
$控制目录 = [string]$组参数.控制目录
$null = New-Item -ItemType Directory -Force -Path $控制目录
$作业表 = @{}
$状态表 = @{}
$临时文件 = New-Object System.Collections.Generic.List[string]
$临时文件.Add($参数文件路径)

function 接收-作业输出($产物名) {
	$作业 = $作业表[$产物名]
	if ($null -eq $作业) { return }
	foreach ($项 in @(Receive-Job -Job $作业 -ErrorAction SilentlyContinue)) {
		$行 = [string]$项
		if ($行.StartsWith('__VSI_PROGRESS__')) {
			try {
				$进度 = $行.Substring(16) | ConvertFrom-Json
				if (-not $状态表.ContainsKey($产物名)) {
					$状态表[$产物名] = @{ 已下载 = 0L; 总长度 = 0L; 起始时刻 = Get-Date; 汇报完成 = $false }
				}
				$状态表[$产物名].已下载 = [long]$进度.已下载
				$状态表[$产物名].总长度 = [long]$进度.总长度
			} catch { }
			continue
		}
		if ([string]::IsNullOrWhiteSpace($行)) { continue }
		if ($行 -match '本地下载完成') { $状态表[$产物名].汇报完成 = $true }
		Write-Output ('[本地供给-{0}] {1}' -f $产物名, $行)
	}
	if ($作业.State -in @('Completed', 'Failed', 'Stopped')) {
		if ($状态表.ContainsKey($产物名)) { $状态表[$产物名].汇报完成 = $true }
	}
}

function 发送-统一快照 {
	foreach ($产物名 in @('CLI', '服务端')) {
		if (-not $作业表.ContainsKey($产物名)) { continue }
		$状态 = $状态表[$产物名]
		$作业 = $作业表[$产物名]
		if ($状态.汇报完成 -or $作业.State -in @('Completed', 'Failed', 'Stopped')) { continue }
		Write-Output ('__VSI_SNAPSHOT__' + (@{ 端 = '本地'; 产物 = $产物名; 已下载 = [long]$状态.已下载; 总长度 = [long]$状态.总长度 } | ConvertTo-Json -Compress))
	}
}

try {
	foreach ($产物 in @($组参数.产物列表)) {
		$产物名 = [string]$产物.产物名
		$单参数文件 = Join-Path $控制目录 ('参数-' + $产物名 + '.xml')
		$临时文件.Add($单参数文件)
		$产物 | Add-Member -MemberType NoteProperty -Name 结构化进度 -Value $true -Force
		$产物 | Export-Clixml -LiteralPath $单参数文件
		$供给脚本 = Join-Path $PSScriptRoot 'local-supply.ps1'
		$作业表[$产物名] = Start-Job -ArgumentList $供给脚本, $单参数文件 -ScriptBlock {
			param($脚本, $单参数)
			& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $脚本 $单参数 2>&1 | ForEach-Object { [string]$_ }
		}
		$状态表[$产物名] = @{ 已下载 = 0L; 总长度 = 0L; 起始时刻 = Get-Date; 汇报完成 = $false }
	}
	while ($true) {
		foreach ($产物名 in @($作业表.Keys)) {
			$停止文件 = Join-Path $控制目录 ($产物名 + '.stop')
			if ((Test-Path -LiteralPath $停止文件) -and $作业表[$产物名].State -eq 'Running') {
				Stop-Job -Job $作业表[$产物名] -ErrorAction SilentlyContinue
				$状态表[$产物名].汇报完成 = $true
			}
			接收-作业输出 $产物名
		}
		发送-统一快照
		$未结束 = @($作业表.Values | Where-Object { $_.State -eq 'Running' -or $_.State -eq 'NotStarted' })
		if ($未结束.Count -eq 0) { break }
		Start-Sleep -Seconds 1
	}
} finally {
	foreach ($作业 in @($作业表.Values)) {
		Receive-Job -Job $作业 -ErrorAction SilentlyContinue | Out-Null
		Remove-Job -Job $作业 -Force -ErrorAction SilentlyContinue
	}
	foreach ($文件 in $临时文件) { Remove-Item -LiteralPath $文件 -Force -ErrorAction SilentlyContinue }
	Remove-Item -LiteralPath $控制目录 -Recurse -Force -ErrorAction SilentlyContinue
}
