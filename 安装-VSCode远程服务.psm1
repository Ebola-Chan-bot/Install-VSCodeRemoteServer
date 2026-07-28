# 安装-VSCode远程服务 Module
# 通过 SSH 与 BITS 在远程 Windows 主机上安装 VS Code Server

# 加载私有远程脚本模板
$script:模块根目录 = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:远程脚本_通用 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-通用.ps1') -Raw -Encoding UTF8
$script:远程脚本_Win7 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Win7.ps1') -Raw -Encoding UTF8

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

		[int]$最大恢复次数 = 5,

		[int]$超时秒数 = 600,

		[ValidateSet('通用', 'Win7', '自动')]
		[string]$远程脚本版本 = '自动'
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
				版本名   = $版本名
				命令路径 = $命令路径
				命令名称 = $命令对象.Name
				发布通道 = $发布通道
				提交号   = $提交号
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

		if ($null -ne $预览版信息) { return $预览版信息 }
		if ($null -ne $稳定版信息) { return $稳定版信息 }

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
			[string]$命令文本,
			[switch]$TTY
		)

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}

		$ssh参数 = @('-p', $端口)
		if ($TTY) { $ssh参数 += '-t' }
		$ssh参数 += $连接目标
		$ssh参数 += $命令文本

		& $ssh命令.Source $ssh参数
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

	function 取-服务器压缩包文件名 {
		param(
			[string]$架构
		)

		return ('vscode-server-{0}.zip' -f $架构)
	}

	function 取-服务器压缩包下载地址 {
		param(
			[string]$发布通道,
			[string]$提交号,
			[string]$架构
		)

		$文件名 = 取-服务器压缩包文件名 -架构 $架构
		return ('https://vscode.download.prss.microsoft.com/dbazure/download/{0}/{1}/{2}' -f $发布通道, $提交号, $文件名)
	}

	function 下载-本地服务器压缩包 {
		param(
			[string]$发布通道,
			[string]$提交号,
			[string]$架构
		)

		$下载地址 = 取-服务器压缩包下载地址 -发布通道 $发布通道 -提交号 $提交号 -架构 $架构
		$本地压缩包路径 = Join-Path $env:TEMP ('vscode-server-{0}-{1}.zip' -f $架构, $提交号)

		if (-not (Test-Path $本地压缩包路径)) {
			Write-Host ('本机开始下载 VS Code Server 压缩包: {0}' -f $下载地址)
			Invoke-WebRequest -Uri $下载地址 -OutFile $本地压缩包路径 -UseBasicParsing
		}

		if (-not (Test-Path $本地压缩包路径)) {
			throw ('本机下载完成后未找到压缩包: {0}' -f $本地压缩包路径)
		}

		return $本地压缩包路径
	}

	function 探测-远程PS版本 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		try {
			$输出 = & (Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1).Source '-p' $端口 $连接目标 'powershell -NoProfile -Command "Write-Output $PSVersionTable.PSVersion.Major"'
			if ($LASTEXITCODE -eq 0 -and $输出) {
				foreach ($行 in $输出) {
					$行 = $行.Trim()
					# 跳过 SSH 诊断信息（CNAME 警告等）
					if ($行 -match '^\d+$') {
						$主版本 = [int]$行
						Write-Host ('检测到远程 PowerShell 主版本: {0}' -f $主版本)
						return $主版本
					}
				}
			}
		} catch {
			Write-Host ('远程 PowerShell 版本检测失败: {0}' -f $_)
		}

		return $null
	}

	function 选择-远程脚本 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$指定版本
		)

		switch ($指定版本) {
			'通用' {
				Write-Host '按用户指定使用通用版远程脚本。'
				return $script:远程脚本_通用
			}
			'Win7' {
				Write-Host '按用户指定使用 Win7 适配版远程脚本。'
				return $script:远程脚本_Win7
			}
			'自动' {
				$远程PS版本 = 探测-远程PS版本 -连接目标 $连接目标 -端口 $端口
				if ($null -eq $远程PS版本) {
					Write-Host '无法检测远程 PowerShell 版本，使用通用版远程脚本。'
					return $script:远程脚本_通用
				} elseif ($远程PS版本 -le 2) {
					Write-Host ('检测到远程 PowerShell {0}.0，使用 Win7 适配版远程脚本。' -f $远程PS版本)
					return $script:远程脚本_Win7
				} else {
					Write-Host ('检测到远程 PowerShell {0}.0，使用通用版远程脚本。' -f $远程PS版本)
					return $script:远程脚本_通用
				}
			}
		}

		throw ('未知的远程脚本版本: {0}' -f $指定版本)
	}

	function 执行-远程安装脚本 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$脚本文本,
			[string]$本地附加压缩包路径,
			[string]$远程附加压缩包文件名
		)

		$本地临时脚本路径 = Join-Path $env:TEMP ('临时安装-VSCode远程服务-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本文件名 = 'vscode-server-install-temp.ps1'
		$远程临时脚本路径 = ('./{0}' -f $远程临时脚本文件名)

		try {
			[System.IO.File]::WriteAllText($本地临时脚本路径, $脚本文本, [System.Text.UTF8Encoding]::new($true))
			上传-文件到远程 -本地路径 $本地临时脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程临时脚本路径
			if (-not [string]::IsNullOrWhiteSpace($本地附加压缩包路径) -and -not [string]::IsNullOrWhiteSpace($远程附加压缩包文件名)) {
				上传-文件到远程 -本地路径 $本地附加压缩包路径 -连接目标 $连接目标 -端口 $端口 -远程路径 ('./{0}' -f $远程附加压缩包文件名)
			}
			执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\{0}"' -f $远程临时脚本文件名) -TTY
		} finally {
			if (Test-Path $本地临时脚本路径) {
				Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			}

			try {
				执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('del /q "%USERPROFILE%\{0}" 2>nul' -f $远程临时脚本文件名)
			} catch {
			}
		}
	}

	# ===== 主流程 =====

	$ErrorActionPreference = 'Stop'
	$本地信息 = 取-本地VSCode信息 -指定版本 $本地版本
	$连接目标 = 取-SSH连接目标 -主机 $远程主机 -账户 $远程账户
	$本地附加压缩包路径 = $null
	$远程附加压缩包文件名 = $null

	Write-Host ('本机自动检测到的 VS Code 命令: {0}' -f $本地信息.命令路径)
	Write-Host ('本机自动检测到的发布通道: {0}' -f $本地信息.发布通道)
	Write-Host ('本机自动检测到的提交号: {0}' -f $本地信息.提交号)
	Write-Host ('远程连接目标: {0}' -f $连接目标)

	# 选择远程脚本
	$远程安装脚本 = 选择-远程脚本 -连接目标 $连接目标 -端口 $SSH端口 -指定版本 $远程脚本版本
	if ($远程安装脚本 -eq $script:远程脚本_Win7) {
		$本地附加压缩包路径 = 下载-本地服务器压缩包 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号 -架构 'win32-x64'
		$远程附加压缩包文件名 = 'vscode-server-upload-temp.zip'
	}

	# 替换占位符
	$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
	$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)
	$远程安装脚本 = $远程安装脚本.Replace('__轮询秒数__', [string]$轮询秒数)
	$远程安装脚本 = $远程安装脚本.Replace('__最大恢复次数__', [string]$最大恢复次数)
	$远程安装脚本 = $远程安装脚本.Replace('__超时秒数__', [string]$超时秒数)

	执行-远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本 -本地附加压缩包路径 $本地附加压缩包路径 -远程附加压缩包文件名 $远程附加压缩包文件名
}

# 导出公共函数
Export-ModuleMember -Function '安装-VSCode远程服务'
