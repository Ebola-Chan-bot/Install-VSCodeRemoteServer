#!/bin/sh
# sysroot 部署脚本（旧 glibc 主机专用）
# 此文件通过主模块上传到远程主机执行，__目录__ 占位符会在上传前被替换为实际 sysroot 安装路径。在远端解包（rpm2cpio|cpio 保留 symlink；CentOS/RHEL 系必有此二工具），避免 Windows 侧处理 Linux symlink 的坑。关键：EL8 RPM 解包后 glibc 核心库在 lib64/（loader 也在其中），libstdc++/libgcc 在 usr/lib64/；而 loader 只搜索自己所在目录与 rpath，故将全部库归并到 loader 所在目录，环境变量写探测到的真实路径。
set -eu
SYSROOT='__目录__'
STAGE="$SYSROOT/.stage"

echo "[sysroot] 开始组装: $SYSROOT"
mkdir -p "$SYSROOT/glibc" "$SYSROOT/bin"
cd "$STAGE"

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
	printf '%s\n' '# >>> vscode-sysroot (安装-VSCode远程服务 模块自动注入) >>>'
	printf 'export VSCODE_SERVER_CUSTOM_GLIBC_LINKER="%s"\n' "$LOADER"
	printf 'export VSCODE_SERVER_CUSTOM_GLIBC_PATH="%s"\n' "$LIBDIR"
	printf 'export VSCODE_SERVER_PATCHELF_PATH="%s/bin/bin/patchelf"\n' "$SYSROOT"
	printf '%s\n' '# <<< vscode-sysroot <<<'
	sed '/# >>> vscode-sysroot/,/# <<< vscode-sysroot/d' "$RC"
} > "$TMPRC"
mv "$TMPRC" "$RC"

rm -rf "$STAGE"
echo '[sysroot] 部署完成。'
