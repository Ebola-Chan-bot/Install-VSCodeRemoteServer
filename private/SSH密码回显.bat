@echo off
rem SSH_ASKPASS 回调：把当前进程环境变量中的密码打印到 stdout 供 ssh 读取
rem 环境变量由模块在收集密码时写入，仅存在于当前 PowerShell 会话及其子进程中
echo %VSCODE_SSH密码%
