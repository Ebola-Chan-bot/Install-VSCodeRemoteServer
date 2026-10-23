# 回归自检：Windows 单会话安装的传输通道（argv 上限 vs stdin）
#
# 守住的缺陷（2026-10-22 真机复现，用户表现为「Remote-SSH 连不上/连接超时，窗口永远重连不上」）：
#   执行-Windows单会话安装 把「安装脚本 gzip+base64 的载荷」嵌进引导模板、又整体按 UTF-16 base64 一次，
#   结果整段塞进 ssh 的 argv → 实测 37,950 字符 > Windows CreateProcess 上限 32,767
#   → 本地 ssh.exe 拒绝启动（Program 'ssh.exe' failed to run: The filename or extension is too long，psm1:621）
#   → preconnect 退出码 1 → Remote-SSH 判 PreconnectScriptFailure → 整条连接夭折。
#   连带后果（同轮取证）：解析被拒 → 窗口信任服务拿不到 _remoteAuthority → 工作区永不受信任且 canSetWorkspaceTrust=false
#   → 终端启动的信任门永久悬挂（连 Remote-SSH 自己的隐藏连接终端都起不来）→ 窗口陷入死锁，reload 无效。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\windows-stdin-transport-selfcheck.ps1            # 静态+算术（不联网）
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\windows-stdin-transport-selfcheck.ps1 -跑真机    # 追加 E：真机传输无损性探测（短连接，不影响在用连接）
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\windows-stdin-transport-selfcheck.ps1 -跑全链路 # 追加 F：真跑生产 preconnect 安装链路
#   可选：-主机 上科大A服务器_张天夫   （默认即此，Windows 远端）
#
# 为什么 F 段必须单独开关、不能跟着 -跑真机 一起跑（2026-10-23 实测教训）：
#   F 段跑的是生产薄脚本，与用户自己的 Remote-SSH 连接完全同一条路：同一台主机的同一个竞速暂存目录、同一份带宽。
#   我曾把自检挂到后台跑，它的供给进程与用户正在跑的供给进程同时抢 190MB 下载，日志里冒出两个「另一供给进程」、
#   两边在同一续传点上互抢文件句柄 —— 自检自己成了它要排查的故障源。所以：F 段只在显式 -跑全链路 时跑，
#   且跑之前先查本机有无在用的 preconnect/供给进程，有就直接拒绝（可用 -忽略在用连接 强制覆盖）。

param(
	[string]$主机 = '上科大A服务器_张天夫',
	[int]$端口 = 22,
	[switch]$跑真机,
	[switch]$跑全链路,
	[switch]$忽略在用连接
)

$ErrorActionPreference = 'Stop'
$仓库根 = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$模块目录 = Join-Path $仓库根 '接管远程服务器安装扩展\module'
$私有目录 = Join-Path $模块目录 'private'
$psm1路径 = Join-Path $模块目录 'Install-VSCodeRemoteServer.psd1'
$psm1正文 = Get-Content (Join-Path $模块目录 'Install-VSCodeRemoteServer.psm1') -Raw -Encoding UTF8
$引导模板 = Get-Content (Join-Path $私有目录 'Windows单会话引导.ps1') -Raw -Encoding UTF8
$stdin模板 = Get-Content (Join-Path $私有目录 'windows-stdin-bootstrap.ps1') -Raw -Encoding UTF8

. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 '  [通过] ' -失败前缀 '  [失败] ' -细节分隔 '  — '

# 断言台账（通过/失败计数 + 失败清单）全部交给公共库；这里只留薄转发保持原调用签名
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

Write-Host '===== A. 静态守卫：载荷必须走 stdin，argv 只装固定引导 ====='
断言 'stdin 引导模板存在' ($stdin模板.Length -gt 200) ((Join-Path $私有目录 'windows-stdin-bootstrap.ps1') + ' 共 ' + [string]$stdin模板.Length + ' 字符')
断言 'stdin 引导用有界异步读（绝不无期限挂起）' (($stdin模板 -match '\[Console\]::In\.ReadToEndAsync\(\)') -and ($stdin模板 -match '\.Wait\(')) '无期限 ReadToEnd 会让远端在本地被 taskkill 后永远卡在读取里成孤儿、堆满 sshd 会话拖垮后续连接（2026-10-23 上科大B服务器死亡螺旋）'
断言 'stdin 引导再无裸的无期限 ReadToEnd' (-not ($stdin模板 -match '\[Console\]::In\.ReadToEnd\(\)')) '旧写法正是孤儿堆积的根源'
断言 'stdin 引导等不到 EOF 会自行退出' (($stdin模板 -match '远端主动退出') -and ($stdin模板 -match 'exit 1')) '有界超时后必须自杀，绝不留孤儿会话放大饱和'
断言 'stdin 引导执行安装脚本前先回到达回执' ($stdin模板 -match '载荷已到达') '回执让本地看门狗尽早拿到首字节，把「慢启动」与「真挂死」区分开（安装脚本首个输出要等僵尸清理跑完才打）'
$回执位 = $stdin模板.IndexOf('载荷已到达')
$执行位 = $stdin模板.IndexOf('[scriptblock]::Create')
断言 '回执早于执行安装脚本' (($回执位 -ge 0) -and ($执行位 -gt $回执位)) '回执必须早于任何耗时步骤才有意义'
断言 'stdin 引导去空白后再解码' ($stdin模板.Contains([char]39 + '\s' + [char]39) -and $stdin模板 -match [regex]::Escape('-replace')) '分块换行/回车必须被清洗掉才能 base64 解码（-match 会把正则 \s 当空白类，故用 Contains 比字面量）'
断言 'stdin 引导对空输入显式失败' ($stdin模板 -match 'exit 1' -and $stdin模板 -match '标准输入为空') '载荷没送达要给出直白报错，不能静默成功'
断言 'stdin 引导不含载荷占位符' (-not ($stdin模板 -match '__载荷__')) '它必须与载荷大小无关（否则 argv 又会膨胀）'

断言 '执行-SSH命令 有标准输入参数' ($psm1正文 -match '\[string\]\$标准输入') ''
断言 '执行-SSH命令 会把标准输入喂给 ssh' ($psm1正文 -match '\$标准输入 \| & \$ssh命令\.Source') '管道结束时 PowerShell 关闭 ssh 标准输入，EOF 确定送达'
断言 '单会话安装改用 stdin 传载荷' ($psm1正文.Contains('-标准输入文本 $载荷标准输入')) '硬化函数的参数名是 -标准输入文本（载荷走它，argv 只装固定引导）'
断言 '单会话 argv 只装固定引导' ($psm1正文.Contains("-EncodedCommand {0}' -f `$固定引导码")) ''
断言 '旧写法已根除：整段引导码不得再进 argv' (-not $psm1正文.Contains("-EncodedCommand {0}' -f `$引导码)")) '这一行正是撞 32767 上限的元凶'
断言 '有固定引导长度守卫' ($psm1正文.Contains('$固定引导码.Length -gt 8000')) 'argv 里唯一随模板增长的部分必须有上限守卫'
断言 '有分块重组一致性断言' ($psm1正文.Contains('$载荷标准输入.Length -ne')) '分块出错要在本端就拦下，别等远端解码失败'
断言 '注释已记录通道变更与实测依据' (($psm1正文 -match '32,767') -and ($psm1正文 -match 'DefaultShell')) '把"为什么不再禁 stdin"的实测结论留在代码里'
断言 '模板头部旧结论已更新' (-not ($引导模板 -match '不走 stdin')) 'Windows单会话引导.ps1 的头部注释不得继续留已被推翻的结论'
# --- 硬化通道：实测管道式 stdin 会在 120KB 那一档偶发挂死约 66 分钟，故改为自起进程 + 显式 EOF + 看门狗 ---
断言 '有专用的标准输入执行函数' ($psm1正文.Contains('function 执行-SSH命令带标准输入')) '单会话载荷不得再靠 PowerShell 管道喂 ssh'
断言 '生产路径调用硬化函数' ($psm1正文.Contains('执行-SSH命令带标准输入 -连接目标 $连接目标')) ''
断言 '载荷写完后显式关闭标准输入（EOF 确定）' ($psm1正文.Contains('$进程.StandardInput.Close()')) '依赖管道收尾就是当年挂死的根源'
断言 'stderr 已异步抽干' ($psm1正文.Contains('StandardError.ReadToEndAsync()')) '只重定向不读，缓冲区写满会把远端堵住→同样表现为挂死'
断言 '有硬超时看门狗并杀进程树' (($psm1正文.Contains('taskkill /PID $进程.Id /T /F')) -and ($psm1正文.Contains('[stdin超时]'))) '挂死必须变成可诊断的快速失败，不能无声干等'
断言 '看门狗超时会顺延（有输出就算进展）' ($psm1正文.Contains('$截止 = (Get-Date).AddSeconds($超时秒)')) '长安装流程不能被固定超时误杀'
断言 '只有有效行才顺延看门狗（空行/CLIXML 不算进展）' ($psm1正文.Contains("if (`$行.Trim() -ne '' -and `$行 -notmatch '^(#< CLIXML|<Objs|</Objs>)')")) '缺陷复现：旧写法下空行流会一路顺延，实测 448 秒 > 240 秒看门狗也没触发'
# 行处理器的参数绑定：本循环是 `& $处理行 $行` 直接调用，写成 [string]$_ 则只在管道调用（ForEach-Object）下有值，
# 实测那样取值恒为空串 → 远端竞速标记进不了回调 → 本地供给永不启动，而自检旧版只看退出码，漏掉了它
断言 '行处理器用 param 显式接收实参（不靠 $_）' ($psm1正文.Contains('param([string]$文本行)')) '写成 $_ 只在管道调用下有值，& 调用时恒为空'
# 断言必须限定在硬化函数体内：旧的管道式 执行-SSH命令 用 `ForEach-Object $处理行` 调用，那里用 $_ 是正确的
$硬化起 = $psm1正文.IndexOf('function 执行-SSH命令带标准输入')
$硬化止 = $psm1正文.IndexOf('function 上传-文件到远程')
$硬化体 = if ($硬化起 -ge 0 -and $硬化止 -gt $硬化起) { $psm1正文.Substring($硬化起, $硬化止 - $硬化起) } else { '' }
断言 '硬化函数体已定位（断言范围限定用它）' ($硬化体.Length -gt 500) ('函数体 ' + $硬化体.Length + ' 字符')
断言 '硬化函数里不得用 $_ 取行内容' ((-not ($硬化体 -match '剥离-终端控制序列 \(\[string\]\$_\)')) -and (-not ($硬化体.Contains('$文本 = 剥离-终端控制序列 ([string]$_)')))) '旧写法是本缺陷的直接根因（每行都变空串）'
断言 '硬化函数把行实参传给行处理器' ($硬化体.Contains('& $处理行 $行')) ''
断言 '注释留下行处理器取值的实测教训' ($psm1正文.Contains('本地供给永不启动')) '否则下一个人会把它改回 $_'
断言 '挂死会重试一次' (($psm1正文.Contains('$尝试上限 = 2')) -and ($psm1正文.Contains("-notmatch '^\[stdin超时\]'"))) '只对通道挂死重试，其它错误原样抛出保留真实原因'
断言 '注释留下 120KB 挂死的实测依据' ((($psm1正文 -match '120KB') -or ($psm1正文 -match '120 KB')) -and ($psm1正文 -match '66 分钟')) '否则下一个人又会把它改回管道式'

Write-Host ''
Write-Host '===== B. 模块可解析/可导入（全新进程，避免当前会话污染） ====='
$导入脚本 = Join-Path $env:TEMP 'vsi-import-check.ps1'
@(
	'$ErrorActionPreference = ''Stop'''
	('Import-Module ''' + $psm1路径 + ''' -Force')
	'Write-Output (''命令数='' + (Get-Command -Module Install-VSCodeRemoteServer).Count)'
	'if ($null -eq (Get-Command -Module Install-VSCodeRemoteServer -Name ''安装-VSCode远程服务'' -ErrorAction SilentlyContinue)) { Write-Output ''缺命令:安装-VSCode远程服务'' } else { Write-Output ''关键命令在位'' }'
) -join "`r`n" | Set-Content -Path $导入脚本 -Encoding UTF8
$导入输出 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $导入脚本 2>&1)
$导入退出码 = $LASTEXITCODE
$导入文本 = ($导入输出 -join ' | ')
断言 '模块在全新进程可导入' ($导入退出码 -eq 0) ('退出码 ' + $导入退出码 + '；' + $导入文本.Substring(0, [Math]::Min(160, $导入文本.Length)))
断言 '导入后关键命令在位' ($导入文本 -match '关键命令在位') $导入文本

Write-Host ''
Write-Host '===== C. 算术复算：新旧 argv 体积对比（用生产同一套模板与算法） ====='
function 算-载荷体积 {
	param([string]$安装脚本文本)
	$精简正文 = (($安装脚本文本 -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join "`n"
	$压缩流 = New-Object System.IO.MemoryStream
	$压缩器 = New-Object System.IO.Compression.GZipStream($压缩流, [System.IO.Compression.CompressionMode]::Compress)
	$正文字节 = [System.Text.Encoding]::UTF8.GetBytes($精简正文)
	$压缩器.Write($正文字节, 0, $正文字节.Length)
	$压缩器.Close()
	$载荷 = [Convert]::ToBase64String($压缩流.ToArray())
	$引导脚本 = $引导模板.Replace('__载荷__', $载荷)
	$引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($引导脚本))
	return [pscustomobject]@{ 精简正文 = $精简正文.Length; gzip字节 = $压缩流.ToArray().Length; 载荷 = $载荷.Length; 引导码 = $引导码.Length }
}
# 生产路径把 remote-install-common.ps1（+win7 等）拼成安装脚本正文，这里取通用与 win7 合并作为上界近似
$通用正文 = Get-Content (Join-Path $私有目录 'remote-install-common.ps1') -Raw -Encoding UTF8
$win7正文 = Get-Content (Join-Path $私有目录 'remote-install-win7.ps1') -Raw -Encoding UTF8
$体 = 算-载荷体积 -安装脚本文本 ($通用正文 + "`n" + $win7正文)
$固定引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($stdin模板))
# 注意：$体.引导码 是「字符数」（int），$固定引导码 才是真正的字符串 —— 两者不能混用字符串相加，
# 否则 int 会被转成它的十进制字面量（实测踩过：旧 argv 被算成 43 字符，缺陷复现断言恒失败）。
$argv前缀 = 'powershell -NoProfile -EncodedCommand '
$旧argv = $argv前缀.Length + $体.引导码
$新argv = $argv前缀.Length + $固定引导码.Length
Write-Host ('  精简正文 ' + $体.精简正文 + ' 字符 → gzip ' + $体.gzip字节 + ' 字节 → 载荷 base64 ' + $体.载荷 + ' → 引导码 ' + $体.引导码 + ' 字符')
Write-Host ('  旧 argv = ' + $旧argv + ' 字符（上限 32767）；新 argv = ' + $新argv + ' 字符（与载荷无关）')
断言 '固定引导足够小（守住 8000 守卫线）' ($固定引导码.Length -lt 8000) ('EncodedCommand ' + $固定引导码.Length + ' 字符')
断言 '新 argv 远离 CreateProcess 上限' ($新argv -lt 8192) ('新 argv ' + $新argv + ' 字符 vs 上限 32767')
断言 '载荷确实已不再决定 argv' ($体.引导码 -gt ($新argv * 4)) ('引导码 ' + $体.引导码 + ' 字符 ≫ 新 argv ' + $新argv + ' 字符（解耦有效）')
断言 '旧写法在当前模板下确实会炸（缺陷可复现，守卫有意义）' ($旧argv -gt 32767) ('旧 argv ' + $旧argv + ' > 32767 → ssh.exe 会拒绝启动')

Write-Host ''
Write-Host '===== D. 分块可逆（与 psm1 同一分块规则） ====='
$每块字符 = 4000
$原文 = 'A' * 123456 + ([char]0x4E2D) + 'z' * 50000   # 混入非 ASCII，确认我们传的是 base64（纯 ASCII）而非脚本正文
$块列表 = New-Object System.Collections.ArrayList
for ($起 = 0; $起 -lt $原文.Length; $起 += $每块字符) { [void]$块列表.Add($原文.Substring($起, [Math]::Min($每块字符, $原文.Length - $起))) }
$重组 = ($块列表 -join "`n") + "`n"
$还原 = ($重组 -replace '\s', '')
断言 '分块去空白后可无损还原' ($还原 -eq $原文) ('块数 ' + $块列表.Count + '，还原 ' + $还原.Length + '/' + $原文.Length + ' 字符')
断言 '重组文本不含回车（CR 会混进远端命令）' (-not ($重组 -match "`r")) 'PS 管道喂原生程序会把行尾换成 CRLF，故载荷必须是不含 CR 也能还原的 base64 分块'

if (-not $跑真机) {
	Write-Host ''
	Write-Host '===== E. 真机端到端：已跳过（加 -跑真机 才会连远端） ====='
} else {
	Write-Host ''
	Write-Host ('===== E. 真机端到端（' + $主机 + '）：走与生产完全相同的通道 =====')
	$ssh = Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -eq $ssh) {
		断言 'ssh 客户端可用' $false '未找到 ssh.exe，无法做真机验证'
	} else {		# PS 5.1 下原生命令的 stderr（ssh 的 ignoring bad CNAME 等无害噪声）在 $ErrorActionPreference='Stop'
		# 且被重定向时会升为终止性错误，会把整个自检打挂 → 真机调用期间临时切 Continue，finally 里恢复
		$原EAP = $ErrorActionPreference
		$ErrorActionPreference = 'Continue'		# E1：退出码是否穿过引导层的 [scriptblock]::Create + & 透传（生产靠它区分成功/失败/PS2 回退）
		$内层1 = 'Write-Output ''__VSI_SELFCHECK__ E1=OK''; exit 7'
		$内层码1 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($内层1))
		$输出1 = $null; $码1 = 0
		try {
			$输出1 = @($内层码1 | & $ssh.Source -p $端口 $主机 ('powershell -NoProfile -EncodedCommand {0}' -f $固定引导码) 2>&1)
			$码1 = $LASTEXITCODE
		} finally { $ErrorActionPreference = $原EAP }
		$文本1 = ($输出1 -join ' | ')
		断言 'E1 内层标记回显到达' ($文本1 -match '__VSI_SELFCHECK__ E1=OK') $文本1.Substring(0, [Math]::Min(140, $文本1.Length))
		# Windows sshd（DefaultShell=powershell.exe）会把远端非零退出码**压平成 1**（实测：内层 exit 7 → ssh 退出码 1），
		# 所以细分数值不可依赖，只判"非零"；真正的结果码一律走 stdout 标记（模块既有纪律：__VSI_RC__ / __VSI_ERR__）。
		# 反之，成功必须还能判：内层 exit 0 → ssh 退出码 0，由 E2 的断言守住（执行-SSH命令 的 throw 依据就是它）。
		断言 'E1 内层非零退出会让 ssh 非零退出（压平为 1，细分数值走 __VSI_RC__ 标记）' ($码1 -ne 0) ('ssh 退出码 ' + $码1 + '；内层 exit 7 已被远端 sshd 压平')

		# E2：按生产实际体积把引导码原样送一遍（argv 里的内层脚本只负责读全量 stdin 并报长度+SHA256），
		#     本地比对：长度与哈希一致才算通道无损（引导层的解码/退出码由 E1 覆盖）。
		$生产引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($引导模板.Replace('__载荷__', ('A' * $体.载荷))))
		$本地长度 = $生产引导码.Length
		$本地哈希 = (([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($生产引导码))) | ForEach-Object { $_.ToString('x2') }) -join ''
		$内层2 = '$raw=[Console]::In.ReadToEnd(); $c=($raw -replace ''\s'',''''); $h=[System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($c)); Write-Output (''__VSI_SELFCHECK__ LEN='' + $c.Length); Write-Output (''__VSI_SELFCHECK__ SHA='' + (($h | ForEach-Object { $_.ToString(''x2'') }) -join '''')); exit 0'
		$块列表2 = New-Object System.Collections.ArrayList
		for ($起 = 0; $起 -lt $生产引导码.Length; $起 += $每块字符) { [void]$块列表2.Add($生产引导码.Substring($起, [Math]::Min($每块字符, $生产引导码.Length - $起))) }
		$标准输入2 = (($块列表2 -join "`n") + "`n")
		$内层2码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($内层2))
		$输出2 = $null; $码2 = 0
		try {
			$ErrorActionPreference = 'Continue'
			$输出2 = @($标准输入2 | & $ssh.Source -p $端口 $主机 ('powershell -NoProfile -EncodedCommand {0}' -f $内层2码) 2>&1)
			$码2 = $LASTEXITCODE
		} finally { $ErrorActionPreference = $原EAP }
		$文本2 = ($输出2 -join ' | ')
		$远长度 = [regex]::Match($文本2, '__VSI_SELFCHECK__ LEN=(\d+)').Groups[1].Value
		$远哈希 = [regex]::Match($文本2, '__VSI_SELFCHECK__ SHA=([0-9a-f]{64})').Groups[1].Value
		Write-Host ('  生产体积载荷 ' + $本地长度 + ' 字符 → 远端解得 ' + $远长度 + ' 字符；退出码 ' + $码2)
		断言 'E2 生产体积载荷长度一致' ($远长度 -eq [string]$本地长度) ('本地 ' + $本地长度 + ' vs 远端 ' + $远长度)
		断言 'E2 生产体积载荷 SHA256 一致' ($远哈希 -eq $本地哈希) ('远端 ' + $远哈希.Substring(0, 16) + '… vs 本地 ' + $本地哈希.Substring(0, 16) + '…')
		断言 'E2 远端退出码为 0' ($码2 -eq 0) ('退出码 ' + $码2)
	}
}

Write-Host ''
Write-Host ('===== F. 真机跑完整生产链路（preconnect 实现脚本） =====')
if (-not $跑全链路) {
	Write-Host '  已跳过：这段会真跑生产安装，与用户在用的连接抢同一份带宽与同一个竞速暂存目录。'
	Write-Host '  要跑就加 -跑全链路（-跑真机 只负责 E 段的无损性探测，不会抢连接）。'
} else {
	# 抢连接守卫：本机已有在用的 preconnect/供给进程时拒绝再开一路（自检绝不允许成为故障源）
	$自身PID = $PID
	$在用进程 = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
		Where-Object { $_.ProcessId -ne $自身PID -and $null -ne $_.CommandLine -and
			($_.CommandLine -match '预连接-持久化VSCode|local-supply\.ps1|接管安装-|Install-VSCodeRemoteServer') })
	if (($在用进程.Count -gt 0) -and (-not $忽略在用连接)) {
		$在用进程 | Select-Object -First 5 | ForEach-Object {
			$cmd = [string]$_.CommandLine; if ($cmd.Length -gt 140) { $cmd = $cmd.Substring(0, 140) + '…' }
			Write-Host ('  在用进程 PID ' + $_.ProcessId + ': ' + $cmd)
		}
		# 消息与详情都得加括号：裸拼接会让 + / 变量 / 尾串变成多余实参，这条「已拒绝运行」的告警
		# 自己先抛 PositionalParameterNotFound，用户看到的就不是结论而是一堆绑定错误（静态闸门抓出）
		断言 ('F 未与在用连接抢资源（检测到 ' + $在用进程.Count + ' 个在用的 preconnect/供给进程，已拒绝运行）') $false ('确认没有在用连接后重跑，或加 -忽略在用连接 强制覆盖')
	} else {
	# 为什么不能直接调 执行-SSH命令带标准输入：它是嵌套函数（定义在 安装-VSCode远程服务 内部，与 执行-SSH命令 同层），
	# 只在那个函数运行期间存在，模块作用域里拿不到（实测报 not recognized）。
	# 为什么跑已安装副本而不是仓库副本：仓库里的 接管安装实现.ps1 需要同目录的 接管安装配置.json（由扩展在 globalStorage 生成），
	#   仓库副本没有 → 必然报"找不到配置文件"。真实生产入口就是 globalStorage 里那份，它 import 的是**已安装扩展目录**里的模块，
	#   所以 F 段先做"已安装 == 仓库"哈希核对，防止拿旧安装冒充新代码通过。
	$扩展目录 = Get-ChildItem (Join-Path $env:USERPROFILE '.vscode-insiders\extensions') -Directory -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -like 'ebola-chan-bot.remotessh-server-installer-*' } | Sort-Object Name -Descending | Select-Object -First 1
	$接管目录 = Join-Path $env:APPDATA 'Code - Insiders\User\globalStorage\ebola-chan-bot.remotessh-server-installer'
	$薄脚本 = Join-Path $接管目录 ('接管安装-' + $主机 + '.ps1')
	if ($null -eq $扩展目录 -or -not (Test-Path $薄脚本)) {
		断言 'F 生产入口存在' $false ('未找到已安装扩展或薄脚本：扩展目录=' + [string]$扩展目录 + '，薄脚本=' + $薄脚本)
	} else {
		# 先核对已安装模块与仓库一致（psm1 + 两个 Windows 引导模板）
		$需核对 = @('module\Install-VSCodeRemoteServer.psm1', 'module\private\windows-stdin-bootstrap.ps1', 'module\private\Windows单会话引导.ps1')
		$哈希不符 = @()
		foreach ($相 in $需核对) {
			$仓 = Join-Path (Join-Path $仓库根 '接管远程服务器安装扩展') $相
			$装 = Join-Path $扩展目录.FullName $相
			$仓哈希 = if (Test-Path $仓) { (Get-FileHash $仓 -Algorithm SHA256).Hash } else { '仓库缺文件' }
			$装哈希 = if (Test-Path $装) { (Get-FileHash $装 -Algorithm SHA256).Hash } else { '未安装该文件' }
			if ($仓哈希 -ne $装哈希) { $哈希不符 += ($相 + '（仓库 ' + $仓哈希.Substring(0, [Math]::Min(12, $仓哈希.Length)) + ' ≠ 已装 ' + $装哈希.Substring(0, [Math]::Min(12, $装哈希.Length)) + '）') }
		}
		断言 '已安装模块与仓库一致（否则 F 测的是旧代码）' ($哈希不符.Count -eq 0) (($哈希不符 -join '；') + $(if ($哈希不符.Count -gt 0) { '  → 请先重新打包并 code-insiders --install-extension <vsix> --force' } else { '（扩展目录 ' + $扩展目录.Name + '）' }))

		$F日 = Join-Path $env:TEMP 'vsi-selfcheck-preconnect.log'
		$原EAP2 = $ErrorActionPreference
		$F码 = -1
		$计时F = [System.Diagnostics.Stopwatch]::StartNew()
		try {
			$ErrorActionPreference = 'Continue'
			# 走 Remote-SSH 的完全同一条路：薄脚本 → 公共实现 → 模块（薄脚本自带 -远程主机 传参）
			$F输出 = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $薄脚本 2>&1)
			$F码 = $LASTEXITCODE
		} finally { $ErrorActionPreference = $原EAP2; $计时F.Stop() }
		$F文本 = ($F输出 | ForEach-Object { [string]$_ }) -join "`n"
		$F文本 | Set-Content -Path $F日 -Encoding UTF8
		$F行 = ($F输出 | Where-Object { $_ -match '\[单会话\]|too long|远程系统类型|已完整安装|零下载|接管安装' } | Select-Object -First 5)
		Write-Host ('  薄脚本=' + $薄脚本)
		Write-Host ('  退出码=' + $F码 + '  耗时=' + [Math]::Round($计时F.Elapsed.TotalSeconds, 1) + ' 秒  输出行数=' + $F输出.Count + '  全量日志: ' + $F日)
		$F行 | ForEach-Object { $t = [string]$_; if ($t.Length -gt 200) { $t = $t.Substring(0, 200) + '…' }; Write-Host ('    ' + $t) }
		断言 'F preconnect 退出码 0（旧缺陷下恒为 1，Remote-SSH 会判 PreconnectScriptFailure）' ($F码 -eq 0) ('退出码 ' + $F码)
		断言 'F 走了新的 stdin 通道（日志里有分块下发那行）' ($F文本 -match '\[单会话\] 引导码 \d+ 字符，分 \d+ 块走标准输入下发') ''
		断言 'F 分块措辞说清了「非传输必需」（不许再把稳健选择说成硬限制）' ($F文本 -match '分块为稳健选择而非传输必需') ''
		断言 'F argv 仍远小于上限' ($F文本 -match 'argv 上只剩 \d+ 字符的固定引导代码') ''
		断言 'F 不再出现 argv 超长错误' (-not ($F文本 -match 'filename or extension is too long')) '旧缺陷的原话不得再出现'
		# 功能性断言（能抓住“行处理器拿到空串”这类缺陷）：必须看到**远端产生的**行
		# 远端行与本地行的区别：本地行在 ssh 启动前就打完，远端行包含探测/安装/竞速措辞
		$远端行特征 = '准备安装 VS Code 远程服务|发布通道|自动检测到的系统架构|已完整安装|零下载|竞速|远程下载进度|本地下载进度|CLI 已存在'
		$远端行数 = @($F输出 | Where-Object { [string]$_ -match $远端行特征 }).Count
		断言 'F 看到远端产生的行（行处理器真的拿到内容）' ($远端行数 -gt 0) ('命中 ' + $远端行数 + ' 行；为 0 则说明远端行被处理成了空串')
		断言 'F 非空输出占比健康（空行泛滥是上述缺陷的典型症状）' ((@($F输出 | Where-Object { ([string]$_).Trim() -ne '' }).Count) -ge (@($F输出 | Where-Object { ([string]$_).Trim() -eq '' }).Count)) ('非空 ' + @($F输出 | Where-Object { ([string]$_).Trim() -ne '' }).Count + ' / 空 ' + @($F输出 | Where-Object { ([string]$_).Trim() -eq '' }).Count)
	}
	}
}

Write-Host ''
if (写-断言汇总 -标题 '汇总') { Write-Host '全部通过。'; exit 0 }
Write-Host '存在失败：详见上方 [失败] 行与本汇总的失败明细。'
exit 1
