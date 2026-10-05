# 本地竞速供给子进程脚本
# 由 启动-本地竞速供给 通过 Start-Process 作为独立 powershell 进程运行，与主模块进程隔离；远程侧获胜的瞬间，主流程用 taskkill /T /F 直接击杀本进程及其派生的 ssh/scp，下载或上传无论进行到哪一步都被立即终止（真正的事件驱动即时取消，零轮询）。参数经 Clixml 文件传入，避开命令行转义与 PS 5.1 原生命令 stderr 终止性错误陷阱。
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

	function 取-取消标记命令 {
		if ($系统类型 -eq 'Linux') {
			return ('test -f {0}/LOCAL_CANCEL' -f $暂存目录)
		}
		return (转换-远程PowerShell命令 ('if (Test-Path -LiteralPath ''{0}\LOCAL_CANCEL'') {{ exit 0 }} else {{ exit 1 }}' -f $暂存目录))
	}

	# 下载前的低成本取消检查（远程已获胜则不必下载）
	if ((调用-远程命令 (取-取消标记命令)).退出码 -eq 0) { Write-Output '远程侧已获胜，本地供给取消（下载前）。'; return }

	# 预建远程暂存目录：本地供给可能先于远程脚本跑到上传步骤，目录不存在会导致 scp 失败
	$建目录命令 = if ($系统类型 -eq 'Linux') {
		('mkdir -p {0}' -f $暂存目录)
	} else {
		(转换-远程PowerShell命令 ('New-Item -ItemType Directory -Force -Path ''{0}'' | Out-Null' -f $暂存目录))
	}
	$null = 调用-远程命令 $建目录命令

	# 分块 HTTP 断点续传下载（失败无限重试且等待秒数递增）。进程会在远程获胜时被整体击杀，故下载循环无需任何取消检查；
	# 半成品保留在本地 TEMP 供下次运行续传，文件名带提交号：防旧版本残包被 416 误判为完整或被错误续传。
	$本地包路径 = Join-Path $env:TEMP ('race-supply-{0}-{1}' -f $提交号, $远程包名)
	$重试次数 = 0
	while ($true) {
		$重试次数++
		$已存在字节数 = 0
		if (Test-Path -LiteralPath $本地包路径) { $已存在字节数 = (Get-Item -LiteralPath $本地包路径).Length }
		$响应 = $null
		$响应流 = $null
		$文件流 = $null
		try {
			$请求 = [System.Net.HttpWebRequest]::Create($下载地址)
			$请求.Timeout = 60000
			$请求.ReadWriteTimeout = 60000
			if ($已存在字节数 -gt 0) { $请求.AddRange($已存在字节数) }
			$响应 = $请求.GetResponse()
			$状态码 = [int]$响应.StatusCode
			if ($状态码 -eq 206) {
				$文件流 = [System.IO.File]::Open($本地包路径, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
			} else {
				$文件流 = [System.IO.File]::Open($本地包路径, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
				$已存在字节数 = 0
			}
			$响应流 = $响应.GetResponseStream()
			$缓冲区 = New-Object byte[] 65536
			$已下载 = $已存在字节数
			while (($读取数 = $响应流.Read($缓冲区, 0, $缓冲区.Length)) -gt 0) {
				$文件流.Write($缓冲区, 0, $读取数)
				$已下载 += $读取数
			}
			$文件流.Flush()
			Write-Output ('本地下载完成：共 {0} 字节。' -f $已下载)
			break
		} catch {
			# 416 = 请求区间无效：断点续传起点已不小于服务器完整大小，说明本地文件早已下载完整（如实测 231MB 包上次运行被击杀后残留），视为成功退出重试循环。
			# PS 5.1 中 GetResponse 抛出的 $_.Exception 常是 MethodInvocationException 包装（实测取不到状态码），真正的 WebException 在 InnerException 里，须遍历异常链
			$HTTP状态码 = 0
			$异常 = $_.Exception
			while ($null -ne $异常 -and $HTTP状态码 -eq 0) {
				try { $HTTP状态码 = [int]$异常.Response.StatusCode } catch { }
				$异常 = $异常.InnerException
			}
			if ($HTTP状态码 -eq 416 -and $已存在字节数 -gt 0) {
				Write-Output ('服务器返回 416：本地文件 {0} 字节已完整，无需续传。' -f $已存在字节数)
				break
			}
			$等待秒数 = [Math]::Min(30, $重试次数 * 2)
			Write-Output ('下载中断（{0}），{1} 秒后重试（第 {2} 次，已续传 {3} 字节）...' -f $_.Exception.Message, $等待秒数, $重试次数, $已存在字节数)
			Start-Sleep -Seconds $等待秒数
		} finally {
			if ($null -ne $文件流) { $文件流.Dispose() }
			if ($null -ne $响应流) { $响应流.Dispose() }
			if ($null -ne $响应) { $响应.Close() }
		}
	}

	# 上传前的取消复检：防止远程恰在下载完成到上传之间获胜，仍做一次低成本检查
	if ((调用-远程命令 (取-取消标记命令)).退出码 -eq 0) { Write-Output '远程侧已获胜，本地供给取消（上传前）。'; return }

	$scp命令 = Get-Command scp -ErrorAction SilentlyContinue | Select-Object -First 1
	Write-Output '开始上传本地压缩包到暂存目录...'
	$上传目标 = ('{0}:{1}{2}{3}.uploading' -f $连接目标, $暂存目录, $分隔符, $远程包名)
	$null = & $scp命令.Source (@('-P', $端口) + $密码选项 + @($本地包路径, $上传目标)) 2>&1
	if ($LASTEXITCODE -ne 0) { Write-Output ('上传失败，退出码 {0}，本地供给退出（远程将继续自下载）。' -f $LASTEXITCODE); return }

	# 原子改名 + 写完成标记（带远端取消检查，避免远程已获胜后仍写标记）。退出码约定：0=包已就位，2=远程已获胜跳过改名，其他=失败
	# Linux 版包 sh -c 是防登录 shell 不是 sh（tcsh/fish 会把 if...then...fi 判成语法错误）；Windows 版经 转换-远程PowerShell命令 走 EncodedCommand，避开双引号被剥与 cmd 把 | 当管道解析
	if ($系统类型 -eq 'Linux') {
		$改名命令 = ("sh -c 'if [ -f {0}/LOCAL_CANCEL ]; then exit 2; fi; mv {0}/{1}.uploading {0}/{1} && touch {0}/{2}'" -f $暂存目录, $远程包名, $完成标记名)
	} else {
		$改名脚本 = ('if (Test-Path -LiteralPath ''{0}\LOCAL_CANCEL'') {{ exit 2 }}; try {{ Move-Item -LiteralPath ''{0}\{1}.uploading'' -Destination ''{0}\{1}'' -Force -ErrorAction Stop; New-Item -ItemType File -Force ''{0}\{2}'' -ErrorAction Stop | Out-Null }} catch {{ Write-Output $_.Exception.Message; exit 1 }}' -f $暂存目录, $远程包名, $完成标记名)
		$改名命令 = 转换-远程PowerShell命令 $改名脚本
	}
	$改名结果 = 调用-远程命令 $改名命令
	if ($改名结果.退出码 -eq 0) {
		Write-Output '本地供给完成：包已就位并写入完成标记。'
	} elseif ($改名结果.退出码 -eq 2) {
		Write-Output '远程侧已获胜，本地供给取消（改名前）。'
	} else {
		Write-Output ('改名/标记命令失败（退出码 {0}），远端报错：{1}，远程将继续自下载。' -f $改名结果.退出码, $(if ([string]::IsNullOrWhiteSpace($改名结果.输出)) { '无' } else { $改名结果.输出 }))
	}
} catch {
	Write-Output ('本地供给任务异常终止: {0}' -f $_.Exception.Message)
}
