#!/bin/sh
# 接管安装编排（由 Install-VSCodeRemoteServer 模块取本模板填入占位符后生成）：单会话依次完成各阶段，每段以对应阶段文件是否上传为门，未上传即整段跳过（与按需拼接等价）；阶段脚本随同一批上传带入登录目录（vsi-stage-* 前缀），本脚本负责串接、降级与收尾清理。阶段失败语义：安装按其退出码中止、sysroot/保活失败中止（20/21）、原生补丁失败仅告警。
if [ -f "$HOME/vsi-stage-sysroot.sh" ]; then
	echo '[接管安装-编排] 阶段: sysroot 兼容性环境'
	if find '__兼容性目录__/glibc' -name 'ld-*.so' -type f 2>/dev/null | grep -q . && '__兼容性目录__/bin/bin/patchelf' --version >/dev/null 2>&1 && grep -q 'vscode-sysroot (' "$HOME/.bashrc"; then
		echo '[sysroot部署] 远程 sysroot 已部署，跳过。'
	else
		mkdir -p '__兼容性目录__/.stage' || { echo '[接管安装-编排] 错误: 创建 sysroot 暂存目录失败' >&2; exit 20; }
		for F in "$HOME"/vsi-stage-bundle-*; do
			[ -f "$F" ] || continue
			mv -f "$F" '__兼容性目录__/.stage/'${F##*/vsi-stage-bundle-} 2>/dev/null
		done
		sh "$HOME/vsi-stage-sysroot.sh" || { echo '[接管安装-编排] 错误: sysroot 部署失败' >&2; exit 20; }
	fi
	case "$(echo "LINKER=$VSCODE_SERVER_CUSTOM_GLIBC_LINKER")" in
		'LINKER=__兼容性目录__'/*) echo '[接管安装-编排] 已验证非交互会话可见 VSCODE_SERVER_CUSTOM_GLIBC_LINKER。' ;;
		*) echo '[接管安装-编排] 警告: 非交互会话未读到 sysroot 环境变量（远程 shell 可能不是 bash），Remote-SSH 若仍报 glibc 错误请手动检查 ~/.bashrc。' ;;
	esac
fi
if [ -f "$HOME/vsi-stage-install.sh" ]; then
	echo '[接管安装-编排] 阶段: 远程安装'
	sh "$HOME/vsi-stage-install.sh"
	RC=$?
	if [ "$RC" -ne 0 ]; then
		echo "[接管安装-编排] 错误: 安装失败（退出码 $RC）" >&2
		exit "$RC"
	fi
fi
if [ -f "$HOME/vsi-stage-native.sh" ]; then
	echo '[接管安装-编排] 阶段: 原生组件补丁'
	sh "$HOME/vsi-stage-native.sh" || echo '[接管安装-编排] 提示: 原生补丁未完全成功，不阻断安装结果'
fi
if [ -f "$HOME/vsi-stage-keepalive.sh" ]; then
	echo '[接管安装-编排] 阶段: 服务保活检修'
	sh "$HOME/vsi-stage-keepalive.sh" || { echo '[接管安装-编排] 错误: 服务保活检修失败' >&2; exit 21; }
fi
echo '[接管安装-编排] 阶段: 收尾清理'
rm -rf '__暂存目录__' 2>/dev/null
rm -f "$HOME"/vsi-stage-* 2>/dev/null
echo '[接管安装-编排] 编排完成'
exit 0
