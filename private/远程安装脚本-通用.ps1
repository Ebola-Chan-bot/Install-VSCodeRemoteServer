# 远程安装脚本（通用版）
# 要求远程 PowerShell 3.0+
# 此文件通过主脚本上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function 取-系统架构标识 {
	$原始架构 = if ($env:PROCESSOR_ARCHITEW6432) {
		$env:PROCESSOR_ARCHITEW6432
	} elseif ($env:PROCESSOR_ARCHITECTURE) {
		$env:PROCESSOR_ARCHITECTURE
	} else {
		$null
	}

	if ([string]::IsNullOrEmpty($原始架构) -or $原始架构.Trim().Length -eq 0) {
		throw '未能自动检测远程系统架构。'
	}

	switch ($原始架构.ToUpperInvariant()) {
		'AMD64' { return 'win32-x64' }
		'X64' { return 'win32-x64' }
		'ARM64' { return 'win32-arm64' }
		default { throw ('暂不支持的远程系统架构: {0}' -f $原始架构) }
	}
}

function 取-安装目录 {
	param(
		[string]$通道,
		[string]$版本提交号
	)

	$安装根目录 = if ($通道 -eq 'insider') {
		Join-Path $HOME '.vscode-server-insiders\bin'
	} else {
		Join-Path $HOME '.vscode-server\bin'
	}

	return Join-Path $安装根目录 $版本提交号
}

function 取-下载地址 {
	param(
		[string]$通道,
		[string]$版本提交号,
		[string]$架构
	)

	$文件名 = 'vscode-server-{0}.zip' -f $架构
	return 'https://vscode.download.prss.microsoft.com/dbazure/download/{0}/{1}/{2}' -f $通道, $版本提交号, $文件名
}

function 停止-占用安装目录的进程 {
	param(
		[string]$安装目录,
		[string]$版本提交号
	)

	$进程列表 = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
		($_.ExecutablePath -and $_.ExecutablePath.StartsWith($安装目录, [System.StringComparison]::OrdinalIgnoreCase)) -or
		($_.CommandLine -and $_.CommandLine -like ('*' + $版本提交号 + '*'))
	}

	foreach ($进程 in $进程列表) {
		try {
			Stop-Process -Id $进程.ProcessId -Force -ErrorAction SilentlyContinue
		} catch {
		}
	}
}

function 取-BITS任务 {
	param(
		[string]$任务名称,
		[string]$目标路径
	)

	return Get-BitsTransfer -ErrorAction SilentlyContinue |
		Where-Object { $_.DisplayName -eq $任务名称 -or $_.Destination -eq $目标路径 } |
		Select-Object -First 1
}

function 等待-BITS任务完成 {
	param(
		[string]$任务名称,
		[string]$目标路径,
		[int]$恢复上限,
		[int]$等待秒数,
		[int]$超时秒数
	)

	$已恢复次数 = 0
	$开始时间 = Get-Date

	while ($true) {
		$当前任务 = 取-BITS任务 -任务名称 $任务名称 -目标路径 $目标路径
		if ($null -eq $当前任务) {
			if (Test-Path $目标路径) {
				return
			}

			throw '未找到正在执行的 BITS 下载任务。'
		}

		$当前状态 = [string]$当前任务.JobState
		$总字节数 = [uint64]$当前任务.BytesTotal
		$已传字节数 = [uint64]$当前任务.BytesTransferred
		$总大小未知 = ($总字节数 -eq [uint64]::MaxValue)
		$当前进度 = if ((-not $总大小未知) -and $总字节数 -gt 0) {
			[math]::Round(($已传字节数 * 100.0) / $总字节数, 1)
		} else {
			0
		}
		$总字节显示 = if ($总大小未知) {
			'未知'
		} else {
			[string]$总字节数
		}

		Write-Host ('状态: {0} | 进度: {1}% | {2} / {3} 字节' -f $当前状态, $当前进度, $已传字节数, $总字节显示)

		if ($当前状态 -eq 'Transferred') {
			Complete-BitsTransfer -BitsJob $当前任务
			return
		}

		if ($当前状态 -eq 'TransientError' -or $当前状态 -eq 'Error') {
			if ($已恢复次数 -ge $恢复上限) {
				throw ('BITS 下载失败，超过最大恢复次数。当前状态: {0}' -f $当前状态)
			}

			$已恢复次数++
			Write-Host ('检测到传输中断，开始第 {0} 次恢复。' -f $已恢复次数)
			Resume-BitsTransfer -BitsJob $当前任务 -Asynchronous
		}

		if ($超时秒数 -gt 0) {
			$已耗时 = ((Get-Date) - $开始时间).TotalSeconds
			if ($已耗时 -gt $超时秒数) {
				throw ('BITS 下载超时（{0} 秒），当前状态: {1}' -f $超时秒数, $当前状态)
			}
		}

		Start-Sleep -Seconds $等待秒数
	}
}

function 展开-服务器压缩包 {
	param(
		[string]$压缩包路径,
		[string]$目标目录
	)

	Expand-Archive -Path $压缩包路径 -DestinationPath $目标目录 -Force

	$目录项列表 = @(Get-ChildItem -Force $目标目录)
	if ($目录项列表.Count -eq 1 -and $目录项列表[0].PSIsContainer) {
		$内层目录 = $目录项列表[0]
		Get-ChildItem -Force $内层目录.FullName | Move-Item -Destination $目标目录 -Force
		Remove-Item $内层目录.FullName -Recurse -Force
	}

	$包装目录 = Get-ChildItem -Force $目标目录 -Directory | Where-Object { $_.Name -like 'vscode-server-*' } | Select-Object -First 1
	if ($null -ne $包装目录) {
		foreach ($包装目录项 in (Get-ChildItem -Force $包装目录.FullName)) {
			$目标路径 = Join-Path $目标目录 $包装目录项.Name
			if (-not (Test-Path $目标路径)) {
				Move-Item $包装目录项.FullName -Destination $目标目录 -Force
			}
		}
		Remove-Item $包装目录.FullName -Recurse -Force
	}

	Remove-Item $压缩包路径 -Force -ErrorAction SilentlyContinue
}

$提交号 = '__提交号__'
$发布通道 = '__发布通道__'
$轮询秒数 = [int]'__轮询秒数__'
$最大恢复次数 = [int]'__最大恢复次数__'
$超时秒数 = [int]'__超时秒数__'
$系统架构 = 取-系统架构标识
$最终安装目录 = 取-安装目录 -通道 $发布通道 -版本提交号 $提交号
$压缩包路径 = Join-Path $最终安装目录 'vscode-server.zip'
$下载地址 = 取-下载地址 -通道 $发布通道 -版本提交号 $提交号 -架构 $系统架构
$任务名称 = 'VSCode远程服务-' + $提交号

Write-Host ('准备安装 VS Code 远程服务，提交号: {0}' -f $提交号)
Write-Host ('发布通道: {0}' -f $发布通道)
Write-Host ('自动检测到的系统架构: {0}' -f $系统架构)
Write-Host ('自动检测到的安装目录: {0}' -f $最终安装目录)
Write-Host ('下载地址: {0}' -f $下载地址)

停止-占用安装目录的进程 -安装目录 $最终安装目录 -版本提交号 $提交号

if (Test-Path $最终安装目录) {
	Remove-Item $最终安装目录 -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force $最终安装目录 | Out-Null
Start-Service BITS -ErrorAction SilentlyContinue

$旧任务 = 取-BITS任务 -任务名称 $任务名称 -目标路径 $压缩包路径
if ($null -ne $旧任务) {
	Remove-BitsTransfer -BitsJob $旧任务 -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host '开始通过 BITS 下载压缩包。'
Start-BitsTransfer -Source $下载地址 -Destination $压缩包路径 -DisplayName $任务名称 -Asynchronous | Out-Null

$新任务 = $null
for ($序号 = 0; $序号 -lt 10; $序号++) {
	$新任务 = 取-BITS任务 -任务名称 $任务名称 -目标路径 $压缩包路径
	if ($null -ne $新任务) {
		break
	}

	Start-Sleep -Seconds 1
}

if ($null -eq $新任务) {
	throw '已发起下载，但未找到新建的 BITS 任务。'
}

等待-BITS任务完成 -任务名称 $任务名称 -目标路径 $压缩包路径 -恢复上限 $最大恢复次数 -等待秒数 $轮询秒数 -超时秒数 $超时秒数

if (-not (Test-Path $压缩包路径)) {
	throw ('下载完成后未找到压缩包: {0}' -f $压缩包路径)
}

Write-Host '下载完成，开始解压。'
展开-服务器压缩包 -压缩包路径 $压缩包路径 -目标目录 $最终安装目录

Write-Host '安装完成，当前目录内容如下。'
Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize
