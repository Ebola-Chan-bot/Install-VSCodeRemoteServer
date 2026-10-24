# 远端时钟偏差取证：测量「本机时钟 − 远端时钟」，用来解释同一份日志里两套时间戳为什么对不上。
#
# 为什么需要它：远端脚本的输出经 SSH 转发后会被外层（VS Code preconnect 日志 / 本地转发层）按**本机时钟**标注，
# 而远端若自己也内嵌时钟，就会在同一份日志里形成两条时间轴。远端主机没有 NTP 同步时这个偏差能有几分钟，
# 足以让人把「21 秒」读成「4 分钟」——2026-10-24 就据此误判过「CLI 已远程获胜却 4 分钟后才取消本地供给」。
# 生产侧的结论是**远端输出一律不内嵌时钟**（由外层唯一时钟标注）；本探针负责给这个结论提供可复现的数字，
# 免得代码注释里写上一个来源不明的"约 X 分 Y 秒"。
#
# 测的是**两台机器各自系统钟表的差值**，不是网络延迟：
#   RTT 补偿（NTP 单采样）：本机记 t0 → 远端执行 Get-Date 并回报 → 本机记 t1；
#   偏差 = (t0 + t1)/2 − 远端读数，不确定度 = (t1 − t0)/2（含连接建立与远端 PowerShell 启动）。
#   远端读数必落在 [t0, t1] 区间内，故任何网络/启动耗时最多造成 RTT/2 的误差（实测往返 ~1.4 秒 ⇒ ≤ 0.7 秒），
#   **不可能是几百秒的来源**；几百秒只能是两台机器的钟表本身不同（没开 NTP 的主机很常见）。
# 口径：一律按 **UTC** 相减，并同时回报远端时区偏移——若两端时区不同，拿「本地时间」相减会把时区差误算成时钟差。
# 身份自证：同时回报远端主机名、远端自己的 IPv4、以及 ssh 本次**实际连到的地址**，
#   用来确认「我测到的机器」是不是「你手动 SSH 到的机器」：同一别名可以解出多个地址，OpenSSH 按顺序试连，不同次可能落到不同机器。
# 远端命令一律走 -EncodedCommand：纯 ASCII、无任何引号（PS 5.1 向 ssh.exe 传内嵌双引号会被剥掉，既有教训）。
# 只读：远端只执行 Get-Date / Get-NetIPAddress，不改任何状态。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\远端时钟偏差.ps1
#   powershell ... -File _probe\远端时钟偏差.ps1 -主机列表 '上科大B服务器' -重复次数 3 -间隔秒 3   # 看偏差在一段时间内是否稳定（漂移/被校正）
param(
	[string[]]$主机列表 = @('上科大A服务器_张天夫', '上科大B服务器'),
	[int]$重复次数 = 3,
	[int]$间隔秒 = 3
)
$ErrorActionPreference = 'Stop'

# 远端内层脚本：回报自己的本地时刻、**自己算好的 UTC**（不能拿远端 Ticks 在本机转 UTC，那会给远端读数套上本机时区）、
# 自己的时区偏移、主机名与 IPv4，以及 Windows 时间服务（W32Time）状态——后者解释偏差**为什么存在、会不会继续变大**：
#   Running = 有 NTP 在同步（偏差应在秒级）；Stopped/NoService = 钟表自由漂移（偏差会一路涨）。全用单引号，避开双引号被 ssh.exe 剥掉的既有坑。
$内层 = @'
$t = Get-Date
$ip = ''
try { $ip = ([string[]]((Get-NetIPAddress -AddressFamily IPv4).IPAddress)) -join ',' } catch { }
$svc = (Get-Service W32Time -ErrorAction SilentlyContinue).Status
if (-not $svc) { $svc = 'NoService' }
Write-Output ('__CLK__' + $t.Ticks + '|' + $t.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss.fff') + '|' + [int][DateTimeOffset]::Now.Offset.TotalMinutes + '|' + $env:COMPUTERNAME + '|' + $ip + '|' + $svc)
'@
$编码命令 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($内层))
$ssh = (Get-Command ssh -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $ssh) { Write-Output '未找到 ssh.exe'; exit 1 }

$本机时区分钟 = [int][DateTimeOffset]::Now.Offset.TotalMinutes
Write-Output ('本机时区偏移 = ' + $本机时区分钟 + ' 分钟（下面一律按 UTC 相减，偏差与时区无关）')
Write-Output ''
Write-Output '手动复核办法：先记下本机 UTC，紧接着跑下面这条（可粘），远端回报的 UTC 与本机 UTC 直接相减就是时钟偏差：'
Write-Output ('  ' + $ssh + ' -n -o BatchMode=yes <主机别名> powershell -NoProfile -EncodedCommand ' + $编码命令)
Write-Output ('  本机此刻 UTC = ' + [DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss.fff'))

# ssh 的 mDNS bad CNAME 等噪声在 $ErrorActionPreference='Stop' 下会升成终止性错误，采样期间临时切 Continue
$原始EAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$有失败 = $false
try {
	foreach ($主机 in $主机列表) {
		Write-Output ''
		Write-Output ('===== ' + $主机 + ' =====')
		$样本 = @()
		for ($轮 = 1; $轮 -le [Math]::Max(1, $重复次数); $轮++) {
			# -v 只为拿到 debug1 里「实际连到哪个地址」，用于判断多次采样/你的手动连接是否落在同一台机器
			$t0 = [DateTime]::UtcNow
			$输出 = @(& $ssh -n -v -o BatchMode=yes -o ConnectTimeout=10 $主机 powershell -NoProfile -EncodedCommand $编码命令 2>&1)
			$t1 = [DateTime]::UtcNow
			$码 = $LASTEXITCODE
			$往返毫秒 = ($t1 - $t0).TotalMilliseconds
			# ssh 的调试行走 stderr，在 PS 5.1 里以 ErrorRecord 对象形态到达：不显式转字符串就匹配不上（实测恒得 '?'）
			$连行 = (@($输出 | Where-Object { ([string]$_) -match 'Connecting to ' } | Select-Object -First 1) | ForEach-Object { [string]$_ }) -join ''
			# debug1 的地址括号形态不统一：`Connecting to <名> [fe80::…%16] port 22.` 用**方括号**，`Authenticated to <名> ([fe80::…]:22)` 才是圆括号；
			# 且 IPv6 可带区域号（%16），故不限定字符集、只按「括号内全部内容 + 尾随 port」提取
			$对端IP = if ($连行 -match 'Connecting to .*?[\[\(]([^\]\)]+)[\]\)] port') { $Matches[1] } else { '?' }
			$命中 = @($输出 | Where-Object { ([string]$_) -match '__CLK__' } | ForEach-Object { [string]$_ } | Select-Object -First 1)
			if ($码 -ne 0 -or -not $命中) {
				Write-Output ('  第 ' + $轮 + ' 次：连不上或未取到读数（退出码 ' + $码 + '）：' + (($输出 | Where-Object { $_ -notmatch '^debug1' } | Select-Object -First 3) -join ' | '))
				$有失败 = $true
				continue
			}
			$件 = $命中 -split '\|'
			# 远端回报的就是它自己算的 UTC，这里只做解析，不再套本机时区
			$远UTC = [DateTime]::ParseExact($件[1], 'yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
			$中点 = $t0 + [TimeSpan]::FromTicks([long](($t1.Ticks - $t0.Ticks) / 2))
			$偏差秒 = ($中点 - $远UTC).TotalSeconds
			$远时区 = [int]$件[2]
			$样本 += [pscustomobject]@{ 偏差秒 = $偏差秒; 往返毫秒 = $往返毫秒; 对端IP = $对端IP; 远端主机名 = $件[3]; 远IPv4 = $件[4]; 时间服务 = $件[5] }
			Write-Output ('  第 ' + $轮 + ' 次：连到 ' + $对端IP + '；远端主机名 ' + $件[3] + '；远端 IPv4 ' + $(if ($件[4]) { $件[4] } else { '(取不到)' }) + '；远端时区偏移 ' + $远时区 + ' 分钟')
			Write-Output ('          W32Time 服务 = ' + $件[5] + $(if ($件[5] -eq 'Running') { '（有 NTP 同步，偏差应在秒级）' } else { '（未运行 ⇒ 钟表自由漂移，偏差会继续涨，且不能用固定值换算）' }))
			Write-Output ('          远端 UTC = ' + $件[1] + '   本机 UTC 中点 = ' + $中点.ToString('yyyy-MM-dd HH:mm:ss.fff') + '   往返 ' + [Math]::Round($往返毫秒, 0) + ' ms')
			Write-Output ('          ⇒ 时钟偏差 = ' + [Math]::Round($偏差秒, 1) + ' 秒（正数 = 本机快；不确定度 ±' + [Math]::Round($往返毫秒 / 2000, 1) + ' 秒）' + $(if ($远时区 -ne $本机时区分钟) { '；⚠ 两端时区不同（远 ' + $远时区 + ' vs 本 ' + $本机时区分钟 + ' 分钟），看本地时间的差值没有意义' } else { '；两端时区相同' }))
			if ($轮 -lt [Math]::Max(1, $重复次数)) { Start-Sleep -Seconds ([Math]::Max(1, $间隔秒)) }
		}
		if ($样本.Count -gt 0) {
			$统计 = $样本 | Measure-Object -Property 偏差秒 -Minimum -Maximum -Average
			$文字 = if ($统计.Average -ge 0) { '本机钟表比远端快 ' } else { '远端钟表比本机快 ' }
			Write-Output ('  结论：' + $文字 + [Math]::Round([Math]::Abs($统计.Average), 1) + ' 秒（' + $样本.Count + ' 次采样，范围 ' + [Math]::Round($统计.Minimum, 1) + ' ~ ' + [Math]::Round($统计.Maximum, 1) + ' 秒）')
			$对端IP集 = @($样本 | ForEach-Object { $_.对端IP } | Sort-Object -Unique)
			$主机名集 = (($样本 | ForEach-Object { $_.远端主机名 } | Sort-Object -Unique) -join '、')
			Write-Output ('  这几次连的是：主机名 ' + $主机名集 + ' / 地址 ' + (($对端IP集) -join '、'))
			if ($对端IP集.Count -gt 1) { Write-Output '  ⚠ 多次连到了不同地址：同名多机，你手动 SSH 很可能落在了另一台上——先对齐是哪台再比时钟' }
			if (($统计.Maximum - $统计.Minimum) -gt 2) { Write-Output '  ⚠ 采样间偏差在变（钟表正被校正或漂移中），日志换算只能按粗粒度看' }
			Write-Output '  注意：偏差是**每台主机各有各的值、且会随时间漂移**，别把它当常数写进代码或注释；日志混排两套时钟的根治办法是让远端不要自带时钟。'
		}
	}
} finally {
	$ErrorActionPreference = $原始EAP
}
if ($有失败) { exit 1 }
