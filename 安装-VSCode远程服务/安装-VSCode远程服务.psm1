# 安装-VSCode远程服务 Module
# 通过 SSH 与 BITS 在远程 Windows 主机上安装 VS Code Server

# 加载私有远程脚本模板
$script:模块根目录 = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:远程脚本_通用 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-通用.ps1') -Raw -Encoding UTF8
$script:远程脚本_Win7 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Win7.ps1') -Raw -Encoding UTF8
$script:远程脚本_Linux = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Linux.sh') -Raw -Encoding UTF8

# SSH 密码复用状态（由 初始化-SSH会话 设置）
$script:SSH密码选项 = @()
$script:密码已注入 = $false

function 安装-VSCode远程服务 {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0)]
		[Alias('目标服务器', '计算机名', 'IP', '主机')]
		[string]$远程主机,

		[string]$远程账户,

		# 0 表示未指定：将优先采用 ~/.ssh/config 中匹配到的 Port，仍无则用 22
		[int]$SSH端口 = 0,

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

	function 测试-通配符匹配 {
		param(
			[string]$模式,
			[string]$目标
		)

		# ssh 的 Host 模式支持 * 与 ? 通配符，转为正则后做整串匹配（大小写不敏感由 -match 默认行为保证）
		$正则 = '^' + [regex]::Escape($模式).Replace('\*', '.*').Replace('\?', '.') + '$'
		return $目标 -match $正则
	}

	function 取-SSH配置中的连接信息 {
		param(
			[string]$主机,
			[int]$用户指定端口
		)

		# 模拟 ssh 解析 ~/.ssh/config：直接传裸 IP/主机名时，ssh 自身的 Host 匹配只认命令行输入的别名，会导致用户名回退为本机用户。这里额外按 HostName 指令反查（也兼容 Host 通配符模式），让“主机 → 账户/端口”能从配置中查回，多块命中时遵循 ssh“同一关键字首个值生效”的合并规则。
		$配置文件路径 = Join-Path $env:USERPROFILE '.ssh\config'
		if (-not (Test-Path $配置文件路径)) {
			return [pscustomobject]@{ 用户 = ''; 端口 = 0 }
		}

		$块列表 = New-Object System.Collections.ArrayList
		$当前块 = $null
		foreach ($原始行 in (Get-Content $配置文件路径 -Encoding UTF8)) {
			$行 = $原始行.Trim()
			if ($行 -eq '' -or $行.StartsWith('#')) { continue }

			if ($行 -match '^([^=\s]+)\s*=\s*(.*)$') {
				$关键字 = $Matches[1]
				$参数 = $Matches[2].Trim()
			} elseif ($行 -match '^(\S+)\s+(.*)$') {
				$关键字 = $Matches[1]
				$参数 = $Matches[2].Trim()
			} else {
				continue
			}

			if ($关键字 -ieq 'Match') {
				# Match 块的条件由 ssh 运行时求值，无法本地模拟，保守地忽略其下指令，避免误取配置
				$当前块 = $null
				continue
			}

			if ($关键字 -ieq 'Host') {
				if ($null -ne $当前块) { [void]$块列表.Add($当前块) }
				$当前块 = @{ 模式列表 = @($参数 -split '\s+'); 主机名 = ''; 端口 = 0; 用户 = '' }
				continue
			}

			if ($null -eq $当前块) { continue }

			# ssh 语义：同一关键字首个出现的值生效
			if ($关键字 -ieq 'HostName' -and $当前块.主机名 -eq '') {
				$当前块.主机名 = $参数
			} elseif ($关键字 -ieq 'Port' -and $当前块.端口 -eq 0 -and $参数 -match '^\d+$') {
				$当前块.端口 = [int]$参数
			} elseif ($关键字 -ieq 'User' -and $当前块.用户 -eq '') {
				$当前块.用户 = $参数
			}
		}

		if ($null -ne $当前块) { [void]$块列表.Add($当前块) }

		$结果用户 = ''
		$结果端口 = 0
		foreach ($块 in $块列表) {
			# ssh 模式语义：任一否定模式（!开头）命中则整块排除；否则任一肯定模式命中即匹配；
			# 扩展点：HostName 指令与目标主机精确相等也视为命中（这是本机回退问题的修复核心）
			$被排除 = $false
			$正向命中 = $false
			foreach ($模式 in $块.模式列表) {
				if ($模式.StartsWith('!')) {
					if (测试-通配符匹配 -模式 $模式.Substring(1) -目标 $主机) { $被排除 = $true; break }
				} elseif (测试-通配符匹配 -模式 $模式 -目标 $主机) {
					$正向命中 = $true
				}
			}

			if ($被排除) { continue }
			if (-not ($正向命中 -or ($块.主机名 -ieq $主机))) { continue }

			# 用户已显式指定端口时，只接受未限定端口或端口一致的块，避免跨服务串账户
			if ($用户指定端口 -ne 0 -and $块.端口 -ne 0 -and $块.端口 -ne $用户指定端口) { continue }

			if ($结果用户 -eq '' -and $块.用户 -ne '') { $结果用户 = $块.用户 }
			if ($结果端口 -eq 0 -and $块.端口 -ne 0) { $结果端口 = $块.端口 }
			if ($结果用户 -ne '' -and $结果端口 -ne 0) { break }
		}

		return [pscustomobject]@{ 用户 = $结果用户; 端口 = $结果端口 }
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

	function 取-环境探测命令 {
		# 单条跨 shell 兼容（sh / cmd / PowerShell 5.1）的多行探测命令：每行在不适用的平台上要么输出可识别的垃圾、要么报非致命错误，解析端按标记筛选。
		# 行序有讲究：Windows 关键行在前（PowerShell 默认 shell 若配置文件设了 EAP=Stop，不存在的命令会终止后续行，此时 Linux 专用行丢失也无妨），Linux 关键行在后
		return @'
echo HOMEDIR_CMD=%USERPROFILE%
powershell -NoProfile -Command "Write-Output $PSVersionTable.PSVersion.Major"
powershell -NoProfile -Command "Write-Output $env:USERPROFILE"
uname -s
printf 'HOMEDIR_SH=%s\n' "$HOME"
echo PROBE_END
'@
	}

	function 解析-环境报告 {
		param(
			[string[]]$输出
		)

		$系统类型 = 'Windows'
		$登录目录 = ''
		$PS主版本 = $null
		foreach ($原始行 in $输出) {
			$行 = ([string]$原始行).Trim()
			if ($行 -eq 'Linux') {
				$系统类型 = 'Linux'
				continue
			}

			# 注意：-match 会覆盖 $Matches，故捕获组必须在本分支内立即取出到变量后再做后续判断
			if ($行 -match '^HOMEDIR_SH=(.+)$') {
				$候选 = $Matches[1].Trim()
				if ($系统类型 -eq 'Linux' -and $登录目录 -eq '' -and $候选.StartsWith('/')) {
					$登录目录 = $候选.TrimEnd('/')
				}
				continue
			}

			if ($行 -match '^HOMEDIR_CMD=(.+)$') {
				$候选 = $Matches[1].Trim()
				if ($系统类型 -eq 'Windows' -and $登录目录 -eq '' -and $候选 -match '[\\/]' -and $候选 -notmatch '[%$]') {
					$登录目录 = $候选.TrimEnd('\', '/')
				}
				continue
			}

			# Windows 默认 shell 为 PowerShell 时，探测命令中的 powershell 行直接输出裸路径（无标记前缀），按 Windows 路径形态识别
			if ($系统类型 -eq 'Windows' -and $登录目录 -eq '' -and $行 -match '^[A-Za-z]:\\') {
				$登录目录 = $行.TrimEnd('\', '/')
				continue
			}

			if ($系统类型 -eq 'Windows' -and $null -eq $PS主版本 -and $行 -match '^\d+$') {
				$PS主版本 = [int]$行
			}
		}

		$完整 = if ($系统类型 -eq 'Linux') { $登录目录 -ne '' } else { ($登录目录 -ne '') -and ($null -ne $PS主版本) }

		return [pscustomobject]@{
			系统类型 = $系统类型
			登录目录 = $登录目录
			PS主版本 = $PS主版本
			完整 = $完整
		}
	}

	function 执行-环境探测 {
		param(
			[string]$连接目标,
			[int]$端口,
			[switch]$免密模式
		)

		# 一次 SSH 调用完成全部环境试探；认证失败（退出码 255）返回 $null 由调用方进入密码收集流程
		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法探测远程环境。'
		}

		$ssh参数 = @('-n', '-p', $端口) + $script:SSH密码选项
		if ($免密模式) { $ssh参数 += @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10') }
		# 探测命令必须用 LF 行尾：本模块文件以 CRLF 保存，here-string 会带上 \r，远端 sh 会把行尾的 \r 当成命令的一部分（如 uname -s\r 报 invalid option），导致关键输出行丢失
		$ssh参数 += @($连接目标, ((取-环境探测命令) -replace "`r`n", "`n"))

		# PS 5.1 下原生命令 stderr 一旦被重定向即变终止性错误，捕获期间临时切 Continue 并在 finally 恢复；不重定向时探测命令的多平台垃圾行会污染控制台，故此处选择捕获
		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			$输出 = @(& $ssh命令.Source $ssh参数 2>&1)
		} finally {
			$ErrorActionPreference = $原始EAP
		}

		if ($LASTEXITCODE -eq 255) {
			return $null
		}

		return (解析-环境报告 -输出 $输出)
	}

	function 补全-环境报告 {
		param(
			[pscustomobject]$报告,
			[string]$连接目标,
			[int]$端口
		)

		# 探测报告不完整时（如远程 shell 行为异常）退回逐项试探，保证正确性优先于连接次数
		if ($报告.完整) {
			return $报告
		}

		Write-Host '环境探测报告不完整，退回逐项试探。'
		$系统类型 = 探测-远程系统类型 -连接目标 $连接目标 -端口 $端口
		$登录目录 = if ($报告.登录目录 -ne '') { $报告.登录目录 } else { 取-远程登录目录 -连接目标 $连接目标 -端口 $端口 -远程系统类型 $系统类型 }
		$PS主版本 = $报告.PS主版本
		if ($系统类型 -eq 'Windows' -and $null -eq $PS主版本) {
			$PS主版本 = 探测-远程PS版本 -连接目标 $连接目标 -端口 $端口
		}

		return [pscustomobject]@{
			系统类型 = $系统类型
			登录目录 = $登录目录
			PS主版本 = $PS主版本
			完整 = $true
		}
	}

	function 初始化-SSH会话 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		$script:SSH密码选项 = @()
		$script:密码已注入 = $false

		# 免密探测与环境试探合并为同一次连接：成功即同时拿到免密结论与完整环境报告
		$报告 = 执行-环境探测 -连接目标 $连接目标 -端口 $端口 -免密模式
		if ($null -ne $报告) {
			Write-Host '检测到远程主机已配置免密登录，无需输入密码。'
			return (补全-环境报告 -报告 $报告 -连接目标 $连接目标 -端口 $端口)
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

		# 密码注入后的第一次连接同样兼作环境试探，避免为试探再单独连一次
		$报告 = 执行-环境探测 -连接目标 $连接目标 -端口 $端口
		if ($null -eq $报告) {
			清除-SSH密码复用
			throw ('SSH 认证失败：{0} 拒绝了所提供的密码。' -f $连接目标)
		}

		Write-Host '密码已收集，后续所有 SSH/SCP 操作将自动复用，无需再次输入。'
		return (补全-环境报告 -报告 $报告 -连接目标 $连接目标 -端口 $端口)
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

		$scp参数 = @('-P', $端口) + $script:SSH密码选项 + @($本地路径, ('{0}:{1}' -f $连接目标, $远程路径))

		# PS 5.1 下原生命令的 stderr 一旦被重定向就会变成终止性错误，因此探测与捕获期间临时切换为 Continue，并在 finally 中恢复
		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			# 默认走 SFTP 协议上传
			& $SCP命令.Source $scp参数 2>&1 | Out-Null
		} finally {
			$ErrorActionPreference = $原始EAP
		}

		if ($LASTEXITCODE -eq 0) {
			return
		}

		# SFTP 协议失败时，远端常只给出模糊的 "close remote: Failure"，掩盖真实原因（实测它对应的往往是 Linux 端的 "Disk quota exceeded"）；经典 SCP 协议（-O）会把远端真实错误原样回显。用它补传一次：成功则上传就此完成；仍失败则取其输出作为直白的报错依据
		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			$诊断输出 = @(& $SCP命令.Source (@('-O') + $scp参数) 2>&1)
		} finally {
			$ErrorActionPreference = $原始EAP
		}

		if ($LASTEXITCODE -eq 0) {
			return
		}

		$远端错误 = ($诊断输出 | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join "`n"

		# 空间不足类错误额外指明出问题的目标路径（含主机）与要上传的文件大小，便于定位是哪台机器的哪个路径空间不足、需要腾出多少空间
		if ($远端错误 -match 'quota exceeded|No space left|空间不足|磁盘已满|配额') {
			$文件信息 = Get-Item -LiteralPath $本地路径 -ErrorAction SilentlyContinue
			$大小显示 = if ($null -ne $文件信息) { ('{0} 字节' -f $文件信息.Length) } else { '未知' }
			throw ('SCP 上传失败，退出码: {0}。上传到目标路径 {1}:{2} 时远端空间不足，要上传的文件大小为 {3}。{4}{5}' -f $LASTEXITCODE, $连接目标, $远程路径, $大小显示, "`n", $远端错误)
		}

		throw ('SCP 上传失败，退出码: {0}。{1}{2}' -f $LASTEXITCODE, "`n", $远端错误)
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
		# -n 将 stdin 重定向为 NUL：老版 sshd（如 Win7 自带）在远程命令结束后仍会等待 stdin 关闭才断开会话，不加 -n 会永久挂起
		try {
			$输出 = & $ssh命令.Source (@('-n', '-p', $端口) + $script:SSH密码选项 + @($连接目标, 'uname -s'))
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

	function 取-远程登录目录 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$远程系统类型
		)

		# 取远程登录目录（scp 相对路径的基准目录），用于把上传目标拼成绝对路径，报错时能指明完整目标路径
		$查询命令 = if ($远程系统类型 -eq 'Linux') {
			'printf %s "$HOME"'
		} else {
			'powershell -NoProfile -Command "Write-Output $env:USERPROFILE"'
		}

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			return ''
		}

		# 解析失败属可降级场景，返回空串由调用方退回相对路径，故不抛错
		# -n 避免老版 sshd（如 Win7）在命令结束后等待 stdin 而挂起
		try {
			$输出 = @(& $ssh命令.Source (@('-n', '-p', $端口) + $script:SSH密码选项 + @($连接目标, $查询命令)))
		} catch {
			return ''
		}

		if ($LASTEXITCODE -ne 0) {
			return ''
		}

		# 取最后一个非空行：登录横幅等杂项输出在前，真实目录在命令输出末尾
		for ($序号 = $输出.Count - 1; $序号 -ge 0; $序号--) {
			$文本 = ([string]$输出[$序号]).Trim().TrimEnd('/', '\')
			if (-not [string]::IsNullOrWhiteSpace($文本)) {
				return $文本
			}
		}

		return ''
	}

	function 探测-远程PS版本 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		# -n 避免老版 sshd（如 Win7）在命令结束后等待 stdin 而挂起
		$输出 = & (Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1).Source (@('-n', '-p', $端口) + $script:SSH密码选项 + @($连接目标, 'powershell -NoProfile -Command "Write-Output $PSVersionTable.PSVersion.Major"'))
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
			[int]$PS主版本
		)

		# 一律自动探测：按远程 PowerShell 版本决定使用 Win7 兼容版还是通用版
		if ($PS主版本 -le 2) {
			Write-Host ('检测到远程 PowerShell {0}.0，使用 Win7 适配版远程脚本。' -f $PS主版本)
			return $script:远程脚本_Win7
		} else {
			Write-Host ('检测到远程 PowerShell {0}.0，使用通用版远程脚本。' -f $PS主版本)
			return $script:远程脚本_通用
		}
	}

	function 执行-远程安装脚本 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$脚本文本,
			[string]$本地附加压缩包路径,
			[string]$远程附加压缩包文件名,
			[string]$远程登录目录
		)

		$本地临时脚本路径 = Join-Path $env:TEMP ('临时安装-VSCode远程服务-{0}.ps1' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本文件名 = 'vscode-server-install-temp.ps1'
		# 已知远程登录目录时上传目标用绝对路径，报错可直接显示完整目标路径；否则退回登录目录下的相对路径
		$远程路径前缀 = if ([string]::IsNullOrWhiteSpace($远程登录目录)) { './' } else { $远程登录目录.TrimEnd('\', '/') + '\' }
		$远程临时脚本路径 = $远程路径前缀 + $远程临时脚本文件名

		try {
			[System.IO.File]::WriteAllText($本地临时脚本路径, $脚本文本, [System.Text.UTF8Encoding]::new($true))
			上传-文件到远程 -本地路径 $本地临时脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程临时脚本路径
			if (-not [string]::IsNullOrWhiteSpace($本地附加压缩包路径) -and -not [string]::IsNullOrWhiteSpace($远程附加压缩包文件名)) {
				上传-文件到远程 -本地路径 $本地附加压缩包路径 -连接目标 $连接目标 -端口 $端口 -远程路径 ($远程路径前缀 + $远程附加压缩包文件名)
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
			[string]$脚本文本,
			[string]$远程登录目录
		)

		$本地临时脚本路径 = Join-Path $env:TEMP ('临时安装-VSCode远程服务-{0}.sh' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本文件名 = 'vscode-server-install-temp.sh'
		# 已知远程登录目录时上传目标用绝对路径，报错可直接显示完整目标路径；否则退回登录目录下的相对路径
		$远程路径前缀 = if ([string]::IsNullOrWhiteSpace($远程登录目录)) { './' } else { $远程登录目录.TrimEnd('\', '/') + '/' }
		$远程临时脚本路径 = $远程路径前缀 + $远程临时脚本文件名

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

	# 裸 IP/主机名不允许回退本机用户名：先从 ~/.ssh/config 反查该主机对应的账户与端口。若用户已内嵌账户（如 user@host）或显式给了 -远程账户，则以用户输入为准
	$SSH配置信息 = 取-SSH配置中的连接信息 -主机 $远程主机 -用户指定端口 $SSH端口
	if ([string]::IsNullOrWhiteSpace($远程账户) -and $远程主机 -notmatch '@' -and $SSH配置信息.用户 -ne '') {
		Write-Host ('已从 ~/.ssh/config 解析到该主机的登录账户: {0}' -f $SSH配置信息.用户)
		$远程账户 = $SSH配置信息.用户
	}

	if ($SSH端口 -eq 0) {
		$SSH端口 = if ($SSH配置信息.端口 -gt 0) { $SSH配置信息.端口 } else { 22 }
		Write-Host ('使用 SSH 端口: {0}' -f $SSH端口)
	}

	$连接目标 = 取-SSH连接目标 -主机 $远程主机 -账户 $远程账户
	$本地附加压缩包路径 = $null
	$远程附加压缩包文件名 = $null

	# 认证与环境试探合并：免密主机一次连接拿到全部环境信息；需密码主机在密码注入后的第一次连接拿到
	$环境 = 初始化-SSH会话 -连接目标 $连接目标 -端口 $SSH端口

	Write-Host ('本机自动检测到的 VS Code 命令: {0}' -f $本地信息.命令路径)
	Write-Host ('本机自动检测到的发布通道: {0}' -f $本地信息.发布通道)
	Write-Host ('本机自动检测到的提交号: {0}' -f $本地信息.提交号)
	Write-Host ('远程连接目标: {0}' -f $连接目标)
	Write-Host ('远程系统类型: {0}' -f $环境.系统类型)
	if ([string]::IsNullOrWhiteSpace($环境.登录目录)) {
		Write-Host '未能解析远程登录目录，上传目标将使用相对路径。'
	} else {
		Write-Host ('远程登录目录: {0}' -f $环境.登录目录)
	}

	if ($环境.系统类型 -eq 'Linux') {
		# Linux 远程主机直接走 sh 安装流程
		$远程安装脚本 = $script:远程脚本_Linux
		$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
		$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)

		执行-Linux远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本 -远程登录目录 $环境.登录目录
		清除-SSH密码复用
		return
	}

	# Windows 远程主机：一律自动探测脚本版本（按远程 PowerShell 版本选择）
	$远程安装脚本 = 选择-远程脚本 -PS主版本 $环境.PS主版本
	if ($远程安装脚本 -eq $script:远程脚本_Win7) {
		$本地附加压缩包路径 = 下载-本地服务器压缩包 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号 -架构 'win32-x64'
		$远程附加压缩包文件名 = 'vscode-server-upload-temp.zip'
	}

	# 替换占位符
	$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
	$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)

	执行-远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本 -本地附加压缩包路径 $本地附加压缩包路径 -远程附加压缩包文件名 $远程附加压缩包文件名 -远程登录目录 $环境.登录目录
	清除-SSH密码复用
}

# 导出公共函数
Export-ModuleMember -Function '安装-VSCode远程服务'
