# 汇报点审计：把「一次中断只有一条消息」「重试对齐下个汇报周期」「不写死固定秒数」变成可自动判定的结构规则。
# PowerShell 侧走 AST（发射点归属、模板措辞、等待算法），Linux sh 侧走文本规则。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\report-point-audit.ps1
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

# ============ 全局禁忌：旧机制必须彻底消失（三份源码 + sh 一起查）============
$三份 = @(
	(Join-Path $repo 'scripts\private\remote-install-common.ps1'),
	(Join-Path $repo 'scripts\private\local-supply.ps1'),
	(Join-Path $repo 'scripts\private\remote-install-linux.sh')
)
Write-Output '===== 全局禁忌（旧机制残留） ====='
$禁忌表 = [ordered]@{
	'Min(30'          = '写死「最长 30 秒」的固定等待上限'
	'事件周期秒数'        = '与汇报周期并立的第二套事件时钟（双时钟 = 一次中断两条消息的成因之一）'
	'上次事件输出时刻'      = '事件行专用时间戳（双时钟）'
	'静默中断次数'        = '省略计数（改为对齐周期后无需省略，也就不该有静默丢弃）'
	'已报原因指纹'        = '故障指纹去重（同上）'
	'上次报告时间'        = '进度行专用时间戳（每轮重置 → 与中断行各算各的，一次中断产出两条）'
	'上次进度输出'        = '本地供给的进度行专用时间戳（同上）'
	'EVENT_SILENCED'  = 'sh 侧省略计数'
	'EVENT_WIDEN'     = 'sh 侧放宽标志（改为调用方直接 EVENT_INTERVAL++）'
	'lt 30'           = 'sh 侧固定 30 秒封顶'
	'EVENT_INTERVAL * 2' = 'sh 侧周期翻倍（已改为逐轮 +1、上限不写死）'
	'-lt 10'        = '汇报周期放宽被封顶（用户明确要求中途放宽无上限；封顶会重新引入「固定周期必刷一行」那个病根）'
	'[datetime]::MinValue' = '以上古时刻初始化汇报时钟：算「本轮已耗」时 [int] 转换必抛溢出，异常从 catch 逸出会穿透重试循环（实测缺陷，改用 Get-Date）'
}
# 只扫代码行：注释里正当引用被禁字面量（写明纪律与踩坑记录）不应算残留，否则审计会变成禁止写文档
$代码文本表 = @{}
foreach ($文件 in $三份) {
	$代码文本表[$文件] = (@(Get-Content -LiteralPath $文件) | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
}
foreach ($键 in $禁忌表.Keys) {
	$命中 = @()
	foreach ($文件 in $三份) {
		$文本 = $代码文本表[$文件]
		$偏移 = 0
		while (($偏移 = $文本.IndexOf($键, $偏移, [StringComparison]::Ordinal)) -ge 0) {
			$命中 += ((Split-Path -Leaf $文件) + ':第' + ($文本.Substring(0, $偏移) -split "`n").Count + '段')
			$偏移 += $键.Length
		}
	}
	断言 ($命中.Count -eq 0) ("无「$($禁忌表[$键])」（'$键' 代码行命中 " + $命中.Count + ' 处' + $(if ($命中.Count -gt 0) { '：' + ($命中 -join ', ') } else { '' }) + '）')
}
# 正向对照：三处汇报时钟都以现实时刻初始化（MinValue 初值会让 catch 里的 [int] 转换溢出）
$健康初值 = 0
foreach ($文件 in $三份[0..1]) { $健康初值 += @([regex]::Matches($代码文本表[$文件], '\$上次汇报时刻 = Get-Date')).Count }
断言 ($健康初值 -eq 7) ("汇报时钟均以 Get-Date 初始化（3 处轮起 + 两端各 2 处干净重建时的重置时钟，实测 $健康初值 处，期望 7）")

# ============ PowerShell：AST 级汇报点审计 ============
Write-Output ''
Write-Output '===== PowerShell 汇报点（AST） ====='
function 取-发射点 {
	param($命令节点)
	# 发射点 = 一次 Write-Host/Write-Output；模板取其参数里第一个字符串常量（兼容裸串与 (... -f ...) 两种写法）
	$名 = $命令节点.GetCommandName()
	if ($名 -notin @('Write-Host', 'Write-Output')) { return $null }
	# 注意：CommandElements[0] 是命令名本身（也是 StringConstantExpressionAst），从下标 1 起找才是真正的参数；
	# 参数名为 Parameter 类型（如 -NoNewline）也要跳。本提取器曾因此把模板认成 'Write-Host'，导致所有按模板匹配的断言在空集上假通过
	$串节点 = $null
	for ($i = 1; $i -lt $命令节点.CommandElements.Count; $i++) {
		$元素 = $命令节点.CommandElements[$i]
		if ($元素 -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
			if ($元素.StringConstantType -ne 'Parameter') { $串节点 = $元素; break }
			continue
		}
		$候选 = $元素.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $n.StringConstantType -ne 'Parameter' }, $true) | Select-Object -First 1
		if ($null -ne $候选) { $串节点 = $候选; break }
	}
	if ($null -eq $串节点) { return $null }
	# 所属函数：判定「同一下载函数里只允许一个中断发射点」
	$函数节点 = $null
	$当前 = $命令节点.Parent
	while ($null -ne $当前) {
		if ($当前 -is [System.Management.Automation.Language.FunctionDefinitionAst]) { $函数节点 = $当前; break }
		$当前 = $当前.Parent
	}
	return [pscustomobject]@{ 命令 = $名; 模板 = $串节点.Value; 行 = $命令节点.Extent.StartLineNumber; 函数 = $(if ($函数节点) { $函数节点.Name } else { '<顶层>' }) }
}

# 每文件的精确期望值（多一处、少一处都说明汇报点被改动，必须人工复核）：
#   放宽 = 报告周期秒数++ 的出现次数（common：CLI 整包失败 + 头阶段汇报 + 数据阶段基线汇报 + 总量未知 + 本轮无进度 + 头阶段重建 + 数据阶段重建；local-supply：等他方供给进程 + 头阶段汇报 + 数据阶段基线汇报 + 总量未知 + 本轮无进度 + 头阶段重建 + 数据阶段重建）——汇报点的零进展只可能是连后首报基线（非基线零进展走干净重建）
#   另：停滞重建事件也只放宽一档（+1），全文件不得出现任何「周期翻倍」写法（用户明确要求停滞也保持 +1 规律；翻倍曾把重试梯子从 1,2,3… 错改成 1,2,4,8…，实测 60 秒内中断行从 ~9 条掉到 5 条）
#   推进 = $上次汇报时刻 被赋值次数（进度行、中断行与他方等待行共用同一时钟）
#   同频睡 = Start-Sleep -Seconds $等待秒数 的次数（等他方分支是固定 1 秒轻量探，不计入）
$期望 = @{
		'remote-install-common.ps1' = @{ 放宽 = 7; 推进 = 4; 同频睡 = 2 }
		'local-supply.ps1' = @{ 放宽 = 7; 推进 = 5; 同频睡 = 2 }
}
# 「本轮毫无进展」判据的正形：计数器必需每轮归零（上一轮残留值会让瞬时失败轮误判为有进展）+ 比较项必需存在，各恰好 1 处
$进展判据 = @{
	'remote-install-common.ps1' = @(
			@('$已写入字节数 = 0', 2, '本轮写字节计数器归零（轮起 + 干净重建前各一处）'),
			@('$当前磁盘字节数 -le $轮起磁盘字节数', 1, '无进展判据取「轮末磁盘 vs 轮起磁盘」（重建会归零 $已写入字节数，它不再能作轮级证据）')
	)
	'local-supply.ps1' = @(
		@('$已下载 = 0', 1, '本轮已下载计数器每轮归零'),
		@('$轮起已下载 = 0', 1, '轮起点每轮归零'),
		@('$已下载 -le $轮起已下载', 1, '无进展判据取「落地 vs 轮起」')
	)
}
foreach ($相对 in @('scripts\private\remote-install-common.ps1', 'scripts\private\local-supply.ps1')) {
	$全路径 = Join-Path $repo $相对
	$名 = Split-Path -Leaf $全路径
	$tokens = $null; $errors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($全路径, [ref]$tokens, [ref]$errors)
	if ($errors.Count -gt 0) { 写-断言 ("parse: $名") $false (($errors | ForEach-Object { $_.Message }) -join '; '); continue }
	$命令集 = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
	$发射点集 = @($命令集 | ForEach-Object { 取-发射点 $_ } | Where-Object { $_ })
	$全文 = (Get-Content -LiteralPath $全路径 -Raw)

	Write-Output ''
	Write-Output ("--- $名（发射点 " + $发射点集.Count + ' 个） ---')

	# 正向对照（防提取器回到空集、所有断言在空集上假通过）：进度行与起始行的模板必须能认出
	$进度发射 = @($发射点集 | Where-Object { $_.模板 -like '*下载进度*' })
	断言 ($进度发射.Count -ge 2) ("提取器正向对照：认出「下载进度」发射点（实测 " + $进度发射.Count + ' 个，期望 >=2）')
	$起始发射 = @($发射点集 | Where-Object { $_.模板 -match '开始下载|断点续传|下载源' })
	断言 ($起始发射.Count -ge 1) ("提取器正向对照：认出起始行发射点（实测 " + $起始发射.Count + ' 个，期望 >=1）')

	# 规则 1：不得有「按轮回显下载地址」的起始行（一次中断的第二条消息 + 每轮刷链接的病根）
	$按轮起始 = @($发射点集 | Where-Object { ($_.模板 -match '开始下载|断点续传') -and ($_.模板 -match '次尝试') })
	断言 ($按轮起始.Count -eq 0) ("起始行不再按轮回显地址（违规 " + $按轮起始.Count + ' 个' + $(if ($按轮起始.Count) { '：行 ' + (($按轮起始 | ForEach-Object { $_.行 }) -join ',') } else { '' }) + '）')

	# 规则 2：下载地址只随起始行公布一次（「已公布」门控存在）
	断言 ($全文 -match '\$地址已公布|\$源清单已公布') ("$名 有「地址/源清单只公布一次」门控变量")

	# 规则 3：一次中断恒为一条消息——中断模板在每个下载函数里只有一个发射点
	$中断发射 = @($发射点集 | Where-Object { $_.模板 -like '*下载中断*' })
	断言 ($中断发射.Count -ge 1) ("$名 确有中断发射点（" + $中断发射.Count + ' 个）')
	$重复 = @($中断发射 | Group-Object 函数 | Where-Object { $_.Count -gt 1 })
	断言 ($重复.Count -eq 0) ("没有哪个函数里留着两个中断发射点（重复 " + $重复.Count + ' 个）')
	foreach ($发 in $中断发射) {
		$摘 = $发.模板.Substring(0, [Math]::Min(70, $发.模板.Length))
		Write-Output ('    行' + $发.行 + ' [' + $发.函数 + ']: ' + $摘)
	}

	# 规则 4：重试对齐下个汇报周期——等待必须由「周期 − 本轮已耗」算出，且 sleep 用的就是它
	$对齐算式 = @([regex]::Matches($全文, [regex]::Escape('$等待秒数 = [Math]::Max(1, [int][Math]::Ceiling($报告周期秒数 - ($此刻 - $上次汇报时刻).TotalSeconds))')))
	断言 ($对齐算式.Count -ge 1) ("等待秒数 = max(1, 汇报周期 − 本轮已耗)（实测对齐算式 " + $对齐算式.Count + ' 处）')
	$sleeps = @(Select-String -LiteralPath $全路径 -SimpleMatch -Pattern 'Start-Sleep -Seconds $等待秒数')
	断言 ($sleeps.Count -eq $期望[$名].同频睡) ("$名 按 $等待秒数 睡到下个汇报周期（实测 " + $sleeps.Count + " 处，期望 $($期望[$名].同频睡)）")
	$写死睡 = @(Select-String -LiteralPath $全路径 -Pattern 'Start-Sleep -Seconds \$重试次数')
	断言 ($写死睡.Count -eq 0) ("已无「按重试次数写死秒数」的旧 sleep（实测 " + $写死睡.Count + ' 处）')

	# 规则 5：单一时钟——进度行与中断行共用 $上次汇报时刻
	$推进点 = @([regex]::Matches($全文, '\$上次汇报时刻 = \$'))
	断言 ($推进点.Count -eq $期望[$名].推进) ("上次汇报时刻由进度行与中断行共同推进（实测赋值 " + $推进点.Count + " 处，期望 $($期望[$名].推进)）")

	# 规则 6：周期放宽只在「毫无进展 / 总量未知」时发生
	$放宽点 = @(Select-String -LiteralPath $全路径 -SimpleMatch -Pattern '$报告周期秒数++')
	断言 ($放宽点.Count -eq $期望[$名].放宽) ("周期放宽点数量 = 期望值 $($期望[$名].放宽)（实测 " + $放宽点.Count + ' 处：' + (($放宽点 | ForEach-Object { $_.LineNumber }) -join ',') + '）')
	$翻倍点 = @(Select-String -LiteralPath $全路径 -SimpleMatch -Pattern '$报告周期秒数 * 2')
	断言 ($翻倍点.Count -eq 0) ("周期绝不翻倍（停滞重建也只 +1；曾一度误改成翻倍，已撤销改回，实测 $($翻倍点.Count) 处：行 " + (($翻倍点 | ForEach-Object { $_.LineNumber }) -join ',') + '）')
	foreach ($判据 in $进展判据[$名]) {
		$次数 = @([regex]::Matches($代码文本表[$全路径], [regex]::Escape($判据[0]))).Count
		断言 ($次数 -eq $判据[1]) ("$($判据[2])：'$($判据[0])' 代码行命中 $次数 处（期望 $($判据[1])）")
	}

	# 规则 7：中断行措辞必须给出续传点与实际等待秒数（「N 秒后续传重试」）；不得再用「下个汇报周期」这种内部术语——中断行自己就是本轮的汇报，再说“下次汇报”会让人以为 N 秒是已过时的旧值
	$措辞不全 = @($中断发射 | Where-Object { $_.模板 -notmatch '秒后(续传)?重试' -or $_.模板 -match '下个汇报周期' })
	断言 ($措辞不全.Count -eq 0) ("中断行都措辞为「…N 秒后续传重试」（不合规 " + $措辞不全.Count + ' 条）')
}

# ============ 时钟纪律：安装流全量不自己打时间 ============
# 边界规则（2026-10-24 用户定调）：凡是会进入 Remote-SSH 日志流的输出，**两端一律不得自己打时间**——外层会自动给每个数据块标
#   [HH:mm:ss.fff] [preconnect]，而远端钟表未必同步（同批测试机实测：A 机 ≈0.2 秒、B 机 ≈226 秒且仍在漂），
#   两套时间轴混排会让人完全无法排序（已把「21 秒」误读成「4 分钟」）。取值一律依靠外层唯一时钟。
# 例外：**不进该日志流、外层没有标签**的自有输出面必须保留时间戳，否则永久失去可诊断性：
#   ① keepalive-wrapper.sh → $PERSIST_DIR/wrapper.log（远端本地文件）与 CLI 自己的 .cli.<提交号>.log（VS Code 重定向，不是 preconnect 流）；
#   ② extension.js / terminalRescue.js → 扩展自己的 OutputChannel（VS Code 不给它加时间标签）。
# 下面的“例外正向对照”断言就是守这条：如果例外清单变成“干脆把文件全排除”的借口，这两条会先红。
Write-Output ''
Write-Output '===== 时钟纪律（安装流全量） ====='

function 查-ps1内嵌时钟 {
	param([string]$文本)
	# 两种“把当前时间打进输出”的写法合成一个交替正则：Get-Date -Format、ToString('…HH:mm…')。返回违规**处数**（整数），不返回数组，免得调用侧误把元素个数当个数
	return @([regex]::Matches($文本, "Get-Date\s*-Format|ToString\('[^']*(HH|hh):mm")).Count
}

function 查-sh输出带时间 {
	param([string[]]$行集)
	# 违规 = 输出语句（echo/log/printf）+ $(date 同时出现**人类可读的时间格式**（+%F / +%T / %H:%M / %Y）。
	# 三个条件缺一不可：`date +%s`（纪元秒）是计算用途——版本目录按 mtime 排序的键（redirect 进临时文件，从不上屏）、
	# 补丁包的变更指纹（比对用）；同理 `|| echo 0` 这种兼容回退也不属于日志输出。只看“行里有 echo 且有 $(date”会把它们全误报（实测误报 4 处）。
	$命中 = @()
	for ($i = 0; $i -lt $行集.Count; $i++) {
		$是输出行 = ($行集[$i] -match '(^|[\s;&|(|{])(echo|log|printf)\b')
		$有时间输出 = ($行集[$i] -match '\$\(date') -and ($行集[$i] -match '\+%[FTY]|%H:%M|%T')
		if ($是输出行 -and $有时间输出) { $命中 += ($i + 1) }
	}
	return $命中
}

# 正向对照：先把违规样本喂给检查器，确认真能抓到（否则下面所有的 0 都是空集假通过）
断言 ((查-ps1内嵌时钟 "Write-Host ('[{0}] 下载完成。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))") -eq 1) '时钟检查器正向对照：ps1 违规样本被抓出（实测处数 = 1）'
断言 ((查-ps1内嵌时钟 "Write-Host ('完成')") -eq 0) '时钟检查器不误报：无时钟的输出行为 0 处'
断言 (@(查-sh输出带时间 @('log "[$(date "+%F %T")] 开始"')).Count -eq 1) '时钟检查器正向对照：sh 输出行带时间戳被抓出'
断言 (@(查-sh输出带时间 @('EVENT_NOW=$(date +%s)')).Count -eq 0) '时钟检查器不误报：纯计算用途的 date +%s 不算违规'
断言 (@(查-sh输出带时间 @('echo "$(date -r "$DIR" +%s 2>/dev/null || echo 0) $DIR" >> "$LIST_TMP"')).Count -eq 0) '时钟检查器不误报：排序键（纪元秒 + || echo 0 回退 + 重定向到临时文件）不算违规'

$ps1清单 = @(
	'scripts\安装实现.ps1',
	'scripts\private\remote-install-common.ps1',
	'scripts\private\local-supply.ps1',
	'scripts\private\windows-stdin-bootstrap.ps1',
	'scripts\private\Windows单会话引导.ps1',
	'接管安装实现.ps1'
)
foreach ($相对 in $ps1清单) {
	$全路径 = Join-Path $repo $相对
	if (-not (Test-Path -LiteralPath $全路径)) { 断言 $false ("时钟纪律：待查文件不存在 $相对"); continue }
	$命中 = 查-ps1内嵌时钟 ((Get-Content -LiteralPath $全路径 -Raw -Encoding UTF8))
	断言 ($命中 -eq 0) ("$([IO.Path]::GetFileName($相对)) 不自己打时间（交外层唯一时钟）：违规 $命中 处")
}
$sh清单 = @(
	'scripts\private\remote-install-linux.sh',
	'scripts\private\接管编排脚本模板.sh',
	'scripts\private\会话帧循环.sh',
	'scripts\private\native-patch.sh',
	'scripts\private\sysroot-deploy.sh',
	'scripts\private\keepalive-deploy.sh'
)
foreach ($相对 in $sh清单) {
	$全路径 = Join-Path $repo $相对
	if (-not (Test-Path -LiteralPath $全路径)) { 断言 $false ("时钟纪律：待查文件不存在 $相对"); continue }
	$行集 = @(Get-Content -LiteralPath $全路径 -Encoding UTF8)
	$命中 = @(查-sh输出带时间 $行集)
	断言 ($命中.Count -eq 0) ("$([IO.Path]::GetFileName($相对)) 不自己打时间（交外层唯一时钟）：违规 $($命中.Count) 处" + $(if ($命中.Count) { '，行 ' + (($命中) -join ',') } else { '' }))
}
# Linux 侧 log() 本体不得再加时间戳（回归守卫：曾为 `echo "[$(date …)] $*"`）
$sh正文 = Get-Content -LiteralPath (Join-Path $repo 'scripts\private\remote-install-linux.sh') -Raw -Encoding UTF8
断言 ($sh正文 -match 'log\(\)\s*\{\s*\r?\n\s*echo "\$\*"') 'Linux 侧 log() 就是裸 echo "$*"（不再拼时间戳）'
# 例外正向对照：两个自有输出面确实保留了时间戳
$包装正文 = Get-Content -LiteralPath (Join-Path $repo 'scripts\private\keepalive-wrapper.sh') -Raw -Encoding UTF8
断言 ($包装正文 -match '\$\(date') '例外① 保活包装脚本仍带时间戳（输出去远端本地 wrapper.log / CLI log，外层根本没标签；删了就永久无法定位事件先后）'
$扩展正文 = Get-Content -LiteralPath (Join-Path $repo 'extension.js') -Raw -Encoding UTF8
断言 ($扩展正文 -match 'toLocaleTimeString') '例外② 扩展终端救援 OutputChannel 仍带时间标签（VS Code 不给 OutputChannel 加标签）'

# ============ Linux sh ============
Write-Output ''
Write-Output '===== remote-install-linux.sh ====='
$sh路径 = Join-Path $repo 'scripts\private\remote-install-linux.sh'
$sh行 = @(Get-Content -LiteralPath $sh路径)
$sh全文 = ($sh行 -join "`n")
断言 ($sh全文 -notmatch 'log\s+.本次下载失败') '已无「本次下载失败，清理残留文件。」这条冗余日志'
断言 ($sh全文 -notmatch 'log\s+.上次下载失败') '已无「上次下载失败，等待 N 秒后开始第 M 次重试…」这条冗余日志'
断言 ($sh全文 -notmatch 'log "开始下载: \$URL"') '已无每源每轮都打的「开始下载: $URL」'
$事件调用 = @([regex]::Matches($sh全文, 'log_event "')).Count
断言 ($事件调用 -eq 3) ("三个下载循环各一处 event 调用（实测 $事件调用，期望 3）= 一次中断一条消息")
$同频睡 = @(Select-String -LiteralPath $sh路径 -SimpleMatch -Pattern 'sleep "$EVENT_SLEEP_NEXT"')
断言 ($同频睡.Count -eq 3) ("三处都按 EVENT_SLEEP_NEXT 睡到下个汇报周期（实测 " + $同频睡.Count + '，期望 3）')
$放宽 = @(Select-String -LiteralPath $sh路径 -SimpleMatch -Pattern 'EVENT_INTERVAL=$((EVENT_INTERVAL + 1))')
断言 ($放宽.Count -eq 3) ("三处「本轮毫无进展才放宽周期」（实测 " + $放宽.Count + '，期望 3）')
$定义行 = ($sh行 | Select-String -Pattern '^log_event\(\)' | Select-Object -First 1).LineNumber
$首调用 = ($sh行 | Select-String -Pattern '^\s+log_event "' | Select-Object -First 1).LineNumber
断言 ($定义行 -lt $首调用) ("log_event 定义（行 $定义行）早于首个调用（行 $首调用）：sh 逐行解释，顺序不能颠倒")
$首次守卫 = @([regex]::Matches($sh全文, 'if \[ "\$CLI_ATTEMPT" -eq 1 \]; then')).Count
断言 ($首次守卫 -eq 3) ("三处 CLI/源地址仍在「首次尝试」守卫内公布（实测 $首次守卫，期望 3）")

# ============ 并发隔离与远端结果码纪律（本轮线上事故的五个结构根因，全部变成可自动判定的规则） ============
Write-Output ''
Write-Output '===== 并发隔离与远端结果码纪律 ====='
function 取-代码文本([string]$路径) {
	return ((@(Get-Content -LiteralPath $路径) | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n")
}
$供给代码 = $代码文本表[$三份[1]]
$共通代码 = $代码文本表[$三份[0]]
$模块代码 = 取-代码文本 (Join-Path $repo 'scripts\安装实现.ps1')
$编排代码 = 取-代码文本 (Join-Path $repo 'scripts\private\接管编排脚本模板.sh')
$sh代码 = $代码文本表[$三份[2]]
断言 ($供给代码.Length -gt 8000 -and $模块代码.Length -gt 8000) ('取样正向对照：代码文本非空（供给 ' + $供给代码.Length + ' 字符 / 模块 ' + $模块代码.Length + ' 字符）')

# 规则 8：不靠非零退出码判成败。实测两台 Windows 主机的 OpenSSH sshd 把任何非零码压平成 1（exit 2/3/7 全变 1），
# 结果码必须走 stdout 标记；只允许对 0 做判定（0 能原样传回）。唯一例外：255 是 ssh 客户端自己的传输失败码（不经远端压缩）。
$非零码判定 = @()
foreach ($文 in @($共通代码, $供给代码, $模块代码)) {
	foreach ($匹 in @([regex]::Matches($文, '退出码\s*-(eq|ne)\s*[1-9]|LASTEXITCODE\s*-(eq|ne)\s*[1-9]\d*'))) {
		if ($匹.Value -match '255') { continue }
		$非零码判定 += $匹.Value
	}
}
断言 ($非零码判定.Count -eq 0) ('无「把远端非零退出码当区分信息」的判定（实测命中 ' + $非零码判定.Count + ' 处' + $(if ($非零码判定.Count -gt 0) { '：' + ($非零码判定 -join ', ') } else { '' }) + '；ssh 自身的 255 不在此列）')
foreach ($码 in @(0, 1, 2, 3)) {
	断言 ($供给代码.Contains('__VSI_RC__:' + $码)) ('远端改名脚本用 stdout 标记回传结果码 ' + $码 + '（Windows sshd 会把非零退出码压平成 1）')
}
断言 (@([regex]::Matches($供给代码, '__VSI_RC__\\s\*:\\s\*\(\\d\+\)')).Count -ge 1) '本地从 stdout 解析结果码（拿不到标记时退回退出码）'
断言 ($供给代码.Contains('$改名码 = $改名结果.退出码')) '解析前先以退出码兵底（远端未回标记时仍可判 0/非0）'
# 注意：消息若由 + 拼成，整段必须套括号。裸写在参数位置上时 + / 变量 / 尾串会被当成额外实参，
# 断言直接抛 PositionalParameterNotFound，脚本却接着往下跑、最后照样报「0 问题」——这条断言
# 因此曾长期根本没执行过（2026-10-23 迁移公共库台账时被 扫-裸拼接实参 抓出来）。
断言 (@([regex]::Matches($供给代码, '__VSI_ERR__:')).Count -ge 3) ('失败/幂等路径都带 __VSI_ERR__ 真因标记（实测 ' + ([regex]::Matches($供给代码, '__VSI_ERR__:')).Count + ' 处）')

# 规则 9：供给进程绝不共写同一个文件——下载到本进程私有名，完成后才发布为稳定成品名

断言 ($供给代码.Contains("'.downloading-' + `$PID")) '在途文件名带本进程 PID（两供给进程绝不写同一文件）'
断言 (@([regex]::Matches($供给代码, [regex]::Escape('$下载目标路径 = $在途路径'))).Count -eq 1) '下载目标初值为私有在途名（不是稳定成品名）'
断言 ($供给代码.Contains('测-文件被占用')) '先探测他方是否持锁（而不是直接开写报错）'
断言 ($供给代码.Contains('认领遗留半成品')) '能认领上轮被杀进程留下的半成品续传'
断言 ($供给代码.Contains('.solo')) '他方长时间无进展时升级为自己独立下载（不会死等）'
断言 ($供给代码.Contains('being used by another process')) '文件被占用归为非网络故障，不计入重试（线上刷屏主症状）'
断言 ($供给代码.Contains('Move-Item') -and $供给代码.Contains('-Destination $成品路径')) '完成后才把私有在途名发布为稳定成品名'

# 规则 10：父进程（连接）死了供给进程必须自行终止，不得留下孤儿长期占用缓存与带宽
断言 ($供给代码.Contains('function 测-父进程仍在')) '供给脚本内有父进程存活看门狗'
断言 (@([regex]::Matches($供给代码, '测-父进程仍在 ')).Count -ge 1) '看门狗在真实循环里被调用（不只定义不用）'
断言 ($模块代码.Contains('父进程ID = $PID')) '模块把自己的 PID 交给供给子进程'
断言 ($模块代码.Contains('local-supply') -and $模块代码.Contains('taskkill')) '模块启动新一批供给前会清掉孤儿供给进程'

# 规则 11：暂存目录绝不整目录删——并发连接的 .uploading 就住在那里
断言 (@([regex]::Matches($共通代码, [regex]::Escape('Remove-Item -LiteralPath $暂存目录 -Recurse'))).Count -eq 0) 'remote-install-common.ps1 已无整目录删除'
断言 (@([regex]::Matches($sh代码, 'rm -rf "\$STAGING"')).Count -eq 0) 'remote-install-linux.sh 已无整目录删除'
断言 (@([regex]::Matches($编排代码, [regex]::Escape("rm -rf '__暂存目录__'"))).Count -eq 0) '接管编排脚本模板.sh 已无整目录删除'
断言 (@([regex]::Matches($共通代码, '清理-竞速暂存目录')).Count -ge 3) ('改为逐项清理函数（定义 + 两处调用，实测 ' + ([regex]::Matches($共通代码, '清理-竞速暂存目录')).Count + ' 处）')
断言 ($sh代码.Contains('*.uploading')) 'sh 侧清理保留 .uploading 在途文件'
断言 ($编排代码.Contains('*.uploading')) '编排模板清理保留 .uploading 在途文件'
断言 ($模块代码.Contains('*.uploading) continue')) '竞速预备命令跳过 .uploading（Linux 侧）'

# 规则 12：远端 PowerShell 必须抑制进度条，否则 CLIXML 垃圾会把真因淹没（实测日志不可读的成因）
# 源码里该串嵌在单引号字面量中（内层引号双写），故按双写形态搜
断言 ($供给代码.Contains("`$ProgressPreference = ''SilentlyContinue''; ")) '远端命令开头一律抑制进度条'
断言 ($供给代码.Contains('取-远端命令摘要')) '回传前先过滤 ssh/CLIXML 噪声，只留真因摘要'

# ============ 规则 13：布尔谓词函数体内必须零输出（本轮最隐蔽的缺陷） ============
# 实测事故：测-父进程仍在 在 return $false 前用 Write-Output 打印了说明文字，于是调用处
#   if (-not (测-父进程仍在 '…')) { return }
# 收到的是 @('父进程已退出…', $false) —— 非空数组按真值判定恒为 $true，-not 之后恒为 $false，
# 看门狗从未生效：父进程（连接）被杀后供给子进程照常无限重试（线上存活 34 分钟、死握共用缓存文件）。
Write-Output ''
Write-Output '===== 布尔谓词纯净度（函数体内不得发射输出） ====='
$谓词文件 = @($三份[0], $三份[1], (Join-Path $repo 'scripts\安装实现.ps1'))
$谓词总数 = 0
$谓词污染 = @()
foreach ($文件 in $谓词文件) {
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($文件, [ref]$null, [ref]$null)
	$函数集 = @($ast.FindAll({ param($n) ($n -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($n.Name -match '^(测|测试|是否)') }, $true))
	$谓词总数 += $函数集.Count
	foreach ($fn in $函数集) {
		$发射 = @($fn.FindAll({ param($n) ($n -is [System.Management.Automation.Language.CommandAst]) -and ($n.CommandElements[0].Value -in @('Write-Output', 'Write-Host', 'Write-Warning', 'Write-Verbose', 'echo')) }, $true))
		if ($发射.Count -gt 0) { $谓词污染 += ((Split-Path -Leaf $文件) + ':' + $fn.Name + '（体内发射 ' + $发射.Count + ' 处，行 ' + (($发射 | ForEach-Object { $_.Extent.StartLineNumber }) -join ',') + '）') }
	}
}
断言 ($谓词总数 -ge 3) ("取样正向对照：确实扫到了布尔谓词函数（实测 $谓词总数 个，期望 >=3；为 0 说明本规则在空集上白过）")
断言 ($谓词污染.Count -eq 0) ('布尔谓词函数体内零输出发射（污染源 ' + $谓词污染.Count + ' 个' + $(if ($谓词污染.Count -gt 0) { '：' + ($谓词污染 -join '；') } else { '' }) + '）')

# 规则 14：父进程身份按「PID + 启动时刻」比对，不得只看 PID 是否存在（父死之后 PID 会被别的进程复用）
断言 ($供给代码.Contains('$父进程启动时刻')) '供给脚本记录了父进程启动时刻作为身份基线'
断言 (@([regex]::Matches($供给代码, '\.StartTime')).Count -ge 1) '看门狗按启动时刻判定父进程是否还是同一个（防 PID 复用误判存活）'
断言 (@([regex]::Matches($供给代码, 'if \(-not \(测-父进程仍在\)\)')).Count -ge 1) '看门狗在真实循环里被调用（谓词无参、说明文字由调用处打印）'

Write-Output ''
Write-Output ("审计问题总数: " + (取-断言计数).失败 + " (0 = 通过)")
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
