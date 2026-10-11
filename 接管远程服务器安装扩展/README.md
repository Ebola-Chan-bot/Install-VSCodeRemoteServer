把 Install-VSCodeRemoteServer 模块接入 Remote-SSH：一个开关决定远程服务器由谁安装。开关开启时，Remote-SSH 每次连接前都由本模块安装远程服务器（本地下载+上传与远程自下载竞速、旧 glibc 自动部署官方 sysroot、CLI 引导预装），Remote-SSH 自带的安装步骤检测到服务端已就位便直接复用；开关关闭时一切还原为 Remote-SSH 自带安装。

# 功能特性

- **只有一个开关**：设置项「安装VSCode远程服务.接管远程服务器安装」，无需任何其它配置
- **开启即替换**：接管后远程服务器一律由本模块安装，Remote-SSH 自带安装步骤不再产出任何东西
- **关闭即还原**：把 `remote.SSH.preconnect` 恢复为接管前的取值、删除本扩展生成的接管脚本，Remote-SSH 恢复自带安装
- **接管范围自动确定**：`~/.ssh/config`（含 `Include` 展开）里的全部主机；接管前已配置过 preconnect 的主机也一并覆盖
- **链式兼容**：某主机接管前已有的 preconnect 脚本会在本模块安装完成后原样执行，既有行为不受影响
- **绝不阻断连接**：接管脚本出错只写日志不中止连接；未配置免密登录的主机自动跳过接管、保持 Remote-SSH 自带安装

# 使用方法

1. 在扩展设置里勾选「接管远程服务器安装」（等价于在 settings.json 写入 `"安装VSCode远程服务.接管远程服务器安装": true`）。
2. 之后每次 Remote-SSH 连接都会先经本模块安装远程服务器。首次连接时 VS Code 会弹一次 preconnect 脚本授权确认，选「Allow and Don't Ask Again」即可。
3. 取消勾选即还原为 Remote-SSH 自带安装。

# 工作原理

Remote-SSH 提供 `remote.SSH.preconnect` 设置：连接发起前在本机执行一个脚本（Windows 上必须是 `.ps1`，以 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File` 调用、不带任何参数、非零退出会中止连接）。本扩展开启接管后，把该设置指向自动生成的接管脚本，脚本调用本模块的 `安装-VSCode远程服务` 先把远程服务器装好；Remote-SSH 自带安装步骤随后发现服务端已就位便直接复用——安装由此被本模块替换。关闭开关则把设置改回原值，Remote-SSH 便重新按自带方式安装。

接管脚本由扩展按主机自动生成在扩展的全局存储目录，文件内容逐字节稳定（参与 Remote-SSH 的一次性授权确认，内容变化会重新弹窗），并且自带主机名（preconnect 不传参数）。

# 注意事项

- 还原的是「安装方式」：Remote-SSH 恢复自带安装；已由本模块装好的服务端原样保留（与自带安装产物同构，无需重装）。
- 接管期间请不要手动改写 `remote.SSH.preconnect`，该设置由本扩展管理；关闭开关时会整体恢复为接管前的取值。
- 免密登录（密钥认证）是接管的前提：需要交互输密码的主机无法在 preconnect 静默安装，扩展会自动跳过并保持 Remote-SSH 自带安装。
- VS Code 更新到新提交号后的首次连接同样由本模块安装对应版本，无需手动干预。
