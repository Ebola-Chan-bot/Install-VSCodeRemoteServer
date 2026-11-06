# 统一竞速汇报回归：直接执行 安装实现.ps1 中的真实调度函数，验证四端只由同一个时钟输出。
$ErrorActionPreference = 'Stop'
$仓库 = 'c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer'
$源文件 = Join-Path $仓库 '接管远程服务器安装扩展\scripts\安装实现.ps1'
$失败 = 0
function 断言([bool]$条件, [string]$说明) {
	if ($条件) { Write-Output ('PASS ' + $说明) } else { $script:失败++; Write-Output ('FAIL ' + $说明) }
}
function 调用-推进 {
	return @(& { 推进-统一竞速汇报 } 6>&1 | ForEach-Object { [string]$_ })
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($源文件, [ref]$tokens, [ref]$errors)
断言 ($errors.Count -eq 0) '安装实现.ps1 语法解析通过'
foreach ($名字 in @('初始化-统一竞速汇报', '登记-竞速快照', '推进-统一竞速汇报', '完成-竞速产物', '完成-竞速端点')) {
	$函数 = $ast.Find({ param($节点) $节点 -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $节点.Name -eq $名字 }, $true)
	if ($null -ne $函数) { Invoke-Expression $函数.Extent.Text } else { $失败++; Write-Output ('FAIL 找不到真实函数 ' + $名字) }
}

初始化-统一竞速汇报 -产物列表 @('CLI', '服务端')
# 启动门槛：初始化状态不能凭空显示 0 字节；只有收到该端真实快照后才允许输出进度（即使真实的 0 字节也可以）。
$script:统一竞速汇报.下次汇报时刻 = (Get-Date).AddSeconds(-1)
$启动前输出 = @(调用-推进)
断言 ($启动前输出.Count -eq 0) '供给启动前不输出默认的已传 0 字节'
foreach ($端 in @('本地', '远程')) {
	foreach ($产物 in @('CLI', '服务端')) {
		断言 (-not $script:统一竞速汇报.状态[$产物][$端].已就绪) ('初始化时未伪造已就绪状态：' + $产物 + '/' + $端)
	}
}
# 用完整的四端快照模拟竞速期间的原始协议输入；这些输入本身不应产生任何日志。
$快照列表 = @(
	(@{ 端 = '本地'; 产物 = 'CLI'; 已下载 = 1000; 总长度 = 100000 } | ConvertTo-Json -Compress),
	(@{ 端 = '远程'; 产物 = 'CLI'; 已下载 = 900; 总长度 = 100000 } | ConvertTo-Json -Compress),
	(@{ 端 = '本地'; 产物 = '服务端'; 已下载 = 2000; 总长度 = 200000 } | ConvertTo-Json -Compress),
	(@{ 端 = '远程'; 产物 = '服务端'; 已下载 = 1900; 总长度 = 200000 } | ConvertTo-Json -Compress)
)
foreach ($快照 in $快照列表) { [void](登记-竞速快照 ('__VSI_SNAPSHOT__' + $快照)) }
$事件文本 = '[本地供给-CLI] 本地下载：测试重建事件（只应出现一次）'
$事件 = @{ 端 = '本地'; 产物 = 'CLI'; 文本 = $事件文本 } | ConvertTo-Json -Compress
[void](登记-竞速快照 ('__VSI_EVENT__' + $事件))

$未到期输出 = @(调用-推进)
断言 ($未到期输出.Count -eq 0) '事件与快照在共享周期未到期时均不直接输出'

# 到同一个共享汇报点：四端快照 + 一条事件，合计五行；不再由每个下载器各自打印。
$script:统一竞速汇报.下次汇报时刻 = (Get-Date).AddSeconds(-1)
$到期输出 = @(调用-推进)
断言 ($到期输出.Count -eq 5) '共享汇报点一次输出四端进度与一条事件（合计 5 行）'
foreach ($标签 in @('[本地供给-CLI]', '[远程自下载-CLI]', '[本地供给-服务端]', '[远程自下载-服务端]')) {
	断言 ((@($到期输出 | Where-Object { $_.Contains($标签) -and ($_ -match '下载进度') }).Count) -eq 1) ('本周期只输出一次进度 ' + $标签)
}
断言 ((@($到期输出 | Where-Object { $_ -eq $事件文本 }).Count) -eq 1) '重建事件在共享汇报点只输出一次'
断言 ($script:统一竞速汇报.事件队列.Count -eq 0) '输出后事件队列已清空，不会下一轮重放'
断言 ($script:统一竞速汇报.周期 -ge 1) '共享周期由调度器维护且不小于 1 秒'

# 新事件在下一周期之前到达，仍不得抢跑；到下一周期才输出，旧事件不能重复。
$第二事件文本 = '[远程自下载-服务端] 测试下载中断（只应出现一次）'
$第二事件 = @{ 端 = '远程'; 产物 = '服务端'; 文本 = $第二事件文本 } | ConvertTo-Json -Compress
[void](登记-竞速快照 ('__VSI_EVENT__' + $第二事件))
$抢跑输出 = @(调用-推进)
断言 ($抢跑输出.Count -eq 0) '新事件不会在独立下载器计时点抢跑输出'
$script:统一竞速汇报.下次汇报时刻 = (Get-Date).AddSeconds(-1)
$第二轮输出 = @(调用-推进)
断言 ((@($第二轮输出 | Where-Object { $_ -eq $第二事件文本 }).Count) -eq 1) '第二个事件在下一个共享汇报点输出一次'
断言 ((@($第二轮输出 | Where-Object { $_ -eq $事件文本 }).Count) -eq 0) '第二个汇报点不重复输出第一个事件'

# 协议转发守卫：两端协调器必须原样透出事件，不能添加前缀或直接打印。
$协调器 = Get-Content (Join-Path $仓库 '接管远程服务器安装扩展\scripts\private\local-race-coordinator.ps1') -Raw -Encoding UTF8
$远端协调 = Get-Content (Join-Path $仓库 '接管远程服务器安装扩展\scripts\private\remote-install-common.ps1') -Raw -Encoding UTF8
断言 ($协调器.Contains("__VSI_EVENT__')) {`r`n`t`t`t# 事件协议必须原样透出") -or $协调器.Contains("__VSI_EVENT__')) {`n`t`t`t# 事件协议必须原样透出")) '本地协调器保留统一事件协议转发'
断言 ($远端协调.Contains("elseif (`$行.StartsWith('__VSI_EVENT__'))")) '远端组合协调器保留统一事件协议转发'

# 直接调用本地与远端下载器内的真实事件函数，确认它们产生的是协议消息而不是各自刷日志。
$本地源 = Join-Path $仓库 '接管远程服务器安装扩展\scripts\private\local-supply.ps1'
$本地标记 = $null; $本地错误 = $null
$本地树 = [System.Management.Automation.Language.Parser]::ParseFile($本地源, [ref]$本地标记, [ref]$本地错误)
$本地函数 = $本地树.Find({ param($节点) $节点 -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $节点.Name -eq '写-竞速事件' }, $true)
Invoke-Expression $本地函数.Extent.Text
$结构化进度 = $true
$产物名 = 'CLI'
$本地事件行 = @(写-竞速事件 '本地协议测试')
断言 ($本地事件行.Count -eq 1 -and $本地事件行[0].StartsWith('__VSI_EVENT__')) '本地下载器结构化事件走协议而非直接日志'
$本地事件对象 = $本地事件行[0].Substring(13) | ConvertFrom-Json
断言 ($本地事件对象.端 -eq '本地' -and $本地事件对象.产物 -eq 'CLI') '本地事件保留端与产物身份'

$远端源 = Join-Path $仓库 '接管远程服务器安装扩展\scripts\private\remote-install-common.ps1'
$远端标记 = $null; $远端错误 = $null
$远端树 = [System.Management.Automation.Language.Parser]::ParseFile($远端源, [ref]$远端标记, [ref]$远端错误)
$远端函数 = $远端树.Find({ param($节点) $节点 -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $节点.Name -eq '写-竞速事件' }, $true)
Invoke-Expression $远端函数.Extent.Text
$端标注 = '[远程自下载-服务端]'
$远端事件行 = @(写-竞速事件 '远端协议测试')
断言 ($远端事件行.Count -eq 1 -and $远端事件行[0].StartsWith('__VSI_EVENT__')) '远端下载器结构化事件走协议而非直接日志'
$远端事件对象 = $远端事件行[0].Substring(13) | ConvertFrom-Json
断言 ($远端事件对象.端 -eq '远程' -and $远端事件对象.产物 -eq '服务端') '远端事件保留端与产物身份'

# 用真实 Start-Job 跑真实协调器函数，验证本地事件在转发时不被加前缀、不变成第二个输出点。
$协调树标记 = $null; $协调树错误 = $null
$协调树 = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $仓库 '接管远程服务器安装扩展\scripts\private\local-race-coordinator.ps1'), [ref]$协调树标记, [ref]$协调树错误)
$协调函数 = $协调树.Find({ param($节点) $节点 -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $节点.Name -eq '接收-作业输出' }, $true)
Invoke-Expression $协调函数.Extent.Text
$作业表 = @{}
$状态表 = @{}
$作业表['CLI'] = Start-Job { Write-Output '__VSI_EVENT__{"端":"本地","产物":"CLI","文本":"协调器协议测试"}' }
Wait-Job -Job $作业表['CLI'] -Timeout 15 | Out-Null
$转发事件 = @(& { 接收-作业输出 'CLI' } 6>&1 | ForEach-Object { [string]$_ })
Remove-Job -Job $作业表['CLI'] -Force -ErrorAction SilentlyContinue
断言 ($转发事件.Count -eq 1 -and $转发事件[0].StartsWith('__VSI_EVENT__')) '真实协调器原样转发事件，不产生独立端标注日志'
[void](登记-竞速快照 $转发事件[0])
断言 ($script:统一竞速汇报.事件队列.Count -eq 1) '协调器转发的事件进入同一个主流程队列'

# 真实 0 字节不是伪造状态：收到快照后允许显示，且启动消息必须先于它出现。
$script:统一竞速汇报.下次汇报时刻 = (Get-Date).AddSeconds(-1)
$零快照 = @{ 端 = '本地'; 产物 = 'CLI'; 已下载 = 0; 总长度 = 0 } | ConvertTo-Json -Compress
[void](登记-竞速快照 ('__VSI_SNAPSHOT__' + $零快照))
$零输出 = @(调用-推进)
断言 ($script:统一竞速汇报.状态['CLI']['本地'].已就绪) '真实 0 字节快照将该端标记为已就绪'
断言 ((@($零输出 | Where-Object { $_.Contains('[本地供给-CLI]') -and $_.Contains('已传 0 字节') }).Count) -eq 1) '真实 0 字节快照允许显示为已传 0 字节'
$协调源 = Get-Content (Join-Path $仓库 '接管远程服务器安装扩展\scripts\private\local-race-coordinator.ps1') -Raw -Encoding UTF8
$启动登记位置 = $协调源.IndexOf("Write-Output ('[本地供给-{0}] 本地供给已启动")
$启动作业位置 = $协调源.IndexOf('$作业表[$产物名] = Start-Job')
断言 ($启动登记位置 -ge 0 -and $启动作业位置 -gt $启动登记位置) '真实协调器先输出已启动，再创建供给作业'
$本地源全文 = Get-Content $本地源 -Raw -Encoding UTF8
断言 ($本地源全文.Contains('if (-not $结构化进度)') -and $本地源全文.Contains('组合竞速由 local-race-coordinator.ps1 在启动作业前播报')) '本地供给在组合模式下不重复播报已启动'

Write-Output ''
Write-Output ('统一竞速汇报回归失败数: ' + $失败)
exit $(if ($失败 -eq 0) { 0 } else { 1 })
