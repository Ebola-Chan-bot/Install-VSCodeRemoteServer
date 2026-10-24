`_probe` 是这个仓库的开发用探针与回归自检目录。它**不进 VSIX**（`vsce ls` 里没有它），所以这里的文件名可以用中文、脚本可以为排障写得直白粗糙；一旦要进安装包，文件名必须全 ASCII（市场服务端解包时会把中文名有损解码成 `?`，同字数的中文名会撞字典键）。

这里的东西只有两种存在理由：一是**证明生产代码没坏**（回归自检，可反复跑、必须稳定绿），二是**下次出事能立刻上手**（取证工具，平时不跑）。凡是两者都不是的一次性调查脚本，用一次就该删——本轮清理已经按这个标准删掉 30 个文件，理由见最后一节。

# 一分钟用法

```powershell
cd c:\Users\vhtmf\source\repos\Install-VSCodeRemoteServer
# 改完模块代码后，第一件事：跑全部离线自检（约 3 分钟）
powershell -NoProfile -ExecutionPolicy Bypass -File .\_probe\跑全部自检.ps1
# 只想快速确认没打破静态守卫（秒级）
powershell ... -File .\_probe\跑全部自检.ps1 -跳过耗时
# 有真机环境时追加真机段（会连主机、传数据、可能起进程）
powershell ... -File .\_probe\跑全部自检.ps1 -含真机 -主机 上科大B服务器 -端口 22
# 有活着的 VS Code 窗口且开着 CDP 端口时追加窗口段
powershell ... -File .\_probe\跑全部自检.ps1 -含窗口 -窗口CDP端口 17890 -窗口标题特征 上科大B服务器
```

总入口按「离线 / 耗时 / 真机 / 窗口」四类分派：**环境不可用一律标 SKIP，绝不标 FAIL**。这条不是偷懒——把连不上主机也算失败，会让「全绿」永远拿不到，人很快就学会无视这个闸门（狼来了）。退出码 0 且没有 FAIL，就可以打包。

sh 自检要单独跑（需 git bash）：

```powershell
& 'C:\Program Files\Git\bin\bash.exe' .\_probe\log-event-selftest.sh
```

# 库里有什么：可复用逻辑的唯一出处

`lib\探针公共库.ps1` 是本轮整理的产物——此前 20 多个临时调查脚本各抄一份载荷构造、SSH 派发、断言计数，同一条纪律要改九处，改漏了就出现「探针对，线上错」。库里固化五类东西：

| 分节 | 函数 | 解决什么 |
| --- | --- | --- |
| 一、断言台账 | `Initialize-断言` / `写-断言` / `取-断言计数` / `写-断言汇总` | 计数、失败清单、汇总与退出码只写一遍；`写-断言` 认两种历史参数顺序（`条件,说明` 与 `说明,条件`），迁移时 200 多个调用点一行不用改 |
| 二、路径与源码守卫 | `取-仓库根` / `取-模块目录` / `取-私有目录` / `校-脚本语法` / `补-脚本BOM` / `扫-裸拼接实参` | 探针自己不能因为路径写错或 BOM 缺失而误判生产代码；`校-脚本语法` 顺带报 BOM 数（双 BOM 会让 `param()` 报错） |
| 三、载荷构造 | `构造-单会话载荷` / `构造-固定引导码` / `取-引导码特征` | 剔注释→gzip→base64→塞进引导模板→UTF-16 再 base64→**整段**走 stdin（不分块；远端读全量后剔掉所有空白再解码），与 `Install-VSCodeRemoteServer.psm1` 的 `执行-Windows单会话安装` **同一套算法**，并返回「载荷不含空白」这个无损传输前提的判据。`取-引导码特征` 取固定引导码的前 48 字符当钢印指纹——它**每次调用逐字相同**（载荷在 stdin 上，不进 argv），所以能把「生产引导进程」与「探针/别人的一次性 EncodedCommand 脚本」分开 |
| 四、远端调度 | `剥-SSH噪声` / `送-远端脚本` / `取-远端有界计时包装` / `取-远端普查脚本` | 噪声剥离（CNAME 警告、CLIXML、ErrorRecord 模板）、有界远端等待、只读普查脚本的单一事实来源 |
| 五、生产同形态 stdin | `送-载荷经stdin` | 与 `执行-SSH命令带标准输入` 逐字同序：`ProcessStartInfo`、三流重定向、写完 **显式 Close**、stderr 异步抽干、逐行回调、看门狗到点 `taskkill /T` |

库自己有 87 项断言（`lib-selftest.ps1`），其中两项最关键：

- **漂移守卫**：自检里独立重算一遍 `引导码`，再要求与库算出的逐字符相等。库里任何一处偏离 psm1，这条就红。
- **生产同源守卫**：把 `送-载荷经stdin` 的函数体与 psm1 里硬化过的发送体做字面量比对（`\.(cmd|bat)$`、`CreateNoWindow`、`Close()`、`taskkill` 等 8 个片段），防止两边各改各的。

# 现存清单

**总入口**

- `跑全部自检.ps1` —— 按环境分类跑完所有自检；跑前先用 AST 扫「假绿断言」（见铁律三）。

**离线回归自检（默认跑）**

- `lib-selftest.ps1` —— 公共库自身（87 项）。
- `report-point-audit.ps1` —— 上报点审计：每个分支都得给结论，禁吞错、禁裸 `Write-Output`（0 问题为绿）。
- `format-string-audit.ps1` —— 格式化字符串审计：`-f`/`{0}` 占位符个数必须与实参对上（0 问题为绿）。
- `windows-stdin-transport-selfcheck.ps1` —— Windows stdin 通道与生产代码同源性：A 静态守卫、B 模块可导入、C 新旧 argv 体积、D 分块可逆、E 真机端到端（默认跳）、F 全链路真装（默认跳）。
- `staging-rename-selftest.ps1 -只跑A` —— sh 预备命令在 git bash 下实跑；B 段（真主机五个改名场景）要 `-含真机`。
- `zombie-session-selftest.ps1` —— 僵尸会话清理判据（误杀守卫）离线跑；B 段实连主机，连不上自动 SKIP。
- `rescue-detection-selftest.js` —— 终端超时检测口径回归（复刻 2026-10-22 空壳会话把真会话挤掉的事故）。
- `payload-load-check.js` —— 渲染器载荷的占位符替换、残留校验、语法可解析性（不连 CDP）。
- `log-event-selftest.sh` —— `log_event` 单一时钟自检，从真实 `remote-install-linux.sh` 抽代码跑（需 git bash）。

**耗时回归自检（`-跳过耗时` 可跳）**

- `dual-end-inflight-labeling-selftest.ps1` —— 两端在途命名、属主认领、发布改名、端标注（68 项，含 sh 干跑）。
- `download-log-selftest.ps1` —— 下载器实跑约 60 秒，核对进度行可解析、一次中断恒为一条消息。
- `local-supply-selftest.ps1` —— 本地供给：完整性校验、属主判定、上传改名（起子进程约 45 秒）。
- `supply-concurrency-selftest.ps1` —— 并发供给：活属主的在途文件绝不能被抢（含「1MB 半成品但没有句柄」这种边角）。

**取证工具（出事时才跑，别进自检清单）**

- `远端体检.ps1 -主机 <名>` —— 一次 SSH 只读普查：powershell/sshd/Start-Job 计数、**引导进程三分类**（生产固定引导码 / 其中疑似卡死孤儿 / 其它 EncodedCommand）、DefaultShell 与 `IsOutputRedirected`、竞速目录与残包、盘符、家目录**实际可写性**（写一个探针文件再删，`df` 显示空闲不代表配额没满）。可选 `-测下载速率` 两次采样求差。
  孤儿判据**三个条件缺一不可**：带生产引导码特征（`取-引导码特征`）+ 龄 >180s + CPU <1s（一直阻塞在读取里没干活；正在下 190MB 的安装 CPU 不是 0）。只按「EncodedCommand + 超龄」认孤儿的旧判据实测把两个 7772s 的进程报成待杀孤儿，实际那两个是**我自己早先的探针**（argv 971/955 字符，不是 5772 字符的固定引导码）；同一条错判据碰上正在跑的安装就会建议杀掉活安装，所以宁漏不误，连 CPU 都读不到就当「不杀」。
- `prod-faithful-repro.ps1` —— 用生产同形态载荷真连一次，四个场景：默认快标记、`-大载荷`（2300 个 GUID）、`-冷启动计时`、`-慢安装`（30 秒沉默），逐行打 `@秒` 到达记录，判读段直接给「是缓冲还是没送达」的结论。
- `remote-stale-tree-clean.ps1 -龄下限秒 300`（或 `-连接起点 "yyyy-MM-dd HH:mm:ss"`）—— 陈旧引导树清点。**默认只清点不动手**，`-清理` 才杀；只杀带生产固定引导码特征者与其 Start-Job 工作进程，**其它 EncodedCommand 一概只报告不动手**（可能是别人的自动化）。
  优先用 `-龄下限秒`：龄由**远端自己的时钟**算，不受两边时钟偏差影响。`-连接起点` 是本地生成的时间戳却要拿去和远端进程启动时刻比——实测 B 服务器远端比本地慢约 4 分钟，偏得够多时会把正在用的会话判成陈旧。实测：清理时恰好有一个刚起 2 秒的生产引导进程（真安装/预连接），龄判据让它 `陈旧=False` 而幸免；被清掉的是那两个 873s、CPU 0.5s 的残留。
- `zombie-session-run.ps1` —— 把模块里**原样抽出**的清理代码块在真主机上执行一次真清理并复检（自检已核对判据不会误杀）。
- `ssh-传输容量取证.ps1` —— ① 各阶段体积（走 `构造-单会话载荷`，不再自己抄算法）② DefaultShell 对比 ③ 纯 argv 容量上限 ④ stdin 通道四档（2/40/120/400 KB）长度 + SHA256 双判据。
- `远端时钟偏差.ps1 [-主机列表 <名>,<名>] [-重复次数 N]` —— RTT 补偿法量「本机时钟 − 远端时钟」（本机 t0 → 远端 `Get-Date` → 本机 t1，偏差取中点差、不确定度 = 往返的一半；远端命令走 `-EncodedCommand` 避开引号剥离，全程只读）。同一份日志里混了两套时间戳时用它拿真数字：实测上科大A ≈ −0.5 秒（已同步）、上科大B ≈ +225 秒——偏差逐主机不同且会漂移，**不要**把某个主机的值当常数写进代码或注释（我曾把从日志推算的「3 分 48 秒」写成「实测」，后被本探针证伪为 225 秒）。
- `cdp-alive.js` / `bundle-grep.js` —— 窗口是否还响应（3 秒内回 `Runtime.evaluate`）；从 `workbench.desktop.main.js` 按正则切上下文，读混淆 bundle 的真实机制（别凭记忆猜字段名）。
- `window-inject.js` / `window-identify-close.js` —— 附着 renderer、经生产同款钥匙交接拿 DI 容器引用、按序执行 `payloads/*.js`；识别「authority 解码失败被当主机名」的坏窗口并关掉（`--close`）。
- `_vscode_stub_full.js` —— `vscode` 模块桩，让 `terminalRescue.js` / `cdp.js` 能在纯 node 下被 require（只覆盖 require 期与自测路径的最小 API 面）。
- `cdp-selftest.js` —— 在 VS Code 之外验证 CDP 三段载荷（钥匙/诊断/修复）对真实活窗口可用，需 `-含窗口`。

**载荷**（经 `window-inject.js` 注入窗口）

- `payloads/trust-state.js` `trust-match.js` `trust-compare.js` `trust-repair.js` `grant-trust-record.js` —— 工作区信任状态取证、匹配口径对比、修复与授权记录。
- `payloads/gate-probe.js` `cleanup.js` `exthost-restart.js` `reload-window.js` `final-recover.js` —— 卡点探查、清理、扩展宿主重启、重载窗口、终极恢复。

# 三条铁律（都是线上踩出来的）

一、**远端脚本一律 argv 内 base64 派发，载荷才走 stdin（且必须显式 Close + 看门狗 + 到达回执）。**
`… | ssh host "bash -s"` 会被 PS 5.1 换成 CRLF，远端把 `\r` 并进命令（`exit 0\r` → numeric argument required），整体退 255 且现象诡异。载荷过大放不进 argv（Windows 命令行约 32 KB，超了 ssh.exe 直接拒绝启动），才走 stdin；走 stdin 就必须：写完 ASCII 字节 → `Flush()` → **显式 `Close()`**（远端等 EOF）→ 到点 `taskkill /PID … /T`。远端侧则必须有界读取并在执行安装脚本**之前**先回一行「载荷已到达」——2026-10-23 上科大B服务器那次卡死就是缺这两样：本地 `taskkill` 传不到远端，无界 `ReadToEnd()` 变永久孤儿，孤儿堆满 sshd 后首字节延迟超过看门狗，杀得更凶，形成死亡螺旋。

二、**任何远端等待都得有界，探针自己不留孤儿。**
`Start-Job` + `Wait-Job -Timeout`（库里 `取-远端有界计时包装`），超时就明说「挂死，卡点坐实」而不是继续等。判进程脱离不能只看 PGID/SID，要同时打 pid/ppid/pgid/sid 四列，且必须在**真实调用路径**下复测（隔离测试时父进程早已退出，PPID=1 会掩盖差异）。

但「有界读取」**不等于**「有界执行」——这是本轮整理时新发现的残留风险（2026-10-23 B 服务器实测）：引导已经拿到载荷、脚本也跑完打了标记，可本地 ssh 先退出/被看门狗杀掉之后，远端那对 powershell 包装进程 **751 秒仍在场、CPU 只有 0.5s**，即它卡在写出（管道另一端没人读，Windows 匠名管道约 4KB 写满即永久阻塞）。90 秒的有界读只管「载入阶段」，管不到执行阶段。所以：任何在远端长时间跑的引导都应有**执行期的自限**（例如周期性查自己的 sshd 祖先进程是否还在，不在就退出）；在落地之前，孤儿仍会产生，靠 `远端体检.ps1` 认 + `remote-stale-tree-clean.ps1 -龄下限秒` 收。

三、**同一个算法只能有一份实现，且必须有漂移守卫。**
载荷构造只有 `构造-单会话载荷`（psm1 是线上实现，库是探针实现，自检负责证明二者逐字符一致）。断言消息若由 `+` 拼接，**整段必须加括号**：裸写在参数位置时 `+`、变量、尾串会变成多余实参，命令在绑定阶段就抛 `PositionalParameterNotFound`，脚本却接着跑完并报「0 失败」。本轮整理靠 `扫-裸拼接实参` 抓到两条这样的断言——它们长期根本没执行过，其中一条正是「检测到在用连接就拒绝运行」的告警。`跑全部自检.ps1` 跑前的静态闸门会挡住这类假绿。

# 排障时先跑哪一个

| 症状 | 先跑 | 看什么 |
| --- | --- | --- |
| 安装卡在「下发引导码」之后不动 | `远端体检.ps1 -主机 <名>` | 疑似卡死孤儿 >0（三条件都成立才算）→ 去 `remote-stale-tree-clean.ps1 -龄下限秒 300` 先清点；sshd 数 ≥30 → 会话饱和；家目录可写=否 → 配额/权限 |
| 怀疑 stdin 没送到或被缓冲 | `prod-faithful-repro.ps1 -慢安装` | 到达记录的 `@秒`：首行早、后续沉默=输出缓冲；一行都没有=载荷没送到或远端秒死 |
| 竞速目录里出现半成品互相踩 | `dual-end-inflight-labeling-selftest.ps1`、`supply-concurrency-selftest.ps1` | 在途名是否带 PID、活属主是否被抢 |
| 远端日志口径变了/少了真因 | `report-point-audit.ps1`、`download-log-selftest.ps1` | 每个分支是否都有结论、进度与中断行是否可解析 |
| 传输体量怀疑超限 | `ssh-传输容量取证.ps1` | ④ 四档哈希是否全对、③ argv 上限在哪 |
| 日志里远端时间戳与外层时间戳对不上 | `远端时钟偏差.ps1 -主机 <名> -重复次数 3` | 偏差秒数与是否漂移；根治办法是远端不自带时钟（生产侧已执行），不是事后换算 |
| 窗口内状态不对（信任/卡点） | `cdp-alive.js` → `window-inject.js payloads/trust-state.js` | 先确认窗口活着，再注入取证，别凭日志猜 |

# 新增自检的规矩

1. 用库的台账：`Initialize-断言` + `写-断言`（或文件内的一行薄转发 `断言`），别自己数计数。
2. 写进 `跑全部自检.ps1` 的清单并标类别；需要真机或活窗口的，默认必须能 SKIP，不能把环境不可用报成回归。
3. 断言消息带 `+` 拼接时整体加括号；闸门 0 会静态扫。
4. 每条否定式断言都要配**正向对照**：同一个判据拿去测「确实坏掉的输入」必须报红。没有对照的断言等于没测（本目录里 `report-point-audit`、`lib-selftest` 都有「取样正向对照：代码文本非空」这类兜底）。
5. 断言生产代码时优先用 `(Get-Command 生产函数).Definition` 抽函数体，别复制粘贴一份——复制品会随生产改动静静过期。
6. 探针脚本必须 UTF-8 带 BOM（PS 5.1 无 BOM 会把中文标识符读歪）。**编辑器/工具链每次写文件都可能抹掉 BOM**（实测改一次掉一次），所以 `跑全部自检.ps1` 的闸门 0a 会先调 `补-脚本BOM` 把所有探针规范到恰好 1 个 BOM（补完还会报出改了哪几个），再跑 AST 扫描——扫描本身也要靠 BOM 才能正确读中文标识符。

# 这次整理删掉了什么、为什么

删除标准只有一条：**这段逻辑已经被库或已产品化的代码覆盖，或它回答的是一次性问题**。共删 30 个文件。

- 一次性主机调查（8 个）：`b-server-probe.ps1`、`b-server-probe2.ps1`、`remote-state-readonly.ps1`、`remote-session-probe.ps1`、`remote-server-probe.ps1`、`remote-zombie-probe.ps1`、`remote-hang-probe.ps1`、`remote-ssh-event-probe.ps1` → 全部由 `远端体检.ps1` + `取-远端普查脚本` 覆盖。
- 通道机制试探（8 个）：`stdin-roundtrip-repro.ps1`、`stdin-method-test.ps1`、`output-buffering-test.ps1`、`writehost-buffering-test.ps1`、`stream-visibility-test.ps1`、`stream-transport-repro.ps1`、`defaultshell-compare.ps1`、`zombie-cleanup-timing.ps1` → 结论已写进生产代码与本文铁律，试探过程不必留存；容量口径由 `ssh-传输容量取证.ps1` 承担。
- 已被产品化取代的载荷（10 个）：`pty-channel-repair.js`、`pty-live-final.js`、`terminal-live-probe.js`、`local-terminal-probe.js`、`launch-trace.js`、`launch-trace2.js`、`launch-instrument.js`、`deep-walk.js`、`container-scan.js`、`lock-hunt.js` → 同类能力已固化进扩展的 `renderer-scripts/`（`channel-diagnose`、`channel-repair`、`key-handover`），探针副本只会与线上分叉。
- 清理与挂起试验（2 个）：`zombie-cleanup-repro.ps1`、`stopprocess-hang-test.ps1` → 判据已进 `zombie-session-selftest.ps1`，实跑工具是 `zombie-session-run.ps1` / `remote-stale-tree-clean.ps1`。
- 另重写 2 个（先删后按库重写）：`prod-faithful-repro.ps1`、`remote-stale-tree-clean.ps1`（后者改为**默认清点、`-清理` 才动手**，避免排障时误杀在用会话）。
