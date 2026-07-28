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
	$路径列表 = @(
		'Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp',
		'SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp',
		'SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp'
	)

	foreach ($路径 in $路径列表) {
		try {
			$regPath = "HKLM:\$路径"
			# 先尝试读取现有值，若已包含 TLS 1.2 标志则跳过
			$现有值 = Get-ItemProperty -Path $regPath -Name 'DefaultSecureProtocols' -ErrorAction SilentlyContinue
			if ($现有值 -and ($现有值.DefaultSecureProtocols -band 0x800) -eq 0x800) {
				continue
			}

			$新值 = if ($现有值) { $现有值.DefaultSecureProtocols -bor 0x800 } else { 0x800 }
			New-Item -Path $regPath -Force -ErrorAction SilentlyContinue | Out-Null
			Set-ItemProperty -Path $regPath -Name 'DefaultSecureProtocols' -Value $新值 -Type DWord -Force -ErrorAction SilentlyContinue
			Write-Host "已配置 WinHTTP TLS 1.2: $regPath"
		} catch {
			Write-Host "注意: 无法配置 $regPath (可能需要管理员权限)"
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

	if ([string]::IsNullOrWhiteSpace($原始架构)) {
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
		($_.ExecutablePath -and $_.ExecutablePath.StartsWith($安装目录, [StringComparison]::OrdinalIgnoreCase)) -or
		($_.CommandLine -and $_.CommandLine -like ('*' + $版本提交号 + '*'))
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

function 取-BITS任务 {
	param(
		[string]$任务名称,
		[string]$目标路径
	)

	# PS 2.0 兼容：显式导入 BITS 模块
	Import-Module BitsTransfer -ErrorAction SilentlyContinue

	return Get-BitsTransfer -ErrorAction SilentlyContinue |
		Where-Object { $_.DisplayName -eq $任务名称 -or $_.Destination -eq $目标路径 } |
		Select-Object -First 1
}

function 等待-BITS任务完成 {
	param(
		[string]$任务名称,
		[string]$目标路径,
		[int]$恢复上限,
		[int]$等待秒数,
		[int]$超时秒数
	)

	$已恢复次数 = 0
	$开始时间 = Get-Date

	while ($true) {
		$当前任务 = 取-BITS任务 -任务名称 $任务名称 -目标路径 $目标路径
		if ($null -eq $当前任务) {
			if (Test-Path $目标路径) {
				return
			}

			throw '未找到正在执行的 BITS 下载任务。'
		}

		$当前状态 = [string]$当前任务.JobState
		# PS 2.0 兼容：使用 [double] 避免 [uint64] 不可用
		$总字节数 = [double]$当前任务.BytesTotal
		$已传字节数 = [double]$当前任务.BytesTransferred
		$总大小未知 = ($当前任务.BytesTotal -ge [uint64]::MaxValue -or $总字节数 -le 0)
		$当前进度 = if ((-not $总大小未知) -and $总字节数 -gt 0) {
			try {
				[math]::Round(($已传字节数 * 100.0) / $总字节数, 1)
			} catch {
				0
			}
		} else {
			0
		}
		$总字节显示 = if ($总大小未知) {
			'未知'
		} else {
			[string][long]$总字节数
		}

		Write-Host ('状态: {0} | 进度: {1}% | {2} / {3} 字节' -f $当前状态, $当前进度, [long]$已传字节数, $总字节显示)

		if ($当前状态 -eq 'Transferred') {
			Complete-BitsTransfer -BitsJob $当前任务
			return
		}

		if ($当前状态 -eq 'TransientError' -or $当前状态 -eq 'Error') {
			if ($已恢复次数 -ge $恢复上限) {
				throw ('BITS 下载失败，超过最大恢复次数。当前状态: {0}' -f $当前状态)
			}

			$已恢复次数++
			Write-Host ('检测到传输中断，开始第 {0} 次恢复。' -f $已恢复次数)
			try {
				Resume-BitsTransfer -BitsJob $当前任务 -Asynchronous
			} catch {
				Write-Host ('恢复失败: {0}' -f $_)
			}
		}

		if ($超时秒数 -gt 0) {
			$已耗时 = ((Get-Date) - $开始时间).TotalSeconds
			if ($已耗时 -gt $超时秒数) {
				throw ('BITS 下载超时（{0} 秒），当前状态: {1}' -f $超时秒数, $当前状态)
			}
		}

		Start-Sleep -Seconds $等待秒数
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

$提交号 = '2be9624b801009a53db8f629bd7762137d100007'
$发布通道 = 'insider'
$轮询秒数 = [int]'3'
$最大恢复次数 = [int]'5'
$超时秒数 = [int]'120'
$系统架构 = 取-系统架构标识
$最终安装目录 = 取-安装目录 -通道 $发布通道 -版本提交号 $提交号
$压缩包路径 = Join-Path $最终安装目录 'vscode-server.zip'
$下载地址 = 取-下载地址 -通道 $发布通道 -版本提交号 $提交号 -架构 $系统架构
$任务名称 = 'VSCode远程服务-' + $提交号

Write-Host ('准备安装 VS Code 远程服务，提交号: {0}' -f $提交号)
Write-Host ('发布通道: {0}' -f $发布通道)
Write-Host ('自动检测到的系统架构: {0}' -f $系统架构)
Write-Host ('自动检测到的安装目录: {0}' -f $最终安装目录)
Write-Host ('下载地址: {0}' -f $下载地址)

停止-占用安装目录的进程 -安装目录 $最终安装目录 -版本提交号 $提交号

if (Test-Path $最终安装目录) {
	Remove-Item $最终安装目录 -Recurse -Force -ErrorAction SilentlyContinue
}

New-Item -ItemType Directory -Force $最终安装目录 | Out-Null
Start-Service BITS -ErrorAction SilentlyContinue

$旧任务 = 取-BITS任务 -任务名称 $任务名称 -目标路径 $压缩包路径
if ($null -ne $旧任务) {
	Remove-BitsTransfer -BitsJob $旧任务 -Confirm:$false -ErrorAction SilentlyContinue
}

Write-Host '开始通过 BITS 下载压缩包。'
Start-BitsTransfer -Source $下载地址 -Destination $压缩包路径 -DisplayName $任务名称 -Asynchronous | Out-Null

$新任务 = $null
for ($序号 = 0; $序号 -lt 10; $序号++) {
	$新任务 = 取-BITS任务 -任务名称 $任务名称 -目标路径 $压缩包路径
	if ($null -ne $新任务) {
		break
	}

	Start-Sleep -Seconds 1
}

if ($null -eq $新任务) {
	throw '已发起下载，但未找到新建的 BITS 任务。'
}

等待-BITS任务完成 -任务名称 $任务名称 -目标路径 $压缩包路径 -恢复上限 $最大恢复次数 -等待秒数 $轮询秒数 -超时秒数 $超时秒数

if (-not (Test-Path $压缩包路径)) {
	throw ('下载完成后未找到压缩包: {0}' -f $压缩包路径)
}

Write-Host '下载完成，开始解压。'
展开-服务器压缩包 -压缩包路径 $压缩包路径 -目标目录 $最终安装目录

Write-Host '安装完成，当前目录内容如下。'
Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize
