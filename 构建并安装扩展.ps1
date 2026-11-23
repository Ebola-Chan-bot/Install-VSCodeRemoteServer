[CmdletBinding()]
param(
	[switch]$仅构建,
	[switch]$仅安装
)

# 构建并安装「RemoteSSH服务器安装」扩展：把 接管远程服务器安装扩展 打包成 vsix，再装进本机 VS Code 与 VS Code Insiders；版本号取自 package.json，本脚本绝不修改版本号。
if ($仅构建 -and $仅安装) { throw '参数 -仅构建 与 -仅安装 不能同时使用。' }
$ErrorActionPreference = 'Stop'

function 读-扩展清单 {
	param([string]$扩展目录)

	# package.json 的 publisher/name/version 同时决定 vsix 文件名与安装目录名，是打包与安装的唯一事实来源
	$清单路径 = Join-Path $扩展目录 'package.json'
	if (-not (Test-Path -LiteralPath $清单路径)) { throw ('找不到扩展清单: {0}' -f $清单路径) }
	$清单 = Get-Content -LiteralPath $清单路径 -Raw -Encoding UTF8 | ConvertFrom-Json
	foreach ($字段 in @('name', 'publisher', 'version')) {
		$值 = [string]$清单.$字段
		if ([string]::IsNullOrWhiteSpace($值)) { throw ('package.json 缺少 {0} 字段。' -f $字段) }
	}
	return $清单
}

function 取-编辑器列表 {
	# 覆盖本机两处编辑器：优先官方安装位置的命令行工具，找不到再退回 PATH 上的 code / code-insiders
	$列表 = New-Object System.Collections.ArrayList
	$候选 = @(
		[pscustomobject]@{ 名 = 'VS Code'; CLI = (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'); 备用名 = 'code'; 扩展根 = (Join-Path $env:USERPROFILE '.vscode\extensions') }
		[pscustomobject]@{ 名 = 'VS Code Insiders'; CLI = (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd'); 备用名 = 'code-insiders'; 扩展根 = (Join-Path $env:USERPROFILE '.vscode-insiders\extensions') }
	)
	foreach ($项 in $候选) {
		$cli路径 = $项.CLI
		if (-not (Test-Path -LiteralPath $cli路径)) {
			$在路径上 = Get-Command $项.备用名 -ErrorAction SilentlyContinue | Select-Object -First 1
			if ($null -eq $在路径上) { Write-Host ('跳过 {0}：未找到命令行工具 {1}。' -f $项.名, $项.备用名); continue }
			$cli路径 = $在路径上.Source
		}
		[void]$列表.Add([pscustomobject]@{ 名 = $项.名; CLI = $cli路径; 扩展根 = $项.扩展根 })
	}
	return $列表
}

function 构建-扩展包 {
	param([string]$扩展目录, $清单)

	# 打包用 npx 现拉 @vscode/vsce，免装全局 vsce；输出 vsix 落扩展目录，命名与历史包一致 <name>-<version>.vsix
	$npx命令 = Get-Command npx -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -eq $npx命令) { throw '未找到 npx，请先安装 Node.js（vsce 打包依赖它）。' }
	$vsix路径 = Join-Path $扩展目录 ('{0}-{1}.vsix' -f $清单.name, $清单.version)
	Push-Location $扩展目录
	$原EAP = $ErrorActionPreference
	$ErrorActionPreference = 'SilentlyContinue'
	try {
		# 喂一行 y 应答 vsce 可能出现的 [y/N] 交互（有 license 字段但目录里没有 LICENSE 文件时会出现），无人值守绝不允许挂住；无提示时多余输入无副作用
		# PS 5.1 会把原生命令 stderr 额外写一份到错误流并当 NativeCommandError 显示，Stop 下还会直接炸；SilentlyContinue 压显示，stderr 文本仍由 2>&1 收进 $输出，成败一律以退出码判定
		$输出 = ('y' | & $npx命令.Source --yes '@vscode/vsce' package --out $vsix路径 2>&1 | Out-String)
		$退出码 = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $原EAP
		Pop-Location
	}
	if ($退出码 -ne 0) { throw ('打包失败（退出码 {0}）：{1}' -f $退出码, $输出) }
	if (-not (Test-Path -LiteralPath $vsix路径)) { throw ('打包未生成 vsix: {0}' -f $vsix路径) }
	$vsix信息 = Get-Item -LiteralPath $vsix路径
	# 本函数的返回值（vsix 路径）被调用方捕获，说明文字一律走 Write-Host，混入管道会把返回值变成数组、后续当路径用就全盘错乱
	Write-Host $输出.TrimEnd()
	Write-Host ('构建完成: {0}（{1:N0} 字节）' -f $vsix信息.FullName, $vsix信息.Length)
	Write-Host ('SHA256: {0}' -f (Get-FileHash -LiteralPath $vsix路径 -Algorithm SHA256).Hash)
	return $vsix路径
}

function 安装-扩展包 {
	param($编辑器, [string]$vsix路径, [string]$扩展目录, [string]$扩展标识, [string]$版本)

	$原EAP = $ErrorActionPreference
	$ErrorActionPreference = 'SilentlyContinue'
	try {
		# code 命令行工具可能向 stderr 写警告，同压显示，成败以退出码判定
		$输出 = (& $编辑器.CLI --install-extension $vsix路径 --force 2>&1 | Out-String)
		$退出码 = $LASTEXITCODE
	} finally {
		$ErrorActionPreference = $原EAP
	}
	if ($退出码 -ne 0) { throw ('{0} 安装失败（退出码 {1}）：{2}' -f $编辑器.名, $退出码, $输出) }
	$目标目录 = Join-Path $编辑器.扩展根 ('{0}-{1}' -f $扩展标识, $版本)
	if (-not (Test-Path -LiteralPath $目标目录)) { throw ('{0} 安装后找不到扩展目录: {1}' -f $编辑器.名, $目标目录) }
	# 抽查关键文件哈希，闭环确认装进编辑器的正是本次构建内容，而不是旧版本或半套文件
	foreach ($相对路径 in @('extension.js', '接管安装实现.ps1', (Join-Path 'scripts' '安装实现.ps1'))) {
		$源哈希 = (Get-FileHash -LiteralPath (Join-Path $扩展目录 $相对路径) -Algorithm SHA256).Hash
		$装哈希 = (Get-FileHash -LiteralPath (Join-Path $目标目录 $相对路径) -Algorithm SHA256).Hash
		if ($源哈希 -ne $装哈希) { throw ('{0} 安装内容与源码不一致: {1}' -f $编辑器.名, $相对路径) }
	}
	Write-Host ('{0} 安装并核对完成: {1}' -f $编辑器.名, $目标目录)
}

$扩展目录 = Join-Path $PSScriptRoot '接管远程服务器安装扩展'
if (-not (Test-Path -LiteralPath $扩展目录)) { throw ('找不到扩展目录: {0}' -f $扩展目录) }
$清单 = 读-扩展清单 -扩展目录 $扩展目录
$发布者 = ([string]$清单.publisher).ToLowerInvariant()
$包名 = ([string]$清单.name).ToLowerInvariant()
$扩展标识 = '{0}.{1}' -f $发布者, $包名
$版本 = [string]$清单.version
Write-Output ('扩展: {0} 版本 {1}' -f $扩展标识, $版本)

$vsix路径 = Join-Path $扩展目录 ('{0}-{1}.vsix' -f $清单.name, $版本)
if (-not $仅安装) {
	$vsix路径 = 构建-扩展包 -扩展目录 $扩展目录 -清单 $清单
}
if ($仅构建) {
	Write-Output '仅构建完成，未执行安装。'
} else {
	if (-not (Test-Path -LiteralPath $vsix路径)) { throw ('找不到安装包: {0}（先不带 -仅安装 跑一次构建）' -f $vsix路径) }
	$编辑器列表 = 取-编辑器列表
	if ($编辑器列表.Count -eq 0) { throw '未找到任何 VS Code 命令行工具，无法安装。' }
	foreach ($编辑器 in $编辑器列表) {
		安装-扩展包 -编辑器 $编辑器 -vsix路径 $vsix路径 -扩展目录 $扩展目录 -扩展标识 $扩展标识 -版本 $版本
	}
	Write-Output '构建并安装全部完成。扩展宿主里已加载的旧代码不会自动重载，请重新加载窗口（或重启编辑器）后生效。'
}
