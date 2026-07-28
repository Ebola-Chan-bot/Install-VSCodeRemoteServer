@{
	RootModule           = '安装-VSCode远程服务.psm1'
	ModuleVersion        = '1.0.2'
	GUID                 = '2e2606a2-1d8b-418e-9d6d-a714a7704bdc'
	Author               = '埃博拉酱-机器人'
	CompanyName          = '一致行动党'
	Copyright            = '(c) 2026 一致行动党. 保留所有权利。'
	Description          = '通过 SSH 与 BITS 在远程 Windows 主机上安装与本机 VS Code 对应版本的 VS Code Server。自动检测远程 PowerShell 版本并选择适配的安装脚本（通用版 / Win7 兼容版）。'
	PowerShellVersion    = '5.1'
	RequiredModules      = @()
	FunctionsToExport    = @('安装-VSCode远程服务')
	CmdletsToExport      = @()
	VariablesToExport    = @()
	AliasesToExport      = @()
	PrivateData          = @{
		PSData = @{
			Tags         = @('PowerShell', 'VSCode', 'RemoteSSH', 'VSCodeServer', 'Windows', 'BITS', 'SSH')
			LicenseUri   = 'https://opensource.org/licenses/MIT'
			ProjectUri   = ''
			ReleaseNotes = @'
支持Win7
'@
		}
	}
}
