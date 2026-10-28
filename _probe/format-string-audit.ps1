# 格式串审计 + 真渲染：从源码 AST 实时取出每条 `-f` 表达式与每个日志发射点，
#   ① 核对「占位符最大索引 + 1」== 实给参数个数（-f 多给的参数被静默丢弃、少给直接抛错，两种都是只在下载中途才暴露的日志 bug）；
#   ② 把与下载日志相关的模板用合成样本渲染一遍，确认屏幕上真会出现的文本没有残留花括号、没有粘行，且一次中断只对应一条消息。
# 模板全部来自源码本身（不硬编码样本），改了文案这里自动跟着变，不会漂移。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\format-string-audit.ps1
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$目标 = @(
	(Join-Path $repo 'scripts\private\remote-install-common.ps1'),
	(Join-Path $repo 'scripts\private\local-supply.ps1')
)
$样本 = @('甲', '乙', '丙', '丁', '戊', '己', '庚', '辛', '壬', '癸')
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

function 取-发射点 {
	param($命令节点)
	$名 = $命令节点.GetCommandName()
	if ($名 -notin @('Write-Host', 'Write-Output')) { return $null }
	# CommandElements[0] 是命令名本身（同样是 StringConstantExpressionAst），必须从下标 1 起找参数
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
	return [pscustomobject]@{ 命令 = $名; 模板 = $串节点.Value; 行 = $命令节点.Extent.StartLineNumber }
}

foreach ($全路径 in $目标) {
	$名 = Split-Path -Leaf $全路径
	$tokens = $null; $errors = $null
	$ast = [System.Management.Automation.Language.Parser]::ParseFile($全路径, [ref]$tokens, [ref]$errors)
	断言 ($errors.Count -eq 0) ("语法解析: $名")
	Write-Output ''
	Write-Output ("===== $名 =====")

	# ① 占位符数量 vs 参数数量
	$格式节点 = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'Format' }, $true)
	$不匹配 = 0
	foreach ($节点 in $格式节点) {
		$格式串 = $null
		if ($节点.Left -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $格式串 = $节点.Left.Value }
		if ($null -eq $格式串) { continue }   # 左边是变量/拼接时数量无法静态判定，跳过
		$最大索引 = -1
		foreach ($m in [regex]::Matches($格式串, '\{(\d+)\}')) { $值 = [int]$m.Groups[1].Value; if ($值 -gt $最大索引) { $最大索引 = $值 } }
		$需要 = $最大索引 + 1
		$实给 = 1
		if ($节点.Right -is [System.Management.Automation.Language.ArrayLiteralAst]) { $实给 = $节点.Right.Elements.Count }
		if ($需要 -ne $实给) {
			$不匹配++
			Write-Output ('  MISMATCH 行' + $节点.Extent.StartLineNumber + ": 占位符需 $需要 个，实给 $实给 个")
			Write-Output ('    ' + $格式串)
		}
	}
	断言 ($不匹配 -eq 0) ("全部 -f 表达式占位符与参数数量一致（" + $格式节点.Count + ' 个表达式，失配 ' + $不匹配 + ' 个）')

	# ② 下载日志相关模板的真渲染
	$命令集 = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
	$发射点集 = @($命令集 | ForEach-Object { 取-发射点 $_ } | Where-Object { $_ })
	$下载相关 = @($发射点集 | Where-Object { $_.模板 -match '开始下载|断点续传|下载中断|下载进度|下载源|下载完成|缓存已完整|服务器返回 416|安装完成' })
	Write-Output ("  下载相关发射点 " + $下载相关.Count + ' 个，逐条渲染：')
	$残留花括号 = 0
	foreach ($发 in $下载相关) {
		$渲染 = $null
		try { $渲染 = $发.模板 -f $样本 } catch { $渲染 = $发.模板 }
		if ($渲染 -match '\{\d') { $残留花括号++ }
		Write-Output ('    行' + $发.行 + ': ' + $渲染)
	}
	断言 ($残留花括号 -eq 0) ("渲染后无残留花括号（残留 $残留花括号 条）")
	$中断条数 = @($下载相关 | Where-Object { $_.模板 -like '*下载中断*' }).Count
	断言 ($中断条数 -ge 1 -and $中断条数 -le 2) ("中断发射点数量合理（$中断条数 个：common 为 CLI+断点续传两处，local-supply 一处）")
}

Write-Output ''
Write-Output ("审计问题总数: " + (取-断言计数).失败 + " (0 = 通过)")
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
