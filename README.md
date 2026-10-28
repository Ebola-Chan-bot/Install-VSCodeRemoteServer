这是仅供 VS Code 使用的 Remote-SSH 安装接管扩展。按主机勾选后，扩展会在每次连接前安装与当前 VS Code 提交号严格匹配的 Server；未勾选的主机保持 Remote-SSH 自带安装。

# 使用

1. 安装扩展后，运行「RemoteSSH服务器安装: 选择接管与保活的主机…」。
2. 分别勾选要接管安装和启用保活的主机，两组清单可独立设置、可重叠。
3. 每次连接都会自动执行安装检查；CLI、服务端及旧 glibc 兼容环境均按需处理，无需从命令行导入模块或运行安装命令。

扩展使用本机 PowerShell 脚本执行 preconnect，脚本必须能免密登录远程主机。Remote-SSH 的标准输入是 `ignore`，不支持在连接过程中交互输入密码。脚本路径与 Remote-SSH 授权记录仅保留在本机，`remote.SSH.preconnect` 会被加入 `settingsSync.ignoredSettings`，避免其它机器的用户目录覆盖本机路径。

# 安装与竞速

- 自动识别 Windows / Linux、远程架构、登录目录和本机 VS Code 发布通道。
- CLI 与服务端按同一顺序串行竞速：CLI 决出后再处理服务端；每个产物内部由本地下载+上传与远程自下载并行。
- 支持 HTTP Range 断点续传、完整性校验、并发连接隔离与失败连接残留清理。
- 旧 glibc Linux 主机按需部署官方 sysroot 和原生模块补丁。
- 可选服务保活：Linux 上通过双 `fork`、`setsid` 与进程名豁免，使 Server 在 SSH 会话被周期回收后继续存活，重连时热附着。

详细设置、外部 preconnect 脚本处理及还原行为见 [扩展 README](接管远程服务器安装扩展/README.md)。