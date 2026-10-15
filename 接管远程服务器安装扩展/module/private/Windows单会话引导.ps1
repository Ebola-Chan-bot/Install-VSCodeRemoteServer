# Windows 单会话引导：由 执行-Windows单会话安装 取本文件把载荷占位符替换为安装脚本正文（去整行注释与空行后 gzip+base64）后，整段经 -EncodedCommand 下发到远端执行。
# 不走 stdin：实测远端默认 shell 对 stdin 的收尾不可靠（载荷/EOF 随机不到，两侧永久挂死且远端残留僵尸进程），载荷内嵌命令行才是确定性的。远端 PowerShell 为 2.0 时打 __PS2__ 标记并退出 0，调用方据此回退离散安装流程；正常结束退出 0，安装脚本抛出终止性错误时退出 1。
if ($PSVersionTable.PSVersion.Major -le 2) {
	Write-Output '__PS2__'
	exit 0
}
$流 = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String('__载荷__'))
$解压 = New-Object System.IO.Compression.GZipStream($流, [System.IO.Compression.CompressionMode]::Decompress)
$读 = New-Object System.IO.StreamReader($解压, [System.Text.Encoding]::UTF8)
$文本 = $读.ReadToEnd()
try {
	& ([scriptblock]::Create($文本))
	exit 0
} catch {
	Write-Host ('安装脚本异常终止: {0}' -f $_.Exception.Message)
	exit 1
}
