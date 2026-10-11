本文件记录「接管远程服务器安装」扩展的版本变更，版本号遵循语义化版本。

# 1.0.0

- 首个版本：提供唯一开关「安装VSCode远程服务.接管远程服务器安装」。
- 开启后 Remote-SSH 每次连接前由 Install-VSCodeRemoteServer 模块安装远程服务器，替换 Remote-SSH 自带的安装步骤。
- 关闭后把 `remote.SSH.preconnect` 还原为接管前的取值并删除接管脚本，Remote-SSH 恢复自带安装。
- 接管范围自动取自 `~/.ssh/config`（含 `Include` 展开），接管前已有的 preconnect 脚本按主机链式保留。
