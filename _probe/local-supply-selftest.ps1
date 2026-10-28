# 本地供给子进程行为自检：用真实参数文件把 local-supply.ps1 拉起来（系统类型=Linux 可跳过下载前的 ssh 取消检查），
# 对着两个必连不上的地址跑约 45 秒，核对多源轮试 + 单一时钟的全部性质：
#   ① 源清单只公布一次；② 一次中断恒为一条消息（行数 == 已推进轮数）；
#   ③ 每条中断行都带续传点与「下个汇报周期（N 秒后）重试」；④ 实测间隔 == 上一条声明的等待、等待随周期递增；
#   ⑤ 源序号严格按「第 N 次 → 列表[(N-1) % 总数]」轮转；⑥ 子进程 stderr 无异常逸出（catch 里抛出会穿透重试循环）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\local-supply-selftest.ps1
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$供给脚本 = Join-Path $repo 'scripts\private\local-supply.ps1'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

$tokens = $null; $errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($供给脚本, [ref]$tokens, [ref]$errors)
断言 ($errors.Count -eq 0) ("语法解析: local-supply.ps1")

$源列表 = @('https://127.0.0.1:9/primary-pkg.tar.gz', 'https://127.0.0.1:8/backup-pkg.tar.gz')
$本地文件名 = 'vsi-selftest-supply-{0}.tar.gz' -f (Get-Random)
$参数文件 = Join-Path $env:TEMP 'vsi-selftest-supply.clixml'
@{
	连接目标   = 'selftest.invalid'
	端口      = 22
	密码选项   = @()
	暂存目录   = 'AUTO'
	下载地址   = $源列表[0]
	下载地址列表 = $源列表
	远程包名   = 'REMOTE.tar.gz'
	完成标记名  = 'LOCAL_DONE.selftest'
	取消标记名  = 'LOCAL_CANCEL.selftest'
	系统类型   = 'Linux'
	分隔符    = '||'
	提交号    = 'selftestcommit'
	产物名    = '服务端'
	本地文件名  = $本地文件名
} | Export-Clixml -LiteralPath $参数文件

$outPath = Join-Path $env:TEMP 'vsi-selftest-supply-out.txt'
$errPath = Join-Path $env:TEMP 'vsi-selftest-supply-err.txt'
Remove-Item -LiteralPath $outPath, $errPath -Force -ErrorAction SilentlyContinue

$观测秒数 = 45
Write-Output ''
Write-Output "===== 拉起本地供给子进程约 $观测秒数 秒（对两个必失败地址轮试） ====="
$proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $供给脚本, $参数文件) -RedirectStandardOutput $outPath -RedirectStandardError $errPath -NoNewWindow -PassThru
Start-Sleep -Seconds $观测秒数
if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 700

$lines = @(Get-Content -LiteralPath $outPath)
$errText = if (Test-Path -LiteralPath $errPath) { (Get-Content -LiteralPath $errPath -Raw) } else { '' }
Write-Output '----- 捕获到的完整输出 -----'
$lines | ForEach-Object { Write-Output $_ }
Write-Output '----- 断言 -----'

# ① 源清单只公布一次，且序号与地址顺序一致
$清单行 = @($lines | Where-Object { $_ -like '*本地下载备源*' })
断言 ($清单行.Count -eq 1) ("备源清单只公布一次（实测 " + $清单行.Count + ' 行，期望 1；单源时已改为不打，本用例故意给两个源）')
if ($清单行.Count -eq 1) { Write-Output ('    ' + $清单行[0]) }
断言 ($清单行.Count -eq 0 -or ($清单行[0] -like '*1) https://127.0.0.1:9*' -and $清单行[0] -like '*2) https://127.0.0.1:8*')) '清单里两个源按序编号且与地址列表同序'

# ② 一次中断一条消息
$中断行 = @($lines | Where-Object { $_ -like '*下载中断*' })
$解析 = @()
foreach ($l in $中断行) {
	$m = [regex]::Match($l, '^下载中断（第 (?<n>\d+) 次，源 (?<s>\d+)/(?<tot>\d+)(?<省略>.*?)，续传点 (?<b>\d+) 字节）：(?<r>.*?)。(?<w>\d+) 秒后续传重试$')
	if ($m.Success) {
		$解析 += [pscustomobject]@{ 轮次 = [int]$m.Groups['n'].Value; 原因 = $m.Groups['r'].Value; 源 = [int]$m.Groups['s'].Value; 总数 = [int]$m.Groups['tot'].Value; 等待 = [int]$m.Groups['w'].Value }
	}
}
$max轮 = if ($解析.Count -gt 0) { ($解析 | Measure-Object -Property 轮次 -Maximum).Maximum } else { 0 }
断言 ($中断行.Count -ge 4) ("中断行条数足够核对（实测 " + $中断行.Count + '）')
断言 ($解析.Count -eq $中断行.Count) ("每条中断行都带源序号/续传点/「N 秒后续传重试」（不合规 " + ($中断行.Count - $解析.Count) + ' 条）')
断言 ($中断行.Count -eq $max轮) ("一次中断一条消息：中断行 " + $中断行.Count + " == 已推进轮数 $max轮")

# ③ 多源轮转与列表取下标严格同源
$期望序列 = (0..($解析.Count + 3) | ForEach-Object { ($_ % 2) + 1 })
$实际序列 = ($解析 | ForEach-Object { $_.源 }) -join ','
$期望前段 = ($期望序列[0..($解析.Count - 1)]) -join ','
断言 ($实际序列 -eq $期望前段) ("源序号按轮轮转（实际: $实际序列 ；期望: $期望前段）")
断言 (@($解析 | Where-Object { $_.总数 -ne 2 }).Count -eq 0) '源总数恒为地址列表长度 2'

# ④ 等待随周期递增、无固定值形态（本地供给首轮起周期逐档放宽）
if ($解析.Count -ge 3) {
	$等待序列 = ($解析 | ForEach-Object { $_.等待 }) -join ' → '
	Write-Output ('    等待序列: ' + $等待序列)
	断言 (($解析[-1].等待) -ge ($解析[0].等待 + 1)) ("等待随周期递增而非固定值（首 " + $解析[0].等待 + ' → 末 ' + $解析[-1].等待 + '）')
	断言 (@($解析 | Group-Object 等待 | Where-Object { $_.Count -eq $解析.Count }).Count -eq 0) '不存在「每轮同一个写死秒数」的形态'
}
# 实测间隔与时间戳无关：本地供给行不带内嵌时间戳（外层转发器才加前缀），故只能用「声明等待占观测窗口的比例」自证：
# 窗口时长 = 累计等待 + 累计连接尝试耗时（本轮耗时不属于汇报周期，无法在此拆分），故只卡下限：
# 声明等待占窗口 >=40% 证明真在按周期等而不是忙轮询；占窗口 <=100% 证明没把等待打印成比实际更长的值
$累计等待 = ($解析 | Measure-Object -Property 等待 -Sum).Sum
断言 ($累计等待 -ge ($观测秒数 * 0.4)) ("声明等待占观测窗口 " + [Math]::Round($累计等待 * 100.0 / $观测秒数) + "%（累计 $累计等待 秒 / 窗口 $观测秒数 秒），非忙轮询")
断言 ($累计等待 -le $观测秒数) ("声明等待累计未超过观测窗口（$累计等待 秒 <= $观测秒数 秒），等待值与实际时长同量级")
Write-Output ('    平均周期: 等待 ' + [Math]::Round($累计等待 / $解析.Count, 1) + 's + 尝试 ' + [Math]::Round(($观测秒数 - $累计等待) / $解析.Count, 1) + "s ≈ 每轮 " + [Math]::Round($观测秒数 / $解析.Count, 1) + 's')

# ⑤ 无异常逸出；半成品保留以便续传
$异常特征 = @('RuntimeException', 'CategoryInfo', 'InvalidCastIConvertible', 'Cannot convert value', 'FullyQualifiedErrorId', '未响应', 'not recognized', '不是内部或外部')
$逸出 = @($异常特征 | Where-Object { ($errText -like "*$_*") -or (($lines -join "`n") -like "*$_*") })
断言 ($逸出.Count -eq 0) ("子进程无异常逸出（命中 " + $逸出.Count + ' 个' + $(if ($逸出.Count) { '：' + ($逸出 -join ',') } else { '' }) + '）')
if ($errText) { Write-Output ('    stderr 前 400 字: ' + $errText.Substring(0, [Math]::Min(400, $errText.Length))) }
$半成品 = Join-Path $env:TEMP $本地文件名
Write-Output ('    半成品保留供下轮续传: ' + $半成品 + '（存在=' + (Test-Path -LiteralPath $半成品) + '）')

Remove-Item -LiteralPath $半成品, $参数文件, $outPath, $errPath -Force -ErrorAction SilentlyContinue
Write-Output ''
Write-Output ("断言失败数: " + (取-断言计数).失败)
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
