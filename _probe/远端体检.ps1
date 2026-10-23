# 远端体检（只读）：一条命令取回排查「远端在跑 / 本地静默」类故障所需的全部现场。
#
# 合并了此前八个一次性探针（b-server-probe、b-server-probe2、remote-state-readonly、remote-session-probe、
# remote-server-probe、remote-zombie-probe、remote-hang-probe、defaultshell-compare），它们的差别只在「多问远端几句」，
# 传输与噪声处理却各抄了一遍（抄漏 ssh -n / BatchMode 就会让探针自己挂在密码提示上，2026-10-23 实测踩过）。
#
# 覆盖：powershell/sshd/Start-Job 计数、卡死引导孤儿（EncodedCommand 且龄 >180s）及其树、DefaultShell 与重定向态、
#       竞速暂存目录与已装 server、数据目录残留 CLI 包、磁盘与家目录可写性；可选两次采样求下载速率。
# 纪律：全程只读（唯一写动作是家目录可写性自测，当场删掉）；绝不下载、不删标记、不杀进程。
#       要清孤儿请用 remote-stale-tree-clean.ps1（破坏性，会杀进程，需显式给连接起点）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\远端体检.ps1 -主机 上科大A服务器_张天夫
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\远端体检.ps1 -主机 张天夫@上科大B服务器 -提交号 58173d0ebc… -含引导树明细
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\远端体检.ps1 -主机 … -提交号 … -测下载速率

param(
	[string]$主机 = '上科大A服务器_张天夫',
	[string]$提交号 = '58173d0ebc1838579e3c331e0a47e365904a6456',
	[int]$端口 = 22,
	[int]$连接超时秒 = 12,
	[switch]$不含提交号,
	[switch]$含引导树明细,
	[switch]$测下载速率,
	[int]$采样间隔秒 = 12
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
# 生产单会话安装在远端 argv 里的钢印指纹（固定引导码的前缀）：靠它才能把
# 「生产引导进程」与「探针/别人的一次性 EncodedCommand 脚本」分开，否则会把正在跑的安装报成孤儿
$引导码特征 = 取-引导码特征

Write-Host ('===== 远端体检：' + $主机 + $(if ($不含提交号) { '' } else { '（提交号 ' + $提交号.Substring(0, 10) + '…）' }) + ' =====')

$普查 = if ($不含提交号) {
	取-远端普查脚本 -引导码特征 $引导码特征 -含引导树明细:$含引导树明细
} else {
	取-远端普查脚本 -提交号 $提交号 -引导码特征 $引导码特征 -含引导树明细:$含引导树明细 -含竞速文件明细:$测下载速率
}
$r = 送-远端脚本 -主机 $主机 -脚本文本 $普查 -端口 $端口 -连接超时秒 $连接超时秒
Write-Host ('  ssh 退出码=' + $r.退出码 + '  耗时=' + $r.耗时秒 + 's  argv 用去 ' + $r.编码长度 + ' 字符')
if ($r.行.Count -eq 0) {
	Write-Host '  取不到远端结论行。原始输出：'
	$r.全部行 | Select-Object -First 12 | ForEach-Object { Write-Host ('    ' + $_) }
	Write-Host '  判读：退出码 255 + 12s ≈ 连接层就不通（sshd 饱和拒连 / 凭据 / 网络），不是安装逻辑问题。'
	exit 1
}
$r.行 | ForEach-Object { Write-Host ('  ' + $_) }

# 现场判读（把「一堆数字」翻译成「下一步该干什么」，避免每次都要重新回忆判据）
$文本 = ($r.行 -join ' ')
$孤儿数 = 0
if ($文本 -match '疑似卡死孤儿=(\d+)') { $孤儿数 = [int]$Matches[1] }
$引导进程数 = 0
if ($文本 -match '固定引导码进程数=(\d+)') { $引导进程数 = [int]$Matches[1] }
$其它编码数 = 0
if ($文本 -match '其它EncodedCommand进程数\([^)]*\)=(\d+)') { $其它编码数 = [int]$Matches[1] }
$sshd数 = 0
if ($文本 -match 'sshd会话数=(\d+)') { $sshd数 = [int]$Matches[1] }
$已装 = ($文本 -match '服务端已装=True')
Write-Host ''
Write-Host '===== 判读 ====='
if ($孤儿数 -gt 0) {
	Write-Host ('  ⚠ 有 ' + $孤儿数 + ' 个疑似卡死引导孤儿（带生产引导码特征 且 超龄 且 几乎没耗 CPU）。')
	Write-Host '    它们是本地看门狗 taskkill 杀 ssh 后留下的（Windows 不向远端传播信号）；'
	Write-Host '    孤儿堆积 → sshd 会话饱和 → 新连接首字节延迟超过 240s 看门狗 → 再杀再留 → 死亡螺旋。'
	Write-Host ('    处理：remote-stale-tree-clean.ps1 -主机 ' + $主机 + ' -连接起点 <本次连接起点>（默认只清点，-清理 才动手）。')
} elseif ($引导进程数 -gt 0) {
	Write-Host ('  有 ' + $引导进程数 + ' 个生产引导进程，但 CPU 非零或未超龄 → **很可能就是正在跑的安装，不要杀**。')
	Write-Host '    下一步：-测下载速率 看在途文件是否长大；长大=正常，不长大且服务端已装=' + $(if ($已装) { 'True' } else { 'False' }) + ' 才是真卡住。'
} else {
	Write-Host '  无生产引导进程：远端侧干净，卡在别处（通道 / 本地回调 / VS Code 侧信任门）。'
}
if ($其它编码数 -gt 0) {
	Write-Host ('  另有 ' + $其它编码数 + ' 个其它 EncodedCommand 进程（探针/一次性脚本，不是生产引导；清理工具不会动它们）。')
}
if ($sshd数 -ge 30) {
	Write-Host ('  ⚠ sshd 会话数 ' + $sshd数 + '（≥30 视为拥挤）：新连接的首字节投递会明显变慢，清理孤儿后应回落。')
} else {
	Write-Host ('  sshd 会话数 ' + $sshd数 + '（正常水位）。')
}
if ($文本 -match '家目录可写=否') {
	Write-Host '  ⚠ 家目录不可写：下载/解压必然失败，先解决配额或权限（df 空闲多 ≠ 配额没满）。'
}

if ($测下载速率) {
	if ($不含提交号) {
		Write-Host '  （-测下载速率 需要 -提交号，已跳过）'
	} else {
		Write-Host ''
		Write-Host ('===== 下载速率：两次采样（间隔 ' + $采样间隔秒 + ' 秒） =====')
		$采样脚本 = @'
$rc = Join-Path $env:USERPROFILE ('.vscode-server-insiders\race-' + '__SUB__')
if (-not (Test-Path $rc)) { Write-Output '__T__无竞速目录'; return }
foreach ($f in @(Get-ChildItem -LiteralPath $rc -Force -ErrorAction SilentlyContinue)) {
	Write-Output ('__T__' + $f.Name + '=' + $f.Length)
}
'@.Replace('__SUB__', $提交号)
		$s1 = 送-远端脚本 -主机 $主机 -脚本文本 $采样脚本 -端口 $端口 -连接超时秒 $连接超时秒
		Start-Sleep -Seconds $采样间隔秒
		$s2 = 送-远端脚本 -主机 $主机 -脚本文本 $采样脚本 -端口 $端口 -连接超时秒 $连接超时秒
		function 取-尺寸表([object[]]$行集) {
			$表 = @{}
			foreach ($行 in $行集) {
				$m = [regex]::Match([string]$行, '^(.+?)=(\d+)$')
				if ($m.Success) { $表[$m.Groups[1].Value] = [int64]$m.Groups[2].Value }
			}
			return $表
		}
		$t1 = 取-尺寸表 $s1.行
		$t2 = 取-尺寸表 $s2.行
		if ($t1.Count -eq 0 -and $t2.Count -eq 0) {
			Write-Host '  竞速目录不存在或为空（可能尚未开始竞速，或本轮零下载直接跳过）。'
		} else {
			foreach ($名 in (($t1.Keys + $t2.Keys) | Sort-Object -Unique)) {
				$a = if ($t1.ContainsKey($名)) { $t1[$名] } else { 0 }
				$b = if ($t2.ContainsKey($名)) { $t2[$名] } else { 0 }
				$速率 = [Math]::Round((($b - $a) / [Math]::Max(1, $采样间隔秒)) / 1KB, 1)
				Write-Host ('  ' + $名.PadRight(42) + ($a.ToString('N0')).PadLeft(13) + ' → ' + ($b.ToString('N0')).PadLeft(13) + '  ' + ($速率.ToString('0.0')).PadLeft(9) + ' KB/s')
			}
			Write-Host '  判读：0 KB/s 且文件不在长大 = 远端下载已死（等本地供给或换源）；持续增长即正常。'
		}
	}
}
