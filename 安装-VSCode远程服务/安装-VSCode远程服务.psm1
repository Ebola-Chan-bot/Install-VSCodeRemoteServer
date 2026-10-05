# 安装-VSCode远程服务 Module
# 通过 SSH 与 BITS 在远程 Windows 主机上安装 VS Code Server

# 加载私有远程脚本模板
$script:模块根目录 = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:远程脚本_通用 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-通用.ps1') -Raw -Encoding UTF8
$script:远程脚本_Win7 = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Win7.ps1') -Raw -Encoding UTF8
$script:远程脚本_Linux = Get-Content -Path (Join-Path $script:模块根目录 'private\远程安装脚本-Linux.sh') -Raw -Encoding UTF8
$script:脚本_sysroot部署 = Get-Content -Path (Join-Path $script:模块根目录 'private\sysroot部署脚本.sh') -Raw -Encoding UTF8
$script:脚本_原生组件补丁 = Get-Content -Path (Join-Path $script:模块根目录 'private\原生组件补丁脚本.sh') -Raw -Encoding UTF8
$script:脚本_服务保活部署 = Get-Content -Path (Join-Path $script:模块根目录 'private\服务保活部署脚本.sh') -Raw -Encoding UTF8
$script:脚本_服务保活包装 = Get-Content -Path (Join-Path $script:模块根目录 'private\服务保活包装脚本.sh') -Raw -Encoding UTF8

# SSH 密码复用状态（由 初始化-SSH会话 设置）
$script:SSH密码选项 = @()
$script:密码已注入 = $false
# 远端输出中未闭合的 OSC 标题序列跨行跟踪标志（由 剥离-终端控制序列 使用）
$script:标题序列未闭合 = $false

function 剥离-终端控制序列 {
	param(
		[string]$文本
	)

	# 带 -TTY 分配 PTY 后，远端 Windows 控制台（conhost/PowerShell）会向输出流插入 VT 控制序列：清屏 ESC[2J、光标归零 ESC[H、藏/显光标、设窗口标题的 OSC 序列（内部可含换行且可跨行到达）。这些序列原样透传到本地终端会被照做执行，造成提前清屏、光标乱跳、逐字重影、行首大段空白等错位乱行。逐行转发前一律剥掉，只留纯文本。
	$结果 = New-Object System.Text.StringBuilder
	$位置 = 0
	while ($位置 -lt $文本.Length) {
		$字符 = $文本[$位置]
		if ($script:标题序列未闭合) {
			# 仍在 OSC 标题序列内部：整段丢弃直到终止符 BEL 或 ST(ESC\)
			if ($字符 -eq [char]7) {
				$script:标题序列未闭合 = $false
				$位置++
				continue
			}
			if ($字符 -eq [char]27) {
				# 可能是 ST，交给下方转义序列分支处理
				$script:标题序列未闭合 = $false
				continue
			}
			$位置++
			continue
		}
		if ($字符 -ne [char]27) {
			# 行内残留 CR 会让终端回车覆写同一行，一并丢弃
			if ($字符 -ne [char]13) { [void]$结果.Append($字符) }
			$位置++
			continue
		}
		# ESC 开头的序列
		if (($位置 + 1) -ge $文本.Length) {
			$位置++
			continue
		}
		$引导符 = $文本[$位置 + 1]
		if ($引导符 -eq '[') {
			# CSI 序列：ESC[ 参数字节(0x30-0x3F)* 中间字节(0x20-0x2F)* 终止字节(0x40-0x7E)
			$位置 += 2
			while ($位置 -lt $文本.Length -and [int][char]$文本[$位置] -ge 0x30 -and [int][char]$文本[$位置] -le 0x3F) { $位置++ }
			while ($位置 -lt $文本.Length -and [int][char]$文本[$位置] -ge 0x20 -and [int][char]$文本[$位置] -le 0x2F) { $位置++ }
			if ($位置 -lt $文本.Length) { $位置++ }
		} elseif ($引导符 -eq ']') {
			# OSC 序列：ESC]...BEL 或 ESC]...ST(ESC\)，可能被按行切分，闭合与否用标志跨调用跟踪
			$位置 += 2
			while ($位置 -lt $文本.Length) {
				if ($文本[$位置] -eq [char]7) { $位置++; break }
				if ($文本[$位置] -eq [char]27 -and ($位置 + 1) -lt $文本.Length -and $文本[$位置 + 1] -eq '\') { $位置 += 2; break }
				$位置++
			}
			if ($位置 -ge $文本.Length) { $script:标题序列未闭合 = $true }
		} else {
			# 两字符转义（ESC=、ESC> 等）：丢弃 ESC 与紧跟的一个字符
			$位置 += 2
		}
	}
	return $结果.ToString()
}

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
		[string]$本地版本,

		# 以下两个开关仅供本模块的公共入口 安装-VSCode服务保活 转发使用，对用户隐藏
		[Parameter(DontShow)]
		[switch]$仅服务保活,

		[Parameter(DontShow)]
		[switch]$移除服务保活
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
		# 单条跨 shell 兼容（sh / cmd / PowerShell 5.1）的多行探测命令：每行在不适用的平台上要么输出可识别的垃圾、要么报非致命错误，解析端按标记/值形态筛选。
		# 行序有讲究：Windows 关键行在前（PowerShell 默认 shell 若配置文件设了 EAP=Stop，不存在的命令会终止后续行，此时 Linux 专用行丢失也无妨），Linux 关键行在后
		# 硬约束：命令行内绝不得出现双引号与圆括号——PS 5.1 向原生命令传字符串参数时不转义内部双引号，远端收到时已被剥掉；剥掉后裸露的 ( 对远端 bash 是语法错误，会中止整段脚本导致后续所有关键行丢失（实测：含括号的 ARCH_PS 行让 Linux 主机报告退化为不完整，每次都回退逐项试探）。因此所有取值行都用裸值输出，由解析端按值形态识别（Linux 词汇 / Windows 大写架构名 / 盘符路径 / 纯数字）
		return @'
echo HOMEDIR_CMD=%USERPROFILE%
powershell -NoProfile -Command Write-Output $PSVersionTable.PSVersion.Major
powershell -NoProfile -Command Write-Output $env:USERPROFILE
powershell -NoProfile -Command Write-Output $env:PROCESSOR_ARCHITECTURE
uname -s
uname -m
printf 'HOMEDIR_SH=%s\n' $HOME
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
		$原始架构 = ''
		foreach ($原始行 in $输出) {
			$行 = ([string]$原始行).Trim()
			if ($行 -eq 'Linux') {
				$系统类型 = 'Linux'
				continue
			}

			# 裸架构行：Linux 侧来自 uname -m（x86_64/aarch64/armv7l 等，位于 Linux 行之后），Windows 侧来自 powershell 行输出的 %PROCESSOR_ARCHITECTURE% 值（AMD64/ARM64 等）。
			# -match 默认大小写不敏感；竞速按需，缺失只影响竞速是否启用，不影响报告完整性
			if ($原始架构 -eq '' -and $行 -match '^(x86_64|amd64|aarch64|arm64|armv7l|armv6l|armhf|arm|x86)$') {
				$原始架构 = $行
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
			原始架构 = $原始架构
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
		$探测结果 = 探测-远程系统类型 -连接目标 $连接目标 -端口 $端口
		$系统类型 = $探测结果.系统类型
		$登录目录 = if ($报告.登录目录 -ne '') { $报告.登录目录 } else { 取-远程登录目录 -连接目标 $连接目标 -端口 $端口 -远程系统类型 $系统类型 }
		$PS主版本 = $报告.PS主版本
		if ($系统类型 -eq 'Windows' -and $null -eq $PS主版本) {
			$PS主版本 = 探测-远程PS版本 -连接目标 $连接目标 -端口 $端口
		}

		# 合并探测拿到的架构优先；退回逐项试探时用逐项结果补齐（竞速依赖）
		$原始架构 = if ($报告.原始架构 -ne '') { $报告.原始架构 } else { $探测结果.原始架构 }

		return [pscustomobject]@{
			系统类型 = $系统类型
			登录目录 = $登录目录
			PS主版本 = $PS主版本
			原始架构 = $原始架构
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
			[switch]$TTY,
			[scriptblock]$每行回调
		)

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}

		$ssh参数 = @('-p', $端口) + $script:SSH密码选项
		if ($TTY) { $ssh参数 += '-t' }
		$ssh参数 += $连接目标
		$ssh参数 += $命令文本

		if ($每行回调) {
			# 流式转发并逐行回调（用于竞速判胜等事件监听）：Write-Host 保持原有的控制台实时输出；转发前剥离远端控制序列，避免本地终端照做执行造成乱行
			# PS 5.1 下原生命令 stderr 一旦被重定向即变终止性错误，捕获期间临时切 Continue 并在 finally 恢复
			$原始EAP = $ErrorActionPreference
			try {
				$ErrorActionPreference = 'Continue'
				$script:标题序列未闭合 = $false
				& $ssh命令.Source $ssh参数 2>&1 | ForEach-Object {
					$文本 = 剥离-终端控制序列 ([string]$_)
					Write-Host $文本
					& $每行回调 $文本
				}
			} finally {
				$ErrorActionPreference = $原始EAP
			}
		} else {
			# 无回调时同样逐行净化后转发（不能原样透传：远端控制序列会让本地终端清屏/跳光标）
			$原始EAP = $ErrorActionPreference
			try {
				$ErrorActionPreference = 'Continue'
				$script:标题序列未闭合 = $false
				& $ssh命令.Source $ssh参数 2>&1 | ForEach-Object {
					Write-Host (剥离-终端控制序列 ([string]$_))
				}
			} finally {
				$ErrorActionPreference = $原始EAP
			}
		}
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

	function 取-远程架构标识 {
		param(
			[string]$原始架构,
			[string]$系统类型
		)

		# 把探测到的原始架构（uname -m / %PROCESSOR_ARCHITECTURE%）映射为下载 artifact 使用的架构标识；无法识别返回空串（竞速不启用，远程单独下载）
		if ([string]::IsNullOrWhiteSpace($原始架构)) { return '' }
		if ($系统类型 -eq 'Linux') {
			switch -Regex ($原始架构.ToLowerInvariant()) {
				'^(x86_64|amd64)$' { return 'linux-x64' }
				'^(aarch64|arm64)$' { return 'linux-arm64' }
				'^(armv7l|armv6l|armhf|arm)$' { return 'linux-armhf' }
				default { return '' }
			}
		} else {
			switch ($原始架构.ToUpperInvariant()) {
				'AMD64' { return 'win32-x64' }
				'X64' { return 'win32-x64' }
				'ARM64' { return 'win32-arm64' }
				default { return '' }
			}
		}
	}

	function 初始化-竞速上下文 {
		param(
			[pscustomobject]$环境,
			[string]$发布通道,
			[string]$提交号
		)

		# 汇总竞速所需信息：暂存目录（登录目录下 .vscode-server[-insiders]/race-<提交号>）、包 artifact 名与下载地址。
		# 登录目录或架构无法确定时返回 $null，主流程将替换占位符为空串（远程脚本回退单独下载）
		if ([string]::IsNullOrWhiteSpace($环境.登录目录)) { return $null }
		$架构标识 = 取-远程架构标识 -原始架构 $环境.原始架构 -系统类型 $环境.系统类型
		if ($架构标识 -eq '') { return $null }

		$数据目录名 = if ($发布通道 -eq 'insider') { '.vscode-server-insiders' } else { '.vscode-server' }
		if ($环境.系统类型 -eq 'Linux') {
			$分隔符 = '/'
			$包扩展名 = '.tar.gz'
		} else {
			$分隔符 = '\'
			$包扩展名 = '.zip'
		}

		$暂存目录 = ($环境.登录目录.TrimEnd('/', '\') + $分隔符 + $数据目录名 + $分隔符 + ('race-{0}' -f $提交号))
		$包文件名 = ('vscode-server-{0}{1}' -f $架构标识, $包扩展名)
		$下载地址 = ('https://vscode.download.prss.microsoft.com/dbazure/download/{0}/{1}/{2}' -f $发布通道, $提交号, $包文件名)
		# 远程侧约定的包名与完成标记名（与远程脚本内的命名保持一致；标记带架构后缀防串包）
		$远程包名 = ('LOCAL{0}' -f $包扩展名)
		$完成标记名 = ('LOCAL_DONE.{0}' -f $架构标识)

		return [pscustomobject]@{
			暂存目录 = $暂存目录
			包扩展名 = $包扩展名
			包文件名 = $包文件名
			下载地址 = $下载地址
			提交号 = $提交号
			远程包名 = $远程包名
			完成标记名 = $完成标记名
			分隔符 = $分隔符
		}
	}

	function 启动-本地竞速供给 {
		param(
			[pscustomobject]$竞速上下文,
			[string]$连接目标,
			[int]$端口,
			[string]$系统类型
		)

		# 供给以独立子 powershell 进程运行（不再是 Start-Job 的同进程 runspace）：Start-Job 无法中断阻塞的网络调用，
		# 而子进程可在任意步骤被 taskkill /T /F 连同其派生的 ssh/scp 一起终止，实现真正的零轮询即时取消。
		# 参数经 Clixml 文件传入子进程（避开命令行转义与 PS 5.1 原生 stderr 陷阱）；stdout/stderr 重定向到日志文件，
		# 收尾时回收打印。返回 {进程;日志路径;错误路径;参数文件路径}。
		$参数文件 = Join-Path $env:TEMP ('race-supply-param-{0}.xml' -f ([guid]::NewGuid().ToString('N')))
		$日志文件 = Join-Path $env:TEMP ('race-supply-log-{0}.txt' -f ([guid]::NewGuid().ToString('N')))
		$错误文件 = Join-Path $env:TEMP ('race-supply-err-{0}.txt' -f ([guid]::NewGuid().ToString('N')))

		@{
			连接目标 = $连接目标
			端口 = $端口
			密码选项 = @($script:SSH密码选项)
			暂存目录 = $竞速上下文.暂存目录
			下载地址 = $竞速上下文.下载地址
			远程包名 = $竞速上下文.远程包名
			完成标记名 = $竞速上下文.完成标记名
			系统类型 = $系统类型
			分隔符 = $竞速上下文.分隔符
			提交号 = $竞速上下文.提交号
		} | Export-Clixml -LiteralPath $参数文件

		$供给脚本 = Join-Path $script:模块根目录 'private\本地竞速供给脚本.ps1'
		$powershell命令 = Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -First 1
		$powershellExe = if ($powershell命令) { $powershell命令.Source } else { 'powershell.exe' }

		$进程 = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $供给脚本), ('"{0}"' -f $参数文件)) -RedirectStandardOutput $日志文件 -RedirectStandardError $错误文件 -WindowStyle Hidden -PassThru

		return [pscustomobject]@{
			进程 = $进程
			日志路径 = $日志文件
			错误路径 = $错误文件
			参数文件路径 = $参数文件
		}
	}

	function 停止-供给进程树 {
		param(
			$供给
		)

		# 击杀供给进程树：taskkill /T 连同其派生的 ssh/scp 子进程一起终止；
		# PS 5.1 的 .NET Process.Kill() 只杀单进程不含子进程，更无法中断子进程内阻塞的下载/上传，故用 taskkill。
		if ($null -eq $供给 -or $null -eq $供给.进程) { return }
		$proc = $供给.进程
		try { $proc.Refresh() } catch { }
		if ($proc.HasExited) { return }
		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			$null = & taskkill.exe /PID $proc.Id /T /F 2>&1
		} finally {
			$ErrorActionPreference = $原始EAP
		}
	}

	function 等待-供给进程并回收日志 {
		param(
			$供给
		)

		# 收尾：兜底击杀残留供给进程树、等待退出、按 [本地供给] 前缀打印其日志，再删除临时文件（均失败无害）
		if ($null -eq $供给) { return }
		停止-供给进程树 -供给 $供给
		if ($null -ne $供给.进程) {
			try { $null = $供给.进程.WaitForExit(10000) } catch { }
		}
		foreach ($日志 in @($供给.日志路径, $供给.错误路径)) {
			if (-not [string]::IsNullOrWhiteSpace($日志) -and (Test-Path -LiteralPath $日志)) {
				Get-Content -LiteralPath $日志 | ForEach-Object { Write-Host ('[本地供给] {0}' -f $_) }
			}
		}
		foreach ($临时文件 in @($供给.日志路径, $供给.错误路径, $供给.参数文件路径)) {
			if (-not [string]::IsNullOrWhiteSpace($临时文件)) {
				Remove-Item -LiteralPath $临时文件 -Force -ErrorAction SilentlyContinue
			}
		}
	}

	function 清理-竞速暂存目录 {
		param(
			[pscustomobject]$竞速上下文,
			[string]$连接目标,
			[int]$端口,
			[string]$系统类型
		)

		# 收尾清理暂存目录（远程脚本正常结束已清理过，这里是异常退出情形的双保险；失败无害）
		$清理命令 = if ($系统类型 -eq 'Linux') {
			('rm -rf {0}' -f $竞速上下文.暂存目录)
		} else {
			('powershell -NoProfile -Command "Remove-Item -LiteralPath ''{0}'' -Recurse -Force -ErrorAction SilentlyContinue"' -f $竞速上下文.暂存目录)
		}
		try {
			执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 $清理命令
		} catch {
			# 清理失败无害
		}
	}

	function 执行-SSH命令并捕获 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$命令文本
		)

		# 捕获版 SSH 执行：返回 pscustomobject（勿用元组，空输出时会被 PowerShell 展平导致属性错位），-n 防老版 sshd 挂起
		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}

		$原始EAP = $ErrorActionPreference
		try {
			# PS 5.1 下原生命令 stderr 一旦被重定向即变终止性错误，捕获期间临时切 Continue 并在 finally 恢复
			$ErrorActionPreference = 'Continue'
			$输出 = @(& $ssh命令.Source (@('-n', '-p', $端口) + $script:SSH密码选项 + @($连接目标, $命令文本)) 2>&1)
		} finally {
			$ErrorActionPreference = $原始EAP
		}

		return [pscustomobject]@{ 输出 = $输出; 退出码 = $LASTEXITCODE }
	}

	function 探测-远程glibc版本 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		# 解析 ldd --version 首行（如 "ldd (GNU libc) 2.17"）；非 glibc 环境或探测失败返回 $null
		$结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 'ldd --version 2>/dev/null | head -1'
		if ($结果.退出码 -ne 0) { return $null }
		foreach ($行 in $结果.输出) {
			$文本 = ([string]$行).Trim()
			if ($文本 -match '(\d+\.\d+)\s*$') {
				try { return [version]$Matches[1] } catch { return $null }
			}
		}
		return $null
	}

	function 下载-兼容性工具包 {
		# 本地下载并缓存 sysroot 素材（glibc/libstdc++/libgcc 的 CentOS 8 RPM + patchelf 0.18 静态二进制，共约 5MB）
		# vault.centos.org 对无 UA 请求返回 403，故走清华/阿里镜像并显式 UA；patchelf 用 GitHub Release 官方静态包（0.17.x 有 segfault 问题，官方要求 >= 0.18）
		$缓存目录 = Join-Path $env:TEMP 'vscode-sysroot-bundle'
		New-Item -ItemType Directory -Force $缓存目录 | Out-Null

		$镜像前缀列表 = @(
			'https://mirrors.tuna.tsinghua.edu.cn/centos-vault/8.5.2111/BaseOS/x86_64/os/Packages',
			'https://mirrors.aliyun.com/centos-vault/8.5.2111/BaseOS/x86_64/os/Packages'
		)

		$素材清单 = New-Object System.Collections.ArrayList
		foreach ($rpm名称 in @('glibc-2.28-164.el8.x86_64.rpm', 'libstdc++-8.5.0-4.el8_5.x86_64.rpm', 'libgcc-8.5.0-4.el8_5.x86_64.rpm')) {
			[void]$素材清单.Add([pscustomobject]@{ 文件名 = $rpm名称; 地址列表 = @($镜像前缀列表 | ForEach-Object { $_ + '/' + $rpm名称 }) })
		}
		[void]$素材清单.Add([pscustomobject]@{
			文件名 = 'patchelf-0.18.0-x86_64.tar.gz'
			地址列表 = @('https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz')
		})

		foreach ($素材 in $素材清单) {
			$本地路径 = Join-Path $缓存目录 $素材.文件名
			if ((Test-Path $本地路径) -and ((Get-Item $本地路径).Length -gt 0)) { continue }

			$下载成功 = $false
			foreach ($地址 in $素材.地址列表) {
				try {
					Write-Host ('下载 sysroot 素材: {0}' -f $素材.文件名)
					Invoke-WebRequest -Uri $地址 -OutFile $本地路径 -UseBasicParsing -UserAgent 'Mozilla/5.0'
					if ((Get-Item $本地路径).Length -gt 0) { $下载成功 = $true; break }
				} catch {
					Remove-Item $本地路径 -Force -ErrorAction SilentlyContinue
				}
			}

			if (-not $下载成功) {
				throw ('sysroot 素材下载失败: {0}（已尝试 {1} 个源）' -f $素材.文件名, $素材.地址列表.Count)
			}
		}

		return $缓存目录
	}

	function 部署-远程兼容性环境 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$远程登录目录
		)

		# 官方 sysroot 妥协方案的全自动部署（VS Code 1.99+ 对旧 glibc 系统的 workaround）：
		# 在远程家目录组装 vscode-sysroot（glibc 2.28 库 + patchelf 0.18），并向 ~/.bashrc 顶部注入 VSCODE_SERVER_CUSTOM_GLIBC_LINKER / VSCODE_SERVER_CUSTOM_GLIBC_PATH / VSCODE_SERVER_PATCHELF_PATH 三个环境变量，Remote-SSH 后续安装时即自动用 sysroot patch server 而不报 glibc 先决条件错误。已部署过则幂等跳过。返回 sysroot 目录路径；部署失败抛异常由调用方决定容忍度。
		$sysroot目录 = ($远程登录目录.TrimEnd('/', '\')) + '/vscode-sysroot'

		# 就绪检查：loader 实体、patchelf、bashrc 标记块三者齐备才算已部署（按 ld-*.so 实体文件判定，与部署脚本的锚定标准一致；缺任一项则重新部署自愈）
		$就绪命令 = 'find "{0}/glibc" -name "ld-*.so" -type f | grep -q . && "{0}/bin/bin/patchelf" --version >/dev/null 2>&1 && grep -q "vscode-sysroot (" "$HOME/.bashrc"' -f $sysroot目录
		$就绪结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 $就绪命令
		if ($就绪结果.退出码 -eq 0) {
			Write-Host '远程 sysroot 已部署，跳过。'
			return $sysroot目录
		}

		$缓存目录 = 下载-兼容性工具包
		$暂存目录 = $sysroot目录 + '/.stage'
		[void](执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 ('mkdir -p "{0}"' -f $暂存目录))

		foreach ($素材文件 in (Get-ChildItem $缓存目录 -File)) {
			上传-文件到远程 -本地路径 $素材文件.FullName -连接目标 $连接目标 -端口 $端口 -远程路径 ($暂存目录 + '/' + $素材文件.Name)
		}

		# 部署脚本为独立模板文件（private\sysroot部署脚本.sh，模块加载时读入），在远端解包组装 sysroot；库布局归并、loader 选址与环境变量注入的实现细节见该文件内注释
		$部署脚本文本 = ($script:脚本_sysroot部署 -replace "`r`n", "`n").Replace('__目录__', $sysroot目录)

		$本地部署脚本路径 = Join-Path $env:TEMP ('sysroot-deploy-{0}.sh' -f ([guid]::NewGuid().ToString('N')))
		$远程部署脚本文件名 = 'vscode-sysroot-deploy-temp.sh'
		$远程部署脚本路径 = $远程登录目录.TrimEnd('/', '\') + '/' + $远程部署脚本文件名
		try {
			[System.IO.File]::WriteAllText($本地部署脚本路径, $部署脚本文本, [System.Text.UTF8Encoding]::new($false))
			上传-文件到远程 -本地路径 $本地部署脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程部署脚本路径

			$部署结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 ('sh "{0}"' -f $远程部署脚本路径)
			foreach ($行 in $部署结果.输出) { Write-Host ('[sysroot部署] {0}' -f $行) }
			if ($部署结果.退出码 -ne 0) {
				throw ('sysroot 部署脚本失败，退出码 {0}' -f $部署结果.退出码)
			}
		} finally {
			Remove-Item $本地部署脚本路径 -Force -ErrorAction SilentlyContinue
			try { 执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('rm -f "{0}"' -f $远程部署脚本路径) } catch { }
		}

		# 验证非交互 ssh 会话确实能吃到 .bashrc 注入的变量（bash 对 SSH_CLIENT 会话会读 ~/.bashrc）
		# 注意命令用单引号构造，防止 $VSCODE_SERVER_* 被本地 PowerShell 展开；匹配 sysroot 目录前缀即可（lib64/usr/lib64 布局均可）
		$验证结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 'echo "LINKER=$VSCODE_SERVER_CUSTOM_GLIBC_LINKER"'
		$验证命中 = $false
		foreach ($行 in $验证结果.输出) {
			if (([string]$行) -match ('^LINKER=' + [regex]::Escape($sysroot目录) + '[\\/]')) { $验证命中 = $true }
		}
		if ($验证命中) {
			Write-Host '已验证非交互 SSH 会话可见 VSCODE_SERVER_CUSTOM_GLIBC_LINKER。'
		} else {
			Write-Host '警告: 非交互 SSH 会话未读到 sysroot 环境变量（远程 shell 可能不是 bash 或 .bashrc 未被加载），Remote-SSH 若仍报 glibc 错误请手动检查 ~/.bashrc。'
		}

		return $sysroot目录
	}

	function 修补-远程原生组件 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$远程登录目录
		)

		# 旧 glibc 主机上有两类原生组件需要与 server 的 node 走同一套 sysroot 环境：
		# vsce-sign（扩展签名校验工具，.NET 单文件）与 *.node（扩展/服务端原生模块，node 的RUNPATH不被 dlopen 子对象继承，librt/libutil 等落到系统老库报 GLIBC_PRIVATE 错）。补丁脚本自带备份、patch 后实际加载验证与失败还原，幂等（已 patch 且验证通过则跳过）。
		$补丁脚本文本 = $script:脚本_原生组件补丁 -replace "`r`n", "`n"
		$本地临时脚本路径 = Join-Path $env:TEMP ('native-patch-{0}.sh' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本路径 = $远程登录目录.TrimEnd('/', '\') + '/vscode-native-patch-temp.sh'
		try {
			[System.IO.File]::WriteAllText($本地临时脚本路径, $补丁脚本文本, [System.Text.UTF8Encoding]::new($false))
			上传-文件到远程 -本地路径 $本地临时脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程临时脚本路径

			$补丁结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 ('sh "{0}"' -f $远程临时脚本路径)
			foreach ($行 in $补丁结果.输出) { Write-Host ([string]$行) }
			if ($补丁结果.退出码 -ne 0) {
				Write-Host ('警告: 原生组件补丁未完全成功（退出码 {0}），扩展签名校验或原生模块加载可能仍会失败。' -f $补丁结果.退出码)
			}
		} finally {
			Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			try { 执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('rm -f "{0}"' -f $远程临时脚本路径) } catch { }
		}
	}

	function 部署-VSCode服务保活 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$远程登录目录,
			[string]$提交号,
			[string]$发布通道,
			[ValidateSet('部署', '移除')]
			[string]$动作
		)

		# 把 Remote-SSH exec server 的启动入口 CLI（<数据根目录>/code[-insiders]-<提交号>）替换为包装脚本：真正启动的command-shell以「双 fork + setsid」拉起（PPID 归 1、自建会话），与 sshd-session 的祖先链彻底断开而存活；主机周期性收割超龄会话时 Server 不死，本地 VS Code 重连即可热附着（复用 pid.txt 与 connectionToken）而非冷启动。真实二进制备份必须放数据目录之外：官方引导脚本每次连接都会按文件名对数据目录做 GC（只保留最新 5 个匹配项）。
		$根目录 = $远程登录目录.TrimEnd('/', '\')
		$数据目录名 = if ($发布通道 -eq 'insider') { '.vscode-server-insiders' } else { '.vscode-server' }
		$CLI基础名 = if ($发布通道 -eq 'insider') { 'code-insiders' } else { 'code' }

		$脚本文本 = $script:脚本_服务保活部署
		$脚本文本 = $脚本文本.Replace('__动作__', $动作)
		$脚本文本 = $脚本文本.Replace('__数据目录__', ($根目录 + '/' + $数据目录名))
		$脚本文本 = $脚本文本.Replace('__服务保活目录__', ($根目录 + '/.vscode-persistent'))
		$脚本文本 = $脚本文本.Replace('__CLI文件名__', ($CLI基础名 + '-' + $提交号))
		$脚本文本 = $脚本文本.Replace('__当前提交号__', $提交号)
		$脚本文本 = $脚本文本.Replace('__发布通道__', $发布通道)

		# 包装脚本模板是独立文件，与部署脚本一同上传到远程，部署脚本按占位符给出的路径读取它生成包装脚本
		$本地临时脚本路径 = Join-Path $env:TEMP ('临时VSCode服务保活-{0}.sh' -f ([guid]::NewGuid().ToString('N')))
		$本地包装模板路径 = Join-Path $env:TEMP ('临时VSCode服务保活包装-{0}.sh' -f ([guid]::NewGuid().ToString('N')))
		$远程临时脚本路径 = $根目录 + '/vscode-server-persist-temp.sh'
		$远程包装模板路径 = $根目录 + '/vscode-server-persist-wrapper-temp.sh'
		$脚本文本 = $脚本文本.Replace('__包装脚本路径__', $远程包装模板路径)
		try {
			# Linux sh 脚本要求 LF 行尾，且不得带 BOM，否则 shebang 与语法会出错
			[System.IO.File]::WriteAllText($本地临时脚本路径, ($脚本文本 -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
			[System.IO.File]::WriteAllText($本地包装模板路径, ($script:脚本_服务保活包装 -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
			上传-文件到远程 -本地路径 $本地临时脚本路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程临时脚本路径
			上传-文件到远程 -本地路径 $本地包装模板路径 -连接目标 $连接目标 -端口 $端口 -远程路径 $远程包装模板路径

			$结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 ('sh "{0}"' -f $远程临时脚本路径)
			foreach ($行 in $结果.输出) { Write-Host $行 }
			if ($结果.退出码 -ne 0) {
				throw ('服务保活{0}脚本失败，退出码 {1}' -f $动作, $结果.退出码)
			}
		} finally {
			Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			Remove-Item $本地包装模板路径 -Force -ErrorAction SilentlyContinue
			try { 执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('rm -f "{0}" "{1}"' -f $远程临时脚本路径, $远程包装模板路径) } catch { }
		}
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

		# Windows 远程主机的默认 shell（cmd）没有 uname 命令，只有 Linux 会原样输出内核名与硬件架构。一次取回 uname -s 与 uname -m：Linux 侧同时拿到系统类型与原始架构（竞速所需）；Windows 主机执行 uname 必失败，其 stderr 在 PS 5.1 下会被提升为终止性错误，此处静默捕获并视为 Windows（Windows 架构另有探测路径），这是预期的判别路径
		# -n 将 stdin 重定向为 NUL：老版 sshd（如 Win7 自带）在远程命令结束后仍会等待 stdin 关闭才断开会话，不加 -n 会永久挂起
		try {
			$输出 = & $ssh命令.Source (@('-n', '-p', $端口) + $script:SSH密码选项 + @($连接目标, 'uname -s; uname -m'))
			$行列表 = @($输出 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
			if ($LASTEXITCODE -eq 0 -and $行列表.Contains('Linux')) {
				# uname -m 的输出紧跟在 uname -s 后行，取 Linux 行的下一行作原始架构
				$索引 = [array]::IndexOf($行列表, 'Linux')
				$架构 = if (($索引 + 1) -lt $行列表.Count) { $行列表[$索引 + 1] } else { '' }
				Write-Host ('检测到远程系统类型: Linux，原始架构: {0}' -f $架构)
				return [pscustomobject]@{ 系统类型 = 'Linux'; 原始架构 = $架构 }
			}

			# uname 执行失败但认证已通过（LASTEXITCODE 非 0 但不是认证问题），视为 Windows
			# 认证失败的退出码通常是 255，且伴随 Permission denied；此处简化处理：非 0 即 Windows
			$win架构 = 探测-Windows架构 -连接目标 $连接目标 -端口 $端口
			Write-Host ('检测到远程系统类型: Windows，原始架构: {0}' -f $win架构)
			return [pscustomobject]@{ 系统类型 = 'Windows'; 原始架构 = $win架构 }
		} catch {
			# 已知且无害：Windows 无 uname 命令，失败即代表远程是 Windows
			$win架构 = 探测-Windows架构 -连接目标 $连接目标 -端口 $端口
			Write-Host ('检测到远程系统类型: Windows，原始架构: {0}' -f $win架构)
			return [pscustomobject]@{ 系统类型 = 'Windows'; 原始架构 = $win架构 }
		}
	}

	function 探测-Windows架构 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		# cmd 默认 shell 下 %PROCESSOR_ARCHITECTURE% 直接展开；远程默认 shell 是 PowerShell 时该语法也兼容（输出原样回显变量值不成立，但回退路径里 PS 版本单独探，这里只取 cmd 展开形态）。失败返回空串（只影响竞速启用，不影响安装）
		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) { return '' }
		try {
			$输出 = @(& $ssh命令.Source (@('-n', '-p', $端口) + $script:SSH密码选项 + @($连接目标, 'echo %PROCESSOR_ARCHITECTURE%')))
			if ($LASTEXITCODE -ne 0) { return '' }
			foreach ($行 in $输出) {
				$文本 = ([string]$行).Trim()
				if ($文本 -match '^(AMD64|ARM64|x86|X64)$') { return $文本 }
			}
			return ''
		} catch {
			return ''
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
			[string]$远程登录目录,
			[scriptblock]$每行回调
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
			执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('powershell -NoProfile -ExecutionPolicy Bypass -File "%USERPROFILE%\{0}"' -f $远程临时脚本文件名) -TTY -每行回调 $每行回调
		} finally {
			# 清理临时文件（无害操作，失败不影响主流程）
			if (Test-Path $本地临时脚本路径) {
				Remove-Item $本地临时脚本路径 -Force -ErrorAction SilentlyContinue
			}

			try {
				# 远程默认 shell 可能是 PowerShell 也可能是 cmd，cmd 专属语法（del、2>nul）在 PowerShell 下会报错，统一用 powershell 包装，两种 shell 下都能正确执行且静默失败
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
			[string]$远程登录目录,
			[scriptblock]$每行回调
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
			执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 ('sh ~/{0}' -f $远程临时脚本文件名) -TTY -每行回调 $每行回调
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

	# 服务保活入口：只部署或移除包装脚本，不安装 Server、不启用竞速下载
	if ($仅服务保活) {
		if ($环境.系统类型 -ne 'Linux') {
			清除-SSH密码复用
			throw '服务保活仅支持 Linux 远程主机（依赖 setsid 脱离会话与 POSIX sh）。'
		}
		if ([string]::IsNullOrWhiteSpace($环境.登录目录)) {
			清除-SSH密码复用
			throw '无法解析远程登录目录，服务保活需要绝对路径，请确认远程 shell 能输出 $HOME。'
		}

		$保活动作 = if ($移除服务保活) { '移除' } else { '部署' }
		Write-Host ('执行服务保活{0}...' -f $保活动作)
		try {
			部署-VSCode服务保活 -连接目标 $连接目标 -端口 $SSH端口 -远程登录目录 $环境.登录目录 -提交号 $本地信息.提交号 -发布通道 $本地信息.发布通道 -动作 $保活动作
		} finally {
			清除-SSH密码复用
		}
		return
	}

	if ($环境.系统类型 -eq 'Linux') {
		# 旧 glibc 兼容（官方 sysroot 妥协方案）：VS Code 1.99+ 的 server 要求 glibc >= 2.28，老系统（如 CentOS 7 glibc 2.17）需在家目录部署 sysroot 并注入 VSCODE_SERVER_CUSTOM_GLIBC_* 环境变量
		$兼容性sysroot目录 = ''
		$glibc版本 = 探测-远程glibc版本 -连接目标 $连接目标 -端口 $SSH端口
		if ($null -ne $glibc版本) {
			Write-Host ('远程 glibc 版本: {0}' -f $glibc版本)
		}
		if (($null -ne $glibc版本) -and ($glibc版本 -lt [version]'2.28')) {
			if ([string]::IsNullOrWhiteSpace($环境.登录目录)) {
				Write-Host '警告: 远程 glibc 过旧且登录目录未知，无法自动部署 sysroot；Remote-SSH 连接将因先决条件失败。'
			} else {
				Write-Host ('远程 glibc {0} < 2.28，不满足 VS Code Server 先决条件，自动部署官方 sysroot 妥协方案...' -f $glibc版本)
				$兼容性sysroot目录 = 部署-远程兼容性环境 -连接目标 $连接目标 -端口 $SSH端口 -远程登录目录 $环境.登录目录
			}
		}

		# Linux 远程主机走 sh 安装流程；能确定暂存目录与远程架构时启用竞速（本地子进程下载+上传 与 远程自下载 并行，先完成者胜）
		$竞速上下文 = 初始化-竞速上下文 -环境 $环境 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号
		$本地供给 = $null
		$每行回调 = $null
		if ($null -ne $竞速上下文) {
			Write-Host ('已启用竞速模式：本地子进程下载+上传 与 远程自下载并行，暂存目录 {0}' -f $竞速上下文.暂存目录)
			# 预清理暂存目录，防陈旧标记/残包造成误判
			清理-竞速暂存目录 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			$本地供给 = 启动-本地竞速供给 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			# 事件驱动即时取消：监听远程 stdout，一旦输出"竞速获胜"即竞速结束，立刻击杀本地供给进程树（零轮询）
			# GetNewClosure 把回调绑进独立动态模块，模块里看不到本函数的嵌套函数，须先把函数体取成脚本块变量随闭包带走
			$停止供给动作 = ${function:停止-供给进程树}
			$每行回调 = { param($行) if ($行 -match '竞速获胜') { & $停止供给动作 -供给 $本地供给 } }.GetNewClosure()
		} else {
			Write-Host '未启用竞速模式（登录目录或远程架构无法确定），由远程单独下载。'
		}

		$远程安装脚本 = $script:远程脚本_Linux
		$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
		$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)
		$远程安装脚本 = $远程安装脚本.Replace('__暂存目录__', $(if ($null -ne $竞速上下文) { $竞速上下文.暂存目录 } else { '' }))
		$远程安装脚本 = $远程安装脚本.Replace('__兼容性目录__', $兼容性sysroot目录)

		try {
			执行-Linux远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本 -远程登录目录 $环境.登录目录 -每行回调 $每行回调
		} finally {
			# 收尾：击杀本地供给进程树并回收其日志，再双保险清理暂存目录（失败无害）
			等待-供给进程并回收日志 -供给 $本地供给
			if ($null -ne $竞速上下文) {
				清理-竞速暂存目录 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			}
			# 旧 glibc 主机：vsce-sign 与 *.node 原生模块同样需要 sysroot 环境，收尾时统一补丁（失败仅告警不影响安装结果）
			if (-not [string]::IsNullOrWhiteSpace($兼容性sysroot目录)) {
				try {
					修补-远程原生组件 -连接目标 $连接目标 -端口 $SSH端口 -远程登录目录 $环境.登录目录
				} catch {
					Write-Host ('警告: 原生组件补丁步骤失败: {0}' -f $_.Exception.Message)
				}
			}
		}
		清除-SSH密码复用
		return
	}


	# Windows 远程主机：一律自动探测脚本版本（按远程 PowerShell 版本选择）
	$远程安装脚本 = 选择-远程脚本 -PS主版本 $环境.PS主版本
	$竞速上下文 = $null
	$本地供给 = $null
	$每行回调 = $null
	if ($远程安装脚本 -eq $script:远程脚本_Win7) {
		# Win7（PS2）版无法在远程后台作业里可靠自下载，保持原有本地下载+上传供给方式，不竞速
		$本地附加压缩包路径 = 下载-本地服务器压缩包 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号 -架构 'win32-x64'
		$远程附加压缩包文件名 = 'vscode-server-upload-temp.zip'
	} else {
		# 通用版：能确定暂存目录与远程架构时启用竞速
		$竞速上下文 = 初始化-竞速上下文 -环境 $环境 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号
		if ($null -ne $竞速上下文) {
			Write-Host ('已启用竞速模式：本地子进程下载+上传 与 远程自下载并行，暂存目录 {0}' -f $竞速上下文.暂存目录)
			清理-竞速暂存目录 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			$本地供给 = 启动-本地竞速供给 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			# 事件驱动即时取消：同上，函数体先取成脚本块变量再带入 GetNewClosure 闭包
			$停止供给动作 = ${function:停止-供给进程树}
			$每行回调 = { param($行) if ($行 -match '竞速获胜') { & $停止供给动作 -供给 $本地供给 } }.GetNewClosure()
		} else {
			Write-Host '未启用竞速模式（登录目录或远程架构无法确定），由远程单独下载。'
		}
	}

	# 替换占位符（Win7 版无 __暂存目录__ 占位符，替换为空串不影响其行为）
	$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
	$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)
	$远程安装脚本 = $远程安装脚本.Replace('__暂存目录__', $(if ($null -ne $竞速上下文) { $竞速上下文.暂存目录 } else { '' }))

	try {
		执行-远程安装脚本 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本 -本地附加压缩包路径 $本地附加压缩包路径 -远程附加压缩包文件名 $远程附加压缩包文件名 -远程登录目录 $环境.登录目录 -每行回调 $每行回调
	} finally {
		等待-供给进程并回收日志 -供给 $本地供给
		if ($null -ne $竞速上下文) {
			清理-竞速暂存目录 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
		}
	}
	清除-SSH密码复用
}


function 安装-VSCode服务保活 {
	<#
	.SYNOPSIS
		让远程 Linux 主机上的 VS Code Server 脱离 SSH 会话存活，主机周期性回收超龄会话后本地重连可热附着。

	.DESCRIPTION
		部分集群登录节点会用 root 权限的周期任务强制回收超龄 SSH 会话（实测有主机把存活超过 60 分钟的会话全部杀掉）。Remote-SSH 的 exec server 进程树是 sshd 会话后代，会随之被杀：本地 VS Code 每小时掉线一次，重连后远端终端与扩展状态全部丢失，日志表现为 Unknown reconnection token 加整轮冷启动。

		本命令把数据根目录下的 CLI 入口（code[-insiders]-<提交号>）替换为包装脚本：真正启动的 command-shell 以「双 fork + setsid」方式拉起——子 shell 立即退出使真身 PPID 归 1、setsid 另建会话与进程组，从而与 sshd 会话的祖先链彻底断开，在会话被周期性收割后存活；同时把 --parent-process-id 看门狗参数改写为 PID 1。真实二进制另存到 <登录目录>/.vscode-persistent/real，避开官方引导脚本按文件名对数据目录做的 GC（只保留最新 5 个匹配项）。

		效果：会话仍会被回收（这层由主机管理策略决定，无法在客户端改变），但 Server 不死，本地 VS Code 自动重连时热附着，编辑器、扩展宿主与远端终端及其滚动历史原地保留。掉线代价从整轮冷启动降为十几秒闪断。

		注意：VS Code 更新到新提交号后需重新执行一次本命令。新提交号的 CLI 会由官方引导脚本下载为裸 ELF，当次连接不受保护，重跑后恢复保护。

	.PARAMETER 远程主机
		目标主机名或 IP（必填，位置参数 0）。传 ~/.ssh/config 中的 Host 别名时，账户与端口由 OpenSSH 自行解析。

	.PARAMETER 远程账户
		SSH 登录账户。未指定时从 ~/.ssh/config 反查匹配项。

	.PARAMETER SSH端口
		SSH 端口。未指定时取 ~/.ssh/config 中匹配到的 Port，仍无则用 22。

	.PARAMETER 本地版本
		预览版或稳定版。本机同时安装两者时必填，用于确定提交号与数据根目录名。

	.PARAMETER 移除
		还原为官方原始布局：把真实二进制移回数据目录覆盖包装脚本，并删除 .vscode-persistent 目录。

	.EXAMPLE
		安装-VSCode服务保活 bme_login_贾梦涵

		对 ~/.ssh/config 中的别名部署服务保活，账户与端口由配置文件解析。

	.EXAMPLE
		安装-VSCode服务保活 10.15.49.6 -SSH端口 22112 -远程账户 v-jiamh -本地版本 预览版

		裸 IP 连接时显式给出账户、端口与本机版本。

	.EXAMPLE
		安装-VSCode服务保活 bme_login_贾梦涵 -移除

		移除保活包装，还原官方原始布局。
	#>
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true, Position = 0)]
		[Alias('目标服务器', '计算机名', 'IP', '主机')]
		[string]$远程主机,

		[string]$远程账户,

		# 0 表示未指定：将优先采用 ~/.ssh/config 中匹配到的 Port，仍无则用 22
		[int]$SSH端口 = 0,

		[ValidateSet('预览版', '稳定版')]
		[string]$本地版本,

		[switch]$移除
	)

	# 复用主入口已实现的连接协商（ssh config 反查、密码一次性收集复用、环境与登录目录探测），仅把动作切成服务保活的部署或移除
	$转发参数 = @{
		远程主机     = $远程主机
		SSH端口      = $SSH端口
		仅服务保活   = $true
		移除服务保活 = $移除.IsPresent
	}
	if (-not [string]::IsNullOrWhiteSpace($远程账户)) { $转发参数['远程账户'] = $远程账户 }
	if (-not [string]::IsNullOrWhiteSpace($本地版本)) { $转发参数['本地版本'] = $本地版本 }

	安装-VSCode远程服务 @转发参数
}


# 导出公共函数
Export-ModuleMember -Function '安装-VSCode远程服务', '安装-VSCode服务保活'
