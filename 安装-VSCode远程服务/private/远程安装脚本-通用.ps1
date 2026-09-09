# 远程安装脚本（通用版）
# 要求远程 PowerShell 3.0+
# 此文件通过主脚本上传到远程主机执行，__占位符__ 会在上传前被替换为实际值。

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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

	# 新版 exec server 布局：<数据目录>\cli\servers\<质量名>-<提交号>\server
	# 旧版 bin\<提交号> 布局已不再写入（Remote-SSH 的 CLI 只认新布局）
	$质量名 = if ($通道 -eq 'insider') { 'Insiders' } else { 'Stable' }
	$数据目录 = if ($通道 -eq 'insider') {
		Join-Path $HOME '.vscode-server-insiders'
	} else {
		Join-Path $HOME '.vscode-server'
	}

	return Join-Path $数据目录 ('cli\servers\{0}-{1}\server' -f $质量名, $版本提交号)
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

	$进程列表 = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
		($_.ExecutablePath -and $_.ExecutablePath.StartsWith($安装目录, [System.StringComparison]::OrdinalIgnoreCase)) -or
		($_.CommandLine -and $_.CommandLine -like ('*' + $版本提交号 + '*'))
	}

	foreach ($进程 in $进程列表) {
		try {
			Stop-Process -Id $进程.ProcessId -Force -ErrorAction SilentlyContinue
		} catch {
		}
	}
}

function 通过HTTP断点续传下载 {
	param(
		[string]$下载地址,
		[string]$目标路径
	)

	# 基于 HTTP Range 头的断点续传：本地已存在部分文件时从偏移处继续。
	# 不限重试次数与总时长，失败等待秒数逐次递增（1秒、2秒、3秒……），所有输出带时间戳。
	$重试次数 = 0
	while ($true) {
		$重试次数++
		$已存在字节数 = 0
		if (Test-Path $目标路径) {
			$已存在字节数 = (Get-Item $目标路径).Length
		}

		try {
			$Web请求 = [System.Net.HttpWebRequest]::Create($下载地址)
			$Web请求.Timeout = 60000
			$Web请求.ReadWriteTimeout = 60000
			if ($已存在字节数 -gt 0) {
				$Web请求.AddRange($已存在字节数)
				Write-Host ('[{0}] 从 {1} 字节处断点续传（第 {2} 次尝试）: {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $已存在字节数, $重试次数, $下载地址)
			} else {
				Write-Host ('[{0}] 开始下载（第 {1} 次尝试）: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $重试次数, $下载地址)
			}

			$响应 = $Web请求.GetResponse()
			$状态码 = [int]$响应.StatusCode
			$响应流 = $null
			$文件流 = $null
			try {
				if ($状态码 -eq 206) {
					# 服务器支持断点续传：以追加方式写入剩余内容，文件总长度 = 已有部分 + 本次 ContentLength
					$内容总长度 = $已存在字节数 + $响应.ContentLength
					if ($响应.ContentLength -lt 0) { $内容总长度 = 0 }
					$文件流 = [System.IO.File]::Open($目标路径, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
				} elseif ($状态码 -eq 200) {
					if ($已存在字节数 -gt 0) {
						Write-Host ('[{0}] 服务器未响应 Range 请求（返回 200），将重新完整下载。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
					}

					$内容总长度 = $响应.ContentLength
					if ($内容总长度 -lt 0) { $内容总长度 = 0 }
					$文件流 = [System.IO.File]::Open($目标路径, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
				} else {
					throw ('收到意外的 HTTP 状态码: {0}' -f $状态码)
				}

				$响应流 = $响应.GetResponseStream()
				$缓冲区 = New-Object byte[] 65536
				$已写入字节数 = 0
				$上次报告时间 = [datetime]::MinValue
				while ($true) {
					$读取字节数 = $响应流.Read($缓冲区, 0, $缓冲区.Length)
					if ($读取字节数 -le 0) { break }

					$文件流.Write($缓冲区, 0, $读取字节数)
					$已写入字节数 += $读取字节数
					$当前时间 = Get-Date
					if (($当前时间 - $上次报告时间).TotalSeconds -ge 1) {
						$上次报告时间 = $当前时间
						$已传总字节数 = $已存在字节数 + $已写入字节数
						if ($内容总长度 -gt 0) {
							$进度 = [math]::Round(($已传总字节数 * 100.0) / $内容总长度, 1)
							Write-Host ('[{0}] 状态: Transferring | 进度: {1}% | {2} / {3} 字节' -f ($当前时间.ToString('yyyy-MM-dd HH:mm:ss')), $进度, $已传总字节数, $内容总长度)
						} else {
							Write-Host ('[{0}] 状态: Transferring | 已传: {1} 字节' -f ($当前时间.ToString('yyyy-MM-dd HH:mm:ss')), $已传总字节数)
						}
					}
				}
			} finally {
				if ($null -ne $响应流) { $响应流.Dispose() }
				if ($null -ne $文件流) { $文件流.Dispose() }
				$响应.Dispose()
			}

			if ($内容总长度 -gt 0 -and (Get-Item $目标路径).Length -lt $内容总长度) {
				throw ('下载提前结束: 文件 {0} 字节，预期至少 {1} 字节。' -f (Get-Item $目标路径).Length, $内容总长度)
			}

			Write-Host ('[{0}] 下载完成。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
			return
		} catch {
			Write-Host ('[{0}] 第 {1} 次下载中断: {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $重试次数, $_.Exception.Message)
		}

		# 保留已下载的部分文件，等待递增秒数后自动续传重试（1秒、2秒、3秒……）
		Start-Sleep -Seconds $重试次数
	}
}

function 展开-服务器压缩包 {
	param(
		[string]$压缩包路径,
		[string]$目标目录
	)

	Expand-Archive -Path $压缩包路径 -DestinationPath $目标目录 -Force

	$目录项列表 = @(Get-ChildItem -Force $目标目录)
	if ($目录项列表.Count -eq 1 -and $目录项列表[0].PSIsContainer) {
		$内层目录 = $目录项列表[0]
		Get-ChildItem -Force $内层目录.FullName | Move-Item -Destination $目标目录 -Force
		Remove-Item $内层目录.FullName -Recurse -Force
	}

	$包装目录 = Get-ChildItem -Force $目标目录 -Directory | Where-Object { $_.Name -like 'vscode-server-*' } | Select-Object -First 1
	if ($null -ne $包装目录) {
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

$提交号 = '__提交号__'
$发布通道 = '__发布通道__'
$系统架构 = 取-系统架构标识
$最终安装目录 = 取-安装目录 -通道 $发布通道 -版本提交号 $提交号
# 固定文件名（不含随机后缀），使同一安装目录下的下载路径确定，便于识别与断点续传定位
$下载压缩包路径 = Join-Path $最终安装目录 'vscode-server-download.zip'
$下载地址 = 取-下载地址 -通道 $发布通道 -版本提交号 $提交号 -架构 $系统架构

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

Write-Host '开始通过 HTTP 断点续传下载压缩包。'
通过HTTP断点续传下载 -下载地址 $下载地址 -目标路径 $下载压缩包路径

if (-not (Test-Path $下载压缩包路径)) {
	throw ('下载完成后未找到压缩包: {0}' -f $下载压缩包路径)
}

Write-Host '下载完成，开始解压。'
展开-服务器压缩包 -压缩包路径 $下载压缩包路径 -目标目录 $最终安装目录

Write-Host '安装完成，当前目录内容如下。'
Get-ChildItem -Force $最终安装目录 | Select-Object Name, Length, Mode | Format-Table -AutoSize
