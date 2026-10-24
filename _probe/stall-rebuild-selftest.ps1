# 停滞干净重建行为自检：实跑仓库里那份 通过HTTP断点续传下载（按 AST 取函数体，不是副本），对着一个
# 「每连接只发 100 字节然后永久停滞」的伪 HTTP 源跑约 30 秒，核对停滞处理定稿的五条性质：
#   ① 停滞不报错：全程没有「下载中断」行（停滞不走 catch、不计重试）；
#   ② 每次停滞产出一条「干净重建 HTTP 连接」行，且续传点字节数严格递增（Range 续传不丢已收字节）；
#   ③ 进度行照旧时钟驱动（重建之间有「远程下载进度」行）；
#   ④ 磁盘文件长度 >= 最后一条重建行的续传点（写的字节真的落了盘）；
#   ⑤ catch 无异常逸出（伪源停滞期间不得有任何穿透重试循环的异常）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\stall-rebuild-selftest.ps1
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$源文件 = Join-Path $repo 'module\private\remote-install-common.ps1'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

# ===== 取被测函数（仓库文件本身，防止副本漂移） =====
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($源文件, [ref]$tokens, [ref]$errors)
断言 ($errors.Count -eq 0) ("语法解析: remote-install-common.ps1" + $(if ($errors.Count) { ' -> ' + (($errors | ForEach-Object { $_.Message }) -join '; ') } else { '' }))
$func = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -like '*HTTP*' }, $true) | Select-Object -First 1
if (-not $func) { Write-Output 'FAIL: 找不到断点续传下载函数'; exit 1 }
Write-Output ("被测函数: " + $func.Name + "（" + $func.Extent.Text.Length + " 字，取自仓库文件本身）")

# ===== 伪源：TCP 侦听，每连接解析 Range 后回 206 + 恰好 100 字节，随后永久停滞（不发也不关） =====
$端口 = 0
$侦听探测 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$侦听探测.Start(); $端口 = ([System.Net.IPEndPoint]$侦听探测.LocalEndpoint).Port; $侦听探测.Stop()

# 伪源：单线程顺序应答——每个新连接同步读请求头、回 206+100 字节，然后把 socket 攥进挂起列表（不再写也不再关 = 停滞）；
# 不需要每连接开线程/运行空间：客户端只有在上一连接被判停滞重建后才会来下一个连接，顺序应答刚好跟得上
$伪源代码 = {
	param([int]$端口)
	$挂起 = New-Object 'System.Collections.Generic.List[object]'
	$侦听 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $端口)
	$侦听.Start()
	while ($true) {
		$客户 = $侦听.AcceptTcpClient()
		try {
			$s = $客户.GetStream()
			$s.ReadTimeout = 10000
			$buf = New-Object byte[] 4096
			$ms = New-Object System.IO.MemoryStream
			while ($true) {
				$n = $s.Read($buf, 0, $buf.Length)
				if ($n -le 0) { break }
				$ms.Write($buf, 0, $n)
				if ([Text.Encoding]::ASCII.GetString($ms.ToArray()) -match "`r`n`r`n") { break }
			}
			$请求文本 = [Text.Encoding]::ASCII.GetString($ms.ToArray())
			$起点 = 0
			$m = [regex]::Match($请求文本, 'bytes=(\d+)-')
			if ($m.Success) { $起点 = [int]$m.Groups[1].Value }
			$数据 = [Text.Encoding]::ASCII.GetBytes('x' * 100)
			# Content-Length 必须远大于实发字节数：若恰好等于实发量，HttpWebRequest 会视为响应完整而干净 EOF（永远等不到停滞）
			$头 = "HTTP/1.1 206 Partial Content`r`nContent-Length: 100000`r`nContent-Range: bytes $起点-$($起点+99999)/1000000`r`n`r`n"
			$头字节 = [Text.Encoding]::ASCII.GetBytes($头)
			$s.Write($头字节, 0, $头字节.Length)
			$s.Write($数据, 0, $数据.Length)
			$s.Flush()
		} catch { }
		$挂起.Add($客户)
	}
}

$服务作业 = Start-Job -ScriptBlock $伪源代码 -ArgumentList $端口
Start-Sleep -Seconds 2
if ($服务作业.State -ne 'Running') {
	Write-Output ('FAIL: 伪源作业没起来：' + (($服务作业 | Receive-Job) -join "`n"))
	exit 1
}
Write-Output ("伪源已就位：http://127.0.0.1:$端口/fake.bin（每连接发 100 字节后永久停滞）")

# ===== 起被测下载器 =====
$url = "http://127.0.0.1:$端口/fake.bin"
$target = Join-Path $env:TEMP 'stall-rebuild-selftest.bin'
Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
$runner = $func.Extent.Text + "`n" + '&' + ' ' + $func.Name + " '$url' '$target'"
$runnerPath = Join-Path $env:TEMP 'stall-rebuild-selftest-runner.ps1'
Set-Content -LiteralPath $runnerPath -Value $runner -Encoding UTF8
$outPath = Join-Path $env:TEMP 'stall-rebuild-selftest-out.txt'
$errPath = Join-Path $env:TEMP 'stall-rebuild-selftest-err.txt'
Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

$观测秒数 = 30
Write-Output ''
Write-Output "===== 实跑下载器约 $观测秒数 秒（伪源每连接只发 100 字节后停滞） ====="
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runnerPath) -RedirectStandardOutput $outPath -RedirectStandardError $errPath -NoNewWindow -PassThru
Start-Sleep -Seconds $观测秒数
$磁盘长度 = if (Test-Path -LiteralPath $target) { (Get-Item -LiteralPath $target).Length } else { 0 }
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 700
Remove-Job -Id $服务作业.Id -Force -ErrorAction SilentlyContinue

$lines = @(Get-Content -LiteralPath $outPath)
$错误文本 = if (Test-Path -LiteralPath $errPath) { (Get-Content -LiteralPath $errPath -Raw) } else { '' }
Write-Output '----- 捕获到的完整输出 -----'
$lines | ForEach-Object { Write-Output $_ }
Write-Output '----- 断言 -----'

# ① 停滞不报错：没有任何中断行
$中断行 = @($lines | Where-Object { $_ -like '*下载中断*' })
断言 ($中断行.Count -eq 0) ('停滞全程零中断行（停滞不按失败处理，实测 ' + $中断行.Count + ' 条）')

# ② 重建行 >= 2 且续传点严格递增
$重建行 = @($lines | Where-Object { $_ -like '*干净重建 HTTP 连接*' })
断言 ($重建行.Count -ge 2) ('至少两次干净重建（实测 ' + $重建行.Count + ' 次）')
$续传点 = @($重建行 | ForEach-Object { if ($_ -match '续传点 (\d+) 字节') { [int]$Matches[1] } })
$递增 = $true
for ($i = 1; $i -lt $续传点.Count; $i++) { if ($续传点[$i] -le $续传点[$i - 1]) { $递增 = $false } }
断言 ($续传点.Count -ge 2 -and $递增) ('重建续传点严格递增（Range 续传不丢字节）：' + ($续传点 -join ' -> '))

# ③ 进度行照旧存在
$进度行 = @($lines | Where-Object { $_ -like '*远程下载进度*' })
断言 ($进度行.Count -ge 2) ('重建之间有进度行（实测 ' + $进度行.Count + ' 条）')

# ④ 磁盘长度不落后于最后一条重建行的续传点
$落盘不丢 = ($续传点.Count -eq 0) -or ($磁盘长度 -ge $续传点[-1])
断言 $落盘不丢 ('磁盘文件 ' + $磁盘长度 + ' 字节 >= 最后重建续传点 ' + $(if ($续传点.Count) { $续传点[-1] } else { 0 }) + ' 字节')

# ⑤ 无异常逸出（与 download-log-selftest 同款特征表）
$异常特征 = @('RuntimeException', 'CategoryInfo', 'InvalidCastIConvertible', 'Cannot convert value', 'FullyQualifiedErrorId', '异常终止')
$逸出 = @($异常特征 | Where-Object { $错误文本 -like "*$_*" -or (($lines -join "`n") -like "*$_*") })
断言 ($逸出.Count -eq 0) ('catch 里无异常逸出（命中特征 ' + $逸出.Count + ' 个' + $(if ($逸出.Count) { '：' + ($逸出 -join ',') } else { '' }) + '）')
if ($逸出.Count -gt 0 -and $错误文本) { Write-Output ('    stderr 前 600 字: ' + $错误文本.Substring(0, [Math]::Min(600, $错误文本.Length))) }

Remove-Item -LiteralPath $target, $runnerPath -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output ("断言失败数: " + (取-断言计数).失败)
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
