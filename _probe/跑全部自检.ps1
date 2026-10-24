# _probe\跑全部自检.ps1 —— 一条命令跑完所有回归自检，给一句「全绿 / 有失败」的结论。
#
# 为什么要它：自检文件有十几个，改完模块代码后靠记忆挨个跑必然漏，而漏掉的那一个
#   往往恰好就是这次改动打破的那个。所以清单固化成代码，改完验一次全部。
#
# 为什么分「离线 / 需真机 / 需活窗口」三类：把连不上主机、没开着窗口也算成 FAIL，会让
#   「全绿」永远拿不到，人很快就学会无视这个闸门（狼来了）。所以默认只跑离线段，
#   环境类失败明确标 SKIP 并写清前提，真机/窗口段要显式开开关。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\_probe\跑全部自检.ps1                     # 离线段（默认，约 3 分钟）
#   powershell ... -File .\_probe\跑全部自检.ps1 -跳过耗时                                          # 只跑秒级的那些
#   powershell ... -File .\_probe\跑全部自检.ps1 -含真机 -主机 上科大B服务器 -端口 22               # 追加真机段（会连主机、传数据）
#   powershell ... -File .\_probe\跑全部自检.ps1 -含窗口 -窗口CDP端口 17890                         # 追加 CDP 活窗口段
#
# 判定口径：子脚本退出码非 0 = 失败；**此外**子脚本输出里出现参数绑定/解析类错误指纹也判失败——
#   这类抛出不会改退出码，脚本会接着跑到最后照报「0 失败」（见下方闸门 0，真实事故）。
param(
	[switch]$跳过耗时,
	[switch]$含真机,
	[switch]$含窗口,
	[string]$主机 = '',
	[int]$端口 = 22,
	[int]$窗口CDP端口 = 17890,
	[string]$窗口标题特征 = ''
)

$ErrorActionPreference = 'Stop'
$根 = $PSScriptRoot
. (Join-Path $根 'lib\探针公共库.ps1')

# ---------------- 闸门 0：先扫代码，再跑代码 ----------------
# 2026-10-23 的真实事故：report-point-audit 与 windows-stdin-transport-selfcheck 里各有 1 条断言，
#   消息用 + 拼接却没加括号 → + / 变量 / 尾串被解析成多余实参 → 断言在绑定阶段就抛
#   PositionalParameterNotFound → 脚本继续往下跑，最后照报「0 问题 / 全部通过」。
#   两条断言长期根本没执行过（其中一条正是「检测到在用连接就拒绝运行」的告警）。
# 这种假绿靠退出码永远抓不到，所以跑之前先用 AST 扫一遍。
# 但 AST 扫描必须排在 BOM 规范化之后：PS 5.1 读无 BOM 的 UTF-8 会把中文标识符读歪，扫描自身就会误判。
# 编辑器/工具链每次写文件都可能把 BOM 抹掉（实测改一次掉一次），所以这里直接规范化，不报错让人手修；
# 双 BOM 同样要治：它会让 param() 不再是首个 token，报出指向参数默认值那一行、与真因无关的赋值错误。
$BOM修正 = New-Object System.Collections.Generic.List[string]
foreach ($f in @(Get-ChildItem -LiteralPath $根 -Recurse -Filter *.ps1)) {
	if (补-脚本BOM -路径 $f.FullName) { $BOM修正.Add($f.Name) }
}
if ($BOM修正.Count -gt 0) { Write-Host ('已规范化 BOM ' + $BOM修正.Count + ' 个文件（补到恰好 1 个）：' + ($BOM修正 -join '、')) }

$静态命中 = @()
foreach ($f in @(Get-ChildItem -LiteralPath $根 -Recurse -Filter *.ps1)) {
	$静态命中 += @(扫-裸拼接实参 -路径 $f.FullName -命令名 '断言')
}
if ($静态命中.Count -gt 0) {
	Write-Host ('!!! 跑前静态闸门失败：有 ' + $静态命中.Count + ' 处断言把拼接消息裸写在参数位置（这些断言从未真正执行过，脚本却仍会报「0 失败」）')
	foreach ($h in $静态命中) { Write-Host ('    ' + (Split-Path $h.路径 -Leaf) + ':L' + $h.行号 + '  ' + $h.原文) }
	Write-Host "    修法：把整段消息用括号包起来 ('前半' + `$x + '后半')。"
	exit 1
}

# 脚本级抛出的指纹：出现即判失败（退出码为 0 也不算）
$错误指纹 = @(
	'positional parameter cannot be found',
	'is not recognized as the name of a cmdlet',
	'ParameterBindingException',
	'Unexpected token',
	'MethodNotFound',
	'PropertyNotFound',
	'InvalidOperation:'
)

# ---------------- 清单 ----------------
# 类别：离线 = 任何机器上都能跑；耗时 = 离线但要几十秒（起子进程/等超时）；
#       真机 = 必须连得上主机；真机可离线段 = 有降级参数，默认只跑离线那一半；窗口 = 必须开着 VS Code 窗口并留 CDP 端口
$清单 = @(
	@{ 文件 = 'lib-selftest.ps1';                        类别 = '离线';       说明 = '探针公共库自身：台账/路径/语法守卫、载荷算法与线上同源、SSH 噪声剥离、生产 stdin 同源码、裸拼接扫描' },
	@{ 文件 = 'dual-end-inflight-labeling-selftest.ps1'; 类别 = '耗时';       说明 = '两端在途命名 + 属主认领 + 发布 + 端标注（含 sh 干跑，19 秒）' },
	@{ 文件 = 'windows-stdin-transport-selfcheck.ps1';   类别 = '离线';       说明 = 'Windows stdin 通道与生产代码同源性（A-E 段离线；F 段真机需 -含真机）'; 真机参数 = @('-跑真机', '-跑全链路', '-忽略在用连接') },
	@{ 文件 = 'report-point-audit.ps1';                   类别 = '离线';       说明 = '上报点审计：每个分支都要有结论，禁吞错、禁裸 Write-Output' },
	@{ 文件 = 'format-string-audit.ps1';                  类别 = '离线';       说明 = '格式化字符串审计：占位符个数必须与实参个数对上' },
	@{ 文件 = 'download-log-selftest.ps1';                类别 = '耗时';       说明 = '下载日志口径：进度行可解析、一次中断一条消息（实跑下载器约 60 秒）' },@{ 文件 = 'stall-rebuild-selftest.ps1';               类别 = '耗时';        说明 = '停滞干净重建：零进展一个周期即重建、Range 续传点递增、停滞不算失败（伪源实跑约 35 秒）' },	@{ 文件 = 'local-supply-selftest.ps1';                类别 = '耗时';       说明 = '本地供给：完整性校验、属主判定、上传改名（起子进程约 45 秒）' },
	@{ 文件 = 'supply-concurrency-selftest.ps1';          类别 = '耗时';       说明 = '并发供给：活属主的在途文件绝不能被抢' },
	@{ 文件 = 'staging-rename-selftest.ps1';              类别 = '真机可离线段'; 说明 = '暂存改名与清理保留在途产物；A 段离线（要 git bash），B 段五场景要真主机'; 降级参数 = @('-只跑A'); 真机参数 = @('-主机') },
	@{ 文件 = 'zombie-session-selftest.ps1';              类别 = '真机可离线段'; 说明 = '僵尸会话清理判据（误杀守卫）；A 段离线，B 段实连主机只报告'; 真机参数 = @('-主机') }
)

$结果 = New-Object System.Collections.Generic.List[pscustomobject]

function 跑-JS {
	param(
		[Parameter(Mandatory = $true)][string]$文件,
		[string[]]$额外参数 = @()
	)
	$路径 = Join-Path $根 $文件
	if (-not (Test-Path -LiteralPath $路径)) { Write-Host ('MISS             ' + $文件 + '（清单里有、磁盘上没有）'); return }
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	$out = @(& node $路径 @额外参数 2>&1 | ForEach-Object { [string]$_ })
	$码 = $LASTEXITCODE
	$sw.Stop()
	$抛出行 = @($out | Where-Object { $_ -match 'ReferenceError|TypeError|SyntaxError|UnhandledPromiseRejection' } | Select-Object -First 2)
	$判定 = if (($码 -eq 0) -and ($抛出行.Count -eq 0)) { 'PASS' } else { 'FAIL' }
	Write-Host ('{0,-16} {1,-45} 退出码 {2}  {3,6:N1} 秒' -f $判定, $文件, $码, $sw.Elapsed.TotalSeconds)
	@($out | Select-Object -Last 2) | ForEach-Object { if ([string]$_ -ne '') { Write-Host ('        ' + ([string]$_).Trim()) } }
	foreach ($行 in $抛出行) { Write-Host ('      ! 抛出: ' + $行.Trim()) }
	$script:结果.Add([pscustomobject]@{ 文件 = $文件; 判定 = $判定; 退出码 = $码; 秒 = [math]::Round($sw.Elapsed.TotalSeconds, 1); 标注 = 'JS' })
}

function 跑-一项 {
	param(
		[Parameter(Mandatory = $true)][string]$文件,
		[string[]]$额外参数 = @(),
		[string]$标注 = ''
	)
	$路径 = Join-Path $根 $文件
	if (-not (Test-Path -LiteralPath $路径)) {
		Write-Host ('MISS  ' + $文件 + '（清单里有、磁盘上没有：清单该同步了）')
		$script:结果.Add([pscustomobject]@{ 文件 = $文件; 判定 = 'MISS'; 退出码 = 999; 秒 = 0; 标注 = '文件缺失' })
		return
	}
	$sw = [System.Diagnostics.Stopwatch]::StartNew()
	$参数 = @('-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', $路径) + $额外参数
	$out = @(& powershell.exe $参数 2>&1 | ForEach-Object { [string]$_ })
	$码 = $LASTEXITCODE
	$sw.Stop()
	$失败行 = @($out | Where-Object { $_ -match '^(FAIL|\s*\[失败\])' } | Select-Object -First 3)
	$抛出行 = @($out | Where-Object { $一 = $_; @($错误指纹 | Where-Object { $一.Contains($_) }).Count -gt 0 } | Select-Object -First 2)
	$跳过行 = @($out | Where-Object { $_ -match '^SKIP|已跳过' } | Select-Object -First 1)
	$判定行 = @($out | Where-Object { $_ -match '=====.*(汇总|通过|失败)|失败数|问题总数|全部通过' } | Select-Object -Last 2)
	$判定 = 'PASS'
	if (($码 -ne 0) -or ($抛出行.Count -gt 0)) { $判定 = 'FAIL' }
	elseif ($跳过行.Count -gt 0) { $判定 = 'PASS(部分跳过)' }
	Write-Host ('{0,-16} {1,-45} 退出码 {2}  {3,6:N1} 秒 {4}' -f $判定, $文件, $码, $sw.Elapsed.TotalSeconds, $标注)
	foreach ($行 in $判定行) { Write-Host ('        ' + $行.Trim()) }
	foreach ($行 in $跳过行) { Write-Host ('      ~ ' + $行.Trim()) }
	foreach ($行 in $失败行) { Write-Host ('      ! ' + $行.Trim()) }
	foreach ($行 in $抛出行) { Write-Host ('      ! 脚本级抛出（退出码为 0 也不算通过）: ' + $行.Trim()) }
	$script:结果.Add([pscustomobject]@{ 文件 = $文件; 判定 = $判定; 退出码 = $码; 秒 = [math]::Round($sw.Elapsed.TotalSeconds, 1); 标注 = $标注 })
}

foreach ($项 in $清单) {
	$类别 = $项.类别
	if (($类别 -like '*耗时*') -and $跳过耗时) { Write-Host ('SKIP             ' + $项.文件.PadRight(45) + '（-跳过耗时）'); continue }
	# 真机参数：只有给了 -含真机 且 -主机 才追加（真机段会往主机上写数据/起进程，不得默认执行）
	$追加 = @()
	$带真机 = $false
	if ($含真机 -and $主机 -ne '' -and $项.真机参数) {
		$带真机 = $true
		if ($类别 -eq 'windows-stdin-transport-selfcheck.ps1' -or $项.文件 -eq 'windows-stdin-transport-selfcheck.ps1') {
			$追加 = $项.真机参数 + @('-主机', $主机, '-端口', $端口)
		} else {
			$追加 = @($项.真机参数) + @($主机)
		}
	}
	if ($类别 -eq '离线') { 跑-一项 -文件 $项.文件 -额外参数 $追加 -标注 $(if ($带真机) { '(含真机段)' } else { '' }); continue }
	if ($类别 -eq '耗时') { 跑-一项 -文件 $项.文件 -额外参数 $追加 -标注 '(耗时用例)'; continue }
	if ($类别 -eq '真机可离线段') {
		if ($带真机) {
			跑-一项 -文件 $项.文件 -额外参数 $追加 -标注 '(真机段)'
		} elseif ($项.降级参数) {
			跑-一项 -文件 $项.文件 -额外参数 @($项.降级参数) -标注 '(只跑离线段；真机段要 -含真机 -主机 <名>)'
		} else {
			跑-一项 -文件 $项.文件 -标注 '(默认跑；连不上主机会自行降级为 SKIP)'
		}
		continue
	}
	Write-Host ('SKIP             ' + $项.文件.PadRight(45) + '（需要 ' + $类别 + '，见文件头）')
}

# ---------------- JS 侧 ----------------
# rescue-detection-selftest.js 纯离线；cdp-selftest.js 要活窗口 + CDP 端口，默认跳过
if (Get-Command node -ErrorAction SilentlyContinue) {
	跑-JS -文件 'rescue-detection-selftest.js'
	if ($含窗口) {
		$参 = @("$窗口CDP端口")
		if ($窗口标题特征 -ne '') { $参 += $窗口标题特征 }
		跑-JS -文件 'cdp-selftest.js' -额外参数 $参
	} else {
		Write-Host ('SKIP             cdp-selftest.js                              （需活窗口 + CDP 端口，用 -含窗口 打开）')
	}
} else {
	Write-Host 'SKIP             JS 自检（本机没有 node）'
}

Write-Host ''
$坏 = @($结果 | Where-Object { $_.判定 -eq 'FAIL' -or $_.判定 -eq 'MISS' })
$跳 = @($结果 | Where-Object { $_.判定 -eq 'PASS(部分跳过)' })
Write-Host ('===== 全部自检：跑了 ' + $结果.Count + ' 项，失败 ' + $坏.Count + ' 项，部分跳过 ' + $跳.Count + ' 项，总耗时 ' + [math]::Round((@($结果 | Measure-Object -Property 秒 -Sum).Sum), 1) + ' 秒 =====')
if ($坏.Count -gt 0) {
	$坏 | ForEach-Object { Write-Host ('  失败：' + $_.文件 + '（' + $_.判定 + '，退出码 ' + $_.退出码 + '）') }
	Write-Host '  （真机/窗口段没跑的不算失败，也不算通过——要它们必须给环境，见 -含真机 / -含窗口）'
	exit 1
}
Write-Host '全部通过。（部分跳过 = 环境不可用，不是回归）'
exit 0
