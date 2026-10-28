# Windows 单会话引导：由 执行-Windows单会话安装 取本文件把载荷占位符替换为安装脚本正文（去整行注释与空行后 gzip+base64）后下发到远端执行。
# 下发通道：本文件整体（含替换后的载荷）再按 UTF-16 base64 一次，经 **stdin** 送到远端，由 private\windows-stdin-bootstrap.ps1 那段固定引导解码并调用。
# 为什么不再直接进 argv：双重 base64 使命令行达 3.8 万字符 > Windows CreateProcess 上限 32767，本地 ssh.exe 直接拒绝启动（Program 'ssh.exe' failed to run: The filename or extension is too long）→ preconnect 退出码 1 → Remote-SSH 判 PreconnectScriptFailure，整条连接夭折（2026-10-22 真机复现）。
# stdin 通道已实测可靠：远端 sshd DefaultShell=powershell.exe（无 cmd 的 8191 上限），2KB/40KB/120KB/400KB 四档长度与 SHA256 双判据全一致、退出码 0、单程约 1 秒；本地 PowerShell 在管道结束时关闭 ssh 的标准输入，EOF 确定送达（旧结论“stdin 收尾不可靠、远端挂死留僵尸”据此推翻）。远端 PowerShell 为 2.0 时打 __PS2__ 标记并退出 0，调用方据此回退离散安装流程；正常结束退出 0，安装脚本抛出终止性错误时退出 1。
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
