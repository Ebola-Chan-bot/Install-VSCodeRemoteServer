# 接管 Remote-SSH 远程服务器安装的公共实现（随「接管远程服务器安装」扩展分发，请勿手工修改）。
#
# 调用方：扩展为每台勾选主机生成的薄 preconnect 脚本（与本文件同目录，只把主机名传进来），或「复制调用代码自行粘贴」方式下用户粘贴进其原 preconnect 脚本里的那一行（同样经薄脚本进来）。Remote-SSH调用 preconnect 脚本时不传任何参数、不注入环境变量、标准输入是 ignore，脚本能自知的只有自身路径，因此主机名必须由薄脚本传参带入；模块路径、发布通道等易变信息则读同目录的配置文件。Remote-SSH只对薄脚本做内容哈希授权，改本文件与配置文件都不会重新触发授权确认。
#
# 退出码约定：0 = 正常；非 0 = 失败，Remote-SSH 会中止本次连接。任何失败都如实报错退出，不静默回退到自带安装。
[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$远程主机
)

$配置文件名 = '接管安装配置.json'
$开关名 = '安装VSCode远程服务.接管远程服务器安装'
$配置文件 = Join-Path $PSScriptRoot $配置文件名
$失败 = $false

# ---- 输出：一律经「缓冲 + 周期批量刷出」，连早期错误也不例外 ----
# Remote-SSH 记录 preconnect 输出时把每个数据块按换行切分：块内多行用 \n 连接、块尾不带换行，切分后即连续行，不会多出空行；逐行带换行写则每行后被补一个空行；两块紧挨着到达又会被读端合并成一个块，块间没有分隔符就会把前块末行与后块首行并成一行，故批间隔取 1 秒。不用独立刷写线程：PowerShell 的定时器回调必须在所属 runspace 的线程上执行，主线程忙于管道时回调根本不会触发。
#
# 写出一律走标准输出的原始字节流，不用 Write-Host：实测 Write-Host 经宿主写出端按 256 字节缓冲切块，单次写出超过 256 字节必然被拆成多块，读端就会在行中间断开（如实测出现的“远程登录目录: /home_data/home/slst” + “/v-jiamh”），极端情况还会把一个 UTF-8 多字节字符切成两半变成乱码；而 OpenStandardOutput 的字节流一次 Write+Flush 实测能整批送达（600 B ~ 70 KB 均为完整一块、零乱码），于是每次刷出恰好对应读端一个数据块，行不会被腰斩。
$缓冲 = [System.Collections.Generic.List[string]]::new()
$上次刷出 = [DateTime]::MinValue
$标准输出流 = $null
try { $标准输出流 = [Console]::OpenStandardOutput() } catch { $标准输出流 = $null }

function 写出文本([string]$文本) {
	if ($文本 -eq '') { return }
	if ($null -ne $script:标准输出流) {
		try {
			$字节 = [Text.Encoding]::UTF8.GetBytes($文本)
			$script:标准输出流.Write($字节, 0, $字节.Length)
			$script:标准输出流.Flush()
			return
		} catch {
			# 流不可用时退回 Write-Host：宁可被 256 字节拆开，也不能丢内容
			$script:标准输出流 = $null
		}
	}
	Write-Host -NoNewline $文本
}

function 刷出缓冲([switch]$补足间隔) {
	$行 = @($script:缓冲 | Where-Object { $_ -ne '' })
	$script:缓冲.Clear()
	if ($行.Count -eq 0) { return }
	# 收尾或报错时距上次写出可能不足 1 秒，补足间隔以免与上一块被读端合并成一行
	if ($补足间隔 -and $script:上次刷出 -ne [DateTime]::MinValue) {
		$等待 = 1.0 - ([DateTime]::Now - $script:上次刷出).TotalSeconds
		if ($等待 -gt 0) { Start-Sleep -Seconds $等待 }
	}
	写出文本 ($行 -join [char]10)
	$script:上次刷出 = [DateTime]::Now
}

function 报错退出($消息) {
	$script:缓冲.Add('[接管安装] ' + $消息)
	刷出缓冲 -补足间隔
	exit 1
}

if (-not (Test-Path -LiteralPath $配置文件)) {
	报错退出 ('找不到配置文件 {0}，请在 VS Code 中关闭再重新开启「{1}」以重建接管文件。' -f $配置文件, $开关名)
}

try {
	$配置 = Get-Content -LiteralPath $配置文件 -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
	报错退出 ('配置文件 {0} 解析失败：{1}' -f $配置文件, $_.Exception.Message)
}

# 同理：配置里缺字段时取到的是 $null，而 $null -eq '' 为假，靠「等于空串」判断根本拦不住，一律用 IsNullOrWhiteSpace。
if ([string]::IsNullOrWhiteSpace([string]$配置.模块路径)) {
	报错退出 ('配置文件 {0} 缺少「模块路径」，请关闭再重新开启「{1}」。' -f $配置文件, $开关名)
}
if ([string]::IsNullOrWhiteSpace([string]$配置.本地版本)) {
	报错退出 ('配置文件 {0} 缺少「本地版本」，请关闭再重新开启「{1}」。' -f $配置文件, $开关名)
}
$模块路径 = [string]$配置.模块路径
$本地版本 = [string]$配置.本地版本
# 本主机启用的能力：接管安装与服务保活相互独立（可重叠），都来自配置文件里的主机清单
$启用接管 = @($配置.接管主机) -contains $远程主机
$启用保活 = @($配置.保活主机) -contains $远程主机
if (-not $启用接管 -and -not $启用保活) {
	# 自调方式的薄脚本可能仍被用户粘贴的调用行引用；主机被取消勾选后这里应安静无事（非失败）
	$script:缓冲.Add(('[接管安装] 主机 {0} 未启用接管或保活（可能刚被取消勾选），本次未处理。' -f $远程主机))
	刷出缓冲 -补足间隔
	exit 0
}

& {
	try {
		# 免密前提由模块在 -非交互 模式下校验（它的免密检测与环境试探本是同一次连接，不再重复探测）：
		# 需要密码时模块直接报错退出——本进程标准输入被 Remote-SSH 设为 ignore，交互收密码只会挂起，绝不回退自带安装。
		# 注意：本文件绝不执行任何“原 preconnect 脚本”——若主机接管前有外部脚本，扩展已在勾选时让用户二选一：覆盖丢弃，或由用户把一行调用代码粘进其原脚本（那时调用链是 用户脚本 → 薄脚本 → 本文件）。
		Import-Module -Name $模块路径 -Force -ErrorAction Stop -DisableNameChecking

		if ($启用接管) {
			# 接管+保活同跑时把保活检修并入同一次远程会话（-含服务保活），不再单独走一轮连接；平台提示随参传入，Windows 主机由模块直走 powershell 单会话流程
			安装-VSCode远程服务 -远程主机 $远程主机 -本地版本 $本地版本 -非交互 -含服务保活:$启用保活 -平台提示映射 $配置.平台提示映射 -ErrorAction Stop
		} elseif ($启用保活) {
			# 仅保活主机：不安装 Server，只做保活包装的幂等检修（已部署跳过、旧版升级、CLI 缺失自动下载真身再包装）。
			# 新提交号的 CLI 由 Remote-SSH 在本次连接安装，当次不受保护属预期，下一次连接由本步自动补上。
			安装-VSCode服务保活 -远程主机 $远程主机 -本地版本 $本地版本 -非交互 -ErrorAction Stop
		}
	} catch {
		# throw 会穿透 *>&1 落到 stderr，故在这里收敛成一行干净消息，随缓冲走 stdout
		$script:失败 = $true
		'[接管安装] ' + $_.Exception.Message
		# 位置信息必须一并带上：preconnect 的输出只有日志可查，缺了出错位置等于无从排障
		if ($_.InvocationInfo) {
			'[接管安装] 出错位置: {0}:{1}' -f (Split-Path -Leaf $_.InvocationInfo.ScriptName), $_.InvocationInfo.ScriptLineNumber
		}
		foreach ($帧 in @($_.ScriptStackTrace)) {
			if (-not [string]::IsNullOrWhiteSpace($帧)) { '[接管安装]   ' + $帧.Trim() }
		}
	}
} *>&1 | ForEach-Object {
	$script:缓冲.Add([string]$_)
	if ($_ -is [System.Management.Automation.ErrorRecord]) { $script:失败 = $true }
	if (([DateTime]::Now - $script:上次刷出).TotalSeconds -ge 1) {
		刷出缓冲
	}
}

刷出缓冲 -补足间隔
if ($null -ne $标准输出流) { try { $标准输出流.Flush() } catch { } }
if ($script:失败) { exit 1 }
exit 0
