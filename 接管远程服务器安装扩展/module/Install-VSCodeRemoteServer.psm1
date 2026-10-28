# 安装-VSCode远程服务 Module
# 通过 SSH 与 BITS 在远程 Windows 主机上安装 VS Code Server

# 加载私有远程脚本模板
$script:模块根目录 = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:远程脚本_通用 = Get-Content -Path (Join-Path $script:模块根目录 'private\remote-install-common.ps1') -Raw -Encoding UTF8
$script:远程脚本_Win7 = Get-Content -Path (Join-Path $script:模块根目录 'private\remote-install-win7.ps1') -Raw -Encoding UTF8
$script:远程脚本_Linux = Get-Content -Path (Join-Path $script:模块根目录 'private\remote-install-linux.sh') -Raw -Encoding UTF8
$script:脚本_sysroot部署 = Get-Content -Path (Join-Path $script:模块根目录 'private\sysroot-deploy.sh') -Raw -Encoding UTF8
$script:脚本_原生组件补丁 = Get-Content -Path (Join-Path $script:模块根目录 'private\native-patch.sh') -Raw -Encoding UTF8
$script:脚本_服务保活部署 = Get-Content -Path (Join-Path $script:模块根目录 'private\keepalive-deploy.sh') -Raw -Encoding UTF8
$script:脚本_服务保活包装 = Get-Content -Path (Join-Path $script:模块根目录 'private\keepalive-wrapper.sh') -Raw -Encoding UTF8
$script:脚本_服务保活改名器 = (Get-Content -Path (Join-Path $script:模块根目录 'private\keepalive-renamer.js') -Raw -Encoding UTF8) -replace "`r`n", "`n"
# 会话引导与编排的脚本正文一律独立成文件（不在 psm1 里内嵌字符串），sh 正文加载时归一 LF 行尾（sh 对 \r 零容忍）
# stdin 引导是「固定极小」的一层：载荷经标准输入送达、argv 只装本引导的 EncodedCommand，命令行长度与安装脚本大小彻底解耦
$script:脚本_单会话引导 = Get-Content -Path (Join-Path $script:模块根目录 'private\Windows单会话引导.ps1') -Raw -Encoding UTF8
$script:脚本_stdin引导 = Get-Content -Path (Join-Path $script:模块根目录 'private\windows-stdin-bootstrap.ps1') -Raw -Encoding UTF8
$script:脚本_会话帧循环 = (Get-Content -Path (Join-Path $script:模块根目录 'private\会话帧循环.sh') -Raw -Encoding UTF8) -replace "`r`n", "`n"
$script:脚本_环境探测命令 = (Get-Content -Path (Join-Path $script:模块根目录 'private\环境探测命令.txt') -Raw -Encoding UTF8) -replace "`r`n", "`n"
$script:脚本_接管编排模板 = (Get-Content -Path (Join-Path $script:模块根目录 'private\接管编排脚本模板.sh') -Raw -Encoding UTF8) -replace "`r`n", "`n"
# 供给子进程日志的实时转发登记：{产物名; 路径; 已读字节; 残段}。子进程 stdout/stderr 重定向到日志文件，这里按字节偏移增量读出立刻上屏，本地下载/上传进度不再积压到收尾统一打印
$script:供给日志登记 = New-Object System.Collections.ArrayList

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

		# 以下开关仅供本模块的公共入口 安装-VSCode服务保活 转发与 preconnect 非交互场景使用，对用户隐藏
		[Parameter(DontShow)]
		[switch]$仅服务保活,

		[Parameter(DontShow)]
		[switch]$移除服务保活,

		# 非交互环境（如 Remote-SSH preconnect）：需要密码时直接报错，不收集密码
		[Parameter(DontShow)]
		[switch]$非交互,

		# 与接管安装同跑时把服务保活检修并入同一次远程会话（供 preconnect 场景使用），对用户隐藏
		[Parameter(DontShow)]
		[switch]$含服务保活,

		# Remote-SSH 的 remotePlatform 映射（由 preconnect 实现脚本传入）：Windows 主机直走 powershell 单会话流程，不再徒劳尝试 sh 引导
		[Parameter(DontShow)]
		[object]$平台提示映射
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
		# 命令正文存于 private\环境探测命令.txt（脚本正文一律独立成文件，不在字符串里内嵌），改正文前先读上面的硬约束
		return $script:脚本_环境探测命令
	}

	function 解析-环境报告 {
		param(
			[string[]]$输出
		)

		$系统类型 = 'Windows'
		$登录目录 = ''
		$PS主版本 = $null
		$原始架构 = ''
		$内核版本 = $null
		$Glibc版本 = $null
		$提交上限KB = $null
		$已提交KB = $null
		$提交模式 = $null
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

			# Linux 专用：内核发布（uname -r 裸值，如 3.10.0-1160.el7.x86_64）与 glibc（ldd --version 首行，如 ldd (GNU libc) 2.17）；随合并探测一次带回，免去为它们各开一次 SSH（慢速主机上每次往返可达数十秒）
			if ($null -eq $内核版本 -and $行 -match '^(\d+\.\d+)\.') {
				try { $内核版本 = [version]$Matches[1] } catch { $内核版本 = $null }
				continue
			}
			if ($null -eq $Glibc版本 -and $行 -match 'libc.*?(\d+\.\d+)\s*$') {
				try { $Glibc版本 = [version]$Matches[1] } catch { $Glibc版本 = $null }
				continue
			}

			# Linux 专用：内存提交额度（CommitLimit/Committed_AS 原样行 + OVERCOMMIT= 模式行），解析出余量供内存紧张预警
			if ($null -eq $提交上限KB -and $行 -match '^CommitLimit:\s+(\d+)') { $提交上限KB = [long]$Matches[1]; continue }
			if ($null -eq $已提交KB -and $行 -match '^Committed_AS:\s+(\d+)') { $已提交KB = [long]$Matches[1]; continue }
			if ($null -eq $提交模式 -and $行 -match '^OVERCOMMIT=(\d+)$') { $提交模式 = [int]$Matches[1]; continue }

			# Windows 默认 shell 为 PowerShell 时，探测命令中的 powershell 行直接输出裸路径（无标记前缀），按 Windows 路径形态识别
			if ($系统类型 -eq 'Windows' -and $登录目录 -eq '' -and $行 -match '^[A-Za-z]:\\') {
				$登录目录 = $行.TrimEnd('\', '/')
				continue
			}

			if ($系统类型 -eq 'Windows' -and $null -eq $PS主版本 -and $行 -match '^\d+$') {
				$PS主版本 = [int]$行
			}
		}

		$提交余量KB = $null
		$严格提交模式 = $false
		if ($null -ne $提交上限KB -and $null -ne $已提交KB) {
			$提交余量KB = [Math]::Max(0L, $提交上限KB - $已提交KB)
			$严格提交模式 = ($提交模式 -eq 2)
		}

		$完整 = if ($系统类型 -eq 'Linux') { $登录目录 -ne '' } else { ($登录目录 -ne '') -and ($null -ne $PS主版本) }

		return [pscustomobject]@{
			系统类型 = $系统类型
			登录目录 = $登录目录
			PS主版本 = $PS主版本
			原始架构 = $原始架构
			内核版本 = $内核版本
			Glibc版本 = $Glibc版本
			提交余量KB = $提交余量KB
			严格提交模式 = $严格提交模式
			完整 = $完整
		}
	}

	function 执行-环境探测 {
		param(
			[string]$连接目标,
			[int]$端口,
			[switch]$免密模式,
			# 与探测同行执行的轻量远端准备（同一条连接）；语法须跨 sh/cmd/PowerShell 全兼容（约束见 取-环境探测命令 注释）
			[string]$附加命令
		)

		# 一次 SSH 调用完成全部环境试探；认证失败（退出码 255）返回 $null 由调用方进入密码收集流程
		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法探测远程环境。'
		}

		$ssh参数 = @('-n', '-p', $端口) + $script:SSH密码选项
		if ($免密模式) { $ssh参数 += @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10') }
		# 探测命令必须用 LF 行尾：本模块文件以 CRLF 保存，here-string 会带上 \r，远端 sh 会把行尾的 \r 当成命令的一部分（如 uname -s\r 报 invalid option），导致关键输出行丢失
		$探测命令文本 = (取-环境探测命令) -replace "`r`n", "`n"
		if (-not [string]::IsNullOrWhiteSpace($附加命令)) {
			$探测命令文本 = $探测命令文本 + "`n" + $附加命令
		}
		$ssh参数 += @($连接目标, $探测命令文本)

		# PS 5.1 下原生命令 stderr 一旦被重定向即变终止性错误，捕获期间临时切 Continue 并在 finally 恢复；不重定向时探测命令的多平台垃圾行会污染控制台，故此处选择捕获
		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			$输出 = @(& $ssh命令.Source $ssh参数 2>&1)
		} finally {
			$ErrorActionPreference = $原始EAP
		}

		if ($LASTEXITCODE -eq 255) {
			# 留诊断给非交互模式报错时区分「要密码」与「连不上」
			$script:环境探测诊断 = (@($输出) | ForEach-Object { [string]$_ }) -join ' '
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
			内核版本 = $报告.内核版本
			Glibc版本 = $报告.Glibc版本
			提交余量KB = $报告.提交余量KB
			严格提交模式 = $报告.严格提交模式
			完整 = $true
		}
	}

	function 初始化-SSH会话 {
		param(
			[string]$连接目标,
			[int]$端口,
			# 非交互（如 Remote-SSH preconnect，标准输入是 ignore）：需要密码时直接报错而不是收集
			[switch]$非交互,
			[string]$附加命令,
			# 单会话通道：探测已随会话引导体发出，直接取结果；取不到（非 POSIX 远端/免密失败）则回退离散探测
			$会话
		)

		$script:SSH密码选项 = @()
		$script:密码已注入 = $false

		if ($null -ne $会话 -and $会话.进程.HasExited) {
			Write-Host '单会话进程已退出，回退离散流程。'
		}
		if ($null -ne $会话 -and -not $会话.进程.HasExited) {
			$会话探测行 = 读取-会话探测 $会话
			if ($null -ne $会话探测行) {
				Write-Host '检测到远程主机已配置免密登录，无需输入密码。'
				$报告 = 解析-环境报告 -输出 $会话探测行
				return (补全-环境报告 -报告 $报告 -连接目标 $连接目标 -端口 $端口)
			}
			# 会话没能完成探测：弃用会话，回退下方离散流程（它会给出准确的免密/连接报错）；把会话错误流带出来否则无从排查
			try {
				$null = $会话.错误任务.Wait(2000)
				if ($会话.错误任务.IsCompleted -and -not [string]::IsNullOrWhiteSpace($会话.错误任务.Result)) {
					Write-Host ('单会话错误流: {0}' -f ($会话.错误任务.Result.Trim()))
				}
			} catch { }
			Write-Host '单会话探测未完成，回退离散流程。'
			关闭-接管会话 $会话
			$会话 = $null
		}

		# 同一次会话内复用环境报告（如 preconnect 里安装与保活各调用一次本函数）：免去重复的整轮 SSH 往返
		if ($null -eq $script:环境报告缓存) { $script:环境报告缓存 = @{} }
		$缓存键 = '{0}:{1}' -f $连接目标, $端口
		if ($非交互 -and $script:环境报告缓存.ContainsKey($缓存键)) {
			return $script:环境报告缓存[$缓存键]
		}

		# 免密探测与环境试探合并为同一次连接：成功即同时拿到免密结论与完整环境报告（含内核与 glibc 版本）
		$报告 = 执行-环境探测 -连接目标 $连接目标 -端口 $端口 -免密模式 -附加命令 $附加命令
		if ($null -ne $报告) {
			Write-Host '检测到远程主机已配置免密登录，无需输入密码。'
			$补全报告 = 补全-环境报告 -报告 $报告 -连接目标 $连接目标 -端口 $端口
			if ($非交互) { $script:环境报告缓存[$缓存键] = $补全报告 }
			return $补全报告
		}

		if ($非交互) {
			$诊断 = '无法连接远程主机'
			if ($script:环境探测诊断 -match 'Permission denied|denied|password|认证') { $诊断 = '未配置免密登录（密钥认证）' }
			throw ('{0}（{1}）：本环境无法交互输入密码（Remote-SSH preconnect 的标准输入被忽略）。请为该主机配置密钥认证，或取消勾选该主机改用 Remote-SSH 自带安装。' -f $诊断, $连接目标)
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
		$env:SSH_ASKPASS = Join-Path $script:模块根目录 'private\ssh-askpass.bat'
		$env:SSH_ASKPASS_REQUIRE = 'force'
		# 注意：不要加 BatchMode=yes——它会禁用 askpass 机制，导致密码无法注入
		$script:SSH密码选项 = @()
		$script:密码已注入 = $true

		# 密码注入后的第一次连接同样兼作环境试探，避免为试探再单独连一次
		$报告 = 执行-环境探测 -连接目标 $连接目标 -端口 $端口 -附加命令 $附加命令
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
			[string]$标准输入,
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

		# 流式转发并逐行回调（用于竞速判胜等事件监听）：Write-Host 保持原有的控制台实时输出；转发前剥离远端控制序列，避免本地终端照做执行造成乱行。
		# PS 5.1 下原生命令 stderr 一旦被重定向即变终止性错误，捕获期间临时切 Continue 并在 finally 恢复
		$原始EAP = $ErrorActionPreference
		$退出码 = 0
		try {
			$ErrorActionPreference = 'Continue'
			$script:标题序列未闭合 = $false
			$处理行 = {
				$文本 = 剥离-终端控制序列 ([string]$_)
				# 远端 powershell 在非控制台 stdio 下会把进度记录序列化成 CLIXML 噪声（#< CLIXML / <Objs>…），滤掉不进日志
				if ($文本 -match '^(#< CLIXML|<Objs|</Objs>)') { return }
				Write-Host $文本
				if ($每行回调) { & $每行回调 $文本 }
				转发-供给日志
			}
			# 大载荷一律走标准输入：argv 只装固定引导，命令行长度不再随安装脚本膨胀。
			# 实测教训（2026-10-22）：双重 base64 后 argv 达 37,950 字符 > CreateProcess 上限 32,767，本地 ssh.exe 直接拒绝启动（Program 'ssh.exe' failed to run: The filename or extension is too long），退出码 1 冒到 preconnect → Remote-SSH 判 PreconnectScriptFailure，整条连接夭折。管道结束时 PowerShell 会关闭原生进程的标准输入，EOF 确定送达，远端 ReadToEnd 才能返回。
			if ([string]::IsNullOrEmpty($标准输入)) {
				& $ssh命令.Source $ssh参数 2>&1 | ForEach-Object $处理行
			} else {
				$标准输入 | & $ssh命令.Source $ssh参数 2>&1 | ForEach-Object $处理行
			}
			$退出码 = $LASTEXITCODE
		} finally {
			$ErrorActionPreference = $原始EAP
		}
		if ($退出码 -ne 0) {
			throw ('SSH 执行失败，退出码: {0}' -f $退出码)
		}
	}

	# 走标准输入下发大载荷的 SSH 调用（Windows 单会话引导专用）：自己起 ssh 进程、把载荷一次性写入 StandardInput 后**显式 Close()**，输出异步读并配硬超时看门狗。为什么不用 PowerShell 管道（`$文本 | & ssh …`）：管道收尾不可靠是**偶发真实故障**——实测同一条通道 2KB/40KB/400KB 三档都在约 1 秒内无损送达（长度 + SHA256 双判据一致、退出码 0），但 120KB 那一档**挂死约 66 分钟**（退出码 -1、哈希无法核对）。无声挂死会把 Remote-SSH 的整个连接一起拖死，所以这里改成：EOF 由我们自己关闭（确定性），并加超时看门狗——超时即 taskkill 整树 + 抛类型化错误，让调用方重试而不是干等。
	function 执行-SSH命令带标准输入 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$命令文本,
			[string]$标准输入文本,
			[int]$超时秒 = 240,
			[scriptblock]$每行回调
		)

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}

		$参数串 = '-p ' + $端口
		foreach ($项 in $script:SSH密码选项) { $参数串 = $参数串 + ' "' + $项 + '"' }
		$参数串 = $参数串 + ' ' + $连接目标 + ' "' + $命令文本 + '"'

		$psi = New-Object System.Diagnostics.ProcessStartInfo
		# .cmd/.bat 包装的 ssh（某些环境用批处理包装）不能被 CreateProcess 直接启动，包一层 cmd /c
		if ($ssh命令.Source -match '\.(cmd|bat)$') {
			$psi.FileName = 'cmd.exe'
			$psi.Arguments = '/c ""' + $ssh命令.Source + '" ' + $参数串 + '"'
		} else {
			$psi.FileName = $ssh命令.Source
			$psi.Arguments = $参数串
		}
		$psi.UseShellExecute = $false
		$psi.RedirectStandardInput = $true
		$psi.RedirectStandardOutput = $true
		$psi.RedirectStandardError = $true
		$psi.CreateNoWindow = $true
		try { $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
		try { $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8 } catch { }

		$进程 = [System.Diagnostics.Process]::Start($psi)
		# stderr 必须异步抽干：只重定向不读取，缓冲区写满（约 4KB）就会把远端进程堵住 → 表现为"挂死"，与被替换掉的管道式写法是同一类故障，这里一并根除（仓库既有的 预热直连 也是这么做的）
		$错误任务 = $进程.StandardError.ReadToEndAsync()
		$截止 = (Get-Date).AddSeconds($超时秒)
		$已超时 = $false
		$有效行数 = 0
		# 启动层截止：生产同形态实测健康主机从建连到引导打出「载荷已到达」回执只要 5.8 秒（回执在引导做任何重活之前打，且远端读 stdin 本身有 90 秒界限），故 90 秒内一行有效输出都没有 = 远端启动/读取/回传链路未产出回执，不必白等满 240 秒的安装段超时；零输出本身不能证明远端进程没有启动（2026-10-24 B 服务器实测）。
		$启动截止 = (Get-Date).AddSeconds([Math]::Min(90, $超时秒))
		$启动层挂死 = $false
		$原EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			# 载荷一次性写入并立刻关闭：EOF 由我们决定，不给通道留"收尾不确定"的空间
			# 载荷是 base64 分块（纯 ASCII，不含 CR 也容忍被加 CRLF），用 ASCII 写字节即可
			$载荷字节 = [System.Text.Encoding]::ASCII.GetBytes($标准输入文本)
			$进程.StandardInput.BaseStream.Write($载荷字节, 0, $载荷字节.Length)
			$进程.StandardInput.Flush()
			$进程.StandardInput.Close()
			# 本地侧检查点：写出+关闭完成说明 EOF 已交给 ssh.exe，此后若再无任何有效输出，挂点必在远端/连接层而非载荷没送出去——事后取证时这行日志就是分界线
			Write-Host ('[单会话] 载荷已写出 {0} 字节并关闭标准输入，等待远端引导回执…' -f $载荷字节.Length)

			$script:标题序列未闭合 = $false
			# 注意：本循环以 `& $处理行 $行` 直接调用（不是 ForEach-Object 的管道调用），
			# 所以行处理器**必须用 param 接收实参**。写成 `[string]$_` 只在管道调用下才取到内容：
			# 实测那样取值恒为空串，后果是远端每一行都变空行——竞速标记进不了回调、本地供给永不启动（只剩远端独自下载），
			# 且空行仍算“有进展”把看门狗截止时间一路顺延（实测 448 秒 > 240 秒也没被杀），表现为“远端在跑、本地一片静默”。
			$处理行 = {
				param([string]$文本行)
				$文本 = 剥离-终端控制序列 $文本行
				# 远端 powershell 在非控制台 stdio 下会把进度记录序列化成 CLIXML 噪声，滤掉不进日志
				if ($文本 -match '^(#< CLIXML|<Objs|</Objs>)') { return }
				Write-Host $文本
				if ($每行回调) { & $每行回调 $文本 }
				转发-供给日志
			}
			$读任务 = $进程.StandardOutput.ReadLineAsync()
			while ($true) {
				if ($读任务.Wait(500)) {
					$行 = $读任务.Result
					if ($null -eq $行) { break }    # 读到 null = 远端标准输出已关闭
					& $处理行 $行
					# 只有“有效行”才算进展：空行与 CLIXML 序列化噪声不得顺延看门狗截止时间
					# （实测：行处理器取错变量时每一行都变空串，空流一路顺延，448 秒 > 240 秒看门狗也没触发）
					if ($行.Trim() -ne '' -and $行 -notmatch '^(#< CLIXML|<Objs|</Objs>)') {
						$有效行数++
						$截止 = (Get-Date).AddSeconds($超时秒)
					}
					$读任务 = $进程.StandardOutput.ReadLineAsync()
					continue
				}
				if ($进程.HasExited) {
					# 进程已结束：把异步读里已就绪的剩余行取干净再收尾
					while ($读任务.Wait(0)) {
						$行 = $读任务.Result
						if ($null -eq $行) { break }
						& $处理行 $行
						$读任务 = $进程.StandardOutput.ReadLineAsync()
					}
					break
				}
				if ((Get-Date) -gt $截止) { $已超时 = $true; break }
				# 启动层快速判死：一行有效输出都没收到过且超过启动截止 → 远端启动/读取/回传链路未产出回执，立即判死重试而非盲等安装段超时；不要把零输出解释成远端进程一定不存在
				if ($有效行数 -eq 0 -and (Get-Date) -gt $启动截止) { $已超时 = $true; $启动层挂死 = $true; break }
			}
		} finally {
			$ErrorActionPreference = $原EAP
		}

		if ($已超时) {
			# 看门狗：挂死的会话必须连整棵进程树一起清掉，否则本地 ssh 与远端 powershell 会双双留着占会话
			try { & taskkill /PID $进程.Id /T /F 2>&1 | Out-Null } catch { }
			try { if (-not $进程.HasExited) { $进程.Kill() } } catch { }
			if ($启动层挂死) {
				# 只能断言“本地未收到回执”，不能据此断言“远端引导未启动”：B 服务器实测远端进程已启动，却卡在 Console.In 的全量读取调用里（连 Task 都不返回，90 秒等待无法执行）。新引导已改用原始 stdin 的 StreamReader；诊断必须保留连接建立、远端读取、输出回传三种可能，避免再次把排障引向僵尸会话或安装脚本。
				throw ('[stdin超时] 标准输入通道 {0} 秒内未收到远端任何有效输出（载荷已完整写出并关闭）：远端可能尚未启动，也可能已启动但卡在标准输入读取或输出回传；当前无法仅凭本地零输出区分。请用远端体检与生产同形态复现核对远端进程和读取状态，不要直接归因为僵尸会话或安装脚本。已终止 ssh 进程树（PID {1}）。' -f [Math]::Min(90, $超时秒), $进程.Id)
			}
			throw ('[stdin超时] 标准输入通道收到 {0} 行有效输出后 {1} 秒再无进展（安装脚本静默段超过看门狗），已按看门狗终止 ssh 进程树（PID {2}）。远端可能残留 powershell，连接可安全重试。' -f $有效行数, $超时秒, $进程.Id)
		}
		if (-not $进程.WaitForExit(30000)) {
			try { & taskkill /PID $进程.Id /T /F 2>&1 | Out-Null } catch { }
			throw '[stdin超时] ssh 进程在读完后 30 秒内未退出，已强制终止。'
		}
		$退出码 = $进程.ExitCode
		if ($退出码 -ne 0) {
			# 远端 stderr 一并带出：否则失败时只剩一个退出码，排障要重新连一次才能看到真实原因
			$错误摘要 = ''
			try {
				if ($错误任务.IsCompleted) {
					$错误文本 = [string]$错误任务.Result
					if (-not [string]::IsNullOrWhiteSpace($错误文本)) { $错误摘要 = '；远端 stderr 摘要: ' + $错误文本.Substring(0, [Math]::Min(300, $错误文本.Length)).Trim() }
				}
			} catch { }
			throw ('SSH 执行失败（标准输入通道），退出码: {0}{1}' -f $退出码, $错误摘要)
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

	function 取-CLI下载地址 {
		param(
			[string]$发布通道,
			[string]$提交号,
			[string]$架构标识
		)

		# CLI 下载 artifact 与官方引导规则一致：armhf 用 cli-linux-armhf，Linux 其余用 cli-alpine-<短架构>，Windows 用 cli-win32-<短架构>
		$artifact名 = switch ($架构标识) {
			'linux-x64' { 'cli-alpine-x64' }
			'linux-arm64' { 'cli-alpine-arm64' }
			'linux-armhf' { 'cli-linux-armhf' }
			'win32-x64' { 'cli-win32-x64' }
			'win32-arm64' { 'cli-win32-arm64' }
			default { '' }
		}
		if ($artifact名 -eq '') { return '' }
		return ('https://update.code.visualstudio.com/commit:{0}/{1}/{2}' -f $提交号, $artifact名, $发布通道)
	}

	function 初始化-竞速上下文 {
		param(
			[pscustomobject]$环境,
			[string]$发布通道,
			[string]$提交号,
			[switch]$需要sysroot材料
		)

		# 汇总竞速所需信息：暂存目录（登录目录下 .vscode-server[-insiders]/race-<提交号>）与逐产物的包名/标记名/下载地址。
		# 竞速按产物独立进行（CLI 与服务端各竞速一次）：哪边能下载就由哪边供给，单边断网时另一边照样补上，互不拖累。
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
		$服务端下载地址 = ('https://vscode.download.prss.microsoft.com/dbazure/download/{0}/{1}/vscode-server-{2}{3}' -f $发布通道, $提交号, $架构标识, $包扩展名)
		$CLI下载地址 = 取-CLI下载地址 -发布通道 $发布通道 -提交号 $提交号 -架构标识 $架构标识

		# 远程侧约定的包名与标记名（与远程脚本内的命名保持一致；完成标记带架构后缀防串包，取消标记按产物区分让本地供给逐产物止损）
		$产物列表 = @(
			[pscustomobject]@{ 产物名 = 'CLI'; 下载地址列表 = @($CLI下载地址); 本地文件名 = ''; 远程包名 = ('LOCAL_CLI{0}' -f $包扩展名); 完成标记名 = ('LOCAL_CLI_DONE.{0}' -f $架构标识); 取消标记名 = 'LOCAL_CLI_CANCEL' }
			[pscustomobject]@{ 产物名 = '服务端'; 下载地址列表 = @($服务端下载地址); 本地文件名 = ''; 远程包名 = ('LOCAL{0}' -f $包扩展名); 完成标记名 = ('LOCAL_DONE.{0}' -f $架构标识); 取消标记名 = 'LOCAL_CANCEL' }
		)
		# sysroot 素材并入同一套竞速（旧 glibc 主机）：与 CLI/服务端同规则双端供给、断点续传，任一边能取到即可部署；素材文件名自带版本号，本地缓存名保持稳定跨提交号复用（.job 交接文件另按 race-supply-<提交号>-<名> 命名落 TEMP 根目录，上传器照常发现）
		if ($需要sysroot材料) {
			foreach ($素材 in 取-sysroot素材清单) {
				$产物列表 += [pscustomobject]@{ 产物名 = $素材.文件名; 下载地址列表 = @($素材.地址列表); 本地文件名 = ('vscode-sysroot-bundle\{0}' -f $素材.文件名); 远程包名 = $素材.文件名; 完成标记名 = ('LOCAL_BUNDLE_DONE.{0}' -f $素材.文件名); 取消标记名 = ('BUNDLE_CANCEL.{0}' -f $素材.文件名) }
			}
		}

		return [pscustomobject]@{
			暂存目录 = $暂存目录
			包扩展名 = $包扩展名
			提交号 = $提交号
			分隔符 = $分隔符
			架构标识 = $架构标识
			产物列表 = $产物列表
		}
	}

	function 启动-本地竞速供给 {
		param(
			[pscustomobject]$竞速上下文,
			[string]$连接目标,
			[int]$端口,
			[string]$系统类型
		)

		# 供给以独立子 powershell 进程运行（不再是 Start-Job 的同进程 runspace）：Start-Job 无法中断阻塞的网络调用，而子进程可在任意步骤被 taskkill /T /F 连同其派生的 ssh/scp 一起终止，实现真正的零轮询即时取消。本函数只启动调用方传入的产物清单；CLI 与服务端由回调按远端竞速顺序逐个传入，sysroot 素材则可按独立阶段批量传入。参数经 Clixml 文件传入子进程（避开命令行转义与 PS 5.1 原生 stderr 陷阱）；stdout/stderr 重定向到日志文件，收尾时回收打印。返回供给对象数组：{产物名;进程;日志路径;错误路径;参数文件路径}。
		$供给列表 = @()
		foreach ($产物 in $竞速上下文.产物列表) {
			$参数文件 = Join-Path $env:TEMP ('race-supply-param-{0}.xml' -f ([guid]::NewGuid().ToString('N')))
			$日志文件 = Join-Path $env:TEMP ('race-supply-log-{0}.txt' -f ([guid]::NewGuid().ToString('N')))
			$错误文件 = Join-Path $env:TEMP ('race-supply-err-{0}.txt' -f ([guid]::NewGuid().ToString('N')))

			@{
				产物名 = $产物.产物名
				连接目标 = $连接目标
				端口 = $端口
				密码选项 = @($script:SSH密码选项)
				暂存目录 = $竞速上下文.暂存目录
				下载地址列表 = @($产物.下载地址列表)
				本地文件名 = [string]$产物.本地文件名
				远程包名 = $产物.远程包名
				完成标记名 = $产物.完成标记名
				取消标记名 = $产物.取消标记名
				系统类型 = $系统类型
				分隔符 = $竞速上下文.分隔符
				提交号 = $竞速上下文.提交号
				架构标识 = $竞速上下文.架构标识
				# 父进程（本模块宿主）ID：子进程靠它做「父死即自终止」看护。主模块可能被 VS Code 直接杀掉（连接超时/用户取消），此时根本走不到下方的 等待-供给进程并回收日志，子进程会变成孤儿继续把 190MB 下完并死握共用缓存文件（实测堵死下一个连接八分钟）。0 = 不启用看护。
				父进程ID = $PID
			} | Export-Clixml -LiteralPath $参数文件

			$供给脚本 = Join-Path $script:模块根目录 'private\local-supply.ps1'
			$powershell命令 = Get-Command powershell -ErrorAction SilentlyContinue | Select-Object -First 1
			$powershellExe = if ($powershell命令) { $powershell命令.Source } else { 'powershell.exe' }

			$进程 = Start-Process -FilePath $powershellExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $供给脚本), ('"{0}"' -f $参数文件)) -RedirectStandardOutput $日志文件 -RedirectStandardError $错误文件 -WindowStyle Hidden -PassThru

			$供给列表 += [pscustomobject]@{
				产物名 = $产物.产物名
				进程 = $进程
				日志路径 = $日志文件
				错误路径 = $错误文件
				参数文件路径 = $参数文件
			}
			# 登记子进程日志供 转发-供给日志 增量转出（本地下载/上传进度随产生上屏）
			[void]$script:供给日志登记.Add([pscustomobject]@{ 产物名 = $产物.产物名; 路径 = $日志文件; 已读字节 = [long]0; 残段 = '' })
			[void]$script:供给日志登记.Add([pscustomobject]@{ 产物名 = $产物.产物名; 路径 = $错误文件; 已读字节 = [long]0; 残段 = '' })
		}
		return $供给列表
	}

	function 停止-供给进程树 {
		param(
			$供给
		)

		# 击杀供给进程树（$供给 可为单个供给对象或数组，逐个处理）：taskkill /T 连同其派生的 ssh/scp 子进程一起终止；
		# PS 5.1 的 .NET Process.Kill() 只杀单进程不含子进程，更无法中断子进程内阻塞的下载/上传，故用 taskkill。
		foreach ($单个供给 in @($供给)) {
			if ($null -eq $单个供给 -or $null -eq $单个供给.进程) { continue }
			$proc = $单个供给.进程
			try { $proc.Refresh() } catch { }
			if ($proc.HasExited) { continue }
			$原始EAP = $ErrorActionPreference
			try {
				$ErrorActionPreference = 'Continue'
				$null = & taskkill.exe /PID $proc.Id /T /F 2>&1
			} finally {
				$ErrorActionPreference = $原始EAP
			}
		}
	}

	function 转发-供给日志 {
		param([switch]$收尾)

		# 增量转出供给子进程日志（[本地供给-产物名] 前缀，与收尾打印同格式）：按登记的字节偏移续读，半行残段留待拼齐再发；-收尾 把残段也作为一行发出。日志文件用共享读打开（子进程仍在写），读不到按缺失跳过
		foreach ($登记 in @($script:供给日志登记)) {
			$新增文本 = ''
			try {
				$读取流 = New-Object System.IO.FileStream($登记.路径, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
				try {
					[void]$读取流.Seek($登记.已读字节, [System.IO.SeekOrigin]::Begin)
					$读取器 = New-Object System.IO.StreamReader($读取流, [System.Text.Encoding]::Default)
					$新增文本 = $读取器.ReadToEnd()
					$登记.已读字节 = $读取流.Position
				} finally {
					$读取流.Dispose()
				}
			} catch {
				continue
			}
			$段落 = @(($登记.残段 + $新增文本) -split "`r?`n")
			$登记.残段 = $段落[$段落.Count - 1]
			if ($段落.Count -gt 1) {
				foreach ($行 in $段落[0..($段落.Count - 2)]) {
					Write-Host ('[本地供给-{0}] {1}' -f $登记.产物名, $行)
				}
			}
		}
		if ($收尾) {
			foreach ($登记 in @($script:供给日志登记)) {
				if (-not [string]::IsNullOrEmpty($登记.残段)) {
					Write-Host ('[本地供给-{0}] {1}' -f $登记.产物名, $登记.残段)
					$登记.残段 = ''
				}
			}
		}
	}

	function 刷新-接管输出缓冲 {
		# 主输出缓冲由「新行到达」触发刷出，远端安静时段没有新行就不会刷；等待滴答里调用接管安装实现注册的钩子补刷（模块被单独调用时无此钩子，跳过）
		$钩子 = Get-Variable -Name 接管安装刷出缓冲钩子 -Scope Global -ValueOnly -ErrorAction SilentlyContinue
		if ($null -ne $钩子) {
			& $钩子
		}
	}

	function 等待-供给进程并回收日志 {
		param(
			$供给
		)

		# 收尾：兜底击杀残留供给进程树、等待退出，补发日志残余（正文已随产生实时转发，见 转发-供给日志），再删除临时文件（均失败无害）
		foreach ($单个供给 in @($供给)) {
			if ($null -eq $单个供给) { continue }
			停止-供给进程树 -供给 $单个供给
			if ($null -ne $单个供给.进程) {
				try { $null = $单个供给.进程.WaitForExit(10000) } catch { }
			}
		}
		转发-供给日志 -收尾
		foreach ($单个供给 in @($供给)) {
			if ($null -eq $单个供给) { continue }
			foreach ($临时文件 in @($单个供给.日志路径, $单个供给.错误路径, $单个供给.参数文件路径)) {
				if (-not [string]::IsNullOrWhiteSpace($临时文件)) {
					Remove-Item -LiteralPath $临时文件 -Force -ErrorAction SilentlyContinue
				}
			}
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

	function 探测-远程内核版本 {
		param(
			[string]$连接目标,
			[int]$端口
		)

		# 解析 uname -r 的主次版本号（如 2.6.32-504.el6.x86_64 → 2.6）；探测失败返回 $null
		$结果 = 执行-SSH命令并捕获 -连接目标 $连接目标 -端口 $端口 -命令文本 'uname -r'
		if ($结果.退出码 -ne 0) { return $null }
		foreach ($行 in $结果.输出) {
			$文本 = ([string]$行).Trim()
			if ($文本 -match '^(\d+\.\d+)') {
				try { return [version]$Matches[1] } catch { return $null }
			}
		}
		return $null
	}

	function 取-sysroot素材清单 {
		# sysroot 素材定义（glibc/libstdc++/libgcc 的 CentOS 8 RPM + patchelf 0.18 静态二进制，共约 5MB）：本地供给与远程自下载共用同一地址列表
		# vault.centos.org 对无 UA 请求返回 403，故走清华/阿里镜像并显式 UA；patchelf 用 GitHub Release 官方静态包（0.17.x 有 segfault 问题，官方要求 >= 0.18），并附 GitHub 加速镜像作备源（部分网络 GitHub 直连不可达，实测 ghfast.top 可达）
		$镜像前缀列表 = @(
			'https://mirrors.tuna.tsinghua.edu.cn/centos-vault/8.5.2111/BaseOS/x86_64/os/Packages',
			'https://mirrors.aliyun.com/centos-vault/8.5.2111/BaseOS/x86_64/os/Packages'
		)
		$清单 = New-Object System.Collections.ArrayList
		foreach ($rpm名称 in @('glibc-2.28-164.el8.x86_64.rpm', 'libstdc++-8.5.0-4.el8_5.x86_64.rpm', 'libgcc-8.5.0-4.el8_5.x86_64.rpm')) {
			[void]$清单.Add([pscustomobject]@{ 文件名 = $rpm名称; 地址列表 = @($镜像前缀列表 | ForEach-Object { $_ + '/' + $rpm名称 }) })
		}
		$patchelf地址 = 'https://github.com/NixOS/patchelf/releases/download/0.18.0/patchelf-0.18.0-x86_64.tar.gz'
		[void]$清单.Add([pscustomobject]@{
			文件名 = 'patchelf-0.18.0-x86_64.tar.gz'
			地址列表 = @($patchelf地址, ('https://ghfast.top/{0}' -f $patchelf地址), ('https://gh-proxy.com/{0}' -f $patchelf地址))
		})
		return @($清单)
	}

	function 上传-一批文件到远程 {
		param(
			[string[]]$本地路径,
			[string]$连接目标,
			[int]$端口,
			[string]$远程目录
		)

		# 多文件一次连接上传（scp 单次调用接受多个源）：把逐文件上传的 N 次连接开销压成 1 次（慢速主机上每次连接可达数十秒）
		$SCP命令 = Get-Command scp -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $SCP命令) {
			throw '未找到 scp 命令。请确保已安装 OpenSSH 客户端。'
		}
		$目标 = '{0}:{1}/' -f $连接目标, $远程目录.TrimEnd('/', '\')

		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			& $SCP命令.Source (@('-P', $端口) + $script:SSH密码选项 + $本地路径 + @($目标)) 2>&1 | Out-Null
		} finally {
			$ErrorActionPreference = $原始EAP
		}
		if ($LASTEXITCODE -eq 0) {
			return
		}

		# 与单文件上传同款回退：SFTP 失败时用经典 SCP 协议（-O）补传一次，远端真实报错（如磁盘配额）才能回显
		$原始EAP = $ErrorActionPreference
		try {
			$ErrorActionPreference = 'Continue'
			$诊断输出 = @(& $SCP命令.Source (@('-O', '-P', $端口) + $script:SSH密码选项 + $本地路径 + @($目标)) 2>&1)
		} finally {
			$ErrorActionPreference = $原始EAP
		}
		if ($LASTEXITCODE -eq 0) {
			return
		}
		$远端错误 = ($诊断输出 | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() }) -join "`n"
		throw ('SCP 批量上传失败，退出码: {0}。目标 {1}。{2}{3}' -f $LASTEXITCODE, $目标, "`n", $远端错误)
	}

	function 构造-保活部署文本 {
		param(
			[string]$远程登录目录,
			[string]$提交号,
			[string]$发布通道,
			[ValidateSet('部署', '移除')][string]$动作,
			[string]$包装模板远程路径,
			[string]$改名模板远程路径
		)

		# 保活部署脚本的占位符填充：把 Remote-SSH exec server 的启动入口 CLI（<数据根目录>/code[-insiders]-<提交号>）替换为包装脚本
		# （真正启动的 command-shell 以「双 fork + setsid」拉起、与 sshd 会话祖先链断开而存活；真身另存数据目录之外避开官方 GC）
		$根目录 = $远程登录目录.TrimEnd('/', '\')
		$数据目录名 = if ($发布通道 -eq 'insider') { '.vscode-server-insiders' } else { '.vscode-server' }
		$CLI基础名 = if ($发布通道 -eq 'insider') { 'code-insiders' } else { 'code' }

		$文本 = $script:脚本_服务保活部署
		$文本 = $文本.Replace('__动作__', $动作)
		$文本 = $文本.Replace('__数据目录__', ($根目录 + '/' + $数据目录名))
		$文本 = $文本.Replace('__服务保活目录__', ($根目录 + '/.vscode-persistent'))
		$文本 = $文本.Replace('__CLI文件名__', ($CLI基础名 + '-' + $提交号))
		$文本 = $文本.Replace('__当前提交号__', $提交号)
		$文本 = $文本.Replace('__发布通道__', $发布通道)
		$文本 = $文本.Replace('__改名器路径__', $改名模板远程路径)
		return $文本.Replace('__包装脚本路径__', $包装模板远程路径)
	}

	function 生成-接管编排脚本 {
		param(
			[string]$暂存目录,
			[string]$兼容性目录
		)

		# 单会话编排脚本：模板存于 private\接管编排脚本模板.sh（脚本正文一律独立成文件，不在字符串里内嵌），把 sysroot 部署、安装、原生补丁、保活检修、收尾清理串成一个 sh 脚本，由 执行-接管编排 随同一批阶段文件上传后一次性执行（每次 SSH 连接的开销在慢速主机上不可接受）。
		# 各阶段段落以对应阶段文件是否上传为门（上传条件与阶段启用条件一一对应），未上传即整段跳过，与旧的按需拼接等价；阶段失败语义不变：安装按其退出码中止、sysroot/保活失败中止（20/21）、原生补丁失败仅告警。
		return $script:脚本_接管编排模板.Replace('__暂存目录__', $暂存目录).Replace('__兼容性目录__', $兼容性目录)
	}

	function 建立-接管会话 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$预备命令
		)

		# 单会话帧协议：一条 SSH 连接内完成 探测 → 等待本地备好阶段文件 → 逐帧上传 → 就地执行 全程。
		# 远端引导体经 base64 编码后由 echo | base64 -d 写入远端临时文件再由 sh 执行（写文件而不在命令里内嵌正文，任何 POSIX 登录 shell 都能启动、彻底避开引号/括号转义问题；关键：sh 的 stdin 必须是 ssh 通道本身，帧循环才能收到后续帧——不能用 echo | base64 -d | sh，那样 sh 的 stdin 是脚本管道、读完即 EOF，帧循环秒退且看似成功）；Windows 远端没有 sh/base64 会立即失败，由调用方回退离散流程。
		# stdin 是帧通道，四类帧：__FILE__（<字节数>\n<裸名>\n<裸字节>，落盘 $HOME/）、__CMD__（一行命令静默执行，用于改名+写标记，帧序即“先文件后改名”的原子序，坏包/截断包永远不会被就位）、__RUN__（一行命令，后台起编排，输出继承会话 stdout 回传，结束时回传 __ORCH_EXIT__=N 退出码）、__EXIT__（收尾退循环）。编排运行期间帧循环不退，供给产物的上传帧可随时插入——单会话由主线程（读输出）与上传器线程（写帧）双工占用；写入仅由一方执行，无并发写入风险。
		$帧循环 = $script:脚本_会话帧循环
		$引导体 = ((取-环境探测命令) -replace "`r`n", "`n")
		if (-not [string]::IsNullOrWhiteSpace($预备命令)) {
			$引导体 = $引导体 + "`n" + $预备命令
		}
		$引导体 = $引导体 + "`n" + $帧循环
		$编码 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($引导体))
		# 引导体先落远端临时文件再由 sh 执行：sh 的 stdin 得以保持为 ssh 通道（帧循环的 read 收帧）；不用 echo | base64 -d | sh 是因为那样 sh 的 stdin 是脚本管道、读完即 EOF，帧循环秒退且退出码 0 看似成功
		$临时名 = '.vscode-boot-' + ([guid]::NewGuid().ToString('N').Substring(0, 8)) + '.sh'
		$启动命令 = 'echo ' + $编码 + ' | base64 -d > ~/' + $临时名 + ' && sh ~/' + $临时名 + '; rm -f ~/' + $临时名

		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $ssh命令) {
			throw '未找到 ssh 命令，无法连接远程服务器。'
		}
		# 注意不能带 -n（stdin 归 /dev/null）：帧通道就在 stdin 上；BatchMode 必带——否则免密失败时 ssh 会从帧通道里抢读密码
		$参数串 = '-p ' + $端口 + ' -o BatchMode=yes -o ConnectTimeout=10'
		foreach ($项 in $script:SSH密码选项) {
			$参数串 = $参数串 + ' "' + $项 + '"'
		}
		$参数串 = $参数串 + ' ' + $连接目标 + ' "' + $启动命令 + '"'
		$psi = New-Object System.Diagnostics.ProcessStartInfo
		# .cmd/.bat 包装的 ssh（某些环境用批处理包装）不能被 CreateProcess 直接启动，包一层 cmd /c
		if ($ssh命令.Source -match '\.(cmd|bat)$') {
			$psi.FileName = 'cmd.exe'
			$psi.Arguments = '/c ""' + $ssh命令.Source + '" ' + $参数串 + '"'
		} else {
			$psi.FileName = $ssh命令.Source
			$psi.Arguments = $参数串
		}
		$psi.UseShellExecute = $false
		$psi.RedirectStandardInput = $true
		$psi.RedirectStandardOutput = $true
		$psi.RedirectStandardError = $true
		$psi.CreateNoWindow = $true
		$进程 = [System.Diagnostics.Process]::Start($psi)
		$错误任务 = $进程.StandardError.ReadToEndAsync()
		# 牺牲行吸收 StreamWriter 首次写入的 UTF-8 BOM 前导（实测 ef bb bf 会贴在第一帧行首导致帧型匹配失败、整条帧流错位）：带换行的整行连 BOM 一起被远端帧循环当未知帧忽略，其后的真帧（BaseStream 字节直写）不受污染
		$进程.StandardInput.Write('预热行-吸收编码前导' + "`n")
		$进程.StandardInput.Flush()

		return [pscustomobject]@{
			进程 = $进程
			标准输入 = $进程.StandardInput
			标准输出 = $进程.StandardOutput
			错误任务 = $错误任务
		}
	}

	function 读取-会话探测 {
		param($会话)

		# 读到 PROBE_END 为止返回全部输出行；到 EOF 都没见标记返回 $null（非 POSIX 远端或免密失败），由调用方回退离散流程
		$行 = New-Object System.Collections.Generic.List[string]
		while ($true) {
			$文本 = $会话.标准输出.ReadLine()
			if ($null -eq $文本) { return $null }
			$行.Add($文本)
			if ($文本 -match 'PROBE_END') { return $行 }
		}
	}

	function 发送-会话帧文件 {
		param($会话, [string]$本地路径, [string]$远端名)
		$字节 = [System.IO.File]::ReadAllBytes($本地路径)
		$头 = [System.Text.Encoding]::UTF8.GetBytes("__FILE__`n" + $字节.Length + "`n" + [string]$远端名 + "`n")
		# 必须走 BaseStream 字节直写：StreamWriter.Write(byte[]) 会被强转 char[] 再按文本编码，二进制帧字节被改写、远端 head -c 永远等不齐
		$会话.标准输入.BaseStream.Write($头, 0, $头.Length)
		$会话.标准输入.BaseStream.Write($字节, 0, $字节.Length)
	}

	function 发送-会话命令帧 {
		param($会话, [string]$命令文本)
		$字节 = [System.Text.Encoding]::UTF8.GetBytes("__CMD__`n" + $命令文本 + "`n")
		$会话.标准输入.BaseStream.Write($字节, 0, $字节.Length)
	}

	function 发送-会话阶段 {
		param(
			$会话,
			$文件清单,
			[string]$运行命令,
			[scriptblock]$每行回调,
			[string]$交接目录,
			[string]$交接匹配
		)

		# 阶段文件逐帧送出 + RUN 帧后台起编排；随后启动上传器线程（消费供给的 .job 交接文件）并流式读输出到 __ORCH_EXIT__。
		# 写入次序严格互斥：阶段帧与 RUN 帧由本线程写完，上传器才启动（之后 stdin 只由它写），收尾停传后再送 __EXIT__。
		foreach ($文件 in $文件清单) {
			发送-会话帧文件 -会话 $会话 -本地路径 $文件.路径 -远端名 $文件.名
		}
		$运行帧 = [System.Text.Encoding]::UTF8.GetBytes("__RUN__`n" + $运行命令 + "`n")
		$会话.标准输入.BaseStream.Write($运行帧, 0, $运行帧.Length)
		$会话.标准输入.Flush()

		$上传器 = 启动-帧上传器 -会话 $会话 -扫描目录 $交接目录 -匹配模式 $交接匹配
		$编排退出码 = $null
		try {
			while ($true) {
				# 异步读 + 无输出看门狗：帧流错位或远端卡死时没有任何输出，同步 ReadLine 会永久挂起，这里 30 分钟无输出即带诊断中止
				$读取任务 = $会话.标准输出.ReadLineAsync()
				$静默累计毫秒 = 0
				while (-not $读取任务.Wait(1000)) {
					# 等待按 1 秒切片：每秒转出供给日志新行（本地下载/上传进度实时上屏）并补刷主输出缓冲（远端安静时没有新行触发刷出，上一段末行会滞留）
					$静默累计毫秒 += 1000
					if ($静默累计毫秒 -ge 1800000) {
						throw '单会话 30 分钟无任何输出（远端帧流可能已错位或编排卡死），放弃等待。'
					}
					转发-供给日志
					刷新-接管输出缓冲
				}
				$文本行 = $读取任务.Result
				if ($null -eq $文本行) { break }
				if ($文本行 -match '^__FRAME_TRUNCATED__') {
					throw ('远端报告帧数据不完整（发端字节被改写或传输错位）：{0}' -f $文本行)
				}
				if ($文本行 -match '^__ORCH_EXIT__=(\d+)') {
					$编排退出码 = [int]$Matches[1]
					break
				}
				$净化 = 剥离-终端控制序列 $文本行
				Write-Host $净化
				if ($每行回调) { & $每行回调 $净化 }
			}
		} finally {
			# 先送 EXIT 再停上传器：上传器可能正在写遗留供给的大帧，先停会卡在等帧写完；EXIT 或随后的 stdin 关闭（EOF）都会让远端帧循环退出
			try {
				$退出帧 = [System.Text.Encoding]::UTF8.GetBytes("__EXIT__`n")
				$会话.标准输入.BaseStream.Write($退出帧, 0, $退出帧.Length)
				$会话.标准输入.Flush()
			} catch { }
			停止-帧上传器 $上传器
		}
		if ($null -eq $编排退出码) {
			throw '单会话执行异常：未收到编排退出码（会话提前中断）。'
		}
		if ($编排退出码 -ne 0) {
			throw ('接管编排执行失败，退出码: {0}' -f $编排退出码)
		}
	}

	function 启动-帧上传器 {
		param($会话, [string]$扫描目录, [string]$匹配模式)

		# 上传器 = 独立 runspace 线程：消费本次运行的 race-supply-<提交号>-*.job 交接文件（供给下载完成后写入）并按“文件帧→命令帧”序送出；按提交号过滤，历史残留的交接文件（旧提交号大包）不碰，否则会被拖死。
		# 与主线程（读输出）双工占用同一会话：写 stdin 的只有本线程（阶段帧在它启动前已送完），无并发写入风险。
		$运行空间 = [runspacefactory]::CreateRunspace()
		$运行空间.Open()
		$运行空间.SessionStateProxy.SetVariable('输入流', $会话.标准输入.BaseStream)
		$运行空间.SessionStateProxy.SetVariable('扫描目录', $扫描目录)
		$运行空间.SessionStateProxy.SetVariable('匹配模式', $匹配模式)
		$运行空间.SessionStateProxy.SetVariable('停止标志', $false)
		$ps = [powershell]::Create()
		$ps.Runspace = $运行空间
		[void]$ps.AddScript({
			while ($true) {
				if ((Get-Variable -Name 停止标志 -ValueOnly)) { break }
				Get-ChildItem -LiteralPath $扫描目录 -Filter $匹配模式 -ErrorAction SilentlyContinue | ForEach-Object {
					try {
						$交接 = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
						$字节 = [System.IO.File]::ReadAllBytes([string]$交接.数据文件)
						$头 = [System.Text.Encoding]::UTF8.GetBytes("__FILE__`n" + $字节.Length + "`n" + [string]$交接.远端名 + "`n")
						$输入流.Write($头, 0, $头.Length)
						$输入流.Write($字节, 0, $字节.Length)
						$尾 = [System.Text.Encoding]::UTF8.GetBytes("__CMD__`n" + [string]$交接.完成命令 + "`n")
						$输入流.Write($尾, 0, $尾.Length)
						$输入流.Flush()
						Remove-Item -LiteralPath $_.FullName -Force
						Remove-Item -LiteralPath ([string]$交接.数据文件) -Force -ErrorAction SilentlyContinue
					} catch { }
				}
				Start-Sleep -Milliseconds 500
			}
		})
		$句柄 = $ps.BeginInvoke()
		return @{ 运行空间 = $运行空间; PS = $ps; 句柄 = $句柄 }
	}

	function 停止-帧上传器 {
		param($上传器)
		if ($null -eq $上传器) { return }
		try { $上传器.运行空间.SessionStateProxy.SetVariable('停止标志', $true) } catch { }
		# 异步等待 + 超时强停：上传器可能正卡在大帧写入（遗留供给），阻塞式 EndInvoke 会把收尾拖死
		try {
			if (-not $上传器.句柄.AsyncWaitHandle.WaitOne(3000)) { $上传器.PS.Stop() }
		} catch { }
		try { $上传器.PS.Dispose() } catch { }
		try { $上传器.运行空间.Dispose() } catch { }
	}

	function 关闭-接管会话 {
		param($会话)
		# 不 Dispose 进程对象：调用方还靠 HasExited 判断会话是否可用（Dispose 后查询会抛异常）
		try { $会话.标准输入.Close() } catch { }
		try { if (-not $会话.进程.HasExited) { $会话.进程.Kill() } } catch { }
	}

	function 执行-接管编排 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$远程登录目录,
			[string]$提交号,
			[string]$发布通道,
			[string]$安装脚本文本,
			[bool]$需要sysroot阶段,
			[bool]$需要保活阶段,
			[ValidateSet('部署', '移除')][string]$保活动作,
			$竞速上下文,
			[scriptblock]$每行回调,
			# 单会话通道（非交互场景）：阶段文件从其 stdin 逐帧送入、就地执行；为 $null 或已退出时回退离散上传+执行
			$会话
		)

		# 一次批量上传 + 一次远程会话跑完全部阶段（sysroot → 安装 → 原生补丁 → 保活 → 清理）：慢速主机上每条 SSH 往返可达数十秒，逐阶段上传+执行的连接开销远超干活本身。未见「编排完成」标记（异常退出）时才在 finally 兜底清理远端暂存文件（失败无害）。
		$根目录 = $远程登录目录.TrimEnd('/', '\')
		$暂存目录 = if ($null -ne $竞速上下文) { $竞速上下文.暂存目录 } else { '' }
		$兼容性目录 = $根目录 + '/vscode-sysroot'
		$本地目录 = Join-Path $env:TEMP ('接管编排-{0}' -f ([guid]::NewGuid().ToString('N')))
		[void](New-Item -ItemType Directory -Path $本地目录 -Force)

		$上传清单 = New-Object System.Collections.Generic.List[string]
		$落盘 = {
			param($名字, $内容)
			$路径 = Join-Path $本地目录 $名字
			# Linux sh 脚本要求 LF 行尾且不得带 BOM，否则 shebang 与语法会出错
			[System.IO.File]::WriteAllText($路径, ($内容 -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
			[void]$上传清单.Add($路径)
		}

		$编排状态 = @{ 已完成 = $false }
		$包装回调 = {
			param($行)
			if ($null -ne $每行回调) { & $每行回调 $行 }
			if ($行 -match '接管安装-编排\] 编排完成') { $编排状态.已完成 = $true }
		}.GetNewClosure()

		try {
			& $落盘 'vsi-stage-orch.sh' (生成-接管编排脚本 -暂存目录 $暂存目录 -兼容性目录 $兼容性目录)
			if ($null -ne $安装脚本文本) {
				& $落盘 'vsi-stage-install.sh' $安装脚本文本
			}
			if ($需要sysroot阶段) {
				& $落盘 'vsi-stage-native.sh' ($script:脚本_原生组件补丁.Replace('__提交号__', $提交号).Replace('__发布通道__', $发布通道))
				# sysroot 素材走双端竞速：本地供给进程（竞速产物，断点续传多源下载）与远程自下载（部署脚本的取材阶段，多源断点续传）并行、先到先得，不再随批上传 bundle；地址列表两共，任一边能取到即可部署
				$取材行 = @(取-sysroot素材清单 | ForEach-Object { "start_fetch '{0}' {1}" -f $_.文件名, (($_.地址列表 | ForEach-Object { "'{0}'" -f $_ }) -join ' ') })
				$取材行 += ('wait_fetch {0} || exit 1' -f ((取-sysroot素材清单 | ForEach-Object { "'{0}'" -f $_.文件名 }) -join ' '))
				& $落盘 'vsi-stage-sysroot.sh' ($script:脚本_sysroot部署.Replace('__目录__', $兼容性目录).Replace('__竞速暂存目录__', $暂存目录).Replace('__取材阶段__', ($取材行 -join "`n")))
			}
			if ($需要保活阶段) {
				& $落盘 'vsi-stage-keepalive.sh' (构造-保活部署文本 -远程登录目录 $远程登录目录 -提交号 $提交号 -发布通道 $发布通道 -动作 $保活动作 -包装模板远程路径 ($根目录 + '/vsi-stage-wrapper.sh') -改名模板远程路径 ($根目录 + '/vsi-stage-renamer.js'))
				& $落盘 'vsi-stage-wrapper.sh' $script:脚本_服务保活包装
				& $落盘 'vsi-stage-renamer.js' $script:脚本_服务保活改名器
			}

			if ($null -ne $会话 -and -not $会话.进程.HasExited) {
				# 单会话路径：阶段帧 + RUN 帧 + 供给交接帧 全走这一条连接，省掉独立上传/改名的每条连接开销
				Write-Host '编排经单会话帧通道执行（全部阶段共用这一条连接）。'
				$帧清单 = @()
				foreach ($路径 in $上传清单) {
					$帧清单 += @{ 路径 = $路径; 名 = [System.IO.Path]::GetFileName($路径) }
				}
				发送-会话阶段 -会话 $会话 -文件清单 $帧清单 -运行命令 'sh vsi-stage-orch.sh' -每行回调 $包装回调 -交接目录 $env:TEMP -交接匹配 ('race-supply-{0}-*.job' -f $提交号)
			} else {
				$会话状态 = if ($null -eq $会话) { '对象为空' } elseif ($会话.进程.HasExited) { ('进程已退出，退出码 ' + $会话.进程.ExitCode) } else { '进程仍在运行' }
				Write-Host ('单会话不可用（{0}），编排回退离散上传+执行（多条连接）。' -f $会话状态)
				if ($null -ne $会话) {
					try {
						$null = $会话.错误任务.Wait(1500)
						if ($会话.错误任务.IsCompleted -and -not [string]::IsNullOrWhiteSpace($会话.错误任务.Result)) { Write-Host ('单会话错误流: {0}' -f ($会话.错误任务.Result.Trim())) }
					} catch { }
				}
				上传-一批文件到远程 -本地路径 $上传清单.ToArray() -连接目标 $连接目标 -端口 $端口 -远程目录 $根目录
				执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 'sh vsi-stage-orch.sh' -TTY -每行回调 $包装回调
			}
		} finally {
			Remove-Item -LiteralPath $本地目录 -Recurse -Force -ErrorAction SilentlyContinue
			if ($null -ne $会话) {
				关闭-接管会话 $会话
			}
			if (-not $编排状态.已完成) {
				# 异常退出兜底：清掉远端暂存的阶段文件与竞速暂存目录（失败无害；正常路径已由编排脚本收尾）
				$清理命令 = if ($暂存目录 -ne '') { ('rm -f vsi-stage-*; rm -rf ''{0}'' 2>/dev/null' -f $暂存目录) } else { 'rm -f vsi-stage-*' }
				try { 执行-SSH命令 -连接目标 $连接目标 -端口 $端口 -命令文本 $清理命令 } catch { }
			}
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

	function 初始化-竞速上下文-Windows单会话 {
		param(
			[string]$发布通道,
			[string]$提交号
		)

		# Windows 单会话模式的竞速上下文：无需探测登录目录与架构——远端脚本自行推算暂存目录，本地供给用相对路径 scp；架构固定 win32-x64（PS2 老主机由引导版本门回退离散流程，其路径同样硬编码此架构；ARM64远端会在标记核对时拒收异架构包，改由远程自下载供给）
		$架构标识 = 'win32-x64'
		$数据目录名 = if ($发布通道 -eq 'insider') { '.vscode-server-insiders' } else { '.vscode-server' }
		$服务端下载地址 = ('https://vscode.download.prss.microsoft.com/dbazure/download/{0}/{1}/vscode-server-{2}.zip' -f $发布通道, $提交号, $架构标识)
		$CLI下载地址 = 取-CLI下载地址 -发布通道 $发布通道 -提交号 $提交号 -架构标识 $架构标识
		$产物列表 = @(
			[pscustomobject]@{ 产物名 = 'CLI'; 下载地址列表 = @($CLI下载地址); 本地文件名 = ''; 远程包名 = 'LOCAL_CLI.zip'; 完成标记名 = ('LOCAL_CLI_DONE.{0}' -f $架构标识); 取消标记名 = 'LOCAL_CLI_CANCEL' }
			[pscustomobject]@{ 产物名 = '服务端'; 下载地址列表 = @($服务端下载地址); 本地文件名 = ''; 远程包名 = 'LOCAL.zip'; 完成标记名 = ('LOCAL_DONE.{0}' -f $架构标识); 取消标记名 = 'LOCAL_CANCEL' }
		)
		return [pscustomobject]@{
			暂存目录 = '{0}/race-{1}' -f $数据目录名, $提交号
			包扩展名 = '.zip'
			提交号 = $提交号
			分隔符 = '/'
			架构标识 = $架构标识
			产物列表 = $产物列表
		}
	}

	function 新建-供给回调 {
		param(
			[pscustomobject]$竞速上下文,
			[string]$连接目标,
			[int]$端口,
			[string]$系统类型
		)

		# 本地供给与远端使用同一产物顺序：预备后只启动第一个待装产物，收到该产物的决出行才启动下一个；同一产物内部仍是本地与远程并行竞速。
		$供给容器 = New-Object System.Collections.ArrayList
		$待启动队列 = New-Object System.Collections.ArrayList
		$已启动产物 = New-Object 'System.Collections.Generic.HashSet[string]'
		$调度状态 = @{ 已结束 = $false }
		$启动动作 = ${function:启动-本地竞速供给}
		$停止动作 = ${function:停止-供给进程树}
		$启动下一产物 = {
			if ($调度状态.已结束 -or $待启动队列.Count -eq 0) { return }
			$产物名 = [string]$待启动队列[0]
			$待启动队列.RemoveAt(0)
			$子上下文 = [pscustomobject]@{
				暂存目录 = $竞速上下文.暂存目录
				包扩展名 = $竞速上下文.包扩展名
				提交号 = $竞速上下文.提交号
				分隔符 = $竞速上下文.分隔符
				架构标识 = $竞速上下文.架构标识
				产物列表 = @($竞速上下文.产物列表 | Where-Object { $_.产物名 -eq $产物名 })
			}
			foreach ($单个 in (& $启动动作 -竞速上下文 $子上下文 -连接目标 $连接目标 -端口 $端口 -系统类型 $系统类型)) {
				[void]$供给容器.Add($单个)
			}
			[void]$已启动产物.Add($产物名)
		}.GetNewClosure()
		$回调 = {
			param($行)
			if (-not $调度状态.已结束 -and $行 -match '^__接管预备完成__(.*)$') {
				$待装列表 = @($Matches[1] -split '\s+' | Where-Object { $_ })
				foreach ($产物 in $竞速上下文.产物列表) {
					if (($待装列表 -contains $产物.产物名) -and -not $已启动产物.Contains($产物.产物名) -and -not $待启动队列.Contains($产物.产物名)) {
						[void]$待启动队列.Add([string]$产物.产物名)
					}
				}
				& $启动下一产物
			}
			if ($行 -match '竞速获胜|本轮零下载') {
				$调度状态.已结束 = $true
				$待启动队列.Clear()
				& $停止动作 -供给 @($供给容器.ToArray())
			}
			# 本地或远程任一方决出当前产物，都推进到下一个产物；远程获胜时同时停止该产物的本地供给，保留按产物即时止损。
			if (-not $调度状态.已结束 -and $行 -match '竞速决出：(?<产物>[^\s]+?)\s*由(?<获胜方>远程自下载|本地供给)获胜') {
				$产物名 = $Matches['产物']
				if ($Matches['获胜方'] -eq '远程自下载') {
					& $停止动作 -供给 @($供给容器.ToArray() | Where-Object { $_.产物名 -eq $产物名 })
				}
				for ($i = $待启动队列.Count - 1; $i -ge 0; $i--) {
					if ([string]$待启动队列[$i] -eq $产物名) { $待启动队列.RemoveAt($i) }
				}
				& $启动下一产物
			}
		}.GetNewClosure()
		return [pscustomobject]@{ 回调 = $回调; 供给容器 = $供给容器 }
	}

	function 执行-Windows单会话安装 {
		param(
			[string]$连接目标,
			[int]$端口,
			[string]$脚本文本,
			[pscustomobject]$竞速上下文
		)

		# Windows 单会话全流程：探测/预备/安装/竞速监控/暂存收尾一条 ssh 全包。载荷（安装脚本正文去整行注释与空行后 gzip+base64）嵌进单会话引导后，整段走 **stdin** 下发；argv里只放固定极小的 stdin 引导（private\windows-stdin-bootstrap.ps1）的 EncodedCommand，命令行长度从此与安装脚本大小解耦。
		# 旧结论「不走 stdin（实测远端默认 shell 对 stdin 收尾不可靠，挂死率高且远端留僵尸进程）」已被 2026-10-22 真机实测推翻：
		#   ① 远端 sshd DefaultShell = powershell.exe（不是 cmd.exe，故无 8191 字符命令行上限）；
		#   ② 远端读全量 stdin → 去掉一切空白 → base64 解码，2KB/40KB/120KB/400KB 四档的长度与 SHA256 双判据全部一致、退出码 0、单程约 1 秒（本地 PowerShell 在管道结束时关闭 ssh 的标准输入，EOF 确定送达，无需赌收尾）。
		# 而旧做法实测致命：双重 base64 使 argv 达 37,950 字符 > CreateProcess 上限 32,767 → ssh.exe 拒绝启动（Program 'ssh.exe' failed to run: The filename or extension is too long）→ preconnect 退出码 1→Remote-SSH 判 PreconnectScriptFailure（Session Summary「预连接脚本已失败」）→ 整条连接夭折，窗口再也重连不上。
		# 引导自带 PS2 版本门：命中打 __PS2__ 标记并退出 0，调用方据此回退离散流程。返回 '完成' 或 'PS2'。
		$精简正文 = (($脚本文本 -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join "`n"
		$压缩流 = New-Object System.IO.MemoryStream
		$压缩器 = New-Object System.IO.Compression.GZipStream($压缩流, [System.IO.Compression.CompressionMode]::Compress)
		$正文字节 = [System.Text.Encoding]::UTF8.GetBytes($精简正文)
		$压缩器.Write($正文字节, 0, $正文字节.Length)
		$压缩器.Close()
		$载荷 = [Convert]::ToBase64String($压缩流.ToArray())
		$引导脚本 = $script:脚本_单会话引导.Replace('__载荷__', $载荷)
		$引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($引导脚本))
		# ===== 传输通道：载荷走 stdin，argv 只装固定引导 =====
		$固定引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:脚本_stdin引导))
		if ($固定引导码.Length -gt 8000) {
			# 守卫：本文件是 argv 里**唯一**随模板增长的部件（载荷已不再进 argv），一旦变胖就可能把整条命令行顶穿上限。
			throw ('stdin 固定引导过长（EncodedCommand {0} 字符 > 8000），请精简 private\windows-stdin-bootstrap.ps1；它的长度直接决定 argv 占用，必须远小于命令行上限 32767。' -f $固定引导码.Length)
		}
		$载荷标准输入 = $引导码
		# 整段一次写入、不分块：远端 windows-stdin-bootstrap.ps1 是 ReadToEndAsync 读全量后 `-replace '\s',''` 剔掉**全部空白**再 base64 解码，行结构对传输没有任何意义（实测 2KB/40KB/120KB/400KB 四档长度与 SHA256 双判据全一致）。旧写法把载荷切成 4000 字符一块、join 换行、再校验「拼接后长度 == 引导码长度 + 块数」：那是自己切、自己拼、自己校，只可能拦下“我自己写错了切分/拼接代码”（开发期测一次就会暴露的事），拦不下任何传输层问题（损坏由远端 base64 解码失败与安装脚本自身校验兜底），“避开超长单行的未知处理”也只是没有实测依据的猜测——卡 32767 的从来只是 argv 通道（载荷已改走 stdin）。故删掉分块与那道无效不变式，少三步复杂度。
		Write-Host ('[单会话] 引导码 {0} 字符整段走标准输入下发；argv 上只剩 {1} 字符的固定引导代码，远低于 Windows 命令行 32767 上限。' -f $引导码.Length, $固定引导码.Length)
		$回调包 = 新建-供给回调 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $端口 -系统类型 'Windows'
		$script:单会话PS2标记 = $false
		$内部回调 = $回调包.回调
		$检测回调 = {
			param($行)
			if ($行 -match '__PS2__') { $script:单会话PS2标记 = $true }
			& $内部回调 $行
		}
		try {
			$命令行 = 'powershell -NoProfile -EncodedCommand {0}' -f $固定引导码
			# 通道挂死重试：实测管道式 stdin 会偶发无声挂死（120KB 那一档挂了约 66 分钟），现在改走"显式 Close() + 看门狗"的新函数，挂死会在 240 秒无进展时被判死并清树，这里再重试一次。只对 [stdin超时] 这一类重试；其它错误（含 PS2、认证失败、远端报错）原样抛出，保留真实原因。
			$尝试上限 = 2
			for ($轮次 = 1; $轮次 -le $尝试上限; $轮次++) {
				try {
					执行-SSH命令带标准输入 -连接目标 $连接目标 -端口 $端口 -命令文本 $命令行 -标准输入文本 $载荷标准输入 -超时秒 240 -每行回调 $检测回调
					break
				} catch {
					if ($_.Exception.Message -notmatch '^\[stdin超时\]') { throw }
					if ($轮次 -ge $尝试上限) { throw }
					# 把挂点诊断透进日志：「启动层挂死」与「安装段静默」是两种完全不同的故障（前者查连接/僵尸会话，后者查安装脚本哪段没有输出），只报"挂死"会让每次事故都要重新取证
					Write-Host ('[单会话] 标准输入通道挂死（第 {0} 次尝试），已按看门狗终止并清理，重试第 {1} 次。挂点诊断：{2}' -f $轮次, ($轮次 + 1), $_.Exception.Message)
					$script:单会话PS2标记 = $false
				}
			}
		} finally {
			等待-供给进程并回收日志 -供给 @($回调包.供给容器.ToArray())
		}
		if ($script:单会话PS2标记) { return 'PS2' }
		return '完成'
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
	# ===== 本地孤儿会话清理：断线/失败的连接留下的 ssh/scp/cmd 孤儿（父进程已死）仍持有远程会话，是远端僵尸会话的源头；只清引用本主机、本 Windows 会话且父进程已死的，活动连接（父进程存活）与其它登录会话一概不碰
	$本会话ID = [int](Get-Process -Id $PID).SessionId
	try {
		$孤儿数 = 0
		foreach ($候 in @(Get-CimInstance Win32_Process -Filter "Name = 'ssh.exe' or Name = 'scp.exe' or Name = 'cmd.exe'" -ErrorAction SilentlyContinue)) {
			if ($候.CommandLine -notmatch [regex]::Escape($远程主机)) { continue }
			if ($null -ne $候.SessionId -and [int]$候.SessionId -ne $本会话ID) { continue }
			if ($null -ne (Get-Process -Id $候.ParentProcessId -ErrorAction SilentlyContinue)) { continue }
			try { Stop-Process -Id $候.ProcessId -Force -ErrorAction Stop; $孤儿数++ } catch { }
		}
		if ($孤儿数 -gt 0) {
			Write-Output ('已清理本地孤儿连接进程 {0} 个（断线残留，仍持有远程会话）。' -f $孤儿数)
		}
	} catch { }
	# ===== 孤儿本地供给进程清理：连接被取消/超时时主模块直接死，走不到 taskkill 收尾，本地供给子进程就成了孤儿（实测存活 34 分钟）。它会把整个包下完并死握共用缓存文件：实测同时连接的新供给进程被堵八分钟、刷六条「文件被占用」中断。判据与上下两段清理同纪律：命令行带 local-supply.ps1 特征 + 直系父进程已死 + 仅限本 Windows 登录会话，父进程在侧（活的供给进程）与其它会话一概不碰。子进程自带的「父死即自终止」是第一道防线，这里清掉的是升级前就已遗留的旧孤儿（它们不知道看护规则）。
	try {
		$供给孤儿数 = 0
		foreach ($候 in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue)) {
			if ($候.CommandLine -notmatch 'local-supply\.ps1') { continue }
			if ($null -ne $候.SessionId -and [int]$候.SessionId -ne $本会话ID) { continue }
			if ($候.ProcessId -eq $PID) { continue }
			if ($null -ne (Get-Process -Id $候.ParentProcessId -ErrorAction SilentlyContinue)) { continue }
			& taskkill /PID $候.ProcessId /T /F 2>&1 | Out-Null
			$供给孤儿数++
		}
		if ($供给孤儿数 -gt 0) {
			Write-Output ('已清理孤儿本地供给进程 {0} 个（断线连接遗留，正占用共用缓存文件并白吃带宽）。' -f $供给孤儿数)
		}
	} catch { }
	# ===== 死安装终端清理：Remote-SSH 在隐藏终端里跑安装脚本，连接超时放弃/窗口异常后终端的 pty 宿主先死，cmd（连带内层 cmd 与 ssh 子树）成为孤儿挂在死管道上——仍占控制台会话、仍握着已放弃的远程会话隧道，残留累积会拖垮后续连接的输出投递（实测同窗口残留累积后新连接的安装命令根本不被执行、终端一个字节都不上屏）。判据三重全满足才杀：①命令行带安装终端特征（vscode-linux-multi-line-command）；②仅限本 Windows 会话内的候选；③直系父进程已死且向上 8 代祖先链找不到任何存活终端宿主。宿主名单必须含 VS Code 窗口/pty 宿主进程（^Code/VSCodium）：实测存活终端的进程链是 cmd ← Code(pty宿主) ← Code(窗口)，conhost/OpenConsole 是旁挂兄弟而非祖先，旧判据只认 conhost 会把一切存活安装终端（含其它窗口正在跑的）误判成孤儿整树杀掉、对方窗口弹“终端进程已终止”；现在凡有存活宿主或存活父进程在侧的一概不碰，只有窗口已亡的无主孤儿才清。
	try {
		$进程快照 = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
		$按Pid索引 = @{}
		foreach ($项 in $进程快照) { $按Pid索引[[int]$项.ProcessId] = $项 }
		$死终端数 = 0
		foreach ($候 in $进程快照) {
			if ($候.Name -ne 'cmd.exe') { continue }
			if ($候.CommandLine -notmatch 'vscode-linux-multi-line-command') { continue }
			if ($null -ne $候.SessionId -and [int]$候.SessionId -ne $本会话ID) { continue }
			if ($null -ne (Get-Process -Id $候.ParentProcessId -ErrorAction SilentlyContinue)) { continue }
			$宿主存活 = $false
			$游标 = $候
			for ($代 = 0; $代 -lt 8; $代++) {
				if ($null -eq $游标.ParentProcessId -or [int]$游标.ParentProcessId -le 4) { break }
				if (-not $按Pid索引.ContainsKey([int]$游标.ParentProcessId)) { break }
				$游标 = $按Pid索引[[int]$游标.ParentProcessId]
				if ($游标.Name -match 'OpenConsole|conhost|winpty-agent|VSCodium|^Code') { $宿主存活 = $true; break }
			}
			if ($宿主存活) { continue }
			& taskkill /PID $候.ProcessId /T /F 2>&1 | Out-Null
			$死终端数++
		}
		if ($死终端数 -gt 0) {
			Write-Output ('已清理死安装终端进程树 {0} 棵（超时放弃的残留，占据会话并拖慢后续连接）。' -f $死终端数)
		}
	} catch { }
	$本地附加压缩包路径 = $null
	$远程附加压缩包文件名 = $null

	# 认证与环境试探合并：免密主机一次连接拿到全部环境信息；需密码主机在密码注入后的第一次连接拿到
	# 竞速暂存的预清理+预建随环境探测同一条连接完成（残留标记与完整包清掉、目录建好）：必须早于本地供给启动（防残包被误当完整包），又不值得独占一条连接。sh -c 包装让命令只在 POSIX 端生效（cmd/PowerShell 下是无害噪声），$HOME 即登录目录，单引号避开 PS 5.1 传参剥双引号的坑。
	# **绝不 rm -rf 整目录**：暂存目录名只按提交号、不带连接唯一性，另一条并发连接可能正在往同一目录上传 <包名>.uploading，或在写 <包名>.downloading-<PID>（远端自下载的私有在途名），整删会让它们的改名发布步骤报「在途文件不在」而白白失去供给（Windows 侧实测已发生）。只清非在途项，在途文件留给收尾清理按 6 小时龄回收。
	$竞速数据目录名 = if ($本地信息.发布通道 -eq 'insider') { '.vscode-server-insiders' } else { '.vscode-server' }
	$竞速预备命令 = "sh -c 'D=`$HOME/{0}/race-{1}; mkdir -p `$D; for f in `$D/*; do [ -e `$f ] || continue; case `$f in *.uploading) continue;; *.downloading-*) continue;; esac; rm -rf `$f; done; exit 0'" -f $竞速数据目录名, $本地信息.提交号
	# 非交互（preconnect）优先走单会话：探测/上传/执行一条连接全包（实测慢速主机每条独立连接 25s 会话开销）；Linux用 sh 引导，Windows 用 powershell -EncodedCommand 引导（脚本经 stdin）；建不起来或探测取不到结果时自然回退离散流程（交互式手动调用恒走离散，保留密码收集能力）
	$接管会话 = $null
	$平台提示 = ''
	if ($非交互) {
		try {
			$平台提示 = [string]$平台提示映射.$远程主机
		} catch { }
		if ($平台提示 -match '^(?i)windows') {
			# ===== Windows 单会话全流程：探测/预备/安装/竞速监控/收尾一条 ssh 全包（离散流程要 4~7 条）；PS2老主机由引导版本门拦下，回退下方离散流程 =====
			$单会话上下文 = 初始化-竞速上下文-Windows单会话 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号
			$远程安装脚本文本 = $script:远程脚本_通用.Replace('__提交号__', $本地信息.提交号).Replace('__发布通道__', $本地信息.发布通道).Replace('__暂存目录__', 'AUTO')
			Write-Host ('远程连接目标: {0}' -f $连接目标)
			Write-Host '远程系统类型: Windows（单会话全流程）'
			Write-Host ('已启用竞速模式：本地子进程下载+上传 与 远程自下载并行，暂存目录 {0}（远端产物已就位时本轮零下载，自动跳过竞速）' -f $单会话上下文.暂存目录)
			if ((执行-Windows单会话安装 -连接目标 $连接目标 -端口 $SSH端口 -脚本文本 $远程安装脚本文本 -竞速上下文 $单会话上下文) -eq '完成') {
				清除-SSH密码复用
				return
			}
			Write-Host '远程 PowerShell 为 2.0（Win7 适配），回退离散安装流程。'
		} elseif ($平台提示 -notmatch '^(?i)windows') {
			try {
				$接管会话 = 建立-接管会话 -连接目标 $连接目标 -端口 $SSH端口 -预备命令 $竞速预备命令
			} catch {
				Write-Host ('单会话建立失败，回退离散流程：{0}' -f $_.Exception.Message)
				$接管会话 = $null
			}
		}
	}
	$环境 = 初始化-SSH会话 -连接目标 $连接目标 -端口 $SSH端口 -非交互:$非交互 -附加命令 $竞速预备命令 -会话 $接管会话

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
			执行-接管编排 -连接目标 $连接目标 -端口 $SSH端口 -远程登录目录 $环境.登录目录 `
				-提交号 $本地信息.提交号 -发布通道 $本地信息.发布通道 `
				-安装脚本文本 $null -需要sysroot阶段 $false -需要保活阶段 $true -保活动作 $保活动作 -竞速上下文 $null -每行回调 $null -会话 $接管会话
		} finally {
			清除-SSH密码复用
		}
		return
	}

	if ($环境.系统类型 -eq 'Linux') {
		# 远端内存提交余量预警（只警告不干预后续流程）：严格提交模式（overcommit=2）下余量耗尽时一切新内存分配都会失败，实测表现为新开终端报 forkpty(3) failed、服务端与扩展主机 V8 报 Committing semi space failed 堆溢出；通常是集群上其他任务占满全机提交额度所致，待其释放后重连即恢复
		if ($环境.严格提交模式 -and $null -ne $环境.提交余量KB -and $环境.提交余量KB -lt 4194304) {
			Write-Host ('警告: 远端内存提交余量仅 {0:N1} GB（严格提交模式下全机额度接近上限），新开终端或扩展主机可能报 forkpty 失败/堆内存溢出；通常是集群上其他任务占满所致，与本工具无关，待其释放后重连即可。' -f ($环境.提交余量KB / 1MB))
		}
		# 旧 glibc 兼容（官方 sysroot 妥协方案）：VS Code 1.99+ 的 server 要求 glibc >= 2.28，老系统（如 CentOS 7 glibc 2.17）需在家目录部署 sysroot 并注入 VSCODE_SERVER_CUSTOM_GLIBC_* 环境变量
		$兼容性sysroot目录 = ''
		# 合并环境探测已带回 glibc/内核则直接用（各免一轮 SSH 往返），缺失才退回单独探测
		$glibc版本 = $环境.Glibc版本
		if ($null -eq $glibc版本) { $glibc版本 = 探测-远程glibc版本 -连接目标 $连接目标 -端口 $SSH端口 }
		if ($null -ne $glibc版本) {
			Write-Host ('远程 glibc 版本: {0}' -f $glibc版本)
		}
		if (($null -ne $glibc版本) -and ($glibc版本 -lt [version]'2.28')) {
			if ([string]::IsNullOrWhiteSpace($环境.登录目录)) {
				Write-Host '警告: 远程 glibc 过旧且登录目录未知，无法自动部署 sysroot；Remote-SSH 连接将因先决条件失败。'
			} else {
				# sysroot 妥协方案的硬性前提：glibc 2.28 的 loader 要求内核 ≥ 3.2，旧内核（如 CentOS 6 的 2.6.32）上 loader 启动即报 FATAL: kernel too old 拒绝加载任何程序，补丁与安装均无意义，先探明内核再决定是否继续
				$内核版本 = $环境.内核版本
				if ($null -eq $内核版本) { $内核版本 = 探测-远程内核版本 -连接目标 $连接目标 -端口 $SSH端口 }
				if ($null -ne $内核版本) {
					Write-Host ('远程内核版本: {0}' -f $内核版本)
				}
				if (($null -ne $内核版本) -and ($内核版本 -lt [version]'3.2')) {
					清除-SSH密码复用
					throw ('远程内核 {0} 过旧：glibc 2.28 运行时要求内核不低于 3.2，旧内核上 loader 启动即报 FATAL: kernel too old 拒绝运行，sysroot 妥协方案无解（实测 /bin/ls 都无法加载）。请升级主机内核/系统，或对该主机改用支持旧内核的旧版 VS Code。' -f $内核版本)
				}
				Write-Host ('远程 glibc {0} < 2.28，不满足 VS Code Server 先决条件，自动部署官方 sysroot 妥协方案...' -f $glibc版本)
				# 部署动作本身已并入接管编排的 sysroot 阶段；这里只定目录。旧 glibc 主机同时启用原生组件补丁阶段
				$兼容性sysroot目录 = ($环境.登录目录.TrimEnd('/', '\')) + '/vscode-sysroot'
			}
		}

		# Linux 远程主机走 sh 安装流程；能确定暂存目录与远程架构时启用竞速（本地子进程下载+上传 与 远程自下载 并行，先完成者胜）
		$竞速上下文 = 初始化-竞速上下文 -环境 $环境 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号 -需要sysroot材料 (-not [string]::IsNullOrWhiteSpace($兼容性sysroot目录))
		$本地供给 = New-Object System.Collections.ArrayList
		$回调包 = $null
		$每行回调 = $null
		if ($null -ne $竞速上下文) {
			Write-Host ('已启用竞速模式：本地子进程下载+上传 与 远程自下载并行，暂存目录 {0}（远端产物已就位时本轮零下载，自动跳过竞速）' -f $竞速上下文.暂存目录)
			# sysroot 素材属于安装前的独立阶段，保持原有供给；CLI 与服务端改由预备标记和决出行驱动，与远端一样逐个启动。
			$素材上下文 = [pscustomobject]@{
				暂存目录 = $竞速上下文.暂存目录
				包扩展名 = $竞速上下文.包扩展名
				提交号 = $竞速上下文.提交号
				分隔符 = $竞速上下文.分隔符
				架构标识 = $竞速上下文.架构标识
				产物列表 = @($竞速上下文.产物列表 | Where-Object { $_.产物名 -notin @('CLI', '服务端') })
			}
			if ($素材上下文.产物列表.Count -gt 0) {
				foreach ($单个 in (启动-本地竞速供给 -竞速上下文 $素材上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型)) {
					[void]$本地供给.Add($单个)
				}
			}
			$回调包 = 新建-供给回调 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			$调度回调 = $回调包.回调
			$停止供给动作 = ${function:停止-供给进程树}
			$每行回调 = {
				param($行)
				& $调度回调 $行
				if ($行 -match '竞速获胜|本轮零下载') {
					& $停止供给动作 -供给 @($本地供给.ToArray())
				}
				if ($行 -match '竞速决出：(?<产物>[^\s]+?)\s*由远程自下载获胜') {
					$产物名 = $Matches['产物']
					& $停止供给动作 -供给 @($本地供给.ToArray() | Where-Object { $_.产物名 -eq $产物名 })
				}
			}.GetNewClosure()
		} else {
			Write-Host '未启用竞速模式（登录目录或远程架构无法确定），由远程单独下载。'
		}

		$远程安装脚本 = $script:远程脚本_Linux
		$远程安装脚本 = $远程安装脚本.Replace('__提交号__', $本地信息.提交号)
		$远程安装脚本 = $远程安装脚本.Replace('__发布通道__', $本地信息.发布通道)
		$远程安装脚本 = $远程安装脚本.Replace('__暂存目录__', $(if ($null -ne $竞速上下文) { $竞速上下文.暂存目录 } else { '' }))
		$远程安装脚本 = $远程安装脚本.Replace('__兼容性目录__', $兼容性sysroot目录)

		# 全阶段合并执行：sysroot → 安装 → 原生补丁 →（可选）保活检修 → 清理 全部在单次上传后的单次远程会话里完成
		try {
			执行-接管编排 -连接目标 $连接目标 -端口 $SSH端口 -远程登录目录 $环境.登录目录 `
				-提交号 $本地信息.提交号 -发布通道 $本地信息.发布通道 `
				-安装脚本文本 $远程安装脚本 -需要sysroot阶段 (-not [string]::IsNullOrWhiteSpace($兼容性sysroot目录)) `
				-需要保活阶段 $含服务保活 -保活动作 '部署' -竞速上下文 $竞速上下文 -每行回调 $每行回调 -会话 $接管会话
		} finally {
		# 收尾：击杀独立素材供给与回调启动的 CLI/服务端供给，并回收全部日志。
		$全部本地供给 = @($本地供给.ToArray())
		if ($null -ne $回调包) { $全部本地供给 += @($回调包.供给容器.ToArray()) }
		等待-供给进程并回收日志 -供给 $全部本地供给
	}
	清除-SSH密码复用
	return
}


	# Windows 远程主机：一律自动探测脚本版本（按远程 PowerShell 版本选择）
	$远程安装脚本 = 选择-远程脚本 -PS主版本 $环境.PS主版本
	$竞速上下文 = $null
	$每行回调 = $null
	$本地供给容器 = New-Object System.Collections.ArrayList
	if ($远程安装脚本 -eq $script:远程脚本_Win7) {
		# Win7（PS2）版无法在远程后台作业里可靠自下载，保持原有本地下载+上传供给方式，不竞速
		$本地附加压缩包路径 = 下载-本地服务器压缩包 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号 -架构 'win32-x64'
		$远程附加压缩包文件名 = 'vscode-server-upload-temp.zip'
	} else {
		# 通用版：能确定暂存目录与远程架构时启用竞速；供给由回调在远端预备完成标记后启动（预备先于上传），远端脚本启动时自行清建暂存目录、收尾自清，无需为此单独占连接
		$竞速上下文 = 初始化-竞速上下文 -环境 $环境 -发布通道 $本地信息.发布通道 -提交号 $本地信息.提交号
		if ($null -ne $竞速上下文) {
			Write-Host ('已启用竞速模式：本地子进程下载+上传 与 远程自下载并行，暂存目录 {0}（远端产物已就位时本轮零下载，自动跳过竞速）' -f $竞速上下文.暂存目录)
			$回调包 = 新建-供给回调 -竞速上下文 $竞速上下文 -连接目标 $连接目标 -端口 $SSH端口 -系统类型 $环境.系统类型
			$每行回调 = $回调包.回调
			$本地供给容器 = $回调包.供给容器
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
		# 供给收尾即可：远端暂存目录由安装脚本启动时自清建、收尾自清，不再为此单独占连接
		等待-供给进程并回收日志 -供给 @($本地供给容器.ToArray())
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

		# 非交互环境（如 Remote-SSH preconnect）：需要密码时直接报错，不收集密码
		[Parameter(DontShow)]
		[switch]$非交互,

		[switch]$移除
	)

	# 复用主入口已实现的连接协商（ssh config 反查、密码一次性收集复用、环境与登录目录探测），仅把动作切成服务保活的部署或移除
	$转发参数 = @{
		远程主机     = $远程主机
		SSH端口      = $SSH端口
		仅服务保活   = $true
		移除服务保活 = $移除.IsPresent
	}
	if ($非交互.IsPresent) { $转发参数['非交互'] = $true }
	if (-not [string]::IsNullOrWhiteSpace($远程账户)) { $转发参数['远程账户'] = $远程账户 }
	if (-not [string]::IsNullOrWhiteSpace($本地版本)) { $转发参数['本地版本'] = $本地版本 }

	安装-VSCode远程服务 @转发参数
}


# 导出公共函数
Export-ModuleMember -Function '安装-VSCode远程服务', '安装-VSCode服务保活'
