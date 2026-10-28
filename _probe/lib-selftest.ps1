# 探针公共库的回归自检（不联网、不动远端、不动生产代码）
#
# 为什么要给「库」写自检：库是把历次取证逻辑固定下来的唯一副本，一旦它与生产算法漂移，
# 用它跑出来的结论就会指错方向（本轮就吃过亏：探针抄漏 `ssh -n`/BatchMode，结果探针自己挂在密码提示上，
# 一度把「B 需要密码」误当成远端卡死的原因）。所以库的每一条铁律都必须有断言守着。
#
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\lib-selftest.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 '  [通过] ' -失败前缀 '  [失败] '

$模块目录 = 取-模块目录
$私有目录 = 取-私有目录
$psm1正文 = Get-Content -LiteralPath (Join-Path $模块目录 '安装实现.ps1') -Raw -Encoding UTF8

Write-Host '===== A. 库本体：语法/BOM/导出面 ====='
$查库 = 校-脚本语法 -路径 (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
写-断言 '库语法可解析' ($查库.语法错误 -eq 0) ($查库.错误明细 -join '；')
写-断言 '库是 UTF-8 with BOM（PS 5.1 硬性要求）' ($查库.BOM数 -eq 1) ('BOM 数 ' + $查库.BOM数)
foreach ($fn in @('Initialize-断言', '写-断言', '写-断言汇总', '取-断言计数', '校-脚本语法', '补-脚本BOM', '扫-裸拼接实参', '取-仓库根', '取-模块目录', '构造-单会话载荷', '构造-固定引导码', '取-引导码特征', '剥-SSH噪声', '送-远端脚本', '取-远端有界计时包装', '取-远端普查脚本', '送-载荷经stdin')) {
	写-断言 ('库导出 ' + $fn) ($null -ne (Get-Command -Name $fn -ErrorAction SilentlyContinue)) ''
}

Write-Host ''
Write-Host '===== B. 断言台账：两种历史调用顺序都要认 ====='
# 用「前后快照取增量」验证，绝不中途 Initialize：那会把 A 段已有的计数抹掉（初版就这样丢过结果）
$基线 = 取-断言计数
写-断言 '(说明,条件) 顺序' $true
$中间 = 取-断言计数
写-断言 $true '(条件,说明) 顺序'
$末 = 取-断言计数
写-断言 '两种顺序都记为通过（各 +1）' ((($中间.通过 - $基线.通过) -eq 1) -and (($末.通过 - $中间.通过) -eq 1)) ('增量 ' + ($中间.通过 - $基线.通过) + ' / ' + ($末.通过 - $中间.通过))
写-断言 '两种顺序都不误记为失败' (($末.失败 - $基线.失败) -eq 0) ('失败增量 ' + ($末.失败 - $基线.失败))

Write-Host ''
Write-Host '===== C. 载荷构造与生产算法同源（漂移守卫） ====='
# 正向对照：用生产同款输入跑一遍，确认库真的算出了东西（防「在空集上假通过」）
$通用正文 = Get-Content -LiteralPath (Join-Path $私有目录 'remote-install-common.ps1') -Raw -Encoding UTF8
$构 = 构造-单会话载荷 -安装脚本文本 $通用正文
写-断言 '库能算出引导码（正向对照）' ($构.引导码.Length -gt 10000) ('引导码 ' + $构.引导码.Length + ' 字符')
写-断言 '载荷整段写入且不含空白（分块已删；base64 无空白是远端剔空白后无损的前提）' (($构.载荷不含空白) -and ($构.载荷标准输入 -ceq $构.引导码)) ('载荷标准输入 ' + $构.载荷标准输入.Length + ' 字符 == 引导码 ' + $构.引导码.Length + ' 字符，含空白=' + (-not $构.载荷不含空白))
写-断言 '载荷标准输入不含 CR（CRLF 会把 \r 混进远端命令）' (-not $构.载荷标准输入.Contains("`r")) ''
# 漂移守卫①：库必须与 psm1 的算法逐字同源（照 psm1 现写的四步在本地**独立**复算一遍，比对结果）
function 本地复算引导码 {
	param([string]$安装脚本文本)
	$精简正文 = (($安装脚本文本 -split "`r?`n") | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne '' }) -join "`n"
	$压缩流 = New-Object System.IO.MemoryStream
	$压缩器 = New-Object System.IO.Compression.GZipStream($压缩流, [System.IO.Compression.CompressionMode]::Compress)
	$正文字节 = [System.Text.Encoding]::UTF8.GetBytes($精简正文)
	$压缩器.Write($正文字节, 0, $正文字节.Length)
	$压缩器.Close()
	$载荷 = [Convert]::ToBase64String($压缩流.ToArray())
	$引导脚本 = (Get-Content -LiteralPath (Join-Path $私有目录 'Windows单会话引导.ps1') -Raw -Encoding UTF8).Replace('__载荷__', $载荷)
	return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($引导脚本))
}
写-断言 '库的引导码 == 按 psm1 算法独立复算的引导码' ((本地复算引导码 $通用正文) -eq $构.引导码) '两者漂移了：改了一边必须同时改另一边'
# 漂移守卫②：psm1 的算法特征必须还在（psm1 改了算法而库没跟上时，这里就红）
# 去注释那一步的字面量含反斜杠：PowerShell 双引号不对反斜杠做转义，写成单个反斜杠即可；
# 若手误叠成双反斜杠，字面量就与 psm1 里的单反斜杠不匹配、断言恒红（初版就踩了这个）。
$去注释特征 = ("-notmatch '^\s*#'")
写-断言 'psm1 仍按「去注释去空行 → gzip → base64 → 塞模板 → UTF-16 base64」构造' (($psm1正文.Contains($去注释特征)) -and ($psm1正文.Contains('GZipStream')) -and ($psm1正文.Contains(".Replace('__载荷__', `$载荷)")) -and ($psm1正文.Contains('[System.Text.Encoding]::Unicode.GetBytes($引导脚本)'))) '四步任一变形都必须同步改库，否则库算出来的载荷与生产不同源'
写-断言 'psm1 也把载荷整段写入 stdin（与库同源，分块已删）' ($psm1正文 -match '\$载荷标准输入 = \$引导码') ''
写-断言 'psm1 不得回退到分块（无 $每块字符、无拼接长度自校验）' ((($psm1正文 -match '\$每块字符') -eq $false) -and (($psm1正文 -match '分块重组后长度不一致') -eq $false)) ''

Write-Host ''
Write-Host '===== D. 固定引导码：argv 占用必须远小于上限 ====='
$固 = 构造-固定引导码
$argv = 'powershell -NoProfile -EncodedCommand ' + $固
写-断言 '固定引导码低于 8000 守卫线' ($固.Length -lt 8000) ('EncodedCommand ' + $固.Length + ' 字符')
写-断言 '由此构成的 argv 远离 CreateProcess 上限 32767' ($argv.Length -lt 8192) ('argv ' + $argv.Length + ' 字符')
写-断言 '引导码与载荷体积无关（解耦有效）' ($固.Length * 4 -lt $构.引导码.Length) ('固定 ' + $固.Length + ' vs 载荷引导码 ' + $构.引导码.Length)
$引导文 = Get-Content -LiteralPath (Join-Path $私有目录 'windows-stdin-bootstrap.ps1') -Raw -Encoding UTF8
写-断言 '引导使用原始 stdin 的 StreamReader 有界异步读（等不到 EOF 自退）' (($引导文.Contains('[Console]::OpenStandardInput()')) -and ($引导文.Contains('New-Object System.IO.StreamReader')) -and ($引导文.Contains('.ReadToEndAsync()')) -and ($引导文.Contains('.Wait('))) ''
写-断言 '引导不再使用会在大载荷时同步卡住的 Console.In.ReadToEndAsync' (-not $引导文.Contains('[Console]::In.ReadToEndAsync()')) 'B 服务器实测旧读取器在返回 Task 前就卡住，Wait(90000) 无法执行；新读取器已用 154KB 载荷验证'

Write-Host ''
Write-Host '===== E. 远端下发原语：argv 通道必须无噪声、不挂起 ====='
$送源码 = (Get-Command 送-远端脚本).Definition
写-断言 '远端脚本先 CRLF→LF（\r 混进命令会让远端语法报错）' ($送源码.Contains('-replace "`r`n", "`n"')) ''
写-断言 '走 UTF-16 base64 + powershell -EncodedCommand' (($送源码.Contains('[System.Text.Encoding]::Unicode.GetBytes')) -and ($送源码.Contains('-EncodedCommand '))) ''
写-断言 '带 ssh -n（stdin 走 nul，不会停在交互输入上）' ($送源码.Contains("'-n'")) ''
写-断言 '默认 BatchMode=yes（没有免密就秒失败，绝不卡在密码提示）' ($送源码.Contains('BatchMode=yes')) ''
写-断言 '带 ConnectTimeout（连不上要快速失败）' ($送源码.Contains('ConnectTimeout=')) ''
写-断言 'ssh 调用被 $ErrorActionPreference=Continue 包住（原生 stderr 在 Stop 下会变成终止错误）' (($送源码.Contains("ErrorActionPreference = 'Continue'"))) ''
$剥源码 = (Get-Command 剥-SSH噪声).Definition
写-断言 '剥掉 mDNS CNAME 警告' ($剥源码.Contains('ignoring bad CNAME')) ''
写-断言 '剥掉 CLIXML 进度记录片段' ($剥源码.Contains('#< CLIXML')) ''
写-断言 '剥掉 PS 5.1 的 NativeCommandError 包装' ($剥源码.Contains('NativeCommandError')) ''
# 行为验证：噪声过滤与标记提取
$假输出 = @('ignoring bad CNAME "x" for host', '#< CLIXML', '__T__真实结论1', '<Objs Version="1.1">噪音</Objs>', '__T__真实结论2', 'CategoryInfo : NotSpecified')
$净 = @(剥-SSH噪声 -行集合 $假输出)
# 6 行里 4 行是噪声（CNAME 警告 / CLIXML 头 / Objs 片段 / CategoryInfo 模板），只剩 2 行结论
写-断言 '噪声过滤只留下有效行（6 行输入 → 2 行）' ($净.Count -eq 2) (($净) -join ' | ')
写-断言 '留下的正是两条带标记的结论行' ((($净 | Where-Object { $_ -match '^__T__' }).Count) -eq 2) ''
写-断言 '返回的是可枚举数组而不是被包住的 List（调用方 @() 的 .Count 才可信）' ($净[0] -is [string]) ('首元素类型 ' + $净[0].GetType().Name)

Write-Host ''
Write-Host '===== F. 有界计时包装与普查脚本：探针自身绝不挂死、绝不改远端状态 ====='
$包 = 取-远端有界计时包装 -片段 "Write-Output '__T__X'" -超时秒 7 -名字 '测试片段'
写-断言 '包装用 Start-Job' ($包.Contains('Start-Job')) ''
写-断言 '包装用 Wait-Job -Timeout（超时就断，不跟着挂）' (($包.Contains('Wait-Job $j -Timeout')) -and ($包.Contains('7')) ) ''
写-断言 '包装超时分支明确报「挂死」并给出卡点' (($包.Contains('Stop-Job')) -and ($包.Contains('挂死'))) ''
写-断言 '包装收尾 Remove-Job（不留远端作业残骸）' ($包.Contains('Remove-Job $j -Force')) ''
$普查 = 取-远端普查脚本 -提交号 'abc123' -含引导树明细 -含竞速文件明细
# 禁词比对一律用 **-cnotmatch**（区分大小写）：-match 不区分大小写，'Move-Item' 会被 Remove-Item 误匹配，
# 实测就是这个假阳性把「普查不改远端状态」这条断言弄红的（普查只该有一处 Remove-Item，见下一条）
写-断言 '普查脚本不改远端状态：无 taskkill/Stop-Process/Set-ItemProperty/Move-Item' (($普查 -cnotmatch 'taskkill') -and ($普查 -cnotmatch 'Stop-Process') -and ($普查 -cnotmatch 'Set-ItemProperty') -and ($普查 -cnotmatch 'Move-Item')) ''
写-断言 '（对照）不区分大小写的 -match 确实会把 Remove-Item 误判成 Move-Item' ($普查 -match 'Move-Item') '该假阳性就是上面改用 -cnotmatch 的理由；本条一旦变红说明普查里的 Remove-Item 也没了，请同时复查上面那条'
$删除次数 = ([regex]::Matches($普查, 'Remove-Item')).Count
写-断言 '普查里 Remove-Item 只出现一次，且是清掉自己的可写性探针文件' (($删除次数 -eq 1) -and ($普查 -match 'Remove-Item \$试')) ('Remove-Item 出现 ' + $删除次数 + ' 次')
写-断言 '普查确实用可写性自测判断家目录能不能写（df 空闲多 ≠ 用户配额没满）' (($普查 -match '\.vsi-probe-write-test\.txt') -and ($普查 -match '家目录可写')) ''
# 孤儿判据必须三条件齐备：光看「EncodedCommand + 超龄」会把正在跑的安装（同一固定引导码，下载几十分钟）
# 和探针脚本一起报成孤儿，按这个结论去动手就是杀活安装（2026-10-23 B 服务器实测误报两个）
$特征 = 取-引导码特征
$固定码 = 构造-固定引导码
写-断言 '引导码特征是固定引导码的真前缀（否则匹不上就是永远报 0 个孤儿）' (($固定码.StartsWith($特征)) -and ($特征.Length -eq 48)) ('特征 ' + $特征.Length + ' 字符；引导码 ' + $固定码.Length + ' 字符')
写-断言 '特征取自真实的 stdin 引导模板（而不是写死的常量）' (($特征.Length -gt 0) -and ((取-引导码特征 -长度 16).Length -eq 16)) ''
$普查带特征 = 取-远端普查脚本 -提交号 'abc123' -含引导树明细 -含竞速文件明细 -引导码特征 $特征
写-断言 '普查里特征占位符已替成真值' ((-not ($普查带特征 -match '__引导特征__')) -and ($普查带特征.Contains($特征))) ''
写-断言 '无特征时也不留占位符（退化为全部归入「其它编码」，不得抛错）' ((-not ($普查 -match '__引导特征__')) -and ($普查.Contains("`$引导特征 -ne ''"))) ''
写-断言 '孤儿判据带 CPU 近零这一条（正在下载安装 CPU 不是 0，单靠超龄会误杀）' (($普查.Contains('UserModeTime')) -and ($普查.Contains('KernelModeTime')) -and ($普查.Contains('$cpu -lt 1'))) ''
写-断言 'CPU 读不到时保守当不杀（宁漏报不误报）' ($普查.Contains('保守当不杀')) ''
写-断言 '三分类都在：生产引导 / 疑似孤儿计数 / 其它 EncodedCommand' (($普查.Contains('固定引导码进程数')) -and ($普查.Contains('疑似卡死孤儿')) -and ($普查.Contains('其它EncodedCommand进程数'))) ''
写-断言 '普查仍无杀伤动作（只报告不建议直接杀）' (($普查 -cnotmatch 'taskkill') -and ($普查 -cnotmatch 'Stop-Process')) ''
写-断言 '普查覆盖 sshd 会话数（饱和判据）' ($普查.Contains("Name='sshd.exe'")) ''
写-断言 '普查覆盖竞速目录与已装 server' (($普查.Contains('race-')) -and ($普查.Contains('cli\servers\Insiders-'))) ''
写-断言 '普查覆盖磁盘与家目录可写性（下载前提）' (($普查.Contains('Get-PSDrive')) -and ($普查.Contains('家目录可写'))) ''
写-断言 '普查占位符已全部替换（不留 __树明细__/__提交号段__/__竞速明细__）' ((-not ($普查 -match '__树明细__|__提交号段__|__竞速明细__|__提交号__'))) ''
$普查无提交号 = 取-远端普查脚本
写-断言 '不给提交号时明确提示跳过（不留未替换占位符）' ((-not ($普查无提交号 -match '__提交号段__')) -and ($普查无提交号.Contains('跳过竞速'))) ''

Write-Host ''
Write-Host '===== G. stdin 客户端：与生产硬化函数同一套序列 ====='
$送源码2 = (Get-Command 送-载荷经stdin).Definition
function 取-生产硬化体 {
	$起 = $psm1正文.IndexOf('function 执行-SSH命令带标准输入')
	$止 = $psm1正文.IndexOf('function 上传-文件到远程')
	if ($起 -lt 0 -or $止 -le $起) { return '' }
	return $psm1正文.Substring($起, $止 - $起)
}
$生产体 = 取-生产硬化体
写-断言 '定位到生产硬化函数体（守卫范围限定用它）' ($生产体.Length -gt 500) ($生产体.Length.ToString() + ' 字符')
foreach ($要 in @(
	@('RedirectStandardError = $true', '三流全重定向'),
	@('CreateNoWindow = $true', '不建窗口'),
	@('StandardError.ReadToEndAsync()', 'stderr 异步抽干（只重定向不读会被缓冲写满堵死远端）'),
	@('StandardInput.Flush()', '写后 Flush'),
	@('StandardInput.Close()', '显式 Close 送确定的 EOF'),
	@('ReadLineAsync()', '异步逐行读'),
	@('taskkill /PID $进程.Id /T /F', '看门狗杀整棵本地进程树'),
	@('\.(cmd|bat)$', '批处理包装的 ssh 判则（不能直接 CreateProcess，需套 cmd /c）')
)) {
	# 全部用字面量 Contains：比字面量一律不用 -match/-like（正则里的竖线与反斜杠极易写歪，
	# 实测把 '\.cmd\|bat' 当模式时永远不中，因为代码里的字面量是 '\.(cmd|bat)$'）
	写-断言 ('库与生产都有 ' + $要[1]) (($送源码2.Contains($要[0])) -and ($生产体.Contains($要[0]))) ('生产: ' + $生产体.Contains($要[0]) + ' / 库: ' + $送源码2.Contains($要[0]))
}
写-断言 '库按 ASCII 写字节（载荷是纯 ASCII base64）' ($送源码2.Contains('[System.Text.Encoding]::ASCII.GetBytes($标准输入文本)')) ''
写-断言 '库逐行记录到达时刻（判定输出是否被缓冲到退出才 flush 只能靠它）' (($送源码2.Contains('到达.Add')) -and ($送源码2.Contains('耗时秒'))) ''
写-断言 '库到点必杀本地 ssh 树（探针自身不留孤儿）' (($送源码2.Contains('if (-not $进程.HasExited)')) -and ($送源码2.Contains('taskkill'))) ''

Write-Host ''
Write-Host '===== H. 语法/BOM 工具在真实文件上的行为 ====='
$查psm1 = 校-脚本语法 -路径 (Join-Path $模块目录 '安装实现.ps1')
写-断言 '扩展安装脚本语法可解析（正向对照：工具真能干活）' ($查psm1.语法错误 -eq 0) ($查psm1.错误明细 -join '；')
写-断言 '扩展安装脚本是单 BOM' ($查psm1.BOM数 -eq 1) ('BOM 数 ' + $查psm1.BOM数)
$查引导 = 校-脚本语法 -路径 (Join-Path $私有目录 'windows-stdin-bootstrap.ps1')
写-断言 '纯 ASCII 模板可以零 BOM（无中文标识符，PS 5.1 不按 ANSI 误读）' ($查引导.语法错误 -eq 0) ('BOM 数 ' + $查引导.BOM数)
# 补 BOM 的幂等性与「剥到只剩一个」行为（在临时文件上验，绝不碰仓库文件）
$临时 = Join-Path $env:TEMP ('vsi-lib-selftest-bom-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
	[System.IO.File]::WriteAllBytes($临时, [byte[]](0x61, 0x0D, 0x0A))          # 无 BOM
	写-断言 '无 BOM 时 补-脚本BOM 返回 true 并补上' ((补-脚本BOM -路径 $临时) -and ((校-脚本语法 -路径 $临时).BOM数 -eq 1)) ''
	写-断言 '已是单 BOM 时 补-脚本BOM 幂等返回 false' (-not (补-脚本BOM -路径 $临时)) ''
	$双 = [byte[]](0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF, 0x61)                   # 双 BOM（实测会让 param() 解析失败）
	[System.IO.File]::WriteAllBytes($临时, $双)
	写-断言 '双 BOM 被识别为 2 个（这是会让 param() 报错的硬缺陷）' ((校-脚本语法 -路径 $临时).BOM数 -eq 2) ''
	写-断言 '双 BOM 被剥到只剩 1 个' ((补-脚本BOM -路径 $临时) -and ((校-脚本语法 -路径 $临时).BOM数 -eq 1)) ''
} finally { Remove-Item -LiteralPath $临时 -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '===== I. 仓库路径解析 ====='
写-断言 '取-仓库根 指到仓库（含 _probe 与扩展目录）' ((Test-Path (Join-Path (取-仓库根) '_probe')) -and (Test-Path (Join-Path (取-仓库根) '接管远程服务器安装扩展\scripts'))) (取-仓库根)
写-断言 '取-私有目录 指到模块 private' (Test-Path (Join-Path (取-私有目录) 'remote-install-common.ps1')) ''
# 路径解析必须靠 $PSScriptRoot：函数里 $MyInvocation.MyCommand.Definition 拿到的是函数体文本（实测把注释当路径，Resolve-Path 直接报错）
$根源码 = (Get-Command 取-仓库根).Definition
写-断言 '取-仓库根 用 $PSScriptRoot 而不是 MyCommand.Definition' (($根源码.Contains('$PSScriptRoot')) -and (-not ($根源码 -match 'MyCommand\.Definition'))) ''

Write-Host ''
Write-Host '===== J. 裸拼接实参扫描（假绿防护） ====='
# 这段的价值在真实事故：报告点上的一条断言因为消息没加括号，招的额外实参让它从未执行过，
# 而脉本仍报「0 问题」并退出 0。没有这道扫描就只能靠人胉看子命令的报错行。
$临时2 = Join-Path $env:TEMP ('vsi-lib-selftest-bareplus-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
	$坏例 = @"
function 断言([bool]`$条件, [string]`$说明) { }
`$x = 3
断言 (`$x -ge 3) '前半 ' + `$x + ' 后半'
断言 (`$x -ge 3) ('前半 ' + `$x + ' 后半')
断言 (`$x -ge 3) '字符串里有加号 a+b'
Write-Host '与断言无关的裸拼接 ' + `$x
"@
	[System.IO.File]::WriteAllText($临时2, $坏例, (New-Object System.Text.UTF8Encoding($true)))
	$命中 = @(扫-裸拼接实参 -路径 $临时2)
	写-断言 '正例：裸拼接的断言被抓出且只抓这一条（括号化的、字符串内加号的、Write-Host 的都不误报）' ($命中.Count -eq 1) ('命中 ' + $命中.Count + ' 条' + $(if ($命中.Count -gt 0) { '；行号 ' + (($命中 | ForEach-Object { $_.行号 }) -join ',') } else { '' }))
	写-断言 '行号对得上（指向裸拼接那行，不是文件头）' ((@($命中 | Where-Object { $_.行号 -eq 3 }).Count -eq 1)) ('得到行号：' + ((@($命中 | ForEach-Object { $_.行号 }) -join ',')) + '；期望 3（样例文件第 3 行）')
	写-断言 '命中项带原文与命令名（直接拿去改，不用回头找）' (($命中.Count -eq 0) -or (($命中[0].命令名 -eq '断言') -and ($命中[0].原文.Contains('__VSI') -or ($命中[0].原文.Length -gt 10)))) ''
	# 默认只盯 断言；指定其他命令名也能扫（将来 写-断言 / 报-结果 同类接口可直接复用）
	写-断言 '可指定命令名（扫 Write-Host 时同样能抽到裸拼接）' ((@(扫-裸拼接实参 -路径 $临时2 -命令名 'Write-Host').Count -eq 1)) ''
	# 语法坏文件不得抛：扫到一半报错会把它自己的异常当成扫描结果，反而遮住真问题
	[System.IO.File]::WriteAllText($临时2, "function 断言 { }`r`n断言 ((( " , (New-Object System.Text.UTF8Encoding($true)))
	$不抛 = $true
	try { $r = @(扫-裸拼接实参 -路径 $临时2) } catch { $不抛 = $false }
	写-断言 '语法错误文件上不抛异常（返回空也不报错）' ($不抛) ''
} finally { Remove-Item -LiteralPath $临时2 -Force -ErrorAction SilentlyContinue }

# 仓库自身必须干净：所有自检都不存在裸拼接断言（跑全部自检.ps1 的闸门0 同样会卡住）
$全库命中 = @()
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path (取-仓库根) '_probe') -Recurse -Filter *.ps1)) { $全库命中 += @(扫-裸拼接实参 -路径 $f.FullName) }
写-断言 '_probe 下所有脚本均无裸拼接断言调用' ($全库命中.Count -eq 0) $(if ($全库命中.Count -gt 0) { ($全库命中 | ForEach-Object { (Split-Path $_.路径 -Leaf) + ':L' + $_.行号 }) -join '；' } else { '实测 0 处' })

if (写-断言汇总 -标题 '探针公共库自检') { exit 0 } else { exit 1 }
