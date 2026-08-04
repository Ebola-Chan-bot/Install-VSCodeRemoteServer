@{
	RootModule           = '安装-VSCode远程服务.psm1'
	ModuleVersion        = '1.1.0'
	GUID                 = '2e2606a2-1d8b-418e-9d6d-a714a7704bdc'
	Author               = '埃博拉酱-机器人'
	CompanyName          = '一致行动党'
	Copyright            = '(c) 2026 一致行动党. 保留所有权利。'
	Description          = '通过 SSH 在远程主机上安装与本机 VS Code 对应版本的 VS Code Server。自动检测远程系统类型：Windows 使用 BITS 下载并按 PowerShell 版本选择适配脚本（通用版 / Win7 兼容版），Linux 使用 sh 脚本下载安装。'
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
'@
		}
	}
}
