@{
	RootModule           = '安装-VSCode远程服务.psm1'
	ModuleVersion        = '2.0.1'
	GUID                 = '2e2606a2-1d8b-418e-9d6d-a714a7704bdc'
	Author               = '埃博拉酱-机器人'
	CompanyName          = '一致行动党'
	Copyright            = '(c) 2026 一致行动党. 保留所有权利。'
	Description          = @'
通过 SSH 在远程主机上安装与本机 VS Code 版本严格匹配的 VS Code Server。

功能特性：
- 自动检测远程系统类型（Windows / Linux），无需用户指定；裸 IP/主机名连接时会从 ~/.ssh/config 反查该主机对应的账户与端口
- Windows 使用 HTTP 断点续传下载（基于 Range 头，中断后自动从已下载字节数处续传），按远程 PowerShell 版本自动选择通用版或 Win7 兼容版脚本；Win7 版压缩包由本机下载后中转上传，不在远程发起下载
- Linux 使用 sh 脚本下载安装，自动检测 x64 / arm64 / armhf 架构，支持 curl / wget，含备用下载源
- 自动读取本机 VS Code 提交号与发布通道（稳定版 / 预览版），下载与之完全对应的服务端
- 基于 SSH_ASKPASS 的密码复用，全程只需输入一次密码；已配置密钥免密的主机完全免交互

使用语法：
  安装-VSCode远程服务 -远程主机 <主机名或IP> [-远程账户 <账户>] [-SSH端口 <端口>] [-本地版本 <预览版|稳定版>]
  未指定账户或端口时，从 ~/.ssh/config 反查匹配项（优先 Host 精确/通配匹配，其次 HostName 等于主机名）

下载行为：Windows HTTP 断点续传 / Linux curl+wget 下载均无限重试、无超时

常用示例：
  # 基本用法（自动检测系统与版本）
  安装-VSCode远程服务 192.168.1.100 -远程账户 user

  # 指定端口与预览版
  安装-VSCode远程服务 10.15.49.6 -SSH端口 22112 -本地版本 预览版 -远程账户 v-jiamh
'@
	PowerShellVersion    = '5.1'
	RequiredModules      = @()
	FunctionsToExport    = @('安装-VSCode远程服务')
	CmdletsToExport      = @()
	VariablesToExport    = @()
	AliasesToExport      = @()
	PrivateData          = @{
		PSData = @{
			Tags         = @('PowerShell', 'VSCode', 'RemoteSSH', 'VSCodeServer', 'Windows', 'Linux', 'SSH')
			LicenseUri   = 'https://opensource.org/licenses/MIT'
			ProjectUri   = 'https://github.com/Ebola-Chan-bot/Install-VSCodeRemoteServer'
			ReleaseNotes = @'
环境试探合并为单次 SSH 调用：一条跨 shell 兼容的多行探测命令一次取回系统类型、登录目录与 PowerShell 版本，并与免密探测合并（免密主机全程仅一次试探连接）；报告不完整时退回逐项试探保证正确性；Windows OpenSSH 不支持 ControlMaster 连接复用，故采用合并命令而非复用连接。
断点续传时进度报告周期不再重置为 1 秒：报告周期变量移到重试循环外初始化，跨续传段继承上一段的周期值。
修复老版 sshd（Win7 自带）挂起：探测类 ssh 调用全部加 -n（stdin 重定向 NUL）。此前在 Win7 主机上远程 powershell 命令输出后 sshd 仍等待 stdin 关闭，ssh 客户端永久挂起，导致逐项试探卡死；已在四台真实主机（Linux x2 / Win10+ / Win7 PS2）验证。
竞速架构：Linux 与 Windows 通用版远程主机的 Server 包改为"远程自下载（后台）与本地下载+上传（后台作业）并行，先完成者获胜"。本地模块在登录目录下的 race-<提交号> 暂存目录与远程脚本交换压缩包与带架构后缀的完成标记；胜方产生后写取消标记并终止败方下载。登录目录或远程架构无法确定时自动回退远程单独下载；Win7（PS2）版保持原本的本地供给方式不竞速。环境探测与逐项试探均新增远程架构取回（uname -m / %PROCESSOR_ARCHITECTURE%）。已在 bme_login（Linux x64，预览版）实测：本地侧 16 秒完成 221MB 下载+上传并获胜，安装完整性校验通过。
旧 glibc Linux 主机自动部署官方 sysroot 妥协方案：探测到远程 glibc < 2.28（如 CentOS 7 的 2.17）时，自动从清华/阿里 CentOS 8 镜像下载 glibc/libstdc++/libgcc RPM 与 patchelf 0.18（本地 TEMP 缓存复用），上传后在远程家目录 rpm2cpio 解包组装 vscode-sysroot（约 30MB，库归并到 loader 原生目录），并向 ~/.bashrc 顶部幂等注入 VSCODE_SERVER_CUSTOM_GLIBC_LINKER/GLIBC_PATH/PATCHELF_PATH 三个环境变量（带标记块）；Remote-SSH 连接时即按官方机制自动 patch server，不再报 glibc 先决条件错误（exitCode 207）。安装脚本本身绝不自行 patchelf——实测 patchelf 直接改写新版 node（v24）会静默损坏二进制且残留错误 interpreter 会误导官方 CLI 跳过修复；改为只以 loader 显式加载方式验证 sysroot 可用性（非破坏）。部署后自动验证非交互 SSH 会话能读到环境变量。已在 bme_login（glibc 2.17，内核 3.10，CentOS 7.6）实测：sysroot 部署、node 经 loader 启动验证（v24.21.0）、环境变量注入全部通过。
修复单连接环境探测在 Linux 主机上退化的问题：探测命令中含圆括号的 ARCH_PS 行依赖双引号包裹，而 PS 5.1 向原生命令传参时不转义内部双引号，远端 bash 收到裸 ( 即语法错误并中止整段脚本，导致所有 Linux 主机的探测报告不完整、每次连接多花 4 次往返退回逐项试探。现探测命令行内彻底禁用双引号与圆括号，架构改为裸值输出（uname -m / $env:PROCESSOR_ARCHITECTURE），解析端按值形态识别；已在 Linux/Windows/Win7 三台主机实测（Linux 与 Win10 恢复单连接完整报告，Win7 老 sshd 只执行首行的限制不变，仍由逐项试探兜底）。
'@
		}
	}
}
