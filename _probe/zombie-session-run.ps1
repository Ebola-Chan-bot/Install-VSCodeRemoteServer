# 用模块里**原样抽出的**清理代码块在真主机上执行一次真清理（自检已核对判据不会误杀），并复检结果
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$主机 = '上科大A服务器_张天夫'
$模块文本 = [System.IO.File]::ReadAllText((Join-Path $repo 'module\private\remote-install-common.ps1'))
$起 = $模块文本.IndexOf('# ===== 僵尸会话自动清理')
$尾起 = $模块文本.IndexOf('if ($僵尸会话数 -gt 0) {', $起)
$尾 = $模块文本.IndexOf("`n}", $尾起)
$块 = $模块文本.Substring($起, $尾 - $起 + 2)
Write-Output ('抽出生产代码块 ' + $块.Length + ' 字符（原样执行，未做任何替换）')
$远端脚本 = ("`$ProgressPreference = 'SilentlyContinue'`n" + ($块 -replace "`r`n", "`n") + "`nWrite-Output '__Z__END'")
$编码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($远端脚本))
$原EAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $输出 = @(ssh -n -o BatchMode=yes $主机 ('powershell -NoProfile -EncodedCommand ' + $编码) 2>&1) } finally { $ErrorActionPreference = $原EAP }
$行 = @((($输出 | ForEach-Object { [string]$_ }) -join "`n") -split "[`r`n]+")
$行 | Where-Object { $_ -match '已清理|__Z__END' } | ForEach-Object { Write-Output ('  ' + $_) }
Write-Output ('ssh 退出码=' + $LASTEXITCODE)
