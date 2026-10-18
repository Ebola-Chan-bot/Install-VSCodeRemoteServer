# 本地竞速供给子进程脚本（每个竞速产物一个实例：CLI 与服务端各由 启动-本地竞速供给 起一个，并行下载/上传互不阻塞）
# 由 启动-本地竞速供给 通过 Start-Process 作为独立 powershell 进程运行，与主模块进程隔离；竞速全部决出的瞬间，主流程用 taskkill /T /F 直接击杀本进程及其派生的 ssh/scp，下载或上传无论进行到哪一步都被立即终止（真正的事件驱动即时取消，零轮询）。参数经 Clixml 文件传入，避开命令行转义与 PS 5.1 原生命令 stderr 终止性错误陷阱。
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true, Position = 0)]
	[string]$参数文件路径
)

$ErrorActionPreference = 'Continue'
try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

	$参数 = Import-Clixml -LiteralPath $参数文件路径
	$连接目标 = [string]$参数.连接目标
	$端口 = [int]$参数.端口
	$密码选项 = @($参数.密码选项)
	$暂存目录 = [string]$参数.暂存目录
	$下载地址 = [string]$参数.下载地址
	$远程包名 = [string]$参数.远程包名
	$完成标记名 = [string]$参数.完成标记名
	$系统类型 = [string]$参数.系统类型
	$分隔符 = [string]$参数.分隔符
	$提交号 = [string]$参数.提交号
	$产物名 = [string]$参数.产物名
	$取消标记名 = [string]$参数.取消标记名
	# 多源地址列表（sysroot 素材等有镜像备源）与可选的稳定本地缓存名（文件名自带版本号的素材跨提交号复用）；.job 交接文件恒按 race-supply-<提交号>-<远程包名> 命名落 TEMP 根目录，与数据文件位置解耦，上传器按固定模式照常发现
	$地址列表 = @($参数.下载地址列表 | Where-Object { $_ })
	if ($地址列表.Count -eq 0) { $地址列表 = @([string]$参数.下载地址) }
	$本地文件名 = [string]$参数.本地文件名
	if ([string]::IsNullOrWhiteSpace($本地文件名)) { $本地文件名 = 'race-supply-{0}-{1}' -f $提交号, $远程包名 }
	# Windows 远端相对暂存目录（单会话模式约定）锚定登录目录：scp 相对路径落点与 ssh 会话位置实测都是登录目录，但命令里的相对路径随执行上下文可能漂移（实测 Start-Job 的 CWD 是「文档」目录），统一改写成 $env:USERPROFILE 绝对表达式由远端展开，与远端脚本解析出的绝对暂存目录严格同目录。
	$远端暂存目录文本 = if ($暂存目录 -match '^[A-Za-z]:[\\/]' -or $暂存目录.StartsWith('\\')) { $暂存目录 } else { ('$env:USERPROFILE\' + ($暂存目录 -replace '/', '\')) }

	function 调用-远程命令([string]$命令文本) {
		# 返回 {退出码, 输出} 对象（不用元组：命令无 stdout 时 PowerShell 会展平数组导致下标错位），失败时把远端报错一并带回展示
		$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
		$输出 = @(& $ssh命令.Source (@('-n', '-p', $端口) + $密码选项 + @($连接目标, $命令文本)) 2>&1)
		$输出文本 = ($输出 | ForEach-Object { [string]$_ }) -join ' | '
		return [pscustomobject]@{ 退出码 = $LASTEXITCODE; 输出 = $输出文本 }
	}

	function 转换-远程PowerShell命令([string]$脚本文本) {
		# Windows 远程命令统一走 powershell -EncodedCommand：命令行只剩 base64，不含双引号/圆括号/管道等会被 PS5.1 传参剥掉或被远端 cmd 解析的字符（同 取-环境探测命令 的硬约束）
		$编码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($脚本文本))
		return ('powershell -NoProfile -EncodedCommand {0}' -f $编码)
	}

	function 测试-本地包完整([string]$路径) {
		# 完整性快检：zip 查头部 PK 魔数与尾部 EOCD 结束记录（必在尾 64KB 内，截断包必缺）；tar.gz 查 gzip 头魔数。坏包在这里被拦下，绝不送上远端
		try {
			$信息 = Get-Item -LiteralPath $路径
			if ($信息.Length -lt 22) { return $false }
			$流 = [System.IO.File]::OpenRead($路径)
			try {
				$头 = New-Object byte[] 4
				if ($流.Read($头, 0, 4) -ne 4) { return $false }
				if ($远程包名 -like '*.zip') {
					if ($头[0] -ne 0x50 -or $头[1] -ne 0x4B) { return $false }
					$尾窗大小 = [int][Math]::Min(65557, $信息.Length)
					[void]$流.Seek($信息.Length - $尾窗大小, 'Begin')
					$尾窗 = New-Object byte[] $尾窗大小
					[void]$流.Read($尾窗, 0, $尾窗大小)
					for ($i = 0; $i -le $尾窗.Length - 4; $i++) {
						if ($尾窗[$i] -eq 0x50 -and $尾窗[$i + 1] -eq 0x4B -and $尾窗[$i + 2] -eq 0x05 -and $尾窗[$i + 3] -eq 0x06) { return $true }
					}
					return $false
				}
				# rpm：头魔数 ed ab ee db（拦 HTML 错误页、截断包等）
				if ($远程包名 -like '*.rpm') {
					return ($头[0] -eq 0xED -and $头[1] -eq 0xAB -and $头[2] -eq 0xEE -and $头[3] -eq 0xDB)
				}
				# tar.gz：gzip 头魔数 1f 8b（拦 HTML 错误页、全零文件等）
				return ($头[0] -eq 0x1F -and $头[1] -eq 0x8B)
			}
			finally {
				$流.Dispose()
			}
		}
		catch {
			return $false
		}
	}

	function 取-取消标记命令 {
		if ($系统类型 -eq 'Linux') {
			return ('test -f {0}/{1}' -f $暂存目录, $取消标记名)
		}
		return (转换-远程PowerShell命令 ('if (Test-Path -LiteralPath "{0}\{1}") {{ exit 0 }} else {{ exit 1 }}' -f $远端暂存目录文本, $取消标记名))
	}

	function 下次汇报间隔($上次汇报间隔, $总计已用秒数, $已下载字节数, $预计总大小) {
		# 自适应报告节奏：判据等价于「预计剩余时间 < 间隔逐级回落到 1 秒所需的总时长 上次汇报间隔*(上次汇报间隔-1)/2」，其中预计剩余时间 = 剩余字节 /（已下载字节数 / 总计已用秒数）；不足即收紧 1 秒、否则放宽 1 秒，切换点随实际速度浮动而非固定 2/3 进度；判据乘开避免除法，已下载 0 字节时恒判放宽，返回值下限 1 秒
		if (($预计总大小 - $已下载字节数) * $总计已用秒数 * 2 -lt $上次汇报间隔 * ($上次汇报间隔 - 1) * $已下载字节数) {
			return [Math]::Max(1, $上次汇报间隔 - 1)
		}
		else {
			return $上次汇报间隔 + 1
		}
	}

	# Linux：暂存目录的预清理/预建已由主流程在环境探测的同一条连接完成（残包与取消标记已清、目录已建，
	# 且此时尚无竞速获胜的可能），本进程起步不再独占连接做检查——慢速主机上每次 SSH 往返可达数十秒。
	# Windows：保持原样（探测附加命令是 sh -c 包装，在 cmd/powershell 下只是噪声不生效）。
	if ($系统类型 -ne 'Linux') {
		# 下载前的低成本取消检查（远程已获胜则不必下载）
		if ((调用-远程命令 (取-取消标记命令)).退出码 -eq 0) { Write-Output '远程侧已获胜，本地供给取消（下载前）。'; return }
		# 预建远程暂存目录：本地供给可能先于远程脚本跑到上传步骤，目录不存在会导致 scp 失败
		$建目录命令 = 转换-远程PowerShell命令 ('New-Item -ItemType Directory -Force -Path "{0}" | Out-Null' -f $远端暂存目录文本)
		$null = 调用-远程命令 $建目录命令
	}

	# 分块 HTTP 断点续传下载（失败无限重试且等待秒数递增、逐源轮试）。进程会在远程获胜时被整体击杀，故下载循环无需任何取消检查；
	# 半成品保留在本地供下次运行续传；默认文件名带提交号防旧版本残包被 416 误判为完整或被错误续传，文件名自带版本号的素材用稳定缓存名跨提交号复用。
	$本地包路径 = Join-Path $env:TEMP $本地文件名
	$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $本地包路径)
	$重试次数 = 0
	# 报告周期在重试循环外初始化：断点续传时继承上一段的周期，不从 1 秒重新开始
	$报告周期秒数 = 1
	# 总计已用秒数的计时起点同样在重试循环外：估算平均速度 = 已下载字节数 / 总计已用秒数
	$下载起始时刻 = Get-Date
	while ($true) {
		# 缓存已完整（过完整性快检）就不再碰网络：稳定缓存名的素材跨提交号复用，每次连接不再白下一遭；坏包/半成品仍走下方断点续传
		if ((Test-Path -LiteralPath $本地包路径) -and (测试-本地包完整 $本地包路径)) {
			Write-Output ('本地缓存已完整：{0} 字节，跳过下载。' -f (Get-Item -LiteralPath $本地包路径).Length)
			break
		}
		$重试次数++
		$已存在字节数 = 0
		if (Test-Path -LiteralPath $本地包路径) { $已存在字节数 = (Get-Item -LiteralPath $本地包路径).Length }
		$响应 = $null
		$响应流 = $null
		$文件流 = $null
		try {
			# 多源轮试：每次重试换下一个源（部分源可能整站不可达，如 GitHub 直连被断），同一半成品跨源续传（各源内容一致）
			$当前地址 = $地址列表[($重试次数 - 1) % $地址列表.Count]
			$请求 = [System.Net.HttpWebRequest]::Create($当前地址)
			# 显式 UA 必带：centos-vault 镜像对无 UA/非浏览器请求回 403（实测阿里云拒裸 HttpWebRequest）
			$请求.UserAgent = 'Mozilla/5.0'
			$请求.Timeout = 60000
			$请求.ReadWriteTimeout = 60000
			if ($已存在字节数 -gt 0) { $请求.AddRange($已存在字节数) }
			$响应 = $请求.GetResponse()
			$状态码 = [int]$响应.StatusCode
			# 期望总长：206 为已有部分+本段，其余为整段；ContentLength 未知（-1）时跳过长度核对，由完整性快检兑底
			$期望长度 = if ($响应.ContentLength -ge 0) { $已存在字节数 + $响应.ContentLength } else { -1 }
			if ($状态码 -eq 206) {
				$文件流 = [System.IO.File]::Open($本地包路径, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
			}
			else {
				$文件流 = [System.IO.File]::Open($本地包路径, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
				$已存在字节数 = 0
			}
			$响应流 = $响应.GetResponseStream()
			$缓冲区 = New-Object byte[] 65536
			$已下载 = $已存在字节数
			$上次进度输出 = [datetime]::MinValue
			while (($读取数 = $响应流.Read($缓冲区, 0, $缓冲区.Length)) -gt 0) {
				$文件流.Write($缓冲区, 0, $读取数)
				$已下载 += $读取数
				$此刻 = Get-Date
				if (($此刻 - $上次进度输出).TotalSeconds -ge $报告周期秒数) {
					$上次进度输出 = $此刻
					# 进度行与远程侧同款两种句式：总量已知报 X / Y 字节（P%），总量未知报已传 X 字节
					if ($期望长度 -gt 0) {
						$进度百分比 = [math]::Round(($已下载 * 100.0) / $期望长度, 1)
						Write-Output ('本地下载进度：{0} / {1} 字节（{2}%）' -f $已下载, $期望长度, $进度百分比)
						# 报告周期自适应（见 下次汇报间隔）：按预计剩余时间决定收紧或放宽
						$报告周期秒数 = 下次汇报间隔 $报告周期秒数 ($此刻 - $下载起始时刻).TotalSeconds $已下载 $期望长度
					}
					else {
						Write-Output ('本地下载进度：已传 {0} 字节' -f $已下载)
						# 总大小未知时无法估算剩余时间，只增不减
						$报告周期秒数++
					}
				}
			}
			$文件流.Flush()
			# 先关流再校验：完整性快检要重新打开文件读，写句柄未关（FileShare.None）时 OpenRead 必失败，
			# 会把完整包误判成"疑似截断"白触发一轮重试（实测每次完整下载都中招，靠 416 兜底才救回）
			if ($null -ne $文件流) { $文件流.Dispose(); $文件流 = $null }
			if ($null -ne $响应流) { $响应流.Dispose(); $响应流 = $null }
			if ($null -ne $响应) { $响应.Close(); $响应 = $null }
			# 长度核对：流式读到底只代表连接正常关闭，不代表传输完整（实测截断包曾被当完整包送解压报晦涩的 End of Central Directory 错误）
			if ($期望长度 -gt 0 -and (Get-Item -LiteralPath $本地包路径).Length -lt $期望长度) {
				throw ('下载提前结束：本地 {0} 字节，预期 {1} 字节。' -f (Get-Item -LiteralPath $本地包路径).Length, $期望长度)
			}
			if (-not (测试-本地包完整 $本地包路径)) {
				throw '本地包完整性校验未通过（疑似截断）。'
			}
			Write-Output ('本地下载完成：共 {0} 字节。' -f $已下载)
			break
		}
		catch {
			# 416 = 请求区间无效：断点续传起点已不小于服务器完整大小，说明本地文件早已下载完整（如实测 231MB 包上次运行被击杀后残留），视为成功退出重试循环。
			# PS 5.1 中 GetResponse 抛出的 $_.Exception 常是 MethodInvocationException 包装（实测取不到状态码），真正的 WebException 在 InnerException 里，须遍历异常链
			$HTTP状态码 = 0
			$异常 = $_.Exception
			while ($null -ne $异常 -and $HTTP状态码 -eq 0) {
				try { $HTTP状态码 = [int]$异常.Response.StatusCode } catch { }
				$异常 = $异常.InnerException
			}
			if ($HTTP状态码 -eq 416 -and $已存在字节数 -gt 0) {
				if (测试-本地包完整 $本地包路径) {
					Write-Output ('服务器返回 416：本地文件 {0} 字节已完整，无需续传。' -f $已存在字节数)
					break
				}
				Remove-Item -LiteralPath $本地包路径 -Force -ErrorAction SilentlyContinue
				Write-Output '服务器返回 416 但本地包完整性校验未通过，删除后从头重下。'
				continue
			}
			$等待秒数 = [Math]::Min(30, $重试次数 * 2)
				Write-Output ('下载中断（{0}，源: {1}），{2} 秒后重试（第 {3} 次，已续传 {4} 字节）...' -f $_.Exception.Message, $当前地址, $等待秒数, $重试次数, $已存在字节数)
			Start-Sleep -Seconds $等待秒数
		}
		finally {
			if ($null -ne $文件流) { $文件流.Dispose() }
			if ($null -ne $响应流) { $响应流.Dispose() }
			if ($null -ne $响应) { $响应.Close() }
		}
	}

	if ($系统类型 -eq 'Linux') {
		# 交接主会话上传：本进程只负责下载，完成后写 .job 交接文件即退出，主会话的上传器线程按“文件帧→改名帧”序送入同一条连接。
		# 原子性与 scp 方案一致：帧序天然保证“先文件后改名”，改名命令内含远端取消检查，坏包/截断包绝不会被就位。
		# 帧通道的落盘点恒为 $HOME/<远端名>（见 会话帧循环.sh），故改名从 ~ 取件再移入暂存目录；.job 恒落 TEMP 根目录按固定模式命名（见上方注释）。
		$改名命令 = ("sh -c 'if [ -f {0}/{3} ]; then exit 2; fi; mv ~/{1}.uploading {0}/{1} && touch {0}/{2}'" -f $暂存目录, $远程包名, $完成标记名, $取消标记名)
		$交接 = @{ 数据文件 = $本地包路径; 远端名 = ('{0}.uploading' -f $远程包名); 完成命令 = $改名命令 }
		$交接 | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:TEMP ('race-supply-{0}-{1}.job' -f $提交号, $远程包名)) -Encoding UTF8
		Write-Output ('本地下载完成：共 {0} 字节，已交接主会话上传（{1}）。' -f (Get-Item -LiteralPath $本地包路径).Length, $远程包名)
		return
	}

	# Windows：保持独立 scp 上传 + 改名（LAN 快，不走单会话）
	# 上传前的取消复检：防止远程恰在下载完成到上传之间获胜，仍做一次低成本检查
	if ((调用-远程命令 (取-取消标记命令)).退出码 -eq 0) { Write-Output '远程侧已获胜，本地供给取消（上传前）。'; return }

	$scp命令 = Get-Command scp -ErrorAction SilentlyContinue | Select-Object -First 1
	Write-Output '开始上传本地压缩包到暂存目录...'
	$上传目标 = ('{0}:{1}{2}{3}.uploading' -f $连接目标, $暂存目录, $分隔符, $远程包名)
	$null = & $scp命令.Source (@('-P', $端口) + $密码选项 + @($本地包路径, $上传目标)) 2>&1
	if ($LASTEXITCODE -ne 0) { Write-Output ('上传失败，退出码 {0}，本地供给退出（远程将继续自下载）。' -f $LASTEXITCODE); return }

	# 上传完整性核对：远端字节数必须与本地一致才写完成标记（scp 断流截断时绝不放行，否则远端会拿坏包解压）
	$本地大小 = (Get-Item -LiteralPath $本地包路径).Length
	if ($系统类型 -eq 'Linux') {
		$核对命令 = ('stat -c %s {0}/{1}.uploading' -f $暂存目录, $远程包名)
	}
 else {
		$核对命令 = 转换-远程PowerShell命令 ('[long](Get-Item -LiteralPath "{0}\{1}.uploading").Length' -f $远端暂存目录文本, $远程包名)
	}
	$核对结果 = 调用-远程命令 $核对命令
	# 调用-远程命令 把多行输出折成 ' | ' 单行，且 ssh 的 CNAME 警告等 stderr 会混入——按分隔符+换行切段后只认纯数字段，防噪声把大小核对误判成"未知"
	$远端大小行 = @($核对结果.输出 -split '[\r\n|]+' | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -Last 1)
	if ($核对结果.退出码 -ne 0 -or $远端大小行.Count -eq 0 -or [long]$远端大小行[0] -ne $本地大小) {
		Write-Output ('上传核对失败：远端 {0} 字节 ≠ 本地 {1} 字节，放弃本次改名与标记。' -f $(if ($远端大小行.Count -gt 0) { $远端大小行[0].Trim() } else { '未知' }), $本地大小)
		return
	}

	# 原子改名 + 写完成标记（带远端取消检查，避免远程已获胜后仍写标记）。退出码约定：0=包已就位，2=远程已获胜跳过改名，其他=失败
	# Linux 版包 sh -c 是防登录 shell 不是 sh（tcsh/fish 会把 if...then...fi 判成语法错误）；Windows 版经 转换-远程PowerShell命令 走 EncodedCommand，避开双引号被剥与 cmd 把 | 当管道解析
	if ($系统类型 -eq 'Linux') {
		# gzip -t 把关：远端完整解压测试通过才改名写标记（tar.gz 的截断无法靠魔数检出，交给 gzip -t 一票否决）
		$改名命令 = ("sh -c 'if [ -f {0}/{3} ]; then exit 2; fi; gzip -t {0}/{1}.uploading && mv {0}/{1}.uploading {0}/{1} && touch {0}/{2}'" -f $暂存目录, $远程包名, $完成标记名, $取消标记名)
	}
 else {
		$改名脚本 = ('if (Test-Path -LiteralPath "{0}\{3}") {{ exit 2 }}; try {{ Move-Item -LiteralPath "{0}\{1}.uploading" -Destination "{0}\{1}" -Force -ErrorAction Stop; New-Item -ItemType File -Force "{0}\{2}" -ErrorAction Stop | Out-Null }} catch {{ Write-Output $_.Exception.Message; exit 1 }}' -f $远端暂存目录文本, $远程包名, $完成标记名, $取消标记名)
		$改名命令 = 转换-远程PowerShell命令 $改名脚本
	}
	$改名结果 = 调用-远程命令 $改名命令
	if ($改名结果.退出码 -eq 0) {
		Write-Output '本地供给完成：包已就位并写入完成标记。'
	}
 elseif ($改名结果.退出码 -eq 2) {
		Write-Output '远程侧已获胜，本地供给取消（改名前）。'
	}
 else {
		Write-Output ('改名/标记命令失败（退出码 {0}），远端报错：{1}，远程将继续自下载。' -f $改名结果.退出码, $(if ([string]::IsNullOrWhiteSpace($改名结果.输出)) { '无' } else { $改名结果.输出 }))
	}
}
catch {
	Write-Output ('本地供给任务异常终止: {0}' -f $_.Exception.Message)
}