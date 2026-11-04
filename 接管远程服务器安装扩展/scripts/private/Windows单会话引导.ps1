# Windows 单会话引导：由 执行-Windows单会话安装 取本文件把载荷占位符替换为安装脚本正文（去整行注释与空行后 gzip+base64）后下发到远端执行。
# 下发通道：本文件整体（含替换后的载荷）再按 UTF-16 base64 一次，经 **stdin** 送到远端，由 private\windows-stdin-bootstrap.ps1 那段固定引导解码并调用。
# 载荷与守卫文件落盘后用标准 PowerShell 调用语法（& 路径）执行，$PSScriptRoot 指向真实目录，同目录的兄弟文件（如 ssh-pipe-guard.ps1）可直接引用。
if ($PSVersionTable.PSVersion.Major -le 2) {
	Write-Output '__PS2__'
	exit 0
}
$流 = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String('__载荷__'))
$解压 = New-Object System.IO.Compression.GZipStream($流, [System.IO.Compression.CompressionMode]::Decompress)
$读 = New-Object System.IO.StreamReader($解压, [System.Text.Encoding]::UTF8)
$文本 = $读.ReadToEnd()
$临时目录 = Join-Path $env:TEMP ('vsi-install-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $临时目录 | Out-Null
$安装脚本路径 = Join-Path $临时目录 'remote-install-common.ps1'
[System.IO.File]::WriteAllText($安装脚本路径, $文本, (New-Object System.Text.UTF8Encoding($true)))
$守卫源路径 = Join-Path $临时目录 'ssh-pipe-guard.ps1'
$流2 = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String('__守卫载荷__'))
$解压2 = New-Object System.IO.Compression.GZipStream($流2, [System.IO.Compression.CompressionMode]::Decompress)
$读2 = New-Object System.IO.StreamReader($解压2, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($守卫源路径, $读2.ReadToEnd(), (New-Object System.Text.UTF8Encoding($true)))
try {
	& $安装脚本路径
	$退出码 = $LASTEXITCODE
	if ($null -eq $退出码) { $退出码 = 0 }
} catch {
	Write-Host ('安装脚本异常终止: {0}' -f $_.Exception.Message)
	$退出码 = 1
} finally {
	Remove-Item -LiteralPath $临时目录 -Recurse -Force -ErrorAction SilentlyContinue
}
exit $退出码
