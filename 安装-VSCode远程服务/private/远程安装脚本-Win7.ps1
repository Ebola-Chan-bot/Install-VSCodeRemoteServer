# 远程安装脚本（Win7 适配版）
# 兼容 PowerShell 2.0 / Windows 7
# 此文件通过主脚本上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。

$ErrorActionPreference = 'Stop'

# PowerShell 版本自检
if ($PSVersionTable.PSVersion.Major -lt 2) {
	throw '需要 PowerShell 2.0 或更高版本。'
}

# .NET TLS 1.2（对 BITS 无效，但对 Invoke-WebRequest 等有用）
try {
	[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
} catch {
	Write-Host '注意: 无法设置 .NET TLS 1.2，BITS 下载走 WinHTTP 通道不受影响。'
}

# WinHTTP TLS 1.2 注册表配置（BITS 依赖此项）
function 启用-WinHttpTls12 {
	# 使用 reg.exe 而非 PS 注册表驱动，避免 PS 2.0 兼容性问题
	$路径列表 = @(
		'SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp',
		'SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp'
	)

	foreach ($路径 in $路径列表) {
		try {
			$regArgs = @('add', "HKLM\$路径", '/v', 'DefaultSecureProtocols', '/t', 'REG_DWORD', '/d', '2048', '/f')
			$result = & reg.exe $regArgs 2>&1
			if ($LASTEXITCODE -eq 0) {
				Write-Host "已配置 WinHTTP TLS 1.2: HKLM\$路径"
			} else {
				Write-Host "注意: 无法配置 WinHTTP TLS 1.2: HKLM\$路径 ($result)"
			}
		} catch {
			Write-Host "注意: reg.exe 调用失败: $_"
		}
	}
}

function 取-系统架构标识 {
	$原始架构 = if ($env:PROCESSOR_ARCHITEW6432) {
		$env:PROCESSOR_ARCHITEW6432
	} elseif ($env:PROCESSOR_ARCHITECTURE) {
		$env:PROCESSOR_ARCHITECTURE
	} else {
		$null
	}

	if ([string]::IsNullOrEmpty($原始架构) -or $原始架构.Trim().Length -eq 0) {
		throw '未能自动检测远程系统架构。'
	}

	switch ($原始架构.ToUpperInvariant()) {
		'AMD64' { return 'win32-x64' }
		'X64' { return 'win32-x64' }
		'ARM64' { return 'win32-arm64' }
		default { throw ('暂不支持的远程系统架构: {0}' -f $原始架构) }
	}
}

function 取-安装目录 {
	param(
		[string]$通道,
		[string]$版本提交号
	)

	$安装根目录 = if ($通道 -eq 'insider') {
		Join-Path $HOME '.vscode-server-insiders\bin'
	} else {
		Join-Path $HOME '.vscode-server\bin'
	}

	return Join-Path $安装根目录 $版本提交号
}

function 取-下载地址 {
	param(
		[string]$通道,
		[string]$版本提交号,
		[string]$架构
	)

	$文件名 = 'vscode-server-{0}.zip' -f $架构
	return 'https://vscode.download.prss.microsoft.com/dbazure/download/{0}/{1}/{2}' -f $通道, $版本提交号, $文件名
}

function 停止-占用安装目录的进程 {
	param(
		[string]$安装目录,
		[string]$版本提交号
	)

	# PS 2.0 兼容：使用 Get-WmiObject 代替 Get-CimInstance
	$进程列表 = Get-WmiObject Win32_Process -ErrorAction SilentlyContinue | Where-Object {
		($_.ExecutablePath -and ($_.ExecutablePath -like ($安装目录 + '*'))) -or
		($_.CommandLine -and ($_.CommandLine -like ('*' + $版本提交号 + '*')))
	}

	if ($进程列表) {
		foreach ($进程 in $进程列表) {
			try {
				Stop-Process -Id $进程.ProcessId -Force -ErrorAction SilentlyContinue
			} catch {
			}
		}
	}
}

function 展开-服务器压缩包 {
	param(
		[string]$压缩包路径,
		[string]$目标目录
	)

	# 尝试 .NET 4.5 ZipFile，失败则回退到 Shell.Application COM
	$解压成功 = $false
	try {
		Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
		[System.IO.Compression.ZipFile]::ExtractToDirectory($压缩包路径, $目标目录)
		$解压成功 = $true
		Write-Host '使用 .NET ZipFile 解压完成。'
	} catch {
		Write-Host '.NET ZipFile 不可用，尝试 COM 解压...'
	}

	if (-not $解压成功) {
		New-Item -ItemType Directory -Force $目标目录 | Out-Null
		$shell = New-Object -ComObject Shell.Application
		$zip = $shell.NameSpace($压缩包路径)
		if ($null -eq $zip) {
			throw '无法打开压缩包。'
		}
		foreach ($item in $zip.Items()) {
			$shell.NameSpace($目标目录).CopyHere($item, 0x14)
		}
		# COM CopyHere 是异步的，等待完成
		$等待上限 = 120
		$已等待 = 0
		while ($已等待 -lt $等待上限) {
			$目标项 = Get-ChildItem $目标目录 -ErrorAction SilentlyContinue
			$压缩项 = @($zip.Items())
			if ($目标项.Count -ge $压缩项.Count) {
				break
			}
			Start-Sleep -Seconds 1
			$已等待++
		}
		Write-Host 'COM 解压完成。'
	}

	# 处理单层内目录
	$目录项列表 = @(Get-ChildItem -Force $目标目录)
	if ($目录项列表.Count -eq 1 -and $目录项列表[0].PSIsContainer) {
		$内层目录 = $目录项列表[0]
		Get-ChildItem -Force $内层目录.FullName | Move-Item -Destination $目标目录 -Force
		Remove-Item $内层目录.FullName -Recurse -Force
	}

	# 处理 vscode-server-* 包装目录
	$包装目录 = Get-ChildItem -Force $目标目录 | Where-Object { $_.PSIsContainer -and $_.Name -like 'vscode-server-*' } | Select-Object -First 1
	if ($包装目录) {
		foreach ($包装目录项 in (Get-ChildItem -Force $包装目录.FullName)) {
			$目标路径 = Join-Path $目标目录 $包装目录项.Name
			if (-not (Test-Path $目标路径)) {
				Move-Item $包装目录项.FullName -Destination $目标目录 -Force
			}
		}
		Remove-Item $包装目录.FullName -Recurse -Force
	}

	Remove-Item $压缩包路径 -Force -ErrorAction SilentlyContinue
}

# ===== 主流程 =====

Write-Host ('远程 PowerShell 版本: {0}' -f $PSVersionTable.PSVersion)

# 配置 WinHTTP TLS 1.2（BITS 下载 HTTPS 必需）
启用-WinHttpTls12
Write-Host 'WinHTTP 配置完成，开始安装流程。'

$提交号 = '__提交号__'
$发布通道 = '__发布通道__'
$系统架构 = 取-系统架构标识
$最终安装目录 = 取-安装目录 -通道 $发布通道 -版本提交号 $提交号
$压缩包路径 = Join-Path $最终安装目录 ('vscode-server-{0}.zip' -f ([guid]::NewGuid().ToString('N')))
$上传压缩包路径 = Join-Path $HOME 'vscode-server-upload-temp.zip'
$下载地址 = 取-下载地址 -通道 $发布通道 -版本提交号 $提交号 -架构 $系统架构

Write-Host ('准备安装 VS Code 远程服务，提交号: {0}' -f $提交号)
Write-Host ('发布通道: {0}' -f $发布通道)
Write-Host ('自动检测到的系统架构: {0}' -f $系统架构)
Write-Host ('自动检测到的安装目录: {0}' -f $最终安装目录)
Write-Host ('下载地址: {0}' -f $下载地址)

Write-Host '停止占用进程...'
停止-占用安装目录的进程 -安装目录 $最终安装目录 -版本提交号 $提交号
Write-Host '进程检查完成。'
Write-Host '步骤A: 检查已有目录...'
if (Test-Path $最终安装目录) {
	Write-Host '步骤B: 安装目录已存在，保留目录本身。'
}
Write-Host '步骤D: 创建安装目录...'
New-Item -ItemType Directory -Force $最终安装目录 | Out-Null
Write-Host '步骤D1: 清理旧压缩包...'
Get-ChildItem -Path $最终安装目录 -Filter 'vscode-server*.zip' -ErrorAction SilentlyContinue |
	ForEach-Object {
		Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
	}
Write-Host '步骤E: 检查已上传压缩包...'
if (-not (Test-Path $上传压缩包路径)) {
	throw ('未找到已上传的压缩包: {0}' -f $上传压缩包路径)
}
Write-Host '步骤F: 移动已上传压缩包到安装目录...'
try {
	Move-Item -Path $上传压缩包路径 -Destination $压缩包路径 -Force -ErrorAction Stop
} catch {
	Write-Host ('移动失败，改用复制+删除: {0}' -f $_.Exception.Message)
	Copy-Item -Path $上传压缩包路径 -Destination $压缩包路径 -Force -ErrorAction Stop
	Remove-Item -Path $上传压缩包路径 -Force -ErrorAction SilentlyContinue
}
Write-Host '步骤G: 压缩包已就位。'

if (-not (Test-Path $压缩包路径)) {
	throw ('下载完成后未找到压缩包: {0}' -f $压缩包路径)
}

Write-Host '下载完成，开始解压。'
展开-服务器压缩包 -压缩包路径 $压缩包路径 -目标目录 $最终安装目录

Write-Host '安装完成，当前目录内容如下。'
Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize
