# 取证：Windows 远程单会话引导的传输通道容量实测（不改任何状态，只读）
#
# 背景（2026-10-22 复现）：preconnect 脚本报 `Program 'ssh.exe' failed to run: The filename or extension is too long`，
#   位置 psm1:621 `& $ssh命令.Source $ssh参数 2>&1 | ForEach-Object $处理行`，调用链 执行-Windows单会话安装 → 安装-VSCode远程服务。
#   该函数把「安装脚本正文 gzip+base64」再嵌进引导模板、又整体按 UTF-16 base64 一次（$引导码），结果直接进 argv，
#   撞上 Windows CreateProcess 约 32KB 命令行上限 → ssh.exe 根本没起 → 退出码 1 → Remote-SSH 判 PreconnectScriptFailure，整条连接夭折。
# 待判定的问题：
#   ① 各阶段实际字节数到底多大（本地能算出来的部分）；
#   ② 远端 sshd 的默认 shell 是什么（cmd.exe 会带 8191 字符命令行上限，决定 argv 方案是否根本无解）；
#   ③ argv 通道实际能塞多长（真机试探：2000/6000/12000/30000 字符）；
#   ④ stdin 通道能否可靠送达大载荷（旧注释说"远端默认 shell 对 stdin 收尾不可靠"，需要证据推翻或确认）。
# 判据：远端回显清洗后的长度与 SHA256，与本地一致即为通道无损；用 StopWatch 计时（不用 Measure-Command，它会吞管道输出）。
# 用法：powershell -ExecutionPolicy Bypass -File _probe\ssh-传输容量取证.ps1 [-远程主机 上科大A服务器_张天夫] [-账户 张天夫]

param(
	[string]$远程主机 = '上科大A服务器_张天夫',
	[string]$账户 = '张天夫',
	[int]$端口 = 22,
	[switch]$跳过stdin测试
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
$模块目录 = 取-模块目录
$连接目标 = '{0}@{1}' -f $账户, $远程主机
Write-Host '===== ① 本地各阶段体积（直接用公共库 构造-单会话载荷，与生产同一套算法，不再自己拄一份） ====='

function 算-引导码长度 {
	param([string]$脚本文本, [string]$模板文本)
	# 薄包装：字段名沿用本工具历史叫法，算法一律走库（库与 psm1 的同源性由 lib-selftest.ps1 的漂移守卫守住）
	$构 = 构造-单会话载荷 -安装脚本文本 $脚本文本 -引导模板路径 $模板文本
	$argv文本 = 'powershell -NoProfile -EncodedCommand {0}' -f $构.引导码
	return [pscustomobject]@{
		精简正文字符 = $构.精简正文字符
		gzip字节     = $构.gzip字节
		载荷base64   = $构.载荷.Length
		引导脚本字符 = $构.引导脚本.Length
		引导码base64 = $构.引导码.Length
		argv长度     = $argv文本.Length
	}
}

$模板路径 = Join-Path $模块目录 'private\Windows单会话引导.ps1'
$通用路径 = Join-Path $模块目录 'private\remote-install-common.ps1'
$win7路径 = Join-Path $模块目录 'private\remote-install-win7.ps1'
$模板文本 = Get-Content $模板路径 -Raw -Encoding UTF8
Write-Host ('  Windows单会话引导.ps1     字符数 = {0}' -f $模板文本.Length)
foreach ($对 in @(
	@{ 名 = '仅 remote-install-common.ps1（保守下界）'; 文 = (Get-Content $通用路径 -Raw -Encoding UTF8) },
	@{ 名 = '通用 + win7 合并（近似上界）';           文 = ((Get-Content $通用路径 -Raw -Encoding UTF8) + "`n" + (Get-Content $win7路径 -Raw -Encoding UTF8)) }
)) {
	$r = 算-引导码长度 -脚本文本 $对.文 -模板文本 $模板文本
	Write-Host ('  --- {0}' -f $对.名)
	Write-Host ('      精简正文 {0} 字符 → gzip {1} 字节 → 载荷 base64 {2} 字符' -f $r.精简正文字符, $r.gzip字节, $r.载荷base64)
	Write-Host ('      引导脚本 {0} 字符 → 引导码 base64 {1} 字符 → **argv {2} 字符**' -f $r.引导脚本字符, $r.引导码base64, $r.argv长度)
	# PS 5.1 不支持把 if 当表达式内联用，先算成变量
	$对CreateProcess = '未超'
	if ($r.argv长度 -gt 32767) { $对CreateProcess = '超限（ssh.exe 起不来）' }
	$对cmd = '未超'
	if ($r.argv长度 -gt 8191) { $对cmd = '超限（远端 cmd /c 也会拒）' }
	Write-Host ('      判定：CreateProcess 上限 32767 → {0}；远端 cmd.exe /c 上限 8191 → {1}' -f $对CreateProcess, $对cmd)
}

Write-Host ''
Write-Host '===== ② 远端 sshd 默认 shell（决定 argv 是否有 8191 上限） ====='
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$reg = @(& ssh.exe -n -p $端口 $连接目标 'reg query "HKLM\SOFTWARE\OpenSSH" /v DefaultShell' 2>&1)
$sw.Stop()
Write-Host ('  耗时 {0:N2} 秒，退出码 {1}' -f $sw.Elapsed.TotalSeconds, $LASTEXITCODE)
if (($reg | Out-String).Trim() -eq '') { Write-Host '  （无输出：多半是注册表里没有 DefaultShell 值 → sshd 用内置默认 cmd.exe，argv 受 8191 限制）' }
$reg | ForEach-Object { Write-Host ('    ' + $_) }

Write-Host ''
Write-Host '===== ③ argv 通道容量试探（回显长度一致即通） ====='
foreach ($长 in @(500, 2000, 6000, 8000, 12000, 20000, 30000)) {
	$填充 = 'A' * $长
	$cmdText = 'powershell -NoProfile -Command ("ARGVLEN=" + "{0}".Length)' -f $填充
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	$out = @(& ssh.exe -n -p $端口 $连接目标 $cmdText 2>&1)
	$码 = $LASTEXITCODE
	$sw.Stop()
	$回显 = ($out | Where-Object { $_ -match 'ARGVLEN=' } | Select-Object -First 1)
	if ($null -eq $回显) { $回显 = (($out | Select-Object -First 1)) }
	Write-Host ('  期望 {0,6} → 退出码 {1}  {2,6:N2} 秒  回显={3}' -f $长, $码, $sw.Elapsed.TotalSeconds, [string]$回显)
}

if ($跳过stdin测试) { Write-Host ''; Write-Host '（已跳过 stdin 测试）'; return }

Write-Host ''
Write-Host '===== ④ stdin 通道可靠性（生产同款序列：显式 Close + 看门狗；清洗后长度 + SHA256 双判据） ====='
# 本段旧写法是 `$文本 | & ssh.exe …` 管道式，120KB 那一档实测挂死约 66 分钟；生产早已改成
#   ProcessStartInfo + 写完立即 Close + stderr 异步抽干 + 看门狗（库里的 送-载荷经stdin 就是它），
#   所以此处量的是**现行生产通道**的容量，不再重复测已废弃的管道写法。
# 远端固定小引导：读全量 stdin → 去空白 → 报长度与 SHA256（全 ASCII 源码，不含中文，避免管道编码问题）
# 它的读取也是有界的（等不到 EOF 就报 STDINTIMEOUT 并退出）：探针自身绝不得在远端留孤儿
$远端脚本 = '$b=[Console]::In.ReadToEndAsync();if(-not $b.Wait(90000)){Write-Output "STDINTIMEOUT";exit 1};$s=$b.Result;$c=($s -replace "\s","");$h=[Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($c));Write-Output ("STDINLEN=" + $c.Length);Write-Output ("STDINSHA=" + (($h | ForEach-Object { $_.ToString("x2") }) -join ""));exit 0'
$小引导码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($远端脚本))
$小命令行 = 'powershell -NoProfile -EncodedCommand ' + $小引导码
Write-Host ('  固定小引导 EncodedCommand 长度 = {0} 字符（永远进 argv，与载荷大小无关）' -f $小引导码.Length)
foreach ($KB in @(2, 40, 120, 400)) {
	$目标长度 = $KB * 1024
	$字母 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
	$sb = New-Object System.Text.StringBuilder
	while ($sb.Length -lt $目标长度) { [void]$sb.Append($字母) }
	$净 = $sb.ToString(0, $目标长度)
	$本地哈希 = (([Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::ASCII.GetBytes($净))) | ForEach-Object { $_.ToString('x2') }) -join ''
	# 整段喂 stdin（与生产一致：载荷已不再分块）。注意：早先四档均通过的实测结果是**分块版**跑出来的，改整段后需连真机复跑一次才能沿用结论（整段才能真测出单次写入的容量上限，分块反而会把长行问题掩盖）
	$文本 = $净
	$r = 送-载荷经stdin -主机 $连接目标 -命令文本 $小命令行 -标准输入文本 $文本 -端口 $端口 -超时秒 150
	$远长度 = ($r.行 | Where-Object { $_ -match 'STDINLEN=' } | Select-Object -First 1)
	$远哈希行 = ($r.行 | Where-Object { $_ -match 'STDINSHA=' } | Select-Object -First 1)
	$一致 = ($null -ne $远哈希行) -and (($远哈希行 -replace 'STDINSHA=', '') -eq $本地哈希)
	$噪声 = (($r.行 | Where-Object { $_ -notmatch 'STDINLEN=|STDINSHA=' } | Select-Object -First 2) -join ' | ')
	Write-Host ('  {0,4} KB → 退出码 {1}  {2,6:N2} 秒  {3}  哈希一致={4}  看门狗超时={5}' -f $KB, $r.退出码, $r.耗时秒, [string]$远长度, $一致, $r.超时)
	if ($噪声) { Write-Host ('        （其它输出：{0}）' -f $噪声) }
}
Write-Host ''
Write-Host '判读：④ 全部「哈希一致=True 且 退出码 0」→ 生产 stdin 通道能承载该体量载荷（实测已推到 154KB、39 块）；'
Write-Host '      若大尺寸挂死/不一致 → 先用 prod-faithful-repro.ps1 分清「本地写出卡住」与「远端没收到」，再用 远端体检.ps1 看是不是会话饱和；'
Write-Host '      实在不行才考虑回到 ③ 的 argv 上限内分块多连接方案（每块 <= min(8191, 32767) 再留余量）。'
