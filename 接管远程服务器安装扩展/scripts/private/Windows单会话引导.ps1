# Windows 单会话引导：由 执行-Windows单会话安装 取本文件把载荷占位符替换为安装脚本正文（去整行注释与空行后 gzip+base64）后下发到远端执行。
# 下发通道：本文件整体（含替换后的载荷）再按 UTF-16 base64 一次，经 **stdin** 送到远端，由 private\windows-stdin-bootstrap.ps1 那段固定引导解码并调用。
# 载荷与守卫文件落盘后用标准 PowerShell 调用语法（& 路径）执行，$PSScriptRoot 指向真实目录，同目录的兄弟文件（如 ssh-pipe-guard.ps1）可直接引用。
if ($PSVersionTable.PSVersion.Major -le 2) {
	Write-Output '__PS2__'
	exit 0
}

# ===== 帧接收器（全单连接）=====
# 引导段结束后 stdin 仍保持打开：本地供给的竞速产物按 __FILE__/__CMD__ 字节帧协议由独立接收线程落盘（__FILE__ = <字节数>\n<裸名>\n<裸字节>，落盘登录目录；__CMD__ = 单行 PowerShell 改名+写标记，帧序即「先文件后改名」的原子序，坏包绝不会被就位；__EXIT__ = 收尾退环），协议与 Linux 会话帧循环.sh 完全一致——上传不再依赖任何 scp/ssh 额外连接。裸流与越过标记的帧首段由 windows-stdin-bootstrap.ps1 经 $global:VSI_帧输入流 / $global:VSI_帧剩余字节 交接；全局缺失（未经帧通道引导）时不启动接收器，竞速退化为仅远程自下载，流程仍安全。
function 启动-帧接收器 {
	param($输入流, $起始剩余字节)
	if ($null -eq $输入流) { return $null }
	$运行空间 = [runspacefactory]::CreateRunspace()
	$运行空间.Open()
	$运行空间.SessionStateProxy.SetVariable('输入流', $输入流)
	$运行空间.SessionStateProxy.SetVariable('剩余字节', $起始剩余字节)
	$运行空间.SessionStateProxy.SetVariable('停止标志', $false)
	$接收PS = [powershell]::Create()
	$接收PS.Runspace = $运行空间
	[void]$接收PS.AddScript({
		$script:缓冲 = [byte[]](Get-Variable -Name 剩余字节 -ValueOnly)
		if ($null -eq $script:缓冲) { $script:缓冲 = New-Object byte[] 0 }
		$script:偏移 = 0
		function 等-有字节 {
			# 返回 true = 缓冲里至少还有 1 个未消费字节；false = EOF/停止/读失败。ReadAsync + 2 秒切片：停止标志可被响应，也不会成为永不退出的孤儿线程
			while (($script:缓冲.Length - $script:偏移) -le 0) {
				if (Get-Variable -Name 停止标志 -ValueOnly) { return $false }
				$读缓冲 = New-Object byte[] 65536
				$任务 = $null
				try { $任务 = (Get-Variable -Name 输入流 -ValueOnly).ReadAsync($读缓冲, 0, $读缓冲.Length) } catch { return $false }
				try { if (-not $任务.Wait(2000)) { continue } } catch { return $false }
				$读到 = 0
				try { $读到 = $任务.Result } catch { return $false }
				if ($读到 -le 0) { return $false }
				if ($读到 -lt $读缓冲.Length) {
					$收窄 = New-Object byte[] $读到
					[Array]::Copy($读缓冲, $收窄, $读到)
					$读缓冲 = $收窄
				}
				$script:缓冲 = $读缓冲
				$script:偏移 = 0
			}
			return $true
		}
		function 读-字节行 {
			# 逐字节读到 LF，剥尾部 CR 后按 UTF-8 解码（改名命令帧可能含非 ASCII）；EOF/停止在线中途也返回 $null 当作通道结束
			$汇 = New-Object System.IO.MemoryStream
			while ($true) {
				if (-not (等-有字节)) { return $null }
				$字节 = $script:缓冲[$script:偏移]
				$script:偏移++
				if ($字节 -eq 10) { break }
				$汇.WriteByte($字节)
			}
			$字节组 = $汇.ToArray()
			while ($字节组.Length -gt 0 -and $字节组[$字节组.Length - 1] -eq 13) { [Array]::Resize([ref]$字节组, $字节组.Length - 1) }
			return [System.Text.Encoding]::UTF8.GetString($字节组)
		}
		while ($true) {
			if (Get-Variable -Name 停止标志 -ValueOnly) { break }
			$帧型 = 读-字节行
			if ($null -eq $帧型) { break }
			if ($帧型 -eq '__EXIT__') { break }
			if ($帧型 -eq '__FILE__') {
				$长度行 = 读-字节行
				if ($null -eq $长度行) { break }
				$文件名 = 读-字节行
				if ($null -eq $文件名) { break }
				$预期字节数 = -1
				try { $预期字节数 = [long](($长度行 -replace '\s', '')) } catch { $预期字节数 = -1 }
				# 落盘只取裸名：落点恒为登录目录（%USERPROFILE%），路径分量一律丢弃，防止帧把文件写出界外
				$安全名 = [System.IO.Path]::GetFileName($文件名)
				$目标路径 = Join-Path $env:USERPROFILE $安全名
				$已收字节数 = [long]0
				$落盘错误 = ''
				if ($预期字节数 -lt 0) { $落盘错误 = 'bad_length_header' }
				else {
					$文件流 = $null
					try {
						$文件流 = [System.IO.File]::Create($目标路径)
						while ($已收字节数 -lt $预期字节数) {
							if (-not (等-有字节)) { break }
							$可取 = [int][Math]::Min([Math]::Min(65536, $预期字节数 - $已收字节数), $script:缓冲.Length - $script:偏移)
							$文件流.Write($script:缓冲, $script:偏移, $可取)
							$script:偏移 += $可取
							$已收字节数 += $可取
						}
					} catch { $落盘错误 = $_.Exception.Message }
					if ($null -ne $文件流) { try { $文件流.Dispose() } catch { } }
				}
				# 长度不符也可能来自落盘失败（磁盘满/配额）：连同预期与实际字节一起回报，本地侧会带 stderr 诊断抛出，不得只归因“传输错位”；半成品删除防止竞速误用坏包
				if ($落盘错误 -ne '' -or $已收字节数 -ne $预期字节数) {
					$附注 = ''
					if ($落盘错误 -ne '') { $附注 = ' write_error=' + $落盘错误 }
					Write-Host ('__FRAME_TRUNCATED__ {0} expected={1} received={2}{3}' -f $安全名, $预期字节数, $已收字节数, $附注)
					try { Remove-Item -LiteralPath $目标路径 -Force -ErrorAction SilentlyContinue } catch { }
					break
				}
				continue
			}
			if ($帧型 -eq '__CMD__') {
				$命令文本 = 读-字节行
				if ($null -eq $命令文本) { break }
				try { & ([scriptblock]::Create($命令文本)) | Out-Null } catch { }
				continue
			}
			# 未知帧型行按预热/垃圾行忽略（与 Linux 会话帧循环.sh 的 case 无匹配分支同语义）
		}
	})
	$句柄 = $接收PS.BeginInvoke()
	return @{ 运行空间 = $运行空间; PS = $接收PS; 句柄 = $句柄 }
}
function 停止-帧接收器 {
	param($接收器)
	if ($null -eq $接收器) { return }
	try { $接收器.运行空间.SessionStateProxy.SetVariable('停止标志', $true) } catch { }
	# 异步等待 + 超时强停：接收器可能正卡在读取切片里，阻塞式 EndInvoke 会把收尾拖死；接收线程是后台 runspace 线程，即使弃管也不阻碍进程退出
	try {
		if (-not $接收器.句柄.AsyncWaitHandle.WaitOne(3000)) { $接收器.PS.Stop() }
	} catch { }
	try { $接收器.PS.Dispose() } catch { }
	try { $接收器.运行空间.Dispose() } catch { }
}

# 接收器在安装脚本执行前启动：竞速产物的帧随时可能在安装期间到达，接收线程与安装主流程并行、互不阻塞
$接收器 = 启动-帧接收器 -输入流 $global:VSI_帧输入流 -起始剩余字节 $global:VSI_帧剩余字节

$流 = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String('__载荷__'))
$解压 = New-Object System.IO.Compression.GZipStream($流, [System.IO.Compression.CompressionMode]::Decompress)
$读 = New-Object System.IO.StreamReader($解压, [System.Text.Encoding]::UTF8)
$文本 = $读.ReadToEnd()
$临时目录 = Join-Path $env:TEMP ('vsi-install-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $临时目录 | Out-Null
$安装脚本路径 = Join-Path $临时目录 'remote-install-common.ps1'
[System.IO.File]::WriteAllText($安装脚本路径, $文本, (New-Object System.Text.UTF8Encoding($true)))
$守卫源路径 = Join-Path $临时目录 'ssh-pipe-guard.ps1'
$流2 = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String('__守卫载荷__'))
$解压2 = New-Object System.IO.Compression.GZipStream($流2, [System.IO.Compression.CompressionMode]::Decompress)
$读2 = New-Object System.IO.StreamReader($解压2, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($守卫源路径, $读2.ReadToEnd(), (New-Object System.Text.UTF8Encoding($true)))
try {
	& $安装脚本路径
	$退出码 = $LASTEXITCODE
	if ($null -eq $退出码) { $退出码 = 0 }
} catch {
	Write-Host ('安装脚本异常终止: {0}' -f $_.Exception.Message)
	$退出码 = 1
} finally {
	# 先停帧接收器再清临时目录；之后进程退出时 stdin 随进程关闭，本地侧读到 EOF 收尾
	停止-帧接收器 $接收器
	Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
}
exit $退出码
