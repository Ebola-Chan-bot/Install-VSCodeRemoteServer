#!/bin/sh
# 原生组件补丁脚本（旧 glibc 主机专用）
# 此文件通过主模块上传到远程主机执行。VS Code 有两类原生组件需要与 server 的 node 走同一套 sysroot 环境：
#   1) vsce-sign：扩展签名校验工具（.NET 单文件），依赖较新 libstdc++，做 node 同款 patch（解释器 + RPATH）；
#   2) *.node：扩展与服务端的 Node 原生模块。node 的 RUNPATH 不被 dlopen 的子对象继承，原生模块依赖的librt.so.1 / libutil.so.1等库（node 自身不预载）会落到系统老版本（2.17），与进程里已加载的 sysroot libc（2.28）混用后报 "undefined symbol ... version GLIBC_PRIVATE"，只需补 RPATH。
# 脚本自带安全机制：原件备份（.orig.bak 仅保留首次）、在临时副本上 patch、patch 后实际加载验证，通过才原子替换，失败保留原文件并告警；对已补丁文件幂等跳过。
set -eu

LINKER=${VSCODE_SERVER_CUSTOM_GLIBC_LINKER:-}
LIBDIR=${VSCODE_SERVER_CUSTOM_GLIBC_PATH:-}
PATCHELF=${VSCODE_SERVER_PATCHELF_PATH:-}
# 回退：登录 shell 非 bash 时环境变量不会自动到位，直接解析 ~/.bashrc 里 sysroot 部署写入的标记块
if [ -z "$LINKER" ] || [ -z "$LIBDIR" ] || [ -z "$PATCHELF" ]; then
	RC="$HOME/.bashrc"
	if [ -f "$RC" ]; then
		LINKER=$(sed -n 's/^export VSCODE_SERVER_CUSTOM_GLIBC_LINKER="\([^"]*\)".*/\1/p' "$RC" | head -1)
		LIBDIR=$(sed -n 's/^export VSCODE_SERVER_CUSTOM_GLIBC_PATH="\([^"]*\)".*/\1/p' "$RC" | head -1)
		PATCHELF=$(sed -n 's/^export VSCODE_SERVER_PATCHELF_PATH="\([^"]*\)".*/\1/p' "$RC" | head -1)
	fi
fi
if [ -z "$LINKER" ] || [ -z "$LIBDIR" ] || [ -z "$PATCHELF" ]; then
	echo '[原生补丁] 错误: 未读到 sysroot 环境配置，请先部署 sysroot 兼容性环境。' >&2
	exit 1
fi
if [ ! -x "$PATCHELF" ] || [ ! -f "$LINKER" ]; then
	echo '[原生补丁] 错误: sysroot 组件缺失（patchelf 或 loader 不可用）。' >&2
	exit 1
fi

# ===== vsce-sign（可执行文件）：解释器 + RPATH 双补，验证 = .NET 托管程序实际执行 =====
verify_vsce() {
	COREHOST_TRACE=1 "$1" --help 2>&1 | grep -q 'Execute managed assembly'
}

patch_vsce() {
	V="$1"
	echo "[原生补丁] 处理: $V"
	if [ ! -f "$V.orig.bak" ]; then
		cp -p "$V" "$V.orig.bak"
	fi
	cp -p "$V" "$V.patching"
	if "$PATCHELF" --set-interpreter "$LINKER" --add-rpath "$LIBDIR" "$V.patching" && verify_vsce "$V.patching"; then
		mv -f "$V.patching" "$V"
		echo "[原生补丁] 完成: $V"
		return 0
	fi
	rm -f "$V.patching"
	echo "[原生补丁] 警告: patch 后验证失败，保留原文件: $V" >&2
	return 1
}

# ===== *.node（Node 原生模块）：只补 RPATH（解释器由加载它的 node 提供），验证 = node 实际 dlopen =====
is_native_elf() {
	# 必须是本机架构的 ELF：Windows 预编译产物（PE）与其它架构的 prebuilds 直接跳过
	[ "$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' ')" = '7f454c46' ] || return 1
	MACHINE=$(od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' ')
	case "$(uname -m)" in
		x86_64|amd64) WANT=62 ;;
		aarch64|arm64) WANT=183 ;;
		armv7l|armv6l|arm) WANT=40 ;;
		*) WANT='' ;;
	esac
	[ -z "$WANT" ] || [ "$MACHINE" = "$WANT" ]
}

find_node_for() {
	# 从 .node 位置向上找同一 server 的 node（ABI 必须匹配），找不到退回数据目录下任意 node
	D=$(dirname "$1")
	while [ "$D" != '/' ]; do
		if [ -x "$D/node" ] && [ -f "$D/node" ]; then
			echo "$D/node"
			return 0
		fi
		D=$(dirname "$D")
	done
	if [ -n "${FALLBACK_NODE:-}" ]; then
		echo "$FALLBACK_NODE"
		return 0
	fi
	return 1
}

dlopen_ok() {
	# 用真实 node 加载验证链接可用；ABI/初始化类报错（如 did not self-register）与链接无关，不判失败
	OUT=$(VSCODE_PATCH_TARGET="$2" "$1" -e 'try{process.dlopen({exports:{}},process.env.VSCODE_PATCH_TARGET);console.log("DLOPEN_OK")}catch(e){console.log("DLOPEN_ERR:"+e.message)}' 2>&1) || return 1
	case "$OUT" in
		*DLOPEN_OK*) return 0 ;;
		*DLOPEN_ERR:*)
			case "$OUT" in
				*'undefined symbol'*|*GLIBC*|*GLIBCXX*|*'cannot open shared object'*|*'loading shared libraries'*|*'wrong ELF'*|*'exec format'*|*'not a dynamic executable'*|*'file too short'*) return 1 ;;
				*) return 0 ;;
			esac ;;
		*) return 1 ;;
	esac
}

patch_node() {
	V="$1"
	NODEBIN="$2"
	echo "[原生补丁] 处理: $V"
	if [ ! -f "$V.orig.bak" ]; then
		cp -p "$V" "$V.orig.bak"
	fi
	cp -p "$V" "$V.patching"
	if "$PATCHELF" --add-rpath "$LIBDIR" "$V.patching" 2>/dev/null && dlopen_ok "$NODEBIN" "$V.patching"; then
		mv -f "$V.patching" "$V"
		echo "[原生补丁] 完成: $V"
		return 0
	fi
	rm -f "$V.patching"
	echo "[原生补丁] 警告: patch 后验证失败，保留原文件: $V" >&2
	return 1
}

LIST="$HOME/.vscode-native-patch-list.$$"
trap 'rm -f "$LIST"' EXIT
FALLBACK_NODE=$(find "$HOME"/.vscode-server* -name node -type f -perm -u+x 2>/dev/null | head -1 || true)
FOUND=0
FAILED=0
for DIR in "$HOME"/.vscode-server*; do
	[ -d "$DIR" ] || continue
	find "$DIR" \( -path '*/@vscode/vsce-sign/bin/vsce-sign' -o -name '*.node' \) -type f 2>/dev/null > "$LIST" || true
	while IFS= read -r V; do
		[ -n "$V" ] || continue
		FOUND=1
		case "$V" in
			*.node)
				is_native_elf "$V" || continue
				# 幂等判据：RPATH 已含 sysroot 库目录即已补过
				case "$("$PATCHELF" --print-rpath "$V" 2>/dev/null || true)" in
					*"$LIBDIR"*) continue ;;
				esac
				if NODEBIN=$(find_node_for "$V"); then
					# 未补丁版本若已能正常加载，就无需补丁——绝不碰本已正常的模块。
					# 关键教训：握手签名模块 vsda 本可正常工作，被补 RPATH 后反而使连接握手
					# 签名校验失败（Refused to connect to unsupported server）。只补真正加载失败的。
					if dlopen_ok "$NODEBIN" "$V"; then
						continue
					fi
					patch_node "$V" "$NODEBIN" || FAILED=1
				else
					echo "[原生补丁] 警告: 未找到可验证的 node，跳过: $V" >&2
				fi
				;;
			*)
				# vsce-sign 幂等判据：解释器已指向 sysroot loader 且实际运行正常
				if [ "$("$PATCHELF" --print-interpreter "$V" 2>/dev/null || true)" = "$LINKER" ]; then
					if verify_vsce "$V"; then
						echo "[原生补丁] 已就绪，跳过: $V"
						continue
					fi
					echo "[原生补丁] 已 patch 但验证失败，回滚原件后重做: $V"
					if [ -f "$V.orig.bak" ]; then
						cp -p "$V.orig.bak" "$V"
					fi
				fi
				patch_vsce "$V" || FAILED=1
				;;
		esac
	done < "$LIST"
done

if [ "$FOUND" -eq 0 ]; then
	echo '[原生补丁] 未发现 vsce-sign 或原生模块（对应 server 尚未安装），跳过。'
fi
exit "$FAILED"
