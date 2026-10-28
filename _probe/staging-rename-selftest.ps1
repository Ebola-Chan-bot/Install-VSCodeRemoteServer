# 暂存目录清理与远端改名脚本的真机自检
#  A. sh 预备命令：用 psm1 里同一表达式生成命令串，在 git bash 下用假 HOME 跑，核对「标记与完整包被清、活连接的 .uploading 保留」
#     （这条命令要穿过 PS 5.1 双引号 + `转义 + ssh + sh 四层，生成串必须真跑一遍才算验证）
#  B. Windows 远端改名脚本：用 local-supply.ps1 里同一格式串生成，在真主机上跑四个场景（happy / 源文件不在 / 取消标记在 / 目标已同长），
#     核对退出码与 __VSI_ERR__: 标记是否可解析（旧版真机实测退 1 且真因被 CLIXML 噪声淹没）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\staging-rename-selftest.ps1 [-只跑A] [-主机 <ssh别名>]
param(
	[switch]$只跑A,
	[string]$主机 = '上科大A服务器_张天夫'
)
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

# ---------- A. sh 预备命令（与 psm1 中的表达式逐字一致） ----------
$竞速数据目录名 = '.vscode-server-insiders'
$提交号 = 'selftestcommit0000000000000000000000000000ab'
$竞速预备命令 = "sh -c 'D=`$HOME/{0}/race-{1}; mkdir -p `$D; for f in `$D/*; do [ -e `$f ] || continue; case `$f in *.uploading) continue;; esac; rm -rf `$f; done; exit 0'" -f $竞速数据目录名, $提交号
Write-Output '===== A. 生成的 sh 预备命令（将交给 git bash 实跑） ====='
Write-Output $竞速预备命令
断言 ($竞速预备命令 -notmatch 'rm -rf ~|rm -rf \$D;|rm -rf "\$D"') '预备命令不再整目录删除暂存目录'
断言 ($竞速预备命令 -like '*`.uploading) continue;;*') '预备命令保留 .uploading 分支存在'
断言 ($竞速预备命令 -like '*mkdir -p*') '预备命令仍负责建目录'
断言 ($竞速预备命令 -notmatch '"') '预备命令不含双引号（PS 5.1 传给 ssh 会剥掉内嵌双引号）'

# 只取 sh -c 后面那段单引号内的脚本，用假 HOME 在本地 git bash 跑
$sh载荷 = [regex]::Match($竞速预备命令, "^sh -c '(.*)'$").Groups[1].Value
$假HOME = Join-Path $env:TEMP ('vsi-selftest-home-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$假目录 = Join-Path $假HOME (("$竞速数据目录名/race-$提交号") -replace '\\', '/')
$null = New-Item -ItemType Directory -Force -Path $假目录
# 摆好四类文件：残留标记、残留完整包、活连接的在途文件、死连接的陈旧在途文件
Set-Content -LiteralPath (Join-Path $假目录 'LOCAL_DONE.win32-x64') -Value '' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $假目录 'LOCAL_CANCEL') -Value '' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $假目录 'LOCAL.zip') -Value 'x' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $假目录 'LOCAL.zip.uploading') -Value 'y' -Encoding Ascii
$陈旧在途 = Join-Path $假目录 'STALE.zip.uploading'
Set-Content -LiteralPath $陈旧在途 -Value 'z' -Encoding Ascii
(Get-Item -LiteralPath $陈旧在途).LastWriteTime = (Get-Date).AddHours(-8)

$bash = 'C:\Program Files\Git\bin\bash.exe'
if (-not (Test-Path -LiteralPath $bash)) { $bash = 'bash.exe' }
$sh脚本文件 = Join-Path $env:TEMP ('vsi-selftest-prep-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh')
# 假 HOME + 真跑生成串（bash 收到的是与远端逐字相同的那段脚本）
# 两个硬约束：① .sh 绝不能带 BOM（bash 会把 BOM 当命令名首字符，报 "HOME=...: No such file or directory"）；② HOME 必须 export（否则子 sh 拿不到）
$跑 = "export HOME='" + ($假HOME -replace '\\', '/') + "`'" + "`n" + $sh载荷
[System.IO.File]::WriteAllText($sh脚本文件, $跑, [System.Text.UTF8Encoding]::new($false))
& $bash -n $sh脚本文件
断言 ($LASTEXITCODE -eq 0) '生成串通过 sh -n 语法检查'
& $bash $sh脚本文件 2>&1 | ForEach-Object { Write-Output ('    bash: ' + $_) }
$剩 = @(Get-ChildItem -LiteralPath $假目录 -Force | ForEach-Object { $_.Name })
Write-Output ('    清理后剩余: ' + ($(if ($剩.Count) { $剩 -join ', ' } else { '(空)' })))
断言 ($剩 -contains 'LOCAL.zip.uploading') '活连接的在途文件被保留'
断言 (-not ($剩 -contains 'LOCAL_DONE.win32-x64')) '残留完成标记被清掉（否则下一轮误判获胜）'
断言 (-not ($剩 -contains 'LOCAL_CANCEL')) '残留取消标记被清掉（否则本地供给被误取消）'
断言 (-not ($剩 -contains 'LOCAL.zip')) '残留完整包被清掉（本轮要重新竞速）'
断言 ($剩 -contains 'STALE.zip.uploading') '陈旧在途文件由收尾清理按龄回收（预备命令不误删，避免误伤活连接）'
# 陈旧在途文件由收尾清理按 6 小时龄回收（预备命令只保留不动），此处只核对它没被误删活文件所伤
Remove-Item -LiteralPath $sh脚本文件 -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $假HOME -Recurse -Force -ErrorAction SilentlyContinue
if ($只跑A) {
	Write-Output ''
	Write-Output ("A 段断言失败数: " + (取-断言计数).失败)
	exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
}

# ---------- B. Windows 远端改名脚本（与 local-supply.ps1 里的格式串逐字一致） ----------
Write-Output ''
Write-Output ('===== B. 远端改名脚本（真主机 ' + $主机 + '，五场景） =====')
$远端暂存目录文本 = '$env:USERPROFILE\__vsi_selftest_stage__'
$远程包名 = 'LOCAL.zip'
$完成标记名 = 'LOCAL_DONE.selftest'
$取消标记名 = 'LOCAL_CANCEL.selftest'
$改名脚本 = ('if (Test-Path -LiteralPath "{0}\{3}") {{ Write-Output "__VSI_RC__:2"; exit 2 }}; ' +
	'if (-not (Test-Path -LiteralPath "{0}\{1}.uploading")) {{ Write-Output "__VSI_RC__:3"; Write-Output "__VSI_ERR__:在途文件不在（暂存目录被并发连接重建或已被清理）"; exit 3 }}; ' +
	'try {{ ' +
	'if (Test-Path -LiteralPath "{0}\{1}") {{ if ((Get-Item -LiteralPath "{0}\{1}.uploading").Length -eq (Get-Item -LiteralPath "{0}\{1}").Length) {{ New-Item -ItemType File -Force "{0}\{2}" -ErrorAction Stop | Out-Null; Write-Output "__VSI_RC__:0"; Write-Output "__VSI_ERR__:目标已存在且长度一致，沿用已就位包并补写标记"; exit 0 }} }}; ' +
	'Move-Item -LiteralPath "{0}\{1}.uploading" -Destination "{0}\{1}" -Force -ErrorAction Stop; ' +
	'New-Item -ItemType File -Force "{0}\{2}" -ErrorAction Stop | Out-Null; Write-Output "__VSI_RC__:0" ' +
	'}} catch {{ Write-Output "__VSI_RC__:1"; Write-Output ("__VSI_ERR__:" + $_.Exception.GetType().Name + ": " + ($_.Exception.Message -replace "\s+", " ")); exit 1 }}') -f $远端暂存目录文本, $远程包名, $完成标记名, $取消标记名

# 漂移守卫：本自检的字符串是生产格式串的副本，必须逐片段回对源码；有人改了 local-supply.ps1 却没同步自检时，这里当场报错
$源码文本 = (Get-Content -LiteralPath (Join-Path $repo 'scripts\private\local-supply.ps1') -Raw)
$关键片段 = @(
	'__VSI_RC__:0', '__VSI_RC__:1', '__VSI_RC__:2', '__VSI_RC__:3',
	'__VSI_ERR__:在途文件不在', '__VSI_ERR__:" + $_.Exception.GetType().Name',
	'Move-Item -LiteralPath "{0}\{1}.uploading" -Destination "{0}\{1}" -Force',
	'New-Item -ItemType File -Force "{0}\{2}" -ErrorAction Stop',
	'__VSI_RC__\s*:\s*(\d+)'
)
foreach ($片段 in $关键片段) {
	断言 ($源码文本.Contains($片段)) ("漂移守卫：源码里仍有「$片段」")
}
断言 ($源码文本 -notmatch '退出码 -eq [23]') '源码里已无「依赖非零退出码」的判定（实测 Windows sshd 把非零码统统压平成 1）'
断言 (($改名脚本 -split '__VSI_ERR__').Count -ge 3) '改名脚本在三处失败/幂等路径都带 __VSI_ERR__ 标记'
断言 ($改名脚本 -notmatch "`{`{|\}\}") '改名脚本里无残留的 {{ }} 转义（-f 已吃干净）'

# 场景核对：先在远端摆好看板文件，再跑改名脚本，按生产同款 regex 从 stdout 取 __VSI_RC__ 结果码（不得看退出码）
function 跑-远端场景([string]$名称, [string]$布置脚本, [string]$期望结果码, [string]$期望片段) {
	$组合脚本 = '$ProgressPreference = ''SilentlyContinue'';' + "`n" + $布置脚本 + "`n" + $改名脚本 + "`n"
	$编码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($组合脚本))
	# ssh 对中文主机名会往 stderr 吐 mDNS CNAME 警告，PS 把它包成 ErrorRecord；
	# 在 Stop 偏好下这条原生 stderr 会变成终止性错误打断自检（生产代码 local-supply.ps1 顶部恒为 Continue，故不受影响）。此处同样临时放宽。
	$原EAP = $ErrorActionPreference
	$ErrorActionPreference = 'Continue'
	try {
		$输出 = @(ssh -n -o BatchMode=yes $主机 ('powershell -NoProfile -EncodedCommand ' + $编码) 2>&1)
		$ssh码 = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $原EAP
	}
	$原文 = (($输出 | ForEach-Object { [string]$_ }) -join "`n")
	$结果码 = $ssh码
	foreach ($段 in @($原文 -split '[\r\n|]+')) {
		if ($段 -match '__VSI_RC__\s*:\s*(\d+)') { $结果码 = [int]$matches[1] }
	}
	$真因 = ((($原文 -split "[`r`n|]+") | Where-Object { $_ -match '__VSI_ERR__' }) -join ' ') -replace '.*__VSI_ERR__\s*:\s*', ''
	Write-Output ('  [' + $名称 + '] 结果码=' + $结果码 + '（ssh 退出码=' + $ssh码 + '）真因=' + $(if ($真因) { $真因 } else { '(无)' }))
	断言 ([string]$结果码 -eq [string]$期望结果码) ("$名称 stdout 结果码 $结果码 == 期望 $期望结果码")
	if ($期望片段) { 断言 ($真因 -like "*$期望片段*") ("$名称 回传可读真因（含「$期望片段」）") }
	# CLIXML 进度记录垃圾必须消失（$ProgressPreference 已在 转换-远程PowerShell命令 与本自检的远端脚本开头抑制）
	$噪声 = @($输出 | ForEach-Object { [string]$_ } | Where-Object { $_ -match '#< CLIXML|<Objs Version|Preparing modules for first use' })
	断言 ($噪声.Count -eq 0) ("$名称 远端输出无 CLIXML 进度垃圾（实测 " + $噪声.Count + ' 行）')
}

# 布置脚本用双引号包裹路径：$d 内含 $env:USERPROFILE，必须由**远端** PowerShell 展开；
# 用单引号会让远端拿到字面量 $d 而把文件建到错误的相对路径上（本自检初版就踩了这坑，四场景全报「在途文件不在」）
$d = '$env:USERPROFILE\__vsi_selftest_stage__'
跑-远端场景 '源文件不在' "Remove-Item -LiteralPath `"$d`" -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force -Path `"$d`" | Out-Null" '3' '在途文件不在'
跑-远端场景 '正常改名' "Set-Content -LiteralPath `"$d\LOCAL.zip.uploading`" -Value 'abc' -Encoding Ascii" '0' ''
跑-远端场景 '取消标记在' "Set-Content -LiteralPath `"$d\LOCAL_CANCEL.selftest`" -Value '' -Encoding Ascii" '2' ''
跑-远端场景 '目标已同长' "Remove-Item -LiteralPath `"$d\LOCAL_CANCEL.selftest`" -Force -ErrorAction SilentlyContinue; Set-Content -LiteralPath `"$d\LOCAL.zip`" -Value 'abc' -Encoding Ascii; Set-Content -LiteralPath `"$d\LOCAL.zip.uploading`" -Value 'abc' -Encoding Ascii" '0' '沿用已就位包'
跑-远端场景 '目标长度不同' "Set-Content -LiteralPath `"$d\LOCAL.zip`" -Value 'old' -Encoding Ascii; Set-Content -LiteralPath `"$d\LOCAL.zip.uploading`" -Value 'newpkg' -Encoding Ascii" '0' ''
$清脚本 = 'Remove-Item -LiteralPath ($env:USERPROFILE + ''\__vsi_selftest_stage__'') -Recurse -Force -ErrorAction SilentlyContinue'
$清编码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes('$ProgressPreference = ''SilentlyContinue''; ' + $清脚本))
$原EAP2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $null = ssh -n -o BatchMode=yes $主机 ('powershell -NoProfile -EncodedCommand ' + $清编码) 2>&1 } finally { $ErrorActionPreference = $原EAP2 }
Write-Output '  远端自测暂存目录已清理'

Write-Output ''
Write-Output ("自检断言失败数累计: " + (取-断言计数).失败)
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
