#!/bin/sh
# sysroot 部署脚本（旧 glibc 主机专用）
# 此文件通过主模块上传到远程主机执行，__目录__ 占位符会在上传前被替换为实际 sysroot 安装路径。在远端解包（rpm2cpio|cpio 保留 symlink；CentOS/RHEL 系必有此二工具），避免 Windows 侧处理 Linux symlink 的坑。关键：EL8 RPM 解包后 glibc 核心库在 lib64/（loader 也在其中），libstdc++/libgcc 在 usr/lib64/；而 loader 只搜索自己所在目录与 rpath，故将全部库归并到 loader 所在目录，环境变量写探测到的真实路径。
set -eu
SYSROOT='__目录__'
STAGE="$SYSROOT/.stage"

echo "[sysroot] 开始组装: $SYSROOT"
mkdir -p "$SYSROOT/glibc" "$SYSROOT/bin"
cd "$STAGE"

# ===== 双端竞速取材：本地供给上传（上传器落在竞速暂存目录）与远程自下载并行，先到先得 =====
# 远程胜出即写取消标记让本地供给止损；本地胜出直接取件。远程全部源失败不立即放弃——继续等本地供给，两边都取不到才报错。
RACE='__竞速暂存目录__'

start_fetch() {
	NAME=$1
	shift
	if [ -f "$NAME" ] || [ -f "$STAGE/$NAME" ]; then
		echo "[sysroot] $NAME 已就位"
		return 0
	fi
	if [ -n "$RACE" ] && [ -f "$RACE/$NAME" ]; then
		mv -f "$RACE/$NAME" "$STAGE/$NAME"
		echo "[sysroot] $NAME 由本地供给提供"
		return 0
	fi
	# 远程自下载：多源断点续传、逐源轮试，落 .part 就绪后原子改名；胜利后写取消标记让本地供给止损
	(
		for U in "$@"; do
			if command -v curl >/dev/null 2>&1; then
				# 显式 UA 必带：centos-vault 镜像对无 UA 请求回 403（同本地侧硬约束）
				curl -fL -C - -A 'Mozilla/5.0' --connect-timeout 10 --retry 2 -o "$STAGE/$NAME.part" "$U" && mv -f "$STAGE/$NAME.part" "$STAGE/$NAME" && exit 0
			fi
			if command -v wget >/dev/null 2>&1; then
				wget -c -q -U 'Mozilla/5.0' -T 10 -O "$STAGE/$NAME.part" "$U" && mv -f "$STAGE/$NAME.part" "$STAGE/$NAME" && exit 0
			fi
		done
		rm -f "$STAGE/$NAME.part"
	) >/dev/null 2>&1 &
	echo "[sysroot] $NAME 远程自下载已在后台启动"
}

wait_fetch() {
	DEADLINE=$(( $(date +%s) + 600 ))
	while :; do
		MISSING=''
		for NAME in "$@"; do
			if [ -f "$STAGE/$NAME" ]; then
				# 已就位（远程下载或先前取件）：顺手让本地供给止损
				if [ -n "$RACE" ]; then touch "$RACE/BUNDLE_CANCEL.$NAME" 2>/dev/null; fi
				continue
			fi
			if [ -n "$RACE" ] && [ -f "$RACE/$NAME" ]; then
				mv -f "$RACE/$NAME" "$STAGE/$NAME"
				echo "[sysroot] $NAME 由本地供给提供"
				continue
			fi
			MISSING="$MISSING $NAME"
		done
		if [ -z "$MISSING" ]; then
			return 0
		fi
		if [ "$(date +%s)" -ge "$DEADLINE" ]; then
			echo "[sysroot] 错误: 双端均未取到素材:$MISSING（本地下载/上传与远程自下载都未成功，请检查网络后重试）" >&2
			return 1
		fi
		echo "[sysroot] 等待素材就位:$MISSING（本地供给上传或远程下载中）"
		sleep 20
	done
}

__取材阶段__

for RPM in glibc-*.rpm libstdc++-*.rpm libgcc-*.rpm; do
	echo "[sysroot] 解包 $RPM"
	rpm2cpio "$RPM" | (cd "$SYSROOT/glibc" && cpio -idmu --quiet)
done

echo '[sysroot] 解包 patchelf'
TARFILE=$(ls patchelf-*.tar.gz | head -1)
tar -xzf "$TARFILE" -C "$SYSROOT/bin"
chmod +x "$SYSROOT/bin/bin/patchelf"

echo '[sysroot] 归并库目录（loader 与全部库必须在同一目录）'
# 锚定 glibc 原生目录：必须选 ld-2.28.so 实体文件所在目录（RPM 解包后为 lib64/）。绝不能用复制到其它目录的 loader：实测副本目录作解释器会让 loader 初始化 segfault。
LOADER_REAL=$(find "$SYSROOT/glibc" -name 'ld-*.so' -type f 2>/dev/null | head -1)
if [ -z "$LOADER_REAL" ]; then
	echo '[sysroot] 错误: 未找到动态链接器实体文件 ld-*.so' >&2
	exit 1
fi
LIBDIR=$(dirname "$LOADER_REAL")
# 把其它目录的库全部复制进原生目录（libstdc++/libgcc 在 usr/lib64/）；-a 保留符号链接形态
for OTHER in $(find "$SYSROOT/glibc" -name '*.so*' 2>/dev/null); do
	OD=$(dirname "$OTHER")
	if [ "$OD" != "$LIBDIR" ]; then
		cp -a "$OTHER" "$LIBDIR/" 2>/dev/null || true
	fi
done
# 自愈：清除任何非原生目录的 loader 副本/软链（防旧版本部署残留误导后续探测）
for STALE in $(find "$SYSROOT/glibc" -name 'ld-linux-x86-64.so.2' 2>/dev/null); do
	SD=$(dirname "$STALE")
	if [ "$SD" != "$LIBDIR" ]; then
		rm -f "$STALE" 2>/dev/null || true
	fi
done
LOADER="$LIBDIR/ld-linux-x86-64.so.2"

echo '[sysroot] 验证组件'
"$SYSROOT/bin/bin/patchelf" --version
GLIBC_VER=$("$LOADER" --version 2>/dev/null | head -1)
echo "[sysroot] loader: $LOADER"
echo "[sysroot] sysroot glibc: $GLIBC_VER"
case "$GLIBC_VER" in
	*2.28*) ;;
	*) echo '[sysroot] 警告: sysroot glibc 版本异常' ;;
esac
# 归并目录下必须能看到 libstdc++ 3.4.25（node 原生模块依赖）
if strings "$LIBDIR/libstdc++.so.6" 2>/dev/null | grep -q GLIBCXX_3.4.25; then
	echo '[sysroot] libstdc++ GLIBCXX_3.4.25 就绪'
else
	echo '[sysroot] 警告: libstdc++ 未含 GLIBCXX_3.4.25'
fi

echo '[sysroot] 注入 ~/.bashrc 环境变量块（顶部，幂等重建）'
RC="$HOME/.bashrc"
touch "$RC"
TMPRC="$RC.vscsysroot.$$"
{
	printf '%s\n' '# >>> vscode-sysroot (VS Code 扩展自动注入) >>>'
	printf 'export VSCODE_SERVER_CUSTOM_GLIBC_LINKER="%s"\n' "$LOADER"
	printf 'export VSCODE_SERVER_CUSTOM_GLIBC_PATH="%s"\n' "$LIBDIR"
	printf 'export VSCODE_SERVER_PATCHELF_PATH="%s/bin/bin/patchelf"\n' "$SYSROOT"
	printf '%s\n' '# <<< vscode-sysroot <<<'
	sed '/# >>> vscode-sysroot/,/# <<< vscode-sysroot/d' "$RC"
} > "$TMPRC"
mv "$TMPRC" "$RC"

rm -rf "$STAGE"
echo '[sysroot] 部署完成。'
