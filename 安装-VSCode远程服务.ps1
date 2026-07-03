<#PSScriptInfo

.VERSION 1.0.1

.DESCRIPTION
通过 SSH 与 BITS 在远程 Windows 主机上安装与本机 VS Code 对应版本的 VS Code Server。

.GUID 2e2606a2-1d8b-418e-9d6d-a714a7704bdc

.AUTHOR 埃博拉酱-机器人

.COMPANYNAME 一致行动党

.COPYRIGHT (c) 2026 一致行动党. 保留所有权利。

.TAGS PowerShell VSCode RemoteSSH VSCodeServer Windows BITS SSH

.LICENSEURI https://opensource.org/licenses/MIT

.RELEASENOTES
修复直接调用失败的问题

#>

<#
.SYNOPSIS
通过 SSH 在远程 Windows 主机上安装与本机 VS Code 对应版本的 VS Code Server。

.DESCRIPTION
此脚本会根据用户指定的本机版本类型选择 VS Code 预览版或稳定版，自动检测本机提交号，
再通过 SSH 和 SCP 将远程安装脚本上传到目标 Windows 主机，使用 BITS 断点续传下载对应
版本的 VS Code Server 压缩包，并完成解压、目录整理与清理。

.PARAMETER 远程主机
要安装 VS Code 远程服务的目标服务器，可以是 SSH 配置名、计算机名或 IP 地址。

.PARAMETER 远程账户
可选的远程登录账户名。不提供时直接使用当前 SSH 配置或默认账户。

.PARAMETER SSH端口
远程 SSH 端口，默认值为 22。

.PARAMETER 本地版本
指定本机使用预览版还是稳定版。取值只能是“预览版”或“稳定版”。

.PARAMETER 轮询秒数
轮询远程 BITS 下载任务状态的时间间隔，默认值为 3 秒。

.PARAMETER 最大恢复次数
远程 BITS 下载任务在中断后允许自动恢复的最大次数，默认值为 5。

.EXAMPLE
安装-VSCode远程服务 上科大A服务器 -本地版本 预览版

.EXAMPLE
安装-VSCode远程服务 192.168.1.10 -远程账户 admin -SSH端口 22 -本地版本 稳定版
#>

function 安装-VSCode远程服务 {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0)]
		[Alias('目标服务器', '计算机名', 'IP', '主机')]
		[string]$远程主机,

		[string]$远程账户,

		[int]$SSH端口 = 22,

		[ValidateSet('预览版', '稳定版')]
		[string]$本地版本,

		[int]$轮询秒数 = 3,

		[int]$最大恢复次数 = 5
	)

	function 取-本地VSCode信息 {
		param(
			[string]$指定版本
		)

		function 取-单个版本信息 {
			param(
				[string]$命令名,
				[string]$版本名,
				[string]$发布通道
			)

			$命令对象 = Get-Command $命令名 -ErrorAction SilentlyContinue | Select-Object -First 1
			if ($null -eq $命令对象) {
				return $null
			}

			$命令路径 = if ($命令对象.Path) { $命令对象.Path } else { $命令对象.Source }
			if ([string]::IsNullOrWhiteSpace($命令路径)) {
				return $null
			}

			$版本输出 = & $命令路径 --version 2>$null
			if ($LASTEXITCODE -ne 0 -or $版本输出.Count -lt 2) {
				return $null
			}

			$提交号 = [string]($版本输出 | Select-Object -Skip 1 -First 1)
			$提交号 = $提交号.Trim()
			if ($提交号 -notmatch '^[0-9a-f]{40}$') {
				return $null
			}

			return [pscustomobject]@{
				版本名 = $版本名
				命令路径 = $命令路径
				命令名称 = $命令对象.Name
				发布通道 = $发布通道
				提交号 = $提交号
			}
		}

		$预览版信息 = 取-单个版本信息 -命令名 'code-insiders' -版本名 '预览版' -发布通道 'insider'
		$稳定版信息 = 取-单个版本信息 -命令名 'code' -版本名 '稳定版' -发布通道 'stable'

		if (-not [string]::IsNullOrWhiteSpace($指定版本)) {
			if ($指定版本 -eq '预览版') {
				if ($null -eq $预览版信息) {
					throw '用户指定了预览版，但本机未安装可用的 VS Code Insiders。'
				}

				return $预览版信息
			}

			if ($null -eq $稳定版信息) {
				throw '用户指定了稳定版，但本机未安装可用的 VS Code Stable。'
			}

			return $稳定版信息
		}

		if ($null -ne $预览版信息 -and $null -ne $稳定版信息) {
			throw '本机同时安装了预览版和稳定版。请通过 -本地版本 显式指定要使用的版本。'
		}

		if ($null -ne $预览版信息) {
			return $预览版信息
		}

		if ($null -ne $稳定版信息) {
			return $稳定版信息
		}

		throw '本机未检测到可用的 VS Code 预览版或稳定版。'
	}

	function 取-SSH连接目标 {
		param(
			[string]$主机,
			[string]$账户
		)

		if ([string]::IsNullOrWhiteSpace($账户)) {
			return $主机
		}

		return ('{0}@{1}' -f $账户, $主机)
	}

	function 执行-SSH命令 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$命令文本
		)

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}

		& $ssh命令.Source '-p' $端口 $连接目标 $命令文本
		if ($LASTEXITCODE -ne 0) {
			throw ('SSH 执行失败，退出码: {0}' -f $LASTEXITCODE)
		}
	}

	function 上传-文件到远程 {
		param(
			[string]$本地路径,
			[string]$连接目标,
			[int]$端口,
			[string]$远程路径
		)

		$SCP命令 = Get-Command scp -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $SCP命令) {
			throw '未找到 scp 命令，无法上传远程安装脚本。'
		}

		& $SCP命令.Source '-P' $端口 $本地路径 ('{0}:{1}' -f $连接目标, $远程路径)
		if ($LASTEXITCODE -ne 0) {
			throw ('SCP 上传失败，退出码: {0}' -f $LASTEXITCODE)
		}
	}

	function 执行-远程安装脚本 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$脚本文本
		)

		$本地临时脚本路径 = Join-Path $env:TEMP ('临时安装-VSCode远程服务-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本文件名 = 'vscode-server-install-temp.ps1'
		$远程临时脚本路径 = ('./{0}' -f $远程临时脚本文件名)

		try {
			[System.IO.File]::WriteAllText($本地临时脚本路径, $脚本文本, [System.Text.UTF8Encoding]::new($false))
			上传-文件到远程 -本地路径 $本地临时脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程临时脚本路径
			执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\{0}"' -f $远程临时脚本文件名)
		} finally {
			if (Test-Path $本地临时脚本路径) {
				Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			}

			try {
				执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('del /q "%USERPROFILE%\{0}"' -f $远程临时脚本文件名)
			} catch {
			}
		}
	}

	$ErrorActionPreference = 'Stop'
	$本地信息 = 取-本地VSCode信息 -指定版本 $本地版本
	$连接目标 = 取-SSH连接目标 -主机 $远程主机 -账户 $远程账户

	$远程安装脚本 = @'
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

	if ([string]::IsNullOrWhiteSpace($原始架构)) {
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
		[int]$等待秒数
	)

	$已恢复次数 = 0

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

等待-BITS任务完成 -任务名称 $任务名称 -目标路径 $压缩包路径 -恢复上限 $最大恢复次数 -等待秒数 $轮询秒数

if (-not (Test-Path $压缩包路径)) {
	throw ('下载完成后未找到压缩包: {0}' -f $压缩包路径)
}

Write-Host '下载完成，开始解压。'
展开-服务器压缩包 -压缩包路径 $压缩包路径 -目标目录 $最终安装目录

Write-Host '安装完成，当前目录内容如下。'
Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize
'@

	$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
	$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)
	$远程安装脚本 = $远程安装脚本.Replace('__轮询秒数__', [string]$轮询秒数)
	$远程安装脚本 = $远程安装脚本.Replace('__最大恢复次数__', [string]$最大恢复次数)

	Write-Host ('本机自动检测到的 VS Code 命令: {0}' -f $本地信息.命令路径)
	Write-Host ('本机自动检测到的发布通道: {0}' -f $本地信息.发布通道)
	Write-Host ('本机自动检测到的提交号: {0}' -f $本地信息.提交号)
	Write-Host ('远程连接目标: {0}' -f $连接目标)

	执行-远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本
}
安装-VSCode远程服务 @args