@{
	RootModule           = '安装-VSCode远程服务.psm1'
	ModuleVersion        = '1.1.1'
	GUID                 = '2e2606a2-1d8b-418e-9d6d-a714a7704bdc'
	Author               = '埃博拉酱-机器人'
	CompanyName          = '一致行动党'
	Copyright            = '(c) 2026 一致行动党. 保留所有权利。'
	Description          = @'
通过 SSH 在远程主机上安装与本机 VS Code 版本严格匹配的 VS Code Server。

功能特性：
- 自动检测远程系统类型（Windows / Linux），无需用户指定
- Windows 使用 HTTP 断点续传下载（基于 Range 头，中断后自动从已下载字节数处续传），按远程 PowerShell 版本自动选择通用版或 Win7 兼容版脚本；Win7 版压缩包由本机下载后中转上传，不在远程发起下载
- Linux 使用 sh 脚本下载安装，自动检测 x64 / arm64 / armhf 架构，支持 curl / wget，含备用下载源
- 自动读取本机 VS Code 提交号与发布通道（稳定版 / 预览版），下载与之完全对应的服务端
- 基于 SSH_ASKPASS 的密码复用，全程只需输入一次密码；已配置密钥免密的主机完全免交互

使用语法：
  安装-VSCode远程服务 -远程主机 <主机名或IP> [-远程账户 <账户>] [-SSH端口 <端口>] [-本地版本 <预览版|稳定版>]

下载行为：Windows HTTP 断点续传 / Linux curl+wget 下载均无限重试、无超时；失败后等待间隔逐次递增，进度输出带时间戳

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
Windows 通用版脚本不再使用 BITS（SSH 远程登录会话下 BITS 必然报 0x800704DD），改为基于 HTTP Range 头的断点续传下载：单次运行内任何传输中断都会自动从已下载字节数处续传，无限重试、无超时，失败等待间隔逐次递增。
'@
		}
	}
}
