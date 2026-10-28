# 探针公共库 —— 把历次线上取证里反复重写的通用逻辑固定下来，只放**与具体故障无关**的原语。
#
# 引入方式（探针脚本开头一行）：
#	. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')     # 或 . "$PSScriptRoot\lib\探针公共库.ps1"
#
# 为什么要有这个库：2026-10-23 排查「B 服务器连接卡死」时，同一个「base64 argv 下发远端脚本」的原语
# 被我在十个一次性探针里各抄了一遍，抄漏一次（忘了 ssh -n / 忘了 BatchMode）就让探针自己挂在密码提示上；
# 载荷构造算法也在三个脚本里各抄一遍，任何一个抄歪都会得出「通道有罪」的错误结论。
# 固定成一处后，探针只写「要问远端什么问题」，传输与噪声处理都不再由每个探针各自负责。
#
# 三条铁律（都是线上踩出来的，改动前务必读完）：
#   ① 远端命令一律走 argv 里的 base64：PS 5.1 向原生命令传参时会剥掉内嵌双引号，复杂脚本整体 EncodedCommand，
#      命令行只剩 base64，任何 shell 元字符都碰不到；载荷本身必须是 LF（CRLF 里的 \r 会被远端并入命令）。
#   ② 探针自身的一切远端等待必须有界：无界等待会把探针变成孤儿（诊断脚本自己成了故障源——
#      本轮 B 服务器上的死亡螺旋就是这样被一次次「重试」喂大的）。
#   ③ 载荷构造必须与 psm1 生产算法逐字节同源：lib-selftest.ps1 里有漂移守卫，改一处必须两处一致。

# ==========================================================================================
#  一、断言台账（兼容三种历史调用顺序，故各自检可直接换掉本地实现而不改百余处调用点）
# ==========================================================================================
$script:断言通过数 = 0
$script:断言失败数 = 0
$script:断言失败清单 = New-Object System.Collections.Generic.List[string]
$script:断言通过前缀 = 'OK   '
$script:断言失败前缀 = 'FAIL '
$script:断言细节分隔 = ' —— '

function Initialize-断言 {
	param(
		[string]$通过前缀 = 'OK   ',
		[string]$失败前缀 = 'FAIL ',
		[string]$细节分隔 = ' —— '
	)
	# 台账清零并设定输出前缀：各历史自检的前缀不同（'OK  '/'FAIL '、'  [通过] '/'  [失败] '），
	# 迁移到公共库时只需在这里设一次，调用点一行都不用改
	$script:断言通过数 = 0
	$script:断言失败数 = 0
	$script:断言失败清单 = New-Object System.Collections.Generic.List[string]
	$script:断言通过前缀 = $通过前缀
	$script:断言失败前缀 = $失败前缀
	$script:断言细节分隔 = $细节分隔
}

function 写-断言 {
	param(
		[Parameter(Position = 0)] $甲,
		[Parameter(Position = 1)] $乙,
		[Parameter(Position = 2)][string]$细节 = ''
	)
	# 兼容历史三种写法：(说明,条件)、(条件,说明)、命名参数 -说明/-条件。
	# 靠**实参类型**判方向，不靠位置——各自检当初各写各的，硬统一位置会改上百个调用点
	if ($甲 -is [bool]) { $条件 = $甲; $说明 = [string]$乙 } else { $说明 = [string]$甲; $条件 = [bool]$乙 }
	if ($条件) {
		$script:断言通过数++
		Write-Host ($script:断言通过前缀 + $说明)
	} else {
		$script:断言失败数++
		$script:断言失败清单.Add($说明)
		Write-Host ($script:断言失败前缀 + $说明 + $(if ($细节 -ne '') { $script:断言细节分隔 + $细节 } else { '' }))
	}
}

function 取-断言计数 {
	# 给需要自定义汇总措辞的自检用（历史上有「审计问题总数」「断言失败数」「累计失败数」三种格式），
	# 台账与计数逻辑仍只在库里一份，避免各自维护一份又各自漂移
	return [pscustomobject]@{
		通过 = $script:断言通过数
		失败 = $script:断言失败数
		清单 = @($script:断言失败清单)
	}
}

function 写-断言汇总 {
	param(
		[string]$标题 = '汇总'
	)
	# 打印通过/失败计数与失败明细；返回 $true 表示全过（调用方可 exit $(if(写-断言汇总){0}else{1})）
	Write-Host ''
	Write-Host ('===== ' + $标题 + '：通过 ' + $script:断言通过数 + ' 项，失败 ' + $script:断言失败数 + ' 项 =====')
	if ($script:断言失败数 -gt 0) {
		Write-Host '失败明细：'
		foreach ($条 in $script:断言失败清单) { Write-Host ('  - ' + $条) }
		return $false
	}
	Write-Host '全部通过。'
	return $true
}

# ==========================================================================================
#  二、仓库路径与语法/BOM 校验（改完必查：PS 5.1 会把无 BOM 的 UTF-8 按 ANSI 误读，双 BOM 会让 param() 解析失败）
# ==========================================================================================
function 取-仓库根 {
	# 从本库所在目录（_probe\lib）回溯到仓库根，供各探针拼模块路径。
	# 必须用 $PSScriptRoot：在函数里 MyCommand 的 Definition 属性返回的是**函数体文本**而不是文件路径
	#（实测把整段注释当成路径拼进去，Resolve-Path 报 Illegal characters in path）。
	return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function 取-模块目录 {
	return (Join-Path (取-仓库根) '接管远程服务器安装扩展\scripts')
}

function 取-私有目录 {
	return (Join-Path (取-模块目录) 'private')
}

function 校-脚本语法 {
	param(
		[Parameter(Mandatory = $true)][string]$路径
	)
	# 返回 @{路径;语法错误;错误明细;BOM数;文本}。BOM 数 >1 是**硬缺陷**：会让 param() 不再是首个 token，
	# typed 参数被当表达式解析，报出与真因无关的「The assignment expression is not valid」（指向参数默认值那一行）。
	# BOM 数 0 对含中文标识符的 .ps1 同样是缺陷（PS 5.1 按 ANSI 误读 → 标识符乱码 → 找不到命令）。
	$完整路径 = (Resolve-Path -LiteralPath $路径).Path
	$字节 = [System.IO.File]::ReadAllBytes($完整路径)
	$BOM数 = 0
	$位 = 0
	while (($位 + 2) -lt $字节.Length -and $字节[$位] -eq 0xEF -and $字节[$位 + 1] -eq 0xBB -and $字节[$位 + 2] -eq 0xBF) { $BOM数++; $位 += 3 }
	$错 = $null; $词 = $null
	$null = [System.Management.Automation.Language.Parser]::ParseFile($完整路径, [ref]$词, [ref]$错)
	return [pscustomobject]@{
		路径     = $完整路径
		语法错误 = @($错).Count
		错误明细 = @($错 | ForEach-Object { ('L' + $_.Extent.StartLineNumber + ': ' + $_.Message) })
		BOM数    = $BOM数
		文本     = (Get-Content -LiteralPath $完整路径 -Raw -Encoding UTF8)
	}
}

function 补-脚本BOM {
	param(
		[Parameter(Mandatory = $true)][string]$路径
	)
	# 把 BOM 个数规范成恰好 1 个：0 个则补（PS 5.1 读含中文脚本必需），多于 1 个则剥到只剩 1 个
	$完整路径 = (Resolve-Path -LiteralPath $路径).Path
	$查 = 校-脚本语法 -路径 $完整路径
	if ($查.BOM数 -eq 1) { return $false }
	$字节 = [System.IO.File]::ReadAllBytes($完整路径)
	$位 = 0
	while (($位 + 2) -lt $字节.Length -and $字节[$位] -eq 0xEF -and $字节[$位 + 1] -eq 0xBB -and $字节[$位 + 2] -eq 0xBF) { $位 += 3 }
	$正文 = $字节[$位..($字节.Length - 1)]
	$头 = [byte[]](0xEF, 0xBB, 0xBF)
	[System.IO.File]::WriteAllBytes($完整路径, ($头 + $正文))
	return $true
}

function 扫-裸拼接实参 {
	param(
		[Parameter(Mandatory = $true)][string]$路径,
		[string[]]$命令名 = @('断言')
	)
	<#
	.SYNOPSIS
	找出「在参数模式里裸用 + 拼消息」的调用：断言 ($条件) '前半' + $x + '后半'。
	这种写法里 + / $x / '后半' 会被解析成**额外实参**而不是字符串拼接，命令直接抛
	PositionalParameterNotFound；若调用方不盯子命令的错误，这个抛出会被后续语句接着
	执行吞掉，脚本照旧打印「失败 0 项」——实测踩过：report-point-audit 里
	__VSI_ERR__ 那条断言从未真正跑过，却连着几轮都算进「全绿」。
	正确写法是把整段消息加括号：断言 ($条件) ('前半' + $x + '后半')。
	判据走 AST 不走文本正则：裸 + 会成为一个独立命令元素、其文本恰为 '+'；
	而括号里的拼接整体是一个 ParenExpressionAst，不会误报。
	#>
	$tokens = $null; $errors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($路径, [ref]$tokens, [ref]$errors)
	if ($null -eq $ast) { return @() }
	$命中 = New-Object System.Collections.Generic.List[pscustomobject]
	foreach ($cmd in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
		$名 = $cmd.GetCommandName()
		if ($命令名 -notcontains $名) { continue }
		$裸加 = @($cmd.CommandElements | Where-Object { $_.Extent.Text -eq '+' })
		if ($裸加.Count -eq 0) { continue }
		$文本 = $cmd.Extent.Text
		$命中.Add([pscustomobject]@{
			路径   = $路径
			行号   = $cmd.Extent.StartLineNumber
			命令名 = $名
			裸加数 = $裸加.Count
			原文   = $(if ($文本.Length -gt 160) { $文本.Substring(0, 160) + '…' } else { $文本 })
		})
	}
	return $命中
}

# ==========================================================================================
#  三、单会话载荷构造 —— 必须与 psm1 执行-Windows单会话安装 逐字节同源
# ==========================================================================================
function 构造-单会话载荷 {
	param(
		[Parameter(Mandatory = $true)][string]$安装脚本文本,
		[string]$引导模板路径 = ''
	)
	# 还原生产的四步：去整行注释与空行 → gzip → base64 = 载荷；载荷塞进引导模板 = 引导脚本；
	# 引导脚本按 UTF-16 再 base64 = 引导码（这一步让体积膨胀约 2.67 倍，正是当年撞 argv 上限的原因）；
	# 引导码**整段**直接作为经 stdin 下发的载荷标准输入。不分块：远端 windows-stdin-bootstrap.ps1 是 ReadToEndAsync 读全量后 `-replace '\s',''` 剔掉全部空白再解码，行结构对传输没有任何意义（旧写法的 4000 字符分块 + 「长度 == 引导码长度 + 块数」自校验已删：那是自己切自己拼自己校，拦不下传输层问题）。
	# 真正要守的前提改由 `载荷不含空白` 字段表达：base64 不含空白 → 传输中被塞入任何空白（如 PS 管道把行尾换成 CRLF）都会在远端被剔净，因而无损。
	if ($引导模板路径 -eq '') { $引导模板路径 = Join-Path (取-私有目录) 'Windows单会话引导.ps1' }
	$引导模板 = Get-Content -LiteralPath $引导模板路径 -Raw -Encoding UTF8

	$精简正文 = (($安装脚本文本 -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join "`n"
	$压缩流 = New-Object System.IO.MemoryStream
	$压缩器 = New-Object System.IO.Compression.GZipStream($压缩流, [System.IO.Compression.CompressionMode]::Compress)
	$正文字节 = [System.Text.Encoding]::UTF8.GetBytes($精简正文)
	$压缩器.Write($正文字节, 0, $正文字节.Length)
	$压缩器.Close()
	$载荷 = [Convert]::ToBase64String($压缩流.ToArray())

	$引导脚本 = $引导模板.Replace('__载荷__', $载荷)
	$引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($引导脚本))

	$载荷标准输入 = $引导码

	return [pscustomobject]@{
		精简正文字符 = $精简正文.Length
		gzip字节     = $压缩流.ToArray().Length
		载荷         = $载荷
		引导脚本     = $引导脚本
		引导码       = $引导码
		载荷标准输入 = $载荷标准输入
		载荷不含空白 = (-not ($载荷标准输入 -match '\s'))
	}
}

function 构造-固定引导码 {
	# argv 里唯一常驻的部分：windows-stdin-bootstrap.ps1 按 UTF-16 base64。它的长度直接决定 argv 占用，
	# 必须远小于 CreateProcess 上限 32767（生产里有 8000 字符守卫线）。
	param([string]$引导路径 = '')
	if ($引导路径 -eq '') { $引导路径 = Join-Path (取-私有目录) 'windows-stdin-bootstrap.ps1' }
	$文 = Get-Content -LiteralPath $引导路径 -Raw -Encoding UTF8
	return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($文))
}

function 取-引导码特征 {
	param(
		[int]$长度 = 48,
		[string]$引导路径 = ''
	)
	# 生产单会话安装在远端的 argv 长这样：powershell -NoProfile -EncodedCommand <固定引导码>。
	# 引导码**每次调用都逐字相同**（载荷在 stdin 上，不进 argv），所以取它的前缀就是
	# 「这个进程是生产引导」的钢印指纹，能把探针/一次性脚本的 EncodedCommand 区分开。
	# 用途：普查与陈旧树清理都靠它认孤儿（认错了会建议杀掉正在跑的安装，代价极大）。
	$码 = 构造-固定引导码 -引导路径 $引导路径
	if ($码.Length -le $长度) { return $码 }
	return $码.Substring(0, $长度)
}

# ==========================================================================================
#  四、远端下发（argv 通道）—— 探针的主力原语
# ==========================================================================================
function 剥-SSH噪声 {
	param(
		[Parameter(Mandatory = $true, ValueFromPipeline = $true)] $行集合
	)
	# 剥掉三类与结论无关的噪声：ssh 对中文主机名的 mDNS CNAME 警告、PS 进度记录被序列化成的 CLIXML 片段、
	# PS 5.1 把原生命令 stderr 包装成的 NativeCommandError/CategoryInfo 模板。
	# 不剥会让「取不到结果」与「结果被噪声淹没」两种情况无法区分（实测吃过亏）。
	# end 里必须直接发数组：写 `, $出` 会把 List 包成单元素而抑制枚举（实测调用方 @() 只拿到 1 个 List 对象、.Count 恒为 1）
	begin { $出 = New-Object System.Collections.Generic.List[string] }
	process {
		foreach ($项 in @($行集合)) {
			$t = [string]$项
			if ($t -match 'ignoring bad CNAME') { continue }
			if ($t -match '^(#< CLIXML|<Objs|</Objs>)') { continue }
			if ($t -match 'NativeCommandError|CategoryInfo|FullyQualifiedErrorId|^\+ CategoryInfo|^\+ FullyQualified') { continue }
			if ($t -match 'at line:\d+ char:\d+') { continue }
			$出.Add($t)
		}
	}
	end { $出.ToArray() }
}

function 送-远端脚本 {
	param(
		[Parameter(Mandatory = $true)][string]$主机,
		[Parameter(Mandatory = $true)][string]$脚本文本,
		[int]$端口 = 22,
		[int]$连接超时秒 = 12,
		[switch]$允许交互,     # 默认不允许：一律 BatchMode=yes，没免密就秒失败，绝不停在密码提示上把终端卡死（探针自己挂在提示上会把排障带偷）
		[switch]$不过滤标记,   # 默认只回带标记的行（噪声最小）；开此开关则回全部有效行
		[string]$标记前缀 = '__T__'
	)
	# 生产级原语：CRLF→LF、UTF-16 base64、ssh -n -o BatchMode=yes -o ConnectTimeout，回带行剥噪声后按标记过滤。
	# 返回 @{退出码;耗时秒;行}。注意 Windows sshd 会把远端一切非零退出码压平成 1，
	# 所以「退出码」不能用来区分远端内部的多种结果——要细分只能靠 stdout 标记（生产用 __VSI_RC__/__VSI_ERR__）。
	$干净脚本 = $脚本文本 -replace "`r`n", "`n"
	$编码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($干净脚本))
	$ssh参数 = @('-n')
	if (-not $允许交互) { $ssh参数 += @('-o', 'BatchMode=yes') }
	$ssh参数 += @('-o', ('ConnectTimeout=' + $连接超时秒), '-p', [string]$端口, $主机, ('powershell -NoProfile -EncodedCommand ' + $编码))
	$计时 = [System.Diagnostics.Stopwatch]::StartNew()
	$原EAP = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try { $输出 = @(& ssh.exe @ssh参数 2>&1) } finally { $ErrorActionPreference = $原EAP; $计时.Stop() }
	$有效 = @(剥-SSH噪声 -行集合 $输出)
	if ($不过滤标记) { $结果行 = $有效 } else { $结果行 = @($有效 | Where-Object { $_ -match [regex]::Escape($标记前缀) } | ForEach-Object { $_ -replace [regex]::Escape($标记前缀), '' }) }
	return [pscustomobject]@{
		退出码  = $LASTEXITCODE
		耗时秒  = [Math]::Round($计时.Elapsed.TotalSeconds, 1)
		行      = $结果行
		全部行  = $有效
		编码长度 = $编码.Length
	}
}

function 取-远端有界计时包装 {
	param(
		[Parameter(Mandatory = $true)][string]$片段,
		[int]$超时秒 = 45,
		[string]$名字 = '片段'
	)
	# 把任意远端代码片段包成 Start-Job + Wait-Job -Timeout 后返回脚本文本：
	# 用来测「某个远端调用会不会挂」而**不让探针自己跟着挂**。片段的输出必须以 __T__ 前缀回行。
	# 片段里禁止出现单引号以外的字符串定界符冲突（本函数按 here-string 原样嵌套）。
	return @'
$sw=[System.Diagnostics.Stopwatch]::StartNew()
$j = Start-Job -ScriptBlock {
__片段__
}
if (Wait-Job $j -Timeout __超时__) {
	$r = Receive-Job $j
	Write-Output ('__T__' + '__名字__' + ' 用时=' + [Math]::Round($sw.Elapsed.TotalSeconds,1) + 's')
	$r | ForEach-Object { Write-Output ('__T__ ' + $_) }
} else {
	Stop-Job $j -ErrorAction SilentlyContinue
	Write-Output ('__T__' + '__名字__' + ' 【超时 >__超时__s 挂死】← 卡点坐实')
}
Remove-Job $j -Force -ErrorAction SilentlyContinue
'@.Replace('__片段__', $片段).Replace('__超时__', [string]$超时秒).Replace('__名字__', $名字)
}

function 取-远端普查脚本 {
	param(
		[string]$提交号 = '',
		[switch]$含引导树明细,
		[switch]$含竞速文件明细,
		[string]$引导码特征 = ''
	)
	# 只读远端体检（绝不改状态）：这是排查「远端在跑 / 本地静默」类故障的第一手现场。
	# 覆盖：powershell/sshd/Start-Job 计数、引导进程分类与树龄、DefaultShell 与重定向态、
	# 竞速暂存目录、已安装 server、磁盘与家目录可写性。
	# 为什么认孤儿要三条件同时成立（缺一不可）：① argv 带生产固定引导码特征（-引导码特征，
	# 由 取-引导码特征 给出）——把探针类一次脚本分开；② 树龄 > 180 秒；③ CPU 时间几乎为零
	# ——一直阻塞在读取里没干活（正在下载 190MB 的安装 CPU 不是 0）。
	# 旧判据只看「EncodedCommand + 超龄」，实测把两个进程误判成孤儿并建议去杀：生产安装本身
	# 就用同一段固定引导码（下载几十分钟很正常），探针也是 argv+EncodedCommand 派发。按错误判据
	# 动手会杀掉活安装，所以宁可漏报不可误报：读不到 CPU 就保守当「不杀」。
	# 背景：本地看门狗 taskkill 只杀本地 ssh，Windows 不向远端传播信号，远端引导会卡在读取里成孤儿；
	# 孤儿堆积 → sshd 会话饱和 → 新连接首字节延迟超过看门狗 → 死亡螺旋（2026-10-23 B 服务器实测）。
	$片段 = @'
function T([string]$s){ Write-Output ('__T__' + $s) }
function 短([string]$s,[int]$n){ if(-not $s){return ''}; $s=($s -replace '\s+',' '); if($s.Length -gt $n){return $s.Substring(0,$n)}; return $s }
$自 = $PID
T ('远端时刻=' + (Get-Date).ToString('MM-dd HH:mm:ss'))
$ps = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue)
T ('powershell总数=' + $ps.Count)
$引导特征 = '__引导特征__'
$引导进程 = @()
$其它编码 = @()
foreach ($p in $ps) {
	$cl = [string]$p.CommandLine
	$龄 = 0
	if ($null -ne $p.CreationDate) { $龄 = [int]((Get-Date) - $p.CreationDate).TotalSeconds }
	if ($cl -match 'EncodedCommand') {
		if (($引导特征 -ne '') -and $cl.Contains($引导特征)) { $引导进程 += $p } else { $其它编码 += $p }
	}
	__树明细__
}
$疑似孤儿数 = 0
foreach ($p in $引导进程) {
	$龄 = [int]((Get-Date) - $p.CreationDate).TotalSeconds
	$u = $p.UserModeTime
	$kc = $p.KernelModeTime
	if (($null -eq $u) -or ($null -eq $kc)) {
		T ('  固定引导码进程 PID=' + $p.ProcessId + ' 龄=' + $龄 + 's CPU=读不到 ← 保守当不杀（误杀活安装的代价远大于漏报一个孤儿）')
	} else {
		$cpu = [Math]::Round(([uint64]$u + [uint64]$kc) / 10000000, 1)
		$孤 = ($龄 -gt 180 -and $cpu -lt 1)
		if ($孤) { $疑似孤儿数++ }
		T ('  固定引导码进程 PID=' + $p.ProcessId + ' 龄=' + $龄 + 's CPU=' + $cpu + 's' + $(if ($孤) { ' ← 疑似卡死孤儿（超龄且几乎没耗 CPU）' } else { ' ← 在干活或没超龄，别杀' }))
	}
}
T ('固定引导码进程数=' + $引导进程.Count + ' 其中疑似卡死孤儿=' + $疑似孤儿数 + '（判据：带生产引导码特征 且 龄>180s 且 CPU<1s）')
T ('其它EncodedCommand进程数(非生产引导，多为探针/一次性脚本)=' + $其它编码.Count)
foreach ($p in $其它编码) { T ('  其它 PID=' + $p.ProcessId + ' 龄=' + [int]((Get-Date)-$p.CreationDate).TotalSeconds + 's') }
T ('Start-Job工作进程数=' + @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '-s -NoLogo' }).Count)
T ('sshd会话数=' + @(Get-CimInstance Win32_Process -Filter "Name='sshd.exe'" -ErrorAction SilentlyContinue).Count)
$k = 'HKLM:\SOFTWARE\OpenSSH'
if (Test-Path $k) { $pr = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue; T ('DefaultShell=' + [string]$pr.DefaultShell + '  CommandArgs=' + [string]$pr.DefaultShellCommandArgs) } else { T 'DefaultShell=(未注册，sshd 用内置默认)' }
T ('PSVersion=' + $PSVersionTable.PSVersion + '  输出已重定向=' + [Console]::IsOutputRedirected)
__提交号段__
Get-PSDrive -PSProvider FileSystem | ForEach-Object { T ('  盘' + $_.Name + ': 空闲GB=' + [Math]::Round($_.Free/1GB,2)) }
$试 = Join-Path $env:USERPROFILE '.vsi-probe-write-test.txt'
try { Set-Content -Path $试 -Value 'x' -ErrorAction Stop; Remove-Item $试 -Force -ErrorAction SilentlyContinue; T '家目录可写=是' } catch { T ('家目录可写=否 → ' + $_.Exception.Message) }
T 'END'
'@
	$树明细 = if ($含引导树明细) { "if (`$cl -match 'EncodedCommand' -and `$p.ProcessId -ne `$自) { T ('  引导 PID=' + `$p.ProcessId + ' PPID=' + `$p.ParentProcessId + ' 龄=' + `$龄 + 's cmd=' + (短 `$cl 150)) }" } else { '' }
	$片段 = $片段.Replace('__树明细__', $树明细)
	$片段 = $片段.Replace('__引导特征__', $引导码特征)

	if ($提交号 -ne '') {
		$段 = @'
$根 = Join-Path $env:USERPROFILE '.vscode-server-insiders'
$rc = Join-Path $根 ('race-' + '__提交号__')
T ('竞速目录存在=' + (Test-Path $rc))
if (Test-Path $rc) {
	$项 = @(Get-ChildItem -LiteralPath $rc -Force -ErrorAction SilentlyContinue)
	T ('  竞速项数=' + $项.Count)
	__竞速明细__
}
$sv = Join-Path $根 ('cli\servers\Insiders-' + '__提交号__' + '\server')
T ('服务端已装=' + (Test-Path $sv))
$cli = Get-ChildItem -LiteralPath $根 -Filter 'vscode-cli-*' -ErrorAction SilentlyContinue
T ('数据目录残留CLI包数=' + @($cli).Count)
foreach ($c in $cli) { T ('  残留 ' + $c.Name + ' ' + $c.Length + '字节 ' + $c.LastWriteTime.ToString('MM-dd HH:mm')) }
'@
		$竞速明细 = if ($含竞速文件明细) { "foreach (`$f in `$项) { T ('    ' + `$f.Name + '  ' + `$f.Length + ' 字节  ' + `$f.LastWriteTime.ToString('MM-dd HH:mm:ss')) }" } else { '' }
		$片段 = $片段.Replace('__提交号段__', ($段.Replace('__提交号__', $提交号).Replace('__竞速明细__', $竞速明细)))
	} else {
		$片段 = $片段.Replace('__提交号段__', "T '（未指定提交号，跳过竞速/服务端状态）'")
	}
	return $片段
}

# ==========================================================================================
#  五、stdin 通道客户端 —— 与生产 执行-SSH命令带标准输入 同一套序列
# ==========================================================================================
function 送-载荷经stdin {
	param(
		[Parameter(Mandatory = $true)][string]$主机,
		[Parameter(Mandatory = $true)][string]$命令文本,
		[Parameter(Mandatory = $true)][string]$标准输入文本,
		[int]$端口 = 22,
		[int]$超时秒 = 60,
		[scriptblock]$每行回调
	)
	# 生产同序列（缺一不可，每一处都对应一个实测过的挂死形态）：
	#   ProcessStartInfo 起 ssh（.cmd/.bat 包装则套 cmd /c）→ Redirect 三流 + CreateNoWindow + UTF8 输出编码
	#   → stderr 用 ReadToEndAsync **异步抽干**（只重定向不读，缓冲区约 4KB 写满就把远端堵死，表现与挂死无异）
	#   → 载荷按 ASCII 字节写出 → Flush → **显式 Close**（EOF 由我们决定，不赌管道收尾；旧管道式写法在 120KB 那档挂死约 66 分钟）
	#   → ReadLineAsync + Task.Wait(500) 轮询，逐行记到达时刻 → 看门狗到点 taskkill /T /F 杀整棵本地树。
	# 返回 @{退出码;超时;行;到达记录;stderr;耗时秒}。到达记录是「每行 + 距 ssh 启动的秒数」，
	# 判定「输出是否被缓冲到退出才 flush」只能靠它（本轮就是靠它证伪了缓冲假设）。
	$ssh命令 = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -eq $ssh命令) { throw '未找到 ssh 命令' }
	$参数串 = '-p ' + $端口 + ' ' + $主机 + ' "' + $命令文本 + '"'
	$psi = New-Object System.Diagnostics.ProcessStartInfo
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

	$计时 = [System.Diagnostics.Stopwatch]::StartNew()
	$进程 = [System.Diagnostics.Process]::Start($psi)
	$错误任务 = $进程.StandardError.ReadToEndAsync()
	$载荷字节 = [System.Text.Encoding]::ASCII.GetBytes($标准输入文本)
	$进程.StandardInput.BaseStream.Write($载荷字节, 0, $载荷字节.Length)
	$进程.StandardInput.Flush()
	$进程.StandardInput.Close()

	$行 = New-Object System.Collections.Generic.List[string]
	$到达 = New-Object System.Collections.Generic.List[pscustomobject]
	$已超时 = $false
	$截止 = [DateTime]::Now.AddSeconds($超时秒)
	$读任务 = $进程.StandardOutput.ReadLineAsync()
	while ($true) {
		if ($读任务.Wait(500)) {
			$当前行 = $读任务.Result
			if ($null -eq $当前行) { break }
			$行.Add($当前行)
			$到达.Add([pscustomobject]@{ 秒 = [Math]::Round($计时.Elapsed.TotalSeconds, 1); 行 = $当前行 })
			if ($每行回调) { & $每行回调 $当前行 }
			$读任务 = $进程.StandardOutput.ReadLineAsync()
			continue
		}
		if ($进程.HasExited) {
			while ($读任务.Wait(0)) {
				$当前行 = $读任务.Result
				if ($null -eq $当前行) { break }
				$行.Add($当前行); $到达.Add([pscustomobject]@{ 秒 = [Math]::Round($计时.Elapsed.TotalSeconds, 1); 行 = $当前行 })
				$读任务 = $进程.StandardOutput.ReadLineAsync()
			}
			break
		}
		if ([DateTime]::Now -gt $截止) { $已超时 = $true; break }
	}
	if (-not $进程.HasExited) {
		try { & taskkill /PID $进程.Id /T /F 2>&1 | Out-Null } catch { }
		try { $进程.WaitForExit(5000) | Out-Null } catch { }
	}
	$计时.Stop()
	$错误摘要 = ''
	try { if ($错误任务.IsCompleted) { $错误摘要 = (([string]$错误任务.Result -replace '\s+', ' ')) } } catch { }
	return [pscustomobject]@{
		退出码   = $(if ($进程.HasExited) { $进程.ExitCode } else { -1 })
		超时     = $已超时
		行       = $行
		到达记录 = $到达
		stderr   = $错误摘要
		耗时秒   = [Math]::Round($计时.Elapsed.TotalSeconds, 1)
		载荷字节 = $载荷字节.Length
	}
}
