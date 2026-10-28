# 僵尸 sshd 会话清理的回归自检（真主机上跑，但只报告不杀伤）
# 做法：从模块源码里**原样抽出**清理代码块 + 把杀伤动作替换成打印标记，与一段独立写的「实况清点」一起送上远端跑一次，
# 再在本地交叉核对：拟清集合必须落在「树龄>60 分钟 且 整棵树无 ESTABLISHED 连接 且 不含自身」的集合里（否则就是误杀）。
# 正向对照：跑本脚本自己的那条 sshd 会话必然「有 ESTABLISHED 连接」，它绝不能出现在拟清集合里。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File _probe\zombie-session-selftest.ps1 [-主机 <ssh别名>]
# A 段（误杀守卫、只认 ESTABLISHED 会话树等判据）纯离线；B 段要真主机，连不上就明确 SKIP，不算回归失败
param(
	[string]$主机 = '上科大A服务器_张天夫'
)
$ErrorActionPreference = 'Stop'
$repo = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer\接管远程服务器安装扩展'
$模块文件 = Join-Path $repo 'scripts\private\remote-install-common.ps1'
. (Join-Path $PSScriptRoot 'lib\探针公共库.ps1')
Initialize-断言 -通过前缀 'OK  ' -失败前缀 'FAIL '
# 断言台账统一放公共库；本地只留薄转发，调用点一行不改
function 断言 { param([Parameter(Position = 0)]$甲, [Parameter(Position = 1)]$乙, [Parameter(Position = 2)]$丙 = '') ; 写-断言 $甲 $乙 ([string]$丙) }

# ---------- 1. 语法与守卫静态核对 ----------
Write-Output '===== A. 模块源码静态核对 ====='
$语法错 = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($模块文件, [ref]$null, [ref]$语法错)
断言 (@($语法错).Count -eq 0) ('remote-install-common.ps1 语法解析通过（错误 ' + @($语法错).Count + ' 个）')
$模块文本 = [System.IO.File]::ReadAllText($模块文件)

# ---------- 2. 从源码里原样抽出清理代码块 ----------
$起记 = '# ===== 僵尸会话自动清理'
$起 = $模块文本.IndexOf($起记)
断言 ($起 -ge 0) '模块里找得到僵尸会话清理段的起始标记'
$尾记 = 'if ($僵尸会话数 -gt 0) {'
$尾起 = $模块文本.IndexOf($尾记, $起)
断言 ($尾起 -gt $起) '找得到新加的 sshd 会话树清理段的收尾报告块'
$尾 = $模块文本.IndexOf("`n}", $尾起)
断言 ($尾 -gt $尾起) '收尾报告块的右花括号找得到（抽取边界完整）'
$清理原文 = $模块文本.Substring($起, $尾 - $起 + 2)
Write-Output ('  抽出代码块 ' + $清理原文.Length + ' 字符 / ' + (@($清理原文 -split "`r?`n").Count) + ' 行')
断言 ($清理原文.Contains('$全进程表 = @{')) '抽出的块自带进程表构造（不依赖外部上下文）'
断言 ($清理原文.Contains("Get-NetTCPConnection -State Established")) '按「已建立连接」取证（不是靠猜进程名）'
断言 ($清理原文.Contains('$能取连接表 = $false') -and $清理原文.Contains('if ($能取连接表)')) '取不到连接表就整段跳过（没证据绝不动 sshd 会话）'
断言 ($清理原文.Contains("IndexOf('-R')")) '只认 sshd 会话侧进程（-R），不碰主监听进程'
断言 ($清理原文.Contains('-lt 60')) '树龄下限 60 分钟（避开刚建立的会话）'
断言 ($清理原文.Contains('$自身链') -and $清理原文.Contains('[int]$PID')) '本次连接自己的会话树被显式排除'
断言 ($清理原文.Contains('[Array]::Reverse')) '先杀子孙再杀树根（自底向上，避免留孤儿）'

# ---------- 3. 把杀伤动作换成打印，构造远端探针 ----------
$拟 = $清理原文
$拟 = $拟.Replace('try { Stop-Process -Id $候.ProcessId -Force -ErrorAction Stop; $僵尸数++ } catch { }', "Write-Output ('__Z__拟杀孤儿powershell=' + `$候.ProcessId); `$僵尸数++")
$拟 = $拟.Replace('try { Stop-Process -Id $树内 -Force -ErrorAction Stop } catch { }', "Write-Output ('__Z__拟杀树成员=' + `$树内)")
$拟 = $拟.Replace("`$僵尸会话数++", "Write-Output ('__Z__拟清会话树根=' + `$会话根.ProcessId + ' 龄分钟=' + [int]((Get-Date) - `$会话根.CreationDate).TotalMinutes + ' 树大小=' + `$树.Count); `$僵尸会话数++")
断言 ($拟 -notmatch 'Stop-Process') '探针里已无任何杀伤动作（真主机上只报告）'
断言 (@([regex]::Matches($拟, '__Z__拟清会话树根')).Count -eq 1) '杀伤替换只命中一处（替换串若与源码漂移，这里会当场暴露）'

# ---------- 4. 独立写一段实况清点，作为交叉核对的证据源 ----------
$实况 = @'
$进程表 = @{}
foreach ($项 in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $进程表[[int]$项.ProcessId] = $项 }
$持连 = @{}
try { foreach ($连 in @(Get-NetTCPConnection -State Established -ErrorAction Stop)) { $持连[[int]$连.OwningProcess] = $true } } catch { Write-Output '__Z__实况_连接表不可用' }
$自身 = @{}
$游 = $进程表[[int]$PID]
for ($i = 0; $i -lt 12 -and $null -ne $游; $i++) { $自身[[int]$游.ProcessId] = $true; $游 = $进程表[[int]$游.ParentProcessId] }
foreach ($根 in $进程表.Values) {
    if ($根.Name -notlike 'sshd*') { continue }
    if ($null -eq $根.CommandLine -or $根.CommandLine.IndexOf('-R') -lt 0) { continue }
    $树 = @([int]$根.ProcessId); $待 = @([int]$根.ProcessId)
    for ($层 = 0; $层 -lt 8 -and $待.Count -gt 0; $层++) {
        $下 = @()
        foreach ($it in $进程表.Values) { if ($null -ne $it.ParentProcessId -and $待 -contains [int]$it.ParentProcessId) { $树 += [int]$it.ProcessId; $下 += [int]$it.ProcessId } }
        $待 = $下
    }
    $连数 = 0; foreach ($t in $树) { if ($持连[$t]) { $连数++ } }
    $是我 = $false; foreach ($t in $树) { if ($自身[$t]) { $是我 = $true; break } }
    Write-Output ('__Z__实况=根' + $根.ProcessId + ' 龄分钟=' + [int]((Get-Date) - $根.CreationDate).TotalMinutes + ' 树大小=' + $树.Count + ' 树内已建立连接=' + $连数 + ' 是本次连接=' + $是我)
}
Write-Output '__Z__实况结束'
'@
$实况 = $实况 -replace "`r`n", "`n"
$远端脚本 = ('$ProgressPreference = ''SilentlyContinue''' + "`n" + $实况 + "`n" + ($拟 -replace "`r`n", "`n") + "`nWrite-Output ('__Z__报告僵尸数=' + `$僵尸数 + ' 报告会话数=' + `$僵尸会话数)`nWrite-Output '__Z__END'`n")
$编码 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($远端脚本))

# ---------- 5. 上真主机跑一次 ----------
Write-Output ''
Write-Output ('===== B. 真主机 ' + $主机 + ' 只报告实跑 =====')
$原EAP = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try { $输出 = @(ssh -n -o BatchMode=yes $主机 ('powershell -NoProfile -EncodedCommand ' + $编码) 2>&1) } finally { $ErrorActionPreference = $原EAP }
$行 = @((($输出 | ForEach-Object { [string]$_ }) -join "`n") -split "[`r`n]+")
Write-Output ('  远端回传行数=' + $行.Count + ' ssh 退出码=' + $LASTEXITCODE)
if (($LASTEXITCODE -ne 0) -or ($行 -notcontains '__Z__END')) {
	# 环境不可用（主机不可达/没免密/远端被卡）不算回归：把话说清，按已跑完的 A 段定退出码。
	# 旧版在这里直接往下跑，会把一次网络故障渲染成 4 条「清理逻辑坏了」的假告警
	Write-Output ''
	Write-Output ('SKIP  B 段（真主机 ' + $主机 + '）：ssh 退出码 ' + $LASTEXITCODE + '，远端未跑完 → 环境不可用，不计作回归失败。')
	Write-Output ('      A 段（清理判据与误杀守卫）已全部执行完毕；要跑真机请先确认 ssh -o BatchMode=yes ' + $主机 + ' 能进。')
	Write-Output ('自检断言失败数累计: ' + (取-断言计数).失败)
	exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
}
$实况行 = @($行 | Where-Object { $_ -like '__Z__实况=根*' })
$拟清行 = @($行 | Where-Object { $_ -like '__Z__拟清会话树根=*' })
$拟杀树 = @($行 | Where-Object { $_ -like '__Z__拟杀树成员=*' })
$拟杀孤 = @($行 | Where-Object { $_ -like '__Z__拟杀孤儿powershell=*' })
$报告行 = @($行 | Where-Object { $_ -like '__Z__报告*' })
Write-Output '  ── 远端会话实况（树根 / 龄 / 树内已建立连接） ──'
$实况行 | ForEach-Object { Write-Output ('    ' + $_) }
Write-Output ('  ── 拟清会话树根 ' + $拟清行.Count + ' 条；拟杀树成员 ' + $拟杀树.Count + ' 个；拟杀孤儿 powershell ' + $拟杀孤.Count + ' 个 ──')
$拟清行 | ForEach-Object { Write-Output ('    ' + $_) }
$报告行 | ForEach-Object { Write-Output ('    ' + $_) }
断言 ($行 -contains '__Z__END') '远端脚本跑到底（有结束标记）'
断言 ($实况行.Count -ge 1) ('实况清点确有会话树可判（实测 ' + $实况行.Count + ' 条）')

# ---------- 6. 交叉核对：拟清集合必须完全落在「可安全杀」集合里 ----------
$可安全杀 = @{}
$活会话根 = @()
$本次根 = @()
foreach ($l in $实况行) {
	if ($l -notmatch '根(\d+) 龄分钟=(-?\d+) 树大小=(\d+) 树内已建立连接=(\d+) 是本次连接=(True|False)') { continue }
	$根id = $matches[1]; $龄 = [int]$matches[2]; $连 = [int]$matches[4]; $是我 = ($matches[5] -eq 'True')
	if ($是我) { $本次根 += $根id }
	if ($连 -gt 0) { $活会话根 += $根id }
	if ($龄 -gt 60 -and $连 -eq 0 -and -not $是我) { $可安全杀[$根id] = $true }
}
断言 ($本次根.Count -ge 1) ('正向对照：至少认出本次连接自己的会话树（实测 ' + ($本次根 -join ',') + '）——它必带 ESTABLISHED 连接')
$拟清根 = @()
foreach ($l in $拟清行) { if ($l -match '拟清会话树根=(\d+)') { $拟清根 += $matches[1] } }
$越界 = @($拟清根 | Where-Object { -not $可安全杀[$_] })
断言 ($越界.Count -eq 0) ('拟清集合没有越界（越界 ' + $越界.Count + ' 个' + $(if ($越界.Count -gt 0) { '：' + ($越界 -join ',') } else { '' }) + '）= 不会误杀活会话/新会话/本次会话')
$误伤活 = @($拟清根 | Where-Object { $活会话根 -contains $_ })
断言 ($误伤活.Count -eq 0) ('有 ESTABLISHED 连接的活会话一条也没被拟清（实测命中 ' + $误伤活.Count + ' 个）')
$误伤己 = @($拟清根 | Where-Object { $本次根 -contains $_ })
断言 ($误伤己.Count -eq 0) '本次连接自己的会话绝不在拟清之列（$PID 树排除生效）'
$拟杀树根 = @($拟杀树 | ForEach-Object { if ($_ -match '拟杀树成员=(\d+)') { $matches[1] } })
断言 (@($拟杀树根 | Where-Object { $本次根 -contains $_ }).Count -eq 0) '拟杀的树成员里不含本次会话的任何进程'
if ($报告行.Count -gt 0 -and $报告行[0] -match '报告僵尸数=(-?\d+) 报告会话数=(-?\d+)') {
	断言 ([int]$matches[2] -eq $拟清行.Count) ('报告条数与拟清树根数一致（报告 ' + $matches[2] + ' / 拟清 ' + $拟清行.Count + '）')
} else { 断言 $false '远端回传了报告行（含僵尸数/会话数计数）' }
Write-Output ('  结论：远端当前有 ' + $实况行.Count + ' 条 sshd 会话树，其中活会话（有连接）' + $活会话根.Count + ' 条、可安全清理 ' + $可安全杀.Count + ' 条、拟清 ' + $拟清根.Count + ' 条')

Write-Output ''
Write-Output ('自检断言失败数累计: ' + (取-断言计数).失败)
exit $(if ((取-断言计数).失败 -eq 0) { 0 } else { 1 })
