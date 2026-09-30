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
'@
		}
	}
}
