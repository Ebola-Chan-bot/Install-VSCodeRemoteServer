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
	# 父进程（主模块）ID：主模块被 VS Code 杀掉（连接超时/用户取消）时本进程必须自行收工，否则会变成孤儿：实测孤儿存活 34 分钟、把 190MB 包下完并死握共用缓存文件，把同时连接的新供给进程堵成一刷屏幕的「文件被占用」。
	# 0 = 未传（旧参数文件），此时不启用看护，行为与以前一致。
	$父进程ID = 0
	$父进程启动时刻 = $null
	if ($null -ne $参数.ParentProcessId -or $null -ne $参数.父进程ID) {
		try { $父进程ID = [int]$(if ($null -ne $参数.父进程ID) { $参数.父进程ID } else { $参数.ParentProcessId }) } catch { $父进程ID = 0 }
	}
	# 记下父进程启动时刻作为身份基线：光看 PID 活不活会被「父进程已死、PID 被别的进程复用」蒙过去（长时间看护尤其容易碰上）
	if ($父进程ID -gt 0) {
		try { $父进程启动时刻 = @(Get-Process -Id $父进程ID -ErrorAction Stop)[0].StartTime } catch { $父进程启动时刻 = $null }
	}
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
		return [pscustomobject]@{ 退出码 = $LASTEXITCODE; 原始输出 = $输出文本; 输出 = (取-远端命令摘要 $输出文本) }
	}

	function 取-远端命令摘要([string]$原始输出) {
		# 把远端命令的混合输出收敛成「人能读的真因」：① 优先取 __VSI_ERR__: 标记后的真实异常；
		# ② 没有标记则剔掉已知噪声（ssh 对中文主机名的 mDNS 警告、PowerShell 把进度记录序列化成 CLIXML 的垃圾、PS 5.1 对原生 stderr 包装的 NativeCommandError/CategoryInfo 模板与 '+ ~~~' 位置行）只留正文。
		# 旧写法把未经过滤的混合输出当成「远端报错」直接上报，真因被淹没在千余字的 CLIXML 里、日志完全不可读。
		if ([string]::IsNullOrWhiteSpace($原始输出)) { return '' }
		$段 = @($原始输出 -split '[\r\n|]+')
		$标记行 = @($段 | Where-Object { $_ -match '__VSI_ERR__\s*:\s*' })
		if ($标记行.Count -gt 0) {
			return (($标记行 -join ' / ') -replace '.*__VSI_ERR__\s*:\s*', '').Trim()
		}
		$噪声模式 = 'ignoring bad CNAME', '#< CLIXML', '<Objs Version', '</Objs>', '<AV>', '<PR N=', '<MS>', '<TN RefId', 'NativeCommandError', 'CategoryInfo', 'FullyQualifiedErrorId', 'At line:', '^\s*\+', '^\s*~+', '^\s*$', 'Preparing modules for first use'
		$正文 = @($段 | Where-Object {
			$行 = $_.Trim()
			$是噪声 = $false
			foreach ($模式 in $噪声模式) { if ($行 -match $模式) { $是噪声 = $true; break } }
			-not $是噪声
		})
		if ($正文.Count -eq 0) { return '' }
		return (($正文 | Select-Object -First 3) -join ' / ').Trim()
	}

	function 测-文件被占用([string]$路径) {
		# 独占探测：能以 ReadWrite 打开 = 无人持有（随即关闭）；抛共享异常 = 另一进程正在写同一产物。
		# 这是判「并发供给」的唯一可靠手段：同名共享路径上两个进程各自 Append 会交错写坏同一个包
		if (-not (Test-Path -LiteralPath $路径)) { return $false }
		try {
			$探流 = [System.IO.File]::Open($路径, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
			$探流.Dispose()
			return $false
		}
		catch {
			return $true
		}
	}

	function 测-属主存活([string]$路径) {
		# 纯谓词：函数体内绝不 Write-Output/Write-Host（同 测-父进程仍在 的纪律，一旦发射内容，调用处的 if 会收到数组，真值判定恒为真）。
		# 在途名自带属主 PID（<成品名>.downloading-<PID>）。写句柄只在真正传数据的那几秒被持有，而属主进程在两次重试之间（等下个汇报周期）并不持有任何句柄 —— 只按「是否被占用」判归属，会把一个活着的属主的半成品当成「无人遗留」抢走改名（认领即改名，等于把对方的续传点搬走），于是两边各自从同一字节数重新下载同一个 ~190MB 产物（2026-10-23 实测：本进程在 42,121,870 字节处被接管，随后双方各自续传，几十 MB 白下一遍）。
		# PID 复用风险：文件名里只有 PID，无启动时刻，理论上可能把复用后的无关进程当活属主 —— 代价是多等一会儿（对方无进展 60 轮即判僵死转自下），比抢走活属主的文件安全得多。
		$名 = Split-Path $路径 -Leaf
		if ($名 -notmatch '\.downloading-(\d+)') { return $false }
		$属主ID = 0
		if (-not [int]::TryParse($Matches[1], [ref]$属主ID)) { return $false }
		if ($属主ID -le 4) { return $false }
		return [bool](Get-Process -Id $属主ID -ErrorAction SilentlyContinue)
	}

	function 取-属主PID([string]$路径) {
		# 纯谓词：从在途名里取出属主 PID（取不到返回 0），供消息如实标注「属主 PID N（存活/已消失）」
		$名 = Split-Path $路径 -Leaf
		if ($名 -notmatch '\.downloading-(\d+)') { return 0 }
		$属主ID = 0
		if (-not [int]::TryParse($Matches[1], [ref]$属主ID)) { return 0 }
		return $属主ID
	}

	function 测-父进程仍在 {
		# 纯谓词：函数体内绝不 Write-Output/Write-Host。一旦发射任何内容，调用处 if (-not (测-父进程仍在)) 收到的就是@('说明文字', $false) 这样的数组，而数组按真值判定恒为真 → -not 恒为假 → 看门狗永不生效（实测缺陷：父进程被杀后供给子进程照样无限重试，正是 34 分钟孤儿供给进程的成因）。要说的话一律由调用处说。
		if ($父进程ID -le 0) { return $true }
		$现进程 = Get-Process -Id $父进程ID -ErrorAction SilentlyContinue
		if ($null -eq $现进程) { return $false }
		if ($null -eq $父进程启动时刻) { return $true }
		try { $现启动 = $现进程.StartTime } catch { $现启动 = $null }
		# 读不到对方启动时刻（权限等）就保守认为仍在，宁可多下也不误停别人的有效供给
		if ($null -eq $现启动) { return $true }
		return ($现启动 -eq $父进程启动时刻)
	}

	function 转换-远程PowerShell命令([string]$脚本文本) {
		# Windows 远程命令统一走 powershell -EncodedCommand：命令行只剩 base64，不含双引号/圆括号/管道等会被 PS5.1 传参剥掉或被远端 cmd 解析的字符（同 取-环境探测命令 的硬约束）
		# 开头必置 $ProgressPreference='SilentlyContinue'：不置时 PowerShell 会把模块首次加载等进度记录序列化成 CLIXML 写到 stderr（实测「Preparing modules for first use.」），混进输出后成为上千字的 `#< CLIXML | <Objs …>` 垃圾，把真实报错挤得看不见
		$脚本文本 = '$ProgressPreference = ''SilentlyContinue''; ' + $脚本文本
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

	function 下次汇报间隔($上次汇报间隔, $总计已用秒数, $已下载字节数, $预计总大小) {
		# 自适应报告节奏：判据等价于「预计剩余时间 < 间隔逐级回落到 1 秒所需的总时长 上次汇报间隔*(上次汇报间隔-1)/2」，其中预计剩余时间 = 剩余字节 /（已下载字节数 / 总计已用秒数）；不足即收紧 1 秒、否则放宽 1 秒，切换点随实际速度浮动而非固定 2/3 进度；判据乘开避免除法，已下载 0 字节时恒判放宽，返回值下限 1 秒。
		# 放宽不设上限是刻意设计（判据在预计剩余时间远大于 T(T-1)/2 时持续放宽，间隔渐进趋向 sqrt(2×预计剩余秒数)：中途越慢间隔越长，越接近完成越自动逐级收密到 1 秒）。不得改成固定上限或固定周期（旧写法每 30 秒必刷一行就是那样来的）；进度行本身改由时钟驱动，故间隔再大也不会出现「有字节到却整段无输出」
		if (($预计总大小 - $已下载字节数) * $总计已用秒数 * 2 -lt $上次汇报间隔 * ($上次汇报间隔 - 1) * $已下载字节数) {
			return [Math]::Max(1, $上次汇报间隔 - 1)
		}
		else {
			return $上次汇报间隔 + 1
		}
	}

	# 起步不为预检单开任何 SSH 连接（Linux 与 Windows 同纪律）：远端暂存目录由主流程的 清理-竞速暂存目录 在输出 __接管预备完成__ 之前清建完毕，而本进程正是听到该标记才被启动（psm1 回调），故起步时目录必已存在、取消标记必刚被清过——再查再建纯属冗余往返。旧 Windows 侧的「查取消标记 + 预建暂存目录」两条预检命令已删除：每条是一次完整 SSH 连接建立，慢速/会话饱和主机上以分钟计（2026-10-23 实测 B 服务器从供给启动到公布下载源静默约 4 分钟，看起来像供给根本没启动）。
	# 远端获胜的止损靠既有两道，不靠预检：主流程听到「竞速获胜」行即击杀本进程树（事件驱动，约 1 秒内）；远端改名命令自带取消检查（原子，退出码 2 即跳过就位）。
	# 启动即播报：子进程第一行，让「供给已启动」在日志里第一时间可见，其后的下载源行/进度行都能接上
	Write-Output ('本地供给已启动：直接开始下载（产物 {0}），不为预检单开 SSH 连接。' -f $产物名)

	# 分块 HTTP 断点续传下载（失败无限重试、逐源轮试，重试时刻对齐到下个汇报周期）。主模块会在远程获胜时击杀本进程树；本进程另自带「父进程已死即自终止」看护。
	# 落点分两个名字（并发隔离的关键）：
	#   成品名 = race-supply-<提交号>-<远程包名>（只放**完整**包，跨连接/跨提交号复用）；
	#   在途名 = <成品名>.downloading-<PID>（本进程私有，两个并发供给进程永不写同一文件）。
	# 旧写法两个进程（尤其是主模块已死却没被杀掉的孤儿）直接 Append 同一个成品名，后者报「The process cannot access the file ... being used by another process」并连续重试：实测堵了 8 分钟、刷了六条「下载中断」，而那八分钟里对方一直在全速下载到 193㎆。
	# 现在的行为：成品完整则直接用；他人遗留且无人持有的半成品改名认领续传；他人正持有写句柄则**等它下完并接管上传**（不重复抢带宽），久无进展才转独立文件自行下载。
	$成品路径 = Join-Path $env:TEMP $本地文件名
	$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $成品路径)
	$在途目录 = Split-Path $成品路径
	$在途过滤 = ((Split-Path $成品路径 -Leaf) + '.downloading*')
	$在途路径 = ($成品路径 + '.downloading-' + $PID)
	$下载目标路径 = $在途路径
	$本地包路径 = $成品路径
	# 等他对方的状态：连续多少个周期尺寸没长（判僵死）与上次尺寸
	$停滞周期数 = 0
	$上次他方尺寸 = -1
	$重试次数 = 0
	# 源清单只在真要联网时公布一次（缓存命中直接跳过则一行不多打）：无限重试下每轮中断都重刷整条 URL 会把日志淹掉，中断行改用「源 序号/总数」回指本清单
	$源清单已公布 = $false
	# 报告周期在重试循环外初始化：断点续传时继承上一段的周期，不从 1 秒重新开始
	$报告周期秒数 = 1
	# 总计已用秒数的计时起点同样在重试循环外：估算平均速度 = 已下载字节数 / 总计已用秒数
	$下载起始时刻 = Get-Date
	# 同一产物已确认的总长度跨连接保留，等待响应头与续传重连也继续显示百分比；新响应的明确长度会更新它。
	$已知总长度 = 0
	# 单一时钟（汇报周期既是进度行的打印节奏，也是中断行与重试的节奏）：
	# ①上次汇报时刻由进度行与中断行共同推进，一轮里两类行不会各打一遍——一次中断恒为一条消息（旧写法进度行与中断行各有各的计时，一次中断能产出两条）；
	# ②重试等到下个汇报周期：等待 = 周期 − 本轮在上次汇报之后已耗掉的秒数（下限 1 秒）——一次耗时几十秒的停等本身就算消耗了一个周期，不在其上再叠固定等待，周期上限也不写死（旧写法封顶 30 秒，每 30 秒必刷一行）；
	# ③周期只在「本轮一个字节都没落地」时放宽一档（与「总量未知只增不减」同规则）；本轮有进度时周期已由 下次汇报间隔 自适应，失败不额外拖慢恢复。
	# 时钟初值必须是现实时刻，绝不能用 [datetime]::MinValue：否则 catch 里算「本轮已耗」会得 -6.4e10 秒，`[int]` 转换抛 InvalidCastIConvertible，而异常从 catch 逸出会穿透 while 重试循环、本供给进程当场失败（实测缺陷，已由 _probe\download-log-selftest.ps1 的 stderr 断言拦下）。
	$上次汇报时刻 = Get-Date
	$等待秒数 = 1
	while ($true) {
		# 父进程（主模块）已死 = 本次连接已不存在，继续下载只会白耗带宽并堵死后来者
		if (-not (测-父进程仍在)) {
			Write-Output ('父进程（模块，PID {0}）已退出，本地供给自行终止（下载/等待阶段）。' -f $父进程ID)
			return
		}
		# 成品已完整（自己的缓存 / 另一供给进程刚下完 / 素材跨提交号复用）就不再碰网络，直接进上传
		if ((Test-Path -LiteralPath $成品路径) -and (测试-本地包完整 $成品路径)) {
			Write-Output ('本地缓存已完整：{0} 字节，跳过下载。' -f (Get-Item -LiteralPath $成品路径).Length)
			$本地包路径 = $成品路径
			break
		}

		# ===== 并发归属判定：谁在写同一产物就等谁，绝不两个进程共写一个文件 =====
		$他方持有 = @()
		# 旧版孤儿直接写成品名，新版写在途名，两者都要看（升级过渡期两种形态共存）
		if (测-文件被占用 $成品路径) { $他方持有 += $成品路径 }
		foreach ($候 in @(Get-ChildItem -LiteralPath $在途目录 -Filter $在途过滤 -ErrorAction SilentlyContinue | Sort-Object Length -Descending)) {
			if ($候.FullName -eq $在途路径 -or $候.FullName -eq $下载目标路径) { continue }
			# 归属判据 = 写句柄被持有 **或** 属主 PID 存活；只看句柄会把「活属主正在等下个汇报周期」的瞬间误判成无人遗留
			if ((测-文件被占用 $候.FullName) -or (测-属主存活 $候.FullName)) { $他方持有 += $候.FullName }
		}
		if ($他方持有.Count -gt 0 -and $下载目标路径 -ne ($在途路径 + '.solo')) {
			$他方 = $他方持有[0]
			$他方尺寸 = 0
			if (Test-Path -LiteralPath $他方) { $他方尺寸 = (Get-Item -LiteralPath $他方).Length }
			# 如实报属主身份与判据：等谁、为什么等（句柄占用还是属主存活）都要看得出来，不能让人按字节数猜
			$他方属主ID = 取-属主PID $他方
			$他方属主 = if ($他方属主ID -gt 0) { ('PID ' + $他方属主ID + $(if (测-属主存活 $他方) { '，存活' } else { '，句柄占用中' })) } else { '旧版孤儿（直接写成品名）' }
			if ($他方尺寸 -eq $上次他方尺寸) { $停滞周期数++ } else { $停滞周期数 = 0; $上次他方尺寸 = $他方尺寸 }
			if ($停滞周期数 -ge 60) {
				# 对方僵死（连续 60 个轮次尺寸不长 = 至少一分钟无任何进展）：不再干等，改用自己的独立文件从头下载
				$下载目标路径 = ($在途路径 + '.solo')
				Write-Output '另一供给进程连续一分钟无进展，判定僵死，本进程改用独立文件自行下载。'
			} else {
				# 等他下完（重复下 ~190MB 只会互相抢带宽）：沿用同一汇报时钟，首轮立即报一次，其后按周期报
				$此刻 = Get-Date
				if (($此刻 - $上次汇报时刻).TotalSeconds -ge $报告周期秒数) {
					$上次汇报时刻 = $此刻
					# 等待期的汇报周期同样只增不减（总量未知无参照，放宽不设上限）
					$报告周期秒数++
					Write-Output ('另一供给进程正在下载同一产物（属主 {0}，已传 {1} 字节），等它完成后直接接管上传，不重复下载...' -f $他方属主, $他方尺寸)
				}
				Start-Sleep -Seconds 1
				continue
			}
		}

		# 认领无人持有的遗留半成品（上一轮进程被杀留下的）：改名接过来续传，避免从头再下；多余的一并清掉防 TEMP 堆积。
		# 「无人持有」= 没有写句柄 **且** 属主 PID 已消失。少了后半段判据就会把活属主的半成品抢走（见 测-属主存活 的实测教训）。
		if (-not (Test-Path -LiteralPath $下载目标路径)) {
			foreach ($候 in @(Get-ChildItem -LiteralPath $在途目录 -Filter $在途过滤 -ErrorAction SilentlyContinue | Sort-Object Length -Descending)) {
				if ($候.FullName -eq $下载目标路径) { continue }
				if (测-文件被占用 $候.FullName) { continue }
				if (测-属主存活 $候.FullName) { continue }
				if (-not (Test-Path -LiteralPath $下载目标路径)) {
					try {
						# 如实报属主身份：为什么认定它无人认领（PID 已消失）也得看得出来，不能让人按字节数猜
						$遗留属主ID = 取-属主PID $候.FullName
						$遗留属主 = if ($遗留属主ID -gt 0) { ('属主 PID ' + $遗留属主ID + ' 已消失') } else { '属主不明（旧版命名）' }
						$认领字节 = $候.Length
						$认领原名 = $候.Name
						Move-Item -LiteralPath $候.FullName -Destination $下载目标路径 -Force -ErrorAction Stop
						Write-Output ('认领遗留半成品续传：{0} 字节（原名 {1}，{2}）。' -f $认领字节, $认领原名, $遗留属主)
					} catch {
						Remove-Item -LiteralPath $候.FullName -Force -ErrorAction SilentlyContinue
					}
				} else {
					# 已认领过一份：其余未持有且属主已死的遗留半成品都是同一产物的重复副本，删掉（内容一致，留着只吃磁盘）
					Remove-Item -LiteralPath $候.FullName -Force -ErrorAction SilentlyContinue
				}
			}
		}

		$重试次数++
		if (-not $源清单已公布) {
			$源清单已公布 = $true
			# 单源时不报清单：那条 URL 与远端自下载侧的「开始下载: …」完全同一条（两端地址均由主模块从同一处下发），同一份日志里重复两遍只会让人怀疑两处不一样；本地供给直接从进度行开始。
			# 多源才真有本地独有信息（备源清单与轮试顺序，中断行里的「源 2/3」也靠它才有出处），此时才报。
			if ($地址列表.Count -gt 1) {
				$源清单 = ((1..$地址列表.Count | ForEach-Object { '{0}) {1}' -f $_, $地址列表[$_ - 1] }) -join '；')
				Write-Output ('本地下载备源（共 {0} 个，按序轮试）：{1}' -f $地址列表.Count, $源清单)
			}
		}
		# 本轮字节计数归零：catch 里靠「本轮落地 vs 轮起」判是否毫无进展，上一轮的残留值会让瞬时失败轮误判为「有进展」而周期不放宽
		$已下载 = 0
		$轮起已下载 = 0
		$已存在字节数 = 0
		# 本轮放宽至多一次：头阶段 0 字节行与中断行都会放宽周期，一次快速失败的连接尝试若两条都发就计了两次放宽，重试退避翻倍加速；头阶段汇报过则由它承担本轮放宽，中断行不再重复
		$头阶段已汇报 = $false
		if (Test-Path -LiteralPath $下载目标路径) { $已存在字节数 = (Get-Item -LiteralPath $下载目标路径).Length }
		# 「本次汇报相比上次有无进展」的比对基线：轮起始于磁盘字节数；$轮起已下载 也钉在轮起磁盘值（重建后累计值从磁盘刷新，轮级证据不失真）
		$轮起已下载 = $已存在字节数
		$上次汇报字节数 = $已存在字节数
		$响应 = $null
		$响应流 = $null
		$文件流 = $null
		try {
			# 多源轮试：每次重试换下一个源（部分源可能整站不可达，如 GitHub 直连被断），同一半成品跨源续传（各源内容一致）
			$当前地址 = $地址列表[($重试次数 - 1) % $地址列表.Count]
			# ===== 连接循环：停滞 ⇒ 循环内干净重建（continue）；流正常结束或真实错误才离开循环 =====
			# 停滞判定不写死秒数，与自适应汇报周期同一个时钟：汇报点发现累计字节相比上次汇报毫无增长（整整一个周期没收到一个字节）即判连接停滞，**干净重建 HTTP 连接**续传（Range 从磁盘断点恢复），不按失败处理：不打中断行、不计重试次数、不插额外等待。
			# 停滞**重建事件**也只把周期放宽一档（+1，与无进展汇报同规则）：无上限、无封顶、基于**当时值**——重建只重置计时起点 $上次汇报时刻，周期值原样带过去继续增长，**绝不翻倍也不重置回初值**；持续停滞下窗口按 1,2,3,4,5… 等差增长，慢启动源的窗口同样终将越过其延迟。任何字节一旦进展，周期即交还 下次汇报间隔 按真实速度收敛（其收紧下限 1 秒是唯一能把周期带回小值的路径，且只发生在真实进展之后）。
			# （重）连后第一次汇报只记基线不判定（新连接还没给过一个窗口）；尚未收到任何字节的慢启动阶段仍按时钟照报 0 字节行，可观测性不变。
			while ($true) {
				$需重建 = $false
				$连接后首报 = $true
				$请求 = [System.Net.HttpWebRequest]::Create($当前地址)
				# 显式 UA 必带：centos-vault 镜像对无 UA/非浏览器请求回 403（实测阿里云拒裸 HttpWebRequest）
				$请求.UserAgent = 'Mozilla/5.0'
				$请求.Timeout = 60000
				$请求.ReadWriteTimeout = 60000
				if ($已存在字节数 -gt 0) { $请求.AddRange($已存在字节数) }
				# ===== 响应头阶段同样可观测：同步 GetResponse 期间（DNS/TLS/服务器排队）旧写法整段静默 =====
				# 改 BeginGetResponse + 1 秒切片：到钟点就报一行（总量未知句式，此时已写盘字节只能是断点续传起点，全新下载即 0），首字节迟迟不到日志也不死寂
				$期望长度 = 0
				$响应任务 = $请求.BeginGetResponse($null, $null)
				while (-not $响应任务.AsyncWaitHandle.WaitOne(1000)) {
					$此刻 = Get-Date
					if (($此刻 - $上次汇报时刻).TotalSeconds -ge $报告周期秒数) {
						$上次汇报时刻 = $此刻
						$零进展 = ($已存在字节数 -le $上次汇报字节数)
						# 整整一个周期没有新字节 ⇒ 停滞：不再等响应头，干净重建（连后首报只记基线不判定）
						if ((-not $连接后首报) -and $零进展) { $需重建 = $true; break }
						if ($连接后首报) { $连接后首报 = $false }
						$上次汇报字节数 = $已存在字节数
						if ($已知总长度 -gt 0) {
							$进度百分比 = [math]::Round(($已存在字节数 * 100.0) / $已知总长度, 1)
							Write-Output ('本地下载进度：{0} / {1} 字节（{2}%）' -f $已存在字节数, $已知总长度, $进度百分比)
						} else {
							Write-Output ('本地下载进度：已传 {0} 字节' -f $已存在字节数)
						}
						# 响应头未到无法按本轮响应重新估算，只增不减（无上限）；能走到这里的汇报必是连后首报基线（非基线零进展已走重建，重建处同样 +1）
						$报告周期秒数++
						$头阶段已汇报 = $true
					}
				}
				if ($需重建) {
					try { $请求.Abort() } catch { }
					# 停滞重建事件也只放宽一档（+1，与无进展汇报同规则）：无上限、基于当时值，绝不翻倍也不重置回初值——重建只重置计时起点，窗口按 1,2,3,4,5… 等差增长
					$报告周期秒数++
					Write-Output ('本地下载：连接持续无新字节，已确认停滞：干净重建 HTTP 连接（续传点 {0} 字节，不算失败）' -f $已存在字节数)
					$上次汇报时刻 = Get-Date
					$上次汇报字节数 = $已存在字节数
					continue
				}
				$响应 = $请求.EndGetResponse($响应任务)
				$状态码 = [int]$响应.StatusCode
				# 206 的总长 = 已有部分 + 本段；200 的总长就是 ContentLength，不能错误叠加已有部分。长度未知时沿用本任务已确认的总长。
				if ($状态码 -eq 206) {
					$期望长度 = if ($响应.ContentLength -ge 0) { $已存在字节数 + $响应.ContentLength } else { -1 }
					$文件流 = [System.IO.File]::Open($下载目标路径, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
				}
				else {
					$期望长度 = $响应.ContentLength
					$文件流 = [System.IO.File]::Open($下载目标路径, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
					$已存在字节数 = 0
				}
				if ($期望长度 -gt 0) { $已知总长度 = $期望长度 } else { $期望长度 = $已知总长度 }
				$响应流 = $响应.GetResponseStream()
				$缓冲区 = New-Object byte[] 65536
				$已下载 = $已存在字节数
				# 汇报改为时钟驱动，进度行不再依赖「有字节到达」这个事件（与远程侧同款）：源端爬行期照样按时钟报当前累计字节数，首字节迟迟不到就报 0 字节，日志不会死寂。
				# 疏密规则：总量已知由 下次汇报间隔 按预计剩余时间自适应，总量未知 +1；零进展（停滞）重建同样 +1；放宽一律不设上限、不翻倍。
				while ($true) {
					$读取结果 = $响应流.BeginRead($缓冲区, 0, $缓冲区.Length, $null, $null)
					# EndRead 必须且只能调一次：拿到字节就结算并退出内层；本秒没拿到只走汇报点，下一轮继续在同一个异步操作上等
					$读取数 = -1
					while ($读取数 -lt 0) {
						if ($读取结果.AsyncWaitHandle.WaitOne(1000)) {
							$读取数 = $响应流.EndRead($读取结果)
						}
						$此刻 = Get-Date
						if (($此刻 - $上次汇报时刻).TotalSeconds -ge $报告周期秒数) {
							$上次汇报时刻 = $此刻
							$零进展 = ($已下载 -le $上次汇报字节数)
							# 整整一个周期没有新字节 ⇒ 断流：干净重建（连后首报只记基线不判定）
							if ((-not $连接后首报) -and $零进展) { $需重建 = $true; break }
							if ($连接后首报) { $连接后首报 = $false }
							$上次汇报字节数 = $已下载
							# 进度行与远程侧同款两种句式：总量已知报 X / Y 字节（P%），总量未知报已传 X 字节
							if ($期望长度 -gt 0) {
								$进度百分比 = [math]::Round(($已下载 * 100.0) / $期望长度, 1)
								Write-Output ('本地下载进度：{0} / {1} 字节（{2}%）' -f $已下载, $期望长度, $进度百分比)
								# 能被汇报出的零进展必是连后首报基线（非基线零进展已走重建）：按总量未知规则放宽一档；有进展由 下次汇报间隔 按预计剩余时间自适应，放宽不设上限
								if ($零进展) { $报告周期秒数++ } else { $报告周期秒数 = 下次汇报间隔 $报告周期秒数 ($此刻 - $下载起始时刻).TotalSeconds $已下载 $期望长度 }
							}
							else {
								Write-Output ('本地下载进度：已传 {0} 字节' -f $已下载)
								# 总大小未知（分块响应）时无法估算剩余时间，只增不减（无上限）
								$报告周期秒数++
							}
						}
					}
					if ($需重建) { break }
					if ($读取数 -le 0) { break }
					$文件流.Write($缓冲区, 0, $读取数)
					$已下载 += $读取数
				}
				# 逐连接关流：重建路径也要关（否则下一圈的 Append 打不开自己上一圈的写句柄），Flush 保证已收字节落盘后续传点才准
				if ($null -ne $文件流) { $文件流.Flush(); $文件流.Dispose(); $文件流 = $null }
				if ($null -ne $响应流) { $响应流.Dispose(); $响应流 = $null }
				if ($null -ne $响应) { $响应.Close(); $响应 = $null }
				if ($需重建) {
					# 停滞前已写盘的字节不丢：续传点从磁盘刷新，下一圈带 Range 续传
					$已存在字节数 = if (Test-Path -LiteralPath $下载目标路径) { (Get-Item -LiteralPath $下载目标路径).Length } else { 0 }
					# 停滞重建事件也只放宽一档（+1，与无进展汇报同规则）：无上限、基于当时值，绝不翻倍也不重置回初值——重建只重置计时起点，窗口按 1,2,3,4,5… 等差增长
					$报告周期秒数++
					Write-Output ('本地下载：连接持续无新字节，已确认停滞：干净重建 HTTP 连接（续传点 {0} 字节，不算失败）' -f $已存在字节数)
					$上次汇报时刻 = Get-Date
					$上次汇报字节数 = $已存在字节数
					continue
				}
				break
			}
			# 关流再校验：流已在连接循环内逐连接关闭（下面的 dispose 组是空安全兜底）；完整性快检要重新打开文件读，写句柄未关（FileShare.None）时 OpenRead 必失败，
			# 会把完整包误判成"疑似截断"白触发一轮重试（实测每次完整下载都中招，靠 416 兜底才救回）
			if ($null -ne $文件流) { $文件流.Dispose(); $文件流 = $null }
			if ($null -ne $响应流) { $响应流.Dispose(); $响应流 = $null }
			if ($null -ne $响应) { $响应.Close(); $响应 = $null }
			# 长度核对：流式读到底只代表连接正常关闭，不代表传输完整（实测截断包曾被当完整包送解压报晦涩的 End of Central Directory 错误）
			if ($期望长度 -gt 0 -and (Get-Item -LiteralPath $下载目标路径).Length -lt $期望长度) {
				throw ('下载提前结束：本地 {0} 字节，预期 {1} 字节。' -f (Get-Item -LiteralPath $下载目标路径).Length, $期望长度)
			}
			if (-not (测试-本地包完整 $下载目标路径)) {
				throw '本地包完整性校验未通过（疑似截断）。'
			}
			# 发布成品：把私有在途文件原子改名到稳定成品名（下次连接/其它窗口直接复用，不再重下 ~190MB）；
			# 改名失败（他人占着成品名）不致命：直接用自有在途文件上传，内容完全一致
			$本地包路径 = $下载目标路径
			if ($下载目标路径 -ne $成品路径) {
				try {
					Move-Item -LiteralPath $下载目标路径 -Destination $成品路径 -Force -ErrorAction Stop
					$本地包路径 = $成品路径
				} catch {
					Write-Output ('成品名暂不可写入（{0}），改为直接用本进程在途文件上传。' -f $_.Exception.Message)
				}
			}
			Write-Output ('本地下载完成：共 {0} 字节。' -f (Get-Item -LiteralPath $本地包路径).Length)
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
				if (测试-本地包完整 $下载目标路径) {
					Write-Output ('服务器返回 416：本地文件 {0} 字节已完整，无需续传。' -f $已存在字节数)
					$本地包路径 = $下载目标路径
					break
				}
				Remove-Item -LiteralPath $下载目标路径 -Force -ErrorAction SilentlyContinue
				Write-Output '服务器返回 416 但本地包完整性校验未通过，删除后从头重下。'
				continue
			}
			# 文件共享冲突（being used by another process）不是网络失败：私有在途名下已几乎不可能发生，万一碰上（认领竞态）也不该当网络故障计入重试与周期放宽，下个周期回循环顶重新判归属即可
			if ($_.Exception -is [System.IO.IOException] -and $_.Exception.Message -match 'being used by another process') {
				$此刻 = Get-Date
				$等待秒数 = [Math]::Max(1, [int][Math]::Ceiling($报告周期秒数 - ($此刻 - $上次汇报时刻).TotalSeconds))
				Start-Sleep -Seconds $等待秒数
				$上次汇报时刻 = Get-Date
				Write-Output '上个汇报周期内下载目标文件被另一进程持有（非网络故障，不计入重试）。本次汇报即重新判定归属'
				continue
			}
			# 源序号与多源轮试的取址规则严格同源（$地址列表[($重试次数 - 1) % Count]），中断行只报序号不再重刷整条 URL
			$源序号 = (($重试次数 - 1) % $地址列表.Count) + 1
			$中断原因 = $_.Exception.Message
			# 原因来自各处 throw，末尾常自带句号；直接接模板分隔符就拼出「字节。，源 1/1」这种错标点。统一剥掉尾部标点与空白后再拼（本模板把原因放最后并以句号收尾，不再让原因夹在中间）
			$中断原因 = $中断原因.TrimEnd('。', '.', '，', ',', '；', ';', '！', ' ', "`r", "`n")
			# 停滞不再走这里（连接循环内干净重建），这里只收真实错误（连接被拒/DNS/HTTP 状态码/截断）
			$此刻 = Get-Date
			# 续传点 = 失败瞬间的在途文件长度（比「本轮起点字节数」更能反映真实进度；416 分支刚删掉文件时按 0 报）
			$续传点字节数 = 0
			if (Test-Path -LiteralPath $下载目标路径) { $续传点字节数 = (Get-Item -LiteralPath $下载目标路径).Length }
			# 本轮毫无进展（连接被拒/DNS 失败等真实错误；停滞已改为循环内干净重建不进 catch）才放宽一档，与远程侧同规则且放宽不设上限；头阶段已汇报过则本轮放宽已由它承担，不二次放宽
			if (($已下载 -le $轮起已下载) -and (-not $头阶段已汇报)) { $报告周期秒数++ }
			# 异常只在下个汇报周期打印，打印后立即续传；不得在异常发生的瞬间抢先汇报。
			$等待秒数 = [Math]::Max(1, [int][Math]::Ceiling($报告周期秒数 - ($此刻 - $上次汇报时刻).TotalSeconds))
			Start-Sleep -Seconds $等待秒数
			$上次汇报时刻 = Get-Date
			Write-Output ('上个汇报周期内下载中断（第 {0} 次，源 {1}/{2}，续传点 {3} 字节）：{4}。本次汇报即续传重试' -f $重试次数, $源序号, $地址列表.Count, $续传点字节数, $中断原因)
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

	# Windows：独立 scp 上传 + 改名（LAN 快，不走单会话）。上传→核对→改名整体最多两轮：并发连接会在自己竞速起步时把整个暂存目录删掉重建（暂存目录只按提交号命名、不带连接唯一性），把本进程刚上传的在途文件连目录一起清走→改名命令报「在途文件不在」（实测退出码 1 + 真因被 CLIXML 垃圾淹没）。此时（且仅此时）自动重传一次即自愈，不再只报一句失败就放弃本地供给。
	for ($上传轮 = 1; $上传轮 -le 2; $上传轮++) {
		# 上传前不再单开连接复检取消标记：远端获胜的瞬间主流程即按「竞速获胜」行击杀本进程树（事件驱动，约 1 秒内），且远端改名命令自带取消检查（退出码 2 即跳过就位）——复检只堵约 1 秒的窗口，却要一次完整 SSH 连接（慢主机上以分钟计）

		$scp命令 = Get-Command scp -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($上传轮 -eq 1) {
			Write-Output '开始上传本地压缩包到暂存目录...'
		}
		else {
			Write-Output '远端暂存文件已被并发连接清走，重新上传一次...'
		}
		$上传目标 = ('{0}:{1}{2}{3}.uploading' -f $连接目标, $暂存目录, $分隔符, $远程包名)
		$null = & $scp命令.Source (@('-P', $端口) + $密码选项 + @($本地包路径, $上传目标)) 2>&1
		if ($LASTEXITCODE -ne 0) { Write-Output ('上传失败，退出码 {0}，本地供给退出（远程将继续自下载）。' -f $LASTEXITCODE); return }

		# 上传完整性核对：远端字节数必须与本地一致才写完成标记（scp 断流截断时绝不放行，否则远端会拿坏包解压）
		$本地大小 = (Get-Item -LiteralPath $本地包路径).Length
		$核对命令 = 转换-远程PowerShell命令 ('if (Test-Path -LiteralPath "{0}\{1}.uploading") {{ Write-Output ("__VSI_SIZE__:" + [long](Get-Item -LiteralPath "{0}\{1}.uploading").Length) }} else {{ Write-Output "__VSI_SIZE__:-1" }}' -f $远端暂存目录文本, $远程包名)
		$核对结果 = 调用-远程命令 $核对命令
		# 只认 __VSI_SIZE__: 后的数字（避开 ssh 的 CNAME 警告、CLIXML 垃圾与本地 PowerShell 对原生 stderr 的包装模板把它误当成大小）；-1 = 上传后又没了
		$远端大小 = -1
		foreach ($段 in @($核对结果.原始输出 -split '[\r\n|]+')) {
			if ($段 -match '__VSI_SIZE__\s*:\s*(-?\d+)') { $远端大小 = [long]$matches[1] }
		}
		if ($核对结果.退出码 -ne 0 -or $远端大小 -ne $本地大小) {
			if ($远端大小 -lt 0) {
				Write-Output ('上传核对失败：远端已无在途文件（本地 {0} 字节），疑似被并发连接清走。' -f $本地大小)
				if ($上传轮 -lt 2) { continue }
				return
			}
			Write-Output ('上传核对失败：远端 {0} 字节 ≠ 本地 {1} 字节，放弃本次改名与标记。' -f $远端大小, $本地大小)
			return
		}

		# 原子改名 + 写完成标记。**结果码走 stdout 标记 __VSI_RC__:n，不得依赖退出码**：实测两台 Windows 主机的 OpenSSH sshd 把**任何非零退出码压平成 1**（`exit 2`/`exit 3`/`cmd /c exit 7` 全部变 1，只有 0 原样传回），于是「远程已获胜」与「真失败」在调用方看来一模一样：旧代码的 exit 2 分支根本进不去，本属正常的「远程已获胜」被报成了「改名/标记命令失败（退出码 1）」。约定：0 = 已就位并写标记；2 = 远程已获胜；3 = 在途文件不在（可重传自愈）；1 = 其它失败。目标已存在且长度一致时直接当成功（幂等）：文件名含提交号，同名即同版本；并发窗口先一步改过名时本进程不该再报失败。
		# 异常真因用 __VSI_ERR__: 标记回传：旧写法只把 $_.Exception.Message 丢进 stdout，一旦同时吐 CLIXML 与 ssh 的 mDNS 噪声，真因就被上千字噪声淹没成完全不可读的日志（实测只看到 ignoring bad CNAME 与 #< CLIXML，看不出任何错误）。
		$改名脚本 = ('if (Test-Path -LiteralPath "{0}\{3}") {{ Write-Output "__VSI_RC__:2"; exit 2 }}; ' +
			'if (-not (Test-Path -LiteralPath "{0}\{1}.uploading")) {{ Write-Output "__VSI_RC__:3"; Write-Output "__VSI_ERR__:在途文件不在（暂存目录被并发连接重建或已被清理）"; exit 3 }}; ' +
			'try {{ ' +
			'if (Test-Path -LiteralPath "{0}\{1}") {{ if ((Get-Item -LiteralPath "{0}\{1}.uploading").Length -eq (Get-Item -LiteralPath "{0}\{1}").Length) {{ New-Item -ItemType File -Force "{0}\{2}" -ErrorAction Stop | Out-Null; Write-Output "__VSI_RC__:0"; Write-Output "__VSI_ERR__:目标已存在且长度一致，沿用已就位包并补写标记"; exit 0 }} }}; ' +
			'Move-Item -LiteralPath "{0}\{1}.uploading" -Destination "{0}\{1}" -Force -ErrorAction Stop; ' +
			'New-Item -ItemType File -Force "{0}\{2}" -ErrorAction Stop | Out-Null; Write-Output "__VSI_RC__:0" ' +
			'}} catch {{ Write-Output "__VSI_RC__:1"; Write-Output ("__VSI_ERR__:" + $_.Exception.GetType().Name + ": " + ($_.Exception.Message -replace "\s+", " ")); exit 1 }}') -f $远端暂存目录文本, $远程包名, $完成标记名, $取消标记名
		$改名结果 = 调用-远程命令 (转换-远程PowerShell命令 $改名脚本)
		# 结果码优先取 stdout 标记；拿不到标记时退回退出码（只保留 0/非0 语义，此时 2/3 不可分，按失败处理并报清两个码）
		$改名码 = $改名结果.退出码
		foreach ($段 in @($改名结果.原始输出 -split '[\r\n|]+')) {
			if ($段 -match '__VSI_RC__\s*:\s*(\d+)') { $改名码 = [int]$matches[1] }
		}
		$码说明 = $(if ($改名码 -eq $改名结果.退出码) { $改名码 } else { '' + $改名码 + '（ssh 退出码 ' + $改名结果.退出码 + '）' })
		if ($改名码 -eq 0) {
			Write-Output ('本地供给完成：包已就位并写入完成标记（{0} 字节）。{1}' -f $本地大小, $改名结果.输出)
			return
		}
		if ($改名码 -eq 2) {
			Write-Output '远程侧已获胜，本地供给取消（改名前）。'
			return
		}
		if ($改名码 -eq 3 -and $上传轮 -lt 2) {
			Write-Output ('远端改名未完成：{0}' -f $改名结果.输出)
			continue
		}
		Write-Output ('改名/标记未完成（结果码 {0}），远端原因：{1}，远程将继续自下载。' -f $码说明, $(if ([string]::IsNullOrWhiteSpace($改名结果.输出)) { '远端未回传可读原因（仅噪声，已过滤）' } else { $改名结果.输出 }))
		return
	}
}
catch {
	Write-Output ('本地供给任务异常终止: {0}' -f $_.Exception.Message)
}