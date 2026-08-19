# 安装-VSCode远程服务 Module
# 通过 SSH 与 BITS 在远程 Windows 主机上安装 VS Code Server

# 加载私有远程脚本模板
$script:模块根目录 = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:远程脚本_通用 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-通用.ps1') -Raw -Encoding UTF8
$script:远程脚本_Win7 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Win7.ps1') -Raw -Encoding UTF8
$script:远程脚本_Linux = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Linux.sh') -Raw -Encoding UTF8

# SSH 密码复用状态（由 初始化-SSH密码复用 设置）
$script:SSH密码选项 = @()
$script:密码已注入 = $false

function 安装-VSCode远程服务 {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0)]
		[Alias('目标服务器', '计算机名', 'IP', '主机')]
		[string]$远程主机,

		[string]$远程账户,

		[int]$SSH端口 = 22,

		[ValidateSet('预览版', '稳定版')]
		[string]$本地版本
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

			# --version 失败属于预期情况（命令存在但无法执行或输出格式不符），
			# 其 stderr 在 PS 5.1 下会被提升为终止性错误，此处静默捕获并返回 $null，不影响后续版本探测逻辑
			try {
				$版本输出 = & $命令路径 --version
				if ($LASTEXITCODE -ne 0 -or $版本输出.Count -lt 2) {
					return $null
				}
			} catch {
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

	function 初始化-SSH密码复用 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		$script:SSH密码选项 = @()
		$script:密码已注入 = $false

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}

		# 先用 BatchMode 探测：免密（密钥/agent）可直接成功；需要密码时会立即失败。
		# 探测命令必须用 'exit 0' 而非 'true'：Windows 远程主机（无论默认 shell 是 cmd 还是 PowerShell）
		# 都没有 true 命令，会导致认证虽成功但命令退出码非 0，被误判为需要密码。'exit 0' 在
		# PowerShell、cmd、bash/sh 下均是合法且退出码为 0 的命令。
		# 注意：此处绝不能对 stderr 做任何重定向（2>$null / 2>&1）。外层作用域 EAP=Stop 时，
		# 一旦被重定向，stderr 的每一行（如 CNAME 警告）都会被提升为 NativeCommandError 终止性错误，
		# 被 catch 误判为认证失败而错误进入密码收集流程。不重定向让 stderr 直达控制台（与手动 ssh 行为一致），仅凭 $LASTEXITCODE 判断。
		try {
			& $ssh命令.Source '-p' $端口 '-o' 'BatchMode=yes' '-o' 'ConnectTimeout=10' $连接目标 'exit 0' | Out-Null
			if ($LASTEXITCODE -eq 0) {
				Write-Host '检测到远程主机已配置免密登录，无需输入密码。'
				return
			}
		} catch {
			# 仅捕获 ssh 无法启动等真正异常；BatchMode 下密码认证失败以非 0 退出码体现，由下面流程处理
		}

		# 需要密码：交互收集一次，之后通过 SSH_ASKPASS 注入到后续每次 ssh/scp 调用
		$安全密码 = Read-Host ('请输入 {0} 的 SSH 密码（仅本次会话使用，不会保存）' -f $连接目标) -AsSecureString
		$密码指针 = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($安全密码)
		try {
			$明文密码 = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($密码指针)
		} finally {
			[System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($密码指针)
		}

		if ([string]::IsNullOrEmpty($明文密码)) {
			throw '密码不能为空。'
		}

		# SSH_ASKPASS 协议要求一个可执行程序：ssh 需要密码时执行它并把 stdout 第一行当作密码。
		# 密码本体只保存在当前进程的环境变量中（不写盘），模块自带的 bat 负责把该环境变量打印出来。
		$env:VSCODE_SSH密码 = $明文密码
		$env:SSH_ASKPASS = Join-Path $script:模块根目录 'private\SSH密码回显.bat'
		$env:SSH_ASKPASS_REQUIRE = 'force'
		# 注意：不要加 BatchMode=yes——它会禁用 askpass 机制，导致密码无法注入
		$script:SSH密码选项 = @()
		$script:密码已注入 = $true

		Write-Host '密码已收集，后续所有 SSH/SCP 操作将自动复用，无需再次输入。'
	}

	function 清除-SSH密码复用 {
		# 清理敏感状态（无害清理，逐条容错）
		if ($script:密码已注入) {
			Remove-Item Env:VSCODE_SSH密码 -ErrorAction SilentlyContinue
			Remove-Item Env:SSH_ASKPASS -ErrorAction SilentlyContinue
			Remove-Item Env:SSH_ASKPASS_REQUIRE -ErrorAction SilentlyContinue
			$script:密码已注入 = $false
		}
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

		$ssh参数 = @('-p', $端口) + $script:SSH密码选项
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
			throw '未找到 scp 命令。请确保已安装 OpenSSH 客户端。'
		}

		& $SCP命令.Source (@('-P', $端口) + $script:SSH密码选项 + @($本地路径, ('{0}:{1}' -f $连接目标, $远程路径)))
		if ($LASTEXITCODE -ne 0) {
			throw ('SCP 上传失败，退出码: {0}。请检查网络连接与远程主机权限。' -f $LASTEXITCODE)
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
			try {
				Invoke-WebRequest -Uri $下载地址 -OutFile $本地压缩包路径 -UseBasicParsing
			} catch {
				throw ('本机下载 VS Code Server 压缩包失败: {0}' -f $_.Exception.Message)
			}
		}

		if (-not (Test-Path $本地压缩包路径)) {
			throw ('本机下载完成后未找到压缩包: {0}' -f $本地压缩包路径)
		}

		return $本地压缩包路径
	}

	function 探测-远程系统类型 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法探测远程系统类型。'
		}

		# Windows 远程主机的默认 shell（cmd）没有 uname 命令，只有 Linux 会原样输出内核名。
		# Windows 主机执行 uname 必失败，其 stderr 在 PS 5.1 下会被提升为终止性错误，
		# 此处静默捕获并视为 Windows，这是预期的判别路径，不影响功能
		try {
			$输出 = & $ssh命令.Source (@('-p', $端口) + $script:SSH密码选项 + @($连接目标, 'uname -s'))
			if ($LASTEXITCODE -eq 0 -and @($输出 | Where-Object { $_ -and $_.Trim() -eq 'Linux' }).Count -gt 0) {
				Write-Host '检测到远程系统类型: Linux'
				return 'Linux'
			}

			# uname 执行失败但认证已通过（LASTEXITCODE 非 0 但不是认证问题），视为 Windows
			# 认证失败的退出码通常是 255，且伴随 Permission denied；此处简化处理：非 0 即 Windows
			Write-Host '检测到远程系统类型: Windows'
			return 'Windows'
		} catch {
			# 已知且无害：Windows 无 uname 命令，失败即代表远程是 Windows
			Write-Host '检测到远程系统类型: Windows'
			return 'Windows'
		}
	}

	function 探测-远程PS版本 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		$输出 = & (Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1).Source (@('-p', $端口) + $script:SSH密码选项 + @($连接目标, 'powershell -NoProfile -Command "Write-Output $PSVersionTable.PSVersion.Major"'))
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

		throw '无法从远程主机获取 PowerShell 版本。请确认远程主机已安装 PowerShell 且可通过 SSH 执行。'
	}

	function 选择-远程脚本 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		# 一律自动探测：按远程 PowerShell 版本决定使用 Win7 兼容版还是通用版
		$远程PS版本 = 探测-远程PS版本 -连接目标 $连接目标 -端口 $端口
		if ($远程PS版本 -le 2) {
			Write-Host ('检测到远程 PowerShell {0}.0，使用 Win7 适配版远程脚本。' -f $远程PS版本)
			return $script:远程脚本_Win7
		} else {
			Write-Host ('检测到远程 PowerShell {0}.0，使用通用版远程脚本。' -f $远程PS版本)
			return $script:远程脚本_通用
		}
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
			# 清理临时文件（无害操作，失败不影响主流程）
			if (Test-Path $本地临时脚本路径) {
				Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			}

			try {
				# 远程默认 shell 可能是 PowerShell 也可能是 cmd，cmd 专属语法（del、2>nul）在 PowerShell 下会报错，
				# 统一用 powershell 包装，两种 shell 下都能正确执行且静默失败
				执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('powershell -NoProfile -Command "Remove-Item $env:USERPROFILE\{0} -Force -ErrorAction SilentlyContinue"' -f $远程临时脚本文件名)
			} catch {
				# 远程清理失败不影响主流程，临时文件会被系统定期清理
			}
		}
	}

	function 执行-Linux远程安装脚本 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$脚本文本
		)

		$本地临时脚本路径 = Join-Path $env:TEMP ('临时安装-VSCode远程服务-{0}.sh' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本文件名 = 'vscode-server-install-temp.sh'
		$远程临时脚本路径 = ('./{0}' -f $远程临时脚本文件名)

		try {
			# Linux sh 脚本要求 LF 行尾，且不得带 BOM，否则 shebang 与语法会出错
			$脚本文本 = $脚本文本 -replace "`r`n", "`n"
			[System.IO.File]::WriteAllText($本地临时脚本路径, $脚本文本, [System.Text.UTF8Encoding]::new($false))
			上传-文件到远程 -本地路径 $本地临时脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程临时脚本路径
			执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('sh ~/{0}' -f $远程临时脚本文件名) -TTY
		} finally {
			# 清理临时文件（无害操作，失败不影响主流程）
			if (Test-Path $本地临时脚本路径) {
				Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			}

			try {
				执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('rm -f ~/{0}' -f $远程临时脚本文件名)
			} catch {
				# 远程清理失败不影响主流程，临时文件会被系统定期清理
			}
		}
	}

	# ===== 主流程 =====

	$ErrorActionPreference = 'Stop'
	$本地信息 = 取-本地VSCode信息 -指定版本 $本地版本
	$连接目标 = 取-SSH连接目标 -主机 $远程主机 -账户 $远程账户
	$本地附加压缩包路径 = $null
	$远程附加压缩包文件名 = $null

	# 检测是否免密；需要密码时收集一次并注入 SSH_ASKPASS，后续调用自动复用
	初始化-SSH密码复用 -连接目标 $连接目标 -端口 $SSH端口

	Write-Host ('本机自动检测到的 VS Code 命令: {0}' -f $本地信息.命令路径)
	Write-Host ('本机自动检测到的发布通道: {0}' -f $本地信息.发布通道)
	Write-Host ('本机自动检测到的提交号: {0}' -f $本地信息.提交号)
	Write-Host ('远程连接目标: {0}' -f $连接目标)

	# 自动检测远程系统类型
	$远程系统类型 = 探测-远程系统类型 -连接目标 $连接目标 -端口 $SSH端口

	if ($远程系统类型 -eq 'Linux') {
		# Linux 远程主机直接走 sh 安装流程
		$远程安装脚本 = $script:远程脚本_Linux
		$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
		$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)

		执行-Linux远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本
		清除-SSH密码复用
		return
	}

	# Windows 远程主机：一律自动探测脚本版本（按远程 PowerShell 版本选择）
	$远程安装脚本 = 选择-远程脚本 -连接目标 $连接目标 -端口 $SSH端口
	if ($远程安装脚本 -eq $script:远程脚本_Win7) {
		$本地附加压缩包路径 = 下载-本地服务器压缩包 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号 -架构 'win32-x64'
		$远程附加压缩包文件名 = 'vscode-server-upload-temp.zip'
	}

	# 替换占位符
	$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
	$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)

	执行-远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本 -本地附加压缩包路径 $本地附加压缩包路径 -远程附加压缩包文件名 $远程附加压缩包文件名
	清除-SSH密码复用
}

# 导出公共函数
Export-ModuleMember -Function '安装-VSCode远程服务'
