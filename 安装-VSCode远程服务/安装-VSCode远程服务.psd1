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
- 提供 安装-VSCode服务保活 入口：让 Linux 主机的 VS Code Server 脱离 SSH 会话存活，主机周期性回收超龄会话后本地重连可热附着，远端终端与扩展状态原地保留（-移除 可还原官方布局）

使用语法：
  安装-VSCode远程服务 -远程主机 <主机名或IP> [-远程账户 <账户>] [-SSH端口 <端口>] [-本地版本 <预览版|稳定版>]
  安装-VSCode服务保活 -远程主机 <主机名或IP> [-远程账户 <账户>] [-SSH端口 <端口>] [-本地版本 <预览版|稳定版>] [-移除]
  未指定账户或端口时，从 ~/.ssh/config 反查匹配项（优先 Host 精确/通配匹配，其次 HostName 等于主机名）

下载行为：Windows HTTP 断点续传 / Linux curl+wget 下载均无限重试、无超时

常用示例：
  # 基本用法（自动检测系统与版本）
  安装-VSCode远程服务 192.168.1.100 -远程账户 user

  # 指定端口与预览版
  安装-VSCode远程服务 10.15.49.6 -SSH端口 22112 -本地版本 预览版 -远程账户 v-jiamh

  # 让远程 VS Code Server 在会话被周期性回收后依然存活（本地重连热附着）
  安装-VSCode服务保活 bme_login_贾梦涵

  # 移除上述保活配置，还原官方原始布局
  安装-VSCode服务保活 bme_login_贾梦涵 -移除
'@
	PowerShellVersion    = '5.1'
	RequiredModules      = @()
	FunctionsToExport    = @('安装-VSCode远程服务', '安装-VSCode服务保活')
	CmdletsToExport      = @()
	VariablesToExport    = @()
	AliasesToExport      = @()
	PrivateData          = @{
		PSData = @{
			Tags         = @('PowerShell', 'VSCode', 'RemoteSSH', 'VSCodeServer', 'Windows', 'Linux', 'SSH')
			LicenseUri   = 'https://opensource.org/licenses/MIT'
			ProjectUri   = 'https://github.com/Ebola-Chan-bot/Install-VSCodeRemoteServer'
			ReleaseNotes = @'
竞速架构：Linux 与 Windows 通用版远程主机的 Server 包改为"远程自下载（后台）与本地下载+上传（后台作业）并行，先完成者获胜"。
旧 glibc Linux 主机自动部署官方 sysroot 妥协方案
修复 Windows 通用版竞速模式下远程自下载后台作业启动失败的问题
竞速中远程侧先完成时，本地供给任务被立即终止，不再继续消耗下载与上传
新增入口 安装-VSCode服务保活：Linux 远程主机的 VS Code Server 不再随 SSH 会话被回收而终止，本地断线重连后可热附着，远端终端与扩展状态不再丢失
安装-VSCode服务保活 -移除：卸载保活配置，把真实 CLI 移回数据目录并清理 .vscode-persistent，还原官方原始布局
修复 Windows 通用版补装 CLI 时反复报"文件被占用"并永久重试的问题：与 VS Code 连接自带安装并行时，CLI 已就位即视为安装完成，正常继续后续安装
远程安装过程的控制台输出不再因下载进度条刷新而出现汉字重影、行首大段空白等错乱
修复远程安装输出错位乱行、提前清屏的问题：远端控制台插入的终端控制序列不再透传到本地终端执行
安装结尾的目录清单不再与上一行粘连
修复 Windows 远程主机竞速模式下本地供给上传完成后"改名/标记命令失败（退出码 1）"、压缩包永远无法就位的问题
本地供给改名/标记命令失败时会一并显示远端报错内容，便于定位原因
修复竞速分出胜负时报"停止-供给进程树"无法识别错误的问题，本地下载/上传进程树按预期被立即终止
旧 glibc Linux 主机上扩展签名校验恢复正常，安装扩展不再报签名验证失败
'@
		}
	}
}
