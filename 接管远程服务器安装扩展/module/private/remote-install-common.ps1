# 远程安装脚本（通用版）
# 要求远程 PowerShell 3.0+
# 此文件通过主脚本上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# 关闭内置进度条：Invoke-WebRequest 的进度条靠移动光标反复重绘，在 SSH 会话里会把已输出的中文行重绘错乱（每个汉字重影、行首留大段空格），本脚本的关键进度均有自打印文本，不需要进度条
$ProgressPreference = 'SilentlyContinue'

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

	# 新版 exec server 布局：<数据目录>\cli\servers\<质量名>-<提交号>\server
	# 旧版 bin\<提交号> 布局已不再写入（Remote-SSH 的 CLI 只认新布局）
	$质量名 = if ($通道 -eq 'insider') { 'Insiders' } else { 'Stable' }
	$数据目录 = if ($通道 -eq 'insider') {
		Join-Path $HOME '.vscode-server-insiders'
	} else {
		Join-Path $HOME '.vscode-server'
	}

	return Join-Path $数据目录 ('cli\servers\{0}-{1}\server' -f $质量名, $版本提交号)
}

function 取-CLI安装信息 {
	param(
		[string]$通道,
		[string]$版本提交号,
		[string]$架构
	)

	# Remote-SSH 引导的契约：数据根目录下需存在 <cli名>-<提交号>[.exe]，cli 名稳定版为 code、预览版为 code-insiders；Windows 的 CLI 下载 artifact 为 cli-win32-<短架构>（如 cli-win32-x64），与服务器压缩包的 win32-x64 标识不同，需去掉 win32- 前缀取短架构；包内可执行文件不带提交号，落地后按上述规则重命名
	$cli基础名 = if ($通道 -eq 'insider') { 'code-insiders' } else { 'code' }
	$cli落地名 = ('{0}-{1}.exe' -f $cli基础名, $版本提交号)
	$短架构 = $架构 -replace '^win32-', ''
	$数据目录 = if ($通道 -eq 'insider') {
		Join-Path $HOME '.vscode-server-insiders'
	} else {
		Join-Path $HOME '.vscode-server'
	}

	return [pscustomobject]@{
		包内可执行名 = ('{0}.exe' -f $cli基础名)
		落地路径 = (Join-Path $数据目录 $cli落地名)
		下载地址 = ('https://update.code.visualstudio.com/commit:{0}/cli-win32-{1}/{2}' -f $版本提交号, $短架构, $通道)
	}
}

function 安装-远程CLI {
	param(
		[pscustomobject]$CLI信息
	)

	# 仅补装缺失的 CLI（Remote-SSH 引导仅做文件存在性检查，存在即视为已安装）；CLI 压缩包约 30MB，直接整包下载，无需断点续传，失败按递增间隔无限重试
	# VS Code 连接时的官方引导会与本脚本并行下载并启动同名 CLI：运行中的 exe 被系统锁定、无法覆盖，只复制不复查会永远报"文件被占用"并无限重试，故每轮重试前与失败后都复查落地文件，只要它已出现即视为安装完成（文件名含提交号，同名即同版本，无需覆盖）
	# 落位用改名而非复制：解包目录与目标同在数据目录下，改名是原子操作，中断也不会留下残缺 exe 占着正式名而被误判为已安装
	if (Test-Path -LiteralPath $CLI信息.落地路径) {
		Write-Host ('[{0}] CLI 已存在，跳过安装: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
		return
	}

	$数据目录 = Split-Path -Parent $CLI信息.落地路径
	New-Item -ItemType Directory -Force $数据目录 | Out-Null
	$cli压缩包路径 = Join-Path $数据目录 ('vscode-cli-{0}.zip' -f [System.IO.Path]::GetFileNameWithoutExtension($CLI信息.落地路径))

	$重试次数 = 0
	while ($true) {
		$重试次数++
		# 重试前复查：并行的官方引导可能已把 CLI 装好（甚至已启动），此时安装实际已完成，直接收尾退出，不再徒劳下载 30MB 后必然复制失败
		if (Test-Path -LiteralPath $CLI信息.落地路径) {
			Write-Host ('[{0}] CLI 已就位（并行安装完成），跳过安装: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
			return
		}
		try {
			Write-Host ('[{0}] 开始下载远程 CLI（第 {1} 次尝试）: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $重试次数, $CLI信息.下载地址)
			Invoke-WebRequest -Uri $CLI信息.下载地址 -OutFile $cli压缩包路径 -UseBasicParsing

			展开-CLI压缩包 -压缩包路径 $cli压缩包路径 -CLI信息 $CLI信息

			Write-Host ('[{0}] 远程 CLI 安装完成: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
			return
		} catch {
			Write-Host ('[{0}] 第 {1} 次 CLI 下载中断: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $重试次数, $_.Exception.Message)
			# 失败后复查：报"被另一进程占用"通常就是并行引导已把 CLI 装好并在运行，此时安装实际已完成，视为成功收尾而非无限重试
			if (Test-Path -LiteralPath $CLI信息.落地路径) {
				Write-Host ('[{0}] CLI 已就位（并行安装完成），视为安装完成: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
				return
			}
		}

		Start-Sleep -Seconds $重试次数
	}
}

function 展开-CLI压缩包 {
	param(
		[string]$压缩包路径,
		[pscustomobject]$CLI信息
	)

	# 解包 CLI 压缩包并按引导契约落地改名（包内可执行名不带提交号）；解包目录与目标同在数据目录下，改名落位是原子操作，中断也不会留下残缺 exe 占着正式名而被误判为已安装
	$数据目录 = Split-Path -Parent $CLI信息.落地路径
	New-Item -ItemType Directory -Force $数据目录 | Out-Null
	$临时解压目录 = Join-Path $数据目录 ('cli-unpack-{0}' -f ([System.IO.Path]::GetRandomFileName()))
	try {
		Expand-Archive -Path $压缩包路径 -DestinationPath $临时解压目录 -Force
		$包内路径 = Join-Path $临时解压目录 $CLI信息.包内可执行名
		if (-not (Test-Path -LiteralPath $包内路径)) {
			throw ('CLI 压缩包内未找到 {0}。' -f $CLI信息.包内可执行名)
		}

		Move-Item -LiteralPath $包内路径 -Destination $CLI信息.落地路径 -Force
	} finally {
		Remove-Item $临时解压目录 -Recurse -Force -ErrorAction SilentlyContinue
		Remove-Item $压缩包路径 -Force -ErrorAction SilentlyContinue
	}
}

function 安装-CLI压缩包 {
	param(
		[string]$压缩包路径,
		[pscustomobject]$CLI信息
	)

	# 竞速供给包的一次性落位：VS Code 官方引导可能已并行把 CLI 装好（甚至已启动、目标被系统锁定），先复查再落位；失败再复查，已出现即视为完成（文件名含提交号，同名即同版本）
	if (Test-Path -LiteralPath $CLI信息.落地路径) {
		Write-Host ('[{0}] CLI 已就位（并行安装完成），跳过安装: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
		return
	}
	try {
		展开-CLI压缩包 -压缩包路径 $压缩包路径 -CLI信息 $CLI信息
		Write-Host ('[{0}] 远程 CLI 安装完成: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
	} catch {
		if (Test-Path -LiteralPath $CLI信息.落地路径) {
			Write-Host ('[{0}] CLI 已就位（并行安装完成），跳过安装: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
			return
		}
		throw
	}
}

function 竞速-单个产物 {
	param(
		[string]$产物名,
		[string]$下载地址,
		[string]$远程包路径,
		[string]$远程完成标记,
		[string]$本地包路径,
		[string]$本地完成标记,
		[string]$本地取消标记,
		[string]$下载函数文本
	)

	# 单个产物的竞速：远程自下载（后台作业）与本地下载+上传（由本地模块负责）并行，先完成者获胜，返回 {获胜方;获胜包路径}。
	# 逐产物独立竞速：哪边能下载就由哪边供给，单边断网时另一边照样补上，互不拖累。
	# 清理本端上一轮残留；本地包/本地标记由本地供给任务管理，不在此处删（可能已先于本脚本完成）
	Remove-Item -LiteralPath $远程包路径, $远程完成标记, $本地取消标记 -Force -ErrorAction SilentlyContinue

	Write-Host ('[{0}] {1} 竞速：远程自下载与本地下载+上传并行，先完成者用于安装。' -f (Get-Date -Format 'HH:mm:ss'), $产物名)
	# 把断点续传下载函数以文本形式带入后台作业（Start-Job 是独立进程，无法直接调用本脚本函数），保证竞速模式下远程侧仍是断点续传。
	# 注意：Definition 属性不含花括号（函数体以 param(...) 开头），注入时必须自行包上 { }，否则是非法函数声明
	$下载作业 = Start-Job -ArgumentList $下载函数文本, $下载地址, $远程包路径, $远程完成标记 -ScriptBlock {
		param($下载函数文本, $下载地址, $远程包路径, $远程完成标记)
		$ErrorActionPreference = 'Continue'
		[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
		Invoke-Expression ('function 通过HTTP断点续传下载 { ' + $下载函数文本 + ' }')
		try {
			通过HTTP断点续传下载 -下载地址 $下载地址 -目标路径 $远程包路径
			if ((Test-Path $远程包路径) -and ((Get-Item $远程包路径).Length -gt 0)) {
				New-Item -ItemType File -Force $远程完成标记 | Out-Null
				Write-Output '远程自下载完成。'
			} else {
				Write-Output '远程自下载结束后未发现完整压缩包，等待本地供给。'
			}
		} catch {
			Write-Output ('远程自下载异常终止: {0}' -f $_.Exception.Message)
		}
	}

	$等待秒数 = 0
	$获胜方 = $null
	# 竞速等待心跳没有产物总大小可比对，无法估算剩余时间，报告周期只增不减（每个周期比上个周期多 1 秒）
	$报告周期秒数 = 1
	$下次报告秒数 = $报告周期秒数
	while ($true) {
		if (Test-Path -LiteralPath $远程完成标记) { $获胜方 = '远程自下载'; break }
		if (Test-Path -LiteralPath $本地完成标记) { $获胜方 = '本地供给'; break }
		# 流式转发后台作业的输出（下载进度/重试消息）
		Receive-Job -Job $下载作业 | ForEach-Object { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $_) }
		Start-Sleep -Seconds 1
		$等待秒数++
		if ($等待秒数 -ge $下次报告秒数) {
			$远程字节 = 0
			if (Test-Path -LiteralPath $远程包路径) { $远程字节 = (Get-Item -LiteralPath $远程包路径).Length }
			Write-Host ('[{0}] {1} 竞速等待 {2}s：远程侧已下载 {3} 字节。' -f (Get-Date -Format 'HH:mm:ss'), $产物名, $等待秒数, $远程字节)
			$报告周期秒数++
			$下次报告秒数 = $等待秒数 + $报告周期秒数
		}
	}

	# 胜负已定：写该产物的取消标记让本地供给任务停止该产物的后续动作，并终止远程后台下载
	New-Item -ItemType File -Force $本地取消标记 | Out-Null
	Stop-Job -Job $下载作业 -ErrorAction SilentlyContinue
	Receive-Job -Job $下载作业 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $_) }
	Remove-Job -Job $下载作业 -Force -ErrorAction SilentlyContinue

	$获胜包路径 = if ($获胜方 -eq '本地供给') { $本地包路径 } else { $远程包路径 }
	Write-Host ('[{0}] 竞速决出：{1} 由{2}获胜。' -f (Get-Date -Format 'HH:mm:ss'), $产物名, $获胜方)
	if (-not (Test-Path -LiteralPath $获胜包路径)) {
		throw ('竞速决出的包不存在: {0}' -f $获胜包路径)
	}

	return [pscustomobject]@{ 获胜方 = $获胜方; 获胜包路径 = $获胜包路径 }
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

function 通过HTTP断点续传下载 {
	param(
		[string]$下载地址,
		[string]$目标路径
	)

	# 本函数的函数体会被整段文本化送进后台下载作业重新定义（见 $下载函数文本），故自适应函数必须内嵌在函数体内随行，不能依赖外部定义
	function 下次汇报间隔($上次汇报间隔, $总计已用秒数, $已下载字节数, $预计总大小) {
		# 自适应报告节奏：判据等价于「预计剩余时间 < 间隔逐级回落到 1 秒所需的总时长 上次汇报间隔*(上次汇报间隔-1)/2」，其中预计剩余时间 = 剩余字节 /（已下载字节数 / 总计已用秒数）；不足即收紧 1 秒、否则放宽 1 秒，切换点随实际速度浮动而非固定 2/3 进度；判据乘开避免除法，已下载 0 字节时恒判放宽，返回值下限 1 秒
		if (($预计总大小 - $已下载字节数) * $总计已用秒数 * 2 -lt $上次汇报间隔 * ($上次汇报间隔 - 1) * $已下载字节数) {
			return [Math]::Max(1, $上次汇报间隔 - 1)
		}
		else {
			return $上次汇报间隔 + 1
		}
	}

	# 基于 HTTP Range 头的断点续传：本地已存在部分文件时从偏移处继续。
	# 不限重试次数与总时长，失败等待秒数逐次递增（1秒、2秒、3秒……），所有输出带时间戳。
	# 报告周期在重试循环外初始化：断点续传时继承上一段的周期，不从 1 秒重新开始
	$重试次数 = 0
	$报告周期秒数 = 1
	# 总计已用秒数的计时起点同样在重试循环外：估算平均速度 = 已下载字节数 / 总计已用秒数
	$下载起始时刻 = Get-Date
	while ($true) {
		$重试次数++
		$已存在字节数 = 0
		if (Test-Path $目标路径) {
			$已存在字节数 = (Get-Item $目标路径).Length
		}

		try {
			$Web请求 = [System.Net.HttpWebRequest]::Create($下载地址)
			$Web请求.Timeout = 60000
			$Web请求.ReadWriteTimeout = 60000
			if ($已存在字节数 -gt 0) {
				$Web请求.AddRange($已存在字节数)
				Write-Host ('[{0}] 从 {1} 字节处断点续传（第 {2} 次尝试）: {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $已存在字节数, $重试次数, $下载地址)
			} else {
				Write-Host ('[{0}] 开始下载（第 {1} 次尝试）: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $重试次数, $下载地址)
			}

			$响应 = $Web请求.GetResponse()
			$状态码 = [int]$响应.StatusCode
			$响应流 = $null
			$文件流 = $null
			try {
				if ($状态码 -eq 206) {
					# 服务器支持断点续传：以追加方式写入剩余内容，文件总长度 = 已有部分 + 本次 ContentLength
					$内容总长度 = $已存在字节数 + $响应.ContentLength
					if ($响应.ContentLength -lt 0) { $内容总长度 = 0 }
					$文件流 = [System.IO.File]::Open($目标路径, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
				} elseif ($状态码 -eq 200) {
					if ($已存在字节数 -gt 0) {
						Write-Host ('[{0}] 服务器未响应 Range 请求（返回 200），将重新完整下载。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
					}

					$内容总长度 = $响应.ContentLength
					if ($内容总长度 -lt 0) { $内容总长度 = 0 }
					$文件流 = [System.IO.File]::Open($目标路径, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
				} else {
					throw ('收到意外的 HTTP 状态码: {0}' -f $状态码)
				}

				$响应流 = $响应.GetResponseStream()
				$缓冲区 = New-Object byte[] 65536
				$已写入字节数 = 0
				$上次报告时间 = [datetime]::MinValue
				# 报告周期沿用外层变量且断点续传不重置；疏密由 下次汇报间隔 按预计剩余时间自动决定，下限 1 秒
				while ($true) {
					$读取字节数 = $响应流.Read($缓冲区, 0, $缓冲区.Length)
					if ($读取字节数 -le 0) { break }

					$文件流.Write($缓冲区, 0, $读取字节数)
					$已写入字节数 += $读取字节数
					$当前时间 = Get-Date
					if (($当前时间 - $上次报告时间).TotalSeconds -ge $报告周期秒数) {
						$上次报告时间 = $当前时间
						$已传总字节数 = $已存在字节数 + $已写入字节数
						if ($内容总长度 -gt 0) {
							$进度 = [math]::Round(($已传总字节数 * 100.0) / $内容总长度, 1)
							Write-Host ('[{0}] 状态: Transferring | 进度: {1}% | {2} / {3} 字节' -f ($当前时间.ToString('HH:mm:ss')), $进度, $已传总字节数, $内容总长度)
							# 报告周期自适应（见 下次汇报间隔）：按预计剩余时间决定收紧或放宽
							$报告周期秒数 = 下次汇报间隔 $报告周期秒数 ($当前时间 - $下载起始时刻).TotalSeconds $已传总字节数 $内容总长度
						} else {
							Write-Host ('[{0}] 状态: Transferring | 已传: {1} 字节' -f ($当前时间.ToString('HH:mm:ss')), $已传总字节数)
							# 总大小未知时无法估算剩余时间，只增不减
							$报告周期秒数++
						}
					}
				}
			} finally {
				if ($null -ne $响应流) { $响应流.Dispose() }
				if ($null -ne $文件流) { $文件流.Dispose() }
				$响应.Dispose()
			}

			if ($内容总长度 -gt 0 -and (Get-Item $目标路径).Length -lt $内容总长度) {
				throw ('下载提前结束: 文件 {0} 字节，预期至少 {1} 字节。' -f (Get-Item $目标路径).Length, $内容总长度)
			}

			# zip 完整性抽检：EOCD 结束记录（PK\x05\x06）必在尾部 64KB 内，缺失即截断包。chunked 响应无 Content-Length 时上面的长度核对被跳过，此为唯一防线。
			# 本函数会以文本形式注入后台作业执行（独立进程），校验逻辑必须内联、不得调用脚本内其他函数
			if ([System.IO.Path]::GetExtension($目标路径) -ieq '.zip') {
				$校验信息 = Get-Item -LiteralPath $目标路径
				$校验尾窗大小 = [int][Math]::Min(65557, $校验信息.Length)
				$校验流 = [System.IO.File]::OpenRead($校验信息.FullName)
				$含EOCD = $false
				try {
					[void]$校验流.Seek($校验信息.Length - $校验尾窗大小, 'Begin')
					$校验尾窗 = New-Object byte[] $校验尾窗大小
					[void]$校验流.Read($校验尾窗, 0, $校验尾窗大小)
					for ($i = 0; $i -le $校验尾窗.Length - 4; $i++) {
						if ($校验尾窗[$i] -eq 0x50 -and $校验尾窗[$i + 1] -eq 0x4B -and $校验尾窗[$i + 2] -eq 0x05 -and $校验尾窗[$i + 3] -eq 0x06) { $含EOCD = $true; break }
					}
				} finally {
					$校验流.Dispose()
				}
				if (-not $含EOCD) {
					throw ('压缩包完整性校验未通过（疑似截断，缺 EOCD）: {0}' -f $目标路径)
				}
			}

			Write-Host ('[{0}] 下载完成。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
			return
		} catch {
			# 416 = 请求区间无效：断点续传起点已不小于服务器完整大小，说明本地文件早已下载完整，视为成功。
			# PS 5.1 中 GetResponse 抛出的 $_.Exception 常是 MethodInvocationException 包装（实测取不到状态码），真正的 WebException 在 InnerException 里，须遍历异常链
			$HTTP状态码 = 0
			$异常 = $_.Exception
			while ($null -ne $异常 -and $HTTP状态码 -eq 0) {
				try { $HTTP状态码 = [int]$异常.Response.StatusCode } catch { }
				$异常 = $异常.InnerException
			}
			if ($HTTP状态码 -eq 416 -and $已存在字节数 -gt 0) {
				Write-Host ('[{0}] 服务器返回 416：文件 {1} 字节已完整，无需续传。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $已存在字节数)
				return
			}
			Write-Host ('[{0}] 第 {1} 次下载中断: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $重试次数, $_.Exception.Message)
		}

		# 保留已下载的部分文件，等待递增秒数后自动续传重试（1秒、2秒、3秒……）
		Start-Sleep -Seconds $重试次数
	}
}

function 测试-压缩包完整 {
	param(
		[string]$路径
	)

	# 完整性快检：zip 查头部 PK 魔数与尾部 EOCD 结束记录（PK\x05\x06，必在尾 64KB 内，截断包必缺）。Expand-Archive 对坏包只会报晦涩的 "End of Central Directory record could not be found"，前置校验可给出清晰结论并触发自愈
	if ([string]::IsNullOrWhiteSpace($路径) -or -not (Test-Path -LiteralPath $路径)) { return $false }
	try {
		$信息 = Get-Item -LiteralPath $路径
		if ($信息.Length -lt 22) { return $false }
		$流 = [System.IO.File]::OpenRead($路径)
		try {
			$头 = New-Object byte[] 4
			if ($流.Read($头, 0, 4) -ne 4) { return $false }
			if ($头[0] -ne 0x50 -or $头[1] -ne 0x4B) { return $false }
			$尾窗大小 = [int][Math]::Min(65557, $信息.Length)
			[void]$流.Seek($信息.Length - $尾窗大小, 'Begin')
			$尾窗 = New-Object byte[] $尾窗大小
			[void]$流.Read($尾窗, 0, $尾窗大小)
			for ($i = 0; $i -le $尾窗.Length - 4; $i++) {
				if ($尾窗[$i] -eq 0x50 -and $尾窗[$i + 1] -eq 0x4B -and $尾窗[$i + 2] -eq 0x05 -and $尾窗[$i + 3] -eq 0x06) { return $true }
			}
			return $false
		} finally {
			$流.Dispose()
		}
	} catch {
		return $false
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
# ===== Remote-SSH 管道执行守卫（幂等部署到用户 profile）：远端 sshd 的默认 shell 是 PowerShell 且 Remote-SSH 的连接脚本不带 -NoProfile、经 stdin 管道喂给交互式 REPL 执行，回显与提示符让输出膨胀并滞留在管道渲染段（连接端等不到握手标记只能超时，实测 122 秒超时仍失败）。
# 守卫把「无命令行参数的管道会话」（裸 powershell 被整本喂脚本的形态）转为非交互整本执行，输出只剩脚本本身的少量关键行，一次冲刷即达；带参数/命令的会话与交互登录不受影响，本模块自身的 -EncodedCommand 会话也不受影响。经 stdin 管道喂给守卫自身即可执行修复脚本（守卫即执行通道）；修复/部署脚本的标识符必须用 ASCII（控制台输入按 GBK 解码，中文标识符会被毁）。
$守卫块 = @'

$守卫标记 = 'Remote-SSH 管道执行守卫 v3' # 幂等标记与版本号（勿删本行）：标记必须留在代码行尾注释里（整行注释会被载荷的去注释步骤剥掉，标记丢失会导致每连一次就重贴一份守卫）
# stdin 是管道且进程无命令行参数 = 有程序把整本脚本喂给裸 REPL 执行（带参数/命令的会话照常执行，不拦截）。
# 分块即读即执行、绝不等 EOF：实测管道 EOF 在终端场景下经常不来，等 EOF 的旧守卫会永久卡在 ReadToEnd（追踪只有 GUARD_START 没有 STDIN_BYTES）；逐行累积、能解析就立即点执行，脚本跑到哪算哪；非交互执行让输出只剩脚本本身的少量关键行，不再有回显/提示符膨胀滞留问题。
if ([Console]::IsInputRedirected -and ([Environment]::GetCommandLineArgs().Count -eq 1)) {
	$缓冲 = New-Object System.Text.StringBuilder
	while ($true) {
		$行文本 = [Console]::In.ReadLine()
		if ($null -eq $行文本) { break }
		[void]$缓冲.AppendLine($行文本)
		try { $块 = [scriptblock]::Create($缓冲.ToString()) } catch { continue }
		[void]$缓冲.Clear()
		try { . $块 } catch { Write-Output ('脚本异常: {0}' -f $_.Exception.Message) }
	}
	if ($缓冲.Length -gt 0) {
		try { . ([scriptblock]::Create($缓冲.ToString())) } catch { Write-Output ('脚本异常: {0}' -f $_.Exception.Message) }
	}
	exit
}
$守卫结束 = 1 # 守卫块结束标记（勿删本行）
'@
$守卫路径 = Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\profile.ps1'
$守卫现状 = if (Test-Path -LiteralPath $守卫路径) { [System.IO.File]::ReadAllText($守卫路径) } else { '' }
if ($守卫现状 -notmatch "管道执行守卫 v3'") {
	# 先剥离旧版守卫块再贴新版：守卫总是追加在文件末尾，从首个守卫特征行截到文件尾即可；旧块若留在前面会先于新版触发并永久卡死（等 EOF 的旧 ReadToEnd）
	$截断位置 = -1
	foreach ($特征 in @('$守卫标记 = ''Remote-SSH 管道执行守卫', '# Remote-SSH 管道执行守卫', '$stdinScriptText', '[Console]::IsInputRedirected')) {
		$位置 = $守卫现状.IndexOf($特征)
		if ($位置 -ge 0 -and ($截断位置 -lt 0 -or $位置 -lt $截断位置)) { $截断位置 = $位置 }
	}
	if ($截断位置 -eq 0) { $守卫现状 = '' }
	elseif ($截断位置 -gt 0) { $守卫现状 = $守卫现状.Substring(0, $截断位置) }
	New-Item -ItemType Directory -Force -Path (Split-Path $守卫路径) | Out-Null
	[System.IO.File]::WriteAllText($守卫路径, ($守卫现状 + $守卫块), (New-Object System.Text.UTF8Encoding($true)))
}

# ===== 僵尸会话自动清理：断线/失败的连接在 Windows 上会留下孤儿 powershell（sshd 会话已死但进程不随死），每个占一个控制台会话，累积后会拖慢新连接的输出投递（实测同一条连接命令，干净时 0.3 秒出首字节、僵尸成堆时 100+ 秒）。判据只看祖先链：向上 12 代找不到 sshd（实际进程名是 sshd.exe，必须用前缀匹配）= 整条会话已死的孤儿；命令行形态不作判据（实测孤儿有三种形态：裸 REPL、sftp 子系统外层壳、命令会话外层壳）；活动连接的会话进程（祖先链里有存活 sshd）与新启动进程（5 分钟内）一概不碰。
$全进程表 = @{}
foreach ($项 in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
	$全进程表[[int]$项.ProcessId] = $项
}
$僵尸数 = 0
foreach ($候 in $全进程表.Values) {
	if ($候.Name -ne 'powershell.exe') { continue }
	if (((Get-Date) - $候.CreationDate).TotalMinutes -lt 5) { continue }
	$祖先有sshd = $false
	$游标 = $候
	for ($i = 0; $i -lt 12; $i++) {
		if ($null -eq $游标.ParentProcessId -or $游标.ParentProcessId -eq 0) { break }
		$父 = $全进程表[[int]$游标.ParentProcessId]
		if ($null -eq $父) { break }
		if ($父.Name -like 'sshd*') { $祖先有sshd = $true; break }
		$游标 = $父
	}
	if (-not $祖先有sshd) {
		try { Stop-Process -Id $候.ProcessId -Force -ErrorAction Stop; $僵尸数++ } catch { }
	}
}
if ($僵尸数 -gt 0) {
	Write-Output ('已清理僵尸会话 {0} 个，后续连接的输出投递不再被拖慢。' -f $僵尸数)
}

# 竞速暂存目录：本地模块与远程脚本约定在同一目录交换压缩包与标记文件；空串表示未启用竞速，回退远程单独下载
$暂存目录 = '__暂存目录__'
if ($暂存目录 -eq 'AUTO') {
	# 单会话模式的哨兵值：暂存目录由本脚本自行推算，本地模块不探测登录目录、scp 只用相对路径。
	# 必须解析成登录目录基准的绝对路径：相对路径随执行上下文漂移（实测 Start-Job 的 CWD 是「文档」目录，AUTO\REMOTE_CLI.zip 被解析成 文档\AUTO\... 直接报 Cannot find path 中断安装），而 scp 相对路径的落点实测就是登录目录，锚定 $env:USERPROFILE 与之对齐。
	$数据目录名 = if ($发布通道 -eq 'insider') { '.vscode-server-insiders' } else { '.vscode-server' }
	$暂存目录 = ('{0}\{1}\race-{2}' -f $env:USERPROFILE, $数据目录名, $提交号)
}
$系统架构 = 取-系统架构标识
$最终安装目录 = 取-安装目录 -通道 $发布通道 -版本提交号 $提交号
# 固定文件名（不含随机后缀），使同一安装目录下的下载路径确定，便于识别与断点续传定位
$下载压缩包路径 = Join-Path $最终安装目录 'vscode-server-download.zip'
$下载地址 = 取-下载地址 -通道 $发布通道 -版本提交号 $提交号 -架构 $系统架构
$CLI信息 = 取-CLI安装信息 -通道 $发布通道 -版本提交号 $提交号 -架构 $系统架构

Write-Host ('准备安装 VS Code 远程服务，提交号: {0}' -f $提交号)
Write-Host ('发布通道: {0}' -f $发布通道)
Write-Host ('自动检测到的系统架构: {0}' -f $系统架构)
Write-Host ('自动检测到的安装目录: {0}' -f $最终安装目录)
Write-Host ('下载地址: {0}' -f $下载地址)

# ===== 判定待装产物：已就位的产物不参与竞速，避免无谓的下载与上传 =====
$CLI已就位 = Test-Path -LiteralPath $CLI信息.落地路径
# Remote-SSH 的 CLI 用 server 目录下的 product.json 与 bin 判定安装完整性
$服务端已就绪 = (Test-Path -LiteralPath (Join-Path $最终安装目录 'product.json')) -and (Test-Path -LiteralPath (Join-Path $最终安装目录 'bin'))

$启用竞速 = -not [string]::IsNullOrWhiteSpace($暂存目录)
$CLI获胜包路径 = $null
$获胜包路径 = $下载压缩包路径
if ($启用竞速) {
	# ===== 竞速模式：每个缺失产物各竞速一次（本地下载+上传 vs 远程自下载，先完成者获胜），CLI 与服务端独立判胜、互不拖累 =====
	# 单边断网时由另一边补上：远端连不上下载服务器就等本地供给，本地下载失败就等远程自下载
		# 清建暂存目录：上一轮的残包与标记必须清掉（残留的完成标记会让本轮误判本地供给已获胜、残留半成品会被误当完整包）；本地供给听到下方标记才启动，不会误删它的在途文件。
		Remove-Item -LiteralPath $暂存目录 -Recurse -Force -ErrorAction SilentlyContinue
		New-Item -ItemType Directory -Force $暂存目录 | Out-Null
		# 供给触发标记：本地模块听到此行才启动本地供给子进程（顺序保证：清建先于任何上传），只报真正待装的产物。
		$待装产物名 = @()
		if (-not $CLI已就位) { $待装产物名 += 'CLI' }
		if (-not $服务端已就绪) { $待装产物名 += '服务端' }
		if ($待装产物名.Count -gt 0) {
			Write-Host ('__接管预备完成__{0}' -f ($待装产物名 -join ' '))
		}
	# 把断点续传下载函数以文本形式带入后台作业（Start-Job 是独立进程，无法直接调用本脚本函数），竞速双方产物都用它下载
	$下载函数文本 = (Get-Command '通过HTTP断点续传下载').Definition
	if (-not $CLI已就位) {
		$CLI竞速结果 = 竞速-单个产物 -产物名 'CLI' -下载地址 $CLI信息.下载地址 -远程包路径 (Join-Path $暂存目录 'REMOTE_CLI.zip') -远程完成标记 (Join-Path $暂存目录 'REMOTE_CLI_DONE') -本地包路径 (Join-Path $暂存目录 'LOCAL_CLI.zip') -本地完成标记 (Join-Path $暂存目录 ('LOCAL_CLI_DONE.{0}' -f $系统架构)) -本地取消标记 (Join-Path $暂存目录 'LOCAL_CLI_CANCEL') -下载函数文本 $下载函数文本
		$CLI获胜包路径 = $CLI竞速结果.获胜包路径
	}
	if (-not $服务端已就绪) {
		$服务端竞速结果 = 竞速-单个产物 -产物名 '服务端' -下载地址 $下载地址 -远程包路径 (Join-Path $暂存目录 'REMOTE.zip') -远程完成标记 (Join-Path $暂存目录 'REMOTE_DONE') -本地包路径 (Join-Path $暂存目录 'LOCAL.zip') -本地完成标记 (Join-Path $暂存目录 ('LOCAL_DONE.{0}' -f $系统架构)) -本地取消标记 (Join-Path $暂存目录 'LOCAL_CANCEL') -下载函数文本 $下载函数文本
		$获胜包路径 = $服务端竞速结果.获胜包路径
	}
	# 全部产物竞速决出：该行触发主流程立即击杀本地供给进程树（零轮询即时取消）
	Write-Host '竞速获胜：全部产物已就位，开始安装。'
}

# ===== 安装 CLI（Remote-SSH 引导的启动入口，server 由它拉起，二者缺一不可，故先补 CLI）=====
if ($CLI已就位) {
	Write-Host ('[{0}] CLI 已存在，跳过安装: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $CLI信息.落地路径)
} elseif (($null -ne $CLI获胜包路径) -and (测试-压缩包完整 $CLI获胜包路径)) {
	安装-CLI压缩包 -压缩包路径 $CLI获胜包路径 -CLI信息 $CLI信息
} else {
	if ($null -ne $CLI获胜包路径) {
		Write-Host ('警告: 竞速决出的 CLI 包不完整（疑似截断），弃用并改由远程下载: {0}' -f $CLI获胜包路径)
		Remove-Item -LiteralPath $CLI获胜包路径 -Force -ErrorAction SilentlyContinue
	}
	安装-远程CLI -CLI信息 $CLI信息
}

if ($服务端已就绪) {
	# Remote-SSH 的 CLI 用 server 目录下的 product.json 与 bin 判定安装完整性，同提交号且结构完整则直接复用，避免重复下载约 190MB 的 Server 压缩包
	Write-Host ('[{0}] 同提交号的 Server 已完整安装，跳过下载与解压: {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $最终安装目录)
	# 表格经 Out-String 转为单字符串后由 Write-Host 输出：避免成功流与信息流在 SSH 管道合并时缺换行，导致表格与上一行粘连
	$目录表格 = (Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize | Out-String).TrimEnd()
	Write-Host $目录表格
	return
}

停止-占用安装目录的进程 -安装目录 $最终安装目录 -版本提交号 $提交号

if (Test-Path $最终安装目录) {
	Remove-Item $最终安装目录 -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force $最终安装目录 | Out-Null

if (-not $启用竞速) {
	Write-Host '开始通过 HTTP 断点续传下载压缩包。'
	通过HTTP断点续传下载 -下载地址 $下载地址 -目标路径 $下载压缩包路径
}

# 选取完整包：任何一侧的包都可能因网络截断损坏（坏包解压只会报晦涩的 End of Central Directory 错误），逐候选校验、坏包弃用换下一个，全不可用则回退前台重下自愈
$候选包列表 = @($获胜包路径)
if ($启用竞速) {
	$候选包列表 += (Join-Path $暂存目录 'LOCAL.zip')
	$候选包列表 += (Join-Path $暂存目录 'REMOTE.zip')
}
$候选包列表 += $下载压缩包路径
$可用包路径 = ''
foreach ($候选包 in ($候选包列表 | Select-Object -Unique)) {
	if ([string]::IsNullOrWhiteSpace($候选包) -or -not (Test-Path -LiteralPath $候选包)) { continue }
	if (测试-压缩包完整 $候选包) {
		$可用包路径 = $候选包
		break
	}
	Write-Host ('警告: 压缩包不完整（疑似截断），弃用: {0}' -f $候选包)
	Remove-Item -LiteralPath $候选包 -Force -ErrorAction SilentlyContinue
}
if ($可用包路径 -eq '') {
	Write-Host '所有候选压缩包均不可用，前台重新下载。'
	Remove-Item -LiteralPath $下载压缩包路径 -Force -ErrorAction SilentlyContinue
	通过HTTP断点续传下载 -下载地址 $下载地址 -目标路径 $下载压缩包路径
	if (测试-压缩包完整 $下载压缩包路径) {
		$可用包路径 = $下载压缩包路径
	} else {
		throw ('重新下载的压缩包仍不完整: {0}' -f $下载压缩包路径)
	}
}

Write-Host '下载完成，开始解压。'
展开-服务器压缩包 -压缩包路径 $可用包路径 -目标目录 $最终安装目录

# 竞速暂存目录用完即清（本地模块收尾时也会再清一次，双保险）
if (-not [string]::IsNullOrWhiteSpace($暂存目录)) {
	Remove-Item -LiteralPath $暂存目录 -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '安装完成，当前目录内容如下。'
# 表格经 Out-String 转为单字符串后由 Write-Host 输出：避免成功流与信息流在 SSH 管道合并时缺换行，导致表格与上一行粘连
$目录表格 = (Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize | Out-String).TrimEnd()
Write-Host $目录表格
