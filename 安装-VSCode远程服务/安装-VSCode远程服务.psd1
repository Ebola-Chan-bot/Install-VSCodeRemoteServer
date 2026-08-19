@{
	RootModule           = '安装-VSCode远程服务.psm1'
	ModuleVersion        = '1.1.0'
	GUID                 = '2e2606a2-1d8b-418e-9d6d-a714a7704bdc'
	Author               = '埃博拉酱-机器人'
	CompanyName          = '一致行动党'
	Copyright            = '(c) 2026 一致行动党. 保留所有权利。'
	Description          = @'
通过 SSH 在远程主机上安装与本机 VS Code 版本严格匹配的 VS Code Server。

功能特性：
- 自动检测远程系统类型（Windows / Linux），无需用户指定
- Windows 使用 BITS 后台下载，按远程 PowerShell 版本自动选择通用版或 Win7 兼容版脚本
- Linux 使用 sh 脚本下载安装，自动检测 x64 / arm64 / armhf 架构，支持 curl / wget，含备用下载源
- 自动读取本机 VS Code 提交号与发布通道（稳定版 / 预览版），下载与之完全对应的服务端
- 基于 SSH_ASKPASS 的密码复用，全程只需输入一次密码；已配置密钥免密的主机完全免交互

使用语法：
  安装-VSCode远程服务 -远程主机 <主机名或IP> [-远程账户 <账户>] [-SSH端口 <端口>] [-本地版本 <预览版|稳定版>]

下载行为：Windows BITS / Linux curl+wget 下载均无限重试、无超时

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
			Tags         = @('PowerShell', 'VSCode', 'RemoteSSH', 'VSCodeServer', 'Windows', 'Linux', 'BITS', 'SSH')
			LicenseUri   = 'https://opensource.org/licenses/MIT'
			ProjectUri   = 'https://github.com/Ebola-Chan-bot/Install-VSCodeRemoteServer'
			ReleaseNotes = @'
新增 Linux 远程主机支持：自动检测远程系统类型（无需用户输入），Linux 主机通过 sh 脚本安装 VS Code Server，自动检测系统架构（x64/arm64/armhf），支持 prss 与官方备用下载源。
删除 轮询秒数/最大恢复次数/超时秒数/远程脚本版本 四个参数。下载一律无限等待、无限重试，进度输出带时间戳；Windows 远程脚本版本一律自动探测，不允许手动指定。
'@
		}
	}
}
