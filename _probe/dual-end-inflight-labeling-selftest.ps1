# 回归自检：两端下载的「私有在途名 + 完成才发布」与「消息必带端标注」
#
# 守住的两个线上缺陷（2026-10-23 真机取证，主机 上科大A服务器_张天夫，用户表现为「一直卡在下载、日志里两条第 1 次下载中断」）：
#   缺陷C（共写一个成品名）：Remote-SSH 超时重试会再起一条远端会话，两条会话都直接往 REMOTE.zip 写
#     （暂存目录名只按提交号、不带会话唯一性）→ 实测刷出 20+ 条
#     `Exception calling "Open" ... because it is being used by another process`，两边在同一续传点上反复失败。
#     修法：每会话私有在途名 <包名>.downloading-<PID> → 下载完整后改名发布成品 → 再写完成标记（顺序不可颠倒）。
#   缺陷E（消息不带端标注）：本地供给的行有 [本地供给-产物名] 前缀，远端的行经单会话 stdout 回来**没有任何标注**，
#     两端的进度/中断行交织在同一份 preconnect 日志里，只能靠「续传点字节数不同」猜哪条是哪端；
#     两条各自独立时钟打出的「第 1 次下载中断」紧挨着出现，极易误读成同一件事报了两遍。
#     修法：远端下载器每一行都带 [远程自下载-产物名]，与本地侧对称，不再需要靠字节数反推。
#   附带守住（缺陷B）：认领遗留半成品必须按「属主 PID 是否存活」判归属——实测曾把活属主已下 42/84MB 的半成品改名搬走。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File _probe\dual-end-inflight-labeling-selftest.ps1
#   可选：-跳过sh   跳过 git bash 侧（Linux 场景）
#   本自检全部跑在临时目录 + 桩下载函数上，不联网、不连远端、不碰用户的连接与带宽。

param(
	[switch]$跳过sh
)

$ErrorActionPreference = 'Stop'
$仓库根 = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$扩展根 = Join-Path $仓库根 '接管远程服务器安装扩展'
$私有目录 = Join-Path $扩展根 'module\private'
$common路径 = Join-Path $私有目录 'remote-install-common.ps1'
$供给路径 = Join-Path $私有目录 'local-supply.ps1'
$sh路径 = Join-Path $私有目录 'remote-install-linux.sh'
$编排路径 = Join-Path $私有目录 '接管编排脚本模板.sh'
$psm1路径 = Join-Path $扩展根 'module\Install-VSCodeRemoteServer.psm1'

. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK   ' -失败前缀 'FAIL '
# 断言台账（通过/失败计数 + 失败清单）全部交给公共库；这里只留薄转发保持原调用签名与三参顺序（说明在前）
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

$common正文 = Get-Content -LiteralPath $common路径 -Raw -Encoding UTF8
$供给正文 = Get-Content -LiteralPath $供给路径 -Raw -Encoding UTF8
$sh正文 = Get-Content -LiteralPath $sh路径 -Raw -Encoding UTF8
$编排正文 = Get-Content -LiteralPath $编排路径 -Raw -Encoding UTF8
$模块正文 = Get-Content -LiteralPath $psm1路径 -Raw -Encoding UTF8

# 取某个 PowerShell 函数的完整源码（含注释头之后的函数体），用 AST 而不是行号猜，避免改动后错位
function 取-函数源码([System.Management.Automation.Language.ScriptBlockAst]$根AST, [string]$函数名) {
	$fn = $根AST.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -eq $函数名) }, $true) | Select-Object -First 1
	if ($null -eq $fn) { return $null }
	return $fn.Extent.Text
}

Write-Output '===== A. 静态：两端文案与并发约定 ====='
$commonAST = $null; $commonErr = $null; $commonTok = $null
$commonAST = [System.Management.Automation.Language.Parser]::ParseFile($common路径, [ref]$commonTok, [ref]$commonErr)
断言 'A0 remote-install-common.ps1 语法可解析' ($commonErr.Count -eq 0) (($commonErr | ForEach-Object { $_.Message }) -join '；')

# A1 标注覆盖：远端下载器每一行都必须带端标注（进度行 + 中断行 + 起始行）
$下载器源 = 取-函数源码 $commonAST '通过HTTP断点续传下载'
断言 'A1a 远端下载器有 -端标注 参数（默认 [远程自下载-服务端]）' ($下载器源 -match "\[string\]\`$端标注\s*=\s*'\[远程自下载-服务端\]'") ''
$下载器发射行 = @($下载器源 -split "`r?`n" | Where-Object { $_ -match 'Write-Host' })
$无标注行 = @($下载器发射行 | Where-Object { ($_ -match '下载进度|下载中断|开始下载|断点续传') -and ($_ -notmatch '\$端标注') })
断言 'A1b 远端下载器所有进度/中断/起始行都引用 $端标注' ($无标注行.Count -eq 0) ('无标注行 ' + $无标注行.Count + ' 处：' + (($无标注行 | ForEach-Object { $_.Trim() }) -join ' ⏎ '))
断言 'A1c 竞速作业给下载器传了按产物名生成的端标注' ($common正文 -match "\`$端标注 = '\[远程自下载-\{0\}\]' -f \`$产物名") ''
断言 'A1d 竞速作业把端标注传给了下载器' ($common正文 -match '通过HTTP断点续传下载 -下载地址 \$下载地址 -目标路径 \$远程在途路径 -端标注 \$端标注') ''
断言 'A1e 竞速转发不叠加第二层前缀（行内已自带标注）' ($common正文 -match "Receive-Job -Job \`$下载作业 \| ForEach-Object \{ Write-Host \('\{0\}' -f \`$_\) \}") ''
断言 'A1f CLI 整包下载补装路径也带端标注（[远程自下载-CLI]）' ((@($common正文 -split "`r?`n" | Where-Object { $_ -match 'Write-Host' -and $_ -match 'CLI 下载中断|开始下载远程 CLI' -and $_ -notmatch '远程自下载-CLI' }).Count) -eq 0) ''
# 本地侧：前缀由主模块的转发处统一加，二者必须成对存在
断言 'A1g 本地侧行由主模块转发时统一加 [本地供给-产物名] 前缀' ($模块正文 -match "'\[本地供给-\{0\}\] \{1\}'") ''
断言 'A1h 竞速会话级消息也写明是哪一端（远端已有完整成品/并发会话/认领遗留）' ((@($common正文 -split "`r?`n" | Where-Object { $_ -match 'Write-Host' -and $_ -match '远端已有完整自下载成品|另一条并发会话也在自下载|认领遗留半成品续传' -and $_ -notmatch '远程自下载-' }).Count) -eq 0) ''
# sh 侧：远端唯一可见的下载消息就是心跳，必须带端标注
$sh心跳行 = @($sh正文 -split "`r?`n" | Where-Object { $_ -match '远程下载进度' })
断言 'A1i sh 心跳行带 [远程自下载-产物名] 端标注' ((@($sh心跳行 | Where-Object { $_ -notmatch '\[远程自下载-\$1\]' }).Count) -eq 0) ('实测：' + (($sh心跳行 | ForEach-Object { $_.Trim() }) -join ' ⏎ '))
断言 'A1j sh 两个下载函数与前台补装的消息都带端标注' ((@($sh正文 -split "`r?`n" | Where-Object { $_ -match '^\s*(log|log_event) ' -and $_ -match '开始下载|下载源|下载失败|下载中断|下载完成|已发布成品' -and $_ -notmatch '远程自下载-' }).Count) -eq 0) ''

# A2 私有在途名（Windows）
断言 'A2a 远端在途名 = <成品名>.downloading-<PID>' ($common正文 -match "\`$远程在途路径 = \(\`$远程包路径 \+ '\.downloading-' \+ \`$PID\)") ''
断言 'A2b 远端下载写的是在途名而不是成品名' ($common正文 -match '通过HTTP断点续传下载 -下载地址 \$下载地址 -目标路径 \$远程在途路径 -端标注') ''
$发布位置 = $common正文.IndexOf('Move-Item -LiteralPath $远程在途路径 -Destination $远程包路径')
$标记位置 = $common正文.IndexOf('New-Item -ItemType File -Force $远程完成标记 | Out-Null', $发布位置)
断言 'A2c 发布（改名到成品名）先于写完成标记（同一作业体内）' (($发布位置 -ge 0) -and ($标记位置 -gt $发布位置)) ('改名位置 ' + $发布位置 + '，其后最近的标记写入位置 ' + $标记位置)
# 竞速作业体内部的顺序（作业体是 Start-Job 的脚本块，必须就地校验：先改名发布 → 再写标记 → 最后报完成）
断言 'A2c2 作业体内三步顺序：改名 → 写完成标记 → 报完成' ($common正文 -match '(?s)Move-Item -LiteralPath \$远程在途路径 -Destination \$远程包路径.*?New-Item -ItemType File -Force \$远程完成标记 \| Out-Null.*?远程自下载完成。') ''
# 本地侧（缺陷B：按属主 PID 判归属，活属主一概不碰）
断言 'A2d 本地供给同样用 .downloading-<PID> 私有在途名' ($供给正文 -match "'\.downloading-' \+ \`$PID") ''
断言 'A2e 本地供给有属主存活判定（测-属主存活）' ($供给正文 -match 'function 测-属主存活') ''
断言 'A2f 认领前先按属主存活跳过，绝不搬活属主的半成品' ($供给正文 -match 'if \(测-属主存活 \$候\.FullName\) \{ continue \}') ''
断言 'A2g "他方持有"判据含属主存活（不只看句柄）' ($供给正文 -match '\(测-文件被占用 \$候\.FullName\) -or \(测-属主存活 \$候\.FullName\)') ''
# Windows 侧前台 CLI 补装也得是私有名（此前是数据目录下的固定名 vscode-cli-<名>.zip，同样会被并发会话抢）
断言 'A2h Windows 前台 CLI 补装写私有在途名' ($common正文 -match "'vscode-cli-\{0\}\.zip\.downloading-\{1\}'") ''

# A3 私有在途名（sh）+ 发布顺序
断言 'A3a sh 两个下载函数都用 IN_FLIGHT="${PKG_OUT}.downloading-$$"' ((@(Select-String -InputObject $sh正文 -Pattern 'IN_FLIGHT="\$\{PKG_OUT\}\.downloading-\$\$"' -AllMatches).Matches.Count) -ge 2) ''
$sh下载目标 = @([regex]::Matches($sh正文, 'download_file "[^"]*" "\$([A-Za-z_]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
断言 'A3b sh 所有下载目标变量都是每会话私有在途名' ((($sh下载目标 | Where-Object { $_ -notin @('IN_FLIGHT', 'CLI_TAR') }).Count -eq 0) -and ($sh正文 -match 'IN_FLIGHT="\$\{PKG_OUT\}\.downloading-\$\$"') -and ($sh正文 -match 'CLI_TAR="\$DATA_DIR/vscode-cli-\$COMMIT\.tar\.gz\.downloading-\$\$"')) ('实测下载目标变量：' + (($sh下载目标) -join ', '))
$sh改名 = $sh正文.IndexOf('mv -f "$IN_FLIGHT" "$PKG_OUT"')
$sh标记 = $sh正文.IndexOf('touch "$DONE_MARK"')
断言 'A3c sh 两个下载函数都是先改名发布再 touch 完成标记' (([regex]::Matches($sh正文, '(?s)elif mv -f "\$IN_FLIGHT" "\$PKG_OUT".*?touch "\$DONE_MARK"').Count) -ge 2) ('实测命中 ' + ([regex]::Matches($sh正文, '(?s)elif mv -f "\$IN_FLIGHT" "\$PKG_OUT".*?touch "\$DONE_MARK"').Count) + ' 处（应含 server 与 CLI 各一）')
断言 'A3d sh 心跳改看在途名（否则成品名要到发布才出现，进度恒为 0）' ($sh正文 -match 'for RF in "\$2" "\$2"\.downloading-\*') ''

# A4 在途文件的保留：三处清理都必须放行 *.downloading-*
断言 'A4a Windows 收尾清理保留 6 小时内的在途文件（uploading 与 downloading）' ($common正文 -match "\(\`$项\.Name -like '\*\.uploading' -or \`$项\.Name -like '\*\.downloading-\*'\)") ''
断言 'A4b sh cleanup_staging 保留 *.downloading-*' ($sh正文 -match '\*\.downloading-\*\)\s*\r?\n\s*continue') ''
断言 'A4c sh cleanup_staging 按龄回收陈旧在途文件' ($sh正文 -match "-name '\*\.downloading-\*' -mmin \+360") ''
断言 'A4d 编排模板收尾清理保留 *.downloading-*' ($编排正文 -match '\*\.downloading-\*\)\s*\r?\n\s*continue') ''
断言 'A4e Linux 竞速预备命令保留 *.downloading-*' ($模块正文 -match '\*\.downloading-\*\) continue;;') ''

# A5 「存在即视为完成」快路径（并发会话不再重复下载 190MB）
断言 'A5a Windows：远端已有完整成品时直接判远程获胜（完整性用 EOCD 快检）' ($common正文 -match '测试-压缩包完整 \$远程包路径') ''
断言 'A5b Windows：不完整（旧版截断半成品）仍会删掉重下' ($common正文 -match 'if \(Test-Path -LiteralPath \$远程包路径\) \{\r?\n\s*Remove-Item -LiteralPath \$远程包路径') ''
断言 'A5c sh：race_artifact 用 gzip -t 判成品完整后直接获胜' ($sh正文 -match 'if \[ -s "\$2" \] && gzip -t "\$2" 2>/dev/null; then') ''
断言 'A5d sh 快路径也通知本地供给收手（touch 取消标记）' ($sh正文 -match 'touch "\$3"\s*\r?\n\s*touch "\$6"') ''

# A6 诚实措辞（缺陷D）：单源不得说「按序轮试」，分块不得说成传输必需
$供给源清单行 = @($供给正文 -split "`r?`n" | Where-Object { $_ -match '本地下载源' })
断言 'A6a 本地供给单源时说「唯一，无备源可换」' ((@($供给源清单行 | Where-Object { $_ -match '唯一，无备源可换' }).Count) -ge 1) ('实测：' + (($供给源清单行 | ForEach-Object { $_.Trim() }) -join ' ⏎ '))
断言 'A6b 多源时才说「按序轮试」（且带源数）' ((@($供给源清单行 | Where-Object { $_ -match '共 \{0\} 个，按序轮试' }).Count) -ge 1) ''
断言 'A6c 分块说明写清两个真实理由（行长限界 + 可校验的拼接不变式）' (($模块正文 -match '每行行长') -and ($模块正文 -match '拼接不变式')) ''
断言 'A6d psm1 分块日志说明远端剔空白后整段解码（分块非必需）' ($模块正文 -match '分块为稳健选择而非传输必需') ''

Write-Output ''
Write-Output '===== B. 真跑 Windows 竞速函数（桩下载，临时目录） ====='
# 只把需要的两个函数定义进本会话：remote-install-common.ps1 的顶层是完整安装流程，整文件点源会在本机真跑安装
$测试压缩包完整源 = 取-函数源码 $commonAST '测试-压缩包完整'
$竞速单产物源 = 取-函数源码 $commonAST '竞速-单个产物'
$清理暂存源 = 取-函数源码 $commonAST '清理-竞速暂存目录'
断言 'B0 三个待测函数都从 AST 提取出来了' (($null -ne $测试压缩包完整源) -and ($null -ne $竞速单产物源) -and ($null -ne $清理暂存源)) ''
Invoke-Expression $测试压缩包完整源
Invoke-Expression $竞速单产物源
Invoke-Expression $清理暂存源

# 桩下载函数体：会被竞速函数按文本注入后台作业（与生产同一机制），写死一个假包并带上端标注打一行
$桩下载函数体 = @'
param([string]$下载地址, [string]$目标路径, [string]$端标注)
Set-Content -LiteralPath $目标路径 -Value ('Z' * 40) -Encoding Ascii -NoNewline
Write-Host ('{0} 桩下载完成：{1} 字节已落 {2}' -f $端标注, 40, (Split-Path $目标路径 -Leaf))
'@
# Write-Host（信息流 6）与函数返回值（成功流 1）分开收：合并后按类型区分。
# 注意：不能用 `-is [pscustomobject]` 判定返回值——PS 里管道中任何对象都被 PSObject 包装，该判定对信息记录也为真
#（初版就因此把所有行当返回值丢掉、B 段全判空），改用「有无获胜方属性」判别
function 跑-竞速并收输出 {
	param([string]$产物名, [string]$包路径, [string]$完成标记, [string]$取消标记)
	$全 = & {
		竞速-单个产物 -产物名 $产物名 -下载地址 'http://stub/pkg' -远程包路径 $包路径 -远程完成标记 $完成标记 `
			-本地包路径 ($包路径 + '.LOCAL') -本地完成标记 ($完成标记 + '.LOCAL_DONE') -本地取消标记 $取消标记 `
			-下载函数文本 $桩下载函数体
	} 6>&1
	$结果 = $全 | Where-Object { $null -ne $_ -and ($_.PSObject.Properties.Name -contains '获胜方') } | Select-Object -First 1
	$行 = @($全 | Where-Object { $null -eq $_ -or -not ($_.PSObject.Properties.Name -contains '获胜方') } | ForEach-Object { [string]$_ })
	return @{ 结果 = $结果; 行 = $行; 文本 = ($行 -join "`n") }
}
function 取-空闲PID {
	$候 = 990000
	while ((Get-Process -Id $候 -ErrorAction SilentlyContinue)) { $候++ }
	return $候
}

$沙盒 = Join-Path $env:TEMP ('vsi-race-selftest-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $沙盒 | Out-Null
try {
	# ---- B1 正常路径：私有在途名 → 改名发布 → 写标记，且每行带端标注 ----
	Write-Output '--- B1 正常路径：私有在途名 → 发布 → 标记 ---'
	$包1 = Join-Path $沙盒 'REMOTE_TEST.zip'
	$标记1 = Join-Path $沙盒 'REMOTE_TEST_DONE'
	$r1 = 跑-竞速并收输出 '测试产物' $包1 $标记1 (Join-Path $沙盒 'LOCAL_TEST_CANCEL')
	断言 'B1a 竞速判远程自下载获胜' ([string]$r1.结果.获胜方 -eq '远程自下载') ('实际：' + [string]$r1.结果.获胜方 + '；输出：' + $r1.文本)
	断言 'B1b 成品名已发布且内容是桩写的包' ((Test-Path -LiteralPath $包1) -and ((Get-Item -LiteralPath $包1).Length -eq 40)) ''
	断言 'B1c 完成标记已写（发布之后）' (Test-Path -LiteralPath $标记1) ''
	断言 'B1d 私有在途文件没有残渣（已改名发布）' (@(Get-ChildItem -LiteralPath $沙盒 -Filter 'REMOTE_TEST.zip.downloading-*' -Force).Count -eq 0) ''
	断言 'B1e 桩下载行带上了按产物名生成的端标注' ($r1.文本 -match '\[远程自下载-测试产物\] 桩下载完成') ('实际输出：' + $r1.文本)
	断言 'B1f 发布与完成消息同样带端标注' (($r1.文本 -match '\[远程自下载-测试产物\] 下载完成，已改名发布成品') -and ($r1.文本 -match '\[远程自下载-测试产物\] 远程自下载完成')) ''
	断言 'B1g 竞速决出行写明用哪个包' ($r1.文本 -match '竞速决出：测试产物 由远程自下载获胜（用包 REMOTE_TEST\.zip）') ''

	# ---- B2 远端已有完整成品：直接获胜，不再下一轮 ----
	Write-Output ''
	Write-Output '--- B2 远端已有完整成品：存在即视为完成 ---'
	$沙盒2 = Join-Path $env:TEMP ('vsi-race-selftest-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $沙盒2 | Out-Null
	$包2 = Join-Path $沙盒2 'REMOTE_TEST.zip'
	$源文件 = Join-Path $沙盒2 '内容.txt'
	Set-Content -LiteralPath $源文件 -Value ('真包内容' * 20) -Encoding UTF8
	Compress-Archive -LiteralPath $源文件 -DestinationPath $包2 -Force
	$包2哈希前 = (Get-FileHash -LiteralPath $包2 -Algorithm SHA256).Hash
	$r2 = 跑-竞速并收输出 '测试产物' $包2 (Join-Path $沙盒2 'REMOTE_TEST_DONE') (Join-Path $沙盒2 'LOCAL_TEST_CANCEL')
	断言 'B2a 完整成品直接判远程自下载获胜' ([string]$r2.结果.获胜方 -eq '远程自下载') ('实际：' + [string]$r2.结果.获胜方)
	断言 'B2b 明确报出「已有完整成品，跳过重复下载」' ($r2.文本 -match '\[远程自下载-测试产物\] 远端已有完整自下载成品（\d+ 字节）') ('实际输出：' + $r2.文本)
	断言 'B2c 没有起下载作业（日志里没有并行竞速那一行）' ($r2.文本 -notmatch '竞速：远程自下载与本地下载\+上传并行') ''
	断言 'B2d 成品一个字节都没动（没被删了重下）' ((Get-FileHash -LiteralPath $包2 -Algorithm SHA256).Hash -eq $包2哈希前) ''

	# ---- B3 截断半成品（旧版遗留）不得被当完整包，必须删掉重下 ----
	Write-Output ''
	Write-Output '--- B3 旧版遗留的截断半成品：不当完整包用 ---'
	$沙盒3 = Join-Path $env:TEMP ('vsi-race-selftest-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $沙盒3 | Out-Null
	$包3 = Join-Path $沙盒3 'REMOTE_TEST.zip'
	Set-Content -LiteralPath $包3 -Value ('P' * 12345) -Encoding Ascii -NoNewline
	$r3 = 跑-竞速并收输出 '测试产物' $包3 (Join-Path $沙盒3 'REMOTE_TEST_DONE') (Join-Path $沙盒3 'LOCAL_TEST_CANCEL')
	断言 'B3a 截断包不走快路径（照常起下载作业）' ($r3.文本 -match '竞速：远程自下载与本地下载\+上传并行') ('实际输出：' + $r3.文本)
	断言 'B3b 最终成品是桩重新写的完整包（40 字节，不是 12345）' ((Get-Item -LiteralPath $包3).Length -eq 40) ('实际 ' + (Get-Item -LiteralPath $包3).Length + ' 字节')

	# ---- B4 活属主的在途文件：绝对不认领、不删除 ----
	Write-Output ''
	Write-Output '--- B4 另一条并发会话（活属主）的在途文件不受扰 ---'
	$沙盒4 = Join-Path $env:TEMP ('vsi-race-selftest-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $沙盒4 | Out-Null
	$假属主 = Start-Process powershell -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 180' -NoNewWindow -PassThru
	$活属主文件 = Join-Path $沙盒4 ('REMOTE_TEST.zip.downloading-' + $假属主.Id)
	Set-Content -LiteralPath $活属主文件 -Value ('L' * 500) -Encoding Ascii -NoNewline
	$包4 = Join-Path $沙盒4 'REMOTE_TEST.zip'
	try {
		$r4 = 跑-竞速并收输出 '测试产物' $包4 (Join-Path $沙盒4 'REMOTE_TEST_DONE') (Join-Path $沙盒4 'LOCAL_TEST_CANCEL')
		断言 'B4a 活属主的在途文件原样留存（500 字节未被搬走）' (((Test-Path -LiteralPath $活属主文件)) -and ((Get-Item -LiteralPath $活属主文件).Length -eq 500)) $(if (Test-Path -LiteralPath $活属主文件) { ('实际 ' + (Get-Item -LiteralPath $活属主文件).Length + ' 字节') } else { '文件已消失' })
		断言 'B4b 明确报出另一条并发会话在自下载（含属主 PID）' ($r4.文本 -match ('另一条并发会话也在自下载同一产物（属主 PID ' + $假属主.Id + '，已传 500 字节）')) ('实际输出：' + $r4.文本)
		断言 'B4c 没有把活属主的文件当遗留认领走' ($r4.文本 -notmatch '认领遗留半成品') ''
		断言 'B4d 本会话用自己的在途文件照样跑完并获胜' ([string]$r4.结果.获胜方 -eq '远程自下载') ('实际：' + [string]$r4.结果.获胜方)
	} finally {
		Stop-Process -Id $假属主.Id -Force -ErrorAction SilentlyContinue
	}

	# ---- B5 死属主遗留：认领最大的一份，其余删掉 ----
	Write-Output ''
	Write-Output '--- B5 死属主遗留半成品：认领最大的一份 ---'
	$沙盒5 = Join-Path $env:TEMP ('vsi-race-selftest-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $沙盒5 | Out-Null
	$死PID1 = 取-空闲PID
	$死PID2 = $死PID1 + 1
	while ((Get-Process -Id $死PID2 -ErrorAction SilentlyContinue)) { $死PID2++ }
	$包5 = Join-Path $沙盒5 'REMOTE_TEST.zip'
	Set-Content -LiteralPath ($包5 + '.downloading-' + $死PID1) -Value ('D' * 700) -Encoding Ascii -NoNewline
	Set-Content -LiteralPath ($包5 + '.downloading-' + $死PID2) -Value ('d' * 300) -Encoding Ascii -NoNewline
	$r5 = 跑-竞速并收输出 '测试产物' $包5 (Join-Path $沙盒5 'REMOTE_TEST_DONE') (Join-Path $沙盒5 'LOCAL_TEST_CANCEL')
	断言 'B5a 认领最大的一份遗留并写明属主已消失' ($r5.文本 -match ('认领遗留半成品续传：700 字节（原名 REMOTE_TEST\.zip\.downloading-' + $死PID1 + '，属主 PID ' + $死PID1 + ' 已消失）')) ('实际输出：' + $r5.文本)
	断言 'B5b 多余的死属主副本被清掉（同产物不留两份）' (-not (Test-Path -LiteralPath ($包5 + '.downloading-' + $死PID2))) ''
	断言 'B5c 被认领的那份也已随发布消失' (@(Get-ChildItem -LiteralPath $沙盒5 -Filter 'REMOTE_TEST.zip.downloading-*' -Force).Count -eq 0) ''

	# ---- B6 收尾清理：在途文件按名型与年龄放行 ----
	Write-Output ''
	Write-Output '--- B6 收尾清理保留在途、按龄回收 ---'
	$沙盒6 = Join-Path $env:TEMP ('vsi-race-selftest-' + [Guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Force -Path $沙盒6 | Out-Null
	$新在途 = Join-Path $沙盒6 'LOCAL.zip.downloading-12345'
	$旧在途 = Join-Path $沙盒6 'LOCAL.zip.downloading-23456'
	$上传中 = Join-Path $沙盒6 'SERVER.zip.uploading'
	Set-Content -LiteralPath $新在途, $旧在途, $上传中 -Value 'x' -Encoding Ascii
	Set-Content -LiteralPath (Join-Path $沙盒6 'REMOTE_TEST_DONE') -Value '' -Encoding Ascii
	$陈旧时刻 = (Get-Date).AddHours(-7)
	(Get-Item -LiteralPath $旧在途).LastWriteTime = $陈旧时刻
	清理-竞速暂存目录 -暂存目录 $沙盒6
	断言 'B6a 新鲜在途文件（downloading）被保留' (Test-Path -LiteralPath $新在途) ''
	断言 'B6b 新鲜上传文件（uploading）被保留' (Test-Path -LiteralPath $上传中) ''
	断言 'B6c 超过 6 小时未动的在途文件被回收' (-not (Test-Path -LiteralPath $旧在途)) ''
	断言 'B6d 残留完成标记被清掉（防假获胜）' (-not (Test-Path -LiteralPath (Join-Path $沙盒6 'REMOTE_TEST_DONE'))) ''

	# ---- B7 生产注入路径：真下载器经 .Definition 文本化重建后仍带 -端标注 ----
	# B1~B6 用的是桩函数体，没覆盖生产那条：竞速作业是用 (Get-Command '通过HTTP断点续传下载').Definition
	# 把函数体文本化后在独立进程里 Invoke-Expression 重建。新增形参后必须验证注入仍成立，
	# 否则作业里会报「找不到接受实参 -端标注 的位置形式参数」，远端下载当场死。
	Write-Output ''
	Write-Output '--- B7 真下载器注入后台作业后端标注仍生效 ---'
	$真下载器源 = 取-函数源码 $commonAST '通过HTTP断点续传下载'
	Invoke-Expression $真下载器源
	$定义文本 = (Get-Command '通过HTTP断点续传下载').Definition
	断言 'B7a 真下载器的 Definition 文本里带着端标注形参（注入后不会丢）' ($定义文本 -match '\$端标注') ''
	$标注文本 = '[远程自下载-B7测试产物]'
	$B7探测文件 = Join-Path $env:TEMP 'vsi-b7-label-probe.zip'
	Remove-Item -LiteralPath $B7探测文件 -Force -ErrorAction SilentlyContinue
	$注入作业 = Start-Job -ArgumentList $定义文本, $标注文本, $B7探测文件 -ScriptBlock {
		param($定义文本, $标注文本, $探测文件)
		$ErrorActionPreference = 'Continue'
		Invoke-Expression ('function 通过HTTP断点续传下载 { ' + $定义文本 + ' }')
		$形参集 = ((Get-Command '通过HTTP断点续传下载').Parameters.Keys) -join ','
		Write-Output ('B7_PARAMS=' + $形参集)
		# 对必连不上的地址跑：下载器无限重试，外面收够行后会 Stop-Job
		通过HTTP断点续传下载 -下载地址 'https://127.0.0.1:9/nope.zip' -目标路径 $探测文件 -端标注 $标注文本
	}
	$止B7 = [DateTime]::Now.AddSeconds(25)
	$作业文本 = ''
	while ([DateTime]::Now -lt $止B7) {
		# 必须跨轮**累加**：下载器用的是 Write-Host（作业的信息流），每轮 Receive-Job 只回增量，
		# 用覆盖式赋值会在最后一轮拿到空串，把实测到手的证据判成缺失（初版就栽在这里）
		$作业行 = @(Receive-Job -Job $注入作业 -ErrorAction SilentlyContinue 6>&1 | ForEach-Object { [string]$_ })
		if ($作业行.Count) { $作业文本 += (($作业行) -join "`n") + "`n" }
		if ($作业文本 -match '下载中断') { break }
		Start-Sleep -Seconds 1
	}
	Stop-Job -Job $注入作业 -ErrorAction SilentlyContinue
	$尾行 = @(Receive-Job -Job $注入作业 -ErrorAction SilentlyContinue 6>&1 | ForEach-Object { [string]$_ })
	if ($尾行.Count) { $作业文本 += (($尾行) -join "`n") }
	Remove-Job -Job $注入作业 -Force -ErrorAction SilentlyContinue
	Write-Output ('    作业内重建的形参集：' + ([regex]::Match($作业文本, 'B7_PARAMS=(.*)').Groups[1].Value))
	@($作业文本 -split "`r?`n" | Where-Object { $_ -match '开始下载|下载中断' } | Select-Object -First 3) | ForEach-Object {
		$t = $_; if ($t.Length -gt 180) { $t = $t.Substring(0, 180) + '…' }; Write-Output ('    ' + $t)
	}
	断言 'B7b 作业内重建的函数仍有三个形参（下载地址/目标路径/端标注）' ($作业文本 -match 'B7_PARAMS=[^\r\n]*端标注') ('实测：' + ([regex]::Match($作业文本, 'B7_PARAMS=(.*)').Groups[1].Value))
	断言 'B7c 真下载器的行带指定端标注（不是默认值）' ($作业文本 -match ([regex]::Escape($标注文本) + '[^\r\n]*(开始下载|断点续传|下载中断)')) ('实测作业输出：' + (($作业文本 -split "`r?`n" | Select-Object -First 4) -join ' ⏎ '))
	Remove-Item -LiteralPath $B7探测文件 -Force -ErrorAction SilentlyContinue
} finally {
	Remove-Item -LiteralPath $沙盒, $沙盒2, $沙盒3, $沙盒4, $沙盒5, $沙盒6 -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output '===== C. 真跑 sh 竞速与下载函数（git bash + 桩 download_file） ====='
$bash = @('C:\Program Files\Git\bin\bash.exe', 'C:\Program Files\Git\usr\bin\bash.exe', 'bash.exe') | Where-Object { $null -ne (Get-Command $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
if ($跳过sh) {
	Write-Output '  已跳过（-跳过sh）'
} elseif ($null -eq $bash) {
	断言 'C0 找到可用的 bash' $false '安装 Git for Windows 或加 -跳过sh'
} else {
	# 从 sh 文件里按「顶格 } 收尾」提取函数正文：整份文件顶层是完整安装流程，直接 source 会在本机真跑安装
	$sh行 = Get-Content -LiteralPath $sh路径 -Encoding UTF8
	function 取-sh函数([string]$名字) {
		$起 = ($sh行 | Select-String -Pattern ('^' + [regex]::Escape($名字) + '\(\) \{$') | Select-Object -First 1).LineNumber
		if (-not $起) { return $null }
		$文 = New-Object System.Collections.Generic.List[string]
		for ($i = $起; $i -le $sh行.Count; $i++) {
			$文.Add($sh行[$i - 1])
			if ($sh行[$i - 1] -eq '}') { break }
		}
		return ($文 -join "`n")
	}
	$sh下载 = 取-sh函数 'run_remote_download'
	$sh_cli下载 = 取-sh函数 'run_remote_cli_download'
	$sh竞速 = 取-sh函数 'race_artifact'
	断言 'C0 三个 sh 函数都提取出来了' (($null -ne $sh下载) -and ($null -ne $sh_cli下载) -and ($null -ne $sh竞速)) ''

	$脚本文件 = Join-Path $env:TEMP ('vsi-sh-selftest-' + [Guid]::NewGuid().ToString('N') + '.sh')
	$沙盒sh = ($env:TEMP -replace '\\', '/') + '/vsi-sh-sandbox-' + [Guid]::NewGuid().ToString('N')
	# 桩：download_file 先写 1000 字节（让心跳看得到进度），再 sleep，最后写一个真 gzip 包
	$桩 = @'
#!/bin/sh
URL_PRIMARY='http://stub/p'; URL_FALLBACK='http://stub/f'; CLI_URL='http://stub/c'
EVENT_INTERVAL=1; EVENT_REPORT_AT=0; EVENT_SLEEP_NEXT=1; SRC_TOTAL=2
log() { echo "[LOG] $*"; }
log_event() { EVENT_SLEEP_NEXT=1; echo "[EVENT] $1"; }
download_file() {
	if [ "$SLOW" = '1' ]; then
		head -c 1000 /dev/zero > "$2"
		sleep 3
	fi
	printf 'hello-stub' | gzip > "$2"
	return 0
}
'@
	$场景 = @'
SANDBOX="__沙盒__"
rm -rf "$SANDBOX"; mkdir -p "$SANDBOX"

# C1 正常路径：私有在途名 → 校验 → 改名发布 → 写标记
P="$SANDBOX/REMOTE.tar.gz"; M="$SANDBOX/REMOTE_DONE"
run_remote_download "$P" "$M" >/dev/null 2>&1
[ -s "$P" ] && gzip -t "$P" 2>/dev/null && echo "C1_OK published-complete" || echo "C1_FAIL published"
[ -f "$M" ] && echo "C1_OK marked" || echo "C1_FAIL marked"
ls "$SANDBOX" | grep -q 'downloading' && echo "C1_FAIL in-flight-leftover" || echo "C1_OK no-in-flight-leftover"
echo "C1_FILES=$(ls -1 "$SANDBOX" | tr '\n' ' ')"

# C2 另一条并发会话（活属主）的在途文件不受扰：sh 不做认领（download_file 不带 Range，半成品无续传价值）
sleep 90 & SPID=$!
P2="$SANDBOX/S2.tar.gz"; M2="$SANDBOX/S2_DONE"
head -c 500 /dev/zero > "$P2.downloading-$SPID"
BEFORE=$(wc -c < "$P2.downloading-$SPID" | tr -d ' ')
run_remote_download "$P2" "$M2" >/dev/null 2>&1
if [ -f "$P2.downloading-$SPID" ]; then
	AFTER=$(wc -c < "$P2.downloading-$SPID" | tr -d ' ')
	if [ "$BEFORE" = "$AFTER" ]; then echo "C2_OK other-session-inflight-untouched($AFTER)"; else echo "C2_FAIL size-changed $BEFORE->$AFTER"; fi
else
	echo "C2_FAIL other-session-inflight-gone"
fi
gzip -t "$P2" 2>/dev/null && [ -f "$M2" ] && echo "C2_OK own-download-published" || echo "C2_FAIL own-download"
kill $SPID 2>/dev/null

# C3 CLI 走同一纪律，且消息带端标注
P3="$SANDBOX/REMOTE_CLI.tar.gz"; M3="$SANDBOX/REMOTE_CLI_DONE"
OUT3=$(run_remote_cli_download "$P3" "$M3" 2>&1)
gzip -t "$P3" 2>/dev/null && [ -f "$M3" ] && echo "C3_OK cli-published" || echo "C3_FAIL cli-published"
echo "$OUT3" | grep -q '\[远程自下载-CLI\] 开始下载远程 CLI' && echo "C3_OK cli-label" || echo "C3_FAIL cli-label: $(echo "$OUT3" | tr '\n' '|')"
echo "$OUT3" | grep -q '\[远程自下载-CLI\] 下载完成，已改名发布成品' && echo "C3_OK cli-publish-label" || echo "C3_FAIL cli-publish-label"

# C4 远端已有完整成品：race_artifact 立刻判远程获胜，不起后台下载
# 注：胜负靠全局变量返回，绝不能用 $( ) 命令替换（那是子 shell，全局拿不到）——统一重定向到文件再读
sleep 90 & SPID4=$!
P4="$SANDBOX/REMOTE4.tar.gz"; M4="$SANDBOX/REMOTE4_DONE"; CANCEL4="$SANDBOX/LOCAL4_CANCEL"
printf 'hello-stub' | gzip > "$P4"
race_artifact 服务端 "$P4" "$M4" "$SANDBOX/LOCAL4.tar.gz" "$SANDBOX/LOCAL4_DONE" "$CANCEL4" run_remote_download > "$SANDBOX/out4.txt" 2>&1
OUT4=$(cat "$SANDBOX/out4.txt")
[ "$RACE_WINNER_SIDE" = 'remote' ] && echo "C4_OK winner-remote" || echo "C4_FAIL winner=$RACE_WINNER_SIDE"
[ "$RACE_WINNER_PKG" = "$P4" ] && echo "C4_OK pkg-path" || echo "C4_FAIL pkg=$RACE_WINNER_PKG"
[ -f "$M4" ] && [ -f "$CANCEL4" ] && echo "C4_OK marks-written" || echo "C4_FAIL marks"
echo "$OUT4" | grep -q '远端已有完整自下载成品' && echo "C4_OK fastpath-msg" || echo "C4_FAIL fastpath-msg: $(echo "$OUT4" | tr '\n' '|')"
echo "$OUT4" | grep -q '竞速：远程自下载与本地下载+上传并行' && echo "C4_FAIL started-race" || echo "C4_OK no-race-started"
echo "$OUT4" | grep -q '\[远程自下载-服务端\]' && echo "C4_OK label" || echo "C4_FAIL label"
kill $SPID4 2>/dev/null

# C5 截断的旧成品不得当完整包：race 必须照常起下载作业
P5="$SANDBOX/REMOTE5.tar.gz"; M5="$SANDBOX/REMOTE5_DONE"
head -c 4321 /dev/zero > "$P5"
race_artifact 服务端 "$P5" "$M5" "$SANDBOX/LOCAL5.tar.gz" "$SANDBOX/LOCAL5_DONE" "$SANDBOX/LOCAL5_CANCEL" run_remote_download > "$SANDBOX/out5.txt" 2>&1
OUT5=$(cat "$SANDBOX/out5.txt")
echo "$OUT5" | grep -q '远端已有完整自下载成品' && echo "C5_FAIL treated-truncated-as-complete" || echo "C5_OK truncated-not-accepted"
echo "$OUT5" | grep -q '竞速：远程自下载与本地下载+上传并行' && echo "C5_OK race-started" || echo "C5_FAIL race-not-started"
gzip -t "$P5" 2>/dev/null && [ -f "$M5" ] && echo "C5_OK republished-complete" || echo "C5_FAIL republished"

# C6 心跳必须看私有在途名（改造成品名发布制后，成品在发布前不存在）
SLOW=1
P6="$SANDBOX/REMOTE6.tar.gz"; M6="$SANDBOX/REMOTE6_DONE"
race_artifact 服务端 "$P6" "$M6" "$SANDBOX/LOCAL6.tar.gz" "$SANDBOX/LOCAL6_DONE" "$SANDBOX/LOCAL6_CANCEL" run_remote_download > "$SANDBOX/out6.txt" 2>&1
SLOW=''
OUT6=$(cat "$SANDBOX/out6.txt")
echo "$OUT6" | grep -q '\[远程自下载-服务端\] 远程下载进度：已传 1000 字节' && echo "C6_OK heartbeat-sees-inflight" || echo "C6_FAIL heartbeat: $(echo "$OUT6" | tr '\n' '|')"
echo "$OUT6" | grep -q '已传 0 字节' && echo "C6_WARN zero-reported-once(可接受：心跳早于首块落地)" || echo "C6_OK no-zero-heartbeat"

# C7 cleanup_staging 保留在途、回收陈旧
rm -rf "$SANDBOX/ST"; mkdir -p "$SANDBOX/ST"
: > "$SANDBOX/ST/A.zip.uploading"; : > "$SANDBOX/ST/A.zip.downloading-111"; : > "$SANDBOX/ST/A.zip.downloading-222"
touch -d '7 hours ago' "$SANDBOX/ST/A.zip.downloading-222" 2>/dev/null || true
STAGING="$SANDBOX/ST"
cleanup_staging
[ -f "$SANDBOX/ST/A.zip.uploading" ] && echo "C7_OK keep-uploading" || echo "C7_FAIL keep-uploading"
[ -f "$SANDBOX/ST/A.zip.downloading-111" ] && echo "C7_OK keep-fresh-inflight" || echo "C7_FAIL keep-fresh-inflight"
if [ -f "$SANDBOX/ST/A.zip.downloading-222" ]; then echo "C7_INFO stale-inflight-kept(touch -d 不可用则按龄回收未触发)"; else echo "C7_OK stale-inflight-recycled"; fi

echo "SH_SELFCHECK_DONE"
'@
	$sh清理函数 = 取-sh函数 'cleanup_staging'
	$全文 = $桩 + "`n" + $sh清理函数 + "`n" + $sh下载 + "`n" + $sh_cli下载 + "`n" + $sh竞速 + "`n" + $场景.Replace('__沙盒__', $沙盒sh)
	# 必须 LF：CRLF 会让 sh 把 \r 并入命令（$'\r': command not found），这是本项目踩过的老坑
	[System.IO.File]::WriteAllText($脚本文件, ($全文 -replace "`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
	$sh输出 = @()
	try {
		$sh输出 = @(& $bash $脚本文件 2>&1)
	} catch {
		$sh输出 = @($_.Exception.Message)
	}
	$sh文本 = ($sh输出 | ForEach-Object { [string]$_ }) -join "`n"
	Write-Output '  --- sh 场景输出 ---'
	$sh输出 | ForEach-Object { $t = [string]$_; if ($t.Length -gt 190) { $t = $t.Substring(0, 190) + '…' }; Write-Output ('    ' + $t) }
	断言 'C0b sh 场景全部跑完（有收尾标记行）' ($sh文本 -match 'SH_SELFCHECK_DONE') ('原始输出：' + $sh文本)
	$失败行 = @($sh输出 | Where-Object { [string]$_ -match '_FAIL' })
	$通过行 = @($sh输出 | Where-Object { [string]$_ -match '_OK' })
	断言 ('C1-C7 sh 场景无失败行（实测 OK ' + $通过行.Count + ' 行）') ($失败行.Count -eq 0) ('失败行：' + (($失败行 | ForEach-Object { [string]$_ }) -join ' ⏎ '))
	Remove-Item -LiteralPath $脚本文件 -Force -ErrorAction SilentlyContinue
	& $bash -c ('rm -rf ' + "'" + $沙盒sh + "'") 2>&1 | Out-Null
}

Write-Output ''
if (写-断言汇总 -标题 '汇总') { Write-Output '全部通过。'; exit 0 }
Write-Output '存在失败：详见上方 FAIL 行与本汇总的失败明细。'
exit 1
